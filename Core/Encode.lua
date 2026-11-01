-- Encode: compact text format for sending records over addon messages.
--
-- record  = "1^<key>^<ts>^<class>^<level>^<prof>~<prof>..."
-- prof    = "<skillLine>:<rank>:<max>:<name>:<recipe>.<recipe>..."
-- fields after the profs: spec tree, points, buffs, spec name, recipe outputs,
-- then (only when there are any) cooldowns "<id>=<ready>=<dur>,..." and when they were read,
-- then (only when the owner shares it, 0.24+) time played (see Enc.EncodePlayed)
-- numbers are base36 to keep messages short.

local _, ns = ...
local Enc = {}
ns.Encode = Enc

local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"

function Enc.ToB36(n)
  n = math.floor(tonumber(n) or 0)
  if n <= 0 then return "0" end
  local out = {}
  while n > 0 do
    local d = n % 36
    table.insert(out, 1, DIGITS:sub(d + 1, d + 1))
    n = math.floor(n / 36)
  end
  return table.concat(out)
end

function Enc.FromB36(s)
  return tonumber(s or "", 36) or 0
end

-- strip characters we use as separators (and chat escape pipes)
local function Clean(s)
  return (tostring(s or ""):gsub("[%^~:%.,|]", " "))
end
Enc.Clean = Clean

-- recipe -> crafted item, "recipe36=item36,..." (only for recipes this record knows)
function Enc.EncodeOutputs(rec)
  local out = {}
  if rec.outputs then
    local known = {}
    for _, p in pairs(rec.profs or {}) do for id in pairs(p.recipes or {}) do known[id] = true end end
    for r, i in pairs(rec.outputs) do
      if known[r] then out[#out + 1] = Enc.ToB36(r) .. "=" .. Enc.ToB36(i) end
    end
    table.sort(out)
  end
  return table.concat(out, ",")
end

-- Time played (0.24+, field 14): "1=<total>=<thisLevel>=<lvl>=<at>", plus
-- "=<xp>=<xpMax>=<rested>=<sess>" below the level cap. The leading 1 is the
-- format's version (other versions are ignored). Seconds; at = server time of
-- the reading; sess = XP per hour this session (0 = not known).
-- The level cap here is fixed rather than the client's own (ns.MaxLevel), so
-- every encoder and decoder agrees on when there's an XP part.
Enc.PLAYED_MAX_LEVEL = 60
function Enc.EncodePlayed(p)
  if type(p) ~= "table" or (tonumber(p.total) or 0) <= 0 then return nil end
  local B = Enc.ToB36
  local parts = { "1", B(p.total), B(p.thisLevel), B(p.lvl), B(p.at) }
  if p.xpMax and (tonumber(p.lvl) or 0) < Enc.PLAYED_MAX_LEVEL then
    parts[6], parts[7], parts[8], parts[9] = B(p.xp), B(p.xpMax), B(p.rested), B(p.sess)
  end
  return table.concat(parts, "=")
end

-- noCds: core fields only, leaving out the cooldowns and time played (what a
-- 0.21 client passes on: it doesn't know them and relays records without them)
function Enc.EncodeRecord(rec, noCds)
  local profs = {}
  -- sort for stable output (helps tests and avoids needless diffs)
  local lines = {}
  for skillLine in pairs(rec.profs or {}) do lines[#lines + 1] = skillLine end
  table.sort(lines)
  for _, skillLine in ipairs(lines) do
    local p = rec.profs[skillLine]
    local ids = {}
    for id in pairs(p.recipes or {}) do ids[#ids + 1] = id end
    table.sort(ids)
    for i, id in ipairs(ids) do ids[i] = Enc.ToB36(id) end
    profs[#profs + 1] = table.concat({
      Enc.ToB36(skillLine), Enc.ToB36(p.rank), Enc.ToB36(p.max), Clean(p.name), table.concat(ids, "."),
    }, ":")
  end
  local buffs = {}
  for id in pairs(rec.buffs or {}) do buffs[#buffs + 1] = Clean(id) end
  table.sort(buffs)
  local spec = rec.spec or {}
  local fields = {
    "1", (tostring(rec.key):gsub("[%^~]", "")), Enc.ToB36(rec.ts), Clean(rec.class), Enc.ToB36(rec.level),
    table.concat(profs, "~"),
    Enc.ToB36(spec.tree or 0), (tostring(spec.points or ""):gsub("[^%d/]", "")), table.concat(buffs, "."), Clean(spec.name),
    Enc.EncodeOutputs(rec),
  }
  -- profession cooldowns (0.22+), only when there are any so older records encode as before
  if not noCds and rec.cds and next(rec.cds) then
    local cds = {}
    for id, e in pairs(rec.cds) do
      cds[#cds + 1] = (tostring(id):gsub("[^%w_]", "")) .. "=" .. Enc.ToB36(e.ready) .. "=" .. Enc.ToB36(e.dur)
    end
    table.sort(cds)
    fields[12] = table.concat(cds, ",")
    fields[13] = Enc.ToB36(rec.cdChecked or 0)
  end
  -- time played (0.24+), only when shared, so a record without it encodes as
  -- before; empty cooldown fields fill the gap when there are no cooldowns
  local played = not noCds and rec.played and Enc.EncodePlayed(rec.played)
  if played then
    fields[12] = fields[12] or ""
    fields[13] = fields[13] or ""
    fields[14] = played
  end
  return table.concat(fields, "^")
end

local function Split(s, sep)
  local out = {}
  if s == nil or s == "" then return out end
  local start = 1
  while true do
    local i = s.find(s, sep, start, true)
    if not i then
      out[#out + 1] = s:sub(start)
      break
    end
    out[#out + 1] = s:sub(start, i - 1)
    start = i + #sep
  end
  return out
end
Enc.Split = Split

-- Limits on what a received record may hold (records come from other players,
-- so they're untrusted): far above anything real, small enough that nobody can
-- fill everyone's saved data
local MAX_NAME = 32         -- profession and spec names
local MAX_PROFS = 10        -- professions per record
local MAX_RECIPES = 1000    -- recipes per profession
local MAX_OUTPUTS = 2000    -- recipe -> crafted item pairs
local MAX_CD = 14 * 86400   -- longest cooldown, and how far ahead one can be ready
local MAX_BUFFS = 128       -- buffs per record (Data/Buffs.lua lists ~60; a real record must
                            -- never be cut short, or its owner would see a "different" copy)
local MAX_BUFF_ID = 32      -- length of one buff id
local MAX_CLASS = 16        -- class token ("WARRIOR"): upper-case letters only
local MAX_PLAYED = 157680000 -- time played: 5 years
local MAX_XP = 1000000      -- XP needed for one level
local MAX_XP_RATE = 500000  -- XP per hour

-- field 14 -> { total, thisLevel, lvl, at, xp?, xpMax?, rested?, sess? }, or nil
-- if it isn't a sane reading. A bad XP part drops only the XP part. Honest
-- values are never clamped, so encoding a decoded reading gives it back.
-- (the level cap is Enc.PLAYED_MAX_LEVEL, as in EncodePlayed)
function Enc.DecodePlayed(s)
  if type(s) ~= "string" or #s > 120 or not s:match("^[%w=]+$") then return nil end
  local f = Split(s, "=")
  if f[1] ~= "1" or (#f ~= 5 and #f ~= 9) then return nil end
  for i = 2, #f do if f[i] == "" then return nil end end
  local maxLevel = Enc.PLAYED_MAX_LEVEL
  local n = {}
  for i = 2, #f do n[i] = Enc.FromB36(f[i]) end
  local total, thisLevel, lvl, at = n[2], n[3], n[4], n[5]
  local now = ns.Now and ns.Now() or 0
  if total <= 0 or total > MAX_PLAYED or thisLevel < 0 or thisLevel > total
    or lvl < 1 or lvl > maxLevel or at <= 0 or at > now + 300 then
    return nil
  end
  local p = { total = total, thisLevel = thisLevel, lvl = lvl, at = at }
  if #f == 9 and lvl < maxLevel then
    local xp, xpMax, rested, sess = n[6], n[7], n[8], n[9]
    if xpMax > 0 and xpMax <= MAX_XP and xp >= 0 and xp < xpMax and rested >= 0 and rested <= 1.5 * xpMax
      and sess >= 0 and sess <= MAX_XP_RATE then
      p.xp, p.xpMax, p.rested, p.sess = xp, xpMax, rested, sess
    end
  end
  return p
end

function Enc.DecodeRecord(text)
  local f = Split(text, "^")
  if f[1] ~= "1" or not f[2] or f[2] == "" then return nil end
  local class = f[4]
  if not class or #class > MAX_CLASS or not class:match("^%u+$") then class = nil end
  local rec = {
    key = f[2],
    ts = Enc.FromB36(f[3]),
    class = class,
    level = Enc.FromB36(f[5]),
    profs = {},
  }
  local tree = Enc.FromB36(f[7])
  if tree > 0 then
    rec.spec = { tree = tree, points = (f[8] or ""):sub(1, 16),
                 name = (f[10] and f[10] ~= "" and f[10]:sub(1, MAX_NAME)) or nil }
  end
  if f[11] and f[11] ~= "" then
    rec.outputs = {}
    local n = 0
    for _, pair in ipairs(Split(f[11], ",")) do
      local r, i = pair:match("^(%w+)=(%w+)$")
      if r then
        n = n + 1
        if n > MAX_OUTPUTS then break end
        rec.outputs[Enc.FromB36(r)] = Enc.FromB36(i)
      end
    end
  end
  if f[9] and f[9] ~= "" then
    rec.buffs = {}
    local n = 0
    for _, id in ipairs(Split(f[9], ".")) do
      if id ~= "" and #id <= MAX_BUFF_ID then
        n = n + 1
        if n > MAX_BUFFS then break end
        rec.buffs[id] = true
      end
    end
  end
  local nProfs = 0
  for _, ptext in ipairs(Split(f[6] or "", "~")) do
    local pf = Split(ptext, ":")
    local skillLine = Enc.FromB36(pf[1])
    if skillLine > 0 and nProfs < MAX_PROFS then
      nProfs = nProfs + 1
      local recipes, n = {}, 0
      for _, r in ipairs(Split(pf[5] or "", ".")) do
        local id = Enc.FromB36(r)
        if id > 0 then
          n = n + 1
          if n > MAX_RECIPES then break end
          recipes[id] = true
        end
      end
      rec.profs[skillLine] = {
        rank = Enc.FromB36(pf[2]),
        max = Enc.FromB36(pf[3]),
        name = (pf[4] or ""):sub(1, MAX_NAME),
        recipes = recipes,
      }
    end
  end
  -- only cooldowns FableHub knows (Data/Cooldowns.lua loads after this file,
  -- so the list is looked up here, when a record arrives), and only for a
  -- profession the record has (the owner's own cooldowns always do, see
  -- Cooldowns.lua), so nobody can hang made-up cooldowns on a record
  local knownCds = ns.COOLDOWN_BY_ID
  if f[12] and f[12] ~= "" and knownCds then
    local now = ns.Now and ns.Now() or 0
    for _, item in ipairs(Split(f[12], ",")) do
      local id, ready, dur = item:match("^([%w_]+)=(%w+)=(%w+)$")
      local cd = id and knownCds[id]
      if cd and rec.profs[cd.skillLine] then
        rec.cds = rec.cds or {}
        rec.cds[id] = { ready = math.max(0, math.min(Enc.FromB36(ready), now + MAX_CD)),
                        dur = math.max(0, math.min(Enc.FromB36(dur), MAX_CD)) }
      end
    end
    if rec.cds then rec.cdChecked = math.max(0, math.min(Enc.FromB36(f[13]), now + 300)) end
  end
  if f[14] and f[14] ~= "" then rec.played = Enc.DecodePlayed(f[14]) end
  return rec
end

-- digest = "<key>=<ts>,<key>=<ts>..."
function Enc.EncodeDigest(members)
  local parts = {}
  for key, rec in pairs(members) do
    parts[#parts + 1] = key .. "=" .. Enc.ToB36(rec.ts or 0)
  end
  table.sort(parts)
  return table.concat(parts, ",")
end

function Enc.DecodeDigest(text)
  local out = {}
  for _, item in ipairs(Split(text or "", ",")) do
    local key, ts = item:match("^(.-)=(%w+)$")
    if key and key ~= "" then out[key] = Enc.FromB36(ts) end
  end
  return out
end
