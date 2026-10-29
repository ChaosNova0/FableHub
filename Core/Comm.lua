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

-- The channel name follows ns.DATA_EPOCH (Core.lua). Bumping the epoch gives a
-- fresh start (the launch build is era 2): older clients talk on the previous
-- era's channel, so their (beta) data can't reach the new one. Hellos still go
-- out on that channel too, so older clients see that a newer FableHub exists.
local function PrefixFor(epoch) return epoch > 1 and ("FableHub" .. epoch) or "FableHub" end
local PREFIX = PrefixFor(ns.DATA_EPOCH or 1)
local LEGACY_PREFIX = PrefixFor(math.max(1, (ns.DATA_EPOCH or 1) - 1))
ns.PREFIX = PREFIX
local MAX_MSG = 250
local HEADER_ROOM = 16
local CHUNK = MAX_MSG - HEADER_ROOM

ns.present = {}          -- [key] = version, FableHub users heard from this session
local sendQueue = {}
-- Duplicate control. Catch-up answers often queue the same data again (several
-- members logging in at once, all missing the same records): an exact copy of
-- a message still waiting to go out is skipped, and a newer broadcast of a
-- character record replaces an older one still waiting.
local waitingSig = {}    -- [message signature] = true until its first part is sent
local waitingRecord = {} -- [character key] = message id of a record broadcast not started yet
local startedIds = {}    -- [message id] = true once its first part has gone out
local newerSeen = {}     -- [version] = { [key] = true }, versions above ours (see NoteVersion)
local buffers = {}       -- partial multi-part messages
local nextId = math.random(0, 1295)
local queuedCount = 0    -- messages queued so far (tells whether a catch-up request got an answer)
-- Catch-up requests ("what I already have" digests), by message type:
--   D records, Y raid sign-ups, K loot, G alts, J announcements, U craft
--   requests, Q plans, d guild bank requests
local DIGESTS = { D = true, Y = true, K = true, G = true, J = true, U = true, Q = true, d = true }
local digestSentAt = {}  -- [digest type] = GetTime() our own digest of that type was last queued / went out
local lastDigestAt = -1e9 -- the latest of those (any type)
local lastGuildSendAt = -1e9 -- GetTime() something of ours last went out on the guild channel
local lastSendTo = {}     -- [key] = GetTime() a whisper of ours last went out to them
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

-- an item leaves the queue (sent or given up on): its message is no longer "waiting"
local function Dequeue()
  local item = table.remove(sendQueue, 1)
  if item.part == 1 then
    startedIds[item.id] = true
    if item.sig then waitingSig[item.sig] = nil end
    if item.recKey and waitingRecord[item.recKey] == item.id then waitingRecord[item.recKey] = nil end
  end
  if item.part == item.total then startedIds[item.id] = nil end
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
      if item.tries > 10 then Dequeue() end
      tokens = 0
      return
    end
    -- our catch-up request went out: answers to it are expected from now (see RelayGate)
    if item.dig and result == "ok" then
      digestSentAt[item.dig] = GetTime()
      lastDigestAt = GetTime()
    end
    -- (everyone hears it: keeps the catch-up windows of those we answer open,
    -- see RequesterWindowOpen; with the guild channel muted, guild messages go
    -- out as whispers to every FableHub user, so those count too)
    if result == "ok" and (not to or ns.guildMuted) then lastGuildSendAt = GetTime() end
    if result == "ok" and item.target then lastSendTo[item.target] = GetTime() end
    Dequeue()
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

-- remove the waiting (unstarted) parts of message `id`
local function Unqueue(id)
  if startedIds[id] then return false end
  for i = #sendQueue, 1, -1 do
    if sendQueue[i].id == id then
      local item = table.remove(sendQueue, i)
      if item.sig then waitingSig[item.sig] = nil end
    end
  end
  return true
end

-- recKey: a character record broadcast, which replaces an older one still waiting
-- front: goes out ahead of everything waiting (parts are reassembled by
-- message id, so it can't mix into a message already being sent)
function Queue(msgType, payload, target, prefix, form, recKey, front)
  payload = payload or ""
  -- our own catch-up request (features send theirs through ns.Send too)
  local dig = DIGESTS[msgType] and not prefix and msgType or nil
  if dig then
    digestSentAt[dig] = GetTime()
    lastDigestAt = GetTime()
  end
  if not target and ns.guildMuted and not prefix then
    for _, key in ipairs(WhisperPeers(msgType == "H")) do Queue(msgType, payload, key, nil, nil, recKey, front) end
    return
  end
  local sig = table.concat({ msgType, target or "", prefix or "", form or "", payload }, "\1")
  if waitingSig[sig] then return end -- the exact same message is already waiting
  local recSlot = recKey and ((target or "") .. "\1" .. recKey)
  if recSlot and waitingRecord[recSlot] then Unqueue(waitingRecord[recSlot]) end
  local id = NewId()
  local total = math.max(1, math.ceil(#payload / CHUNK))
  for i = 1, total do
    local part = payload:sub((i - 1) * CHUNK + 1, i * CHUNK)
    table.insert(sendQueue, front and i or #sendQueue + 1, { msg = table.concat({ msgType, id, i, total, part }, "#"), target = target, prefix = prefix,
                              form = form, id = id, part = i, total = total,
                              sig = i == 1 and sig or nil, recKey = i == 1 and recSlot or nil,
                              dig = i == total and dig or nil })
  end
  waitingSig[sig] = true
  if recSlot then waitingRecord[recSlot] = id end
  queuedCount = queuedCount + 1
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
  if rec then Queue("F", Enc.EncodeRecord(rec), nil, nil, nil, rec.key) end
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

-- Versions are self-reported. One newer than ours only counts once an officer,
-- or at least two members who are online right now, run it, so one member
-- claiming "999.0" can't make themselves the only one who answers catch-up
-- (and then not answer). (Online now: a main and an alt claiming it one after
-- the other don't count twice.)
local function VersionConfirmed(ver)
  local seen = newerSeen[ver]
  if not seen then return false end
  local n = 0
  for k in pairs(seen) do
    if ns.RealOfficer and ns.RealOfficer(k) then return true end
    local r = ns.roster[k]
    if r and r.online then n = n + 1 end
  end
  return n >= 2
end

local function TrustedVersion(key)
  local mine = VersionNumber(ns.VERSION)
  if key == ns.MyKey() then return mine end
  local ver = ns.present[key]
  local v = VersionNumber(ver)
  if v > mine and not VersionConfirmed(ver) then return mine end
  return v
end

-- the relay among online FableHub users passing `eligible`, not counting `requester`
local function BestRelay(requester, eligible)
  local me = ns.MyKey()
  local best, bestV
  local function consider(key)
    if eligible and not eligible(key) then return end
    local v = TrustedVersion(key)
    if not best or v > bestV or (v == bestV and key < best) then best, bestV = key, v end
  end
  if me and me ~= requester then consider(me) end
  for key in pairs(ns.present) do
    if key ~= requester and key ~= me and ns.IsOnline(key) then consider(key) end
  end
  return best
end

local function AmRelayFor(requester)
  local me = ns.MyKey()
  return me ~= nil and BestRelay(requester) == me
end
ns.AmRelayFor = AmRelayFor

------------------------------------------------------------------------
-- Trust checks
------------------------------------------------------------------------
-- Who really sent a message, as a guild roster key. The part after "-" in the
-- sender's name is either a realm (ours / the guild's) or, on Forever, the last
-- name ("First-Lastname"). Tried in order:
--   exact     the name with no tail or our realm as the tail, or the last name
--             rebuilt as "First Lastname", is exactly a roster key
--   full      a unique case-insensitive match of that full name; or, when the
--             tail is neither our realm nor a known last name, the name before
--             it is a roster key (a connected realm)
--   first     the name arrived without a last name: a unique first-name match
--             ("loose": see LooseSender)
-- strict (whispers, which anyone on the realm can send): exact matches only, so
-- "Hunt-Stormrage" never passes as guildmate "Hunt".
-- Returns key, loose; nil = not in the guild.
local resolved, resolvedHow = {}, {}
ns.On("ROSTER_CHANGED", function() resolved, resolvedHow = {}, {} end)
local function FirstName(key)
  local n = key:match("^([^-]+)") or key
  return (n:match("^(%S+)") or n):lower()
end
local function KnownKey(key) return key ~= nil and (ns.roster[key] ~= nil or key == ns.MyKey()) end

-- is `tail` (the part after "-") our realm or the guild's, in any spelling?
local function IsOurRealm(tail)
  local t = tail:gsub("[%s%-']", ""):lower()
  if t == "" then return true end
  for _, r in ipairs({ ns.KeyRealm() or "", ns.MyRealm() or "" }) do
    if r ~= "" and t == r:gsub("[%s%-']", ""):lower() then return true end
  end
  return false
end

-- the unique roster key whose name (before "-") is `name`, ignoring case
local function UniqueName(name)
  name = name:lower()
  local found
  for key in pairs(ns.roster) do
    if (key:match("^([^-]+)") or key):lower() == name then
      if found then return nil end -- two people share that name: can't tell
      found = key
    end
  end
  return found
end

-- returns key, how ("exact" / "full" / "first")
local function Resolve(sender)
  local base, tail = sender:match("^([^-]+)%-(.*)$")
  base = base or sender
  local realmTail = not tail or IsOurRealm(tail)
  -- the name as it would be in the roster: "First Lastname" when Forever put
  -- the last name in the realm slot
  local full, rebuilt = base, false
  if not realmTail and not base:find(" ", 1, true) then full, rebuilt = base .. " " .. tail, true end
  local key = ns.NormalizeName(full)
  if KnownKey(key) then
    -- "First Lastname-OtherRealm" is someone on another realm who may share a
    -- guildmate's name: not exact
    if realmTail or rebuilt then return key, "exact" end
    return key, "full"
  end
  key = UniqueName(full)
  if key then return key, "full" end
  if rebuilt then
    -- a tail that's neither our realm nor a last name we know: perhaps a
    -- connected realm's name
    key = ns.NormalizeName(base)
    if KnownKey(key) then return key, "full" end
    key = UniqueName(base)
    if key then return key, "full" end
  end
  -- Only when the name arrived without a last name: a full "First Lastname"
  -- that isn't in the roster is someone else (otherwise any player sharing a
  -- guildmate's first name could pass as them)
  if full:find(" ", 1, true) then return nil end
  -- only a first name: a unique first-name match (roster keys all carry the
  -- guild's realm, see NormalizeName)
  local first, found = FirstName(full), nil
  for k in pairs(ns.roster) do
    if FirstName(k) == first then
      if found then return nil end
      found = k
    end
  end
  if found then return found, "first" end
end

function ns.ResolveSender(sender, strict)
  if type(sender) ~= "string" or sender == "" then return nil, false end
  if resolved[sender] == nil then
    local key, how = Resolve(sender)
    resolved[sender], resolvedHow[sender] = key or false, key and how or nil
  end
  local key, how = resolved[sender], resolvedHow[sender]
  if not key or (strict and how ~= "exact") then return nil, false end
  return key, how == "first"
end

-- Members whose latest message only matched the roster by first name
-- ([key] = true). Their messages can't vouch for officer data or first-hand
-- changes (OfficerSent / FirstHand say no). Set per message in OnAddonMessage;
-- never set for ourselves.
local looseFrom = {}
function ns.LooseSender(key) return key ~= nil and looseFrom[key] == true end

-- Is `sender` loose for the message being handled? The message itself
-- (ns.receivingLoose, set by Dispatch and restored for RelayGate replays), or
-- the member's latest message.
local function IsLoose(sender)
  if sender == nil then return false end
  if sender == ns.receivingSender and ns.receivingLoose then return true end
  return looseFrom[sender] == true
end
ns.IsLooseSender = IsLoose

-- officer-only data: the author must be an officer (with `feature`: allowed to
-- use that feature, see Plans.lua), and it must come from the author or be
-- passed on by an officer or someone with that feature (members can't pass it on)
-- (with a feature, whoever passes it on must be allowed to use that feature
-- too: an officer the Guild Master took a feature away from can't pass on that
-- feature's data under someone else's name)
function ns.OfficerSent(sender, author, feature)
  local P = ns.Plans
  if IsLoose(sender) then return false end
  if not author or author == "" or not P.IsOfficer(author, feature) then return false end
  return sender == author or P.IsOfficer(sender, feature)
end

-- a change made by `actor` that arrived from `sender`: did it come first-hand
-- (or from an officer / someone with `feature`)? Second-hand copies from
-- members only fill gaps. A sender matched only by first name never counts.
function ns.FirstHand(sender, actor, feature)
  if IsLoose(sender) then return false end
  return sender == actor or ns.Plans.IsOfficer(sender, feature)
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

-- allowed `feature` by real guild rank (an officer, without a feature)
local function RealAllowed(key, feature)
  if feature == nil then return RealOfficer(key) end
  local idx = ns.Plans.RankIndex(key)
  return idx ~= nil and ns.Plans.RankAllowed(feature, idx)
end

-- With a feature, the relay is chosen among members allowed that feature, so
-- the copies it passes on are accepted by OfficerSent.
function ns.AmOfficerRelayFor(requester, feature)
  local me = ns.MyKey()
  if not me or not RealAllowed(me, feature) then return false end
  return BestRelay(requester, function(key) return RealAllowed(key, feature) end) == me
end

-- Is `sender` the member who answers our catch-up (or the next in line, in
-- case our view of who's online differs a little from theirs)? Second-hand
-- copies of other people's data that aren't from an officer are only taken
-- from them. nil = we haven't heard their hello yet, so we can't tell.
function ns.IsMyRelay(sender)
  if not ns.present[sender] then return nil end
  local me = ns.MyKey()
  local first = BestRelay(me)
  if sender == first then return true end
  return BestRelay(me, function(key) return key ~= first end) == sender
end

-- Second-hand data (copies of other people's records, sign-ups, links,
-- requests...) is only taken from an officer, or from the member answering
-- our catch-up while that answer is due: within CATCHUP_WINDOW seconds of our
-- own digest of that kind (see DIGESTS for the letters). So a member can't
-- push second-hand data whenever they like by making themselves look like the
-- relay.
-- A relay with a lot to send (about one part a second, hundreds of parts for
-- someone who was away a while) can take much longer than that, so each
-- sender's windows slide: while a kind's window is still open for them,
-- anything we hear from our relay (or a message RelayGate accepts or defers
-- from them) keeps it open CATCHUP_WINDOW seconds more. So their windows close
-- after CATCHUP_WINDOW seconds of silence from them, and CATCHUP_MAX seconds
-- after our digest at the latest. (A window that closed doesn't reopen.)
--
-- ns.RelayGate(sender, digestType, replay)
--   true  accept now
--   false reject
--   nil   deferred: the sender may be our relay but their hello hasn't reached
--         us yet (at login their answers often arrive first). `replay` is
--         called later, at most once, when their hello arrives and shows them
--         to be our relay, with the message context (ns.receiving,
--         ns.receivingPayload, ns.receivingSender, ns.receivingLoose) restored;
--         it's dropped if they turn out not to be, or the window closes first.
-- A sender matched to the roster only by first name is never accepted.
local CATCHUP_WINDOW = 180
local CATCHUP_MAX = 1800   -- hard limit after our digest, however busy the relay
local MAX_PENDING = 400    -- replays waiting per sender
local pendingReplays = {}  -- [sender] = { { fn, dig, msgType, payload, from, loose }, ... }
local relayUntil = {}      -- [sender] = { [digest type] = GetTime() that window closes for them }
local relayHeardAt = -1e9  -- GetTime() we last heard a member known to be our relay (see AutoResync)

-- is our catch-up window of `digestType` open for `sender`?
local function CatchUpOpen(digestType, sender)
  local t = digestSentAt[digestType]
  if not t then return false end
  local now = GetTime()
  if now - t > CATCHUP_MAX then return false end
  if now - t <= CATCHUP_WINDOW then return true end
  local u = sender and relayUntil[sender]
  return u ~= nil and (u[digestType] or 0) >= now
end

-- we heard from `sender` as (possibly) our relay: their windows still open
-- stay open CATCHUP_WINDOW seconds more
local function RelayActive(sender)
  if not sender or GetTime() - lastDigestAt > CATCHUP_MAX then return end
  local closes = GetTime() + CATCHUP_WINDOW
  local u = relayUntil[sender]
  for d in pairs(DIGESTS) do
    if CatchUpOpen(d, sender) then
      if not u then u = {}; relayUntil[sender] = u end
      if (u[d] or 0) < closes then u[d] = closes end
    end
  end
end

function ns.RelayGate(sender, digestType, replay)
  if type(sender) ~= "string" or IsLoose(sender) then return false end
  if ns.Plans and ns.Plans.IsOfficer(sender) then return true end
  if not CatchUpOpen(digestType, sender) then return false end
  local relay = ns.IsMyRelay(sender)
  if relay then
    relayHeardAt = GetTime()
    RelayActive(sender)
    return true
  end
  if relay == false or type(replay) ~= "function" then return false end
  local list = pendingReplays[sender]
  if not list then list = {}; pendingReplays[sender] = list end
  if #list >= MAX_PENDING then return false end
  list[#list + 1] = { fn = replay, dig = digestType, msgType = ns.receiving, payload = ns.receivingPayload,
                      from = ns.receivingSender, loose = ns.receivingLoose }
  -- (they may be our relay: keep their windows open while the replays wait;
  -- dropped with the replays if their hello shows they aren't)
  RelayActive(sender)
  return nil
end

-- `sender`'s hello arrived: run their waiting replays if they're our relay,
-- drop them if not (still unknown: keep waiting)
local function FlushReplays(sender)
  if not sender then return end
  local relay = ns.IsMyRelay(sender)
  if relay == nil then return end
  -- (windows kept open for them before their hello, see OnAddonMessage)
  if not relay then relayUntil[sender] = nil end
  local list = pendingReplays[sender]
  if not list then return end
  pendingReplays[sender] = nil
  if not relay then
    ns.Debug(("dropped %d catch-up messages from %s (not our relay)"):format(#list, sender))
    return
  end
  local r1, r2, r3, r4 = ns.receiving, ns.receivingPayload, ns.receivingSender, ns.receivingLoose
  for _, e in ipairs(list) do
    if CatchUpOpen(e.dig, sender) then
      ns.receiving, ns.receivingPayload, ns.receivingSender, ns.receivingLoose = e.msgType, e.payload, e.from, e.loose
      local ok, err = pcall(e.fn)
      if not ok then ns.ReportError(err) end
    end
  end
  ns.receiving, ns.receivingPayload, ns.receivingSender, ns.receivingLoose = r1, r2, r3, r4
end

-- drop replays whose catch-up window closed, and windows that closed
local function ExpireReplays()
  for sender, list in pairs(pendingReplays) do
    for i = #list, 1, -1 do
      if not CatchUpOpen(list[i].dig, sender) then table.remove(list, i) end
    end
    if #list == 0 then pendingReplays[sender] = nil end
  end
  local now = GetTime()
  for sender, u in pairs(relayUntil) do
    local open = false
    for _, t in pairs(u) do if t >= now then open = true end end
    if not open then relayUntil[sender] = nil end
  end
end

-- catch-up digests other modules send at startup and on /fhub sync
local digests = {}
function ns.RegisterDigest(fn) digests[#digests + 1] = fn end

------------------------------------------------------------------------
-- Receiving
------------------------------------------------------------------------
local helloAnswered = {}    -- [key] = { t, n }: our replies to their hellos (see HandleHello)
local replyDue = {}         -- [key] = GetTime() of a hello of theirs we owe a reply to
local lastReplyAt = -1      -- GetTime() we last queued a reply (R)
local wantedRecently = {}   -- [key] = GetTime() when we decided to ask for it
local wantSeen = {}         -- [key] = GetTime() when someone else asked for it
local answeredWant = 0
local wantFrom = {}         -- [requester] = GetTime() we last re-sent our record for their W
local reassertFrom = {}     -- [sender] = GetTime() their digest or record copy last made us reassert our record
-- the message being handled came from a sender resolved exactly to the roster
-- (ResolveSender's "exact"); set by OnAddonMessage
local receivingExact = false

-- Our reply to hellos heard at or after `since` (one reply on the guild
-- channel answers everyone who said hello before it). front: ahead of
-- everything waiting to go out (see Dispatch)
local function SendReply(since, front)
  if lastReplyAt >= since then return end
  lastReplyAt = GetTime()
  Queue("R", HelloPayload(), nil, nil, nil, nil, front)
end

-- Catch-up answers re-send a lot, so there's a budget: once a request got an
-- answer (we re-sent something), the same member's next request of that kind
-- is ignored for ANSWER_GAP seconds (they already have it, and changes since
-- reach them as they happen); and at most MAX_ANSWERS members' logins are
-- answered per minute in all (all the kinds one member asks for at login count
-- once). Re-sending our own record to correct a newer "copy" counts too.
local ANSWER_GAP = 300
local answeredAt = {}       -- [requester#type] = GetTime() of our last answer that sent something
local MAX_ANSWERS = 60      -- per minute
local answerWindow, answerCount = 0, 0
local answerCounted = {}    -- [requester] = GetTime() they were last counted

local function RollAnswers()
  local now = GetTime()
  if now - answerWindow >= 60 then answerWindow, answerCount = now, 0 end
end
-- over budget for `who` (nil: a new answer of its own, e.g. a reassert)?
local function OverBudget(who)
  RollAnswers()
  if who and (answerCounted[who] or -1) >= answerWindow then return false end -- already counted this minute
  return answerCount >= MAX_ANSWERS
end
local function CountAnswer(who)
  RollAnswers()
  if who and (answerCounted[who] or -1) >= answerWindow then return end
  answerCount = answerCount + 1
  if who then answerCounted[who] = GetTime() end
end

-- Newer FableHub versions seen in the guild. Told once per version, and only
-- when an officer or at least two members run it (so one player claiming a
-- made-up version can't nag everyone).
local toldNewer = {}
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

-- ask `key`'s owner for their record (version `theirTs`) unless it arrived
-- meanwhile. When someone else asked first, wait a little for the owner's
-- answer to them; ask ourselves if it doesn't come (the owner may have
-- turned that member's ask down, see HandleWant).
local WANT_WAIT = 8
local function WantIfStill(key, theirTs, scheduled, waited)
  local g = ns.GuildDB()
  local have = g and g.members[key]
  if have and (have.ts or 0) >= theirTs then return end
  if not waited and (wantSeen[key] or 0) >= scheduled then
    C_Timer.After(WANT_WAIT, function() WantIfStill(key, theirTs, scheduled, true) end)
    return
  end
  ns.Send("W", key)
end

local function HandleHello(sender, payload, isReply)
  local f = Enc.Split(payload, "^")
  local proto = tonumber(f[1]) or 0
  -- The key they claim (f[4]) is never used: only the name the game gives us,
  -- as we resolved it (so nobody can be noted as present, or as running some
  -- version, under someone else's name). Versions only count from senders
  -- matched exactly to the roster (see VersionConfirmed).
  if f[2] and #f[2] > 16 then f[2] = f[2]:sub(1, 16) end
  ns.present[sender] = f[2] or "?"
  if receivingExact then NoteVersion(sender, f[2]) end
  local g = ns.GuildDB()
  if g then
    g.addonUsers[sender] = { version = f[2], seen = ns.Now() }
  end
  -- catch-up answers of theirs that arrived before this hello (see RelayGate)
  FlushReplays(sender)
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
      C_Timer.After(1 + math.random() * 3, function() WantIfStill(sender, theirTs, scheduled, false) end)
    end
  end

  -- answer each member's hello at most 3 times in 5 minutes: enough for a
  -- /reload or two (a reloaded client needs our reply to know we're here),
  -- but a repeated hello can't make every FableHub user reply every time
  -- (past that, the reply still goes out right before our answer if they ask
  -- us for catch-up: they need it to take our answers, see Dispatch; that
  -- path has its own limits, DIGEST_GAP and ANSWER_GAP)
  if not isReply then
    local now, a = GetTime(), helloAnswered[sender]
    if not a or now - a.t > 300 then a = { t = now, n = 0 }; helloAnswered[sender] = a end
    -- (sent at once instead if they ask us for catch-up first, see Dispatch)
    local heard = GetTime()
    replyDue[sender] = heard
    if a.n < 3 then
      a.n = a.n + 1
      C_Timer.After(1 + math.random() * 4, function() SendReply(heard) end)
    end
  end
  ns.Fire("DATA_CHANGED")
end

-- W: re-send our record (at most every 10 s, and once per ANSWER_GAP for each
-- member asking, so nobody can make us broadcast it over and over)
local function HandleWant(sender, key)
  wantSeen[key] = GetTime()
  wantedRecently[key] = GetTime()
  if key == ns.MyKey() then
    local now = GetTime()
    if now - answeredWant > 10 and (not wantFrom[sender] or now - wantFrom[sender] > ANSWER_GAP) then
      answeredWant, wantFrom[sender] = now, now
      ns.BroadcastRecord(ns.MyRecord())
    end
  end
end

-- someone sent a newer "copy" of our own record than we have (a forgery, or
-- stale data from another client): make ours newer and send it again, so the
-- real one wins everywhere. Counts toward the answer budget (when it's used
-- up, the re-send waits for the next minute).
-- (defined before HandleDigest, which calls it)
local reasserting = false
local function ReassertMine(theirTs)
  local mine = ns.MyRecord()
  if not mine then return end
  if (mine.ts or 0) <= theirTs then mine.ts = theirTs + 1 end
  if reasserting then return end -- already on its way (it reads the record when it goes)
  reasserting = true
  local delay = 3
  if OverBudget(nil) then delay = math.max(3, 61 - (GetTime() - answerWindow)) end
  C_Timer.After(delay, function()
    reasserting = false
    CountAnswer(nil)
    ns.MirrorMyRecord()
    ns.BroadcastRecord(ns.MyRecord())
  end)
end
ns.ReassertMine = ReassertMine

-- ReassertMine because of `sender`'s digest or record copy: at once for our
-- relay or an officer (not matched only by first name); anyone else at most
-- once per 5 minutes each (or one member sending everyone's records or a
-- digest with a future time could make every client re-send its record
-- every 20 seconds)
local function ReassertFor(sender, theirTs)
  local trusted = not IsLoose(sender) and (ns.IsMyRelay(sender) or ns.Plans.IsOfficer(sender))
  if not trusted then
    local now = GetTime()
    if reassertFrom[sender] and now - reassertFrom[sender] < 300 then return end
    reassertFrom[sender] = now
  end
  ReassertMine(theirTs)
end

local function HandleDigest(sender, payload)
  local theirs = Enc.DecodeDigest(payload)
  -- someone holds a newer "copy" of our record than ours: correct it
  local me, mine = ns.MyKey(), ns.MyRecord()
  if me and mine and (theirs[me] or 0) > (mine.ts or 0) and ns.TimeOK(theirs[me]) then
    ReassertFor(sender, theirs[me])
  end
  if not AmRelayFor(sender) then return end
  local g = ns.GuildDB()
  if not g then return end
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

-- the same record apart from cooldowns (clients pass records on with only the
-- cooldowns they know: 0.21 none, and each version drops ones newer than it)
local function SameApartFromCds(a, b)
  return Enc.EncodeRecord(a, true) == Enc.EncodeRecord(b, true)
end

-- does `rec` hold a cooldown `mine` doesn't, or holds differently? (cooldowns
-- `mine` has that `rec` lacks don't count: see SameApartFromCds)
local function CdsDiffer(rec, mine)
  for id, e in pairs(rec.cds or {}) do
    local m = mine.cds and mine.cds[id]
    if not m or Enc.ToB36(m.ready) ~= Enc.ToB36(e.ready) or Enc.ToB36(m.dur) ~= Enc.ToB36(e.dur) then return true end
  end
  return false
end

-- does `rec` hold a cooldown `have` lacks?
local function AddsCds(rec, have)
  for id in pairs(rec.cds or {}) do
    if not (have.cds and have.cds[id]) then return true end
  end
  return false
end

-- Who may change a character record:
--   * the owner (sender == rec.key) may always send their own record;
--   * a copy passed on by someone else is how records of members who are
--     offline reach people (catch-up answers to a digest). It's taken from an
--     officer, or from the member answering our catch-up while that's due
--     (ns.RelayGate, digest "D"): it may fill in a record we don't have,
--     replace an older copy (otherwise newer records of offline members would
--     never reach anyone holding an old one), or add cooldowns to the same
--     version of a record we hold without them;
--   * anyone else's copies of other people's records are ignored, so a member
--     can't rewrite (or invent) someone else's professions.
-- A relay matched to the roster only by first name (see LooseSender) isn't trusted.
local function HandleFull(sender, payload)
  local rec = Enc.DecodeRecord(payload)
  if not rec or not ns.TimeOK(rec.ts) then return end
  if rec.key == ns.MyKey() then
    local mine = ns.MyRecord()
    -- a newer copy, or one with our timestamp but different contents, gets
    -- corrected; a copy of ours someone passed on is left alone, also when it
    -- lacks some of our cooldowns (an older client relaying it without the
    -- ones it doesn't know). Throttled per sender like a digest's (ReassertFor).
    if mine and (rec.ts > (mine.ts or 0)
        or (rec.ts == (mine.ts or 0) and (not SameApartFromCds(rec, mine) or CdsDiffer(rec, mine)))) then
      ReassertFor(sender, rec.ts)
    end
    return
  end
  -- only guild members (stops made-up members piling up in everyone's saved data)
  if next(ns.roster) and not ns.roster[rec.key] then return end
  -- (a sender matched only by first name isn't taken as the owner: see
  -- LooseSender; RelayGate refuses them as a relay too)
  if sender ~= rec.key or IsLoose(sender) then
    local g = ns.GuildDB()
    local have = g and g.members[rec.key]
    if have then
      local ts = have.ts or 0
      if ts > rec.ts then return end
      -- the same version: only of use when it brings cooldowns ours lacks
      if ts == rec.ts and (not AddsCds(rec, have) or not SameApartFromCds(rec, have)) then return end
    end
    if not ns.RelayGate(sender, "D", function() HandleFull(sender, payload) end) then return end
  end
  if ns.StoreRecord(rec) then
    ns.Debug("stored " .. rec.key .. " (from " .. sender .. ")")
  end
end

-- Size limits: most messages fit in a few parts; only these can be big.
-- Anything longer is dropped, so nobody can make everyone buffer ~100 KB.
local MAX_PARTS = { F = 120, B = 400, D = 200, Y = 120, A = 30, P = 30, Q = 40, d = 40, t = 30, l = 30, I = 12, G = 12, K = 12 }
local DEFAULT_PARTS = 8
local MAX_BUFFERS = 16 -- half-received messages per sender

-- Catch-up requests make the answering member re-send a lot: answer each
-- member's request of a kind at most once per DIGEST_GAP seconds, so a
-- spammed /fhub sync (or a modified client) can't flood the guild channel.
-- (DIGESTS is at the top of the file; the answer budget is above HandleHello.)
local DIGEST_GAP = 20
local lastDigest = {}

-- While a lot is already waiting to go out (about 3 minutes' worth), catch-up
-- answers wait their turn instead of piling on more: at launch everyone's data
-- starts empty, and the answers to one login usually cover the next one too.
-- The same when the answer budget (MAX_ANSWERS) is used up.
local BUSY_QUEUE = 200
local MAX_WAITS = 10 -- 30 s apart: after 5 minutes, answer anyway

-- An answer is only of use while the asker's catch-up window is open (see
-- RelayGate): it slides while they hear from us, so it closes CATCHUP_WINDOW
-- seconds after our last guild message (or their request), CATCHUP_MAX after
-- their request at the latest. A waiting answer whose window has (about)
-- closed is dropped instead of sent to be ignored: they can /fhub sync again.
-- While we're busy (BUSY_QUEUE) we keep sending, so their window stays open
-- and the answer still lands after MAX_WAITS; when only the budget held it up
-- and we went quiet, it's dropped.
local CLOSE_MARGIN = 20
local function RequesterWindowOpen(asker, askedAt)
  local now = GetTime()
  if now - askedAt > CATCHUP_MAX - CLOSE_MARGIN then return false end
  -- (whispers to them keep it open too)
  local heard = math.max(askedAt, lastGuildSendAt, lastSendTo[asker] or -1e9)
  return now - heard <= CATCHUP_WINDOW - CLOSE_MARGIN
end

local Dispatch
local function AnswerCatchUp(sender, msgType, payload, waits, channel, loose, askedAt)
  if waits > 0 and not RequesterWindowOpen(sender, askedAt) then
    ns.Debug(("dropped catch-up answer %s for %s (their window closed)"):format(msgType, sender))
    return
  end
  if (#sendQueue > BUSY_QUEUE or OverBudget(sender)) and waits < MAX_WAITS then
    C_Timer.After(30, function()
      if ns.IsOnline(sender) then AnswerCatchUp(sender, msgType, payload, waits + 1, channel, loose, askedAt) end
    end)
    return
  end
  local before = queuedCount
  Dispatch(sender, msgType, payload, true, channel, loose)
  if queuedCount > before then
    answeredAt[sender .. "#" .. msgType] = GetTime()
    CountAnswer(sender)
  end
end

-- channel: "GUILD" or "WHISPER", passed to CommHandlers as a third argument.
-- loose: this message's sender matched the roster only by first name (see
-- ResolveSender); handlers see it as ns.receivingLoose.
function Dispatch(sender, msgType, payload, answering, channel, loose)
  if DIGESTS[msgType] and not answering then
    local k = sender .. "#" .. msgType
    local now = GetTime()
    if (lastDigest[k] and now - lastDigest[k] < DIGEST_GAP) or (answeredAt[k] and now - answeredAt[k] < ANSWER_GAP) then
      ns.Debug("ignored repeated catch-up request " .. msgType .. " from " .. sender)
      return
    end
    lastDigest[k] = now
    -- we owe them a reply to their hello: send it first, so it reaches them
    -- before our answers (they only take catch-up answers from the member
    -- they know answers them, see RelayGate), ahead of whatever is waiting.
    -- Only when we answer them as their relay (officers' answers are taken
    -- without it, see RelayGate / OfficerSent).
    if replyDue[sender] and AmRelayFor(sender) then
      SendReply(replyDue[sender], true)
      replyDue[sender] = nil
    end
    return AnswerCatchUp(sender, msgType, payload, 0, channel, loose, now)
  end
  -- which message is being handled and who sent it (the roster key): the
  -- officer change log (ChangeLog.lua) tells what a "...changed" event fired by
  -- a handler came from, and RelayGate / OfficerSent / FirstHand whether the
  -- sender only matched by first name. (ns.receiving only for feature
  -- messages: the change log has nothing to note for core ones.)
  local feature = ns.CommHandlers[msgType]
  local core = msgType == "H" or msgType == "R" or msgType == "W" or msgType == "D" or msgType == "F"
  if not core and not feature then return end
  local r1, r2, r3, r4 = ns.receiving, ns.receivingPayload, ns.receivingSender, ns.receivingLoose
  if core then
    ns.receiving, ns.receivingPayload = nil, nil
  else
    ns.receiving, ns.receivingPayload = msgType, payload
  end
  ns.receivingSender, ns.receivingLoose = sender, loose and true or nil
  local ok, err
  if msgType == "H" then ok, err = pcall(HandleHello, sender, payload, false)
  elseif msgType == "R" then ok, err = pcall(HandleHello, sender, payload, true)
  elseif msgType == "W" then ok, err = pcall(HandleWant, sender, payload)
  elseif msgType == "D" then ok, err = pcall(HandleDigest, sender, payload)
  elseif msgType == "F" then ok, err = pcall(HandleFull, sender, payload)
  else ok, err = pcall(feature, sender, payload, channel) end
  ns.receiving, ns.receivingPayload, ns.receivingSender, ns.receivingLoose = r1, r2, r3, r4
  if not ok then error(err, 0) end
end

function ns.OnAddonMessage(prefix, text, channel, sender)
  if channel ~= "GUILD" and channel ~= "WHISPER" then return end
  local legacy = PREFIX ~= LEGACY_PREFIX and prefix == LEGACY_PREFIX
  if prefix ~= PREFIX and not legacy then return end
  if issecretvalue and (issecretvalue(text) or issecretvalue(sender)) then return end
  if ns.Diag then ns.Diag.NoteRecv(sender, channel, prefix) end
  local raw = sender
  sender = ns.NormalizeName(sender)
  if not sender then return end
  -- whispers can come from anyone on the realm: only guild members count, and
  -- only by their exact name (no first-name guess, or anyone sharing a
  -- guildmate's first name could whisper as them).
  -- (GUILD messages can only come from the guild.)
  local who, loose = ns.ResolveSender(raw, channel == "WHISPER")
  if ns.Diag then ns.Diag.NoteSender(sender, who) end
  if legacy then
    -- older clients on the old channel: only note their version, use nothing else
    local t, payload = text:match("^([HR])#%w+#1#1#(.*)$")
    if t and channel == "GUILD" then
      local f = Enc.Split((payload:gsub("|", "")), "^")
      local ver = f[2]
      -- only the name the game gave us counts, never the key they claim (f[4])
      local key = who
      if key and key ~= ns.MyKey() and ver and #ver <= 16 and ver:match("^%d+%.%d+%.?%d*$") then
        ns.present[key] = ns.present[key] or ver
      end
    end
    return
  end
  if channel == "WHISPER" and not who then return end
  sender = who or sender
  receivingExact = who ~= nil and resolvedHow[raw] == "exact"
  if who and who ~= ns.MyKey() then looseFrom[who] = loose or nil end
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
  -- every part heard from our relay keeps our catch-up windows open (see
  -- RelayGate): answers to us can sit behind a long queue of other parts.
  -- Also before their hello reached us (nil: can't tell yet), as RelayGate's
  -- deferred path does: dropped by FlushReplays if they turn out not to be.
  if not loose and GetTime() - lastDigestAt <= CATCHUP_MAX then
    local relay = ns.IsMyRelay(sender)
    if relay then relayHeardAt = GetTime() end
    if relay ~= false then RelayActive(sender) end
  end
  part, total = tonumber(part), tonumber(total)
  if total == 1 then return Dispatch(sender, msgType, payload, nil, channel, loose) end
  if total > (MAX_PARTS[msgType] or DEFAULT_PARTS) or part < 1 or part > total then return end

  -- (a sender matched only by first name gets buffers of their own, so their
  -- parts never mix into the real member's message)
  local bkey = sender .. "#" .. channel .. "#" .. (loose and "~" or "") .. id
  local buf = buffers[bkey]
  if not buf then
    local open = 0
    for k in pairs(buffers) do if k:sub(1, #sender + 1) == sender .. "#" then open = open + 1 end end
    if open >= MAX_BUFFERS then return end
    buf = { total = total, parts = {}, got = 0, t = GetTime(), msgType = msgType }
    buffers[bkey] = buf
  end
  -- every part must agree on the total, or the message could complete with a gap
  if total ~= buf.total then return end
  if not buf.parts[part] then
    buf.parts[part] = payload
    buf.got = buf.got + 1
  end
  if buf.got == buf.total then
    buffers[bkey] = nil
    Dispatch(sender, buf.msgType, table.concat(buf.parts), nil, channel, loose)
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

-- A catch-up that outlasts CATCHUP_MAX (a long backlog at about one part a
-- second): when a window is about to hit that limit while our relay is still
-- sending to us, send our digests again, once per login / sync. That opens
-- fresh windows, and the relay (its ANSWER_GAP long passed) answers with only
-- what our new digests still lack.
local autoResynced = false
local function AutoResync()
  if autoResynced or not started then return end
  local now = GetTime()
  if now - relayHeardAt > CATCHUP_WINDOW then return end
  for d, t in pairs(digestSentAt) do
    local age = now - t
    -- (checked every 30 s: two chances in this range, and our digests are
    -- queued within seconds, before the window closes)
    if age >= CATCHUP_MAX - 90 and age < CATCHUP_MAX - 30 then
      for sender, u in pairs(relayUntil) do
        if (u[d] or 0) >= now and ns.IsMyRelay(sender) then
          autoResynced = true
          ns.Debug("catch-up still running near its time limit: asking again")
          SendAllDigests()
          return
        end
      end
    end
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
  autoResynced = false
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
    for k, t in pairs(lastDigest) do if now - t > DIGEST_GAP then lastDigest[k] = nil end end
    for k, t in pairs(answeredAt) do if now - t > ANSWER_GAP then answeredAt[k] = nil end end
    for k, t in pairs(wantFrom) do if now - t > ANSWER_GAP then wantFrom[k] = nil end end
    for k, t in pairs(reassertFrom) do if now - t > 300 then reassertFrom[k] = nil end end
    for k, t in pairs(answerCounted) do if now - t > 120 then answerCounted[k] = nil end end
    for k, t in pairs(replyDue) do if now - t > 60 then replyDue[k] = nil end end
    for k, t in pairs(lastSendTo) do if now - t > CATCHUP_MAX then lastSendTo[k] = nil end end
    AutoResync()
    ExpireReplays()
  end)
  TryStart()
end)

ns.RegisterEvent("PLAYER_GUILD_UPDATE", function()
  if IsInGuild() and not started then TryStart() end
end)

ns.RegisterEvent("CHAT_MSG_ADDON", ns.OnAddonMessage)
