-- Change log (officers): the last few officer actions, such as permission
-- changes, raid nights, loot priorities, announcements and alt fixes.
--
-- No messages of its own: every officer change already reaches each client as
-- a normal sync message saying who made it, so an officer's FableHub writes a
-- line when it accepts one (or sends one of its own). Changes made while you
-- were offline arrive with catch-up and are logged under their real author
-- and time.
--
-- g.changelog = { { ts, by, text, key, item, n, ids = { [id] = true } }, ... } newest first

local _, ns = ...
local Enc, P = ns.Encode, ns.Plans
local CL = {}
ns.ChangeLog = CL

CL.MAX = 20     -- entries kept
CL.MERGE = 300  -- the same officer repeating the same kind of change within 5 minutes is one line

local function List()
  local g = ns.GuildDB()
  if not g then return nil end
  g.changelog = g.changelog or {}
  return g.changelog
end

function CL.Entries()
  return List() or {}
end

------------------------------------------------------------------------
-- What each kind of message means. Each returns nil for messages that
-- aren't an officer action worth logging (automatic loot records, etc).
--   { id = unique per change, key = kind (for merging), ts, by, text, item }
------------------------------------------------------------------------
local function Quote(s)
  s = tostring(s or "")
  if #s > 40 then s = s:sub(1, 37) .. "..." end
  return "\"" .. s .. "\""
end

local function NightName(occId)
  local E = ns.Events
  local id = E and E.ParseOcc(occId)
  local ev = id and E.Get(id)
  local occ = E and E.Occ(occId)
  local title = ev and ev.title or "a raid night"
  if occ then return ("%s (%s)"):format(title, date("%d %b", occ.start)) end
  return title
end

local D = {}

-- the feature a change's author (`by`) must have for a received change to be
-- logged (nil = officer / Guild Master); see Observe
local FEATURE = { P = "plans", V = "raids", O = "raids", B = "loot", M = "loot", L = "loot", Z = "announce",
                  X = "alts", q = "bankreq" }

-- feature permissions (Guild Master)
D.c = function(payload)
  local d = P.DecodePerms(payload)
  if not d then return nil end
  return { id = "c" .. d.ts, key = "perms", ts = d.ts, by = d.by, text = "changed feature permissions" }
end

-- officer ranks (Guild Master)
D.C = function(payload)
  local f = Enc.Split(payload, "^")
  if f[1] ~= "1" then return nil end
  local rank, ts = tonumber(f[3]), Enc.FromB36(f[4])
  local names = P.RankNames()
  local rankName = rank and names[rank] or ("Rank " .. ((rank or 0) + 1))
  return { id = "C" .. ts, key = "cfg", ts = ts, by = f[2], text = "set officer ranks: up to " .. rankName }
end

-- shared raid plans
D.P = function(payload)
  local plan = P.Decode(payload)
  if not plan then return nil end
  return { id = "P" .. plan.id .. "@" .. plan.ts, key = "plan:" .. plan.id, ts = plan.ts, by = plan.author,
           text = (plan.deleted and "deleted raid plan " or "shared raid plan ") .. Quote(plan.name) }
end

-- raid nights
D.V = function(payload)
  local ev = ns.Events and ns.Events.DecodeEvent(payload)
  if not ev then return nil end
  return { id = "V" .. ev.id .. "@" .. ev.ts, key = "night:" .. ev.id, ts = ev.ts, by = ev.author,
           text = (ev.deleted and "deleted raid night " or "saved raid night ") .. Quote(ev.title) }
end

-- attendance marked by hand (the minutes recorded during a raid aren't logged)
D.O = function(payload)
  local f = Enc.Split(payload, "^")
  if f[1] ~= "1" then return nil end
  local ts = Enc.FromB36(f[5])
  return { id = "O" .. f[2] .. f[3] .. "@" .. ts, key = "att:" .. f[2], ts = ts, by = f[6],
           text = "changed attendance for " .. NightName(f[2]) }
end

-- That's My BIS import
D.B = function(payload)
  local tmb = ns.Loot and ns.Loot.DecodeTMB(payload)
  if not tmb then return nil end
  local n = 0
  for _ in pairs(tmb.items or {}) do n = n + 1 end
  return { id = "B" .. tmb.ts, key = "tmb", ts = tmb.ts, by = tmb.by,
           text = ("imported That's My BIS (%d items)"):format(n) }
end

-- loot priority and wishlist edits made in FableHub
D.M = function(payload)
  local f = Enc.Split(payload, "^")
  if f[1] ~= "1" then return nil end
  local ts = Enc.FromB36(f[6])
  return { id = "M" .. f[2] .. f[3] .. f[4] .. "@" .. ts, key = "prio", ts = ts, by = f[7],
           text = "edited loot priorities", item = Enc.FromB36(f[2]) }
end

-- loot history: only removals (new drops are recorded automatically)
D.L = function(payload)
  local e = ns.Loot and ns.Loot.DecodeEntry(payload)
  if not e or not e.deleted then return nil end
  return { id = "L" .. e.id .. "@" .. e.ts, key = "lootdel", ts = e.ts, by = e.by,
           text = "removed {item} (" .. ns.ShortName(e.to) .. ") from loot history", item = e.item }
end

-- announcements
D.Z = function(payload)
  local a = ns.Announce and ns.Announce.Decode(payload)
  if not a then return nil end
  local editor = Enc.Split(payload, "^")[9]
  local verb = a.deleted and "deleted" or (math.abs((a.ts or 0) - (a.created or 0)) <= 5 and "posted" or "edited")
  return { id = "Z" .. a.id .. "@" .. a.ts, key = "ann:" .. a.id, ts = a.ts, by = editor,
           text = verb .. " an announcement: " .. Quote(a.text) }
end

-- alt links set by an officer
D.X = function(payload)
  local char, e = ns.Alts.Decode(payload)
  if not char or not e.manual then return nil end
  -- a character set as its own main is an unlink, or the set-up A.Link sends
  -- for the main before linking alts to it: weak, so merging with a link
  -- keeps the "linked" text (see CL.Add)
  local weak = e.main == char
  local text = weak and ("unlinked " .. ns.ShortName(char))
    or ("linked " .. ns.ShortName(char) .. " to " .. ns.ShortName(e.main))
  return { id = "X" .. char .. "@" .. e.ts, key = "alts", ts = e.ts, by = e.by, text = text, weak = weak or nil }
end

-- guild bank requests handed over or declined by an officer
D.q = function(payload)
  local r = ns.GuildBank and ns.GuildBank.DecodeReq(payload)
  if not r or r.actor == r.by or (r.status ~= "given" and r.status ~= "declined") then return nil end
  local text = r.status == "given"
    and ("handed over {item} x" .. (r.qty or 1) .. " to " .. ns.ShortName(r.by))
    or ("declined " .. ns.ShortName(r.by) .. "'s request for {item}")
  return { id = "q" .. r.id .. "@" .. r.ts, key = "bank:" .. r.id, ts = r.ts, by = r.actor, text = text, item = r.item }
end

------------------------------------------------------------------------
-- Recording
------------------------------------------------------------------------
function CL.Add(e)
  if not e or not e.by or e.by == "" or not e.ts or not P.CanEdit() then return end
  local list = List()
  if not list then return end
  for _, x in ipairs(list) do
    if x.ids and x.ids[e.id] then return end -- already logged
  end
  -- the same officer doing the same kind of thing again shortly after: one line
  for _, x in ipairs(list) do
    if x.key == e.key and x.by == e.by and math.abs((x.ts or 0) - e.ts) <= CL.MERGE then
      x.ids[e.id] = true
      x.n = (x.n or 1) + 1
      -- the newest change's text, except that a weak one ("unlinked" set-up)
      -- never replaces a real one, and a real one always replaces a weak one
      local newer = e.ts >= (x.ts or 0)
      if (newer and not (e.weak and not x.weak)) or (x.weak and not e.weak) then
        x.text, x.item, x.weak = e.text, e.item, e.weak
      end
      if newer then x.ts = e.ts end
      table.sort(list, function(a, b) return (a.ts or 0) > (b.ts or 0) end)
      ns.Fire("CHANGELOG_CHANGED")
      return
    end
  end
  table.insert(list, { ts = e.ts, by = e.by, text = e.text, key = e.key, item = e.item, weak = e.weak, n = 1,
                       ids = { [e.id] = true } })
  table.sort(list, function(a, b) return (a.ts or 0) > (b.ts or 0) end)
  while #list > CL.MAX do table.remove(list) end
  ns.Fire("CHANGELOG_CHANGED")
end

local function Observe(msgType, payload, mine)
  local describe = D[msgType]
  if not describe then return end
  local ok, e = pcall(describe, payload)
  if not ok or not e then return end
  -- our own messages: only changes we just made (not old data we pass on in catch-up)
  if mine and (e.by ~= ns.MyKey() or e.ts < ns.Now() - 120) then return end
  -- others': only straight from the officer who made the change, or passed on
  -- by an officer. Features accept some second-hand copies from members to
  -- fill gaps; those mustn't put lines in an officer's name into the log.
  if not mine and not ns.OfficerSent(ns.receivingSender, e.by, FEATURE[msgType]) then return end
  CL.Add(e)
end

-- others' changes: Comm.lua notes which message is being handled (ns.receiving,
-- and who it came from: ns.receivingSender), and each feature fires its
-- "changed" event only when it accepts the change
for _, event in ipairs({ "PLANS_CHANGED", "EVENTS_CHANGED", "LOOT_CHANGED", "ANNOUNCE_CHANGED", "ALTS_CHANGED", "BANK_CHANGED" }) do
  ns.On(event, function()
    if ns.receiving and ns.receivingSender then Observe(ns.receiving, ns.receivingPayload, false) end
  end)
end

-- our own changes, as they're sent
local send = ns.Send
function ns.Send(msgType, payload)
  send(msgType, payload)
  if D[msgType] then
    local ok, err = pcall(Observe, msgType, payload, true)
    if not ok then ns.ReportError(err) end
  end
end

------------------------------------------------------------------------
-- Window (Settings > Officers > Change log)
------------------------------------------------------------------------
local frame

local function ItemText(id)
  local info = id and ns.Loot and ns.Loot.ItemInfo(id)
  return (info and info.link) or (id and ("item " .. id)) or "an item"
end

local function Line(e)
  local text = e.text:gsub("{item}", function() return ItemText(e.item) end)
  if (e.n or 1) > 1 then text = text .. (" (%d changes)"):format(e.n) end
  return text
end

local function Fill()
  local T = ns.Theme
  local list = CL.Entries()
  for i, row in ipairs(frame.rows) do
    local e = list[i]
    if e then
      local r, g, b = 0.8, 0.8, 0.8
      local roster = ns.roster[e.by]
      if roster then r, g, b = ns.ClassColor(roster.class) end
      row.when:SetText(date("%d %b %H:%M", e.ts))
      row.who:SetText(ns.ShortName(e.by))
      row.who:SetTextColor(r, g, b, 1)
      row.what:SetText(Line(e))
      row:Show()
    else
      row:Hide()
    end
  end
  frame.empty:SetShown(#list == 0)
  frame.sub:SetText(("The last %d officer changes your FableHub has seen."):format(CL.MAX))
  frame.sub:SetTextColor(1, 1, 1, T.dim)
end

function CL.Show()
  local T = ns.Theme
  if not frame then
    frame = CreateFrame("Frame", "FableHubChangeLogFrame", UIParent)
    frame:SetSize(640, 92 + CL.MAX * 22)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetToplevel(true)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    T.Fill(frame, { T.bg[1], T.bg[2], T.bg[3], 1 })
    T.Border(frame, 0.15)
    if UISpecialFrames then table.insert(UISpecialFrames, "FableHubChangeLogFrame") end

    local title = T.Text(frame, 15, 1)
    title:SetPoint("TOPLEFT", 14, -12)
    title:SetText("Change log")
    frame.sub = T.Text(frame, 11, T.dim)
    frame.sub:SetPoint("TOPLEFT", 14, -34)
    local close = T.CloseButton(frame, function() frame:Hide() end)
    close:SetPoint("TOPRIGHT", -8, -8)

    local line = frame:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 1, 1, 0.07)
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", 14, -54)
    line:SetPoint("TOPRIGHT", -14, -54)

    frame.rows = {}
    for i = 1, CL.MAX do
      local row = CreateFrame("Frame", nil, frame)
      row:SetHeight(22)
      row:SetPoint("TOPLEFT", 14, -60 - (i - 1) * 22)
      row:SetPoint("TOPRIGHT", -14, -60 - (i - 1) * 22)
      row.when = T.Text(row, 11, 0.45)
      row.when:SetPoint("LEFT")
      row.when:SetWidth(100)
      row.when:SetJustifyH("LEFT")
      row.who = T.Text(row, 12, 1)
      row.who:SetPoint("LEFT", 104, 0)
      row.who:SetWidth(130)
      row.who:SetJustifyH("LEFT")
      row.who:SetWordWrap(false)
      row.what = T.Text(row, 12, 0.85)
      row.what:SetPoint("LEFT", 238, 0)
      row.what:SetPoint("RIGHT")
      row.what:SetJustifyH("LEFT")
      row.what:SetWordWrap(false)
      frame.rows[i] = row
    end
    frame.empty = T.Text(frame, 12, 0.45)
    frame.empty:SetPoint("TOPLEFT", 14, -66)
    frame.empty:SetText("Nothing yet. Officer changes appear here as your FableHub sees them.")

    ns.On("CHANGELOG_CHANGED", function() if frame:IsShown() then Fill() end end)
  end
  Fill()
  frame:Show()
end
