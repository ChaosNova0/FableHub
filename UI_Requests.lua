-- Requests page (Professions > Requests) and the new-request window.

local _, ns = ...
local UI, T, P, R = ns.UI, ns.Theme, ns.Plans, ns.Requests

local GREEN, GOLD = { 0.4, 0.85, 0.5 }, { 1, 0.82, 0 }

local function StatusText(r)
  if R.Expired(r) then return UI.Dim("Expired", 0.4) end
  if r.status == "open" then return UI.Colorize("Open", GOLD[1], GOLD[2], GOLD[3]) end
  if r.status == "claimed" then
    return UI.Colorize("Claimed", 0.65, 0.7, 1) .. UI.Dim(" by " .. ns.ShortName(r.claimer or "?"), 0.6)
  end
  if r.status == "done" then return UI.Colorize("Done", GREEN[1], GREEN[2], GREEN[3]) end
  return UI.Dim("Cancelled", 0.4)
end

local function Ago(ts)
  return UI.TimeAgo(ts)
end

ns.RegisterPanel("requests", "Craft Requests", nil, function(panel)
  local mineOnly, showFinished = false, false

  local newBtn = T.Button(panel, "New request", 110, 22)
  newBtn:SetPoint("TOPLEFT", 0, 0)
  local mineToggle = T.Toggle(panel, "Only ones I can craft", function(v) mineOnly = v; panel:Refresh() end)
  mineToggle:SetPoint("LEFT", newBtn, "RIGHT", 14, 0)
  local finishedToggle = T.Toggle(panel, "Show recently finished", function(v) showFinished = v; panel:Refresh() end)
  finishedToggle:SetPoint("LEFT", mineToggle, "RIGHT", 14, 0)
  local info = T.Text(panel, 11, 0.45)

  local list = UI.CreateList(panel, {
    { title = "Item", flex = true },
    { title = "Qty", width = 30, justify = "RIGHT" },
    { title = "Mats", width = 96 },
    { title = "Requested by", width = 140 },
    { title = "Status", width = 140 },
    { title = "Crafters", width = 54, justify = "RIGHT", defaultAsc = false },
    { title = "Posted", width = 62, justify = "RIGHT" },
  }, 24)
  list:SetPoint("TOPLEFT", 0, -32)
  list:SetPoint("BOTTOMRIGHT", 0, 0)
  local bar = UI.Toolbar(panel)
  bar:Add(newBtn)
  bar:Add(mineToggle, { gap = 14 })
  bar:Add(finishedToggle, { gap = 14 })
  bar:Status(info)
  bar:Below(list, { gap = 10 })
  list.sortCol, list.sortAsc = 5, true

  ----------------------------------------------------------------------
  -- new request window
  ----------------------------------------------------------------------
  local dlg = CreateFrame("Frame", nil, panel)
  dlg:SetAllPoints()
  dlg:SetFrameLevel(panel:GetFrameLevel() + 30)
  T.Fill(dlg, T.bg)
  dlg:EnableMouse(true)
  dlg:Hide()
  local st = {}

  local dTitle = T.Text(dlg, 15, 1); dTitle:SetPoint("TOPLEFT", 0, 0); dTitle:SetText("Ask the guild to craft something")
  local dCancel = T.Button(dlg, "Cancel", 80, 22); dCancel:SetPoint("TOPRIGHT", 0, 0)
  local l1 = T.Text(dlg, 11, T.section); l1:SetPoint("TOPLEFT", 0, -34); l1:SetText("WHAT DO YOU NEED?")
  local input = T.Input(dlg, 360, "Item or recipe name, or shift-click an item")
  input:SetPoint("TOPLEFT", 0, -50)
  UI.AcceptLinks(input)
  local sug = UI.CreateList(dlg, { { title = "Crafted in the guild", flex = true }, { title = "Crafters", width = 54, justify = "RIGHT" } }, 24)
  sug:SetPoint("TOPLEFT", 0, -78)
  sug:SetSize(360, 22 + 7 * 24)
  sug.sortable = false
  local chosen = T.Text(dlg, 14, 1); chosen:SetPoint("TOPLEFT", 0, -84); chosen:SetWidth(360); chosen:SetJustifyH("LEFT")
  local chosenSub = T.Text(dlg, 11, 0.5); chosenSub:SetPoint("TOPLEFT", 0, -104); chosenSub:SetWidth(360); chosenSub:SetJustifyH("LEFT")

  local RX = 380
  local l2 = T.Text(dlg, 11, T.section); l2:SetPoint("TOPLEFT", RX, -34); l2:SetText("HOW MANY")
  local qtyBox = CreateFrame("Frame", nil, dlg); qtyBox:SetSize(110, 22); qtyBox:SetPoint("TOPLEFT", RX, -50)
  T.Fill(qtyBox, T.input); T.Border(qtyBox, 0.08)
  local qMinus = T.Button(qtyBox, "<", 22, 22); qMinus:SetPoint("LEFT")
  local qPlus = T.Button(qtyBox, ">", 22, 22); qPlus:SetPoint("RIGHT")
  local qText = T.Text(qtyBox, 12, 0.9); qText:SetPoint("CENTER")
  local l3 = T.Text(dlg, 11, T.section); l3:SetPoint("TOPLEFT", RX, -84); l3:SetText("MATS")
  local matBtns, matOrder = {}, { "all", "some", "none" }
  local matLabel = { all = "I have all", some = "Some", none = "None" }
  for i, m in ipairs(matOrder) do
    local b = T.Button(dlg, matLabel[m], i == 1 and 80 or 60, 22)
    if i == 1 then b:SetPoint("TOPLEFT", RX, -100) else b:SetPoint("LEFT", matBtns[matOrder[i - 1]], "RIGHT", 4, 0) end
    b:SetScript("OnClick", function() st.mats = m; dlg:Refresh() end)
    matBtns[m] = b
  end
  local l4 = T.Text(dlg, 11, T.section); l4:SetPoint("TOPLEFT", RX, -134); l4:SetText("NOTE")
  local noteBox = T.Input(dlg, 220, "Needed for Thursday's raid")
  noteBox:SetPoint("TOPLEFT", RX, -150)
  local postBtn = T.Button(dlg, "Post request", 130, 24); postBtn:SetPoint("TOPLEFT", RX, -190)
  local dStatus = T.Text(dlg, 12, 0.7); dStatus:SetPoint("TOPLEFT", RX, -222); dStatus:SetWidth(240); dStatus:SetJustifyH("LEFT")
  -- narrow window: the left column gives up room so the right one still fits
  UI.TwoColumns(dlg, {
    maxL = 360, rightW = 220,
    left = { input, sug, chosen, chosenSub },
    right = { { l2, -34 }, { qtyBox, -50 }, { l3, -84 }, { matBtns.all, -100 }, { l4, -134 }, { noteBox, -150 },
              { postBtn, -190 }, { dStatus, -222 } },
    rightFit = { { dStatus, 240 }, { noteBox, 220 } },
  })

  function dlg:Refresh()
    local picking = st.recipe == nil
    sug:SetShown(picking and (st.text or "") ~= "")
    chosen:SetShown(not picking); chosenSub:SetShown(not picking)
    if picking and (st.text or "") ~= "" then
      local rows = {}
      for _, r in ipairs(R.Search(st.text, 7)) do
        rows[#rows + 1] = {
          cols = { R.DisplayName(r, 16) .. "  " .. UI.Dim(r.profName, 0.45), tostring(#r.crafters) },
          onClick = function()
            st.recipe, st.prof, st.item = r.recipe, r.prof, r.item
            input:SetText(""); input:ClearFocus()
            dlg:Refresh()
          end,
        }
      end
      sug:SetItems(rows, "Nobody in the guild is known to craft that yet")
    end
    if not picking then
      chosen:SetText(R.DisplayName({ recipe = st.recipe, item = st.item }, 18))
      local crafters = R.Crafters(st.recipe, st.prof)
      local names = {}
      for i, c in ipairs(crafters) do
        if i > 5 then names[#names + 1] = "+" .. (#crafters - 5) break end
        names[#names + 1] = ns.ShortName(c.key)
      end
      chosenSub:SetText(#crafters > 0 and ("Can craft: " .. table.concat(names, ", ")) or "Nobody in the guild is known to craft this yet.")
    end
    qText:SetText(tostring(st.qty or 1))
    for m, b in pairs(matBtns) do b:SetSelected(st.mats == m) end
    postBtn:SetSelected(st.recipe ~= nil)
  end

  input:HookScript("OnTextChanged", function(self)
    local text = self:GetText() or ""
    if text == "" and st.recipe then return end
    st.text = text
    if text ~= "" then st.recipe, st.prof, st.item = nil, nil, nil end
    -- a shift-clicked item that the guild can craft selects straight away
    if text:find("item:", 1, true) then
      local hit = R.Search(text, 1)[1]
      if hit then st.recipe, st.prof, st.item = hit.recipe, hit.prof, hit.item end
    end
    dlg:Refresh()
  end)
  qMinus:SetScript("OnClick", function() st.qty = math.max(1, (st.qty or 1) - 1); dlg:Refresh() end)
  qPlus:SetScript("OnClick", function() st.qty = math.min(99, (st.qty or 1) + 1); dlg:Refresh() end)
  dCancel:SetScript("OnClick", function() dlg:Hide(); panel:Refresh() end)
  postBtn:SetScript("OnClick", function()
    if not st.recipe then dStatus:SetText(UI.Colorize("Pick what you need first.", 0.95, 0.45, 0.4)) return end
    local r = R.Post(st.recipe, st.prof, st.item, st.qty, st.mats, noteBox:GetText())
    if r then
      dlg:Hide()
      panel:Refresh()
      ns.Print(("Request posted: %s x%d."):format(R.DisplayName(r), r.qty))
    end
  end)

  local function OpenNew(recipe, prof, item)
    st = { recipe = recipe, prof = prof, item = item, qty = 1, mats = "all", text = "" }
    input:SetText(""); noteBox:SetText(""); dStatus:SetText("")
    st.recipe, st.prof, st.item = recipe, prof, item
    dlg:Show()
    dlg:Refresh()
    if not recipe then input:SetFocus() end
  end
  newBtn:SetScript("OnClick", function() OpenNew() end)
  R.OpenNew = function(recipe, prof, item)
    if ns.UI.ShowPanel then ns.UI.ShowPanel("requests") end
    OpenNew(recipe, prof, item)
  end
  R.dialogState = function() return st end -- for tests

  ----------------------------------------------------------------------
  local function Actions(r)
    local me = ns.MyKey()
    local items = {}
    local active = R.Active(r)
    if active and r.status == "open" and r.by ~= me then
      items[#items + 1] = { text = UI.Colorize("Claim: I'll craft this", GREEN[1], GREEN[2], GREEN[3]), onClick = function() R.Claim(r) end }
    end
    if active and r.status == "claimed" and (r.claimer == me or r.by == me) then
      items[#items + 1] = { text = "Mark as done", onClick = function() R.Done(r) end }
      items[#items + 1] = { text = r.claimer == me and "Un-claim (I can't do it)" or "Un-claim (back to open)", onClick = function() R.Unclaim(r) end }
    end
    if active and r.status == "open" and r.by == me then
      items[#items + 1] = { text = "Mark as done", onClick = function() R.Done(r) end }
    end
    if r.by ~= me then items[#items + 1] = { text = "Whisper " .. ns.ShortName(r.by), onClick = function() UI.Whisper(r.by) end } end
    if r.claimer and r.claimer ~= me then items[#items + 1] = { text = "Whisper " .. ns.ShortName(r.claimer), onClick = function() UI.Whisper(r.claimer) end } end
    if (r.status == "open" or r.status == "claimed") and (r.by == me or P.CanEdit()) then
      items[#items + 1] = { text = UI.Colorize(r.by == me and "Cancel my request" or "Cancel (officer)", 0.95, 0.45, 0.4), onClick = function() R.Cancel(r) end }
    end
    if #items == 0 then items[1] = { text = UI.Dim("Nothing to do here", 0.5) } end
    T.Menu(list, items, 220)
  end

  function panel:Refresh()
    R.Prune()
    local me = ns.MyKey()
    local rows, open, forMe = {}, 0, 0
    for _, r in pairs(R.All()) do
      local active = R.Active(r)
      local canCraft = R.ICanCraft(r)
      if active and r.status == "open" then open = open + 1; if canCraft and r.by ~= me then forMe = forMe + 1 end end
      if (active or showFinished) and (not mineOnly or canCraft) then
        local crafters = R.Crafters(r.recipe, r.prof)
        local name = R.DisplayName(r)
        if canCraft and active and r.status == "open" and r.by ~= me then
          name = name .. "  " .. UI.Colorize("you can craft", GOLD[1], GOLD[2], GOLD[3])
        end
        local order = ({ open = 1, claimed = 2, done = 3, cancelled = 4 })[r.status] or 5
        if not active and order < 3 then order = 5 end
        rows[#rows + 1] = {
          cols = { name, tostring(r.qty or 1), UI.Dim(R.MATS[r.mats] or "", 0.6),
                   UI.NameCell(r.by, (ns.roster[r.by] or {}).class, ns.IsOnline(r.by)), StatusText(r),
                   #crafters > 0 and tostring(#crafters) or UI.Dim("0", 0.4), UI.Dim(Ago(r.created), 0.5) },
          sort = { name:lower(), r.qty or 1, r.mats or "", ns.ShortName(r.by):lower(), order * 1e10 - (r.created or 0),
                   #crafters, -(r.created or 0) },
          tooltip = function(tt)
            if r.item then pcall(tt.SetItemByID, tt, r.item) else tt:AddLine(R.DisplayName(r)) end
            tt:AddLine(" ")
            tt:AddLine(("%s wants %d  -  %s"):format(ns.ShortName(r.by), r.qty or 1, R.MATS[r.mats] or ""), 1, 1, 1)
            if r.note then tt:AddLine(r.note, 0.8, 0.8, 0.8, true) end
            if r.claimer then tt:AddLine("Claimed by " .. ns.ShortName(r.claimer), 0.65, 0.7, 1) end
            tt:AddLine(" ")
            tt:AddLine(#crafters > 0 and "Can craft:" or "Nobody in the guild is known to craft this.", 1, 0.82, 0)
            for i, c in ipairs(crafters) do
              if i > 8 then tt:AddLine(("+%d more"):format(#crafters - 8), 0.6, 0.6, 0.6) break end
              tt:AddLine(ns.Icons.Dot(c.online) .. " " .. UI.ClassName(c.key, (ns.roster[c.key] or {}).class))
            end
            tt:AddLine(" ")
            tt:AddLine("Click for options", 0.6, 0.6, 0.6)
          end,
          onClick = function() Actions(r) end,
        }
      end
    end
    info:SetText(("%d open  ·  %d you can craft"):format(open, forMe))
    list:SetItems(rows, showFinished and "No requests yet" or "No open requests. Click New request to ask the guild for something.")
    UI.SetHint("Click a request to claim it, mark it done or whisper. Finished requests clear after 30 minutes; open ones expire after 7 days.")
    if dlg:IsShown() then dlg:Refresh() end
  end

  panel:SetScript("OnHide", function() dlg:Hide() end)
end, "profgroup")

ns.On("REQUESTS_CHANGED", function() if ns.UI.QueueRefresh then ns.UI.QueueRefresh() end end)
