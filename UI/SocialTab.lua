-- A "FableHub" tab on the game's own Social window, after Friends, Who, Guild
-- and Raid. Clicking it closes the Social window and opens FableHub in its
-- place, so it feels like switching tabs.
--
-- The tab only shows while you're in a guild, and can be turned off in
-- Settings > General (option "socialTab").
--
-- It isn't one of the Social window's own tabs: the game's tab count is left
-- alone, so the game never tries to select it or show a page for it.

local _, ns = ...

local tab

local function Wanted()
  return IsInGuild() and ns.Option("socialTab") and true or false
end

local function Update()
  if not tab then return end
  tab:SetShown(Wanted())
  if PanelTemplates_DeselectTab then PanelTemplates_DeselectTab(tab) end
end
ns.UpdateSocialTab = Update

local function OnClick()
  if HideUIPanel then HideUIPanel(FriendsFrame) else FriendsFrame:Hide() end
  if not (FableHubFrame and FableHubFrame:IsShown()) then ns.ToggleUI() end
end

local function Create()
  if tab or not FriendsFrame or not FriendsFrameTab1 then return end
  -- put it after the last tab, in case the game (or another addon) has more than four
  local last, i = FriendsFrameTab1, 2
  while _G["FriendsFrameTab" .. i] do
    last = _G["FriendsFrameTab" .. i]
    i = i + 1
  end

  -- the same look as the Social window's own tabs
  tab = CreateFrame("Button", "FableHubSocialTab", FriendsFrame, "CharacterFrameTabButtonTemplate")
  tab:SetText("FableHub")
  tab:SetPoint("LEFT", last, "RIGHT", -14, 0)
  if PanelTemplates_TabResize then PanelTemplates_TabResize(tab, 0) end
  tab:SetScript("OnClick", OnClick)
  tab:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Open FableHub")
    GameTooltip:Show()
  end)
  tab:SetScript("OnLeave", function() GameTooltip:Hide() end)

  -- check again each time the Social window opens (you may have joined or left a guild)
  FriendsFrame:HookScript("OnShow", Update)
  Update()
end

ns.On("LOGIN", Create)
ns.RegisterEvent("PLAYER_GUILD_UPDATE", Update)
ns.On("OPTIONS_CHANGED", Update)
