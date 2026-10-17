-- Ready check: when a ready check starts (or you click "Check now"), look at
-- everyone in the group for a flask or elixirs, food, other consumables, class
-- buffs, and missing enchants. Runs on each player's own FableHub, nothing is
-- sent to the guild. Only the latest check is kept.
--
-- Buffs are read for the whole group. Enchants need an inspect, which only
-- works within about 28 yards, so far-away players show "?" until they come close.

local _, ns = ...
local RC = {}
ns.ReadyCheck = RC

RC.last = nil -- { at, source, players = { list of player }, classes = { CLASS = n } }

local buffById
local function BuffById(id)
  if not buffById then
    buffById = {}
    for _, b in ipairs(ns.BUFFS or {}) do buffById[b.id] = b end
  end
  return buffById[id]
end

local function Auras(unit)
  local out = {}
  for i = 1, 40 do
    local name, id
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
      local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HELPFUL")
      if not ok or not a then break end
      name, id = a.name, a.spellId
    elseif UnitBuff then
      local ok, n, _, _, _, _, _, _, _, _, sid = pcall(UnitBuff, unit, i)
      if not ok or not n then break end
      name, id = n, sid
    else
      break
    end
    -- some clients hide aura details in combat; skip anything unreadable
    if type(name) == "string" then out[#out + 1] = { name = name, id = type(id) == "number" and id or nil } end
  end
  return out
end
RC.Auras = Auras

-- does this aura list contain the buff (by any of its spell names or ids)?
local function HasBuff(auras, buff)
  if not buff then return false end
  local names = {}
  for _, n in ipairs(buff.detect or { buff.name }) do names[n] = true end
  local ids = {}
  for _, i in ipairs(buff.ids or {}) do ids[i] = true end
  for _, a in ipairs(auras) do
    if names[a.name] or (a.id and ids[a.id]) then return true end
  end
  return false
end

-- group members as { unit, name, class }
local function GroupUnits()
  local out = {}
  if IsInRaid and IsInRaid() then
    for i = 1, ((GetNumGroupMembers and GetNumGroupMembers()) or 0) do
      local name, _, _, _, _, classFile = GetRaidRosterInfo(i)
      if name then out[#out + 1] = { unit = "raid" .. i, name = name, class = classFile } end
    end
  else
    local _, myClass = UnitClass("player")
    out[1] = { unit = "player", name = UnitName and UnitName("player") or ns.ShortName(ns.MyKey()), class = myClass }
    if IsInGroup and IsInGroup() then
      for i = 1, 4 do
        local unit = "party" .. i
        if UnitExists and UnitExists(unit) then
          local _, cls = UnitClass(unit)
          out[#out + 1] = { unit = unit, name = UnitName(unit), class = cls }
        end
      end
    end
  end
  return out
end

------------------------------------------------------------------------
-- Enchants (needs inspect, except for yourself)
------------------------------------------------------------------------
-- returns list of missing slot numbers, or nil if the gear couldn't be read
function RC.MissingEnchants(unit)
  local Cons = ns.Consumables
  local missing, read = {}, 0
  for _, slot in ipairs(Cons.ENCHANT_SLOTS) do
    local link = GetInventoryItemLink and GetInventoryItemLink(unit, slot)
    if link then
      read = read + 1
      local skip = false
      if slot == 17 and C_Item and C_Item.GetItemInfoInstant then
        local _, _, _, equipLoc = C_Item.GetItemInfoInstant(link)
        skip = equipLoc and Cons.NO_ENCHANT_EQUIP[equipLoc] or false
      end
      local enchant = link:match("item:%-?%d+:(%-?%d*)")
      if not skip and (not enchant or enchant == "" or enchant == "0") then missing[#missing + 1] = slot end
    end
  end
  if read < 3 then return nil end
  return missing
end

local queue, inspecting = {}, nil

local function IsMe(unit)
  if unit == "player" then return true end
  return UnitIsUnit and UnitIsUnit(unit, "player") or false
end

local function NextInspection()
  if inspecting then
    if ns.Now() - inspecting.at > 4 then inspecting = nil else return end -- gave up waiting
  end
  if InCombatLockdown and InCombatLockdown() then return end
  while #queue > 0 do
    local p = table.remove(queue, 1)
    if IsMe(p.unit) then
      p.enchants = RC.MissingEnchants("player")
      ns.Fire("READYCHECK_CHANGED")
    elseif UnitExists and UnitExists(p.unit) and CanInspect and CanInspect(p.unit)
      and (not CheckInteractDistance or CheckInteractDistance(p.unit, 1)) and NotifyInspect then
      inspecting = { p = p, guid = UnitGUID and UnitGUID(p.unit), at = ns.Now() }
      NotifyInspect(p.unit)
      return
    end
  end
end

ns.RegisterEvent("INSPECT_READY", function(guid)
  local i = inspecting
  if not i or (i.guid and guid and guid ~= i.guid) then return end
  inspecting = nil
  local got = RC.MissingEnchants(i.p.unit)
  if got then i.p.enchants = got end
  if ClearInspectPlayer then ClearInspectPlayer() end
  ns.Fire("READYCHECK_CHANGED")
end)

-- try again for anyone still unread (e.g. they were out of range)
function RC.RetryEnchants()
  if not RC.last then return end
  queue = {}
  for _, p in ipairs(RC.last.players) do
    if not p.enchants then queue[#queue + 1] = p end
  end
end

------------------------------------------------------------------------
-- The check
------------------------------------------------------------------------
function RC.Run(source, keepEnchants)
  local Cons = ns.Consumables
  local units = GroupUnits()
  local classes = {}
  for _, u in ipairs(units) do if u.class then classes[u.class] = (classes[u.class] or 0) + 1 end end
  local players = {}
  for _, u in ipairs(units) do
    local auras = Auras(u.unit)
    local p = Cons.Classify(auras)
    p.unit, p.name, p.class = u.unit, u.name, u.class
    p.buffs = {}
    for _, cb in ipairs(Cons.CLASS_BUFFS) do
      local b = BuffById(cb.id)
      if b then
        local provided = false
        for cls in pairs(b.classes or {}) do if classes[cls] then provided = true end end
        p.buffs[cb.id] = { has = HasBuff(auras, b), expected = provided and not cb.optional, provided = provided }
      end
    end
    local blessings = 0
    p.blessingNames = {}
    for _, id in ipairs(Cons.BLESSINGS) do
      local b = BuffById(id)
      if b and HasBuff(auras, b) then blessings = blessings + 1; p.blessingNames[#p.blessingNames + 1] = b.name end
    end
    p.blessings = blessings
    p.blessingsNeeded = math.min(classes.PALADIN or 0, Cons.BLESSINGS_MAX)
    players[#players + 1] = p
  end
  table.sort(players, function(a, b) return (a.name or "") < (b.name or "") end)
  -- a re-check keeps enchants already read for the same players
  if keepEnchants and RC.last then
    local old = {}
    for _, q in ipairs(RC.last.players) do old[q.name or ""] = q.enchants end
    for _, q in ipairs(players) do q.enchants = old[q.name or ""] end
  end
  RC.last = { at = ns.Now(), source = source or "ready check", players = players, classes = classes }
  inspecting = nil
  RC.RetryEnchants()
  ns.Fire("READYCHECK_CHANGED")
  return RC.last
end

-- everything a player is missing, as short labels
function RC.Missing(p)
  local Cons = ns.Consumables
  local out = {}
  if not p.flaskOk then out[#out + 1] = "Flask" end
  if not p.food then out[#out + 1] = "Food" end
  for _, cb in ipairs(Cons.CLASS_BUFFS) do
    local b = p.buffs[cb.id]
    if b and b.expected and not b.has then out[#out + 1] = cb.short end
  end
  if p.blessings < p.blessingsNeeded then out[#out + 1] = "Blessings" end
  if p.enchants and #p.enchants > 0 then out[#out + 1] = "Enchants" end
  return out
end

ns.RegisterEvent("READY_CHECK", function()
  if not ns.Option("readyCheckAuto") then return end
  if not (IsInGroup and IsInGroup()) and not (IsInRaid and IsInRaid()) then return end
  RC.Run("ready check")
end)
-- people often buff during the check: look again when it ends
ns.RegisterEvent("READY_CHECK_FINISHED", function()
  if RC.last and ns.Now() - RC.last.at < 120 then RC.Run("ready check", true) end
end)

ns.On("LOGIN", function()
  if C_Timer and C_Timer.NewTicker then C_Timer.NewTicker(1.5, NextInspection) end
end)
