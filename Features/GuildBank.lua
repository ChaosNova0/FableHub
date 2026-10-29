-- Guild bank: what's in the guild bank, its gold, its logs, and item requests.
--
-- Addons can only read the bank while someone has it open at a guild banker,
-- so every member's FableHub saves a copy of the tabs they can see when they
-- open it, and shares it. The game's own tab permissions decide who gets what:
--   * the Guild Master's FableHub reads which ranks may view each tab (only the
--     Guild Master's client can read that for every rank) and shares the map;
--   * tabs every rank may view go to the whole guild;
--   * restricted tabs are sent privately (addon whisper) only to members whose
--     rank may view them, and nobody else's addon ever receives them.
-- Until the Guild Master has opened the bank once with FableHub, restricted-ness
-- is unknown, so tabs only go to members of the same rank or higher than the
-- person who read them.
--
-- g.bank = {
--   tabs  = { [tab] = { name, icon, ts, by, items = { [slot] = { id, n, s } } } },
--   logs  = { [tab] = { ts, by, entries = { { k, who, id, n, at } } } }   tab 0 = gold log
--   money = { v, ts, by },
--   perm  = { ts, by, ranks, tabs, view = { [tab] = { [rankIndex] = true } } },
--   requests = { [id] = { id, by, item, qty, note, status, ts, actor, created } },
-- }
-- Messages: t tab contents, l log, g gold, p permissions, q request, d digest.

local _, ns = ...
local Enc, P = ns.Encode, ns.Plans
local B = {}
ns.GuildBank = B

B.SLOTS = 98
B.MAX_TABS = 8
B.STATUS = { open = "Requested", given = "Handed over", declined = "Declined", cancelled = "Cancelled" }
B.KEEP_DONE = 7 * 86400
B.EXPIRE_OPEN = 30 * 86400 -- open requests nobody answered are dropped after this

local function G()
  local g = ns.GuildDB()
  if not g then return nil end
  g.bank = g.bank or {}
  local b = g.bank
  b.tabs = b.tabs or {}
  b.logs = b.logs or {}
  b.requests = b.requests or {}
  return b
end
B.G = G

local function Safe(s) return (tostring(s or ""):gsub("[%^/;,|]", " ")) end

-- a received whole number: digits only (no "nan", "inf", "-5" or "1e9"),
-- clamped to lo..hi; anything else is `default`
local function Num(s, lo, hi, default)
  if type(s) ~= "string" or #s > 15 or not s:match("^%d+$") then return default end
  return math.max(lo, math.min(hi, tonumber(s)))
end

------------------------------------------------------------------------
-- Permissions
------------------------------------------------------------------------
local function MaxRank()
  local b = G()
  local n = (b and b.perm and b.perm.ranks) or ((GuildControlGetNumRanks and GuildControlGetNumRanks()) or 10)
  return n - 1
end

-- may this member's rank view this tab? (tab 0 = gold log: everyone)
function B.CanView(key, tab)
  if tab == 0 then return true end
  local rank = P.RankIndex(key)
  if key == ns.MyKey() and rank == nil then return true end
  if rank == nil then return false end
  if rank == 0 then return true end
  local b = G()
  local perm = b and b.perm
  if perm and perm.view then
    return perm.view[tab] and perm.view[tab][rank] or false
  end
  -- no map yet: same rank or higher than whoever read the tab
  local t = b and b.tabs[tab]
  if not t then return true end -- nothing stored yet: whoever sent it decided
  local readerRank = P.RankIndex(t.by)
  return readerRank ~= nil and rank <= readerRank
end

-- every rank may view it
function B.IsPublic(tab)
  if tab == 0 then return true end
  local b = G()
  local perm = b and b.perm
  if not (perm and perm.view and perm.view[tab]) then return false end
  for r = 0, MaxRank() do if not perm.view[tab][r] then return false end end
  return true
end

local function EncodePerm(p)
  local parts = {}
  for tab, ranks in pairs(p.view or {}) do
    local rs = {}
    for r in pairs(ranks) do rs[#rs + 1] = tostring(r) end
    table.sort(rs, function(a, b) return tonumber(a) < tonumber(b) end)
    parts[#parts + 1] = tab .. ":" .. table.concat(rs, ".")
  end
  table.sort(parts)
  return table.concat({ "1", Enc.ToB36(p.ts or 0), Safe(p.by), tostring(p.ranks or 0), tostring(p.tabs or 0),
                        table.concat(parts, ";") }, "^")
end

local function DecodePerm(text)
  local f = Enc.Split(text, "^")
  if f[1] ~= "1" then return nil end
  local p = { ts = Enc.FromB36(f[2]), by = f[3], ranks = tonumber(f[4]) or 0, tabs = tonumber(f[5]) or 0, view = {} }
  for _, part in ipairs(Enc.Split(f[6] or "", ";")) do
    local tab, rs = part:match("^(%d+):(.*)$")
    tab = tonumber(tab)
    if tab then
      p.view[tab] = {}
      for _, r in ipairs(Enc.Split(rs, ".")) do if tonumber(r) then p.view[tab][tonumber(r)] = true end end
    end
  end
  return p
end

-- Guild Master only: read every rank's view permission for every tab
function B.ReadPermissions()
  if not P.IsGuildMaster() then return end
  if not (GuildControlGetNumRanks and GuildControlSetRank and GetGuildBankTabPermissions and GetNumGuildBankTabs) then return end
  local b = G()
  if not b then return end
  if GuildControlUI and GuildControlUI.IsShown and GuildControlUI:IsShown() then return end -- don't disturb it
  local ranks, tabs = GuildControlGetNumRanks() or 0, GetNumGuildBankTabs() or 0
  if ranks == 0 or tabs == 0 then return end
  local view = {}
  for tab = 1, tabs do view[tab] = { [0] = true } end
  for rank = 2, ranks do -- rank 1 here is the Guild Master (rank index 0), who sees everything
    pcall(GuildControlSetRank, rank)
    for tab = 1, tabs do
      local ok, canView = pcall(GetGuildBankTabPermissions, tab)
      if ok and canView then view[tab][rank - 1] = true end
    end
  end
  pcall(GuildControlSetRank, 1)
  local p = { ts = ns.Now(), by = ns.MyKey(), ranks = ranks, tabs = tabs, view = view }
  if b.perm and EncodePerm({ view = b.perm.view, ranks = b.perm.ranks, tabs = b.perm.tabs })
    == EncodePerm({ view = view, ranks = ranks, tabs = tabs }) then return end
  p.ts = math.max(p.ts, (b.perm and b.perm.ts or 0) + 1)
  b.perm = p
  ns.Send("p", EncodePerm(p))
  B.DropUnviewable()
  -- tabs opened up to more ranks: send them to the newly allowed members now
  C_Timer.After(2, function()
    for tab, t in pairs(b.tabs) do B.Distribute(tab, "t", B.EncodeTab(tab, t)) end
    for tab, l in pairs(b.logs) do if tab ~= 0 then B.Distribute(tab, "l", B.EncodeLog(tab, l)) end end
  end)
  ns.Fire("BANK_CHANGED")
end

ns.CommHandlers.p = function(sender, payload)
  local p = DecodePerm(payload)
  if not p or P.RankIndex(p.by) ~= 0 then return end -- only the Guild Master
  -- straight from the Guild Master, or passed on by an officer
  if not ns.OfficerSent(sender, p.by) or not ns.TimeOK(p.ts) then return end
  local b = G()
  if not b or (b.perm and (b.perm.ts or 0) >= p.ts) then return end
  b.perm = p
  B.DropUnviewable()
  ns.Fire("BANK_CHANGED")
end

-- forget tabs (and their logs) this character's rank can no longer view
function B.DropUnviewable()
  local b = G()
  if not b or not b.perm then return end
  local me = ns.MyKey()
  for tab in pairs(b.tabs) do if not B.CanView(me, tab) then b.tabs[tab] = nil end end
  for tab in pairs(b.logs) do if tab ~= 0 and not B.CanView(me, tab) then b.logs[tab] = nil end end
end

------------------------------------------------------------------------
-- Encoding
------------------------------------------------------------------------
-- the parts of an item link that matter beyond its ID (random suffixes, enchants)
-- item:id:enchant:gem1:gem2:gem3:gem4:suffix:... - keep the first seven fields
-- only when the item has an enchant or random suffix ("of the Monkey")
local function ItemString(link)
  local s = type(link) == "string" and link:match("item:([%-%d:]+)")
  if not s then return nil end
  local f = {}
  for v in (s .. ":"):gmatch("([^:]*):") do f[#f + 1] = v end
  local id = tonumber(f[1])
  local enchant, suffix = tonumber(f[2]) or 0, tonumber(f[7]) or 0
  if not id then return nil end
  if enchant == 0 and suffix == 0 then return id, nil end
  local keep = {}
  for i = 1, 7 do keep[i] = f[i] or "" end
  return id, table.concat(keep, ":")
end
B.ItemString = ItemString

local function EncodeTab(tab, t)
  local items = {}
  for slot, it in pairs(t.items or {}) do
    items[#items + 1] = slot .. "." .. Enc.ToB36(it.id) .. "." .. (it.n or 1) .. (it.s and ("." .. it.s:gsub(":", "_")) or "")
  end
  table.sort(items)
  return table.concat({ "1", tab, Enc.ToB36(t.ts or 0), Safe(t.by), Safe(t.name), Safe(t.icon), table.concat(items, ",") }, "^")
end

B.EncodeTab = EncodeTab

local function DecodeTab(text)
  local f = Enc.Split(text, "^")
  local tab = tonumber(f[2])
  if f[1] ~= "1" or not tab or tab < 1 or tab > B.MAX_TABS then return nil end
  local t = { ts = Enc.FromB36(f[3]), by = f[4], name = f[5] ~= "" and f[5] or ("Tab " .. tab),
              icon = tonumber(f[6]) or (f[6] ~= "" and f[6]) or nil, items = {} }
  for _, part in ipairs(Enc.Split(f[7] or "", ",")) do
    local slot, id, n, s = part:match("^(%d+)%.(%w+)%.(%d+)%.?(.*)$")
    slot = tonumber(slot)
    if slot and slot >= 1 and slot <= B.SLOTS then
      -- s: the item string (enchant / random suffix), digits only, at most 120 characters
      local str = (s ~= "" and #s <= 120 and s:match("^[%d_%-]+$")) and (s:gsub("_", ":")) or nil
      t.items[slot] = { id = Enc.FromB36(id), n = tonumber(n) or 1, s = str }
    end
  end
  return tab, t
end

local function EncodeLog(tab, l)
  local entries = {}
  for _, e in ipairs(l.entries or {}) do
    entries[#entries + 1] = table.concat({ e.k or "", Safe(e.who), Enc.ToB36(e.id or 0), tostring(e.n or 0),
                                           Enc.ToB36(e.at or 0), tostring(e.from or 0), tostring(e.to or 0) }, "/")
  end
  return table.concat({ "1", tab, Enc.ToB36(l.ts or 0), Safe(l.by), table.concat(entries, ";") }, "^")
end

B.EncodeLog = EncodeLog

local function DecodeLog(text)
  local f = Enc.Split(text, "^")
  local tab = tonumber(f[2])
  if f[1] ~= "1" or not tab or tab < 0 or tab > B.MAX_TABS then return nil end
  local l = { ts = Enc.FromB36(f[3]), by = f[4], entries = {} }
  for _, part in ipairs(Enc.Split(f[5] or "", ";")) do
    local p = Enc.Split(part, "/")
    if p[1] and p[1] ~= "" and #l.entries < 100 then -- the game keeps 25 per tab
      -- n: item count or copper; from/to: tab numbers
      l.entries[#l.entries + 1] = { k = p[1], who = p[2], id = Enc.FromB36(p[3]), n = Num(p[4], 0, 1e12, 0),
                                    at = Enc.FromB36(p[5]), from = Num(p[6], 0, B.MAX_TABS, 0),
                                    to = Num(p[7], 0, B.MAX_TABS, 0) }
    end
  end
  return tab, l
end

------------------------------------------------------------------------
-- Sharing (respecting tab permissions)
------------------------------------------------------------------------
-- send one tab's data: everyone if every rank may view it, otherwise only
-- to online FableHub users whose rank may (or just `only`, for catch-up)
local function Distribute(tab, msgType, payload, only)
  if B.IsPublic(tab) then
    if only then ns.SendTo(only, msgType, payload) else ns.Send(msgType, payload) end
    return
  end
  if only then
    if B.CanView(only, tab) then ns.SendTo(only, msgType, payload) end
    return
  end
  for key in pairs(ns.present) do
    if key ~= ns.MyKey() and ns.IsOnline(key) and B.CanView(key, tab) then ns.SendTo(key, msgType, payload) end
  end
end
B.Distribute = Distribute

local function Store(kind, tab, data, sender)
  local b = G()
  if not b or not ns.TimeOK(data.ts) then return false end
  local into = kind == "tab" and b.tabs or b.logs
  local cur = into[tab]
  if cur and (cur.ts or 0) >= (data.ts or 0) then return false end
  -- from the member who read it (or an officer); copies passed on by other
  -- members only fill a tab we have nothing for
  if cur and sender and not ns.FirstHand(sender, data.by) then return false end
  into[tab] = data
  ns.Fire("BANK_CHANGED")
  return true
end

-- with the Guild Master's map, both the reader and we must be allowed; without
-- it, the sender already decided who may receive it
local function Acceptable(tab, by)
  local b = G()
  if not b then return false end
  if not b.perm then return P.RankIndex(by) ~= nil end
  return B.CanView(by, tab) and B.CanView(ns.MyKey(), tab)
end

ns.CommHandlers.t = function(sender, payload)
  local tab, t = DecodeTab(payload)
  if tab and Acceptable(tab, t.by) then Store("tab", tab, t, sender) end
end

ns.CommHandlers.l = function(sender, payload)
  local tab, l = DecodeLog(payload)
  if tab and Acceptable(tab, l.by) then Store("log", tab, l, sender) end
end

ns.CommHandlers.g = function(sender, payload)
  local f = Enc.Split(payload, "^")
  if f[1] ~= "1" then return end
  local b = G()
  local v = Num(f[4], 0, 1e12) -- copper, a plain whole number
  if not v then return end
  local m = { ts = Enc.FromB36(f[2]), by = f[3], v = v }
  if not b or (b.money and (b.money.ts or 0) >= m.ts) or not P.RankIndex(m.by) or not ns.TimeOK(m.ts) then return end
  if b.money and not ns.FirstHand(sender, m.by) then return end -- second-hand copies only fill gaps
  b.money = m
  ns.Fire("BANK_CHANGED")
end

local function SendMoney(only)
  local b = G()
  local m = b and b.money
  if not m then return end
  local payload = table.concat({ "1", Enc.ToB36(m.ts), Safe(m.by), tostring(m.v or 0) }, "^")
  if only then ns.SendTo(only, "g", payload) else ns.Send("g", payload) end
end

------------------------------------------------------------------------
-- Reading the bank (anyone, while it's open)
------------------------------------------------------------------------
local reader = { open = false }
B.reader = reader

local function ReadTab(tab)
  local items, count = {}, 0
  for slot = 1, B.SLOTS do
    local link = GetGuildBankItemLink and GetGuildBankItemLink(tab, slot)
    if link then
      local _, n = GetGuildBankItemInfo(tab, slot)
      local id, s = ItemString(link)
      if id then items[slot] = { id = id, n = n or 1, s = s }; count = count + 1 end
    end
  end
  return items, count
end

local LOG_KINDS = { deposit = "d", withdraw = "w", move = "m", repair = "r", withdrawForTab = "w",
                    buyTab = "b", depositSummary = "d" }

local function ReadLog(tab)
  local entries = {}
  local now = ns.Now()
  local function Ago(y, mo, d, h)
    return now - ((((y or 0) * 12 + (mo or 0)) * 30 + (d or 0)) * 24 + (h or 0)) * 3600
  end
  if tab == 0 then
    local n = GetNumGuildBankMoneyTransactions and GetNumGuildBankMoneyTransactions() or 0
    for i = 1, n do
      local kind, who, amount, y, mo, d, h = GetGuildBankMoneyTransaction(i)
      if kind then
        entries[#entries + 1] = { k = kind == "deposit" and "gd" or (kind == "repair" and "gr" or "gw"),
                                  who = who or "?", n = amount or 0, at = Ago(y, mo, d, h) }
      end
    end
  else
    local n = GetNumGuildBankTransactions and GetNumGuildBankTransactions(tab) or 0
    for i = 1, n do
      local kind, who, link, count, from, to, y, mo, d, h = GetGuildBankTransaction(tab, i)
      local id = link and ItemString(link)
      if kind and id then
        entries[#entries + 1] = { k = LOG_KINDS[kind] or "m", who = who or "?", id = id, n = count or 1,
                                  at = Ago(y, mo, d, h), from = from or 0, to = to or 0 }
      end
    end
  end
  return entries
end

local function Viewable()
  local out = {}
  local n = GetNumGuildBankTabs and GetNumGuildBankTabs() or 0
  for tab = 1, math.min(n, B.MAX_TABS) do
    local name, icon, isViewable = GetGuildBankTabInfo(tab)
    if isViewable then out[#out + 1] = { tab = tab, name = name, icon = icon } end
  end
  return out
end

-- one tab at a time: ask the server for it, wait for the reply, read it
local function Step()
  if not reader.open then return end
  local job = table.remove(reader.queue, 1)
  if not job then
    reader.busy = false
    B.ReadMoney()
    return
  end
  reader.busy, reader.job, reader.got = true, job, false
  if job.kind == "tab" then
    -- when we asked: a slots update right after this is still about the
    -- previous tab (or the bank opening), not this one (see Got)
    reader.queriedAt, job.recheck = GetTime(), nil
    if QueryGuildBankTab then QueryGuildBankTab(job.tab) end
  else
    if QueryGuildBankLog then QueryGuildBankLog(job.tab == 0 and (B.MAX_TABS + 1) or job.tab) end
  end
  local mine = job
  C_Timer.After(3, function() -- no reply: move on without saving anything
    if reader.job == mine and not reader.got then reader.job = nil; Step() end
  end)
end

-- returns true when the tab should be read again before trusting it
local function Finish(job)
  local b = G()
  if not b or not job then return end
  local me = ns.MyKey()
  if job.kind == "tab" then
    local items, count = ReadTab(job.tab)
    local t = { name = job.name or ("Tab " .. job.tab), icon = job.icon, items = items, by = me }
    local cur = b.tabs[job.tab]
    -- an empty read of a tab we have items for is usually a reply that hadn't
    -- arrived yet: only believe it once a second read agrees
    if count == 0 and cur and next(cur.items or {}) and not job.emptyOnce then
      job.emptyOnce = true
      return true
    end
    if not cur or EncodeTab(job.tab, { name = cur.name, icon = cur.icon, items = cur.items })
                ~= EncodeTab(job.tab, { name = t.name, icon = t.icon, items = items }) then
      t.ts = math.max(ns.Now(), (cur and cur.ts or 0) + 1)
      b.tabs[job.tab] = t
      Distribute(job.tab, "t", EncodeTab(job.tab, t))
      ns.Fire("BANK_CHANGED")
    end
  else
    local entries = ReadLog(job.tab)
    local cur = b.logs[job.tab]
    local l = { entries = entries, by = me }
    if #entries > 0 and (not cur or EncodeLog(job.tab, { entries = cur.entries }) ~= EncodeLog(job.tab, { entries = entries })) then
      l.ts = math.max(ns.Now(), (cur and cur.ts or 0) + 1)
      b.logs[job.tab] = l
      Distribute(job.tab, "l", EncodeLog(job.tab, l))
      ns.Fire("BANK_CHANGED")
    end
  end
end

function B.ReadMoney()
  if not reader.open or not GetGuildBankMoney then return end
  local v = GetGuildBankMoney()
  local b = G()
  if not b or not v then return end
  if b.money and b.money.v == v then return end
  b.money = { v = v, ts = math.max(ns.Now(), (b.money and b.money.ts or 0) + 1), by = ns.MyKey() }
  SendMoney()
  ns.Fire("BANK_CHANGED")
end

function B.OnOpen()
  -- GUILDBANKFRAME_OPENED and PLAYER_INTERACTION_MANAGER_FRAME_SHOW can both
  -- fire for one visit: read once
  if not IsInGuild() or reader.open then return end
  reader.open = true
  if P.IsGuildMaster() then pcall(B.ReadPermissions) end
  reader.queue = {}
  for _, v in ipairs(Viewable()) do
    reader.queue[#reader.queue + 1] = { kind = "tab", tab = v.tab, name = v.name, icon = v.icon }
  end
  for _, v in ipairs(Viewable()) do reader.queue[#reader.queue + 1] = { kind = "log", tab = v.tab } end
  reader.queue[#reader.queue + 1] = { kind = "log", tab = 0 }
  C_Timer.After(0.5, Step)
end

function B.OnClose()
  reader.open, reader.busy, reader.job = false, false, nil
end

local function Got(kind)
  local job = reader.job
  if not reader.open or not job or job.kind ~= kind or reader.got then return end
  -- the event doesn't say which tab: one arriving within ~0.2 s of our query
  -- is the reply for an earlier tab, not the one we just asked for. Look
  -- again shortly in case it was ours after all (or ours came at once).
  if kind == "tab" and GetTime() - (reader.queriedAt or 0) < 0.15 then
    if not job.recheck then
      job.recheck = true
      C_Timer.After(0.25, function() if reader.job == job and not reader.got then Got(kind) end end)
    end
    return
  end
  reader.got = true
  C_Timer.After(0.3, function()
    if reader.job ~= job then return end
    -- an empty read to double-check goes to the front of the queue again
    if Finish(job) then table.insert(reader.queue, 1, job) end
    reader.job = nil
    Step()
  end)
end

ns.RegisterEvent("GUILDBANKFRAME_OPENED", B.OnOpen)
ns.RegisterEvent("GUILDBANKFRAME_CLOSED", B.OnClose)
ns.RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", function(kind)
  local GB = Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType.GuildBanker
  if GB and kind == GB then B.OnOpen() end
end)
ns.RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", function(kind)
  local GB = Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType.GuildBanker
  if GB and kind == GB then B.OnClose() end
end)
ns.RegisterEvent("GUILDBANKBAGSLOTS_CHANGED", function() Got("tab") end)
ns.RegisterEvent("GUILDBANKLOG_UPDATE", function() Got("log") end)
ns.RegisterEvent("GUILDBANK_UPDATE_MONEY", function() B.ReadMoney() end)
ns.RegisterEvent("GUILDBANK_UPDATE_TABS", function()
  if reader.open and P.IsGuildMaster() then pcall(B.ReadPermissions) end
end)

------------------------------------------------------------------------
-- Looking things up
------------------------------------------------------------------------
-- tabs this character may see, in order
function B.Tabs()
  local b = G()
  local out = {}
  if not b then return out end
  for tab, t in pairs(b.tabs) do
    if B.CanView(ns.MyKey(), tab) then out[#out + 1] = { tab = tab, data = t } end
  end
  table.sort(out, function(a, c) return a.tab < c.tab end)
  return out
end

-- totals per item across the visible tabs: { [id] = { id, n, tabs = { [tab] = n }, s } }
function B.Totals()
  local out = {}
  for _, v in ipairs(B.Tabs()) do
    for _, it in pairs(v.data.items or {}) do
      local t = out[it.id]
      if not t then t = { id = it.id, n = 0, tabs = {}, s = it.s }; out[it.id] = t end
      t.n = t.n + (it.n or 1)
      t.tabs[v.tab] = (t.tabs[v.tab] or 0) + (it.n or 1)
    end
  end
  return out
end

function B.FormatMoney(copper)
  copper = math.floor(copper or 0)
  local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
  local gs = tostring(g):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
  return ("|cffffd700%sg|r |cffc7c7cf%ds|r |cffeda55f%dc|r"):format(gs, s, c)
end

------------------------------------------------------------------------
-- Item requests: members ask, officers hand over or decline
------------------------------------------------------------------------
local function EncodeReq(r)
  return table.concat({ "1", Safe(r.id), Safe(r.by), Enc.ToB36(r.item or 0), tostring(r.qty or 1), Safe(r.note),
                        r.status, Enc.ToB36(r.ts or 0), Safe(r.actor), Enc.ToB36(r.created or 0) }, "^")
end

local function DecodeReq(text)
  local f = Enc.Split(text, "^")
  if f[1] ~= "1" or not f[2] or f[2] == "" or not B.STATUS[f[7] or ""] then return nil end
  local note = (f[6] or ""):gsub("|", "") -- (shown in chat and the UI: no formatting codes)
  return { id = f[2], by = f[3], item = Enc.FromB36(f[4]), qty = Num(f[5], 1, 999, 1), -- as B.Request allows
           note = note ~= "" and note or nil, status = f[7], ts = Enc.FromB36(f[8]), actor = f[9],
           created = Enc.FromB36(f[10]) }
end

B.DecodeReq = DecodeReq -- for the officer change log

-- what was asked, by whom and when: fixed once posted (officers and the
-- requester only move the status along). Compared as sent, since EncodeReq
-- blanks some characters.
local function SameAsk(old, new)
  return Safe(old.by) == Safe(new.by) and (old.item or 0) == (new.item or 0) and (old.qty or 1) == (new.qty or 1)
    and (old.created or 0) == (new.created or 0) and Safe(old.note) == Safe(new.note)
end

local function Allowed(old, new, relayed)
  local actor = new.actor
  if not actor or actor == "" then return false end
  if not old then
    if new.status == "open" then return actor == new.by and P.IsOfficer(actor, "bankask") end
    -- we missed the earlier steps (caught up from a relay): trust the requester or an officer
    return relayed and (actor == new.by or P.IsOfficer(actor, "bankreq")) and P.IsOfficer(new.by, "bankask") or false
  end
  if not SameAsk(old, new) then return false end
  if P.IsOfficer(actor, "bankreq") then return true end
  -- the requester: cancel what's open, or reopen what they cancelled (not
  -- what an officer declined or gave)
  if actor ~= old.by then return false end
  return (new.status == "cancelled" and old.status == "open") or (new.status == "open" and old.status == "cancelled")
end

-- done with: handled a week ago, or still open a month after it was asked
-- (nobody is going to hand it over now, and it shouldn't sync forever)
local function Finished(r)
  if r.status == "open" then return ns.Now() - (r.created or r.ts or 0) > B.EXPIRE_OPEN end
  return ns.Now() - (r.ts or 0) > B.KEEP_DONE
end

local function ApplyReq(r, silent)
  local b = G()
  if not b or Finished(r) then return false end
  local old = b.requests[r.id]
  if old and (old.ts or 0) >= (r.ts or 0) then return false end
  if not Allowed(old, r, true) then return false end
  b.requests[r.id] = r
  if not silent then
    if not old and r.by ~= ns.MyKey() and P.CanEdit("bankreq") and ns.Option("alertBankRequest") then
      local info = ns.Loot and ns.Loot.ItemInfo(r.item)
      ns.Print(("%s asks the guild bank for %s x%d. Type /fhub to hand it over."):format(ns.ShortName(r.by),
        (info and info.link) or ("item " .. r.item), r.qty))
    elseif old and r.by == ns.MyKey() and old.status ~= r.status and ns.Option("alertMyRequest") then
      local info = ns.Loot and ns.Loot.ItemInfo(r.item)
      ns.Print(("Your guild bank request for %s: %s."):format((info and info.link) or ("item " .. r.item),
        B.STATUS[r.status]:lower()))
    end
  end
  ns.Fire("BANK_CHANGED")
  return true
end

local function CommitReq(r)
  r.ts = math.max(ns.Now(), (r.ts or 0) + 1)
  r.actor = ns.MyKey()
  local b = G()
  if not b or not Allowed(b.requests[r.id], r) then return nil end
  b.requests[r.id] = r
  ns.Send("q", EncodeReq(r))
  ns.Fire("BANK_CHANGED")
  return r
end

local counter = 0
function B.Request(itemID, qty, note)
  if not itemID or not IsInGuild() or not P.CanEdit("bankask") then return nil end
  counter = counter + 1
  return CommitReq({ id = "b" .. Enc.ToB36(ns.Now()) .. Enc.ToB36(math.random(0, 1295)) .. counter, by = ns.MyKey(),
                     item = itemID, qty = math.max(1, math.min(999, tonumber(qty) or 1)),
                     note = note and note ~= "" and note:sub(1, 80) or nil, status = "open", created = ns.Now() })
end

function B.SetStatus(r, status)
  local c = {}
  for k, v in pairs(r) do c[k] = v end
  c.status = status
  return CommitReq(c)
end

function B.Requests()
  local b = G()
  local out = {}
  for _, r in pairs(b and b.requests or {}) do
    if not Finished(r) and r.status ~= "cancelled" then out[#out + 1] = r end
  end
  table.sort(out, function(a, c)
    if (a.status == "open") ~= (c.status == "open") then return a.status == "open" end
    return (a.created or 0) > (c.created or 0)
  end)
  return out
end

function B.OpenCount()
  local n = 0
  for _, r in ipairs(B.Requests()) do if r.status == "open" then n = n + 1 end end
  return n
end

local MAX_OPEN = 10  -- open bank requests per member, so nobody can flood the officers
local MAX_TOTAL = 30 -- and requests of any kind (handled ones are kept a week)
local function HandleReq(sender, payload, replayed)
  local r = DecodeReq(payload)
  if not r or not ns.TimeOK(r.ts) or not ns.TimeOK(r.created) then return end
  -- requesters must be guild members, so made-up names can't get round MAX_OPEN
  if next(ns.roster) and not ns.roster[r.by] then return end
  local b = G()
  local old = b and b.requests[r.id]
  -- (a cancelled request opened again counts as a new open one)
  if not old or (r.status == "open" and old.status ~= "open") then
    local open, total = 0, 0
    for _, x in pairs(b and b.requests or {}) do
      if x.by == r.by then
        total = total + 1
        if x.status == "open" then open = open + 1 end
      end
    end
    if open >= MAX_OPEN or (not old and total >= MAX_TOTAL) then return end
  end
  -- the actor must be the sender (or the sender an officer); copies passed on
  -- by other members during catch-up only fill in requests we don't have yet
  if not ns.FirstHand(sender, r.actor, "bankreq") then
    if old then return end
    -- a request we never saw, open or handled: only from the member answering
    -- our catch-up (so nobody can ask in someone else's name, or hand things
    -- over in an officer's)
    if not replayed then
      if not ns.RelayGate(sender, "d", function() HandleReq(sender, payload, true) end) then return end
    end
  end
  ApplyReq(r)
end
ns.CommHandlers.q = function(sender, payload) HandleReq(sender, payload, false) end

------------------------------------------------------------------------
-- Catch-up
------------------------------------------------------------------------
-- requests catch-up passes on: not finished, and (once the roster has loaded)
-- from guild members only, since others refuse the rest
local function Shared(r)
  return not Finished(r) and (not next(ns.roster) or ns.roster[r.by] ~= nil)
end

function B.SendDigest()
  local b = G()
  if not b then return end
  local parts = { "m=" .. Enc.ToB36(b.money and b.money.ts or 0), "p=" .. Enc.ToB36(b.perm and b.perm.ts or 0) }
  -- count only requests catch-up passes on, so the counts can match
  local maxTs, n = 0, 0
  for _, r in pairs(b.requests) do
    if Shared(r) then n = n + 1 end
    if (r.ts or 0) > maxTs then maxTs = r.ts end
  end
  parts[#parts + 1] = "q=" .. Enc.ToB36(maxTs) .. "." .. n
  for tab, t in pairs(b.tabs) do parts[#parts + 1] = "t" .. tab .. "=" .. Enc.ToB36(t.ts or 0) end
  for tab, l in pairs(b.logs) do parts[#parts + 1] = "l" .. tab .. "=" .. Enc.ToB36(l.ts or 0) end
  ns.Send("d", "1^" .. table.concat(parts, ","))
end

local function HandleDigest(sender, payload, retried)
  -- the permission map is officer data: an officer passes it on; the rest
  -- comes from the usual relay
  local member, officer = ns.AmRelayFor(sender), ns.AmOfficerRelayFor(sender)
  if not member and not officer then return end
  local b = G()
  if not b then return end
  -- a brand-new member may not be in our roster yet: their rank decides what they may get
  if P.RankIndex(sender) == nil and not retried then
    ns.RequestRoster()
    C_Timer.After(5, function() HandleDigest(sender, payload, true) end)
    return
  end
  local f = Enc.Split(payload, "^")
  local theirs = {}
  for _, item in ipairs(Enc.Split(f[2] or "", ",")) do
    local k, v = item:match("^(.-)=([%w%.]+)$")
    if k then theirs[k] = v end
  end
  local function Ts(k) return Enc.FromB36((theirs[k] or "0"):match("^(%w+)")) end
  if officer and b.perm and b.perm.ts > Ts("p") then ns.SendTo(sender, "p", EncodePerm(b.perm)) end
  if not member then return end
  if b.money and b.money.ts > Ts("m") then SendMoney(sender) end
  local qTs, qN = (theirs.q or ""):match("^(%w+)%.(%d+)$")
  qTs, qN = Enc.FromB36(qTs), tonumber(qN) or 0
  local n = 0
  for _, r in pairs(b.requests) do if Shared(r) then n = n + 1 end end
  for _, r in pairs(b.requests) do
    if (qN < n or (r.ts or 0) > qTs) and Shared(r) then ns.SendTo(sender, "q", EncodeReq(r)) end
  end
  for tab, t in pairs(b.tabs) do
    if (t.ts or 0) > Ts("t" .. tab) then Distribute(tab, "t", EncodeTab(tab, t), sender) end
  end
  for tab, l in pairs(b.logs) do
    if (l.ts or 0) > Ts("l" .. tab) then Distribute(tab, "l", EncodeLog(tab, l), sender) end
  end
end
ns.CommHandlers.d = function(sender, payload) HandleDigest(sender, payload, false) end

ns.RegisterDigest(function() B.SendDigest() end)

-- tidy finished (and long-unanswered) requests, and those of members who
-- have left the guild: only with a loaded roster, and not if it would drop
-- most of them (a roster that's still filling in must not wipe them; as
-- Alts.PruneLeft)
ns.On("LOGIN", function()
  C_Timer.After(50, function()
    local b = G()
    if not b then return end
    local roster = next(ns.roster) and IsInGuild() and ns.roster
    local left, total = {}, 0
    for id, r in pairs(b.requests) do
      if Finished(r) then
        b.requests[id] = nil
      else
        total = total + 1
        if roster and not roster[r.by] then left[#left + 1] = id end
      end
    end
    if #left > 0 and #left * 2 <= total then
      for _, id in ipairs(left) do b.requests[id] = nil end
    end
  end)
end)
