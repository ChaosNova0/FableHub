-- UI: main window (title bar, sidebar navigation, content area), a sortable
-- list widget with flexible columns, and shared UI helpers.

local _, ns = ...
local T = ns.Theme
local UI = {}
ns.UI = UI

local main
local panels, panelOrder = {}, {}
local current
UI._panels = panels -- exposed for testing

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------
function UI.TimeAgo(ts)
  if not ts or ts == 0 then return "never" end
  local d = ns.Now() - ts
  if d < 90 then return "just now" end
  if d < 3600 then return math.floor(d / 60) .. "m ago" end
  if d < 86400 then return math.floor(d / 3600) .. "h ago" end
  return math.floor(d / 86400) .. "d ago"
end

function UI.Colorize(text, r, g, b)
  return ("|cff%02x%02x%02x%s|r"):format(r * 255, g * 255, b * 255, text)
end

function UI.Dim(text, alpha)
  local v = math.floor(255 * (alpha or T.dim))
  return ("|cff%02x%02x%02x%s|r"):format(v, v, v, text)
end

function UI.ClassName(key, classFile)
  return UI.Colorize(ns.ShortName(key), ns.ClassColor(classFile))
end

-- name cell: status dot, class icon, class-coloured name (dimmed when offline)
function UI.NameCell(key, classFile, online)
  local name = ns.ShortName(key)
  local text = online and UI.Colorize(name, ns.ClassColor(classFile)) or UI.Dim(name, 0.45)
  return ns.Icons.Dot(online) .. " " .. ns.Icons.Class(classFile, 14) .. " " .. text
end

function UI.Whisper(key, text)
  local target = ns.ShortName(key)
  if text and text ~= "" then
    local cmd = "/w " .. target .. " " .. text
    if ChatFrameUtil and ChatFrameUtil.OpenChat then return ChatFrameUtil.OpenChat(cmd) end
    if ChatFrame_OpenChat then return ChatFrame_OpenChat(cmd) end
  end
  if ChatFrameUtil and ChatFrameUtil.SendTell then return ChatFrameUtil.SendTell(target) end
  if ChatFrame_SendTell then return ChatFrame_SendTell(target) end
end

function UI.InsertLink(link)
  if not link then return false end
  if ChatFrameUtil and ChatFrameUtil.InsertLink then return ChatFrameUtil.InsertLink(link) end
  if ChatEdit_InsertLink then return ChatEdit_InsertLink(link) end
  return false
end

-- Tooltip skinning: dark panel + hairline, applied while we own the tooltip
function UI.TooltipOwner(owner)
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
end

------------------------------------------------------------------------
-- Sortable virtual list
--   columns = { { title, width | flex = true, justify, defaultAsc, bar } }
--   list:SetItems({ { cols = {...}, sort = {...}, bars = { [c] = 0..1 }, tooltip, onClick } })
------------------------------------------------------------------------
local GAP = 10

-- opts.noHeader: no column titles (compact lists on the Home page)
function UI.CreateList(parent, columns, rowHeight, opts)
  rowHeight = rowHeight or 22
  opts = opts or {}
  local list = CreateFrame("Frame", nil, parent)
  list.columns, list.items, list.offset = columns, {}, 0
  list.sortCol, list.sortAsc = 1, true
  list.rows, list.headers, list.widths, list.lefts = {}, {}, {}, {}

  -- header and rows sit in a horizontal scroll frame: when the window is too
  -- narrow for the columns, the table scrolls sideways instead of spilling out
  local hs = CreateFrame("ScrollFrame", nil, list)
  hs:SetPoint("TOPLEFT")
  hs:SetPoint("BOTTOMRIGHT", -10, 0)
  if hs.SetClipsChildren then hs:SetClipsChildren(true) end
  local inner = CreateFrame("Frame", nil, hs)
  inner:SetSize(100, 100)
  hs:SetScrollChild(inner)
  list.hscroll, list.inner = hs, inner

  local header = CreateFrame("Frame", nil, inner)
  header:SetPoint("TOPLEFT")
  header:SetPoint("TOPRIGHT")
  header:SetHeight(opts.noHeader and 1 or 20)
  if opts.noHeader then header:SetAlpha(0) end
  local line = header:CreateTexture(nil, "ARTWORK")
  line:SetColorTexture(1, 1, 1, T.border)
  line:SetPoint("BOTTOMLEFT")
  line:SetPoint("BOTTOMRIGHT")
  line:SetHeight(1)

  for i, col in ipairs(columns) do
    local h = CreateFrame("Button", nil, header)
    h:SetHeight(20)
    local fs = T.Text(h, 11, T.section)
    fs:SetAllPoints()
    fs:SetJustifyH(col.justify or "LEFT")
    h.text = fs
    list.headers[i] = h
    h:SetScript("OnClick", function()
      if list.sortable == false then return end
      if list.sortCol == i then list.sortAsc = not list.sortAsc
      else list.sortCol, list.sortAsc = i, (col.defaultAsc ~= false) end
      list:Sort()
      list:Update()
    end)
    h:SetScript("OnEnter", function() fs:SetTextColor(1, 1, 1, 0.8) end)
    h:SetScript("OnLeave", function() list:Update() end)
  end

  local body = CreateFrame("Frame", nil, inner)
  body:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, opts.noHeader and 0 or -2)
  body:SetPoint("BOTTOMRIGHT", inner, "BOTTOMRIGHT")
  list.body = body

  local empty = T.Text(list, 12, 0.35)
  empty:SetPoint("TOP", hs, "TOP", 0, opts.noHeader and -40 or -62)
  empty:SetWidth(380)
  empty:SetJustifyH("CENTER")
  list.emptyText = empty

  -- slim scrollbar
  local slider = CreateFrame("Slider", nil, list)
  slider:SetPoint("TOPRIGHT", 0, opts.noHeader and 0 or -22)
  slider:SetPoint("BOTTOMRIGHT", 0, 0)
  slider:SetWidth(4)
  slider:SetOrientation("VERTICAL")
  T.Fill(slider, { 1, 1, 1, 0.05 })
  local thumb = slider:CreateTexture(nil, "OVERLAY")
  thumb:SetColorTexture(1, 1, 1, 0.25)
  thumb:SetSize(4, 40)
  slider:SetThumbTexture(thumb)
  slider:SetMinMaxValues(0, 0)
  slider:SetValueStep(1)
  if slider.SetObeyStepOnDrag then slider:SetObeyStepOnDrag(true) end
  slider:SetScript("OnValueChanged", function(_, v)
    local o = math.floor(v + 0.5)
    if o ~= list.offset then list.offset = o; list:Update() end
  end)
  slider:SetScript("OnEnter", function()
    local r, g, b = T.Accent()
    thumb:SetColorTexture(r, g, b, 0.8)
  end)
  slider:SetScript("OnLeave", function() thumb:SetColorTexture(1, 1, 1, 0.25) end)
  list.slider = slider

  -- slim horizontal scrollbar, only when the columns don't fit
  local hbar = CreateFrame("Slider", nil, list)
  hbar:SetPoint("BOTTOMLEFT", 0, 0)
  hbar:SetPoint("BOTTOMRIGHT", -10, 0)
  hbar:SetHeight(4)
  hbar:SetOrientation("HORIZONTAL")
  T.Fill(hbar, { 1, 1, 1, 0.05 })
  local hthumb = hbar:CreateTexture(nil, "OVERLAY")
  hthumb:SetColorTexture(1, 1, 1, 0.25)
  hthumb:SetSize(40, 4)
  hbar:SetThumbTexture(hthumb)
  hbar:SetMinMaxValues(0, 0)
  hbar:SetValueStep(1)
  hbar:SetScript("OnValueChanged", function(_, v) if hs.SetHorizontalScroll then hs:SetHorizontalScroll(v) end end)
  hbar:SetScript("OnEnter", function() local r, g, b = T.Accent(); hthumb:SetColorTexture(r, g, b, 0.8) end)
  hbar:SetScript("OnLeave", function() hthumb:SetColorTexture(1, 1, 1, 0.25) end)
  hbar:Hide()
  list.hbar = hbar

  list:EnableMouseWheel(true)
  list:SetScript("OnMouseWheel", function(_, delta)
    if hbar:IsShown() and IsShiftKeyDown and IsShiftKeyDown() then
      local _, hmax = hbar:GetMinMaxValues()
      hbar:SetValue(math.max(0, math.min(hmax, (hbar:GetValue() or 0) - delta * 40)))
      return
    end
    local _, max = slider:GetMinMaxValues()
    slider:SetValue(math.max(0, math.min(max, list.offset - delta * 3)))
  end)

  -- smallest width the columns need (flex columns get at least MIN_FLEX)
  local MIN_FLEX = 90
  function list:MinWidth()
    local fixed, flex = 0, 0
    for _, col in ipairs(columns) do
      if col.flex then flex = flex + 1 else fixed = fixed + (col.width or 80) end
    end
    return 8 + fixed + flex * MIN_FLEX + GAP * (#columns - 1) + 4
  end
  -- size the scrolling area: as wide as the list, or wider when the columns need it
  function list:FitWidth()
    local avail = (list:GetWidth() or 0) - 10
    local height = list:GetHeight() or 0
    if avail <= 0 or height <= 0 then return end
    local need = self:MinWidth()
    local wide = need > avail
    inner:SetSize(wide and need or avail, height - (wide and 8 or 0))
    hbar:SetShown(wide)
    slider:SetPoint("BOTTOMRIGHT", 0, wide and 8 or 0) -- keep the two scrollbars apart
    hbar:SetMinMaxValues(0, wide and (need - avail) or 0)
    if not wide then hbar:SetValue(0); if hs.SetHorizontalScroll then hs:SetHorizontalScroll(0) end end
  end
  list:SetScript("OnSizeChanged", function() list:FitWidth() end)

  local function MakeRow(i)
    local row = CreateFrame("Button", nil, body)
    row:SetHeight(rowHeight)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * rowHeight)
    row:SetPoint("TOPRIGHT", 0, -(i - 1) * rowHeight)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    T.Fill(row, { 0, 0, 0, (i % 2 == 0) and 0.2 or 0.1 })
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.04)
    local accentLine = row:CreateTexture(nil, "HIGHLIGHT")
    accentLine:SetPoint("TOPLEFT")
    accentLine:SetPoint("BOTTOMLEFT")
    accentLine:SetWidth(2)
    row.accentLine = accentLine
    local headerBg = row:CreateTexture(nil, "BORDER")
    headerBg:SetAllPoints()
    headerBg:SetColorTexture(1, 1, 1, 0.045)
    headerBg:Hide()
    row.headerBg = headerBg
    row.cells, row.bars = {}, {}
    for c, col in ipairs(columns) do
      local fs = T.Text(row, 12)
      fs:SetJustifyH(col.justify or "LEFT")
      fs:SetWordWrap(false)
      row.cells[c] = fs
      if col.bar then
        local track = row:CreateTexture(nil, "ARTWORK")
        track:SetColorTexture(1, 1, 1, 0.08)
        track:SetHeight(2)
        local fill = row:CreateTexture(nil, "OVERLAY")
        fill:SetHeight(2)
        row.bars[c] = { track = track, fill = fill }
      end
    end
    row:SetScript("OnEnter", function(self)
      local r, g, b = T.Accent()
      self.accentLine:SetColorTexture(r, g, b, 0.9)
      local item = self.item
      if item and item.tooltip then
        UI.TooltipOwner(self)
        item.tooltip(GameTooltip, item)
        GameTooltip:Show()
      end
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:SetScript("OnClick", function(self, button)
      if self.item and self.item.onClick then self.item.onClick(self.item, button) end
    end)
    row:RegisterForDrag("LeftButton")
    row:SetScript("OnDragStart", function(self)
      if self.item and self.item.onDragStart then GameTooltip:Hide(); self.item.onDragStart(self.item) end
    end)
    list:PlaceRow(row)
    return row
  end

  -- work out column positions from the current width
  function list:ComputeColumns()
    local width = (body:GetWidth() or 0)
    local fixed, flexCount = 0, 0
    for _, col in ipairs(columns) do
      if col.flex then flexCount = flexCount + 1 else fixed = fixed + (col.width or 80) end
    end
    local avail = width - 8 - GAP * (#columns - 1)
    local flexW = flexCount > 0 and math.max(MIN_FLEX, (avail - fixed) / flexCount) or 0
    local x = 8
    for i, col in ipairs(columns) do
      local w = col.flex and flexW or (col.width or 80)
      self.widths[i], self.lefts[i] = w, x
      x = x + w + GAP
    end
  end

  function list:PlaceRow(row)
    for c, fs in ipairs(row.cells) do
      fs:ClearAllPoints()
      fs:SetPoint("LEFT", row, "LEFT", self.lefts[c] or 0, 0)
      fs:SetWidth(self.widths[c] or 80)
      local bar = row.bars[c]
      if bar then
        fs:ClearAllPoints()
        fs:SetPoint("LEFT", row, "LEFT", self.lefts[c] or 0, 2)
        bar.track:ClearAllPoints()
        bar.track:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", self.lefts[c] or 0, 3)
        bar.track:SetWidth(math.max(1, (self.widths[c] or 80) - 8))
        bar.fill:ClearAllPoints()
        bar.fill:SetPoint("BOTTOMLEFT", bar.track, "BOTTOMLEFT")
      end
    end
  end

  function list:Layout()
    self:ComputeColumns()
    for i, h in ipairs(self.headers) do
      h:ClearAllPoints()
      h:SetPoint("LEFT", header, "LEFT", self.lefts[i], 0)
      h:SetWidth(self.widths[i])
    end
    for _, row in ipairs(self.rows) do self:PlaceRow(row) end
    local n = math.max(1, math.floor((body:GetHeight() or 0) / rowHeight))
    for i = #self.rows + 1, n do self.rows[i] = MakeRow(i) end
    self.visible = n
    self:Update()
  end
  body:SetScript("OnSizeChanged", function() list:Layout() end)

  function list:Sort()
    if self.sortable == false then return end
    local c, asc = self.sortCol, self.sortAsc
    table.sort(self.items, function(a, b)
      if a.pinned ~= b.pinned then return a.pinned and true or false end
      local va = a.sort and a.sort[c]; if va == nil then va = a.cols[c] or "" end
      local vb = b.sort and b.sort[c]; if vb == nil then vb = b.cols[c] or "" end
      if type(va) ~= type(vb) then va, vb = tostring(va), tostring(vb) end
      if va == vb then
        local na, nb = tostring(a.sort and a.sort[1] or a.cols[1]), tostring(b.sort and b.sort[1] or b.cols[1])
        return na < nb
      end
      if asc then return va < vb else return va > vb end
    end)
  end

  function list:SetItems(items, emptyMsg)
    self.items = items or {}
    self.emptyText:SetText(#self.items == 0 and (emptyMsg or "Nothing to show") or "")
    self:Sort()
    self:Update()
  end

  function list:Update()
    local n = self.visible or 0
    local max = math.max(0, #self.items - n)
    self.slider:SetMinMaxValues(0, max)
    if self.offset > max then self.offset = max end
    self.slider:SetShown(max > 0)
    local ar, ag, ab = T.Accent()
    for i = 1, #self.rows do
      local row = self.rows[i]
      local item = (i <= n) and self.items[i + self.offset] or nil
      row.item = item
      if item then
        for c, fs in ipairs(row.cells) do fs:SetText(item.cols[c] or "") end
        row.headerBg:SetShown(item.header and true or false)
        for c, bar in pairs(row.bars) do
          local frac = item.bars and item.bars[c]
          if frac then
            bar.track:Show()
            bar.fill:Show()
            bar.fill:SetColorTexture(ar, ag, ab, 0.75)
            bar.fill:SetWidth(math.max(1, bar.track:GetWidth() * math.min(1, frac)))
          else
            bar.track:Hide()
            bar.fill:Hide()
          end
        end
        row:Show()
      else
        row:Hide()
      end
    end
    for i, h in ipairs(self.headers) do
      local title = self.columns[i].title:upper()
      if i == self.sortCol and self.sortable ~= false then
        h.text:SetText(title .. (self.sortAsc and "  ^" or "  v"))
        h.text:SetTextColor(ar, ag, ab, 0.9)
      else
        h.text:SetText(title)
        h.text:SetTextColor(1, 1, 1, T.section)
      end
    end
  end

  return list
end

------------------------------------------------------------------------
-- Drag and drop: UI.BeginDrag(payload, label); drop targets set frame.OnDrop
------------------------------------------------------------------------
local ghost
UI.dropTargets = {}

function UI.RegisterDropTarget(frame) table.insert(UI.dropTargets, frame) end

-- MouseIsOver() was removed from the modern client; frames have IsMouseOver()
function UI.IsMouseOver(f)
  if f.IsMouseOver then return f:IsMouseOver() end
  if MouseIsOver then return MouseIsOver(f) end
  return false
end

local function TargetUnderCursor()
  for _, f in ipairs(UI.dropTargets) do
    if f:IsVisible() and f.OnDrop and UI.IsMouseOver(f) then return f end
  end
end

function UI.BeginDrag(payload, label)
  if not ghost then
    ghost = CreateFrame("Frame", nil, UIParent)
    ghost:SetFrameStrata("TOOLTIP")
    ghost:SetSize(160, 22)
    T.Fill(ghost, { 0.07, 0.06, 0.05, 0.95 })
    T.Border(ghost, 0.3)
    ghost.text = T.Text(ghost, 12, 1)
    ghost.text:SetPoint("LEFT", 8, 0)
    ghost:Hide()
  end
  ghost.payload = payload
  ghost.text:SetText(label or "")
  ghost:SetWidth(math.max(100, (ghost.text:GetStringWidth() or 100) + 18))
  local hovered
  ghost:SetScript("OnUpdate", function(self)
    local x, y = GetCursorPosition()
    local s = UIParent:GetEffectiveScale()
    self:ClearAllPoints()
    self:SetPoint("LEFT", UIParent, "BOTTOMLEFT", x / s + 12, y / s)
    local target = TargetUnderCursor()
    if target ~= hovered then
      if hovered and hovered.SetDropHover then hovered:SetDropHover(false) end
      if target and target.SetDropHover then target:SetDropHover(true) end
      hovered = target
    end
    if not IsMouseButtonDown("LeftButton") then
      self:SetScript("OnUpdate", nil)
      self:Hide()
      if hovered and hovered.SetDropHover then hovered:SetDropHover(false) end
      local t = TargetUnderCursor()
      if t then t.OnDrop(t, self.payload) end
    end
  end)
  ghost:Show()
end

------------------------------------------------------------------------
-- Main window
------------------------------------------------------------------------
-- group = id of a nav group (ns.RegisterNavGroup) to show this panel under
function ns.RegisterPanel(id, title, icon, builder, group)
  panels[id] = { id = id, title = title, icon = icon, builder = builder, group = group }
  table.insert(panelOrder, id)
end

-- A sidebar section with sub-items. children = panel ids in display order.
local groups = {}
-- parent = id of the group this one sits inside (a third sidebar level)
function ns.RegisterNavGroup(id, title, icon, children, parent)
  groups[id] = { id = id, title = title, icon = icon, children = children, parent = parent }
end

-- is panel id shown inside group gid (directly or in one of its sub-groups)?
local function InGroup(id, gid)
  local p = panels[id]
  local g = p and p.group and groups[p.group]
  while g do
    if g.id == gid then return true end
    g = g.parent and groups[g.parent]
  end
  return false
end

-- first panel of a group (descending into sub-groups)
local function FirstPanel(gid)
  local g = groups[gid]
  local first = g and g.children[1]
  if first and groups[first] then return FirstPanel(first) end
  return first
end

local LayoutNav

-- a page that errors shouldn't take the rest of the window down with it
local function SafeRefresh(p)
  if not (p and p.frame and p.frame.Refresh) then return end
  local ok, err = pcall(p.frame.Refresh, p.frame)
  if not ok then ns.ReportError("page " .. p.id .. ": " .. tostring(err)) end
end

local function ShowPanel(id)
  for pid, p in pairs(panels) do
    if p.frame then p.frame:SetShown(pid == id) end
    if p.nav then p.nav:SetSelected(pid == id) end
  end
  local open = FableHubDB.settings.navOpen
  for gid, grp in pairs(groups) do
    local inside = InGroup(id, gid)
    if inside then open[gid] = true end
    if grp.nav then grp.nav:SetActive(inside) end
  end
  if LayoutNav then LayoutNav() end
  if main and main.NavReveal and panels[id] then main.NavReveal(panels[id].nav) end
  current = id
  if main and main.PaintCog then main.PaintCog(false) end
  SafeRefresh(panels[id])
  if FableHubDB and id ~= "settings" and id ~= "permissions" then FableHubDB.settings.lastTab = id end
end

UI.ShowPanel = function(id) if main then ShowPanel(id) end end

local function SaveGeometry()
  local s = FableHubDB.settings
  local point, _, relPoint, x, y = main:GetPoint()
  s.window = { point = point, relPoint = relPoint, x = x, y = y, w = main:GetWidth(), h = main:GetHeight() }
end

local function Build()
  main = CreateFrame("Frame", "FableHubFrame", UIParent)
  local s = FableHubDB.settings
  local w = s.window
  main:SetSize(w and w.w or 900, w and w.h or 540)
  if w and w.point then main:SetPoint(w.point, UIParent, w.relPoint or w.point, w.x, w.y)
  else main:SetPoint("CENTER") end
  main:SetFrameStrata("HIGH")
  main:SetToplevel(true)
  main:SetClampedToScreen(true)
  main:SetMovable(true)
  main:SetResizable(true)
  if main.SetResizeBounds then main:SetResizeBounds(740, 400, 1600, 1000)
  elseif main.SetMinResize then main:SetMinResize(740, 400) end
  main:EnableMouse(true)
  main:Hide()
  table.insert(UISpecialFrames, "FableHubFrame")

  main.bgTex = T.Fill(main, T.bg)
  T.Border(main, 0.08)

  -- title bar (drag to move)
  local titleBar = CreateFrame("Frame", nil, main)
  titleBar:SetPoint("TOPLEFT")
  titleBar:SetPoint("TOPRIGHT")
  titleBar:SetHeight(40)
  titleBar:EnableMouse(true)
  titleBar:RegisterForDrag("LeftButton")
  titleBar:SetScript("OnDragStart", function() main:StartMoving() end)
  titleBar:SetScript("OnDragStop", function() main:StopMovingOrSizing(); SaveGeometry() end)
  local sep = titleBar:CreateTexture(nil, "ARTWORK")
  sep:SetColorTexture(1, 1, 1, T.border)
  sep:SetPoint("BOTTOMLEFT")
  sep:SetPoint("BOTTOMRIGHT")
  sep:SetHeight(1)

  local logo = T.Text(titleBar, 17, 1)
  logo:SetPoint("LEFT", 16, 0)
  main.logo = logo
  local guildText = T.Text(titleBar, 12, T.dim)
  guildText:SetPoint("LEFT", logo, "RIGHT", 12, -1)
  main.guildText = guildText

  local close = T.CloseButton(titleBar, function() main:Hide() end)
  close:SetPoint("RIGHT", -10, 0)

  -- Settings cog, left of the close button: click to open Settings, again to go back
  local cog = CreateFrame("Button", nil, titleBar)
  cog:SetSize(18, 18)
  cog:SetPoint("RIGHT", close, "LEFT", -8, 0)
  local cogTex = cog:CreateTexture(nil, "ARTWORK")
  cogTex:SetAllPoints()
  cogTex:SetTexture("Interface\\Buttons\\UI-OptionsButton")
  local function PaintCog(hover)
    if current == "settings" or current == "permissions" or hover then
      local r, g, b = T.Accent()
      cogTex:SetVertexColor(r, g, b, 1)
    else
      cogTex:SetVertexColor(1, 1, 1, 0.55)
    end
  end
  cog:SetScript("OnEnter", function(self)
    PaintCog(true)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Settings")
    GameTooltip:Show()
  end)
  cog:SetScript("OnLeave", function() PaintCog(false); GameTooltip:Hide() end)
  cog:SetScript("OnClick", function()
    if current == "settings" or current == "permissions" then
      ShowPanel(UI.beforeSettings and panels[UI.beforeSettings] and UI.beforeSettings or "home")
    else
      UI.beforeSettings = current
      ShowPanel("settings")
    end
    PaintCog(false)
  end)
  main.PaintCog = PaintCog

  -- sidebar
  local side = CreateFrame("Frame", nil, main)
  side:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 1, 0)
  side:SetPoint("BOTTOMLEFT", 1, 1)
  side:SetWidth(190)
  main.sideTex = T.Fill(side, T.sidebar)
  local sideLine = side:CreateTexture(nil, "ARTWORK")
  sideLine:SetColorTexture(1, 1, 1, T.border)
  sideLine:SetPoint("TOPRIGHT")
  sideLine:SetPoint("BOTTOMRIGHT")
  sideLine:SetWidth(1)

  local navLabel = T.Text(side, 11, T.section)
  navLabel:SetPoint("TOPLEFT", 14, -16)
  navLabel:SetText("GUILD")

  local sideStatus = T.Text(side, 11, 0.4)
  sideStatus:SetPoint("BOTTOMLEFT", 14, 14)
  sideStatus:SetPoint("BOTTOMRIGHT", -10, 14)
  sideStatus:SetJustifyH("LEFT")
  sideStatus:SetSpacing(3)
  main.sideStatus = sideStatus

  -- the navigation scrolls between the GUILD label and the status text
  local navScroll = CreateFrame("ScrollFrame", nil, side)
  navScroll:SetPoint("TOPLEFT", 0, -36)
  navScroll:SetPoint("BOTTOMRIGHT", 0, 64)
  if navScroll.SetClipsChildren then navScroll:SetClipsChildren(true) end
  local nav = CreateFrame("Frame", nil, navScroll)
  nav:SetSize(190, 10)
  navScroll:SetScrollChild(nav)
  local navBar = navScroll:CreateTexture(nil, "OVERLAY") -- thin position marker, only when it scrolls
  navBar:SetWidth(2)
  navBar:SetColorTexture(1, 1, 1, 0.18)
  navBar:Hide()
  local function NavScrollTo(v)
    local max = math.max(0, (nav:GetHeight() or 0) - (navScroll:GetHeight() or 0))
    v = math.max(0, math.min(max, v or 0))
    navScroll:SetVerticalScroll(v)
    local view, total = navScroll:GetHeight() or 0, nav:GetHeight() or 0
    if max > 0 and total > 0 then
      local h = math.max(20, view * view / total)
      navBar:SetHeight(h)
      navBar:ClearAllPoints()
      navBar:SetPoint("TOPRIGHT", navScroll, "TOPRIGHT", -2, -(view - h) * (v / max))
      navBar:Show()
    else
      navBar:Hide()
    end
  end
  navScroll:EnableMouseWheel(true)
  navScroll:SetScript("OnMouseWheel", function(self, delta) NavScrollTo((self:GetVerticalScroll() or 0) - delta * 32) end)
  navScroll:SetScript("OnSizeChanged", function() NavScrollTo((navScroll:GetVerticalScroll() or 0)) end)
  main.NavScrollTo = NavScrollTo
  -- keep a sidebar entry in view (e.g. the page you just opened)
  function main.NavReveal(btn)
    if not btn or not btn:IsShown() or not btn.navY then return end
    local top, view = (navScroll:GetVerticalScroll() or 0), navScroll:GetHeight() or 0
    if btn.navY < top then NavScrollTo(btn.navY)
    elseif btn.navY + 32 > top + view then NavScrollTo(btn.navY + 32 - view) end
  end

  -- content
  local content = CreateFrame("Frame", nil, main)
  content:SetPoint("TOPLEFT", side, "TOPRIGHT", 16, -14)
  content:SetPoint("BOTTOMRIGHT", -14, 34)

  local hint = T.Text(main, 11, 0.35)
  hint:SetPoint("BOTTOMLEFT", side, "BOTTOMRIGHT", 16, 12)
  main.hint = hint

  -- sidebar entries in order: plain panels, and groups where their first child appears
  s.navOpen = s.navOpen or {}
  local entries, emitted = {}, {}
  for _, id in ipairs(panelOrder) do
    local p = panels[id]
    local grp = p.group and groups[p.group]
    while grp and grp.parent and groups[grp.parent] do grp = groups[grp.parent] end -- emit from the top group
    -- "titlebar" pages (Settings, Feature permissions) open from the title bar, not the sidebar
    if p.group ~= "titlebar" and grp then
      if not emitted[grp.id] then
        emitted[grp.id] = true
        if s.navOpen[grp.id] == nil then s.navOpen[grp.id] = true end
        grp.nav = T.NavButton(nav, grp.title, grp.icon, { caret = true })
        local function GroupClick(g)
          return function()
            if s.navOpen[g.id] and InGroup(current, g.id) then
              s.navOpen[g.id] = false
              LayoutNav()
            else
              s.navOpen[g.id] = true
              ShowPanel(FirstPanel(g.id))
            end
          end
        end
        grp.nav:SetScript("OnClick", GroupClick(grp))
        entries[#entries + 1] = { nav = grp.nav }
        for _, cid in ipairs(grp.children) do
          local sub = groups[cid]
          if sub then
            -- a sub-group: its own header, with its pages one level further in
            if s.navOpen[sub.id] == nil then s.navOpen[sub.id] = true end
            sub.nav = T.NavButton(nav, sub.title, nil, { indent = true, caret = true })
            sub.nav:SetScript("OnClick", GroupClick(sub))
            entries[#entries + 1] = { nav = sub.nav, group = grp.id }
            for _, sid in ipairs(sub.children) do
              local c = panels[sid]
              if c then
                c.nav = T.NavButton(nav, c.title, nil, { indent = 2 })
                c.nav:SetScript("OnClick", function() ShowPanel(sid) end)
                entries[#entries + 1] = { nav = c.nav, group = sub.id, parent = grp.id }
              end
            end
          else
            local c = panels[cid]
            if c then
              c.nav = T.NavButton(nav, c.title, nil, { indent = true })
              c.nav:SetScript("OnClick", function() ShowPanel(cid) end)
              entries[#entries + 1] = { nav = c.nav, group = grp.id }
            end
          end
        end
      end
    elseif p.group ~= "titlebar" then
      p.nav = T.NavButton(nav, p.title, p.icon)
      p.nav:SetScript("OnClick", function() ShowPanel(id) end)
      entries[#entries + 1] = { nav = p.nav }
    end
  end
  LayoutNav = function()
    local y = 0
    for _, e in ipairs(entries) do
      local visible = (not e.group or s.navOpen[e.group]) and (not e.parent or s.navOpen[e.parent])
      e.nav:SetShown(visible)
      if visible then
        e.nav:ClearAllPoints()
        e.nav:SetPoint("TOPLEFT", 0, y)
        e.nav:SetPoint("TOPRIGHT", -1, y)
        e.nav.navY = -y
        y = y - (e.group and 26 or 32)
      end
    end
    nav:SetHeight(math.max(10, -y + 4))
    NavScrollTo((navScroll:GetVerticalScroll() or 0))
    for gid, grp in pairs(groups) do if grp.nav then grp.nav:SetOpen(s.navOpen[gid]) end end
  end
  LayoutNav()

  for _, id in ipairs(panelOrder) do
    local p = panels[id]
    local f = CreateFrame("Frame", nil, content)
    f:SetAllPoints()
    f:Hide()
    p.frame = f
    local ok, err = pcall(p.builder, f)
    if not ok then
      ns.ReportError("building page " .. id .. ": " .. tostring(err))
      f.Refresh = nil
      local msg = T.Text(f, 12, 0.6)
      msg:SetPoint("CENTER")
      msg:SetText("This page couldn't load. The rest of FableHub still works.")
    elseif f._toolbars then
      -- toolbars reflow after every refresh (things shown/hidden) and on resize
      local refresh = f.Refresh
      if refresh then
        f.Refresh = function(self, ...)
          refresh(self, ...)
          UI.LayoutToolbars(self)
        end
      end
      local prev = f:GetScript("OnSizeChanged")
      f:SetScript("OnSizeChanged", function(...)
        if prev then prev(...) end
        UI.LayoutToolbars(f)
      end)
    end
  end

  -- resize grip (bottom-right)
  local grip = CreateFrame("Button", nil, main)
  grip:SetSize(14, 14)
  grip:SetPoint("BOTTOMRIGHT", -3, 3)
  local gt = grip:CreateTexture(nil, "OVERLAY")
  gt:SetAllPoints()
  gt:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  gt:SetVertexColor(1, 1, 1, 0.35)
  grip:SetScript("OnEnter", function() local r, g, b = T.Accent(); gt:SetVertexColor(r, g, b, 1) end)
  grip:SetScript("OnLeave", function() gt:SetVertexColor(1, 1, 1, 0.35) end)
  grip:SetScript("OnMouseDown", function() main:StartSizing("BOTTOMRIGHT") end)
  grip:SetScript("OnMouseUp", function() main:StopMovingOrSizing(); SaveGeometry() end)

  UI.ApplyOpacity()
  main:SetScript("OnShow", function()
    ns.RequestRoster()
    UI.RefreshChrome()
    if current then ShowPanel(current) end
  end)
end

-- Window opacity (0.5 to 1). Pop-up dialogs inside FableHub stay solid.
UI.DEFAULT_OPACITY = 0.85
function UI.Opacity()
  local o = FableHubDB and FableHubDB.settings.opacity
  return math.max(0.5, math.min(1, tonumber(o) or UI.DEFAULT_OPACITY))
end
function UI.ApplyOpacity()
  if not main then return end
  local a = UI.Opacity()
  main.bgTex:SetColorTexture(T.bg[1], T.bg[2], T.bg[3], a)
  -- the sidebar stays a touch darker than the content area
  main.sideTex:SetColorTexture(T.sidebar[1], T.sidebar[2], T.sidebar[3], math.min(1, a * 0.85 + 0.1))
end

-- Toolbars that reflow like a web page: controls sit left to right and wrap
-- onto another row when the page is too narrow; search boxes stretch and shrink.
--   bar:Add(frame, o)  o.gap (space before it, default 8), o.right (pushed to the
--                      right of its row), o.grow (o.min..o.max wide, takes spare
--                      room), o.fill (a whole row, e.g. an info line; o.wrap lets
--                      it wrap onto more lines), o.newRow,
--                      o.w (fixed width), o.visible (function; default IsShown)
--   bar:Status(fs)     right-aligned count on row 1; moves to the hint line when
--                      row 1 has no room for it
--   bar:Below(frame,o) keeps frame's top under the toolbar: o.x (number or
--                      function; default the toolbar's left), o.gap (default 12),
--                      o.point (default TOPLEFT)
-- opts: left (number or function), right, top, before(width) (called first, for
-- pages that resize their own columns), owner (frame whose Refresh/size changes
-- lay it out; default the parent).
local function MeasureWidth(o)
  local f = o.f
  if o.w then return o.w end
  if f.label and f.label.GetStringWidth then           -- T.Toggle
    return 39 + math.max(40, f.label:GetStringWidth() or 0)
  end
  if f.GetObjectType and f:GetObjectType() == "FontString" then
    return (f:GetStringWidth() or 0) + 2
  end
  return f:GetWidth() or 0
end

function UI.Toolbar(parent, opts)
  opts = opts or {}
  local owner = opts.owner or parent
  local bar = { parent = parent, items = {}, below = {}, h = 22, rowH = opts.rowH or 22, rowGap = opts.rowGap or 6,
                rows = 1, top = opts.top or 0, right = opts.right or 0 }
  owner._toolbars = owner._toolbars or {}
  table.insert(owner._toolbars, bar)
  if owner ~= parent and parent.HookScript then
    parent:HookScript("OnSizeChanged", function() bar:Layout() end)
  end

  function bar:Add(f, o) o = o or {}; o.f = f; self.items[#self.items + 1] = o; return f end
  function bar:Status(fs) self.status = fs; fs:ClearAllPoints(); fs:SetWordWrap(false); return fs end
  function bar:Below(f, o) o = o or {}; o.f = f; self.below[#self.below + 1] = o; return f end
  function bar:Left()
    local l = opts.left
    if type(l) == "function" then l = l() end
    return l or 0
  end
  function bar:Width() return (parent:GetWidth() or 0) - self:Left() - self.right end

  function bar:Layout()
    if opts.before then opts.before(parent:GetWidth() or 0) end
    local left = self:Left()
    local W = self:Width()
    if W <= 20 then return end -- not sized yet
    local rows, row = {}, nil
    local function NewRow() row = { items = {}, used = 0 }; rows[#rows + 1] = row end
    NewRow()
    for _, o in ipairs(self.items) do
      local vis
      if o.visible then vis = o.visible() else vis = o.f:IsShown() end
      if vis then
        local w
        if o.fill then w = W
        elseif o.grow then w = math.min(o.min or 120, W)
        else w = math.min(MeasureWidth(o), W) end
        local gap = (#row.items > 0) and (o.gap or 8) or 0
        if #row.items > 0 and (o.fill or o.newRow or row.full or row.used + gap + w > W) then
          NewRow(); gap = 0
        end
        o._w, o._gap = w, gap
        row.items[#row.items + 1] = o
        row.used = row.used + gap + w
        row.full = o.fill
      end
    end

    -- the count on the right of row 1, if there's room for it
    local reserve = 0
    self.overflow = nil
    local st = self.status
    if st then
      local text = st:GetText() or ""
      local need = (st:GetStringWidth() or 0) + 16
      if text == "" then
        st:Hide()
      elseif rows[1].full or W - rows[1].used < need then
        st:Hide()
        self.overflow = text
      else
        reserve = need
        st:Show()
        st:ClearAllPoints()
        st:SetPoint("RIGHT", parent, "TOPRIGHT", -self.right - 2, self.top - self.rowH / 2)
      end
    end

    local rowTop = self.top
    for ri, r in ipairs(rows) do
      local avail = W - (ri == 1 and reserve or 0)
      local spare = avail - r.used
      for _, o in ipairs(r.items) do
        if o.grow and spare > 0 then
          local add = math.min(spare, (o.max or 100000) - o._w)
          if add > 0 then o._w = o._w + add; spare = spare - add end
        end
      end
      -- a wrapping info line (o.wrap) can make its row taller
      r.h = self.rowH
      for _, o in ipairs(r.items) do
        if o.wrap then
          o.f:SetWidth(o._w)
          r.h = math.max(r.h, math.ceil((o.f:GetStringHeight() or 0) + 4))
        end
      end
      local y = rowTop - r.h / 2
      rowTop = rowTop - r.h - self.rowGap
      local x, pushed = left, false
      for i, o in ipairs(r.items) do
        if o.right and not pushed then
          pushed = true
          local rest = 0
          for j = i, #r.items do rest = rest + r.items[j]._w + (j > i and r.items[j]._gap or 0) end
          x = math.max(x + o._gap, left + avail - rest)
        else
          x = x + o._gap
        end
        o.f:ClearAllPoints()
        o.f:SetPoint("LEFT", parent, "TOPLEFT", x, y)
        o._x, o._row = x, ri
        if o.grow or o.fill then o.f:SetWidth(o._w) end
        x = x + o._w
      end
    end

    local oldH = self.h
    self.rows = #rows
    self.h = self.top - rowTop - self.rowGap
    for _, b in ipairs(self.below) do
      local x = b.x
      if type(x) == "function" then x = x() end
      local point = b.point or "TOPLEFT"
      b.f:SetPoint(point, parent, point, x or left, self.top - self.h - (b.gap or 12))
    end
    if opts.onHeight and oldH ~= self.h then opts.onHeight(self.h) end
    if st then UI.PaintHint() end
  end
  return bar
end

-- two-column pages (pop-up forms inside a page): the left column narrows
-- (o.minL..o.maxL) so the right column (o.rightW wide) still fits.
--   o.left     frames sized to the left column's width
--   o.right    { {frame, y}, ... } placed at the right column's x
--   o.rightFit { {frame, maxWidth}, ... } sized to the room left on the right
function UI.TwoColumns(frame, o)
  local gap = o.gap or 20
  local function Fit()
    local w = frame:GetWidth() or 0
    if w <= 0 then return end
    local leftW = math.max(o.minL or 200, math.min(o.maxL, w - gap - o.rightW))
    local rx = leftW + gap
    for _, f in ipairs(o.left or {}) do f:SetWidth(leftW) end
    for _, r in ipairs(o.right or {}) do r[1]:SetPoint("TOPLEFT", frame, "TOPLEFT", rx, r[2]) end
    for _, r in ipairs(o.rightFit or {}) do r[1]:SetWidth(math.max(80, math.min(r[2], w - rx))) end
  end
  frame:HookScript("OnSizeChanged", Fit)
  frame:HookScript("OnShow", Fit)
  Fit()
  return Fit
end

function UI.LayoutToolbars(f)
  for _, bar in ipairs(f._toolbars or {}) do
    local ok, err = pcall(bar.Layout, bar)
    if not ok then ns.ReportError("toolbar: " .. tostring(err)) end
  end
end

-- the hint line at the bottom; a toolbar count that didn't fit goes in front
local hintBase
function UI.SetHint(text)
  hintBase = text
  UI.PaintHint()
end
function UI.PaintHint()
  if not main then return end
  local extra
  local p = current and panels[current]
  for _, bar in ipairs(p and p.frame and p.frame._toolbars or {}) do
    if bar.overflow then extra = bar.overflow end
  end
  main.hint:SetText(extra and (extra .. "   ·   " .. (hintBase or "")) or (hintBase or ""))
end

function UI.RefreshChrome()
  if not main or not main:IsShown() then return end
  main.logo:SetText(("|c%sFable|rHub"):format(T.AccentHex()))
  local guildName = IsInGuild() and GetGuildInfo("player")
  main.guildText:SetText(guildName and ("<" .. guildName .. ">") or "No guild")

  local g = ns.GuildDB()
  local users, online = 1, 1
  local haveRoster = next(ns.roster) ~= nil
  if g then
    for k in pairs(g.addonUsers) do
      if k ~= ns.MyKey() and (not haveRoster or ns.roster[k]) then users = users + 1 end
    end
  end
  for key in pairs(ns.present) do if ns.IsOnline(key) then online = online + 1 end end
  local members, membersOnline = 0, 0
  for _, r in pairs(ns.roster) do
    members = members + 1
    if r.online then membersOnline = membersOnline + 1 end
  end
  main.sideStatus:SetText(("%s %d of %d online\n%s %d use FableHub (%d online)\n%s"):format(
    ns.Icons.Dot(true, 7), membersOnline, members,
    ns.Icons.Dot(false, 7), users, online,
    ns.updateAvailable and UI.Colorize(("v%s  ·  update: %s"):format(ns.VERSION, ns.updateAvailable), T.Accent())
      or UI.Dim("v" .. ns.VERSION, 0.3)))
end

local refreshPending = false
local function QueueRefresh()
  if not main or not main:IsShown() or refreshPending then return end
  refreshPending = true
  C_Timer.After(0.3, function()
    refreshPending = false
    if not main:IsShown() then return end
    UI.RefreshChrome()
    SafeRefresh(panels[current])
  end)
end
UI.QueueRefresh = QueueRefresh
ns.On("DATA_CHANGED", QueueRefresh)
ns.On("ROSTER_CHANGED", QueueRefresh)
ns.On("UPDATE_AVAILABLE", QueueRefresh)

function ns.ToggleUI()
  if not main then Build() end
  if main:IsShown() then main:Hide() return end
  if not IsInGuild() then ns.Print("You're not in a guild yet, so there's nothing to show.") end
  if not UI.openedThisSession and panels.home and ns.Option("homeFirst") then
    current = "home"
  else
    current = current or (FableHubDB.settings.lastTab and panels[FableHubDB.settings.lastTab] and FableHubDB.settings.lastTab)
      or panelOrder[1]
  end
  UI.openedThisSession = true
  main:Show()
end

function ns.ResetWindow()
  FableHubDB.settings.window = nil
  if main then
    main:ClearAllPoints()
    main:SetPoint("CENTER")
    main:SetSize(900, 540)
  end
end

------------------------------------------------------------------------
-- Member picker: a pop-up at the mouse that lists guild members, filtered as
-- you type. Click a name, or press Enter for the top one.
--   UI.PickMember(title, onPick(key), opts) ; opts.exclude = { [key] = true }
------------------------------------------------------------------------
local picker
local PICK_ROWS = 10

-- guild members matching text: names starting with it first, then containing it
function UI.MemberMatches(text, exclude)
  text = (text or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  local starts, contains = {}, {}
  for _, key in ipairs(ns.rosterOrder) do
    if not (exclude and exclude[key]) then
      local short = ns.ShortName(key):lower()
      if text == "" or short:sub(1, #text) == text then starts[#starts + 1] = key
      elseif short:find(text, 1, true) then contains[#contains + 1] = key end
    end
  end
  local function byName(a, b)
    local ra, rb = ns.roster[a], ns.roster[b]
    local oa, ob = ra and ra.online and 1 or 0, rb and rb.online and 1 or 0
    if text == "" and oa ~= ob then return oa > ob end -- nothing typed: online first
    return ns.ShortName(a):lower() < ns.ShortName(b):lower()
  end
  table.sort(starts, byName)
  table.sort(contains, byName)
  for _, k in ipairs(contains) do starts[#starts + 1] = k end
  return starts
end

function UI.PickMember(title, onPick, opts)
  opts = opts or {}
  if not picker then
    picker = T.Popup(240, 76 + PICK_ROWS * 20)
    picker.title = T.Text(picker, 12, 0.85)
    picker.title:SetPoint("TOPLEFT", 10, -10)
    picker.title:SetPoint("RIGHT", -10, 0)
    picker.title:SetJustifyH("LEFT")
    picker.box = T.Input(picker, 220, "Type to search the guild")
    picker.box:SetPoint("TOPLEFT", 10, -28)
    picker.rows = {}
    for i = 1, PICK_ROWS do
      local b = CreateFrame("Button", nil, picker)
      b:SetHeight(20)
      b:SetPoint("TOPLEFT", 10, -54 - (i - 1) * 20)
      b:SetPoint("RIGHT", -10, 0)
      local hl = b:CreateTexture(nil, "HIGHLIGHT")
      hl:SetAllPoints()
      hl:SetColorTexture(1, 1, 1, 0.07)
      b.sel = b:CreateTexture(nil, "BACKGROUND")
      b.sel:SetAllPoints()
      b.sel:SetColorTexture(1, 1, 1, 0.05)
      b.text = T.Text(b, 12, 0.9)
      b.text:SetPoint("LEFT", 4, 0)
      b.text:SetPoint("RIGHT", -4, 0)
      b.text:SetJustifyH("LEFT")
      b.text:SetWordWrap(false)
      b:SetScript("OnClick", function(self) if self.key then picker:Choose(self.key) end end)
      picker.rows[i] = b
    end
    picker.more = T.Text(picker, 11, 0.4)
    picker.more:SetPoint("BOTTOMLEFT", 12, 6)
    picker.offset = 0
    picker:EnableMouseWheel(true)
    picker:SetScript("OnMouseWheel", function(self, delta)
      self.offset = math.max(0, math.min(math.max(0, #self.matches - PICK_ROWS), self.offset - delta * 3))
      self:Draw()
    end)
    function picker:Draw()
      for i, b in ipairs(self.rows) do
        local key = self.matches[i + self.offset]
        b.key = key
        if key then
          local r = ns.roster[key]
          local rec = ns.GuildDB() and ns.GuildDB().members[key]
          local classFile = (rec and rec.class) or (r and r.class)
          b.text:SetText(UI.NameCell(key, classFile, r and r.online) ..
            UI.Dim("  " .. ((r and r.level) and ("lvl " .. r.level) or ""), 0.4))
          b.sel:SetShown(i + self.offset == 1)
          b:Show()
        else
          b:Hide()
        end
      end
      local n = #self.matches
      if n == 0 then self.more:SetText("Nobody in the guild matches")
      elseif n > PICK_ROWS then self.more:SetText(("%d-%d of %d  ·  scroll for more"):format(self.offset + 1,
        math.min(n, self.offset + PICK_ROWS), n))
      else self.more:SetText("") end
    end
    function picker:Update()
      self.matches = UI.MemberMatches(self.box:GetText(), self.exclude)
      self.offset = 0
      self:Draw()
    end
    function picker:Choose(key)
      self.box:ClearFocus()
      self:Close()
      if self.onPick then self.onPick(key) end
    end
    picker.box:HookScript("OnTextChanged", function() picker:Update() end)
    picker.box:SetScript("OnEnterPressed", function() if picker.matches[1] then picker:Choose(picker.matches[1]) end end)
    picker.box:SetScript("OnEscapePressed", function(self) self:ClearFocus(); picker:Close() end)
  end
  picker.onPick, picker.exclude = onPick, opts.exclude
  picker.title:SetText(title or "Choose a guild member")
  picker.box:SetText(opts.text or "")
  picker:Update()
  picker:Open()
  picker.box:SetFocus()
  return picker
end
