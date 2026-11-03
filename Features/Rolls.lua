-- Rolls: the master looter (or an officer with the award window open) asks the
-- group to /roll for an item, and FableHub collects the results for the award window.
--
-- Who's who in the group (R.Group) is worked out from the group itself, never
-- from the guild roster's loose name matching:
--   group.members[id] = { id, unit, name, key }
--     id    the exact name the group roster gives ("Bob", "Bob-OtherRealm", "Anna-Smith")
--     name  how to show them ("Anna Smith", "Bob-OtherRealm")
--     key   their guild key, only on an exact match (GUID, or full name), else nil (a pug)
--   group.alias[spelling] = id, or false when two people share that spelling
--     (every spelling the game may use for them: roster name, first name,
--      "First Last", "Name-Realm"); a spelling shared by two is never used
--   group.byKey[guild key] = id (false if two group members claim the same key)
-- Worked out again after a group or guild roster change, or when 5 s old.
--
-- R.current / R.last[tag] = { item, tag, started, ends, open,
--     rolls = { [id] = { roll, low, high, tier, at, again, name, key } }, n }
--   tier: 1 main spec (/roll 100), 2 off spec (/roll 99), 3 any other range
--   again: how many extra times they rolled (only the first roll counts)
--   tag: which drop the roll is for (the award window passes one per drop, so
--        two copies of the same item get a roll each); defaults to the item id
-- Kept for this session only.
--
-- Roll popups. Whoever starts a roll (an officer with loot permission) tells the
-- group over the raid / party addon channel (message o, see Comm.lua), and
-- FableHub users there get a popup with Main spec / Off spec / Pass buttons:
--   o  "1^S^<rid>^<itemID>^<ms>^<os>^<endsAt>"   a roll started (endsAt: ns.Now() time)
--      "1^E^<rid>"                               it ended early
--      "1^X^<rid>"                               it was cancelled
--   (a roll that runs its whole length costs one message: popups close themselves)
-- R.incoming = { from (guild key), rid, item, ms, os, endsAt, localEnds, own } the one
--   popup showing (own: we started the roll ourselves; shown without a message)
-- R.dismissed["<from>#<rid>"] = true  popups already rolled on, passed or closed
-- A popup only opens for a start that:
--   came from someone in our group right now, by the exact name the game gave
--   the message, who is a guild member by GUID (or exact name, see GuildKeyOf)
--   and may use Loot (P.IsOfficer by real guild rank);
--   has an item id, ranges (2 <= off < main <= 1000) and an end 1-125 s away;
--   is within 10 starts a minute (2 s apart) from that sender, and wasn't dismissed.
-- The item's name comes from our own game, never the message. The buttons do a
-- real /roll, so rolls are still only counted from the game's roll message.
-- Nothing is ever sent back: Pass only closes the popup.
--
-- Rules:
-- - Nothing else is sent over the addon channel and nothing is saved: rolls live
--   only on the client that started them. Announcements go to raid (or party)
--   chat, and a raid warning when we're allowed to send one.
-- - Rolls are read only from the game's own system message ("X rolls N (1-100)"),
--   which players can't fake. The name must be exactly a group member's (any
--   spelling shared by two members is ignored), only their first roll counts,
--   and nothing is collected after the roll closes.
-- - One roll at a time: starting another closes the open one (announced as usual).
--   A short cooldown between starts stops repeated clicks flooding the chat.
-- - The closing message only names main or off spec rolls from people still in the group.
--   With none it says "Nobody rolled." (no main or off spec rolls at all) or
--   "No one still in the group rolled." (everyone who made one has left).

local _, ns = ...
local R = {}
ns.Rolls = R

R.MS, R.OS = 100, 99            -- /roll 100 for main spec, /roll 99 for off spec
R.TIER_MS, R.TIER_OS, R.TIER_OTHER = 1, 2, 3
R.LENGTHS = { 10, 15, 20, 30, 45 }
R.DEFAULT_LENGTH = 20
R.MAX_ROLLS = 80                -- more than a 40-player raid can make; caps a flood
R.START_COOLDOWN = 3            -- seconds between starting rolls
R.MAX_TIE_NAMES = 5             -- the closing message names this many tied players
R.last = {}

local gen = 0                   -- bumps on every start/stop/cancel so old timers do nothing
local lastStartAt = -1e9
local ridSeq                 -- (started from the clock, so loading doesn't use up math.random)
local function NewRid()      -- a roll's id in popup messages (base 36, up to 4 characters)
  ridSeq = ((ridSeq or math.floor(GetTime() * 1000)) + 1) % 1679616
  return ns.Encode.ToB36(ridSeq)
end

function R.Length()
  local s = FableHubDB and FableHubDB.settings
  local v = s and tonumber(s.rollSeconds)
  if v and v >= 5 and v <= 120 then return math.floor(v) end
  return R.DEFAULT_LENGTH
end

function R.SetLength(seconds)
  seconds = tonumber(seconds)
  if not seconds or seconds < 5 or seconds > 120 then return end
  FableHubDB.settings.rollSeconds = math.floor(seconds)
  ns.Fire("OPTIONS_CHANGED", "rollSeconds")
end

------------------------------------------------------------------------
-- Telling the window something changed: at most one redraw per burst of
-- rolls (a raid all rolling at once), plus a light once-a-second tick for
-- the countdown (ROLLS_TICK)
------------------------------------------------------------------------
local changePending = false
local function Changed()
  if changePending then return end
  changePending = true
  C_Timer.After(0.25, function()
    changePending = false
    ns.Fire("ROLLS_CHANGED")
  end)
end
R.Changed = Changed

------------------------------------------------------------------------
-- Who's in the group
------------------------------------------------------------------------
local function Secret(v) return issecretvalue and v ~= nil and issecretvalue(v) end

local guidKeys, guidKeysFor -- GUID -> guild key, rebuilt when the roster table changes
local function GuildKeyByGuid(guid)
  if not guid or Secret(guid) then return nil end
  if guidKeysFor ~= ns.roster then
    guidKeys, guidKeysFor = {}, ns.roster
    for key, r in pairs(ns.roster) do if r.guid then guidKeys[r.guid] = key end end
  end
  local key = guidKeys[guid]
  if key == false then return nil end -- (a pug we already looked for)
  if key and ns.roster[key] then return key end
  -- (a member who joined since: look them up directly)
  for k, r in pairs(ns.roster) do if r.guid == guid then guidKeys[guid] = k return k end end
  guidKeys[guid] = false
end

-- A group member's guild key on an exact match only: their GUID, or their full
-- name when the game won't give us their GUID. A name match is refused when
-- both GUIDs are known and differ, so a pug sharing a guild member's name (on
-- another realm, or a connected one) never becomes that guild member.
local function GuildKeyOf(guid, n, r)
  local key = GuildKeyByGuid(guid)
  if key then return key end
  if not n then return nil end
  local knownGuid = guid and not Secret(guid)
  local function ByName(k)
    local entry = k and ns.roster[k]
    if not entry then return nil end
    if knownGuid and entry.guid and entry.guid ~= guid then return nil end
    return k
  end
  if r and r ~= "" then
    -- Forever puts a last name where the realm goes
    local full = ByName(ns.NormalizeName(n .. " " .. r))
    if full then return full end
    if r == ns.KeyRealm() or r == ns.MyRealm() then return ByName(ns.NormalizeName(n)) end
    return nil
  end
  return ByName(ns.NormalizeName(n))
end
R.GuildKeyOf = GuildKeyOf

local group, groupAt = nil, -1e9
local function Invalidate() group = nil end
R.Invalidate = Invalidate

local function UnitParts(unit)
  if not UnitName then return nil end
  local n, r = UnitName(unit)
  if Secret(n) or Secret(r) then return nil end
  if n == nil or n == "" or n == UNKNOWNOBJECT then return nil end
  return n, r
end

local function Build()
  local g = { members = {}, alias = {}, byKey = {}, n = 0 }
  local spellings = {} -- [id] = the other spellings the game may use for them
  -- someone's exact roster name is theirs; the other spellings only count
  -- while no one else in the group could be meant
  local function Alias(spelling, id)
    if not spelling or spelling == "" or g.members[spelling] then return end
    local cur = g.alias[spelling]
    if cur == nil then g.alias[spelling] = id
    elseif cur ~= id then g.alias[spelling] = false end
  end
  local function Add(unit, rosterName)
    local n, r = UnitParts(unit)
    if rosterName and Secret(rosterName) then rosterName = nil end
    local id = rosterName or (n and ((r and r ~= "") and (n .. "-" .. r) or n))
    if not id or g.members[id] then return end
    local guid = UnitGUID and UnitGUID(unit)
    local key = GuildKeyOf(guid, n, r)
    local name = key and ns.ShortName(key) or (n and r and r ~= "" and (n .. "-" .. r)) or id
    local classFile
    if UnitClass then classFile = select(2, UnitClass(unit)) end
    if Secret(classFile) then classFile = nil end
    g.members[id] = { id = id, unit = unit, name = name, key = key, class = classFile }
    g.n = g.n + 1
    local list = {}
    if n then
      list[#list + 1] = n
      if r and r ~= "" then list[#list + 1] = n .. "-" .. r; list[#list + 1] = n .. " " .. r
      else
        -- (someone on our own realm: addon messages name them "Name-Realm")
        list[#list + 1] = n .. "-" .. ns.MyRealm()
        list[#list + 1] = n .. "-" .. ns.KeyRealm()
      end
    end
    if key then
      list[#list + 1] = ns.ShortName(key)
      list[#list + 1] = key
      if g.byKey[key] == nil then g.byKey[key] = id elseif g.byKey[key] ~= id then g.byKey[key] = false end
    end
    spellings[id] = list
  end
  if IsInRaid and IsInRaid() then
    for i = 1, (GetNumGroupMembers and GetNumGroupMembers()) or 0 do
      local name = GetRaidRosterInfo and GetRaidRosterInfo(i)
      Add("raid" .. i, name)
    end
  elseif IsInGroup and IsInGroup() then
    Add("player")
    for i = 1, 4 do
      if not UnitExists or UnitExists("party" .. i) then Add("party" .. i) end
    end
  end
  -- two people claiming one guild member: neither is them
  for key, id in pairs(g.byKey) do
    if id == false then
      for _, m in pairs(g.members) do if m.key == key then m.key, m.name = nil, m.id end end
    end
  end
  for id in pairs(g.members) do g.alias[id] = id end
  for id, list in pairs(spellings) do
    for _, s in ipairs(list) do Alias(s, id) end
  end
  return g
end

-- the group (rebuilt after a roster change, or when a few seconds old)
function R.Group()
  if not group or GetTime() - groupAt > 5 then
    group, groupAt = Build(), GetTime()
  end
  return group
end

-- a spelling of a name (roll line, master loot candidate) -> the member, or nil
-- when nobody in the group has it or two people share it
function R.Lookup(spelling)
  if type(spelling) ~= "string" or Secret(spelling) then return nil end
  local g = R.Group()
  local id = g.alias[spelling]
  return id and g.members[id] or nil
end

-- the group member who is guild member `key` (nil if none, or two claim it)
function R.MemberByKey(key)
  local id = key and R.Group().byKey[key]
  return id and R.Group().members[id] or nil
end

-- guild keys of everyone in the group (for "not in raid" marks)
function R.GroupKeys()
  local out = {}
  for _, m in pairs(R.Group().members) do if m.key then out[m.key] = true end end
  return out
end

ns.RegisterEvent("GROUP_ROSTER_UPDATE", function()
  Invalidate()
  if R.current and R.current.open then Changed() end
  -- a popup from someone no longer with us (or we left the group) closes
  local inc = R.incoming
  if inc and (not ((IsInRaid and IsInRaid()) or (IsInGroup and IsInGroup()))
              or (not inc.own and not R.GroupKeys()[inc.from])) then
    R.ClosePopup()
  end
end)
-- who's a guild member can change with the guild roster: the group is worked
-- out again the next time it's asked for (the roster itself is rebuilt a moment
-- after the event, see Core.lua, hence ROSTER_CHANGED too)
ns.RegisterEvent("GUILD_ROSTER_UPDATE", Invalidate)
ns.On("ROSTER_CHANGED", Invalidate)

------------------------------------------------------------------------
-- Chat
------------------------------------------------------------------------
local function InGroup()
  return (IsInRaid and IsInRaid()) or (IsInGroup and IsInGroup()) or false
end

-- raid warning if we may send one, otherwise raid or party chat
local function Channel(warning)
  if IsInRaid and IsInRaid() then
    if warning and ((UnitIsGroupLeader and UnitIsGroupLeader("player")) or (UnitIsGroupAssistant and UnitIsGroupAssistant("player"))) then
      return "RAID_WARNING"
    end
    return "RAID"
  end
  if IsInGroup and IsInGroup() then return "PARTY" end
end
R.Channel = Channel

local function Say(msg, warning)
  local chan = Channel(warning)
  if chan and SendChatMessage then pcall(SendChatMessage, msg, chan) end
end

local function ItemLink(itemID)
  local info = ns.Loot and ns.Loot.ItemInfo(itemID)
  return (info and info.link) or ("item " .. tostring(itemID))
end

------------------------------------------------------------------------
-- Reading "/roll" results
------------------------------------------------------------------------
-- The game's text is RANDOM_ROLL_RESULT ("%s rolls %d (%d-%d)" in English).
-- Built into a pattern from the client's own string, so other languages work too.
local rollPattern
local function RollPattern()
  if rollPattern then return rollPattern end
  local fmt = type(RANDOM_ROLL_RESULT) == "string" and RANDOM_ROLL_RESULT or "%s rolls %d (%d-%d)"
  -- some clients number their placeholders (%1$s); drop the numbers
  fmt = fmt:gsub("%%%d%$", "%%")
  local p = fmt:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
  p = p:gsub("%%s", "(.+)"):gsub("%%d", "(%%d+)")
  rollPattern = "^" .. p .. "$"
  return rollPattern
end

-- "Name rolls 57 (1-100)" -> "Name", 57, 1, 100
function R.ParseRoll(msg)
  if type(msg) ~= "string" or Secret(msg) or #msg > 200 then return end
  local who, roll, low, high = msg:match(RollPattern())
  roll, low, high = tonumber(roll), tonumber(low), tonumber(high)
  if not who or not roll or not low or not high or #who > 60 then return end
  return who, roll, low, high
end

function R.TierOf(low, high)
  if low ~= 1 then return R.TIER_OTHER end
  if high == R.MS then return R.TIER_MS end
  if high == R.OS then return R.TIER_OS end
  return R.TIER_OTHER
end

-- returns true when the roll was counted
function R.OnRoll(msg)
  local cur = R.current
  if not cur or not cur.open then return false end
  local who, roll, low, high = R.ParseRoll(msg)
  if not who or roll < low or roll > high then return false end
  local m = R.Lookup(who)
  if not m then return false end
  local r = cur.rolls[m.id]
  if r then
    r.again = (r.again or 0) + 1
    if r.again <= 3 then Changed() end -- (a /roll macro gets no more redraws)
    return false
  end
  if cur.n >= R.MAX_ROLLS then return false end
  cur.rolls[m.id] = { roll = roll, low = low, high = high, tier = R.TierOf(low, high), at = GetTime(),
                      name = m.name, key = m.key }
  cur.n = cur.n + 1
  Changed()
  return true
end

ns.RegisterEvent("CHAT_MSG_SYSTEM", function(msg)
  R.OnRoll(msg)
  -- our own /roll (typed, or from the popup) closes the popup
  if R.incoming then
    local who = R.ParseRoll(msg)
    local m = who and R.Lookup(who)
    if m and (m.unit == "player" or (m.key ~= nil and m.key == ns.MyKey())) then R.ClosePopup() end
  end
end)

------------------------------------------------------------------------
-- Starting and stopping
------------------------------------------------------------------------
-- tag: which drop this roll is for (default: the item id)
function R.Start(itemID, seconds, tag)
  itemID = tonumber(itemID)
  if not itemID then return false, "No item to roll for." end
  if not InGroup() then return false, "You need to be in a raid or party to start a roll." end
  if GetTime() - lastStartAt < R.START_COOLDOWN then return false, "Wait a moment before starting another roll." end
  if R.current and R.current.open then R.Stop(true) end
  lastStartAt = GetTime()
  Invalidate()
  seconds = tonumber(seconds) or R.Length()
  seconds = math.max(5, math.min(120, math.floor(seconds)))
  tag = tag or itemID
  gen = gen + 1
  local my = gen
  local now = GetTime()
  local rid = NewRid()
  R.current = { item = itemID, tag = tag, started = now, ends = now + seconds, open = true, rolls = {}, n = 0,
                rid = rid, endsAt = ns.Now() + seconds }
  R.last[tag] = R.current
  Say(("Roll for %s: /roll %d main spec, /roll %d off spec (%d sec)"):format(ItemLink(itemID), R.MS, R.OS, seconds), true)
  -- popups for FableHub users in the group, and for ourselves
  if ns.Plans.CanEdit("loot") and ns.SendGroup then
    ns.SendGroup("o", ("1^S^%s^%d^%d^%d^%d"):format(rid, itemID, R.MS, R.OS, R.current.endsAt), seconds)
  end
  if ns.Option("rollPopup") then
    R.ShowPopup({ own = true, from = ns.MyKey() or "?", rid = rid, item = itemID, ms = R.MS, os = R.OS,
                  endsAt = R.current.endsAt, localEnds = now + seconds })
  end
  if seconds > 5 then
    C_Timer.After(seconds - 5, function()
      if gen == my and R.current and R.current.open then Say(("5 seconds left to roll for %s"):format(ItemLink(itemID))) end
    end)
  end
  C_Timer.After(seconds, function() if gen == my then R.Stop() end end)
  -- a once-a-second tick so the countdown on screen moves (no full redraw)
  local function Tick()
    if gen ~= my or not (R.current and R.current.open) then return end
    ns.Fire("ROLLS_TICK")
    C_Timer.After(1, Tick)
  end
  C_Timer.After(1, Tick)
  ns.Fire("ROLLS_CHANGED")
  return true
end

-- main and off spec rolls from people still in the group, best first
local function Winners(roll)
  local present = R.Group().members
  local out = {}
  for _, e in ipairs(R.Sorted(roll)) do
    if e.tier ~= R.TIER_OTHER and present[e.id] then out[#out + 1] = e end
  end
  return out
end

-- replaced: closing because another roll is starting (its start replaces the
-- popups, so no "ended" message is needed)
function R.Stop(replaced)
  local cur = R.current
  if not cur or not cur.open then return end
  gen = gen + 1
  cur.open = false
  cur.ended = GetTime()
  Invalidate()
  -- ended early: popups close now, not at the time they were given
  if not replaced and cur.rid and cur.endsAt and cur.endsAt - ns.Now() > 1 and ns.SendGroup
     and ns.Plans.CanEdit("loot") then
    ns.SendGroup("o", "1^E^" .. cur.rid, 10)
  end
  local inc = R.incoming
  if inc and inc.own and inc.rid == cur.rid then R.ClosePopup() end
  local list = Winners(cur)
  local top = list[1]
  local link = ItemLink(cur.item)
  if top and list[2] and list[2].tier == top.tier and list[2].roll == top.roll then
    local names, more = {}, 0
    for _, e in ipairs(list) do
      if e.tier == top.tier and e.roll == top.roll then
        if #names < R.MAX_TIE_NAMES then names[#names + 1] = e.name else more = more + 1 end
      end
    end
    local who = table.concat(names, ", ") .. (more > 0 and (" and " .. more .. " more") or "")
    Say(("Rolls closed for %s. Tie at %d: %s"):format(link, top.roll, who))
  elseif top then
    Say(("Rolls closed for %s. Highest: %s %d%s"):format(link, top.name, top.roll,
      top.tier == R.TIER_OS and " (off spec)" or ""))
  else
    -- main or off spec rolls, but everyone who made one has left the group
    local anyRolled = false
    for _, r in pairs(cur.rolls) do
      if r.tier ~= R.TIER_OTHER then anyRolled = true break end
    end
    if anyRolled then
      Say(("Rolls closed for %s. No one still in the group rolled."):format(link))
    else
      Say(("Rolls closed for %s. Nobody rolled."):format(link))
    end
  end
  ns.Fire("ROLLS_CHANGED")
end

-- Cancel the roll for drop `tag` (default: the open one). An open roll is
-- called off in chat; a closed one is just forgotten.
function R.Cancel(tag)
  local cur = R.current
  if tag == nil and cur then tag = cur.tag end
  if tag == nil then return end
  local roll = R.last[tag]
  if not roll then return end
  R.last[tag] = nil
  if cur == roll then
    gen = gen + 1
    R.current = nil
    if roll.open then
      Say(("Roll for %s cancelled."):format(ItemLink(roll.item)))
      if roll.rid and ns.SendGroup and ns.Plans.CanEdit("loot") then ns.SendGroup("o", "1^X^" .. roll.rid, 10) end
    end
    local inc = R.incoming
    if inc and inc.own and inc.rid == roll.rid then R.ClosePopup() end
  end
  ns.Fire("ROLLS_CHANGED")
end

------------------------------------------------------------------------
-- Roll popups (see the header; the window is UI/RollPopup.lua)
------------------------------------------------------------------------
R.dismissed = {}
local dismissedCount = 0
local startsFrom = {}  -- [sender key] = { GetTime() of their recent starts }
local START_LIMIT, START_WINDOW, START_GAP = 10, 60, 2

function R.ShowPopup(inc)
  R.incoming = inc
  local my = inc
  -- closes by itself at the end, whether or not the window is showing
  C_Timer.After(math.max(0, inc.localEnds - GetTime()) + 0.5, function()
    if R.incoming == my then R.ClosePopup() end
  end)
  ns.Fire("ROLL_POPUP")
end

function R.ClosePopup()
  local inc = R.incoming
  if not inc then return end
  if dismissedCount >= 50 then R.dismissed, dismissedCount = {}, 0 end
  R.dismissed[inc.from .. "#" .. inc.rid] = true
  dismissedCount = dismissedCount + 1
  R.incoming = nil
  ns.Fire("ROLL_POPUP")
end

-- the popup's buttons: "ms" or "os" does a real /roll with the ranges in our own code
function R.PopupRoll(kind)
  local inc = R.incoming
  if not inc then return end
  local high = kind == "ms" and R.MS or R.OS
  if not (RandomRoll and pcall(RandomRoll, 1, high)) then
    ns.Print(("Couldn't roll for you: type /roll %d instead."):format(high))
  end
  R.ClosePopup()
end

-- a sample popup (local only), so people can place it before raid night
function R.TestPopup(itemID)
  local now = GetTime()
  R.ShowPopup({ own = true, test = true, from = ns.MyKey() or "?", rid = "test" .. math.floor(now), item = itemID or 19019,
                ms = R.MS, os = R.OS, endsAt = ns.Now() + 20, localEnds = now + 20 })
end

local function AllowStart(who)
  local now = GetTime()
  local list = startsFrom[who] or {}
  local kept = {}
  for _, t in ipairs(list) do if now - t < START_WINDOW then kept[#kept + 1] = t end end
  startsFrom[who] = kept
  if #kept >= START_LIMIT or (kept[#kept] and now - kept[#kept] < START_GAP) then return false end
  kept[#kept + 1] = now
  return true
end

-- who: the sender's guild key by exact name (Comm.lua), or nil (for example an
-- officer on a connected realm); raw: the name the game gave the message.
-- The sender must be the group member with that name, and that member must be
-- the guild member by GUID (or exact name): a stranger sharing an officer's
-- name is a different group member, with no guild key.
ns.GroupHandlers.o = function(who, payload, channel, raw)
  if not ns.Option("rollPopup") or not InGroup() then return end
  if type(payload) ~= "string" or #payload > 100 then return end
  local m = R.Lookup(raw)
  if not m or not m.key or m.unit == "player" then return end
  if who and who ~= m.key then return end
  who = m.key
  if who == ns.MyKey() then return end
  if not ns.Plans.IsOfficer(who, "loot") then return end
  local kind = payload:match("^1%^(%u)%^")
  if kind == "S" then
    local rid, item, ms, os, endsAt = payload:match("^1%^S%^(%w%w?%w?%w?)%^(%d+)%^(%d+)%^(%d+)%^(%d+)$")
    item, ms, os, endsAt = tonumber(item), tonumber(ms), tonumber(os), tonumber(endsAt)
    if not rid or not item or item < 1 or item > 999999 then return end
    if not ms or not os or os < 2 or os >= ms or ms > 1000 then return end
    local left = endsAt and (endsAt - ns.Now())
    if not left or left <= 1 or left > 125 then return end
    if R.dismissed[who .. "#" .. rid] then return end
    if R.incoming and R.incoming.from == who and R.incoming.rid == rid then return end
    if not AllowStart(who) then return end
    -- (the buttons always roll our own MS / OS ranges, never ones from the message)
    R.ShowPopup({ from = who, rid = rid, item = item, ms = R.MS, os = R.OS, endsAt = endsAt, localEnds = GetTime() + left })
  elseif kind == "E" or kind == "X" then
    local rid = payload:match("^1%^[EX]%^(%w%w?%w?%w?)$")
    local inc = R.incoming
    if rid and inc and inc.from == who and inc.rid == rid then R.ClosePopup() end
  end
end

ns.On("OPTIONS_CHANGED", function(key)
  if key == "rollPopup" and not ns.Option("rollPopup") then R.ClosePopup() end
end)

function R.SecondsLeft()
  local cur = R.current
  if not cur or not cur.open then return 0 end
  return math.max(0, math.ceil(cur.ends - GetTime()))
end

-- the roll (open or finished) for a drop, if there is one this session
function R.For(tag)
  if tag == nil then return nil end
  return R.last[tag]
end

-- main spec first, then off spec, then other ranges; highest roll first, then
-- whoever rolled first. Each entry: { id, name, key, roll, low, high, tier, again, tie }
function R.Sorted(roll)
  local out = {}
  if not roll then return out end
  for id, r in pairs(roll.rolls) do
    out[#out + 1] = { id = id, name = r.name, key = r.key, roll = r.roll, low = r.low, high = r.high,
                      tier = r.tier, again = r.again, at = r.at }
  end
  table.sort(out, function(a, b)
    if a.tier ~= b.tier then return a.tier < b.tier end
    if a.roll ~= b.roll then return a.roll > b.roll end
    if a.at ~= b.at then return a.at < b.at end
    return a.id < b.id
  end)
  -- mark a tie for the top spot
  if out[2] and out[1].tier == out[2].tier and out[1].roll == out[2].roll and out[1].tier ~= R.TIER_OTHER then
    for _, e in ipairs(out) do
      if e.tier == out[1].tier and e.roll == out[1].roll then e.tie = true end
    end
  end
  return out
end
