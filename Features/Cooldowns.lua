-- Cooldowns: profession cooldowns (transmutes, Mooncloth, Salt Shaker...) for
-- every character, so the guild can see whose are ready.
--
-- Each character's own FableHub reads their cooldowns and keeps them in their
-- record, which already goes to the guild:
--   rec.cds[id] = { ready = server time it's ready (0 = ready when checked), dur = seconds }
--   rec.cdChecked = when they were last read
-- The list of cooldowns is in Data/Cooldowns.lua.

local _, ns = ...
local CD = {}
ns.Cooldowns = CD

CD.SOON = 86400               -- under a day left counts as "almost ready"
CD.STALE = 14 * 86400         -- not read for this long: it may have been used since
CD.CHECK_EVERY = 20 * 3600    -- re-read and re-share unchanged cooldowns at most this often
local SAME = 120              -- ready times this close are the same (timers drift a little)

local function SafeCall(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, a, b, c = pcall(fn, ...)
  if ok then return a, b, c end
  return nil
end

------------------------------------------------------------------------
-- Which recipes belong to a cooldown
------------------------------------------------------------------------
-- the cooldown id of a recipe in this profession, or nil
function CD.OfRecipe(recipeID, skillLine)
  local id = ns.COOLDOWN_OF_RECIPE[recipeID]
  if id then return id end
  for _, cd in ipairs(ns.COOLDOWNS) do
    if cd.prefix and cd.skillLine == skillLine and ns.RecipeName then
      local name, loaded = ns.RecipeName(recipeID)
      if loaded and name:sub(1, #cd.prefix) == cd.prefix then return cd.id end
    end
  end
  return nil
end

------------------------------------------------------------------------
-- Reading your own cooldowns
------------------------------------------------------------------------
local function SpellCooldown(id)
  if C_Spell and C_Spell.GetSpellCooldown then
    local info = SafeCall(C_Spell.GetSpellCooldown, id)
    if type(info) == "table" then return info.startTime or 0, info.duration or 0 end
  end
  local start, dur = SafeCall(GetSpellCooldown, id)
  return start or 0, dur or 0
end

local function ItemCooldown(id)
  local start, dur = SafeCall((C_Container and C_Container.GetItemCooldown) or GetItemCooldown, id)
  return start or 0, dur or 0
end

local function OwnsItem(id)
  local n = SafeCall((C_Item and C_Item.GetItemCount) or GetItemCount, id, true)
  return (n or 0) > 0
end

-- a recipe of this cooldown you know, if any
local function KnownSpell(cd, rec)
  local p = rec.profs and rec.profs[cd.skillLine]
  local known = p and p.recipes or {}
  for _, id in ipairs(cd.spells or {}) do
    if known[id] or SafeCall(IsPlayerSpell, id) then return id end
  end
  if cd.prefix and p then
    for id in pairs(known) do
      if CD.OfRecipe(id, cd.skillLine) == cd.id then return id end
    end
  end
  return nil
end

-- what the game says right now: { [id] = { ready, dur } }
local function ReadCooldowns(rec, now)
  local found = {}
  for _, cd in ipairs(ns.COOLDOWNS) do
    local start, dur, has = 0, 0, false
    if cd.item then
      if OwnsItem(cd.item) then has = true; start, dur = ItemCooldown(cd.item) end
    else
      local spell = KnownSpell(cd, rec)
      if spell then has = true; start, dur = SpellCooldown(spell) end
    end
    if has then
      -- short durations are the global cooldown, not the profession one
      local left = (start > 0 and dur > 60) and (start + dur - GetTime()) or 0
      local old = rec.cds and rec.cds[cd.id]
      found[cd.id] = {
        ready = left > 0 and math.floor(now + left + 0.5) or 0,
        dur = dur > 60 and math.floor(dur + 0.5) or (old and old.dur) or 0,
      }
    end
  end
  return found
end

-- when a stored cooldown is ready, as a time still to come (0 = already ready)
local function Pending(e, now)
  local r = e and e.ready or 0
  return r > now and r or 0
end

function CD.ScanOwn()
  local rec = ns.MyRecord()
  if not rec or not rec.profs then return end
  local now = ns.Now()
  local found = ReadCooldowns(rec, now)
  local old = rec.cds or {}
  local changed = false
  for id, e in pairs(found) do
    local o = old[id]
    if not o or math.abs(Pending(o, now) - e.ready) > SAME or (e.dur > 0 and o.dur ~= e.dur) then changed = true end
  end
  for id in pairs(old) do if not found[id] then changed = true end end
  local due = next(found) ~= nil and now - (rec.cdChecked or 0) >= CD.CHECK_EVERY
  if changed or due then
    rec.cds = next(found) and found or nil
    rec.cdChecked = now
    if ns.RecordChanged then ns.RecordChanged(rec) end
  end
end

local scanPending = false
local function QueueScan(delay)
  if scanPending then return end
  scanPending = true
  C_Timer.After(delay or 3, function()
    scanPending = false
    local ok, err = pcall(CD.ScanOwn)
    if not ok then ns.ReportError("cooldowns: " .. tostring(err)) end
  end)
end
CD.QueueScan = QueueScan

ns.On("LOGIN", function() QueueScan(12) end)
for _, e in ipairs({ "SPELL_UPDATE_COOLDOWN", "BAG_UPDATE_COOLDOWN", "TRADE_SKILL_SHOW", "NEW_RECIPE_LEARNED" }) do
  ns.RegisterEvent(e, function() QueueScan(3) end)
end

------------------------------------------------------------------------
-- Reading anyone's cooldowns
------------------------------------------------------------------------
-- nil if the record has no such cooldown, else
-- { state = "ready"|"soon"|"cooling"|"unknown", left, ready, dur, age }
function CD.Info(rec, id)
  local e = rec and rec.cds and rec.cds[id]
  if not e then return nil end
  local now = ns.Now()
  local left = (e.ready or 0) - now
  local age = now - (rec.cdChecked or rec.ts or 0)
  local state
  if left > 0 then state = left < CD.SOON and "soon" or "cooling"
  else state = age > CD.STALE and "unknown" or "ready" end
  return { state = state, left = math.max(0, left), ready = e.ready or 0, dur = e.dur or 0, age = age }
end

-- the cooldowns a record has, in data-file order
function CD.Of(rec)
  local out = {}
  if rec and rec.cds then
    for _, cd in ipairs(ns.COOLDOWNS) do
      if rec.cds[cd.id] then out[#out + 1] = cd end
    end
  end
  return out
end

-- "2d 4h", "18h" ("18h 12m" when long), "25m"
function CD.FormatLeft(sec, long)
  local m = math.max(0, math.floor(sec / 60 + 0.5))
  local d, h, mm = math.floor(m / 1440), math.floor((m % 1440) / 60), m % 60
  if d > 0 then return ("%dd %dh"):format(d, h) end
  if h > 0 then return long and ("%dh %dm"):format(h, mm) or (h .. "h") end
  return mm .. "m"
end

function CD.FormatDuration(sec)
  if not sec or sec <= 0 then return nil end
  local hours = math.floor(sec / 3600 + 0.5)
  if hours >= 24 and hours % 24 == 0 then
    local d = hours / 24
    return d == 1 and "1 day" or (d .. " days")
  end
  return hours .. " hours"
end

local function Ago(sec)
  if sec < 3600 then return math.max(1, math.floor(sec / 60)) .. "m" end
  if sec < 2 * 86400 then return math.floor(sec / 3600) .. "h" end
  return math.floor(sec / 86400) .. "d"
end
CD.Ago = Ago

local COLORS = { ready = "40d66e", unknown = "8c8c8c", cooling = "8c8c8c" }

-- the short coloured text after an icon: Ready, 18h, 2d 4h, ? 15d old
function CD.Text(info)
  if info.state == "ready" then return "|cff" .. COLORS.ready .. "Ready|r" end
  if info.state == "unknown" then return ("|cff%s? %s old|r"):format(COLORS.unknown, Ago(info.age)) end
  if info.state == "soon" then return ("|c%s%s|r"):format(ns.Theme.AccentHex(), CD.FormatLeft(info.left)) end
  return ("|cff%s%s|r"):format(COLORS.cooling, CD.FormatLeft(info.left))
end

local texCache = {}
function CD.Texture(cd)
  if texCache[cd.id] then return texCache[cd.id] end
  local tex
  if cd.item then
    tex = SafeCall(C_Item and C_Item.GetItemIconByID or GetItemIcon, cd.item)
  elseif cd.spells and cd.spells[1] then
    tex = SafeCall(C_Spell and C_Spell.GetSpellTexture or GetSpellTexture, cd.spells[1])
  end
  if not tex then return ns.Icons.ProfessionTexture(cd.skillLine) end -- not loaded yet: try again next time
  texCache[cd.id] = tex
  return tex
end

-- icon markup, darkened unless ready
local TINT = { ready = "255:255:255", soon = "170:150:130", cooling = "110:110:110", unknown = "70:70:70" }
function CD.Icon(cd, state, size)
  size = size or 14
  return ("|T%s:%d:%d:0:0:64:64:5:59:5:59:%s|t"):format(tostring(CD.Texture(cd)), size, size, TINT[state] or TINT.cooling)
end

-- icon + text for one cooldown of a record ("" if it has none)
function CD.Badge(rec, cd, size)
  local info = CD.Info(rec, cd.id)
  if not info then return "" end
  return CD.Icon(cd, info.state, size) .. " " .. CD.Text(info)
end

-- tooltip lines for one character's cooldown
function CD.AddTooltip(tt, rec, cd)
  local info = CD.Info(rec, cd.id)
  if not info then return end
  if info.state == "ready" then
    tt:AddDoubleLine(CD.Icon(cd, "ready", 14) .. " " .. cd.name, "Ready", 1, 1, 1, 0.25, 0.84, 0.43)
  elseif info.state == "unknown" then
    tt:AddDoubleLine(CD.Icon(cd, "unknown", 14) .. " " .. cd.name, "Unknown", 1, 1, 1, 0.6, 0.6, 0.6)
  else
    local at = date("%a %H:%M", info.ready)
    tt:AddDoubleLine(CD.Icon(cd, info.state, 14) .. " " .. cd.name,
      CD.FormatLeft(info.left, true) .. "  (" .. at .. ")", 1, 1, 1, 0.8, 0.8, 0.8)
  end
end

-- how many cooldowns are ready among these records (optionally only some cooldowns)
function CD.CountReady(records, only)
  local n = 0
  for _, rec in pairs(records) do
    for _, cd in ipairs(ns.COOLDOWNS) do
      if not only or only[cd.id] then
        local info = CD.Info(rec, cd.id)
        if info and info.state == "ready" then n = n + 1 end
      end
    end
  end
  return n
end
