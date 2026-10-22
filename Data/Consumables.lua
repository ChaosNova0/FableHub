-- What the ready check looks for: consumables, class buffs and enchant slots.
-- This is a plain data file: edit it as Forever adds or changes items.
--
-- A buff counts if its spell ID is listed, or its name matches one of the
-- patterns (lower case, Lua patterns). Spell IDs below are the classic ones;
-- Forever's may differ, which is why names are matched too.

local _, ns = ...
local C = {}
ns.Consumables = C

-- Flasks: one flask = full marks for the "flask or elixirs" line
C.FLASK = {
  ids = { 17624, 17626, 17627, 17628, 17629 },
  patterns = { "^flask of" },
}

-- Elixirs: two different elixirs count the same as a flask
C.ELIXIR = {
  ids = {
    17538, -- Elixir of the Mongoose
    11405, -- Elixir of the Giants
    17539, -- Greater Arcane Elixir
    11390, -- Arcane Elixir
    26276, -- Greater Firepower
    11474, -- Shadow Power
    21920, -- Frost Power
    11334, -- Greater Agility
    11348, -- Greater Armor (Superior Defense)
    3593,  -- Health II (Elixir of Fortitude)
    24361, -- Regeneration (Major Troll's Blood)
    24363, -- Mana Regeneration (Mageblood)
    11396, -- Greater Intellect
    17535, -- Elixir of the Sages
  },
  patterns = { "^elixir of", " elixir$", "^greater arcane elixir" },
}
C.ELIXIRS_FOR_FLASK = 2

-- Food buffs
C.FOOD = {
  ids = {
    25661, -- Increased Stamina (Dirge's Kickin' Chimaerok Chops)
    24799, -- Strength (Smoked Desert Dumplings)
    18194, -- Mana Regeneration (Nightfin Soup)
    18192, -- Agility (Grilled Squid)
    18125, -- Blessed Sunfruit
    18141, -- Blessed Sunfruit Juice
  },
  patterns = { "^well fed" },
}

-- Other buffs worth a point each (up to the "other" cap in the point values)
C.OTHER = {
  ids = {
    24382, 24383, 24417,              -- Spirit / Swiftness / Sheen of Zanza
    16323, 16329,                     -- Juju Power, Juju Might
    10667, 10669, 10692, 10668, 10693, -- Blasted Lands buffs (R.O.I.D.S., Scorpok, Cortex, Lung Juice, Gizzard Gum)
    17038,                            -- Winterfall Firewater
    12179, 12174, 12175, 12177, 12176, 12178, -- Scrolls (Strength, Agility, Protection, Spirit, Intellect, Stamina IV)
    25804,                            -- Rumsey Rum Black Label
  },
  patterns = { "^spirit of zanza", "^juju " },
}

-- Class buffs the ready check expects (ids from Buffs.lua). A buff is only
-- expected when someone in the raid has the class that casts it.
C.CLASS_BUFFS = {
  { id = "fort", short = "Fort" },
  { id = "motw", short = "MotW" },
  { id = "int", short = "Int" },
  { id = "spirit", short = "Spirit", optional = true }, -- shown, not counted as missing
  { id = "shprot", short = "Shadow", optional = true },
}
-- Paladin blessings: each paladin gives each player one, so a player is
-- expected to have as many as there are paladins (up to BLESSINGS_MAX).
C.BLESSINGS = { "might", "wisdom", "kings", "salv", "light", "sanct" }
C.BLESSINGS_MAX = 4

-- Gear slots that should be enchanted (inventory slot numbers).
-- 15 back, 5 chest, 9 wrist, 10 hands, 8 feet, 16 main hand, 17 off hand.
-- Head, shoulders and legs are left out because their enchants need reputation.
C.ENCHANT_SLOTS = { 15, 5, 9, 10, 8, 16, 17 }
C.SLOT_NAMES = { [1] = "Head", [3] = "Shoulders", [5] = "Chest", [7] = "Legs", [8] = "Feet", [9] = "Wrist",
                 [10] = "Hands", [15] = "Back", [16] = "Main hand", [17] = "Off hand", [18] = "Ranged" }
-- off-hand items that can't be enchanted
C.NO_ENCHANT_EQUIP = { INVTYPE_HOLDABLE = true, INVTYPE_RELIC = true }

------------------------------------------------------------------------
local function Index(list)
  local set = {}
  for _, id in ipairs(list.ids or {}) do set[id] = true end
  list.set = set
end
Index(C.FLASK); Index(C.ELIXIR); Index(C.FOOD); Index(C.OTHER)

local function Matches(list, name, id)
  if id and list.set[id] then return true end
  name = (name or ""):lower()
  for _, p in ipairs(list.patterns or {}) do
    if name:find(p) then return true end
  end
  return false
end

-- auras = { { name, id }, ... } ->
--   { flask = name or nil, elixirs = { names }, food = name or nil, other = { names },
--     flaskOk = flask or enough elixirs }
function C.Classify(auras)
  local out = { elixirs = {}, other = {} }
  local seen = {}
  for _, a in ipairs(auras) do
    local name = a.name or tostring(a.id)
    if Matches(C.FLASK, a.name, a.id) then out.flask = name
    elseif Matches(C.ELIXIR, a.name, a.id) then
      if not seen[name] then seen[name] = true; out.elixirs[#out.elixirs + 1] = name end
    elseif Matches(C.FOOD, a.name, a.id) then out.food = name
    elseif Matches(C.OTHER, a.name, a.id) then out.other[#out.other + 1] = name end
  end
  out.flaskOk = out.flask ~= nil or #out.elixirs >= C.ELIXIRS_FOR_FLASK
  return out
end
