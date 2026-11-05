-- A FableHub tab on the game's Guild & Communities window, under the small
-- square tabs down its right-hand side (Chat, Roster, Guild Benefits, Guild
-- Info). Clicking it closes that window and opens FableHub in its place.
--
-- The tab only shows while you're in a guild and the game's own side tabs are
-- showing, and can be turned off in Settings > General (option "guildTab").
--
-- The Guild & Communities window is part of the game's Blizzard_Communities,
-- which only loads the first time it's opened, so the tab is made then (or at
-- login if it's already loaded). It isn't one of the window's own tabs: it
-- sits below the last one showing and moves when they do.
--
-- It uses the game's own side tab template when there is one, and otherwise
-- draws the same look itself.

local _, ns = ...

local tab
local Update

-- the window's own side tabs, top to bottom
local SIDE_TABS = { "ChatTab", "RosterTab", "GuildBenefitsTab", "GuildInfoTab" }

-- follow a side tab as it comes and goes
local watched = {}
local function Watch(t)
  if watched[t] or not t.HookScript then return end
  watched[t] = true
  t:HookScript("OnShow", function() Update() end)
  t:HookScript("OnHide", function() Update() end)
end

-- every side tab: the known ones, plus any other small button hanging off the
-- window's right edge (the game or another addon may add more than the four)
local function SideTabs()
  local list, seen = {}, {}
  for _, key in ipairs(SIDE_TABS) do
    local t = CommunitiesFrame[key]
    if type(t) == "table" and t ~= tab then list[#list + 1] = t; seen[t] = true end
  end
  local right = CommunitiesFrame.GetRight and CommunitiesFrame:GetRight()
  if right and CommunitiesFrame.GetChildren then
    for _, c in ipairs({ CommunitiesFrame:GetChildren() }) do
      if c ~= tab and not seen[c] and c.GetRect then
        local l, _, w, h = c:GetRect()
        if l and w and h and math.abs(l - right) <= 12 and w <= 64 and h <= 64 then
          list[#list + 1] = c; seen[c] = true
        end
      end
    end
  end
  return list
end

-- the lowest side tab showing (by position on screen once the window is laid
-- out; before that, the last one in the list)
local function LastShownTab(list)
  local last, lowest
  for _, t in ipairs(list) do
    Watch(t)
    if t:IsShown() then
      local b = t.GetBottom and t:GetBottom()
      if not b then
        if not lowest then last = t end
      elseif not lowest or b < lowest then
        last, lowest = t, b
      end
    end
  end
  return last
end

-- the gap the game leaves between its side tabs (RosterTab hangs under ChatTab)
local function Gap()
  local r = CommunitiesFrame.RosterTab
  if type(r) == "table" and r.GetPoint then
    local point, rel, relPoint, _, y = r:GetPoint(1)
    if point == "TOP" and relPoint == "BOTTOM" and type(rel) == "table" and type(y) == "number" then return y end
  end
  return -20
end

function Update()
  if not tab then return end
  local list = SideTabs()
  local last = LastShownTab(list)
  local want = IsInGuild() and ns.Option("guildTab") and (last or #list == 0) and true or false
  tab:ClearAllPoints()
  if last then
    tab:SetPoint("TOP", last, "BOTTOM", 0, Gap())
  else
    -- (no side tabs on this client: where the first one would be)
    tab:SetPoint("TOPLEFT", CommunitiesFrame, "TOPRIGHT", 0, -36)
  end
  tab:SetShown(want)
  if tab.SetChecked then tab:SetChecked(false) end
end
ns.UpdateGuildTab = Update
function ns.GuildTab() return tab end

local function OnClick(self)
  if self.SetChecked then self:SetChecked(false) end
  if HideUIPanel then HideUIPanel(CommunitiesFrame) else CommunitiesFrame:Hide() end
  if not (FableHubFrame and FableHubFrame:IsShown()) then ns.ToggleUI() end
end

-- the side tab look drawn by hand: a 32x32 icon on the spellbook tab background
local function MakeOwnTab()
  local t = CreateFrame("CheckButton", "FableHubGuildTab", CommunitiesFrame)
  t:SetSize(32, 32)
  local bg = t:CreateTexture(nil, "BACKGROUND")
  bg:SetTexture("Interface\\SpellBook\\SpellBook-SkillLineTab")
  bg:SetSize(64, 64)
  bg:SetPoint("TOPLEFT", -3, 11)
  t:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
  t:SetCheckedTexture("Interface\\Buttons\\CheckButtonHilight")
  local hl, ck = t:GetHighlightTexture(), t:GetCheckedTexture()
  if hl and hl.SetBlendMode then hl:SetBlendMode("ADD") end
  if ck and ck.SetBlendMode then ck:SetBlendMode("ADD") end
  return t
end

local function MakeTab()
  local ok, t = pcall(CreateFrame, "CheckButton", "FableHubGuildTab", CommunitiesFrame, "CommunitiesFrameTabTemplate")
  if not (ok and t) then t = MakeOwnTab() end
  -- our logo as the icon: the template's own icon slot if it has one
  local icon = t["Icon"]
  if type(icon) == "table" and icon.SetTexture then
    icon:SetTexture(ns.Icons.LOGO)
    icon:SetAllPoints()
  else
    t:SetNormalTexture(ns.Icons.LOGO)
  end
  return t
end

local function Create()
  if tab or not CommunitiesFrame then return end
  tab = MakeTab()
  tab.tooltip = "FableHub" -- (the template's own tooltip uses this)
  -- our own click replaces the template's, which would switch the window's pages
  tab:SetScript("OnClick", OnClick)
  tab:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("FableHub")
    GameTooltip:AddLine("Open the guild's FableHub window.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  tab:SetScript("OnLeave", function() GameTooltip:Hide() end)

  -- check again each time the window opens, and once more a moment later (the
  -- window, or another addon, may still be adding or moving tabs). Update
  -- also follows each side tab it finds as it comes and goes.
  CommunitiesFrame:HookScript("OnShow", function()
    Update()
    C_Timer.After(0, Update)
  end)
  Update()
end

ns.On("LOGIN", Create)
ns.RegisterEvent("ADDON_LOADED", function(name)
  if name == "Blizzard_Communities" then Create() end
end)
ns.RegisterEvent("PLAYER_GUILD_UPDATE", Update)
ns.On("OPTIONS_CHANGED", Update)
