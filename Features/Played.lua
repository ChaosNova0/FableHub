-- Played: your /played time on the roster, for players who choose to share it
-- (Settings > Privacy, off by default; account-wide).
--
-- Each sharing character asks the game for its time played (RequestTimePlayed)
-- at login and on level-up, keeps the latest reading in rec.playedLive (never
-- sent) and counts on from it while logged in. A snapshot goes into its own
-- record as rec.played (sent with it, Encode.lua field 14):
--   { total, thisLevel, lvl, at, xp?, xpMax?, rested?, sess? }
-- rec.played only changes inside ns.RecordChanged (via PL.BeforeChange), so
-- the record's time moves with it: turning sharing off sends a newer record
-- without it, which replaces the old copy everywhere. A copy passed on by an
-- older client (no time played) only ever fills gaps, never removes it.

local _, ns = ...
local PL = {}
ns.Played = PL

PL.MIN_VERSION = "0.24.0"   -- first FableHub that shares time played
PL.SHARE_EVERY = 2 * 3600   -- re-share after this much more time played
PL.DRIFT = 600              -- or when a reading is this far off what was shared
PL.FRESH = 3600             -- after /reload, skip the login request when the reading is newer
PL.MIN_GAP = 60             -- seconds between our requests
PL.MUTE_MAX = 10            -- chat frames get the event back after this at the latest
PL.ONLINE_MAX = 5 * 3600    -- count on from someone's reading only this long
PL.STALE = 600              -- show "Updated ..." for readings older than this
PL.MIN_AVG = 600            -- level average needs this much time on the level
PL.MIN_SESSION = 600        -- session XP/hour needs this much time
PL.MAX_RATE = 500000        -- XP per hour (the most a record may say, see Encode.lua)

local floor, max, min = math.floor, math.max, math.min

local function Sharing() return ns.Option("sharePlayed") and true or false end
PL.Sharing = Sharing

local function MyLevel() return UnitLevel("player") or 0 end

-- XP, XP needed for the level, rested XP (nil when the client can't say)
local function ReadXP()
  if not (UnitXP and UnitXPMax) then return nil end
  local xp, xpMax = tonumber(UnitXP("player")), tonumber(UnitXPMax("player"))
  if not xp or not xpMax or xpMax <= 0 then return nil end
  local rested = GetXPExhaustion and tonumber(GetXPExhaustion()) or 0
  return floor(xp), floor(xpMax), floor(rested)
end
PL.ReadXP = ReadXP

------------------------------------------------------------------------
-- Formatting
------------------------------------------------------------------------
-- "21d 3h" / "22h 40m" / "40m"
function PL.FormatShort(s)
  s = max(0, floor(tonumber(s) or 0))
  local d, h, m = floor(s / 86400), floor(s % 86400 / 3600), floor(s % 3600 / 60)
  if d > 0 then return ("%dd %dh"):format(d, h) end
  if h > 0 then return ("%dh %dm"):format(h, m) end
  return ("%dm"):format(m)
end

-- "4d 6h 12m" / "6h 12m" / "12m"
function PL.FormatLong(s)
  s = max(0, floor(tonumber(s) or 0))
  local d, h, m = floor(s / 86400), floor(s % 86400 / 3600), floor(s % 3600 / 60)
  if d > 0 then return ("%dd %dh %dm"):format(d, h, m) end
  if h > 0 then return ("%dh %dm"):format(h, m) end
  return ("%dm"):format(m)
end

-- 61880 -> "61,880"
function PL.Num(n)
  local s = tostring(floor(tonumber(n) or 0))
  local sign, digits = s:match("^(%-?)(%d+)$")
  if not digits then return s end
  local out = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return sign .. out:gsub("^,", "")
end

-- XP bar as texture escapes for a tooltip line: XP (accent), rested (light
-- blue) and the rest (dim grey), `width` pixels in all
local BAR = "|TInterface\\Buttons\\WHITE8X8:8:%d:0:0:8:8:0:8:0:8:%d:%d:%d|t"
function PL.Bar(xp, xpMax, rested, width)
  width = width or 200
  xpMax = max(1, tonumber(xpMax) or 1)
  xp = max(0, min(tonumber(xp) or 0, xpMax))
  local fillW = floor(width * xp / xpMax + 0.5)
  local restW = floor(width * max(0, min(tonumber(rested) or 0, xpMax - xp)) / xpMax + 0.5)
  restW = min(restW, width - fillW)
  local leftW = width - fillW - restW
  local r, g, b = ns.Theme.Accent()
  local out = {}
  if fillW > 0 then out[#out + 1] = BAR:format(fillW, floor(r * 255), floor(g * 255), floor(b * 255)) end
  if restW > 0 then out[#out + 1] = BAR:format(restW, 115, 180, 255) end
  if leftW > 0 then out[#out + 1] = BAR:format(leftW, 70, 70, 70) end
  return table.concat(out)
end

------------------------------------------------------------------------
-- Own readings
------------------------------------------------------------------------
-- stale: a fresh login whose first reading hasn't arrived (the saved one is
-- from last session, so counting on from it would add the time offline)
local stale = false
local reloaded = false

-- XP per hour since the session started (nil until there's something to say)
local function SessionRate(live, xp)
  local s = live and live.session
  if not s or s.lvl ~= MyLevel() or not xp then return nil end
  local secs = ns.Now() - (s.at or 0)
  local gain = xp - (s.xp or 0)
  if secs < PL.MIN_SESSION or gain <= 0 then return nil end
  return gain / secs * 3600
end

-- start a new session baseline when there's none or it's from another level
local function EnsureSession(live)
  local s = live.session
  if not s or s.lvl ~= MyLevel() then
    live.session = { at = ns.Now(), xp = (ReadXP()) or 0, lvl = MyLevel() }
  end
end

-- the latest reading counted on to now: total, this level (nil if it's from another level)
local function LiveNow(live)
  local d = max(0, ns.Now() - (live.at or 0))
  local thisLevel = live.lvl == MyLevel() and (live.thisLevel or 0) + d or nil
  return (live.total or 0) + d, thisLevel
end

local function Usable(live)
  return live ~= nil and live.total ~= nil and not stale
end

-- what goes into our record now
local function Snapshot(rec)
  local live = rec.playedLive
  local now, lvl = ns.Now(), MyLevel()
  local total, thisLevel = LiveNow(live)
  local p = { total = floor(total), thisLevel = floor(thisLevel or 0), lvl = lvl, at = now }
  -- (the wire's level cap, not this client's: see Enc.EncodePlayed)
  if lvl < ns.Encode.PLAYED_MAX_LEVEL then
    local xp, xpMax, rested = ReadXP()
    if xp and xpMax and rested then
      p.xp, p.xpMax = min(xp, xpMax - 1), xpMax
      p.rested = min(rested, floor(1.5 * xpMax))
      p.sess = min(floor(SessionRate(live, xp) or 0), PL.MAX_RATE)
    end
  end
  return p
end
PL.Snapshot = Snapshot

-- Called by ns.RecordChanged before the record's time moves on
function PL.BeforeChange(rec)
  if not rec or rec.key ~= ns.MyKey() then return end
  if not Sharing() then rec.played = nil return end
  local live = rec.playedLive
  if Usable(live) and live.lvl == MyLevel() then rec.played = Snapshot(rec) end
end

-- share a new snapshot when the shared one has fallen behind
function PL.CheckDue()
  if not Sharing() then return end
  local rec = ns.MyRecord()
  local live = rec and rec.playedLive
  if not Usable(live) or live.lvl ~= MyLevel() then return end
  local p = rec.played
  local total = LiveNow(live)
  if not p or p.lvl ~= MyLevel() or total - (p.total or 0) >= PL.SHARE_EVERY
      -- (what others count on to from the shared one is off, e.g. the time
      -- offline after logging back in)
      or math.abs(((p.total or 0) + (ns.Now() - (p.at or 0))) - total) > PL.DRIFT then
    ns.RecordChanged(rec)
  end
end

local function OnReading(total, thisLevel)
  total, thisLevel = tonumber(total), tonumber(thisLevel)
  if not total or total <= 0 or not Sharing() then return end
  local rec = ns.MyRecord()
  if not rec then return end
  local old = rec.playedLive
  rec.playedLive = { total = floor(total), thisLevel = floor(max(0, min(thisLevel or 0, total))), lvl = MyLevel(),
                     at = ns.Now(), session = old and old.session }
  EnsureSession(rec.playedLive)
  stale = false
  PL.CheckDue()
  ns.Fire("DATA_CHANGED")
end

------------------------------------------------------------------------
-- Asking the game. The answer also prints in chat ("Total time played: ..."),
-- so chat frames stop listening for it until our answer has arrived. (The
-- function that prints it has a different name on each client, so it isn't
-- replaced: the frames are unregistered and registered again.)
------------------------------------------------------------------------
local pending          -- id of the request waiting for its answer
local requestId = 0
local lastRequest      -- GetTime() of our last request
local retryQueued = false
local lostRetry = false  -- the one retry after a lost answer (per login / level-up) is used
local afterCombat = false
local muted = {}       -- chat frames we unregistered

local function ChatFrames()
  local out, seen = {}, {}
  local function add(f)
    if type(f) == "table" and not seen[f] then seen[f] = true; out[#out + 1] = f end
  end
  for i = 1, tonumber(NUM_CHAT_WINDOWS) or 0 do add(_G["ChatFrame" .. i]) end
  if type(CHAT_FRAMES) == "table" then
    for _, name in ipairs(CHAT_FRAMES) do add(_G[name]) end
  end
  return out
end

local function Mute()
  for _, f in ipairs(ChatFrames()) do
    if type(f.IsEventRegistered) == "function" and type(f.UnregisterEvent) == "function" then
      local ok, on = pcall(f.IsEventRegistered, f, "TIME_PLAYED_MSG")
      if ok and on and pcall(f.UnregisterEvent, f, "TIME_PLAYED_MSG") then muted[#muted + 1] = f end
    end
  end
end

local function Unmute()
  for i = #muted, 1, -1 do
    local f = muted[i]
    muted[i] = nil
    if type(f.RegisterEvent) == "function" then pcall(f.RegisterEvent, f, "TIME_PLAYED_MSG") end
  end
end
function PL.MutedCount() return #muted end

function PL.Request()
  if not Sharing() or type(RequestTimePlayed) ~= "function" or pending then return false end
  local now = GetTime()
  if lastRequest and now - lastRequest < PL.MIN_GAP then
    -- asked a moment ago: once more when the gap is over
    if not retryQueued then
      retryQueued = true
      C_Timer.After(PL.MIN_GAP - (now - lastRequest) + 0.5, function()
        retryQueued = false
        PL.Request()
      end)
    end
    return false
  end
  if InCombatLockdown() then afterCombat = true return false end
  afterCombat = false
  lastRequest = now
  requestId = requestId + 1
  local id = requestId
  pending = id
  Mute()
  local ok, err = pcall(RequestTimePlayed)
  if not ok then
    pending = nil
    Unmute()
    ns.ReportError("played: " .. tostring(err))
    return false
  end
  C_Timer.After(PL.MUTE_MAX, function()
    local lost = pending == id
    if lost then pending = nil end
    if not pending then Unmute() end
    -- no answer and still no reading (a fresh login): ask once more
    if lost and not lostRetry then
      local rec = ns.MyRecord()
      if not Usable(rec and rec.playedLive) then
        lostRetry = true
        PL.Request()
      end
    end
  end)
  return true
end

function PL.IsPending() return pending ~= nil end

ns.RegisterEvent("TIME_PLAYED_MSG", function(total, thisLevel)
  -- (the player's own /played as well: a free reading)
  if pending then
    pending = nil
    -- the chat frames listen again once this event has gone round
    C_Timer.After(0, function() if not pending then Unmute() end end)
  end
  OnReading(total, thisLevel)
end)

ns.RegisterEvent("PLAYER_REGEN_ENABLED", function()
  if afterCombat then PL.Request() end
end)

------------------------------------------------------------------------
-- Turning it on and off
------------------------------------------------------------------------
function PL.SetSharing(on)
  ns.SetOption("sharePlayed", on)
  local rec = ns.MyRecord()
  if on then
    PL.Request() -- shared once the reading arrives
  elseif rec then
    rec.playedLive = nil
    if rec.played then
      rec.played = nil
      ns.RecordChanged(rec)
    end
  end
  ns.Fire("DATA_CHANGED")
end

-- "Share your time played?" on Home's Getting started card
function PL.WantTip()
  return ns.Option("homeTips") and IsInGuild() and not Sharing()
    and not (FableHubDB and FableHubDB.settings and FableHubDB.settings.playedTipDismissed) and true or false
end

function PL.DismissTip()
  FableHubDB.settings.playedTipDismissed = true
end

------------------------------------------------------------------------
-- Login, reload and level-up
------------------------------------------------------------------------
ns.RegisterEvent("PLAYER_ENTERING_WORLD", function(isInitialLogin, isReloadingUi)
  local rec = ns.MyRecord()
  local live = rec and rec.playedLive
  if isInitialLogin then
    reloaded = false
    if live then
      stale = true
      live.session = nil -- a new session
    end
  elseif isReloadingUi then
    reloaded = true
  end
end)

local function LoginRequest()
  if not Sharing() then return end
  local rec = ns.MyRecord()
  local live = rec and rec.playedLive
  if reloaded and live and live.total and live.lvl == MyLevel() and ns.Now() - (live.at or 0) < PL.FRESH then
    stale = false
    EnsureSession(live)
    PL.CheckDue()
    return
  end
  lostRetry = false
  PL.Request()
end

local ticking = false
ns.On("LOGIN", function()
  local rec = ns.MyRecord()
  -- turned off on another character: take it off this one too
  if rec and not Sharing() then
    rec.playedLive = nil
    if rec.played then
      rec.played = nil
      ns.RecordChanged(rec)
    end
  end
  C_Timer.After(12, LoginRequest)
  if not ticking then
    ticking = true
    C_Timer.NewTicker(300, function() PL.CheckDue() end)
  end
end)

ns.RegisterEvent("PLAYER_LEVEL_UP", function(newLevel)
  if not Sharing() then return end
  newLevel = tonumber(newLevel) or MyLevel()
  local rec = ns.MyRecord()
  local live = rec and rec.playedLive
  if Usable(live) then
    -- counted on until the real reading arrives a moment later
    local now = ns.Now()
    rec.playedLive = { total = floor((LiveNow(live))), thisLevel = 0, lvl = newLevel, at = now,
                       session = { at = now, xp = 0, lvl = newLevel } }
  end
  lostRetry = false
  C_Timer.After(2, PL.Request)
end)

------------------------------------------------------------------------
-- Reading anyone's time played
------------------------------------------------------------------------
-- their FableHub version: this session, else the last one we saw
local function VersionOf(key)
  local g = ns.GuildDB()
  return ns.present[key] or (g and g.addonUsers and g.addonUsers[key] and g.addonUsers[key].version)
end

-- a character's time played counted on to now (nil when not shared)
local function TotalOf(key)
  if key == ns.MyKey() then
    local rec = ns.MyRecord()
    local live = rec and rec.playedLive
    if Sharing() and Usable(live) then return (LiveNow(live)) end
    return nil
  end
  local own = FableHubDB.chars[key] -- my other characters: their own saved record
  local p = own and own.played
  if own and not p then return nil end
  if not p then
    local g = ns.GuildDB()
    local rec = g and g.members[key]
    p = rec and rec.played
    if not p then return nil end
    local r = ns.roster[key]
    local d = ns.Now() - (p.at or 0)
    if r and r.online and d > 0 and d <= PL.ONLINE_MAX then return p.total + d end
  end
  return p.total
end

-- Everything the column and tooltip show:
-- { state = "none"|"off"|"old"|"on"|"pending", total, thisLevel, lvl, xp, xpMax,
--   rested, pct, rate, rateKind = "session"|"level", avg, nextIn, alts, at,
--   stale, levelKnown, mine }
-- withAlts: also add up the time played of their linked characters
function PL.Info(key, rec, r, withAlts)
  local now, maxLevel = ns.Now(), ns.MaxLevel()
  local info = { mine = key == ns.MyKey() }
  local xp, xpMax, rested, sess, snapXp, snapLevel
  if info.mine then
    rec = ns.MyRecord()
    if not Sharing() then info.state = "off" return info end
    local live = rec and rec.playedLive
    if not Usable(live) then info.state = "pending" return info end
    local lvl = MyLevel()
    info.total, info.thisLevel = LiveNow(live)
    info.lvl, info.at = live.lvl, now
    if lvl < maxLevel and live.lvl == lvl then
      xp, xpMax, rested = ReadXP()
      sess = SessionRate(live, xp)
      snapXp, snapLevel = xp, info.thisLevel
    end
  else
    local p = rec and rec.played
    if not p then
      if not (rec and rec.ts and rec.ts > 0) then info.state = "none"
      else
        local ver = VersionOf(key)
        info.state = (ver and ns.VersionNumber(ver) < ns.VersionNumber(PL.MIN_VERSION)) and "old" or "off"
      end
      return info
    end
    local online = r and r.online
    local d = now - (p.at or 0)
    if not online or d <= 0 or d > PL.ONLINE_MAX then d = 0 end
    local level = (r and r.level) or rec.level or p.lvl
    info.total = p.total + d
    info.lvl, info.at = p.lvl, p.at
    info.stale = now - (p.at or 0) > PL.STALE
    if level <= p.lvl then
      info.thisLevel = (p.thisLevel or 0) + ((level == p.lvl) and d or 0)
      if p.lvl < maxLevel and p.xpMax then
        xp, xpMax, rested = p.xp, p.xpMax, p.rested
        if online and (p.sess or 0) > 0 and now - (p.at or 0) <= PL.ONLINE_MAX then sess = p.sess end
        snapXp, snapLevel = p.xp, p.thisLevel
      end
    end
  end
  info.state = "on"
  if xpMax and xpMax > 0 then
    info.levelKnown = true
    info.xp, info.xpMax, info.rested = xp, xpMax, rested or 0
    info.pct = floor(xp / xpMax * 100)
    if (snapLevel or 0) >= PL.MIN_AVG then info.avg = snapXp / snapLevel * 3600 end
    if sess and sess > 0 then info.rate, info.rateKind = sess, "session"
    elseif info.avg then info.rate, info.rateKind = info.avg, "level" end
    if info.rate and info.rate > 0 then info.nextIn = (xpMax - xp) / info.rate * 3600 end
  end
  if withAlts and ns.Alts and ns.Alts.GroupOf then
    local sum, n = 0, 0
    for _, k in ipairs(ns.Alts.GroupOf(key, true)) do -- verified links only
      local t = (k == key) and info.total or TotalOf(k)
      if t then sum, n = sum + t, n + 1 end
    end
    if n > 1 and sum > info.total then info.alts = sum end
  end
  return info
end

-- the Played column: text, sort value (-1 without data)
function PL.Cell(key, rec, r, online)
  local info = PL.Info(key, rec, r)
  local UI = ns.UI
  if not info.total then return UI.Dim("-", 0.3), -1 end
  local text = PL.FormatShort(info.total)
  return online and text or UI.Dim(text, 0.45), floor(info.total / 60)
end

local function Line(tt, left, right)
  tt:AddDoubleLine(left, right, 0.8, 0.8, 0.8, 1, 1, 1)
end

-- the "Time played" part of a roster tooltip
function PL.AddTooltip(tt, key, rec, r)
  local info = PL.Info(key, rec, r, true)
  local UI = ns.UI
  tt:AddLine(" ")
  if info.state ~= "on" then
    local text
    if info.state == "pending" then text = "Reading your time played..."
    elseif info.state == "old" then text = "Time played shows once they update FableHub."
    elseif info.state == "none" then text = "Time played shows once they use FableHub."
    elseif info.mine then text = "Time played not shared (Settings > Privacy)."
    else text = "Time played not shared." end
    tt:AddLine(text, 0.6, 0.6, 0.6)
    return
  end
  tt:AddLine("Time played", ns.Theme.Accent())
  Line(tt, "Total", PL.FormatLong(info.total))
  if info.alts then Line(tt, "With alts", PL.FormatLong(info.alts)) end
  if info.levelKnown then
    if info.thisLevel then Line(tt, "This level", PL.FormatLong(info.thisLevel)) end
    Line(tt, ("Level %d to %d"):format(info.lvl, info.lvl + 1), info.pct .. "%")
    tt:AddLine(PL.Bar(info.xp, info.xpMax, info.rested, 200))
    Line(tt, ("%s / %s XP"):format(PL.Num(info.xp), PL.Num(info.xpMax)),
      info.rested > 0 and (PL.Num(info.rested) .. " rested") or "not rested")
    Line(tt, "XP per hour", info.rate and PL.Num(info.rate) or "-")
    if info.rateKind == "session" then
      tt:AddLine("  this session" .. (info.avg and (" · " .. PL.Num(info.avg) .. " over this level") or ""), 0.6, 0.6, 0.6)
    elseif info.rateKind == "level" then
      tt:AddLine("  average over this level", 0.6, 0.6, 0.6)
    end
    local nextIn = info.nextIn
    Line(tt, "Next level in", not nextIn and "-" or (nextIn > 30 * 86400 and "30d+") or PL.FormatLong(nextIn))
  end
  if not info.mine and info.stale then tt:AddLine("Updated " .. UI.TimeAgo(info.at), 0.6, 0.6, 0.6) end
end
