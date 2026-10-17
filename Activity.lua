-- Activity: a short "what's been happening" log for the Home page.
-- Each member's FableHub works it out from data it already syncs, so it costs no
-- network traffic. Only changes seen after installing are reported.
--
-- g.activity = { { id, t, kind, key, text, icon }, ... } newest last, capped
-- kinds: level, skill, recipe, join, leave, raid, craft

local _, ns = ...
local A = {}
ns.Activity = A

A.MAX = 150
A.KEEP = 30 * 86400
A.LEVELS = { 10, 20, 30, 40, 50, 60 }
A.SKILLS = { 150, 225, 300 }
A.RECIPE_QUALITY = 3 -- rare or better

local function G()
  local g = ns.GuildDB()
  if not g then return nil end
  g.activity = g.activity or {}
  g.activitySeen = g.activitySeen or {}
  return g
end

function A.List()
  local g = G()
  if not g then return {} end
  local out, cutoff = {}, ns.Now() - A.KEEP
  for i = #g.activity, 1, -1 do
    local e = g.activity[i]
    if (e.t or 0) >= cutoff then out[#out + 1] = e end
  end
  table.sort(out, function(a, b) return (a.t or 0) > (b.t or 0) end)
  return out
end

-- dedupe: the same thing can arrive more than once (relays, rescans)
function A.Add(kind, key, text, dedupe, t, icon)
  local g = G()
  if not g or not text then return end
  dedupe = dedupe or (kind .. ":" .. tostring(key) .. ":" .. text)
  if g.activitySeen[dedupe] then return end
  g.activitySeen[dedupe] = t or ns.Now()
  table.insert(g.activity, { t = t or ns.Now(), kind = kind, key = key, text = text, icon = icon })
  while #g.activity > A.MAX do table.remove(g.activity, 1) end
  ns.Fire("ACTIVITY_CHANGED")
end

------------------------------------------------------------------------
-- Comparing a member's record before and after it changed
------------------------------------------------------------------------
local function Crossed(old, new, marks)
  local hit
  for _, m in ipairs(marks) do
    if (old or 0) < m and (new or 0) >= m then hit = m end
  end
  return hit
end

local function Quality(itemID)
  if not itemID then return nil end
  if C_Item and C_Item.GetItemQualityByID then
    local ok, q = pcall(C_Item.GetItemQualityByID, itemID)
    if ok and q then return q end
  end
  local info = ns.Loot and ns.Loot.ItemInfo(itemID)
  return info and info.quality
end

-- old/new: { level, profs = { [skillLine] = { name, rank, recipes } }, outputs }
function A.Compare(key, old, new, t)
  if not old or not new or not key then return end
  local name = ns.ShortName(key)
  local lvl = Crossed(old.level, new.level, A.LEVELS)
  if lvl then
    A.Add("level", key, ("%s reached level %d"):format(name, lvl), "level:" .. key .. ":" .. lvl, t)
  end
  for skillLine, p in pairs(new.profs or {}) do
    local op = old.profs and old.profs[skillLine]
    if op then
      local sk = Crossed(op.rank, p.rank, A.SKILLS)
      if sk then
        A.Add("skill", key, ("%s reached %d %s"):format(name, sk, p.name or "?"), "skill:" .. key .. ":" .. skillLine .. ":" .. sk, t,
          ns.Icons and ns.Icons.ProfessionTexture(skillLine))
      end
      -- new rare-or-better recipes (skip the very first scan of a profession)
      local oldRecipes = op.recipes or {}
      if next(oldRecipes) ~= nil then
        local learned = {}
        for id in pairs(p.recipes or {}) do
          if not oldRecipes[id] then
            local item = new.outputs and new.outputs[id]
            local q = Quality(item)
            if q and q >= A.RECIPE_QUALITY then learned[#learned + 1] = { id = id, item = item } end
          end
        end
        for i, r in ipairs(learned) do
          if i > 3 then
            A.Add("recipe", key, ("%s learned %d more %s recipes"):format(name, #learned - 3, p.name or ""), nil, t)
            break
          end
          local info = ns.Loot and ns.Loot.ItemInfo(r.item)
          local what = info and info.link or (ns.RecipeName and ns.RecipeName(r.id)) or ("recipe " .. r.id)
          A.Add("recipe", key, ("%s can now craft %s"):format(name, what), "recipe:" .. key .. ":" .. r.id, t, info and info.icon)
        end
      end
    end
  end
end

-- a lightweight copy of a record, for comparing later
function A.Snapshot(rec)
  if not rec then return nil end
  local s = { level = rec.level, profs = {}, outputs = rec.outputs }
  for skillLine, p in pairs(rec.profs or {}) do
    local copy = {}
    for id in pairs(p.recipes or {}) do copy[id] = true end
    s.profs[skillLine] = { name = p.name, rank = p.rank, recipes = copy }
  end
  return s
end

-- our own character changes in place, so keep a snapshot to compare against
local mySnap
function A.CheckOwn()
  local rec = ns.MyRecord()
  if not rec or (rec.ts or 0) == 0 then return end
  if mySnap then A.Compare(rec.key, mySnap, rec) end
  mySnap = A.Snapshot(rec)
end

------------------------------------------------------------------------
-- Guild joins and departures
------------------------------------------------------------------------
local function ToPattern(fmt)
  if not fmt then return nil end
  local p = fmt:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
  p = p:gsub("%%%%s", "(.+)")
  return "^" .. p .. "$"
end

local systemPatterns
ns.RegisterEvent("CHAT_MSG_SYSTEM", function(msg)
  if type(msg) ~= "string" or (issecretvalue and issecretvalue(msg)) or not IsInGuild() then return end
  if not systemPatterns then
    systemPatterns = {
      { p = ToPattern(ERR_GUILD_JOIN_S or "%s has joined the guild."), kind = "join", fmt = "%s joined the guild" },
      { p = ToPattern(ERR_GUILD_LEAVE_S or "%s has left the guild."), kind = "leave", fmt = "%s left the guild" },
      { p = ToPattern(ERR_GUILD_REMOVE_SS or "%s has been kicked out of the guild by %s."), kind = "leave", fmt = "%s was removed from the guild" },
    }
  end
  for _, sp in ipairs(systemPatterns) do
    local who = sp.p and msg:match(sp.p)
    if who then
      local short = ns.ShortName(who)
      A.Add(sp.kind, who, sp.fmt:format(short), sp.kind .. ":" .. short .. ":" .. math.floor(ns.Now() / 3600))
      return
    end
  end
end)

-- members who joined while we were offline: new names in the roster
ns.On("ROSTER_CHANGED", function()
  local g = G()
  if not g or not next(ns.roster) then return end
  local known = g.knownRoster
  if not known then
    g.knownRoster = {}
    for key in pairs(ns.roster) do g.knownRoster[key] = true end
    return
  end
  for key in pairs(ns.roster) do
    if not known[key] then
      known[key] = true
      A.Add("join", key, ("%s joined the guild"):format(ns.ShortName(key)), "join:" .. ns.ShortName(key) .. ":" .. math.floor(ns.Now() / 3600))
    end
  end
end)

------------------------------------------------------------------------
-- Raid nights scheduled, crafting requests crafted
------------------------------------------------------------------------
ns.On("EVENT_SCHEDULED", function(ev)
  local occ
  if ns.Events then
    local occs = ns.Events.Occurrences(ns.Now(), ns.Now() + 28 * 86400)
    for _, o in ipairs(occs) do if o.event.id == ev.id then occ = o break end end
  end
  local when = occ and (" for " .. ns.Events.FormatDay(occ.start) .. " " .. ns.Events.FormatTime(occ.start)) or ""
  A.Add("raid", ev.author, ("%s scheduled %s%s%s"):format(ns.ShortName(ev.author), ev.title or "a raid night", when,
    ev.weekly and " (weekly)" or ""), "raid:" .. ev.id)
end)

ns.On("REQUEST_DONE", function(r)
  if not r.claimer then return end
  local what = ns.Requests and ns.Requests.DisplayName(r) or "an item"
  A.Add("craft", r.claimer, ("%s crafted %s for %s"):format(ns.ShortName(r.claimer), what, ns.ShortName(r.by)), "craft:" .. r.id)
end)

local function Prune()
  local g = G()
  if not g then return end
  local cutoff = ns.Now() - A.KEEP
  local keep = {}
  for _, e in ipairs(g.activity) do if (e.t or 0) >= cutoff then keep[#keep + 1] = e end end
  g.activity = keep
  for k, t in pairs(g.activitySeen) do if t < cutoff then g.activitySeen[k] = nil end end
end

ns.On("LOGIN", function()
  C_Timer.After(12, function() if IsInGuild() then Prune(); A.CheckOwn() end end)
end)
