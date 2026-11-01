-- Cleanup: forget members who left the guild, and age out old saved data.
--
-- g.missing[charKey] = when this client first saw the character absent from the
--   guild roster. A character still absent after FORGET_AFTER is removed from
--   every per-member table. Each client times this from its own first sighting,
--   so nothing about it is synced. Someone who rejoins just has the mark cleared.
-- Records for characters outside the roster are refused by the sync code
-- (ns.StoreSummaries / the record handlers), so forgotten data doesn't come back.

local _, ns = ...
local C = {}
ns.Cleanup = C

C.FORGET_AFTER = 7 * 86400     -- absent from the roster this long: forget them
C.CHECK_EVERY = 300            -- look at the roster at most every 5 minutes
C.LOOT_KEEP_DAYS = 365         -- loot history older than this is dropped
C.ITEM_INDEX_MAX = 20000       -- item names cache (account-wide): trim above this...
C.ITEM_INDEX_TRIM = 15000      -- ...down to this, keeping items still in use

-- per-member tables keyed by character key
local MEMBER_TABLES = { "members", "partials", "addonUsers", "alts", "whisperNames", "owner" }

local function Count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

-- every character this guild's saved data knows about
local function KnownKeys(g)
  local keys = {}
  for _, name in ipairs(MEMBER_TABLES) do
    local t = g[name]
    if type(t) == "table" then for key in pairs(t) do keys[key] = true end end
  end
  return keys
end

-- The roster is only trusted when it's loaded and includes us: right after
-- login (or a guild change) it can be empty or partial for a moment.
local function RosterReady()
  if not IsInGuild() or not next(ns.roster) then return false end
  local me = ns.MyKey()
  return me ~= nil and ns.roster[me] ~= nil
end

-- Removes one character from every per-member table.
function C.Forget(g, key)
  for _, name in ipairs(MEMBER_TABLES) do
    local t = g[name]
    if type(t) == "table" then t[key] = nil end
  end
  if g.missing then g.missing[key] = nil end
end

-- Marks absent characters, clears marks for ones back in the roster, and
-- forgets anyone absent for FORGET_AFTER. Returns the number forgotten.
function C.CheckRoster(g)
  if not g or not RosterReady() then return 0 end
  g.missing = g.missing or {}
  local now, me = ns.Now(), ns.MyKey()
  local known = KnownKeys(g)
  for key in pairs(g.missing) do known[key] = true end
  local total, absent = 0, {}
  for key in pairs(known) do
    total = total + 1
    if ns.roster[key] or key == me then
      g.missing[key] = nil
    else
      absent[#absent + 1] = key
    end
  end
  -- more than half the guild gone at once is far more likely a broken roster
  -- (or a guild rename) than a real exodus: change nothing
  if #absent * 2 > total then
    ns.Debug(("cleanup: %d of %d characters missing from the roster, skipped"):format(#absent, total))
    return 0
  end
  local gone = {}
  for _, key in ipairs(absent) do
    local since = g.missing[key]
    if not since or since > now then
      g.missing[key] = now
    elseif now - since >= C.FORGET_AFTER then
      gone[#gone + 1] = key
    end
  end
  for _, key in ipairs(gone) do C.Forget(g, key) end
  if #gone > 0 then
    ns.Debug(("cleanup: forgot %d character(s) no longer in the guild"):format(#gone))
    ns.Fire("MEMBERS_FORGOTTEN", gone)
    ns.Fire("DATA_CHANGED")
  end
  return #gone
end

-- Drops loot history older than LOOT_KEEP_DAYS, and deleted entries once
-- they're older than catch-up passes on (nobody can send the entry back then).
function C.AgeLoot(g)
  if not g or type(g.loot) ~= "table" then return 0 end
  local now = ns.Now()
  local keepFrom = now - C.LOOT_KEEP_DAYS * 86400
  local syncFrom = now - ((ns.Loot and ns.Loot.SYNC_DAYS) or 180) * 86400
  local n = 0
  for id, e in pairs(g.loot) do
    local at = type(e) == "table" and e.at or 0
    if at < keepFrom or (e.deleted and at <= syncFrom) then
      g.loot[id] = nil
      n = n + 1
    end
  end
  if n > 0 then ns.Fire("LOOT_CHANGED") end
  return n
end

-- Item IDs any saved guild still refers to (priorities, seen drops, loot history).
local function ItemsInUse()
  local used = {}
  for _, g in pairs(FableHubDB.guilds or {}) do
    if g.tmb and type(g.tmb.items) == "table" then for id in pairs(g.tmb.items) do used[id] = true end end
    if type(g.seen) == "table" then for id in pairs(g.seen) do used[id] = true end end
    if type(g.loot) == "table" then
      for _, e in pairs(g.loot) do if type(e) == "table" and e.item then used[e.item] = true end end
    end
  end
  return used
end

-- Keeps the account-wide item names cache from growing forever. Items still in
-- use are always kept; the rest are dropped (the game reloads names on demand).
function C.TrimItemIndex()
  local idx = FableHubDB and FableHubDB.itemIndex
  if type(idx) ~= "table" then return 0 end
  local size = Count(idx)
  if size <= C.ITEM_INDEX_MAX then return 0 end
  local used = ItemsInUse()
  local n = 0
  for id in pairs(idx) do
    if size - n <= C.ITEM_INDEX_TRIM then break end
    if not used[id] then idx[id] = nil; n = n + 1 end
  end
  return n
end

local lastCheck = -math.huge
ns.On("ROSTER_CHANGED", function()
  local t = GetTime()
  if t - lastCheck < C.CHECK_EVERY then return end
  local g = ns.GuildDB()
  if not g or not RosterReady() then return end
  lastCheck = t
  C.CheckRoster(g)
end)

ns.On("LOGIN", function()
  -- once a session, after login traffic has settled
  C_Timer.After(60, function()
    local g = ns.GuildDB()
    if g then C.AgeLoot(g) end
    C.TrimItemIndex()
  end)
end)
