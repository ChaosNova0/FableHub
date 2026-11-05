-- FableHub: guild roster + profession tracker for WoW: Forever
-- Core: namespace, saved data, events, shared helpers.

local ADDON, ns = ...
ns.VERSION = "0.28.0"
-- The sync format. Clients only take records, hashes and deltas from members
-- on the same protocol; any future change to the wire format bumps it.
ns.PROTOCOL = 2
-- Data era. Bumping it clears everyone's saved guild data once, and FableHub
-- moves to a new message channel ("FableHub" .. era), so clients still on
-- older versions can't send old data into the new one. Settings are kept.
ns.DATA_EPOCH = 3 -- 1 = Forever beta, 2 = launch (Nov 4, 2026), 3 = launch, 0.26 sync
-- Test suite only: the real client always defines WOW_PROJECT_ID, so in game
-- nothing can change the data era from outside FableHub
if FABLEHUB_TEST_EPOCH and not WOW_PROJECT_ID then ns.DATA_EPOCH = FABLEHUB_TEST_EPOCH end

------------------------------------------------------------------------
-- Small callback bus so the UI can react to data changes
------------------------------------------------------------------------
-- Errors inside FableHub are caught so one broken feature can't stop the rest,
-- but each distinct error is passed once to the game's error handler, so it
-- shows up in BugSack / "Display Lua errors" and can be reported.
local reported = {}
-- the last errors are kept in saved data for /fhub bug
local function LogError(err)
  if not FableHubDB then return end
  FableHubDB.errors = FableHubDB.errors or {}
  local list = FableHubDB.errors
  for _, e in ipairs(list) do
    if e.msg == err then e.n = (e.n or 1) + 1; e.t = time(); e.v = ns.VERSION; return end
  end
  table.insert(list, { msg = err:sub(1, 400), t = time(), n = 1, v = ns.VERSION })
  while #list > 20 do table.remove(list, 1) end
end
function ns.ReportError(err)
  err = tostring(err)
  ns.Debug("error: " .. err)
  if reported[err] then return end
  reported[err] = true
  pcall(LogError, err)
  local handler = geterrorhandler and geterrorhandler()
  if handler then pcall(handler, "FableHub " .. (ns.VERSION or "") .. ": " .. err) end
end

local listeners = {}
function ns.On(event, fn)
  listeners[event] = listeners[event] or {}
  table.insert(listeners[event], fn)
end
function ns.Fire(event, ...)
  local list = listeners[event]
  if not list then return end
  for _, fn in ipairs(list) do
    local ok, err = pcall(fn, ...)
    if not ok then ns.ReportError(err) end
  end
end

------------------------------------------------------------------------
-- Printing
------------------------------------------------------------------------
function ns.Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cff8fd3ffFableHub|r: " .. tostring(msg))
end
-- debug messages only ever show on the developer's account
function ns.Debug(msg)
  if FableHubDB and FableHubDB.settings and FableHubDB.settings.debug and ns.IsDeveloper() then
    DEFAULT_CHAT_FRAME:AddMessage("|cff888888FableHub debug|r: " .. tostring(msg))
  end
end

------------------------------------------------------------------------
-- Names. Character keys are always "Name-Realm" so data from the guild
-- roster, chat and our own character line up.
------------------------------------------------------------------------
function ns.MyRealm()
  local realm = GetNormalizedRealmName and GetNormalizedRealmName()
  if not realm or realm == "" then
    realm = (GetRealmName and GetRealmName() or ""):gsub("[%s%-]", "")
  end
  return realm
end

-- The realm in FableHub's character keys: the guild's home realm, so every
-- client labels everyone the same way. (On connected realms the roster gives
-- names without a realm, and each client used to add its own realm, so the
-- same character got different keys on different clients.)
-- (asked for every message and roster entry, so it's remembered until the guild changes)
function ns.KeyRealm()
  if ns._keyRealm then return ns._keyRealm end
  if IsInGuild and IsInGuild() and GetGuildInfo then
    local _, _, _, guildRealm = GetGuildInfo("player")
    if type(guildRealm) == "string" and guildRealm ~= "" then
      ns._keyRealm = (guildRealm:gsub("[%s%-]", ""))
      return ns._keyRealm
    end
  end
  return ns.MyRealm()
end

-- "Name" or "Name-AnyRealm" -> "Name-<KeyRealm>" (guild members are all on
-- connected realms; Forever names are unique "First Lastname")
function ns.NormalizeName(name)
  if not name or name == "" then return nil end
  local base = name:match("^([^-]+)") or name
  local realm = ns.KeyRealm()
  if realm == "" then return base end
  return base .. "-" .. realm
end

-- Our own key. The guild roster is the source of truth (Forever adds last
-- names, which UnitFullName reports differently), so once the roster loads we
-- match ourselves by GUID and adopt the roster's spelling of our name.
function ns.MyKey()
  if ns._myKey then return ns._myKey end
  local name, realm = UnitFullName("player")
  if not name then return nil end
  local legacy = name .. "-" .. ((realm and realm ~= "") and realm or ns.MyRealm()) -- how older versions keyed us
  -- Forever reports the last name where the realm would be ("Sniffin", "Tootsies")
  if realm and realm ~= "" and realm ~= ns.MyRealm() then name = name .. " " .. realm end
  ns._myKey = ns.NormalizeName(name)
  -- move our own record saved under an older spelling
  local chars = FableHubDB and FableHubDB.chars
  if chars and legacy ~= ns._myKey and chars[legacy] then
    if not chars[ns._myKey] or (chars[ns._myKey].ts or 0) < (chars[legacy].ts or 0) then
      chars[ns._myKey] = chars[legacy]
      chars[ns._myKey].key = ns._myKey
    end
    chars[legacy] = nil
  end
  return ns._myKey
end

function ns.SetMyKey(newKey)
  if not newKey or newKey == ns._myKey then ns._myKeyConfirmed = true return end
  local oldKey = ns._myKey
  ns._myKey = newKey
  ns._myKeyConfirmed = true
  if not FableHubDB then return end
  local chars = FableHubDB.chars
  if oldKey and chars[oldKey] then
    if not chars[newKey] or (chars[newKey].ts or 0) < (chars[oldKey].ts or 0) then
      chars[newKey] = chars[oldKey]
    end
    chars[oldKey] = nil
  end
  local rec = chars[newKey]
  if rec then
    rec.key = newKey
    rec.ts = math.max(ns.Now(), (rec.ts or 0) + 1) -- never backwards
  end
  for _, g in pairs(FableHubDB.guilds) do
    if oldKey then
      g.members[oldKey] = nil; g.addonUsers[oldKey] = nil
      if g.partials then g.partials[oldKey] = nil end
    end
  end
  ns.MirrorMyRecord()
  ns.Debug("your key is now " .. newKey .. (oldKey and (" (was " .. oldKey .. ")") or ""))
  if ns.QueueOwnBroadcast then ns.QueueOwnBroadcast(3) end
  ns.Fire("DATA_CHANGED")
end

-- display name: drop the realm part (character names can't contain "-")
function ns.ShortName(key)
  if not key then return "?" end
  return (key:match("^([^-]+)")) or key
end

function ns.ClassColor(classFile)
  local c = classFile and (C_ClassColor and C_ClassColor.GetClassColor(classFile)
    or (RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]))
  if c then return c.r, c.g, c.b end
  return 0.8, 0.8, 0.8
end

-- Developer account: test officer mode, debug messages and /dump FableHub.
-- Off unless this account's own saved data turns it on (nothing in the code
-- says who the developer is). To turn it on, once per account:
--   /run FableHubDB.settings.developer = true   then /reload
-- It only changes things on this computer: other players' FableHub judge
-- everyone by their real guild rank.
function ns.IsDeveloper()
  local db = FableHubDB
  return type(db) == "table" and type(db.settings) == "table" and db.settings.developer == true
end

function ns.Now()
  return (GetServerTime and GetServerTime()) or time()
end

-- the level cap (60 on Forever)
function ns.MaxLevel()
  return (GetMaxPlayerLevel and GetMaxPlayerLevel()) or MAX_PLAYER_LEVEL or 60
end

------------------------------------------------------------------------
-- Saved data
--   FableHubDB.guilds[guildKey].members[charKey] = record
--   record = { key, ts, class, level, profs = { [skillLine] = { name, rank, max, recipes = {[id]=true} } } }
--   FableHubDB.guilds[guildKey].partials[charKey] = a newer record of which
--     only the summary has arrived so far (everything but the recipes; see
--     ns.StoreSummaries). Kept apart from members, so the sync code (relaying,
--     owner checks, Activity) only ever sees whole records.
--   record.hash = checksum of the record's canonical encoding (Hash.lua
--     ns.HashOf), only ever worked out on this computer, never taken from a
--     message. Partials never carry one.
--   FableHubDB.guilds[guildKey].owner[charKey] = "<ts36>:<hash>": the version
--     and checksum the character's owner last announced first-hand (hello,
--     record or delta; see Comm.lua SetOwnerHash). Copies passed on by others
--     must match it.
------------------------------------------------------------------------
local DB_VERSION = 1

local STALE_GUILD = 90 * 86400 -- forget a guild's data after 90 days without visiting it

local function InitDB()
  FableHubDB = FableHubDB or {}
  local db = FableHubDB
  db.dbVersion = db.dbVersion or DB_VERSION
  db.guilds = db.guilds or {}
  db.settings = db.settings or {}
  db.chars = db.chars or {} -- your own characters' records, kept even if you change guild
  -- fresh start for a new data era (see ns.DATA_EPOCH): settings stay
  if (db.epoch or 1) < ns.DATA_EPOCH then
    ns.freshStart = next(db.guilds) ~= nil or next(db.chars) ~= nil
    db.guilds, db.chars, db.errors = {}, {}, nil
  end
  db.epoch = ns.DATA_EPOCH
  -- tidy guilds not visited for a long time (e.g. old characters, beta guilds)
  local now = time()
  for gk, g in pairs(db.guilds) do
    if not g.lastSeen then g.lastSeen = now
    elseif now - g.lastSeen > STALE_GUILD then db.guilds[gk] = nil end
  end
end

function ns.GuildKey()
  if not IsInGuild() then return nil end
  local guildName, _, _, guildRealm = GetGuildInfo("player")
  if not guildName then return nil end
  local faction = UnitFactionGroup("player") or ""
  return guildName .. "|" .. (guildRealm or ns.MyRealm()) .. "|" .. faction
end

local CheckPartials -- (below, with the summaries)
local partialsChecked = {} -- [guild table] = true once checked this session

-- Saved records without a checksum (saved before the hash job finished, or
-- stored by code that doesn't hash): worked out in the background, once a
-- session. Our own characters' records are skipped (they change in place;
-- Comm.lua keeps our own checksum apart).
local function RehashMembers(g)
  local H, Enc = ns.Hash, ns.Encode
  if not H or H.broken then return end
  local chars = FableHubDB and FableHubDB.chars or {}
  for key, rec in pairs(g.members) do
    -- (a checksum that isn't one, e.g. saved data edited by hand: worked out again)
    if rec.hash ~= nil and not Enc.ValidH16(rec.hash) then rec.hash = nil end
    if not rec.hash and chars[key] ~= rec then
      H.Queue(ns.Encode.EncodeRecord(rec), function(h)
        -- (only if that record is still the one we hold)
        if g.members[key] == rec then rec.hash = h end
      end)
    end
  end
end

-- Owners' checksums from saved data that aren't "<ts36>:<16 hex>" are dropped
-- (the next hello, record or delta from the owner sets them again)
local function CheckOwners(g)
  local Enc = ns.Encode
  for key, v in pairs(g.owner) do
    local ts36, h
    if type(v) == "string" then ts36, h = v:match("^(%w+):(%w+)$") end
    if not ts36 or not Enc.Num(ts36, 4294967296) or not Enc.ValidH16(h) then g.owner[key] = nil end
  end
end

-- Returns the saved table for the current guild, or nil when not in a guild yet.
function ns.GuildDB()
  local gk = ns.GuildKey()
  if not gk then return nil end
  local g = FableHubDB.guilds[gk]
  if not g then
    g = { members = {}, addonUsers = {}, partials = {}, owner = {} }
    FableHubDB.guilds[gk] = g
  end
  g.partials = g.partials or {} -- (saved before 0.25)
  g.owner = g.owner or {}
  if not partialsChecked[g] then
    partialsChecked[g] = true
    CheckPartials(g)
    CheckOwners(g)
    RehashMembers(g)
  end
  g.lastSeen = time()
  return g
end

function ns.MyRecord()
  local key = ns.MyKey()
  if not key then return nil end
  local rec = FableHubDB.chars[key]
  if not rec then
    rec = { key = key, ts = 0, profs = {} }
    FableHubDB.chars[key] = rec
  end
  return rec
end

-- A partial record shows the recipes of the whole record `full` we hold
-- (older) until its own arrive: staleRecipes. The tables are shared, not
-- copied (SavedVariables may write them twice; harmless).
local function CarryRecipes(part, full)
  for skillLine, p in pairs(part.profs or {}) do
    local fp = full.profs and full.profs[skillLine]
    p.recipes = (fp and fp.recipes) or {}
  end
  part.outputs = full.outputs
  part.staleRecipes = true
end

-- Store a record received from someone else. Returns true if it was stored.
-- A copy of the version we already hold only replaces ours with
-- opts.replace (Comm.lua decides that from the owner's checksum: ours was a
-- wrong copy); an older one only with opts.force (the owner's own record,
-- which is the authority even when ours claims to be newer: see Comm.lua). Every client holds a version exactly
-- as its owner encoded it (see Encode.lua: canonical encoding), so there's
-- nothing to merge between copies.
function ns.StoreRecord(rec, opts)
  local g = ns.GuildDB()
  if not g or not rec or not rec.key then return false end
  local old = g.members[rec.key]
  local same = old and (old.ts or 0) == (rec.ts or 0)
  local older = old and (old.ts or 0) > (rec.ts or 0)
  if same and not (opts and opts.replace) then return false end
  if older and not (opts and opts.force) then return false end
  g.members[rec.key] = rec
  -- (Activity compares whole records only: never against a summary, nor a
  -- corrected copy of the same version, nor a copy that claimed to be newer)
  if old and not same and not older and ns.Activity then pcall(ns.Activity.Compare, rec.key, old, rec, rec.ts) end
  -- (the owner's record replacing one that claimed to be newer: summaries
  -- that came with that one go too)
  if older and g.partials then g.partials[rec.key] = nil end
  -- a summary waiting for this record is done; one of a still newer version
  -- shows this record's recipes until its own arrive
  local part = g.partials and g.partials[rec.key]
  if part then
    if (part.ts or 0) <= (rec.ts or 0) then g.partials[rec.key] = nil
    else CarryRecipes(part, rec) end
  end
  ns.Fire("DATA_CHANGED")
  return true
end

------------------------------------------------------------------------
-- Summaries (0.25+): at catch-up a relay sends the light part of each record
-- first (everything but the recipes and crafted items; see Comm.lua "E"), so
-- the roster, classes, levels, cooldowns and time played fill in long before
-- every recipe list has arrived. Until the whole record comes, a summary is
-- kept in g.partials, never in g.members:
--   g.partials[key] = the summary record, partial = true, and when we hold an
--     older whole record, its recipes (staleRecipes = true)
-- It's only kept while it's newer than our whole copy (StoreRecord drops it
-- when the record arrives). Our own record is never partial.
------------------------------------------------------------------------
local MAX_PARTIALS = 1000

-- once a session: drop summaries no newer than the whole record (an older
-- FableHub run meanwhile updated members but not partials), and share the
-- whole record's recipe tables again (saved data stores them as copies)
function CheckPartials(g)
  for key, part in pairs(g.partials) do
    local m = g.members[key]
    if m and (m.ts or 0) >= (part.ts or 0) then g.partials[key] = nil
    elseif m and part.staleRecipes then CarryRecipes(part, m) end
  end
end

-- Is a summary newer than anything we hold of that character? (Only then is
-- it of use: a summary of a version we hold whole, or hold as a summary
-- already, brings nothing, as every copy of a version is the same.)
local function SummaryNew(g, rec)
  local m, p = g.members[rec.key], g.partials[rec.key]
  return (rec.ts or 0) > math.max(m and (m.ts or 0) or -1, p and (p.ts or 0) or -1)
end

-- would this summary change anything we hold? (roster members only, and
-- never our own character)
function ns.SummaryUseful(rec)
  local g = ns.GuildDB()
  if not g or not rec or not rec.key or rec.key == ns.MyKey() then return false end
  if not ns.roster[rec.key] then return false end
  return SummaryNew(g, rec)
end

-- Store a batch of decoded summaries; DATA_CHANGED fires once. Returns how
-- many changed something. (g, the guild table, may be left out:
-- ns.StoreSummaries(list))
function ns.StoreSummaries(g, list)
  if list == nil then g, list = nil, g end
  g = g or ns.GuildDB()
  if not g or type(list) ~= "table" or not next(ns.roster) then return 0 end
  local me = ns.MyKey()
  local count = 0
  for _ in pairs(g.partials) do count = count + 1 end
  local changed = 0
  for _, rec in ipairs(list) do
    local key = rec.key
    if key and key ~= me and ns.roster[key] and SummaryNew(g, rec) then
      if g.partials[key] or count < MAX_PARTIALS then
        if not g.partials[key] then count = count + 1 end
        rec.partial = true
        rec.outputs = nil
        for _, p in pairs(rec.profs or {}) do p.recipes = {} end
        local m = g.members[key]
        if m then CarryRecipes(rec, m) end
        g.partials[key] = rec
        changed = changed + 1
      end
    end
  end
  if changed > 0 then ns.Fire("DATA_CHANGED") end
  return changed
end

-- What the UI shows for a character: the newest we have, a summary while its
-- record is on the way (`g`: the guild table, when the caller has it)
function ns.MemberRecord(key, g)
  g = g or ns.GuildDB()
  if not g or not key then return nil end
  return (g.partials and g.partials[key]) or g.members[key]
end

-- catch-up progress for the UI: partial = characters whose recipes haven't
-- arrived yet, total = characters we hold anything for (roster members once
-- the roster has loaded), active = a catch-up is being answered right now
function ns.SyncProgress()
  local g = ns.GuildDB()
  local out = { partial = 0, total = 0, active = ns.CatchUpActive and ns.CatchUpActive() or false }
  if not g then return out end
  local haveRoster = next(ns.roster) ~= nil
  for key in pairs(g.members) do
    if not haveRoster or ns.roster[key] then out.total = out.total + 1 end
  end
  for key in pairs(g.partials or {}) do
    if not haveRoster or ns.roster[key] then
      out.partial = out.partial + 1
      if not g.members[key] then out.total = out.total + 1 end
    end
  end
  return out
end

-- Our own record lives in db.chars and is mirrored into the guild table.
function ns.MirrorMyRecord()
  local g = ns.GuildDB()
  local rec = ns.MyRecord()
  if g and rec then
    g.members[rec.key] = rec
    if g.partials then g.partials[rec.key] = nil end
  end
end

------------------------------------------------------------------------
-- Guild roster cache (everyone in the guild, addon or not)
------------------------------------------------------------------------
ns.roster = {}      -- [key] = { name, rank, rankIndex, level, class, online, zone, note }
ns.rosterOrder = {}

function ns.RequestRoster()
  if C_GuildInfo and C_GuildInfo.GuildRoster then
    C_GuildInfo.GuildRoster()
  elseif GuildRoster then
    GuildRoster()
  end
end

local function RebuildRoster()
  local roster, order = {}, {}
  local n = GetNumGuildMembers() or 0
  local myGuid = UnitGUID and UnitGUID("player")
  for i = 1, n do
    local name, rankName, rankIndex, level, _, zone, note, _, online, _, classFile,
      _, _, _, _, _, guid = GetGuildRosterInfo(i)
    local key = ns.NormalizeName(name)
    if key and guid and myGuid and guid == myGuid then ns.SetMyKey(key) end
    if key then
      local lastSeen
      if not online and GetGuildRosterLastOnline then
        local y, mo, d, h = GetGuildRosterLastOnline(i)
        if y then lastSeen = ns.Now() - ((((y * 12 + (mo or 0)) * 30 + (d or 0)) * 24 + (h or 0)) * 3600) end
      end
      roster[key] = {
        key = key, rank = rankName, rankIndex = rankIndex, level = level,
        class = classFile, online = online and true or false, zone = zone, note = note, lastSeen = lastSeen,
        guid = guid,
      }
      order[#order + 1] = key
    end
  end
  if n > 0 or not IsInGuild() then
    ns.roster, ns.rosterOrder = roster, order
  end
  ns.Fire("ROSTER_CHANGED")
end

function ns.IsOnline(key)
  if key == ns.MyKey() then return true end
  local r = ns.roster[key]
  return r and r.online or false
end

------------------------------------------------------------------------
-- On/off options (Settings page). Unset means the default.
------------------------------------------------------------------------
ns.OPTION_DEFAULTS = {
  alertRaid = true,          -- chat reminder for raid nights you haven't signed up for
  alertNewRequest = true,    -- chat message when someone requests something you can craft
  alertRequestLogin = true,  -- login reminder of open requests you can craft
  alertMyRequest = true,     -- chat message when your request is claimed or done
  minimapBadge = true,       -- request count on the minimap button
  socialTab = true,          -- a FableHub tab on the game's Social window
  homeFirst = true,          -- open on Home first each session
  readyCheckAuto = true,     -- run the ready check page's check on every ready check
  lootAnnounce = true,       -- officers: announce awarded loot in raid chat
  awardWindow = true,        -- officers: open the award window when we're the master looter
  lootTooltip = true,        -- prio list, wishlist and who has it in item tooltips
  rollPopup = true,          -- a popup with roll buttons when an officer starts a roll
  alertBankRequest = true,   -- officers: chat message when someone requests a guild bank item
  homeTips = true,           -- "Getting started" card on Home while there's setup left to do
  sharePlayed = false,       -- share your /played time with the guild (Settings > Privacy)
}
function ns.Option(key)
  local s = FableHubDB and FableHubDB.settings
  local v = s and s[key]
  if v == nil then return ns.OPTION_DEFAULTS[key] end
  return v
end
function ns.SetOption(key, v)
  FableHubDB.settings[key] = v and true or false
  ns.Fire("OPTIONS_CHANGED", key)
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------
local frame = CreateFrame("Frame")
ns.eventFrame = frame
local handlers = {}
ns.handlers = handlers

function ns.RegisterEvent(event, fn)
  if not handlers[event] then
    -- skip events this client doesn't have (Forever runs the modern client,
    -- which dropped some classic-era events)
    if C_EventUtils and C_EventUtils.IsEventValid and not C_EventUtils.IsEventValid(event) then
      ns.Debug("event not on this client: " .. event)
      return
    end
    local ok = pcall(frame.RegisterEvent, frame, event)
    if not ok then
      ns.Debug("event not on this client: " .. event)
      return
    end
    handlers[event] = {}
  end
  table.insert(handlers[event], fn)
end

frame:SetScript("OnEvent", function(_, event, ...)
  local list = handlers[event]
  if not list then return end
  for _, fn in ipairs(list) do
    local ok, err = pcall(fn, ...)
    if not ok then ns.ReportError(event .. ": " .. tostring(err)) end
  end
end)

ns.RegisterEvent("ADDON_LOADED", function(name)
  if name ~= ADDON then return end
  InitDB()
end)

local rosterPending = false
ns.RegisterEvent("GUILD_ROSTER_UPDATE", function()
  -- the event can fire in bursts; rebuild at most twice a second
  if rosterPending then return end
  rosterPending = true
  C_Timer.After(0.5, function()
    rosterPending = false
    RebuildRoster()
  end)
end)

ns.RegisterEvent("PLAYER_GUILD_UPDATE", function()
  ns._keyRealm = nil -- joined or left a guild
  ns.MirrorMyRecord()
  ns.RequestRoster()
end)

ns.RegisterEvent("PLAYER_LOGIN", function()
  if ns.freshStart then
    ns.freshStart = nil
    C_Timer.After(8, function()
      ns.Print("Fresh start: guild data saved before this version was cleared. It refills as guildmates log in.")
    end)
  end
  ns.RequestRoster()
  -- refresh the roster every 60s so online status stays current
  C_Timer.NewTicker(60, function() if IsInGuild() then ns.RequestRoster() end end)
  -- global handle for /dump FableHub, on a developer account only
  if ns.IsDeveloper() then FableHub = ns end
  ns.Fire("LOGIN")
end)

------------------------------------------------------------------------
-- Slash command
------------------------------------------------------------------------
SLASH_FABLEHUB1 = "/fhub"
SLASH_FABLEHUB2 = "/fablehub"
ns.SlashHandlers = {} -- extra /fhub commands from other files: [word] = function(rest)
SlashCmdList.FABLEHUB = function(msg)
  msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  local word, rest = msg:match("^(%S+)%s*(.*)$")
  if word and ns.SlashHandlers[word] then return ns.SlashHandlers[word](rest or "") end
  if msg == "" or msg == "show" then
    if ns.ToggleUI then ns.ToggleUI() end
  elseif msg == "sync" then
    if ns.ForceSync then ns.ForceSync() end
  elseif msg == "scan" then
    if ns.ScanAll then ns.ScanAll(true) end
    ns.Print("Rescanned your character.")
  elseif msg:match("^opacity") then
    local n = tonumber(msg:match("(%d+)"))
    if not n or n < 50 or n > 100 then
      ns.Print("Usage: /fhub opacity 50-100 (currently " .. math.floor((ns.UI and ns.UI.Opacity() or 0.85) * 100 + 0.5) .. ")")
    else
      FableHubDB.settings.opacity = n / 100
      if ns.UI and ns.UI.ApplyOpacity then ns.UI.ApplyOpacity() end
      ns.Print(("Window opacity set to %d%%."):format(n))
    end
  elseif msg == "testofficer" and ns.IsDeveloper() then
    FableHubDB.settings.testOfficer = not FableHubDB.settings.testOfficer
    ns.Print(FableHubDB.settings.testOfficer
      and "Test officer mode ON. FableHub treats you as an officer on this computer only. Type /fhub testofficer again to turn it off."
      or "Test officer mode OFF.")
    ns.Fire("PLANS_CHANGED")
  elseif msg == "minimap" then
    if ns.ToggleMinimapButton then ns.ToggleMinimapButton() end
  elseif msg == "resetwindow" then
    if ns.ResetWindow then ns.ResetWindow() end
    ns.Print("Window size and position reset.")
  elseif msg == "debug" and ns.IsDeveloper() then
    FableHubDB.settings.debug = not FableHubDB.settings.debug
    ns.Print("Debug " .. (FableHubDB.settings.debug and "on" or "off"))
  elseif msg == "status" then
    if ns.PrintStatus then ns.PrintStatus() end
  elseif msg == "reset" then
    local gk = ns.GuildKey()
    if gk then FableHubDB.guilds[gk] = nil end
    ns.MirrorMyRecord()
    ns.Fire("DATA_CHANGED")
    ns.Print("Cleared stored guild data. It will refill as guildmates log in.")
  else
    ns.Print("/fhub - open window | /fhub sync - resync with guild | /fhub scan - rescan your character | /fhub minimap - show or hide the minimap button | /fhub resetwindow | /fhub opacity 50-100 | /fhub status | /fhub bug - report to copy | /fhub ping Name - test whispers | /fhub reset")
  end
end
