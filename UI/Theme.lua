-- Theme: colours, fonts and the small set of skinned widgets FableHub uses.
-- Look: very dark warm panels, hairline borders, dimmed white text, one accent.
-- If EllesmereUI is installed, its accent colour is used so the two match.

local _, ns = ...
local T = {}
ns.Theme = T

T.FONT = "Interface\\AddOns\\FableHub\\Media\\Fonts\\Questrial-Regular.ttf"
-- Questrial draws its letters smaller than most fonts at the same size, so
-- FableHub asks for it about 10% bigger (font sizes in the code stay as they are)
T.FONT_SCALE = 1.1
T.FALLBACK_FONT = "Fonts\\ARIALN.TTF"

T.bg       = { 0.069, 0.058, 0.047, 0.97 }  -- main panel
T.sidebar  = { 0.045, 0.038, 0.031, 1 }     -- left nav strip
T.input    = { 0.030, 0.023, 0.018, 0.6 }   -- search boxes, toggle tracks
T.button   = { 0.089, 0.080, 0.072, 0.6 }
T.border   = 0.06                            -- white alpha for hairlines
T.text     = 0.92                            -- white alpha, primary text
T.dim      = 0.53                            -- white alpha, secondary text
T.section  = 0.41                            -- white alpha, column headers
T.defaultAccent = { 220 / 255, 167 / 255, 127 / 255 } -- soft bronze

function T.Accent()
  local s = FableHubDB and FableHubDB.settings
  if s and s.accent then return s.accent[1], s.accent[2], s.accent[3] end
  local eui = _G.EllesmereUI
  local c = eui and eui.ELLESMERE_GREEN
  if type(c) == "table" and c.r then return c.r, c.g, c.b end
  local a = T.defaultAccent
  return a[1], a[2], a[3]
end

function T.AccentHex()
  local r, g, b = T.Accent()
  return ("ff%02x%02x%02x"):format(r * 255, g * 255, b * 255)
end

------------------------------------------------------------------------
-- Primitives
------------------------------------------------------------------------
function T.Fill(frame, c, layer, sub)
  local t = frame:CreateTexture(nil, layer or "BACKGROUND", nil, sub)
  t:SetAllPoints()
  t:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
  return t
end

local function Pixel(t)
  if t.SetSnapToPixelGrid then t:SetSnapToPixelGrid(false); t:SetTexelSnappingBias(0) end
end

-- 1px border made of four textures (crisp at any UI scale)
function T.Border(frame, alpha, layer)
  local edges = {}
  local a = alpha or T.border
  local function Edge(p1, p2, horizontal)
    local t = frame:CreateTexture(nil, layer or "BORDER")
    t:SetColorTexture(1, 1, 1, a)
    t:SetPoint(p1)
    t:SetPoint(p2)
    if horizontal then
      if PixelUtil and PixelUtil.SetHeight then PixelUtil.SetHeight(t, 1) else t:SetHeight(1) end
    else
      if PixelUtil and PixelUtil.SetWidth then PixelUtil.SetWidth(t, 1) else t:SetWidth(1) end
    end
    Pixel(t)
    edges[#edges + 1] = t
  end
  Edge("TOPLEFT", "TOPRIGHT", true)
  Edge("BOTTOMLEFT", "BOTTOMRIGHT", true)
  Edge("TOPLEFT", "BOTTOMLEFT", false)
  Edge("TOPRIGHT", "BOTTOMRIGHT", false)
  function frame:SetBorderAlpha(na) for _, e in ipairs(edges) do e:SetColorTexture(1, 1, 1, na) end end
  function frame:SetBorderColor(r, g, b, na) for _, e in ipairs(edges) do e:SetColorTexture(r, g, b, na or 1) end end
  return edges
end

-- Set our font, falling back to a built-in one if the file can't be loaded
function T.SetFont(obj, size, flags)
  size = size or 12
  if not obj:SetFont(T.FONT, math.floor(size * T.FONT_SCALE + 0.5), flags or "") then
    obj:SetFont(T.FALLBACK_FONT, size, flags or "")
  end
end

function T.Font(fs, size, alpha, flags)
  T.SetFont(fs, size, flags)
  fs:SetShadowColor(0, 0, 0, 0.8)
  fs:SetShadowOffset(1, -1)
  fs:SetTextColor(1, 1, 1, alpha or T.text)
  return fs
end

function T.Text(parent, size, alpha, layer)
  return T.Font(parent:CreateFontString(nil, layer or "OVERLAY"), size, alpha)
end

------------------------------------------------------------------------
-- Widgets
------------------------------------------------------------------------
function T.Button(parent, text, width, height)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(width or 90, height or 22)
  local bg = T.Fill(b, T.button)
  T.Border(b, 0.3)
  local fs = T.Text(b, 12, 0.55)
  fs:SetPoint("CENTER")
  b:SetFontString(fs)
  b:SetText(text)
  b.selected = false
  local function Paint(hover)
    if b.selected then
      local r, g, bl = T.Accent()
      fs:SetTextColor(r, g, bl, 1)
      b:SetBorderColor(r, g, bl, 0.6)
    else
      fs:SetTextColor(1, 1, 1, hover and 0.7 or 0.55)
      b:SetBorderAlpha(hover and 0.45 or 0.3)
    end
    bg:SetColorTexture(T.button[1], T.button[2], T.button[3], hover and 0.65 or 0.6)
  end
  b:SetScript("OnEnter", function() Paint(true) end)
  b:SetScript("OnLeave", function() Paint(false) end)
  function b:SetSelected(v) b.selected = v and true or false; Paint(false) end
  Paint(false)
  return b
end

function T.SearchBox(parent, width, placeholder, onChange)
  local box = CreateFrame("EditBox", nil, parent)
  box:SetSize(width or 180, 22)
  box:SetAutoFocus(false)
  T.SetFont(box, 12)
  box:SetTextColor(1, 1, 1, T.text)
  box:SetTextInsets(22, 6, 0, 0)
  T.Fill(box, T.input)
  T.Border(box, 0.08)
  local icon = box:CreateTexture(nil, "OVERLAY")
  icon:SetTexture("Interface\\Common\\UI-Searchbox-Icon")
  icon:SetSize(13, 13)
  icon:SetPoint("LEFT", 6, -1)
  icon:SetVertexColor(1, 1, 1, 0.45)
  local hint = T.Text(box, 12, 0.3)
  hint:SetPoint("LEFT", 22, 0)
  hint:SetPoint("RIGHT", -6, 0)  -- cut off rather than spill when the box shrinks
  hint:SetJustifyH("LEFT")
  hint:SetWordWrap(false)
  hint:SetText(placeholder or "Search")
  local function Update()
    hint:SetShown((box:GetText() or "") == "" and not box:HasFocus())
  end
  box:SetScript("OnTextChanged", function(self)
    Update()
    onChange((self:GetText() or ""):lower())
  end)
  box:SetScript("OnEditFocusGained", function(self) self:SetBorderAlpha(0.2); Update() end)
  box:SetScript("OnEditFocusLost", function(self) self:SetBorderAlpha(0.08); Update() end)
  box:SetScript("OnEscapePressed", function(self)
    if (self:GetText() or "") ~= "" then self:SetText("") else self:ClearFocus() end
  end)
  box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  return box
end

-- Toggle switch with a label: track + sliding knob, accent when on
function T.Toggle(parent, label, onChange)
  local b = CreateFrame("Button", nil, parent)
  b:SetHeight(20)
  local track = CreateFrame("Frame", nil, b)
  track:SetSize(28, 14)
  track:SetPoint("LEFT")
  local fill = T.Fill(track, { 0.267, 0.267, 0.267, 0.65 })
  local knob = track:CreateTexture(nil, "ARTWORK")
  knob:SetSize(10, 10)
  local fs = T.Text(b, 12, T.dim)
  fs:SetPoint("LEFT", track, "RIGHT", 7, 0)
  fs:SetText(label)
  b:SetWidth(28 + 7 + math.max(40, (fs:GetStringWidth() or 60)) + 4)
  b.label = fs
  b.checked = false
  local function Paint(hover)
    knob:ClearAllPoints()
    if b.checked then
      local r, g, bl = T.Accent()
      fill:SetColorTexture(r, g, bl, 0.75)
      knob:SetPoint("RIGHT", -2, 0)
      knob:SetColorTexture(1, 1, 1, 1)
    else
      fill:SetColorTexture(0.267, 0.267, 0.267, 0.65)
      knob:SetPoint("LEFT", 2, 0)
      knob:SetColorTexture(1, 1, 1, 0.5)
    end
    fs:SetTextColor(1, 1, 1, (hover or b.checked) and 0.8 or T.dim)
  end
  b:SetScript("OnClick", function()
    b.checked = not b.checked
    Paint(true)
    onChange(b.checked)
  end)
  b:SetScript("OnEnter", function() Paint(true) end)
  b:SetScript("OnLeave", function() Paint(false) end)
  function b:SetChecked(v) b.checked = v and true or false; Paint(false) end
  Paint(false)
  return b
end

-- Flat "X" close button
function T.CloseButton(parent, onClick)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(20, 20)
  local lines = {}
  for i, deg in ipairs({ 45, -45 }) do
    local t = b:CreateTexture(nil, "ARTWORK")
    t:SetColorTexture(1, 1, 1, 0.5)
    t:SetSize(12, 1.5)
    t:SetPoint("CENTER")
    if t.SetRotation then t:SetRotation(math.rad(deg)) end
    lines[i] = t
  end
  b:SetScript("OnEnter", function()
    local r, g, bl = T.Accent()
    for _, t in ipairs(lines) do t:SetColorTexture(r, g, bl, 1) end
  end)
  b:SetScript("OnLeave", function()
    for _, t in ipairs(lines) do t:SetColorTexture(1, 1, 1, 0.5) end
  end)
  b:SetScript("OnClick", onClick)
  return b
end

-- Sidebar navigation entry: accent bar on the left when selected.
-- opts.indent = sub-item under a group; opts.caret = group header with open/closed arrow.
function T.NavButton(parent, text, icon, opts)
  opts = opts or {}
  local b = CreateFrame("Button", nil, parent)
  b:SetHeight(opts.indent and 26 or 30)
  local hl = T.Fill(b, { 1, 1, 1, 0 }, "ARTWORK")
  local bar = b:CreateTexture(nil, "OVERLAY")
  bar:SetPoint("TOPLEFT")
  bar:SetPoint("BOTTOMLEFT")
  bar:SetWidth(2)
  local ic
  if icon then
    ic = b:CreateTexture(nil, "OVERLAY")
    ic:SetTexture(icon)
    ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    ic:SetSize(16, 16)
    ic:SetPoint("LEFT", 14, 0)
  end
  local fs = T.Text(b, opts.indent and 12 or 13, T.dim)
  fs:SetPoint("LEFT", opts.indent == 2 and 52 or ((icon or opts.indent) and 38 or 14), 0)
  fs:SetText(text)
  local caret
  if opts.caret then
    caret = T.Text(b, 11, 0.4)
    caret:SetPoint("RIGHT", -14, 0)
  end
  b.selected, b.active, b.open = false, false, true
  local function Paint(hover)
    if caret then caret:SetText(b.open and "-" or "+") end
    if b.selected then
      local r, g, bl = T.Accent()
      bar:SetColorTexture(r, g, bl, 1)
      hl:SetColorTexture(r, g, bl, 0.08)
      fs:SetTextColor(1, 1, 1, 1)
      if ic then ic:SetDesaturated(false); ic:SetAlpha(1) end
    else
      bar:SetColorTexture(0, 0, 0, 0)
      hl:SetColorTexture(1, 1, 1, hover and 0.04 or 0)
      fs:SetTextColor(1, 1, 1, (hover or b.active) and 0.85 or T.dim)
      if ic then ic:SetDesaturated(not b.active); ic:SetAlpha((hover or b.active) and 1 or 0.6) end
    end
  end
  b:SetScript("OnEnter", function() Paint(true) end)
  b:SetScript("OnLeave", function() Paint(false) end)
  function b:SetSelected(v) b.selected = v and true or false; Paint(false) end
  -- a group header whose child is showing: brighter, but no accent bar
  function b:SetActive(v) b.active = v and true or false; Paint(false) end
  function b:SetOpen(v) b.open = v and true or false; Paint(false) end
  Paint(false)
  return b
end

-- Plain text input
function T.Input(parent, width, placeholder)
  local box = CreateFrame("EditBox", nil, parent)
  box:SetSize(width or 140, 22)
  box:SetAutoFocus(false)
  T.SetFont(box, 12)
  box:SetTextColor(1, 1, 1, T.text)
  box:SetTextInsets(7, 7, 0, 0)
  T.Fill(box, T.input)
  T.Border(box, 0.08)
  local hint = T.Text(box, 12, 0.3)
  hint:SetPoint("LEFT", 7, 0)
  hint:SetPoint("RIGHT", -6, 0)
  hint:SetJustifyH("LEFT")
  hint:SetWordWrap(false)
  hint:SetText(placeholder or "")
  local function Update() hint:SetShown((box:GetText() or "") == "" and not box:HasFocus()) end
  box:HookScript("OnTextChanged", Update)
  box:HookScript("OnEditFocusGained", function(self) self:SetBorderAlpha(0.2); Update() end)
  box:HookScript("OnEditFocusLost", function(self) self:SetBorderAlpha(0.08); Update() end)
  box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  return box
end

-- Dropdown-style popup menu: items = { { text, onClick, checked } }
local menu, catcher
function T.Menu(anchor, items, width)
  if not menu then
    catcher = CreateFrame("Button", nil, UIParent)
    catcher:SetAllPoints(UIParent)
    catcher:SetFrameStrata("FULLSCREEN")
    catcher:RegisterForClicks("AnyUp")
    catcher:SetScript("OnClick", function() menu:Hide(); catcher:Hide() end)
    catcher:Hide()
    menu = CreateFrame("Frame", nil, UIParent)
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    T.Fill(menu, { 0.055, 0.047, 0.038, 0.98 })
    T.Border(menu, 0.12)
    menu.buttons = {}
    menu:Hide()
  end
  for _, b in ipairs(menu.buttons) do b:Hide() end
  width = width or 180
  local y = -4
  for i, item in ipairs(items) do
    local b = menu.buttons[i]
    if not b then
      b = CreateFrame("Button", nil, menu)
      b:SetHeight(22)
      local hl = b:CreateTexture(nil, "HIGHLIGHT")
      hl:SetAllPoints()
      hl:SetColorTexture(1, 1, 1, 0.06)
      b.text = T.Text(b, 12, 0.85)
      b.text:SetPoint("LEFT", 10, 0)
      b.text:SetPoint("RIGHT", -10, 0)
      b.text:SetJustifyH("LEFT")
      b.text:SetWordWrap(false)
      menu.buttons[i] = b
    end
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", 1, y)
    b:SetPoint("TOPRIGHT", -1, y)
    local text = item.text
    if item.checked then
      local r, g, bl = T.Accent()
      text = ("|cff%02x%02x%02x%s|r"):format(r * 255, g * 255, bl * 255, text)
    end
    b.text:SetText(text)
    b:SetScript("OnClick", function() menu:Hide(); catcher:Hide(); if item.onClick then item.onClick() end end)
    b:Show()
    y = y - 22
  end
  menu:SetSize(width, -y + 4)
  menu:ClearAllPoints()
  -- open where the mouse is; fall back to under the anchor
  local x, cy = GetCursorPosition()
  local scale = UIParent:GetEffectiveScale() or 1
  if x and cy and scale > 0 then
    menu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / scale + 2, cy / scale - 2)
  else
    menu:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
  end
  menu:SetClampedToScreen(true)
  catcher:Show()
  menu:Show()
end

-- Filter dropdown under a button: ticks stay open while you pick several.
-- Closes on a click elsewhere or Escape.
--   spec.title, spec.width
--   spec.options()  -> { { value, text, count, checked }, false (= divider), ... }
--                      options with no count that aren't ticked are left out
--   spec.onToggle(value), spec.onClear()
--   spec.mode = { labels = { "All", "Any" }, get() -> index, set(index) }  (optional switch in the header)
--   spec.onClose()
local cm, cmCatcher
function T.CloseCheckMenu()
  if cm and cm:IsShown() then cm:Hide() end
end

local function CheckRow(i)
  local row = cm.rows[i]
  if row then return row end
  row = CreateFrame("Button", nil, cm)
  row:SetHeight(22)
  local hl = row:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(1, 1, 1, 0.06)
  local box = CreateFrame("Frame", nil, row)
  box:SetSize(12, 12)
  box:SetPoint("LEFT", 10, 0)
  row.boxFill = T.Fill(box, { 1, 1, 1, 0 })
  T.Border(box, 0.3)
  row.box = box
  local tick = box:CreateTexture(nil, "OVERLAY")
  tick:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
  tick:SetSize(16, 16)
  tick:SetPoint("CENTER", 1, 0)
  tick:SetVertexColor(0.07, 0.06, 0.05)
  row.tick = tick
  row.label = T.Text(row, 12, 0.75)
  row.label:SetJustifyH("LEFT")
  row.label:SetWordWrap(false)
  row.count = T.Text(row, 11, 0.45)
  row.count:SetPoint("RIGHT", -10, 0)
  row:SetScript("OnClick", function(self) if self.onClick then self.onClick() end end)
  cm.rows[i] = row
  return row
end

local function CheckLine(i)
  local line = cm.lines[i]
  if line then return line end
  line = cm:CreateTexture(nil, "ARTWORK")
  line:SetColorTexture(1, 1, 1, 0.08)
  line:SetHeight(1)
  cm.lines[i] = line
  return line
end

-- run a menu callback, then repaint unless the callback already did (pages
-- that refresh themselves repaint an open menu as part of that): one paint per click
local function ThenPaint(fn, ...)
  local before = cm.paints
  fn(...)
  if cm.paints == before then T.PaintCheckMenu() end
end

function T.PaintCheckMenu()
  if not cm or not cm.spec then return end
  cm.paints = (cm.paints or 0) + 1
  local spec = cm.spec
  local W = spec.width or 220
  local r, g, b = T.Accent()
  local y = -6

  cm.title:ClearAllPoints()
  cm.title:SetPoint("TOPLEFT", 10, y - 4)
  cm.title:SetText((spec.title or ""):upper())
  if spec.mode then
    local sel = spec.mode.get()
    for i, btn in ipairs(cm.seg) do
      btn.text:SetText(spec.mode.labels[i])
      if i == sel then btn.bg:SetColorTexture(r, g, b, 0.18); btn.text:SetTextColor(r, g, b, 1)
      else btn.bg:SetColorTexture(1, 1, 1, 0); btn.text:SetTextColor(1, 1, 1, 0.5) end
      btn:SetScript("OnClick", function() ThenPaint(spec.mode.set, i) end)
    end
    cm.segHolder:ClearAllPoints()
    cm.segHolder:SetPoint("TOPRIGHT", -8, y - 1)
    cm.segHolder:Show()
  else
    cm.segHolder:Hide()
  end
  y = y - 24

  local ri, li, lastRow, any = 0, 0, false, false
  local function Divider()
    li = li + 1
    local line = CheckLine(li)
    line:ClearAllPoints()
    line:SetPoint("TOPLEFT", 1, y - 4)
    line:SetPoint("TOPRIGHT", -1, y - 4)
    line:Show()
    y = y - 9
  end
  local function Row(text, alpha)
    ri = ri + 1
    local row = CheckRow(ri)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", 1, y)
    row:SetPoint("TOPRIGHT", -1, y)
    row.label:SetText(text)
    row.label:SetTextColor(1, 1, 1, alpha)
    row:Show()
    y = y - 22
    return row
  end

  for _, o in ipairs(spec.options() or {}) do
    if o == false then
      if lastRow then Divider(); lastRow = false end
    elseif o.checked or (o.count or 0) > 0 then
      local row = Row(o.text, o.checked and 1 or ((o.count or 0) > 0 and 0.75 or 0.35))
      row.box:Show()
      row.label:ClearAllPoints()
      row.label:SetPoint("LEFT", 30, 0)
      row.label:SetPoint("RIGHT", -40, 0)
      row.count:SetText(tostring(o.count or 0))
      row.count:Show()
      row.tick:SetShown(o.checked and true or false)
      if o.checked then row.boxFill:SetColorTexture(r, g, b, 1); row.box:SetBorderColor(r, g, b, 1)
      else row.boxFill:SetColorTexture(1, 1, 1, 0); row.box:SetBorderAlpha(0.3) end
      local value = o.value
      row.onClick = function() ThenPaint(spec.onToggle, value) end
      lastRow, any = true, true
    end
  end
  if not any then
    local row = Row("Nothing in this view", 0.35)
    row.box:Hide(); row.count:Hide()
    row.label:ClearAllPoints(); row.label:SetPoint("LEFT", 10, 0)
    row.onClick = nil
  end
  Divider()
  local clear = Row("Clear", 0.5)
  clear.box:Hide(); clear.count:Hide()
  clear.label:ClearAllPoints(); clear.label:SetPoint("LEFT", 10, 0)
  clear.onClick = function() ThenPaint(spec.onClear) end

  for i = ri + 1, #cm.rows do cm.rows[i]:Hide() end
  for i = li + 1, #cm.lines do cm.lines[i]:Hide() end
  cm:SetSize(W, -y + 4)
end

function T.CheckMenu(anchor, spec)
  if not cm then
    cmCatcher = CreateFrame("Button", nil, UIParent)
    cmCatcher:SetAllPoints(UIParent)
    cmCatcher:SetFrameStrata("FULLSCREEN")
    cmCatcher:RegisterForClicks("AnyUp")
    cmCatcher:SetScript("OnClick", T.CloseCheckMenu)
    cmCatcher:Hide()
    cm = CreateFrame("Frame", nil, UIParent)
    cm:SetFrameStrata("FULLSCREEN_DIALOG")
    cm:SetClampedToScreen(true)
    cm:EnableMouse(true)
    T.Fill(cm, { 0.055, 0.047, 0.038, 0.98 })
    T.Border(cm, 0.14)
    cm.rows, cm.lines = {}, {}
    cm.title = T.Text(cm, 11, T.section)
    local holder = CreateFrame("Frame", nil, cm)
    holder:SetSize(64, 16)
    T.Border(holder, 0.18)
    cm.segHolder, cm.seg = holder, {}
    for i = 1, 2 do
      local btn = CreateFrame("Button", nil, holder)
      btn:SetSize(32, 16)
      btn:SetPoint("LEFT", (i - 1) * 32, 0)
      btn.bg = T.Fill(btn, { 1, 1, 1, 0 })
      btn.text = T.Text(btn, 11, 0.5)
      btn.text:SetPoint("CENTER")
      cm.seg[i] = btn
    end
    cm:Hide()
    cm:SetScript("OnHide", function(self)
      cmCatcher:Hide()
      local s = self.spec
      self.spec = nil
      if s and s.onClose then s.onClose() end
    end)
    -- Escape closes just this menu (not the FableHub window); other keys pass through
    cm:SetScript("OnKeyDown", function(self, key)
      local free = not (InCombatLockdown and InCombatLockdown())
      if key == "ESCAPE" then
        if free then pcall(self.SetPropagateKeyboardInput, self, false) end
        T.CloseCheckMenu()
      elseif free then
        pcall(self.SetPropagateKeyboardInput, self, true)
      end
    end)
  end
  if cm:IsShown() then cm:Hide() end
  cm.spec = spec
  cm:ClearAllPoints()
  cm:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -4)
  T.PaintCheckMenu()
  local free = not (InCombatLockdown and InCombatLockdown())
  cm:EnableKeyboard(free)
  if free then pcall(cm.SetPropagateKeyboardInput, cm, true) end
  cmCatcher:Show()
  cm:Show()
end

function T.CheckMenuOpen(spec)
  return cm and cm:IsShown() and (spec == nil or cm.spec == spec) or false
end

-- A small pop-up that opens at the mouse and closes when you click elsewhere.
local popupCatcher, openPopup
function T.Popup(width, height)
  local f = CreateFrame("Frame", nil, UIParent)
  f:SetSize(width, height)
  f:SetFrameStrata("FULLSCREEN_DIALOG")
  f:SetClampedToScreen(true)
  f:EnableMouse(true)
  T.Fill(f, { 0.055, 0.047, 0.038, 0.98 })
  T.Border(f, 0.12)
  f:Hide()
  function f:Open()
    if not popupCatcher then
      popupCatcher = CreateFrame("Button", nil, UIParent)
      popupCatcher:SetAllPoints(UIParent)
      popupCatcher:SetFrameStrata("FULLSCREEN")
      popupCatcher:RegisterForClicks("AnyUp")
      popupCatcher:SetScript("OnClick", function() if openPopup then openPopup:Hide() end; popupCatcher:Hide() end)
    end
    if openPopup and openPopup ~= self then openPopup:Hide() end
    openPopup = self
    local x, y = GetCursorPosition()
    local s = UIParent:GetEffectiveScale() or 1
    self:ClearAllPoints()
    self:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", (x or 0) / s + 2, (y or 0) / s - 2)
    popupCatcher:Show()
    self:Show()
  end
  function f:Close()
    self:Hide()
    if popupCatcher then popupCatcher:Hide() end
    if openPopup == self then openPopup = nil end
  end
  return f
end
