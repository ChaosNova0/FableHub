-- Events: raid nights, sign-ups and attendance.
--
-- event = { id, title, raid, duration (minutes), anchors = { epoch, ... }, weekly, skips = { [occSuffix] = true },
--           ts, author, deleted }
--   A one-off night has one anchor and weekly = false. A weekly series has one
--   anchor per weekday; occurrence n of anchor a starts at anchors[a] + n weeks.
--   Times are absolute (server epoch), so everyone sees them in their own time zone.
-- occurrence id = "<eventId>@<a>.<n>"
--
-- signups[occId][signerKey] = { status = A|T|L|D|R(removed), char, role, note, ts }
-- attendance[occId] = { min = { [key] = minutes }, ov = { [key] = { v, ts, by } }, ts }

local _, ns = ...
local Enc, P = ns.Encode, ns.Plans
local E = {}
ns.Events = E

local WEEK = 7 * 86400
E.STATUS = { A = "Accepted", L = "Late", T = "Tentative", D = "Declined" }
E.STATUS_ORDER = { A = 1, L = 2, T = 3, D = 4 }
E.RAIDS = { "Barrow Deeps", "Hyjal Summit", "Other" }

------------------------------------------------------------------------
-- Storage
------------------------------------------------------------------------
local function G()
  local g = ns.GuildDB()
  if not g then return nil end
  g.events = g.events or {}
  g.signups = g.signups or {}
  g.attendance = g.attendance or {}
  return g
end
E.G = G

function E.All() local g = G(); return g and g.events or {} end
function E.Get(id) return id and E.All()[id] end

------------------------------------------------------------------------
-- Occurrences
------------------------------------------------------------------------
function E.ParseOcc(occId)
  local id, a, n = tostring(occId or ""):match("^(.-)@(%d+)%.(%d+)$")
  return id, tonumber(a), tonumber(n)
end

-- only the id E.Occurrences itself builds ("<id>@1.0", not "<id>@01.0" or
-- "<id>@1.00"), so one raid night can't be signed up to under many ids
function E.Occ(occId)
  local id, a, n = E.ParseOcc(occId)
  if not a or id .. "@" .. tostring(a) .. "." .. tostring(n) ~= occId then return nil end
  local ev = E.Get(id)
  if not ev or ev.deleted or not ev.anchors[a] then return nil end
  if n > 0 and not ev.weekly then return nil end
  local start = ev.anchors[a] + n * WEEK
  return { id = occId, event = ev, start = start, finish = start + (ev.duration or 180) * 60,
           skipped = ev.skips[a .. "." .. n] and true or false }
end

-- all occurrences overlapping [from, to], sorted by start
function E.Occurrences(from, to, includeSkipped)
  local out = {}
  for id, ev in pairs(E.All()) do
    if not ev.deleted then
      for a, anchor in ipairs(ev.anchors) do
        local first, last = 0, 0
        if ev.weekly then
          first = math.max(0, math.floor((from - anchor - (ev.duration or 180) * 60) / WEEK))
          last = math.floor((to - anchor) / WEEK)
        end
        for n = first, last do
          local occ = E.Occ(id .. "@" .. a .. "." .. n)
          if occ and occ.finish >= from and occ.start <= to and (includeSkipped or not occ.skipped) then
            out[#out + 1] = occ
          end
        end
      end
    end
  end
  table.sort(out, function(x, y) return x.start < y.start end)
  return out
end

function E.Active(now)
  now = now or ns.Now()
  for _, occ in ipairs(E.Occurrences(now - 6 * 3600, now + 3600)) do
    if now >= occ.start - 15 * 60 and now <= occ.finish + 15 * 60 then return occ end
  end
end

------------------------------------------------------------------------
-- Editing (officers)
------------------------------------------------------------------------
local counter = 0
function E.Save(ev)
  if not P.CanEdit("raids") then return nil end
  if not ev.id then
    counter = counter + 1
    ev.id = "e" .. Enc.ToB36(ns.Now()) .. Enc.ToB36(math.random(0, 1295)) .. counter
  end
  ev.skips = ev.skips or {}
  ev.ts = ns.Now()
  ev.author = ns.MyKey()
  local isNew = E.All()[ev.id] == nil
  E.All()[ev.id] = ev
  if isNew and not ev.deleted then ns.Fire("EVENT_SCHEDULED", ev) end
  ns.Send("V", E.EncodeEvent(ev))
  ns.Fire("EVENTS_CHANGED")
  return ev
end

function E.Delete(ev)
  ev.deleted = true
  return E.Save(ev)
end

function E.Skip(occId)
  local id, a, n = E.ParseOcc(occId)
  local ev = E.Get(id)
  if not ev then return end
  ev.skips[a .. "." .. n] = true
  return E.Save(ev)
end

------------------------------------------------------------------------
-- Sign-ups
------------------------------------------------------------------------
function E.Signups(occId)
  local g = G()
  return g and g.signups[occId] or {}
end

function E.MySignup(occId)
  local mine = E.Signups(occId)
  local me = mine[ns.MyKey()]
  if me and me.status ~= "R" then return me end
  -- signed up from one of my other characters?
  for key, s in pairs(mine) do
    if FableHubDB.chars[key] and s.status ~= "R" then return s, key end
  end
end

local function EncodeSignup(occId, signer, s)
  local Safe = function(v) return (tostring(v or ""):gsub("[%^]", " ")) end
  -- field 9: where the sign-up came from (hidden; "rh" = Raid-Helper import, empty = in game)
  return table.concat({ "1", Safe(occId), Safe(signer), Enc.ToB36(s.ts), s.status, Safe(s.char), s.role or "", Safe(s.note),
                        s.src or "" }, "^")
end
E.EncodeSignup = EncodeSignup

function E.SignUp(occId, status, char, role, note)
  local g = G()
  if not g or not E.Occ(occId) then return end
  g.signups[occId] = g.signups[occId] or {}
  local me = ns.MyKey()
  -- one sign-up per player: withdraw any from my other characters
  for key, s in pairs(g.signups[occId]) do
    if key ~= me and FableHubDB.chars[key] and s.status ~= "R" then
      s.status, s.ts = "R", ns.Now()
      ns.Send("S", EncodeSignup(occId, key, s))
    end
  end
  local cur = g.signups[occId][me]
  local s = { status = status, char = char or me, role = role, note = (note or ""):sub(1, 60),
              ts = math.max(ns.Now(), (cur and cur.ts or 0) + 1) } -- two answers in one second both count
  g.signups[occId][me] = s
  ns.Send("S", EncodeSignup(occId, me, s))
  ns.Fire("EVENTS_CHANGED")
  return s
end

-- officers: change anyone's answer, role or note (changes = { status, role, note }; role false = none)
-- status "R" clears their answer. Marked as changed by this officer (hidden src "o:<key>").
function E.OfficerSet(occId, key, changes)
  if not P.CanEdit("raids") or not E.Occ(occId) or not key then return nil end
  local g = G()
  g.signups[occId] = g.signups[occId] or {}
  local cur = g.signups[occId][key]
  local s = { status = cur and cur.status or "A", char = cur and E.SignupChar(key, cur) or key, role = cur and cur.role,
              note = cur and cur.note or "" }
  if changes.status then s.status = changes.status end
  if changes.role ~= nil then s.role = changes.role or nil end
  if changes.note then s.note = changes.note:sub(1, 60) end
  if not cur and not changes.status then s.status = "A" end
  s.ts = math.max(ns.Now(), (cur and cur.ts or 0) + 1)
  s.src = "o:" .. (ns.MyKey() or "")
  s.off = true -- (local only: the character stands as set, see E.SignupChar)
  g.signups[occId][key] = s
  ns.Send("S", EncodeSignup(occId, key, s))
  ns.Fire("EVENTS_CHANGED")
  return s
end

------------------------------------------------------------------------
-- Attendance
------------------------------------------------------------------------
function E.Attendance(occId)
  local g = G()
  if not g then return nil end
  return g.attendance[occId]
end

local function AttRecord(occId)
  local g = G()
  local a = g.attendance[occId]
  if not a then
    a = { min = {}, ov = {}, ts = 0 }
    g.attendance[occId] = a
  end
  return a
end

-- present? true/false/nil (nil = no data)
function E.Present(occ, key)
  local a = E.Attendance(occ.id)
  if not a then return nil end
  local ov = a.ov[key]
  if ov then return ov.v end
  local m = a.min[key] or 0
  local dur = (occ.event.duration or 180)
  return m >= math.min(60, dur * 0.5)
end

function E.Override(occId, key, present)
  if not P.CanEdit("raids") then return end
  local a = AttRecord(occId)
  a.ov[key] = { v = present, ts = ns.Now(), by = ns.MyKey() }
  a.ts = ns.Now()
  ns.Send("O", table.concat({ "1", occId, key, present and "1" or "0", Enc.ToB36(a.ov[key].ts), ns.MyKey() }, "^"))
  ns.Fire("EVENTS_CHANGED")
end

-- attendance % over the last `days` days of recorded raid nights
function E.AttendanceStats(key, days)
  local now = ns.Now()
  local attended, total = 0, 0
  for _, occ in ipairs(E.Occurrences(now - (days or 30) * 86400, now)) do
    if occ.finish < now and E.Attendance(occ.id) then
      total = total + 1
      if E.Present(occ, key) then attended = attended + 1 end
    end
  end
  return attended, total
end

-- Resolve a raid roster name to a guild roster key (handles realm/last-name formats)
function E.ResolveKey(name)
  if not name then return nil end
  local key = ns.NormalizeName(name)
  if ns.roster[key] then return key end
  local short = ns.ShortName(name)
  for k in pairs(ns.roster) do
    if ns.ShortName(k) == short then return k end
  end
  -- Forever puts the last name where the realm goes ("Anna-Smith"): try it
  -- as "Anna Smith"
  local base, tail = name:match("^([^-]+)%-(.+)$")
  if base then
    local full = ns.NormalizeName(base .. " " .. tail)
    if full and ns.roster[full] then return full end
  end
  -- Forever last names: raid roster may only give the first name. Only for a
  -- bare first name, and only when exactly one guild member has it (two
  -- "Anna"s must not credit the wrong one)
  if short:find(" ", 1, true) then return nil end
  local found
  for k in pairs(ns.roster) do
    if ns.ShortName(k):match("^(%S+)") == short then
      if found then return nil end
      found = k
    end
  end
  return found
end

-- author = the officer who recorded it (relays pass it on, so non-officers can relay)
local function EncodeAttendance(occId, a)
  local parts = {}
  for k, m in pairs(a.min) do parts[#parts + 1] = (tostring(k):gsub("[,=%^]", " ")) .. "=" .. m end
  table.sort(parts)
  return table.concat({ "1", occId, a.by or ns.MyKey() or "", Enc.ToB36(a.ts), table.concat(parts, ",") }, "^")
end

-- GetRaidRosterInfo's name, or nil for a raider who's offline (8th return).
-- Without an 8th return at all, treat them as online.
local function NameIfOnline(...)
  if select("#", ...) >= 8 and not select(8, ...) then return nil end
  return (...)
end

local lastBroadcast, finalSent = {}, {}
local function RecordTick()
  if not IsInGuild() or not P.CanEdit("raids") then return end
  if not (IsInRaid and IsInRaid()) then return end
  local occ = E.Active()
  if not occ then return end
  local a = AttRecord(occ.id)
  a.by = ns.MyKey()
  local n = (GetNumGroupMembers and GetNumGroupMembers()) or 0
  for i = 1, n do
    -- offline raiders still hold their spot but aren't attending
    local name = NameIfOnline(GetRaidRosterInfo(i))
    local key = name and E.ResolveKey(name)
    if key then a.min[key] = (a.min[key] or 0) + 1 end
  end
  a.ts = ns.Now()
  -- share every 10 minutes while the night runs, and once more as it ends
  -- (E.Active keeps the night for 15 minutes after its finish: one final
  -- broadcast, not one a minute)
  local now = ns.Now()
  local send
  if now >= occ.finish then
    send = not finalSent[occ.id]
    finalSent[occ.id] = true
  else
    send = now - (lastBroadcast[occ.id] or 0) >= 600
  end
  if send then
    lastBroadcast[occ.id] = now
    ns.Send("A", EncodeAttendance(occ.id, a))
  end
  ns.Fire("EVENTS_CHANGED")
end

------------------------------------------------------------------------
-- Encoding events
--   "1^id^ts^author^title^raid^duration^weekly^anchors^skips^deleted"
------------------------------------------------------------------------
local function Safe(s) return (tostring(s or ""):gsub("[%^]", " ")) end

function E.EncodeEvent(ev)
  local anchors, skips = {}, {}
  for i, t in ipairs(ev.anchors) do anchors[i] = Enc.ToB36(t) end
  for k in pairs(ev.skips or {}) do skips[#skips + 1] = k end
  table.sort(skips)
  return table.concat({ "1", Safe(ev.id), Enc.ToB36(ev.ts), Safe(ev.author), Safe(ev.title), Safe(ev.raid),
    tostring(ev.duration or 180), ev.weekly and "1" or "0", table.concat(anchors, ","), table.concat(skips, ","),
    ev.deleted and "1" or "0" }, "^")
end

function E.DecodeEvent(text)
  local f = Enc.Split(text, "^")
  if f[1] ~= "1" or not f[2] or f[2] == "" then return nil end
  local ev = { id = f[2], ts = Enc.FromB36(f[3]), author = f[4], title = f[5] ~= "" and f[5] or "Raid night",
    raid = f[6], duration = tonumber(f[7]) or 180, weekly = f[8] == "1", anchors = {}, skips = {}, deleted = f[11] == "1" }
  for _, a in ipairs(Enc.Split(f[9] or "", ",")) do ev.anchors[#ev.anchors + 1] = Enc.FromB36(a) end
  for _, k in ipairs(Enc.Split(f[10] or "", ",")) do if k ~= "" then ev.skips[k] = true end end
  if #ev.anchors == 0 then return nil end
  return ev
end

------------------------------------------------------------------------
-- Network handlers
------------------------------------------------------------------------
ns.CommHandlers.V = function(sender, payload)
  local ev = E.DecodeEvent(payload)
  if not ev or not ns.TimeOK(ev.ts) then return end
  -- the author must be an officer, and so must whoever passed it on
  if not ns.OfficerSent(sender, ev.author, "raids") then return end
  local cur = E.Get(ev.id)
  if cur and (cur.ts or 0) >= ev.ts then return end
  E.All()[ev.id] = ev
  if not cur and not ev.deleted then ns.Fire("EVENT_SCHEDULED", ev) end
  ns.Fire("EVENTS_CHANGED")
end

-- Sign-ups are taken for weekly nights from last week's up to 8 weeks ahead
-- (n counts weeks from the anchor), so nobody can fill saved data with
-- sign-ups to far-off weeks. One-off nights have a single occurrence.
local SIGNUP_WEEKS_BACK, SIGNUP_WEEKS_AHEAD = 1, 8
local function SignupOcc(occId)
  local occ = E.Occ(occId)
  if not occ then return nil end
  if occ.event.weekly then
    local _, a, n = E.ParseOcc(occId)
    local week = math.floor((ns.Now() - occ.event.anchors[a]) / WEEK)
    if n < week - SIGNUP_WEEKS_BACK or n > week + SIGNUP_WEEKS_AHEAD then return nil end
  end
  return occ
end

-- raid nights (within the window above) one member has a sign-up for
local MAX_SIGNUPS = 40
local function SignupCount(g, signer)
  local n = 0
  for occId, list in pairs(g.signups) do
    if list[signer] and SignupOcc(occId) then n = n + 1 end
  end
  return n
end

-- The character a sign-up is for. Members may sign up as one of their own
-- linked characters; the character is stored as sent and checked here, when
-- it's used, against the alt links as they are now (links can arrive after
-- the sign-up). One we can't tell is theirs counts as the signer.
function E.SignupChar(signer, s)
  local char = s and s.char
  if not char or char == "" or char == signer then return signer end
  if s.off then return char end -- an officer's change (see OfficerSet / HandleSignup)
  -- my own sign-ups: both characters on this account
  if FableHubDB.chars[signer] and FableHubDB.chars[char] then return char end
  -- (links we only have from a catch-up relay don't count: see Alts.lua)
  local A = ns.Alts
  if A and A.MainOf(char, true) == A.MainOf(signer, true) then return char end
  return signer
end

-- Someone sent a newer "copy" of our own sign-up (forged, or stale): send our
-- real one again, newer. At most once per raid night per FIX_GAP seconds; a
-- copy arriving in between gets one more answer when the gap is over.
local FIX_GAP = 300
local fixedAt, fixWaiting = {}, {}
local function FixMine(occId, theirTs)
  local now = GetTime()
  local last = fixedAt[occId]
  if last and now - last < FIX_GAP then
    local waiting = fixWaiting[occId]
    if not waiting then
      C_Timer.After(FIX_GAP - (now - last) + 1, function()
        local t = fixWaiting[occId]
        fixWaiting[occId] = nil
        if t then FixMine(occId, t) end
      end)
    end
    if not waiting or theirTs > waiting then fixWaiting[occId] = theirTs end
    return
  end
  local g, me = G(), ns.MyKey()
  if not g or not me or not SignupOcc(occId) then return end
  local mine = g.signups[occId] and g.signups[occId][me]
  if mine and (mine.ts or 0) > theirTs then return end -- changed it ourselves since: already sent
  fixedAt[occId] = now
  local fix = mine and {} or { status = "R", char = me }
  for k, v in pairs(mine or {}) do fix[k] = v end
  fix.ts = theirTs + 1
  g.signups[occId] = g.signups[occId] or {}
  g.signups[occId][me] = fix
  ns.Send("S", EncodeSignup(occId, me, fix))
end

local function HandleSignup(sender, payload, replayed)
  local f = Enc.Split(payload, "^")
  if f[1] ~= "1" then return end
  local occId, signer, ts, status = f[2], f[3], Enc.FromB36(f[4]), f[5]
  if not occId or not signer or not (E.STATUS[status] or status == "R") or not ns.TimeOK(ts) then return end
  local g = G()
  if not g then return end
  -- only for raid nights we know, in the sign-up window (no made-up
  -- occurrences piling up in saved data; catch-up sends them again once the
  -- night itself has arrived)
  if not SignupOcc(occId) then return end
  -- we're authoritative for our own sign-up, except officers importing from Raid-Helper.
  -- A newer "copy" from anyone else (forged, or stale) gets our real answer sent again.
  if signer == ns.MyKey() and not P.IsOfficer(sender, "raids") then
    local mine = g.signups[occId] and g.signups[occId][signer]
    if ts >= (mine and mine.ts or 0) then FixMine(occId, ts) end
    return
  end
  -- guild members only, so made-up names don't pile up in saved data
  if next(ns.roster) and not ns.roster[signer] then return end
  local cur = g.signups[occId] and g.signups[occId][signer]
  if cur and (cur.ts or 0) >= ts then return end
  -- a sign-up to a night they had none for: up to MAX_SIGNUPS nights each
  if not cur and SignupCount(g, signer) >= MAX_SIGNUPS then return end
  -- only the player themselves or an officer can change a sign-up; copies passed
  -- on by other members (catch-up) only fill in sign-ups we don't have yet, and
  -- only from the member answering our catch-up (so nobody can answer for
  -- everyone who hasn't signed up)
  if not ns.FirstHand(sender, signer, "raids") then
    if cur then return end
    if not replayed then
      if not ns.RelayGate(sender, "Y", function() HandleSignup(sender, payload, true) end) then return end
    end
  end
  local role = f[7]
  if role == "" or not ns.ROLE_NAMES[role] then role = nil end
  -- the character as sent, if it's a guild member: whether it's theirs is
  -- checked when it's used (E.SignupChar), since their alt links may reach
  -- us later. (Rewriting it here would store something other than what
  -- everyone else holds under the same timestamp.)
  local char = f[6] ~= "" and f[6]:sub(1, 64) or signer
  if char ~= signer and next(ns.roster) and not ns.roster[char] then char = signer end
  local src = (f[9] and f[9] ~= "") and f[9]:sub(1, 70) or nil
  -- an officer's own change, sent by that officer: the character stands as set
  local off = src ~= nil and src == "o:" .. sender and P.IsOfficer(sender, "raids") and ns.FirstHand(sender, sender)
  g.signups[occId] = g.signups[occId] or {}
  g.signups[occId][signer] = { status = status, char = char, role = role, note = (f[8] or ""):gsub("|", ""):sub(1, 60), ts = ts,
                               src = src, off = off or nil }
  ns.Fire("EVENTS_CHANGED")
end
ns.CommHandlers.S = function(sender, payload) HandleSignup(sender, payload, false) end

ns.CommHandlers.A = function(sender, payload)
  local f = Enc.Split(payload, "^")
  if f[1] ~= "1" or not ns.OfficerSent(sender, f[3], "raids") then return end
  local occId, ts = f[2], Enc.FromB36(f[4])
  if not ns.TimeOK(ts) then return end
  if not E.Occ(occId) then return end
  local a = AttRecord(occId)
  a.by = a.by or f[3]
  for _, item in ipairs(Enc.Split(f[5] or "", ",")) do
    local k, m = item:match("^(.+)=(%d+)$")
    m = tonumber(m)
    if k and m and m > (a.min[k] or 0) then a.min[k] = m end
  end
  if ts > (a.ts or 0) then a.ts = ts end
  ns.Fire("EVENTS_CHANGED")
end

ns.CommHandlers.O = function(sender, payload)
  local f = Enc.Split(payload, "^")
  if f[1] ~= "1" or not ns.OfficerSent(sender, f[6], "raids") then return end
  local occId, key, v, ts = f[2], f[3], f[4] == "1", Enc.FromB36(f[5])
  if not ns.TimeOK(ts) then return end
  if not E.Occ(occId) then return end
  local a = AttRecord(occId)
  local cur = a.ov[key]
  if cur and (cur.ts or 0) >= ts then return end
  a.ov[key] = { v = v, ts = ts, by = f[6] }
  if ts > (a.ts or 0) then a.ts = ts end
  ns.Fire("EVENTS_CHANGED")
end

-- sign-ups catch-up passes on: only guild members' (once the roster has
-- loaded), since others refuse the rest and the counts would never match
local function Shared(signer)
  return not next(ns.roster) or ns.roster[signer] ~= nil
end

local function SignupStats(list)
  local maxTs, n = 0, 0
  for signer, s in pairs(list) do
    if Shared(signer) then
      n = n + 1
      if (s.ts or 0) > maxTs then maxTs = s.ts end
    end
  end
  return maxTs, n
end

-- catch-up digest: events, sign-ups per occurrence, attendance per occurrence
function E.SendDigest()
  local g = G()
  if not g then return end
  local parts = {}
  for id, ev in pairs(g.events) do parts[#parts + 1] = "e:" .. Safe(id) .. "=" .. Enc.ToB36(ev.ts or 0) end
  for occId, list in pairs(g.signups) do
    local maxTs, n = SignupStats(list)
    parts[#parts + 1] = "s:" .. occId .. "=" .. Enc.ToB36(maxTs) .. "." .. n
  end
  for occId, a in pairs(g.attendance) do parts[#parts + 1] = "a:" .. occId .. "=" .. Enc.ToB36(a.ts or 0) end
  ns.Send("Y", table.concat(parts, ","))
end

ns.CommHandlers.Y = function(sender, payload)
  -- sign-ups come from the usual relay; raid nights and attendance (officer
  -- data) only from an officer, since others won't accept them from members
  local member, officer = ns.AmRelayFor(sender), ns.AmOfficerRelayFor(sender, "raids")
  if not member and not officer then return end
  local g = G()
  if not g then return end
  local theirs = {}
  for _, item in ipairs(Enc.Split(payload, ",")) do
    local k, v = item:match("^(.-)=([%w%.]+)$")
    if k then theirs[k] = v end
  end
  for id, ev in pairs(g.events) do
    if officer and Enc.FromB36(theirs["e:" .. id]) < (ev.ts or 0) then ns.Send("V", E.EncodeEvent(ev)) end
  end
  for occId, list in pairs(g.signups) do
    -- (sign-ups for nights that no longer exist, or outside the sign-up window,
    -- are refused, so skip them too)
    if member and SignupOcc(occId) then
      local maxTs, n = SignupStats(list)
      local t = theirs["s:" .. occId]
      local tTs, tN = 0, 0
      if t then local a, b = t:match("^(%w+)%.(%d+)$"); tTs, tN = Enc.FromB36(a), tonumber(b) or 0 end
      if tTs < maxTs or tN < n then
        for signer, s in pairs(list) do
          if Shared(signer) then ns.Send("S", EncodeSignup(occId, signer, s)) end
        end
      end
    end
  end
  for occId, a in pairs(g.attendance) do
    if officer and Enc.FromB36(theirs["a:" .. occId]) < (a.ts or 0) then
      if next(a.min) then ns.Send("A", EncodeAttendance(occId, a)) end
      for key, ov in pairs(a.ov) do
        ns.Send("O", table.concat({ "1", occId, key, ov.v and "1" or "0", Enc.ToB36(ov.ts), ov.by or "" }, "^"))
      end
    end
  end
end

------------------------------------------------------------------------
-- Housekeeping, reminders, timers
------------------------------------------------------------------------
-- raid nights dated more than 2 years ahead are mistakes (e.g. an import with a typo'd year):
-- officers delete them so they don't linger unseen
local function RemoveFarFuture()
  if not P.CanEdit("raids") then return end
  local limit = ns.Now() + 2 * 365 * 86400
  for _, ev in pairs(E.All()) do
    if not ev.deleted then
      local far = true
      for _, a in ipairs(ev.anchors or {}) do if a <= limit then far = false end end
      if far and ev.anchors and #ev.anchors > 0 then E.Delete(ev) end
    end
  end
end
E.RemoveFarFuture = RemoveFarFuture

local function Prune()
  local g = G()
  if not g then return end
  local cutoff = ns.Now() - 90 * 86400
  for occId in pairs(g.signups) do
    local occ = E.Occ(occId)
    if not occ or occ.finish < cutoff then g.signups[occId] = nil end
  end
  for occId in pairs(g.attendance) do
    local occ = E.Occ(occId)
    if not occ or occ.finish < cutoff then g.attendance[occId] = nil end
  end
end

function E.FormatTime(t)
  local h24 = true
  if GetCVar then
    local ok, v = pcall(GetCVar, "timeMgrUseMilitaryTime")
    if ok and v == "0" then h24 = false end
  end
  return (date(h24 and "%H:%M" or "%I:%M %p", t):gsub("^0(%d:)", "%1"))
end

function E.FormatDay(t)
  local today = date("*t", ns.Now())
  local d = date("*t", t)
  if d.year == today.year and d.yday == today.yday then return "Today" end
  local tomorrow = date("*t", ns.Now() + 86400)
  if d.year == tomorrow.year and d.yday == tomorrow.yday then return "Tomorrow" end
  return date("%a %d %b", t)
end

local function Remind()
  if not ns.Option("alertRaid") then return end
  local now = ns.Now()
  for _, occ in ipairs(E.Occurrences(now, now + 24 * 3600)) do
    if occ.start > now and not E.MySignup(occ.id) then
      ns.Print(("%s %s at %s - you haven't signed up yet. Type /fhub to sign up."):format(
        occ.event.title, E.FormatDay(occ.start):lower(), E.FormatTime(occ.start)))
    end
  end
end

ns.On("LOGIN", function()
  C_Timer.NewTicker(60, RecordTick)
  C_Timer.After(20, function() Prune(); RemoveFarFuture(); Remind() end)
end)

------------------------------------------------------------------------
-- Typed dates, times and lengths
------------------------------------------------------------------------
local MONTHS = { jan = 1, feb = 2, mar = 3, apr = 4, may = 5, jun = 6, jul = 7, aug = 8, sep = 9, oct = 10, nov = 11, dec = 12 }
local WDAYS = { sun = 1, mon = 2, tue = 3, wed = 4, thu = 5, fri = 6, sat = 7 }

function E.DayStart(t)
  local d = date("*t", t)
  return time({ year = d.year, month = d.month, day = d.day, hour = 0, min = 0, sec = 0 })
end

local function MakeDay(y, m, d)
  if not (y and m and d) or m < 1 or m > 12 or d < 1 or d > 31 then return nil end
  local t = time({ year = y, month = m, day = d, hour = 0, min = 0, sec = 0 })
  local back = date("*t", t)
  if back.month ~= m or back.day ~= d then return nil end -- e.g. 31 Feb
  return t
end

-- Returns the start of the day, or nil. Day comes before month in numeric dates.
function E.ParseDate(text, now)
  now = now or ns.Now()
  local s = (text or ""):lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub(",", " ")
  if s == "" then return nil end
  local today = E.DayStart(now)
  local cur = date("*t", now)
  if s == "today" then return today end
  if s == "tomorrow" or s == "tmrw" then return E.DayStart(now + 86400 + 3600) end
  -- weekday name: the next one (today if it matches)
  local wd = s:match("^(%a%a%a)")
  if wd and WDAYS[wd] and not s:find("%d") then
    for i = 0, 6 do
      local t = E.DayStart(now + i * 86400 + 3600)
      if date("*t", t).wday == WDAYS[wd] then return t end
    end
  end
  local function WithYear(d, m, y)
    if y then
      y = tonumber(y)
      if y < 100 then y = 2000 + y end
      return MakeDay(y, m, d)
    end
    local t = MakeDay(cur.year, m, d)
    if t and t < today then t = MakeDay(cur.year + 1, m, d) end -- a date that's passed means next year
    return t
  end
  -- 2026-10-21
  local y, m, d = s:match("^(%d%d%d%d)[-/.](%d%d?)[-/.](%d%d?)$")
  if y then return MakeDay(tonumber(y), tonumber(m), tonumber(d)) end
  -- 21/10, 21/10/26, 21-10-2026, 21.10
  d, m, y = s:match("^(%d%d?)[/.%-](%d%d?)[/.%-]?(%d*)$")
  if d then return WithYear(tonumber(d), tonumber(m), y ~= "" and y or nil) end
  -- 21 oct [2026], or oct 21 [2026]
  local dd, mon, yy = s:match("^(%d%d?)%s*(%a+)%.?%s*(%d*)$")
  if not dd then mon, dd, yy = s:match("^(%a+)%.?%s*(%d%d?)%a*%s*(%d*)$") end
  if dd and mon and MONTHS[mon:sub(1, 3)] then
    return WithYear(tonumber(dd), MONTHS[mon:sub(1, 3)], yy ~= "" and yy or nil)
  end
  return nil
end

-- Returns minutes after midnight, or nil. Accepts 20:00, 20.30, 2030, 20, 8pm, 8:30 pm, noon, midnight.
function E.ParseTime(text)
  local s = (text or ""):lower():gsub("%s+", "")
  if s == "" then return nil end
  if s == "noon" then return 12 * 60 end
  if s == "midnight" then return 0 end
  local ampm = s:match("([ap])%.?m?%.?$")
  if ampm then s = s:gsub("[ap]%.?m?%.?$", "") end
  local h, m = s:match("^(%d%d?)[:.](%d%d)$")
  if not h then
    local digits = s:match("^(%d+)$")
    if digits then
      if #digits <= 2 then h, m = digits, "0"
      elseif #digits == 3 then h, m = digits:sub(1, 1), digits:sub(2)
      elseif #digits == 4 then h, m = digits:sub(1, 2), digits:sub(3) end
    end
  end
  h, m = tonumber(h), tonumber(m)
  if not h or not m or m > 59 then return nil end
  if ampm then
    if h < 1 or h > 12 then return nil end
    if ampm == "a" then h = (h == 12) and 0 or h else h = (h == 12) and 12 or h + 12 end
  end
  if h > 23 then return nil end
  return h * 60 + m
end

-- Returns minutes, or nil. Accepts 3h, 2h30, 2h 30m, 2:30, 90m, 2.5h, 150 (minutes) and 3 (hours).
function E.ParseDuration(text)
  -- longest words first: "mins?" would turn "minutes" into "mutes"
  local s = (text or ""):lower():gsub("%s+", ""):gsub("hours?", "h"):gsub("hrs?", "h"):gsub("minutes?", "m"):gsub("mins?", "m")
  if s == "" then return nil end
  local total
  local h, m = s:match("^(%d+)h(%d*)m?$")
  if h then total = tonumber(h) * 60 + (tonumber(m) or 0) end
  if not total then
    local hh, mm = s:match("^(%d+):(%d%d)$")
    if hh then total = tonumber(hh) * 60 + tonumber(mm) end
  end
  if not total then
    local dec = s:match("^(%d*%.%d+)h?$") or s:match("^(%d+%.%d*)h?$")
    if dec then total = math.floor(tonumber(dec) * 60 + 0.5) end
  end
  if not total then
    local mins = s:match("^(%d+)m$")
    if mins then total = tonumber(mins) end
  end
  if not total then
    local n = tonumber(s:match("^(%d+)$") or "")
    if n then total = (n <= 12) and n * 60 or n end -- small numbers are hours, big ones minutes
  end
  if not total or total < 15 or total > 12 * 60 then return nil end
  return total
end

function E.FormatDuration(minutes)
  return ("%dh %02dm"):format(math.floor(minutes / 60), minutes % 60)
end

ns.RegisterDigest(function() E.SendDigest() end)
