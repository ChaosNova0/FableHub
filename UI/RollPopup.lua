-- Roll popup: when an officer starts a roll (Features/Rolls.lua), FableHub users
-- in the group get this small window: the item, who called the roll, a
-- countdown, what FableHub knows about you and the item (your prio or wishlist
-- spot, or that you already have it) and Main spec / Off spec / Pass.
-- The buttons do a real /roll (RandomRoll); Pass and the close button only
-- close it, and send nothing. Escape doesn't close it (people press Escape in
-- combat to clear their target). Settings > Loot turns popups off.
--
-- Saved: FableHubDB.settings.rollPopupPos = { point, relPoint, x, y } once moved
-- (cleared by /fhub resetwindow). Nothing protected here, so it works in combat.

local _, ns = ...
local UI, T, L, R = ns.UI, ns.Theme, ns.Loot, ns.Rolls

local f

local function SavePosition()
  local point, _, relPoint, x, y = f:GetPoint(1)
  if point then FableHubDB.settings.rollPopupPos = { point, relPoint, math.floor(x or 0), math.floor(y or 0) } end
end

local function Place()
  f:ClearAllPoints()
  local p = FableHubDB.settings.rollPopupPos
  if type(p) == "table" and type(p[1]) == "string" and tonumber(p[3]) and tonumber(p[4]) then
    f:SetPoint(p[1], UIParent, p[2] or p[1], tonumber(p[3]), tonumber(p[4]))
  else
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 180)
  end
end

-- "You're Prio 2 on this", "Wishlist 1", "You already have it"
local function Context(itemID)
  local me = ns.MyKey()
  if not me then return "" end
  local parts = {}
  local prio, wish = L.ItemPriorities(itemID)
  local found
  for _, r in ipairs(prio) do if r.key == me then found = "You're Prio " .. r.order .. " on this" break end end
  if not found then
    for _, r in ipairs(wish) do if r.key == me then found = "Wishlist " .. r.order break end end
  end
  if found then parts[#parts + 1] = UI.Colorize(found, 1, 0.82, 0) end
  if L.Received(itemID, me) then parts[#parts + 1] = UI.Colorize("You already have it", 0.95, 0.45, 0.4) end
  return table.concat(parts, UI.Dim("  ·  ", 0.4))
end

local function Build()
  f = CreateFrame("Frame", "FableHubRollFrame", UIParent)
  f:SetSize(330, 124)
  f:SetFrameStrata("DIALOG")
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", function() f:StopMovingOrSizing(); SavePosition() end)
  T.Fill(f, T.bg)
  T.Border(f, 0.12)
  f:Hide()

  f.title = T.Text(f, 12, 0.9)
  f.title:SetPoint("TOPLEFT", 12, -10)
  f.timeText = T.Text(f, 12, 0.6)
  f.timeText:SetPoint("TOPRIGHT", -34, -10)
  local close = T.CloseButton(f, function() R.ClosePopup() end)
  close:SetPoint("TOPRIGHT", -6, -6)

  -- item icon with its tooltip
  f.icon = CreateFrame("Button", nil, f)
  f.icon:SetSize(36, 36)
  f.icon:SetPoint("TOPLEFT", 12, -30)
  f.iconTex = f.icon:CreateTexture(nil, "ARTWORK")
  f.iconTex:SetAllPoints()
  T.Border(f.icon, 0.25)
  f.icon:SetScript("OnEnter", function(self)
    local inc = R.incoming
    if not inc then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if not pcall(GameTooltip.SetItemByID, GameTooltip, inc.item) then GameTooltip:AddLine(L.ItemText(inc.item)) end
    GameTooltip:Show()
  end)
  f.icon:SetScript("OnLeave", function() GameTooltip:Hide() end)

  f.itemText = T.Text(f, 13, 1)
  f.itemText:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", 10, -2)
  f.itemText:SetPoint("RIGHT", f, "RIGHT", -12, 0)
  f.itemText:SetJustifyH("LEFT")
  f.context = T.Text(f, 11, 0.8)
  f.context:SetPoint("TOPLEFT", f.itemText, "BOTTOMLEFT", 0, -4)
  f.context:SetPoint("RIGHT", f, "RIGHT", -12, 0)
  f.context:SetJustifyH("LEFT")

  -- countdown bar
  f.barBg = f:CreateTexture(nil, "ARTWORK")
  f.barBg:SetColorTexture(1, 1, 1, 0.06)
  f.barBg:SetHeight(3)
  f.barBg:SetPoint("TOPLEFT", 12, -74)
  f.barBg:SetPoint("TOPRIGHT", -12, -74)
  f.bar = f:CreateTexture(nil, "OVERLAY")
  f.bar:SetHeight(3)
  f.bar:SetPoint("TOPLEFT", f.barBg, "TOPLEFT")

  f.ms = T.Button(f, "Main spec (" .. R.MS .. ")", 112, 24)
  f.ms:SetPoint("BOTTOMLEFT", 12, 12)
  f.ms:SetScript("OnClick", function() R.PopupRoll("ms") end)
  f.os = T.Button(f, "Off spec (" .. R.OS .. ")", 112, 24)
  f.os:SetPoint("LEFT", f.ms, "RIGHT", 6, 0)
  f.os:SetScript("OnClick", function() R.PopupRoll("os") end)
  f.pass = T.Button(f, "Pass", 70, 24)
  f.pass:SetPoint("LEFT", f.os, "RIGHT", 6, 0)
  f.pass:SetScript("OnClick", function() R.ClosePopup() end)
  f.ms:SetSelected(true)

  -- anything else hiding it (the UI being hidden, a reload): that's a pass
  f:SetScript("OnHide", function() if R.incoming then R.ClosePopup() end end)

  local acc = 0
  f:SetScript("OnUpdate", function(_, elapsed)
    acc = acc + (elapsed or 0)
    if acc < 0.2 then return end
    acc = 0
    f:Tick()
  end)

  function f:Tick()
    local inc = R.incoming
    if not inc then return end
    local total = math.max(1, inc.localEnds - (inc.shownAt or GetTime()))
    local left = math.max(0, inc.localEnds - GetTime())
    self.timeText:SetText(("%ds"):format(math.ceil(left)))
    local w = self.barBg:GetWidth() or 0
    self.bar:SetWidth(math.max(1, w * left / total))
    -- the item's name and icon load on demand
    if not self.loaded then self:FillItem() end
  end

  function f:FillItem()
    local inc = R.incoming
    if not inc then return end
    local info = L.ItemInfo(inc.item)
    self.loaded = info ~= nil
    self.itemText:SetText(info and info.link or ("item " .. inc.item))
    self.iconTex:SetTexture(info and info.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
  end
end

local function Show()
  local inc = R.incoming
  if not inc then
    if f and f:IsShown() then f:Hide() end
    return
  end
  if not f then Build() end
  Place()
  inc.shownAt = inc.shownAt or GetTime()
  local who = inc.own and "you" or ns.ShortName(inc.from)
  f.title:SetText(("|c%sFable|rHub roll%s"):format(T.AccentHex(), UI.Dim("   called by " .. who, 0.5)))
  local ar, ag, ab = T.Accent()
  f.bar:SetColorTexture(ar, ag, ab, 0.9)
  f.loaded = false
  f:FillItem()
  local ctx = Context(inc.item)
  f.context:SetText(ctx ~= "" and ctx or UI.Dim(inc.test and "A sample: drag it where you want it" or "Typing /roll works too", 0.45))
  f:Show()
  f:Tick()
end

ns.On("ROLL_POPUP", Show)

-- a sample popup, to place it before raid night
ns.SlashHandlers["testroll"] = function() R.TestPopup() end
