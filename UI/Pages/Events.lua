-- Raid nights tab: upcoming and past raid nights, sign-ups, attendance.

local _, ns = ...
local UI, T, P, E = ns.UI, ns.Theme, ns.Plans, ns.Events

local STATUS_COLORS = {
  A = { 0.4, 0.85, 0.5 }, L = { 0.95, 0.78, 0.35 }, T = { 0.65, 0.7, 1 }, D = { 0.9, 0.4, 0.4 },
}
local function StatusTag(st, short)
  if not st or not E.STATUS[st] then return UI.Dim(short and "-" or "No reply", 0.35) end
  local c = STATUS_COLORS[st]
  return UI.Colorize(short and E.STATUS[st]:sub(1, 1) or E.STATUS[st], c[1], c[2], c[3])
end
local function RoleTag(role)
  if not role then return "" end
  return UI.Dim(ns.ROLE_NAMES[role] or role, 0.7)
end

local WEEKDAYS = { { 2, "Mon" }, { 3, "Tue" }, { 4, "Wed" }, { 5, "Thu" }, { 6, "Fri" }, { 7, "Sat" }, { 1, "Sun" } }

local function Label(parent, text)
  local fs = T.Text(parent, 11, T.section)
  fs:SetText(text:upper())
  return fs
end

------------------------------------------------------------------------
ns.RegisterPanel("events", "Raid nights", nil, function(panel)
  local selectedOcc
  local showPast, showNoReply = false, true

  -- top bar
  local newBtn = T.Button(panel, "New raid night", 120, 22)
  newBtn:SetPoint("TOPLEFT", 0, 0)
  local rhBtn = T.Button(panel, "Import Raid-Helper", 140, 22)
  rhBtn:SetPoint("LEFT", newBtn, "RIGHT", 6, 0)
  rhBtn:SetScript("OnClick", function() if ns.RaidHelperUI then ns.RaidHelperUI.Open(panel) end end)
  local pastToggle = T.Toggle(panel, "Show past nights", function(v) showPast = v; selectedOcc = nil; panel:Refresh() end)
  pastToggle:SetPoint("LEFT", rhBtn, "RIGHT", 14, 0)
  local info = T.Text(panel, 11, 0.4)

  -- left: occurrence list
  local list = UI.CreateList(panel, {
    { title = "When", width = 104 },
    { title = "Raid night", flex = true },
    { title = "You", width = 26, justify = "CENTER" },
  }, 24)
  list:SetPoint("TOPLEFT", 0, -34)
  list:SetPoint("BOTTOMLEFT", 0, 0)
  list:SetWidth(270)
  list.sortable = false

  local divider = panel:CreateTexture(nil, "ARTWORK")
  divider:SetColorTexture(1, 1, 1, T.border)
  divider:SetPoint("TOPLEFT", list, "TOPRIGHT", 10, 0)
  divider:SetPoint("BOTTOMLEFT", list, "BOTTOMRIGHT", 10, 0)
  divider:SetWidth(1)

  -- right: detail
  local detail = CreateFrame("Frame", nil, panel)
  detail:SetPoint("TOPLEFT", 292, -34)
  detail:SetPoint("BOTTOMRIGHT", 0, 0)

  local title = T.Text(detail, 17, 1)
  title:SetPoint("TOPLEFT", 0, 0)
  local sub = T.Text(detail, 12, 0.55)
  sub:SetPoint("TOPLEFT", 0, -24)

  local editBtn = T.Button(detail, "Edit", 56, 22)
  editBtn:SetPoint("TOPRIGHT", 0, 0)
  local skipBtn = T.Button(detail, "Cancel this one", 116, 22)
  skipBtn:SetPoint("RIGHT", editBtn, "LEFT", -4, 0)
  local deleteBtn = T.Button(detail, "Delete", 60, 22)
  deleteBtn:SetPoint("RIGHT", skipBtn, "LEFT", -4, 0)
  local copyBtn = T.Button(detail, "Copy", 56, 22)
  local planBtn = T.Button(detail, "Raid plan", 80, 22)
  title:SetJustifyH("LEFT")
  title:SetWordWrap(false)
  sub:SetPoint("RIGHT", detail, "RIGHT", 0, 0)
  sub:SetJustifyH("LEFT")
  sub:SetWordWrap(false)

  -- my sign-up
  local signRow = CreateFrame("Frame", nil, detail)
  signRow:SetPoint("TOPLEFT", 0, -52)
  signRow:SetPoint("TOPRIGHT", 0, -52)
  signRow:SetHeight(52)
  local statusBtns, order = {}, { "A", "L", "T", "D" }
  local myChar, myRole
  local noteBox = T.Input(signRow, 160, "Note to officers")
  for i, st in ipairs(order) do
    local b = T.Button(signRow, E.STATUS[st], 78, 22)
    if i == 1 then b:SetPoint("TOPLEFT", 0, 0) else b:SetPoint("LEFT", statusBtns[order[i - 1]], "RIGHT", 4, 0) end
    b:SetScript("OnClick", function()
      if selectedOcc then
        E.SignUp(selectedOcc, st, myChar, myRole, noteBox:GetText())
        noteBox:ClearFocus()
      end
    end)
    statusBtns[st] = b
  end
  local charBtn = T.Button(signRow, "Character", 150, 22)
  charBtn:SetPoint("TOPLEFT", 0, -28)
  local roleBtn = T.Button(signRow, "Role", 80, 22)
  roleBtn:SetPoint("LEFT", charBtn, "RIGHT", 4, 0)
  noteBox:SetPoint("LEFT", roleBtn, "RIGHT", 4, 0)
  noteBox:SetPoint("RIGHT", signRow, "RIGHT", 0, 0)
  -- narrow window: the sign-up buttons shrink to fit
  signRow:SetScript("OnSizeChanged", function(self)
    local w = self:GetWidth() or 0
    if w <= 0 then return end
    local bw = math.max(56, math.min(78, math.floor((w - 12) / 4)))
    for _, st in ipairs(order) do statusBtns[st]:SetWidth(bw) end
    charBtn:SetWidth(math.max(100, math.min(150, math.floor(w * 0.4))))
  end)
  local function Resubmit()
    if not selectedOcc then return end
    local mine = E.MySignup(selectedOcc)
    if mine then E.SignUp(selectedOcc, mine.status, myChar, myRole, noteBox:GetText()) end
  end
  noteBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); Resubmit() end)

  local function MyCharacters()
    local out = {}
    for key, rec in pairs(FableHubDB.chars) do
      if ns.roster[key] or key == ns.MyKey() then out[#out + 1] = { key = key, class = rec.class } end
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
  end
  charBtn:SetScript("OnClick", function()
    local items = {}
    for _, c in ipairs(MyCharacters()) do
      items[#items + 1] = { text = ns.Icons.Class(c.class, 14) .. " " .. ns.ShortName(c.key), checked = c.key == myChar,
        onClick = function() myChar = c.key; Resubmit(); panel:Refresh() end }
    end
    T.Menu(charBtn, items, 180)
  end)
  roleBtn:SetScript("OnClick", function()
    local items = {}
    for _, r in ipairs(ns.ROLES) do
      items[#items + 1] = { text = ns.ROLE_NAMES[r], checked = r == myRole,
        onClick = function() myRole = r; Resubmit(); panel:Refresh() end }
    end
    T.Menu(roleBtn, items, 120)
  end)

  local summary = T.Text(detail, 12, 0.75)
  summary:SetJustifyH("LEFT")
  local noReplyToggle = T.Toggle(detail, "Show no replies", function(v) showNoReply = v; panel:Refresh() end)
  noReplyToggle:SetChecked(true)

  -- top bar wraps when narrow; the raid night list narrows (270 -> 210)
  local listW = 270
  local bar = UI.Toolbar(panel, {
    before = function(w)
      if w <= 0 then return end
      listW = w < 640 and 210 or 270
      list:SetWidth(listW)
    end,
  })
  bar:Add(newBtn)
  bar:Add(rhBtn, { gap = 6 })
  bar:Add(pastToggle, { gap = 14 })
  bar:Status(info)
  bar:Below(list, { x = 0 })
  bar:Below(detail, { x = function() return listW + 22 end })

  -- the night's title gives way to the officer buttons, which wrap if needed
  local head = UI.Toolbar(detail, { owner = panel })
  head:Add(title, { grow = true, min = 100 })
  head:Add(planBtn, { right = true, gap = 8 })
  head:Add(copyBtn, { gap = 4 })
  head:Add(deleteBtn, { gap = 4 })
  head:Add(skipBtn, { gap = 4 })
  head:Add(editBtn, { gap = 4 })
  head:Below(sub, { x = 0, gap = 2 })
  head:Below(signRow, { x = 0, gap = 30 })
  head:Below(signRow, { point = "TOPRIGHT", x = 0, gap = 30 })

  local responses = UI.CreateList(detail, {
    { title = "Name", width = 150 },
    { title = "Role", width = 56 },
    { title = "Status", width = 70 },
    { title = "Note", flex = true },
    { title = "When", width = 60, justify = "RIGHT" },
  }, 22)
  local attendanceList = UI.CreateList(detail, {
    { title = "Name", width = 150 },
    { title = "Signed", width = 70 },
    { title = "Attended", width = 80 },
    { title = "Time in raid", width = 80, justify = "RIGHT", defaultAsc = false },
    { title = "Note", flex = true },
  }, 22)
  attendanceList.sortCol = 3
  responses.sortCol = 3

  local emptyText = T.Text(panel, 13, 0.4)
  emptyText:SetPoint("CENTER", detail, "CENTER", 0, 20)
  emptyText:SetJustifyH("CENTER")

  ----------------------------------------------------------------------
  -- Editor (officers)
  ----------------------------------------------------------------------
  local editor = CreateFrame("Frame", nil, panel)
  editor:SetPoint("TOPLEFT", detail, "TOPLEFT")
  editor:SetPoint("BOTTOMRIGHT", detail, "BOTTOMRIGHT")
  editor:SetFrameLevel(detail:GetFrameLevel() + 20)
  T.Fill(editor, T.bg)
  editor:EnableMouse(true)
  editor:Hide()
  local ed = {}

  local edTitle = T.Text(editor, 15, 1)
  edTitle:SetPoint("TOPLEFT", 0, 0)
  local l1 = Label(editor, "Name"); l1:SetPoint("TOPLEFT", 0, -34)
  local titleBox = T.Input(editor, 260, "Hyjal Summit, Tuesday")
  titleBox:SetPoint("TOPLEFT", 0, -50)
  local l2 = Label(editor, "Raid"); l2:SetPoint("TOPLEFT", 280, -34)
  local raidBox = T.Input(editor, 140, "Hyjal Summit")
  raidBox:SetPoint("TOPLEFT", 280, -50)
  local raidBtn = T.Button(editor, "v", 22, 22)
  raidBtn:SetPoint("LEFT", raidBox, "RIGHT", 2, 0)
  raidBtn:SetScript("OnClick", function()
    local items = {}
    for _, r in ipairs(E.RAIDS) do
      items[#items + 1] = { text = r, checked = ed.raid == r, onClick = function() ed.raid = r; raidBox:SetText(r) end }
    end
    T.Menu(raidBtn, items, 160)
  end)
  raidBox:HookScript("OnTextChanged", function(self) local t = (self:GetText() or ""):gsub("^%s+", ""); if t ~= "" then ed.raid = t end end)

  local edError = T.Text(editor, 11, 0.8)
  edError:SetPoint("TOPLEFT", 0, -128)

  -- typed fields: parse on Enter or when leaving the box; bad input is put back
  local function Typed(box, parse, apply, describe)
    local function Commit()
      local v = parse(box:GetText())
      if v then
        apply(v)
        edError:SetText("")
      else
        edError:SetText(UI.Colorize(describe, 0.95, 0.45, 0.4))
      end
      editor:Update()
    end
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    box:HookScript("OnEditFocusLost", Commit)
    return Commit
  end

  -- Day: type it or pick from a calendar
  local l3 = Label(editor, "Day"); l3:SetPoint("TOPLEFT", 0, -86)
  local dayBox = T.Input(editor, 130, "21/10 or tue")
  dayBox:SetPoint("TOPLEFT", 0, -102)
  local calBtn = T.Button(editor, "Pick", 40, 22)
  calBtn:SetPoint("LEFT", dayBox, "RIGHT", 2, 0)
  Typed(dayBox, function(t) return E.ParseDate(t) end, function(v) ed.day = v end,
    "Couldn't read that date. Try 21/10, 21 Oct, tomorrow or tue.")

  -- Start: type it or pick from a list in 15-minute steps
  local l4 = Label(editor, "Start"); l4:SetPoint("TOPLEFT", 196, -86)
  local timeBox = T.Input(editor, 80, "20:00")
  timeBox:SetPoint("TOPLEFT", 196, -102)
  local timeBtn = T.Button(editor, "v", 22, 22)
  timeBtn:SetPoint("LEFT", timeBox, "RIGHT", 2, 0)
  Typed(timeBox, E.ParseTime, function(v) ed.minutes = v end, "Couldn't read that time. Try 20:00, 8pm or 8:30 pm.")

  -- Length: typed, tidied into "3h 00m"
  local l5 = Label(editor, "Length"); l5:SetPoint("TOPLEFT", 318, -86)
  local durBox = T.Input(editor, 100, "3h")
  durBox:SetPoint("TOPLEFT", 318, -102)
  Typed(durBox, E.ParseDuration, function(v) ed.duration = v end, "Couldn't read that length. Try 3h, 2h30, 2:30 or 90m.")

  local repeatToggle = T.Toggle(editor, "Repeat every week on", function(v) ed.weekly = v; editor:Update() end)
  repeatToggle:SetPoint("TOPLEFT", 0, -150)
  local dayBtns = {}
  for i, wd in ipairs(WEEKDAYS) do
    local b = T.Button(editor, wd[2], 42, 22)
    b:SetPoint("TOPLEFT", (i - 1) * 46, -176)
    b:SetScript("OnClick", function()
      ed.wdays[wd[1]] = not ed.wdays[wd[1]] or nil
      editor:Update()
    end)
    dayBtns[i] = b
  end
  local edNote = T.Text(editor, 11, 0.4)
  edNote:SetPoint("TOPLEFT", 0, -210)
  edNote:SetWidth(420)
  edNote:SetJustifyH("LEFT")

  local saveBtn = T.Button(editor, "Save and share", 120, 24)
  saveBtn:SetPoint("TOPLEFT", 0, -246)
  local cancelBtn = T.Button(editor, "Cancel", 80, 24)
  cancelBtn:SetPoint("LEFT", saveBtn, "RIGHT", 6, 0)

  -- the editor's fields flow onto more rows when the window is narrow
  local fields = {
    { label = l1, box = titleBox, w = 260 },
    { label = l2, box = raidBox, w = 164 },
    { label = l3, box = dayBox, w = 172, newRow = true },
    { label = l4, box = timeBox, w = 104 },
    { label = l5, box = durBox, w = 100 },
  }
  function editor:Reflow()
    local w = self:GetWidth() or 0
    if w <= 0 then return end
    local x, labelY, first = 0, -34, true
    for _, f in ipairs(fields) do
      local fw = math.min(f.w, w)
      if not first and (f.newRow or x + 20 + fw > w) then x, labelY = 0, labelY - 52
      elseif not first then x = x + 20 end
      first = false
      if f.box == titleBox then titleBox:SetWidth(fw) end
      f.label:SetPoint("TOPLEFT", x, labelY)
      f.box:SetPoint("TOPLEFT", x, labelY - 16)
      x = x + fw
    end
    local y = labelY - 16 - 26
    edError:SetPoint("TOPLEFT", 0, y)
    y = y - 22
    repeatToggle:SetPoint("TOPLEFT", 0, y)
    y = y - 26
    local perRow = math.max(1, math.min(#dayBtns, math.floor((w + 4) / 46)))
    for i, b in ipairs(dayBtns) do
      b:SetPoint("TOPLEFT", ((i - 1) % perRow) * 46, y - math.floor((i - 1) / perRow) * 26)
    end
    y = y - (math.ceil(#dayBtns / perRow) - 1) * 26 - 34
    edNote:SetWidth(math.min(420, w))
    edNote:SetPoint("TOPLEFT", 0, y)
    y = y - math.max(36, math.ceil((edNote:GetStringHeight() or 0) + 14))
    saveBtn:SetPoint("TOPLEFT", 0, y)
  end
  editor:SetScript("OnSizeChanged", function(self) self:Reflow() end)
  cancelBtn:SetScript("OnClick", function() editor:Hide(); panel:Refresh() end)

  ----------------------------------------------------------------------
  -- Calendar pop-up
  ----------------------------------------------------------------------
  local cal = T.Popup(7 * 30 + 16, 6 * 24 + 62)
  cal.month = nil
  local calTitle = T.Text(cal, 13, 1); calTitle:SetPoint("TOP", 0, -8)
  local calPrev = T.Button(cal, "<", 22, 20); calPrev:SetPoint("TOPLEFT", 6, -6)
  local calNext = T.Button(cal, ">", 22, 20); calNext:SetPoint("TOPRIGHT", -6, -6)
  local heads = { "Mo", "Tu", "We", "Th", "Fr", "Sa", "Su" }
  for i, h in ipairs(heads) do
    local fs = T.Text(cal, 10, T.section)
    fs:SetPoint("TOPLEFT", 8 + (i - 1) * 30, -32)
    fs:SetWidth(28); fs:SetJustifyH("CENTER"); fs:SetText(h)
  end
  local cells = {}
  for i = 1, 42 do
    local b = CreateFrame("Button", nil, cal)
    b:SetSize(28, 22)
    b:SetPoint("TOPLEFT", 8 + ((i - 1) % 7) * 30, -46 - math.floor((i - 1) / 7) * 24)
    b.bg = T.Fill(b, { 1, 1, 1, 0 })
    local hl = b:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.08)
    b.text = T.Text(b, 12, 0.85); b.text:SetPoint("CENTER")
    cells[i] = b
  end
  function cal:Draw()
    local m = date("*t", self.month)
    calTitle:SetText(date("%B %Y", self.month))
    -- first cell is the Monday on or before the 1st
    local first = time({ year = m.year, month = m.month, day = 1, hour = 12 })
    local wd = date("*t", first).wday -- 1 = Sunday
    local back = (wd + 5) % 7
    local today = E.DayStart(ns.Now())
    local ar, ag, ab = T.Accent()
    for i, b in ipairs(cells) do
      local dayT = E.DayStart(first + (i - 1 - back) * 86400)
      local d = date("*t", dayT)
      b.day = dayT
      b.text:SetText(tostring(d.day))
      local inMonth = d.month == m.month
      local past = dayT < today
      b.text:SetTextColor(1, 1, 1, (not inMonth or past) and 0.3 or 0.9)
      if dayT == ed.day then b.bg:SetColorTexture(ar, ag, ab, 0.5)
      elseif dayT == today then b.bg:SetColorTexture(1, 1, 1, 0.1)
      else b.bg:SetColorTexture(1, 1, 1, 0) end
      b:SetScript("OnClick", function()
        ed.day = dayT
        edError:SetText("")
        cal:Close()
        editor:Update()
      end)
    end
  end
  local function ShiftMonth(n)
    local m = date("*t", cal.month)
    local mm, yy = m.month + n, m.year
    if mm < 1 then mm, yy = 12, yy - 1 elseif mm > 12 then mm, yy = 1, yy + 1 end
    cal.month = time({ year = yy, month = mm, day = 1, hour = 12 })
    cal:Draw()
  end
  calPrev:SetScript("OnClick", function() ShiftMonth(-1) end)
  calNext:SetScript("OnClick", function() ShiftMonth(1) end)
  calBtn:SetScript("OnClick", function()
    local d = date("*t", ed.day)
    cal.month = time({ year = d.year, month = d.month, day = 1, hour = 12 })
    cal:Draw()
    cal:Open()
  end)

  ----------------------------------------------------------------------
  -- Time dropdown (every 15 minutes)
  ----------------------------------------------------------------------
  local timePop = T.Popup(110, 10 * 22 + 8)
  local timeList = UI.CreateList(timePop, { { title = "", flex = true } }, 22, { noHeader = true })
  timeList:SetPoint("TOPLEFT", 4, -4)
  timeList:SetPoint("BOTTOMRIGHT", -4, 4)
  timeList.sortable = false
  timeBtn:SetScript("OnClick", function()
    local rows, current = {}, 1
    local ar, ag, ab = T.Accent()
    for i = 0, 95 do
      local mins = i * 15
      local label = E.FormatTime(time({ year = 2000, month = 1, day = 1, hour = math.floor(mins / 60), min = mins % 60 }))
      if math.abs(mins - (ed.minutes or 0)) < 15 and current == 1 then current = i + 1 end
      rows[#rows + 1] = {
        cols = { mins == ed.minutes and UI.Colorize(label, ar, ag, ab) or label },
        onClick = function() ed.minutes = mins; edError:SetText(""); timePop:Close(); editor:Update() end,
      }
    end
    timePop:Open()
    timeList:SetItems(rows)
    timeList:Layout()
    -- open scrolled to the current time
    timeList.slider:SetValue(math.max(0, current - 4))
  end)

  local DayStart = E.DayStart
  local function At(dayEpoch, minutes)
    local d = date("*t", dayEpoch)
    return time({ year = d.year, month = d.month, day = d.day, hour = math.floor(minutes / 60), min = minutes % 60, sec = 0 })
  end

  function editor:Update()
    if not dayBox:HasFocus() then dayBox:SetText(date("%a %d %b %Y", ed.day)) end
    if not timeBox:HasFocus() then timeBox:SetText(E.FormatTime(At(ed.day, ed.minutes))) end
    if not durBox:HasFocus() then durBox:SetText(E.FormatDuration(ed.duration)) end
    if not raidBox:HasFocus() then raidBox:SetText(ed.raid or "") end
    repeatToggle:SetChecked(ed.weekly)
    local wd = date("*t", ed.day).wday
    if ed.weekly and not next(ed.wdays) then ed.wdays[wd] = true end
    for i, w in ipairs(WEEKDAYS) do
      dayBtns[i]:SetShown(ed.weekly)
      dayBtns[i]:SetSelected(ed.wdays[w[1]])
    end
    edNote:SetText(ed.weekly
      and "Repeats from the chosen day onward. Times are shown in each player's own time zone."
      or "A one-off raid night. Times are shown in each player's own time zone.")
    editor:Reflow()
  end

  -- ev = event to edit; copyFrom = event to copy into a new raid night
  local function OpenEditor(ev, copyFrom)
    ed = { wdays = {} }
    local src = ev or copyFrom
    edError:SetText("")
    if src then
      local first = src.anchors[1]
      ed.event = ev -- nil when copying, so saving makes a new raid night
      ed.day = DayStart(first)
      if copyFrom then
        -- suggest the next week that hasn't passed yet
        ed.day = DayStart(first)
        while ed.day < DayStart(ns.Now()) or ed.day == DayStart(first) do ed.day = DayStart(ed.day + 7 * 86400 + 3600) end
      end
      local d = date("*t", first)
      ed.minutes = d.hour * 60 + d.min
      ed.duration = src.duration or 180
      ed.weekly = src.weekly
      ed.raid = src.raid or E.RAIDS[1]
      for _, a in ipairs(src.anchors) do ed.wdays[date("*t", a).wday] = true end
      titleBox:SetText(src.title or "")
      edTitle:SetText(copyFrom and "Copy raid night: pick the new date" or "Edit raid night")
    else
      ed.day = DayStart(ns.Now() + 86400)
      ed.minutes, ed.duration, ed.weekly, ed.raid = 20 * 60, 180, false, E.RAIDS[1]
      titleBox:SetText("")
      edTitle:SetText("New raid night")
    end
    editor:Show()
    editor:Update()
    if copyFrom then dayBox:SetFocus(); dayBox:HighlightText() end
  end
  E.OpenEditorForTest = OpenEditor
  newBtn:SetScript("OnClick", function() OpenEditor(nil) end)
  editBtn:SetScript("OnClick", function()
    local occ = selectedOcc and E.Occ(selectedOcc)
    if occ then OpenEditor(occ.event) end
  end)
  copyBtn:SetScript("OnClick", function()
    local occ = selectedOcc and E.Occ(selectedOcc)
    if occ then OpenEditor(nil, occ.event) end
  end)
  copyBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Copy this raid night")
    GameTooltip:AddLine("Opens a new raid night with the same settings so you only need to pick the date.", 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
  end)
  copyBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  -- open this night's raid plan, or make one from its sign-ups
  planBtn:SetScript("OnClick", function()
    if not selectedOcc then return end
    local plan = P.ForNight(selectedOcc)[1] or P.FromNight(selectedOcc)
    if plan then
      P.openPlan = plan.id
      UI.ShowPanel("raids")
    end
  end)
  planBtn:SetScript("OnEnter", function(self)
    local has = selectedOcc and P.ForNight(selectedOcc)[1]
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine(has and "Open this night's raid plan" or "Make a raid plan from this night")
    GameTooltip:AddLine(has and ("Opens \"" .. has.name .. "\" in Raid plans.")
      or "Accepted and Late sign-ups become the plan's member list (Tentative listed apart), with the character and role each person signed up with. Arrange the groups in Raid plans.",
      0.8, 0.8, 0.8, true)
    GameTooltip:Show()
  end)
  planBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  saveBtn:SetScript("OnClick", function()
    for _, b in ipairs({ dayBox, timeBox, durBox, raidBox }) do if b:HasFocus() then b:ClearFocus() end end
    local anchors = {}
    if ed.weekly then
      for i = 0, 6 do
        local day = ed.day + i * 86400
        if ed.wdays[date("*t", day).wday] then anchors[#anchors + 1] = At(day, ed.minutes) end
      end
    end
    if #anchors == 0 then anchors[1] = At(ed.day, ed.minutes) end
    table.sort(anchors)
    local ev = ed.event or {}
    -- keep existing anchors (and so everyone's sign-ups) if the schedule didn't change
    local same = ev.anchors and #ev.anchors == #anchors and ev.weekly == ed.weekly
    if same then for i, a in ipairs(anchors) do if ev.anchors[i] ~= a then same = false end end end
    if not same then ev.anchors, ev.skips = anchors, {} end
    local name = (titleBox:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
    ev.title = name ~= "" and name or ed.raid
    ev.raid, ev.duration, ev.weekly = ed.raid, ed.duration, ed.weekly and true or false
    local saved = E.Save(ev)
    editor:Hide()
    if saved then
      local occs = E.Occurrences(ns.Now() - 3600, ns.Now() + 21 * 86400)
      for _, o in ipairs(occs) do if o.event.id == saved.id then selectedOcc = o.id break end end
    end
    panel:Refresh()
  end)

  local deleteArmed = 0
  deleteBtn:SetScript("OnClick", function()
    local occ = selectedOcc and E.Occ(selectedOcc)
    if not occ then return end
    if GetTime() - deleteArmed > 3 then
      deleteArmed = GetTime()
      deleteBtn:SetText("Sure?")
      C_Timer.After(3, function() deleteBtn:SetText("Delete") end)
      return
    end
    deleteArmed = 0
    deleteBtn:SetText("Delete")
    E.Delete(occ.event)
    selectedOcc = nil
    panel:Refresh()
  end)
  skipBtn:SetScript("OnClick", function()
    if selectedOcc then E.Skip(selectedOcc); selectedOcc = nil; panel:Refresh() end
  end)

  ----------------------------------------------------------------------
  local function Tooltip(tt, item)
    local key = item.key
    local s = item.signup
    tt:AddLine(ns.Icons.Class(item.class, 16) .. " " .. ns.ShortName(item.char or key), ns.ClassColor(item.class))
    if item.char and item.char ~= key then tt:AddLine("Signed up by " .. ns.ShortName(key), 0.7, 0.7, 0.7) end
    if s then
      tt:AddDoubleLine(StatusTag(s.status), UI.TimeAgo(s.ts))
      if s.role then tt:AddLine(ns.ROLE_NAMES[s.role], 0.8, 0.8, 0.8) end
      if s.note and s.note ~= "" then tt:AddLine(s.note, 1, 1, 1, true) end
      if s.src == "rh" then tt:AddLine("Signed up in Discord via Raid-Helper", 0.55, 0.55, 0.55)
      elseif s.src and s.src:sub(1, 2) == "o:" then tt:AddLine("Changed by " .. ns.ShortName(s.src:sub(3)), 0.55, 0.55, 0.55) end
    else
      tt:AddLine("Hasn't replied", 0.6, 0.6, 0.6)
    end
    if item.canFix then
      tt:AddLine(" ")
      tt:AddLine("Click to mark as attended or not.", 0.6, 0.6, 0.6)
    end
    if P.CanEdit("raids") then
      if not item.canFix then tt:AddLine(" ") end
      tt:AddLine("Right-click to change their answer, role or note.", 0.6, 0.6, 0.6)
    end
  end

  -- officers: right-click menu to change anyone's answer, role or note
  local notePop
  local function EditNote(occId, key)
    if not notePop then
      notePop = T.Popup(260, 58)
      notePop.title = T.Text(notePop, 12, 0.85)
      notePop.title:SetPoint("TOPLEFT", 10, -10)
      notePop.box = T.Input(notePop, 240, "Note, then Enter")
      notePop.box:SetPoint("TOPLEFT", 10, -28)
      notePop.box:SetMaxLetters(60)
      notePop.box:SetScript("OnEnterPressed", function(self)
        E.OfficerSet(notePop.occId, notePop.key, { note = self:GetText() or "" })
        self:ClearFocus()
        notePop:Close()
      end)
      notePop.box:SetScript("OnEscapePressed", function(self) self:ClearFocus(); notePop:Close() end)
    end
    local cur = E.Signups(occId)[key]
    notePop.occId, notePop.key = occId, key
    notePop.title:SetText("Note for " .. ns.ShortName(cur and E.SignupChar(key, cur) or key))
    notePop.box:SetText(cur and cur.note or "")
    notePop:Open()
    notePop.box:SetFocus()
  end

  local function OfficerMenu(owner, occId, key)
    if not P.CanEdit("raids") or not occId then return end
    local cur = E.Signups(occId)[key]
    local status = cur and cur.status ~= "R" and cur.status
    local items = {}
    for _, st in ipairs({ "A", "L", "T", "D" }) do
      items[#items + 1] = { text = E.STATUS[st], checked = status == st,
                            onClick = function() E.OfficerSet(occId, key, { status = st }) end }
    end
    items[#items + 1] = { text = UI.Dim("Role", 0.45) }
    for _, role in ipairs(ns.ROLES) do
      items[#items + 1] = { text = "   " .. ns.ROLE_NAMES[role], checked = cur and cur.role == role,
                            onClick = function() E.OfficerSet(occId, key, { role = role }) end }
    end
    items[#items + 1] = { text = "Edit note...", onClick = function() EditNote(occId, key) end }
    if status then
      items[#items + 1] = { text = UI.Colorize("Clear their answer", 0.9, 0.5, 0.45),
                            onClick = function() E.OfficerSet(occId, key, { status = "R" }) end }
    end
    T.Menu(owner, items, 190)
  end

  local function ClassOf(key)
    local r = ns.roster[key]
    local rec = (key == ns.MyKey()) and ns.MyRecord() or (ns.GuildDB() and ns.GuildDB().members[key])
    return (rec and rec.class) or (r and r.class)
  end

  -- show a particular night (e.g. after a Raid-Helper import), past or upcoming
  function panel:ShowNight(occId)
    local occ = E.Occ(occId)
    if not occ then return end
    showPast = occ.finish < ns.Now()
    pastToggle:SetChecked(showPast)
    selectedOcc = occId
    self:Refresh()
  end

  function panel:Refresh()
    local canEdit = P.CanEdit("raids")
    newBtn:SetShown(canEdit)
    pastToggle:ClearAllPoints()
    rhBtn:SetShown(canEdit)
    if canEdit then pastToggle:SetPoint("LEFT", rhBtn, "RIGHT", 14, 0) else pastToggle:SetPoint("TOPLEFT", 0, 0) end

    local now = ns.Now()
    local occs
    if showPast then
      occs = E.Occurrences(now - 60 * 86400, now)
      local rev = {}
      for i = #occs, 1, -1 do if occs[i].finish < now then rev[#rev + 1] = occs[i] end end
      occs = rev
    else
      occs = E.Occurrences(now, now + 28 * 86400)
    end

    local items = {}
    local ar, ag, ab = T.Accent()
    local found = false
    for _, occ in ipairs(occs) do
      if occ.id == selectedOcc then found = true end
      local mine = E.MySignup(occ.id)
      local running = now >= occ.start and now <= occ.finish
      local when = E.FormatDay(occ.start) .. " " .. UI.Dim(E.FormatTime(occ.start), 0.6)
      local name = occ.event.title
      if occ.id == selectedOcc then name = UI.Colorize(name, ar, ag, ab) end
      if running then name = name .. "  " .. UI.Colorize("now", 0.4, 0.85, 0.5) end
      items[#items + 1] = {
        cols = { when, name, showPast and "" or StatusTag(mine and mine.status, true) },
        onClick = function() selectedOcc = occ.id; editor:Hide(); panel:Refresh() end,
      }
    end
    if not found then selectedOcc = occs[1] and occs[1].id or nil end
    if not found and selectedOcc then
      -- re-highlight the auto-selected row
      return panel:Refresh()
    end
    list:SetItems(items, showPast and "No past raid nights in the last 60 days"
      or (canEdit and "No raid nights planned. Click New raid night." or "No raid nights planned yet."))
    info:SetText(showPast and "Last 60 days" or "Next 4 weeks")

    local occ = selectedOcc and E.Occ(selectedOcc)
    detail:SetShown(occ ~= nil and not editor:IsShown())
    emptyText:SetShown(occ == nil and not editor:IsShown())
    emptyText:SetText(canEdit and "Create a raid night to start taking sign-ups" or "Nothing to show yet")
    if not occ then
      UI.SetHint(canEdit and "Officers create raid nights; members sign up here." or "Officers post raid nights here for you to sign up to.")
      return
    end

    local ev = occ.event
    local past = occ.finish < now
    title:SetText(ev.title)
    sub:SetText(("%s  ·  %s - %s  ·  %s%s"):format(E.FormatDay(occ.start), E.FormatTime(occ.start), E.FormatTime(occ.finish),
      ev.raid or "", ev.weekly and "  ·  weekly" or ""))
    editBtn:SetShown(canEdit)
    deleteBtn:SetShown(canEdit)
    skipBtn:SetShown(canEdit and ev.weekly and not past)
    copyBtn:SetShown(canEdit)
    planBtn:SetShown(P.CanEdit("plans") and not past)
    local hasPlan = P.ForNight(occ.id)[1] ~= nil
    planBtn:SetText(hasPlan and "Raid plan" or "Make raid plan")
    planBtn:SetWidth(hasPlan and 80 or 112)
    head:Layout()
    local extra = head.h - 22 -- header wrapped onto more rows

    -- my sign-up controls
    signRow:SetShown(not past)
    local mine = E.MySignup(occ.id)
    if not past then
      myChar = (mine and mine.char) or myChar or ns.MyKey()
      if not myRole or not mine then
        local d = P.Describe(nil, myChar)
        myRole = (mine and mine.role) or d.role
      end
      for st, b in pairs(statusBtns) do b:SetSelected(mine and mine.status == st) end
      charBtn:SetText(ns.Icons.Class(ClassOf(myChar), 14) .. " " .. ns.ShortName(myChar))
      roleBtn:SetText(ns.ROLE_NAMES[myRole] or "Role")
      if not noteBox:HasFocus() then noteBox:SetText(mine and mine.note or "") end
    end

    -- responses
    local top = (past and -52 or -112) - extra
    noReplyToggle:ClearAllPoints()
    noReplyToggle:SetPoint("TOPRIGHT", 0, top + 3)
    noReplyToggle:SetShown(not past)
    summary:ClearAllPoints()
    summary:SetPoint("TOPLEFT", 0, top)
    if past then summary:SetPoint("RIGHT", detail, "RIGHT", 0, 0)
    else summary:SetPoint("RIGHT", noReplyToggle, "LEFT", -8, 0) end

    local signups = E.Signups(occ.id)
    local counts, roles = { A = 0, L = 0, T = 0, D = 0 }, { TANK = 0, HEALER = 0, MELEE = 0, RANGED = 0 }
    local rows, seen = {}, {}
    for signer, s in pairs(signups) do
      if s.status ~= "R" then
        counts[s.status] = (counts[s.status] or 0) + 1
        if (s.status == "A" or s.status == "L") and s.role then roles[s.role] = roles[s.role] + 1 end
        local char = E.SignupChar(signer, s)
        seen[signer] = true
        seen[char] = true
        rows[#rows + 1] = { key = signer, char = char, signup = s }
      end
    end
    local noReply = 0
    for _, m in ipairs(ns.AllMembers()) do
      local lvl = (m.roster and m.roster.level) or 0
      if not seen[m.key] and lvl >= ns.MAX_LEVEL then
        noReply = noReply + 1
        if showNoReply or past then rows[#rows + 1] = { key = m.key, char = m.key } end
      end
    end
    summary:SetText(("%s %d   %s %d   %s %d   %s %d   %s %d        %s %d  %s %d  %s %d  %s %d"):format(
      StatusTag("A"), counts.A, StatusTag("L"), counts.L, StatusTag("T"), counts.T, StatusTag("D"), counts.D,
      UI.Dim("No reply", 0.45), noReply,
      UI.Dim("T", 0.5), roles.TANK, UI.Dim("H", 0.5), roles.HEALER, UI.Dim("M", 0.5), roles.MELEE, UI.Dim("R", 0.5), roles.RANGED))

    -- the summary wraps onto two lines when the window is narrow
    local listTop = top - math.max(24, math.ceil((summary:GetStringHeight() or 0) + 10))
    responses:ClearAllPoints()
    responses:SetPoint("TOPLEFT", 0, listTop)
    responses:SetPoint("BOTTOMRIGHT", 0, 0)
    attendanceList:ClearAllPoints()
    attendanceList:SetPoint("TOPLEFT", 0, listTop)
    attendanceList:SetPoint("BOTTOMRIGHT", 0, 0)
    responses:SetShown(not past)
    attendanceList:SetShown(past)

    if not past then
      local out = {}
      for _, r in ipairs(rows) do
        local s = r.signup
        local cls = ClassOf(r.char)
        out[#out + 1] = {
          key = r.key, char = r.char, signup = s, class = cls,
          cols = { UI.NameCell(r.char, cls, ns.IsOnline(r.char) or ns.IsOnline(r.key)), RoleTag(s and s.role),
                   StatusTag(s and s.status), UI.Dim(s and s.note or "", 0.75), s and UI.Dim(UI.TimeAgo(s.ts), 0.45) or "" },
          sort = { ns.ShortName(r.char):lower(), s and s.role or "Z", s and E.STATUS_ORDER[s.status] or 9, s and s.note or "", -(s and s.ts or 0) },
          tooltip = Tooltip,
          onClick = function(it, button)
            if button == "RightButton" then OfficerMenu(responses, occ.id, it.key) end
          end,
        }
      end
      responses:SetItems(out, "No members at level " .. ns.MAX_LEVEL .. " yet")
      UI.SetHint(mine and "You're signed up. Change your status, character, role or note any time."
        or "Pick Accepted, Late, Tentative or Declined to sign up.")
    else
      -- attendance for a past night: everyone signed up, plus anyone recorded in the raid
      local att = E.Attendance(occ.id)
      if att then
        for key in pairs(att.min) do if not seen[key] then rows[#rows + 1] = { key = key, char = key }; seen[key] = true end end
        for key in pairs(att.ov) do if not seen[key] then rows[#rows + 1] = { key = key, char = key }; seen[key] = true end end
      end
      local out, present = {}, 0
      for _, r in ipairs(rows) do
        local s = r.signup
        local who = r.char
        local here = E.Present(occ, who)
        if here == nil and att then here = false end
        if here then present = present + 1 end
        local mins = att and att.min[who] or 0
        local fixed = att and att.ov[who]
        local cls = ClassOf(who)
        if s or here or (att and (att.min[who] or att.ov[who])) or (past and showNoReply) then
          out[#out + 1] = {
            key = r.key, char = who, signup = s, class = cls, canFix = canEdit,
            cols = { UI.NameCell(who, cls, false), StatusTag(s and s.status),
                     here == nil and UI.Dim("not recorded", 0.35) or (here and UI.Colorize("Yes", 0.4, 0.85, 0.5) or UI.Colorize("No", 0.9, 0.4, 0.4))
                       .. (fixed and UI.Dim("  (set)", 0.4) or ""),
                     mins > 0 and (math.floor(mins / 60) .. "h " .. (mins % 60) .. "m") or UI.Dim("-", 0.3),
                     UI.Dim(s and s.note or "", 0.7) },
            sort = { ns.ShortName(who):lower(), s and E.STATUS_ORDER[s.status] or 9, here and 0 or 1, mins, s and s.note or "" },
            tooltip = Tooltip,
            onClick = function(it, button)
              if button == "RightButton" then OfficerMenu(attendanceList, occ.id, it.key)
              elseif canEdit then E.Override(occ.id, who, not here) end
            end,
          }
        end
      end
      attendanceList:SetItems(out, "Nobody signed up or was recorded")
      summary:SetText(att and (("%d attended  ·  recorded automatically by officers in the raid"):format(present))
        or "No attendance recorded. An officer with FableHub needs to be in the raid while it runs.")
      UI.SetHint(canEdit and "Click a member to correct their attendance." or "Attendance is recorded by officers in the raid.")
    end
  end

  panel:SetScript("OnHide", function() editor:Hide() end)
end, "raidgroup")

ns.On("EVENTS_CHANGED", function() if ns.UI.QueueRefresh then ns.UI.QueueRefresh() end end)
