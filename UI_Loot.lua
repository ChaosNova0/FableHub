-- Loot pages (Priorities, Loot history), That's My BIS import dialog and the award window.

local _, ns = ...
local UI, T, P, L = ns.UI, ns.Theme, ns.Plans, ns.Loot

ns.RegisterNavGroup("lootgroup", "Loot", "Interface\\Icons\\INV_Misc_Bag_10_Blue", { "priorities", "loothistory" })

------------------------------------------------------------------------
-- Shift-click item links into our edit boxes
------------------------------------------------------------------------
local linkBoxes = {}
function UI.AcceptLinks(box) table.insert(linkBoxes, box) end
local lastLink, lastLinkAt = nil, 0
local function OnInsertLink(link)
  -- both hooks can fire for one shift-click on clients where one calls the other
  local now = GetTime()
  if link == lastLink and now - lastLinkAt < 0.1 then return end
  lastLink, lastLinkAt = link, now
  for _, box in ipairs(linkBoxes) do
    if box:IsVisible() and box:HasFocus() then box:Insert(link) return end
  end
end
ns.On("LOGIN", function()
  if ChatEdit_InsertLink then pcall(hooksecurefunc, "ChatEdit_InsertLink", OnInsertLink) end
  if ChatFrameUtil and ChatFrameUtil.InsertLink then pcall(hooksecurefunc, ChatFrameUtil, "InsertLink", OnInsertLink) end
end)

local function ListTag(row)
  if not row then return UI.Dim("-", 0.3) end
  if row.type == L.TYPE_PRIO then return UI.Colorize("Prio " .. row.order, 1, 0.82, 0) end
  return UI.Dim("Wish " .. row.order, 0.75)
end

local function ItemTooltip(tt, itemID)
  local ok = pcall(tt.SetItemByID, tt, itemID)
  if not ok then tt:AddLine(L.ItemText(itemID)) end
end

------------------------------------------------------------------------
-- Award window (opens when an officer loots in a raid, or from Loot history)
------------------------------------------------------------------------
local award
local function RaidKeys()
  local out = {}
  local n = (IsInRaid and IsInRaid() and GetNumGroupMembers and GetNumGroupMembers()) or 0
  for i = 1, n do
    local key = ns.Events.ResolveKey((GetRaidRosterInfo(i)))
    if key then out[key] = true end
  end
  return out
end

local function BuildAward()
  award = CreateFrame("Frame", "FableHubAwardFrame", UIParent)
  award:SetSize(640, 360)
  award:SetPoint("CENTER", 0, 80)
  award:SetFrameStrata("HIGH")
  award:SetMovable(true)
  award:EnableMouse(true)
  award:RegisterForDrag("LeftButton")
  award:SetScript("OnDragStart", award.StartMoving)
  award:SetScript("OnDragStop", award.StopMovingOrSizing)
  award:SetClampedToScreen(true)
  T.Fill(award, T.bg)
  T.Border(award, 0.1)
  table.insert(UISpecialFrames, "FableHubAwardFrame")
  award:Hide()

  local title = T.Text(award, 15, 1)
  title:SetPoint("TOPLEFT", 14, -12)
  title:SetText(("|c%sFable|rHub  loot"):format(T.AccentHex()))
  local close = T.CloseButton(award, function() award:Hide() end)
  close:SetPoint("TOPRIGHT", -8, -8)

  award.items = UI.CreateList(award, { { title = "Drops", flex = true } }, 26)
  award.items:SetPoint("TOPLEFT", 12, -42)
  award.items:SetPoint("BOTTOMLEFT", 12, 44)
  award.items:SetWidth(220)
  award.items.sortable = false

  award.cands = UI.CreateList(award, {
    { title = "Player", flex = true },
    { title = "List", width = 60 },
    { title = "Attend.", width = 50, justify = "RIGHT", defaultAsc = false },
    { title = "Loot 30d", width = 56, justify = "RIGHT" },
    { title = "Has it", width = 44, justify = "CENTER" },
  }, 24)
  award.cands:SetPoint("TOPLEFT", 244, -42)
  award.cands:SetPoint("BOTTOMRIGHT", -12, 44)
  award.cands.sortable = false

  award.note = T.Text(award, 11, 0.45)
  award.note:SetPoint("BOTTOMLEFT", 14, 18)
  award.note:SetPoint("RIGHT", award, "RIGHT", -150, 0)
  award.note:SetJustifyH("LEFT")
  award.btn = T.Button(award, "Award", 120, 24)
  award.btn:SetPoint("BOTTOMRIGHT", -12, 12)
  award.btn:SetScript("OnClick", function()
    local item, cand = award.selectedItem, award.selectedCand
    if not item or not cand then return end
    local e = L.Award(item, cand.key, { prio = cand.type == L.TYPE_PRIO and cand.order or nil,
      wish = cand.type == L.TYPE_WISH and cand.order or nil })
    if e then
      award.awarded[item] = cand.key
      award.selectedCand = nil
      award:Refresh()
    end
  end)

  function award:Refresh()
    local ar, ag, ab = T.Accent()
    -- left: dropped items
    local rows = {}
    for _, id in ipairs(self.drops) do
      local prio = L.ItemPriorities(id)
      local top = prio[1] and (" " .. UI.Dim(ns.ShortName(prio[1].key or prio[1].name), 0.5)) or ""
      local label = L.ItemText(id, 16)
      if self.awarded[id] then label = label .. "  " .. UI.Dim("> " .. ns.ShortName(self.awarded[id]), 0.5)
      else label = label .. top end
      if id == self.selectedItem then label = UI.Colorize("> ", ar, ag, ab) .. label end
      rows[#rows + 1] = {
        cols = { label },
        tooltip = function(tt) ItemTooltip(tt, id) end,
        onClick = function() self.selectedItem, self.selectedCand = id, nil; self:Refresh() end,
      }
    end
    self.items:SetItems(rows, "No epic items")

    -- right: candidates for the selected item
    local cands = {}
    local id = self.selectedItem
    if id then
      local prio, wish = L.ItemPriorities(id)
      local raid = RaidKeys()
      local inRaid = next(raid) ~= nil
      local listed = {}
      local function Add(row, kind)
        local key = row.key
        if key then listed[key] = true end
        local attended, total = ns.Events.AttendanceStats(key or "", 30)
        local isSel = self.selectedCand and self.selectedCand.key == key and key ~= nil
        local nameText = key and UI.NameCell(key, (ns.roster[key] or {}).class, raid[key] or ns.IsOnline(key))
          or UI.Dim(row.name .. " (not in guild)", 0.45)
        if isSel then nameText = UI.Colorize("> ", ar, ag, ab) .. nameText end
        if inRaid and key and not raid[key] then nameText = nameText .. UI.Dim("  not in raid", 0.35) end
        cands[#cands + 1] = {
          cols = { nameText, kind == "other" and UI.Dim("-", 0.3) or ListTag(row),
                   total > 0 and (math.floor(attended / total * 100 + 0.5) .. "%") or UI.Dim("-", 0.3),
                   key and tostring(L.CountReceived(key, 30)) or "",
                   (key and L.Received(id, key)) and UI.Colorize("yes", 0.9, 0.5, 0.45) or "" },
          tooltip = key and function(tt)
            tt:AddLine(ns.ShortName(key), ns.ClassColor((ns.roster[key] or {}).class))
            if total > 0 then tt:AddLine(("Attended %d of last %d raid nights"):format(attended, total), 0.8, 0.8, 0.8) end
            tt:AddLine(("%d items in the last 30 days"):format(L.CountReceived(key, 30)), 0.8, 0.8, 0.8)
          end or nil,
          onClick = function()
            if key then self.selectedCand = { key = key, type = row.type, order = row.order }; self:Refresh() end
          end,
        }
      end
      for _, r in ipairs(prio) do Add(r, "prio") end
      for _, r in ipairs(wish) do if not (r.key and listed[r.key]) then Add(r, "wish") end end
      local others = {}
      for key in pairs(raid) do if not listed[key] then others[#others + 1] = key end end
      table.sort(others)
      for _, key in ipairs(others) do Add({ key = key, name = key }, "other") end
    end
    self.cands:SetItems(cands, id and "Nobody has this on a list, and you're not in a raid" or "Pick an item on the left")
    local sel = self.selectedCand
    self.btn:SetSelected(sel ~= nil)
    self.btn:SetText(sel and ("Award to " .. ns.ShortName(sel.key)) or "Award")
    self.note:SetText(L.settings().lootAnnounce and "Awarding records it in loot history and announces it in raid chat. Trade or master loot the item as usual."
      or "Awarding records it in loot history. Trade or master loot the item as usual.")
  end
end

function L.OpenAward(itemIDs)
  if not P.CanEdit() then return ns.Print("Only officers can award loot.") end
  if not award then BuildAward() end
  award.drops = itemIDs
  award.awarded = award.awarded or {}
  award.selectedItem = itemIDs[1]
  award.selectedCand = nil
  award:Show()
  award:Refresh()
end

ns.RegisterEvent("LOOT_OPENED", function()
  if not P.CanEdit() or not (IsInRaid and IsInRaid()) then return end
  local instanceType = GetInstanceInfo and select(2, GetInstanceInfo())
  local ids = {}
  for slot = 1, (GetNumLootItems and GetNumLootItems()) or 0 do
    local link = GetLootSlotLink and GetLootSlotLink(slot)
    local id = L.ItemIdFromLink(link)
    if id then
      local _, _, _, _, quality = GetLootSlotInfo(slot)
      if quality and quality >= L.QUALITY then
        ids[#ids + 1] = id
        if instanceType == "raid" then L.Seen(id, (GetInstanceInfo())) end
      end
    end
  end
  if #ids > 0 then L.OpenAward(ids) end
end)

ns.On("LOOT_CHANGED", function() if award and award:IsShown() then award:Refresh() end end)

------------------------------------------------------------------------
-- Priorities page
------------------------------------------------------------------------
ns.RegisterPanel("priorities", "Priorities", nil, function(panel)
  local mode, filterText = "player", ""
  local selected -- person id in the player view

  local search = T.SearchBox(panel, 200, "Search player or item", function(t) filterText = t; panel:Refresh() end)
  search:SetPoint("TOPLEFT", 0, 0)
  local byPlayer = T.Button(panel, "Players", 74, 22)
  byPlayer:SetPoint("LEFT", search, "RIGHT", 10, 0)
  local byItem = T.Button(panel, "Items", 64, 22)
  byItem:SetPoint("LEFT", byPlayer, "RIGHT", 4, 0)
  local importBtn = T.Button(panel, "Import from That's My BIS", 190, 22)
  importBtn:SetPoint("TOPRIGHT", 0, 0)
  local info = T.Text(panel, 11, 0.45)
  info:SetPoint("TOPLEFT", 0, -30)
  info:SetJustifyH("LEFT")
  info:SetWordWrap(false)

  -- item view
  local itemList = UI.CreateList(panel, {
    { title = "Item", flex = true },
    { title = "Raid", width = 110 },
    { title = "Prio", flex = true },
    { title = "Wish", width = 40, justify = "RIGHT", defaultAsc = false },
    { title = "Has it", width = 110 },
  }, 24)
  itemList:SetPoint("TOPLEFT", 0, -50)
  itemList:SetPoint("BOTTOMRIGHT", 0, 0)

  -- player view: people on the left, reading pane on the right
  local playerView = CreateFrame("Frame", nil, panel)
  playerView:SetPoint("TOPLEFT", 0, -50)
  playerView:SetPoint("BOTTOMRIGHT", 0, 0)
  local people = UI.CreateList(playerView, {
    { title = "Member", flex = true },
    { title = "Prio", width = 32, justify = "RIGHT", defaultAsc = false },
    { title = "Wish", width = 32, justify = "RIGHT", defaultAsc = false },
    { title = "Has", width = 30, justify = "RIGHT", defaultAsc = false },
  }, 24)
  people:SetPoint("TOPLEFT", 0, 0)
  people:SetPoint("BOTTOMLEFT", 0, 0)
  people:SetWidth(250)
  local pDivider = playerView:CreateTexture(nil, "ARTWORK")
  pDivider:SetColorTexture(1, 1, 1, T.border)
  pDivider:SetPoint("TOPLEFT", people, "TOPRIGHT", 10, 0)
  pDivider:SetPoint("BOTTOMLEFT", people, "BOTTOMRIGHT", 10, 0)
  pDivider:SetWidth(1)

  local pane = CreateFrame("Frame", nil, playerView)
  pane:SetPoint("TOPLEFT", 272, 0)
  pane:SetPoint("BOTTOMRIGHT", 0, 0)
  local paneName = T.Text(pane, 17, 1)
  paneName:SetPoint("TOPLEFT", 0, 0)
  local paneSub = T.Text(pane, 12, 0.55)
  paneSub:SetPoint("TOPLEFT", 0, -24)
  local paneAdd = T.Button(pane, "Add item", 150, 22)
  paneAdd:SetPoint("TOPRIGHT", 0, 0)
  local paneList = UI.CreateList(pane, {
    { title = "Item", flex = true },
    { title = "Prio", width = 44, justify = "CENTER" },
    { title = "Wishlist", width = 60, justify = "CENTER" },
    { title = "Has it", width = 70, justify = "RIGHT" },
  }, 24)
  paneList:SetPoint("TOPLEFT", 0, -48)
  paneList:SetPoint("BOTTOMRIGHT", 0, 0)
  paneList.sortCol = 2
  local paneEmpty = T.Text(pane, 13, 0.4)
  paneEmpty:SetPoint("CENTER", 0, 20)

  -- import dialog
  local dlg = CreateFrame("Frame", nil, panel)
  dlg:SetAllPoints()
  dlg:SetFrameLevel(panel:GetFrameLevel() + 30)
  T.Fill(dlg, T.bg)
  dlg:EnableMouse(true)
  dlg:Hide()
  local dTitle = T.Text(dlg, 15, 1)
  dTitle:SetPoint("TOPLEFT", 0, 0)
  dTitle:SetText("Import from That's My BIS")
  local dHelp = T.Text(dlg, 12, 0.6)
  dHelp:SetPoint("TOPLEFT", 0, -24)
  dHelp:SetPoint("RIGHT", dlg, "RIGHT", 0, 0)
  dHelp:SetJustifyH("LEFT")
  dHelp:SetText("On thatsmybis.com, open your guild's Export page and copy the Gargul export. Paste it below (Ctrl+V), then click Import. Everyone in the guild gets the priorities.")
  local box = CreateFrame("Frame", nil, dlg)
  box:SetPoint("TOPLEFT", 0, -62)
  box:SetPoint("BOTTOMRIGHT", 0, 40)
  T.Fill(box, T.input)
  T.Border(box, 0.1)
  local scroll = CreateFrame("ScrollFrame", nil, box)
  scroll:SetPoint("TOPLEFT", 8, -8)
  scroll:SetPoint("BOTTOMRIGHT", -8, 8)
  local edit = CreateFrame("EditBox", nil, scroll)
  edit:SetMultiLine(true)
  edit:SetAutoFocus(false)
  edit:SetMaxLetters(0)
  T.SetFont(edit, 11)
  edit:SetTextColor(1, 1, 1, 0.8)
  edit:SetWidth(600)
  edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  scroll:SetScrollChild(edit)
  scroll:SetScript("OnSizeChanged", function(self, w) edit:SetWidth(math.max(100, (w or 600))) end)
  box:EnableMouse(true)
  box:SetScript("OnMouseDown", function() edit:SetFocus() end)
  local dStatus = T.Text(dlg, 12, 0.7)
  dStatus:SetPoint("BOTTOMLEFT", 0, 12)
  local dImport = T.Button(dlg, "Import", 90, 24)
  dImport:SetPoint("BOTTOMRIGHT", -96, 6)
  local dCancel = T.Button(dlg, "Cancel", 86, 24)
  dCancel:SetPoint("BOTTOMRIGHT", 0, 6)
  dCancel:SetScript("OnClick", function() dlg:Hide(); edit:SetText(""); panel:Refresh() end)
  dImport:SetScript("OnClick", function()
    local tmb, err = L.Import(edit:GetText())
    if tmb then
      dStatus:SetText(UI.Colorize(("Imported %d entries for %d items. Sharing with the guild..."):format(tmb.count,
        (function() local n = 0; for _ in pairs(tmb.items) do n = n + 1 end; return n end)()), 0.4, 0.85, 0.5))
      edit:SetText("")
      C_Timer.After(1.5, function() dlg:Hide(); panel:Refresh() end)
    else
      dStatus:SetText(UI.Colorize(err or "Import failed.", 0.95, 0.45, 0.4))
    end
  end)
  importBtn:SetScript("OnClick", function() dStatus:SetText(""); dlg:Show(); edit:SetFocus() end)

  ----------------------------------------------------------------------
  -- Add an item to someone's prio list or wishlist (officers)
  ----------------------------------------------------------------------
  local addBtn = T.Button(panel, "Add item to a list", 140, 22)
  addBtn:SetPoint("RIGHT", importBtn, "LEFT", -6, 0)

  -- toolbar wraps when narrow; the member list narrows too
  local peopleW = 250
  local bar = UI.Toolbar(panel, {
    before = function(w)
      if w <= 0 then return end
      peopleW = w < 640 and 190 or 250
      people:SetWidth(peopleW)
      pane:SetPoint("TOPLEFT", peopleW + 22, 0)
    end,
  })
  bar:Add(search, { grow = true, min = 140, max = 200 })
  bar:Add(byPlayer, { gap = 10 })
  bar:Add(byItem, { gap = 4 })
  bar:Add(addBtn, { right = true, gap = 12 })
  bar:Add(importBtn, { gap = 6 })
  bar:Add(info, { fill = true })
  bar:Below(itemList, { gap = 0 })
  bar:Below(playerView, { gap = 0 })

  -- reading pane header: the name gives way to the button
  paneName:SetJustifyH("LEFT")
  paneName:SetWordWrap(false)
  local paneBar = UI.Toolbar(pane, { owner = panel })
  paneBar:Add(paneName, { grow = true, min = 80 })
  paneBar:Add(paneAdd, { right = true, gap = 8 })
  paneBar:Below(paneSub, { gap = 2 })
  paneBar:Below(paneList, { gap = 26 })

  local add = CreateFrame("Frame", nil, panel)
  add:SetAllPoints()
  add:SetFrameLevel(panel:GetFrameLevel() + 30)
  T.Fill(add, T.bg)
  add:EnableMouse(true)
  add:Hide()
  local st = { item = nil, member = nil, typ = L.TYPE_PRIO, order = 1, itemText = "", memberText = "" }

  local aTitle = T.Text(add, 15, 1)
  aTitle:SetPoint("TOPLEFT", 0, 0)
  aTitle:SetText("Add an item to a prio list or wishlist")
  local done = T.Button(add, "Done", 80, 22)
  done:SetPoint("TOPRIGHT", 0, 0)

  -- left column: item search, then the item's current entries
  local lItem = T.Text(add, 11, T.section); lItem:SetPoint("TOPLEFT", 0, -34); lItem:SetText("ITEM")
  local itemInput = T.Input(add, 330, "Item name, item ID, or shift-click an item")
  itemInput:SetPoint("TOPLEFT", 0, -50)
  UI.AcceptLinks(itemInput)
  local itemSug = UI.CreateList(add, { { title = "Matches", flex = true } }, 24)
  itemSug:SetPoint("TOPLEFT", 0, -78)
  itemSug:SetSize(330, 22 + 6 * 24)
  itemSug.sortable = false
  local chosen = T.Text(add, 13, 1)
  chosen:SetPoint("TOPLEFT", 0, -84)
  chosen:SetWidth(330)
  chosen:SetJustifyH("LEFT")
  chosen:SetWordWrap(false)
  local searchHelp = T.Text(add, 11, 0.4)
  searchHelp:SetPoint("TOPLEFT", 0, -78 - 22 - 6 * 24 - 6)
  searchHelp:SetWidth(330)
  searchHelp:SetJustifyH("LEFT")
  searchHelp:SetText("Name search covers items FableHub or your game has seen. An item ID or a shift-clicked link always works.")

  local lEntries = T.Text(add, 11, T.section); lEntries:SetPoint("TOPLEFT", 0, -112); lEntries:SetText("ON LISTS FOR THIS ITEM")
  local entries = UI.CreateList(add, {
    { title = "Member", flex = true },
    { title = "List", width = 60 },
    { title = "From", width = 90 },
  }, 22)
  entries:SetPoint("TOPLEFT", 0, -128)
  entries:SetPoint("BOTTOMLEFT", 0, 0)
  entries:SetWidth(330)
  entries.sortable = false

  -- right column: member, list, order
  local RX = 350
  local lMember = T.Text(add, 11, T.section); lMember:SetPoint("TOPLEFT", RX, -34); lMember:SetText("GUILD MEMBER")
  local memberInput = T.Input(add, 220, "Start typing a name")
  memberInput:SetPoint("TOPLEFT", RX, -50)
  local memberSug = UI.CreateList(add, { { title = "Members", flex = true }, { title = "Lvl", width = 26, justify = "RIGHT" } }, 22)
  memberSug:SetPoint("TOPLEFT", RX, -78)
  memberSug:SetSize(220, 20 + 6 * 22)
  memberSug.sortable = false

  local lList = T.Text(add, 11, T.section); lList:SetPoint("TOPLEFT", RX, -84); lList:SetText("LIST")
  local prioBtn = T.Button(add, "Prio", 70, 22); prioBtn:SetPoint("TOPLEFT", RX, -100)
  local wishBtn = T.Button(add, "Wishlist", 80, 22); wishBtn:SetPoint("LEFT", prioBtn, "RIGHT", 4, 0)
  local lOrder = T.Text(add, 11, T.section); lOrder:SetPoint("TOPLEFT", RX, -134); lOrder:SetText("ORDER")
  local orderBox = CreateFrame("Frame", nil, add)
  orderBox:SetSize(110, 22)
  orderBox:SetPoint("TOPLEFT", RX, -150)
  T.Fill(orderBox, T.input)
  T.Border(orderBox, 0.08)
  local oMinus = T.Button(orderBox, "<", 22, 22); oMinus:SetPoint("LEFT")
  local oPlus = T.Button(orderBox, ">", 22, 22); oPlus:SetPoint("RIGHT")
  local oText = T.Text(orderBox, 12, 0.9); oText:SetPoint("CENTER")
  local saveBtn = T.Button(add, "Add to list", 120, 24)
  saveBtn:SetPoint("TOPLEFT", RX, -190)
  local aStatus = T.Text(add, 12, 0.7)
  aStatus:SetPoint("TOPLEFT", RX, -222)
  aStatus:SetWidth(260)
  aStatus:SetJustifyH("LEFT")
  -- narrow window: the left column gives up room so the right one still fits
  UI.TwoColumns(add, {
    maxL = 330, rightW = 220,
    left = { itemInput, itemSug, chosen, searchHelp, entries },
    right = { { lMember, -34 }, { memberInput, -50 }, { memberSug, -78 }, { lList, -84 }, { prioBtn, -100 },
              { lOrder, -134 }, { orderBox, -150 }, { saveBtn, -190 }, { aStatus, -222 } },
    rightFit = { { aStatus, 260 } },
  })

  local function NextOrder()
    local prio, wish = L.ItemPriorities(st.item or 0)
    local n = 0
    for _, r in ipairs(st.typ == L.TYPE_PRIO and prio or wish) do if r.order > n then n = r.order end end
    return n + 1
  end

  function add:Refresh()
    local ar, ag, ab = T.Accent()
    -- item search
    local typing = st.item == nil
    itemSug:SetShown(typing and st.itemText ~= "")
    searchHelp:SetShown(typing)
    chosen:SetShown(not typing)
    lEntries:SetShown(not typing)
    entries:SetShown(not typing)
    if typing and st.itemText ~= "" then
      local rows = {}
      for _, id in ipairs(L.SearchItems(st.itemText, 6)) do
        rows[#rows + 1] = {
          cols = { L.ItemText(id, 16) .. "  " .. UI.Dim("#" .. id, 0.35) },
          tooltip = function(tt) ItemTooltip(tt, id) end,
          onClick = function()
            st.item = id
            st.order = NextOrder()
            itemInput:SetText(L.ItemInfo(id) and L.ItemInfo(id).name or tostring(id))
            itemInput:ClearFocus()
            aStatus:SetText("")
            add:Refresh()
          end,
        }
      end
      itemSug:SetItems(rows, "No match. Try the item ID, or shift-click the item.")
    end
    if not typing then
      chosen:SetText(L.ItemText(st.item, 18) .. "  " .. UI.Dim("#" .. st.item .. "  (click the box above to change)", 0.35))
      local prio, wish = L.ItemPriorities(st.item)
      local rows = {}
      for _, list in ipairs({ prio, wish }) do
        for _, r in ipairs(list) do
          rows[#rows + 1] = {
            cols = { r.key and UI.NameCell(r.key, (ns.roster[r.key] or {}).class, ns.IsOnline(r.key)) or UI.Dim(r.name, 0.5),
                     ListTag(r), r.manual and UI.Colorize("FableHub", ar, ag, ab) or UI.Dim("That's My BIS", 0.5) },
            tooltip = function(tt)
              tt:AddLine(r.key and ns.ShortName(r.key) or r.name)
              if r.manual then tt:AddLine("Added in FableHub.", 0.7, 0.7, 0.7)
              else tt:AddLine("From the That's My BIS import.", 0.7, 0.7, 0.7) end
              tt:AddLine("Right-click to remove.", 0.6, 0.6, 0.6)
            end,
            onClick = function(_, button)
              if button == "RightButton" then L.RemoveEntry(st.item, r.slotKey, r.type) end
            end,
          }
        end
      end
      entries:SetItems(rows, "Nobody has this item on a list yet")
    end

    -- member search
    local pickingMember = st.member == nil and st.memberText ~= ""
    memberSug:SetShown(pickingMember)
    for _, w in ipairs({ lList, prioBtn, wishBtn, lOrder, orderBox, saveBtn, aStatus }) do w:SetShown(not pickingMember) end
    if pickingMember then
      local rows, q = {}, st.memberText:lower()
      for _, m in ipairs(ns.AllMembers()) do
        local nm = ns.ShortName(m.key)
        if nm:lower():find(q, 1, true) then
          local r = m.roster or {}
          rows[#rows + 1] = {
            cols = { UI.NameCell(m.key, r.class or (m.rec and m.rec.class), ns.IsOnline(m.key)), UI.Dim(tostring(r.level or ""), 0.5) },
            sort = { nm:lower() },
            onClick = function()
              st.member = m.key
              memberInput:SetText(nm)
              memberInput:ClearFocus()
              add:Refresh()
            end,
          }
        end
      end
      table.sort(rows, function(a, b) return a.sort[1] < b.sort[1] end)
      while #rows > 6 do table.remove(rows) end
      memberSug:SetItems(rows, "No guild member matches")
    end
    prioBtn:SetSelected(st.typ == L.TYPE_PRIO)
    wishBtn:SetSelected(st.typ == L.TYPE_WISH)
    oText:SetText(tostring(st.order))
    local ready = st.item and st.member
    saveBtn:SetSelected(ready)
    saveBtn:SetText(ready and ("Add for " .. ns.ShortName(st.member)) or "Add to list")
  end

  itemInput:HookScript("OnTextChanged", function(self, userInput)
    local text = self:GetText() or ""
    if st.item and L.ItemInfo(st.item) and text == L.ItemInfo(st.item).name then return end
    if st.item and text == tostring(st.item) then return end
    st.item, st.itemText = nil, text
    -- a pasted/shift-clicked link selects straight away
    local id = text:find("item:", 1, true) and L.ItemIdFromLink(text)
    if id then st.item = id; st.order = NextOrder(); L.ItemInfo(id) end
    add:Refresh()
  end)
  memberInput:HookScript("OnTextChanged", function(self)
    local text = self:GetText() or ""
    if st.member and text == ns.ShortName(st.member) then return end
    st.member, st.memberText = nil, text
    add:Refresh()
  end)
  prioBtn:SetScript("OnClick", function() st.typ = L.TYPE_PRIO; st.order = NextOrder(); add:Refresh() end)
  wishBtn:SetScript("OnClick", function() st.typ = L.TYPE_WISH; st.order = NextOrder(); add:Refresh() end)
  oMinus:SetScript("OnClick", function() st.order = math.max(1, st.order - 1); add:Refresh() end)
  oPlus:SetScript("OnClick", function() st.order = math.min(99, st.order + 1); add:Refresh() end)
  saveBtn:SetScript("OnClick", function()
    if not st.item then aStatus:SetText(UI.Colorize("Pick an item first.", 0.95, 0.45, 0.4)) return end
    if not st.member then aStatus:SetText(UI.Colorize("Pick a guild member.", 0.95, 0.45, 0.4)) return end
    L.SetManual(st.item, st.member, st.typ, st.order)
    aStatus:SetText(UI.Colorize(("Added: %s, %s %d."):format(ns.ShortName(st.member),
      st.typ == L.TYPE_PRIO and "prio" or "wishlist", st.order), 0.4, 0.85, 0.5))
    st.member, st.memberText = nil, ""
    memberInput:SetText("")
    st.order = NextOrder()
    add:Refresh()
  end)
  done:SetScript("OnClick", function() add:Hide(); panel:Refresh() end)
  local function OpenAdd(memberKey)
    st = { item = nil, member = memberKey, typ = L.TYPE_PRIO, order = 1, itemText = "", memberText = "" }
    itemInput:SetText(""); aStatus:SetText("")
    memberInput:SetText(memberKey and ns.ShortName(memberKey) or "")
    st.member = memberKey -- setting the text clears it; put it back
    add:Show()
    add:Refresh()
    itemInput:SetFocus()
  end
  addBtn:SetScript("OnClick", function() OpenAdd(nil) end)
  L.addDialog = add -- for tests
  L.addDialogState = function() return st end

  local function SetMode(m)
    mode = m
    byItem:SetSelected(m == "item")
    byPlayer:SetSelected(m == "player")
    itemList:SetShown(m == "item")
    playerView:SetShown(m == "player")
    panel:Refresh()
  end

  -- everyone with list entries: id -> { key, name, items = { [itemID] = { prio, wish, pManual, wManual } } }
  local function People()
    local out = {}
    for id in pairs(L.ItemsWithEntries()) do
      local prio, wish = L.ItemPriorities(id)
      for _, list in ipairs({ prio, wish }) do
        for _, r in ipairs(list) do
          local pid = r.key or ("?" .. r.name)
          local person = out[pid]
          if not person then
            person = { id = pid, key = r.key, name = r.key and ns.ShortName(r.key) or r.name, items = {}, nPrio = 0, nWish = 0, nHas = 0 }
            out[pid] = person
          end
          local it = person.items[id]
          if not it then it = {}; person.items[id] = it end
          it.slotKey = r.slotKey
          if r.type == L.TYPE_PRIO then it.prio, it.pManual = r.order, r.manual; person.nPrio = person.nPrio + 1
          else it.wish, it.wManual = r.order, r.manual; person.nWish = person.nWish + 1 end
          if r.received and not it.has then it.has = r.received; person.nHas = person.nHas + 1 end
        end
      end
    end
    return out
  end
  byItem:SetScript("OnClick", function() SetMode("item") end)
  byPlayer:SetScript("OnClick", function() SetMode("player") end)

  function panel:Refresh()
    importBtn:SetShown(P.CanEdit())
    addBtn:SetShown(P.CanEdit())
    if add:IsShown() then add:Refresh() end
    local g = L.G()
    local tmb = g and g.tmb
    if tmb then
      local n = 0
      for _ in pairs(tmb.items) do n = n + 1 end
      info:SetText(("From That's My BIS: %d items, %d entries. Imported %s by %s."):format(n, tmb.count or 0,
        UI.TimeAgo(tmb.ts), ns.ShortName(tmb.by)))
    else
      info:SetText(P.CanEdit() and "No priorities yet. Import your That's My BIS export to get started."
        or "No priorities yet. Officers import them from That's My BIS.")
    end

    if mode == "item" then
      local ids = L.ItemsWithEntries()
      for id in pairs(g and g.seen or {}) do ids[id] = true end
      local rows = {}
      for id in pairs(ids) do
        local prio, wish = L.ItemPriorities(id)
        local info_ = L.ItemInfo(id)
        local name = info_ and info_.name or ("item " .. id)
        local has = {}
        for _, e in ipairs(L.ReceivedList(id)) do has[#has + 1] = ns.ShortName(e.to) end
        local prioText = {}
        for i, r in ipairs(prio) do
          if i > 4 then prioText[#prioText + 1] = UI.Dim("+" .. (#prio - 4), 0.45) break end
          local nm = r.key and ns.ShortName(r.key) or r.name
          prioText[#prioText + 1] = r.received and UI.Dim(r.order .. " " .. nm, 0.4) or (UI.Dim(r.order .. " ", 0.5) .. nm)
        end
        local hay = name:lower()
        for _, r in ipairs(prio) do hay = hay .. " " .. r.name end
        for _, r in ipairs(wish) do hay = hay .. " " .. r.name end
        if filterText == "" or hay:find(filterText, 1, true) then
          rows[#rows + 1] = {
            cols = { L.ItemText(id), UI.Dim(g.seen[id] or "", 0.55), table.concat(prioText, ", "),
                     #wish > 0 and tostring(#wish) or UI.Dim("-", 0.3), UI.Dim(table.concat(has, ", "), 0.6) },
            sort = { name:lower(), g.seen[id] or "zzz", prio[1] and prio[1].name or "zzz", #wish, has[1] or "" },
            tooltip = function(tt) ItemTooltip(tt, id) end,
          }
        end
      end
      itemList:SetItems(rows, "No items yet")
      UI.SetHint(P.CanEdit() and "Hover an item for its lists. Use Add item to a list to put any item on someone's prio list or wishlist."
        or "Hover an item for its full prio list and wishlist. These also show on any item tooltip in game.")
    else
      local ar, ag, ab = T.Accent()
      local all = People()
      local rows, found = {}, false
      local q = filterText
      for pid, person in pairs(all) do
        local match = q == "" or person.name:lower():find(q, 1, true)
        if not match then
          for id in pairs(person.items) do
            local inf = L.ItemInfo(id)
            if inf and inf.name:lower():find(q, 1, true) then match = true break end
          end
        end
        if match then
          if pid == selected then found = true end
          local cls = person.key and (ns.roster[person.key] or {}).class
          local nameText = person.key and UI.NameCell(person.key, cls, ns.IsOnline(person.key))
            or UI.Dim(person.name .. "  (not in guild)", 0.45)
          if pid == selected then nameText = UI.Colorize("> ", ar, ag, ab) .. nameText end
          rows[#rows + 1] = {
            cols = { nameText, person.nPrio > 0 and tostring(person.nPrio) or UI.Dim("-", 0.3),
                     person.nWish > 0 and tostring(person.nWish) or UI.Dim("-", 0.3),
                     person.nHas > 0 and UI.Colorize(tostring(person.nHas), 0.4, 0.85, 0.5) or UI.Dim("-", 0.3) },
            sort = { person.name:lower(), person.nPrio, person.nWish, person.nHas },
            onClick = function() selected = pid; panel:Refresh() end,
          }
        end
      end
      if not found then
        table.sort(rows, function(a, b) return a.sort[1] < b.sort[1] end)
        -- pick the first match so the pane isn't empty
        local first
        for pid, person in pairs(all) do
          if (q == "" or person.name:lower():find(q, 1, true)) and (not first or person.name:lower() < all[first].name:lower()) then first = pid end
        end
        if first and first ~= selected then selected = first; return panel:Refresh() end
      end
      people:SetItems(rows, q == "" and "Nobody has items on a list yet" or "No member or item matches")

      local person = selected and all[selected]
      pane:SetShown(person ~= nil)
      if person then
        local key = person.key
        paneName:SetText(key and UI.Colorize(person.name, ns.ClassColor((ns.roster[key] or {}).class)) or person.name)
        local bits = {}
        local r = key and ns.roster[key]
        if r then bits[#bits + 1] = (r.rank or "") .. "  ·  level " .. (r.level or "?") end
        if not key then bits[#bits + 1] = "This name from That's My BIS doesn't match anyone in the guild" end
        if key then
          local att, total = ns.Events.AttendanceStats(key, 30)
          if total > 0 then bits[#bits + 1] = ("attended %d of %d raids"):format(att, total) end
          bits[#bits + 1] = ("%d items in the last 30 days"):format(L.CountReceived(key, 30))
        end
        paneSub:SetText(table.concat(bits, "  ·  "))
        paneAdd:SetShown(P.CanEdit() and key ~= nil)
        paneAdd:SetText("Add item for " .. person.name)
        paneAdd:SetScript("OnClick", function() OpenAdd(key) end)

        local items = {}
        for id, it in pairs(person.items) do
          local inf = L.ItemInfo(id)
          local iname = inf and inf.name or ""
          local function Cell(order, manual, isPrio)
            if not order then return UI.Dim("-", 0.3) end
            local t = isPrio and UI.Colorize(tostring(order), 1, 0.82, 0) or tostring(order)
            if manual then t = t .. UI.Colorize("*", ar, ag, ab) end
            return t
          end
          items[#items + 1] = {
            cols = { L.ItemText(id), Cell(it.prio, it.pManual, true), Cell(it.wish, it.wManual, false),
                     it.has and UI.Colorize(date("%d %b", it.has.at), 0.4, 0.85, 0.5) or UI.Dim("-", 0.3) },
            sort = { iname:lower(), it.prio or 999, it.wish or 999, it.has and it.has.at or 0 },
            tooltip = function(tt)
              ItemTooltip(tt, id)
              if it.pManual or it.wManual or P.CanEdit() then tt:AddLine(" ") end
              if it.pManual or it.wManual then tt:AddLine("* added in FableHub", 0.6, 0.6, 0.6) end
              if P.CanEdit() then tt:AddLine("Right-click to remove it from a list.", 0.6, 0.6, 0.6) end
            end,
            onClick = function(_, button)
              if button ~= "RightButton" or not P.CanEdit() then return end
              local menu = {}
              local who = person.name
              if it.prio then
                menu[#menu + 1] = { text = UI.Colorize("Remove from " .. who .. "'s prio list", 0.95, 0.45, 0.4),
                  onClick = function() L.RemoveEntry(id, it.slotKey, L.TYPE_PRIO) end }
              end
              if it.wish then
                menu[#menu + 1] = { text = UI.Colorize("Remove from " .. who .. "'s wishlist", 0.95, 0.45, 0.4),
                  onClick = function() L.RemoveEntry(id, it.slotKey, L.TYPE_WISH) end }
              end
              if #menu > 0 then T.Menu(paneList, menu, 260) end
            end,
          }
        end
        paneList:SetItems(items, "Nothing on their lists")
      end
      UI.SetHint(P.CanEdit() and "Pick a member to see their items. * = added in FableHub. Right-click an item to remove it from a list."
        or "Pick a member to see their prio list and wishlist.")
    end
  end

  panel:SetScript("OnHide", function() dlg:Hide(); add:Hide() end)
  SetMode("player")
end, "lootgroup")

------------------------------------------------------------------------
-- Loot history page
------------------------------------------------------------------------
ns.RegisterPanel("loothistory", "Loot history", nil, function(panel)
  local filterText, recentOnly = "", false

  local search = T.SearchBox(panel, 200, "Search item or player", function(t) filterText = t; panel:Refresh() end)
  search:SetPoint("TOPLEFT", 0, 0)
  local recent = T.Toggle(panel, "Last 30 days", function(v) recentOnly = v; panel:Refresh() end)
  recent:SetPoint("LEFT", search, "RIGHT", 14, 0)
  local announce = T.Toggle(panel, "Announce awards", function(v) FableHubDB.settings.lootAnnounce = v end)
  announce:SetPoint("TOPRIGHT", 0, 0)

  -- officer: add an entry / award an item
  local addRow = CreateFrame("Frame", nil, panel)
  addRow:SetPoint("TOPLEFT", 0, -30)
  addRow:SetPoint("TOPRIGHT", 0, -30)
  addRow:SetHeight(22)
  local itemBox = T.Input(addRow, 230, "Shift-click an item, or type its ID")
  itemBox:SetPoint("LEFT")
  UI.AcceptLinks(itemBox)
  local playerBox = T.Input(addRow, 140, "Player name")
  playerBox:SetPoint("LEFT", itemBox, "RIGHT", 6, 0)
  local addBtn = T.Button(addRow, "Add to history", 110, 22)
  addBtn:SetPoint("LEFT", playerBox, "RIGHT", 6, 0)
  local awardBtn = T.Button(addRow, "Open award window", 140, 22)
  awardBtn:SetPoint("LEFT", addBtn, "RIGHT", 6, 0)
  local addStatus = T.Text(panel, 11, 0.6)
  addStatus:SetWordWrap(false)
  local function SetAddStatus(text)
    addStatus:SetText(text)
    UI.LayoutToolbars(panel)
  end

  addBtn:SetScript("OnClick", function()
    local id = L.ItemIdFromLink(itemBox:GetText())
    local key = ns.Events.ResolveKey(playerBox:GetText())
    if not id then SetAddStatus(UI.Colorize("Shift-click an item into the first box.", 0.95, 0.45, 0.4)) return end
    if not key then SetAddStatus(UI.Colorize("No guild member called that.", 0.95, 0.45, 0.4)) return end
    L.Record(id, key, { note = "added by hand" })
    itemBox:SetText(""); playerBox:SetText("")
    SetAddStatus("Added.")
  end)
  awardBtn:SetScript("OnClick", function()
    local id = L.ItemIdFromLink(itemBox:GetText())
    if not id then SetAddStatus(UI.Colorize("Shift-click an item into the first box.", 0.95, 0.45, 0.4)) return end
    L.OpenAward({ id })
  end)

  local list = UI.CreateList(panel, {
    { title = "When", width = 80 },
    { title = "Item", flex = true },
    { title = "Player", width = 150 },
    { title = "Raid", width = 110 },
    { title = "Prio", width = 36, justify = "RIGHT" },
  }, 24)
  list.sortCol, list.sortAsc = 1, false
  list:SetPoint("TOPLEFT", 0, -34)
  list:SetPoint("BOTTOMRIGHT", 0, 0)

  -- toolbar: search row, then the officers' add row; wraps when narrow
  local function Officer() return addRow:IsShown() end
  local bar = UI.Toolbar(panel)
  bar:Add(search, { grow = true, min = 140, max = 200 })
  bar:Add(recent, { gap = 14 })
  bar:Add(announce, { right = true, gap = 14 })
  bar:Add(itemBox, { newRow = true, grow = true, min = 150, max = 230, visible = Officer })
  bar:Add(playerBox, { gap = 6, w = 140, visible = Officer })
  bar:Add(addBtn, { gap = 6, visible = Officer })
  bar:Add(awardBtn, { gap = 6, visible = Officer })
  bar:Add(addStatus, { gap = 10, visible = function() return Officer() and (addStatus:GetText() or "") ~= "" end })
  bar:Below(list)

  function panel:Refresh()
    local canEdit = P.CanEdit()
    addRow:SetShown(canEdit)
    addStatus:SetShown(canEdit)
    announce:SetShown(canEdit)
    announce:SetChecked(L.settings().lootAnnounce)

    local rows = {}
    local cutoff = ns.Now() - 30 * 86400
    for _, e in ipairs(L.Entries()) do
      local info_ = L.ItemInfo(e.item)
      local iname = info_ and info_.name or ""
      local nm = ns.ShortName(e.to)
      if (not recentOnly or (e.at or 0) >= cutoff)
        and (filterText == "" or iname:lower():find(filterText, 1, true) or nm:lower():find(filterText, 1, true)) then
        rows[#rows + 1] = {
          cols = { UI.Dim(date("%d %b", e.at), 0.6), L.ItemText(e.item), UI.NameCell(e.to, (ns.roster[e.to] or {}).class, ns.IsOnline(e.to)),
                   UI.Dim(e.inst or "", 0.55), e.prio and tostring(e.prio) or UI.Dim("-", 0.3) },
          sort = { e.at or 0, iname:lower(), nm:lower(), e.inst or "", e.prio or 99 },
          tooltip = function(tt)
            ItemTooltip(tt, e.item)
            tt:AddLine(" ")
            tt:AddLine(("Received by %s on %s"):format(nm, date("%d %b %Y %H:%M", e.at)), 0.8, 0.8, 0.8)
            if e.note then tt:AddLine(e.note, 0.7, 0.7, 0.7) end
            tt:AddLine("Recorded by " .. ns.ShortName(e.by), 0.6, 0.6, 0.6)
            if canEdit then tt:AddLine("Right-click to delete", 0.6, 0.6, 0.6) end
          end,
          onClick = function(_, button)
            if button == "RightButton" and canEdit then
              T.Menu(list, { { text = UI.Colorize("Delete this entry", 0.95, 0.45, 0.4), onClick = function() L.Delete(e) end } }, 160)
            end
          end,
        }
      end
    end
    list:SetItems(rows, "No loot recorded yet. Epic drops are recorded automatically while an officer with FableHub is in the raid.")
    UI.SetHint(canEdit and "Shift-click an item into the box to add an entry or open the award window." or "Everything awarded in raids, newest first.")
  end
end, "lootgroup")

ns.On("LOOT_CHANGED", function() if ns.UI.QueueRefresh then ns.UI.QueueRefresh() end end)
