-- Alts: which guild characters belong to the same player.
--
-- Battle.net IDs aren't available to addons, so each member's FableHub links the
-- characters it knows from their own account (FableHubDB is shared by every
-- character on the account). Officers can link or unlink anyone by hand.
--
-- g.alts[charKey] = { main = mainKey, ts, by, manual }
-- The newest entry for a character wins. A member's own entries keep the time of
-- their last change (main picked or alt added), so an officer's fix sticks until
-- the member changes something themselves.

local _, ns = ...
local Enc, P = ns.Encode, ns.Plans
local A = {}
ns.Alts = A

local function All()
  local g = ns.GuildDB()
  if not g then return {} end
  g.alts = g.alts or {}
  return g.alts
end
A.All = All

local function Safe(s) return (tostring(s or ""):gsub("[%^|]", " ")) end

local function Encode(char, e)
  return table.concat({ "1", Safe(char), Safe(e.main), Enc.ToB36(e.ts or 0), e.manual and "1" or "0", Safe(e.by) }, "^")
end

local function Decode(text)
  local f = Enc.Split(text, "^")
  if f[1] ~= "1" or not f[2] or f[2] == "" or not f[3] or f[3] == "" then return nil end
  return f[2], { main = f[3], ts = Enc.FromB36(f[4]) or 0, manual = f[5] == "1" or nil, by = f[6] }
end

A.Decode = Decode -- for the officer change log

local function Store(char, e)
  local cur = All()[char]
  if cur and (cur.ts or 0) >= (e.ts or 0) then return false end
  All()[char] = e
  return true
end

-- the main a character belongs to (itself if not linked). verifiedOnly: ignore
-- a link we only have from a catch-up relay (e.relayed, see HandleLink), for
-- checks that let a character act for its group
function A.MainOf(key, verifiedOnly)
  local e = All()[key]
  if e and e.main and e.main ~= "" and not (verifiedOnly and e.relayed) then return e.main end
  return key
end

local function Level(key)
  local r = ns.roster[key]
  local rec = FableHubDB.chars[key]
  return (r and r.level) or (rec and rec.level) or 0
end
A.Level = Level

------------------------------------------------------------------------
-- My own characters
------------------------------------------------------------------------
-- my account's characters that are in this guild
function A.MyChars()
  local out, seen = {}, {}
  local me = ns.MyKey()
  if me then out[1] = me; seen[me] = true end
  for key in pairs(FableHubDB.chars or {}) do
    if not seen[key] and ns.roster[key] then out[#out + 1] = key; seen[key] = true end
  end
  table.sort(out)
  return out
end

-- highest level first, then name
function A.DefaultMain(chars)
  local best
  for _, key in ipairs(chars) do
    if not best or Level(key) > Level(best) or (Level(key) == Level(best) and key < best) then best = key end
  end
  return best
end

function A.MyMain()
  local chars = A.MyChars()
  local g = ns.GuildDB()
  local picked = g and g.myMain
  for _, key in ipairs(chars) do if key == picked then return picked end end
  return A.DefaultMain(chars)
end

-- share my links with the guild
function A.Publish()
  local g = ns.GuildDB()
  if not g or not IsInGuild() then return end
  local chars = A.MyChars()
  if #chars < 2 then return end
  local main = A.MyMain()
  local sig = main .. ":" .. table.concat(chars, ",")
  if g.myAltsSig ~= sig then
    g.myAltsSig = sig
    g.myAltsTs = math.max(ns.Now(), (g.myAltsTs or 0) + 1)
  end
  g.myAltsTs = g.myAltsTs or ns.Now()
  -- the character we're on goes first: other clients only take a link from us
  -- once they know which group we're in (see the X handler)
  local me = ns.MyKey()
  table.sort(chars, function(a, b)
    if (a == me) ~= (b == me) then return a == me end
    return a < b
  end)
  -- a stored link of ours that's newer (or as new, to another main) than our
  -- time would win over what we send: move our time past it
  for _, key in ipairs(chars) do
    local cur = All()[key]
    if cur and not cur.manual then
      local t = cur.ts or 0
      if t > g.myAltsTs or (t == g.myAltsTs and cur.main ~= main) then g.myAltsTs = t + 1 end
    end
  end
  local changed = false
  for _, key in ipairs(chars) do
    local cur = All()[key]
    -- an officer's link stays until an officer changes it
    if not (cur and cur.manual) then
      -- every link signed by the character we're on, even one already stored
      -- under another of our characters' name: receivers note this character's
      -- vouch (see Agreed) before comparing times, so both sides of a link
      -- complete once each character has logged in
      local e = { main = main, ts = g.myAltsTs, by = me }
      if Store(key, e) then
        changed = true
      elseif cur and cur.main == main then
        cur.relayed = nil -- our own word for it
      end
      ns.Send("X", Encode(key, e))
    end
  end
  if changed then ns.Fire("ALTS_CHANGED") end
end

function A.SetMyMain(key)
  local g = ns.GuildDB()
  if not g then return end
  g.myMain = key
  A.Publish()
end

------------------------------------------------------------------------
-- Officer edits
------------------------------------------------------------------------
local function Officer(char, main)
  if not P.CanEdit("alts") then return false end
  local cur = All()[char]
  local e = { main = main, ts = math.max(ns.Now(), (cur and cur.ts or 0) + 1), by = ns.MyKey(), manual = true }
  All()[char] = e
  ns.Send("X", Encode(char, e))
  return true
end

-- link char (and anyone linked to it) under main. Officer edits only follow
-- verified links (MainOf / GroupOf verifiedOnly), so a link we only have from
-- a catch-up relay isn't turned into an officer's (manual) one.
function A.Link(char, main)
  if not P.CanEdit("alts") or not char or not main or char == main then return false end
  main = A.MainOf(main, true)
  if main == char then return false end
  if A.MainOf(main, true) ~= main or not All()[main] then Officer(main, main) end
  -- an alt moves on its own; a main brings its alts along
  local moving = A.MainOf(char, true) == char and A.GroupOf(char, true) or { char }
  for _, key in ipairs(moving) do Officer(key, main) end
  ns.Fire("ALTS_CHANGED")
  return true
end

-- take one character out of its group
function A.Unlink(char)
  if not P.CanEdit("alts") or A.MainOf(char) == char then return false end
  Officer(char, char)
  ns.Fire("ALTS_CHANGED")
  return true
end

-- make char the main of its group
function A.MakeMain(char)
  if not P.CanEdit("alts") then return false end
  for _, key in ipairs(A.GroupOf(char, true)) do Officer(key, char) end
  ns.Fire("ALTS_CHANGED")
  return true
end

-- every guild character linked with key (including key). verifiedOnly: leave
-- out links we only have from a catch-up relay (see A.MainOf)
function A.GroupOf(key, verifiedOnly)
  local main = A.MainOf(key, verifiedOnly)
  local out, seen = { main }, { [main] = true }
  for char, e in pairs(All()) do
    if not seen[char] and e.main == main and not (verifiedOnly and e.relayed) then
      out[#out + 1] = char; seen[char] = true
    end
  end
  if not seen[key] then out[#out + 1] = key end
  return out
end

------------------------------------------------------------------------
-- Groups for display: only characters in the guild roster
------------------------------------------------------------------------
-- returns groups { main = key, alts = { keys } } (only those with alts) and singles { keys }
function A.Groups()
  local groups, byMain, singles = {}, {}, {}
  for _, key in ipairs(ns.rosterOrder) do
    local main = A.MainOf(key)
    local grp = byMain[main]
    if not grp then
      grp = { main = main, alts = {} }
      byMain[main] = grp
      groups[#groups + 1] = grp
    end
    if key ~= main then grp.alts[#grp.alts + 1] = key end
  end
  local out = {}
  for _, grp in ipairs(groups) do
    if #grp.alts > 0 then
      table.sort(grp.alts, function(a, b)
        if Level(a) ~= Level(b) then return Level(a) > Level(b) end
        return a < b
      end)
      out[#out + 1] = grp
    elseif ns.roster[grp.main] then
      singles[#singles + 1] = grp.main
    end
  end
  table.sort(out, function(a, b) return ns.ShortName(a.main):lower() < ns.ShortName(b.main):lower() end)
  table.sort(singles, function(a, b) return ns.ShortName(a):lower() < ns.ShortName(b):lower() end)
  return out, singles
end

------------------------------------------------------------------------
-- Sync
------------------------------------------------------------------------
-- Members' own links need both sides to agree. A link "char -> main" is
-- taken once
--   * char's side vouched for it: a link sent by char itself, and
--   * main's side vouched for it: a link sent by main itself, or by a
--     character already in main's group,
-- so nobody can file someone else's character under their own main (char's
-- side missing), or put their own character into someone else's group
-- (main's side missing). A character naming itself its own main (a main, or
-- unlinking itself) only needs itself. Linking anyone else stays
-- officer-only (manual links). Links stored before this rule stay as they
-- are.
-- Every Publish, from any character of an account, sends the links of all its
-- characters (each signed by the character we're on), so a link completes
-- once both characters have logged in on a FableHub with this rule.
--
-- Vouches waiting for the other side are kept per character:
--   g.altVouch[char] = { main = mainKey, char = time, mainSide = time }
-- (time = when we got it). They're kept after the link completes too, so the
-- main's side alone can put a character back where it vouched to be (a main
-- restoring its alts after a bad link from an older FableHub). Only roster
-- characters; a side older than VOUCH_AGE no longer counts, and entries are
-- dropped at login once both sides are that old.
local VOUCH_AGE = 30 * 86400

local function Vouches()
  local g = ns.GuildDB()
  if not g then return nil end
  g.altVouch = g.altVouch or {}
  return g.altVouch
end

local function Fresh(t, now) return t ~= nil and now - t <= VOUCH_AGE end

-- note what this link (sent first-hand by e.by) vouches for; true once both
-- sides of char -> e.main have
local function Agreed(char, e)
  local by, main = e.by, e.main
  if char == main then return by == char end
  local charSide = by == char
  -- (a link of by's we only have from a catch-up relay doesn't put it in the group)
  local mainSide = by == main or A.MainOf(by, true) == main
  if not charSide and not mainSide then return false end
  -- with no roster yet we can't tell guild characters from made-up ones: keep nothing
  local list = next(ns.roster) and ns.roster[char] and Vouches()
  if not list then return false end
  local now = ns.Now()
  local v = list[char]
  if v and v.main ~= main then
    -- char's own word for another main stands until char itself says otherwise
    -- (so someone vouching as a "main" can't wipe it)
    if charSide or not Fresh(v.char, now) then v = nil else return false end
  end
  if not v then v = { main = main }; list[char] = v end
  if charSide then v.char = now end
  if mainSide then v.mainSide = now end
  return Fresh(v.char, now) and Fresh(v.mainSide, now)
end

-- drop vouches for characters no longer in the guild, or with both sides stale
local function PruneVouches()
  local list = Vouches()
  if not list or not IsInGuild() or not next(ns.roster) then return end
  local now = ns.Now()
  for char, v in pairs(list) do
    if not ns.roster[char] or (not Fresh(v.char, now) and not Fresh(v.mainSide, now)) then list[char] = nil end
  end
end

local republishQueued = false
local REPUBLISH_GAP = 300 -- per member sending us a wrong link of ours
local republishFor = {}   -- [sender] = GetTime() of the last re-publish they set off
local function HandleLink(sender, payload, replayed)
  local char, e = Decode(payload)
  if not char or not ns.TimeOK(e.ts) then return end
  -- guild members only (no made-up characters piling up in saved data)
  if next(ns.roster) and not (ns.roster[char] and ns.roster[e.main]) then return end
  if e.manual then
    if not ns.OfficerSent(sender, e.by, "alts") then return end -- officer links: officers only
  else
    -- a member's link of one of OUR characters that disagrees with ours (made
    -- up, or stale): publish ours again, newer, so ours wins everywhere
    -- (one re-publish for a burst of them, and at most one per REPUBLISH_GAP
    -- per member setting them off, unless it's an officer)
    local g = ns.GuildDB()
    local mine = false
    for _, k in ipairs(A.MyChars()) do if k == char then mine = true end end
    if mine and g and #A.MyChars() >= 2 and e.main ~= A.MyMain() and e.ts >= (g.myAltsTs or 0) then
      local now = GetTime()
      local officer = P.IsOfficer(sender) and not ns.IsLooseSender(sender)
      if not officer and republishFor[sender] and now - republishFor[sender] < REPUBLISH_GAP then return end
      republishFor[sender] = now
      g.myAltsTs = e.ts + 1
      if not republishQueued then
        republishQueued = true
        C_Timer.After(2, function() republishQueued = false; A.Publish() end)
      end
      return
    end
    local cur = All()[char]
    -- an officer's link stays until an officer changes it
    if cur and cur.manual then return end
    if not ns.FirstHand(sender, e.by) then
      -- copies passed on by other members only fill gaps, and only from the
      -- member answering our catch-up. They're marked relayed (kept here only,
      -- never sent): shown, but not trusted to put anyone in a group (see
      -- A.MainOf) until a first-hand copy of the same link arrives.
      if cur then return end
      if not replayed then
        if not ns.RelayGate(sender, "G", function() HandleLink(sender, payload, true) end) then return end
      end
      e.relayed = true
    elseif sender == e.by and not P.IsOfficer(sender) then
      -- a member's own link: only once both sides agree (see above)
      if not Agreed(char, e) then return end
    end
  end
  -- a first-hand copy of a link we only had relayed: it's verified now
  -- (an older or as-new copy isn't stored, so clear the mark here)
  local stored = All()[char]
  if not e.relayed and stored and stored.relayed and stored.main == e.main then stored.relayed = nil end
  if Store(char, e) then ns.Fire("ALTS_CHANGED") end
end
ns.CommHandlers.X = function(sender, payload) HandleLink(sender, payload, false) end

-- links catch-up passes on: once the roster has loaded, only those between
-- guild members (others refuse the rest, so the counts would never match)
local function Shared(char, e)
  if not next(ns.roster) then return true end
  return ns.roster[char] ~= nil and ns.roster[e.main] ~= nil
end

function A.SendDigest()
  local maxTs, n = 0, 0
  for char, e in pairs(All()) do
    if Shared(char, e) then
      n = n + 1
      if (e.ts or 0) > maxTs then maxTs = e.ts end
    end
  end
  ns.Send("G", "1^" .. Enc.ToB36(maxTs) .. "^" .. Enc.ToB36(n))
end

ns.CommHandlers.G = function(sender, payload)
  -- members' own links come from the usual relay; links an officer set by
  -- hand only from an officer (others won't accept them from a member)
  local member, officer = ns.AmRelayFor(sender), ns.AmOfficerRelayFor(sender, "alts")
  if not member and not officer then return end
  local f = Enc.Split(payload, "^")
  local theirs, theirN = Enc.FromB36(f[2]) or 0, Enc.FromB36(f[3]) or 0
  local n = 0
  for char, e in pairs(All()) do if Shared(char, e) then n = n + 1 end end
  local all = theirN < n -- they're missing some: send everything
  for char, e in pairs(All()) do
    if (all or (e.ts or 0) > theirs) and Shared(char, e) and ((e.manual and officer) or (not e.manual and member)) then
      ns.Send("X", Encode(char, e))
    end
  end
end

-- forget links of characters (or to mains) no longer in the guild. Only with
-- a loaded roster, and not if it would drop most links (a roster that's
-- still filling in must not wipe them)
function A.PruneLeft()
  if not IsInGuild() or not next(ns.roster) then return end
  local all, gone, total = All(), {}, 0
  for char, e in pairs(all) do
    total = total + 1
    if not (ns.roster[char] and ns.roster[e.main]) then gone[#gone + 1] = char end
  end
  if #gone == 0 or #gone * 2 > total then return end
  for _, char in ipairs(gone) do all[char] = nil end
  ns.Fire("ALTS_CHANGED")
end

-- publish once the guild roster has loaded after login
local publishQueued
ns.On("ROSTER_CHANGED", function()
  if publishQueued then return end
  publishQueued = true
  C_Timer.After(12, function() A.PruneLeft(); PruneVouches(); A.Publish() end)
end)

ns.RegisterDigest(function() A.SendDigest() end)
