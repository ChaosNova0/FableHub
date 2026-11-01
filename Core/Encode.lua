-- Encode: compact text format for sending records over addon messages.
--
-- record  = "1^<key>^<ts>^<class>^<level>^<prof>~<prof>..."
-- prof    = "<skillLine>:<rank>:<max>:<name>:<recipe>.<recipe>..."
-- fields after the profs: spec tree, points, buffs, spec name, recipe outputs,
-- then (only when there are any) cooldowns "<id>=<ready>=<dur>,..." and when they were read,
-- then (only when the owner shares it) time played (see Enc.EncodePlayed)
-- numbers are base36 to keep messages short.
--
-- Canonical encoding (0.26+): Enc.DecodeRecord is a pure function of the text
-- (no clock, no data tables), and Enc.EncodeRecord of what it returns gives
-- the record's canonical text: Enc.Canon(text). Every client decoding the same
-- text holds the same record and re-encodes it to the same canonical text, so
-- one checksum of that text (Hash.lua) identifies a version everywhere.
-- Owners always send their record's canonical text.

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

-- lenient: anything that isn't a number reads as 0 (features' own formats)
function Enc.FromB36(s)
  return tonumber(s or "", 36) or 0
end

-- strict, for records: a base36 number of at most 8 letters and digits, no
-- sign or spaces, from 0 to `max`; nil otherwise
local function Num(s, max)
  if type(s) ~= "string" or s == "" or #s > 8 or not s:find("^%w+$") then return nil end
  local v = tonumber(s, 36)
  if not v or v < 0 or v > max then return nil end
  return v
end
Enc.Num = Num

-- strip characters we use as separators (and chat escape pipes)
local function Clean(s)
  return (tostring(s or ""):gsub("[%^~:%.,|]", " "))
end
Enc.Clean = Clean

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
local MAX_CD = 14 * 86400   -- longest cooldown, and how far ahead of the record one can be ready
local MAX_CDS = 16          -- cooldowns per record
local MAX_CD_ID = 32        -- length of one cooldown id
local MAX_BUFFS = 128       -- buffs per record (Data/Buffs.lua lists ~60; a real record must
                            -- never be cut short, or its owner would see a "different" copy)
local MAX_BUFF_ID = 32      -- length of one buff id
local MAX_CLASS = 16        -- class token ("WARRIOR"): upper-case letters only
local MAX_KEY = 64          -- character key
local MAX_PLAYED = 157680000 -- time played: 5 years
local MAX_XP = 1000000      -- XP needed for one level
local MAX_XP_RATE = 500000  -- XP per hour
local MAX_ID = 2147483648   -- recipe, item and skill line ids (2^31)
local MAX_TS = 4294967296   -- times (2^32)
local AHEAD = 300           -- how far past the record's own time a reading may be
Enc.MAX_CD = MAX_CD

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

-- Time played (field 14): "1=<total>=<thisLevel>=<lvl>=<at>", plus
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

-- spec points as sent: digits and "/" only, at most 16 characters
local function Points(s) return (tostring(s or ""):gsub("[^%d/]", "")):sub(1, 16) end

function Enc.EncodeRecord(rec)
  local profs = {}
  -- sorted, so one record always encodes the same way (see Canon above)
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
      Enc.ToB36(skillLine), Enc.ToB36(p.rank), Enc.ToB36(p.max), Clean(p.name):sub(1, MAX_NAME), table.concat(ids, "."),
    }, ":")
  end
  local buffs = {}
  for id in pairs(rec.buffs or {}) do buffs[#buffs + 1] = Clean(id) end
  table.sort(buffs)
  local spec = rec.spec or {}
  local tree = tonumber(spec.tree) or 0
  local fields = {
    "1", (tostring(rec.key):gsub("[%^~]", "")), Enc.ToB36(rec.ts), Clean(rec.class), Enc.ToB36(rec.level),
    table.concat(profs, "~"),
    Enc.ToB36(tree), tree > 0 and Points(spec.points) or "", table.concat(buffs, "."),
    tree > 0 and Clean(spec.name):sub(1, MAX_NAME) or "",
    Enc.EncodeOutputs(rec),
  }
  -- profession cooldowns, only when there are any (at most MAX_CDS, in the
  -- order they're sent: what a decoder keeps)
  if rec.cds and next(rec.cds) then
    local cds = {}
    for id, e in pairs(rec.cds) do
      local clean = (tostring(id):gsub("[^%w_]", ""))
      if clean ~= "" and #clean <= MAX_CD_ID then
        cds[#cds + 1] = clean .. "=" .. Enc.ToB36(e.ready) .. "=" .. Enc.ToB36(e.dur)
      end
    end
    table.sort(cds)
    for i = #cds, MAX_CDS + 1, -1 do cds[i] = nil end
    if #cds > 0 then
      fields[12] = table.concat(cds, ",")
      fields[13] = Enc.ToB36(rec.cdChecked or 0)
    end
  end
  -- time played, only when shared; empty cooldown fields fill the gap when
  -- there are no cooldowns
  local played = rec.played and Enc.EncodePlayed(rec.played)
  if played then
    fields[12] = fields[12] or ""
    fields[13] = fields[13] or ""
    fields[14] = played
  end
  return table.concat(fields, "^")
end

-- field 14 -> { total, thisLevel, lvl, at, xp?, xpMax?, rested?, sess? }, or nil
-- if it isn't a sane reading. A bad XP part drops only the XP part. Honest
-- values are never clamped, so encoding a decoded reading gives it back.
-- refTs: the record's own time (a reading can't be from much later); without
-- it, the clock. (the level cap is Enc.PLAYED_MAX_LEVEL, as in EncodePlayed)
function Enc.DecodePlayed(s, refTs)
  if type(s) ~= "string" or #s > 120 or not s:match("^[%w=]+$") then return nil end
  local f = Split(s, "=")
  if f[1] ~= "1" or (#f ~= 5 and #f ~= 9) then return nil end
  local n = {}
  for i = 2, #f do
    n[i] = Num(f[i], MAX_TS)
    if not n[i] then return nil end
  end
  local maxLevel = Enc.PLAYED_MAX_LEVEL
  local total, thisLevel, lvl, at = n[2], n[3], n[4], n[5]
  local ref = refTs or (ns.Now and ns.Now()) or 0
  if total <= 0 or total > MAX_PLAYED or thisLevel < 0 or thisLevel > total
    or lvl < 1 or lvl > maxLevel or at <= 0 or at > ref + AHEAD then
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

-- Decodes a record. Deterministic: depends on nothing but the text (limits
-- that need a time are measured from the record's own ts; the absolute check,
-- ns.TimeOK, is the receiver's). Cooldowns aren't checked against the list
-- FableHub knows here (that would make the result depend on the version):
-- any well-formed entry is kept, and Cooldowns.lua shows only those it knows,
-- for a profession the record has.
function Enc.DecodeRecord(text)
  if type(text) ~= "string" then return nil end
  local f = Split(text, "^")
  local key = f[2]
  if f[1] ~= "1" or not key or key == "" or #key > MAX_KEY or key:find("[=,~:]") then return nil end
  local class = f[4]
  if not class or #class > MAX_CLASS or not class:match("^%u+$") then class = nil end
  local rec = {
    key = key,
    ts = Num(f[3], MAX_TS) or 0,
    class = class,
    level = Num(f[5], 255) or 0,
    profs = {},
  }
  local tree = Num(f[7], 255) or 0
  if tree > 0 then
    rec.spec = { tree = tree, points = Points(f[8]),
                 name = (f[10] and f[10] ~= "" and f[10]:sub(1, MAX_NAME)) or nil }
  end
  if f[11] and f[11] ~= "" then
    rec.outputs = {}
    local n = 0
    for _, pair in ipairs(Split(f[11], ",")) do
      local r, i = pair:match("^(%w+)=(%w+)$")
      r, i = Num(r, MAX_ID), Num(i, MAX_ID)
      if r and i then
        n = n + 1
        if n > MAX_OUTPUTS then break end
        rec.outputs[r] = i
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
    local skillLine = Num(pf[1], MAX_ID)
    if skillLine and skillLine > 0 and nProfs < MAX_PROFS then
      nProfs = nProfs + 1
      local recipes, n = {}, 0
      for _, r in ipairs(Split(pf[5] or "", ".")) do
        local id = Num(r, MAX_ID)
        if id and id > 0 then
          n = n + 1
          if n > MAX_RECIPES then break end
          recipes[id] = true
        end
      end
      rec.profs[skillLine] = {
        rank = Num(pf[2], 1000) or 0,
        max = Num(pf[3], 1000) or 0,
        name = (pf[4] or ""):sub(1, MAX_NAME),
        recipes = recipes,
      }
    end
  end
  -- cooldowns: well-formed entries, in the order sent; one ready further
  -- ahead of the record than the longest cooldown, or longer than that, is
  -- dropped (never clamped: clamping would change what the owner sent)
  if f[12] and f[12] ~= "" then
    local n = 0
    for _, item in ipairs(Split(f[12], ",")) do
      if n >= MAX_CDS then break end
      local id, ready, dur = item:match("^([%w_]+)=(%w+)=(%w+)$")
      if id and #id <= MAX_CD_ID then
        ready, dur = Num(ready, MAX_TS), Num(dur, MAX_CD)
        if ready and dur and ready <= rec.ts + MAX_CD then
          n = n + 1
          rec.cds = rec.cds or {}
          rec.cds[id] = { ready = ready, dur = dur }
        end
      end
    end
    if rec.cds then
      local checked = Num(f[13], MAX_TS) or 0
      rec.cdChecked = checked <= rec.ts + AHEAD and checked or 0
    end
  end
  if f[14] and f[14] ~= "" then rec.played = Enc.DecodePlayed(f[14], rec.ts) end
  return rec
end

-- the canonical text of an encoded record (nil if it doesn't decode)
function Enc.Canon(text)
  local rec = Enc.DecodeRecord(text)
  return rec and Enc.EncodeRecord(rec) or nil
end

------------------------------------------------------------------------
-- Summaries (0.25+): a record without its recipes and crafted items, sent
-- ahead of the whole records at catch-up (Comm.lua "E")
--   batch = "1" { "," <length> ":" <summary> }
-- "1" is the batch format (others are ignored); length is the summary's size
-- in bytes, base36 (summaries are whole records, so they hold every separator
-- and can't be split on one); summary = Enc.EncodeRecord with no recipes and
-- an empty field 11.
------------------------------------------------------------------------
Enc.MAX_SUMMARY = 1024        -- bytes in one summary (bigger ones go as whole records only)
Enc.MAX_SUMMARY_ENTRIES = 64  -- summaries in one batch

function Enc.EncodeSummary(rec)
  local profs = {}
  for skillLine, p in pairs(rec.profs or {}) do
    profs[skillLine] = { name = p.name, rank = p.rank, max = p.max }
  end
  local view = {}
  for k, v in pairs(rec) do view[k] = v end
  view.profs, view.outputs = profs, nil
  return Enc.EncodeRecord(view)
end

-- summaries (already encoded) -> one batch payload
function Enc.EncodeSummaryBatch(entries)
  local out = { "1" }
  for _, e in ipairs(entries) do out[#out + 1] = "," .. Enc.ToB36(#e) .. ":" .. e end
  return table.concat(out)
end

-- does an encoded summary hold recipes or crafted items? (it mustn't)
local function HoldsRecipes(text)
  local f = Split(text, "^")
  if f[11] and f[11] ~= "" then return true end
  for _, ptext in ipairs(Split(f[6] or "", "~")) do
    local r = Split(ptext, ":")[5]
    if r and r ~= "" then return true end
  end
  return false
end

-- batch payload -> list of decoded summary records (every Enc.DecodeRecord
-- limit applies), or nil for another batch format. At the first length that
-- doesn't fit the text the rest of the batch is dropped; a summary that's too
-- big, holds recipes or doesn't decode is skipped.
function Enc.DecodeSummaryBatch(text)
  if type(text) ~= "string" then return nil end
  if text:sub(1, 1) ~= "1" or (#text > 1 and text:sub(2, 2) ~= ",") then return nil end
  local out, pos, n = {}, 2, #text
  while pos <= n and #out < Enc.MAX_SUMMARY_ENTRIES do
    local lenText = text:match("^,(%w%w?%w?):", pos)
    if not lenText then break end
    local len = Enc.FromB36(lenText)
    local first = pos + #lenText + 2
    local last = first + len - 1
    if len <= 0 or last > n then break end
    -- each summary is followed by the next one's "," or the end
    if last < n and text:sub(last + 1, last + 1) ~= "," then break end
    if len <= Enc.MAX_SUMMARY then
      local entry = text:sub(first, last)
      if not HoldsRecipes(entry) then
        local rec = Enc.DecodeRecord(entry)
        if rec then out[#out + 1] = rec end
      end
    end
    pos = last + 1
  end
  return out
end

------------------------------------------------------------------------
-- Character keys in sync messages: the guild's realm (ns.KeyRealm) is left
-- off, as nearly every key has it. A token without "-" gets it back.
-- Tokens can't hold the separators of the messages that carry them.
------------------------------------------------------------------------
local MAX_WKEY = 48

function Enc.WKey(key)
  local realm = ns.KeyRealm and ns.KeyRealm() or ""
  local tail = "-" .. realm
  if realm ~= "" and #key > #tail and key:sub(-#tail) == tail then return key:sub(1, -#tail - 1) end
  return key
end

-- token -> key, or nil if it isn't a valid token
function Enc.FromWKey(tok)
  if type(tok) ~= "string" or tok == "" or #tok > MAX_WKEY or tok:find("[=,~:%^]") then return nil end
  if tok:find("-", 1, true) then return tok end
  local realm = ns.KeyRealm and ns.KeyRealm() or ""
  return realm ~= "" and (tok .. "-" .. realm) or tok
end

------------------------------------------------------------------------
-- Records catch-up (Catchup.lua, 0.26+). Character keys are spread over NB
-- buckets (Enc.Bucket); a bucket's sum is the XOR of the first 32 bits of the
-- checksums of the records in it, sent as 8 hex digits (16 buckets: 128).
--   D  "1^<sid>^<wkey>,<wkey>,<wkey>^<sums>[^<mask>]"   requester -> guild: who answers,
--        our sums; mask (a follow-up, Catchup.lua Plan): 4 hex digits, bit b set = list
--        (or digest) only bucket b; none = every bucket
--   s  "1^<sid>^<sums>^<self>^<lists>^<digests>"  relay -> requester (whisper)
--        self  = "<ts36>=<h16>": the relay's copy of the requester's own record ("" none)
--        lists = "~"-joined "<b>:<entries>" for each bucket whose sums differ (b: one
--                hex digit); entries = Enc.ListText: ","-joined "<wkey>=<ts36>=<h16>", sorted
--        digests = for buckets whose sums differ but aren't listed: "<b><d>" each,
--                no separator, d = the first 64 bits of the SHA-256 of that bucket's
--                ListText, as 12 letters (Enc.EncodeDigest; 16 hex would make an s
--                with five of them two parts)
--   x  "1^<sid>^<xid36>^<wkey>=<minTs36>,..."   requester -> one relay (whisper): send these
--   y  "1^<sid>^<xid36>^<sent36>^<skipped36>"   relay -> requester (whisper): that x is
--        answered: how many records it queued, how many keys of it it didn't send
-- sid: 3 base36 characters, new for each catch-up; xid: that x's number in
-- the catch-up. A malformed message is refused whole.
------------------------------------------------------------------------
Enc.NB = 16
local MAX_D_RELAYS = 3
local MAX_LIST = 1200  -- entries in one s
local MAX_FETCH = 1000 -- keys in one x
local MAX_XID = 46655  -- x numbers in one catch-up (3 base36 digits)
local SUMS_LEN = Enc.NB * 8

-- the bucket of a character key (0 .. NB-1)
function Enc.Bucket(key)
  local h = 0
  for i = 1, #key do h = (h * 31 + key:byte(i)) % MAX_TS end
  return math.floor(h / 65536) % Enc.NB
end

local function Hex8(x) return ("%04x%04x"):format(math.floor(x / 65536), x % 65536) end
local function ValidH16(h) return type(h) == "string" and #h == 16 and h:find("^[0-9a-f]+$") ~= nil end
local function ValidSid(s) return type(s) == "string" and s:find("^[0-9a-z][0-9a-z][0-9a-z]$") ~= nil end
Enc.ValidH16 = ValidH16

-- sums { [0..NB-1] = number } -> 128 hex digits
function Enc.EncodeSums(sums)
  local out = {}
  for b = 0, Enc.NB - 1 do out[b + 1] = Hex8((sums[b] or 0) % MAX_TS) end
  return table.concat(out)
end

function Enc.DecodeSums(text)
  if type(text) ~= "string" or #text ~= SUMS_LEN or not text:find("^[0-9a-f]+$") then return nil end
  local sums = {}
  for b = 0, Enc.NB - 1 do sums[b] = tonumber(text:sub(b * 8 + 1, b * 8 + 8), 16) end
  return sums
end

-- a set of buckets { [b] = true } <-> 4 hex digits (bit b: bucket b)
function Enc.EncodeMask(set)
  local n = 0
  for b = 0, Enc.NB - 1 do if set[b] then n = n + 2 ^ b end end
  return ("%04x"):format(n)
end
function Enc.DecodeMask(text)
  if type(text) ~= "string" or not text:find("^[0-9a-f][0-9a-f][0-9a-f][0-9a-f]$") then return nil end
  local n = tonumber(text, 16)
  if n == 0 then return nil end
  local set = {}
  for b = 0, Enc.NB - 1 do
    if math.floor(n / 2 ^ b) % 2 == 1 then set[b] = true end
  end
  return set
end

-- relays: the keys named to answer (1 to 3); mask: { [b] = true } or nil
function Enc.EncodeD(sid, relays, sums, mask)
  local w = {}
  for i, key in ipairs(relays) do w[i] = Enc.WKey(key) end
  local f = { "1", sid, table.concat(w, ","), Enc.EncodeSums(sums) }
  if mask and next(mask) then f[5] = Enc.EncodeMask(mask) end
  return table.concat(f, "^")
end

-- -> { sid, relays = { key, ... }, sums, mask = { [b] = true } or nil }, or nil
function Enc.DecodeD(payload)
  if type(payload) ~= "string" then return nil end
  local f = Split(payload, "^")
  if (#f ~= 4 and #f ~= 5) or f[1] ~= "1" or not ValidSid(f[2]) then return nil end
  local mask
  if #f == 5 then
    mask = Enc.DecodeMask(f[5])
    if not mask then return nil end
  end
  local toks = Split(f[3], ",")
  if #toks < 1 or #toks > MAX_D_RELAYS then return nil end
  local relays = {}
  for i, tok in ipairs(toks) do
    relays[i] = Enc.FromWKey(tok)
    if not relays[i] then return nil end
  end
  local sums = Enc.DecodeSums(f[4])
  if not sums then return nil end
  return { sid = f[2], relays = relays, sums = sums, mask = mask }
end

-- one bucket's versions { { key, ts, h }, ... } as a relay lists them in an
-- s: the text a list digest (above) is worked out over, the same on both sides
function Enc.ListText(list)
  local e = {}
  for i, it in ipairs(list) do e[i] = Enc.WKey(it.key) .. "=" .. Enc.ToB36(it.ts) .. "=" .. it.h end
  table.sort(e)
  return table.concat(e, ",")
end

-- 16 hex digits (64 bits) <-> 12 letters, 6 bits each (two 32-bit halves of 6)
local D64 = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-_"
local D64_AT = {}
for i = 1, 64 do D64_AT[D64:sub(i, i)] = i - 1 end
function Enc.EncodeDigest(h16)
  local out = {}
  for half = 0, 1 do
    local n = tonumber(h16:sub(half * 8 + 1, half * 8 + 8), 16)
    for i = 6, 1, -1 do
      local d = n % 64
      out[half * 6 + i] = D64:sub(d + 1, d + 1)
      n = math.floor(n / 64)
    end
  end
  return table.concat(out)
end
function Enc.DecodeDigest(text)
  if type(text) ~= "string" or #text ~= 12 then return nil end
  local hex = {}
  for half = 0, 1 do
    local n = 0
    for i = 1, 6 do
      local d = D64_AT[text:sub(half * 6 + i, half * 6 + i)]
      if not d then return nil end
      n = n * 64 + d
    end
    if n >= MAX_TS then return nil end
    hex[half + 1] = Hex8(n)
  end
  return table.concat(hex)
end

-- self: { ts, h } or nil; lists: { [b] = { { key, ts, h }, ... } } for each
-- bucket listed (an empty list: we hold none there); digests: { [b] = h16 }
-- or nil
function Enc.EncodeS(sid, sums, self, lists, digests)
  local parts, dig = {}, {}
  for b = 0, Enc.NB - 1 do
    local list = lists[b]
    if list then
      parts[#parts + 1] = ("%x"):format(b) .. ":" .. Enc.ListText(list)
    elseif digests and digests[b] then
      dig[#dig + 1] = ("%x"):format(b) .. Enc.EncodeDigest(digests[b])
    end
  end
  local selfText = self and (Enc.ToB36(self.ts) .. "=" .. self.h) or ""
  return table.concat({ "1", sid, Enc.EncodeSums(sums), selfText, table.concat(parts, "~"), table.concat(dig) }, "^")
end

-- -> { sid, sums, self = { ts, h } or nil, listed = { [b] = true },
-- lists = { [key] = { ts, h } }, digests = { [b] = h16 } }, or nil
function Enc.DecodeS(payload)
  if type(payload) ~= "string" then return nil end
  local f = Split(payload, "^")
  if #f ~= 6 or f[1] ~= "1" or not ValidSid(f[2]) then return nil end
  local sums = Enc.DecodeSums(f[3])
  if not sums then return nil end
  local out = { sid = f[2], sums = sums, listed = {}, lists = {} }
  if f[4] ~= "" then
    local ts36, h = f[4]:match("^(%w+)=(%w+)$")
    local ts = Num(ts36, MAX_TS)
    if not ts or not ValidH16(h) then return nil end
    out.self = { ts = ts, h = h }
  end
  local n = 0
  for _, chunk in ipairs(Split(f[5], "~")) do
    local bx, rest = chunk:match("^(%x):(.*)$")
    local b = bx and tonumber(bx, 16)
    if not b or out.listed[b] or bx ~= bx:lower() then return nil end
    out.listed[b] = true
    for _, item in ipairs(Split(rest, ",")) do
      local tok, ts36, h = item:match("^([^=]+)=(%w+)=(%w+)$")
      local key = Enc.FromWKey(tok)
      local ts = Num(ts36, MAX_TS)
      n = n + 1
      if not key or not ts or not ValidH16(h) or n > MAX_LIST or out.lists[key] or Enc.Bucket(key) ~= b then return nil end
      out.lists[key] = { ts = ts, h = h }
    end
  end
  -- (a bucket listed and given a digest too, or twice: malformed)
  out.digests = {}
  local dig = f[6]
  if #dig % 13 ~= 0 then return nil end
  for i = 1, #dig, 13 do
    local bx = dig:sub(i, i)
    local b = bx:find("^[0-9a-f]$") and tonumber(bx, 16)
    local h = Enc.DecodeDigest(dig:sub(i + 1, i + 12))
    if not b or not h or out.listed[b] or out.digests[b] then return nil end
    out.digests[b] = h
  end
  return out
end

-- list: { { key, ts }, ... }: send each of these at version ts or newer
function Enc.EncodeX(sid, xid, list)
  local e = {}
  for i, it in ipairs(list) do e[i] = Enc.WKey(it.key) .. "=" .. Enc.ToB36(it.ts) end
  return "1^" .. sid .. "^" .. Enc.ToB36(xid) .. "^" .. table.concat(e, ",")
end

-- -> { sid, xid, list = { { key, ts }, ... } }, or nil
function Enc.DecodeX(payload)
  if type(payload) ~= "string" then return nil end
  local f = Split(payload, "^")
  local xid = f[3] and Num(f[3], MAX_XID)
  if #f ~= 4 or f[1] ~= "1" or not ValidSid(f[2]) or not xid or f[4] == "" then return nil end
  local list, seen = {}, {}
  local items = Split(f[4], ",")
  if #items > MAX_FETCH then return nil end
  for _, item in ipairs(items) do
    local tok, ts36 = item:match("^([^=]+)=(%w+)$")
    local key = Enc.FromWKey(tok)
    local ts = Num(ts36, MAX_TS)
    if not key or not ts or seen[key] then return nil end
    seen[key] = true
    list[#list + 1] = { key = key, ts = ts }
  end
  return { sid = f[2], xid = xid, list = list }
end

function Enc.EncodeY(sid, xid, n, skipped)
  return table.concat({ "1", sid, Enc.ToB36(xid), Enc.ToB36(n), Enc.ToB36(skipped or 0) }, "^")
end

-- -> { sid, xid, n, skipped }, or nil
function Enc.DecodeY(payload)
  if type(payload) ~= "string" then return nil end
  local f = Split(payload, "^")
  if #f ~= 5 or f[1] ~= "1" or not ValidSid(f[2]) then return nil end
  local xid, n, skipped = Num(f[3], MAX_XID), Num(f[4], MAX_FETCH), Num(f[5], MAX_FETCH)
  if not xid or not n or not skipped then return nil end
  return { sid = f[2], xid = xid, n = n, skipped = skipped }
end

------------------------------------------------------------------------
-- Deltas (Comm.lua "T", 0.26+): an owner's change to their own record, as
-- the edits that turn the version everyone holds (base) into the new one.
--   "1^<wkey>^<baseTs36>^<baseH16>^<newTs36>^<newH16>^<op>^<op>..."
-- Ops work on canonical texts (see Canon above); each is an op letter, an
-- argument up to the first "=", then a value:
--   f<n>=<text>   replace field n (4 5 7 8 9 10 12 13 14); empty clears it
--   p<skill>=<rank>:<max>:<name>:<ids>   set a whole profession
--   h<skill>=<rank>:<max>:<name>         its header only
--   x<skill>                             remove a profession
--   a<skill>=<id>.<id>...  /  r<skill>=...   add / remove recipes
--   o=<recipe>=<item>,...  /  q=<recipe>,... add or change / remove crafted items
-- Fields 1-3 (format, key, ts) never change by op; the ts comes from the header.
-- The receiver re-encodes the result and checks it against <newH16>, so a
-- delta can't make anyone hold something the owner didn't send.
------------------------------------------------------------------------
local DELTA_FIELDS = { [4] = true, [5] = true, [7] = true, [8] = true, [9] = true, [10] = true,
                       [12] = true, [13] = true, [14] = true }
local MAX_OPS = 400
Enc.MAX_DELTA_OPS = MAX_OPS

-- canonical text -> fields 1..14 (missing ones ""), professions
-- { [skill36] = { hdr = "rank:max:name", ids = { [id36] = true }, text = ids text } },
-- crafted items { [recipe36] = item36 }
local function Fields(text)
  local f = Split(text, "^")
  for i = 1, 14 do f[i] = f[i] or "" end
  local profs = {}
  for _, ptext in ipairs(Split(f[6], "~")) do
    local pf = Split(ptext, ":")
    if pf[1] and pf[1] ~= "" then
      local ids = {}
      for _, id in ipairs(Split(pf[5] or "", ".")) do if id ~= "" then ids[id] = true end end
      profs[pf[1]] = { hdr = table.concat({ pf[2] or "", pf[3] or "", pf[4] or "" }, ":"), ids = ids, text = pf[5] or "" }
    end
  end
  local outs = {}
  for _, pair in ipairs(Split(f[11], ",")) do
    local r, i = pair:match("^(%w+)=(%w+)$")
    if r then outs[r] = i end
  end
  return f, profs, outs
end

local function ByNumber(a, b)
  local x, y = tonumber(a, 36) or 0, tonumber(b, 36) or 0
  if x ~= y then return x < y end
  return a < b
end

local function SortedKeys(t, cmp)
  local out = {}
  for k in pairs(t) do out[#out + 1] = k end
  table.sort(out, cmp)
  return out
end

-- the ops turning canonical text `base` into canonical text `new` (a list)
function Enc.DiffRecord(base, new)
  local bf, bp, bo = Fields(base)
  local nf, np, no = Fields(new)
  local ops = {}
  for n = 4, 14 do
    if DELTA_FIELDS[n] and bf[n] ~= nf[n] then ops[#ops + 1] = "f" .. n .. "=" .. nf[n] end
  end
  for _, s in ipairs(SortedKeys(np, ByNumber)) do
    local b, c = bp[s], np[s]
    local whole = "p" .. s .. "=" .. c.hdr .. ":" .. c.text
    if not b then
      ops[#ops + 1] = whole
    else
      local small = {}
      if b.hdr ~= c.hdr then small[#small + 1] = "h" .. s .. "=" .. c.hdr end
      local add, rem = {}, {}
      for id in pairs(c.ids) do if not b.ids[id] then add[#add + 1] = id end end
      for id in pairs(b.ids) do if not c.ids[id] then rem[#rem + 1] = id end end
      table.sort(add, ByNumber)
      table.sort(rem, ByNumber)
      if #add > 0 then small[#small + 1] = "a" .. s .. "=" .. table.concat(add, ".") end
      if #rem > 0 then small[#small + 1] = "r" .. s .. "=" .. table.concat(rem, ".") end
      local size = #small
      for _, op in ipairs(small) do size = size + #op end
      -- (setting the whole profession again when that's shorter)
      if size > #whole then
        ops[#ops + 1] = whole
      else
        for _, op in ipairs(small) do ops[#ops + 1] = op end
      end
    end
  end
  for _, s in ipairs(SortedKeys(bp, ByNumber)) do
    if not np[s] then ops[#ops + 1] = "x" .. s end
  end
  local set, rem = {}, {}
  for _, r in ipairs(SortedKeys(no, ByNumber)) do
    if bo[r] ~= no[r] then set[#set + 1] = r .. "=" .. no[r] end
  end
  for _, r in ipairs(SortedKeys(bo, ByNumber)) do
    if not no[r] then rem[#rem + 1] = r end
  end
  if #set > 0 then ops[#ops + 1] = "o=" .. table.concat(set, ",") end
  if #rem > 0 then ops[#ops + 1] = "q=" .. table.concat(rem, ",") end
  return ops
end

-- canonical text `base` with `ops` applied and the ts set to newTs -> text
-- (re-encode it to get the canonical text), or nil if an op is malformed or
-- doesn't fit the base
function Enc.ApplyDelta(base, ops, newTs)
  if type(base) ~= "string" or type(ops) ~= "table" or #ops > MAX_OPS then return nil end
  local f, profs, outs = Fields(base)
  if f[1] ~= "1" then return nil end
  for _, op in ipairs(ops) do
    local c, rest = op:sub(1, 1), op:sub(2)
    local eq = rest:find("=", 1, true)
    local arg, val = rest, nil
    if eq then arg, val = rest:sub(1, eq - 1), rest:sub(eq + 1) end
    if c == "f" then
      local n = tonumber(arg)
      if not n or not DELTA_FIELDS[n] or not val or tostring(n) ~= arg then return nil end
      f[n] = val
    elseif c == "o" or c == "q" then
      if arg ~= "" or not val then return nil end
      for _, item in ipairs(Split(val, ",")) do
        if c == "o" then
          local r, i = item:match("^(%w+)=(%w+)$")
          if not r then return nil end
          outs[r] = i
        else
          if not item:find("^%w+$") then return nil end
          outs[item] = nil
        end
      end
    else
      if not arg:find("^%w+$") then return nil end
      local p = profs[arg]
      if c == "p" then
        local pf = val and Split(val, ":")
        if not pf or #pf ~= 4 then return nil end
        local ids = {}
        for _, id in ipairs(Split(pf[4], ".")) do
          if not id:find("^%w+$") then return nil end
          ids[id] = true
        end
        profs[arg] = { hdr = table.concat({ pf[1], pf[2], pf[3] }, ":"), ids = ids }
      elseif c == "h" then
        local pf = val and Split(val, ":")
        if not p or not pf or #pf ~= 3 then return nil end
        p.hdr = val
      elseif c == "x" then
        if val or not p then return nil end
        profs[arg] = nil
      elseif c == "a" or c == "r" then
        if not p or not val then return nil end
        for _, id in ipairs(Split(val, ".")) do
          if not id:find("^%w+$") then return nil end
          p.ids[id] = (c == "a") or nil
        end
      else
        return nil
      end
    end
  end
  f[3] = Enc.ToB36(newTs)
  local plist = {}
  for _, s in ipairs(SortedKeys(profs, ByNumber)) do
    plist[#plist + 1] = s .. ":" .. profs[s].hdr .. ":" .. table.concat(SortedKeys(profs[s].ids, ByNumber), ".")
  end
  f[6] = table.concat(plist, "~")
  local olist = {}
  for r, i in pairs(outs) do olist[#olist + 1] = r .. "=" .. i end
  table.sort(olist)
  f[11] = table.concat(olist, ",")
  return table.concat(f, "^", 1, 14)
end

-- base, cur = { ts, text (canonical), hash } -> T payload for `key`
function Enc.EncodeDelta(base, cur, key)
  local ops = Enc.DiffRecord(base.text, cur.text)
  if #ops > MAX_OPS then return nil end
  local head = table.concat({ "1", Enc.WKey(key), Enc.ToB36(base.ts), base.hash, Enc.ToB36(cur.ts), cur.hash }, "^")
  if #ops == 0 then return head end
  return head .. "^" .. table.concat(ops, "^")
end

-- T payload -> { key, baseTs, baseHash, newTs, newHash, ops = { ... } }, or nil
-- if any part is malformed
function Enc.DecodeDelta(payload)
  if type(payload) ~= "string" then return nil end
  local f = Split(payload, "^")
  if f[1] ~= "1" or #f < 6 or #f > 6 + MAX_OPS then return nil end
  local key = Enc.FromWKey(f[2])
  local baseTs, newTs = Num(f[3], MAX_TS), Num(f[5], MAX_TS)
  if not key or not baseTs or not newTs then return nil end
  if not (f[4]:find("^[0-9a-f]+$") and #f[4] == 16 and f[6]:find("^[0-9a-f]+$") and #f[6] == 16) then return nil end
  local ops = {}
  for i = 7, #f do
    if f[i] == "" then return nil end
    ops[#ops + 1] = f[i]
  end
  return { key = key, baseTs = baseTs, baseHash = f[4], newTs = newTs, newHash = f[6], ops = ops }
end
