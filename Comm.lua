-- Comm: guild-channel sync between FableHub users.
--
-- Every message is wrapped as  "<type>#<id>#<part>#<total>#<payload>"
-- so long payloads can be split across several 255-byte addon messages.
--
-- Types
--   H  hello      sent at login:            "<protocol>^<version>^<my record ts>"
--   R  here       reply to a hello:         same payload as H
--   W  want       ask the owner to rebroadcast their record: "<key>"
--   F  full       one character record (see Encode.lua)
--   D  digest     "what I already have" list, so one online member can fill gaps
--
-- Only each character's owner changes their own record. Other users relay
-- copies so data reaches people who were offline at the time.

local _, ns = ...
local Enc = ns.Encode

-- The channel name follows ns.DATA_EPOCH (Core.lua). Bumping the epoch for the
-- launch build gives a fresh start: older clients talk on the old channel, so
-- their (beta) data can't reach the new one. Hellos still go out on the old
-- channel too, so older clients see that a newer FableHub exists.
local LEGACY_PREFIX = "FableHub"
local PREFIX = (ns.DATA_EPOCH or 1) > 1 and ("FableHub" .. ns.DATA_EPOCH) or LEGACY_PREFIX
ns.PREFIX = PREFIX
local MAX_MSG = 250
local HEADER_ROOM = 16
local CHUNK = MAX_MSG - HEADER_ROOM

ns.present = {}          -- [key] = version, FableHub users heard from this session
local sendQueue = {}
local buffers = {}       -- partial multi-part messages
local nextId = math.random(0, 1295)
local started = false
local guildEcho, firstGuildSend = false, nil -- guild channel check (see WhisperPeers)

------------------------------------------------------------------------
-- Sending (token bucket throttle: Blizzard allows ~10 burst then ~1/sec)
------------------------------------------------------------------------
local tokens, MAX_TOKENS, REGEN = 6, 6, 1.0
local lastRegen = 0

local function Paused()
  if InCombatLockdown and InCombatLockdown() then return true end
  if IsEncounterInProgress and IsEncounterInProgress() then return true end
  return false
end

local function SendRaw(msg, target, prefix)
  local ok, res
  if target then
    ok, res = pcall(C_ChatInfo.SendAddonMessage, prefix or PREFIX, msg, "WHISPER", target)
  else
    ok, res = pcall(C_ChatInfo.SendAddonMessage, prefix or PREFIX, msg, "GUILD")
  end
  if ns.Diag then ns.Diag.NoteSend(ok, res, target) end
  if not ok then
    ns.Debug("send error: " .. tostring(res))
    return "drop"
  end
  if res == nil or res == true or res == 0 then return "ok" end
  if res == false then return "retry" end
  local E = Enum and Enum.SendAddonMessageResult
  if E and (res == E.AddonMessageThrottle or res == E.ChannelThrottle or res == E.GeneralError) then
    return "retry"
  end
  ns.Debug("send refused, code " .. tostring(res))
  return "drop"
end

local function Pump()
  if #sendQueue == 0 or not IsInGuild() or Paused() then return end
  local now = GetTime()
  tokens = math.min(MAX_TOKENS, tokens + (now - lastRegen) * REGEN)
  lastRegen = now
  while tokens >= 1 and #sendQueue > 0 do
    local item = sendQueue[1]
    local to = item.form or (item.target and ns.WhisperTarget(item.target))
    if to then ns.NoteWhisper(to, item.target) end
    local result = SendRaw(item.msg, to, item.prefix)
    if not to and result == "ok" and not firstGuildSend then
      firstGuildSend = GetTime()
      C_Timer.After(20, function() ns.CheckGuildEcho() end)
    end
    if result == "retry" then
      item.tries = (item.tries or 0) + 1
      if item.tries > 10 then table.remove(sendQueue, 1) end
      tokens = 0
      return
    end
    table.remove(sendQueue, 1)
    tokens = tokens - 1
  end
end

local function NewId()
  nextId = (nextId + 1) % 46656 -- 3 base36 digits
  return Enc.ToB36(nextId)
end

local Queue
-- Guild channel check. The game echoes our own guild addon messages back to us.
-- On Forever, characters on a connected realm (not the guild's home realm) get
-- no echo and nobody hears them, though whispers still work. If nothing comes
-- back within 20 s of our first guild send, FableHub sends by whisper instead:
-- hellos to every online member (so FableHub users learn about us), everything
-- else to the FableHub users we've heard from.
ns.guildMuted = false
local function WhisperPeers(everyone)
  local list = {}
  local me = ns.MyKey()
  if everyone then
    for key, r in pairs(ns.roster) do if r.online and key ~= me then list[#list + 1] = key end end
  else
    for key in pairs(ns.present) do if key ~= me and ns.IsOnline(key) then list[#list + 1] = key end end
  end
  table.sort(list)
  return list
end
ns.WhisperPeers = WhisperPeers

function Queue(msgType, payload, target, prefix, form)
  payload = payload or ""
  if not target and ns.guildMuted and not prefix then
    for _, key in ipairs(WhisperPeers(msgType == "H")) do Queue(msgType, payload, key) end
    return
  end
  local id = NewId()
  local total = math.max(1, math.ceil(#payload / CHUNK))
  for i = 1, total do
    local part = payload:sub((i - 1) * CHUNK + 1, i * CHUNK)
    table.insert(sendQueue, { msg = table.concat({ msgType, id, i, total, part }, "#"), target = target, prefix = prefix,
                              form = form })
  end
end

-- to the whole guild
function ns.Send(msgType, payload) Queue(msgType, payload, nil) end

-- to one member only (addon whisper): for data not everyone may see
function ns.SendTo(target, msgType, payload)
  if target and target ~= ns.MyKey() then Queue(msgType, payload, target) end
end

-- to one member using a given spelling of their name (for /fhub ping)
function ns.SendToForm(target, form, msgType, payload)
  if target and form and target ~= ns.MyKey() then Queue(msgType, payload, target, nil, form) end
end

------------------------------------------------------------------------
-- Whisper names. Forever's guild roster spells names with last names, and the
-- name the game accepts for a whisper may be spelled differently. Candidates
-- are tried in order: one that gets "No player named ..." is skipped from then
-- on (and that error line is hidden), and one known to work is remembered in
-- saved data (g.whisperNames).
------------------------------------------------------------------------
local badForm = {}       -- [key] = { [form] = true } (this session)
local recentWhisper = {} -- [form] = { key = key, t = GetTime() }

function ns.WhisperCandidates(key)
  local list, seen = {}, {}
  local function add(n)
    if n and n ~= "" and not seen[n] then seen[n] = true; list[#list + 1] = n end
  end
  local g = ns.GuildDB and ns.GuildDB()
  add(g and g.whisperNames and g.whisperNames[key])
  -- "First Lastname" with no realm: what works in Forever (confirmed in game;
  -- "Name Lastname-Realm" is refused, even on connected realms)
  local realm = key:match("%-(.+)$")
  local short = ns.ShortName(key)
  add(short)
  if Ambiguate then add(Ambiguate(key, "none")) end
  add(key)
  local r = ns.roster[key]
  if r and r.guid and GetPlayerInfoByGUID then
    -- the game's own name for the character (may differ from the roster's)
    local ok, _, _, _, _, _, gname, grealm = pcall(GetPlayerInfoByGUID, r.guid)
    if ok and type(gname) == "string" and gname ~= "" then
      if type(grealm) == "string" and grealm ~= "" then add(gname .. "-" .. grealm:gsub("[%s%-]", "")) end
      add(gname .. (realm and ("-" .. realm) or ""))
      add(gname)
    end
  end
  add(short)
  local first = short:match("^(%S+)%s")
  if first then
    add(first .. (realm and ("-" .. realm) or ""))
    add(first)
  end
  return list
end

function ns.WhisperTarget(key)
  local bad = badForm[key] or {}
  for _, form in ipairs(ns.WhisperCandidates(key)) do
    if not bad[form] then return form end
  end
  return key
end

-- a spelling that reached them: use it from now on
function ns.WhisperWorked(key, form)
  local g = ns.GuildDB and ns.GuildDB()
  if not g or not key or not form then return end
  g.whisperNames = g.whisperNames or {}
  g.whisperNames[key] = (form ~= key) and form or nil
  if badForm[key] then badForm[key][form] = nil end
end

function ns.NoteWhisper(form, key)
  recentWhisper[form] = { key = key, t = GetTime() }
end

-- "No player named '%s' is currently playing." as a pattern (any language)
local notFoundPattern
local function NotFoundName(msg)
  if type(msg) ~= "string" then return nil end
  if not notFoundPattern then
    local fmt = ERR_CHAT_PLAYER_NOT_FOUND_S or "No player named '%s' is currently playing."
    notFoundPattern = "^" .. fmt:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%%%s", "(.+)") .. "$"
  end
  return msg:match(notFoundPattern)
end
local function OurFailedWhisper(msg)
  local name = NotFoundName(msg)
  local w = name and recentWhisper[name]
  if w and GetTime() - w.t < 5 then return name, w end
end

ns.RegisterEvent("CHAT_MSG_SYSTEM", function(msg)
  local form, w = OurFailedWhisper(msg)
  if not form or not w.key then return end
  badForm[w.key] = badForm[w.key] or {}
  badForm[w.key][form] = true
  local g = ns.GuildDB and ns.GuildDB()
  if g and g.whisperNames and g.whisperNames[w.key] == form then g.whisperNames[w.key] = nil end
  ns.Debug(("whisper name \"%s\" not found; next time: \"%s\""):format(form, ns.WhisperTarget(w.key)))
  ns.Fire("WHISPER_FAILED", w.key, form)
end)

-- hide those error lines for FableHub's own (invisible) addon whispers
if ChatFrame_AddMessageEventFilter then
  ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", function(_, _, msg)
    if OurFailedWhisper(msg) then return true end
  end)
end

function ns.QueueLength() return #sendQueue end

------------------------------------------------------------------------
-- Higher level messages
------------------------------------------------------------------------
local HelloPayload
-- after a fresh start (new channel), also say hello on the old channel so
-- members still on an older FableHub are told to update
local function LegacyHello()
  if PREFIX ~= LEGACY_PREFIX then Queue("H", HelloPayload(), nil, LEGACY_PREFIX) end
end

function HelloPayload()
  local rec = ns.MyRecord()
  return table.concat({ ns.PROTOCOL, ns.VERSION, Enc.ToB36(rec and rec.ts or 0), ns.MyKey() or "" }, "^")
end

function ns.BroadcastRecord(rec)
  if rec then ns.Send("F", Enc.EncodeRecord(rec)) end
end

-- Debounced broadcast of our own record after it changes.
local ownPending = false
function ns.QueueOwnBroadcast(delay)
  if not started then return end
  if ownPending then return end
  ownPending = true
  C_Timer.After(delay or 8, function()
    ownPending = false
    ns.BroadcastRecord(ns.MyRecord())
  end)
end

local function SendDigest()
  local g = ns.GuildDB()
  if not g then return end
  local others = {}
  for key, rec in pairs(g.members) do
    if key ~= ns.MyKey() then others[key] = rec end
  end
  ns.Send("D", Enc.EncodeDigest(others))
end

-- One online member answers each digest so the guild isn't flooded:
-- the alphabetically first FableHub user who is online, not counting the asker.
ns.CommHandlers = {}   -- extra message types registered by other modules

-- the member on the newest FableHub answers (older versions can't relay newer
-- kinds of data); ties go to the alphabetically first name
local function VersionNumber(v)
  local a, b, c = tostring(v or ""):match("^(%d+)%.(%d+)%.?(%d*)")
  return (tonumber(a) or 0) * 1000000 + (tonumber(b) or 0) * 1000 + (tonumber(c) or 0)
end
ns.VersionNumber = VersionNumber

local function AmRelayFor(requester)
  local me = ns.MyKey()
  local best, bestV = me, VersionNumber(ns.VERSION)
  for key, ver in pairs(ns.present) do
    if key ~= requester and key ~= me and ns.IsOnline(key) then
      local v = VersionNumber(ver)
      if v > bestV or (v == bestV and key < best) then best, bestV = key, v end
    end
  end
  return best == me
end
ns.AmRelayFor = AmRelayFor

------------------------------------------------------------------------
-- Trust checks
------------------------------------------------------------------------
-- Who really sent a message, as a guild roster key. The chat system may
-- spell names without Forever's last names, so an exact match is tried first,
-- then a unique first-name match on the same realm. nil = not in the guild.
local resolved = {}
ns.On("ROSTER_CHANGED", function() resolved = {} end)
local function FirstName(key)
  local n = key:match("^([^-]+)") or key
  return (n:match("^(%S+)") or n):lower()
end
local function RealmOf(key) return key:match("%-(.+)$") end
function ns.ResolveSender(sender)
  if not sender then return nil end
  if ns.roster[sender] then return sender end
  local hit = resolved[sender]
  if hit ~= nil then return hit or nil end
  -- the same "First Lastname" on any realm (guilds can span connected realms, and
  -- names may arrive without a realm, which NormalizeName fills with ours)
  local full = (sender:match("^([^-]+)") or sender):lower()
  local found
  for key in pairs(ns.roster) do
    if (key:match("^([^-]+)") or key):lower() == full then
      if found then found = false break end -- two people share that name: can't tell
      found = key
    end
  end
  if found == nil then
    -- only a first name: a unique first-name match on the same realm
    local first, realm = FirstName(sender), RealmOf(sender)
    for key in pairs(ns.roster) do
      local r = RealmOf(key)
      if FirstName(key) == first and (not realm or not r or r == realm) then
        if found then found = false break end
        found = key
      end
    end
  end
  resolved[sender] = found or false
  return found or nil
end

-- officer-only data: the author must be an officer, and it must come from that
-- officer or be passed on by another officer (members can't pass it on)
function ns.OfficerSent(sender, author)
  local P = ns.Plans
  if not author or author == "" or not P.IsOfficer(author) then return false end
  return sender == author or P.IsOfficer(sender)
end

-- a change made by `actor` that arrived from `sender`: did it come first-hand
-- (or from an officer)? Second-hand copies from members only fill gaps.
function ns.FirstHand(sender, actor)
  return sender == actor or ns.Plans.IsOfficer(sender)
end

-- timestamps more than 5 minutes ahead of the server clock are refused, so a
-- forged "newest" change can't lock data forever
function ns.TimeOK(ts)
  return type(ts) == "number" and ts <= ns.Now() + 300
end

-- the online officer (by real guild rank, not test mode) who answers catch-up
-- requests for officer-only data: newest FableHub version, then alphabetical
local function RealOfficer(key)
  local P = ns.Plans
  local idx = P.RankIndex(key)
  return idx ~= nil and idx <= P.OfficerRank()
end
ns.RealOfficer = RealOfficer
function ns.AmOfficerRelayFor(requester)
  local me = ns.MyKey()
  if not RealOfficer(me) then return false end
  local best, bestV = me, VersionNumber(ns.VERSION)
  for key, ver in pairs(ns.present) do
    if key ~= requester and key ~= me and ns.IsOnline(key) and RealOfficer(key) then
      local v = VersionNumber(ver)
      if v > bestV or (v == bestV and key < best) then best, bestV = key, v end
    end
  end
  return best == me
end

-- catch-up digests other modules send at startup and on /fhub sync
local digests = {}
function ns.RegisterDigest(fn) digests[#digests + 1] = fn end

------------------------------------------------------------------------
-- Receiving
------------------------------------------------------------------------
local wantedRecently = {}   -- [key] = GetTime() when we decided to ask for it
local wantSeen = {}         -- [key] = GetTime() when someone else asked for it
local answeredWant = 0

-- Newer FableHub versions seen in the guild. Told once per version, and only
-- when an officer or at least two members run it (so one player claiming a
-- made-up version can't nag everyone).
local newerSeen, toldNewer = {}, {}
local function NoteVersion(key, ver)
  if not key or not ver or not ver:match("^%d+%.%d+") then return end
  if VersionNumber(ver) <= VersionNumber(ns.VERSION) then return end
  newerSeen[ver] = newerSeen[ver] or {}
  newerSeen[ver][key] = true
  local n, officer = 0, false
  for k in pairs(newerSeen[ver]) do
    n = n + 1
    if ns.RealOfficer(k) then officer = true end
  end
  if not officer and n < 2 then return end
  if not ns.updateAvailable or VersionNumber(ver) > VersionNumber(ns.updateAvailable) then
    ns.updateAvailable = ver
    ns.Fire("UPDATE_AVAILABLE", ver)
  end
  if not toldNewer[ver] then
    toldNewer[ver] = true
    ns.Print(("A newer FableHub is out: %s (you have %s). Ask your officers or the guild Discord for the update.")
      :format(ver, ns.VERSION))
  end
end
ns.NoteVersion = NoteVersion

local function HandleHello(sender, payload, isReply)
  local f = Enc.Split(payload, "^")
  local proto = tonumber(f[1]) or 0
  -- prefer the sender's own idea of their key (matches their records), but
  -- only when we couldn't match them to the roster ourselves
  if f[4] and f[4] ~= "" and not ns.roster[sender] then sender = f[4] end
  ns.present[sender] = f[2] or "?"
  NoteVersion(sender, f[2])
  local g = ns.GuildDB()
  if g then
    g.addonUsers[sender] = { version = f[2], seen = ns.Now() }
  end
  if proto ~= ns.PROTOCOL then return end

  -- do we need their record?
  local theirTs = Enc.FromB36(f[3])
  local have = g and g.members[sender]
  if theirTs > 0 and (not have or (have.ts or 0) < theirTs) then
    local t = wantedRecently[sender]
    if not t or GetTime() - t > 30 then
      local scheduled = GetTime()
      wantedRecently[sender] = scheduled
      -- small random delay so several people don't all ask at once
      C_Timer.After(1 + math.random() * 3, function()
        if (wantSeen[sender] or 0) >= scheduled then return end -- someone else already asked
        ns.Send("W", sender)
      end)
    end
  end

  if not isReply then
    C_Timer.After(1 + math.random() * 4, function() ns.Send("R", HelloPayload()) end)
  end
  ns.Fire("DATA_CHANGED")
end

local function HandleWant(sender, key)
  wantSeen[key] = GetTime()
  wantedRecently[key] = GetTime()
  if key == ns.MyKey() then
    if GetTime() - answeredWant > 10 then
      answeredWant = GetTime()
      ns.BroadcastRecord(ns.MyRecord())
    end
  end
end

local function HandleDigest(sender, payload)
  if not AmRelayFor(sender) then return end
  local g = ns.GuildDB()
  if not g then return end
  local theirs = Enc.DecodeDigest(payload)
  local sent = 0
  for key, rec in pairs(g.members) do
    -- skip the asker's own record and our own (we answer that via H/W)
    if key ~= sender and key ~= ns.MyKey() and (theirs[key] or 0) < (rec.ts or 0) then
      if ns.roster[key] or not next(ns.roster) then -- don't relay people who left the guild
        ns.BroadcastRecord(rec)
        sent = sent + 1
      end
    end
  end
  ns.Debug(("relayed %d records to %s"):format(sent, sender))
end

local function HandleFull(sender, payload)
  local rec = Enc.DecodeRecord(payload)
  if not rec or rec.key == ns.MyKey() or not ns.TimeOK(rec.ts) then return end
  -- only guild members (stops made-up members piling up in everyone's saved data)
  if next(ns.roster) and not ns.roster[rec.key] then return end
  if ns.StoreRecord(rec) then
    ns.Debug("stored " .. rec.key .. " (from " .. sender .. ")")
  end
end

local function Dispatch(sender, msgType, payload)
  if msgType == "H" then HandleHello(sender, payload, false)
  elseif msgType == "R" then HandleHello(sender, payload, true)
  elseif msgType == "W" then HandleWant(sender, payload)
  elseif msgType == "D" then HandleDigest(sender, payload)
  elseif msgType == "F" then HandleFull(sender, payload)
  elseif ns.CommHandlers[msgType] then ns.CommHandlers[msgType](sender, payload)
  end
end

function ns.OnAddonMessage(prefix, text, channel, sender)
  if channel ~= "GUILD" and channel ~= "WHISPER" then return end
  local legacy = PREFIX ~= LEGACY_PREFIX and prefix == LEGACY_PREFIX
  if prefix ~= PREFIX and not legacy then return end
  if issecretvalue and (issecretvalue(text) or issecretvalue(sender)) then return end
  if ns.Diag then ns.Diag.NoteRecv(sender, channel, prefix) end
  sender = ns.NormalizeName(sender)
  if not sender then return end
  -- whispers can come from anyone on the realm: only guild members count.
  -- (GUILD messages can only come from the guild.)
  local who = ns.ResolveSender(sender)
  if ns.Diag then ns.Diag.NoteSender(sender, who) end
  if legacy then
    -- older clients on the old channel: only note their version, use nothing else
    local t, payload = text:match("^([HR])#%w+#1#1#(.*)$")
    if t and channel == "GUILD" then
      local f = Enc.Split(payload, "^")
      local key = who or (f[4] ~= "" and f[4]) or sender
      if key ~= ns.MyKey() then ns.present[key] = ns.present[key] or f[2] end
    end
    return
  end
  if channel == "WHISPER" and not who then return end
  sender = who or sender
  if sender == ns.MyKey() then
    if channel == "GUILD" and not guildEcho then
      guildEcho = true
      if ns.guildMuted then
        ns.guildMuted = false
        ns.Debug("guild channel works again")
        ns.Fire("GUILD_CHANNEL", true)
      end
    end
    return
  end
  -- FableHub never sends WoW formatting codes ("|"), so strip any: no fake
  -- links, images or colours in names, notes or announcements
  if text:find("|", 1, true) then text = text:gsub("|", "") end

  local msgType, id, part, total, payload = text:match("^(%a)#(%w+)#(%d+)#(%d+)#(.*)$")
  if not msgType then return end
  part, total = tonumber(part), tonumber(total)
  if total == 1 then return Dispatch(sender, msgType, payload) end
  if total > 400 or part < 1 or part > total then return end

  local bkey = sender .. "#" .. channel .. "#" .. id
  local buf = buffers[bkey]
  if not buf then
    buf = { total = total, parts = {}, got = 0, t = GetTime(), msgType = msgType }
    buffers[bkey] = buf
  end
  if not buf.parts[part] then
    buf.parts[part] = payload
    buf.got = buf.got + 1
  end
  if buf.got == buf.total then
    buffers[bkey] = nil
    Dispatch(sender, buf.msgType, table.concat(buf.parts))
  end
end

------------------------------------------------------------------------
-- Startup
------------------------------------------------------------------------
-- one second apart so they don't all land at once
local function SendAllDigests()
  C_Timer.After(3, SendDigest)
  for i, fn in ipairs(digests) do
    C_Timer.After(3 + i, function()
      local ok, err = pcall(fn)
      if not ok then ns.ReportError(err) end
    end)
  end
end

local function Start()
  if started then return end
  started = true
  ns.ScanAll()
  ns.MirrorMyRecord()
  ns.Send("H", HelloPayload())
  LegacyHello()
  SendAllDigests()
end

function ns.CheckGuildEcho()
  if guildEcho or ns.guildMuted or not firstGuildSend then return end
  ns.guildMuted = true
  ns.Debug("no echo from the guild channel: sending by whisper")
  ns.Fire("GUILD_CHANNEL", false)
  -- what we sent so far reached nobody: forget which records we already asked
  -- for (those asks were lost), say hello again and resend our data
  for k in pairs(wantedRecently) do wantedRecently[k] = nil end
  ns.Send("H", HelloPayload())
  C_Timer.After(10, function()
    ns.BroadcastRecord(ns.MyRecord())
    SendAllDigests()
  end)
end
function ns.GuildChannelState()
  if guildEcho then return "ok" end
  if ns.guildMuted then return "muted" end
  return firstGuildSend and "checking" or "not used yet"
end

function ns.ForceSync()
  if not IsInGuild() then return ns.Print("You're not in a guild.") end
  if not started then Start() return end
  ns.Send("H", HelloPayload())
  LegacyHello()
  ns.BroadcastRecord(ns.MyRecord())
  SendAllDigests()
  ns.Print("Sync requested.")
end

function ns.PrintStatus()
  local g = ns.GuildDB()
  local stored, users, online = 0, 0, 0
  if g then
    for _ in pairs(g.members) do stored = stored + 1 end
    for _ in pairs(g.addonUsers) do users = users + 1 end
  end
  for key in pairs(ns.present) do if ns.IsOnline(key) then online = online + 1 end end
  ns.Print(("v%s | guild: %s | records: %d | FableHub users seen: %d (%d online now) | queued msgs: %d")
    :format(ns.VERSION, ns.GuildKey() or "none", stored, users, online, #sendQueue))
  local rec = ns.MyRecord()
  for _, p in pairs(rec and rec.profs or {}) do
    local n = ns.CountRecipes and ns.CountRecipes(p) or 0
    local withItem = 0
    for id in pairs(p.recipes or {}) do if rec.outputs and rec.outputs[id] then withItem = withItem + 1 end end
    ns.Print(("  %s %d/%d: %s"):format(p.name or "?", p.rank or 0, p.max or 0,
      n > 0 and (("%d recipes shared, %d with crafted item"):format(n, withItem))
        or "no recipes yet - open this profession's window once"))
  end
end

local function TryStart(attempt)
  attempt = attempt or 1
  if started then return end
  if ns.GuildKey() and ns.MyKey() and (ns._myKeyConfirmed or attempt >= 8) then
    C_Timer.After(5, Start) -- give the client a moment to finish loading
  elseif attempt < 30 then
    C_Timer.After(2, function() TryStart(attempt + 1) end)
  end
end

ns.On("LOGIN", function()
  C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
  if PREFIX ~= LEGACY_PREFIX then C_ChatInfo.RegisterAddonMessagePrefix(LEGACY_PREFIX) end
  C_Timer.NewTicker(0.25, Pump)
  -- drop half-received messages after a minute
  C_Timer.NewTicker(30, function()
    local now = GetTime()
    for k, buf in pairs(buffers) do if now - buf.t > 60 then buffers[k] = nil end end
  end)
  TryStart()
end)

ns.RegisterEvent("PLAYER_GUILD_UPDATE", function()
  if IsInGuild() and not started then TryStart() end
end)

ns.RegisterEvent("CHAT_MSG_ADDON", ns.OnAddonMessage)
