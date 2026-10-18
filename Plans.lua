-- Plans: saved raid plans, who may edit them, and sharing them with the guild.
--
-- plan = { id, name, size (10/20/40), ts, author, shared, dirty, deleted,
--          slots = { [slotIndex] = key }, roles = { [key] = role }, extras = { [key] = classFile } }
-- slot index = (group - 1) * 5 + position

local _, ns = ...
local Enc = ns.Encode
local P = {}
ns.Plans = P

P.SIZES = { 10, 20, 40 }

------------------------------------------------------------------------
-- Permissions: guild ranks up to officerRank (0 = Guild Master) are officers.
-- The Guild Master sets the threshold and it syncs to everyone.
------------------------------------------------------------------------
function P.OfficerRank()
  local g = ns.GuildDB()
  return (g and g.officerRank) or 1
end

function P.RankIndex(key)
  local r = ns.roster[key]
  return r and r.rankIndex
end

-- test officer mode: only on the developer's Battle.net account, this computer only
function P.TestMode()
  return FableHubDB and FableHubDB.settings and FableHubDB.settings.testOfficer and ns.IsDeveloper() and true or false
end

------------------------------------------------------------------------
-- Feature permissions: the Guild Master ticks which ranks may use each
-- feature (g.perms[feature] = { [rankIndex] = true }). A feature the Guild
-- Master hasn't changed follows the officer ranks setting (member features:
-- every rank). The Guild Master can always use everything. Receivers check
-- the author's rank against the feature, so this isn't just hiding buttons.
------------------------------------------------------------------------
P.FEATURES = {
  { id = "announce", name = "Announcements", desc = "Post, pin and delete announcements on Home." },
  { id = "raids", name = "Raid nights", desc = "Create, edit and cancel raid nights, change anyone's sign-up, correct attendance, import from Raid-Helper. Attendance is recorded by these ranks." },
  { id = "plans", name = "Raid plans", desc = "Create, edit and share raid plans." },
  { id = "loot", name = "Loot", desc = "Import That's My BIS, edit prio lists, the award window, loot history. Loot history is recorded by these ranks." },
  { id = "alts", name = "Alts", desc = "Link, unlink and set the main of anyone's characters." },
  { id = "bankreq", name = "Bank requests", desc = "Hand over or decline guild bank requests, and get a chat alert for new ones." },
  { id = "crafts", name = "Craft requests", desc = "Cancel anyone's craft request." },
  { id = "bankask", name = "Ask the bank", desc = "Ask for guild bank items (Guild Bank > Requests).", member = true },
}
P.FEATURE_BY_ID = {}
for _, f in ipairs(P.FEATURES) do P.FEATURE_BY_ID[f.id] = f end

-- may guild rank `idx` use `feature`?
function P.RankAllowed(feature, idx)
  if idx == 0 then return true end
  local g = ns.GuildDB()
  local set = g and g.perms and g.perms[feature]
  if set then return idx ~= nil and set[idx] == true end
  local f = P.FEATURE_BY_ID[feature]
  if f and f.member then return true end
  return idx ~= nil and idx <= P.OfficerRank()
end

function P.Customised(feature)
  local g = ns.GuildDB()
  return g and g.perms and g.perms[feature] ~= nil or false
end

-- without a feature: an officer (officer ranks setting). With one: allowed to
-- use that feature.
function P.IsOfficer(key, feature)
  -- local test mode: only your own addon treats you as an officer
  if key == ns.MyKey() and P.TestMode() then return true end
  local idx = P.RankIndex(key)
  if feature then
    if idx == nil then -- not in the roster (yet): only open member features
      local f = P.FEATURE_BY_ID[feature]
      return f and f.member and not P.Customised(feature) or false
    end
    return P.RankAllowed(feature, idx)
  end
  return idx ~= nil and idx <= P.OfficerRank()
end

function P.CanEdit(feature)
  return P.IsOfficer(ns.MyKey(), feature)
end

-- Guild Master: tick or untick a rank for a feature
function P.SetPerm(feature, idx, on)
  local g = ns.GuildDB()
  if not g or not P.IsGuildMaster() or not P.FEATURE_BY_ID[feature] or idx == 0 then return false end
  g.perms = g.perms or {}
  if not g.perms[feature] then -- start from what applies now
    local set = {}
    local _, n = P.RankNames()
    for i = 1, math.max(n, 10) - 1 do if P.RankAllowed(feature, i) then set[i] = true end end
    g.perms[feature] = set
  end
  g.perms[feature][idx] = on and true or nil
  g.permsTs, g.permsBy = math.max(ns.Now(), (g.permsTs or 0) + 1), ns.MyKey() -- two changes in one second still count
  P.SendPerms()
  ns.Fire("PLANS_CHANGED")
  return true
end

-- Guild Master: back to following the officer ranks setting
function P.ResetPerm(feature)
  local g = ns.GuildDB()
  if not g or not P.IsGuildMaster() then return false end
  if feature then
    if g.perms then g.perms[feature] = nil end
  else
    g.perms = nil
  end
  g.permsTs, g.permsBy = math.max(ns.Now(), (g.permsTs or 0) + 1), ns.MyKey() -- two changes in one second still count
  P.SendPerms()
  ns.Fire("PLANS_CHANGED")
  return true
end

-- "1^by^ts^feature=1.2.3;feature2=;..." (only features the Guild Master changed;
-- an empty list = only the Guild Master)
function P.EncodePerms(g)
  local parts = {}
  for _, f in ipairs(P.FEATURES) do
    local set = g.perms and g.perms[f.id]
    if set then
      local ranks = {}
      for i in pairs(set) do ranks[#ranks + 1] = i end
      table.sort(ranks)
      parts[#parts + 1] = f.id .. "=" .. table.concat(ranks, ".")
    end
  end
  return table.concat({ "1", g.permsBy or "", Enc.ToB36(g.permsTs or 0), table.concat(parts, ";") }, "^")
end

function P.DecodePerms(text)
  local f = Enc.Split(text, "^")
  if f[1] ~= "1" or not f[2] or f[2] == "" then return nil end
  local perms
  for _, item in ipairs(Enc.Split(f[4] or "", ";")) do
    local id, list = item:match("^(%a+)=([%d%.]*)$")
    if id and P.FEATURE_BY_ID[id] then
      perms = perms or {}
      local set = {}
      for i in list:gmatch("%d+") do
        local n = tonumber(i)
        if n and n >= 1 and n <= 20 then set[n] = true end
      end
      perms[id] = set
    end
  end
  return { by = f[2], ts = Enc.FromB36(f[3]), perms = perms }
end

function P.SendPerms()
  local g = ns.GuildDB()
  if not g or not g.permsTs then return end
  ns.Send("c", P.EncodePerms(g))
end

function P.IsGuildMaster()
  return P.RankIndex(ns.MyKey()) == 0
end

function P.RankNames()
  local out = {}
  local n = (GuildControlGetNumRanks and GuildControlGetNumRanks()) or 0
  for i = 1, n do out[i - 1] = GuildControlGetRankName and GuildControlGetRankName(i) or ("Rank " .. i) end
  return out, n
end

function P.SetOfficerRank(idx)
  local g = ns.GuildDB()
  if not g or not P.IsGuildMaster() then return false end
  g.officerRank = idx
  g.officerRankTs = ns.Now()
  g.officerRankBy = ns.MyKey()
  P.SendConfig()
  ns.Fire("PLANS_CHANGED")
  return true
end

------------------------------------------------------------------------
-- Storage
------------------------------------------------------------------------
function P.All()
  local g = ns.GuildDB()
  if not g then return {} end
  g.plans = g.plans or {}
  return g.plans
end

function P.List()
  local out = {}
  for _, plan in pairs(P.All()) do
    if not plan.deleted then out[#out + 1] = plan end
  end
  table.sort(out, function(a, b) return (a.name or ""):lower() < (b.name or ""):lower() end)
  return out
end

function P.Get(id) return id and P.All()[id] end

local counter = 0
function P.New(name, size)
  if not P.CanEdit("plans") then return nil end
  counter = counter + 1
  local id = Enc.ToB36(ns.Now()) .. Enc.ToB36(math.random(0, 1295)) .. counter
  local plan = {
    id = id, name = name or "New raid", size = size or 20, ts = ns.Now(), author = ns.MyKey(),
    shared = false, dirty = true, slots = {}, roles = {}, extras = {},
  }
  P.All()[id] = plan
  ns.Fire("PLANS_CHANGED")
  return plan
end

function P.Touch(plan)
  plan.dirty = true
  ns.Fire("PLANS_CHANGED")
end

function P.SlotOf(plan, key)
  for i, k in pairs(plan.slots) do if k == key then return i end end
end

-- Put key in slot; if the key is already in another slot, swap them.
function P.Place(plan, key, slot)
  if slot < 1 or slot > plan.size then return end
  local from = P.SlotOf(plan, key)
  local occupant = plan.slots[slot]
  -- moving within the plan swaps; a new person dropped on someone replaces them
  if from then plan.slots[from] = occupant end
  plan.slots[slot] = key
  P.Touch(plan)
end

function P.Remove(plan, slot)
  plan.slots[slot] = nil
  P.Touch(plan)
end

function P.Resize(plan, size)
  plan.size = size
  for i in pairs(plan.slots) do if i > size then plan.slots[i] = nil end end
  P.Touch(plan)
end

function P.Count(plan)
  local n = 0
  for i, k in pairs(plan.slots) do if k and i <= plan.size then n = n + 1 end end
  return n
end

function P.AddExtra(plan, name, classFile)
  local key = ns.NormalizeName((name or ""):gsub("^%s+", ""):gsub("%s+$", ""))
  if not key or key == "" then return nil end
  plan.extras[key] = classFile
  P.Touch(plan)
  return key
end

------------------------------------------------------------------------
-- Raid nights: a plan can be made from a raid night and stays linked to it
-- (plan.night = occId). Accepted and Late sign-ups make up the plan's pool;
-- Tentative ones are listed apart. Nobody is moved automatically: people
-- placed in groups who later decline or withdraw are only flagged.
------------------------------------------------------------------------
P.NIGHT_YES = { A = true, L = true }

-- the linked night's sign-ups: yes = Accepted/Late, maybe = Tentative,
-- status[charKey] = sign-up status (A/L/T/D) for everyone who answered
function P.NightPeople(plan)
  local out = { yes = {}, maybe = {}, status = {}, role = {} }
  local E = ns.Events
  if not plan or not plan.night or not E then return out end
  for signer, su in pairs(E.Signups(plan.night)) do
    local key = su.char or signer
    if su.status and su.status ~= "R" then
      out.status[key] = su.status
      out.role[key] = su.role
      if P.NIGHT_YES[su.status] then out.yes[#out.yes + 1] = key
      elseif su.status == "T" then out.maybe[#out.maybe + 1] = key end
    end
  end
  table.sort(out.yes); table.sort(out.maybe)
  return out
end

-- people placed in the plan who are no longer coming: { {key, status}, ... }
-- status D = declined, T = tentative now, "" = no answer / withdrawn
function P.NightProblems(plan)
  local list = {}
  if not plan or not plan.night then return list end
  local people = P.NightPeople(plan)
  for i = 1, plan.size do
    local key = plan.slots[i]
    if key and not plan.extras[key] then
      local st = people.status[key]
      if not P.NIGHT_YES[st or ""] then list[#list + 1] = { key = key, status = st or "", slot = i } end
    end
  end
  return list
end

function P.NightName(occId)
  local E = ns.Events
  local occ = E and E.Occ(occId)
  if not occ then return nil end
  return ("%s %s"):format(occ.event.title or "Raid", date("%d/%m", occ.start))
end

-- a new plan from a raid night: sized for the Accepted/Late count, with each
-- person's signed-up role (Tentative roles too, for when they're added)
function P.FromNight(occId)
  local E = ns.Events
  local occ = E and E.Occ(occId)
  if not occ or not P.CanEdit("plans") then return nil end
  local plan = P.LinkNight(P.New(P.NightName(occId), 20), occId)
  if not plan then return nil end
  local n = #P.NightPeople(plan).yes
  plan.size = n <= 10 and 10 or n <= 20 and 20 or 40
  return plan
end

-- link (or with occId nil, unlink) an existing plan
function P.LinkNight(plan, occId)
  if not plan or not P.CanEdit("plans") then return nil end
  plan.night = occId
  if occId then
    local people = P.NightPeople(plan)
    for key, role in pairs(people.role) do
      if role and not plan.roles[key] then plan.roles[key] = role end
    end
  end
  P.Touch(plan)
  return plan
end

-- plans linked to a raid night
function P.ForNight(occId)
  local out = {}
  for _, plan in ipairs(P.List()) do if plan.night == occId then out[#out + 1] = plan end end
  return out
end

------------------------------------------------------------------------
-- Who someone is, for planning purposes
------------------------------------------------------------------------
-- class, role, spec, buff set (and whether buffs were detected or assumed)
function P.Describe(plan, key)
  local g = ns.GuildDB()
  local rec = g and g.members[key]
  if key == ns.MyKey() then rec = ns.MyRecord() end
  local r = ns.roster[key]
  local classFile = (rec and rec.class) or (r and r.class) or (plan and plan.extras and plan.extras[key])
  local spec = rec and rec.spec
  local role = plan and plan.roles and plan.roles[key]
  local roleSource = role and "plan" or nil
  if not role and spec and classFile and ns.TREE_ROLES[classFile] then
    role = ns.TREE_ROLES[classFile][spec.tree]
    roleSource = role and "talents" or nil
  end
  if not role and classFile then role, roleSource = ns.DEFAULT_ROLE[classFile], "guess" end
  local buffs, detected = {}, false
  if rec and rec.buffs then
    buffs, detected = rec.buffs, true
  elseif classFile then
    for _, b in ipairs(ns.BUFFS) do
      if b.base and b.classes[classFile] then buffs[b.id] = true end
    end
  end
  return {
    key = key, class = classFile, role = role, roleSource = roleSource, spec = spec,
    buffs = buffs, detected = detected, level = (r and r.level) or (rec and rec.level),
    online = ns.IsOnline(key), extra = plan and plan.extras and plan.extras[key] ~= nil and not r,
  }
end

-- Coverage for a plan: providers per buff (raid-wide), per-group party buffs, role counts
function P.Coverage(plan)
  local cov = { providers = {}, groups = {}, roles = { TANK = 0, HEALER = 0, MELEE = 0, RANGED = 0 }, count = 0,
                paladins = 0 }
  local groupCount = math.ceil(plan.size / 5)
  for gi = 1, groupCount do cov.groups[gi] = { party = {}, members = {} } end
  for slot = 1, plan.size do
    local key = plan.slots[slot]
    if key then
      local d = P.Describe(plan, key)
      local gi = math.ceil(slot / 5)
      cov.count = cov.count + 1
      if d.role then cov.roles[d.role] = (cov.roles[d.role] or 0) + 1 end
      if d.class == "PALADIN" then cov.paladins = cov.paladins + 1 end
      table.insert(cov.groups[gi].members, d)
      for id in pairs(d.buffs) do
        local b = ns.BUFF_BY_ID[id]
        if b then
          cov.providers[id] = cov.providers[id] or {}
          table.insert(cov.providers[id], d)
          if b.cat == "party" then
            cov.groups[gi].party[id] = cov.groups[gi].party[id] or {}
            table.insert(cov.groups[gi].party[id], d)
          end
        end
      end
    end
  end
  return cov
end

------------------------------------------------------------------------
-- Encoding
--   "1^id^ts^author^size^name^deleted^slots^roles^extras^night"
--   (night added in 0.19.1; older clients ignore it)
------------------------------------------------------------------------
local function Safe(s) return (tostring(s or ""):gsub("[%^,=#]", " ")) end

function P.Encode(plan)
  local slots, roles, extras = {}, {}, {}
  for i, k in pairs(plan.slots) do slots[#slots + 1] = i .. "=" .. Safe(k) end
  for k, r in pairs(plan.roles) do roles[#roles + 1] = Safe(k) .. "=" .. (ns.ROLE_SHORT[r] or "") end
  for k, c in pairs(plan.extras) do extras[#extras + 1] = Safe(k) .. "=" .. Safe(c) end
  table.sort(slots); table.sort(roles); table.sort(extras)
  return table.concat({
    "1", Safe(plan.id), Enc.ToB36(plan.ts), Safe(plan.author), tostring(plan.size), Safe(plan.name),
    plan.deleted and "1" or "0", table.concat(slots, ","), table.concat(roles, ","), table.concat(extras, ","),
    Safe(plan.night),
  }, "^")
end

local ROLE_FROM_SHORT = { T = "TANK", H = "HEALER", M = "MELEE", R = "RANGED" }

function P.Decode(text)
  local f = Enc.Split(text, "^")
  if f[1] ~= "1" or not f[2] or f[2] == "" then return nil end
  local size = tonumber(f[5]) or 20
  if size ~= 10 and size ~= 20 and size ~= 40 then size = 20 end
  local plan = {
    id = f[2], ts = Enc.FromB36(f[3]), author = f[4], size = size, name = f[6] or "Raid",
    deleted = f[7] == "1", slots = {}, roles = {}, extras = {}, shared = true, dirty = false,
  }
  for _, item in ipairs(Enc.Split(f[8] or "", ",")) do
    local i, k = item:match("^(%d+)=(.+)$")
    i = tonumber(i)
    if i and i >= 1 and i <= size then plan.slots[i] = k end
  end
  for _, item in ipairs(Enc.Split(f[9] or "", ",")) do
    local k, r = item:match("^(.+)=(%a)$")
    if k and ROLE_FROM_SHORT[r] then plan.roles[k] = ROLE_FROM_SHORT[r] end
  end
  for _, item in ipairs(Enc.Split(f[10] or "", ",")) do
    local k, c = item:match("^(.+)=(%u+)$")
    if k then plan.extras[k] = c end
  end
  if f[11] and f[11]:match("^.+@%d+%.%d+$") then plan.night = f[11] end
  return plan
end

------------------------------------------------------------------------
-- Sharing
------------------------------------------------------------------------
function P.Share(plan)
  if not P.CanEdit("plans") then return false end
  if P.TestMode() and (P.RankIndex(ns.MyKey()) or 99) > P.OfficerRank() then
    ns.Print("Test officer mode: guildmates will ignore this plan, because your real rank isn't an officer rank.")
  end
  plan.ts = ns.Now()
  plan.author = ns.MyKey()
  plan.shared, plan.dirty = true, false
  ns.Send("P", P.Encode(plan))
  ns.Fire("PLANS_CHANGED")
  return true
end

function P.Delete(plan)
  if not P.CanEdit("plans") then return false end
  plan.deleted = true
  plan.ts = ns.Now()
  plan.author = ns.MyKey()
  plan.slots, plan.roles, plan.extras = {}, {}, {}
  if plan.shared then ns.Send("P", P.Encode(plan)) else P.All()[plan.id] = nil end
  ns.Fire("PLANS_CHANGED")
  return true
end

function P.SendConfig()
  local g = ns.GuildDB()
  if not g or not g.officerRankTs then return end
  ns.Send("C", table.concat({ "1", g.officerRankBy or ns.MyKey() or "", tostring(g.officerRank or 1), Enc.ToB36(g.officerRankTs) }, "^"))
end

function ns.SendPlanDigest()
  local g = ns.GuildDB()
  if not g then return end
  local parts = { "!cfg=" .. Enc.ToB36(g.officerRankTs or 0), "!perm=" .. Enc.ToB36(g.permsTs or 0) }
  for id, plan in pairs(P.All()) do
    if plan.shared then parts[#parts + 1] = Safe(id) .. "=" .. Enc.ToB36(plan.ts or 0) end
  end
  ns.Send("Q", table.concat(parts, ","))
end

ns.CommHandlers.P = function(sender, payload)
  local plan = P.Decode(payload)
  if not plan then return end
  -- only accept plans last edited by an officer, sent by an officer
  if not ns.OfficerSent(sender, plan.author, "plans") or not ns.TimeOK(plan.ts) then
    ns.Debug("ignored plan from non-officer " .. tostring(plan.author))
    return
  end
  local cur = P.All()[plan.id]
  if cur and (cur.ts or 0) >= plan.ts then return end
  if cur and cur.dirty and plan.author ~= ns.MyKey() then
    ns.Print(("%s updated the raid plan \"%s\" while you had unshared changes. Their version replaced yours.")
      :format(ns.ShortName(plan.author), plan.name))
  end
  P.All()[plan.id] = plan
  ns.Fire("PLANS_CHANGED")
end

ns.CommHandlers.C = function(sender, payload)
  local f = Enc.Split(payload, "^")
  if f[1] ~= "1" then return end
  local from, rank, ts = f[2], tonumber(f[3]), Enc.FromB36(f[4])
  if P.RankIndex(from) ~= 0 or not rank then return end -- only the Guild Master
  if not ns.OfficerSent(sender, from) or not ns.TimeOK(ts) then return end
  local g = ns.GuildDB()
  if not g or (g.officerRankTs or 0) >= ts then return end
  g.officerRank, g.officerRankTs, g.officerRankBy = rank, ts, from
  ns.Fire("PLANS_CHANGED")
end

-- feature permissions: only from the Guild Master (first-hand or passed on by an officer)
ns.CommHandlers.c = function(sender, payload)
  local d = P.DecodePerms(payload)
  if not d or P.RankIndex(d.by) ~= 0 then return end
  if not ns.OfficerSent(sender, d.by) or not ns.TimeOK(d.ts) then return end
  local g = ns.GuildDB()
  if not g or (g.permsTs or 0) >= d.ts then return end
  g.perms, g.permsTs, g.permsBy = d.perms, d.ts, d.by
  ns.Fire("PLANS_CHANGED")
end

ns.CommHandlers.Q = function(sender, payload)
  if not ns.AmOfficerRelayFor(sender) then return end -- plans are officer data
  local theirs = {}
  for _, item in ipairs(Enc.Split(payload, ",")) do
    local id, ts = item:match("^(.-)=(%w+)$")
    if id then theirs[id] = Enc.FromB36(ts) end
  end
  local g = ns.GuildDB()
  if g and (g.officerRankTs or 0) > (theirs["!cfg"] or 0) then P.SendConfig() end
  if g and (g.permsTs or 0) > (theirs["!perm"] or 0) then P.SendPerms() end
  for id, plan in pairs(P.All()) do
    if plan.shared and (theirs[id] or 0) < (plan.ts or 0) then ns.Send("P", P.Encode(plan)) end
  end
end

ns.RegisterDigest(function() ns.SendPlanDigest() end)
