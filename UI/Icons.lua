-- Icons: inline texture markup for class icons, profession icons and status dots.

local _, ns = ...
local I = {}
ns.Icons = I

local MEDIA = "Interface\\AddOns\\FableHub\\Media\\"
I.DOT = MEDIA .. "dot.tga"
I.ROUND = MEDIA .. "round.tga"
I.LOGO = MEDIA .. "logo.tga"

-- fallback profession icons by skill line
local PROF_ICONS = {
  [171] = "Interface\\Icons\\Trade_Alchemy",
  [164] = "Interface\\Icons\\Trade_BlackSmithing",
  [333] = "Interface\\Icons\\Trade_Engraving",
  [202] = "Interface\\Icons\\Trade_Engineering",
  [182] = "Interface\\Icons\\Trade_Herbalism",
  [165] = "Interface\\Icons\\Trade_LeatherWorking",
  [186] = "Interface\\Icons\\Trade_Mining",
  [393] = "Interface\\Icons\\INV_Misc_Pelt_Wolf_01",
  [197] = "Interface\\Icons\\Trade_Tailoring",
  [185] = "Interface\\Icons\\INV_Misc_Food_15",
  [356] = "Interface\\Icons\\Trade_Fishing",
  [129] = "Interface\\Icons\\Spell_Holy_SealOfSacrifice",
  [755] = "Interface\\Icons\\INV_Misc_Gem_01",
  [773] = "Interface\\Icons\\INV_Inscription_Tradeskill01",
  [794] = "Interface\\Icons\\Trade_Archaeology",
}
local UNKNOWN = "Interface\\Icons\\INV_Misc_QuestionMark"
local profCache = {}

function I.ProfessionTexture(skillLine)
  if profCache[skillLine] then return profCache[skillLine] end
  local tex = PROF_ICONS[skillLine]
  if not tex and C_TradeSkillUI and C_TradeSkillUI.GetTradeSkillTexture then
    local ok, t = pcall(C_TradeSkillUI.GetTradeSkillTexture, skillLine)
    if ok and t then tex = t end
  end
  tex = tex or UNKNOWN
  profCache[skillLine] = tex
  return tex
end

-- |T...|t markup, icon trimmed so the default border doesn't show
function I.Prof(skillLine, size)
  size = size or 14
  return ("|T%s:%d:%d:0:0:64:64:5:59:5:59|t"):format(tostring(I.ProfessionTexture(skillLine)), size, size)
end

local classCache = {}
function I.Class(classFile, size)
  if not classFile then return "" end
  size = size or 14
  local k = classFile .. size
  if classCache[k] then return classCache[k] end
  local markup = ""
  local atlas = "classicon-" .. classFile:lower()
  local hasAtlas = C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas)
  if hasAtlas and CreateAtlasMarkup then
    markup = CreateAtlasMarkup(atlas, size, size)
  elseif CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[classFile] then
    local c = CLASS_ICON_TCOORDS[classFile]
    markup = ("|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:%d:%d:0:0:256:256:%d:%d:%d:%d|t")
      :format(size, size, c[1] * 256 + 4, c[2] * 256 - 4, c[3] * 256 + 4, c[4] * 256 - 4)
  end
  classCache[k] = markup
  return markup
end

-- coloured status dot: online green, offline grey
function I.Dot(online, size)
  size = size or 8
  if online then
    return ("|T%s:%d:%d:0:0:32:32:0:32:0:32:64:214:110|t"):format(I.DOT, size, size)
  end
  return ("|T%s:%d:%d:0:0:32:32:0:32:0:32:90:90:90|t"):format(I.DOT, size, size)
end
