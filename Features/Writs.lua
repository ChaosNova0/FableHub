-- Writs: Craftsman's Writs (Professions > Craftsman's Writs). The list itself is
-- Data/Writs.lua; this file works out which writs you hold, what they still
-- need, which guildmates can craft each item, and searches the auction house.
--
-- Nothing here is sent to anyone: no messages, no saved guild data. The quest
-- log and bags are read on this computer only, and the auction house is only
-- searched when you click Search AH (one search per click; FableHub never buys
-- or bids on anything).
--
-- W.LIST       = { row, ... } every writ: { item, name, writ, prof, profName, skill,
--                level ("J"|"E"|"A"), rep, to, qty, spell, nameLower }
--              item = what the writ asks for; writ = the Craftsman's Writ item itself
-- W.BY_ITEM    [itemID] = { row, ... }
-- W.BY_WRIT    [writ item ID] = row
-- W.BY_NAME    [lower-case English name] = row
-- W.held       [itemID] = { need, done, quests = { quest title, ... } }: writs
--              in your quest log (one item on two writs adds up)
-- W.Crafters(itemID) -> { recipe, prof, crafters = { { key, class, online }, ... } }
--              or nil: guildmates who know a recipe that makes it
-- W.Shopping() -> { { item, name, row, have, need, quests }, ... } sorted by name
--
-- Rules: a quest counts as a writ when one of its objectives names a writ item
-- (English name, or the item's name on this client). Scans run at most once a
-- second and wait until combat ends. A request from here only fills in the
-- Craft Request form; the player presses Post.

local _, ns = ...
local W = {}
ns.Writs = W

------------------------------------------------------------------------
-- The list
------------------------------------------------------------------------
W.LIST, W.BY_ITEM, W.BY_NAME, W.BY_WRIT = {}, {}, {}, {}
W.PROF_NAMES = {}
for _, p in ipairs(ns.WRIT_PROFS or {}) do W.PROF_NAMES[p[1]] = p[2] end

for _, p in ipairs(ns.WRIT_PROFS or {}) do
  local skillLine = p[1]
  for _, r in ipairs(ns.WRITS and ns.WRITS[skillLine] or {}) do
    local lv = ns.WRIT_LEVELS[r[4]]
    local row = {
      item = r[1], name = r[2], skill = r[3], level = r[4], rep = lv and lv.rep or 0, writ = r.writ,
      prof = skillLine, profName = p[2], to = r.to, qty = r.qty, spell = r.spell,
      nameLower = r[2]:lower(),
    }
    W.LIST[#W.LIST + 1] = row
    W.BY_ITEM[row.item] = W.BY_ITEM[row.item] or {}
    table.insert(W.BY_ITEM[row.item], row)
    W.BY_NAME[row.nameLower] = row
    if row.writ then W.BY_WRIT[row.writ] = row end
  end
end

W.LEVEL_RANK = {}
for i, lv in ipairs(ns.WRIT_LEVEL_ORDER or {}) do W.LEVEL_RANK[lv] = i end

function W.Row(itemID) local rows = W.BY_ITEM[itemID]; return rows and rows[1] end

-- the item's name on this client (other languages), or the English one
function W.ItemName(row)
  local info = ns.Loot and ns.Loot.ItemInfo(row.item)
  return info and info.name or row.name
end

-- the writ's own name ("Craftsman's Writ: Heavy Quiver"), the same way
function W.WritName(row)
  local info = row.writ and ns.Loot and ns.Loot.ItemInfo(row.writ)
  return info and info.name or ("Craftsman's Writ: " .. row.name)
end

------------------------------------------------------------------------
-- Who in the guild can craft each writ item (worked out when asked, again
-- after guild data or the roster changes)
------------------------------------------------------------------------
local crafterIndex -- [itemID] = { recipe, prof, crafters }, nil when stale

local function BuildCrafters()
  local idx = {}
  local ok, profs = pcall(ns.Crafting)
  if not ok or type(profs) ~= "table" then return idx end
  -- byItem[item] = { recipes = { [recipeID] = { prof, n } }, seen = { [key] = entry }, list }
  local work = {}
  for skillLine, agg in pairs(profs) do
    -- (only the writ professions: Enchanting, Cooking and the rest never match)
    for recipeID, crafters in pairs(W.PROF_NAMES[skillLine] and agg.recipes or {}) do
      local item = agg.outputs and agg.outputs[recipeID]
      if not item then
        local name, loaded = ns.RecipeName(recipeID)
        local row = loaded and name and W.BY_NAME[name:lower()]
        item = row and row.prof == skillLine and row.item
      end
      if item and W.BY_ITEM[item] then
        local w = work[item]
        if not w then w = { recipes = {}, seen = {}, list = {} }; work[item] = w end
        local r = w.recipes[recipeID]
        if not r then r = { prof = skillLine, n = 0 }; w.recipes[recipeID] = r end
        for _, c in ipairs(crafters) do
          r.n = r.n + 1
          if not w.seen[c.key] then
            local e = { key = c.key, class = c.class, online = c.online and true or false }
            w.seen[c.key] = e
            w.list[#w.list + 1] = e
          end
        end
      end
    end
  end
  for item, w in pairs(work) do
    local best, bestN, bestProf
    for recipeID, r in pairs(w.recipes) do
      if not best or r.n > bestN or (r.n == bestN and recipeID < best) then best, bestN, bestProf = recipeID, r.n, r.prof end
    end
    table.sort(w.list, function(a, b)
      if a.online ~= b.online then return a.online end
      return ns.ShortName(a.key):lower() < ns.ShortName(b.key):lower()
    end)
    idx[item] = { recipe = best, prof = bestProf, crafters = w.list }
  end
  return idx
end

function W.Crafters(itemID)
  if not itemID or not W.BY_ITEM[itemID] then return nil end
  if not crafterIndex then crafterIndex = BuildCrafters() end
  return crafterIndex[itemID]
end

local function Stale() crafterIndex = nil end
ns.On("DATA_CHANGED", Stale)
ns.On("ROSTER_CHANGED", Stale)

------------------------------------------------------------------------
-- Your writs, from the quest log
------------------------------------------------------------------------
W.held = {}
W.hasCollapsed = false
local lastSig = ""

-- the client's own names for writ items, lower case: [name] = row
local localNames = {}
local function LocalNames()
  for _, row in ipairs(W.LIST) do
    if not row.localName and (row.nameTries or 0) < 5 then
      row.nameTries = (row.nameTries or 0) + 1
      local info = ns.Loot and ns.Loot.ItemInfo(row.item)
      if info and info.name then
        row.localName = info.name:lower()
        localNames[row.localName] = row
      end
    end
  end
  return localNames
end

-- "Elixir of Wisdom: 0/1" or "0/1 Elixir of Wisdom" -> name (lower case), have, need
local function ParseObjective(text)
  if type(text) ~= "string" or text == "" then return nil end
  text = text:sub(1, 200):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
  text = text:gsub("%s*%b()%s*$", "") -- a note on the end, like "(Complete)"
  local name, have, need = text:match("^%s*(.-)%s*:%s*(%d+)%s*/%s*(%d+)%s*$")
  if not name then have, need, name = text:match("^%s*(%d+)%s*/%s*(%d+)%s+(.-)%s*$") end
  if not name then name = text:match("^%s*(.-)%s*$") end
  if not name or name == "" then return nil end
  return name:lower(), tonumber(have), tonumber(need)
end
W.ParseObjective = ParseObjective -- for tests

local function MatchRow(name, names)
  return W.BY_NAME[name] or names[name]
end

-- add one objective to the result; true when it named a writ item
local function AddObjective(out, title, text, numFulfilled, numRequired, finished, names)
  local name, have, need = ParseObjective(text)
  local row = name and MatchRow(name, names)
  if not row then return false end
  need = tonumber(numRequired) or need or row.qty or 1
  local done = tonumber(numFulfilled) or have or ((finished and need) or 0)
  local h = out[row.item]
  if not h then h = { need = 0, done = 0, quests = {} }; out[row.item] = h end
  h.need = h.need + math.max(1, math.min(10000, need))
  h.done = h.done + math.max(0, math.min(10000, done))
  if type(title) == "string" and title ~= "" then h.quests[#h.quests + 1] = (title:sub(1, 120):gsub("|", "")) end
  return true
end

local MAX_ENTRIES = 200 -- (a quest log never has this many; a guard against a bad answer)

local function ScanModern(out, names)
  local Q = C_QuestLog
  local ok, numShown = pcall(Q.GetNumQuestLogEntries)
  if not ok or type(numShown) ~= "number" then return false end
  local collapsed = false
  for i = 1, math.min(numShown, MAX_ENTRIES) do
    local okI, info = pcall(Q.GetInfo, i)
    if okI and type(info) == "table" then
      if info.isHeader then
        if info.isCollapsed then collapsed = true end
      elseif info.questID then
        local okO, objs = pcall(Q.GetQuestObjectives, info.questID)
        if okO and type(objs) == "table" then
          for _, o in ipairs(objs) do
            if type(o) == "table" then
              AddObjective(out, info.title, o.text, o.numFulfilled, o.numRequired, o.finished, names)
            end
          end
        end
      end
    end
  end
  return true, collapsed
end

-- older clients only (Forever has C_QuestLog)
local function ScanLegacy(out, names)
  if type(GetNumQuestLogEntries) ~= "function" or type(GetQuestLogTitle) ~= "function" then return false end
  local ok, numEntries = pcall(GetNumQuestLogEntries)
  if not ok or type(numEntries) ~= "number" then return false end
  local collapsed = false
  for i = 1, math.min(numEntries, MAX_ENTRIES) do
    local okT, title, _, _, isHeader, isCollapsed = pcall(GetQuestLogTitle, i)
    if okT and title then
      if isHeader then
        if isCollapsed then collapsed = true end
      elseif type(GetNumQuestLeaderBoards) == "function" and type(GetQuestLogLeaderBoard) == "function" then
        local okN, n = pcall(GetNumQuestLeaderBoards, i)
        for j = 1, (okN and type(n) == "number") and math.min(n, 20) or 0 do
          local okL, text, _, finished = pcall(GetQuestLogLeaderBoard, j, i)
          if okL then AddObjective(out, title, text, nil, nil, finished, names) end
        end
      end
    end
  end
  return true, collapsed
end

local function Signature(held, collapsed)
  local keys = {}
  for item, h in pairs(held) do
    keys[#keys + 1] = item .. ":" .. h.need .. ":" .. h.done .. ":" .. table.concat(h.quests, ",")
  end
  table.sort(keys)
  return (collapsed and "c|" or "o|") .. table.concat(keys, ";")
end

function W.ScanQuests()
  local out, names = {}, LocalNames()
  local ok, collapsed
  if C_QuestLog and type(C_QuestLog.GetNumQuestLogEntries) == "function" and type(C_QuestLog.GetInfo) == "function" then
    ok, collapsed = ScanModern(out, names)
  end
  if not ok then ok, collapsed = ScanLegacy(out, names) end
  if not ok then return false end
  W.lastScan = GetTime and GetTime() or 0
  local sig = Signature(out, collapsed)
  W.held, W.hasCollapsed = out, collapsed and true or false
  if sig ~= lastSig then
    lastSig = sig
    ns.Fire("WRITS_CHANGED")
  end
  return true
end

function W.IsMine(item) return W.held[item] ~= nil end
function W.Held() return W.held end

local function CountInBags(item)
  local fn = (C_Item and C_Item.GetItemCount) or GetItemCount
  if not fn then return 0 end
  local ok, n = pcall(fn, item)
  return (ok and tonumber(n)) or 0
end
W.CountInBags = CountInBags

function W.Shopping()
  local out = {}
  for item, h in pairs(W.held) do
    local row = W.Row(item)
    if row then
      out[#out + 1] = { item = item, name = W.ItemName(row), row = row, have = CountInBags(item), need = h.need, quests = h.quests }
    end
  end
  table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
  return out
end

------------------------------------------------------------------------
-- When to look again: quest log changes (at most once a second, never in
-- combat), and bag changes while you hold a writ (for the shopping list)
------------------------------------------------------------------------
local scanQueued, combatPending = false, false
local function InCombat() return InCombatLockdown and InCombatLockdown() and true or false end

local function RunScan()
  scanQueued = false
  if InCombat() then combatPending = true return end
  local ok, err = pcall(W.ScanQuests)
  if not ok then ns.ReportError("writs: " .. tostring(err)) end
end

function W.QueueScan()
  if InCombat() then combatPending = true return end
  if scanQueued then return end
  scanQueued = true
  local now = GetTime and GetTime() or 0
  C_Timer.After(math.max(0.2, (W.lastScan or -10) + 1 - now), RunScan)
end

for _, ev in ipairs({ "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_TURNED_IN" }) do
  ns.RegisterEvent(ev, function() W.QueueScan() end)
end
ns.RegisterEvent("PLAYER_REGEN_ENABLED", function()
  if combatPending then combatPending = false; W.QueueScan() end
end)

local bagPending = false
ns.RegisterEvent("BAG_UPDATE_DELAYED", function()
  if bagPending or not next(W.held) then return end
  bagPending = true
  C_Timer.After(1, function() bagPending = false; ns.Fire("WRITS_CHANGED") end)
end)

------------------------------------------------------------------------
-- Auction house: searched only when you click Search AH, one search a click
------------------------------------------------------------------------
W.ahOpen = false

function W.AHOpen()
  if W.ahOpen then return true end
  local f = AuctionHouseFrame
  if type(f) ~= "table" or type(f.IsShown) ~= "function" then return false end
  local ok, shown = pcall(f.IsShown, f)
  return ok and shown and true or false
end

ns.RegisterEvent("AUCTION_HOUSE_SHOW", function() W.ahOpen = true; ns.Fire("WRITS_CHANGED") end)
ns.RegisterEvent("AUCTION_HOUSE_CLOSED", function() W.ahOpen = false; ns.Fire("WRITS_CHANGED") end)

ns.On("LOGIN", function()
  C_Timer.After(5, function()
    W.ahOpen = W.AHOpen()
    W.QueueScan()
  end)
end)

-- Returns true, or false and a reason to show the player. At most one search
-- is sent per call; Blizzard's auction house code is never changed or hooked.
function W.SearchAH(itemID, name)
  if not W.AHOpen() then return false, "Open the auction house first." end
  local CAH = C_AuctionHouse
  if type(CAH) == "table" and type(CAH.IsThrottledMessageSystemReady) == "function" then
    local ok, ready = pcall(CAH.IsThrottledMessageSystemReady)
    if ok and ready == false then return false, "The auction house is busy, try again in a moment." end
  end
  local row = W.Row(itemID)
  name = name or (row and W.ItemName(row))
  if type(name) ~= "string" or name == "" then return false, "FableHub doesn't know that item's name yet." end
  -- 1. the auction house window's own search box (the results show in the window)
  local f, modes = AuctionHouseFrame, AuctionHouseFrameDisplayMode
  local bar = type(f) == "table" and f.SearchBar
  if type(f) == "table" and type(modes) == "table" and modes.Buy and type(f.SetDisplayMode) == "function"
      and type(bar) == "table" and type(bar.SetSearchText) == "function" and type(bar.StartSearch) == "function" then
    local searching = false -- once StartSearch is called, don't search a second way
    local ok = pcall(function()
      -- only switch to the Buy tab when it isn't showing (switching closes the window's dialogs)
      local mode = type(f.GetDisplayMode) == "function" and f:GetDisplayMode() or f.displayMode
      if mode ~= modes.Buy then f:SetDisplayMode(modes.Buy) end
      bar:SetSearchText(name)
      searching = true
      bar:StartSearch()
    end)
    if ok then return true end
    if searching then return false, "The auction house search didn't start. Try typing it into the auction house instead." end
  end
  -- 2. a browse search sent directly
  if type(CAH) == "table" and type(CAH.SendBrowseQuery) == "function" then
    local ok = pcall(CAH.SendBrowseQuery, { searchString = name, sorts = {}, filters = {}, itemClassFilters = {} })
    if ok then return true end
  end
  return false, "FableHub couldn't search the auction house. Try typing it into the auction house instead."
end

------------------------------------------------------------------------
-- Asking the guild: fills in the Craft Request form (the player posts it)
------------------------------------------------------------------------
function W.RequestFromGuild(row)
  if not row then return false end
  local c = W.Crafters(row.item)
  local recipe = (c and c.recipe) or row.spell
  local prof = (c and c.prof) or row.prof
  if not recipe then return false, "Nobody in the guild is known to craft this yet" end
  local R = ns.Requests
  if not (R and R.OpenNew) then return false, "Open FableHub's Craft Requests page first." end
  local qty, note = 1, "For a Craftsman's Writ"
  if row.qty and row.qty > 1 then
    -- (a request is for up to 99, so a stack of 200 goes in the note)
    note = ("%d %s for a Craftsman's Writ"):format(row.qty, W.ItemName(row))
  else
    local h = W.held[row.item]
    if h then qty = math.max(1, math.min(99, h.need - CountInBags(row.item))) end
  end
  R.OpenNew(recipe, prof, row.item, { qty = qty, note = note })
  return true
end
