-- Raid nights > Import Raid-Helper: paste the event's JSON export, check who
-- matched which character, then import the sign-ups onto the raid night.

local _, ns = ...
local UI = ns.UI
local M = {}
ns.RaidHelperUI = M

local STATUS_COLOR = { A = { 0.4, 0.85, 0.5 }, L = { 0.95, 0.75, 0.3 }, T = { 0.75, 0.75, 0.75 }, D = { 0.9, 0.45, 0.4 } }

local dlg

-- the event's date, with a warning when it's odd
function M.When(ev)
  local E = ns.Events
  local when = E.FormatDay(ev.start) .. " " .. E.FormatTime(ev.start)
  if ns.RaidHelper.Unrealistic(ev) then
    return when .. " " .. date("%Y", ev.start) .. UI.Colorize("  (that date looks wrong)", 0.95, 0.45, 0.4)
  elseif ev.start + ev.minutes * 60 < ns.Now() then
    return when .. UI.Colorize("  (already over)", 0.95, 0.75, 0.3)
  end
  return when
end

-- where the sign-ups will go: text, and whether Import can go ahead
function M.Target(ev, chosen)
  local E, RH = ns.Events, ns.RaidHelper
  local occ
  if chosen and chosen ~= "new" then occ = E.Occ(chosen)
  elseif not chosen then occ = RH.FindNight(ev) end
  if occ then
    return ("goes onto |cffffffff%s|r (%s %s)"):format(occ.event.title or "Raid", E.FormatDay(occ.start), E.FormatTime(occ.start)), true
  end
  if RH.Unrealistic(ev) then
    return UI.Colorize("choose a raid night for these sign-ups", 0.95, 0.75, 0.3), false
  end
  return ("a new raid night will be created (%s)"):format(E.FormatDuration(ev.minutes)), true
end

local function Build(panel)
  local T, RH, E = ns.Theme, ns.RaidHelper, ns.Events
  local ev -- parsed event

  dlg = CreateFrame("Frame", nil, panel)
  dlg:SetAllPoints()
  dlg:SetFrameLevel(panel:GetFrameLevel() + 30)
  T.Fill(dlg, T.bg)
  dlg:EnableMouse(true)
  dlg:Hide()

  local title = T.Text(dlg, 15, 1)
  title:SetPoint("TOPLEFT", 0, 0)
  title:SetText("Import from Raid-Helper")
  local help = T.Text(dlg, 12, 0.6)
  help:SetPoint("TOPLEFT", 0, -24)
  help:SetPoint("RIGHT", dlg, "RIGHT", 0, 0)
  help:SetJustifyH("LEFT")
  help:SetText("On raid-helper.dev, open the event and copy its JSON export. Paste it below (Ctrl+V) and click Read. Check the matches, then Import.")

  local box = CreateFrame("Frame", nil, dlg)
  box:SetPoint("TOPLEFT", 0, -46)
  box:SetPoint("RIGHT", dlg, "RIGHT", -100, 0)
  box:SetHeight(54)
  T.Fill(box, T.input)
  T.Border(box, 0.1)
  local scroll = CreateFrame("ScrollFrame", nil, box)
  scroll:SetPoint("TOPLEFT", 6, -6)
  scroll:SetPoint("BOTTOMRIGHT", -6, 6)
  local edit = CreateFrame("EditBox", nil, scroll)
  edit:SetMultiLine(true)
  edit:SetAutoFocus(false)
  edit:SetMaxLetters(0)
  T.SetFont(edit, 10)
  edit:SetTextColor(1, 1, 1, 0.6)
  edit:SetWidth(500)
  edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  scroll:SetScrollChild(edit)
  scroll:SetScript("OnSizeChanged", function(self, w) edit:SetWidth(math.max(100, (w or 500))) end)
  box:EnableMouse(true)
  box:SetScript("OnMouseDown", function() edit:SetFocus() end)

  local readBtn = T.Button(dlg, "Read", 90, 24)
  readBtn:SetPoint("TOPRIGHT", 0, -46)

  local target = T.Text(dlg, 12, 0.8)
  target:SetPoint("TOPLEFT", 0, -110)
  target:SetPoint("RIGHT", dlg, "RIGHT", -130, 0)
  target:SetJustifyH("LEFT")
  target:SetWordWrap(false)
  local chooseBtn = T.Button(dlg, "Choose raid night", 124, 20)
  chooseBtn:SetPoint("TOPRIGHT", 0, -106)
  local chosen -- nil = automatic, "new" = create on the event's date, or a raid night id

  local list = UI.CreateList(dlg, {
    { title = "Discord name", width = 150 },
    { title = "Signed up as", width = 150 },
    { title = "Answer", width = 110 },
    { title = "Character", flex = true },
  }, 22)
  list:SetPoint("TOPLEFT", 0, -132)
  list:SetPoint("BOTTOMRIGHT", 0, 40)
  list.sortable = false

  local status = T.Text(dlg, 12, 0.7)
  status:SetPoint("BOTTOMLEFT", 0, 12)
  local importBtn = T.Button(dlg, "Import", 90, 24)
  importBtn:SetPoint("BOTTOMRIGHT", -96, 6)
  local closeBtn = T.Button(dlg, "Close", 86, 24)
  closeBtn:SetPoint("BOTTOMRIGHT", 0, 6)
  closeBtn:SetScript("OnClick", function() dlg:Hide(); panel:Refresh() end)

  local Show
  local function OpenLink(e)
    UI.PickMember("Which character is " .. e.name .. "?", function(key)
      RH.Link(e.userId, key)
      Show()
    end)
  end

  -- re-match everyone (after a link changes) and redraw
  Show = function()
    if not ev then
      target:SetText("")
      list:SetItems({}, "Paste an export and click Read.")
      importBtn:SetShown(false)
      return
    end
    for _, e in ipairs(ev.entries) do e.key, e.how = RH.Match(e.userId, e.name) end
    local dest, destOk = M.Target(ev, chosen)
    target:SetText(("|cffffffff%s|r  ·  %s  ·  %s"):format(ev.title, M.When(ev), dest))
    chooseBtn:Show()
    local items, matched = {}, 0
    for _, e in ipairs(ev.entries) do
      local c = STATUS_COLOR[e.status] or { 1, 1, 1 }
      local answer = UI.Colorize(E.STATUS[e.status] or e.status, c[1], c[2], c[3]) .. (e.bench and UI.Dim(" (bench)", 0.5) or "")
      local as = e.class and (ns.Icons.Class(e.class, 14) .. " " .. UI.Colorize(e.spec or "", ns.ClassColor(e.class)))
        or UI.Dim(e.spec or "-", 0.5)
      if e.role then as = as .. UI.Dim("  " .. ns.ROLE_NAMES[e.role], 0.45) end
      local who
      if e.key then
        matched = matched + 1
        local r = ns.roster[e.key]
        who = UI.NameCell(e.key, r and r.class or e.class, r and r.online)
        if e.how == "guess" then who = who .. UI.Colorize("  (guess, check)", 0.95, 0.75, 0.3)
        elseif e.how == "linked" then who = who .. UI.Dim("  (linked)", 0.4) end
      elseif e.how == "ignored" then
        who = UI.Dim("ignored", 0.4)
      else
        who = UI.Colorize("not matched: click to pick", 0.9, 0.45, 0.4)
      end
      items[#items + 1] = {
        e = e,
        cols = { e.name, as, answer, who },
        tooltip = function(tt, it)
          tt:AddLine(it.e.name, 1, 1, 1)
          tt:AddLine("Click to choose the character. Right-click for more.", 0.6, 0.6, 0.6)
        end,
        onClick = function(it, button)
          if button == "RightButton" then
            T.Menu(list, {
              { text = "Choose character...", onClick = function() OpenLink(it.e) end },
              { text = "Ignore this person", onClick = function() RH.Link(it.e.userId, "-"); Show() end },
              { text = "Forget saved link", onClick = function() RH.Link(it.e.userId, nil); Show() end },
            }, 180)
          else
            OpenLink(it.e)
          end
        end,
      }
    end
    list:SetItems(items, "No sign-ups in this event")
    importBtn:SetShown(matched > 0 and destOk)
    status:SetText(("%d sign-ups  ·  %d matched to characters%s"):format(#ev.entries, matched,
      matched < #ev.entries and "  ·  unmatched people are skipped" or ""))
  end

  readBtn:SetScript("OnClick", function()
    local parsed, err = RH.Parse(edit:GetText())
    edit:ClearFocus()
    if not parsed then
      ev = nil
      Show()
      status:SetText(UI.Colorize(err, 0.95, 0.45, 0.4))
      return
    end
    ev = parsed
    chosen = nil
    Show()
  end)

  chooseBtn:SetScript("OnClick", function(self)
    if not ev then return end
    local items = {}
    local now = ns.Now()
    for _, o in ipairs(E.Occurrences(now - 7 * 86400, now + 28 * 86400)) do
      local id = o.id
      items[#items + 1] = { text = E.FormatDay(o.start) .. " " .. E.FormatTime(o.start) .. "  " .. (o.event.title or "Raid"),
                            checked = chosen == id, onClick = function() chosen = id; Show() end }
    end
    if not RH.Unrealistic(ev) then
      items[#items + 1] = { text = "New raid night on " .. E.FormatDay(ev.start), checked = chosen == "new",
                            onClick = function() chosen = "new"; Show() end }
    end
    if #items == 0 then items[1] = { text = "No raid nights in the next 4 weeks" } end
    T.Menu(self, items, 260)
  end)

  importBtn:SetScript("OnClick", function()
    if not ev then return end
    local occ
    if chosen and chosen ~= "new" then occ = E.Occ(chosen)
    elseif chosen ~= "new" then occ = RH.FindNight(ev) end
    if not occ then
      if RH.Unrealistic(ev) then status:SetText(UI.Colorize("Choose a raid night first.", 0.95, 0.45, 0.4)) return end
      occ = RH.CreateNight(ev)
    end
    if not occ then status:SetText(UI.Colorize("Couldn't create the raid night.", 0.95, 0.45, 0.4)) return end
    local n, skipped, unmatched = RH.Import(ev, occ)
    status:SetText(UI.Colorize(("Imported %d sign-ups%s%s. Sharing with the guild..."):format(n,
      skipped > 0 and (", kept " .. skipped .. " newer in-game answers") or "",
      unmatched > 0 and (", skipped " .. unmatched .. " unmatched") or ""), 0.4, 0.85, 0.5))
    edit:SetText("")
    ev = nil
    local occId = occ.id
    C_Timer.After(2, function()
      dlg:Hide()
      if panel.ShowNight then panel:ShowNight(occId) else panel:Refresh() end
    end)
  end)

  dlg.edit, dlg.readBtn, dlg.importBtn, dlg.status, dlg.chooseBtn = edit, readBtn, importBtn, status, chooseBtn
  function dlg:Choose(v) chosen = v; Show() end

  function dlg:Reset()
    ev = nil
    chosen = nil
    edit:SetText("")
    status:SetText("")
    Show()
  end
end

function M.Open(panel)
  if not ns.Plans.CanEdit() then return end
  if not dlg then Build(panel) end
  dlg:Reset()
  dlg:Show()
end
M.Dialog = function() return dlg end
