-- Camping pages: Camp guide (what each profession's camp items do, who can make them)
-- and Camp planner (fill a campfire's slots and see what the camp gives).

local _, ns = ...
local UI, T, C = ns.UI, ns.Theme, ns.Camping


local RED, GREEN = { 0.95, 0.45, 0.4 }, { 0.4, 0.85, 0.5 }
local function Red(t) return UI.Colorize(t, RED[1], RED[2], RED[3]) end

local function ItemLabel(item, size)
  return ("|T%s:%d:%d:0:0:64:64:5:59:5:59|t %s"):format(item.icon, size or 14, size or 14, item.name)
end

local function NoStackText(item)
  local names = {}
  for _, b in ipairs(item.line.noStack or {}) do
    local buff = ns.BUFF_BY_ID[b]
    if buff then names[#names + 1] = buff.name end
  end
  return table.concat(names, ", ")
end

local function ItemTooltip(tt, item)
  tt:AddLine(ItemLabel(item, 16), 1, 1, 1)
  tt:AddLine(("%s, tier %d  -  needs %d %s"):format(item.profName, item.tier, item.skill, item.profName), 0.7, 0.7, 0.7)
  tt:AddLine(" ")
  for _, e in ipairs(item.effects) do tt:AddLine(e, 1, 0.82, 0, true) end
  local ns_ = NoStackText(item)
  if ns_ ~= "" then tt:AddLine("Doesn't stack with " .. ns_, 0.7, 0.7, 0.7, true) end
  local makers = C.Makers(item)
  tt:AddLine(" ")
  if #makers == 0 then
    tt:AddLine("Nobody in the guild can make this yet (that we know of).", 0.6, 0.6, 0.6, true)
  else
    tt:AddLine(("Can make it (%d)"):format(#makers), 1, 0.82, 0)
    for i, m in ipairs(makers) do
      if i > 10 then tt:AddLine(("+%d more"):format(#makers - 10), 0.6, 0.6, 0.6) break end
      tt:AddDoubleLine(ns.Icons.Dot(m.online) .. " " .. UI.ClassName(m.key, (ns.roster[m.key] or {}).class), tostring(m.skill), 1, 1, 1, 0.7, 0.7, 0.7)
    end
  end
end

-- Professions > Camping > Camp guide / Camp planner
ns.RegisterNavGroup("campgroup", "Camping", nil, { "campguide", "campplanner" }, "profgroup")

------------------------------------------------------------------------
-- Camp guide
------------------------------------------------------------------------
ns.RegisterPanel("campguide", "Camp guide", nil, function(panel)
  local filterText, canMakeOnly = "", false
  local search = T.SearchBox(panel, 220, "Search item, profession or buff", function(t) filterText = t; panel:Refresh() end)
  search:SetPoint("TOPLEFT", 0, 0)
  local toggle = T.Toggle(panel, "Only what the guild can make", function(v) canMakeOnly = v; panel:Refresh() end)
  toggle:SetPoint("LEFT", search, "RIGHT", 14, 0)
  -- profession headings collapse; remembered between sessions
  FableHubDB.settings.campCollapsed = FableHubDB.settings.campCollapsed or {}
  local collapsed = FableHubDB.settings.campCollapsed
  local sections = {}
  local allBtn = T.Button(panel, "Collapse all", 96, 22)
  allBtn:SetPoint("TOPRIGHT", 0, 0)
  allBtn:SetScript("OnClick", function()
    local anyOpen = false
    for _, id in ipairs(sections) do if not collapsed[id] then anyOpen = true end end
    for _, id in ipairs(sections) do collapsed[id] = anyOpen or nil end
    panel:Refresh()
  end)
  local info = T.Text(panel, 11, 0.4)
  info:SetJustifyH("LEFT")
  info:SetText("Sit by a campfire for about a minute to get its Camp Benefits for 1 hour. Camp buffs don't stack with the class buff they resemble.")

  local list = UI.CreateList(panel, {
    { title = "Camp item", flex = true },
    { title = "Skill", width = 40, justify = "RIGHT" },
    { title = "Gives", flex = true },
    { title = "Doesn't stack with", width = 150 },
    { title = "Can make", width = 64, justify = "RIGHT" },
  }, 24)
  list:SetPoint("TOPLEFT", 0, -50)
  list:SetPoint("BOTTOMRIGHT", 0, 0)
  list.sortable = false

  local bar = UI.Toolbar(panel)
  bar:Add(search, { grow = true, min = 150, max = 220 })
  bar:Add(toggle, { gap = 14 })
  bar:Add(allBtn, { right = true, gap = 14 })
  bar:Add(info, { fill = true, wrap = true })
  bar:Below(list, { gap = 4 })

  function panel:Refresh()
    UI.SetHint("Click a heading to show or hide it. Hover an item to see who in the guild can make it.")
    local rows = {}
    local q = filterText
    local ar, ag, ab = T.Accent()
    for i = #sections, 1, -1 do sections[i] = nil end
    -- a heading row that opens/closes its section (searching shows everything)
    local function Heading(id, label, n)
      sections[#sections + 1] = id
      local open = q ~= "" or not collapsed[id]
      rows[#rows + 1] = {
        header = true,
        cols = { UI.Colorize(open and "-" or "+", ar, ag, ab) .. "  " .. label .. UI.Dim(("   %d"):format(n), 0.35), "", "", "", "" },
        onClick = function(_, button)
          if button == "RightButton" or q ~= "" then return end
          collapsed[id] = not collapsed[id] or nil
          panel:Refresh()
        end,
      }
      return open
    end
    -- campfires first
    local fireRows = {}
    for _, f in ipairs(C.FIRES) do
      local makers = {}
      for _, m in ipairs(ns.AllMembers()) do
        local sk = C.Skill(m.key, C.COOKING)
        if sk and sk >= f.cooking then makers[#makers + 1] = m.key end
      end
      local hay = (f.name .. " cooking campfire"):lower()
      if (q == "" or hay:find(q, 1, true)) and (not canMakeOnly or #makers > 0) then
        fireRows[#fireRows + 1] = {
          cols = { "|TInterface\\Icons\\Spell_Fire_Fire:14:14:0:0:64:64:5:59:5:59|t " .. f.name, tostring(f.cooking),
                   UI.Dim(("%d camp item slots"):format(f.slots), 0.8), "", #makers > 0 and tostring(#makers) or UI.Dim("-", 0.3) },
          tooltip = function(tt)
            tt:AddLine(f.name, 1, 1, 1)
            tt:AddLine(("Cooking %d  -  %d camp item slots"):format(f.cooking, f.slots), 0.8, 0.8, 0.8)
            if f.note then tt:AddLine(f.note, 0.6, 0.6, 0.6) end
          end,
        }
      end
    end
    if #fireRows > 0 and Heading("fires", UI.Dim("CAMPFIRES (COOKING)", 0.6), #fireRows) then
      for _, r in ipairs(fireRows) do rows[#rows + 1] = r end
    end
    for _, line in ipairs(C.LINES) do
      local lineRows = {}
      for tier = 1, 3 do
        local item = C.ITEM_BY_ID[line.prof .. ":" .. tier]
        if item then
          local makers = C.Makers(item)
          local hay = (item.name .. " " .. item.profName .. " " .. table.concat(item.effects, " ") .. " " .. NoStackText(item)):lower()
          if (q == "" or hay:find(q, 1, true)) and (not canMakeOnly or #makers > 0) then
            local gives = item.effects[1] or ""
            if #item.effects > 1 then gives = item.effects[#item.effects] .. UI.Dim("  + " .. (item.effects[1] or ""), 0.5) end
            lineRows[#lineRows + 1] = {
              cols = { ItemLabel(item) .. UI.Dim("  tier " .. tier, 0.4), tostring(item.skill), gives,
                       UI.Dim(NoStackText(item), 0.55),
                       #makers > 0 and UI.Colorize(tostring(#makers), GREEN[1], GREEN[2], GREEN[3]) or UI.Dim("-", 0.3) },
              tooltip = function(tt) ItemTooltip(tt, item) end,
            }
          end
        end
      end
      if #lineRows > 0 and Heading(tostring(line.prof), ns.Icons.Prof(line.prof, 14) .. "  " .. UI.Dim(line.profName:upper(), 0.6), #lineRows) then
        for _, r in ipairs(lineRows) do rows[#rows + 1] = r end
      end
    end
    local anyOpen = false
    for _, id in ipairs(sections) do if not collapsed[id] then anyOpen = true end end
    allBtn:SetText(anyOpen and "Collapse all" or "Expand all")
    list:SetItems(rows, "Nothing matches")
  end
end, "campgroup")

------------------------------------------------------------------------
-- Camp planner
------------------------------------------------------------------------
ns.RegisterPanel("campplanner", "Camp planner", nil, function(panel)
  local currentId = FableHubDB.settings.lastCamp
  local checkSource = "group"

  local function Current()
    local p = C.Plans()[currentId]
    if p then return p end
    local l = C.List()
    currentId = l[1] and l[1].id
    return l[1]
  end
  local function Select(id) currentId = id; FableHubDB.settings.lastCamp = id; panel:Refresh() end

  -- top bar
  local planBtn = T.Button(panel, "Choose a camp", 200, 22)
  planBtn:SetPoint("TOPLEFT", 0, 0)
  local renameBox = T.Input(panel, 200, "Camp name")
  renameBox:SetPoint("TOPLEFT", 0, 0)
  renameBox:Hide()
  local newBtn = T.Button(panel, "New", 56, 22); newBtn:SetPoint("LEFT", planBtn, "RIGHT", 6, 0)
  local renameBtn = T.Button(panel, "Rename", 70, 22); renameBtn:SetPoint("LEFT", newBtn, "RIGHT", 4, 0)
  local deleteBtn = T.Button(panel, "Delete", 64, 22); deleteBtn:SetPoint("LEFT", renameBtn, "RIGHT", 4, 0)
  local postBtn = T.Button(panel, "Post to chat", 110, 22); postBtn:SetPoint("TOPRIGHT", 0, 0)

  -- campfire row
  local fireLabel = T.Text(panel, 11, T.section); fireLabel:SetPoint("TOPLEFT", 0, -36); fireLabel:SetText("CAMPFIRE")
  local fireBtns = {}
  for i, f in ipairs(C.FIRES) do
    local b = T.Button(panel, ("%s (%d)"):format((f.name:gsub(" Campfire", "")), f.slots), 108, 22)
    if i == 1 then b:SetPoint("TOPLEFT", 72, -32) else b:SetPoint("LEFT", fireBtns[i - 1], "RIGHT", 4, 0) end
    b:SetScript("OnClick", function() local p = Current(); if p then C.SetFire(p, f.id) end end)
    fireBtns[i] = b
  end
  local builderBtn = T.Button(panel, "Lit by: anyone", 170, 22)
  builderBtn:SetPoint("LEFT", fireBtns[#fireBtns], "RIGHT", 12, 0)

  -- slots
  local slotsArea = CreateFrame("Frame", nil, panel)
  slotsArea:SetPoint("TOPLEFT", 0, -64)
  slotsArea:SetSize(470, 10 * 28)
  local rows = {}
  for i = 1, 10 do
    local r = CreateFrame("Frame", nil, slotsArea)
    r:SetPoint("TOPLEFT", 0, -(i - 1) * 28)
    r:SetSize(470, 26)
    T.Fill(r, { 0, 0, 0, (i % 2 == 0) and 0.2 or 0.1 })
    r.num = T.Text(r, 12, 0.4); r.num:SetPoint("LEFT", 6, 0); r.num:SetText(tostring(i))
    r.item = T.Button(r, "Choose item", 196, 22); r.item:SetPoint("LEFT", 24, 0)
    r.member = T.Button(r, "Who brings it", 140, 22); r.member:SetPoint("LEFT", r.item, "RIGHT", 4, 0)
    for _, b in ipairs({ r.item, r.member }) do
      local fs = b:GetFontString()
      fs:ClearAllPoints(); fs:SetPoint("LEFT", 7, 0); fs:SetPoint("RIGHT", -7, 0); fs:SetJustifyH("LEFT"); fs:SetWordWrap(false)
    end
    r.status = T.Text(r, 11, 0.6); r.status:SetPoint("LEFT", r.member, "RIGHT", 6, 0); r.status:SetPoint("RIGHT", -22, 0)
    r.status:SetJustifyH("LEFT"); r.status:SetWordWrap(false)
    r.clear = T.CloseButton(r, function() local p = Current(); if p then p.slots[i] = nil; ns.Fire("CAMP_CHANGED") end end)
    r.clear:SetPoint("RIGHT", -2, 0)
    r.item:HookScript("OnEnter", function(self)
      local p = Current()
      local s = p and p.slots[i]
      local item = s and s.item and C.ITEM_BY_ID[s.item]
      if item then GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); ItemTooltip(GameTooltip, item); GameTooltip:Show() end
    end)
    r.item:HookScript("OnLeave", function() GameTooltip:Hide() end)
    rows[i] = r
  end

  -- right column: what the camp gives
  local right = CreateFrame("Frame", nil, panel)
  right:SetPoint("TOPLEFT", 486, -64)
  right:SetPoint("BOTTOMRIGHT", 0, 0)
  local checkBtn = T.Button(right, "Check against: your group", 200, 22)
  checkBtn:SetPoint("TOPLEFT", 0, 0)
  checkBtn:SetPoint("RIGHT", right, "RIGHT", 0, 0)
  local givesLabel = T.Text(right, 11, T.section); givesLabel:SetPoint("TOPLEFT", 0, -32); givesLabel:SetText("THIS CAMP GIVES")
  local gives = T.Text(right, 12, 0.85)
  gives:SetPoint("TOPLEFT", 0, -48)
  gives:SetPoint("RIGHT", right, "RIGHT", 0, 0)
  gives:SetJustifyH("LEFT"); gives:SetJustifyV("TOP"); gives:SetSpacing(3)
  local warnLabel = T.Text(right, 11, T.section); warnLabel:SetText("CHECK")
  local warns = T.Text(right, 12, 0.85)
  warns:SetPoint("RIGHT", right, "RIGHT", 0, 0)
  warns:SetJustifyH("LEFT"); warns:SetJustifyV("TOP"); warns:SetSpacing(3)

  local emptyText = T.Text(panel, 13, 0.4); emptyText:SetPoint("CENTER", 0, 20)
  local createBtn = T.Button(panel, "Create a camp plan", 150, 24); createBtn:SetPoint("TOP", emptyText, "BOTTOM", 0, -12)

  -- toolbar rows wrap when narrow; the slot list narrows (330-470) to leave
  -- the right-hand column some room
  local slotW = 470
  local bar = UI.Toolbar(panel, {
    before = function(w)
      if w <= 0 then return end
      slotW = math.max(330, math.min(470, w - 216))
      local itemW = math.floor(slotW * 0.42)
      local memberW = math.floor(slotW * 0.3)
      slotsArea:SetWidth(slotW)
      for _, r in ipairs(rows) do
        r:SetWidth(slotW)
        r.item:SetWidth(itemW)
        r.member:SetWidth(memberW)
      end
    end,
  })
  bar:Add(planBtn)
  bar:Add(renameBox)
  bar:Add(newBtn, { gap = 6 })
  bar:Add(renameBtn, { gap = 4 })
  bar:Add(deleteBtn, { gap = 4 })
  bar:Add(postBtn, { right = true, gap = 12 })
  bar:Add(fireLabel, { newRow = true, w = 66 })
  for i, b in ipairs(fireBtns) do bar:Add(b, { gap = i == 1 and 6 or 4 }) end
  bar:Add(builderBtn, { gap = 12 })
  bar:Below(slotsArea, { x = 0, gap = 14 })
  bar:Below(right, { x = function() return slotW + 16 end, gap = 14 })

  ----------------------------------------------------------------------
  -- actions
  ----------------------------------------------------------------------
  local function NewPlan() local p = C.New("Camp " .. (#C.List() + 1)); Select(p.id) end
  newBtn:SetScript("OnClick", NewPlan)
  createBtn:SetScript("OnClick", NewPlan)
  planBtn:SetScript("OnClick", function()
    local items, cur = {}, Current()
    for _, p in ipairs(C.List()) do
      items[#items + 1] = { text = p.name, checked = cur and p.id == cur.id, onClick = function() Select(p.id) end }
    end
    items[#items + 1] = { text = UI.Dim("+ New camp", 0.7), onClick = NewPlan }
    T.Menu(planBtn, items, 220)
  end)
  local function EndRename(save)
    local p = Current()
    if save and p then
      local n = (renameBox:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
      if n ~= "" then p.name = n end
    end
    renameBox:Hide(); planBtn:Show(); panel:Refresh()
  end
  renameBtn:SetScript("OnClick", function()
    local p = Current(); if not p then return end
    planBtn:Hide(); renameBox:Show(); renameBox:SetText(p.name); renameBox:SetFocus(); renameBox:HighlightText()
    UI.LayoutToolbars(panel)
  end)
  renameBox:SetScript("OnEnterPressed", function() EndRename(true) end)
  renameBox:SetScript("OnEscapePressed", function() EndRename(false) end)
  renameBox:SetScript("OnEditFocusLost", function() if renameBox:IsShown() then EndRename(true) end end)
  local armed = 0
  deleteBtn:SetScript("OnClick", function()
    local p = Current(); if not p then return end
    if GetTime() - armed > 3 then
      armed = GetTime(); deleteBtn:SetText("Sure?")
      C_Timer.After(3, function() deleteBtn:SetText("Delete") end)
      return
    end
    armed = 0; deleteBtn:SetText("Delete"); C.Delete(p); currentId = nil; panel:Refresh()
  end)

  local function MemberMenu(anchor, candidates, onPick)
    local items = {}
    for i, m in ipairs(candidates) do
      if i > 20 then break end
      items[#items + 1] = { text = UI.NameCell(m.key, (ns.roster[m.key] or {}).class, m.online) .. "  " .. UI.Dim(tostring(m.skill or ""), 0.5),
        onClick = function() onPick(m.key) end }
    end
    if #items == 0 then items[1] = { text = UI.Dim("Nobody in the guild has enough skill (that we know of)", 0.5) } end
    items[#items + 1] = { text = UI.Dim("Nobody yet", 0.6), onClick = function() onPick(false) end }
    T.Menu(anchor, items, 240)
  end

  builderBtn:SetScript("OnClick", function()
    local p = Current(); if not p then return end
    local fire = C.FIRE_BY_ID[p.fire]
    local cands = {}
    for _, m in ipairs(ns.AllMembers()) do
      local sk = C.Skill(m.key, C.COOKING)
      if sk and sk >= fire.cooking then cands[#cands + 1] = { key = m.key, skill = sk, online = ns.IsOnline(m.key) } end
    end
    table.sort(cands, function(a, b) if a.online ~= b.online then return a.online end return a.skill > b.skill end)
    MemberMenu(builderBtn, cands, function(key) p.builder = key or nil; ns.Fire("CAMP_CHANGED") end)
  end)

  for i, r in ipairs(rows) do
    r.item:SetScript("OnClick", function()
      local p = Current(); if not p then return end
      local items = {}
      for _, line in ipairs(C.LINES) do
        items[#items + 1] = {
          text = ns.Icons.Prof(line.prof, 14) .. " " .. line.profName .. "  " .. UI.Dim(line.buff or line.service or "", 0.45),
          onClick = function()
            local tiers = {}
            for tier = 1, 3 do
              local item = C.ITEM_BY_ID[line.prof .. ":" .. tier]
              if item then
                local n = #C.Makers(item)
                tiers[#tiers + 1] = {
                  text = ItemLabel(item) .. UI.Dim(("  tier %d, %d skill, %d can make"):format(tier, item.skill, n), 0.45),
                  onClick = function() C.SetSlot(p, i, item.id, nil) end,
                }
              end
            end
            T.Menu(r.item, tiers, 320)
          end,
        }
      end
      T.Menu(r.item, items, 300)
    end)
    r.member:SetScript("OnClick", function()
      local p = Current(); if not p then return end
      local s = p.slots[i]
      local item = s and s.item and C.ITEM_BY_ID[s.item]
      local cands = {}
      if item then
        cands = C.Makers(item)
      else
        for _, m in ipairs(ns.AllMembers()) do cands[#cands + 1] = { key = m.key, online = ns.IsOnline(m.key) } end
        table.sort(cands, function(a, b) if a.online ~= b.online then return a.online end return a.key < b.key end)
      end
      MemberMenu(r.member, cands, function(key) C.SetSlot(p, i, nil, key) end)
    end)
  end

  checkBtn:SetScript("OnClick", function()
    local items = { { text = "Your current group", checked = checkSource == "group", onClick = function() checkSource = "group"; panel:Refresh() end } }
    for _, rp in ipairs(ns.Plans.List()) do
      items[#items + 1] = { text = "Raid plan: " .. rp.name, checked = checkSource == rp.id,
        onClick = function() checkSource = rp.id; panel:Refresh() end }
    end
    T.Menu(checkBtn, items, 240)
  end)

  postBtn:SetScript("OnClick", function()
    local p = Current(); if not p then return end
    local items = {}
    local function Add(label, channel, ok)
      if ok then items[#items + 1] = { text = label, onClick = function() C.Post(p, channel) end } end
    end
    Add("Party chat", "PARTY", IsInGroup and IsInGroup() and not (IsInRaid and IsInRaid()))
    Add("Raid chat", "RAID", IsInRaid and IsInRaid())
    Add("Guild chat", "GUILD", IsInGuild())
    if #items == 0 then items[1] = { text = UI.Dim("Join a group or guild to post", 0.5) } end
    items[#items + 1] = { text = UI.Dim("Cancel", 0.5) }
    T.Menu(postBtn, items, 180)
  end)
  postBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Post this camp to chat")
    GameTooltip:AddLine("Choose where. Nothing is posted unless you pick a channel.", 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
  end)
  postBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  ----------------------------------------------------------------------
  function panel:Refresh()
    local p = Current()
    for _, w in ipairs({ renameBtn, deleteBtn, postBtn, fireLabel, builderBtn, slotsArea, right }) do w:SetShown(p ~= nil) end
    for _, b in ipairs(fireBtns) do b:SetShown(p ~= nil) end
    emptyText:SetShown(p == nil); createBtn:SetShown(p == nil)
    if not p then
      planBtn:SetText(UI.Dim("No camps", 0.5))
      emptyText:SetText("Plan which camp items to bring and who brings them")
      UI.SetHint("Camp plans are saved on your computer.")
      return
    end
    planBtn:SetText(p.name)
    local fire = C.FIRE_BY_ID[p.fire] or C.FIRES[1]
    for i, f in ipairs(C.FIRES) do fireBtns[i]:SetSelected(f.id == fire.id) end
    builderBtn:SetText(p.builder and ("Lit by: " .. ns.ShortName(p.builder)) or "Lit by: anyone")

    local res = C.Check(p, checkSource)
    for i, r in ipairs(rows) do
      r:SetShown(i <= fire.slots)
      local s = p.slots[i]
      local item = s and s.item and C.ITEM_BY_ID[s.item]
      r.item:SetText(item and ItemLabel(item) or UI.Dim("Choose item", 0.5))
      r.member:SetText(s and s.key and UI.NameCell(s.key, (ns.roster[s.key] or {}).class, ns.IsOnline(s.key)) or UI.Dim("Who brings it", 0.5))
      local issues = res.perSlot[i] or {}
      if #issues > 0 then
        local text = table.concat(issues, ", ")
        local bad = text:find("needs") or text:find("twice") or text:find("already")
        r.status:SetText(bad and Red(text) or UI.Dim(text, 0.55))
      elseif item and s.key then
        r.status:SetText(UI.Colorize("ok", GREEN[1], GREEN[2], GREEN[3]))
      else
        r.status:SetText("")
      end
      r.clear:SetShown(s ~= nil)
    end

    -- source label
    local srcName = "your group"
    if checkSource ~= "group" then
      local rp = ns.Plans.Get(checkSource)
      if rp then srcName = rp.name else checkSource = "group" end
    end
    checkBtn:SetText("Check against: " .. srcName)

    local lines = {}
    for _, g in ipairs(res.gives) do
      local first = g.item.effects[1] or ""
      local line = ItemLabel(g.item, 13) .. "  " .. first
      if g.redundant then
        local who = g.redundant.providers[1]
        line = line .. "\n    " .. Red(("won't help: %s%s"):format(g.redundant.buff.name, who and (" (" .. ns.ShortName(who.key) .. ")") or ""))
      end
      for k = 2, #g.item.effects do line = line .. "\n    " .. UI.Dim(g.item.effects[k], 0.6) end
      lines[#lines + 1] = line
    end
    gives:SetText(#lines > 0 and table.concat(lines, "\n") or UI.Dim("Pick items for the slots on the left.", 0.5))

    warnLabel:ClearAllPoints()
    warnLabel:SetPoint("TOPLEFT", gives, "BOTTOMLEFT", 0, -16)
    warns:ClearAllPoints()
    warns:SetPoint("TOPLEFT", warnLabel, "BOTTOMLEFT", 0, -6)
    warns:SetPoint("RIGHT", right, "RIGHT", 0, 0)
    local filled = 0
    for i = 1, fire.slots do if p.slots[i] and p.slots[i].item then filled = filled + 1 end end
    local wl = {}
    for _, w in ipairs(res.warnings) do wl[#wl + 1] = Red("- ") .. w end
    if #wl == 0 then wl[1] = UI.Colorize("No problems found.", GREEN[1], GREEN[2], GREEN[3]) end
    wl[#wl + 1] = UI.Dim(("%d of %d slots filled."):format(filled, fire.slots), 0.5)
    warns:SetText(table.concat(wl, "\n"))
    UI.SetHint("Click a slot's item, then who brings it. Each player can place one camp item.")
  end
end, "campgroup")

ns.On("CAMP_CHANGED", function() if ns.UI.QueueRefresh then ns.UI.QueueRefresh() end end)
