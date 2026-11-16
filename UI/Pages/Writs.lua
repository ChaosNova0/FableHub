-- Craftsman's Writs page (Professions > Craftsman's Writs): every writ on
-- Forever, who to hand it in to and who in the guild can craft it. Writs in
-- your quest log are marked Mine, with a shopping list above the list.
--
-- Page state: the profession and level picked (reset on /reload); the two
-- toggles are saved options (writsMineOnly, writsGuildOnly).

local _, ns = ...
local UI, T, W = ns.UI, ns.Theme, ns.Writs

local GREEN, GOLD = { 0.4, 0.85, 0.5 }, { 1, 0.82, 0 }
local SHOP_ROWS = 6
local AH_CLOSED = "Open the auction house first, then click Search AH."

-- crafter names for the list: up to `limit`, class colour when online, then "+N"
local function CrafterCell(crafters, limit)
  if not crafters or #crafters == 0 then return UI.Dim("Nobody yet", 0.4) end
  local out = {}
  for i, c in ipairs(crafters) do
    if i > limit then out[#out + 1] = UI.Dim("+" .. (#crafters - limit), 0.45) break end
    local name = ns.ShortName(c.key)
    out[#out + 1] = c.online and UI.Colorize(name, ns.ClassColor(c.class)) or UI.Dim(name, 0.45)
  end
  return table.concat(out, ", ")
end

local function ItemLink(item)
  local info = ns.Loot.ItemInfo(item)
  return info and info.link
end

ns.RegisterPanel("writs", "Craftsman's Writs", nil, function(panel)
  local prof, level = 0, "all" -- 0 = all professions
  local filterText = ""

  local search = T.SearchBox(panel, 200, "Search writs or items, or shift-click one", function(t) filterText = t; panel:Refresh() end)
  UI.AcceptLinks(search)
  local mineToggle = T.Toggle(panel, "Only mine", function(v) ns.SetOption("writsMineOnly", v); panel:Refresh() end)
  mineToggle:SetChecked(ns.Option("writsMineOnly"))
  local guildToggle = T.Toggle(panel, "Only ones the guild can craft", function(v) ns.SetOption("writsGuildOnly", v); panel:Refresh() end)
  guildToggle:SetChecked(ns.Option("writsGuildOnly"))
  local info = T.Text(panel, 11, 0.45)

  -- profession and level chips
  local profLabel = T.Text(panel, 11, T.section); profLabel:SetText("PROFESSION")
  local profBtns = {}
  local function FitButton(b)
    local fs = b:GetFontString()
    b:SetWidth(math.max(40, math.floor((fs and fs:GetStringWidth() or 40) + 20)))
  end
  local profChoices = { { 0, "All" } }
  for _, p in ipairs(ns.WRIT_PROFS or {}) do profChoices[#profChoices + 1] = p end
  for i, p in ipairs(profChoices) do
    local b = T.Button(panel, p[2], 60, 22)
    FitButton(b)
    b:SetScript("OnClick", function() prof = p[1]; panel:Refresh() end)
    profBtns[i] = { btn = b, value = p[1] }
  end
  local levelLabel = T.Text(panel, 11, T.section); levelLabel:SetText("LEVEL")
  local levelBtns = {}
  local levelChoices = { { "all", "All" } }
  for _, lv in ipairs(ns.WRIT_LEVEL_ORDER or {}) do levelChoices[#levelChoices + 1] = { lv, ns.WRIT_LEVELS[lv].name } end
  for i, l in ipairs(levelChoices) do
    local b = T.Button(panel, l[2], 60, 22)
    FitButton(b)
    b:SetScript("OnClick", function() level = l[1]; panel:Refresh() end)
    levelBtns[i] = { btn = b, value = l[1] }
  end

  ----------------------------------------------------------------------
  -- shopping list (only while you hold a writ)
  ----------------------------------------------------------------------
  local shop = CreateFrame("Frame", nil, panel)
  shop:SetHeight(40)
  T.Fill(shop, { 0, 0, 0, 0.18 })
  T.Border(shop, 0.08)
  shop:Hide()
  local shopTitle = T.Text(shop, 11, T.section)
  shopTitle:SetPoint("TOPLEFT", 10, -8)
  shopTitle:SetText("SHOPPING LIST FOR YOUR WRITS")
  local shopRows = {}
  for i = 1, SHOP_ROWS do
    local r = CreateFrame("Button", nil, shop)
    r:SetHeight(22)
    r:SetPoint("TOPLEFT", 8, -24 - (i - 1) * 22)
    r:SetPoint("TOPRIGHT", -8, -24 - (i - 1) * 22)
    local hl = r:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.04)
    r.btn = T.Button(r, "Search AH", 84, 20)
    r.btn.shopRow = r
    r.btn:SetPoint("RIGHT", 0, 0)
    r.count = T.Text(r, 12, 0.85)
    r.count:SetPoint("RIGHT", r.btn, "LEFT", -12, 0)
    r.count:SetWidth(70)
    r.count:SetJustifyH("RIGHT")
    r.name = T.Text(r, 12)
    r.name:SetPoint("LEFT", 4, 0)
    r.name:SetPoint("RIGHT", r.count, "LEFT", -8, 0)
    r.name:SetJustifyH("LEFT")
    r.name:SetWordWrap(false)
    r:SetScript("OnEnter", function(self)
      local s = self.entry
      if not s then return end
      UI.TooltipOwner(self)
      if not pcall(GameTooltip.SetItemByID, GameTooltip, s.item) then GameTooltip:AddLine(s.name) end
      GameTooltip:AddLine(" ")
      GameTooltip:AddLine(("You have %d of %d"):format(s.have, s.need), 1, 1, 1)
      if #s.quests > 0 then GameTooltip:AddLine("Needed for: " .. table.concat(s.quests, ", "), 0.8, 0.8, 0.8, true) end
      GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    r.btn:HookScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine(W.AHOpen() and "Search the auction house for this item" or AH_CLOSED)
      GameTooltip:Show()
    end)
    r.btn:HookScript("OnLeave", function() GameTooltip:Hide() end)
    r.btn:SetScript("OnClick", function(self)
      local s = self.shopRow.entry
      if not s then return end
      if not W.AHOpen() then ns.Print(AH_CLOSED) return end
      local ok, why = W.SearchAH(s.item, s.name)
      if not ok and why then ns.Print(why) end
    end)
    r:Hide()
    shopRows[i] = r
  end
  local shopMore = T.Text(shop, 11, 0.45)
  shopMore:SetJustifyH("LEFT")
  local shopNote = T.Text(shop, 11, 0.4)
  shopNote:SetJustifyH("LEFT")
  local shopCollapsed = T.Text(shop, 11, 0.4)
  shopCollapsed:SetJustifyH("LEFT")
  shopCollapsed:SetText("Some quest log headers are closed. Open them so FableHub can see every writ you hold.")
  panel.shopBox, panel.shopCollapsed = shop, shopCollapsed -- (for tests)

  -- lays out the box; returns its height (0 when hidden)
  local function PaintShop()
    local list = W.Shopping()
    if #list == 0 then shop:Hide(); return 0 end
    local ahOpen = W.AHOpen()
    for i, r in ipairs(shopRows) do
      local s = list[i]
      r.entry = s
      if s then
        r.name:SetText(ns.Loot.ItemText(s.item, 14) .. UI.Dim("   " .. table.concat(s.quests, ", "), 0.4))
        local txt = ("%d / %d"):format(s.have, s.need)
        r.count:SetText(s.have >= s.need and UI.Colorize(txt, GREEN[1], GREEN[2], GREEN[3]) or txt)
        r.btn:SetAlpha(ahOpen and 1 or 0.4)
        r:Show()
      else
        r:Hide()
      end
    end
    local y = -24 - math.min(#list, SHOP_ROWS) * 22 - 4
    local function Line(fs, show, text)
      fs:SetShown(show)
      if not show then return end
      if text then fs:SetText(text) end
      fs:ClearAllPoints()
      fs:SetPoint("TOPLEFT", shop, "TOPLEFT", 12, y)
      fs:SetPoint("RIGHT", shop, "RIGHT", -12, 0)
      y = y - 16
    end
    Line(shopMore, #list > SHOP_ROWS, ("+%d more"):format(#list - SHOP_ROWS))
    Line(shopNote, not ahOpen, AH_CLOSED)
    Line(shopCollapsed, W.hasCollapsed)
    local h = -y + 4
    shop:SetHeight(h)
    shop:Show()
    return h
  end

  ----------------------------------------------------------------------
  -- the list
  ----------------------------------------------------------------------
  local list = UI.CreateList(panel, {
    { title = "Writ", flex = true },
    { title = "Profession", width = 112 },
    { title = "Skill", width = 36, justify = "RIGHT" },
    { title = "Level", width = 84 },
    { title = "Rep", width = 34, justify = "RIGHT" },
    { title = "Deliver to", width = 150 },
    { title = "Can craft", width = 150, defaultAsc = false },
  }, 24, { id = "writs" })
  -- a starting top edge so the list has a size from the start (the toolbar
  -- moves it under the filters and shopping list once it's laid out)
  list:SetPoint("TOPLEFT", 0, -100)
  list:SetPoint("BOTTOMRIGHT", 0, 0)
  list.sortCol, list.sortAsc = 2, true

  local bar = UI.Toolbar(panel)
  bar:Add(search, { grow = true, min = 160, max = 280 })
  bar:Add(mineToggle, { gap = 14 })
  bar:Add(guildToggle, { gap = 14 })
  bar:Status(info)
  bar:Add(profLabel, { newRow = true, w = 78 }) -- (same width, so the two rows of buttons line up)
  for i, p in ipairs(profBtns) do bar:Add(p.btn, { gap = i == 1 and 8 or 4 }) end
  bar:Add(levelLabel, { newRow = true, w = 78 })
  for i, l in ipairs(levelBtns) do bar:Add(l.btn, { gap = i == 1 and 8 or 4 }) end
  bar:Below(shop, { gap = 10 })
  bar:Below(shop, { gap = 10, point = "TOPRIGHT", x = 0 })
  -- the list sits under the shopping list when there is one (gap set in Refresh)
  local listBelow = { gap = 10 }
  bar:Below(list, listBelow)

  local function Tooltip(tt, it)
    local row, c = it.row, it.crafters
    -- the item the writ asks for (so you can see if it binds when picked up),
    -- then which writ it's for
    if not pcall(tt.SetItemByID, tt, row.item) then tt:AddLine(W.ItemName(row), 1, 1, 1) end
    tt:AddLine(" ")
    tt:AddLine(("Asked for by %s%s"):format(W.WritName(row), row.qty and row.qty > 1 and (" (x" .. row.qty .. ")") or ""), GOLD[1], GOLD[2], GOLD[3], true)
    local lv = ns.WRIT_LEVELS[row.level]
    tt:AddLine(("%s writ  ·  %d reputation"):format(lv and lv.name or "?", row.rep), 1, 1, 1)
    tt:AddLine(("Needs %s %d"):format(row.profName, row.skill), 0.8, 0.8, 0.8)
    tt:AddLine("Deliver to: " .. (row.to or "Not known yet"), 0.8, 0.8, 0.8, true)
    local h = W.held[row.item]
    if h then tt:AddLine(("In your quest log: you have %d of %d"):format(W.CountInBags(row.item), h.need), GOLD[1], GOLD[2], GOLD[3]) end
    tt:AddLine(" ")
    if c and #c > 0 then
      tt:AddLine("Can craft:", GOLD[1], GOLD[2], GOLD[3])
      for i, cr in ipairs(c) do
        if i > 8 then tt:AddLine(("+%d more"):format(#c - 8), 0.6, 0.6, 0.6) break end
        tt:AddLine(ns.Icons.Dot(cr.online) .. " " .. UI.ClassName(cr.key, cr.class))
      end
    else
      tt:AddLine("Nobody in the guild is known to craft this yet.", 0.6, 0.6, 0.6)
    end
    tt:AddLine(" ")
    tt:AddLine("Shift-click to link the writ. Right-click to ask the guild for the item, or whisper a crafter.", 0.6, 0.6, 0.6, true)
  end

  local function Menu(row)
    local items = {}
    local c = W.Crafters(row.item)
    if IsInGuild() then
      local onlyMe = c and #c.crafters > 0
      for _, cr in ipairs(c and c.crafters or {}) do if cr.key ~= ns.MyKey() then onlyMe = false break end end
      if onlyMe then
        items[#items + 1] = { text = UI.Dim("You're the only one in the guild who can craft this", 0.45) }
      elseif (c and c.recipe) or row.spell then
        items[#items + 1] = { text = "Request this from the guild", onClick = function()
          local ok, why = W.RequestFromGuild(row)
          if not ok and why then ns.Print(why) end
        end }
      else
        items[#items + 1] = { text = UI.Dim("Nobody in the guild is known to craft this yet", 0.45) }
      end
    end
    local me = ns.MyKey()
    for _, cr in ipairs(c and c.crafters or {}) do
      if cr.online and cr.key ~= me then
        items[#items + 1] = { text = "Whisper " .. ns.ShortName(cr.key), onClick = function()
          UI.Whisper(cr.key, ("Hi! Could you craft %s for me? It's for a Craftsman's Writ."):format(ItemLink(row.item) or row.name))
        end }
        break
      end
    end
    if W.AHOpen() then
      items[#items + 1] = { text = "Search the auction house for the writ", onClick = function()
        local ok, why = W.SearchAH(row.writ, W.WritName(row))
        if not ok and why then ns.Print(why) end
      end }
      items[#items + 1] = { text = "Search the auction house for " .. W.ItemName(row), onClick = function()
        local ok, why = W.SearchAH(row.item)
        if not ok and why then ns.Print(why) end
      end }
    end
    if #items == 0 then items[1] = { text = UI.Dim("Nothing to do here", 0.5) } end
    T.Menu(list, items, 260)
  end

  local function Click(it, button)
    if IsShiftKeyDown() then
      UI.InsertLink(ItemLink(it.row.writ or it.row.item))
    elseif button == "RightButton" then
      Menu(it.row)
    end
  end

  local function Matches(row, linkItem)
    if linkItem then return row.item == linkItem or row.writ == linkItem end
    if filterText == "" then return true end
    if row.nameLower:find(filterText, 1, true) then return true end
    if W.WritName(row):lower():find(filterText, 1, true) then return true end
    local inf = ns.Loot.ItemInfo(row.item)
    return inf and inf.name:lower():find(filterText, 1, true) and true or false
  end

  -- for tests: pick a profession / level / search text as the chips and box would
  function panel:SetFilters(o)
    if o.prof ~= nil then prof = o.prof end
    if o.level ~= nil then level = o.level end
    if o.text ~= nil then filterText = o.text:lower() end
    self:Refresh()
  end

  function panel:Refresh()
    for _, p in ipairs(profBtns) do p.btn:SetSelected(prof == p.value) end
    for _, l in ipairs(levelBtns) do l.btn:SetSelected(level == l.value) end
    local mineOnly, guildOnly = ns.Option("writsMineOnly"), ns.Option("writsGuildOnly")
    mineToggle:SetChecked(mineOnly); guildToggle:SetChecked(guildOnly)

    local text = filterText:gsub("^%s+", ""):gsub("%s+$", "")
    local linkItem = text:find("item:", 1, true) and ns.Loot.ItemIdFromLink(text) or nil
    local rows, mine = {}, 0
    for _, row in ipairs(W.LIST) do
      local isMine = W.IsMine(row.item)
      if isMine then mine = mine + 1 end
      local c = W.Crafters(row.item)
      local crafters = c and c.crafters or {}
      if (prof == 0 or row.prof == prof) and (level == "all" or row.level == level)
          and (not mineOnly or isMine) and (not guildOnly or #crafters > 0) and Matches(row, linkItem) then
        -- the writ itself; what it asks for is in the tooltip
        local name = row.writ and ns.Loot.ItemInfo(row.writ) and ns.Loot.ItemText(row.writ, 14)
          or UI.Dim(W.WritName(row), 0.8)
        if isMine then name = name .. "  " .. UI.Colorize("MINE", GOLD[1], GOLD[2], GOLD[3]) end
        local lv = ns.WRIT_LEVELS[row.level]
        local rank = W.LEVEL_RANK[row.level] or 9
        rows[#rows + 1] = {
          row = row, crafters = crafters, pinned = isMine or nil,
          cols = {
            name,
            ns.Icons.Prof(row.prof, 13) .. " " .. UI.Dim(row.profName, 0.6),
            tostring(row.skill),
            lv and lv.name or "?",
            tostring(row.rep),
            row.to and UI.Dim(row.to, 0.75) or UI.Dim("Not known yet", 0.4),
            CrafterCell(crafters, 2),
          },
          sort = {
            W.WritName(row):lower(),
            ("%s %d %03d %s"):format(row.profName, rank, row.skill, row.nameLower),
            row.skill * 10 + rank,
            rank * 1000 + row.skill,
            row.rep * 1000 + row.skill,
            row.to and row.to:lower() or "~",
            #crafters,
          },
          tooltip = Tooltip, onClick = Click,
        }
      end
    end
    info:SetText(("%d of %d writs  ·  %d in your quest log"):format(#rows, #W.LIST, mine))
    local shopH = PaintShop()
    listBelow.gap = shopH > 0 and (10 + shopH + 10) or 10
    local empty = "No writs match. Clear the search or pick All."
    if mineOnly and mine == 0 then
      empty = W.hasCollapsed and "No writs found in your quest log. Open any closed quest log headers."
        or "No writs in your quest log. Untick Only mine to see them all."
    end
    list:SetItems(rows, empty)
    UI.SetHint("Writs you hold are marked Mine. Right-click a writ to ask the guild to craft it.")
  end
  -- the first time the page opens, its size settles a moment later: draw again then
  panel:HookScript("OnShow", function()
    C_Timer.After(0, function()
      if not panel:IsShown() then return end
      list:FitWidth()
      panel:Refresh()
    end)
  end)
end, "profgroup")

ns.On("WRITS_CHANGED", function() if ns.UI.QueueRefresh then ns.UI.QueueRefresh() end end)
