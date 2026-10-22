-- Scan: reads your own character (class, level, professions, known recipes).
-- Skill levels are read any time; the recipe list can only be read while a
-- profession window is open, so open each profession once to share recipes.

local _, ns = ...

local function SafeCall(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, a, b, c, d, e, f, g, h, i, j = pcall(fn, ...)
  if ok then return a, b, c, d, e, f, g, h, i, j end
  return nil
end

local function SetsEqual(a, b)
  for k in pairs(a) do if not b[k] then return false end end
  for k in pairs(b) do if not a[k] then return false end end
  return true
end

local function Changed(rec)
  rec.ts = ns.Now()
  ns.MirrorMyRecord()
  if ns.Activity then pcall(ns.Activity.CheckOwn) end
  ns.Fire("DATA_CHANGED")
  ns.QueueOwnBroadcast()
end

------------------------------------------------------------------------
-- Class + level
------------------------------------------------------------------------
local function ScanBasics(rec)
  local _, classFile = UnitClass("player")
  local level = UnitLevel("player")
  local changed = rec.class ~= classFile or rec.level ~= level
  rec.class, rec.level = classFile, level
  return changed
end

------------------------------------------------------------------------
-- Profession skill levels
------------------------------------------------------------------------
local function CollectProfessions()
  local found = {} -- [skillLine] = { name, rank, max }

  -- standard profession slots (primary x2, plus secondary ones)
  local slots = { SafeCall(GetProfessions) }
  for i = 1, 6 do
    local idx = slots[i]
    if idx then
      local name, _, rank, max, _, _, skillLine = SafeCall(GetProfessionInfo, idx)
      if name and skillLine then
        found[skillLine] = { name = name, rank = rank or 0, max = max or 0 }
      end
    end
  end

  -- anything the slots miss (e.g. First Aid if Forever brings it back)
  if C_TradeSkillUI and C_TradeSkillUI.GetAllProfessionTradeSkillLines then
    local lines = SafeCall(C_TradeSkillUI.GetAllProfessionTradeSkillLines) or {}
    for _, skillLine in ipairs(lines) do
      if not found[skillLine] then
        local info = SafeCall(C_TradeSkillUI.GetProfessionInfoBySkillLineID, skillLine)
        if info and (info.skillLevel or 0) > 0
          and (not info.parentProfessionID or info.parentProfessionID == 0 or info.parentProfessionID == skillLine) then
          found[skillLine] = {
            name = info.professionName or ("Profession " .. skillLine),
            rank = info.skillLevel or 0, max = info.maxSkillLevel or 0,
          }
        end
      end
    end
  end
  return found
end

-- When a profession seems to vanish, wait before believing it: during loading
-- screens the game can briefly report fewer professions than you have.
local missingSince = {}
local MISSING_GRACE = 30 -- seconds a profession must stay missing before we drop it

local function ScanSkills(rec, allowRemove)
  local found = CollectProfessions()
  local changed = false
  rec.profs = rec.profs or {}
  rec.stash = rec.stash or {} -- recipes of professions we dropped, in case they come back
  for skillLine, p in pairs(found) do
    missingSince[skillLine] = nil
    local cur = rec.profs[skillLine]
    if not cur then
      local saved = rec.stash[skillLine]
      rec.profs[skillLine] = { name = p.name, rank = p.rank, max = p.max, recipes = saved or {} }
      rec.stash[skillLine] = nil
      changed = true
    elseif cur.rank ~= p.rank or cur.max ~= p.max or cur.name ~= p.name then
      cur.rank, cur.max, cur.name = p.rank, p.max, p.name
      changed = true
    end
  end
  -- drop professions you've unlearned, but only after they've stayed gone a while
  if allowRemove and next(found) ~= nil then
    local now = GetTime()
    local recheck = false
    for skillLine, prof in pairs(rec.profs) do
      if not found[skillLine] and not prof.fromWindow then
        if not missingSince[skillLine] then
          missingSince[skillLine] = now
          recheck = true
        elseif now - missingSince[skillLine] >= MISSING_GRACE then
          if prof.recipes and next(prof.recipes) then rec.stash[skillLine] = prof.recipes end
          rec.profs[skillLine] = nil
          missingSince[skillLine] = nil
          changed = true
        else
          recheck = true
        end
      end
    end
    if recheck and not ns._recheckQueued then
      ns._recheckQueued = true
      C_Timer.After(MISSING_GRACE + 1, function()
        ns._recheckQueued = false
        if ns.ScanAll then ns.ScanAll() end
      end)
    end
  end
  return changed
end

------------------------------------------------------------------------
-- Known recipes (profession window open)
------------------------------------------------------------------------
local function ProfessionWindowIsOurs()
  local T = C_TradeSkillUI
  if not T or not T.IsTradeSkillReady or not SafeCall(T.IsTradeSkillReady) then return false end
  if SafeCall(T.IsTradeSkillLinked) then return false end
  if SafeCall(T.IsTradeSkillGuild) then return false end
  if SafeCall(T.IsNPCCrafting) then return false end
  if SafeCall(T.IsRuneforging) then return false end
  return true
end

-- The item a recipe makes. Clients differ, so try every source we know.
local function LinkItem(link)
  return type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
end
function ns.RecipeOutputItem(recipeID)
  local T = C_TradeSkillUI
  if not T then return nil end
  local schem = SafeCall(T.GetRecipeSchematic, recipeID, false)
  if type(schem) == "table" and type(schem.outputItemID) == "number" and schem.outputItemID > 0 then
    return schem.outputItemID
  end
  local out = SafeCall(T.GetRecipeOutputItemData, recipeID)
  if type(out) == "table" then
    if type(out.itemID) == "number" and out.itemID > 0 then return out.itemID end
    local fromLink = LinkItem(out.hyperlink)
    if fromLink then return fromLink end
  end
  local link = SafeCall(T.GetRecipeItemLink, recipeID)
  if LinkItem(link) then return LinkItem(link) end
  local info = SafeCall(T.GetRecipeInfo, recipeID)
  if type(info) == "table" and LinkItem(info.hyperlink) then return LinkItem(info.hyperlink) end
  return nil
end

function ns.ScanRecipes()
  if not ProfessionWindowIsOurs() then return end
  local T = C_TradeSkillUI
  local base = SafeCall(T.GetBaseProfessionInfo)
  if not base then return end
  local skillLine = base.professionID
  if base.parentProfessionID and base.parentProfessionID > 0 then skillLine = base.parentProfessionID end
  if not skillLine or skillLine == 0 then return end

  local ids = SafeCall(T.GetAllRecipeIDs) or {}
  local learned = {}
  for _, id in ipairs(ids) do
    local info = SafeCall(T.GetRecipeInfo, id)
    if info and info.learned then learned[id] = true end
  end

  -- what each recipe makes (enchants make no item)
  local rec0 = ns.MyRecord()
  rec0.outputs = rec0.outputs or {}
  local outputsChanged = false
  for id in pairs(learned) do
    if not rec0.outputs[id] then -- already known ones don't change
      local itemID = ns.RecipeOutputItem(id)
      if itemID then rec0.outputs[id] = itemID; outputsChanged = true end
    end
  end

  local rec = ns.MyRecord()
  local p = rec.profs[skillLine]
  local changed = false
  if not p then
    -- profession not listed in the normal slots; trust the open window
    p = { name = base.professionName or "?", rank = base.skillLevel or 0, max = base.maxSkillLevel or 0,
          recipes = {}, fromWindow = true }
    rec.profs[skillLine] = p
    changed = true
  end
  if base.skillLevel and base.skillLevel > 0 and p.rank ~= base.skillLevel then
    p.rank, p.max = base.skillLevel, base.maxSkillLevel or p.max
    changed = true
  end
  if next(learned) ~= nil and not SetsEqual(p.recipes or {}, learned) then
    p.recipes = learned
    p.scanned = ns.Now()
    changed = true
  end
  if outputsChanged then changed = true end
  if changed then Changed(rec) end
end

------------------------------------------------------------------------
-- Talents, spec and the raid buffs you can bring
------------------------------------------------------------------------
local function KnownNames()
  local out = {}
  local function Add(name) if type(name) == "string" and name ~= "" then out[name:lower()] = true end end

  -- spellbook (modern API, then classic API)
  local SB = C_SpellBook
  if SB and SB.GetNumSpellBookSkillLines then
    local bank = (Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player) or 0
    for i = 1, SafeCall(SB.GetNumSpellBookSkillLines) or 0 do
      local info = SafeCall(SB.GetSpellBookSkillLineInfo, i)
      if info and info.itemIndexOffset and info.numSpellBookItems then
        for slot = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
          Add(SafeCall(SB.GetSpellBookItemName, slot, bank))
        end
      end
    end
  elseif GetNumSpellTabs then
    for t = 1, SafeCall(GetNumSpellTabs) or 0 do
      local _, _, offset, num = SafeCall(GetSpellTabInfo, t)
      for slot = (offset or 0) + 1, (offset or 0) + (num or 0) do
        Add(SafeCall(GetSpellBookItemName or GetSpellName, slot, BOOKTYPE_SPELL or "spell"))
      end
    end
  end

  -- talents with at least one point (classic-style talent API)
  if GetNumTalentTabs and GetNumTalents and GetTalentInfo then
    for tab = 1, SafeCall(GetNumTalentTabs) or 0 do
      for i = 1, SafeCall(GetNumTalents, tab) or 0 do
        local r = { SafeCall(GetTalentInfo, tab, i) }
        local name, rank = r[1], r[5]
        if type(name) == "string" and type(rank) == "number" and rank > 0 then Add(name) end
      end
    end
  end
  return out
end

-- Points spent in each tree. GetTalentTabInfo's return values differ between
-- client versions, so take the first plain string as the name and the first
-- small number as the points.
local function TreePoints()
  local trees = {}
  if not GetNumTalentTabs or not GetTalentTabInfo then return trees end
  for tab = 1, SafeCall(GetNumTalentTabs) or 0 do
    local r = { SafeCall(GetTalentTabInfo, tab) }
    local name, points
    for i = 1, 10 do
      local v = r[i]
      if not name and type(v) == "string" and not v:find("\\", 1, true) and not v:find("/", 1, true) then name = v end
      if points == nil and type(v) == "number" and v >= 0 and v <= 71 and i > 1 then points = v end
    end
    trees[tab] = { name = name or ("Tree " .. tab), points = points or 0 }
  end
  return trees
end

local function ScanTalents(rec)
  local classFile = rec.class
  if not classFile then return false end

  -- spec
  local trees = TreePoints()
  local best, bestPts, pts = nil, 0, {}
  for i, t in ipairs(trees) do
    pts[i] = t.points
    if t.points > bestPts then best, bestPts = i, t.points end
  end
  local spec
  if best then
    spec = { tree = best, name = trees[best].name, points = table.concat(pts, "/") }
  elseif GetSpecialization and GetSpecializationInfo then
    local idx = SafeCall(GetSpecialization)
    if idx and idx > 0 then
      local _, name = SafeCall(GetSpecializationInfo, idx)
      spec = { tree = idx, name = name or "?", points = "" }
    end
  end

  -- buffs
  local known = KnownNames()
  local buffs = {}
  for _, b in ipairs(ns.BUFFS) do
    if b.classes[classFile] then
      local has = false
      for _, n in ipairs(b.detect or {}) do if known[n:lower()] then has = true break end end
      if not has and b.ids and IsPlayerSpell then
        for _, id in ipairs(b.ids) do if SafeCall(IsPlayerSpell, id) then has = true break end end
      end
      if has then buffs[b.id] = true end
    end
  end

  local changed = false
  local old = rec.spec
  if (spec and (not old or old.tree ~= spec.tree or old.points ~= spec.points or old.name ~= spec.name))
    or (old and not spec) then
    rec.spec = spec
    changed = true
  end
  if not SetsEqual(rec.buffs or {}, buffs) then
    rec.buffs = buffs
    changed = true
  end
  return changed
end
ns.ScanTalents = ScanTalents

------------------------------------------------------------------------
function ns.ScanAll(force)
  local rec = ns.MyRecord()
  if not rec then return end
  local a = ScanBasics(rec)
  local b = ScanSkills(rec, true)
  local c = ScanTalents(rec)
  if a or b or c or force or rec.ts == 0 then Changed(rec) end
end

-- recipe list fills in over a few events; wait for it to settle
local recipePending = false
local function QueueRecipeScan()
  if recipePending then return end
  recipePending = true
  C_Timer.After(1.5, function()
    recipePending = false
    ns.ScanRecipes()
  end)
end

ns.RegisterEvent("TRADE_SKILL_SHOW", QueueRecipeScan)
ns.RegisterEvent("TRADE_SKILL_LIST_UPDATE", QueueRecipeScan)
ns.RegisterEvent("NEW_RECIPE_LEARNED", QueueRecipeScan)

local skillPending = false
local function QueueSkillScan()
  if skillPending then return end
  skillPending = true
  C_Timer.After(2, function()
    skillPending = false
    ns.ScanAll()
  end)
end
ns.RegisterEvent("SKILL_LINES_CHANGED", QueueSkillScan)
ns.RegisterEvent("PLAYER_LEVEL_UP", QueueSkillScan)
for _, e in ipairs({ "SPELLS_CHANGED", "CHARACTER_POINTS_CHANGED", "PLAYER_TALENT_UPDATE",
                     "ACTIVE_TALENT_GROUP_CHANGED", "LEARNED_SPELL_IN_TAB",
                     "LEARNED_SPELL_IN_SKILL_LINE" }) do
  ns.RegisterEvent(e, QueueSkillScan)
end
