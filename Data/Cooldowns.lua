-- Profession cooldowns FableHub tracks. This is a plain data file: edit it as
-- Forever adds or changes cooldowns.
--
-- A cooldown is one of:
--   spells  recipes that share one cooldown (knowing any of them counts)
--   item    a tool whose use has a cooldown (owning it counts)
-- prefix   recipe names starting with this also join the cooldown, in case
--          Forever adds recipes with new IDs (English clients only)
-- Spell and item IDs below are the classic ones.

local _, ns = ...

ns.COOLDOWNS = {
  {
    id = "transmute", name = "Transmute", skillLine = 171, -- Alchemy
    spells = {
      17187, -- Transmute: Arcanite
      11479, -- Transmute: Iron to Gold
      11480, -- Transmute: Mithril to Truesilver
      17559, 17560, 17561, 17562, 17563, 17564, 17565, 17566, -- the elemental and essence transmutes
      25146, -- Transmute: Elemental Fire
    },
    prefix = "Transmute",
    note = "All transmutes share this cooldown.",
  },
  {
    id = "mooncloth", name = "Mooncloth", skillLine = 197, -- Tailoring
    spells = { 18560 },
  },
  {
    id = "saltshaker", name = "Salt Shaker", skillLine = 165, -- Leatherworking
    item = 15846, makes = "Refined Deeprock Salt",
  },
}

-- lookups: by id, and which cooldown a recipe belongs to
ns.COOLDOWN_BY_ID, ns.COOLDOWN_OF_RECIPE = {}, {}
for _, cd in ipairs(ns.COOLDOWNS) do
  ns.COOLDOWN_BY_ID[cd.id] = cd
  for _, spell in ipairs(cd.spells or {}) do ns.COOLDOWN_OF_RECIPE[spell] = cd.id end
end
