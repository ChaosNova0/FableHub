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

-- the main a character belongs to (itself if not linked)
function A.MainOf(key)
  local e = All()[key]
  if e and e.main and e.main ~= "" then return e.main end
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
  -- the character we're on goes first: other clients only take a link from us
  -- once they know which group we're in (see the X handler)
  local me = ns.MyKey()
  table.sort(chars, function(a, b)
    if (a == me) ~= (b == me) then return a == me end
    return a < b
  end)
  local changed = false
  for _, key in ipairs(chars) do
    local cur = All()[key]
    -- an officer's link stays until an officer changes it
    if not (cur and cur.manual) then
      local e = { main = main, ts = g.myAltsTs, by = me }
      if Store(key, e) then changed = true end
      ns.Send("X", Encode(key, All()[key]))
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

-- link char (and anyone linked to it) under main
function A.Link(char, main)
  if not P.CanEdit("alts") or not char or not main or char == main then return false end
  main = A.MainOf(main)
  if main == char then return false end
  if A.MainOf(main) ~= main or not All()[main] then Officer(main, main) end
  -- an alt moves on its own; a main brings its alts along
  local moving = A.MainOf(char) == char and A.GroupOf(char) or { char }
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
  for _, key in ipairs(A.GroupOf(char)) do Officer(key, char) end
  ns.Fire("ALTS_CHANGED")
  return true
end

-- every guild character linked with key (including key)
function A.GroupOf(key)
  local main = A.MainOf(key)
  local out, seen = { main }, { [main] = true }
  for char, e in pairs(All()) do
    if not seen[char] and e.main == main then out[#out + 1] = char; seen[char] = true end
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
-- a player's own link must put the character publishing it in that group:
-- it's the character itself or the main, or the publisher is already
-- known to be in the same group (so nobody can file someone else under a
-- main they have nothing to do with)
local function InGroup(by, char, main)
  return by == char or by == main or A.MainOf(by) == main
end

local function HandleLink(sender, payload, retried)
  local char, e = Decode(payload)
  if not char or not ns.TimeOK(e.ts) then return end
  -- guild members only (no made-up characters piling up in saved data)
  if next(ns.roster) and not (ns.roster[char] and ns.roster[e.main]) then return end
  if e.manual then
    if not ns.OfficerSent(sender, e.by, "alts") then return end -- officer links: officers only
  else
    -- a member's link of one of OUR characters that disagrees with ours (made
    -- up, or stale): publish ours again, newer, so ours wins everywhere
    local g = ns.GuildDB()
    local mine = false
    for _, k in ipairs(A.MyChars()) do if k == char then mine = true end end
    if mine and g and #A.MyChars() >= 2 and e.main ~= A.MyMain() and e.ts >= (g.myAltsTs or 0) then
      g.myAltsTs = e.ts + 1
      C_Timer.After(2, A.Publish)
      return
    end
    local cur = All()[char]
    -- an officer's link stays until an officer changes it
    if cur and cur.manual then return end
    if sender == e.by then
      if not InGroup(e.by, char, e.main) then return end
    elseif not ns.FirstHand(sender, e.by) then
      -- copies passed on by other members only fill gaps, and only from the
      -- member answering our catch-up
      if cur then return end
      local relay = ns.IsMyRelay(sender)
      if relay == nil and not retried then -- their hello hasn't reached us yet
        C_Timer.After(10, function() HandleLink(sender, payload, true) end)
        return
      end
      if not relay then return end
    end
  end
  if Store(char, e) then ns.Fire("ALTS_CHANGED") end
end
ns.CommHandlers.X = function(sender, payload) HandleLink(sender, payload, false) end

function A.SendDigest()
  local maxTs, n = 0, 0
  for _, e in pairs(All()) do
    n = n + 1
    if (e.ts or 0) > maxTs then maxTs = e.ts end
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
  for _ in pairs(All()) do n = n + 1 end
  local all = theirN < n -- they're missing some: send everything
  for char, e in pairs(All()) do
    if (all or (e.ts or 0) > theirs) and ((e.manual and officer) or (not e.manual and member)) then
      ns.Send("X", Encode(char, e))
    end
  end
end

-- publish once the guild roster has loaded after login
local publishQueued
ns.On("ROSTER_CHANGED", function()
  if publishQueued then return end
  publishQueued = true
  C_Timer.After(12, function() A.Publish() end)
end)

ns.RegisterDigest(function() A.SendDigest() end)
