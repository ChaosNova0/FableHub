-- RecipeFacts: what a recipe makes, for the Recipes filters: the gear slot,
-- the armour type and which stats it gives.
--
-- Read from the game, not from a list: slot and armour type from the item's
-- info, stats from its tooltip text (gear, elixirs, Well Fed food) or, for
-- recipes that make no item (enchants), the spell's description.
-- Worked out once per item and kept for the session.

local _, ns = ...
local F = {}
ns.RecipeFacts = F

F.SLOTS = { "Head", "Neck", "Shoulder", "Back", "Chest", "Wrist", "Hands", "Waist", "Legs", "Feet",
            "Ring", "Trinket", "One-hand", "Two-hand", "Off-hand", "Ranged", "Bag" }
F.ARMORS = { "Cloth", "Leather", "Mail", "Plate" }
-- false = a divider in the menu
F.STATS = {
  { "str", "Strength" }, { "agi", "Agility" }, { "sta", "Stamina" }, { "int", "Intellect" }, { "spi", "Spirit" },
  false,
  { "ap", "Attack power" }, { "sp", "Spell damage" }, { "heal", "Healing" }, { "crit", "Crit" }, { "hit", "Hit" },
  { "mp5", "Mana regen" }, { "hp5", "Health regen" }, { "res", "Resistance" },
}
F.STAT_NAME = {}
for _, s in ipairs(F.STATS) do if s then F.STAT_NAME[s[1]] = s[2] end end

local SLOT_OF = {
  INVTYPE_HEAD = "Head", INVTYPE_NECK = "Neck", INVTYPE_SHOULDER = "Shoulder", INVTYPE_CLOAK = "Back",
  INVTYPE_CHEST = "Chest", INVTYPE_ROBE = "Chest", INVTYPE_WRIST = "Wrist", INVTYPE_HAND = "Hands",
  INVTYPE_WAIST = "Waist", INVTYPE_LEGS = "Legs", INVTYPE_FEET = "Feet", INVTYPE_FINGER = "Ring",
  INVTYPE_TRINKET = "Trinket", INVTYPE_WEAPON = "One-hand", INVTYPE_WEAPONMAINHAND = "One-hand",
  INVTYPE_WEAPONOFFHAND = "One-hand", INVTYPE_2HWEAPON = "Two-hand", INVTYPE_SHIELD = "Off-hand",
  INVTYPE_HOLDABLE = "Off-hand", INVTYPE_RANGED = "Ranged", INVTYPE_RANGEDRIGHT = "Ranged",
  INVTYPE_THROWN = "Ranged", INVTYPE_BAG = "Bag",
}
local ARMOR_CLASS = 4 -- item class "Armor"
local ARMOR_SUB = { [1] = "Cloth", [2] = "Leather", [3] = "Mail", [4] = "Plate" }

-- lower-case Lua patterns that mean a recipe gives the stat
F.PATTERNS = {
  str = { "strength" },
  agi = { "agility" },
  sta = { "stamina" },
  int = { "intellect" },
  spi = { "spirit" },
  ap = { "attack power" },
  sp = { "spell damage", "damage and healing done by magical spells", "damage done by %a+ spells", "spell power" },
  heal = { "healing done", "healing spells", "healing by up to", "%+%d+ healing" },
  crit = { "critical" },
  hit = { "chance to hit", "hit rating", "%+%d+%%? hit" },
  mp5 = { "mana per 5", "mana every 5", "mana regen" },
  hp5 = { "health per 5", "health every 5" },
  res = { "resistance" },
}

-- lines that never describe what the item gives
local SKIP = { "^requires", "^durability", "^sell price", "^made by", "^\"", "^unique", "^soulbound",
               "^binds when", "^item level", "^reagents" }

function F.ParseStats(lines)
  local found = {}
  for _, line in ipairs(lines) do
    local l = tostring(line or ""):lower()
    local skip = false
    for _, p in ipairs(SKIP) do if l:find(p) then skip = true break end end
    if not skip then
      for stat, pats in pairs(F.PATTERNS) do
        if not found[stat] then
          for _, p in ipairs(pats) do
            if l:find(p) then found[stat] = true break end
          end
        end
      end
    end
  end
  return found
end

------------------------------------------------------------------------
-- Reading item and spell text
------------------------------------------------------------------------
local function GetItemInfoCompat(id)
  if C_Item and C_Item.GetItemInfo then return C_Item.GetItemInfo(id) end
  if GetItemInfo then return GetItemInfo(id) end
end

local scanTip
local function ScanTooltip(set, arg)
  if not scanTip then
    scanTip = CreateFrame("GameTooltip", "FableHubScanTip", nil, "GameTooltipTemplate")
  end
  scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
  scanTip:ClearLines()
  if not pcall(scanTip[set], scanTip, arg) then return nil end
  local out = {}
  for i = 2, scanTip:NumLines() or 0 do -- line 1 is the name
    local fs = _G["FableHubScanTipTextLeft" .. i]
    local text = fs and fs:GetText()
    if text and text ~= "" then out[#out + 1] = text end
  end
  scanTip:Hide()
  return #out > 0 and out or nil
end

local function TooltipInfoLines(fn, id)
  if not fn then return nil end
  local ok, data = pcall(fn, id)
  if not ok or type(data) ~= "table" or type(data.lines) ~= "table" then return nil end
  local out = {}
  for i = 2, #data.lines do
    local text = data.lines[i].leftText
    if text and text ~= "" then out[#out + 1] = text end
  end
  return #out > 0 and out or nil
end

local function ItemLines(itemID)
  return TooltipInfoLines(C_TooltipInfo and C_TooltipInfo.GetItemByID, itemID)
      or ScanTooltip("SetHyperlink", "item:" .. itemID)
end

local function SpellLines(spellID)
  local fn = (C_Spell and C_Spell.GetSpellDescription) or GetSpellDescription
  if fn then
    local ok, desc = pcall(fn, spellID)
    if ok and type(desc) == "string" and desc ~= "" then return { desc } end
  end
  return TooltipInfoLines(C_TooltipInfo and C_TooltipInfo.GetSpellByID, spellID)
      or ScanTooltip("SetSpellByID", spellID)
end

------------------------------------------------------------------------
-- Facts
------------------------------------------------------------------------
local cache = {}
-- spells whose description hadn't loaded: [key] = { n = tries, t = last try }
local spellTries = {}
local SPELL_TRIES = 5      -- then it's taken as giving no stats
local SPELL_RETRY = 5      -- seconds between tries

-- { slot, armor, stats = { [stat] = true } } for a recipe and the item it makes
-- (itemID nil for enchants), or nil while the game is still loading it
function F.Get(recipeID, itemID)
  local key = itemID and ("i" .. itemID) or ("s" .. recipeID)
  local c = cache[key]
  if c then return c end
  local facts
  if itemID then
    local ok, name, _, _, _, _, _, _, _, equipLoc, _, _, classID, subclassID = pcall(GetItemInfoCompat, itemID)
    if not ok or not name then
      if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, itemID) end
      return nil
    end
    local slot = SLOT_OF[equipLoc or ""]
    local armor = (classID == ARMOR_CLASS and slot and slot ~= "Back") and ARMOR_SUB[subclassID] or nil
    -- the item has loaded: a tooltip with only its name line just gives no stats
    local lines = ItemLines(itemID)
    facts = { slot = slot, armor = armor, stats = lines and F.ParseStats(lines) or {} }
  else
    -- description not loaded yet: try again a few times, a little apart
    local now = GetTime()
    local t = spellTries[key]
    if t and now - t.t < SPELL_RETRY then return nil end
    local lines = SpellLines(recipeID)
    if not lines then
      if not t then t = { n = 0, t = 0 }; spellTries[key] = t end
      t.n, t.t = t.n + 1, now
      if t.n < SPELL_TRIES then return nil end
      spellTries[key] = nil
      facts = { stats = {} }
    else
      spellTries[key] = nil
      facts = { stats = F.ParseStats(lines) }
    end
  end
  cache[key] = facts
  return facts
end

function F.Forget() cache = {}; spellTries = {} end
