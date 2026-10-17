-- Settings: every FableHub option in one place. Opened from the cog next to the close button.

local _, ns = ...
local UI = ns.UI

ns.RegisterPanel("settings", "Settings", "Interface\\Icons\\Trade_Engineering", function(panel)
  local T, P = ns.Theme, ns.Plans
  local refreshers = {}

  -- the page scrolls; when the window is narrow the Officers/Data column moves
  -- under the General/Alerts column instead of sitting beside it
  local scroll = CreateFrame("ScrollFrame", nil, panel)
  scroll:SetAllPoints()
  local body = CreateFrame("Frame", nil, scroll)
  body:SetSize(640, 400)
  scroll:SetScrollChild(body)
  local thumb = panel:CreateTexture(nil, "OVERLAY")
  thumb:SetColorTexture(1, 1, 1, 0.18)
  thumb:SetWidth(3)
  local function ScrollTo(v)
    local max = math.max(0, (body:GetHeight() or 0) - (scroll:GetHeight() or 0))
    v = math.max(0, math.min(max, v or 0))
    scroll:SetVerticalScroll(v)
    local h = scroll:GetHeight() or 0
    if max > 0 and h > 0 then
      local th = math.max(20, h * h / (h + max))
      thumb:ClearAllPoints()
      thumb:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, -(h - th) * v / max)
      thumb:SetHeight(th)
      thumb:Show()
    else
      thumb:Hide()
    end
  end
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(_, delta) ScrollTo((scroll:GetVerticalScroll() or 0) - delta * 40) end)

  local function Column()
    local col = { y = 0 }
    col.frame = CreateFrame("Frame", nil, body)
    col.frame:SetSize(300, 10)
    local parentFrame = col.frame
    local x = 0
    function col:Header(text)
      if self.y < 0 then self.y = self.y - 10 end
      local fs = T.Text(parentFrame, 11, 0.45)
      fs:SetPoint("TOPLEFT", x, self.y)
      fs:SetText(text:upper())
      local line = parentFrame:CreateTexture(nil, "ARTWORK")
      line:SetColorTexture(1, 1, 1, 0.07)
      line:SetHeight(1)
      line:SetPoint("TOPLEFT", x, self.y - 16)
      line:SetWidth(300)
      self.y = self.y - 24
    end
    function col:Toggle(label, get, set, tip)
      local t = T.Toggle(parentFrame, label, function(v) set(v); panel:Refresh() end)
      t:SetPoint("TOPLEFT", x, self.y)
      if tip then
        t:HookScript("OnEnter", function(b)
          GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
          GameTooltip:AddLine(label, 1, 1, 1)
          GameTooltip:AddLine(tip, 0.8, 0.8, 0.8, true)
          GameTooltip:Show()
        end)
        t:HookScript("OnLeave", function() GameTooltip:Hide() end)
      end
      refreshers[#refreshers + 1] = function() t:SetChecked(get()) end
      self.y = self.y - 26
      return t
    end
    function col:Option(label, key, tip)
      return self:Toggle(label, function() return ns.Option(key) end, function(v) ns.SetOption(key, v) end, tip)
    end
    function col:Button(text, width, onClick)
      local b = T.Button(parentFrame, text, width)
      b:SetPoint("TOPLEFT", x, self.y)
      b:SetScript("OnClick", onClick)
      self.y = self.y - 30
      return b
    end
    function col:Note()
      local fs = T.Text(parentFrame, 11, 0.45)
      fs:SetPoint("TOPLEFT", x, self.y)
      fs:SetWidth(300)
      fs:SetJustifyH("LEFT")
      self.y = self.y - 20
      return fs
    end
    return col
  end

  ------------------------------------------------------------------------
  local L = Column()
  L:Header("General")
  L:Toggle("Show the minimap button", function() return not (FableHubDB.settings.minimap and FableHubDB.settings.minimap.hide) end,
    function() if ns.ToggleMinimapButton then ns.ToggleMinimapButton() end end)
  L:Option("Open on Home each session", "homeFirst", "Otherwise FableHub reopens on the page you last used.")

  -- window opacity: - / +
  local opLabel = T.Text(L.frame, 12, 0.8)
  opLabel:SetPoint("TOPLEFT", 0, L.y - 4)
  local function SetOpacity(n)
    n = math.max(50, math.min(100, n))
    FableHubDB.settings.opacity = n / 100
    UI.ApplyOpacity()
    panel:Refresh()
  end
  local minus = T.Button(L.frame, "-", 24)
  minus:SetPoint("TOPLEFT", 150, L.y)
  minus:SetScript("OnClick", function() SetOpacity(math.floor(UI.Opacity() * 100 + 0.5) - 5) end)
  local plus = T.Button(L.frame, "+", 24)
  plus:SetPoint("LEFT", minus, "RIGHT", 4, 0)
  plus:SetScript("OnClick", function() SetOpacity(math.floor(UI.Opacity() * 100 + 0.5) + 5) end)
  refreshers[#refreshers + 1] = function() opLabel:SetText(("Window opacity: %d%%"):format(math.floor(UI.Opacity() * 100 + 0.5))) end
  L.y = L.y - 30
  L:Button("Reset window size and position", 220, function()
    if ns.ResetWindow then ns.ResetWindow() end
  end)

  L:Header("Alerts in chat")
  L:Option("Raid nights I haven't signed up for", "alertRaid", "A reminder when a raid night is less than 24 hours away and you haven't answered.")
  L:Option("New craft requests I can make", "alertNewRequest")
  L:Option("Open craft requests at login", "alertRequestLogin")
  L:Option("My craft request is claimed or done", "alertMyRequest")
  L:Option("Request count on the minimap button", "minimapBadge")
  L:Option("Guild bank requests (officers)", "alertBankRequest", "A chat message when a member asks for an item from the guild bank.")

  L:Header("Raids")
  L:Option("Check buffs and enchants at ready checks", "readyCheckAuto", "Fills the Raids > Ready check page every time a ready check starts. Check now still works when this is off.")

  ------------------------------------------------------------------------
  local R = Column()
  R:Header("Officers")
  local rankBtn = R:Button("Officer ranks", 220, function(self)
    if not P.IsGuildMaster() then return end
    local names, n = P.RankNames()
    local items = {}
    for i = 0, n - 1 do
      items[#items + 1] = { text = "Up to " .. (names[i] or ("Rank " .. (i + 1))), checked = P.OfficerRank() == i,
                            onClick = function() P.SetOfficerRank(i); panel:Refresh() end }
    end
    T.Menu(self, items, 200)
  end)
  local rankNote = R:Note()
  local lootToggle = R:Option("Announce awarded loot in raid chat", "lootAnnounce")
  if ns.IsDeveloper() then -- only on the developer's Battle.net account
    R:Toggle("Test officer mode (this computer only)", function() return P.TestMode() end, function(v)
      FableHubDB.settings.testOfficer = v and true or nil
      ns.Fire("PLANS_CHANGED")
      UI.QueueRefresh()
    end, "FableHub treats you as an officer so you can try officer features. Guildmates ignore anything you post as an officer unless your real rank is one.")
  end

  R:Header("Data")
  R:Button("Sync with guild now", 220, function() if ns.ForceSync then ns.ForceSync() end end)
  R:Button("Rescan my character", 220, function()
    if ns.ScanAll then ns.ScanAll(true) end
    ns.Print("Rescanned your character.")
  end)
  local confirmUntil = 0
  local clearBtn
  clearBtn = R:Button("Clear stored guild data", 220, function()
    if ns.Now() > confirmUntil then
      confirmUntil = ns.Now() + 5
      clearBtn:SetText("Click again to clear")
      C_Timer.After(5, function() panel:Refresh() end)
      return
    end
    confirmUntil = 0
    SlashCmdList.FABLEHUB("reset")
    panel:Refresh()
  end)
  R:Toggle("Debug messages", function() return FableHubDB.settings.debug and true or false end,
    function(v) FableHubDB.settings.debug = v and true or nil end)
  local version = R:Note()

  local function Arrange()
    local w = panel:GetWidth() or 0
    if w <= 0 then return end
    local lh, rh = -L.y + 4, -R.y + 4
    L.frame:SetHeight(lh); R.frame:SetHeight(rh)
    L.frame:ClearAllPoints(); L.frame:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
    R.frame:ClearAllPoints()
    if w >= 650 then
      R.frame:SetPoint("TOPLEFT", body, "TOPLEFT", 340, 0)
      body:SetSize(w - 8, math.max(lh, rh))
    else
      R.frame:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -(lh + 10))
      body:SetSize(w - 8, lh + 10 + rh)
    end
    ScrollTo(scroll:GetVerticalScroll() or 0)
  end
  panel:SetScript("OnSizeChanged", Arrange)

  function panel:Refresh()
    UI.SetHint("Settings are saved for your whole account. Officer ranks and loot announcements only matter for officers.")
    for _, f in ipairs(refreshers) do f() end
    local names = P.RankNames()
    local rankName = names[P.OfficerRank()] or ("Rank " .. (P.OfficerRank() + 1))
    rankBtn:SetText("Officer ranks: up to " .. rankName)
    rankBtn:SetAlpha(P.IsGuildMaster() and 1 or 0.5)
    rankNote:SetText(P.IsGuildMaster() and "You're the Guild Master, so you choose this."
      or "Only the Guild Master can change this.")
    lootToggle:SetAlpha(P.CanEdit() and 1 or 0.5)
    if ns.Now() > confirmUntil then clearBtn:SetText("Clear stored guild data") end
    version:SetText(("FableHub %s%s"):format(ns.VERSION or "", P.CanEdit() and "  ·  you're an officer" or ""))
    Arrange()
  end
end, "titlebar")

ns.On("OPTIONS_CHANGED", function() if UI.QueueRefresh then UI.QueueRefresh() end end)
