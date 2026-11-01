-- Hash: SHA-256 checksums of records (0.26+), worked out a little at a time.
--
-- Every record version is identified by the first 16 hex digits (64 bits) of
-- the SHA-256 of its canonical text (Encode.lua Enc.Canon): owners announce
-- theirs, and copies passed on by others must match (Comm.lua). Hashing a big
-- record is a few dozen 64-byte blocks, and a catch-up can bring hundreds of
-- records, so the work goes through a queue that does at most BLOCKS_PER_STEP
-- blocks per frame (BLOCKS_PAUSED in combat), and stops sooner once the frame's
-- time budget is used (TIME_BUDGET / TIME_PAUSED ms, see Step).
--
-- Bit operations: WoW's `bit` library (band, bor, bxor, ...) may return
-- signed 32-bit numbers, so every result is brought back to 0 .. 2^32-1 with
-- % 2^32. Only band, bor and bxor are used, with exactly two arguments;
-- shifts and rotations are done with arithmetic (exact for 32-bit values in
-- Lua's doubles). A self-test at load checks the library against known
-- answers; if it's missing or wrong, a slower built-in one is used instead
-- (never an error at load).

local _, ns = ...
local H = {}
ns.Hash = H

local M32 = 4294967296
local floor = math.floor

H.BLOCKS_PER_STEP = 32 -- blocks hashed per frame
H.BLOCKS_PAUSED = 8    -- in combat / an encounter
H.HEX = 16             -- hex digits of a record checksum (64 bits)

------------------------------------------------------------------------
-- Built-in bit operations (only when the game's are missing or wrong):
-- 4 bits at a time from 16 x 16 tables
------------------------------------------------------------------------
local LuaBit
local function MakeLuaBit()
  local AND, XOR = {}, {}
  for a = 0, 15 do
    for b = 0, 15 do
      local x, y, r_and, r_xor, bitv = a, b, 0, 0, 1
      for _ = 1, 4 do
        local p, q = x % 2, y % 2
        if p == 1 and q == 1 then r_and = r_and + bitv end
        if p ~= q then r_xor = r_xor + bitv end
        x, y, bitv = (x - p) / 2, (y - q) / 2, bitv * 2
      end
      AND[a * 16 + b], XOR[a * 16 + b] = r_and, r_xor
    end
  end
  local function op(t)
    return function(x, y)
      x, y = x % M32, y % M32
      local r, m = 0, 1
      for _ = 1, 8 do
        local p, q = x % 16, y % 16
        r = r + t[p * 16 + q] * m
        x, y, m = (x - p) / 16, (y - q) / 16, m * 16
      end
      return r
    end
  end
  local band, bxor = op(AND), op(XOR)
  local function bor(x, y)
    x, y = x % M32, y % M32
    return (x + y - band(x, y)) % M32
  end
  return { band = band, bor = bor, bxor = bxor }
end

local band, bxor

------------------------------------------------------------------------
-- SHA-256
------------------------------------------------------------------------
local K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}
local H0 = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }

-- rotate right by n (0 < n < 32): the two parts don't overlap, so adding them is an OR
local P = {}
for n = 0, 32 do P[n] = 2 ^ n end
local function ror(x, n)
  local lo = x % P[n]
  return (x - lo) / P[n] + lo * P[32 - n]
end
local function shr(x, n) return floor(x / P[n]) end

local W = {} -- message schedule, reused by every block
local function Block(st, at)
  local msg, w = st.msg, W
  for j = 1, 16 do
    local a, b, c, d = msg:byte(at + (j - 1) * 4, at + (j - 1) * 4 + 3)
    w[j] = ((a * 256 + b) * 256 + c) * 256 + d
  end
  for j = 17, 64 do
    local x, y = w[j - 15], w[j - 2]
    local s0 = bxor(bxor(ror(x, 7), ror(x, 18)) % M32, shr(x, 3)) % M32
    local s1 = bxor(bxor(ror(y, 17), ror(y, 19)) % M32, shr(y, 10)) % M32
    w[j] = (w[j - 16] + s0 + w[j - 7] + s1) % M32
  end
  local h = st.h
  local a, b, c, d, e, f, g, hh = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
  for j = 1, 64 do
    local S1 = bxor(bxor(ror(e, 6), ror(e, 11)) % M32, ror(e, 25)) % M32
    -- ch = (e and f) xor (not e and g) = g xor (e and (f xor g))
    local ch = bxor(g, band(e, bxor(f, g) % M32) % M32) % M32
    local t1 = (hh + S1 + ch + K[j] + w[j]) % M32
    local S0 = bxor(bxor(ror(a, 2), ror(a, 13)) % M32, ror(a, 22)) % M32
    -- maj = (a and b) xor (a and c) xor (b and c) = (a and (b xor c)) xor (b and c)
    local maj = bxor(band(a, bxor(b, c) % M32) % M32, band(b, c) % M32) % M32
    local t2 = (S0 + maj) % M32
    hh, g, f, e, d, c, b, a = g, f, e, (d + t1) % M32, c, b, a, (t1 + t2) % M32
  end
  h[1], h[2], h[3], h[4] = (h[1] + a) % M32, (h[2] + b) % M32, (h[3] + c) % M32, (h[4] + d) % M32
  h[5], h[6], h[7], h[8] = (h[5] + e) % M32, (h[6] + f) % M32, (h[7] + g) % M32, (h[8] + hh) % M32
end

-- the 8-byte big-endian bit length
local function LengthBytes(n)
  local bits = n * 8
  local out = {}
  for i = 8, 1, -1 do
    out[i] = string.char(bits % 256)
    bits = floor(bits / 256)
  end
  return table.concat(out)
end

-- a hashing state for `text`: { h = 8 words, msg = padded text, pos, blocks }
function H.Init(text)
  local len = #text
  local zeros = (55 - len) % 64
  local msg = text .. "\128" .. string.rep("\0", zeros) .. LengthBytes(len)
  local h = {}
  for i = 1, 8 do h[i] = H0[i] end
  return { h = h, msg = msg, pos = 1, blocks = #msg / 64 }
end

-- hash up to maxBlocks more blocks; returns how many were done
function H.Process(st, maxBlocks)
  local done = 0
  while done < maxBlocks and st.pos <= #st.msg do
    Block(st, st.pos)
    st.pos = st.pos + 64
    done = done + 1
  end
  return done
end

function H.Done(st) return st.pos > #st.msg end

local function Hex(x) return ("%04x%04x"):format(floor(x / 65536), x % 65536) end

-- the 64 hex digits, once every block is done
function H.Final(st)
  local out = {}
  for i = 1, 8 do out[i] = Hex(st.h[i]) end
  return table.concat(out)
end

function H.SHA256Hex(text)
  local st = H.Init(text)
  H.Process(st, st.blocks)
  return H.Final(st)
end

-- a record checksum, worked out at once (tests and small texts; anything
-- else goes through H.Queue)
function H.HashOf(text) return H.SHA256Hex(text):sub(1, H.HEX) end

-- the first 32 bits of a checksum, as a number
function H.H32(h16) return tonumber(h16:sub(1, 8), 16) end

-- a xor b for 32-bit values (bucket sums, Catchup.lua), through the bit
-- library chosen below
function H.Xor(a, b) return bxor(a, b) % M32 end

------------------------------------------------------------------------
-- Choosing the bit library: the game's, if it gives the right answers
------------------------------------------------------------------------
local VECTORS = {
  { "abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" },
  { "", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" },
}
local function SelfTest()
  local ok, good = pcall(function()
    for _, v in ipairs(VECTORS) do
      if H.SHA256Hex(v[1]) ~= v[2] then return false end
    end
    return true
  end)
  return ok and good
end

local function Use(lib)
  band, bxor = lib.band, lib.bxor
end

H.luaBit = false
local native = type(bit) == "table" and type(bit.band) == "function" and type(bit.bxor) == "function" and bit or nil
if native then Use(native) end
if not native or not SelfTest() then
  LuaBit = MakeLuaBit()
  Use(LuaBit)
  H.luaBit = true
  H.BLOCKS_PER_STEP, H.BLOCKS_PAUSED = 4, 4
  if not SelfTest() then H.broken = true end
end

------------------------------------------------------------------------
-- The job queue: H.Queue(text, cb, priority) calls cb(h16) when the text's
-- checksum is ready, a few frames later. At most BLOCKS_PER_STEP blocks are
-- hashed per frame (BLOCKS_PAUSED in combat or an encounter).
-- Test suite only: FABLEHUB_TEST_SHA256 (outside the game) hashes natively;
-- the block budget is still counted the same way.
------------------------------------------------------------------------
local jobs = {}
local idleWaiters = {}
local stepping = false
H.stats = { steps = 0, blocks = 0, maxStep = 0, jobs = 0 }

-- Checking what others send (records, deltas) can't pile up without limit:
-- each key (see H.Queue) has at most one job waiting, and those jobs are
-- refused while more than MAX_QUEUED bytes wait in all. Jobs for our own data
-- (no key: saved records, our own record) are always taken.
H.MAX_QUEUED = 256 * 1024
local queuedBytes = 0
local byKey = {}  -- [key] = its job waiting
function H.QueuedBytes() return queuedBytes end

local function Paused()
  if InCombatLockdown and InCombatLockdown() then return true end
  if IsEncounterInProgress and IsEncounterInProgress() then return true end
  return false
end

local function NativeSHA()
  if WOW_PROJECT_ID or ns._forceLuaSHA then return nil end
  return type(FABLEHUB_TEST_SHA256) == "function" and FABLEHUB_TEST_SHA256 or nil
end

local Step
local function Schedule()
  if stepping then return end
  stepping = true
  C_Timer.After(0, Step)
end

-- A step also stops once it has taken TIME_BUDGET ms (TIME_PAUSED in combat),
-- measured with debugprofilestop when the game has it: the block cap alone
-- can be too much on a slow computer. At least one block a step.
H.TIME_BUDGET = 2
H.TIME_PAUSED = 1

function Step()
  stepping = false
  local paused = Paused()
  local budget = paused and H.BLOCKS_PAUSED or H.BLOCKS_PER_STEP
  -- (read each step: the test suite puts a clock in after loading)
  local clock = type(debugprofilestop) == "function" and debugprofilestop or nil
  local limit = paused and H.TIME_PAUSED or H.TIME_BUDGET
  local t0 = clock and clock()
  local used = 0
  local fast = NativeSHA()
  while used < budget and jobs[1] and (used == 0 or not clock or clock() - t0 < limit) do
    local job = jobs[1]
    if not job.st then
      if fast then
        job.st = { blocks = floor((#job.text + 8) / 64) + 1, pos = 0, fast = fast }
      else
        job.st = H.Init(job.text)
      end
    end
    local st = job.st
    -- (one block at a time while timing, so the step can stop in time)
    local room = clock and 1 or (budget - used)
    local finished
    if st.msg then
      used = used + H.Process(st, room)
      finished = H.Done(st)
    else
      local n = math.min(room, st.blocks - st.pos)
      st.pos = st.pos + n
      used = used + n
      finished = st.pos >= st.blocks
    end
    if finished then
      table.remove(jobs, 1)
      queuedBytes = queuedBytes - #job.text
      if job.key and byKey[job.key] == job then byKey[job.key] = nil end
      local hex = st.msg and H.Final(st) or st.fast(job.text)
      local ok, err = pcall(job.cb, hex:sub(1, H.HEX))
      if not ok then ns.ReportError(err) end
    end
  end
  local s = H.stats
  s.steps, s.blocks = s.steps + 1, s.blocks + used
  if used > s.maxStep then s.maxStep = used end
  if jobs[1] then
    Schedule()
  else
    local list = idleWaiters
    idleWaiters = {}
    for _, fn in ipairs(list) do
      local ok, err = pcall(fn)
      if not ok then ns.ReportError(err) end
    end
  end
end

-- cb(h16) once the checksum of `text` is ready. priority: ahead of the
-- jobs waiting (our own record: hellos wait for it).
-- key (for checking what others sent, e.g. "in:" .. character key): a newer
-- job with the same key replaces one still waiting (its cb is never called),
-- and the job is refused (returns nil) while the queue holds more than
-- MAX_QUEUED bytes: the caller can't check that now.
function H.Queue(text, cb, priority, key)
  local old = key and byKey[key]
  if key and not priority then
    local after = queuedBytes - (old and #old.text or 0) + #text
    if after > H.MAX_QUEUED then return nil end
  end
  if old then
    for i = #jobs, 1, -1 do
      if jobs[i] == old then
        table.remove(jobs, i)
        queuedBytes = queuedBytes - #old.text
        break
      end
    end
    byKey[key] = nil
  end
  local job = { text = text, cb = cb, key = key }
  if priority then table.insert(jobs, 1, job) else jobs[#jobs + 1] = job end
  if key then byKey[key] = job end
  queuedBytes = queuedBytes + #text
  H.stats.jobs = H.stats.jobs + 1
  Schedule()
  return job
end

function H.Idle() return jobs[1] == nil end
-- a job queued with `key` still waiting
function H.Waiting(key) return byKey[key] ~= nil end
function H.Pending() return #jobs end

-- fn() now if nothing is waiting to be hashed, else once the queue is empty.
-- maxWait (seconds): no longer than that; then fn(true) (timed out: what's
-- hashed so far is all there is), and not again when the queue drains.
function H.WhenIdle(fn, maxWait)
  if not jobs[1] then
    local ok, err = pcall(fn)
    if not ok then ns.ReportError(err) end
    return
  end
  if not maxWait then
    idleWaiters[#idleWaiters + 1] = fn
    return
  end
  local ran = false
  local function Once(timedOut)
    if ran then return end
    ran = true
    local ok, err = pcall(fn, timedOut)
    if not ok then ns.ReportError(err) end
  end
  idleWaiters[#idleWaiters + 1] = function() Once(false) end
  C_Timer.After(maxWait, function() Once(true) end)
end
