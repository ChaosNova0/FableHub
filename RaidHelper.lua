-- Raid-Helper import: paste a Raid-Helper event's JSON export and its sign-ups
-- become sign-ups on a FableHub raid night (officers only).
--
-- Raid-Helper lists people by their Discord name, so each sign-up is matched to
-- a guild character: a remembered link first (by Discord user ID), then the
-- name. Officers can link the rest by hand; links are shared with the guild.
--   g.rhLinks[discordUserId] = { key = charKey, ts, by }
-- Imported sign-ups keep the time the person signed up in Discord, so an
-- in-game answer given later still wins (and the other way round).

local _, ns = ...
local Enc, P = ns.Encode, ns.Plans
local RH = {}
ns.RaidHelper = RH

RH.DEFAULT_MINUTES = 180

-- Raid-Helper class names -> WoW class
local CLASS = {
  Warrior = "WARRIOR", Paladin = "PALADIN", Hunter = "HUNTER", Rogue = "ROGUE", Priest = "PRIEST",
  Shaman = "SHAMAN", Mage = "MAGE", Warlock = "WARLOCK", Druid = "DRUID", DK = "DEATHKNIGHT",
  DeathKnight = "DEATHKNIGHT", ["Death Knight"] = "DEATHKNIGHT", Monk = "MONK", DH = "DEMONHUNTER",
  DemonHunter = "DEMONHUNTER", Evoker = "EVOKER",
}
-- spec names (Raid-Helper adds "1" or "_DPS" to tell same-named specs apart) -> WoW class,
-- for people listed under "Tank", "Bench" and so on
local SPEC_CLASS = {
  Protection = "WARRIOR", Arms = "WARRIOR", Fury = "WARRIOR",
  Protection1 = "PALADIN", Holy1 = "PALADIN", Retribution = "PALADIN",
  Guardian = "DRUID", Feral = "DRUID", Balance = "DRUID", Restoration = "DRUID",
  Blood = "DEATHKNIGHT", Frost1 = "DEATHKNIGHT", Frost_DPS = "DEATHKNIGHT", Unholy = "DEATHKNIGHT",
  Brewmaster = "MONK", Mistweaver = "MONK", Windwalker = "MONK",
  Discipline = "PRIEST", Holy = "PRIEST", Shadow = "PRIEST", Smite = "PRIEST",
  Elemental = "SHAMAN", Enhancement = "SHAMAN", Restoration1 = "SHAMAN",
  Arcane = "MAGE", Fire = "MAGE", Frost = "MAGE",
  Affliction = "WARLOCK", Demonology = "WARLOCK", Destruction = "WARLOCK",
  Beastmastery = "HUNTER", Marksmanship = "HUNTER", Survival = "HUNTER",
  Assassination = "ROGUE", Combat = "ROGUE", Subtlety = "ROGUE",
}
local ROLE = { Tanks = "TANK", Tank = "TANK", Healers = "HEALER", Healer = "HEALER", Melee = "MELEE", Ranged = "RANGED" }
-- special "classes" that are really answers
local STATUS_CLASS = { Late = "L", Tentative = "T", Absence = "D", Bench = "T" }

local function G()
  local g = ns.GuildDB()
  if not g then return nil end
  g.rhLinks = g.rhLinks or {}
  return g
end

local function Clean(s) return (tostring(s or ""):lower():gsub("[^%a]", "")) end

------------------------------------------------------------------------
-- Matching Discord names to guild characters
------------------------------------------------------------------------
function RH.Match(userId, name)
  local g = G()
  local link = g and userId and g.rhLinks[userId]
  if link and link.key and link.key ~= "" then
    if link.key == "-" then return nil, "ignored" end
    return link.key, "linked"
  end
  local want, wantClean = (name or ""):lower(), Clean(name)
  if want == "" then return nil end
  local exact, clean, prefix
  for _, key in ipairs(ns.rosterOrder) do
    local short = ns.ShortName(key)
    local first = (short:match("^(%S+)") or short)
    if short:lower() == want or first:lower() == want then exact = exact or key end
    if wantClean ~= "" and (Clean(short) == wantClean or Clean(first) == wantClean) then clean = clean or key end
    if #wantClean >= 4 and Clean(first):sub(1, #wantClean) == wantClean then prefix = prefix or key end
  end
  if exact then return exact, "name" end
  if clean then return clean, "name" end
  if prefix then return prefix, "guess" end
  return nil
end

local function SendLink(userId, l)
  ns.Send("h", table.concat({ "1", userId, (tostring(l.key):gsub("%^", " ")), Enc.ToB36(l.ts or 0), l.by or "" }, "^"))
end

-- key = character key, "-" to ignore this person, nil to forget the link
function RH.Link(userId, key)
  if not P.CanEdit() or not userId or userId == "" then return false end
  local g = G()
  local cur = g.rhLinks[userId]
  local l = { key = key or "", ts = math.max(ns.Now(), (cur and cur.ts or 0) + 1), by = ns.MyKey() }
  g.rhLinks[userId] = l
  SendLink(userId, l)
  return true
end

ns.CommHandlers.h = function(sender, payload)
  local f = Enc.Split(payload, "^")
  if f[1] ~= "1" or not f[2] or f[2] == "" then return end
  if not ns.OfficerSent(sender, f[5]) then return end
  local g = G()
  if not g then return end
  local ts = Enc.FromB36(f[4]) or 0
  if not ns.TimeOK(ts) then return end
  local cur = g.rhLinks[f[2]]
  if cur and (cur.ts or 0) >= ts then return end
  g.rhLinks[f[2]] = { key = f[3] or "", ts = ts, by = f[5] }
end

------------------------------------------------------------------------
-- Parsing
------------------------------------------------------------------------
-- returns event = { title, start, finish, minutes, leader, id, entries = { ... } } or nil, error
function RH.Parse(text)
  text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return nil, "Paste the Raid-Helper export first." end
  local ok, data = pcall(ns.json.decode, text)
  if not ok or type(data) ~= "table" then return nil, "That doesn't look like Raid-Helper's JSON export." end
  if type(data.signUps) ~= "table" then
    if type(data.slots) == "table" then
      return nil, "That's a Composition Tool export. Use the export of the event itself (it has the sign-ups)."
    end
    return nil, "No sign-ups found in that export."
  end
  local start = tonumber(data.startTime)
  if not start then return nil, "The export has no start time." end
  local finish = tonumber(data.endTime)
  local minutes = (finish and finish > start) and math.floor((finish - start) / 60 + 0.5) or RH.DEFAULT_MINUTES
  local ev = { title = data.displayTitle or data.title or "Raid", start = start, minutes = minutes,
               leader = data.leaderName, id = tostring(data.id or ""), entries = {} }
  for _, s in ipairs(data.signUps) do
    if type(s) == "table" and s.name and (s.status == nil or s.status == "primary" or s.status == "queued") then
      local cls = s.className or ""
      local status = STATUS_CLASS[cls] or "A"
      local classFile = CLASS[cls] or SPEC_CLASS[s.specName or ""]
      local spec = (s.specName or ""):gsub("1$", ""):gsub("_DPS$", "")
      local e = {
        -- people added by hand in Raid-Helper have no Discord ID: remember them by name
        name = tostring(s.name), userId = s.userId and tostring(s.userId) or ("n:" .. tostring(s.name):lower()),
        status = status, bench = cls == "Bench", class = classFile, spec = spec ~= "" and spec or nil,
        role = ROLE[s.roleName or ""], ts = tonumber(s.entryTime) or start - 86400,
      }
      e.key, e.how = RH.Match(e.userId, e.name)
      ev.entries[#ev.entries + 1] = e
    end
  end
  table.sort(ev.entries, function(a, b)
    if a.status ~= b.status then return (ns.Events.STATUS_ORDER[a.status] or 9) < (ns.Events.STATUS_ORDER[b.status] or 9) end
    return a.name:lower() < b.name:lower()
  end)
  return ev
end

------------------------------------------------------------------------
-- Import
------------------------------------------------------------------------
-- more than a year away (or 2 years ago): a placeholder date or a typo, not a real raid
function RH.Unrealistic(ev)
  local now = ns.Now()
  return ev.start > now + 365 * 86400 or ev.start < now - 2 * 365 * 86400
end

-- the FableHub raid night starting within 2 hours of the event, if any
function RH.FindNight(ev)
  local best, bestDiff
  for _, occ in ipairs(ns.Events.Occurrences(ev.start - 3 * 3600, ev.start + 3 * 3600)) do
    local diff = math.abs(occ.start - ev.start)
    if diff <= 2 * 3600 and (not bestDiff or diff < bestDiff) then best, bestDiff = occ, diff end
  end
  return best
end

-- create a one-off raid night for the event (officers)
function RH.CreateNight(ev)
  if not P.CanEdit() or RH.Unrealistic(ev) then return nil end
  local saved = ns.Events.Save({ title = ev.title, raid = "Other", duration = ev.minutes, weekly = false, anchors = { ev.start } })
  return RH.FindNight(ev), saved
end

-- write the matched sign-ups onto a raid night; returns imported, skipped (newer in-game answer), unmatched
function RH.Import(ev, occ)
  if not P.CanEdit() or not occ then return 0, 0, 0 end
  local g = ns.GuildDB()
  g.signups[occ.id] = g.signups[occ.id] or {}
  local list = g.signups[occ.id]
  local imported, skipped, unmatched = 0, 0, 0
  for _, e in ipairs(ev.entries) do
    if not e.key then
      unmatched = unmatched + 1
    else
      local cur = list[e.key]
      -- sign-ups imported by 0.13.0-0.13.2 carry a "Raid-Helper" note: re-importing clears it
      local oldLabel = cur and cur.ts == e.ts and (cur.note == "Raid-Helper" or cur.note == "Bench (Raid-Helper)")
      if cur and (cur.ts or 0) >= e.ts and not oldLabel then
        skipped = skipped + 1
      else
        local s = { status = e.status, char = e.key, role = e.role, ts = oldLabel and e.ts + 1 or e.ts,
                    note = e.bench and "Bench" or "", src = "rh" }
        list[e.key] = s
        ns.Send("S", ns.Events.EncodeSignup(occ.id, e.key, s))
        imported = imported + 1
      end
    end
  end
  ns.Fire("EVENTS_CHANGED")
  return imported, skipped, unmatched
end
