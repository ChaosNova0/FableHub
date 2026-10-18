-- Guild Bank: the bank's tabs (as last seen by a guildmate at the banker), its
-- gold, the logs, and item requests. Only tabs your rank may view appear.

local _, ns = ...
local UI = ns.UI

local COLS, ROWS, CELL, GAP = 14, 7, 32, 3

local function ItemIcon(id)
  if C_Item and C_Item.GetItemIconByID then
    local ok, icon = pcall(C_Item.GetItemIconByID, id)
    if ok and icon then return icon end
  end
  local info = ns.Loot and ns.Loot.ItemInfo(id)
  return (info and info.icon) or "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function ItemLabel(id)
  local info = ns.Loot and ns.Loot.ItemInfo(id)
  return (info and info.link) or ("item " .. id)
end

local LOG_TEXT = { d = "deposited", w = "withdrew", m = "moved", r = "repaired with", b = "bought a tab with",
                   gd = "deposited", gw = "withdrew", gr = "repaired with" }

ns.RegisterNavGroup("bankgroup", "Guild Bank", "Interface\\Icons\\INV_Misc_Bag_10_Green", { "guildbank", "bankrequests" })

ns.RegisterPanel("guildbank", "Contents", nil, function(panel)
  local T, B, P = ns.Theme, ns.GuildBank, ns.Plans
  local view, selectedTab, filterText = "items", nil, ""

  -- top bar: views, search, gold
  local viewBtns = {}
  local function ViewButton(id, text, x)
    local b = T.Button(panel, text, 96, 22)
    b:SetPoint("TOPLEFT", x, 0)
    b:SetScript("OnClick", function() view = id; panel:Refresh() end)
    viewBtns[id] = b
    return b
  end
  ViewButton("items", "Items", 0)
  ViewButton("log", "Log", 100)
  local search = T.SearchBox(panel, 200, "Search all tabs", function(t) filterText = t; panel:Refresh() end)
  search:SetPoint("TOPLEFT", 212, 0)
  local gold = T.Text(panel, 13, 0.9)
  local info = T.Text(panel, 11, 0.45)
  info:SetJustifyH("LEFT")
  info:SetWordWrap(false) -- one line, so it never runs into the list below

  -- left: tab list
  local tabList = UI.CreateList(panel, { { title = "Tab", flex = true }, { title = "Items", width = 40, justify = "RIGHT" } },
    24, nil)
  tabList:SetPoint("TOPLEFT", 0, -50)
  tabList:SetPoint("BOTTOMLEFT", 0, 0)
  tabList:SetWidth(170)
  tabList.sortable = false
  tabList.emptyText:SetWidth(150)

  -- right: the slot grid, or a list (search results, log, requests)
  local right = CreateFrame("Frame", nil, panel)
  right:SetPoint("TOPLEFT", tabList, "TOPRIGHT", 14, 0)
  right:SetPoint("BOTTOMRIGHT", 0, 0)

  -- toolbar wraps when narrow; the tab list narrows too
  local bar = UI.Toolbar(panel, {
    before = function(w) if w > 0 then tabList:SetWidth(w < 600 and 140 or 170) end end,
  })
  bar:Add(viewBtns.items)
  bar:Add(viewBtns.log, { gap = 4 })
  bar:Add(search, { gap = 12, grow = true, min = 120, max = 200 })
  bar:Add(gold, { right = true, gap = 12 })
  bar:Add(info, { fill = true })
  bar:Below(tabList, { gap = 4 })

  local grid = CreateFrame("Frame", nil, right)
  grid:SetPoint("TOPLEFT", 0, -22)
  grid:SetSize(COLS * (CELL + GAP), ROWS * (CELL + GAP)) -- resized to fit by FitGrid
  local gridTitle = T.Text(right, 12, 0.8)
  gridTitle:SetPoint("TOPLEFT", 0, -2)
  local cells = {}

  local reqPop
  local function OpenRequest(id)
    if not P.CanEdit("bankask") then
      return ns.Print("Your guild rank can't ask for guild bank items (the Guild Master chooses this).")
    end
    if not reqPop then
      reqPop = T.Popup(270, 112)
      reqPop.title = T.Text(reqPop, 12, 0.85)
      reqPop.title:SetPoint("TOPLEFT", 10, -10)
      reqPop.title:SetPoint("RIGHT", -10, 0)
      reqPop.title:SetJustifyH("LEFT")
      reqPop.title:SetWordWrap(false)
      reqPop.qty = T.Input(reqPop, 60, "How many")
      reqPop.qty:SetPoint("TOPLEFT", 10, -32)
      reqPop.note = T.Input(reqPop, 180, "Note (optional)")
      reqPop.note:SetPoint("LEFT", reqPop.qty, "RIGHT", 8, 0)
      local go = T.Button(reqPop, "Request", 90, 22)
      go:SetPoint("BOTTOMRIGHT", -10, 10)
      local cancel = T.Button(reqPop, "Cancel", 70, 22)
      cancel:SetPoint("RIGHT", go, "LEFT", -6, 0)
      cancel:SetScript("OnClick", function() reqPop:Close() end)
      go:SetScript("OnClick", function()
        reqPop.qty:ClearFocus(); reqPop.note:ClearFocus()
        local r = B.Request(reqPop.item, tonumber(reqPop.qty:GetText()) or 1, reqPop.note:GetText())
        reqPop:Close()
        if r then ns.Print(("Asked the guild bank for %s x%d."):format(ItemLabel(r.item), r.qty)) end
        UI.ShowPanel("bankrequests")
      end)
      reqPop.qty:SetScript("OnEnterPressed", function() go:Click() end)
      reqPop.note:SetScript("OnEnterPressed", function() go:Click() end)
    end
    reqPop.item = id
    reqPop.title:SetText("Request " .. ItemLabel(id))
    reqPop.qty:SetText("1")
    reqPop.note:SetText("")
    reqPop:Open()
    reqPop.qty:SetFocus()
  end
  panel.OpenRequest = OpenRequest

  for i = 1, COLS * ROWS do
    local b = CreateFrame("Button", nil, grid)
    b:SetSize(CELL, CELL)
    b.col, b.row = (i - 1) % COLS, math.floor((i - 1) / COLS)
    b:SetPoint("TOPLEFT", b.col * (CELL + GAP), -b.row * (CELL + GAP))
    T.Fill(b, { 1, 1, 1, 0.04 })
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetPoint("TOPLEFT", 1, -1)
    b.icon:SetPoint("BOTTOMRIGHT", -1, 1)
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    b.border = b:CreateTexture(nil, "OVERLAY")
    b.border:SetAllPoints()
    b.border:SetColorTexture(1, 1, 1, 0)
    b.count = T.Text(b, 11, 1, "OVERLAY")
    b.count:SetPoint("BOTTOMRIGHT", -2, 2)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnEnter", function(self)
      if not self.it then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      if GameTooltip.SetHyperlink then pcall(GameTooltip.SetHyperlink, GameTooltip, "item:" .. (self.it.s or self.it.id)) end
      GameTooltip:AddLine(" ")
      GameTooltip:AddLine("Right-click to request it. Shift-click to link it.", 0.6, 0.6, 0.6)
      GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:SetScript("OnClick", function(self, button)
      if not self.it then return end
      if button == "RightButton" then OpenRequest(self.it.id)
      elseif IsShiftKeyDown and IsShiftKeyDown() then
        local info_ = ns.Loot and ns.Loot.ItemInfo(self.it.id)
        if info_ and info_.link then UI.InsertLink(info_.link) end
      end
    end)
    cells[i] = b
  end

  -- slots shrink or grow to fit the space beside the tab list (16-36 px)
  local cellSize
  local function FitGrid()
    local w = (right:GetWidth() or 0) - 2
    local h = (right:GetHeight() or 0) - 24
    if w <= 0 or h <= 0 then return end
    local size = math.floor(math.min((w - (COLS - 1) * GAP) / COLS, (h - (ROWS - 1) * GAP) / ROWS))
    size = math.max(16, math.min(36, size))
    if size == cellSize then return end
    cellSize = size
    grid:SetSize(COLS * (size + GAP) - GAP, ROWS * (size + GAP) - GAP)
    for _, c in ipairs(cells) do
      c:SetSize(size, size)
      c:ClearAllPoints()
      c:SetPoint("TOPLEFT", c.col * (size + GAP), -c.row * (size + GAP))
    end
  end
  right:SetScript("OnSizeChanged", FitGrid)

  local list = UI.CreateList(right, {
    { title = "", flex = true }, { title = "", width = 90 }, { title = "", width = 110 },
    { title = "", width = 60, justify = "RIGHT" }, { title = "", width = 100 }, { title = "", width = 90, justify = "RIGHT" },
  }, 22)
  list:SetPoint("TOPLEFT", 0, 0)
  list:SetPoint("BOTTOMRIGHT", 0, 0)

  local function SetColumns(titles)
    for i, h in ipairs(list.headers) do list.columns[i].title = titles[i] or "" end
  end

  ----------------------------------------------------------------------
  local function DrawGrid(tab)
    local b = B.G()
    local t = b and b.tabs[tab]
    gridTitle:SetText(t and (t.name .. UI.Dim(("   updated %s by %s"):format(UI.TimeAgo(t.ts), ns.ShortName(t.by)), 0.5)) or "")
    for slot, c in ipairs(cells) do
      local it = t and t.items[slot]
      c.it = it
      if it then
        c.icon:SetTexture(ItemIcon(it.id))
        c.icon:Show()
        c.count:SetText((it.n or 1) > 1 and tostring(it.n) or "")
        local inf = ns.Loot and ns.Loot.ItemInfo(it.id)
        local q = inf and inf.quality
        local qc = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
        if qc and q >= 2 then c.border:SetColorTexture(qc.r, qc.g, qc.b, 0.18) else c.border:SetColorTexture(1, 1, 1, 0) end
      else
        c.icon:Hide()
        c.count:SetText("")
        c.border:SetColorTexture(1, 1, 1, 0)
      end
    end
  end

  local function SearchResults()
    local q = filterText:lower()
    local items = {}
    local tabs = {}
    for _, v in ipairs(B.Tabs()) do tabs[v.tab] = v.data.name end
    for id, tot in pairs(B.Totals()) do
      local inf = ns.Loot and ns.Loot.ItemInfo(id)
      local name = inf and inf.name or ""
      if name:lower():find(q, 1, true) or tostring(id) == q then
        local where = {}
        for tab, n in pairs(tot.tabs) do where[#where + 1] = (tabs[tab] or ("Tab " .. tab)) .. " (" .. n .. ")" end
        table.sort(where)
        local itemID = id
        items[#items + 1] = {
          cols = { ItemLabel(id), "", "", tostring(tot.n), table.concat(where, ", "), "" },
          sort = { name:lower(), "", "", tot.n, "", "" },
          tooltip = function(tt)
            if tt.SetHyperlink then pcall(tt.SetHyperlink, tt, "item:" .. (tot.s or itemID)) end
            tt:AddLine(" ")
            tt:AddLine("Right-click to request it.", 0.6, 0.6, 0.6)
          end,
          onClick = function(_, button) if button == "RightButton" then OpenRequest(itemID) end end,
        }
      end
    end
    SetColumns({ "Item", "", "", "Count", "Where" })
    list:SetItems(items, "Nothing in the guild bank matches")
  end

  local function Log(tab)
    local b = B.G()
    local tabs = {}
    for _, v in ipairs(B.Tabs()) do tabs[v.tab] = v.data.name end
    local items = {}
    local function Add(t, l)
      for _, e in ipairs(l.entries or {}) do
        local what = (t == 0) and B.FormatMoney(e.n) or (ItemLabel(e.id) .. (e.n > 1 and UI.Dim(" x" .. e.n, 0.6) or ""))
        local where = t == 0 and "Gold" or (tabs[t] or ("Tab " .. t))
        if e.k == "m" and e.to and e.to > 0 then where = where .. " > " .. (tabs[e.to] or ("Tab " .. e.to)) end
        items[#items + 1] = {
          cols = { what, UI.Dim(UI.TimeAgo(e.at), 0.6), ns.ShortName(e.who or "?"), "", UI.Dim(LOG_TEXT[e.k] or e.k, 0.7), UI.Dim(where, 0.6) },
          sort = { "", -(e.at or 0) },
        }
      end
    end
    for t, l in pairs(b and b.logs or {}) do
      if (tab == nil or tab == t) and B.CanView(ns.MyKey(), t) then Add(t, l) end
    end
    table.sort(items, function(a, c) return a.sort[2] < c.sort[2] end)
    list.sortable = false
    SetColumns({ "What", "When", "Who", "", "Did", "Tab" })
    list:SetItems(items, "No log yet. It's read when someone opens the guild bank.")
  end

  ----------------------------------------------------------------------
  function panel:Refresh()
    local b = B.G()
    local ar, ag, ab = T.Accent()
    for id, btn in pairs(viewBtns) do
      local label = ({ items = "Items", log = "Log" })[id]
      btn:SetText(id == view and UI.Colorize(label, ar, ag, ab) or label)
    end
    local m = b and b.money
    gold:SetText(m and B.FormatMoney(m.v) or UI.Dim("gold not seen yet", 0.4))

    local tabs = B.Tabs()
    -- left list: tabs (plus "All" and "Gold" in the log view)
    local items = {}
    if view == "log" then
      items[#items + 1] = { cols = { "All", "" }, key = "all" }
      items[#items + 1] = { cols = { "Gold", "" }, key = 0 }
    end
    if selectedTab == nil and view == "items" and tabs[1] then selectedTab = tabs[1].tab end
    local newest
    for _, v in ipairs(tabs) do
      local n = 0
      for _ in pairs(v.data.items or {}) do n = n + 1 end
      items[#items + 1] = { cols = { v.data.name or ("Tab " .. v.tab), UI.Dim(tostring(n), 0.6) }, key = v.tab }
      if not newest or (v.data.ts or 0) > (newest.ts or 0) then newest = v.data end
    end
    for _, it in ipairs(items) do
      local sel = (it.key == selectedTab) or (it.key == "all" and selectedTab == nil)
      if sel then it.cols[1] = UI.Colorize("> ", ar, ag, ab) .. it.cols[1] end
      local key = it.key
      it.onClick = function()
        selectedTab = key ~= "all" and key or nil
        panel:Refresh()
      end
    end
    tabList:SetItems(items, m and "No tabs you can view yet" or "Nobody has opened the guild bank with FableHub yet")

    if newest then
      info:SetText(("Last read %s by %s  ·  opening the guild bank in game updates it")
        :format(UI.TimeAgo(newest.ts), ns.ShortName(newest.by)))
    elseif m then
      info:SetText(("Read %s by %s  ·  no tabs your rank can view (or none bought yet)")
        :format(UI.TimeAgo(m.ts), ns.ShortName(m.by)))
    else
      info:SetText("Open the guild bank in game once and FableHub shares it with the guild")
    end
    UI.SetHint(view == "items" and "Hover an item for details. Right-click to request it from the bank."
      or "The log shows the last entries the game keeps for each tab.")

    local showGrid = view == "items" and filterText == "" and tabs[1] ~= nil
    grid:SetShown(showGrid)
    gridTitle:SetShown(showGrid)
    list:SetShown(not showGrid)
    if showGrid then
      FitGrid()
      if selectedTab and not (b and b.tabs[selectedTab]) then selectedTab = tabs[1] and tabs[1].tab end
      DrawGrid(selectedTab)
    elseif view == "items" and filterText == "" then
      SetColumns({})
      list:SetItems({}, "")
    elseif view == "items" then
      list.sortable = true
      SearchResults()
    else
      Log(selectedTab)
    end
  end
end, "bankgroup")

ns.RegisterPanel("bankrequests", "Requests", nil, function(panel)
  local T, B, P = ns.Theme, ns.GuildBank, ns.Plans
  local info = T.Text(panel, 11, 0.45)
  info:SetPoint("TOPLEFT", 0, -4)
  local list = UI.CreateList(panel, {
    { title = "Item", flex = true }, { title = "Asked", width = 90 }, { title = "By", width = 110 },
    { title = "In bank", width = 60, justify = "RIGHT" }, { title = "Note", width = 140 }, { title = "Status", width = 90, justify = "RIGHT" },
  }, 22)
  list:SetPoint("TOPLEFT", 0, -26)
  list:SetPoint("BOTTOMRIGHT", 0, 0)
  list.sortable = false

  local function Requests()
    local officer = P.CanEdit("bankreq")
    local items = {}
    for _, r in ipairs(B.Requests()) do
      local req = r
      local st = B.STATUS[r.status] or r.status
      if r.status == "open" then st = UI.Colorize(st, 0.95, 0.78, 0.35)
      elseif r.status == "given" then st = UI.Colorize(st, 0.4, 0.85, 0.5)
      else st = UI.Dim(st, 0.5) end
      local have = B.Totals()[r.item]
      items[#items + 1] = {
        cols = { ItemLabel(r.item) .. UI.Dim(" x" .. r.qty, 0.7), UI.Dim(UI.TimeAgo(r.created), 0.6), ns.ShortName(r.by),
                 have and tostring(have.n) or UI.Dim("0", 0.4), UI.Dim(r.note or "", 0.7), st },
        sort = { r.status == "open" and 0 or 1, -(r.created or 0) },
        tooltip = function(tt)
          tt:AddLine(ItemLabel(req.item) .. " x" .. req.qty, 1, 1, 1)
          tt:AddLine("Asked by " .. ns.ShortName(req.by) .. ", " .. UI.TimeAgo(req.created), 0.7, 0.7, 0.7)
          if req.note then tt:AddLine(req.note, 1, 1, 1, true) end
          if req.actor and req.actor ~= req.by then tt:AddLine(B.STATUS[req.status] .. " by " .. ns.ShortName(req.actor), 0.6, 0.6, 0.6) end
          tt:AddLine(" ")
          tt:AddLine(officer and "Right-click to hand over or decline." or (req.by == ns.MyKey() and "Right-click to cancel." or ""), 0.6, 0.6, 0.6)
        end,
        onClick = function(_, button)
          if button ~= "RightButton" then return end
          local menu = {}
          if officer and req.status == "open" then
            menu[#menu + 1] = { text = "Handed over", onClick = function() B.SetStatus(req, "given"); panel:Refresh() end }
            menu[#menu + 1] = { text = "Decline", onClick = function() B.SetStatus(req, "declined"); panel:Refresh() end }
          end
          if req.by == ns.MyKey() and req.status == "open" then
            menu[#menu + 1] = { text = "Cancel my request", onClick = function() B.SetStatus(req, "cancelled"); panel:Refresh() end }
          end
          if req.by ~= ns.MyKey() then menu[#menu + 1] = { text = "Whisper", onClick = function() UI.Whisper(req.by) end } end
          if #menu > 0 then T.Menu(list, menu, 170) end
        end,
      }
    end
    table.sort(items, function(a, c)
      if a.sort[1] ~= c.sort[1] then return a.sort[1] < c.sort[1] end
      return a.sort[2] < c.sort[2]
    end)
    list:SetItems(items, "No requests. Right-click an item on the Contents page to ask for it.")
  end


  function panel:Refresh()
    local n = B.OpenCount()
    info:SetText(n > 0 and ("%d open request%s"):format(n, n == 1 and "" or "s") or "No open requests")
    UI.SetHint(P.CanEdit("bankreq") and "Right-click a request to hand it over or decline it."
      or "Right-click your request to cancel it. To ask for something, right-click it on the Contents page.")
    Requests()
  end
end, "bankgroup")

ns.On("BANK_CHANGED", function() if UI.QueueRefresh then UI.QueueRefresh() end end)
