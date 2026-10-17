-- Raids > Ready check: consumables, class buffs and enchants from the latest ready check.

local _, ns = ...
local UI = ns.UI

local YES = "|TInterface\\RaidFrame\\ReadyCheck-Ready:14:14|t"
local NO = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:14:14|t"
local UNKNOWN = "|TInterface\\RaidFrame\\ReadyCheck-Waiting:14:14|t"

ns.RegisterPanel("readycheck", "Ready check", nil, function(panel)
  local T, RC, Cons = ns.Theme, ns.ReadyCheck, ns.Consumables
  local problemsOnly = false

  local checkBtn = T.Button(panel, "Check now", 100)
  checkBtn:SetPoint("TOPLEFT", 0, 0)
  checkBtn:SetScript("OnClick", function() RC.Run("manual check"); panel:Refresh() end)

  local retryBtn = T.Button(panel, "Re-inspect gear", 120)
  retryBtn:SetPoint("LEFT", checkBtn, "RIGHT", 8, 0)
  retryBtn:SetScript("OnClick", function() RC.RetryEnchants(); panel:Refresh() end)

  local problems = T.Toggle(panel, "Only show problems", function(v) problemsOnly = v; panel:Refresh() end)
  problems:SetPoint("LEFT", retryBtn, "RIGHT", 16, 0)

  local status = T.Text(panel, 11, 0.45)

  local cols = {
    { title = "Name", flex = true },
    { title = "Flask", width = 46, justify = "CENTER" },
    { title = "Food", width = 44, justify = "CENTER" },
    { title = "Other", width = 46, justify = "CENTER" },
  }
  for _, cb in ipairs(Cons.CLASS_BUFFS) do cols[#cols + 1] = { title = cb.short, width = 50, justify = "CENTER" } end
  cols[#cols + 1] = { title = "Blessings", width = 66, justify = "CENTER" }
  cols[#cols + 1] = { title = "Enchants", width = 66, justify = "CENTER" }
  cols[#cols + 1] = { title = "Missing", width = 150 }

  local list = UI.CreateList(panel, cols, 24)
  list:SetPoint("TOPLEFT", 0, -34)
  list:SetPoint("BOTTOMRIGHT", 0, 0)
  local bar = UI.Toolbar(panel)
  bar:Add(checkBtn)
  bar:Add(retryBtn)
  bar:Add(problems, { gap = 16 })
  bar:Status(status)
  bar:Below(list)

  local function Tooltip(tt, it)
    local p = it.p
    tt:AddLine(ns.Icons.Class(p.class, 16) .. " " .. (p.name or "?"), ns.ClassColor(p.class))
    if p.flask then tt:AddDoubleLine("Flask", p.flask, 0.7, 0.7, 0.7, 1, 1, 1)
    elseif #p.elixirs > 0 then tt:AddDoubleLine("Elixirs", table.concat(p.elixirs, ", "), 0.7, 0.7, 0.7, 1, 1, 1)
    else tt:AddDoubleLine("Flask", "none", 0.7, 0.7, 0.7, 0.9, 0.4, 0.4) end
    tt:AddDoubleLine("Food", p.food or "none", 0.7, 0.7, 0.7, p.food and 1 or 0.9, p.food and 1 or 0.4, p.food and 1 or 0.4)
    if #p.other > 0 then tt:AddDoubleLine("Other", table.concat(p.other, ", "), 0.7, 0.7, 0.7, 1, 1, 1) end
    if #p.blessingNames > 0 then tt:AddDoubleLine("Blessings", table.concat(p.blessingNames, ", "), 0.7, 0.7, 0.7, 1, 1, 1) end
    if p.enchants == nil then
      tt:AddLine("Enchants: not inspected yet (needs to be within about 28 yards)", 0.6, 0.6, 0.6, true)
    elseif #p.enchants == 0 then
      tt:AddLine("Enchants: all listed slots enchanted", 0.4, 0.85, 0.5)
    else
      local names = {}
      for _, slot in ipairs(p.enchants) do names[#names + 1] = Cons.SLOT_NAMES[slot] or tostring(slot) end
      tt:AddLine("Missing enchants: " .. table.concat(names, ", "), 0.9, 0.5, 0.45, true)
    end
  end

  function panel:Refresh()
    UI.SetHint("Updates on every ready check. Hover a player for details. Buff and consumable lists live in Consumables.lua.")
    local last = RC.last
    if not last then
      status:SetText("No check yet")
      list:SetItems({}, "Start a ready check, or click Check now while in a group.")
      return
    end
    local items, bad = {}, 0
    for _, p in ipairs(last.players) do
      local missing = RC.Missing(p)
      if #missing > 0 then bad = bad + 1 end
      if not problemsOnly or #missing > 0 then
        local row = {
          UI.Colorize(ns.Icons.Class(p.class, 14) .. " " .. (p.name or "?"), ns.ClassColor(p.class)),
          p.flaskOk and YES or NO,
          p.food and YES or NO,
          #p.other > 0 and tostring(#p.other) or UI.Dim("-", 0.3),
        }
        local sort = { (p.name or ""):lower(), p.flaskOk and 1 or 0, p.food and 1 or 0, #p.other }
        for _, cb in ipairs(Cons.CLASS_BUFFS) do
          local b = p.buffs[cb.id]
          local cell
          if not b or not b.provided then cell = UI.Dim("-", 0.3)
          elseif b.has then cell = YES
          elseif b.expected then cell = NO
          else cell = UI.Dim("no", 0.4) end
          row[#row + 1] = cell
          sort[#sort + 1] = b and b.has and 1 or 0
        end
        if p.blessingsNeeded == 0 and p.blessings == 0 then row[#row + 1] = UI.Dim("-", 0.3)
        else
          local txt = p.blessings .. "/" .. p.blessingsNeeded
          row[#row + 1] = p.blessings >= p.blessingsNeeded and UI.Colorize(txt, 0.4, 0.85, 0.5) or UI.Colorize(txt, 0.9, 0.5, 0.45)
        end
        sort[#sort + 1] = p.blessings - p.blessingsNeeded
        if p.enchants == nil then row[#row + 1] = UNKNOWN; sort[#sort + 1] = -1
        elseif #p.enchants == 0 then row[#row + 1] = YES; sort[#sort + 1] = 0
        else row[#row + 1] = UI.Colorize(#p.enchants .. " missing", 0.9, 0.5, 0.45); sort[#sort + 1] = #p.enchants end
        row[#row + 1] = #missing > 0 and UI.Colorize(table.concat(missing, ", "), 0.9, 0.5, 0.45) or UI.Colorize("ready", 0.4, 0.85, 0.5)
        sort[#sort + 1] = #missing
        items[#items + 1] = { p = p, cols = row, sort = sort, tooltip = Tooltip }
      end
    end
    local unread = 0
    for _, p in ipairs(last.players) do if p.enchants == nil then unread = unread + 1 end end
    status:SetText(("%s %s  ·  %d players  ·  %d missing something%s"):format(
      last.source == "manual check" and "Checked" or "Ready check", UI.TimeAgo(last.at), #last.players, bad,
      unread > 0 and ("  ·  " .. unread .. " not inspected") or ""))
    list:SetItems(items, problemsOnly and "Everyone is ready" or "Nobody in the group")
  end
end, "raidgroup")

ns.On("READYCHECK_CHANGED", function() if UI.QueueRefresh then UI.QueueRefresh() end end)
