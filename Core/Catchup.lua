-- Catchup: the records catch-up (0.26+).
--
-- A member logging in (or typing /fhub sync) compares what they hold with up
-- to three FableHub users online (the relays), and fetches what's missing or
-- wrong, split between them:
--   0. Hellos and replies (Comm.lua H, R) carry the sender's bucket sums
--      (below, over every record it holds, its own included). When every
--      relay picked said the same sums as ours in the last SUMS_FRESH
--      seconds, there's nothing to fetch: no D, the catch-up is done.
--   1. D (guild): the relays we name, and our bucket sums: character keys
--      are spread over 16 buckets (Enc.Bucket), and a bucket's sum is the XOR
--      of the checksums (Hash.lua) of the records we hold in it. In sync, our
--      sums and a relay's are the same.
--   2. s (whisper, from each relay): its sums; the first relay named also
--      lists its version (ts, checksum) of every key in each bucket where its
--      sum differs from ours. The others' lists would mostly repeat the first
--      one's, so each of them sends instead, for those buckets, a digest of
--      the list it would have sent (the checksum of its text): where that's
--      the digest of the first relay's list, it holds exactly those versions,
--      and counts as saying so. Where it isn't (or no digest came), that
--      relay is asked for its own lists of those buckets (a follow-up: a D
--      naming only it, with a bucket mask). (Equal sums alone prove nothing:
--      a relay listing made-up versions can still send its real sums.) An s
--      has room for a few hundred versions: for a new member in a big guild the
--      last buckets aren't listed, and the first relay is asked for them in
--      follow-ups (at most MAX_FOLLOWUPS), the others' digests vouching as
--      before. Each bucket is decided once every relay's version in it is
--      known; the others don't wait for it.
--   3. For every key listed, Decide (below) works out which version to take
--      and its checksum: the owner's own announcement (Comm.lua g.owner) when
--      a relay backs it, else what at least two relays agree on, else a lone
--      relay's newer version. A relay found disagreeing with that at the same
--      version is swapped for another member (at most MAX_SWAPS per
--      catch-up) and not asked again until /reload; never more than one
--      relay over one key (that's a dispute, left to the owner). A relay
--      replaced for being busy or silent after its s keeps its say (its
--      versions still count); where they can't be told (it never listed
--      them), the buckets others listed wait for a relay swapped in, else
--      their keys are left to the owners. A catch-up that asked three never
--      takes a bucket on one relay's word.
--   4. x (whisper, to one relay each): the keys it should send; it answers
--      with the records (F, guild, smallest first, summaries E ahead of long
--      answers), then y. Each record must have the checksum Decide expects
--      (Comm.lua HandleFull asks C.Accepts), or it's refused and the relay
--      replaced; keys a relay didn't send move to another that has them.
--      (The checksum is what's trusted: a record we expect, with exactly
--      that checksum, is taken from anyone in the guild, so members catching
--      up at the same time share each other's records. C.Shared)
-- With fewer than 3 relays to choose from, one relay answers alone (plus the
-- owners' checksums). Relays are picked at random among the members on our
-- FableHub version (a newer one only counts when an officer runs it), so no
-- one member answers everyone.
--
-- Relays answer D at once (the s ahead of the queue), and x like any
-- catch-up answer (they wait while their queue is long or their answer budget
-- is used up; see Comm.lua). Each record goes to one requester at most once
-- per SENT_KEEP, at most MAX_X x are answered per catch-up, and lists go out
-- at most MAX_LISTS times per requester per ANSWER_GAP.

local _, ns = ...
local Enc = ns.Encode
local H = ns.Hash
local CI = ns.CommInternal
local C = {}
ns.Catchup = C

C.START_DELAY = 8    -- seconds after our hello: the replies to it name who's online
C.S_WAIT = 30        -- a relay that hasn't sent its s by then is replaced
C.FETCH_IDLE = 120   -- a relay that sent nothing it owes us for this long is replaced
C.MAX_RELAYS = 3
C.MAX_SWAPS = 3      -- relays replaced per catch-up (silent or wrong)
C.MAX_X = 8          -- x answered per requester's catch-up (relay side)
C.MAX_LISTS = 2      -- catch-ups given lists per requester per ANSWER_GAP (relay side)
C.MAX_FOLLOWUPS = 4  -- follow-up D (a bucket mask: the lists still missing) per catch-up and relay
C.SUMS_FRESH = 60    -- a relay's sums from its hello count for this long (no D when they match ours)
local CATCHUP_MAX = CI.CATCHUP_MAX -- a catch-up ends after this long, finished or not
local PENDING_START = 600 -- nobody to ask: start once someone turns up within this long
local IDLE_TICK = 30
local D_GAP = 20          -- a requester's D answered at most this often
local FOLLOW_GAP = 2      -- relay side: a follow-up at least this long after the requester's last D
local FOLLOW_SEND_GAP = 3 -- requester side: ours this long after the last D to that relay went out
local S_PART_GAP = 20     -- an s still coming in (a part in the last 20 s) is waited for...
local S_MAX_WAIT = 180    -- ... up to this long after our D went out
local DISPUTE_GRACE = S_MAX_WAIT -- while lists are awaited, nothing planned for this long (then the rest is)
local Y_GRACE = 2         -- after a y: a moment for the last records, then their checksums
local SEND_EACH = 1.2     -- about how long each part ahead of ours in our queue takes to go
local X_PARTS = 38        -- an x longer than this is split (receivers take 40 parts)
local MAX_S_PARTS = 78    -- an s longer than this lists fewer buckets (receivers take 80 parts)
local SUMMARY_MIN_PARTS = 12
local MAX_AFTER_PARTS = 80 -- summaries waiting ahead of the queue (ns._afterCap: the test suite trying a smaller one)
local BUSY_SUMMARY_GAP = 10
local SENT_KEEP = 1800    -- relay side: a record goes to one requester at most once this long
local HASH_WAIT = 8       -- sums wait at most this long for checksums still being worked out
local NB = Enc.NB

local sess              -- our catch-up (requester side), nil before the first
local badRelays = {}    -- [key] = true: sent a wrong copy, or a version the majority disproved (until /reload)
local pendingStart      -- GetTime() a catch-up found nobody to ask
-- relay side: [requester] = { sid, at, touched, sent / summed = { [key] = { ts, at } },
-- x, xids = { [xid] = true }, lists, listsFrom; this catch-up (sid): follows (follow-ups
-- answered), listedB = { [b] = true } buckets listed, granted (its lists counted in lists),
-- answering (an s of ours being worked out, not queued yet) }
local relaySess = {}
local lastD = {}        -- relay side: [requester] = GetTime() we last answered their D
local lastBusySummaries = -1e9
local bucketOf = {}     -- [key] = Enc.Bucket(key), for keys we hold
local heardSums = {}    -- [key] = { sums, at = GetTime() }: the sums in their latest hello or reply

local function Bucket(key)
  local b = bucketOf[key]
  if not b then
    b = Enc.Bucket(key)
    bucketOf[key] = b
  end
  return b
end
C.Bucket = Bucket

------------------------------------------------------------------------
-- Bucket sums
------------------------------------------------------------------------
-- fn(key, ts, h) for every record that counts in the sums: whole records with
-- a checksum (never summaries), of roster members once the roster is known,
-- leaving out `exclude`. Our own record counts with the checksum Comm.lua
-- keeps for it (when it's of the version we hold).
local function EachHashed(exclude, fn)
  local g = ns.GuildDB()
  if not g then return end
  local me = ns.MyKey()
  local haveRoster = next(ns.roster) ~= nil
  for key, rec in pairs(g.members) do
    if key ~= exclude and (key == me or not haveRoster or ns.roster[key]) then
      if key == me then
        local own = ns.OwnState()
        if own.hash and own.ts == (rec.ts or 0) then fn(key, own.ts, own.hash) end
      elseif rec.hash then
        fn(key, rec.ts or 0, rec.hash)
      end
    end
  end
end

-- records without a checksum yet (stored by code that doesn't work it out,
-- or still on its way): worked out now, so sums can wait for them (H.WhenIdle)
local hashing = setmetatable({}, { __mode = "k" })
local function EnsureHashes()
  local g = ns.GuildDB()
  if not g or H.broken then return end
  local me = ns.MyKey()
  for key, rec in pairs(g.members) do
    if key ~= me and not rec.hash and not hashing[rec] then
      hashing[rec] = true
      H.Queue(Enc.EncodeRecord(rec), function(h)
        hashing[rec] = nil
        if g.members[key] == rec then rec.hash = h end
      end)
    end
  end
end

local function NewSums()
  local s = {}
  for b = 0, NB - 1 do s[b] = 0 end
  return s
end

-- the sums of every record we hold that counts (ours too): what our hello
-- carries, and what a catch-up compares with its relays' hellos
local function FullSums()
  local sums = NewSums()
  EachHashed(nil, function(key, _, h)
    local b = Bucket(key)
    sums[b] = H.Xor(sums[b], H.H32(h))
  end)
  return sums
end

-- fn(sums text) for a hello or reply of ours (Comm.lua), once the checksums
-- still being worked out are done; fn(nil) when checksums can't be worked out
-- here (Hash.lua H.broken), or are still being worked out after HASH_WAIT
-- seconds (a hello can't wait for hundreds of them: unknown sums, a D then)
function C.HelloSums(fn)
  if H.broken or not ns.GuildDB() then return fn(nil) end
  EnsureHashes()
  H.WhenIdle(function(timedOut)
    if timedOut then return fn(nil) end
    fn(Enc.EncodeSums(FullSums()))
  end, HASH_WAIT)
end

-- a hello or reply from `sender` (their exact name, our protocol: Comm.lua)
-- with their sums; missing or malformed: unknown
function C.NoteHelloSums(sender, text)
  local sums = Enc.DecodeSums(text)
  heardSums[sender] = sums and { sums = sums, at = GetTime() } or nil
end
function C.HeardSums(key) return heardSums[key] end -- (tests)

-- r's sums from its latest hello, recent, and the same as `mine`?
local function SumsMatch(r, mine, now)
  local hs = heardSums[r]
  if not hs or now - hs.at > C.SUMS_FRESH then return false end
  for b = 0, NB - 1 do
    if hs.sums[b] ~= mine[b] then return false end
  end
  return true
end

-- our versions { [key] = { ts, h } } (leaving out our own record) and their sums
local function MyEntries()
  local list, sums = {}, NewSums()
  EachHashed(ns.MyKey(), function(key, ts, h)
    list[key] = { ts = ts, h = h }
    local b = Bucket(key)
    sums[b] = H.Xor(sums[b], H.H32(h))
  end)
  return list, sums
end

------------------------------------------------------------------------
-- Who may answer: FableHub users online on our protocol whose hello came from
-- their exact name, in the roster, not caught out this session. Newest
-- version first; within a version in random order (each catch-up its own),
-- so the members on the newest version share the work and nobody can make
-- themselves the one every catch-up asks. A version newer than ours counts
-- as ours unless an officer runs it: versions are self-reported, and two
-- members claiming a made-up one would otherwise be asked by everyone.
-- (ns._fixedRelayOrder: the test suite keeps them in name order.)
------------------------------------------------------------------------
local function Candidates()
  local me = ns.MyKey()
  local haveRoster = next(ns.roster) ~= nil
  local list = {}
  for key in pairs(ns.present) do
    local proto, exact = ns.HelloInfo(key)
    if key ~= me and proto == ns.PROTOCOL and exact and not ns.LooseSender(key) and ns.IsOnline(key)
      and (not haveRoster or ns.roster[key]) and not badRelays[key] then
      list[#list + 1] = key
    end
  end
  local ver = {}
  local mine = ns.VersionNumber(ns.VERSION)
  for _, key in ipairs(list) do
    local v = CI.TrustedVersion(key)
    if v > mine and not ns.RealOfficer(key) then v = mine end
    ver[key] = v
  end
  table.sort(list, function(a, b)
    if ver[a] ~= ver[b] then return ver[a] > ver[b] end
    return a < b
  end)
  if not ns._fixedRelayOrder then
    local i = 1
    while i <= #list do
      local j = i
      while j < #list and ver[list[j + 1]] == ver[list[i]] do j = j + 1 end
      for k = j, i + 1, -1 do
        local m = math.random(i, k)
        list[k], list[m] = list[m], list[k]
      end
      i = j + 1
    end
  end
  return list
end
C.Candidates = Candidates

------------------------------------------------------------------------
-- Decide: which version of `key` to take, from whom, and who is wrong about
-- it. Pure (the unit tests run it over a table of cases).
--   mine      { ts, hash } of our copy, or nil
--   owner     { ts, h }: the owner's own announcement (g.owner), or nil
--   ownerLive the owner is online and we heard their hello this session
--   votes     { { r, ts, h, implicit }, ... }: each answering relay's version
--             (implicit: its bucket sum matched ours, so it holds what we do)
--   k         how many relays answered
-- Returns { fetch = ts or nil, expect = h, from = { relays }, liars = { relays },
-- contested = true when nothing can tell which version is right: then
-- nothing is taken, nobody is wrong, and the owner is asked (contestTs, and
-- wantHash: the owner's checksum, when known) }.
-- The owner's word alone never makes a relay wrong: their checksum only
-- counts when at least one relay (listing it) holds that version. (Else a
-- member could announce a made-up checksum for their own record and get
-- every relay holding the real one swapped out.) Nor does the owner saying
-- they have an older version than the relays' (online, their hello): the
-- relays' newer one isn't taken, and nobody is wrong (a dispute; the owner
-- may be lying to get relays swapped). A relay that is only behind (an older
-- version) is never wrong, and one key makes at most one relay wrong: two or
-- more against one version is a dispute.
------------------------------------------------------------------------
function C.Decide(key, mine, owner, ownerLive, votes, k)
  local out = { liars = {}, from = {} }
  local T
  for _, v in ipairs(votes) do if not T or v.ts > T then T = v.ts end end
  if not T then return out end
  -- a relay listing exactly that version
  local function Backed(ts, h)
    for _, v in ipairs(votes) do
      if not v.implicit and v.ts == ts and v.h == h then return true end
    end
    return false
  end
  local function Contested(ts, h)
    out.contested, out.contestTs, out.wantHash = true, ts, h
    return out
  end
  local liars, liar = {}, {}
  local function Liar(r)
    if not liar[r] then liar[r] = true; liars[#liars + 1] = r end
  end
  -- newer than the owner, who is online and told us their version: a
  -- dispute, even when a relay holds the owner's version (the owner asked)
  if ownerLive and owner and owner.ts < T then return Contested(owner.ts, owner.h) end
  local atT = {}
  for _, v in ipairs(votes) do if v.ts == T then atT[#atT + 1] = v end end
  local expect, sure
  if owner and owner.ts == T then
    if not Backed(T, owner.h) then return Contested(T, owner.h) end
    expect, sure = owner.h, true
  elseif k >= 2 then
    local count = {}
    for _, v in ipairs(atT) do count[v.h] = (count[v.h] or 0) + 1 end
    for h, n in pairs(count) do
      if n >= 2 and (not expect or n > count[expect] or (n == count[expect] and h < expect)) then expect = h end
    end
    if expect then
      sure = true
    elseif #atT == 1 then
      expect = atT[1].h -- one relay is newer: the others are behind
    else
      return Contested(T, nil)
    end
  else
    expect = atT[1].h
  end
  if sure then
    for _, v in ipairs(atT) do if v.h ~= expect and not v.implicit then Liar(v.r) end end
  end
  if #liars >= 2 then return Contested(T, owner and owner.ts == T and owner.h or nil) end
  out.liars = liars
  out.expect = expect
  if not mine or (mine.ts or 0) < T or ((mine.ts or 0) == T and mine.hash ~= expect) then out.fetch = T end
  for _, v in ipairs(atT) do
    if v.h == expect and not v.implicit and not liar[v.r] then out.from[#out.from + 1] = v.r end
  end
  return out
end

------------------------------------------------------------------------
-- Requester side. sess = {
--   sid, at, phase = "sums" | "fetch" | "done",
--   relays = { key, ... } current relays in order, relaySet = { [key] = true },
--   named = { [key] = true } asked by D, dropped = { [key] = true } replaced,
--   mineAt = { [r] = { list, sums } }: our versions and sums when we asked r,
--   sums / lists / listed = { [r] = ... } their s, listedAny = { [r] = true }
--   (its s listed something), digests = { [r] = { [b] = h16 } } its list
--   digests, listDigest = { [r] = { [b] = h16 } } the digests of the lists
--   r sent (worked out here: digesting = how many still being worked out),
--   follows = { [r] = n } follow-up D sent to r, askMask = { [r] = { [b] = true } }
--   the buckets of the one we wait for (awaitLists = { [r] = true } then),
--   mineNext = { [r] = { list, sums } } our versions when we sent it,
--   noLists = { [r] = true } r answered one without lists (or not at all),
--   undecided: buckets wait for lists (Plan), replan: Plan again,
--   dSeq, lastD = { [r] = n }: the number of the latest D naming r,
--   expect = { [key] = { ts, h, from, alts } } records on their way,
--   assigned = { [r] = { [key] = true } }, nAssigned = { [r] = n },
--   xOut = { [r] = { [xid] = { xid, keys, payload, id, due, sent, resent } } }
--   our x not answered yet (due: when it went out, or about when it will),
--   xSeq, xQueued = { [r] = n }, progressAt = { [r] = GetTime() of its last s,
--   y or record for us }, anyAt = { [r] = GetTime() of its last part of an s
--   whispered to us }, dSentAt = { [r] = GetTime() the latest D naming r went out },
--   featureRelay (answers our feature catch-ups: given fewer records),
--   contested = { [key] = true } owner asked, swaps,
--   startK: how many relays the first D named, struck: how many that
--   answered were caught out,
--   kept = { r, ... } relays replaced (busy or silent) after their s: their
--   versions still count (Voters); keptBefore = { [r] = { [relay] = true } }
--   the relays in the set then (the others were swapped in after),
--   contestedB = { [b] = true } buckets given up on (their keys: the owners),
--   disputing = { [r] = true } relays whose lists are awaited where another
--   listed (PlanOnce): not given keys meanwhile,
--   inSync: done at the start, the relays' hello sums matched ours }
------------------------------------------------------------------------
local Plan, Replace, CheckDone

function C.Active()
  return sess ~= nil and sess.phase ~= "done" and GetTime() - sess.at <= CATCHUP_MAX
end
function C.Relays() return sess and sess.relaySet or {} end
-- not to be taken records from outside a catch-up either: caught out this
-- session, or replaced in our latest catch-up (its late answers are refused)
function C.IsBad(key) return badRelays[key] == true or (sess ~= nil and sess.dropped[key] == true) end
function C.IsLiar(key) return badRelays[key] == true end
function C.Session() return sess end -- (tests and /fhub bug)

local function Finish(s, why)
  if s.phase == "done" then return end
  s.phase = "done"
  ns.Debug(("records catch-up done (%s)"):format(why or "complete"))
end

-- the checksum a passed-on copy of `key` version `ts` must have: what this
-- catch-up decided (Comm.lua ExpectedHash, after the owner's own)
function C.Expect(key, ts)
  local s = sess
  if not s or s.phase == "done" then return nil end
  local e = s.expect[key]
  if e and e.ts == ts then return e.h end
  return nil
end

-- Comm.lua HandleFull / HandleSummary: is a copy of `key` version `ts` from
-- `sender` (not an officer) one we take? Only while our catch-up runs, from
-- one of its relays, for a key it expects at exactly that version. Returns
-- the checksum the record must have (nil: refused).
function C.Accepts(sender, key, ts)
  if not C.Active() or not sess.relaySet[sender] then return nil end
  local e = sess.expect[key]
  if not e or e.ts ~= ts then return nil end
  return e.h
end

-- Comm.lua HandleFull: a whole record (never a summary) of a key our
-- catch-up expects, at exactly that version, from a guild member who isn't
-- one of our relays (their exact name): taken when its checksum is the one
-- expected (someone else's catch-up answer, heard on the guild channel).
-- Returns that checksum (nil: refused). A wrong one is just dropped: only
-- our relays answer for what they send us.
function C.Shared(key, ts)
  if not C.Active() then return nil end
  local e = sess.expect[key]
  if not e or e.ts ~= ts then return nil end
  return e.h
end

local function Unassign(s, key)
  local e = s.expect[key]
  if e and e.from and s.assigned[e.from] and s.assigned[e.from][key] then
    s.assigned[e.from][key] = nil
    s.nAssigned[e.from] = s.nAssigned[e.from] - 1
  end
  if e then e.from = nil end
end

local function Clear(s, key)
  Unassign(s, key)
  s.expect[key] = nil
end

-- we hold that version (or newer) now
local function Satisfied(key, e)
  local g = ns.GuildDB()
  local m = g and g.members[key]
  if not m then return false end
  local ts = m.ts or 0
  return ts > e.ts or (ts == e.ts and (m.hash == nil or m.hash == e.h))
end

local function Live(s, r)
  return s.relaySet[r] and not s.dropped[r] and not badRelays[r] and (s.xQueued[r] or 0) < C.MAX_X
end

-- how busy a relay already is for us: its keys, and (a fraction, so it only
-- breaks ties) whether it sent a long s with lists or answers our feature
-- catch-ups too
local function Load(s, r)
  local w = s.nAssigned[r] or 0
  if s.listedAny[r] then w = w + 0.5 end
  if r == s.featureRelay then w = w + 0.25 end
  return w
end

-- give `key` to the least busy relay among `from` (ties: relay order), not
-- one in `avoid` (those stay its next ones, Reassign)
local function Assign(s, key, ts, h, from, newX, avoid)
  Unassign(s, key)
  local cands = {}
  for _, r in ipairs(from) do if Live(s, r) then cands[#cands + 1] = r end end
  local e = { ts = ts, h = h, alts = {} }
  s.expect[key] = e
  if #cands == 0 then return end -- (waits for a relay swapped in)
  local best
  for _, r in ipairs(cands) do
    if not (avoid and avoid[r]) and (not best or Load(s, r) < Load(s, best)) then best = r end
  end
  for _, r in ipairs(cands) do if r ~= best then e.alts[#e.alts + 1] = r end end
  if not best then return end
  e.from = best
  s.assigned[best][key] = true
  s.nAssigned[best] = s.nAssigned[best] + 1
  newX[best] = newX[best] or {}
  table.insert(newX[best], { key = key, ts = ts })
end

-- does r still owe us its s (or the lists we asked it for)?
local function NeedsS(s, r)
  return not s.sums[r] or s.awaitLists[r] == true
end

-- someone still to answer our D (a relay swapped in, or asked for its lists)?
local function AwaitingS(s)
  for _, r in ipairs(s.relays) do if NeedsS(s, r) then return true end end
  return false
end

-- ask the owner, if online (Comm.lua Want: throttled per key)
local function WantOwner(key, ts, h, force)
  if ns.IsOnline(key) then CI.Want(key, ts, h, force) end
end

-- `key`'s relay is gone or didn't send it: the next one that has it, else a
-- relay swapped in (Plan, once it answers), else the owner. (Not one whose
-- lists are awaited where it may disagree, s.disputing: Plan, once they're
-- here)
local function Reassign(s, key, newX)
  local e = s.expect[key]
  if not e then return end
  Unassign(s, key)
  local alts = e.alts
  e.alts = {}
  -- (the least busy of them)
  local nxt
  for _, r in ipairs(alts) do
    if Live(s, r) and not s.disputing[r] and (not nxt or Load(s, r) < Load(s, nxt)) then nxt = r end
  end
  for _, r in ipairs(alts) do
    if r ~= nxt and Live(s, r) then e.alts[#e.alts + 1] = r end
  end
  if nxt then
    e.from = nxt
    s.assigned[nxt][key] = true
    s.nAssigned[nxt] = s.nAssigned[nxt] + 1
    newX[nxt] = newX[nxt] or {}
    table.insert(newX[nxt], { key = key, ts = e.ts })
  elseif #e.alts > 0 then
    s.undecided = true -- (Plan gives it out once their lists are here)
  elseif not AwaitingS(s) then
    s.expect[key] = nil
    WantOwner(key, e.ts, e.h)
  end
end

-- keys of x (to r) still assigned to r: to another relay, not back to r
local function Reroute(s, r, keys, newX)
  for _, key in ipairs(keys) do
    local e = s.expect[key]
    if e and e.from == r then
      if Satisfied(key, e) then
        Clear(s, key)
      else
        for i = #e.alts, 1, -1 do if e.alts[i] == r then table.remove(e.alts, i) end end
        Reassign(s, key, newX)
      end
    end
  end
end

local function XSent(s, x)
  return function()
    if sess ~= s then return end
    x.sent, x.due = true, GetTime()
  end
end

local function QueueX(s, r, x)
  x.sent = false
  x.id = ns.QueueMsg("x", x.payload, { target = r, dig = "D", onSent = XSent(s, x) })
  -- (when it should be out, about: what's ahead of it in our queue)
  x.due = GetTime() + SEND_EACH * ns.QueueLength()
end

-- an x of ours that never reached r (dropped from our queue, or the whisper
-- failed): sent again once, then its keys go to other relays
local function RetryX(s, r, x, newX)
  if not x.resent then
    x.resent, x.retriedAt = true, GetTime()
    CI.Cancel(x.id)
    QueueX(s, r, x)
    return
  end
  s.xOut[r][x.xid] = nil
  Reroute(s, r, x.keys, newX)
end

-- newX: { [r] = { { key, ts }, ... } }, in relay order. An x longer than
-- X_PARTS parts is split.
local function SendX(s, newX)
  local maxLen = X_PARTS * CI.CHUNK - 16
  for _, r in ipairs(s.relays) do
    local list = newX[r]
    if list and s.relaySet[r] then
      local i = 1
      while i <= #list do
        local part, keys, size = {}, {}, 0
        while i <= #list do
          local it = list[i]
          local add = #Enc.WKey(it.key) + #Enc.ToB36(it.ts) + 2
          if #part > 0 and size + add > maxLen then break end
          part[#part + 1], keys[#keys + 1] = it, it.key
          size = size + add
          i = i + 1
        end
        s.xSeq = s.xSeq + 1
        local x = { xid = s.xSeq, keys = keys, payload = Enc.EncodeX(s.sid, s.xSeq, part) }
        s.xOut[r] = s.xOut[r] or {}
        s.xOut[r][x.xid] = x
        s.xQueued[r] = (s.xQueued[r] or 0) + 1
        QueueX(s, r, x)
      end
    end
  end
end

-- the D naming `list` (the first, or a relay swapped in), or a follow-up
-- (`mask`: the buckets one relay we asked before is to list): our sums as
-- they are now. Its S_WAIT starts once it went out; a backstop in case it
-- never does (dropped from our queue).
local SWaitCheck
local function SendD(s, list, mask)
  local mine, sums = MyEntries()
  s.dSeq = s.dSeq + 1
  local seq = s.dSeq
  for _, r in ipairs(list) do
    s.lastD[r] = seq
    if not s.relaySet[r] then
      s.relays[#s.relays + 1] = r
      s.relaySet[r] = true
    end
    s.named[r] = true
    if mask then
      s.follows[r] = (s.follows[r] or 0) + 1
      s.askMask[r], s.awaitLists[r] = mask, true
      s.mineNext[r] = { list = mine, sums = sums }
    else
      s.mineAt[r] = { list = mine, sums = sums }
    end
    s.assigned[r] = s.assigned[r] or {}
    s.nAssigned[r] = s.nAssigned[r] or 0
  end
  local sent = false
  local id = ns.QueueMsg("D", Enc.EncodeD(s.sid, list, sums, mask), {
    onSent = function()
      sent = true
      local at = GetTime()
      for _, r in ipairs(list) do s.dSentAt[r] = at end
      C_Timer.After(C.S_WAIT, function() SWaitCheck(s, list, at, seq) end)
    end,
  })
  local function Backstop()
    if sent or sess ~= s or s.phase == "done" then return end
    if CI.Waiting(id) or CI.Paused() then
      C_Timer.After(10, Backstop)
      return
    end
    SWaitCheck(s, list, nil, seq)
  end
  C_Timer.After(C.S_WAIT + SEND_EACH * ns.QueueLength(), Backstop)
end

-- S_WAIT after a D: relays named in it that haven't answered are replaced
-- (one whose long s is still coming in gets more time, up to S_MAX_WAIT
-- after our D); one we only asked for its lists isn't asked again (Plan:
-- another member instead, if the buckets still can't be told). Only for the
-- latest D naming each (seq): a follow-up has an S_WAIT of its own.
function SWaitCheck(s, list, sentAt, seq)
  if sess ~= s or s.phase == "done" then return end
  -- (in combat our own messages wait too: try again a little later)
  if CI.Paused() then
    C_Timer.After(10, function() SWaitCheck(s, list, sentAt, seq) end)
    return
  end
  local now = GetTime()
  local still = {}
  for _, r in ipairs(list) do
    if s.relaySet[r] and s.lastD[r] == seq and NeedsS(s, r) then
      -- (only parts of an s it whispered us, or for a follow-up, whose s
      -- waits behind the records it's sending us, what it owed us arriving:
      -- records, summaries, y (Progress). Anything else it sends, on any
      -- channel, could keep us waiting for nothing)
      local last = s.anyAt[r]
      if s.sums[r] and (s.progressAt[r] or -1e9) > (last or -1e9) then last = s.progressAt[r] end
      if last and now - last < S_PART_GAP and sentAt and now - sentAt < S_MAX_WAIT then
        still[#still + 1] = r
      elseif s.sums[r] then
        s.awaitLists[r], s.askMask[r], s.mineNext[r] = nil, nil, nil
        s.noLists[r] = true
      else
        Replace(r, "silent")
      end
    end
  end
  if #still > 0 then
    C_Timer.After(10, function() SWaitCheck(s, still, sentAt, seq) end)
    return
  end
  Plan()
end

-- r is replaced: "silent" (no answer), "busy" (no lists when asked) or
-- "liar" (also not asked again until /reload). Another candidate takes its
-- place (MAX_SWAPS per catch-up), its keys go to the other relays that have
-- them. One that answered and isn't a liar keeps its say (s.kept): what it
-- told us still counts in Decide, and where it can't be told, the buckets
-- others listed wait for the relay swapped in (PlanOnce, Held).
function Replace(r, why)
  local s = sess
  if not s or not s.relaySet[r] then return end
  s.relaySet[r] = nil
  for i = #s.relays, 1, -1 do if s.relays[i] == r then table.remove(s.relays, i) end end
  s.dropped[r] = true
  s.xOut[r] = nil
  s.awaitLists[r], s.askMask[r], s.mineNext[r] = nil, nil, nil
  if why == "liar" then
    badRelays[r] = true
    if s.sums[r] then s.struck = s.struck + 1 end
  elseif s.sums[r] then
    local before = { [r] = true }
    for _, q in ipairs(s.relays) do if s.sums[q] then before[q] = true end end
    s.kept[#s.kept + 1] = r
    s.keptBefore[r] = before
  end
  ns.Debug(("catch-up relay %s replaced (%s)"):format(r, why))
  if s.swaps < C.MAX_SWAPS then
    local nxt
    for _, c in ipairs(Candidates()) do
      if not nxt and not s.relaySet[c] and not s.dropped[c] then nxt = c end
    end
    if nxt then
      s.swaps = s.swaps + 1
      SendD(s, { nxt })
    end
  end
  local keys = {}
  for key in pairs(s.assigned[r] or {}) do keys[#keys + 1] = key end
  table.sort(keys)
  local newX = {}
  for _, key in ipairs(keys) do Reassign(s, key, newX) end
  SendX(s, newX)
  -- (what it was asked to list, or vouched for, is worked out again)
  if s.planning then
    s.replan = true
  elseif s.undecided then
    Plan()
  end
  CheckDone(s)
end

-- the relays that answered, in order
local function Answered(s)
  local out = {}
  for _, r in ipairs(s.relays) do if s.sums[r] then out[#out + 1] = r end end
  return out
end

-- whose versions count: the relays that answered, then those replaced
-- (busy or silent) after answering, unless caught out since or gone from
-- the guild
local function Voters(s, answered)
  local out = {}
  for i = 1, #answered do out[i] = answered[i] end
  local haveRoster = next(ns.roster) ~= nil
  for _, r in ipairs(s.kept) do
    if not badRelays[r] and (not haveRoster or ns.roster[r]) then out[#out + 1] = r end
  end
  return out
end

-- another answered relay that listed bucket b, whose list's digest (worked
-- out here) is the one r sent for b: r holds exactly what it listed there.
-- (Not equal sums: those can't tell a made-up list from the real one)
local function Vouched(s, answered, r, b)
  local d = s.digests[r] and s.digests[r][b]
  if not d then return nil end
  for _, q in ipairs(answered) do
    if q ~= r and s.listed[q][b] and s.listDigest[q] and s.listDigest[q][b] == d then return q end
  end
  return nil
end

-- each answered relay's version of `key`: listed in its s (or in another's
-- whose digest it sent), or (its sum of that bucket matched ours when it
-- answered) ours, implicitly
local function VotesFor(s, answered, key)
  local b = Bucket(key)
  local votes = {}
  for _, r in ipairs(answered) do
    local e, implicit
    if s.listed[r][b] then
      e = s.lists[r][key]
    elseif s.sums[r][b] == s.mineAt[r].sums[b] then
      e, implicit = s.mineAt[r].list[key], true
    else
      local q = Vouched(s, answered, r, b)
      e = q and s.lists[q][key]
    end
    if e then votes[#votes + 1] = { r = r, ts = e.ts, h = e.h, implicit = implicit } end
  end
  return votes
end

-- does r hold something we can't tell in bucket b (its sum differs from
-- ours, and it didn't list it, nor sent the digest of another's list of it)?
local function Unknown(s, answered, r, b)
  return not s.listed[r][b] and s.sums[r][b] ~= s.mineAt[r].sums[b] and not Vouched(s, answered, r, b)
end

-- does r hold exactly what the others listed in bucket b (it listed it the
-- same as every other relay listing it, or sent the digest of one's list)?
local function Agrees(s, voters, r, b)
  if not s.listed[r][b] then return Vouched(s, voters, r, b) ~= nil end
  local d = s.listDigest[r] and s.listDigest[r][b]
  for _, q in ipairs(voters) do
    if q ~= r and s.listed[q][b] and not (s.listDigest[q] and s.listDigest[q][b] == d) then return false end
  end
  return true
end

-- bucket b, listed by someone, whose relays all can be told: decided now
-- (nil), "wait" or "contest" (its keys left to the owners).
--  * A relay replaced after answering, not holding what was listed there:
--    its objection mustn't go with it. The bucket waits for a relay that
--    answered after it was replaced (swapped in) to be told there; with
--    nobody left to answer, its keys are contested where its versions
--    can't be told (where they can, they still count: Decide).
--  * A catch-up that asked several relays never decides a bucket on the
--    word of one (the others replaced or silent): it waits for one swapped
--    in, else contests it. (Relays caught out count among the others:
--    whoever is left is what the majority against them agreed with)
local function Held(s, answered, voters, b)
  for _, r in ipairs(voters) do
    local before = s.keptBefore[r]
    if before and not s.relaySet[r] and not Agrees(s, voters, r, b) then
      local told, pending = false, false
      for _, q in ipairs(s.relays) do
        if not before[q] then
          if s.sums[q] and not Unknown(s, voters, q, b) then told = true else pending = true end
        end
      end
      if not told then
        if pending then return "wait" end
        if Unknown(s, voters, r, b) then return "contest" end
      end
    end
  end
  if s.startK >= 2 then
    local n = 0
    for _, r in ipairs(voters) do if not Unknown(s, voters, r, b) then n = n + 1 end end
    if n + s.struck < 2 then return AwaitingS(s) and "wait" or "contest" end
  end
  return nil
end

-- may r be sent a follow-up D: it answered the last one with lists, and
-- hasn't had MAX_FOLLOWUPS of them yet
local function CanAsk(s, r)
  return not s.noLists[r] and (s.follows[r] or 0) < C.MAX_FOLLOWUPS
end

-- a relay named in a D (not a follow-up) that hasn't sent its s yet
local function AwaitingFirst(s)
  for _, r in ipairs(s.relays) do if not s.sums[r] then return true end end
  return false
end

local function OwnerOf(key)
  local ts, h = ns.OwnerHash(key)
  return ts and { ts = ts, h = h } or nil
end

-- every key listed in bucket b (by a relay whose versions count): left to
-- its owner, ours kept (Held said "contest"). Keys already on their way
-- from a relay still in the set were decided while more could be told, and
-- stay as they are.
local function ContestBucket(s, g, voters, b)
  s.contestedB[b] = true
  local me = ns.MyKey()
  local haveRoster = next(ns.roster) ~= nil
  local top = {}
  for _, r in ipairs(voters) do
    if s.listed[r][b] then
      for key, e in pairs(s.lists[r]) do
        if Bucket(key) == b and key ~= me and (not haveRoster or ns.roster[key]) and (not top[key] or e.ts > top[key]) then
          top[key] = e.ts
        end
      end
    end
  end
  local keys = {}
  for key in pairs(top) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local e = s.expect[key]
    if not (e and e.from and s.relaySet[e.from]) then
      if e then Clear(s, key) end
      if not s.contested[key] then
        s.contested[key] = true
        local m = g.members[key]
        local ts = top[key]
        if not (m and (m.ts or 0) > ts) then
          local owner = OwnerOf(key)
          WantOwner(key, ts, owner and owner.ts == ts and owner.h or nil, true)
        end
      end
    end
  end
  ns.Debug(("records catch-up: bucket %d left to the owners"):format(b))
end

-- One planning pass (Plan): asks for the lists still missing, then decides
-- the buckets every relay's versions in are known (the others wait).
local function PlanOnce(s, g)
  local answered = Answered(s)
  local voters = Voters(s, answered)
  -- the buckets that can't be told yet, and who's asked to list what:
  -- a bucket another relay listed, by each relay that can't be told there
  -- (its own lists); one nobody listed (no room in their s), by one relay
  -- (the first that can be asked: the others' digests then vouch)
  local blocked, asks, stuck, contest = {}, {}, {}, {}
  -- [r] = true: can't be told in a bucket another listed (it may disagree)
  local disputing = {}
  local firstPending = AwaitingFirst(s)
  s.disputing = disputing
  for b = 0, NB - 1 do
    if not s.contestedB[b] then
      local unk, anyListed, covered = {}, false, false
      for _, r in ipairs(voters) do if s.listed[r][b] then anyListed = true end end
      for _, r in ipairs(answered) do
        if s.askMask[r] and s.askMask[r][b] then covered = true end
        if Unknown(s, voters, r, b) then unk[#unk + 1] = r end
      end
      if #unk > 0 then
        blocked[b] = true
        if anyListed then
          for _, r in ipairs(unk) do
            disputing[r] = true
            if not s.awaitLists[r] then
              if CanAsk(s, r) then
                asks[r] = asks[r] or {}
                asks[r][b] = true
              else
                stuck[r] = true
              end
            end
          end
        elseif not covered and not firstPending then
          -- (one already being asked for others first, then relay order)
          local pick, waiting
          for _, r in ipairs(unk) do
            if s.awaitLists[r] then
              waiting = true
            elseif CanAsk(s, r) and (not pick or (asks[r] and not asks[pick])) then
              pick = r
            end
          end
          if pick then
            asks[pick] = asks[pick] or {}
            asks[pick][b] = true
          elseif not waiting then
            stuck[unk[1]] = true
          end
        end
      elseif anyListed then
        local held = Held(s, answered, voters, b)
        if held == "wait" then
          blocked[b] = true
        elseif held == "contest" then
          contest[b] = true
        end
      end
    end
  end
  -- asked, and no lists came (its queue is long, or it answered too many
  -- catch-ups lately), or asked MAX_FOLLOWUPS times: another member instead,
  -- no strike (and this is worked out again without it)
  if next(stuck) then
    for _, r in ipairs(answered) do if stuck[r] then Replace(r, "busy") end end
    s.replan = true
    return
  end
  -- (a follow-up goes FOLLOW_SEND_GAP after the last D to that relay at
  -- the soonest: relays ignore one sooner. Planned again then)
  local now, later = GetTime(), nil
  for _, r in ipairs(answered) do
    if asks[r] then
      local wait = FOLLOW_SEND_GAP - (now - (s.dSentAt[r] or -1e9))
      if wait > 0 then
        if not later or wait > later then later = wait end
      else
        SendD(s, { r }, asks[r])
      end
    end
  end
  if later and not s.planLater then
    s.planLater = true
    C_Timer.After(later + 0.1, function()
      s.planLater = nil
      if sess == s and s.phase ~= "done" then Plan() end
    end)
  end
  s.undecided = next(blocked) ~= nil
  for b = 0, NB - 1 do if contest[b] then ContestBucket(s, g, voters, b) end end
  -- (a relay whose digest isn't that of another's list may disagree with
  -- it: for DISPUTE_GRACE nothing else is planned either, its votes may
  -- show who's wrong elsewhere, and keys planned bit by bit go in more,
  -- smaller x. A dispute lasting longer, a relay taking its time over its
  -- lists, holds back only its buckets, see below)
  if next(disputing) then
    s.disputeAt = s.disputeAt or now
    local left = DISPUTE_GRACE - (now - s.disputeAt)
    if left > 0 then
      if not s.disputeTimer then
        s.disputeTimer = true
        C_Timer.After(left + 0.1, function()
          s.disputeTimer = nil
          if sess == s and s.phase ~= "done" then Plan() end
        end)
      end
      return
    end
  else
    s.disputeAt = nil
  end
  local me = ns.MyKey()
  local haveRoster = next(ns.roster) ~= nil
  local keys, seen = {}, {}
  for _, r in ipairs(voters) do
    for key in pairs(s.lists[r]) do
      local b = Bucket(key)
      if not seen[key] and key ~= me and (not haveRoster or ns.roster[key]) and not blocked[b] and not s.contestedB[b] then
        seen[key] = true
        keys[#keys + 1] = key
      end
    end
  end
  table.sort(keys)
  -- relays proved wrong go first (one may be wrong about several keys), then
  -- the decisions without their votes. (Checksums that can't be worked out
  -- here prove nothing: H.broken) While a relay's lists are still awaited,
  -- nobody is struck yet: its votes may be what proves who's wrong
  -- elsewhere; meanwhile the keys a relay is wrong about wait.
  local holdLiars = next(disputing) ~= nil
  local decisions, caught
  for _ = 1, C.MAX_RELAYS + C.MAX_SWAPS + 1 do
    voters = Voters(s, Answered(s))
    decisions = {}
    caught = {}
    for _, key in ipairs(keys) do
      local m = g.members[key]
      local d = C.Decide(key, m and { ts = m.ts or 0, hash = m.hash }, OwnerOf(key), CI.OwnerLive(key),
        VotesFor(s, voters, key), #voters)
      if H.broken then
        d.liars = {}
        if d.fetch and m and (m.ts or 0) >= d.fetch then d.fetch = nil end
      end
      decisions[key] = d
      for _, r in ipairs(d.liars) do caught[r] = true end
    end
    if not next(caught) or holdLiars then break end
    for _, r in ipairs(voters) do
      if caught[r] then
        if s.relaySet[r] then
          Replace(r, "liar")
        else
          -- (replaced before, its say kept: no more)
          badRelays[r] = true
          s.struck = s.struck + 1
          ns.Debug(("catch-up relay %s caught out after it was replaced"):format(r))
        end
      end
    end
  end
  -- (a relay that may disagree with what another listed isn't sent x
  -- before its own lists are here: it may be about to be caught out; nor
  -- one caught out, not struck yet)
  local newX = {}
  for _, key in ipairs(keys) do
    local d = decisions[key]
    local e = s.expect[key]
    if holdLiars and #d.liars > 0 then
      s.undecided = true -- (decided once nobody's lists are awaited)
    elseif d.fetch then
      if not (e and e.ts == d.fetch and e.h == d.expect and e.from and s.relaySet[e.from]) then
        local ok = not holdLiars
        if holdLiars then
          for _, r in ipairs(d.from) do if not disputing[r] and Live(s, r) then ok = true end end
          if #d.from == 0 then ok = true end
        end
        if ok then
          Assign(s, key, d.fetch, d.expect, d.from, newX, holdLiars and disputing or nil)
        else
          s.undecided = true -- (planned again once their lists are here)
        end
      end
    elseif e then
      Clear(s, key)
    end
    if d.contested and not s.contested[key] then
      -- nothing tells which version is right: keep ours, ask the owner (once)
      s.contested[key] = true
      local m = g.members[key]
      if not (m and (m.ts or 0) > d.contestTs) then WantOwner(key, d.contestTs, d.wantHash, true) end
    end
  end
  SendX(s, newX)
  if s.phase == "sums" then s.phase = "fetch" end
end

-- Works out what to fetch from whom, from the s answers so far. Run when
-- every relay named has answered (or S_WAIT passed), when a follow-up is
-- answered, and again when a relay swapped in answers; keys already on their
-- way from a relay still in the set are left alone. A bucket waits (no keys
-- of it planned) while a relay's versions in it can't be told; the others
-- are planned at once.
function Plan()
  local s = sess
  if not s or s.phase == "done" then return end
  if s.planning then
    s.replan = true
    return
  end
  -- (the digests of lists that came are still being worked out: when they're
  -- done, see OnS)
  if s.digesting > 0 then return end
  local g = ns.GuildDB()
  if not g then return end
  s.planning = true
  -- (again while a pass replaced a relay: what it listed or vouched for counts no more)
  for _ = 1, C.MAX_RELAYS + 2 * C.MAX_SWAPS + 2 do
    s.replan = nil
    PlanOnce(s, g)
    if not s.replan or sess ~= s or s.phase == "done" or s.digesting > 0 then break end
  end
  s.planning, s.replan = nil, nil
  CheckDone(s)
end

function CheckDone(s)
  if s ~= sess or s.phase ~= "fetch" or s.planning then return end
  local awaiting = AwaitingS(s)
  for key, e in pairs(s.expect) do
    if Satisfied(key, e) then
      Clear(s, key)
    elseif not e.from and not awaiting then
      -- nobody left who has it: the owner, if online
      Clear(s, key)
      WantOwner(key, e.ts, e.h)
    end
  end
  if next(s.expect) or awaiting or s.undecided then return end
  Finish(s)
end

-- Starts a records catch-up (a new one replaces any still running). Needs
-- the roster; waits for checksums still being worked out (at most HASH_WAIT
-- seconds: then it goes on with the sums of those worked out so far).
local starting = false
function C.Start()
  if starting or not ns.GuildDB() or not ns.MyKey() then return end
  if not next(ns.roster) then
    pendingStart = GetTime()
    return
  end
  starting = true
  EnsureHashes()
  H.WhenIdle(function()
    starting = false
    local c = Candidates()
    if #c == 0 then
      pendingStart = GetTime()
      ns.Debug("records catch-up: nobody to ask yet")
      return
    end
    pendingStart = nil
    local k = #c >= C.MAX_RELAYS and C.MAX_RELAYS or 1
    local sid
    repeat
      sid = Enc.ToB36(math.random(1296, 46655)) -- 3 base36 digits
    until not sess or sid ~= sess.sid
    if sess then Finish(sess, "replaced") end
    sess = { sid = sid, at = GetTime(), phase = "sums", relays = {}, relaySet = {}, named = {}, dropped = {},
             mineAt = {}, sums = {}, lists = {}, listed = {}, listedAny = {}, awaitLists = {},
             follows = {}, askMask = {}, mineNext = {}, noLists = {}, dSeq = 0, lastD = {},
             expect = {}, assigned = {}, nAssigned = {}, xOut = {}, xSeq = 0, xQueued = {},
             progressAt = {}, anyAt = {}, dSentAt = {}, contested = {}, swaps = 0,
             digests = {}, listDigest = {}, digesting = 0,
             startK = k, kept = {}, keptBefore = {}, contestedB = {}, struck = 0, disputing = {},
             featureRelay = CI.BestRelay(ns.MyKey()) }
    local list = {}
    for i = 1, k do list[i] = c[i] end
    -- every relay picked told us (its hello or reply, the last minute) the
    -- same sums as ours now: nothing to fetch, no D. (Their sums can only
    -- spare a D. Never with one relay: its say-so alone would leave us
    -- without the owners' checksums checked against its lists)
    local inSync = not H.broken and k >= 2
    if inSync then
      local mine, now = FullSums(), GetTime()
      for _, r in ipairs(list) do
        if not SumsMatch(r, mine, now) then inSync = false end
      end
    end
    if inSync then
      for _, r in ipairs(list) do
        sess.relays[#sess.relays + 1] = r
        sess.relaySet[r] = true
      end
      sess.inSync = true
      Finish(sess, "in sync with " .. table.concat(list, ", "))
      return
    end
    ns.Debug(("records catch-up %s: asking %s"):format(sid, table.concat(list, ", ")))
    SendD(sess, list)
  end, HASH_WAIT)
end

-- a hello: someone to ask, if a catch-up found nobody (Comm.lua HandleHello)
local startQueued = false
local function TryPending()
  if not pendingStart or startQueued then return end
  if GetTime() - pendingStart > PENDING_START then pendingStart = nil return end
  if #Candidates() == 0 then return end
  startQueued = true
  -- (a moment for the others' replies to the same hello)
  C_Timer.After(3, function()
    startQueued = false
    if pendingStart then C.Start() end
  end)
end
function C.OnHello() TryPending() end

-- the roster changed: members who left the guild are no longer expected,
-- nor asked (a relay that left is replaced)
ns.On("ROSTER_CHANGED", function()
  TryPending()
  local s = sess
  if not s or s.phase == "done" or not next(ns.roster) then return end
  for key in pairs(s.expect) do
    if not ns.roster[key] then Clear(s, key) end
  end
  for _, l in pairs(s.lists) do
    for key in pairs(l) do if not ns.roster[key] then l[key] = nil end end
  end
  local gone = {}
  for _, r in ipairs(s.relays) do if not ns.roster[r] then gone[#gone + 1] = r end end
  for _, r in ipairs(gone) do Replace(r, "silent") end
  CheckDone(s)
end)

-- a part of a message from `sender` (Comm.lua): an s whispered to us still
-- coming in (SWaitCheck waits for it)
function C.Heard(sender, msgType, channel)
  local s = sess
  if not s or not s.relaySet[sender] then return end
  if msgType == "s" and channel == "WHISPER" then s.anyAt[sender] = GetTime() end
end

-- something r owed us arrived (an s, y, record or summaries for us)
function C.Progress(sender)
  local s = sess
  if s and s.relaySet[sender] then s.progressAt[sender] = GetTime() end
end

-- s: a relay's sums (and lists). The answer to a follow-up (a bucket mask)
-- only changes what we know of those buckets.
function C.OnS(sender, payload, channel)
  local s = sess
  if not s or s.phase == "done" or channel ~= "WHISPER" or not CI.ReceivingExact() or CI.IsLoose(sender) then return end
  if not s.relaySet[sender] or not s.named[sender] or not NeedsS(s, sender) then return end
  local d = Enc.DecodeS(payload)
  if not d or d.sid ~= s.sid then return end
  -- (versions from the future count for nothing)
  local lists = {}
  for key, e in pairs(d.lists) do if ns.TimeOK(e.ts) then lists[key] = e end end
  local first = not s.sums[sender]
  local mask = not first and s.askMask[sender]
  local newly = {} -- [b] = true: buckets listed in this s
  if mask then
    -- our versions and sums when we sent the follow-up, for those buckets
    local at, nxt = s.mineAt[sender], s.mineNext[sender]
    local mine, sums = {}, {}
    for b = 0, NB - 1 do sums[b] = mask[b] and nxt.sums[b] or at.sums[b] end
    for key, e in pairs(at.list) do if not mask[Bucket(key)] then mine[key] = e end end
    for key, e in pairs(nxt.list) do if mask[Bucket(key)] then mine[key] = e end end
    s.mineAt[sender] = { list = mine, sums = sums }
    local L, listed, dig = s.lists[sender], s.listed[sender], s.digests[sender]
    for key in pairs(L) do if mask[Bucket(key)] then L[key] = nil end end
    for b in pairs(mask) do
      s.sums[sender][b], listed[b], dig[b] = d.sums[b], d.listed[b], d.digests[b]
      if d.listed[b] then newly[b] = true end
    end
    for key, e in pairs(lists) do if mask[Bucket(key)] then L[key] = e end end
    -- (none of them listed: not asked again)
    if not next(newly) then s.noLists[sender] = true end
  else
    s.sums[sender], s.lists[sender], s.listed[sender] = d.sums, lists, d.listed
    s.digests[sender] = d.digests
    s.listDigest[sender] = {}
    for b in pairs(d.listed) do newly[b] = true end
  end
  s.awaitLists[sender], s.askMask[sender], s.mineNext[sender] = nil, nil, nil
  if next(newly) then s.listedAny[sender] = true end
  s.progressAt[sender] = GetTime()
  -- their copy of our own record: newer than ours, or ours but different
  local own = ns.OwnState()
  local theirs = d.self
  if first and theirs and own.hash and own.ts and ns.TimeOK(theirs.ts)
    and (theirs.ts > own.ts or (theirs.ts == own.ts and theirs.h ~= own.hash)) then
    CI.ReassertFor(sender, theirs.ts)
  end
  -- the digest of each list it sent (its text as sent, future versions and
  -- all), for the other relays' digests to be compared with. Through the
  -- hash queue, ahead of what waits there: a long s lists a few hundred
  -- versions, too much to hash in one frame. Planning waits for them.
  local ld = s.listDigest[sender]
  if not H.broken and next(newly) then
    local byBucket = {}
    for b in pairs(newly) do
      byBucket[b] = {}
      ld[b] = nil
    end
    for key, e in pairs(d.lists) do
      local list = byBucket[Bucket(key)]
      if list then list[#list + 1] = { key = key, ts = e.ts, h = e.h } end
    end
    for b, list in pairs(byBucket) do
      s.digesting = s.digesting + 1
      H.Queue(Enc.ListText(list), function(h)
        ld[b] = h
        s.digesting = s.digesting - 1
        if s.digesting == 0 and sess == s and not AwaitingFirst(s) then Plan() end
      end, true)
    end
  end
  if not AwaitingFirst(s) then Plan() end
end

-- a record we expected arrived (Comm.lua StoreChecked)
function C.Arrived(key, rec, sender)
  local s = sess
  if not s or s.phase == "done" then return end
  if sender and s.relaySet[sender] then s.progressAt[sender] = GetTime() end
  local e = s.expect[key]
  if e and (rec.ts or 0) >= e.ts then
    Clear(s, key)
    CheckDone(s)
  end
end

-- a passed-on copy whose checksum isn't the one expected (Comm.lua): from one
-- of our relays, it's replaced and the key goes to another; from anyone else
-- (an officer, outside a catch-up), we ask the owner if they're online
function C.BadCopy(sender, key, ts, exp)
  local s = sess
  if s and s.phase ~= "done" and s.relaySet[sender] then
    Replace(sender, "liar")
    return
  end
  WantOwner(key, ts, exp)
end

-- y: a relay queued what it had for one x. Once what came is checked, the
-- keys of that x that didn't arrive go to another relay (it may just not
-- have them any more, or sent them to us before: no strike)
function C.OnY(sender, payload, channel)
  local s = sess
  if not s or s.phase == "done" or channel ~= "WHISPER" or not s.relaySet[sender] then return end
  local d = Enc.DecodeY(payload)
  if not d or d.sid ~= s.sid then return end
  local x = s.xOut[sender] and s.xOut[sender][d.xid]
  if not x then return end
  s.xOut[sender][d.xid] = nil
  s.progressAt[sender] = GetTime()
  C_Timer.After(Y_GRACE, function()
    H.WhenIdle(function()
      if sess ~= s or s.phase == "done" or not s.relaySet[sender] then return end
      local newX = {}
      Reroute(s, sender, x.keys, newX)
      SendX(s, newX)
      CheckDone(s)
    end)
  end)
end

-- a whisper to `key` failed (Comm.lua tries the next spelling of their name):
-- our x to them that went out (or started to) are sent again once, then
-- their keys move on. (A failure just after a retry is the old one's.)
ns.On("WHISPER_FAILED", function(key)
  local s = sess
  if not s or s.phase == "done" or not s.relaySet[key] or not s.xOut[key] then return end
  local newX = {}
  local now = GetTime()
  for _, x in pairs(s.xOut[key]) do
    if (x.sent or CI.Started(x.id)) and not (x.retriedAt and now - x.retriedAt < 2) then RetryX(s, key, x, newX) end
  end
  SendX(s, newX)
  CheckDone(s)
end)

-- every 30 s: relays that owe us records but went offline, or sent nothing
-- of it for FETCH_IDLE after our x went out, are replaced (no strike); our x
-- that never went out are sent again; the catch-up ends after CATCHUP_MAX
local function IdleCheck()
  local s = sess
  if not s or s.phase == "done" then return end
  local now = GetTime()
  if now - s.at > CATCHUP_MAX then return Finish(s, "time limit") end
  if CI.Paused() then return end
  local list = {}
  for _, r in ipairs(s.relays) do list[#list + 1] = r end
  local newX = {}
  for _, r in ipairs(list) do
    if s.relaySet[r] and (s.nAssigned[r] or 0) > 0 and not ns.IsOnline(r) then
      Replace(r, "silent")
    elseif s.relaySet[r] and s.xOut[r] then
      local last, waiting, any = s.progressAt[r] or -1e9, false, false
      for _, x in pairs(s.xOut[r]) do
        any = true
        if not x.sent then
          if CI.Waiting(x.id) then waiting = true else RetryX(s, r, x, newX) end
        end
        if x.due > last then last = x.due end
      end
      if any and not waiting and now - last > C.FETCH_IDLE then Replace(r, "silent") end
    end
  end
  SendX(s, newX)
  CheckDone(s)
end

-- Is our records catch-up being answered right now? (for the sync progress
-- in the sidebar and on the Recipes page, see ns.SyncProgress)
function ns.CatchUpActive()
  if C.Active() then return true end
  local t = CI.RelayAnsweredAt("D")
  return t ~= nil and GetTime() - t <= 60
end

------------------------------------------------------------------------
-- Relay side
------------------------------------------------------------------------
-- D: answered with our s when it names us (at once, ahead of the queue;
-- it never waits for a busy queue or the answer budget). Lists only when
-- we're named first (the others' would mostly repeat ours: they send the
-- digests of theirs), for at most MAX_LISTS catch-ups per requester per
-- ANSWER_GAP, and not while our queue is long, the answer budget is used up,
-- or too much already waits ahead of the queue (a long s would go at the
-- back, past S_WAIT): else sums (and digests) only.
-- A D with a bucket mask lists (or digests) only those buckets. In the same
-- catch-up, named first, it's a follow-up (the lists we had no room for, or
-- ours where the requester can't tell): answered at once, even right after
-- an s with lists, and while our queue is long, at most MAX_FOLLOWUPS
-- times, each once our answer to the last D is queued and FOLLOW_GAP after
-- it; a bucket is listed (or digested) at most once per catch-up, and a
-- catch-up's lists count once in MAX_LISTS.
function C.OnD(sender, payload)
  local me = ns.MyKey()
  if not me or sender == me or CI.IsLoose(sender) then return end
  local d = Enc.DecodeD(payload)
  if not d then return end
  local named = false
  for _, r in ipairs(d.relays) do if r == me then named = true end end
  if not named or (next(ns.roster) and not ns.roster[sender]) then return end
  local first = d.relays[1] == me
  local now = GetTime()
  -- what we already sent them carries over for SENT_KEEP, whatever the
  -- session: a new one (a /reload, /fhub sync) can't make us send it all again
  local rs = relaySess[sender]
  if not rs then
    rs = { sent = {}, summed = {}, x = 0, xids = {}, lists = 0, listsFrom = now }
    relaySess[sender] = rs
  end
  rs.touched = now
  if now - rs.listsFrom > CI.ANSWER_GAP then rs.lists, rs.listsFrom = 0, now end
  -- (a follow-up only once our answer to their last D is queued, and
  -- FOLLOW_GAP after it: each one has us sum and digest again)
  local followUp = d.mask ~= nil and rs.sid == d.sid and first and (rs.follows or 0) < C.MAX_FOLLOWUPS
    and not rs.answering and not (lastD[sender] and now - lastD[sender] < FOLLOW_GAP)
  if lastD[sender] and now - lastD[sender] < D_GAP and not followUp then
    ns.Debug("ignored repeated records catch-up request from " .. sender)
    return
  end
  lastD[sender] = now
  if rs.sid ~= d.sid then rs.x, rs.xids, rs.follows, rs.listedB, rs.granted = 0, {}, 0, {}, nil end
  if followUp then rs.follows = rs.follows + 1 end
  rs.sid, rs.at, rs.answering = d.sid, now, true
  local mask = d.mask
  EnsureHashes()
  -- (checksums still being worked out: at most HASH_WAIT, then the sums of
  -- what's worked out)
  H.WhenIdle(function()
    if relaySess[sender] ~= rs or rs.sid ~= d.sid then return end
    local sums, byBucket = NewSums(), {}
    EachHashed(sender, function(key, ts, h)
      local b = Bucket(key)
      sums[b] = H.Xor(sums[b], H.H32(h))
      if not mask or mask[b] then
        byBucket[b] = byBucket[b] or {}
        table.insert(byBucket[b], { key = key, ts = ts, h = h })
      end
    end)
    local lists = {}
    -- (a follow-up even while our queue is long, sending this catch-up its
    -- records: it asks for a few buckets, and goes ahead of the queue)
    local withLists = first and (rs.granted or rs.lists < C.MAX_LISTS) and not CI.OverBudget(sender)
      and (followUp or ns.QueueLength() <= CI.BUSY_QUEUE) and CI.AfterParts() < (ns._afterCap or MAX_AFTER_PARTS)
    -- (the buckets that count: those asked for, whose sums differ)
    local function Wanted(b) return sums[b] ~= d.sums[b] and (not mask or mask[b]) end
    for b = 0, NB - 1 do
      if withLists and Wanted(b) and not rs.listedB[b] then lists[b] = byBucket[b] or {} end
    end
    local g = ns.GuildDB()
    local m = g and g.members[sender]
    local self = m and m.hash and { ts = m.ts or 0, h = m.hash } or nil
    -- (far too long for one answer: the last buckets aren't listed, their
    -- digests go instead)
    local room = MAX_S_PARTS * CI.CHUNK - NB * 13
    local text = Enc.EncodeS(d.sid, sums, self, lists)
    for b = NB - 1, 0, -1 do
      if #text <= room then break end
      lists[b] = nil
      text = Enc.EncodeS(d.sid, sums, self, lists)
    end
    if next(lists) then
      if not rs.granted then rs.lists, rs.granted = rs.lists + 1, true end
      for b in pairs(lists) do rs.listedB[b] = true end
    end
    -- the digest of what we'd list in each other bucket whose sum differs
    -- (Enc.ListText: the same text a relay listing it sends). Through the
    -- hash queue, ahead of what waits there: all our versions, for a new
    -- member, are too much to hash in one frame. (Not again in a follow-up
    -- for a bucket we listed in this catch-up: they have its list)
    local digests, pending = {}, 1
    local function Send()
      pending = pending - 1
      if pending > 0 or relaySess[sender] ~= rs or rs.sid ~= d.sid then return end
      rs.answering = nil
      ns.QueueMsg("s", Enc.EncodeS(d.sid, sums, self, lists, digests), { target = sender, front = "after" })
      CI.CountAnswer(sender)
    end
    if not H.broken then
      for b = 0, NB - 1 do
        if Wanted(b) and not lists[b] and not (followUp and rs.listedB[b]) then
          pending = pending + 1
          H.Queue(Enc.ListText(byBucket[b] or {}), function(h)
            digests[b] = h
            Send()
          end, true)
        end
      end
    end
    Send()
  end, HASH_WAIT)
end

-- rs.sent / rs.summed: that version of `key` went to the requester less
-- than SENT_KEEP ago
local function Recent(t, key, ts, now)
  local was = t[key]
  return was ~= nil and was.ts == ts and now - was.at < SENT_KEEP
end

-- the records of `list` we can send (each version once per SENT_KEEP):
-- { { rec, text } }, smallest first. peek: don't mark them sent
local function Pick(req, rs, list, peek)
  local g = ns.GuildDB()
  if not g then return {} end
  local me = ns.MyKey()
  local haveRoster = next(ns.roster) ~= nil
  local now = GetTime()
  local out = {}
  for _, it in ipairs(list) do
    local key = it.key
    if key ~= req and (not haveRoster or ns.roster[key]) then
      local m = key == me and ns.MyRecord() or g.members[key]
      if m and (m.ts or 0) >= it.ts and not Recent(rs.sent, key, m.ts or 0, now) then
        if not peek then
          rs.sent[key] = { ts = m.ts or 0, at = now }
          rs.touched = now
        end
        out[#out + 1] = { rec = m, text = Enc.EncodeRecord(m) }
      end
    end
  end
  table.sort(out, function(a, b)
    if #a.text ~= #b.text then return #a.text < #b.text end
    return a.rec.key < b.rec.key
  end)
  return out
end

-- E summaries of `recs` ahead of the queue (at the back past
-- MAX_AFTER_PARTS); returns how many messages. Each record's summary goes
-- once per SENT_KEEP (rs.summed). With the guild channel muted they're
-- whispered to the requester only.
local function QueueSummaries(req, rs, recs)
  local list = {}
  local now = GetTime()
  for _, r in ipairs(recs) do
    local key, ts = r.rec.key, r.rec.ts or 0
    if not Recent(rs.summed, key, ts, now) then
      rs.summed[key] = { ts = ts, at = now }
      local s = Enc.EncodeSummary(r.rec)
      if #s <= Enc.MAX_SUMMARY then list[#list + 1] = s end
    end
  end
  table.sort(list)
  local batch, size, n = {}, 1, 0
  local target = ns.guildMuted and req or nil
  local function flush()
    if #batch == 0 then return end
    local place = CI.AfterParts() < (ns._afterCap or MAX_AFTER_PARTS) and "after" or nil
    ns.QueueMsg("E", Enc.EncodeSummaryBatch(batch), { target = target, front = place })
    n = n + 1
    batch, size = {}, 1
  end
  for _, s in ipairs(list) do
    local add = #s + #Enc.ToB36(#s) + 2
    if size + add > CI.SUMMARY_BATCH or #batch >= Enc.MAX_SUMMARY_ENTRIES then flush() end
    batch[#batch + 1] = s
    size = size + add
  end
  flush()
  return n
end

local function RecordParts(recs)
  local n = 0
  for _, r in ipairs(recs) do n = n + math.ceil(#r.text / CI.CHUNK) end
  return n
end

-- One x answered: summaries (for a long answer), the records on the guild
-- channel, smallest first, then y. Waits like any catch-up answer while our
-- queue is long or the answer budget is used up (the summaries go at once
-- then, for one requester per BUSY_SUMMARY_GAP).
local function AnswerX(req, rs, sid, xid, list, waits, askedAt, summariesSent)
  if relaySess[req] ~= rs then return end
  if waits > 0 and not CI.RequesterWindowOpen(req, askedAt) then
    ns.Debug(("dropped catch-up answer x for %s (their window closed)"):format(req))
    return
  end
  local now = GetTime()
  local busy = ns.QueueLength() > CI.BUSY_QUEUE
  local over = CI.OverBudget(req)
  if (busy or over) and waits < CI.MAX_WAITS then
    if busy and not over and waits == 0 and not summariesSent and now - lastBusySummaries >= BUSY_SUMMARY_GAP
      and CI.AfterParts() < (ns._afterCap or MAX_AFTER_PARTS) then
      if QueueSummaries(req, rs, Pick(req, rs, list, true)) > 0 then
        CI.CountAnswer(req)
        lastBusySummaries = now
        summariesSent = true
      end
    end
    C_Timer.After(30, function()
      if ns.IsOnline(req) then AnswerX(req, rs, sid, xid, list, waits + 1, askedAt, summariesSent) end
    end)
    return
  end
  local recs = Pick(req, rs, list)
  if not summariesSent and RecordParts(recs) >= SUMMARY_MIN_PARTS then QueueSummaries(req, rs, recs) end
  local me, mine = ns.MyKey(), false
  for _, r in ipairs(recs) do
    if r.rec.key == me then mine = true end
    ns.BroadcastRecord(r.rec, r.text)
  end
  -- (keys we didn't send: sent to this requester in the last SENT_KEEP, or
  -- we don't have them; the requester moves them to another relay)
  local function Done()
    ns.QueueMsg("y", Enc.EncodeY(sid, xid, #recs, #list - #recs), { target = req })
  end
  -- our own record goes out once its checksum is worked out (Comm.lua
  -- SendOwn): the y after it
  if mine and ns.OwnRefresh then ns.OwnRefresh(Done) else Done() end
  CI.CountAnswer(req)
  ns.Debug(("relayed %d records to %s"):format(#recs, req))
end

-- x: the records a requester wants from us (their current catch-up only, at
-- most MAX_X of them; one we already answered, the same again, is ignored)
function C.OnX(sender, payload, channel)
  if channel ~= "WHISPER" then return end
  local rs = relaySess[sender]
  if not rs or not rs.sid then return end
  local d = Enc.DecodeX(payload)
  if not d or d.sid ~= rs.sid or GetTime() - rs.at > CATCHUP_MAX or rs.x >= C.MAX_X or rs.xids[d.xid] then return end
  rs.x = rs.x + 1
  rs.xids[d.xid] = true
  AnswerX(sender, rs, d.sid, d.xid, d.list, 0, GetTime(), false)
end

------------------------------------------------------------------------
-- Housekeeping
------------------------------------------------------------------------
-- a member left the guild (Comm.lua ns.ForgetMemberSync)
function C.Forget(key)
  bucketOf[key], relaySess[key], lastD[key], heardSums[key] = nil, nil, nil, nil
  local s = sess
  if not s then return end
  if s.expect[key] then Clear(s, key) end
  for _, l in pairs(s.lists) do l[key] = nil end
  CheckDone(s)
end

ns.On("LOGIN", function()
  C_Timer.NewTicker(IDLE_TICK, function()
    IdleCheck()
    local now = GetTime()
    for k, rs in pairs(relaySess) do
      if now - rs.touched > SENT_KEEP and now - (rs.at or 0) > CATCHUP_MAX then relaySess[k] = nil end
    end
    for k, t in pairs(lastD) do if now - t > D_GAP then lastD[k] = nil end end
    for k, hs in pairs(heardSums) do if now - hs.at > C.SUMS_FRESH then heardSums[k] = nil end end
  end)
end)
