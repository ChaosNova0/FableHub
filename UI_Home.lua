-- Home: the dashboard FableHub opens on.
--   left:  Message of the Day, Announcements, Recent loot
--   right: Upcoming raids (with sign-up buttons), Craft requests, Bank requests (officers only), Online now

local _, ns = ...
local UI, T, P = ns.UI, ns.Theme, ns.Plans

local GOLD, GREEN = { 1, 0.82, 0 }, { 0.4, 0.85, 0.5 }
local STATUS_COLORS = { A = GREEN, L = { 0.95, 0.78, 0.35 }, T = { 0.65, 0.7, 1 }, D = { 0.9, 0.4, 0.4 } }

local HEAD, ROW, PAD = 28, 22, 10

-- A card with a clickable title that collapses it to just the title bar
local function Card(parent, id, title, onToggle)
  local f = CreateFrame("Frame", nil, parent)
  T.Fill(f, { 0, 0, 0, 0.18 })
  T.Border(f, 0.06)
  f.id, f.label = id, title
  f.title = T.Text(f, 11, T.section)
  f.title:SetPoint("TOPLEFT", 10, -8)
  f.body = CreateFrame("Frame", nil, f)
  f.body:SetPoint("TOPLEFT", 10, -26)
  f.body:SetPoint("BOTTOMRIGHT", -10, 8)
  f.links = {}
  local head = CreateFrame("Button", nil, f)
  head:SetPoint("TOPLEFT", 0, 0)
  head:SetPoint("TOPRIGHT", -120, 0)
  head:SetHeight(26)
  head:SetScript("OnEnter", function() local r, g, b = T.Accent(); f.title:SetTextColor(r, g, b, 1) end)
  head:SetScript("OnLeave", function() f.title:SetTextColor(1, 1, 1, T.section) end)
  head:SetScript("OnClick", function()
    local c = FableHubDB.settings.homeCollapsed or {}
    FableHubDB.settings.homeCollapsed = c
    c[id] = not c[id] or nil
    onToggle()
  end)
  function f:Collapsed()
    local c = FableHubDB.settings.homeCollapsed
    return c and c[id] and true or false
  end
  function f:SetLabel(text) self.label = text end
  function f:Apply()
    local col = self:Collapsed()
    self.title:SetText((col and "+  " or "-  ") .. self.label)
    self.body:SetShown(not col)
    for _, l in ipairs(self.links) do l:SetShown(not col and l.wanted ~= false) end
  end
  return f
end

-- Size the cards of one column: each fits its content; if they don't all fit,
-- the cards holding scrolling lists give up space (largest first).
local function FitColumn(cards, avail, gap)
  local heights, total = {}, 0
  for i, c in ipairs(cards) do
    heights[i] = c:Collapsed() and HEAD or math.max(HEAD + ROW + PAD, c.want or 60)
    total = total + heights[i]
  end
  total = total + gap * (#cards - 1)
  local over = total - avail
  while over > 0 do
    local best
    for i, c in ipairs(cards) do
      local minH = HEAD + ROW * 2 + PAD
      if c.flexible and not c:Collapsed() and heights[i] > minH and (not best or heights[i] > heights[best]) then best = i end
    end
    if not best then break end
    local minH = HEAD + ROW * 2 + PAD
    local take = math.min(over, heights[best] - minH)
    heights[best] = heights[best] - take
    over = over - take
    if take <= 0 then break end
  end
  return heights
end

local function Link(card, text, onClick)
  local b = CreateFrame("Button", nil, card)
  b:SetHeight(16)
  local fs = T.Text(b, 11, 0.5)
  fs:SetPoint("RIGHT")
  fs:SetText(text)
  b:SetWidth((fs:GetStringWidth() or 60) + 4)
  b:SetPoint("TOPRIGHT", -10, -6)
  b:SetScript("OnEnter", function() local r, g, bl = T.Accent(); fs:SetTextColor(r, g, bl, 1) end)
  b:SetScript("OnLeave", function() fs:SetTextColor(1, 1, 1, 0.5) end)
  b:SetScript("OnClick", onClick)
  b.text = fs
  table.insert(card.links, b)
  return b
end

local function Go(id) if ns.UI.ShowPanel then ns.UI.ShowPanel(id) end end

-- Setup still to do, as short tips. Each disappears once it's done.
local NO_RECIPES = { [356] = true, [794] = true } -- Fishing, Archaeology
function ns.HomeTips()
  local tips = {}
  local rec = ns.MyRecord and ns.MyRecord()
  local missing = {}
  for skillLine, p in pairs(rec and rec.profs or {}) do
    if ns.ProfCategory(skillLine) ~= "gather" and not NO_RECIPES[skillLine] and not next(p.recipes or {}) then
      missing[#missing + 1] = p.name or "?"
    end
  end
  table.sort(missing)
  if #missing > 0 then
    tips[#tips + 1] = ("Open your %s window once so the guild can see your recipes."):format(
      (table.concat(missing, ", "):gsub(", ([^,]+)$", " and %1")))
  end
  local g = ns.GuildDB and ns.GuildDB()
  if g and P.IsGuildMaster() then
    if not g.officerRankTs then
      tips[#tips + 1] = "Choose which ranks are officers: the cog (top right) > Officer ranks."
    end
    if not (g.bank and g.bank.perm) then
      tips[#tips + 1] = "Open the guild bank once, so FableHub learns which ranks may see each tab."
    end
  end
  if g and P.CanEdit("loot") and not g.tmb then
    tips[#tips + 1] = "Officers: import your That's My BIS priorities under Loot > Priorities."
  end
  return tips
end

ns.RegisterPanel("home", "Home", "Interface\\Icons\\INV_Misc_Note_01", function(panel)
  local function Toggle() panel:Refresh() end
  local motd = Card(panel, "motd", "MESSAGE OF THE DAY", Toggle)
  local news = Card(panel, "news", "ANNOUNCEMENTS", Toggle)
  local activity = Card(panel, "activity", "GUILD ACTIVITY", Toggle)
  local loot = Card(panel, "loot", "RECENT LOOT", Toggle)
  local raids = Card(panel, "raids", "UPCOMING RAIDS", Toggle)
  local reqs = Card(panel, "reqs", "CRAFT REQUESTS", Toggle)
  local online = Card(panel, "online", "ONLINE NOW", Toggle)
  local bankReqs = Card(panel, "bankreqs", "BANK REQUESTS", Toggle) -- officers only
  local tips = Card(panel, "tips", "GETTING STARTED", Toggle)        -- while there's setup left
  for _, c in ipairs({ news, activity, loot, reqs, online, bankReqs }) do c.flexible = true end
  local leftCards, rightCards = { motd, news, activity, loot }, { raids, reqs, online }
  local allLeft = { tips, motd, news, activity, loot }
  local allRight = { raids, reqs, bankReqs, online }

  -- Getting started
  local tipsText = T.Text(tips.body, 12, 0.85)
  tipsText:SetPoint("TOPLEFT")
  tipsText:SetPoint("RIGHT", tips.body, "RIGHT")
  tipsText:SetJustifyH("LEFT"); tipsText:SetJustifyV("TOP")
  tipsText:SetSpacing(3)
  Link(tips, "Hide", function() ns.SetOption("homeTips", false); panel:Refresh() end)

  -- Message of the Day
  local motdText = T.Text(motd.body, 12, 0.85)
  motdText:SetPoint("TOPLEFT")
  motdText:SetPoint("RIGHT", motd.body, "RIGHT")
  motdText:SetJustifyH("LEFT"); motdText:SetJustifyV("TOP")

  -- Announcements
  local composing = false
  local postLink = Link(news, "+ Post", function() composing = not composing; panel:Refresh() end)
  local composer = CreateFrame("Frame", nil, news.body)
  composer:SetPoint("TOPLEFT"); composer:SetPoint("TOPRIGHT")
  composer:SetHeight(26)
  local input = T.Input(composer, 200, "Write an announcement (200 characters)")
  input:SetPoint("LEFT")
  input:SetMaxLetters(ns.Announce.MAX_LEN)
  local pinNew = false
  local pinToggle = T.Toggle(composer, "Pin", function(v) pinNew = v end)
  local postBtn = T.Button(composer, "Post", 56, 22)
  postBtn:SetPoint("RIGHT")
  pinToggle:SetPoint("RIGHT", postBtn, "LEFT", -8, 0)
  input:SetPoint("RIGHT", pinToggle, "LEFT", -8, 0)
  local function DoPost()
    if ns.Announce.Post(input:GetText(), pinNew) then
      input:SetText(""); input:ClearFocus(); composing = false; pinNew = false; pinToggle:SetChecked(false)
      panel:Refresh()
    end
  end
  postBtn:SetScript("OnClick", DoPost)
  input:SetScript("OnEnterPressed", DoPost)
  local newsList = UI.CreateList(news.body, { { title = "", flex = true }, { title = "", width = 110, justify = "RIGHT" } }, 22, { noHeader = true })
  local function TopEmpty(l)
    l.emptyText:ClearAllPoints()
    l.emptyText:SetPoint("TOPLEFT", 2, -3)
    l.emptyText:SetJustifyH("LEFT")
  end

  -- Guild activity
  local actList = UI.CreateList(activity.body, { { title = "", flex = true }, { title = "", width = 64, justify = "RIGHT" } }, 22, { noHeader = true })
  actList:SetAllPoints()
  actList.sortable = false

  -- Recent loot
  Link(loot, "All loot", function() Go("loothistory") end)
  local lootList = UI.CreateList(loot.body, { { title = "", flex = true }, { title = "", width = 130 }, { title = "", width = 50, justify = "RIGHT" } }, 22, { noHeader = true })
  lootList:SetAllPoints()
  lootList.sortable = false
  TopEmpty(newsList); TopEmpty(lootList); TopEmpty(actList)

  -- Upcoming raids
  Link(raids, "All raid nights", function() Go("events") end)
  local raidLines = {}
  for i = 1, 3 do
    local b = CreateFrame("Button", nil, raids.body)
    b:SetHeight(20)
    local hl = b:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.04)
    b.left = T.Text(b, 12, 0.9); b.left:SetPoint("LEFT", 2, 0); b.left:SetJustifyH("LEFT"); b.left:SetWordWrap(false)
    b.right = T.Text(b, 11, 0.8); b.right:SetPoint("RIGHT", -2, 0)
    b.left:SetPoint("RIGHT", b.right, "LEFT", -6, 0)
    b:SetScript("OnClick", function() Go("events") end)
    raidLines[i] = b
  end
  local signRow = CreateFrame("Frame", nil, raids.body)
  signRow:SetHeight(22)
  local signLabel = T.Text(signRow, 11, 0.5); signLabel:SetPoint("LEFT")
  local signBtns, order = {}, { "A", "L", "T", "D" }
  local labels = { A = "Accept", L = "Late", T = "Tentative", D = "Decline" }
  for i, st in ipairs(order) do
    local b = T.Button(signRow, labels[st], st == "T" and 72 or 58, 20)
    if i == 1 then b:SetPoint("LEFT", signLabel, "RIGHT", 8, 0) else b:SetPoint("LEFT", signBtns[order[i - 1]], "RIGHT", 3, 0) end
    signBtns[st] = b
  end
  local raidsEmpty = T.Text(raids.body, 12, 0.4); raidsEmpty:SetPoint("TOPLEFT", 2, -2)

  -- Crafting requests
  Link(reqs, "All craft requests", function() Go("requests") end)
  local reqList = UI.CreateList(reqs.body, { { title = "", flex = true }, { title = "", width = 130, justify = "RIGHT" } }, 22, { noHeader = true })
  reqList:SetAllPoints()
  reqList.sortable = false
  TopEmpty(reqList)

  -- Guild bank requests (officers)
  Link(bankReqs, "All bank requests", function() Go("bankrequests") end)
  local bankList = UI.CreateList(bankReqs.body, { { title = "", flex = true }, { title = "", width = 150, justify = "RIGHT" } }, 22, { noHeader = true })
  bankList:SetAllPoints()
  bankList.sortable = false
  TopEmpty(bankList)

  -- Online now
  Link(online, "Roster", function() Go("roster") end)
  local onlineList = UI.CreateList(online.body, { { title = "", flex = true }, { title = "", width = 26, justify = "RIGHT" }, { title = "", width = 110 } }, 22, { noHeader = true })
  onlineList:SetAllPoints()
  TopEmpty(onlineList)

  ----------------------------------------------------------------------
  local function Widths()
    local w = panel:GetWidth() or 680
    local lw = math.floor((w - 10) * 0.56)
    for _, c in ipairs(allLeft) do c:SetWidth(lw) end
    for _, c in ipairs(allRight) do c:SetWidth(w - 10 - lw) end
  end
  local function Layout()
    local gap = 10
    local avail = panel:GetHeight() or 470
    for _, col in ipairs({ { cards = leftCards, side = "LEFT" }, { cards = rightCards, side = "RIGHT" } }) do
      local heights = FitColumn(col.cards, avail, gap)
      local y = 0
      for i, c in ipairs(col.cards) do
        c:Apply()
        c:ClearAllPoints()
        c:SetPoint("TOP" .. col.side, panel, "TOP" .. col.side, 0, -y)
        c:SetHeight(heights[i])
        y = y + heights[i] + gap
      end
    end
  end
  panel:SetScript("OnSizeChanged", function() if panel:IsShown() then panel:Refresh() end end)

  function panel:Refresh()
    Widths()
    local canEdit = P.CanEdit("announce")
    local now = ns.Now()
    local ar, ag, ab = T.Accent()

    -- Getting started (only while there's something to do)
    local tipList = ns.Option("homeTips") and ns.HomeTips() or {}
    if #tipList > 0 then
      for i, t in ipairs(tipList) do tipList[i] = UI.Colorize("- ", ar, ag, ab) .. t end
      tipsText:SetText(table.concat(tipList, "\n"))
      tips.want = HEAD + (tipsText:GetStringHeight() or 14) + PAD + 2
      leftCards = { tips, motd, news, activity, loot }
      tips:Show()
    else
      leftCards = { motd, news, activity, loot }
      tips:Hide()
    end

    -- MOTD
    local m = GetGuildRosterMOTD and GetGuildRosterMOTD() or ""
    motdText:SetText(m ~= "" and m or UI.Dim("No message of the day set.", 0.45))
    motd.want = HEAD + math.max(14, motdText:GetStringHeight() or 14) + PAD + 2

    -- Announcements
    postLink.wanted = canEdit
    postLink.text:SetText(composing and "Cancel" or "+ Post")
    composer:SetShown(canEdit and composing)
    newsList:ClearAllPoints()
    newsList:SetPoint("TOPLEFT", 0, (canEdit and composing) and -30 or 0)
    newsList:SetPoint("BOTTOMRIGHT")
    newsList.sortable = false
    local rows = {}
    for _, a in ipairs(ns.Announce.List()) do
      local tag = a.pinned and (UI.Colorize("PINNED", ar, ag, ab) .. "  ") or ""
      rows[#rows + 1] = {
        cols = { tag .. a.text, UI.Dim(ns.ShortName(a.by) .. ", " .. UI.TimeAgo(a.created), 0.45) },
        tooltip = function(tt)
          tt:AddLine(a.pinned and "Pinned announcement" or "Announcement", 1, 0.82, 0)
          tt:AddLine(a.text, 1, 1, 1, true)
          tt:AddLine(" ")
          tt:AddLine(("Posted by %s, %s"):format(ns.ShortName(a.by), date("%d %b %H:%M", a.created)), 0.6, 0.6, 0.6)
          if not a.pinned then
            local left = math.max(0, math.ceil((a.created + ns.Announce.EXPIRE - now) / 86400))
            tt:AddLine(("Disappears in %d day%s unless pinned."):format(left, left == 1 and "" or "s"), 0.6, 0.6, 0.6)
          end
          if canEdit then tt:AddLine("Right-click to pin or delete.", 0.6, 0.6, 0.6) end
        end,
        onClick = function(_, button)
          if button ~= "RightButton" or not canEdit then return end
          T.Menu(newsList, {
            { text = a.pinned and "Unpin (disappears 14 days after posting)" or "Pin (keep it until unpinned)",
              onClick = function() ns.Announce.SetPinned(a, not a.pinned) end },
            { text = UI.Colorize("Delete", 0.95, 0.45, 0.4), onClick = function() ns.Announce.Delete(a) end },
          }, 260)
        end,
      }
    end
    newsList:SetItems(rows, canEdit and "No announcements. Click + Post to add one." or "No announcements right now.")
    news.want = HEAD + ((canEdit and composing) and 30 or 0) + math.max(1, #rows) * ROW + PAD

    -- Guild activity
    rows = {}
    local ICON = { level = "Interface\\Icons\\Spell_Holy_SurgeOfLight", join = "Interface\\Icons\\INV_Misc_GroupLooking",
      leave = "Interface\\Icons\\Ability_Rogue_Sprint", raid = "Interface\\Icons\\INV_Misc_PocketWatch_01",
      craft = "Interface\\Icons\\Trade_BlackSmithing", recipe = "Interface\\Icons\\INV_Scroll_03", skill = "Interface\\Icons\\Trade_BlackSmithing" }
    for i, e in ipairs(ns.Activity.List()) do
      if i > 40 then break end
      local icon = e.icon or ICON[e.kind]
      local iconText = icon and ("|T%s:14:14:0:0:64:64:5:59:5:59|t  "):format(tostring(icon)) or ""
      rows[#rows + 1] = {
        cols = { iconText .. e.text, UI.Dim(UI.TimeAgo(e.t), 0.45) },
        tooltip = function(tt) tt:AddLine(e.text, 1, 1, 1, true); tt:AddLine(date("%d %b %H:%M", e.t), 0.6, 0.6, 0.6) end,
      }
    end
    actList:SetItems(rows, "Nothing yet. Level-ups, profession milestones, new members and more will show here.")
    activity.want = HEAD + math.max(1, #rows) * ROW + PAD

    -- Recent loot
    rows = {}
    for i, e in ipairs(ns.Loot.Entries()) do
      if i > 8 then break end
      rows[#rows + 1] = {
        cols = { ns.Loot.ItemText(e.item), UI.NameCell(e.to, (ns.roster[e.to] or {}).class, ns.IsOnline(e.to)), UI.Dim(date("%d %b", e.at), 0.5) },
        tooltip = function(tt) pcall(tt.SetItemByID, tt, e.item) end,
        onClick = function() Go("loothistory") end,
      }
    end
    lootList:SetItems(rows, "No loot recorded yet.")
    loot.want = HEAD + math.max(1, #rows) * ROW + PAD

    -- Upcoming raids
    local E = ns.Events
    local occs = E.Occurrences(now, now + 21 * 86400)
    raidsEmpty:SetShown(#occs == 0)
    raidsEmpty:SetText("No raid nights planned.")
    local y = 0
    for i, b in ipairs(raidLines) do
      local occ = occs[i]
      b:SetShown(occ ~= nil)
      if occ then
        b:ClearAllPoints(); b:SetPoint("TOPLEFT", 0, y); b:SetPoint("TOPRIGHT", 0, y)
        local mine = E.MySignup(occ.id)
        local running = now >= occ.start and now <= occ.finish
        b.left:SetText(("%s %s  %s%s"):format(E.FormatDay(occ.start), UI.Dim(E.FormatTime(occ.start), 0.6), occ.event.title,
          running and ("  " .. UI.Colorize("now", GREEN[1], GREEN[2], GREEN[3])) or ""))
        local c = mine and STATUS_COLORS[mine.status]
        b.right:SetText(mine and UI.Colorize(E.STATUS[mine.status], c[1], c[2], c[3]) or UI.Dim("not signed up", 0.45))
        y = y - 22
        if i == 1 then
          -- sign-up buttons for the next raid night
          signRow:ClearAllPoints(); signRow:SetPoint("TOPLEFT", 0, y); signRow:SetPoint("TOPRIGHT", 0, y)
          signLabel:SetText("Sign up:")
          for st, btn in pairs(signBtns) do
            btn:SetSelected(mine and mine.status == st)
            btn:SetScript("OnClick", function()
              local cur = E.MySignup(occ.id)
              local char = (cur and cur.char) or ns.MyKey()
              local role = (cur and cur.role) or P.Describe(nil, char).role
              E.SignUp(occ.id, st, char, role, cur and cur.note or "")
            end)
          end
          y = y - 28
        end
      end
    end
    signRow:SetShown(occs[1] ~= nil and occs[1].finish > now)
    raids.want = HEAD + math.max(20, -y) + PAD

    -- Crafting requests: ones I can craft, then my own
    local R = ns.Requests
    rows = {}
    local me = ns.MyKey()
    local list = {}
    for _, r in pairs(R.All()) do
      if R.Active(r) then
        if r.by ~= me and r.status == "open" and R.ICanCraft(r) then list[#list + 1] = { r = r, kind = 1 }
        elseif r.by == me then list[#list + 1] = { r = r, kind = 2 }
        elseif r.claimer == me then list[#list + 1] = { r = r, kind = 3 } end
      end
    end
    table.sort(list, function(a, b) if a.kind ~= b.kind then return a.kind < b.kind end return (a.r.created or 0) > (b.r.created or 0) end)
    for _, it in ipairs(list) do
      local r = it.r
      local right
      if it.kind == 1 then right = UI.Colorize("you can craft", GOLD[1], GOLD[2], GOLD[3]) .. UI.Dim(" for " .. ns.ShortName(r.by), 0.5)
      elseif it.kind == 2 then right = r.status == "claimed" and UI.Dim("yours, " .. ns.ShortName(r.claimer or "?") .. " crafting", 0.6) or UI.Dim("yours, open", 0.5)
      else right = UI.Dim("you're crafting for " .. ns.ShortName(r.by), 0.6) end
      rows[#rows + 1] = {
        cols = { R.DisplayName(r) .. UI.Dim(" x" .. (r.qty or 1), 0.5), right },
        onClick = function() Go("requests") end,
      }
    end
    reqList:SetItems(rows, "Nothing for you right now.")
    reqs.want = HEAD + math.max(1, #rows) * ROW + PAD

    -- Guild bank requests: officers only
    if P.CanEdit("bankreq") and ns.GuildBank then
      rightCards = { raids, reqs, bankReqs, online }
      bankReqs:Show()
      local B = ns.GuildBank
      rows = {}
      for _, r in ipairs(B.Requests()) do
        if r.status == "open" then
          local req = r
          local inf = ns.Loot and ns.Loot.ItemInfo(r.item)
          local have = B.Totals()[r.item]
          rows[#rows + 1] = {
            cols = { ((inf and inf.link) or ("item " .. r.item)) .. UI.Dim(" x" .. r.qty, 0.5),
                     UI.Dim(ns.ShortName(r.by) .. ", " .. UI.TimeAgo(r.created), 0.6)
                       .. (have and "" or UI.Colorize("  not in bank", 0.9, 0.5, 0.45)) },
            tooltip = function(tt)
              tt:AddLine(((inf and inf.link) or ("item " .. req.item)) .. " x" .. req.qty, 1, 1, 1)
              tt:AddLine("Asked by " .. ns.ShortName(req.by), 0.7, 0.7, 0.7)
              if req.note then tt:AddLine(req.note, 1, 1, 1, true) end
              tt:AddLine(have and ("In the bank: " .. have.n) or "Not in the bank (as last read)", 0.7, 0.7, 0.7)
              tt:AddLine(" ")
              tt:AddLine("Right-click to hand over or decline. Click to open Requests.", 0.6, 0.6, 0.6)
            end,
            onClick = function(_, button)
              if button == "RightButton" then
                T.Menu(bankList, {
                  { text = "Handed over", onClick = function() B.SetStatus(req, "given"); panel:Refresh() end },
                  { text = "Decline", onClick = function() B.SetStatus(req, "declined"); panel:Refresh() end },
                  { text = "Whisper " .. ns.ShortName(req.by), onClick = function() UI.Whisper(req.by) end },
                }, 180)
              else
                Go("bankrequests")
              end
            end,
          }
        end
      end
      bankReqs:SetLabel(#rows > 0 and ("BANK REQUESTS (%d)"):format(#rows) or "BANK REQUESTS")
      bankList:SetItems(rows, "No open requests.")
      bankReqs.want = HEAD + math.max(1, #rows) * ROW + PAD
    else
      rightCards = { raids, reqs, online }
      bankReqs:Hide()
    end

    -- Online now
    rows = {}
    local n = 0
    for _, mem in ipairs(ns.AllMembers()) do
      local r = mem.roster
      if (r and r.online) or mem.key == me then
        n = n + 1
        local cls = (mem.rec and mem.rec.class) or (r and r.class)
        rows[#rows + 1] = {
          cols = { UI.NameCell(mem.key, cls, true), UI.Dim(tostring((r and r.level) or ""), 0.6), UI.Dim((r and r.zone) or "", 0.5) },
          sort = { ns.ShortName(mem.key):lower() },
          onClick = function(_, button) if button == "RightButton" and mem.key ~= me then UI.Whisper(mem.key) end end,
        }
      end
    end
    online:SetLabel(("ONLINE NOW (%d)"):format(n))
    onlineList:SetItems(rows, "Nobody online.")
    online.want = HEAD + math.max(1, #rows) * ROW + PAD
    Layout()

    UI.SetHint(canEdit and "Click a card's title to collapse it. + Post adds an announcement; right-click one to pin or delete it."
      or "Click a card's title to collapse it. Use the links to open each page.")
  end
end)

ns.On("ANNOUNCE_CHANGED", function() if ns.UI.QueueRefresh then ns.UI.QueueRefresh() end end)
ns.On("ACTIVITY_CHANGED", function() if ns.UI.QueueRefresh then ns.UI.QueueRefresh() end end)
ns.RegisterEvent("GUILD_MOTD", function() if ns.UI.QueueRefresh then ns.UI.QueueRefresh() end end)
