-- Camping: Forever's camp items, and camp plans (who brings what to a campfire).
--
-- Data from the Forever beta (Warcraft Tavern, Method, wow-professions.com, Oct 2026).
-- Most buff values aren't published yet; edit this file as they're confirmed.
--
-- Rules as known:
--   * A Cooking campfire has 3 (Basic), 5 (Journeyman) or 10 (Expert) item slots.
--   * Each player can place one camp item; placing one puts their camp items on a 1 hour cooldown.
--   * Every profession has 3 tiers (20 / 140 / 300 skill). A higher tier keeps the lower
--     tiers' benefit and adds a workstation or utility, and replaces it without using a slot.
--   * Sit by the fire for about a minute to get Camp Benefits for 1 hour.
--   * Camp buffs are weaker than the class buff they resemble and don't stack with it.

local _, ns = ...
local C = {}
ns.Camping = C

local I = "Interface\\Icons\\"

C.FIRES = {
  { id = "basic", name = "Basic Campfire", slots = 3, cooking = 1 },
  { id = "journeyman", name = "Journeyman Campfire", slots = 5, cooking = 90 },
  { id = "expert", name = "Expert Campfire", slots = 10, cooking = 220, note = "Learned at 200 Cooking, usable at 220" },
}
C.FIRE_BY_ID = {}
for _, f in ipairs(C.FIRES) do C.FIRE_BY_ID[f.id] = f end
C.COOKING = 185

-- One line per profession: its buff (from tier 1) and the three tiers.
--   buff      what the camp gives (nil = no buff, a service instead)
--   value     the number if published
--   noStack   ids from Buffs.lua whose class buff replaces it
C.LINES = {
  { prof = 171, profName = "Alchemy", buff = "Mana regeneration", noStack = { "wisdom" }, icon = I .. "Trade_Alchemy",
    tiers = { { "Mana Well", 20, nil }, { "Fermenter", 140, "Workstation for some Alchemy reagents" },
              { "Alchemy Laboratory", 300, "Workstation for some Alchemy recipes" } } },
  { prof = 164, profName = "Blacksmithing", buff = "Strength", noStack = { "soe" }, icon = I .. "Trade_BlackSmithing",
    tiers = { { "Sharpening Wheel", 20, nil }, { "Anvil", 140, "Anvil for Blacksmithing anywhere you camp" },
              { "Master Forge", 300, "Forge for many Blacksmithing plans" } } },
  { prof = 333, profName = "Enchanting", buff = "All stats, armor and resistances", noStack = { "motw" }, icon = I .. "Trade_Engraving",
    tiers = { { "Enchanted Lute", 20, nil }, { "Arcane Salvager", 140, "Better disenchanting" },
              { "Arcane Forge", 300, "Workstation for some Enchanting formulas" } } },
  { prof = 202, profName = "Engineering", buff = nil, service = "Reagent vendor and bag cleaning", icon = I .. "Trade_Engineering",
    tiers = { { "Reagent Bot", 20, nil }, { "Repair Bot", 140, "Repairs for everyone at the camp" },
              { "Anarchist's Workbench", 300, "Workstation for some schematics" } } },
  { prof = 165, profName = "Leatherworking", buff = nil, service = "Rested XP, 5% of a level (once an hour)", icon = I .. "Trade_LeatherWorking",
    tiers = { { "Camp Tent", 20, nil }, { "Tanning Rack", 140, "Workstation for many Leatherworking recipes" },
              { "Sewing Machine", 300, "Workstation for many Leatherworking patterns" } } },
  { prof = 197, profName = "Tailoring", buff = "Spirit", noStack = { "spirit" }, icon = I .. "Trade_Tailoring",
    tiers = { { "Faction Banner", 20, nil }, { "Spinning Wheel", 140, "Workstation for many Tailoring recipes" },
              { "Loom", 300, "Workstation for many Tailoring patterns" } } },
  { prof = 182, profName = "Herbalism", buff = "Intellect", noStack = { "int" }, icon = I .. "Trade_Herbalism",
    tiers = { { "Incense Candle", 20, nil }, { "Greenhouse", 140, "Plant seeds and grow herbs" },
              { "Seed Hybridizer", 300, "Multiply seeds or combine them into rarer ones" } } },
  { prof = 186, profName = "Mining", buff = "Melee attack power", noStack = { "might" }, icon = I .. "Trade_Mining",
    tiers = { { "Lodestone", 20, nil }, { "Rock Garden", 140, "Grows a common mining node over time" },
              { "Molten Foundry", 300, "Needed for some smelting (e.g. Heavy Thorium)" } } },
  { prof = 393, profName = "Skinning", buff = "Critical strike chance", value = "+2% crit", noStack = { "moonkin", "lotp" },
    icon = I .. "INV_Misc_Pelt_Wolf_01",
    tiers = { { "Camp Chair", 20, nil }, { "Field Guide", 140, "Anyone can learn Track Beasts" },
              { "Trapper's Workbench", 300, "Workbench with a trap" } } },
  { prof = 185, profName = "Cooking", buff = "Stamina (food)", firstTier = 2, icon = I .. "INV_Misc_Food_15",
    tiers = { nil, { "Cookie's Feast", 140, nil },
              { "Iron Oven", 300, "Needed for the most advanced Cooking recipes" } } },
  { prof = 129, profName = "First Aid", buff = "Stamina", noStack = { "fort" }, icon = I .. "Spell_Holy_SealOfSacrifice",
    tiers = { { "First Aid Kit", 20, nil }, { "Toxin Study", 140, "Healing potions and anti-venom" },
              { "Plague Doctor's Laboratory", 300, "Healing potions and poultices" } } },
  { prof = 356, profName = "Fishing", buff = "All stats", value = "+8% all stats", noStack = { "kings" }, icon = I .. "Trade_Fishing",
    tiers = { { "Fish Bowl", 20, nil }, { "Fishing Rack", 140, "Uncommon fish for 1 hour, and lures" },
              { "Fishing Hut", 300, "Rare fish for 1 hour, and lures" } } },
}

-- Flatten into items: id = "<prof>:<tier>"
C.ITEMS, C.ITEM_BY_ID = {}, {}
for _, line in ipairs(C.LINES) do
  for tier = 1, 3 do
    local t = line.tiers[tier]
    if t then
      local item = {
        id = line.prof .. ":" .. tier, line = line, prof = line.prof, profName = line.profName, tier = tier,
        name = t[1], skill = t[2], extra = t[3], icon = line.icon,
      }
      -- everything the item does: the line's buff/service plus each tier's extra up to this one
      item.effects = {}
      if line.buff then item.effects[#item.effects + 1] = line.buff .. (line.value and (" (" .. line.value .. ")") or "") end
      if line.service then item.effects[#item.effects + 1] = line.service end
      for k = 2, tier do
        local up = line.tiers[k]
        if up and up[3] then item.effects[#item.effects + 1] = up[3] end
      end
      C.ITEMS[#C.ITEMS + 1] = item
      C.ITEM_BY_ID[item.id] = item
    end
  end
end

------------------------------------------------------------------------
-- Who can make what
------------------------------------------------------------------------
local function RecordFor(key)
  if key == ns.MyKey() then return ns.MyRecord() end
  local g = ns.GuildDB()
  return g and g.members[key]
end

-- skill in a profession, or nil when we don't know (member not using FableHub)
function C.Skill(key, prof)
  local rec = RecordFor(key)
  if not rec or not rec.profs or (rec.ts or 0) == 0 then return nil end
  local p = rec.profs[prof]
  return p and p.rank or 0
end

-- members who can make an item: { { key, skill, online } }, best first
function C.Makers(item)
  local out = {}
  for _, m in ipairs(ns.AllMembers()) do
    local skill = C.Skill(m.key, item.prof)
    if skill and skill >= item.skill then
      out[#out + 1] = { key = m.key, skill = skill, online = ns.IsOnline(m.key) }
    end
  end
  table.sort(out, function(a, b)
    if a.online ~= b.online then return a.online end
    if a.skill ~= b.skill then return a.skill > b.skill end
    return a.key < b.key
  end)
  return out
end

------------------------------------------------------------------------
-- Plans (saved on this computer, per guild)
--   plan = { id, name, fire, builder, slots = { [i] = { item = id, key = memberKey } } }
------------------------------------------------------------------------
function C.Plans()
  local g = ns.GuildDB()
  if not g then return {} end
  g.campPlans = g.campPlans or {}
  return g.campPlans
end

function C.List()
  local out = {}
  for _, p in pairs(C.Plans()) do out[#out + 1] = p end
  table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
  return out
end

local counter = 0
function C.New(name)
  counter = counter + 1
  local plan = { id = "c" .. ns.Encode.ToB36(ns.Now()) .. counter, name = name or "Camp", fire = "basic", slots = {} }
  C.Plans()[plan.id] = plan
  ns.Fire("CAMP_CHANGED")
  return plan
end

function C.Delete(plan)
  C.Plans()[plan.id] = nil
  ns.Fire("CAMP_CHANGED")
end

function C.SlotCount(plan) return (C.FIRE_BY_ID[plan.fire] or C.FIRES[1]).slots end

function C.SetFire(plan, fireId)
  plan.fire = fireId
  for i in pairs(plan.slots) do if i > C.SlotCount(plan) then plan.slots[i] = nil end end
  ns.Fire("CAMP_CHANGED")
end

function C.SetSlot(plan, i, itemId, key)
  plan.slots[i] = plan.slots[i] or {}
  if itemId ~= nil then plan.slots[i].item = itemId or nil end
  if key ~= nil then plan.slots[i].key = key or nil end
  if not plan.slots[i].item and not plan.slots[i].key then plan.slots[i] = nil end
  ns.Fire("CAMP_CHANGED")
end

------------------------------------------------------------------------
-- The group to check camp buffs against
------------------------------------------------------------------------
-- keys of the people in your party/raid right now
function C.GroupKeys()
  local out = { ns.MyKey() }
  if IsInRaid and IsInRaid() then
    out = {}
    for i = 1, (GetNumGroupMembers and GetNumGroupMembers()) or 0 do
      local key = ns.Events.ResolveKey((GetRaidRosterInfo(i)))
      if key then out[#out + 1] = key end
    end
  elseif IsInGroup and IsInGroup() then
    for i = 1, 4 do
      local unit = "party" .. i
      if UnitExists and UnitExists(unit) then
        local name, realm = UnitFullName(unit)
        local key = name and ns.Events.ResolveKey(realm and realm ~= "" and (name .. "-" .. realm) or name)
        if key then out[#out + 1] = key end
      end
    end
  end
  return out
end

-- class buffs the group already has: { [buffId] = { providers } }
function C.ClassBuffs(source)
  local keys
  if source and source ~= "group" then
    local raidPlan = ns.Plans.Get(source)
    keys = {}
    if raidPlan then for i, k in pairs(raidPlan.slots) do if i <= raidPlan.size then keys[#keys + 1] = k end end end
  else
    keys = C.GroupKeys()
  end
  local have = {}
  for _, key in ipairs(keys) do
    local d = ns.Plans.Describe(nil, key)
    for id in pairs(d.buffs or {}) do
      have[id] = have[id] or {}
      table.insert(have[id], d)
    end
  end
  return have, #keys
end

------------------------------------------------------------------------
-- Checking a plan
------------------------------------------------------------------------
-- returns { gives = { { item, effects, redundant = { buff, providers } } }, warnings = { text } }
function C.Check(plan, source)
  local res = { gives = {}, warnings = {}, perSlot = {} }
  local fire = C.FIRE_BY_ID[plan.fire] or C.FIRES[1]
  local classBuffs = C.ClassBuffs(source)

  if plan.builder then
    local cook = C.Skill(plan.builder, C.COOKING)
    if cook and cook < fire.cooking then
      res.warnings[#res.warnings + 1] = ("%s needs %d Cooking for a %s (has %d)."):format(ns.ShortName(plan.builder), fire.cooking, fire.name, cook)
    end
  end

  local usedBy, lines = {}, {}
  for i = 1, fire.slots do
    local s = plan.slots[i]
    local item = s and s.item and C.ITEM_BY_ID[s.item]
    local issues = {}
    if s and s.key then
      if usedBy[s.key] then
        issues[#issues + 1] = "already bringing something"
        res.warnings[#res.warnings + 1] = ("%s is in two slots, but each player can place only one item."):format(ns.ShortName(s.key))
      end
      usedBy[s.key] = true
      if item then
        local skill = C.Skill(s.key, item.prof)
        if skill and skill < item.skill then
          issues[#issues + 1] = ("needs %d %s"):format(item.skill, item.profName)
          res.warnings[#res.warnings + 1] = ("%s needs %d %s for %s (has %d)."):format(ns.ShortName(s.key), item.skill, item.profName, item.name, skill)
        elseif skill == nil then
          issues[#issues + 1] = "skill unknown"
        end
      end
    end
    if item then
      if lines[item.prof] then
        issues[#issues + 1] = "same profession twice"
        res.warnings[#res.warnings + 1] = ("Two %s items: their buffs are the same and won't stack."):format(item.profName)
      end
      lines[item.prof] = true
      local redundant
      for _, b in ipairs(item.line.noStack or {}) do
        if classBuffs[b] then redundant = { buff = ns.BUFF_BY_ID[b], providers = classBuffs[b] } break end
      end
      if redundant then issues[#issues + 1] = "covered by " .. redundant.buff.name end
      res.gives[#res.gives + 1] = { slot = i, item = item, key = s.key, effects = item.effects, redundant = redundant }
    end
    res.perSlot[i] = issues
  end
  return res
end

------------------------------------------------------------------------
-- Chat summary (only when someone clicks Post)
------------------------------------------------------------------------
function C.SummaryLines(plan)
  local fire = C.FIRE_BY_ID[plan.fire] or C.FIRES[1]
  local parts = {}
  for i = 1, fire.slots do
    local s = plan.slots[i]
    local item = s and s.item and C.ITEM_BY_ID[s.item]
    if item then parts[#parts + 1] = (s.key and (ns.ShortName(s.key) .. ": ") or "") .. item.name end
  end
  local head = ("Camp \"%s\" (%s%s): "):format(plan.name, fire.name, plan.builder and (" by " .. ns.ShortName(plan.builder)) or "")
  -- split into chat-sized lines
  local lines, cur = {}, head
  for i, p in ipairs(parts) do
    local piece = p .. (i < #parts and ", " or "")
    if #cur + #piece > 240 then lines[#lines + 1] = cur; cur = "" end
    cur = cur .. piece
  end
  if #parts == 0 then cur = cur .. "no items yet" end
  lines[#lines + 1] = cur
  return lines
end

function C.Post(plan, channel)
  if not SendChatMessage then return false end
  for _, line in ipairs(C.SummaryLines(plan)) do pcall(SendChatMessage, line, channel) end
  return true
end
