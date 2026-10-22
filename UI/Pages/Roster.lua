-- Roster tab: every guild member with level, rank and professions.

local _, ns = ...
local UI = ns.UI

-- secondary skills (shown in their own column)
local SECONDARY = { [185] = "Cooking", [356] = "Fishing", [129] = "First Aid", [794] = "Archaeology" }
ns.SECONDARY = SECONDARY

-- Merge the live guild roster with stored FableHub records.
function ns.AllMembers()
  local g = ns.GuildDB()
  local stored = g and g.members or {}
  local out, seen = {}, {}
  local haveRoster = next(ns.roster) ~= nil
  for _, key in ipairs(ns.rosterOrder) do
    out[#out + 1] = { key = key, roster = ns.roster[key], rec = stored[key] }
    seen[key] = true
  end
  local mine = ns.MyRecord()
  if mine and not seen[mine.key] then
    out[#out + 1] = { key = mine.key, rec = mine }
    seen[mine.key] = true
  end
  if not haveRoster then -- roster not loaded yet: show what we have stored
    for key, rec in pairs(stored) do
      if not seen[key] then out[#out + 1] = { key = key, rec = rec } end
    end
  end
  return out
end

-- professions of a record, split and sorted (highest skill first)
function ns.SplitProfessions(rec)
  local primary, secondary = {}, {}
  if rec and rec.profs then
    for skillLine, p in pairs(rec.profs) do
      local entry = { skillLine = skillLine, name = p.name, rank = p.rank or 0, max = p.max or 0,
                      recipes = p.recipes, scanned = p.scanned }
      if SECONDARY[skillLine] then table.insert(secondary, entry) else table.insert(primary, entry) end
    end
  end
  local bySkill = function(a, b) if a.rank == b.rank then return a.name < b.name end return a.rank > b.rank end
  table.sort(primary, bySkill)
  table.sort(secondary, bySkill)
  return primary, secondary
end

local function CountRecipes(p)
  local n = 0
  for _ in pairs(p.recipes or {}) do n = n + 1 end
  return n
end
ns.CountRecipes = CountRecipes

ns.RegisterPanel("roster", "Members", nil, function(panel)
  local T = ns.Theme
  local filterText, onlineOnly, addonOnly = "", false, false

  local search = T.SearchBox(panel, 220, "Search name, zone or note", function(t) filterText = t; panel:Refresh() end)
  search:SetPoint("TOPLEFT", 0, 0)

  local online = T.Toggle(panel, "Online only", function(v) onlineOnly = v; panel:Refresh() end)
  online:SetPoint("LEFT", search, "RIGHT", 16, 0)

  local addon = T.Toggle(panel, "Has FableHub", function(v) addonOnly = v; panel:Refresh() end)
  addon:SetPoint("LEFT", online, "RIGHT", 14, 0)

  local count = T.Text(panel, 11, 0.4)

  local list = UI.CreateList(panel, {
    { title = "Name", width = 170 },
    { title = "Lvl", width = 30, justify = "RIGHT", defaultAsc = false },
    { title = "Rank", width = 110 },
    { title = "Zone", flex = true },
    { title = "Note", flex = true },
    { title = "Attend.", width = 54, justify = "RIGHT", defaultAsc = false },
    { title = "Last seen", width = 80, justify = "RIGHT" },
  }, 24)
  list:SetPoint("TOPLEFT", 0, -34)
  list:SetPoint("BOTTOMRIGHT", 0, 0)

  local bar = UI.Toolbar(panel)
  bar:Add(search, { grow = true, min = 140, max = 220 })
  bar:Add(online, { gap = 16 })
  bar:Add(addon, { gap = 14 })
  bar:Status(count)
  bar:Below(list)

  local function Tooltip(tt, item)
    local m = item.member
    local r, rec = m.roster, m.rec
    local classFile = (rec and rec.class) or (r and r.class)
    tt:AddLine(ns.Icons.Class(classFile, 16) .. " " .. ns.ShortName(m.key), ns.ClassColor(classFile))
    if r then
      tt:AddDoubleLine(r.rank or "", r.online and ("|cff40d66eOnline|r  " .. (r.zone or "")) or "|cff999999Offline|r")
      if r.note and r.note ~= "" then tt:AddLine(r.note, 0.8, 0.8, 0.8, true) end
    end
    if item.attTotal and item.attTotal > 0 then
      tt:AddLine(("Attended %d of the last %d raid nights (30 days)"):format(item.attended, item.attTotal), 0.8, 0.8, 0.8)
    end
    tt:AddLine(" ")
    -- their FableHub version: this session, else the last one we saw
    local g = ns.GuildDB()
    local ver = ns.present[m.key] or (g and g.addonUsers[m.key] and g.addonUsers[m.key].version)
    if rec and rec.ts and rec.ts > 0 then
      tt:AddLine("Uses FableHub" .. (ver and (" " .. ver) or "") .. ", updated " .. UI.TimeAgo(rec.ts), 0.6, 0.6, 0.6)
    else
      tt:AddLine("Not using FableHub yet", 0.6, 0.6, 0.6)
    end
    tt:AddLine("Right-click to whisper", 0.6, 0.6, 0.6)
  end

  function panel:Refresh()
    UI.SetHint("Hover a member for details. Right-click to whisper.")
    local g = ns.GuildDB()
    local items, users, total = {}, 0, 0
    for _, m in ipairs(ns.AllMembers()) do
      total = total + 1
      local r, rec = m.roster, m.rec
      local hasData = rec and rec.ts and rec.ts > 0
      if hasData then users = users + 1 end
      local isOnline = (r and r.online) or m.key == ns.MyKey()
      local zone, note = (r and r.zone) or "", (r and r.note) or ""
      local hay = (ns.ShortName(m.key) .. " " .. zone .. " " .. note):lower()

      if (not onlineOnly or isOnline) and (not addonOnly or hasData)
        and (filterText == "" or hay:find(filterText, 1, true)) then
        local classFile = (rec and rec.class) or (r and r.class)
        local level = (r and r.level) or (rec and rec.level) or 0
        local attended, attTotal = ns.Events.AttendanceStats(m.key, 30)
        local attPct = attTotal > 0 and math.floor(attended / attTotal * 100 + 0.5) or 0
        local seenTs = isOnline and ns.Now() or (r and r.lastSeen)
          or ((g and g.addonUsers[m.key] and g.addonUsers[m.key].seen) or 0)
        items[#items + 1] = {
          member = m,
          cols = {
            UI.NameCell(m.key, classFile, isOnline),
            isOnline and tostring(level) or UI.Dim(tostring(level), 0.45),
            UI.Dim(r and r.rank or "", isOnline and 0.7 or 0.4),
            UI.Dim(zone, isOnline and 0.6 or 0.35),
            UI.Dim(note, 0.5),
            attTotal > 0 and (attPct >= 75 and UI.Colorize(attPct .. "%", 0.4, 0.85, 0.5) or (attPct >= 50 and (attPct .. "%"))
              or UI.Colorize(attPct .. "%", 0.9, 0.5, 0.45)) or UI.Dim("-", 0.3),
            isOnline and "|cff40d66eonline|r" or UI.Dim(seenTs > 0 and UI.TimeAgo(seenTs) or "", 0.4),
          },
          sort = { ns.ShortName(m.key):lower(), level, (r and r.rankIndex) or 99, zone:lower(), note:lower(),
                   attTotal > 0 and attPct or -1, isOnline and math.huge or seenTs },
          attended = attended, attTotal = attTotal,
          tooltip = Tooltip,
          onClick = function(it, button)
            if button == "RightButton" and it.member.key ~= ns.MyKey() then UI.Whisper(it.member.key) end
          end,
        }
      end
    end
    count:SetText(("%d shown  ·  %d of %d use FableHub"):format(#items, users, total))
    list:SetItems(items, IsInGuild() and "No members match your filters" or "You're not in a guild")
  end
end, "rostergroup")
