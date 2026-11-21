-- Migrate: moving saved data over when the game stopped reporting realm names.
--
-- A game update on 21 Nov 2026 stopped the game reporting realm names. Until
-- then every character key held the guild's realm ("First Last-Realm") and a
-- guild's table was FableHubDB.guilds["<guild>|<realm>|<faction>"]; now keys
-- are just the name ("First Last") and the table is "<guild>||<faction>" (see
-- Core.lua). This moves the old data over, once, on this computer only. It
-- sends nothing and sets off nothing that sends: other clients just see our
-- usual hello afterwards.
--
-- Which keys move. Older versions took keys from messages before the guild
-- roster had loaded, so an old table can hold made-up keys ("Victim
-- Name-Junk"). Only a key whose realm is a trusted one loses its realm; any
-- other key with a "-" is left behind (dropped, never put together with a
-- real member's). Realms are compared without spaces, hyphens or apostrophes
-- and in lower case. Trusted:
--   account step   the realm in the name of any old guild table on this
--                  account (realms this account really played on), the
--                  commonest realm after "-" in FableHubDB.chars' keys (only
--                  ever written by our own client: a character whose guild
--                  table has gone, or who had none) and FableHubDB.realms.
--                  (It runs before Core.lua tidies away guild tables not
--                  visited for 90 days, so their names still count.)
--   guild step     the realm in the old table's own name, and the commonest
--                  realms after "-" in its knownRoster and addonUsers keys
--                  (our own guild roster and the members who said hello),
--                  at most MAX_TAILS spellings in all
-- Fields known to hold a key are re-keyed one by one. The realm is taken out
-- of a text only where the text has a key inside it (activity marks, loot
-- list slots, change log ids, sign-ups' "o:<key>", myAltsSig); free text
-- (announcements, notes, ...) is copied as it is.
--
-- Account step (Core.lua InitDB, while FableHubDB.dbVersion < 2):
--   * FableHubDB.chars: our own characters' records whose key holds a
--     trusted realm. Of several old keys giving the same name (one character
--     name on two realms), only the newest is put together with the record
--     under the new key (ns.MergeOwnRecords; its time becomes now); two old
--     records are never put together. Every old record, merged or not, is
--     kept as a backup and leaves FableHubDB.chars:
--       FableHubDB.migrated = { at = time(), chars = { [old key] = record } }
--     dropped 90 days later (MG.DropOldBackup, every login)
--   * FableHubDB.lastCheck (ready check results) is re-keyed; the latest wins
--   * no realm is learned here (FableHubDB.realms: see Core.lua)
--
-- Guild step (Core.lua ns.GuildDB, the first time a session the guild's table
-- is opened, before anything else looks at it):
--   * keys with a "-" in the new table's members, partials and owner are
--     dropped (the version before this one could take them from messages)
--   * old tables: "<guild>|<realm>|<faction>" for this guild and faction.
--     Only one is moved, as another realm can have a guild of the same name:
--     the one whose realm is the guild's realm GetGuildInfo reports (when
--     it does), else the one visited last (lastSeen). The others are marked
--     old.migrateSkipped = time() and left alone, as is every one once one
--     has been moved (old.migratedTo). The chosen one is put together with
--     the new table, feature by feature:
--       members      someone else's record moves when it's newer than the one
--                    in the new table and its owner vouched for it: the old
--                    table holds the owner's announced version (old.owner),
--                    and the record is that very version, with the owner's
--                    checksum (an older one, or one without a checksum, was
--                    never checked against the owner's word). Only its key
--                    changes; its checksum is worked out again (Core.lua
--                    RehashMembers), as every client turns the same old
--                    record into the same new text. Our own characters are
--                    skipped (the account step did them).
--       partials, owner   not moved (the old checksums cover the old keys;
--                    owners announce theirs again)
--       addonUsers (later seen), whisperNames (gaps only), missing (the
--       earlier time), knownRoster (both, so nobody shows as newly joined)
--       activity (both, no duplicates, the newest A.MAX within A.KEEP),
--       activitySeen (both, the later time)
--       plans, events, announcements, requests, loot, rhLinks, alts, bank
--       tabs, logs, gold, permissions and requests: per id the newer ts wins
--       (a tie keeps the new table's)
--       perms (+ permsTs, permsBy), officerRank (+ Ts, By), tmb: whole, when
--       the old one is newer
--       signups (per person, the newer ts), attendance (minutes: the larger;
--       officers' corrections: the newer ts)
--       manual (per slot, the newer ts; the oldest format, keyed by member
--       only, is converted first as Loot.lua does), seen (both)
--       altVouch (the more recent), myMain and myAltsSig (only when the new
--       table has none), myAltsTs (the later)
--       changelog (both, no duplicates, the newest CL.MAX)
--     Whatever moves is copied: the old table is never changed. Anything else
--     (data of features since removed) stays in the old table.
--   * the old table is kept untouched as a backup, apart from
--     old.migratedTo = the new key and old.migratedAt = time(). Its lastSeen
--     isn't changed, so the usual cleanup of guilds not visited for 90 days
--     (Core.lua InitDB) removes it. The moved table's own realm is
--     remembered as one of ours (ns.LearnRealm); a skipped one's isn't. The
--     new table notes
--       g.migratedFrom[old key] = time()
--       g.migrateNote = { from = old key, n = records moved }  (/fhub status
--       and /fhub bug show the old realm's name only)
-- Every rule keeps the newer or both, so running a step again changes nothing.
--
-- When something moved, one chat line says so, about 8 seconds after login:
-- one about the guild's data when a guild table moved, else one about our
-- characters' data.

local _, ns = ...
local MG = {}
ns.Migrate = MG

MG.BACKUP_KEEP = 90 * 86400
MG.MAX_TAILS = 4

------------------------------------------------------------------------
-- Keys and texts
------------------------------------------------------------------------
local function Norm(s) return (s:gsub("[%s%-']", ""):lower()) end
local function Tbl(v) return type(v) == "table" and v or nil end
local function Num(v) return tonumber(v) or 0 end

local function Escape(s) return (s:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1")) end

-- (only where the realm ends: "-Realm2" isn't "-Realm")
local function KeepEnd(c)
  if c:find("^%w$") then return nil end
  return c
end

-- trust = { norms = { [normalised realm] = true }, pats = { patterns } }
-- from a list of realm spellings (the first MAX_TAILS distinct ones)
local function Trust(spellings)
  local T, seen, tails = { norms = {}, pats = {} }, {}, {}
  for _, t in ipairs(spellings) do
    if #tails >= MG.MAX_TAILS then break end
    if type(t) == "string" and t ~= "" and #t <= 48 and not seen[t] and Norm(t) ~= "" then
      seen[t] = true
      tails[#tails + 1] = t
      T.norms[Norm(t)] = true
    end
  end
  -- patterns taking "-<realm>" out of a text, longest realm first
  table.sort(tails, function(a, b) return #a > #b end)
  for i, t in ipairs(tails) do T.pats[i] = "%-" .. Escape(t) .. "(.?)" end
  return T
end
MG.Trust = Trust

-- A key under trust T: "First Last-Realm" -> "First Last" when Realm is
-- trusted; false for any other "Name-Tail" (made up: left behind); anything
-- else ("Bob", "-", "", "?name", a number) unchanged.
local function Key(k, T)
  if type(k) ~= "string" then return k end
  local base, tail = k:match("^([^-]+)%-(.+)$")
  if not base then return k end
  if T.norms[Norm(tail)] then return ns.NormalizeName(base) or false end
  return false
end
MG.Key = Key

-- a field holding a key: re-keyed when trusted, else left as it is (it then
-- never matches anyone)
local function Val(v, T)
  local nv = Key(v, T)
  if nv == false then return v end
  return nv
end

-- "-<trusted realm>" taken out of a text with a key inside it
local function Strip(s, T)
  if type(s) ~= "string" or not s:find("-", 1, true) then return s end
  for _, p in ipairs(T.pats) do s = (s:gsub(p, KeepEnd)) end
  return s
end
MG.Strip = Strip

-- a copy of a saved value (saved data has no loops)
local function Deep(v, depth)
  depth = depth or 1
  if type(v) ~= "table" or depth > 20 then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = Deep(x, depth + 1) end
  return out
end

-- a map keyed by character, re-keyed (untrusted keys dropped); newest wins via `better`
local function KeyMap(map, T, better)
  local out = {}
  for k, v in pairs(Tbl(map) or {}) do
    local nk = Key(k, T)
    if nk and (out[nk] == nil or (better and better(v, out[nk]))) then out[nk] = v end
  end
  return out
end

local function OldKeys(t)
  local list = {}
  for k in pairs(t) do
    if type(k) == "string" and k:find("^[^-]+%-.+$") then list[#list + 1] = k end
  end
  table.sort(list)
  return list
end

------------------------------------------------------------------------
-- The chat line
------------------------------------------------------------------------
local NOTE_GUILD = "The game stopped reporting realm names, so FableHub moved your guild's saved data over. Nothing was lost."
local NOTE_CHARS = "The game stopped reporting realm names, so FableHub moved your characters' saved data over. Nothing was lost."
local pending, said, loggedIn = nil, nil, false -- "chars" / "guild"
local function Say()
  if not pending or said == pending or said == "guild" then return end
  said = pending
  ns.Print(pending == "guild" and NOTE_GUILD or NOTE_CHARS)
end
-- kind: "chars" (only our own characters moved) or "guild"
function MG.Announce(kind)
  if pending ~= "guild" then pending = kind or "guild" end
  if loggedIn then C_Timer.After(8, Say) end
end
ns.On("LOGIN", function()
  loggedIn = true
  if pending then C_Timer.After(8, Say) end
end)

------------------------------------------------------------------------
-- Account step
------------------------------------------------------------------------
function MG.Account(db)
  -- the realms this account played on: those in old guild tables' names
  local mids = {}
  for gk in pairs(Tbl(db.guilds) or {}) do
    local mid = type(gk) == "string" and gk:match("^.-|([^|]+)|[^|]*$")
    if mid then mids[#mids + 1] = mid end
  end
  table.sort(mids)
  local T = { norms = {} }
  for _, mid in ipairs(mids) do T.norms[Norm(mid)] = true end
  local chars = Tbl(db.chars)
  -- the commonest realm among our own characters' keys (see the header)
  local count, best = {}, nil
  for k in pairs(chars or {}) do
    local t = type(k) == "string" and k:match("^[^-]+%-(.+)$")
    if t and #t <= 48 then count[t] = (count[t] or 0) + 1 end
  end
  for t, n in pairs(count) do
    if not best or n > count[best] or (n == count[best] and t < best) then best = t end
  end
  if best and Norm(best) ~= "" then T.norms[Norm(best)] = true end
  for n, spelling in pairs(Tbl(db.realms) or {}) do
    local s = type(spelling) == "string" and spelling or (type(n) == "string" and n) or ""
    if Norm(s) ~= "" then T.norms[Norm(s)] = true end
  end
  local moved = false
  -- our own characters' records
  if chars then
    local keys = OldKeys(chars)
    -- of several old keys giving one name, only the newest is merged
    local newest = {}
    for _, k in ipairs(keys) do
      local nk, rec = Key(k, T), chars[k]
      if nk and type(rec) == "table" and (not newest[nk] or Num(rec.ts) > Num(chars[newest[nk]].ts)) then newest[nk] = k end
    end
    for _, k in ipairs(keys) do
      local rec, nk = chars[k], Key(k, T)
      if nk and newest[nk] == k then
        local merged = ns.MergeOwnRecords(Tbl(chars[nk]), rec)
        -- (a time of now, past anything anyone holds of us: our scan at
        -- login only moves it on when something changed)
        merged.key, merged.ts = nk, math.max(merged.ts, ns.Now())
        chars[nk] = merged
      end
      db.migrated = Tbl(db.migrated) or { at = time() }
      db.migrated.chars = Tbl(db.migrated.chars) or {}
      db.migrated.chars[k] = rec
      chars[k] = nil
      moved = true
    end
  end
  -- ready check results kept per character
  local checks = Tbl(db.lastCheck)
  if checks then
    for _, k in ipairs(OldKeys(checks)) do
      local v, nk = checks[k], Key(k, T)
      if nk then
        checks[k] = nil
        local cur = checks[nk]
        if type(v) == "table" and (type(cur) ~= "table" or Num(v.at) > Num(cur.at)) then checks[nk] = v end
      end
    end
  end
  if moved then MG.Announce("chars") end
end

function MG.DropOldBackup(db)
  local m = db and db.migrated
  if m ~= nil and (type(m) ~= "table" or time() - Num(m.at) > MG.BACKUP_KEEP) then db.migrated = nil end
end

------------------------------------------------------------------------
-- Guild step
------------------------------------------------------------------------
-- "<ts36>:<h16>" -> ts, checksum
local function OwnerSaid(v)
  if type(v) ~= "string" then return nil end
  local ts36, h = v:match("^(%w+):(%w+)$")
  return ts36 and tonumber(ts36, 36), h
end

local function MoveMembers(g, old, T)
  local chars = Tbl(FableHubDB.chars) or {}
  local owner = Tbl(old.owner) or {}
  local moved = 0
  for k, rec in pairs(Tbl(old.members) or {}) do
    local nk = Key(k, T)
    if type(nk) == "string" and nk ~= "" and not nk:find("-", 1, true) and type(rec) == "table"
        and type(rec.ts) == "number" and not chars[nk] then
      -- only a version its owner vouched for: the one they announced, with
      -- their checksum
      local ots, oh = OwnerSaid(owner[k])
      local vouched = ots ~= nil and rec.ts == ots and rec.hash ~= nil and rec.hash == oh
      local cur = g.members[nk]
      if vouched and not (type(cur) == "table" and Num(cur.ts) >= rec.ts) then
        local copy = {}
        for f, v in pairs(rec) do copy[f] = v end
        copy.key, copy.hash, copy.partial, copy.staleRecipes = nk, nil, nil, nil
        g.members[nk] = copy
        moved = moved + 1
      end
    end
  end
  return moved
end

-- per id: the newer ts wins (a tie keeps the new table's). The winner is
-- copied and its key fields re-keyed by fix(copy, T). charMap: the ids are
-- character keys (untrusted ones are left behind)
local function ById(new, old, T, fix, charMap)
  for id, item in pairs(Tbl(old) or {}) do
    local nid = id
    if charMap then nid = Key(id, T) end
    local cur = nid and new[nid]
    if nid and type(item) == "table" and (type(cur) ~= "table" or Num(item.ts) > Num(cur.ts)) then
      local copy = Deep(item)
      if fix then fix(copy, T) end
      new[nid] = copy
    end
  end
end

local function Field(g, name)
  if type(g[name]) ~= "table" then g[name] = {} end
  return g[name]
end

-- key fields of each kind of item
local function FixBy(e, T) e.by = Val(e.by, T) end
local FIX = {
  plans = function(p, T)
    p.author = Val(p.author, T)
    if Tbl(p.slots) then
      for i, k in pairs(p.slots) do p.slots[i] = Val(k, T) end
    end
    if Tbl(p.roles) then p.roles = KeyMap(p.roles, T) end
    if Tbl(p.extras) then p.extras = KeyMap(p.extras, T) end
  end,
  events = function(e, T) e.author = Val(e.author, T) end,
  announcements = FixBy,
  requests = function(r, T) r.by, r.claimer = Val(r.by, T), Val(r.claimer, T) end,
  loot = function(l, T) l.to, l.by = Val(l.to, T), Val(l.by, T) end,
  rhLinks = function(l, T) l.key, l.by = Val(l.key, T), Val(l.by, T) end,
}

-- one value with its time and author: the old one when it's newer
local function Group(g, old, field, tsField, byField, T)
  if old[tsField] ~= nil and Num(old[tsField]) > Num(g[tsField]) then
    g[field], g[tsField], g[byField] = Deep(old[field]), old[tsField], Val(old[byField], T)
  end
end

local function MergeActivity(g, old, T)
  local A = ns.Activity
  if Tbl(old.activity) then
    local cutoff = ns.Now() - (A and A.KEEP or 30 * 86400)
    local list, seen = {}, {}
    local function Add(e)
      if type(e) ~= "table" or Num(e.t) < cutoff then return end
      local id = table.concat({ tostring(e.t), tostring(e.kind), tostring(e.key), tostring(e.text) }, "|")
      if not seen[id] then seen[id] = true; list[#list + 1] = e end
    end
    for _, e in ipairs(Tbl(g.activity) or {}) do Add(e) end
    for _, e in ipairs(old.activity) do
      if type(e) == "table" then
        local copy = Deep(e)
        copy.key = Val(copy.key, T)
        Add(copy)
      end
    end
    table.sort(list, function(a, b) return Num(a.t) < Num(b.t) end)
    local max = A and A.MAX or 150
    while #list > max do table.remove(list, 1) end
    g.activity = list
  end
  if Tbl(old.activitySeen) then
    local seen = Field(g, "activitySeen")
    for k, t in pairs(old.activitySeen) do
      local nk = Strip(k, T)
      if type(t) == "number" and (type(seen[nk]) ~= "number" or t > seen[nk]) then seen[nk] = t end
    end
  end
end

local function FixSignup(s, T)
  s.char, s.by = Val(s.char, T), Val(s.by, T)
  local src = type(s.src) == "string" and s.src:match("^o:(.*)$")
  if src then s.src = "o:" .. Val(src, T) end
end

local function MergeEvents(g, old, T)
  for occ, list in pairs(Tbl(old.signups) or {}) do
    if type(list) == "table" then
      local signups = Field(g, "signups")
      if type(signups[occ]) ~= "table" then signups[occ] = {} end
      ById(signups[occ], list, T, FixSignup, true)
    end
  end
  for occ, a in pairs(Tbl(old.attendance) or {}) do
    if type(a) == "table" then
      local all = Field(g, "attendance")
      if type(all[occ]) ~= "table" then all[occ] = {} end
      local cur = all[occ]
      local min, ov = Field(cur, "min"), Field(cur, "ov")
      for k, m in pairs(Tbl(a.min) or {}) do
        local nk = Key(k, T)
        if nk and type(m) == "number" and m > Num(min[nk]) then min[nk] = m end
      end
      ById(ov, a.ov, T, FixBy, true)
      if Num(a.ts) > Num(cur.ts) then cur.ts, cur.by = a.ts, Val(a.by, T) end
    end
  end
end

-- g.manual[item] in the oldest format (keyed by member only) -> a copy keyed
-- "<key>|<type>", as Loot.lua's Manual() converts it
local function ManualV2(list)
  local wish = ns.Loot and ns.Loot.TYPE_WISH or 2
  local out = {}
  for k, m in pairs(list) do
    if type(m) == "table" then
      if type(k) == "string" and not k:find("|", 1, true) then
        local copy = Deep(m)
        copy.key = copy.key or k
        local slot = tostring(copy.key) .. "|" .. tostring(copy.t or wish)
        if type(out[slot]) ~= "table" or Num(out[slot].ts) < Num(copy.ts) then out[slot] = copy end
      elseif type(out[k]) ~= "table" or Num(out[k].ts) < Num(m.ts) then
        out[k] = m
      end
    end
  end
  return out
end

-- a loot list slot "<key>|<type>" re-keyed (nil: an untrusted key)
local function Slot(slot, T)
  if type(slot) ~= "string" then return slot end
  local k, typ = slot:match("^(.*)|([^|]*)$")
  if not k then return Strip(slot, T) end
  local nk = Key(k, T)
  return nk and (nk .. "|" .. typ) or nil
end

local function MergeLoot(g, old, T)
  if Tbl(old.manual) then
    local manual = Field(g, "manual")
    local hadAny = next(manual) ~= nil
    for item, list in pairs(old.manual) do
      if type(list) == "table" then
        if not old.manualV2 then list = ManualV2(list) end
        if type(manual[item]) ~= "table" then manual[item] = {} end
        local cur = manual[item]
        for slot, m in pairs(list) do
          local nslot = Slot(slot, T)
          if nslot and type(m) == "table" and (type(cur[nslot]) ~= "table" or Num(m.ts) > Num(cur[nslot].ts)) then
            local copy = Deep(m)
            copy.key, copy.by = Val(copy.key, T), Val(copy.by, T)
            cur[nslot] = copy
          end
        end
      end
    end
    -- (entries of the new table still in the old format are converted by Loot.lua)
    if g.manualV2 or not hadAny then g.manualV2 = true end
  end
  for item, inst in pairs(Tbl(old.seen) or {}) do
    local seen = Field(g, "seen")
    if seen[item] == nil then seen[item] = inst end
  end
  -- (copied only when it's the one kept)
  if Tbl(old.tmb) and (type(g.tmb) ~= "table" or Num(old.tmb.ts) > Num(g.tmb.ts)) then
    g.tmb = Deep(old.tmb)
    g.tmb.by = Val(g.tmb.by, T)
  end
end

local function FixBankRequest(r, T) r.by, r.actor = Val(r.by, T), Val(r.actor, T) end

local function MergeBank(g, old, T)
  local ob = Tbl(old.bank)
  if not ob then return end
  local bank = Field(g, "bank")
  ById(Field(bank, "tabs"), ob.tabs, T, FixBy, false)
  ById(Field(bank, "logs"), ob.logs, T, FixBy, false)
  ById(Field(bank, "requests"), ob.requests, T, FixBankRequest, false)
  for _, f in ipairs({ "money", "perm" }) do
    if Tbl(ob[f]) and (type(bank[f]) ~= "table" or Num(ob[f].ts) > Num(bank[f].ts)) then
      bank[f] = Deep(ob[f])
      bank[f].by = Val(bank[f].by, T)
    end
  end
end

local function MergeAlts(g, old, T)
  ById(Field(g, "alts"), old.alts, T, function(e) e.main, e.by = Val(e.main, T), Val(e.by, T) end, true)
  if Tbl(old.altVouch) then
    local cur = Field(g, "altVouch")
    local function Latest(v) return math.max(Num(v.char), Num(v.mainSide)) end
    for char, v in pairs(old.altVouch) do
      local nk = Key(char, T)
      if nk and type(v) == "table" and (type(cur[nk]) ~= "table" or Latest(v) > Latest(cur[nk])) then
        local copy = Deep(v)
        copy.main = Val(copy.main, T)
        cur[nk] = copy
      end
    end
  end
  if g.myMain == nil and type(old.myMain) == "string" then g.myMain = Val(old.myMain, T) end
  if g.myAltsSig == nil and type(old.myAltsSig) == "string" then g.myAltsSig = Strip(old.myAltsSig, T) end
  if type(old.myAltsTs) == "number" and old.myAltsTs > Num(g.myAltsTs) then g.myAltsTs = old.myAltsTs end
end

local function MergeChangeLog(g, old, T)
  if not Tbl(old.changelog) then return end
  local list, seen = {}, {}
  local function Add(e)
    if type(e) ~= "table" then return end
    local id = tostring(e.ts) .. "|" .. tostring(e.by) .. "|" .. tostring(e.text)
    if not seen[id] then seen[id] = true; list[#list + 1] = e end
  end
  for _, e in ipairs(Tbl(g.changelog) or {}) do Add(e) end
  for _, e in ipairs(old.changelog) do
    if type(e) == "table" then
      local copy = Deep(e)
      copy.by = Val(copy.by, T)
      if Tbl(copy.ids) then
        local ids = {}
        for id, v in pairs(copy.ids) do ids[Strip(id, T)] = v end
        copy.ids = ids
      end
      Add(copy)
    end
  end
  table.sort(list, function(a, b) return Num(a.ts) > Num(b.ts) end)
  local max = ns.ChangeLog and ns.ChangeLog.MAX or 20
  while #list > max do table.remove(list) end
  g.changelog = list
end

local function Merge(g, old, T)
  for k, v in pairs(KeyMap(old.addonUsers, T, function(a, b) return type(a) == "table" and Num(a.seen) > Num(Tbl(b) and b.seen) end)) do
    local users = Field(g, "addonUsers")
    if type(v) == "table" and (type(users[k]) ~= "table" or Num(v.seen) > Num(users[k].seen)) then users[k] = Deep(v) end
  end
  for k, form in pairs(KeyMap(old.whisperNames, T)) do
    local names = Field(g, "whisperNames")
    form = Val(form, T)
    if names[k] == nil and type(form) == "string" and form ~= k then names[k] = form end
  end
  for k, t in pairs(KeyMap(old.missing, T, function(a, b) return type(a) == "number" and a < Num(b) end)) do
    local missing = Field(g, "missing")
    if type(t) == "number" and (type(missing[k]) ~= "number" or t < missing[k]) then missing[k] = t end
  end
  for k in pairs(KeyMap(old.knownRoster, T)) do Field(g, "knownRoster")[k] = true end
  MergeActivity(g, old, T)
  for _, f in ipairs({ "plans", "events", "announcements", "requests", "loot", "rhLinks" }) do
    if Tbl(old[f]) then ById(Field(g, f), old[f], T, FIX[f], false) end
  end
  Group(g, old, "perms", "permsTs", "permsBy", T)
  Group(g, old, "officerRank", "officerRankTs", "officerRankBy", T)
  MergeEvents(g, old, T)
  MergeLoot(g, old, T)
  MergeBank(g, old, T)
  MergeAlts(g, old, T)
  MergeChangeLog(g, old, T)
end

-- the realm spellings trusted for an old table (see the header)
local function Tails(mid, old)
  local count = {}
  for _, f in ipairs({ "knownRoster", "addonUsers" }) do
    for k in pairs(Tbl(old[f]) or {}) do
      local t = type(k) == "string" and k:match("^[^-]+%-(.+)$")
      if t then count[t] = (count[t] or 0) + 1 end
    end
  end
  local others = {}
  for t in pairs(count) do others[#others + 1] = t end
  table.sort(others, function(a, b)
    if count[a] ~= count[b] then return count[a] > count[b] end
    return a < b
  end)
  local list = { mid, (mid:gsub("[%s%-]", "")) }
  for _, t in ipairs(others) do list[#list + 1] = t end
  return list
end

local function MoveTable(g, gk, ok, mid, old)
  local T = Trust(Tails(mid, old))
  local moved = MoveMembers(g, old, T)
  Merge(g, old, T)
  -- done: marked only now, so a run that stopped part-way runs again
  local now = time()
  old.migratedTo, old.migratedAt = gk, now
  g.migratedFrom = Tbl(g.migratedFrom) or {}
  g.migratedFrom[ok] = now
  ns.LearnRealm(mid)
  ns.Debug(("moved %d records from %s"):format(moved, (tostring(ok):gsub("|", "||"))))
  return moved
end

-- keys with a "-" in the new table (never guild keys: see Core.lua)
local function DropDashKeys(g)
  for _, f in ipairs({ "members", "partials", "owner" }) do
    local t = Tbl(g[f])
    if t then
      local drop = {}
      for k in pairs(t) do
        if type(k) ~= "string" or k:find("-", 1, true) then drop[#drop + 1] = k end
      end
      for _, k in ipairs(drop) do t[k] = nil end
    end
  end
end

-- the guild's realm, when the game reports it (else nil)
local function GuildRealm()
  if not GetGuildInfo then return nil end
  local realm = select(4, GetGuildInfo("player"))
  if type(realm) ~= "string" or (issecretvalue and issecretvalue(realm)) or Norm(realm) == "" then return nil end
  return realm
end

function MG.Guild(g, gk)
  local db = FableHubDB
  if type(db) ~= "table" or type(db.guilds) ~= "table" or type(gk) ~= "string" or type(g) ~= "table" then return end
  DropDashKeys(g)
  local name, faction = gk:match("^(.*)||([^|]*)$")
  if not name then return end
  local olds, done = {}, false
  for ok, old in pairs(db.guilds) do
    if ok ~= gk and type(ok) == "string" and type(old) == "table" then
      local n, mid, f = ok:match("^(.*)|([^|]+)|([^|]*)$")
      if n == name and f == faction then
        if old.migratedTo then done = true
        elseif not old.migrateSkipped then olds[#olds + 1] = { key = ok, mid = mid, t = old } end
      end
    end
  end
  if #olds == 0 then return end
  -- only one (see the header): the guild's realm if the game reports it,
  -- else the one visited last
  local pick
  if not done then
    local realm = GuildRealm()
    local list = {}
    if realm then
      for _, o in ipairs(olds) do if Norm(o.mid) == Norm(realm) then list[#list + 1] = o end end
    end
    if #list == 0 then list = olds end
    for _, o in ipairs(list) do
      local a, b = Num(o.t.lastSeen), pick and Num(pick.t.lastSeen)
      if not pick or a > b or (a == b and o.key < pick.key) then pick = o end
    end
  end
  local now = time()
  for _, o in ipairs(olds) do
    if o ~= pick then o.t.migrateSkipped = now end
  end
  if not pick then return end
  g.members = Tbl(g.members) or {}
  local moved = MoveTable(g, gk, pick.key, pick.mid, pick.t)
  g.migrateNote = { from = pick.key, n = moved }
  MG.Announce("guild")
end

-- for /fhub status and /fhub bug: "" when nothing was moved. Only the old
-- realm's name is shown: a table's key holds "|" (a chat formatting code).
function MG.Status(g)
  local note = g and Tbl(g.migrateNote)
  if not note then return "" end
  local from = {}
  for part in tostring(note.from):gmatch("[^,]+") do
    part = part:match("^%s*(.-)%s*$")
    from[#from + 1] = part:match("^.-|([^|]+)|[^|]*$") or part
  end
  local text = table.concat(from, ", "):gsub("|", "||")
  return ("moved %d records from the old saved data (realm %s)"):format(Num(note.n), text)
end
