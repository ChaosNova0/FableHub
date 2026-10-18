-- Raids tab: build raid groups, see buff coverage, save and share plans.

local _, ns = ...
local UI, T, P = ns.UI, ns.Theme, ns.Plans

ns.MAX_LEVEL = 60

local ROLE_COLORS = {
  TANK = { 0.45, 0.65, 1 }, HEALER = { 0.4, 0.85, 0.5 }, MELEE = { 0.95, 0.52, 0.45 }, RANGED = { 0.78, 0.62, 1 },
}
local CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
local CLASS_NAMES = {
  WARRIOR = "Warrior", PALADIN = "Paladin", HUNTER = "Hunter", ROGUE = "Rogue", PRIEST = "Priest",
  SHAMAN = "Shaman", MAGE = "Mage", WARLOCK = "Warlock", DRUID = "Druid",
}

local function RoleTag(role, short)
  if not role then return "" end
  local c = ROLE_COLORS[role]
  local text = short and ns.ROLE_SHORT[role] or ns.ROLE_NAMES[role]
  return UI.Colorize(text, c[1], c[2], c[3])
end

local function BuffIcon(b, size)
  return ("|T%s:%d:%d:0:0:64:64:5:59:5:59|t"):format(b.icon, size or 14, size or 14)
end

-- tooltip describing one planned/pool member
local function MemberTooltip(tt, d)
  tt:AddLine(ns.Icons.Class(d.class, 16) .. " " .. ns.ShortName(d.key), ns.ClassColor(d.class))
  local specText = d.spec and d.spec.name and (d.spec.name .. (d.spec.points ~= "" and ("  " .. d.spec.points) or "")) or "Spec unknown"
  tt:AddDoubleLine(specText, RoleTag(d.role), 0.85, 0.85, 0.85)
  if d.roleSource == "guess" then tt:AddLine("Role guessed from class.", 0.6, 0.6, 0.6) end
  if d.roleSource == "plan" then tt:AddLine("Role set in this plan.", 0.6, 0.6, 0.6) end
  if d.level then tt:AddLine("Level " .. d.level, 0.7, 0.7, 0.7) end
  if d.extra then tt:AddLine("Not in the guild (added by hand)", 0.7, 0.7, 0.7) end
  local icons = {}
  for _, b in ipairs(ns.BUFFS) do if d.buffs[b.id] then icons[#icons + 1] = BuffIcon(b, 16) end end
  if #icons > 0 then
    tt:AddLine(" ")
    tt:AddLine(d.detected and "Brings" or "Brings (assumed from class, not detected)", 1, 0.82, 0)
    local line = {}
    for i, ic in ipairs(icons) do
      line[#line + 1] = ic
      if #line == 10 or i == #icons then tt:AddLine(table.concat(line, " ")); line = {} end
    end
  end
end

local function BuffTooltip(tt, b, providers)
  tt:AddLine(BuffIcon(b, 16) .. " " .. b.name, 1, 1, 1)
  local scope = ({ raid = "Reaches the whole raid", party = "Only the caster's group", debuff = "Boss debuff", utility = "Utility" })[b.cat]
  tt:AddLine(scope, 0.6, 0.6, 0.6)
  if not b.base then tt:AddLine("Needs a talent", 0.6, 0.6, 0.6) end
  tt:AddLine(" ")
  if providers and #providers > 0 then
    for _, d in ipairs(providers) do
      tt:AddDoubleLine(UI.ClassName(d.key, d.class), d.detected and "" or "|cff999999assumed|r")
    end
  else
    tt:AddLine("Nobody in this plan brings this.", 0.8, 0.4, 0.4)
  end
  if b.id == "might" or b.id == "wisdom" or b.id == "kings" or b.id == "salv" or b.id == "light" or b.id == "sanct" then
    tt:AddLine(" ")
    tt:AddLine("Each paladin covers one blessing per class.", 0.6, 0.6, 0.6, true)
  end
end

------------------------------------------------------------------------
ns.RegisterNavGroup("raidgroup", "Raids", "Interface\\Icons\\INV_Misc_Head_Dragon_01", { "events", "raids", "readycheck" })

ns.RegisterPanel("raids", "Raid plans", nil, function(panel)
  local currentId = FableHubDB.settings.lastPlan
  local selectedKey             -- picked in the pool for click-to-place
  local filterText, maxOnly, onlineOnly = "", false, false
  local signedOnly, signedFor = true, nil -- pool shows only the raid night's sign-ups (linked plans)

  local function Current()
    if P.openPlan then -- asked to open a plan (e.g. from Raid nights)
      currentId = P.openPlan
      FableHubDB.settings.lastPlan = currentId
      P.openPlan = nil
    end
    local plan = P.Get(currentId)
    if plan and not plan.deleted then return plan end
    local list = P.List()
    plan = list[1]
    currentId = plan and plan.id
    return plan
  end
  local function Select(id)
    currentId = id
    FableHubDB.settings.lastPlan = id
    selectedKey = nil
    panel:Refresh()
  end

  ----------------------------------------------------------------------
  -- Top bar
  ----------------------------------------------------------------------
  local planBtn = T.Button(panel, "Select a plan", 210, 22)
  planBtn:SetPoint("TOPLEFT", 0, 0)
  planBtn:GetFontString():ClearAllPoints()
  planBtn:GetFontString():SetPoint("LEFT", 9, 0)
  planBtn:GetFontString():SetPoint("RIGHT", -20, 0)
  planBtn:GetFontString():SetJustifyH("LEFT")
  local caret = T.Text(planBtn, 11, 0.5)
  caret:SetPoint("RIGHT", -8, 0)
  caret:SetText("v")

  local renameBox = T.Input(panel, 210, "Plan name")
  renameBox:SetPoint("TOPLEFT", 0, 0)
  renameBox:Hide()

  local newBtn = T.Button(panel, "New", 56, 22)
  newBtn:SetPoint("LEFT", planBtn, "RIGHT", 6, 0)
  local renameBtn = T.Button(panel, "Rename", 70, 22)
  renameBtn:SetPoint("LEFT", newBtn, "RIGHT", 4, 0)
  local deleteBtn = T.Button(panel, "Delete", 64, 22)
  deleteBtn:SetPoint("LEFT", renameBtn, "RIGHT", 4, 0)

  local sizeBtns = {}
  for i, size in ipairs(P.SIZES) do
    local b = T.Button(panel, tostring(size), 38, 22)
    if i == 1 then b:SetPoint("LEFT", deleteBtn, "RIGHT", 14, 0) else b:SetPoint("LEFT", sizeBtns[i - 1], "RIGHT", 3, 0) end
    b:SetScript("OnClick", function()
      local plan = Current()
      if plan and P.CanEdit("plans") then P.Resize(plan, size) end
    end)
    sizeBtns[i] = b
  end
  local shareBtn = T.Button(panel, "Share", 70, 22)
  shareBtn:SetPoint("LEFT", sizeBtns[#sizeBtns], "RIGHT", 14, 0)
  local nightBtn = T.Button(panel, "From raid night", 118, 22)
  nightBtn:SetPoint("LEFT", shareBtn, "RIGHT", 6, 0)

  local status = T.Text(panel, 11, 0.45)
  status:SetPoint("TOPLEFT", 0, -32)

  local rankBtn = T.Button(panel, "Officer ranks", 150, 20)
  rankBtn:SetPoint("TOPRIGHT", 0, -28)

  planBtn:SetScript("OnClick", function()
    local items = {}
    local cur = Current()
    for _, plan in ipairs(P.List()) do
      items[#items + 1] = {
        text = plan.name .. "  " .. UI.Dim(plan.size .. "-man" .. (plan.shared and "" or ", not shared"), 0.45),
        checked = cur and plan.id == cur.id, onClick = function() Select(plan.id) end,
      }
    end
    if P.CanEdit("plans") then
      items[#items + 1] = { text = UI.Dim("+ New plan", 0.7), onClick = function() newBtn:Click() end }
    end
    if #items == 0 then items[1] = { text = UI.Dim("No plans yet", 0.5) } end
    T.Menu(planBtn, items, 240)
  end)

  newBtn:SetScript("OnClick", function()
    local plan = P.New("Raid " .. (#P.List() + 1), 20)
    if plan then Select(plan.id) end
  end)

  local function StartRename()
    local plan = Current()
    if not plan then return end
    planBtn:Hide()
    renameBox:Show()
    renameBox:SetText(plan.name)
    renameBox:SetFocus()
    renameBox:HighlightText()
    UI.LayoutToolbars(panel)
  end
  local function EndRename(save)
    local plan = Current()
    if save and plan then
      local name = (renameBox:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
      if name ~= "" and name ~= plan.name then plan.name = name; P.Touch(plan) end
    end
    renameBox:Hide()
    planBtn:Show()
    panel:Refresh()
  end
  renameBtn:SetScript("OnClick", StartRename)
  renameBox:SetScript("OnEnterPressed", function() EndRename(true) end)
  renameBox:SetScript("OnEscapePressed", function() EndRename(false) end)
  renameBox:SetScript("OnEditFocusLost", function() if renameBox:IsShown() then EndRename(true) end end)

  local deleteArmed = 0
  deleteBtn:SetScript("OnClick", function()
    local plan = Current()
    if not plan then return end
    if GetTime() - deleteArmed > 3 then
      deleteArmed = GetTime()
      deleteBtn:SetText("Sure?")
      C_Timer.After(3, function() deleteBtn:SetText("Delete") end)
      return
    end
    deleteArmed = 0
    deleteBtn:SetText("Delete")
    P.Delete(plan)
    currentId = nil
    panel:Refresh()
  end)

  shareBtn:SetScript("OnClick", function()
    local plan = Current()
    if plan and P.Share(plan) then ns.Print(("Shared \"%s\" with the guild."):format(plan.name)) end
  end)

  nightBtn:SetScript("OnClick", function()
    local E = ns.Events
    local items = {}
    local plan = Current()
    if plan and plan.night then
      items[#items + 1] = { text = "Unlink from " .. (P.NightName(plan.night) or "raid night"),
        onClick = function() P.LinkNight(plan, nil) end }
    end
    local now = ns.Now()
    local nights = E and E.Occurrences(now - 86400, now + 28 * 86400) or {}
    if #nights > 0 then items[#items + 1] = { text = UI.Dim("New plan from:", 0.45) } end
    for _, occ in ipairs(nights) do
      local yes, maybe = 0, 0
      for _, su in pairs(E.Signups(occ.id)) do
        if P.NIGHT_YES[su.status or ""] then yes = yes + 1 elseif su.status == "T" then maybe = maybe + 1 end
      end
      local linked = #P.ForNight(occ.id) > 0
      items[#items + 1] = {
        text = ("%s %s  %s  %s"):format(E.FormatDay(occ.start), E.FormatTime(occ.start), occ.event.title or "",
          UI.Dim(("%d coming%s%s"):format(yes, maybe > 0 and (", " .. maybe .. " maybe") or "",
            linked and ", has a plan" or ""), 0.45)),
        onClick = function()
          local new = P.FromNight(occ.id)
          if new then Select(new.id) end
        end,
      }
    end
    if #items == 0 then items[1] = { text = UI.Dim("No raid nights in the next 4 weeks", 0.5) } end
    T.Menu(nightBtn, items, 340)
  end)
  nightBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Plan from a raid night")
    GameTooltip:AddLine("Makes a new plan whose member list is the night's Accepted and Late sign-ups, with Tentative listed apart. Each person comes with the character and role they signed up with. New sign-ups appear as they come in; anyone placed who later declines is flagged, never moved.", 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
  end)
  nightBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  rankBtn:SetScript("OnClick", function()
    local names, n = P.RankNames()
    local items = {}
    for i = 0, n - 1 do
      items[#items + 1] = {
        text = "Up to " .. (names[i] or ("Rank " .. (i + 1))), checked = P.OfficerRank() == i,
        onClick = function() P.SetOfficerRank(i) end,
      }
    end
    T.Menu(rankBtn, items, 200)
  end)
  rankBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Officer ranks")
    GameTooltip:AddLine("Choose which guild ranks can create and share raid plans. Only the Guild Master can change this, and it syncs to everyone.", 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
  end)
  rankBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  ----------------------------------------------------------------------
  -- Pool (officers only)
  ----------------------------------------------------------------------
  local pool = CreateFrame("Frame", nil, panel)
  pool:SetPoint("TOPLEFT", 0, -54)
  pool:SetPoint("BOTTOMLEFT", 0, 0)
  pool:SetWidth(210)

  -- top bar: wraps onto more rows when the window is narrow
  status:SetJustifyH("LEFT")
  status:SetWordWrap(false)
  local bar = UI.Toolbar(panel)
  bar:Add(planBtn)
  bar:Add(renameBox)
  bar:Add(newBtn, { gap = 6 })
  bar:Add(renameBtn, { gap = 4 })
  bar:Add(deleteBtn, { gap = 4 })
  for i, b in ipairs(sizeBtns) do bar:Add(b, { gap = i == 1 and 14 or 3 }) end
  bar:Add(shareBtn, { gap = 14 })
  bar:Add(nightBtn, { gap = 6 })
  bar:Add(status, { newRow = true, grow = true, min = 120 })
  bar:Add(rankBtn, { right = true, gap = 10 })
  bar:Below(pool, { x = 0, gap = 4 })

  local poolSearch = T.SearchBox(pool, 210, "Find a member", function(t) filterText = t; panel:Refresh() end)
  poolSearch:SetPoint("TOPLEFT", 0, 0)
  local maxToggle = T.Toggle(pool, "Level " .. ns.MAX_LEVEL, function(v) maxOnly = v; panel:Refresh() end)
  maxToggle:SetPoint("TOPLEFT", 0, -28)
  local signedToggle = T.Toggle(pool, "Signed up", function(v) signedOnly = v; panel:Refresh() end)
  signedToggle:SetPoint("TOPLEFT", 0, -28)
  signedToggle:SetChecked(true)
  signedToggle:Hide()
  local onlineToggle = T.Toggle(pool, "Online", function(v) onlineOnly = v; panel:Refresh() end)
  local function PlaceToggles(linked)
    maxToggle:SetShown(not linked)
    signedToggle:SetShown(linked)
    onlineToggle:ClearAllPoints()
    onlineToggle:SetPoint("LEFT", linked and signedToggle or maxToggle, "RIGHT", 10, 0)
  end
  PlaceToggles(false)

  local poolList = UI.CreateList(pool, {
    { title = "Member", flex = true },
    { title = "Role", width = 22, justify = "CENTER" },
    { title = "Lvl", width = 22, justify = "RIGHT", defaultAsc = false },
  }, 22)
  poolList:SetPoint("TOPLEFT", 0, -54)
  poolList:SetPoint("BOTTOMRIGHT", 0, 30)
  -- dropping a planned member back on the pool takes them out of the plan
  poolList.OnDrop = function(_, payload)
    local plan = Current()
    if plan and payload.fromSlot then P.Remove(plan, payload.fromSlot) end
  end
  UI.RegisterDropTarget(poolList)

  local addBox = T.Input(pool, 104, "Add by name")
  addBox:SetPoint("BOTTOMLEFT", 0, 2)
  local addClass = "WARRIOR"
  local classBtn = T.Button(pool, CLASS_NAMES[addClass], 66, 22)
  classBtn:SetPoint("LEFT", addBox, "RIGHT", 4, 0)
  classBtn:SetScript("OnClick", function()
    local items = {}
    for _, c in ipairs(CLASSES) do
      items[#items + 1] = { text = ns.Icons.Class(c, 14) .. " " .. CLASS_NAMES[c], checked = c == addClass,
        onClick = function() addClass = c; classBtn:SetText(CLASS_NAMES[c]) end }
    end
    T.Menu(classBtn, items, 140)
  end)
  local addBtn = T.Button(pool, "Add", 32, 22)
  addBtn:SetPoint("LEFT", classBtn, "RIGHT", 4, 0)
  local function DoAdd()
    local plan = Current()
    local name = addBox:GetText() or ""
    if plan and name ~= "" and P.CanEdit("plans") then
      P.AddExtra(plan, name, addClass)
      addBox:SetText("")
      addBox:ClearFocus()
    end
  end
  addBtn:SetScript("OnClick", DoAdd)
  addBox:SetScript("OnEnterPressed", DoAdd)

  ----------------------------------------------------------------------
  -- Groups
  ----------------------------------------------------------------------
  local groupsArea = CreateFrame("Frame", nil, panel)
  local cards, slots = {}, {}
  local SLOT_H, HEADER_H, PARTY_H = 22, 20, 22

  local function SlotTooltip(self)
    local plan = Current()
    if not plan or not self.key then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    MemberTooltip(GameTooltip, P.Describe(plan, self.key))
    if self.flag then
      local why = self.flag == "D" and "Declined" or self.flag == "T" and "Changed to Tentative" or "Not signed up"
      GameTooltip:AddLine(" ")
      GameTooltip:AddLine(why .. " on the raid night", 1, 0.45, 0.35)
    end
    if P.CanEdit("plans") then
      GameTooltip:AddLine(" ")
      GameTooltip:AddLine("Drag to move. Right-click to remove. Ctrl-click to change role.", 0.6, 0.6, 0.6, true)
    end
    GameTooltip:Show()
  end

  for gi = 1, 8 do
    local card = CreateFrame("Frame", nil, groupsArea)
    T.Fill(card, { 0, 0, 0, 0.18 })
    T.Border(card, 0.06)
    card.title = T.Text(card, 11, T.section)
    card.title:SetPoint("TOPLEFT", 8, -5)
    card.title:SetText("GROUP " .. gi)
    card.count = T.Text(card, 11, 0.35)
    card.count:SetPoint("TOPRIGHT", -8, -5)
    card.partyIcons = {}
    for k = 1, 16 do
      local ib = CreateFrame("Button", nil, card)
      ib:SetSize(16, 16)
      ib.tex = ib:CreateTexture(nil, "ARTWORK")
      ib.tex:SetAllPoints()
      ib.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
      ib:SetPoint("BOTTOMLEFT", 6 + (k - 1) * 18, 4)
      ib:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        BuffTooltip(GameTooltip, self.buff, self.providers)
        GameTooltip:Show()
      end)
      ib:SetScript("OnLeave", function() GameTooltip:Hide() end)
      ib:Hide()
      card.partyIcons[k] = ib
    end
    card.noParty = T.Text(card, 11, 0.25)
    card.noParty:SetPoint("BOTTOMLEFT", 8, 7)
    card.noParty:SetText("No party buffs")
    cards[gi] = card

    for si = 1, 5 do
      local index = (gi - 1) * 5 + si
      local s = CreateFrame("Button", nil, card)
      s:SetHeight(SLOT_H)
      s:SetPoint("TOPLEFT", 1, -(HEADER_H + (si - 1) * SLOT_H))
      s:SetPoint("TOPRIGHT", -1, -(HEADER_H + (si - 1) * SLOT_H))
      s:RegisterForClicks("LeftButtonUp", "RightButtonUp")
      s:RegisterForDrag("LeftButton")
      s.index = index
      s.bg = T.Fill(s, { 1, 1, 1, 0 })
      local hl = s:CreateTexture(nil, "HIGHLIGHT")
      hl:SetAllPoints()
      hl:SetColorTexture(1, 1, 1, 0.05)
      s.mine = s:CreateTexture(nil, "OVERLAY")
      s.mine:SetPoint("TOPLEFT")
      s.mine:SetPoint("BOTTOMLEFT")
      s.mine:SetWidth(2)
      s.name = T.Text(s, 12)
      s.name:SetPoint("LEFT", 6, 0)
      s.name:SetPoint("RIGHT", -24, 0)
      s.name:SetJustifyH("LEFT")
      s.name:SetWordWrap(false)
      s.role = T.Text(s, 11)
      s.role:SetPoint("RIGHT", -6, 0)
      function s:SetDropHover(on)
        local r, g, b = T.Accent()
        self.bg:SetColorTexture(r, g, b, on and 0.18 or 0)
      end
      s.OnDrop = function(self, payload)
        local plan = Current()
        if plan and P.CanEdit("plans") and payload.key then P.Place(plan, payload.key, self.index) end
      end
      UI.RegisterDropTarget(s)
      s:SetScript("OnEnter", SlotTooltip)
      s:SetScript("OnLeave", function() GameTooltip:Hide() end)
      s:SetScript("OnDragStart", function(self)
        if not self.key or not P.CanEdit("plans") then return end
        GameTooltip:Hide()
        UI.BeginDrag({ key = self.key, fromSlot = self.index }, ns.ShortName(self.key))
      end)
      s:SetScript("OnClick", function(self, button)
        local plan = Current()
        if not plan or not P.CanEdit("plans") then return end
        if button == "RightButton" then
          if self.key then P.Remove(plan, self.index) end
        elseif IsControlKeyDown() and self.key then
          local d = P.Describe(plan, self.key)
          local nextRole = "TANK"
          for i, r in ipairs(ns.ROLES) do if r == d.role then nextRole = ns.ROLES[i % #ns.ROLES + 1] end end
          plan.roles[self.key] = nextRole
          P.Touch(plan)
        elseif selectedKey then
          P.Place(plan, selectedKey, self.index)
          selectedKey = nil
        end
      end)
      slots[index] = s
    end
  end

  ----------------------------------------------------------------------
  -- Coverage
  ----------------------------------------------------------------------
  local coverage = CreateFrame("Frame", nil, panel)
  local rolesText = T.Text(coverage, 12, 0.8)
  rolesText:SetPoint("TOPLEFT", 0, 0)
  local covRows = {}
  local y = -24
  for _, catInfo in ipairs(ns.BUFF_CATEGORIES) do
    if catInfo.cat ~= "party" then
      local label = T.Text(coverage, 11, T.section)
      label:SetPoint("TOPLEFT", 0, y - 4)
      label:SetText(catInfo.title:upper())
      local icons, x = {}, 96
      for _, b in ipairs(ns.BUFFS) do
        if b.cat == catInfo.cat then
          local ib = CreateFrame("Button", nil, coverage)
          ib:SetSize(20, 20)
          ib:SetPoint("TOPLEFT", x, y)
          ib.tex = ib:CreateTexture(nil, "ARTWORK")
          ib.tex:SetPoint("TOPLEFT", 1, -1)
          ib.tex:SetPoint("BOTTOMRIGHT", -1, 1)
          ib.tex:SetTexture(b.icon)
          ib.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
          T.Border(ib, 0.1)
          ib.buff = b
          ib:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            BuffTooltip(GameTooltip, self.buff, self.providers)
            GameTooltip:Show()
          end)
          ib:SetScript("OnLeave", function() GameTooltip:Hide() end)
          icons[#icons + 1] = ib
          x = x + 23
        end
      end
      covRows[#covRows + 1] = { cat = catInfo.cat, icons = icons }
      y = y - 26
    end
  end
  local COVERAGE_H = -y

  local emptyText = T.Text(panel, 13, 0.4)
  emptyText:SetPoint("CENTER", 0, 20)
  emptyText:SetJustifyH("CENTER")
  local createBtn = T.Button(panel, "Create a plan", 120, 24)
  createBtn:SetPoint("TOP", emptyText, "BOTTOM", 0, -12)
  createBtn:SetScript("OnClick", function() newBtn:Click() end)

  ----------------------------------------------------------------------
  -- Layout
  ----------------------------------------------------------------------
  local function Layout(plan, canEdit)
    bar:Layout()
    groupsArea:ClearAllPoints()
    groupsArea:SetPoint("TOPLEFT", canEdit and 224 or 0, -(bar.h + 4))
    groupsArea:SetPoint("RIGHT", panel, "RIGHT", 0, 0)
    local width = (panel:GetWidth() or 680) - (canEdit and 224 or 0)
    local groups = math.ceil((plan and plan.size or 20) / 5)
    local perRow = math.min(4, groups)
    local cardW = math.floor((width - (perRow - 1) * 8) / perRow)
    local cardH = HEADER_H + 5 * SLOT_H + PARTY_H + 4
    local rows = math.ceil(groups / perRow)
    for gi = 1, 8 do
      local card = cards[gi]
      if gi <= groups then
        local row, col = math.floor((gi - 1) / perRow), (gi - 1) % perRow
        card:ClearAllPoints()
        card:SetPoint("TOPLEFT", groupsArea, "TOPLEFT", col * (cardW + 8), -row * (cardH + 8))
        card:SetSize(cardW, cardH)
        card:Show()
      else
        card:Hide()
      end
    end
    groupsArea:SetHeight(rows * (cardH + 8))
    coverage:ClearAllPoints()
    coverage:SetPoint("TOPLEFT", groupsArea, "BOTTOMLEFT", 0, -6)
    coverage:SetPoint("RIGHT", panel, "RIGHT", 0, 0)
    coverage:SetHeight(COVERAGE_H)
  end
  panel:SetScript("OnSizeChanged", function() if panel:IsShown() then panel:Refresh() end end)

  ----------------------------------------------------------------------
  function panel:Refresh()
    local plan = Current()
    local canEdit = P.CanEdit("plans")
    local ar, ag, ab = T.Accent()

    for _, b in ipairs({ newBtn, nightBtn }) do b:SetShown(canEdit) end
    for _, b in ipairs({ renameBtn, deleteBtn, shareBtn }) do b:SetShown(canEdit and plan ~= nil) end
    for i, b in ipairs(sizeBtns) do
      b:SetShown(canEdit and plan ~= nil)
      b:SetSelected(plan and plan.size == P.SIZES[i])
    end
    rankBtn:SetShown(P.IsGuildMaster())
    if P.IsGuildMaster() then
      local names = P.RankNames()
      rankBtn:SetText("Officers: up to " .. (names[P.OfficerRank()] or ("rank " .. (P.OfficerRank() + 1))))
    end
    pool:SetShown(canEdit and plan ~= nil)

    if not plan then
      planBtn:SetText(UI.Dim("No plans", 0.5))
      groupsArea:Hide(); coverage:Hide()
      emptyText:Show()
      emptyText:SetText(canEdit and "No raid plans yet" or "No raid plans have been shared yet.\nOfficers create and share them here.")
      createBtn:SetShown(canEdit)
      status:SetText("")
      UI.SetHint(canEdit and "Create a plan, then drag members into groups." or "")
      return
    end
    emptyText:Hide(); createBtn:Hide()
    groupsArea:Show(); coverage:Show()
    planBtn:SetText(plan.name)
    shareBtn:SetSelected(plan.dirty or not plan.shared)
    shareBtn:SetText(plan.shared and (plan.dirty and "Share" or "Shared") or "Share")

    Layout(plan, canEdit)

    -- slots
    local cov = P.Coverage(plan)
    local myKey = ns.MyKey()
    local mySlot
    local problems, flagged = P.NightProblems(plan), {}
    for _, pr in ipairs(problems) do flagged[pr.key] = pr.status end
    for index, s in ipairs(slots) do
      local key = index <= plan.size and plan.slots[index] or nil
      s.key = key
      if key then
        local d = P.Describe(plan, key)
        local name = UI.NameCell(key, d.class, d.online)
        if flagged[key] then name = UI.Colorize("! ", 1, 0.45, 0.35) .. name end
        s.name:SetText(name)
        s.flag = flagged[key]
        s.role:SetText(RoleTag(d.role, true))
        if key == myKey then mySlot = index end
      else
        s.flag = nil
        s.name:SetText(UI.Dim(selectedKey and "Click to place" or "Empty", selectedKey and 0.5 or 0.22))
        s.role:SetText("")
      end
      if key == myKey then s.mine:SetColorTexture(ar, ag, ab, 1) else s.mine:SetColorTexture(0, 0, 0, 0) end
    end

    -- per-group party buffs
    for gi = 1, math.ceil(plan.size / 5) do
      local card, grp = cards[gi], cov.groups[gi]
      card.count:SetText(#grp.members .. "/5")
      local list = {}
      for id, providers in pairs(grp.party) do list[#list + 1] = { b = ns.BUFF_BY_ID[id], providers = providers } end
      table.sort(list, function(a, b) return a.b.order < b.b.order end)
      local maxIcons = math.max(1, math.floor(((card:GetWidth() or 120) - 12) / 18))
      for k, ib in ipairs(card.partyIcons) do
        local item = list[k]
        if item and k <= maxIcons then
          ib.buff, ib.providers = item.b, item.providers
          ib.tex:SetTexture(item.b.icon)
          ib:Show()
        else
          ib:Hide()
        end
      end
      card.noParty:SetShown(#list == 0)
    end

    -- raid coverage
    local r = cov.roles
    rolesText:SetText(("%s %d    %s %d    %s %d    %s %d    %s"):format(
      RoleTag("TANK"), r.TANK, RoleTag("HEALER"), r.HEALER, RoleTag("MELEE"), r.MELEE, RoleTag("RANGED"), r.RANGED,
      UI.Dim(("%d / %d players"):format(cov.count, plan.size), 0.55)))
    for _, row in ipairs(covRows) do
      for _, ib in ipairs(row.icons) do
        local providers = cov.providers[ib.buff.id]
        ib.providers = providers
        local has = providers and #providers > 0
        ib.tex:SetDesaturated(not has)
        ib.tex:SetAlpha(has and 1 or 0.3)
        if has then ib:SetBorderColor(ar, ag, ab, 0.7) else ib:SetBorderAlpha(0.08) end
      end
    end

    -- status line
    local bits = {}
    if plan.shared then
      bits[#bits + 1] = ("Shared by %s, %s"):format(ns.ShortName(plan.author), UI.TimeAgo(plan.ts))
      if plan.dirty then bits[#bits + 1] = UI.Colorize("unshared changes", ar, ag, ab) end
    else
      bits[#bits + 1] = UI.Colorize("Not shared yet", ar, ag, ab)
    end
    if plan.night then
      local nightName = P.NightName(plan.night)
      bits[#bits + 1] = nightName and ("From " .. nightName) or UI.Dim("raid night removed", 0.45)
      if #problems > 0 then
        bits[#bits + 1] = UI.Colorize(("%d no longer coming"):format(#problems), 1, 0.45, 0.35)
      end
    end
    if mySlot then bits[#bits + 1] = ("You're in group %d"):format(math.ceil(mySlot / 5)) end
    if not canEdit then bits[#bits + 1] = "View only" end
    if P.TestMode() then bits[#bits + 1] = UI.Colorize("Test officer mode", 1, 0.55, 0.3) end
    status:SetText(table.concat(bits, "  ·  "))

    -- pool
    if canEdit then
      local items = {}
      local inPlan = {}
      for i, k in pairs(plan.slots) do if i <= plan.size then inPlan[k] = true end end
      local seen = {}
      local function AddPoolItem(key)
        if seen[key] or inPlan[key] then return end
        seen[key] = true
        local d = P.Describe(plan, key)
        if maxOnly and (d.level or 0) < ns.MAX_LEVEL and not d.extra then return end
        if onlineOnly and not d.online then return end
        if filterText ~= "" and not ns.ShortName(key):lower():find(filterText, 1, true) then return end
        local isSel = selectedKey == key
        local nameText = UI.NameCell(key, d.class, d.online)
        if isSel then nameText = UI.Colorize("> ", ar, ag, ab) .. nameText end
        items[#items + 1] = {
          cols = { nameText, RoleTag(d.role, true), d.level and tostring(d.level) or UI.Dim("?", 0.4) },
          sort = { ns.ShortName(key):lower(), d.role or "", d.level or 0 },
          tooltip = function(tt) MemberTooltip(tt, d); tt:AddLine(" "); tt:AddLine("Drag into a group, or click then click a slot.", 0.6, 0.6, 0.6, true) end,
          onClick = function(_, button)
            if button == "LeftButton" then
              selectedKey = (selectedKey ~= key) and key or nil
              panel:Refresh()
            end
          end,
          onDragStart = function() UI.BeginDrag({ key = key }, ns.ShortName(key)) end,
        }
      end
      local linked = plan.night ~= nil and P.NightName(plan.night) ~= nil
      if signedFor ~= plan.id then signedFor = plan.id; signedOnly = true; signedToggle:SetChecked(true) end
      PlaceToggles(linked)
      if linked and signedOnly then
        -- the night's people: Accepted/Late by role, then Tentative apart
        local people = P.NightPeople(plan)
        local roleOrder = { TANK = 1, HEALER = 2, MELEE = 3, RANGED = 4 }
        local function ByRole(list)
          table.sort(list, function(a, b)
            local ra = roleOrder[P.Describe(plan, a).role or ""] or 9
            local rb = roleOrder[P.Describe(plan, b).role or ""] or 9
            if ra ~= rb then return ra < rb end
            return a < b
          end)
          return list
        end
        for _, key in ipairs(ByRole(people.yes)) do
          local before = #items
          AddPoolItem(key)
          if #items > before and people.status[key] == "L" then
            items[#items].cols[1] = items[#items].cols[1] .. UI.Dim("  late", 0.45)
          end
        end
        for key in pairs(plan.extras) do AddPoolItem(key) end
        local before = #items
        local maybe = ByRole(people.maybe)
        for _, key in ipairs(maybe) do AddPoolItem(key) end
        if #items > before then
          table.insert(items, before + 1, { header = true,
            cols = { UI.Dim(("TENTATIVE (%d)"):format(#items - before), 0.45), "", "" } })
        end
        poolList.sortable = false
        poolList:SetItems(items, #people.yes + #people.maybe == 0 and "Nobody has signed up yet"
          or "Everyone who signed up is in the plan")
      else
        for _, m in ipairs(ns.AllMembers()) do AddPoolItem(m.key) end
        for key in pairs(plan.extras) do AddPoolItem(key) end
        poolList.sortable = true
        poolList:SetItems(items, "Everyone matching is already in the plan")
      end
      UI.SetHint(selectedKey and ("Click a slot to place " .. ns.ShortName(selectedKey) .. ".")
        or "Drag members into groups. Ctrl-click a slot to change role, right-click to remove.")
    else
      UI.SetHint(mySlot and "Your slot is marked. Hover anyone to see their spec and buffs." or "Hover anyone to see their spec and buffs.")
    end
  end
end, "raidgroup")

ns.On("PLANS_CHANGED", function() if ns.UI.QueueRefresh then ns.UI.QueueRefresh() end end)
