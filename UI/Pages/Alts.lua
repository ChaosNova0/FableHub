-- Roster > Alts: each player's main with their alts underneath.

local _, ns = ...
local UI = ns.UI

ns.RegisterNavGroup("rostergroup", "Roster", "Interface\\Icons\\INV_Misc_GroupLooking", { "roster", "alts" })

ns.RegisterPanel("alts", "Alts", nil, function(panel)
  local T, A, P = ns.Theme, ns.Alts, ns.Plans
  local filterText = ""
  local collapsed = {}          -- groups the viewer closed (open by default)
  local showSingles = false     -- "Not linked" section, closed by default

  local search = T.SearchBox(panel, 220, "Search name", function(t) filterText = t; panel:Refresh() end)
  search:SetPoint("TOPLEFT", 0, 0)

  local mainBtn = T.Button(panel, "My main", 180)
  mainBtn:SetPoint("LEFT", search, "RIGHT", 16, 0)
  mainBtn:SetScript("OnClick", function(self)
    local items, current = {}, A.MyMain()
    for _, key in ipairs(A.MyChars()) do
      local k = key
      items[#items + 1] = { text = ns.ShortName(k) .. "  (" .. A.Level(k) .. ")", checked = k == current,
                            onClick = function() A.SetMyMain(k); panel:Refresh() end }
    end
    T.Menu(self, items, 180)
  end)

  local count = T.Text(panel, 11, 0.4)

  local list = UI.CreateList(panel, {
    { title = "Name", width = 200 },
    { title = "Lvl", width = 30, justify = "RIGHT" },
    { title = "Rank", width = 110 },
    { title = "Professions", flex = true },
    { title = "Last seen", width = 90, justify = "RIGHT" },
  }, 24)
  list:SetPoint("TOPLEFT", 0, -34)
  list:SetPoint("BOTTOMRIGHT", 0, 0)
  list.sortable = false

  local bar = UI.Toolbar(panel)
  bar:Add(search, { grow = true, min = 140, max = 220 })
  bar:Add(mainBtn, { gap = 16 })
  bar:Status(count)
  bar:Below(list)

  -- "Link as alt of..." (officers): pick the main from the guild
  local function OpenLink(char)
    local exclude = {}
    for _, k in ipairs(A.GroupOf(char)) do exclude[k] = true end
    UI.PickMember("Link " .. ns.ShortName(char) .. " as an alt of:", function(main)
      A.Link(char, main)
      panel:Refresh()
    end, { exclude = exclude })
  end

  local function Menu(key)
    local items = {}
    local mine = false
    for _, k in ipairs(A.MyChars()) do if k == key then mine = true end end
    if mine and A.MyMain() ~= key then
      items[#items + 1] = { text = "Make this my main", onClick = function() A.SetMyMain(key); panel:Refresh() end }
    end
    if P.CanEdit("alts") then
      local main = A.MainOf(key)
      if main ~= key then
        items[#items + 1] = { text = "Make main of this group", onClick = function() A.MakeMain(key); panel:Refresh() end }
        items[#items + 1] = { text = "Unlink from " .. ns.ShortName(main), onClick = function() A.Unlink(key); panel:Refresh() end }
      end
      items[#items + 1] = { text = "Link as alt of...", onClick = function() OpenLink(key) end }
    end
    if key ~= ns.MyKey() then
      items[#items + 1] = { text = "Whisper", onClick = function() UI.Whisper(key) end }
    end
    if #items > 0 then T.Menu(list, items, 200) end
  end

  local function Row(key, indent, isHeader, extra)
    local g = ns.GuildDB()
    local r = ns.roster[key]
    local rec = (g and ns.MemberRecord(key, g)) or FableHubDB.chars[key]
    local classFile = (rec and rec.class) or (r and r.class)
    local online = (r and r.online) or key == ns.MyKey()
    local profs = {}
    if rec then
      local primary = ns.SplitProfessions(rec)
      for _, p in ipairs(primary) do
        profs[#profs + 1] = ns.Icons.Prof(p.skillLine, 13) .. " " .. UI.Dim(p.name .. " " .. p.rank, 0.6)
      end
    end
    local seen = online and "|cff40d66eonline|r" or UI.Dim(r and r.lastSeen and r.lastSeen > 0 and UI.TimeAgo(r.lastSeen) or "", 0.4)
    local name = UI.NameCell(key, classFile, online)
    if not r then name = UI.Dim(ns.ShortName(key) .. " (not in guild)", 0.35) end
    return {
      header = isHeader,
      cols = { indent .. name .. (extra or ""), online and tostring(A.Level(key)) or UI.Dim(tostring(A.Level(key)), 0.45),
               UI.Dim(r and r.rank or "", online and 0.7 or 0.4), table.concat(profs, "   "), seen },
      key = key,
      onClick = function(it, button)
        if button == "RightButton" then Menu(it.key)
        elseif it.toggle then it.toggle(); panel:Refresh() end
      end,
    }
  end

  function panel:Refresh()
    local officer = P.CanEdit("alts")
    UI.SetHint(officer and "Click a main to show or hide alts. Right-click a character to link, unlink or change the main."
      or "Alts are linked automatically when a player logs in with FableHub. Right-click your own character to make it your main.")
    mainBtn:SetText("My main: " .. ns.ShortName(A.MyMain() or ns.MyKey()))
    local ar, ag, ab = T.Accent()
    local items = {}
    local groups, singles = A.Groups()
    local function Match(key) return filterText == "" or ns.ShortName(key):lower():find(filterText, 1, true) end
    local nAlts = 0
    for _, grp in ipairs(groups) do
      nAlts = nAlts + #grp.alts
      local hit = Match(grp.main)
      for _, k in ipairs(grp.alts) do if Match(k) then hit = true end end
      if hit then
        local open = filterText ~= "" or not collapsed[grp.main]
        local arrow = UI.Colorize(open and "-" or "+", ar, ag, ab) .. "  "
        local it = Row(grp.main, arrow, true, UI.Dim("   " .. #grp.alts .. (#grp.alts == 1 and " alt" or " alts"), 0.45))
        local m = grp.main
        it.toggle = function() collapsed[m] = not collapsed[m] end
        items[#items + 1] = it
        if open then
          for _, k in ipairs(grp.alts) do items[#items + 1] = Row(k, "        ", false) end
        end
      end
    end
    local shown = {}
    for _, k in ipairs(singles) do if Match(k) then shown[#shown + 1] = k end end
    if #shown > 0 then
      local open = filterText ~= "" or showSingles
      items[#items + 1] = {
        header = true,
        cols = { UI.Colorize(open and "-" or "+", ar, ag, ab) .. "  " .. UI.Dim("Not linked (" .. #shown .. ")", 0.6), "", "", "", "" },
        onClick = function(_, button) if button ~= "RightButton" then showSingles = not showSingles; panel:Refresh() end end,
      }
      if open then
        for _, k in ipairs(shown) do items[#items + 1] = Row(k, "        ", false) end
      end
    end
    count:SetText(("%d players with alts  ·  %d alts"):format(#groups, nAlts))
    UI.SetHint(officer
      and "Click a main to show or hide alts. Right-click a character to link, unlink or change the main."
      or "Alts are linked automatically when a player logs in with FableHub. Right-click your own character to make it your main.")
    list:SetItems(items, IsInGuild() and "No characters match" or "You're not in a guild")
  end
end, "rostergroup")

ns.On("ALTS_CHANGED", function() if UI.QueueRefresh then UI.QueueRefresh() end end)
