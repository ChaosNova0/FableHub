-- Requests: guild crafting requests (Open > Claimed > Done).
--
-- g.requests[id] = { id, by, recipe, item, prof, qty, mats = "all"|"some"|"none", note,
--                    status = "open"|"claimed"|"done"|"cancelled", claimer, created, ts }
-- Rules: the requester posts, edits and cancels; another member claims; the claimer
-- (or requester) marks it done; the claimer or requester can un-claim; officers can
-- cancel anything. Requests expire 7 days after posting.

local _, ns = ...
local Enc, P = ns.Encode, ns.Plans
local R = {}
ns.Requests = R

R.EXPIRE = 7 * 86400
R.KEEP_FINISHED = 30 * 60 -- done/cancelled requests are cleared after 30 minutes

local function Stale(r)
  if r.status == "done" or r.status == "cancelled" then return ns.Now() - (r.ts or 0) > R.KEEP_FINISHED end
  return ns.Now() - (r.created or 0) > R.EXPIRE + R.KEEP_FINISHED -- expired a while ago
end
R.Stale = Stale
R.MATS = { all = "Has all mats", some = "Has some mats", none = "No mats" }
R.STATUS = { open = "Open", claimed = "Claimed", done = "Done", cancelled = "Cancelled" }

local function G()
  local g = ns.GuildDB()
  if not g then return nil end
  g.requests = g.requests or {}
  return g
end

function R.All() local g = G(); return g and g.requests or {} end
function R.Get(id) return R.All()[id] end

function R.Expired(r) return (r.status == "open" or r.status == "claimed") and ns.Now() - (r.created or 0) > R.EXPIRE end
function R.Active(r) return (r.status == "open" or r.status == "claimed") and not R.Expired(r) end

------------------------------------------------------------------------
-- Who can craft a recipe
------------------------------------------------------------------------
function R.Crafters(recipe, prof)
  local out = {}
  if not recipe then return out end
  for _, m in ipairs(ns.AllMembers()) do
    local rec = m.rec
    if rec and rec.profs then
      local p = prof and rec.profs[prof]
      local knows = p and p.recipes and p.recipes[recipe]
      if not knows and not prof then
        for _, pp in pairs(rec.profs) do if pp.recipes and pp.recipes[recipe] then knows = true break end end
      end
      if knows then out[#out + 1] = { key = m.key, online = ns.IsOnline(m.key) } end
    end
  end
  table.sort(out, function(a, b) if a.online ~= b.online then return a.online end return a.key < b.key end)
  return out
end

function R.ICanCraft(r)
  local rec = ns.MyRecord()
  local p = rec and rec.profs and r.prof and rec.profs[r.prof]
  return p and p.recipes and p.recipes[r.recipe] and true or false
end

-- every recipe known in the guild, for searching: { recipe, prof, item, name, crafters }
function R.GuildRecipes()
  local out, seen = {}, {}
  for skillLine, agg in pairs(ns.Crafting()) do
    for id, crafters in pairs(agg.recipes) do
      if not seen[id] then
        seen[id] = true
        local item = agg.outputs[id]
        out[#out + 1] = { recipe = id, prof = skillLine, profName = agg.name, item = item, crafters = crafters }
      end
    end
  end
  return out
end

function R.Search(text, limit)
  text = (text or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return {} end
  local linkItem = text:find("item:", 1, true) and ns.Loot.ItemIdFromLink(text)
  local res = {}
  for _, r in ipairs(R.GuildRecipes()) do
    local rname = (ns.RecipeName(r.recipe) or ""):lower()
    local info = r.item and ns.Loot.ItemInfo(r.item)
    local iname = info and info.name:lower() or ""
    local hit = (linkItem and r.item == linkItem) or (not linkItem and (rname:find(text, 1, true) or iname:find(text, 1, true)))
    if hit then
      local pos = math.min(rname:find(text, 1, true) or 99, iname:find(text, 1, true) or 99)
      r.score = (pos == 1 and 0 or 1)
      r.sortName = iname ~= "" and iname or rname
      res[#res + 1] = r
    end
  end
  table.sort(res, function(a, b) if a.score ~= b.score then return a.score < b.score end return a.sortName < b.sortName end)
  while #res > (limit or 8) do table.remove(res) end
  return res
end

function R.DisplayName(r, iconSize)
  if r.item then return ns.Loot.ItemText(r.item, iconSize or 14) end
  return ns.RecipeName(r.recipe) or ("Recipe #" .. tostring(r.recipe))
end

------------------------------------------------------------------------
-- Changes (each carries the actor so others can check it was allowed)
------------------------------------------------------------------------
local function Safe(s) return (tostring(s or ""):gsub("[%^|]", " ")) end

local function Encode(r, actor)
  return table.concat({ "1", Safe(r.id), Safe(r.by), Enc.ToB36(r.recipe or 0), Enc.ToB36(r.item or 0), Enc.ToB36(r.prof or 0),
    tostring(r.qty or 1), r.mats or "none", Safe(r.note), r.status, Safe(r.claimer), Enc.ToB36(r.created or 0),
    Enc.ToB36(r.ts or 0), Safe(actor) }, "^")
end

local function Decode(text)
  local f = Enc.Split(text, "^")
  if f[1] ~= "1" or not f[2] or f[2] == "" or not R.STATUS[f[10] or ""] then return nil end
  local recipe, item, prof = Enc.FromB36(f[4]), Enc.FromB36(f[5]), Enc.FromB36(f[6])
  -- (names are shown in chat: no formatting codes)
  local by, claimer, actor = (f[3] or ""):gsub("|", ""), (f[11] or ""):gsub("|", ""), (f[14] or ""):gsub("|", "")
  -- a claimer must be a guild member (once the roster has loaded)
  if claimer ~= "" and next(ns.roster) and not ns.roster[claimer] and claimer ~= ns.MyKey() then return nil end
  return {
    id = f[2], by = by, recipe = recipe > 0 and recipe or nil, item = item > 0 and item or nil, prof = prof > 0 and prof or nil,
    qty = math.max(1, math.min(99, tonumber(f[7]) or 1)), mats = R.MATS[f[8]] and f[8] or "none",
    note = f[9] ~= "" and f[9]:sub(1, 80) or nil,
    status = f[10], claimer = claimer ~= "" and claimer or nil, created = Enc.FromB36(f[12]), ts = Enc.FromB36(f[13]),
  }, f[14] and actor or nil
end

-- who asked, for what, and when: fixed once posted, for everyone. Compared as
-- sent, since Encode blanks ^ and |.
local function SameRequest(old, new)
  return Safe(old.by) == Safe(new.by) and (old.recipe or 0) == (new.recipe or 0) and (old.prof or 0) == (new.prof or 0)
    and (old.item or 0) == (new.item or 0) and (old.created or 0) == (new.created or 0)
end

-- the rest of the ask (amount, mats, note): only the requester may change it
-- (claimers and officers just move it along)
local function SameAsk(old, new)
  return SameRequest(old, new) and (old.qty or 1) == (new.qty or 1) and (old.mats or "none") == (new.mats or "none")
    and Safe(old.note):sub(1, 80) == Safe(new.note):sub(1, 80)
end

local function Allowed(old, new, actor)
  if not actor or actor == "" then return false end
  if not old then return actor == new.by and new.status == "open" end -- only the requester posts
  if not SameRequest(old, new) then return false end
  -- requester: edit amount/mats/note, cancel, mark done, un-claim (but not
  -- claim it in someone else's name)
  if actor == old.by then return new.claimer == nil or new.claimer == old.claimer end
  if not SameAsk(old, new) then return false end
  if P.IsOfficer(actor, "crafts") then return true end
  if actor == new.claimer and old.status == "open" and (new.status == "claimed" or new.status == "done") then return true end
  -- the claimer: keep it (claimed / done) or un-claim it, never hand it on
  if old.claimer == actor then
    if new.claimer == actor then return new.status == "claimed" or new.status == "done" end
    return new.claimer == nil and new.status == "open"
  end
  return false
end

local function Apply(r, actor, silent)
  if Stale(r) then return false end -- already cleared by everyone else
  local all = R.All()
  local old = all[r.id]
  if old and (old.ts or 0) >= (r.ts or 0) then return false end
  if not Allowed(old, r, actor) then ns.Debug("request change refused from " .. tostring(actor)); return false end
  all[r.id] = r
  if not silent then R.Notify(old, r) end
  if r.status == "done" and (not old or old.status ~= "done") then ns.Fire("REQUEST_DONE", r) end
  ns.Fire("REQUESTS_CHANGED")
  return true
end

local function Commit(r)
  r.ts = math.max(ns.Now(), (r.ts or 0) + 1)
  local actor = ns.MyKey()
  local old = R.All()[r.id]
  if not Allowed(old, r, actor) then return nil end
  R.All()[r.id] = r
  if r.status == "done" and (not old or old.status ~= "done") then ns.Fire("REQUEST_DONE", r) end
  ns.Send("N", Encode(r, actor))
  ns.Fire("REQUESTS_CHANGED")
  return r
end

local counter = 0
function R.Post(recipe, prof, item, qty, mats, note)
  if not recipe then return nil end
  counter = counter + 1
  local r = {
    id = "r" .. Enc.ToB36(ns.Now()) .. Enc.ToB36(math.random(0, 1295)) .. counter, by = ns.MyKey(),
    recipe = recipe, prof = prof, item = item, qty = math.max(1, math.min(99, tonumber(qty) or 1)),
    mats = R.MATS[mats] and mats or "none", note = note and note ~= "" and note:sub(1, 80) or nil,
    status = "open", created = ns.Now(),
  }
  return Commit(r)
end

local function Copy(r)
  local c = {}
  for k, v in pairs(r) do c[k] = v end
  return c
end

function R.Claim(r)
  if r.by == ns.MyKey() or not R.Active(r) or r.status ~= "open" then return nil end
  local c = Copy(r); c.status, c.claimer = "claimed", ns.MyKey()
  return Commit(c)
end
function R.Unclaim(r)
  local c = Copy(r); c.status, c.claimer = "open", nil
  return Commit(c)
end
function R.Done(r)
  local c = Copy(r); c.status = "done"
  return Commit(c)
end
function R.Cancel(r)
  local c = Copy(r); c.status = "cancelled"
  return Commit(c)
end

ns.CommHandlers.N = function(sender, payload)
  local r, actor = Decode(payload)
  if r then Apply(r, actor) end
end

------------------------------------------------------------------------
-- Catch-up sync
------------------------------------------------------------------------
-- requests catch-up passes on: not stale, and (once the roster has loaded)
-- from guild members only, since others refuse the rest and the counts
-- would never match
local function Shared(r)
  return not Stale(r) and (not next(ns.roster) or ns.roster[r.by] ~= nil)
end

local function Live()
  local n, maxTs = 0, 0
  for _, r in pairs(R.All()) do
    if Shared(r) then n = n + 1 end
    if (r.ts or 0) > maxTs then maxTs = r.ts end
  end
  return n, maxTs
end

function R.SendDigest()
  local n, maxTs = Live()
  ns.Send("U", "1^" .. Enc.ToB36(maxTs) .. "^" .. n)
end

ns.CommHandlers.U = function(sender, payload)
  if not ns.AmRelayFor(sender) then return end
  local f = Enc.Split(payload, "^")
  local theirs = Enc.FromB36(f[2])
  local theirN = tonumber(f[3])
  local all = theirN and theirN < Live() -- they're missing some older ones
  for _, r in pairs(R.All()) do
    if (all or (r.ts or 0) > theirs) and Shared(r) then
      -- relay with the last actor we can vouch for: the requester or claimer
      local actor = (r.status == "claimed" or r.status == "done") and r.claimer or r.by
      ns.Send("N", Encode(r, actor))
    end
  end
end

-- relayed copies: accept without re-checking order of past changes
local MAX_OPEN = 10 -- open or claimed requests per member, so nobody can flood the guild
local function OpenBy(key)
  local n = 0
  -- (claimed ones count too: otherwise a member and a friend claiming could pile up any number)
  for _, x in pairs(R.All()) do if x.by == key and R.Active(x) then n = n + 1 end end
  return n
end
local baseHandler = ns.CommHandlers.N
local function HandleRequest(sender, payload, replayed)
  local r, actor = Decode(payload)
  if not r or not ns.TimeOK(r.ts) or not ns.TimeOK(r.created) then return end
  -- requesters must be guild members, so made-up names can't get round MAX_OPEN
  if next(ns.roster) and not ns.roster[r.by] then return end
  local all = R.All()
  local old = all[r.id]
  if Stale(r) then return end
  -- (a finished request made active again counts as a new one)
  if (not old or (not R.Active(old) and R.Active(r))) and OpenBy(r.by) >= MAX_OPEN then return end
  -- the actor must be the sender (or the sender an officer); copies passed on by
  -- other members during catch-up only fill in requests we don't have yet
  local firstHand = ns.FirstHand(sender, actor)
  -- a request we never saw that's already past open: first-hand only from the
  -- requester or a crafts officer. A claimer could otherwise make up a request
  -- in someone else's name and un-claim it into an open one, so theirs only
  -- comes the catch-up way.
  if firstHand and not old and r.status ~= "open" and actor ~= r.by and not P.IsOfficer(actor, "crafts") then
    firstHand = false
  end
  if not firstHand then
    if old then return end
    -- a request we never saw, open or not: only from the member answering our
    -- catch-up (so nobody can post or claim on someone else's behalf)
    if not replayed then
      if not ns.RelayGate(sender, "U", function() HandleRequest(sender, payload, true) end) then return end
    end
    if r.status == "open" then
      if actor == r.by then all[r.id] = r; ns.Fire("REQUESTS_CHANGED") end
      return
    end
  end
  if not old and r.status ~= "open" then
    -- we missed the earlier steps; trust it if the actor is part of the request or an officer
    -- (not the claimer: a relay could make up a claimed request in someone
    -- else's name)
    if actor == r.by or P.IsOfficer(actor, "crafts") then
      all[r.id] = r
      ns.Fire("REQUESTS_CHANGED")
    end
    return
  end
  baseHandler(sender, payload)
end
ns.CommHandlers.N = function(sender, payload) HandleRequest(sender, payload, false) end

------------------------------------------------------------------------
-- Alerts
------------------------------------------------------------------------
function R.ForMe()
  local n = 0
  for _, r in pairs(R.All()) do
    if R.Active(r) and r.status == "open" and r.by ~= ns.MyKey() and R.ICanCraft(r) then n = n + 1 end
  end
  return n
end

-- a name shown in chat, with any formatting codes ("|") taken out
local function ChatName(key) return ns.ShortName((tostring(key or "?"):gsub("|", ""))) end

function R.Notify(old, new)
  if new.by == ns.MyKey() then
    -- tell the requester when their request moves on
    if old and old.status ~= new.status and ns.Option("alertMyRequest") then
      if new.status == "claimed" then
        ns.Print(("%s will craft your %s."):format(ChatName(new.claimer), R.DisplayName(new)))
      elseif new.status == "done" and new.claimer then
        ns.Print(("%s marked your %s as done."):format(ChatName(new.claimer), R.DisplayName(new)))
      end
    end
    return
  end
  if not old and new.status == "open" and ns.Option("alertNewRequest") and R.ICanCraft(new) then
    ns.Print(("%s needs %s x%d (%s). You can craft it: /fhub to claim."):format(
      ChatName(new.by), R.DisplayName(new), new.qty or 1, (R.MATS[new.mats] or ""):lower()))
  end
end

function R.Prune()
  local all, removed = R.All(), false
  for id, r in pairs(all) do
    if Stale(r) then all[id] = nil; removed = true end
  end
  if removed then ns.Fire("REQUESTS_CHANGED") end
end
local Prune = R.Prune

ns.On("LOGIN", function()
  C_Timer.NewTicker(300, function() if IsInGuild() then Prune() end end)
  C_Timer.After(45, function()
    if not IsInGuild() then return end
    Prune()
    local n = R.ForMe()
    if n > 0 and ns.Option("alertRequestLogin") then ns.Print(("%d open crafting request%s you can make. Type /fhub to see them."):format(n, n == 1 and "" or "s")) end
    ns.Fire("REQUESTS_CHANGED")
  end)
end)

ns.RegisterDigest(function() R.SendDigest() end)
