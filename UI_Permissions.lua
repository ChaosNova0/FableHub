-- Feature permissions page (opened from Settings > Officers): the Guild Master
-- ticks which ranks may use each officer feature (and asking the guild bank).
-- Everyone else can look but not change it. See Plans.lua for the rules.

local _, ns = ...
local UI, T = ns.UI, ns.Theme

ns.RegisterPanel("permissions", "Feature permissions", nil, function(panel)
  local P = ns.Plans
  local NAME_W, RESET_W, MIN_COL, MAX_COL, ROW_H = 150, 64, 46, 110, 30

  local back = T.Button(panel, "< Settings", 84, 22)
  back:SetPoint("TOPLEFT", 0, 0)
  back:SetScript("OnClick", function() UI.ShowPanel("settings") end)

  local title = T.Text(panel, 15, 1)
  title:SetPoint("LEFT", back, "RIGHT", 12, 0)
  title:SetText("Who can use what")

  local intro = T.Text(panel, 12, 0.6)
  intro:SetPoint("TOPLEFT", 0, -32)
  intro:SetPoint("RIGHT", panel, "RIGHT", 0, 0)
  intro:SetJustifyH("LEFT")
  intro:SetWordWrap(true)

  local resetAll = T.Button(panel, "Reset all", 80, 22)
  resetAll:SetPoint("TOPRIGHT", 0, 0)
  resetAll:SetScript("OnClick", function() P.ResetPerm(nil); panel:Refresh() end)
  resetAll:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Reset all")
    GameTooltip:AddLine("Every feature goes back to following the officer ranks setting (asking the bank: every rank).", 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
  end)
  resetAll:SetScript("OnLeave", function() GameTooltip:Hide() end)

  -- the grid scrolls sideways when there are more ranks than fit
  local scroll = CreateFrame("ScrollFrame", nil, panel)
  scroll:SetPoint("BOTTOMRIGHT", 0, 0)
  local grid = CreateFrame("Frame", nil, scroll)
  grid:SetSize(600, 300)
  scroll:SetScrollChild(grid)
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(self, delta)
    local max = math.max(0, grid:GetWidth() - (self:GetWidth() or 0))
    local x = math.min(max, math.max(0, (self:GetHorizontalScroll() or 0) - delta * 40))
    self:SetHorizontalScroll(x)
  end)

  local heads, rows = {}, {}
  local function Head(i)
    local h = heads[i]
    if h then return h end
    h = CreateFrame("Button", nil, grid)
    h:SetHeight(20)
    h.text = T.Text(h, 11, T.section)
    h.text:SetAllPoints()
    h.text:SetJustifyH("CENTER")
    h.text:SetWordWrap(false)
    h:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
      GameTooltip:AddLine(self.full or "")
      if self.rank == 0 then GameTooltip:AddLine("The Guild Master can always use everything.", 0.8, 0.8, 0.8, true) end
      GameTooltip:Show()
    end)
    h:SetScript("OnLeave", function() GameTooltip:Hide() end)
    heads[i] = h
    return h
  end

  for r, f in ipairs(P.FEATURES) do
    local row = CreateFrame("Frame", nil, grid)
    row:SetHeight(ROW_H)
    row.feature = f.id
    if r % 2 == 0 then T.Fill(row, { 1, 1, 1, 0.025 }) end
    local name = CreateFrame("Button", nil, row)
    name:SetPoint("TOPLEFT", 6, 0)
    name:SetSize(NAME_W - 6, ROW_H)
    name.text = T.Text(name, 12, 0.85)
    name.text:SetPoint("LEFT")
    name.text:SetPoint("RIGHT")
    name.text:SetJustifyH("LEFT")
    name.text:SetWordWrap(false)
    name:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:AddLine(f.name)
      GameTooltip:AddLine(f.desc, 0.8, 0.8, 0.8, true)
      GameTooltip:AddLine(" ")
      GameTooltip:AddLine(P.Customised(f.id) and "Set by the Guild Master."
        or (f.member and "Not changed: every rank." or "Not changed: follows the officer ranks setting."), 0.6, 0.6, 0.6, true)
      GameTooltip:Show()
    end)
    name:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.name = name
    row.cells = {}
    row.reset = T.Button(row, "Reset", RESET_W - 8, 20)
    row.reset:SetScript("OnClick", function() P.ResetPerm(f.id); panel:Refresh() end)
    rows[r] = row
  end

  local function Cell(row, i)
    local c = row.cells[i]
    if c then return c end
    c = T.Toggle(row, "", function(v)
      if not P.SetPerm(row.feature, c.rank, v) then c:SetChecked(not v) end
      panel:Refresh()
    end)
    c:SetWidth(28)
    row.cells[i] = c
    return c
  end

  function panel:Refresh()
    local gm = P.IsGuildMaster()
    local names, n = P.RankNames()
    if n == 0 then n = 1 end
    intro:SetText(gm and "Tick the ranks that may use each feature. Changes reach the guild straight away. Features you haven't changed follow the officer ranks setting; the Guild Master can always use everything."
      or "Only the Guild Master can change these. Hover a feature for what it covers.")
    resetAll:SetShown(gm)

    local top = 32 + math.max(18, intro:GetStringHeight() or 18) + 12
    scroll:ClearAllPoints()
    scroll:SetPoint("TOPLEFT", 0, -top)
    scroll:SetPoint("BOTTOMRIGHT", 0, 0)

    local avail = (panel:GetWidth() or 700) - NAME_W - RESET_W
    local colW = math.max(MIN_COL, math.min(MAX_COL, math.floor(avail / n)))
    local width = NAME_W + n * colW + RESET_W
    grid:SetSize(math.max(width, scroll:GetWidth() or width), 24 + #rows * ROW_H)

    for i = 1, math.max(#heads, n) do
      local h = Head(i)
      if i <= n then
        local rank = i - 1
        h.rank = rank
        h.full = names[rank] or ("Rank " .. i)
        h.text:SetText(h.full)
        h:ClearAllPoints()
        h:SetPoint("TOPLEFT", grid, "TOPLEFT", NAME_W + (i - 1) * colW + 2, 0)
        h:SetWidth(colW - 4)
        h:Show()
      else
        h:Hide()
      end
    end

    for r, row in ipairs(rows) do
      local f = P.FEATURE_BY_ID[row.feature]
      row:ClearAllPoints()
      row:SetPoint("TOPLEFT", grid, "TOPLEFT", 0, -(24 + (r - 1) * ROW_H))
      row:SetWidth(width)
      local custom = P.Customised(f.id)
      row.name.text:SetText(f.name .. (custom and "" or UI.Dim("  default", 0.35)))
      for i = 1, math.max(#row.cells, n) do
        local c = Cell(row, i)
        if i <= n then
          c.rank = i - 1
          c:ClearAllPoints()
          c:SetPoint("CENTER", row, "LEFT", NAME_W + (i - 0.5) * colW, 0)
          c:SetChecked(P.RankAllowed(f.id, i - 1))
          local editable = gm and i > 1
          c:EnableMouse(editable)
          c:SetAlpha(editable and 1 or (gm and 0.45 or 0.7))
          c:Show()
        else
          c:Hide()
        end
      end
      row.reset:ClearAllPoints()
      row.reset:SetPoint("LEFT", row, "LEFT", NAME_W + n * colW + 6, 0)
      row.reset:SetShown(gm and custom)
    end
    UI.SetHint(gm and "Click a switch to allow or block a rank. Hover a feature for what it covers. The mouse wheel scrolls sideways if there are many ranks."
      or "Hover a feature for what it covers.")
  end
  panel:SetScript("OnSizeChanged", function() if panel:IsShown() then panel:Refresh() end end)
end, "titlebar")

ns.On("PLANS_CHANGED", function() if ns.UI.QueueRefresh then ns.UI.QueueRefresh() end end)
