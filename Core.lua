-- FableHub: guild roster + profession tracker for WoW: Forever
-- Core: namespace, saved data, events, shared helpers.

local ADDON, ns = ...
ns.VERSION = "0.17.0"
ns.PROTOCOL = 1

FableHub = ns -- global handle, handy for /dump FableHub while testing

------------------------------------------------------------------------
-- Small callback bus so the UI can react to data changes
------------------------------------------------------------------------
-- Errors inside FableHub are caught so one broken feature can't stop the rest,
-- but each distinct error is passed once to the game's error handler, so it
-- shows up in BugSack / "Display Lua errors" and can be reported.
local reported = {}
function ns.ReportError(err)
  err = tostring(err)
  ns.Debug("error: " .. err)
  if reported[err] then return end
  reported[err] = true
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
function ns.Debug(msg)
  if FableHubDB and FableHubDB.settings and FableHubDB.settings.debug then
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

function ns.NormalizeName(name)
  if not name or name == "" then return nil end
  if name:find("-", 1, true) then return name end
  local realm = ns.MyRealm()
  if realm == "" then return name end
  return name .. "-" .. realm
end

-- Our own key. The guild roster is the source of truth (Forever adds last
-- names, which UnitFullName reports differently), so once the roster loads we
-- match ourselves by GUID and adopt the roster's spelling of our name.
function ns.MyKey()
  if ns._myKey then return ns._myKey end
  local name, realm = UnitFullName("player")
  if not name then return nil end
  if not realm or realm == "" then realm = ns.MyRealm() end
  ns._myKey = (realm ~= "" and (name .. "-" .. realm)) or name
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
    rec.ts = ns.Now()
  end
  for _, g in pairs(FableHubDB.guilds) do
    if oldKey then g.members[oldKey] = nil; g.addonUsers[oldKey] = nil end
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

function ns.Now()
  return (GetServerTime and GetServerTime()) or time()
end

------------------------------------------------------------------------
-- Saved data
--   FableHubDB.guilds[guildKey].members[charKey] = record
--   record = { key, ts, class, level, profs = { [skillLine] = { name, rank, max, recipes = {[id]=true} } } }
------------------------------------------------------------------------
local DB_VERSION = 1

local function InitDB()
  FableHubDB = FableHubDB or {}
  local db = FableHubDB
  db.dbVersion = db.dbVersion or DB_VERSION
  db.guilds = db.guilds or {}
  db.settings = db.settings or {}
  db.chars = db.chars or {} -- your own characters' records, kept even if you change guild
end

function ns.GuildKey()
  if not IsInGuild() then return nil end
  local guildName, _, _, guildRealm = GetGuildInfo("player")
  if not guildName then return nil end
  local faction = UnitFactionGroup("player") or ""
  return guildName .. "|" .. (guildRealm or ns.MyRealm()) .. "|" .. faction
end

-- Returns the saved table for the current guild, or nil when not in a guild yet.
function ns.GuildDB()
  local gk = ns.GuildKey()
  if not gk then return nil end
  local g = FableHubDB.guilds[gk]
  if not g then
    g = { members = {}, addonUsers = {} }
    FableHubDB.guilds[gk] = g
  end
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

-- Store a record received from someone else. Returns true if it was newer.
function ns.StoreRecord(rec)
  local g = ns.GuildDB()
  if not g or not rec or not rec.key then return false end
  local old = g.members[rec.key]
  if old and (old.ts or 0) >= (rec.ts or 0) then return false end
  g.members[rec.key] = rec
  if old and ns.Activity then pcall(ns.Activity.Compare, rec.key, old, rec, rec.ts) end
  ns.Fire("DATA_CHANGED")
  return true
end

-- Our own record lives in db.chars and is mirrored into the guild table.
function ns.MirrorMyRecord()
  local g = ns.GuildDB()
  local rec = ns.MyRecord()
  if g and rec then g.members[rec.key] = rec end
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
  homeFirst = true,          -- open on Home first each session
  readyCheckAuto = true,     -- run the ready check page's check on every ready check
  lootAnnounce = true,       -- officers: announce awarded loot in raid chat
  alertBankRequest = true,   -- officers: chat message when someone requests a guild bank item
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
  ns.MirrorMyRecord()
  ns.RequestRoster()
end)

ns.RegisterEvent("PLAYER_LOGIN", function()
  ns.RequestRoster()
  -- refresh the roster every 60s so online status stays current
  C_Timer.NewTicker(60, function() if IsInGuild() then ns.RequestRoster() end end)
  ns.Fire("LOGIN")
end)

------------------------------------------------------------------------
-- Slash command
------------------------------------------------------------------------
SLASH_FABLEHUB1 = "/fhub"
SLASH_FABLEHUB2 = "/fablehub"
SlashCmdList.FABLEHUB = function(msg)
  msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
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
  elseif msg == "testofficer" then
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
  elseif msg == "debug" then
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
    ns.Print("/fhub - open window | /fhub sync - resync with guild | /fhub scan - rescan your character | /fhub minimap - show or hide the minimap button | /fhub resetwindow | /fhub opacity 50-100 | /fhub testofficer | /fhub status | /fhub reset | /fhub debug")
  end
end
