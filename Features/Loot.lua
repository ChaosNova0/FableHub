-- Loot: That's My BIS priorities, loot history, automatic recording, awards and tooltips.
-- The award window (UI/Pages/Loot.lua) opens by itself only for the master looter
-- (L.IsMasterLooter) when ns.Option("awardWindow") is on; rolls are Features/Rolls.lua.
-- Tooltip lines follow ns.Option("lootTooltip").
--
-- g.tmb   = { ts, by, items = { [itemID] = { { c = lowercase name, o = order, t = 1 prio | 2 wish } } },
--             notes = { [itemID] = text }, tiers = { [itemID] = tier } }
-- g.loot  = { [entryId] = { id, item, to, at, ts, by, inst, note, prio, deleted } }
-- g.seen  = { [itemID] = instance name }   items seen dropping in raids
--
-- Pug raids (L.IsGuildGroup): loot history only keeps loot from guild groups,
-- where at least half the group (raid or party) are guild members by an exact
-- match (Rolls.lua R.Group: GUID or full name). Exactly half counts as a guild
-- group. Outside any group it counts as one, so awarding from Loot history after
-- the raid still records. In a group whose members haven't loaded yet (just
-- after zoning in or a /reload) it counts as a pug group, so nothing records by
-- mistake. In a pug group awards are still announced but not recorded, and loot
-- lines aren't recorded either. Adding an entry by hand in Loot history always
-- records (an officer typed it in on purpose). Items seen dropping (g.seen) and
-- attendance are kept as usual.
-- The award window (UI/Pages/Loot.lua) decides pug or guild group once when it
-- opens in a group (and again each time it's opened for new drops), and passes
-- it to L.Award as opts.pug, so people leaving mid-way don't change it.
--
-- Loot lines ("Bob receives loot: ...") are only recorded in a raid inside a
-- raid instance, never in a party. They're recorded for the group member the
-- name belongs to: a name that is exactly theirs, or a spelling of it no one
-- else in the group shares (R.Lookup), and only if they're a guild member by an
-- exact match. A "You receive" line records for ourselves only once our own key
-- is confirmed in the guild roster. A stranger sharing a guild member's first
-- name, or a spelling two group members share, records nothing.

local _, ns = ...
local Enc, P = ns.Encode, ns.Plans
local L = {}
ns.Loot = L

L.QUALITY = 4          -- record epics and better
L.TYPE_PRIO, L.TYPE_WISH = 1, 2

local function G()
  local g = ns.GuildDB()
  if not g then return nil end
  g.loot = g.loot or {}
  g.seen = g.seen or {}
  return g
end
L.G = G

local function Safe(s) return (tostring(s or ""):gsub("[%^;/:,=|]", " ")) end

------------------------------------------------------------------------
-- Item info (names load asynchronously)
------------------------------------------------------------------------
local itemCache, itemPending = {}, false

local function GetItemInfoCompat(id)
  if C_Item and C_Item.GetItemInfo then return C_Item.GetItemInfo(id) end
  if GetItemInfo then return GetItemInfo(id) end
end

function L.ItemInfo(id)
  id = tonumber(id)
  if not id then return nil end
  local c = itemCache[id]
  if c then return c end
  local ok, name, link, quality, itemLevel, minLevel, _, _, _, _, icon = pcall(GetItemInfoCompat, id)
  if ok and name then
    c = { name = name, link = link, quality = quality, icon = icon, ilvl = itemLevel, req = minLevel }
    itemCache[id] = c
    L.IndexItem(id, name, quality)
    return c
  end
  if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
  return nil
end

------------------------------------------------------------------------
-- Item index: names of every item we've come across (account-wide), so
-- officers can search by name. The game has no full item search for addons.
------------------------------------------------------------------------
-- running count of changes to the index (new items or renamed ones), so
-- FindItemByName knows when to rebuild its name lookup without walking it
local indexChanges = 0

function L.IndexItem(id, name, quality)
  if not id or not name or not FableHubDB then return end
  FableHubDB.itemIndex = FableHubDB.itemIndex or {}
  local cur = FableHubDB.itemIndex[id]
  if not cur or cur.n ~= name then
    FableHubDB.itemIndex[id] = { n = name, q = quality }
    indexChanges = indexChanges + 1
  end
end

-- Returns up to `limit` item IDs matching text: an item ID, a link, or part of a name.
function L.SearchItems(text, limit)
  limit = limit or 8
  text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return {} end
  local direct = L.ItemIdFromLink(text)
  if direct then
    L.ItemInfo(direct) -- start loading it
    return { direct }
  end
  local q = text:lower()
  local results, seen = {}, {}
  -- exact name the client has cached
  local ok, _, link = pcall(GetItemInfoCompat, text)
  local exact = ok and L.ItemIdFromLink(link)
  if exact then results[1] = { id = exact, score = 0 }; seen[exact] = true; L.ItemInfo(exact) end
  -- make sure items we know about by ID are in the index
  local g = G()
  if g then
    if g.tmb then for id in pairs(g.tmb.items) do L.ItemInfo(id) end end
    for id in pairs(g.seen) do L.ItemInfo(id) end
  end
  for id, rec in pairs(FableHubDB.itemIndex or {}) do
    if not seen[id] then
      local name = rec.n:lower()
      local pos = name:find(q, 1, true)
      if pos then
        seen[id] = true
        results[#results + 1] = { id = id, score = (pos == 1 and 1 or 2) * 10 - (rec.q or 0), name = name }
      end
    end
  end
  table.sort(results, function(a, b)
    if a.score ~= b.score then return a.score < b.score end
    return (a.name or "") < (b.name or "")
  end)
  local out = {}
  for i = 1, math.min(limit, #results) do out[i] = results[i].id end
  return out
end

-- An item with exactly this name (crafted items usually share their recipe's name)
local byName, byNameChanges, byNameIdx = {}, -1, nil
function L.FindItemByName(name)
  if not name or name == "" then return nil end
  local idx = FableHubDB and FableHubDB.itemIndex or {}
  -- rebuild only when IndexItem changed something (or the saved table itself changed)
  if indexChanges ~= byNameChanges or idx ~= byNameIdx then
    byName, byNameChanges, byNameIdx = {}, indexChanges, idx
    for id, rec in pairs(idx) do
      local k = rec.n:lower()
      if not byName[k] or (rec.q or 0) > (idx[byName[k]].q or 0) then byName[k] = id end
    end
  end
  local hit = byName[name:lower()]
  if hit then return hit end
  local ok, _, link = pcall(GetItemInfoCompat, name)
  return ok and L.ItemIdFromLink(link) or nil
end

local function IndexBags()
  if not (C_Container and C_Container.GetContainerNumSlots) then return end
  for bag = 0, 4 do
    for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
      local id = C_Container.GetContainerItemID(bag, slot)
      if id then L.ItemInfo(id) end
    end
  end
end
local bagPending = false
ns.RegisterEvent("BAG_UPDATE_DELAYED", function()
  if bagPending then return end
  bagPending = true
  C_Timer.After(3, function() bagPending = false; pcall(IndexBags) end)
end)
ns.On("LOGIN", function() C_Timer.After(15, function() pcall(IndexBags) end) end)

function L.ItemText(id, iconSize)
  local info = L.ItemInfo(id)
  if not info then return ("|cff9d9d9dItem #%s|r"):format(tostring(id)) end
  local r, g, b = 1, 1, 1
  if C_Item and C_Item.GetItemQualityColor then
    local ok, rr, gg, bb = pcall(C_Item.GetItemQualityColor, info.quality or 1)
    if ok and rr then r, g, b = rr, gg, bb end
  elseif ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[info.quality] then
    local q = ITEM_QUALITY_COLORS[info.quality]
    r, g, b = q.r, q.g, q.b
  end
  local icon = info.icon and ("|T%s:%d:%d:0:0:64:64:5:59:5:59|t "):format(tostring(info.icon), iconSize or 14, iconSize or 14) or ""
  return icon .. ("|cff%02x%02x%02x%s|r"):format(r * 255, g * 255, b * 255, info.name)
end

function L.ItemIdFromLink(link)
  if type(link) ~= "string" then return nil end
  return tonumber(link:match("item:(%d+)")) or tonumber(link:match("^%s*(%d+)%s*$"))
end

ns.RegisterEvent("GET_ITEM_INFO_RECEIVED", function()
  if itemPending then return end
  itemPending = true
  C_Timer.After(0.5, function() itemPending = false; ns.Fire("LOOT_CHANGED") end)
end)

------------------------------------------------------------------------
-- Matching That's My BIS character names to guild members
------------------------------------------------------------------------
local nameMap, nameMapRoster
function L.KeyForName(name)
  if not name then return nil end
  if nameMapRoster ~= ns.roster then
    nameMap, nameMapRoster = {}, ns.roster
    for key in pairs(ns.roster) do
      local short = ns.ShortName(key):lower()
      nameMap[short] = key
      local first = short:match("^(%S+)")
      if first and not nameMap[first] then nameMap[first] = key end
    end
  end
  name = name:lower()
  return nameMap[name] or nameMap[name:match("^(%S+)") or name]
end

------------------------------------------------------------------------
-- That's My BIS import
------------------------------------------------------------------------
-- Accepts the text from TMB's Gargul export: Base64 + zlib JSON, or plain JSON.
function L.ParseTMB(text)
  if type(text) ~= "string" then return nil, "Nothing pasted." end
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return nil, "Nothing pasted." end
  local jsonText = text
  if text:sub(1, 1) ~= "{" then
    local raw = ns.Base64 and ns.Base64.Decode(text)
    if not raw or raw == "" then return nil, "That doesn't look like a That's My BIS export." end
    local ok, out = pcall(function() return ns.LibDeflate:DecompressZlib(raw) end)
    if not ok or not out then return nil, "Couldn't unpack the export. Copy it again from That's My BIS, exactly as-is." end
    jsonText = out
  end
  local ok, data = pcall(ns.json.decode, jsonText)
  if not ok or type(data) ~= "table" or type(data.wishlists) ~= "table" then
    return nil, "The export has no wishlist data. Use the Gargul export on That's My BIS."
  end
  local tmb = { items = {}, notes = {}, tiers = {}, count = 0 }
  for itemID, list in pairs(data.wishlists) do
    local id = tonumber(itemID)
    if id and type(list) == "table" then
      local entries, seen = {}, {}
      for _, str in pairs(list) do
        local parts = Enc.Split(tostring(str), "|")
        -- current format: name|order|type|group ; old format has more fields (name|?|order|?|type|...)
        local name, order, typ = parts[1], parts[2], parts[3]
        if #parts > 4 then order, typ = parts[3], parts[5] end
        order = tonumber(order)
        typ = tonumber(typ) == L.TYPE_PRIO and L.TYPE_PRIO or L.TYPE_WISH
        if name and name ~= "" and order then
          local k = name:lower() .. ":" .. typ
          if not seen[k] then
            seen[k] = true
            entries[#entries + 1] = { c = name:lower(), o = order, t = typ }
            tmb.count = tmb.count + 1
          end
        end
      end
      if #entries > 0 then tmb.items[id] = entries end
    end
  end
  if type(data.notes) == "table" then
    for itemID, note in pairs(data.notes) do
      local id = tonumber(itemID)
      if id and type(note) == "string" and note ~= "" then tmb.notes[id] = note:sub(1, 120) end
    end
  end
  if type(data.tiers) == "table" then
    for itemID, tier in pairs(data.tiers) do
      local id = tonumber(itemID)
      if id and tier ~= nil then tmb.tiers[id] = tostring(tier):sub(1, 4) end
    end
  end
  if tmb.count == 0 then return nil, "The export didn't contain any entries." end
  return tmb
end

function L.Import(text)
  if not P.CanEdit("loot") then return nil, "Only officers can import priorities." end
  local tmb, err = L.ParseTMB(text)
  if not tmb then return nil, err end
  local g = G()
  tmb.ts, tmb.by = ns.Now(), ns.MyKey()
  g.tmb = tmb
  L.ShareTMB()
  ns.Fire("LOOT_CHANGED")
  return tmb
end

-- network form: "1^ts^by^items^notes^tiers"
--   items "id36:name.order.type/name.order.type;..."
function L.EncodeTMB(tmb)
  local items, notes, tiers = {}, {}, {}
  for id, list in pairs(tmb.items) do
    local parts = {}
    for _, e in ipairs(list) do parts[#parts + 1] = Safe(e.c):gsub("%.", " ") .. "." .. e.o .. "." .. e.t end
    items[#items + 1] = Enc.ToB36(id) .. ":" .. table.concat(parts, "/")
  end
  for id, n in pairs(tmb.notes or {}) do notes[#notes + 1] = Enc.ToB36(id) .. ":" .. Safe(n) end
  for id, t in pairs(tmb.tiers or {}) do tiers[#tiers + 1] = Enc.ToB36(id) .. ":" .. Safe(t) end
  return table.concat({ "1", Enc.ToB36(tmb.ts), Safe(tmb.by), table.concat(items, ";"), table.concat(notes, ";"),
    table.concat(tiers, ";") }, "^")
end

function L.DecodeTMB(text)
  local f = Enc.Split(text, "^")
  if f[1] ~= "1" then return nil end
  local tmb = { ts = Enc.FromB36(f[2]), by = f[3], items = {}, notes = {}, tiers = {}, count = 0 }
  for _, item in ipairs(Enc.Split(f[4] or "", ";")) do
    local id36, rest = item:match("^(%w+):(.*)$")
    local id = id36 and Enc.FromB36(id36)
    if id and id > 0 then
      local list = {}
      for _, e in ipairs(Enc.Split(rest, "/")) do
        local c, o, t = e:match("^(.-)%.(%d+)%.(%d)$")
        if c then list[#list + 1] = { c = c, o = tonumber(o), t = tonumber(t) }; tmb.count = tmb.count + 1 end
      end
      tmb.items[id] = list
    end
  end
  for _, item in ipairs(Enc.Split(f[5] or "", ";")) do
    local id36, rest = item:match("^(%w+):(.*)$")
    if id36 then tmb.notes[Enc.FromB36(id36)] = rest end
  end
  for _, item in ipairs(Enc.Split(f[6] or "", ";")) do
    local id36, rest = item:match("^(%w+):(.*)$")
    if id36 then tmb.tiers[Enc.FromB36(id36)] = rest end
  end
  return tmb
end

function L.ShareTMB()
  local g = G()
  if g and g.tmb then ns.Send("B", L.EncodeTMB(g.tmb)) end
end

ns.CommHandlers.B = function(sender, payload)
  local tmb = L.DecodeTMB(payload)
  if not tmb or not ns.OfficerSent(sender, tmb.by, "loot") or not ns.TimeOK(tmb.ts) then return end
  local g = G()
  if not g or (g.tmb and (g.tmb.ts or 0) >= tmb.ts) then return end
  g.tmb = tmb
  ns.Fire("LOOT_CHANGED")
end

------------------------------------------------------------------------
-- Changes made in FableHub, kept apart from the TMB import so re-importing
-- doesn't undo them. One record per member, item and list:
--   g.manual[itemID]["<key>|<type>"] = { key, t, o, ts, by, deleted }
--   deleted = true means "removed from this list" (this also hides the
--   matching That's My BIS entry). Members whose TMB name doesn't match
--   anyone in the guild use the key "?<name>".
------------------------------------------------------------------------
local function Manual()
  local g = G()
  if not g then return {} end
  g.manual = g.manual or {}
  -- older format was keyed by member only; convert once
  -- (collect first: a table can't gain keys while pairs() walks it)
  if not g.manualV2 then
    for _, list in pairs(g.manual) do
      local old = {}
      for k, m in pairs(list) do
        if type(k) == "string" and not k:find("|", 1, true) then old[#old + 1] = { k = k, m = m } end
      end
      for _, o in ipairs(old) do
        list[o.k] = nil
        o.m.key = o.m.key or o.k
        local slot = o.m.key .. "|" .. (o.m.t or L.TYPE_WISH)
        if not list[slot] or (list[slot].ts or 0) < (o.m.ts or 0) then list[slot] = o.m end
      end
    end
    g.manualV2 = true
  end
  return g.manual
end
L.Manual = Manual

local function EncodeManual(itemID, m)
  return table.concat({ "1", Enc.ToB36(itemID), Safe(m.key), tostring(m.t), tostring(m.o or 0), Enc.ToB36(m.ts), Safe(m.by),
    m.deleted and "1" or "0" }, "^")
end

local function Put(itemID, key, typ, order, deleted)
  if not P.CanEdit("loot") or not itemID or not key then return nil end
  local all = Manual()
  all[itemID] = all[itemID] or {}
  typ = typ == L.TYPE_PRIO and L.TYPE_PRIO or L.TYPE_WISH
  local m = { key = key, t = typ, o = math.max(1, tonumber(order) or 1), ts = ns.Now(), by = ns.MyKey(), deleted = deleted or nil }
  all[itemID][key .. "|" .. typ] = m
  ns.Send("M", EncodeManual(itemID, m))
  ns.Fire("LOOT_CHANGED")
  return m
end

function L.SetManual(itemID, key, typ, order) return Put(itemID, key, typ, order, false) end

-- Remove someone from an item's prio list or wishlist (imported or hand-made)
function L.RemoveEntry(itemID, key, typ) return Put(itemID, key, typ, 1, true) end

-- older name, removes from whichever lists the member is on
function L.RemoveManual(itemID, key)
  L.RemoveEntry(itemID, key, L.TYPE_PRIO)
  L.RemoveEntry(itemID, key, L.TYPE_WISH)
end

ns.CommHandlers.M = function(sender, payload)
  local f = Enc.Split(payload, "^")
  if f[1] ~= "1" or not ns.OfficerSent(sender, f[7], "loot") or not ns.TimeOK(Enc.FromB36(f[6])) then return end
  local itemID, key = Enc.FromB36(f[2]), f[3]
  if itemID <= 0 or not key or key == "" then return end
  local typ = tonumber(f[4]) == L.TYPE_PRIO and L.TYPE_PRIO or L.TYPE_WISH
  local all = Manual()
  all[itemID] = all[itemID] or {}
  local slot = key .. "|" .. typ
  local cur = all[itemID][slot]
  local ts = Enc.FromB36(f[6])
  if cur and (cur.ts or 0) >= ts then return end
  -- the order must be a plain whole number: "nan" or "inf" would break sorting the lists
  local o = (f[5] or ""):match("^%d+$") and tonumber(f[5]) or 1
  o = math.max(1, math.min(999, o))
  all[itemID][slot] = { key = key, t = typ, o = o, ts = ts, by = f[7], deleted = f[8] == "1" or nil }
  ns.Fire("LOOT_CHANGED")
end

-- every item that has any priority entry (TMB or manual)
function L.ItemsWithEntries()
  local ids = {}
  local g = G()
  if g and g.tmb then for id in pairs(g.tmb.items) do ids[id] = true end end
  for id, list in pairs(Manual()) do
    for _, m in pairs(list) do if not m.deleted then ids[id] = true break end end
  end
  return ids
end

-- Priority info for an item: prio list and wishlist, sorted, with guild keys and received flags
--   row.slotKey = what to pass to RemoveEntry for this row
function L.ItemPriorities(itemID)
  local g = G()
  local list = g and g.tmb and g.tmb.items[itemID]
  local prio, wish = {}, {}
  local manual = Manual()[itemID] or {}
  if list then
    for _, e in ipairs(list) do
      local key = L.KeyForName(e.c)
      local slotKey = key or ("?" .. e.c)
      -- anything set in FableHub for this member and list (changed order, or removed) wins
      if not manual[slotKey .. "|" .. e.t] then
        local row = { name = e.c, key = key, slotKey = slotKey, order = e.o, type = e.t,
                      received = key and L.Received(itemID, key) }
        if e.t == L.TYPE_PRIO then prio[#prio + 1] = row else wish[#wish + 1] = row end
      end
    end
  end
  for _, m in pairs(manual) do
    if not m.deleted then
      local isGuild = m.key:sub(1, 1) ~= "?"
      local row = { name = isGuild and ns.ShortName(m.key):lower() or m.key:sub(2), key = isGuild and m.key or nil,
                    -- (m.o == m.o is false only for NaN, which older versions could store)
                    slotKey = m.key, order = (type(m.o) == "number" and m.o == m.o) and m.o or 1, type = m.t, manual = true,
                    received = isGuild and L.Received(itemID, m.key) or nil }
      if m.t == L.TYPE_PRIO then prio[#prio + 1] = row else wish[#wish + 1] = row end
    end
  end
  local byOrder = function(a, b) if a.order == b.order then return a.name < b.name end return a.order < b.order end
  table.sort(prio, byOrder)
  table.sort(wish, byOrder)
  return prio, wish
end

------------------------------------------------------------------------
-- Loot history
------------------------------------------------------------------------
function L.Entries()
  local out = {}
  local g = G()
  if not g then return out end
  for _, e in pairs(g.loot) do if not e.deleted then out[#out + 1] = e end end
  table.sort(out, function(a, b) return (a.at or 0) > (b.at or 0) end)
  return out
end

-- who received what, indexed by item; rebuilt only after loot history changes
-- (tooltips and the Priorities page ask this a lot)
local recv = { dirty = true }
ns.On("LOOT_CHANGED", function() recv.dirty = true end)
local function ReceivedIndex()
  local g = G()
  local loot = g and g.loot
  if recv.dirty or recv.loot ~= loot then
    local byItem = {}
    for _, e in pairs(loot or {}) do
      if not e.deleted and e.item then
        local t = byItem[e.item]
        if not t then t = { list = {}, to = {} }; byItem[e.item] = t end
        t.list[#t.list + 1] = e
        if e.to and not t.to[e.to] then t.to[e.to] = e end
      end
    end
    recv.byItem, recv.loot, recv.dirty = byItem, loot, false
  end
  return recv.byItem
end

function L.Received(itemID, key)
  local t = ReceivedIndex()[itemID]
  return t and t.to[key] or nil
end

-- every non-deleted entry for an item
function L.ReceivedList(itemID)
  local t = ReceivedIndex()[itemID]
  return t and t.list or {}
end

function L.CountReceived(key, days)
  local g = G()
  local n, cutoff = 0, ns.Now() - (days or 30) * 86400
  if not g then return 0 end
  for _, e in pairs(g.loot) do
    if not e.deleted and e.to == key and (e.at or 0) >= cutoff then n = n + 1 end
  end
  return n
end

local function EncodeEntry(e)
  return table.concat({ "1", Safe(e.id), Enc.ToB36(e.item), Safe(e.to), Enc.ToB36(e.at), Enc.ToB36(e.ts), Safe(e.by),
    Safe(e.inst), Safe(e.note), e.deleted and "1" or "0", tostring(e.prio or "") }, "^")
end

local function DecodeEntry(text)
  local f = Enc.Split(text, "^")
  if f[1] ~= "1" or not f[2] or f[2] == "" then return nil end
  local note = (f[9] or ""):gsub("|", "") -- (shown in the UI: no formatting codes)
  return { id = f[2], item = Enc.FromB36(f[3]), to = f[4], at = Enc.FromB36(f[5]), ts = Enc.FromB36(f[6]), by = f[7],
    inst = f[8] ~= "" and f[8] or nil, note = note ~= "" and note or nil, deleted = f[10] == "1", prio = tonumber(f[11]) }
end

-- Look for an entry for the same item and player within 20 minutes (other officers record the same drop)
local function FindRecent(itemID, key, at)
  local g = G()
  for _, e in pairs(g.loot) do
    if e.item == itemID and e.to == key and math.abs((e.at or 0) - at) <= 20 * 60 then return e end
  end
end

function L.Record(itemID, key, opts)
  opts = opts or {}
  local g = G()
  if not g or not itemID or not key then return nil end
  if not P.CanEdit("loot") then return nil end
  local at = opts.at or ns.Now()
  local existing = FindRecent(itemID, key, at)
  if existing and not existing.deleted then
    -- an award followed by the actual loot message: keep the award's details
    if opts.prio and not existing.prio then existing.prio = opts.prio; existing.ts = ns.Now(); ns.Send("L", EncodeEntry(existing)) end
    return existing
  end
  local inst = opts.inst
  if not inst and GetInstanceInfo then inst = (GetInstanceInfo()) end
  local e = {
    id = Enc.ToB36(itemID) .. "-" .. Enc.ToB36(math.floor(at / 60)) .. "-" .. Safe(ns.ShortName(key)):gsub(" ", ""),
    item = itemID, to = key, at = at, ts = ns.Now(), by = ns.MyKey(), inst = inst, note = opts.note, prio = opts.prio,
  }
  g.loot[e.id] = e
  if inst then g.seen[itemID] = g.seen[itemID] or inst end
  ns.Send("L", EncodeEntry(e))
  ns.Fire("LOOT_CHANGED")
  return e
end

function L.Delete(e)
  if not P.CanEdit("loot") then return end
  e.deleted, e.ts, e.by = true, ns.Now(), ns.MyKey()
  ns.Send("L", EncodeEntry(e))
  ns.Fire("LOOT_CHANGED")
end

L.DecodeEntry = DecodeEntry -- for the officer change log

ns.CommHandlers.L = function(sender, payload)
  local e = DecodeEntry(payload)
  if not e or not ns.OfficerSent(sender, e.by, "loot") or not ns.TimeOK(e.ts) then return end
  local g = G()
  if not g then return end
  local cur = g.loot[e.id]
  if cur and (cur.ts or 0) >= e.ts then return end
  -- the same drop recorded separately by two officers: keep one entry
  if not cur then
    local dup = FindRecent(e.item, e.to, e.at)
    if dup and dup.id ~= e.id and not e.deleted then
      if e.prio and not dup.prio then dup.prio = e.prio end
      return
    end
  end
  g.loot[e.id] = e
  if e.inst then g.seen[e.item] = g.seen[e.item] or e.inst end
  ns.Fire("LOOT_CHANGED")
end

------------------------------------------------------------------------
-- Items seen dropping in raids (shared item list)
------------------------------------------------------------------------
local seenQueue = {}
local function FlushSeen()
  local byInst = {}
  for id, inst in pairs(seenQueue) do
    byInst[inst] = byInst[inst] or {}
    table.insert(byInst[inst], Enc.ToB36(id))
  end
  seenQueue = {}
  for inst, ids in pairs(byInst) do ns.Send("I", "1^" .. Safe(inst) .. "^" .. table.concat(ids, ",")) end
end

function L.Seen(itemID, inst)
  local g = G()
  if not g or not itemID or not inst or g.seen[itemID] then return end
  g.seen[itemID] = inst
  local first = next(seenQueue) == nil
  seenQueue[itemID] = inst
  if first then C_Timer.After(5, FlushSeen) end
  ns.Fire("LOOT_CHANGED")
end

ns.CommHandlers.I = function(sender, payload)
  local f = Enc.Split(payload, "^")
  if f[1] ~= "1" or not f[2] then return end
  local g = G()
  if not g then return end
  local changed, n = false, 0
  local inst = f[2]:sub(1, 60)
  -- the list only needs raid drops: a few thousand at most
  local total = 0
  for _ in pairs(g.seen) do total = total + 1 end
  if total >= 5000 then return end
  for _, id36 in ipairs(Enc.Split(f[3] or "", ",")) do
    n = n + 1
    if n > 200 then break end -- a raid never drops this many new items at once
    local id = Enc.FromB36(id36)
    if id > 0 and not g.seen[id] then g.seen[id] = inst; changed = true end
  end
  if changed then ns.Fire("LOOT_CHANGED") end
end

------------------------------------------------------------------------
-- Catch-up sync
------------------------------------------------------------------------
L.SYNC_DAYS = 180 -- loot history older than this isn't passed on in catch-up

function L.SendDigest()
  local g = G()
  if not g then return end
  local maxTs, seenCount = 0, 0
  for _, e in pairs(g.loot) do if (e.ts or 0) > maxTs then maxTs = e.ts end end
  for _ in pairs(g.seen) do seenCount = seenCount + 1 end
  local manualTs = 0
  for _, list in pairs(Manual()) do for _, m in pairs(list) do if (m.ts or 0) > manualTs then manualTs = m.ts end end end
  -- count only what catch-up passes on (the last 180 days), or the counts
  -- could never match and every digest would re-send the whole history
  local lootN, manualN = 0, 0
  local cutoff = ns.Now() - L.SYNC_DAYS * 86400
  for _, e in pairs(g.loot) do if (e.at or 0) > cutoff then lootN = lootN + 1 end end
  for _, list in pairs(Manual()) do for _ in pairs(list) do manualN = manualN + 1 end end
  ns.Send("K", table.concat({ "1", Enc.ToB36(g.tmb and g.tmb.ts or 0), Enc.ToB36(maxTs), tostring(seenCount),
    Enc.ToB36(manualTs), tostring(lootN), tostring(manualN) }, "^"))
end

ns.CommHandlers.K = function(sender, payload)
  -- loot data is officer-only, so an officer passes it on; the shared list of
  -- items seen dropping comes from the usual relay
  local member, officer = ns.AmRelayFor(sender), ns.AmOfficerRelayFor(sender, "loot")
  if not member and not officer then return end
  local f = Enc.Split(payload, "^")
  if f[1] ~= "1" then return end
  local g = G()
  if not g then return end
  local tmbTs, lootTs, seenCount = Enc.FromB36(f[2]), Enc.FromB36(f[3]), tonumber(f[4]) or 0
  if officer and g.tmb and (g.tmb.ts or 0) > tmbTs then L.ShareTMB() end
  -- counts (sent by 0.13.7+): if they have fewer entries than us, they missed older ones
  local theirLootN, theirManualN = tonumber(f[6]), tonumber(f[7])
  local cutoff = ns.Now() - L.SYNC_DAYS * 86400
  local myLootN, myManualN = 0, 0
  for _, e in pairs(g.loot) do if (e.at or 0) > cutoff then myLootN = myLootN + 1 end end
  for _, list in pairs(Manual()) do for _ in pairs(list) do myManualN = myManualN + 1 end end
  local allLoot = theirLootN and theirLootN < myLootN
  local allManual = theirManualN and theirManualN < myManualN
  for _, e in pairs(g.loot) do
    if officer and (allLoot or (e.ts or 0) > lootTs) and (e.at or 0) > cutoff then ns.Send("L", EncodeEntry(e)) end
  end
  local manualTs = Enc.FromB36(f[5])
  for itemID, list in pairs(Manual()) do
    for _, m in pairs(list) do
      if officer and (allManual or (m.ts or 0) > manualTs) then ns.Send("M", EncodeManual(itemID, m)) end
    end
  end
  local mine = 0
  for _ in pairs(g.seen) do mine = mine + 1 end
  if member and mine > seenCount then
    for id, inst in pairs(g.seen) do seenQueue[id] = inst end
    FlushSeen()
  end
end

------------------------------------------------------------------------
-- Automatic recording from loot messages (officers in a raid)
------------------------------------------------------------------------
local function ToPattern(fmt)
  if not fmt then return nil end
  local p = fmt:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
  p = p:gsub("%%%%s", "(.+)"):gsub("%%%%d", "(%%d+)")
  return "^" .. p .. "$"
end

local patterns
local function LootPatterns()
  if patterns then return patterns end
  patterns = {}
  local function add(fmt, self)
    local p = ToPattern(fmt)
    if p then patterns[#patterns + 1] = { p = p, self = self } end
  end
  add(LOOT_ITEM_MULTIPLE or "%s receives loot: %sx%d.", false)
  add(LOOT_ITEM or "%s receives loot: %s.", false)
  add(LOOT_ITEM_SELF_MULTIPLE or "You receive loot: %sx%d.", true)
  add(LOOT_ITEM_SELF or "You receive loot: %s.", true)
  add(LOOT_ITEM_PUSHED_SELF or "You receive item: %s.", true)
  return patterns
end

-- "Bob receives loot: [link]." -> "Bob", link ; "You receive loot: [link]." -> our key, link, true
function L.ParseLootMessage(msg)
  for _, pat in ipairs(LootPatterns()) do
    local a, b = msg:match(pat.p)
    if a then
      if pat.self then return ns.MyKey(), a, true end
      return a, b, false
    end
  end
end

-- Is this a guild group? At least half of the raid or party are guild members
-- by an exact match (see the header). True when we're not in a group at all;
-- false in a group we can't see anyone in yet (still loading).
function L.IsGuildGroup()
  local grp = ns.Rolls.Group()
  local n = grp.n or 0
  if n == 0 then
    local inGroup = (IsInRaid and IsInRaid()) or (IsInGroup and IsInGroup())
    return not inGroup
  end
  local count = 0
  for _, m in pairs(grp.members) do if m.key ~= nil then count = count + 1 end end
  return count * 2 >= n
end

local function InRaidInstance()
  if not (IsInRaid and IsInRaid()) then return false end
  if not GetInstanceInfo then return true end
  local name, instanceType = GetInstanceInfo()
  return instanceType == "raid", name
end

local function Quality(link, itemID)
  if C_Item and C_Item.GetItemQualityByID then
    local ok, q = pcall(C_Item.GetItemQualityByID, itemID)
    if ok and q then return q end
  end
  local ok, _, _, q = pcall(GetItemInfoCompat, link or itemID)
  return ok and q or nil
end

ns.RegisterEvent("CHAT_MSG_LOOT", function(msg)
  if type(msg) ~= "string" or (issecretvalue and issecretvalue(msg)) then return end
  if not P.CanEdit("loot") then return end
  local inRaid, inst = InRaidInstance()
  if not inRaid then return end
  local who, link, isSelf = L.ParseLootMessage(msg)
  local itemID = L.ItemIdFromLink(link)
  if itemID then L.ItemInfo(itemID) end
  if not who or not itemID then return end
  local q = Quality(link, itemID)
  if not q or q < L.QUALITY then return end
  -- pug raids aren't kept in loot history
  if not L.IsGuildGroup() then return end
  -- only the group member this name belongs to, and only if they're a guild
  -- member (ourselves only once our key is confirmed in the guild roster)
  local key
  if isSelf then
    local me = ns.MyKey()
    key = ns.roster[me] and me or nil
  else
    local m = ns.Rolls.Lookup(who)
    key = m and m.key
  end
  if not key then return end
  local prio
  for _, p in ipairs((L.ItemPriorities(itemID))) do if p.key == key then prio = p.order break end end
  L.Record(itemID, key, { inst = inst, prio = prio })
end)

------------------------------------------------------------------------
-- Award (raid leader / officer clicks a winner)
------------------------------------------------------------------------
L.settings = function()
  local s = FableHubDB.settings
  if s.lootAnnounce == nil then s.lootAnnounce = true end
  return s
end

-- Are we the master looter? true / false, or nil when this client can't tell
-- (no loot method API). Forever has C_PartyInfo.GetLootMethod(): an
-- Enum.LootMethod number, the master looter's party index and raid index; older
-- clients GetLootMethod() with "master" instead of the number. The party index
-- is 0 when it's us, in a party and in a raid alike (it's nil when the master
-- looter isn't in our party or raid group), so no names are compared.
function L.IsMasterLooter()
  local method, partyML
  if C_PartyInfo and C_PartyInfo.GetLootMethod then
    method, partyML = C_PartyInfo.GetLootMethod()
  elseif GetLootMethod then
    method, partyML = GetLootMethod()
  end
  if method == nil then return nil end
  local master = method == "master"
    or (type(method) == "number" and Enum and Enum.LootMethod and method == Enum.LootMethod.Masterlooter)
  if not master then return false end
  return partyML == 0
end

-- With the loot window open as master looter: the loot slot holding the item
-- and the candidate number of group member `memberId` (see Rolls.lua R.Group).
-- Candidates are matched by their exact name; a spelling two group members
-- share is never used. Returns nil (and why) when it can't be given that way.
function L.MasterLootTarget(itemID, memberId)
  if not (GetNumLootItems and GetMasterLootCandidate and GiveMasterLoot) then return nil end
  if not memberId then return nil, "not in group" end
  local R = ns.Rolls
  for slot = 1, GetNumLootItems() do
    local link = GetLootSlotLink and GetLootSlotLink(slot)
    if link and L.ItemIdFromLink(link) == itemID then
      for i = 1, 40 do
        local name = GetMasterLootCandidate(slot, i)
        local m = name and R.Lookup(name)
        if m and m.id == memberId then return slot, i end
      end
      return nil, "not eligible"
    end
  end
  return nil, "not in the loot window"
end

-- Asks the game to hand the item over through master loot. Returns the loot
-- slot when the request was made (whether it worked shows when the slot
-- empties: see the award window), or nil and why not.
function L.GiveMasterLoot(itemID, memberId)
  local slot, cand = L.MasterLootTarget(itemID, memberId)
  if not slot then return nil, cand end
  if not pcall(GiveMasterLoot, slot, cand) then return nil, "refused" end
  return slot
end

-- Says who got it in raid (or party) chat, when announcing is on
function L.AnnounceAward(itemID, name, opts)
  opts = opts or {}
  if not ns.Option("lootAnnounce") or not SendChatMessage then return end
  local chan = (IsInRaid and IsInRaid() and "RAID") or (IsInGroup and IsInGroup() and "PARTY") or nil
  if not chan then return end
  local info = L.ItemInfo(itemID)
  local what = (info and info.link) or ("item " .. itemID)
  local why = opts.prio and (" (prio " .. opts.prio .. ")") or (opts.wish and (" (wishlist " .. opts.wish .. ")") or "")
  pcall(SendChatMessage, ("%s awarded to %s%s"):format(what, name, why), chan)
end

-- Records a guild member's award in loot history and announces it. Returns the
-- loot history entry. In a pug group nothing is recorded: the award is only
-- announced, and it returns nil, "pug". opts.pug (true / false) is what the
-- award window decided when it opened; when nil it's L.IsGuildGroup() now.
function L.Award(itemID, key, opts)
  opts = opts or {}
  if not itemID or not key or not P.CanEdit("loot") then return nil end
  local pug = opts.pug
  if pug == nil then pug = not L.IsGuildGroup() end
  if pug then
    L.AnnounceAward(itemID, ns.ShortName(key), opts)
    return nil, "pug"
  end
  local e = L.Record(itemID, key, { prio = opts.prio, note = opts.note })
  if e then L.AnnounceAward(itemID, ns.ShortName(key), opts) end
  return e
end

------------------------------------------------------------------------
-- Tooltips: prio list, wishlist, and who already has it
------------------------------------------------------------------------
local function AddLootLines(tooltip, itemID)
  if not itemID or not IsInGuild() or not ns.Option("lootTooltip") then return end
  local g = G()
  if not g then return end
  local prio, wish = L.ItemPriorities(itemID)
  local received = {}
  for i, e in ipairs(L.ReceivedList(itemID)) do received[i] = e end
  if #prio == 0 and #wish == 0 and #received == 0 then return end
  local T = ns.Theme
  local hex = T.AccentHex()
  tooltip:AddLine(" ")
  tooltip:AddLine(("|c%sFableHub|r"):format(hex))
  local function Names(list, limit)
    local out = {}
    for i, r in ipairs(list) do
      if i > limit then out[#out + 1] = ("+%d"):format(#list - limit) break end
      local nm = r.key and ns.ShortName(r.key) or r.name
      local text = ("%d %s"):format(r.order, nm)
      if r.received then text = "|cff808080" .. text .. " (has it)|r" end
      out[#out + 1] = text
    end
    return table.concat(out, ", ")
  end
  if #prio > 0 then tooltip:AddLine("Prio: " .. Names(prio, 6), 1, 0.82, 0, true) end
  if #wish > 0 then tooltip:AddLine("Wishlist: " .. Names(wish, 6), 0.8, 0.8, 0.8, true) end
  local note = g.tmb and g.tmb.notes and g.tmb.notes[itemID]
  if note then tooltip:AddLine(note, 0.7, 0.7, 0.7, true) end
  table.sort(received, function(a, b) return (a.at or 0) > (b.at or 0) end)
  for i, e in ipairs(received) do
    if i > 3 then break end
    tooltip:AddDoubleLine("Received by " .. ns.ShortName(e.to), date("%d %b", e.at), 0.6, 0.6, 0.6, 0.5, 0.5, 0.5)
  end
end
L.AddLootLines = AddLootLines

local function HookTooltips()
  if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
      if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end
      local id = data and data.id
      if issecretvalue and issecretvalue(id) then return end
      if id then pcall(L.ItemInfo, id) end
      pcall(AddLootLines, tooltip, id)
    end)
  elseif GameTooltip and GameTooltip.HookScript then
    GameTooltip:HookScript("OnTooltipSetItem", function(tt)
      local _, link = tt:GetItem()
      pcall(AddLootLines, tt, L.ItemIdFromLink(link))
    end)
  end
end

ns.On("LOGIN", function() pcall(HookTooltips) end)

ns.RegisterDigest(function() L.SendDigest() end)
