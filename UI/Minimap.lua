-- Minimap button: click to open, drag around the minimap edge, /fhub minimap to hide.

local _, ns = ...
local T = ns.Theme

local button

local function Settings()
  local s = FableHubDB.settings
  s.minimap = s.minimap or { angle = 200, hide = false }
  return s.minimap
end

local function Place()
  if not button or not Minimap then return end
  local angle = math.rad(Settings().angle or 200)
  local radius = (Minimap:GetWidth() or 140) / 2 + 8
  button:ClearAllPoints()
  button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function OnDragUpdate()
  local mx, my = Minimap:GetCenter()
  local cx, cy = GetCursorPosition()
  local scale = Minimap:GetEffectiveScale()
  cx, cy = cx / scale, cy / scale
  local deg = math.deg(math.atan2(cy - my, cx - mx))
  Settings().angle = deg % 360
  Place()
end

local function Tooltip(self)
  GameTooltip:SetOwner(self, "ANCHOR_LEFT")
  GameTooltip:AddLine(("|c%sFable|rHub"):format(T.AccentHex()))
  local members, online = 0, 0
  for _, r in pairs(ns.roster) do
    members = members + 1
    if r.online then online = online + 1 end
  end
  local users = 1
  for key in pairs(ns.present) do if ns.IsOnline(key) then users = users + 1 end end
  GameTooltip:AddDoubleLine("Guild online", online .. " / " .. members, 0.8, 0.8, 0.8, 1, 1, 1)
  GameTooltip:AddDoubleLine("FableHub users online", tostring(users), 0.8, 0.8, 0.8, 1, 1, 1)
  local req = ns.Requests and ns.Requests.ForMe() or 0
  if req > 0 then GameTooltip:AddDoubleLine("Requests you can craft", tostring(req), 0.8, 0.8, 0.8, 1, 0.82, 0) end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Click to open. Drag to move.", 0.6, 0.6, 0.6)
  GameTooltip:AddLine("/fhub minimap hides this button.", 0.6, 0.6, 0.6)
  GameTooltip:Show()
end

local function Create()
  if button or not Minimap then return end
  button = CreateFrame("Button", "FableHubMinimapButton", Minimap)
  button:SetSize(30, 30)
  button:SetFrameStrata("MEDIUM")
  button:SetFrameLevel((Minimap:GetFrameLevel() or 1) + 8)
  button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  button:RegisterForDrag("LeftButton")

  -- the logo is already a round framed badge, so it fills the button with no ring or mask
  local icon = button:CreateTexture(nil, "ARTWORK")
  icon:SetTexture(ns.Icons.LOGO)
  icon:SetAllPoints()

  local function Paint(hover)
    icon:SetAlpha(hover and 1 or 0.9)
  end
  Paint(false)

  button:SetScript("OnEnter", function(self) Paint(true); Tooltip(self) end)
  button:SetScript("OnLeave", function() Paint(false); GameTooltip:Hide() end)
  button:SetScript("OnClick", function() ns.ToggleUI() end)
  button:SetScript("OnDragStart", function(self)
    GameTooltip:Hide()
    self:SetScript("OnUpdate", OnDragUpdate)
  end)
  button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)

  -- badge: open crafting requests you can make
  local badge = CreateFrame("Frame", nil, button)
  badge:SetSize(16, 16)
  badge:SetPoint("TOPRIGHT", 3, 3)
  badge:SetFrameLevel(button:GetFrameLevel() + 2)
  local bdot = badge:CreateTexture(nil, "ARTWORK")
  bdot:SetAllPoints()
  bdot:SetTexture(ns.Icons.ROUND)
  local btext = T.Text(badge, 10, 1)
  btext:SetPoint("CENTER", 0, 0)
  button.badge, button.badgeText, button.badgeDot = badge, btext, bdot
  badge:Hide()

  Place()
  button:SetShown(not Settings().hide)
  ns.UpdateMinimapBadge()
end

function ns.UpdateMinimapBadge()
  if not button or not button.badge then return end
  local n = ns.Requests and IsInGuild() and ns.Option("minimapBadge") and ns.Requests.ForMe() or 0
  if n > 0 then
    local r, g, b = T.Accent()
    button.badgeDot:SetVertexColor(r, g, b, 1)
    button.badgeText:SetText(n > 9 and "9+" or tostring(n))
    button.badgeText:SetTextColor(0.08, 0.06, 0.05, 1)
    button.badge:Show()
  else
    button.badge:Hide()
  end
end
ns.On("REQUESTS_CHANGED", function() ns.UpdateMinimapBadge() end)
ns.On("DATA_CHANGED", function() ns.UpdateMinimapBadge() end)
ns.On("OPTIONS_CHANGED", function() ns.UpdateMinimapBadge() end)

function ns.ToggleMinimapButton()
  local s = Settings()
  s.hide = not s.hide
  if not button then Create() end
  if button then button:SetShown(not s.hide) end
  ns.Print(s.hide and "Minimap button hidden. Type /fhub minimap to bring it back." or "Minimap button shown.")
end

ns.On("LOGIN", Create)
