-- Buffs: what each class can bring to a raid.
--
-- Based on original (Vanilla) WoW. Forever's class tuning isn't final, so
-- this file is meant to be edited: add, remove or retune entries here and
-- the raid builder picks the changes up automatically.
--
-- Fields
--   id       short unique id (sent over the network, keep it short and stable)
--   name     shown in tooltips
--   cat      "raid"    reaches everyone in the raid (single-target or raid-wide buffs)
--            "party"   only affects the caster's own group (totems, auras, shouts)
--            "debuff"  goes on the boss
--            "utility" other useful tools (dispels, battle res, fear ward...)
--   classes  which classes can provide it
--   detect   spell or talent names to look for in a player's spellbook/talents
--   ids      optional spell IDs to check too (Vanilla IDs; harmless if Forever changed them)
--   base     true if every member of the class has it by max level (assumed for
--            players who don't run FableHub); false/nil = needs a talent
--   icon     texture

local _, ns = ...

local I = "Interface\\Icons\\"

ns.BUFFS = {
  -- Raid-wide buffs ---------------------------------------------------
  { id = "fort", name = "Power Word: Fortitude", cat = "raid", classes = { PRIEST = true },
    detect = { "Power Word: Fortitude", "Prayer of Fortitude" }, base = true, icon = I .. "Spell_Holy_WordFortitude" },
  { id = "spirit", name = "Divine Spirit", cat = "raid", classes = { PRIEST = true },
    detect = { "Divine Spirit", "Prayer of Spirit" }, ids = { 14752 }, icon = I .. "Spell_Holy_DivineSpirit" },
  { id = "shprot", name = "Shadow Protection", cat = "raid", classes = { PRIEST = true },
    detect = { "Shadow Protection", "Prayer of Shadow Protection" }, base = true, icon = I .. "Spell_Shadow_AntiShadow" },
  { id = "motw", name = "Mark of the Wild", cat = "raid", classes = { DRUID = true },
    detect = { "Mark of the Wild", "Gift of the Wild" }, base = true, icon = I .. "Spell_Nature_Regeneration" },
  { id = "thorns", name = "Thorns", cat = "raid", classes = { DRUID = true },
    detect = { "Thorns" }, base = true, icon = I .. "Spell_Nature_Thorns" },
  { id = "int", name = "Arcane Intellect", cat = "raid", classes = { MAGE = true },
    detect = { "Arcane Intellect", "Arcane Brilliance" }, base = true, icon = I .. "Spell_Holy_MagicalSentry" },
  { id = "might", name = "Blessing of Might", cat = "raid", classes = { PALADIN = true },
    detect = { "Blessing of Might", "Greater Blessing of Might" }, base = true, icon = I .. "Spell_Holy_FistOfJustice" },
  { id = "wisdom", name = "Blessing of Wisdom", cat = "raid", classes = { PALADIN = true },
    detect = { "Blessing of Wisdom", "Greater Blessing of Wisdom" }, base = true, icon = I .. "Spell_Holy_SealOfWisdom" },
  { id = "kings", name = "Blessing of Kings", cat = "raid", classes = { PALADIN = true },
    detect = { "Blessing of Kings", "Greater Blessing of Kings" }, ids = { 20217 }, icon = I .. "Spell_Magic_MageArmor" },
  { id = "salv", name = "Blessing of Salvation", cat = "raid", classes = { PALADIN = true },
    detect = { "Blessing of Salvation", "Greater Blessing of Salvation" }, base = true, icon = I .. "Spell_Holy_SealOfSalvation" },
  { id = "light", name = "Blessing of Light", cat = "raid", classes = { PALADIN = true },
    detect = { "Blessing of Light", "Greater Blessing of Light" }, base = true, icon = I .. "Spell_Holy_PrayerOfHealing02" },
  { id = "sanct", name = "Blessing of Sanctuary", cat = "raid", classes = { PALADIN = true },
    detect = { "Blessing of Sanctuary", "Greater Blessing of Sanctuary" }, ids = { 20911 }, icon = I .. "Spell_Nature_LightningShield" },

  -- Party-only buffs ----------------------------------------------------
  { id = "bshout", name = "Battle Shout", cat = "party", classes = { WARRIOR = true },
    detect = { "Battle Shout" }, base = true, icon = I .. "Ability_Warrior_BattleShout" },
  { id = "devo", name = "Devotion Aura", cat = "party", classes = { PALADIN = true },
    detect = { "Devotion Aura" }, base = true, icon = I .. "Spell_Holy_DevotionAura" },
  { id = "retri", name = "Retribution Aura", cat = "party", classes = { PALADIN = true },
    detect = { "Retribution Aura" }, base = true, icon = I .. "Spell_Holy_AuraOfLight" },
  { id = "conc", name = "Concentration Aura", cat = "party", classes = { PALADIN = true },
    detect = { "Concentration Aura" }, base = true, icon = I .. "Spell_Holy_MindSooth" },
  { id = "fireaura", name = "Fire Resistance Aura", cat = "party", classes = { PALADIN = true },
    detect = { "Fire Resistance Aura" }, base = true, icon = I .. "Spell_Fire_SealOfFire" },
  { id = "frostaura", name = "Frost Resistance Aura", cat = "party", classes = { PALADIN = true },
    detect = { "Frost Resistance Aura" }, base = true, icon = I .. "Spell_Frost_WizardMark" },
  { id = "shadaura", name = "Shadow Resistance Aura", cat = "party", classes = { PALADIN = true },
    detect = { "Shadow Resistance Aura" }, base = true, icon = I .. "Spell_Shadow_SealOfKings" },
  { id = "soe", name = "Strength of Earth Totem", cat = "party", classes = { SHAMAN = true },
    detect = { "Strength of Earth Totem" }, base = true, icon = I .. "Spell_Nature_EarthBindTotem" },
  { id = "goa", name = "Grace of Air Totem", cat = "party", classes = { SHAMAN = true },
    detect = { "Grace of Air Totem" }, base = true, icon = I .. "Spell_Nature_InvisibilityTotem" },
  { id = "wf", name = "Windfury Totem", cat = "party", classes = { SHAMAN = true },
    detect = { "Windfury Totem" }, base = true, icon = I .. "Spell_Nature_Windfury" },
  { id = "mspring", name = "Mana Spring Totem", cat = "party", classes = { SHAMAN = true },
    detect = { "Mana Spring Totem" }, base = true, icon = I .. "Spell_Nature_ManaRegenTotem" },
  { id = "hstream", name = "Healing Stream Totem", cat = "party", classes = { SHAMAN = true },
    detect = { "Healing Stream Totem" }, base = true, icon = I .. "INV_Spear_04" },
  { id = "mtide", name = "Mana Tide Totem", cat = "party", classes = { SHAMAN = true },
    detect = { "Mana Tide Totem" }, ids = { 16190 }, icon = I .. "Spell_Frost_SummonWaterElemental" },
  { id = "tranq", name = "Tranquil Air Totem", cat = "party", classes = { SHAMAN = true },
    detect = { "Tranquil Air Totem" }, base = true, icon = I .. "Spell_Nature_Brilliance" },
  { id = "skin", name = "Stoneskin Totem", cat = "party", classes = { SHAMAN = true },
    detect = { "Stoneskin Totem" }, base = true, icon = I .. "Spell_Nature_StoneSkinTotem" },
  { id = "tremor", name = "Tremor Totem", cat = "party", classes = { SHAMAN = true },
    detect = { "Tremor Totem" }, base = true, icon = I .. "Spell_Nature_TremorTotem" },
  { id = "firetotem", name = "Fire Resistance Totem", cat = "party", classes = { SHAMAN = true },
    detect = { "Fire Resistance Totem" }, base = true, icon = I .. "Spell_FireResistanceTotem_01" },
  { id = "frosttotem", name = "Frost Resistance Totem", cat = "party", classes = { SHAMAN = true },
    detect = { "Frost Resistance Totem" }, base = true, icon = I .. "Spell_FrostResistanceTotem_01" },
  { id = "nattotem", name = "Nature Resistance Totem", cat = "party", classes = { SHAMAN = true },
    detect = { "Nature Resistance Totem" }, base = true, icon = I .. "Spell_Nature_NatureResistanceTotem" },
  { id = "tsa", name = "Trueshot Aura", cat = "party", classes = { HUNTER = true },
    detect = { "Trueshot Aura" }, ids = { 19506 }, icon = I .. "Ability_TrueShot" },
  { id = "aotw", name = "Aspect of the Wild", cat = "party", classes = { HUNTER = true },
    detect = { "Aspect of the Wild" }, base = true, icon = I .. "Spell_Nature_ProtectionformNature" },
  { id = "lotp", name = "Leader of the Pack", cat = "party", classes = { DRUID = true },
    detect = { "Leader of the Pack" }, ids = { 17007 }, icon = I .. "Spell_Nature_UnyeildingStamina" },
  { id = "moonkin", name = "Moonkin Aura", cat = "party", classes = { DRUID = true },
    detect = { "Moonkin Form", "Moonkin Aura" }, ids = { 24858 }, icon = I .. "Spell_Nature_ForceOfNature" },
  { id = "bpact", name = "Blood Pact (Imp)", cat = "party", classes = { WARLOCK = true },
    detect = { "Summon Imp", "Blood Pact" }, base = true, icon = I .. "Spell_Shadow_BloodBoil" },

  -- Boss debuffs ---------------------------------------------------------
  { id = "sunder", name = "Sunder Armor", cat = "debuff", classes = { WARRIOR = true },
    detect = { "Sunder Armor" }, base = true, icon = I .. "Ability_Warrior_Sunder" },
  { id = "demo", name = "Demoralizing Shout", cat = "debuff", classes = { WARRIOR = true },
    detect = { "Demoralizing Shout" }, base = true, icon = I .. "Ability_Warrior_WarCry" },
  { id = "tclap", name = "Thunder Clap", cat = "debuff", classes = { WARRIOR = true },
    detect = { "Thunder Clap" }, base = true, icon = I .. "Spell_Nature_ThunderClap" },
  { id = "ff", name = "Faerie Fire", cat = "debuff", classes = { DRUID = true },
    detect = { "Faerie Fire", "Faerie Fire (Feral)" }, base = true, icon = I .. "Spell_Nature_FaerieFire" },
  { id = "cor", name = "Curse of Recklessness", cat = "debuff", classes = { WARLOCK = true },
    detect = { "Curse of Recklessness" }, base = true, icon = I .. "Spell_Shadow_UnholyStrength" },
  { id = "coe", name = "Curse of the Elements", cat = "debuff", classes = { WARLOCK = true },
    detect = { "Curse of the Elements" }, base = true, icon = I .. "Spell_Shadow_ChillTouch" },
  { id = "cos", name = "Curse of Shadow", cat = "debuff", classes = { WARLOCK = true },
    detect = { "Curse of Shadow" }, base = true, icon = I .. "Spell_Shadow_CurseOfAchimonde" },
  { id = "weaving", name = "Shadow Weaving", cat = "debuff", classes = { PRIEST = true },
    detect = { "Shadow Weaving" }, ids = { 15257, 15331, 15332, 15333, 15334 }, icon = I .. "Spell_Shadow_BlackPlague" },
  { id = "scorch", name = "Improved Scorch", cat = "debuff", classes = { MAGE = true },
    detect = { "Improved Scorch" }, ids = { 11095, 12872, 12873 }, icon = I .. "Spell_Fire_SoulBurn" },
  { id = "wchill", name = "Winter's Chill", cat = "debuff", classes = { MAGE = true },
    detect = { "Winter's Chill" }, ids = { 11180, 28592, 28593, 28594, 28595 }, icon = I .. "Spell_Frost_ChillingBlast" },
  { id = "expose", name = "Expose Armor", cat = "debuff", classes = { ROGUE = true },
    detect = { "Expose Armor" }, base = true, icon = I .. "Ability_Warrior_Riposte" },
  { id = "jow", name = "Judgement of Wisdom", cat = "debuff", classes = { PALADIN = true },
    detect = { "Seal of Wisdom" }, base = true, icon = I .. "Spell_Holy_RighteousnessAura" },
  { id = "jol", name = "Judgement of Light", cat = "debuff", classes = { PALADIN = true },
    detect = { "Seal of Light" }, base = true, icon = I .. "Spell_Holy_HealingAura" },

  -- Utility ----------------------------------------------------------------
  { id = "fward", name = "Fear Ward", cat = "utility", classes = { PRIEST = true },
    detect = { "Fear Ward" }, base = true, icon = I .. "Spell_Holy_Excorcism" },
  { id = "innerv", name = "Innervate", cat = "utility", classes = { DRUID = true },
    detect = { "Innervate" }, base = true, icon = I .. "Spell_Nature_Lightning" },
  { id = "brez", name = "Rebirth", cat = "utility", classes = { DRUID = true },
    detect = { "Rebirth" }, base = true, icon = I .. "Spell_Nature_Reincarnation" },
  { id = "sstone", name = "Soulstone", cat = "utility", classes = { WARLOCK = true },
    detect = { "Create Soulstone", "Create Soulstone (Major)" }, base = true, icon = I .. "Spell_Shadow_SoulGem" },
  { id = "summon", name = "Ritual of Summoning", cat = "utility", classes = { WARLOCK = true },
    detect = { "Ritual of Summoning" }, base = true, icon = I .. "Spell_Shadow_Twilight" },
  { id = "decurse", name = "Remove Curse", cat = "utility", classes = { MAGE = true, DRUID = true },
    detect = { "Remove Curse", "Remove Lesser Curse" }, base = true, icon = I .. "Spell_Holy_RemoveCurse" },
  { id = "dispel", name = "Dispel Magic", cat = "utility", classes = { PRIEST = true, PALADIN = true },
    detect = { "Dispel Magic", "Cleanse" }, base = true, icon = I .. "Spell_Holy_DispelMagic" },
  { id = "poison", name = "Cure Poison", cat = "utility", classes = { DRUID = true, SHAMAN = true, PALADIN = true },
    detect = { "Cure Poison", "Abolish Poison", "Purify", "Cleanse" }, base = true, icon = I .. "Spell_Nature_NullifyPoison" },
  { id = "disease", name = "Cure Disease", cat = "utility", classes = { PRIEST = true, SHAMAN = true, PALADIN = true },
    detect = { "Cure Disease", "Abolish Disease", "Purify", "Cleanse" }, base = true, icon = I .. "Spell_Holy_NullifyDisease" },
  { id = "tranqshot", name = "Tranquilizing Shot", cat = "utility", classes = { HUNTER = true },
    detect = { "Tranquilizing Shot" }, base = true, icon = I .. "Spell_Nature_Drowsy" },
}

ns.BUFF_BY_ID = {}
for i, b in ipairs(ns.BUFFS) do
  b.order = i
  ns.BUFF_BY_ID[b.id] = b
end

ns.BUFF_CATEGORIES = {
  { cat = "raid", title = "Raid buffs" },
  { cat = "debuff", title = "Boss debuffs" },
  { cat = "utility", title = "Utility" },
  { cat = "party", title = "Party buffs" },
}

------------------------------------------------------------------------
-- Talent trees -> role. Trees are in the game's fixed order per class.
------------------------------------------------------------------------
ns.TREE_ROLES = {
  WARRIOR = { "MELEE", "MELEE", "TANK" },
  PALADIN = { "HEALER", "TANK", "MELEE" },
  HUNTER  = { "RANGED", "RANGED", "RANGED" },
  ROGUE   = { "MELEE", "MELEE", "MELEE" },
  PRIEST  = { "HEALER", "HEALER", "RANGED" },
  SHAMAN  = { "RANGED", "MELEE", "HEALER" },
  MAGE    = { "RANGED", "RANGED", "RANGED" },
  WARLOCK = { "RANGED", "RANGED", "RANGED" },
  DRUID   = { "RANGED", "TANK", "HEALER" },
}
-- used when a player's spec isn't known yet
ns.DEFAULT_ROLE = {
  WARRIOR = "MELEE", PALADIN = "HEALER", HUNTER = "RANGED", ROGUE = "MELEE", PRIEST = "HEALER",
  SHAMAN = "HEALER", MAGE = "RANGED", WARLOCK = "RANGED", DRUID = "HEALER",
}
ns.ROLES = { "TANK", "HEALER", "MELEE", "RANGED" }
ns.ROLE_NAMES = { TANK = "Tank", HEALER = "Healer", MELEE = "Melee", RANGED = "Ranged" }
ns.ROLE_SHORT = { TANK = "T", HEALER = "H", MELEE = "M", RANGED = "R" }
