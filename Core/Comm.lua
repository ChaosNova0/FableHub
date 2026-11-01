-- Comm: guild-channel sync between FableHub users.
--
-- Every message is wrapped as  "<type>#<id>#<part>#<total>#<payload>"
-- so long payloads can be split across several 255-byte addon messages.
--
-- Types
--   H  hello      sent at login:            "<protocol>^<version>^<my record ts>^<its checksum>^<bucket sums>"
--                 (the sums of what we hold, as in D: a member in sync with
--                 their relays needs no D, see Catchup.lua)
--   R  here       reply to a hello:         same payload as H
--   W  want       ask the owner to rebroadcast their record: "<key>"
--   F  full       one character record (see Encode.lua)
--   T  delta      (0.26+) the owner's change to their own record, as edits
--                 to the version everyone holds (see Enc.EncodeDelta)
--   D  digest     (0.26+) records catch-up request: checksums of what we hold,
--                 by bucket, and the members we ask to answer (Catchup.lua)
--   s  sums       a named relay's answer to D (whisper): its sums, and its
--                 versions of the keys in the buckets where ours differ (or
--                 digests of those lists)
--   x  fetch      the records we want from that relay (whisper)
--   y  done       the relay queued everything for that x (whisper)
--   E  summaries  (0.25+) records without their recipes, sent ahead of the F
--                 records in a catch-up answer (see Enc.EncodeSummaryBatch)
--
-- Only each character's owner changes their own record. Other users relay
-- copies so data reaches people who were offline at the time. Owners
-- announce the checksum (Hash.lua) of their record's current version in their
-- hello, record and delta messages, and a copy passed on by someone else must
-- match the owner's checksum for that version (see HandleFull).

local _, ns = ...
local Enc = ns.Encode

-- The channel name follows ns.DATA_EPOCH (Core.lua). Bumping the epoch gives a
-- fresh start: older clients talk on the previous era's channel, so their data
-- can't reach the new one.
local PREFIX = "FableHub" .. (ns.DATA_EPOCH or 1)
ns.PREFIX = PREFIX
local MAX_MSG = 250
local HEADER_ROOM = 16
local CHUNK = MAX_MSG - HEADER_ROOM
local MAX_RECORD_PARTS = 120 -- parts of one F (MAX_PARTS below)

ns.present = {}          -- [key] = version, FableHub users heard from this session
local sendQueue = {}
-- Duplicate control. Catch-up answers often queue the same data again (several
-- members logging in at once, all missing the same records): an exact copy of
-- a message still waiting to go out is skipped, and a newer broadcast of a
-- character record replaces an older one still waiting.
local waitingSig = {}    -- [message signature] = true until its first part is sent
local waitingRecord = {} -- [character key] = message id of a record broadcast not started yet
local startedIds = {}    -- [message id] = true once its first part has gone out
local sentForm = {}      -- [message id] = the spelling its first part was whispered to (the rest follow it)
local partAt = {}        -- [message id] = GetTime() its latest part went out (until its last does)
-- Receivers drop a half-received message after about a minute without a
-- part of it (see the tickers at the bottom). The rest of one of ours held
-- up longer than this (combat, a boss fight) goes out from its first part again.
local RESTART_AFTER = 45
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

local function SendRaw(msg, target)
  local ok, res
  if target then
    ok, res = pcall(C_ChatInfo.SendAddonMessage, PREFIX, msg, "WHISPER", target)
  else
    ok, res = pcall(C_ChatInfo.SendAddonMessage, PREFIX, msg, "GUILD")
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
  partAt[item.id] = GetTime()
  if item.part == 1 then
    startedIds[item.id] = true
    if item.sig then waitingSig[item.sig] = nil end
    if item.recKey and waitingRecord[item.recKey] == item.id then waitingRecord[item.recKey] = nil end
  end
  if item.part == item.total then startedIds[item.id], sentForm[item.id], partAt[item.id] = nil, nil, nil end
end

-- the message at the front of the queue started too long ago for its
-- receivers to still hold its first parts: put those back in front of it
local function Restart(item)
  for p = item.part - 1, 1, -1 do
    table.insert(sendQueue, 1, { msg = item.all[p], target = item.target, form = item.form, id = item.id, part = p,
                                 total = item.total, front = item.front, all = item.all })
  end
  partAt[item.id] = nil
end

local function Pump()
  if #sendQueue == 0 or not IsInGuild() or Paused() then return end
  local now = GetTime()
  tokens = math.min(MAX_TOKENS, tokens + (now - lastRegen) * REGEN)
  lastRegen = now
  while tokens >= 1 and #sendQueue > 0 do
    local item = sendQueue[1]
    if item.part > 1 and item.all and partAt[item.id] and now - partAt[item.id] > RESTART_AFTER then
      Restart(item)
      item = sendQueue[1]
    end
    -- (every part of a whisper to the same spelling: one that fails partway
    -- fails whole, and goes again whole, see Catchup.lua)
    local to = item.form or (item.target and (sentForm[item.id] or ns.WhisperTarget(item.target)))
    if to and item.target and item.part == 1 and item.total > 1 then sentForm[item.id] = to end
    if to then ns.NoteWhisper(to, item.target) end
    local result = SendRaw(item.msg, to)
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
    -- see RequesterWindowOpen. With the guild channel muted, guild messages go
    -- out as whispers to each FableHub user: only lastSendTo counts then, as a
    -- whisper to one member doesn't keep anyone else's window open)
    if result == "ok" and not to then lastGuildSendAt = GetTime() end
    if result == "ok" and item.target then lastSendTo[item.target] = GetTime() end
    Dequeue()
    tokens = tokens - 1
    -- the whole message is out (see QueueMsg opts.onSent)
    if result == "ok" and item.onSent then
      local ok, err = pcall(item.onSent)
      if not ok then ns.ReportError(err) end
    end
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

-- where a message queued with front = "after" goes: past the rest of a
-- message already being sent (so it isn't held up) and past what was put in
-- front before it (replies, and earlier "after" messages, which keep their order)
local function AfterFront()
  local i = 1
  while sendQueue[i] and (startedIds[sendQueue[i].id] or sendQueue[i].front) do i = i + 1 end
  return i
end

-- how many parts queued with front = "after" are still waiting (they're all
-- within the part of the queue AfterFront skips)
local function AfterParts()
  local i, n = 1, 0
  while sendQueue[i] and (startedIds[sendQueue[i].id] or sendQueue[i].front) do
    if sendQueue[i].front == "after" then n = n + 1 end
    i = i + 1
  end
  return n
end

-- Queues a message; returns its id (nil when nothing was queued, or with the
-- guild channel muted, when it goes out as several whispers). opts (all optional):
--   target  a member's key: an addon whisper to them, not the guild
--   form    the spelling of their name to whisper (for /fhub ping)
--   recKey  a character record broadcast, which replaces an older one still waiting
--   front   true = goes out ahead of everything waiting (parts are reassembled by
--           message id, so it can't mix into a message already being sent);
--           "after" = ahead of everything but what AfterFront skips
--   dig     the catch-up request type this message counts as (default: the
--           message type, for the DIGESTS letters)
--   onSent  called once the message's last part went out
function Queue(msgType, payload, opts)
  payload = payload or ""
  opts = opts or {}
  local target, form, recKey, front = opts.target, opts.form, opts.recKey, opts.front
  -- our own catch-up request (features send theirs through ns.Send too)
  local dig = opts.dig or (DIGESTS[msgType] and msgType) or nil
  if dig then
    digestSentAt[dig] = GetTime()
    lastDigestAt = GetTime()
  end
  if not target and ns.guildMuted then
    local peers = WhisperPeers(msgType == "H")
    for i, key in ipairs(peers) do
      -- (onSent once the last of them went out)
      Queue(msgType, payload, { target = key, recKey = recKey, front = front, dig = opts.dig,
                                onSent = i == #peers and opts.onSent or nil })
    end
    return nil
  end
  local sig = table.concat({ msgType, target or "", form or "", payload }, "\1")
  if waitingSig[sig] then return nil end -- the exact same message is already waiting
  local recSlot = recKey and ((target or "") .. "\1" .. recKey)
  if recSlot and waitingRecord[recSlot] then Unqueue(waitingRecord[recSlot]) end
  local id = NewId()
  local total = math.max(1, math.ceil(#payload / CHUNK))
  local at = front == "after" and AfterFront() or 1
  -- (every part's text, shared by its parts: see Restart)
  local all = total > 1 and {} or nil
  for i = 1, total do
    local part = payload:sub((i - 1) * CHUNK + 1, i * CHUNK)
    local msg = table.concat({ msgType, id, i, total, part }, "#")
    if all then all[i] = msg end
    table.insert(sendQueue, front and (at + i - 1) or #sendQueue + 1, { msg = msg, target = target,
                              form = form, id = id, part = i, total = total, front = front or nil, all = all,
                              sig = i == 1 and sig or nil, recKey = i == 1 and recSlot or nil,
                              dig = i == total and dig or nil, onSent = i == total and opts.onSent or nil })
  end
  waitingSig[sig] = true
  if recSlot then waitingRecord[recSlot] = id end
  queuedCount = queuedCount + 1
  return id
end
ns.QueueMsg = Queue

-- to the whole guild
function ns.Send(msgType, payload) return Queue(msgType, payload) end

-- to one member only (addon whisper): for data not everyone may see
function ns.SendTo(target, msgType, payload)
  if target and target ~= ns.MyKey() then return Queue(msgType, payload, { target = target }) end
end

-- to one member using a given spelling of their name (for /fhub ping)
function ns.SendToForm(target, form, msgType, payload)
  if target and form and target ~= ns.MyKey() then return Queue(msgType, payload, { target = target, form = form }) end
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

-- is message `id` still waiting in our queue (not all of it sent, not dropped)?
local function Waiting(id)
  if not id then return false end
  for i = 1, #sendQueue do if sendQueue[i].id == id then return true end end
  return false
end

-- has part of message `id` gone out, and part not yet?
local function Started(id) return id ~= nil and startedIds[id] == true end

-- drop what's left of message `id` (even part way out: its whisper failed)
local function Cancel(id)
  if not id then return end
  for i = #sendQueue, 1, -1 do
    local item = sendQueue[i]
    if item.id == id then
      table.remove(sendQueue, i)
      if item.sig then waitingSig[item.sig] = nil end
      if item.recKey and waitingRecord[item.recKey] == id then waitingRecord[item.recKey] = nil end
    end
  end
  startedIds[id], sentForm[id], partAt[id] = nil, nil, nil
end

------------------------------------------------------------------------
-- Higher level messages
--
-- Our own record. What we send is always its canonical text (Encode.lua
-- Enc.Canon), with its checksum (Hash.lua), worked out again only when the
-- text changes:
--   own.ts / own.text / own.hash  the version last worked out (Own.Refresh)
--   own.base    { ts, text, hash }: the version the guild holds, as far as we
--               know (our hello's, then each record or delta of ours that
--               started going out). Deltas (T) are edits to it. Kept in memory
--               only: after a /reload it's the hello's version again.
--   own.queued  { ver, id, full }: our last record or delta queued (ver: its
--               version, id: the message, full: an F rather than a T)
------------------------------------------------------------------------
local own = {}
local ownJob -- the checksum being worked out: { text, ts, cbs }
function ns.OwnState() return own end

-- cb({ ts, text, hash }) with our record's current version, once its checksum
-- is known (at once when nothing changed)
local function OwnRefresh(cb)
  local rec = ns.MyRecord()
  if not rec then return end
  local text = Enc.Canon(Enc.EncodeRecord(rec))
  if not text then return end
  -- the record changed without its time moving on (changed in place): move it
  -- on, so two different versions never share a time
  if own.text and text ~= own.text and (rec.ts or 0) == own.ts then
    rec.ts = math.max(ns.Now(), own.ts + 1)
    text = Enc.Canon(Enc.EncodeRecord(rec))
  end
  if text == own.text and own.hash then
    cb({ ts = own.ts, text = own.text, hash = own.hash })
    return
  end
  if ownJob and ownJob.text == text then
    ownJob.cbs[#ownJob.cbs + 1] = cb
    return
  end
  -- (a checksum still being worked out for an older text: its callers get this one)
  local job = { text = text, ts = rec.ts or 0, cbs = ownJob and ownJob.cbs or {} }
  if ownJob then ownJob.dead = true end
  job.cbs[#job.cbs + 1] = cb
  ownJob = job
  ns.Hash.Queue(text, function(h)
    if job.dead then return end
    ownJob = nil
    own.ts, own.text, own.hash = job.ts, job.text, h
    for _, fn in ipairs(job.cbs) do
      local ok, err = pcall(fn, { ts = job.ts, text = job.text, hash = h })
      if not ok then ns.ReportError(err) end
    end
  end, true)
end
ns.OwnRefresh = OwnRefresh

-- "<PROTOCOL>^<VERSION>^<ts36>^<h16>^<sums>": our record's version and
-- checksum, and the bucket sums of every record we hold (Catchup.lua
-- C.HelloSums; "" when unknown), which let a member whose sums are the same
-- as their relays' skip their catch-up request (D)
local function HelloPayload(sums)
  local ts, h = own.ts, own.hash
  -- (checksums can't be worked out on this computer, see Hash.lua: none announced)
  if ns.Hash.broken then h, sums = nil, nil end
  if not h then
    local rec = ns.MyRecord()
    ts, h = rec and rec.ts or 0, ""
  end
  local text = table.concat({ ns.PROTOCOL, ns.VERSION, Enc.ToB36(ts), h, sums or "" }, "^")
  -- (one part: about 175 characters with a 16-character version, so this
  -- can't happen; if it ever did, the sums go)
  if #text > CHUNK then text = table.concat({ ns.PROTOCOL, ns.VERSION, Enc.ToB36(ts), h, "" }, "^") end
  return text
end

-- Our hello (H) or reply to hellos (R), once the checksums still being worked
-- out are done (the sums count them)
local function QueueHello(msgType, opts)
  local C = ns.Catchup
  local function Go(sums) Queue(msgType, HelloPayload(sums), opts) end
  if C and C.HelloSums then C.HelloSums(Go) else Go(nil) end
end

-- Sends our record: a delta (T) from own.base when that's small, else whole
-- (F). forceFull: whole (someone asked for it, or a correction).
local CHUNK_PARTS_T = 3 -- a delta over this many parts goes as the whole record
local function SendOwn(forceFull)
  local me = ns.MyKey()
  if not me then return end
  ns.MirrorMyRecord()
  OwnRefresh(function(cur)
    local slot = "\1" .. me
    local q = own.queued
    local waiting = q and q.id ~= nil and waitingRecord[slot] == q.id
    -- what we queued last has started going out: the guild holds that version now
    if q and not waiting then own.base, own.queued, q = q.ver, nil, nil end
    -- this version is already waiting to go out whole
    if q and q.full and q.ver.hash == cur.hash then return end
    if not forceFull then
      -- nothing new: what's waiting (or the version everyone holds) is this one
      if q and q.ver.hash == cur.hash then return end
      if not q and own.base and own.base.hash == cur.hash and own.base.ts == cur.ts then return end
    end
    -- (a whole record still waiting goes whole again: whoever asked for it
    -- may not hold the base)
    -- (deltas carry checksums: with none worked out here, always whole)
    local full = forceFull or (q and q.full) or ns.guildMuted or not own.base or own.base.ts >= cur.ts
      or ns.Hash.broken
    local p = not full and Enc.EncodeDelta(own.base, cur, me)
    if p and not (#p <= CHUNK_PARTS_T * CHUNK and #p < #cur.text / 2) then p = nil end
    local id
    if p then
      id = Queue("T", p, { recKey = me, front = "after" })
    else
      id = Queue("F", cur.text, { recKey = me })
    end
    own.queued = { ver = cur, id = id, full = not p }
  end)
end
ns.SendOwn = SendOwn

-- text: the record already encoded. Our own record goes through SendOwn
-- (always its canonical text, and the delta base moves with it).
function ns.BroadcastRecord(rec, text)
  if not rec then return end
  if rec.key == ns.MyKey() and rec == ns.MyRecord() then return SendOwn(true) end
  Queue("F", text or Enc.EncodeRecord(rec), { recKey = rec.key })
end

-- Debounced broadcast of our own record after it changes.
local ownPending = false
function ns.QueueOwnBroadcast(delay)
  if not started then return end
  if ownPending then return end
  ownPending = true
  C_Timer.After(delay or 8, function()
    ownPending = false
    SendOwn(false)
  end)
end

-- One online member answers each feature digest so the guild isn't flooded:
-- the alphabetically first FableHub user who is online, not counting the
-- asker. (Records catch-up names its own relays, see Catchup.lua.)
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

-- The members whose second-hand copies we take for our catch-up of kind `d`
-- (a DIGESTS letter; "D", records, when left out): { [key] = true }. While
-- our records catch-up runs (Catchup.lua), the relays it named for it.
-- Otherwise the member who answers (BestRelay) and the next in line, in case
-- our view of who's online differs a little from theirs; for records leaving
-- out members caught sending wrong copies this session.
function ns.RelaySet(d)
  d = d or "D"
  local C = ns.Catchup
  if d == "D" and C and C.Active() then return C.Relays() end
  local me = ns.MyKey()
  local bad = d == "D" and C and C.IsBad or nil
  local function ok(key) return not (bad and bad(key)) end
  local set = {}
  local first = BestRelay(me, ok)
  if first then
    set[first] = true
    local second = BestRelay(me, function(key) return key ~= first and ok(key) end)
    if second then set[second] = true end
  end
  return set
end

-- Is `sender` in that set? Second-hand copies of other people's data that
-- aren't from an officer are only taken from them. nil = we haven't heard
-- their hello yet, so we can't tell (while our records catch-up runs, a
-- member it didn't name just isn't one: false).
function ns.IsMyRelay(sender, d)
  d = d or "D"
  local C = ns.Catchup
  if d == "D" and C and C.Active() then return C.Relays()[sender] == true end
  if not ns.present[sender] then return nil end
  return ns.RelaySet(d)[sender] == true
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
-- [digest type] = GetTime() our relay's answer of that kind was last accepted
-- (RelayGate said yes, or a held one was replayed; see AutoResync)
local relayAnsweredAt = {}

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

-- RelayActive runs for every part of every message: the relay sets it needs
-- are worked out once per moment (GetTime() value) and kind, and again after
-- a hello or a roster change
local setCacheAt, setCache = nil, {}
local function DropRelayCache() setCacheAt = nil end
ns.On("ROSTER_CHANGED", DropRelayCache)
local function IsMyRelayCached(sender, d)
  local C = ns.Catchup
  if d == "D" and C and C.Active() then return C.Relays()[sender] == true end
  if not ns.present[sender] then return nil end
  local now = GetTime()
  if setCacheAt ~= now then setCacheAt, setCache = now, {} end
  local set = setCache[d]
  if not set then
    set = ns.RelaySet(d)
    setCache[d] = set
  end
  return set[sender] == true
end

-- we heard from `sender` as (possibly) our relay: their windows still open
-- stay open CATCHUP_WINDOW seconds more (each kind they may be our relay for:
-- yes, or not known yet)
local function RelayActive(sender)
  if not sender or GetTime() - lastDigestAt > CATCHUP_MAX then return end
  local closes = GetTime() + CATCHUP_WINDOW
  local u = relayUntil[sender]
  for d in pairs(DIGESTS) do
    if CatchUpOpen(d, sender) and IsMyRelayCached(sender, d) ~= false then
      if not u then u = {}; relayUntil[sender] = u end
      if (u[d] or 0) < closes then u[d] = closes end
    end
  end
end

function ns.RelayGate(sender, digestType, replay)
  if type(sender) ~= "string" or IsLoose(sender) then return false end
  if ns.Plans and ns.Plans.IsOfficer(sender) then
    -- (an officer who is also our relay: still answering our catch-up)
    if CatchUpOpen(digestType, sender) and ns.IsMyRelay(sender, digestType) then relayAnsweredAt[digestType] = GetTime() end
    return true
  end
  if not CatchUpOpen(digestType, sender) then return false end
  local relay = ns.IsMyRelay(sender, digestType)
  if relay then
    relayAnsweredAt[digestType] = GetTime()
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

-- `sender`'s hello arrived: run their waiting replays of each kind they're
-- our relay for, drop those of kinds they aren't (still unknown: keep waiting)
local function FlushReplays(sender)
  if not sender then return end
  -- (windows kept open for them before their hello, see OnAddonMessage)
  local u = relayUntil[sender]
  if u then
    for d in pairs(u) do
      if ns.IsMyRelay(sender, d) == false then u[d] = nil end
    end
  end
  local list = pendingReplays[sender]
  if not list then return end
  local keep, run, dropped = {}, {}, 0
  for _, e in ipairs(list) do
    local relay = ns.IsMyRelay(sender, e.dig)
    if relay == nil then keep[#keep + 1] = e
    elseif relay then run[#run + 1] = e
    else dropped = dropped + 1 end
  end
  pendingReplays[sender] = keep[1] and keep or nil
  if dropped > 0 then ns.Debug(("dropped %d catch-up messages from %s (not our relay)"):format(dropped, sender)) end
  local r1, r2, r3, r4 = ns.receiving, ns.receivingPayload, ns.receivingSender, ns.receivingLoose
  for _, e in ipairs(run) do
    if CatchUpOpen(e.dig, sender) then
      relayAnsweredAt[e.dig] = GetTime()
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
local lastReplyAt = -1     -- GetTime() we last queued a reply (R)
local wantedRecently = {}   -- [key] = GetTime() when we decided to ask for it
local wantSeen = {}         -- [key] = GetTime() when someone else asked for it
local answeredWant = 0
local wantFrom = {}         -- [requester] = GetTime() we last re-sent our record for their W
local reassertFrom = {}     -- [sender] = GetTime() their digest or record copy last made us reassert our record
-- the message being handled came from a sender resolved exactly to the roster
-- (ResolveSender's "exact"); set by OnAddonMessage
local receivingExact = false
local presentProto = {}     -- [key] = the sync protocol their latest hello gave
local helloExact = {}       -- [key] = their latest hello came from their exact name
local ownerHeardAt = {}     -- [key] = GetTime() we last took their own checksum from their hello
-- what their latest hello told us: protocol, whether it came from their exact
-- name, and when we last took their own checksum from one (nil: never)
function ns.HelloInfo(key) return presentProto[key], helloExact[key], ownerHeardAt[key] end

------------------------------------------------------------------------
-- Owners' checksums (Core.lua g.owner): the version and checksum each
-- character's owner last announced first-hand (their hello, record or
-- delta, from their exact name). Never taken from anyone passing it on.
------------------------------------------------------------------------
local MAX_TS = 4294967296
local function ValidHash(h) return type(h) == "string" and #h == 16 and h:find("^[0-9a-f]+$") ~= nil end

-- the owner's announced version of `key`: ts, hash (nil if none)
local function OwnerHash(key, g)
  g = g or ns.GuildDB()
  local v = g and g.owner and g.owner[key]
  if type(v) ~= "string" then return nil end
  local ts36, h = v:match("^(%w+):(%x+)$")
  local ts = Enc.Num(ts36, MAX_TS)
  if not ts or not ValidHash(h) then return nil end
  return ts, h
end
ns.OwnerHash = OwnerHash

-- replaced only by the same or a newer version (roster members only);
-- force: the owner's own whole record, which is their latest word even when
-- older (see HandleFull)
local function SetOwnerHash(key, ts, h, force)
  local g = ns.GuildDB()
  if not g or not key or key == ns.MyKey() or not ValidHash(h) or type(ts) ~= "number" then return end
  if next(ns.roster) and not ns.roster[key] then return end
  local cur = OwnerHash(key, g)
  if cur and cur > ts and not force then return end
  g.owner[key] = Enc.ToB36(ts) .. ":" .. h
end

-- the owner is online and we took their checksum from their hello this
-- session (their word on their version is current)
local function OwnerLive(key)
  return ownerHeardAt[key] ~= nil and ns.IsOnline(key)
end

-- The checksum a copy of `key`'s version `ts` must have: the owner's, when
-- that's the version they announced; else what a records catch-up expects
-- from `sender` (Catchup.lua, when loaded). nil: nothing to check against
-- (always, when checksums can't be worked out here: Hash.lua H.broken).
local function ExpectedHash(key, ts, sender)
  if ns.Hash.broken then return nil end
  local ots, oh = OwnerHash(key)
  if ots == ts then return oh end
  local C = ns.Catchup
  if C and C.Expect then return C.Expect(key, ts, sender) end
  return nil
end
ns.ExpectedHash = ExpectedHash

-- A member left the guild (Cleanup.lua): forget what the sync code keeps
-- about them (catch-up state too, when Catchup.lua is loaded)
function ns.ForgetMemberSync(key, g)
  g = g or ns.GuildDB()
  if g and g.owner then g.owner[key] = nil end
  presentProto[key], helloExact[key], ownerHeardAt[key] = nil, nil, nil
  local C = ns.Catchup
  if C and C.Forget then
    local ok, err = pcall(C.Forget, key, g)
    if not ok then ns.ReportError(err) end
  end
end
ns.On("MEMBERS_FORGOTTEN", function(keys)
  local g = ns.GuildDB()
  for _, key in ipairs(type(keys) == "table" and keys or {}) do ns.ForgetMemberSync(key, g) end
end)

-- Our reply to hellos heard at or after `since` (one reply on the guild
-- channel answers everyone who said hello before it). It goes ahead of
-- everything waiting ("after" the message being sent): members only name
-- us for their catch-up once they heard it (Catchup.lua).
local function SendReply(since)
  if lastReplyAt >= since then return end
  lastReplyAt = GetTime()
  QueueHello("R", { front = "after" })
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
-- hash: the owner's checksum of that version: our copy of the same version
-- is wanted too when its checksum differs (a wrong copy)
-- force: ask even when we hold that version or a newer one (two copies of
-- one version and nothing to tell which is right; or the owner says they
-- have an older one than ours): only the owner's own record settles it.
-- Then only a copy of that version with checksum `hash` (when given) counts.
local WANT_WAIT = 8
local function WantIfStill(key, theirTs, scheduled, waited, hash, force)
  local g = ns.GuildDB()
  local have = g and g.members[key]
  if have then
    local ts = have.ts or 0
    if force then
      if ts == theirTs and hash and have.hash == hash then return end
    else
      if ts > theirTs then return end
      if ts == theirTs and (not hash or not have.hash or have.hash == hash) then return end
    end
  end
  if not waited and (wantSeen[key] or 0) >= scheduled then
    C_Timer.After(WANT_WAIT, function() WantIfStill(key, theirTs, scheduled, true, hash, force) end)
    return
  end
  ns.Send("W", key)
end

-- Every W we send goes through here: each key at most once per WANT_GAP
-- seconds (also after someone else asked for it, see HandleWant), after a
-- small random delay so several members don't all ask at once (whoever asks
-- first, the others wait for the owner's answer to them: WantIfStill).
local WANT_GAP = 30
local function Want(key, theirTs, hash, force)
  if not key or key == ns.MyKey() or type(theirTs) ~= "number" then return end
  local t = wantedRecently[key]
  if t and GetTime() - t < WANT_GAP then return end
  local scheduled = GetTime()
  wantedRecently[key] = scheduled
  C_Timer.After(1 + math.random() * 3, function() WantIfStill(key, theirTs, scheduled, false, hash, force) end)
end

local function HandleHello(sender, payload, isReply)
  local f = Enc.Split(payload, "^")
  local proto = tonumber(f[1]) or 0
  -- Only the name the game gives us counts, as we resolved it (so nobody can
  -- be noted as present, or as running some version, under someone else's
  -- name). Versions only count from senders matched exactly to the roster
  -- (see VersionConfirmed).
  -- A version that isn't "1.2" / "1.2.3" (at most 16 characters) is
  -- ignored: it's shown in the UI and compared.
  local ver = f[2]
  if ver and (#ver > 16 or not ver:match("^%d+%.%d+%.?%d*$")) then ver = nil end
  ns.present[sender] = ver or "?"
  if receivingExact and ver then NoteVersion(sender, ver) end
  local g = ns.GuildDB()
  if g then
    g.addonUsers[sender] = { version = ver, seen = ns.Now() }
  end
  presentProto[sender] = proto
  helloExact[sender] = receivingExact
  DropRelayCache()
  -- catch-up answers of theirs that arrived before this hello (see RelayGate)
  FlushReplays(sender)
  if proto ~= ns.PROTOCOL then return end

  -- their own record's version and checksum: the owner's word on it (only
  -- from their exact name, never one matched by first name)
  local theirTs = Enc.Num(f[3], MAX_TS) or 0
  local theirHash = f[4]
  local announced = receivingExact and not IsLoose(sender) and theirTs > 0 and ValidHash(theirHash)
    and ns.TimeOK(theirTs)
  if announced then
    SetOwnerHash(sender, theirTs, theirHash)
    ownerHeardAt[sender] = GetTime()
  end
  -- their bucket sums (Catchup.lua: when every relay a catch-up picks has the
  -- same sums as ours, it needs no D). Only from their exact name.
  local C = ns.Catchup
  if C and C.NoteHelloSums and receivingExact and not IsLoose(sender) then C.NoteHelloSums(sender, f[5]) end

  -- do we need their record? (newer than ours, or ours of that version is
  -- a wrong copy)
  local have = g and g.members[sender]
  -- a summary of theirs newer than the version they say they have is wrong
  -- (the owner is the authority on that): dropped, unless our whole copy is
  -- newer still (then it's the hello that's out of date)
  local part = g and g.partials and g.partials[sender]
  if receivingExact and part and theirTs > 0 and theirTs < (part.ts or 0)
    and (not have or (have.ts or 0) <= theirTs) then
    g.partials[sender] = nil
    ns.Debug(("dropped a summary of %s newer than their own record"):format(sender))
  end
  local wrongCopy = announced and have and (have.ts or 0) == theirTs and have.hash and have.hash ~= theirHash
  if theirTs > 0 and (not have or (have.ts or 0) < theirTs or wrongCopy) then
    Want(sender, theirTs, announced and theirHash or nil)
  elseif announced and have and (have.ts or 0) > theirTs then
    -- ours claims to be newer than what the owner has: a forgery, or data
    -- from another computer of theirs. Their own record replaces it.
    Want(sender, theirTs, theirHash, true)
  end

  -- answer each member's hello at most 3 times in 5 minutes: enough for a
  -- /reload or two (a reloaded client needs our reply to know we're here),
  -- but a repeated hello can't make every FableHub user reply every time
  if not isReply then
    local now, a = GetTime(), helloAnswered[sender]
    if not a or now - a.t > 300 then a = { t = now, n = 0 }; helloAnswered[sender] = a end
    local heard = GetTime()
    if a.n < 3 then
      a.n = a.n + 1
      C_Timer.After(1 + math.random() * 4, function() SendReply(heard) end)
    end
  end
  -- a records catch-up waiting for someone to answer it (Catchup.lua)
  if C and C.OnHello then
    local ok, err = pcall(C.OnHello, sender)
    if not ok then ns.ReportError(err) end
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
      SendOwn(true)
    end
  end
end

-- someone sent a newer "copy" of our own record than we have (a forgery, or
-- stale data from another client): make ours newer and send it again, so the
-- real one wins everywhere. Counts toward the answer budget (when it's used
-- up, the re-send waits for the next minute).
-- At most one re-send every REASSERT_GAP seconds in all: re-sends asked for
-- meanwhile are one, sent when that time is up.
local REASSERT_GAP = 30
local reasserting = false
local lastReassertAt = -1e9
local function ReassertMine(theirTs)
  local mine = ns.MyRecord()
  if not mine then return end
  if (mine.ts or 0) <= theirTs then mine.ts = theirTs + 1 end
  if reasserting then return end -- already on its way (it reads the record when it goes)
  reasserting = true
  local delay = math.max(3, REASSERT_GAP - (GetTime() - lastReassertAt))
  if OverBudget(nil) then delay = math.max(delay, 61 - (GetTime() - answerWindow)) end
  C_Timer.After(delay, function()
    reasserting = false
    lastReassertAt = GetTime()
    CountAnswer(nil)
    SendOwn(true)
  end)
end
ns.ReassertMine = ReassertMine

-- ReassertMine because of `sender`'s catch-up answer or record copy: for our
-- relay or an officer (not matched only by first name) at most once a minute
-- each; anyone else at most once per 5 minutes each (or one member sending
-- everyone's records or a digest with a future time could make every client
-- re-send its record every 20 seconds)
local function ReassertFor(sender, theirTs)
  local trusted = not IsLoose(sender) and (ns.IsMyRelay(sender, "D") or ns.Plans.IsOfficer(sender))
  local now = GetTime()
  if reassertFrom[sender] and now - reassertFrom[sender] < (trusted and 60 or 300) then return end
  reassertFrom[sender] = now
  ReassertMine(theirTs)
end

local summariesHeard = 0 -- summaries we stored (for /fhub bug)

-- Our own record, as someone else sent it: a newer "copy", or one of our
-- version that isn't exactly ours (its canonical text differs), gets
-- corrected. Throttled per sender like a digest's (ReassertFor).
local function OwnCopyCheck(sender, rec)
  local mine = ns.MyRecord()
  if not mine then return end
  local ts = mine.ts or 0
  if rec.ts > ts or (rec.ts == ts and Enc.EncodeRecord(rec) ~= Enc.Canon(Enc.EncodeRecord(mine))) then
    ReassertFor(sender, rec.ts)
  end
end

-- the longest record (canonical text) we take: one that still goes out as a
-- single F (MAX_PARTS below), so every record we hold can be passed on
local MAX_RECORD = MAX_RECORD_PARTS * CHUNK

-- deltas (T): at most one tried per owner every DELTA_GAP seconds; after one
-- failed, none until a whole record of theirs is stored (see HandleDelta)
local DELTA_GAP = 5
local lastDeltaAt = {}   -- [key] = GetTime() we last tried one of theirs
local deltaBlocked = {}  -- [key] = true: one of theirs failed, waiting for their whole record

local function TellArrived(key, held, sender)
  local C = ns.Catchup
  if C and C.Arrived then
    local ok, err = pcall(C.Arrived, key, held, sender)
    if not ok then ns.ReportError(err) end
  end
end

-- hash `text` for intake (key: one job per character waiting, see H.Queue);
-- with the queue full, once it has drained. Keys: "own:" .. character for
-- the owner's own record or delta, "in:" .. character for a copy passed on
-- by a relay or officer, "sh:" .. character for one heard from anyone else
-- (C.Shared): a copy passed on never replaces the owner's own job, or the
-- other way round.
local function HashLater(text, fn, key)
  if ns.Hash.Queue(text, fn, false, key) then return end
  ns.Hash.WhenIdle(function() ns.Hash.Queue(text, fn) end)
end

-- Stores a record that passed its checks: h = its checksum when already
-- worked out (else it's worked out after), firstHand = from its owner (then
-- the checksum is the owner's announcement too, and it replaces our copy
-- even when ours claims to be newer). A copy of the version we hold
-- replaces ours only when it differs (ours was a wrong copy: the caller
-- checked the new one). Tells Catchup.lua, when loaded, that it arrived.
local function StoreChecked(rec, h, firstHand, sender, canon)
  local g = ns.GuildDB()
  if not g then return end
  local key = rec.key
  local have = g.members[key]
  -- (something newer may have come while the checksum was worked out)
  if have and (have.ts or 0) > rec.ts and not firstHand then return end
  canon = canon or Enc.EncodeRecord(rec)
  local stored, identical = false, false
  if have and (have.ts or 0) == rec.ts then
    local differs
    if h and have.hash then differs = have.hash ~= h else differs = Enc.EncodeRecord(have) ~= canon end
    if differs then stored = ns.StoreRecord(rec, { replace = true }) else identical = true end
  elseif have and (have.ts or 0) > rec.ts then
    stored = ns.StoreRecord(rec, { force = true })
    ns.Debug(("%s's own record replaced a copy claiming to be newer"):format(key))
  else
    stored = ns.StoreRecord(rec)
  end
  if firstHand and (stored or identical) then deltaBlocked[key] = nil end
  local held = g.members[key]
  -- the record we now hold has this text: it gets the checksum
  local target = (held == rec or identical) and held or nil
  -- (no checksums at all when they can't be worked out here)
  if ns.Hash.broken then target = nil end
  if h then
    if target then target.hash = h end
    if firstHand then SetOwnerHash(key, rec.ts, h, true) end
  elseif target or firstHand then
    if target and identical and target.hash then
      -- (the same text: the same checksum, nothing to work out)
      if firstHand then SetOwnerHash(key, rec.ts, target.hash, true) end
    elseif not ns.Hash.broken then
      HashLater(canon, function(hh)
        if target and g.members[key] == target then target.hash = hh end
        if firstHand then SetOwnerHash(key, rec.ts, hh, true) end
      end, (firstHand and "own:" or "in:") .. key)
    end
  end
  if stored then ns.Debug("stored " .. key .. " (from " .. tostring(sender) .. ")") end
  if held and held.ts == rec.ts then TellArrived(key, held, sender) end
end
ns.StoreChecked = StoreChecked

-- A copy passed on by someone else whose checksum isn't what the owner (or
-- the catch-up's relays) said: refused. A summary of that version goes too
-- (it came the same way). Catchup.lua, when loaded, deals with the relay;
-- otherwise we ask the owner, if online, for the real one.
local function BadCopy(sender, rec, exp)
  local g = ns.GuildDB()
  local key = rec.key
  local part = g and g.partials[key]
  if part and (part.ts or 0) == rec.ts then g.partials[key] = nil end
  ns.Debug(("refused %s's record from %s: checksum doesn't match"):format(key, tostring(sender)))
  local C = ns.Catchup
  if C and C.BadCopy then
    local ok, err = pcall(C.BadCopy, sender, key, rec.ts, exp)
    if not ok then ns.ReportError(err) end
  elseif ns.IsOnline(key) then
    Want(key, rec.ts, exp)
  end
end

-- a passed-on copy (record or summary) of `key` version `ts` from an
-- officer: a version newer than the one its owner, online, told us they
-- have is made up
local function OfficerCopyOK(key, ts)
  local ots = OwnerHash(key)
  return not (ots and ts > ots and OwnerLive(key))
end

-- An officer may pass records on any time (checked against the owner's
-- checksum, see HandleFull). Anyone else only for our records catch-up:
-- CatchupAccepts gives the checksum Catchup.lua expects for that version
-- from them (nil: not expected from them). CatchupShared: the same for a
-- whole record from any guild member by their exact name (not one of our
-- relays), checked against that checksum and dropped when it differs.
local function IsOfficerSender(sender)
  return not IsLoose(sender) and ns.Plans ~= nil and ns.Plans.IsOfficer(sender) == true
end
local function CatchupAccepts(sender, key, ts)
  local C = ns.Catchup
  if IsLoose(sender) or not (C and C.Accepts) then return nil end
  return C.Accepts(sender, key, ts)
end
local function CatchupShared(sender, key, ts)
  local C = ns.Catchup
  if not receivingExact or IsLoose(sender) or ns.Hash.broken or not (C and C.Shared) then return nil end
  return C.Shared(key, ts)
end

-- the owner's own record (from their exact name): the authority on it. It
-- replaces our copy even when ours claims to be newer (that one is a
-- forgery, or data from another computer of theirs).
local function HandleOwnersRecord(sender, rec, canon)
  local g = ns.GuildDB()
  local have = g.members[rec.key]
  if have and (have.ts or 0) == rec.ts and have.hash and not ns.Hash.broken and Enc.EncodeRecord(have) == canon then
    -- the copy we hold, again: nothing to store or work out
    SetOwnerHash(rec.key, rec.ts, have.hash, true)
    deltaBlocked[rec.key] = nil
    TellArrived(rec.key, have, sender)
    return
  end
  StoreChecked(rec, nil, true, sender, canon)
end

-- Who may change a character record:
--   * the owner (sender == rec.key, by their exact name) may always send
--     their own record;
--   * a copy passed on by someone else is how records of members who are
--     offline reach people. From a member, it's only taken while our records
--     catch-up (Catchup.lua) expects exactly that version of that character,
--     with the checksum it expects: from one of its relays (a wrong one gets
--     the relay replaced), or heard from anyone else in the guild by their
--     exact name (someone else's catch-up answer: a wrong one is dropped); from an
--     officer any time, checked against the owner's checksum for that version
--     when we know it, and never newer than the version the owner, online,
--     told us they have. Such a copy may fill in a record we don't have,
--     replace an older copy, or replace our copy of the same version when
--     that copy is wrong (its checksum isn't the one expected);
--   * anyone else's copies of other people's records are ignored, so a member
--     can't rewrite (or invent) someone else's professions.
-- A relay matched to the roster only by first name (see LooseSender) isn't trusted.
local function HandleFull(sender, payload)
  local rec = Enc.DecodeRecord(payload)
  if not rec or not ns.TimeOK(rec.ts) then return end
  if rec.key == ns.MyKey() then return OwnCopyCheck(sender, rec) end
  -- only guild members (stops made-up members piling up in everyone's saved data)
  if next(ns.roster) and not ns.roster[rec.key] then return end
  local g = ns.GuildDB()
  if not g then return end
  local key = rec.key
  local canon = Enc.EncodeRecord(rec)
  if #canon > MAX_RECORD then return end
  -- (a sender matched only by first name isn't taken as the owner: see LooseSender)
  if sender == key and receivingExact and not IsLoose(sender) then
    return HandleOwnersRecord(sender, rec, canon)
  end
  local exp, shared
  if IsOfficerSender(sender) then
    if not OfficerCopyOK(key, rec.ts) then return end
    exp = ExpectedHash(key, rec.ts, sender)
  else
    exp = CatchupAccepts(sender, key, rec.ts)
    if exp then
      -- (our relay answering: see AutoResync and ns.CatchUpActive)
      relayAnsweredAt.D = GetTime()
      RelayActive(sender)
    else
      exp = CatchupShared(sender, key, rec.ts)
      if not exp then return end
      -- (the first copy heard is checked; another, from anyone, while it's
      -- waiting is ignored: it mustn't replace that job. Our relays' copies
      -- have jobs of their own, "in:")
      if ns.Hash.Waiting("sh:" .. key) then return end
      shared = true
    end
  end
  local have = g.members[key]
  if have then
    local ts = have.ts or 0
    if ts > rec.ts then return end
    -- the same version: only of use when ours is known to be wrong
    if ts == rec.ts and (not exp or have.hash == exp) then return end
  end
  if ns.Hash.broken then exp = nil end
  if not exp then return StoreChecked(rec, nil, false, sender, canon) end
  -- (with too much waiting to be checked, refused: the catch-up asks again)
  ns.Hash.Queue(canon, function(h)
    if h ~= exp then
      if shared then
        return ns.Debug(("dropped %s's record from %s: checksum doesn't match"):format(key, tostring(sender)))
      end
      return BadCopy(sender, rec, exp)
    end
    StoreChecked(rec, h, false, sender, canon)
  end, false, (shared and "sh:" or "in:") .. key)
end

-- T: an owner's change to their own record (see Enc.EncodeDelta). Only ever
-- first-hand: from the owner's exact name, on our protocol. Applied to our
-- copy when it's the version the change starts from; anything else (we
-- missed one, our copy is wrong, the result's checksum isn't the one
-- announced) makes us ask the owner for the whole record (W), and ignore
-- their deltas until it's here.
local function DeltaFailed(d, why)
  deltaBlocked[d.key] = true
  if why then ns.Debug("a change to " .. d.key .. " " .. why .. ": asking for the whole record") end
  Want(d.key, d.newTs, d.newHash)
end

local function ApplyDelta(d, sender, retried)
  local g = ns.GuildDB()
  if not g then return end
  local key = d.key
  local have = g.members[key]
  if not have or (have.ts or 0) ~= d.baseTs or (have.hash and have.hash ~= d.baseHash) then
    if not have or (have.ts or 0) < d.newTs then DeltaFailed(d) end
    return
  end
  if not have.hash then
    -- our copy's checksum isn't worked out yet: once it is, try again (once)
    if retried then return DeltaFailed(d) end
    HashLater(Enc.EncodeRecord(have), function(h)
      if g.members[key] == have then have.hash = h end
      ApplyDelta(d, sender, true)
    end)
    return
  end
  local text = Enc.ApplyDelta(Enc.EncodeRecord(have), d.ops, d.newTs)
  local rec = text and #text <= MAX_RECORD and Enc.DecodeRecord(text)
  if not rec or rec.key ~= key or rec.ts ~= d.newTs then return DeltaFailed(d, "didn't apply") end
  local canon = Enc.EncodeRecord(rec)
  if #canon > MAX_RECORD then return DeltaFailed(d, "is too big") end
  local job = ns.Hash.Queue(canon, function(h)
    if h ~= d.newHash then return DeltaFailed(d, "gave the wrong checksum") end
    StoreChecked(rec, h, true, sender, canon)
  end, false, "own:" .. key)
  -- (too much waiting to be checked: the whole record later instead)
  if not job then Want(key, d.newTs, d.newHash) end
end

local function HandleDelta(sender, payload)
  local d = Enc.DecodeDelta(payload)
  if not d or d.key ~= sender or d.key == ns.MyKey() then return end
  if not receivingExact or IsLoose(sender) or presentProto[sender] ~= ns.PROTOCOL then return end
  if not ns.TimeOK(d.newTs) or d.newTs <= d.baseTs then return end
  if next(ns.roster) and not ns.roster[d.key] then return end
  SetOwnerHash(d.key, d.newTs, d.newHash)
  -- (checksums can't be worked out here: their whole record instead)
  if ns.Hash.broken then return Want(d.key, d.newTs, nil) end
  local now = GetTime()
  if deltaBlocked[d.key] or (lastDeltaAt[d.key] and now - lastDeltaAt[d.key] < DELTA_GAP) then
    -- (one failed, or they come too fast: their whole record instead)
    return Want(d.key, d.newTs, d.newHash)
  end
  lastDeltaAt[d.key] = now
  ApplyDelta(d, sender, false)
end

-- E: a batch of summaries (0.25+). Always second-hand (relays send them, never
-- owners), so each summary is taken like a relayed F: from an officer, or
-- from one of our records catch-up's relays for a character and version it
-- expects (never checked: the whole record is). Kept in g.partials until the
-- whole record arrives (Core.lua ns.StoreSummaries).
local function HandleSummary(sender, payload)
  if not next(ns.roster) then return end
  local list = Enc.DecodeSummaryBatch(payload)
  if not list then return end
  local me = ns.MyKey()
  local officer = IsOfficerSender(sender)
  local useful = {}
  for _, rec in ipairs(list) do
    if rec.ts > 0 and ns.TimeOK(rec.ts) then
      if rec.key == me then
        -- a newer "copy" of ours gets corrected, as for F; one of our version
        -- is left alone (a summary leaves out too much to compare)
        local mine = ns.MyRecord()
        if mine and rec.ts > (mine.ts or 0) then ReassertFor(sender, rec.ts) end
      elseif ns.SummaryUseful(rec) then
        local ok
        if officer then ok = OfficerCopyOK(rec.key, rec.ts)
        else ok = CatchupAccepts(sender, rec.key, rec.ts) ~= nil end
        if ok then useful[#useful + 1] = rec end
      end
    end
  end
  if #useful == 0 then return end
  if not officer then
    relayAnsweredAt.D = GetTime()
    RelayActive(sender)
    local C = ns.Catchup
    if C and C.Progress then C.Progress(sender) end
  end
  local n = ns.StoreSummaries(useful)
  summariesHeard = summariesHeard + n
  ns.Debug(("stored %d summaries (from %s)"):format(n, sender))
end
function ns.SummariesHeard() return summariesHeard end

-- Size limits: most messages fit in a few parts; only these can be big.
-- Anything longer is dropped, so nobody can make everyone buffer ~100 KB.
local MAX_PARTS = { F = MAX_RECORD_PARTS, E = 16, T = 8, D = 2, s = 80, x = 40, y = 1,
                    B = 400, Y = 120, A = 30, P = 30, Q = 40, d = 40, t = 30, l = 30, I = 12, G = 12, K = 12 }
local DEFAULT_PARTS = 8
local MAX_BUFFERS = 16 -- half-received messages per sender
local BUFFER_MAX = 900 -- a half-received message is dropped this long after its first part (or its restart)

-- Catch-up requests make the answering member re-send a lot: answer each
-- member's request of a kind at most once per DIGEST_GAP seconds, so a
-- spammed /fhub sync (or a modified client) can't flood the guild channel.
-- (DIGESTS is at the top of the file; the answer budget is above HandleHello.
-- Records catch-up, D, keeps its own limits: see Catchup.lua.)
local DIGEST_GAP = 20
local lastDigest = {}

-- While a lot is already waiting to go out (about 3 minutes' worth), catch-up
-- answers wait their turn instead of piling on more: at launch everyone's data
-- starts empty, and the answers to one login usually cover the next one too.
-- The same when the answer budget (MAX_ANSWERS) is used up.
-- (Records catch-up does the same for its x answers, see Catchup.lua.)
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
  -- (whispers to them keep it open too; with the guild channel muted, only
  -- those reach them)
  local heard = math.max(askedAt, lastSendTo[asker] or -1e9)
  if not ns.guildMuted then heard = math.max(heard, lastGuildSendAt) end
  return now - heard <= CATCHUP_WINDOW - CLOSE_MARGIN
end

-- One held-up answer per member and kind at a time: a repeat request (their
-- /fhub sync) while one waits is ignored (see Dispatch), so it can't start a
-- second answer re-sending everything.
local answerPending = {}  -- [requester#type] = GetTime() their held-up answer started waiting

local Dispatch
local function AnswerCatchUp(sender, msgType, payload, waits, channel, loose, askedAt)
  local k = sender .. "#" .. msgType
  if waits > 0 and not RequesterWindowOpen(sender, askedAt) then
    ns.Debug(("dropped catch-up answer %s for %s (their window closed)"):format(msgType, sender))
    answerPending[k] = nil
    return
  end
  if (#sendQueue > BUSY_QUEUE or OverBudget(sender)) and waits < MAX_WAITS then
    answerPending[k] = answerPending[k] or GetTime()
    C_Timer.After(30, function()
      if ns.IsOnline(sender) then
        AnswerCatchUp(sender, msgType, payload, waits + 1, channel, loose, askedAt)
      else
        answerPending[k] = nil
      end
    end)
    return
  end
  answerPending[k] = nil
  local before = queuedCount
  Dispatch(sender, msgType, payload, true, channel, loose)
  if queuedCount > before then
    answeredAt[sender .. "#" .. msgType] = GetTime()
    CountAnswer(sender)
  end
end

-- the records catch-up messages, handled by Catchup.lua
local CATCHUP_TYPES = { D = "OnD", s = "OnS", x = "OnX", y = "OnY" }
local function HandleCatchup(sender, msgType, payload, channel)
  local C = ns.Catchup
  local fn = C and C[CATCHUP_TYPES[msgType]]
  if fn then fn(sender, payload, channel) end
end

-- channel: "GUILD" or "WHISPER", passed to CommHandlers as a third argument.
-- loose: this message's sender matched the roster only by first name (see
-- ResolveSender); handlers see it as ns.receivingLoose.
function Dispatch(sender, msgType, payload, answering, channel, loose)
  if DIGESTS[msgType] and msgType ~= "D" and not answering then
    local k = sender .. "#" .. msgType
    local now = GetTime()
    if (lastDigest[k] and now - lastDigest[k] < DIGEST_GAP) or (answeredAt[k] and now - answeredAt[k] < ANSWER_GAP)
      or answerPending[k] then
      ns.Debug("ignored repeated catch-up request " .. msgType .. " from " .. sender)
      return
    end
    lastDigest[k] = now
    return AnswerCatchUp(sender, msgType, payload, 0, channel, loose, now)
  end
  -- which message is being handled and who sent it (the roster key): the
  -- officer change log (ChangeLog.lua) tells what a "...changed" event fired by
  -- a handler came from, and RelayGate / OfficerSent / FirstHand whether the
  -- sender only matched by first name. (ns.receiving only for feature
  -- messages: the change log has nothing to note for core ones.)
  local feature = ns.CommHandlers[msgType]
  local core = msgType == "H" or msgType == "R" or msgType == "W" or msgType == "F" or msgType == "E"
    or msgType == "T" or CATCHUP_TYPES[msgType] ~= nil
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
  elseif msgType == "F" then ok, err = pcall(HandleFull, sender, payload)
  elseif msgType == "E" then ok, err = pcall(HandleSummary, sender, payload)
  elseif msgType == "T" then ok, err = pcall(HandleDelta, sender, payload)
  elseif CATCHUP_TYPES[msgType] then ok, err = pcall(HandleCatchup, sender, msgType, payload, channel)
  else ok, err = pcall(feature, sender, payload, channel) end
  ns.receiving, ns.receivingPayload, ns.receivingSender, ns.receivingLoose = r1, r2, r3, r4
  if not ok then error(err, 0) end
end

function ns.OnAddonMessage(prefix, text, channel, sender)
  if channel ~= "GUILD" and channel ~= "WHISPER" then return end
  if prefix ~= PREFIX then return end
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
  -- (AutoResync only counts answers RelayGate accepted, not this)
  if not loose then
    RelayActive(sender)
    -- (a long s answer still coming in, see Catchup.lua SWaitCheck)
    local C = ns.Catchup
    if C and C.Heard then C.Heard(sender, msgType, channel) end
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
    buf = { total = total, parts = {}, got = 0, t = GetTime(), first = GetTime(), msgType = msgType, restarts = 0 }
    buffers[bkey] = buf
  end
  -- every part must agree on the total, or the message could complete with a gap
  if total ~= buf.total then return end
  -- (dropped a minute after its latest part: a long message takes longer
  -- than that to arrive at about one part a second. Parts we already have
  -- count too: a message held up mid-way goes again from its first part,
  -- see Restart)
  buf.t = GetTime()
  -- (its first part again: the message started over, and gets BUFFER_MAX
  -- from now, twice at most)
  if part == 1 and buf.parts[1] and buf.restarts < 2 then
    buf.restarts = buf.restarts + 1
    buf.first = buf.t
  end
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
-- one second apart so they don't all land at once; the records catch-up
-- (Catchup.lua) a few seconds after our hello, once the replies to it came
local function SendAllDigests()
  local C = ns.Catchup
  if C and C.Start then
    C_Timer.After(C.START_DELAY or 8, function()
      local ok, err = pcall(C.Start)
      if not ok then ns.ReportError(err) end
    end)
  end
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
-- what our new digests still lack. "Still sending" means an answer of that
-- kind was accepted from it (RelayGate) in the last CATCHUP_WINDOW seconds:
-- other traffic from the relay keeps windows open but doesn't count here, or
-- an active guild would resync about once per login.
local autoResynced = false
local function AutoResync()
  if autoResynced or not started then return end
  local now = GetTime()
  for d, t in pairs(digestSentAt) do
    local age = now - t
    -- (checked every 30 s: two chances in this range, and our digests are
    -- queued within seconds, before the window closes)
    if age >= CATCHUP_MAX - 90 and age < CATCHUP_MAX - 30
        and now - (relayAnsweredAt[d] or -1e9) <= CATCHUP_WINDOW then
      for sender, u in pairs(relayUntil) do
        if (u[d] or 0) >= now and ns.IsMyRelay(sender, d) then
          autoResynced = true
          ns.Debug("catch-up still running near its time limit: asking again")
          SendAllDigests()
          return
        end
      end
    end
  end
end

-- The hello carries our record's checksum, so it waits for that (a frame or
-- two). The version in it is what the guild holds of ours from then on
-- (own.base): members holding an older one ask for it (W).
local function Start()
  if started then return end
  started = true
  ns.ScanAll()
  ns.MirrorMyRecord()
  OwnRefresh(function(cur)
    own.base = cur
    QueueHello("H")
    SendAllDigests()
  end)
end

function ns.CheckGuildEcho()
  if guildEcho or ns.guildMuted or not firstGuildSend then return end
  ns.guildMuted = true
  ns.Debug("no echo from the guild channel: sending by whisper")
  ns.Fire("GUILD_CHANNEL", false)
  -- what we sent so far reached nobody: forget which records we already asked
  -- for (those asks were lost), say hello again and resend our data
  for k in pairs(wantedRecently) do wantedRecently[k] = nil end
  QueueHello("H")
  C_Timer.After(10, function()
    SendOwn(true)
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
  ns.MirrorMyRecord()
  OwnRefresh(function()
    QueueHello("H")
    SendOwn(true)
    SendAllDigests()
  end)
  ns.Print("Sync requested.")
end

function ns.PrintStatus()
  local g = ns.GuildDB()
  local stored, partial, users, online = 0, 0, 0, 0
  if g then
    for _ in pairs(g.members) do stored = stored + 1 end
    for _ in pairs(g.partials or {}) do partial = partial + 1 end
    for _ in pairs(g.addonUsers) do users = users + 1 end
  end
  for key in pairs(ns.present) do if ns.IsOnline(key) then online = online + 1 end end
  ns.Print(("v%s | guild: %s | records: %d | partial: %d | FableHub users seen: %d (%d online now) | queued msgs: %d")
    :format(ns.VERSION, ns.GuildKey() or "none", stored, partial, users, online, #sendQueue))
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
  C_Timer.NewTicker(0.25, Pump)
  -- drop half-received messages a minute after their latest part, and
  -- BUFFER_MAX after their first (a sender can't keep one open for ever)
  C_Timer.NewTicker(30, function()
    local now = GetTime()
    for k, buf in pairs(buffers) do
      if now - buf.t > 60 or now - buf.first > BUFFER_MAX then buffers[k] = nil end
    end
    for k, t in pairs(lastDigest) do if now - t > DIGEST_GAP then lastDigest[k] = nil end end
    for k, t in pairs(answeredAt) do if now - t > ANSWER_GAP then answeredAt[k] = nil end end
    for k, t in pairs(wantFrom) do if now - t > ANSWER_GAP then wantFrom[k] = nil end end
    for k, t in pairs(reassertFrom) do if now - t > 300 then reassertFrom[k] = nil end end
    for k, t in pairs(answerCounted) do if now - t > 120 then answerCounted[k] = nil end end
    for k, t in pairs(lastSendTo) do if now - t > CATCHUP_MAX then lastSendTo[k] = nil end end
    for k, t in pairs(answerPending) do if now - t > CATCHUP_MAX then answerPending[k] = nil end end
    AutoResync()
    ExpireReplays()
  end)
  -- catch-up starting or ending (the sidebar and the Recipes page show its progress)
  local syncActive = false
  C_Timer.NewTicker(2, function()
    local active = ns.CatchUpActive()
    if active ~= syncActive then
      syncActive = active
      ns.Fire("SYNC_STATE", active)
    end
  end)
  TryStart()
end)

ns.RegisterEvent("PLAYER_GUILD_UPDATE", function()
  if IsInGuild() and not started then TryStart() end
end)

ns.RegisterEvent("CHAT_MSG_ADDON", ns.OnAddonMessage)

-- What Catchup.lua (the records catch-up, loaded next) shares with this file
ns.CommInternal = {
  Paused = Paused,
  AfterParts = AfterParts,
  SUMMARY_BATCH = 12 * CHUNK,
  CHUNK = CHUNK,
  BUSY_QUEUE = BUSY_QUEUE,
  MAX_WAITS = MAX_WAITS,
  CATCHUP_MAX = CATCHUP_MAX,
  ANSWER_GAP = ANSWER_GAP,
  TrustedVersion = TrustedVersion,
  IsLoose = IsLoose,
  ReassertFor = ReassertFor,
  Want = Want,
  OwnerLive = OwnerLive,
  BestRelay = BestRelay,
  Waiting = Waiting,
  Started = Started,
  Cancel = Cancel,
  OverBudget = OverBudget,
  CountAnswer = CountAnswer,
  RequesterWindowOpen = RequesterWindowOpen,
  ReceivingExact = function() return receivingExact end,
  RelayAnsweredAt = function(d) return relayAnsweredAt[d or "D"] end,
}
