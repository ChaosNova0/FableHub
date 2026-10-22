-- Diagnostics: "/fhub bug" opens a report to copy into Discord, and
-- "/fhub ping Name" tests whether addon whispers reach a guildmate (the route
-- restricted guild bank tabs use). Built for checking things only the live game
-- can tell us: client build, how names arrive, fonts, recent errors.

local _, ns = ...
local Enc = ns.Encode
local D = {}
ns.Diag = D

local function Count(t)
  local n = 0
  for _ in pairs(t or {}) do n = n + 1 end
  return n
end
D.Count = Count

------------------------------------------------------------------------
-- Names as the chat system sent them, when they didn't match the roster exactly
------------------------------------------------------------------------
D.senders = {} -- [name as received] = roster key, or false when not in the guild
function D.NoteSender(raw, resolved)
  if not raw or raw == resolved then return end
  if D.senders[raw] == nil then
    local n = 0
    for _ in pairs(D.senders) do n = n + 1 end
    if n >= 30 then return end
  end
  D.senders[raw] = resolved or false
end

------------------------------------------------------------------------
-- Traffic: what was sent and refused, and what arrived from whom (raw names)
------------------------------------------------------------------------
D.traffic = { sent = 0, refused = {}, recv = {} }
function D.NoteSend(ok, res, target)
  local t = D.traffic
  if ok and (res == nil or res == true or res == 0) then t.sent = t.sent + 1
  else
    local code = ok and tostring(res) or ("error: " .. tostring(res))
    t.refused[code] = (t.refused[code] or 0) + 1
  end
end
function D.NoteRecv(raw, channel, prefix)
  local key = tostring(raw) .. " (" .. tostring(channel) .. (prefix ~= ns.PREFIX and (", " .. tostring(prefix)) or "") .. ")"
  local r = D.traffic.recv
  if r[key] == nil and D.Count(r) >= 30 then return end
  r[key] = (r[key] or 0) + 1
end

------------------------------------------------------------------------
-- Ping: whisper a guildmate's FableHub and wait for its answer (on the guild
-- channel, so the answer arrives even if whispers to us don't work)
------------------------------------------------------------------------
local pings = {}   -- [id] = { key, form, sent, got }
D.lastPing = nil   -- { target, results = { {form, seconds or nil} } }
local answered = {} -- [sender] = GetTime() of our last answer (rate limit)

local function FindMember(name)
  name = (name or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" then return nil end
  local exact, short, first
  for key in pairs(ns.roster) do
    local k = key:lower()
    local s = ns.ShortName(key):lower()
    if k == name then exact = key end
    if s == name then short = short or key end
    if (s:match("^(%S+)") or s) == name then first = first or key end
  end
  return exact or short or first
end
D.FindMember = FindMember

function D.Ping(name)
  local key = FindMember(name)
  if not key then return ns.Print("No guild member called \"" .. tostring(name) .. "\".") end
  if key == ns.MyKey() then return ns.Print("Ping someone else: you can't whisper yourself.") end
  -- every spelling FableHub might use for a whisper; the game says "No player
  -- named ..." for the ones it doesn't know (hidden from chat, noted here)
  local forms = ns.WhisperCandidates(key)
  D.lastPing = { target = key, online = ns.IsOnline(key), results = {} }
  for i, form in ipairs(forms) do
    local id = Enc.ToB36(math.random(0, 46655)) .. i
    pings[id] = { key = key, form = form, sent = GetTime() }
    D.lastPing.results[i] = { form = form, id = id }
    ns.SendToForm(key, form, "e", id)
  end
  ns.Print(("Pinging %s with %d spelling%s of the name%s..."):format(ns.ShortName(key), #forms, #forms == 1 and "" or "s",
    ns.IsOnline(key) and "" or " (they show as offline)"))
  -- messages go out about one a second: wait for ours to leave the queue, then 8s
  local wait = 8 + (ns.QueueLength and ns.QueueLength() or 0)
  if wait > 10 then ns.Print(("  (results in about %d seconds: other FableHub messages are queued first)"):format(wait)) end
  C_Timer.After(wait, function()
    local worked
    for _, r in ipairs(D.lastPing and D.lastPing.results or {}) do
      local p = pings[r.id]
      r.seconds = p and p.got and (p.got - p.sent) or nil
      r.notFound = p and p.notFound or nil
      if r.seconds and not worked then worked = r.form end
    end
    -- no FableHub answer: a spelling the game didn't refuse still reached them
    if not worked and D.lastPing.online then
      for _, r in ipairs(D.lastPing.results) do
        if not r.notFound then worked = r.form; r.reached = true; break end
      end
    end
    for _, r in ipairs(D.lastPing.results) do
      ns.Print(("  \"%s\": %s"):format(r.form, D.Describe(r)))
    end
    if worked then
      ns.WhisperWorked(key, worked)
      ns.Print(("  FableHub will whisper them as \"%s\"."):format(worked))
    end
    if not ns.present[key] then
      ns.Print("  (they haven't been seen with FableHub this session, so they can't answer; the game still says whether a spelling exists)")
    end
  end)
end

function D.Describe(r)
  if r.seconds then return ("FableHub answered in %.1fs"):format(r.seconds) end
  if r.notFound then return "no such player (the game refused this spelling)" end
  if r.reached then return "reached them (no FableHub answer)" end
  return "no answer"
end

ns.On("WHISPER_FAILED", function(key, form)
  for _, p in pairs(pings) do
    if p.key == key and p.form == form then p.notFound = true end
  end
end)

-- someone pinged us: answer on the guild channel
ns.CommHandlers.e = function(sender, payload)
  local id = (payload or ""):match("^(%w+)$")
  if not id then return end
  -- one ping tries several spellings at once: answer up to 10 per 10 seconds per person
  local now = GetTime()
  local a = answered[sender]
  if not a or now - a.t > 10 then a = { t = now, n = 0 }; answered[sender] = a end
  if a.n >= 10 then return end
  a.n = a.n + 1
  ns.Send("f", id)
end
ns.CommHandlers.f = function(sender, payload)
  local p = pings[(payload or ""):match("^(%w+)$") or ""]
  if p and not p.got then p.got = GetTime() end
end

------------------------------------------------------------------------
-- The report
------------------------------------------------------------------------


local function FontCheck()
  local T = ns.Theme
  if not T or not T.FONT then return "?" end
  local frame = CreateFrame("Frame")
  local fs = frame:CreateFontString()
  local ok, loaded = pcall(fs.SetFont, fs, T.FONT, 12, "")
  local file = T.FONT:match("([^\\/]+)$") or T.FONT
  if ok and loaded then return file .. " loaded (shown " .. (T.FONT_SCALE or 1) .. "x)" end
  return file .. " FAILED to load - using the game's font"
end

function D.Report()
  local L = {}
  local function add(fmt, ...) L[#L + 1] = select("#", ...) > 0 and fmt:format(...) or fmt end

  add("FableHub %s report  -  %s", ns.VERSION or "?", date("%Y-%m-%d %H:%M"))
  add("")

  -- client
  local version, build, bdate, interface
  if GetBuildInfo then version, build, bdate, interface = GetBuildInfo() end
  add("[Client]")
  add("Game version %s (build %s, %s), interface %s", tostring(version), tostring(build), tostring(bdate), tostring(interface))
  add("FableHub.toc says interface 16001: %s", tostring(interface) == "16001" and "matches"
    or "DIFFERENT - the TOC needs updating to " .. tostring(interface))
  local getInfo = C_AddOns and C_AddOns.GetAddOnInfo or GetAddOnInfo
  if getInfo then
    local ok, _, _, _, loadable, reason = pcall(getInfo, "FableHub")
    if ok then add("AddOns list: %s", reason == "INTERFACE_VERSION" and "out of date" or (loadable and "OK" or tostring(reason))) end
  end
  add("Locale %s, UI scale %.2f", GetLocale and GetLocale() or "?", UIParent and UIParent:GetEffectiveScale() or 1)
  add("Font: %s", FontCheck())
  add("")

  -- you and the guild
  add("[You]")
  local uname, urealm = UnitFullName("player")
  add("Character (game): %s-%s", tostring(uname), tostring(urealm or ns.MyRealm()))
  add("Character (roster): %s%s", tostring(ns.MyKey()), ns._myKeyConfirmed and "" or " (not matched to the roster yet)")
  local P = ns.Plans
  local myRank = P and P.RankIndex(ns.MyKey())
  add("Guild: %s  -  rank %s, officer ranks: up to %s%s", tostring(ns.GuildKey()), tostring(myRank),
    tostring(P and P.OfficerRank()), (P and P.CanEdit()) and "  (you're an officer)" or "")
  if ns.IsDeveloper and ns.IsDeveloper() then add("Developer account: yes (test officer mode %s)", P and P.TestMode() and "ON" or "off") end
  add("")

  add("[Guild]")
  local online = 0
  for _, r in pairs(ns.roster) do if r.online then online = online + 1 end end
  add("Roster: %d members, %d online", Count(ns.roster), online)
  local versions, users = {}, 0
  for _, ver in pairs(ns.present) do
    users = users + 1
    versions[ver] = (versions[ver] or 0) + 1
  end
  local vl = {}
  for ver, n in pairs(versions) do vl[#vl + 1] = ver .. " x" .. n end
  table.sort(vl)
  add("FableHub seen this session: %d (%s)", users, #vl > 0 and table.concat(vl, ", ") or "none yet")
  if ns.updateAvailable then add("Update available: %s", ns.updateAvailable) end
  add("Message channel: %s, data era %d", tostring(ns.PREFIX), ns.DATA_EPOCH or 1)
  add("")

  add("[Names as received]")
  local any = false
  for raw, key in pairs(D.senders) do
    any = true
    add("%s  ->  %s", raw, key and key or "NOT MATCHED to the guild roster")
  end
  if not any then add("All senders matched the roster exactly.") end
  local gw = ns.GuildDB and ns.GuildDB()
  for key, form in pairs(gw and gw.whisperNames or {}) do add("whispers to %s go to \"%s\"", key, form) end
  add("")

  if D.lastPing then
    add("[Last ping: %s, %s]", D.lastPing.target, D.lastPing.online and "online" or "offline")
    for _, r in ipairs(D.lastPing.results) do
      add("\"%s\": %s", r.form, D.Describe(r))
    end
    add("")
  end

  add("[Traffic]")
  local t = D.traffic
  local refused = {}
  for code, n in pairs(t.refused) do refused[#refused + 1] = "code " .. code .. " x" .. n end
  add("Sent %d messages%s", t.sent, #refused > 0 and ("; refused: " .. table.concat(refused, ", ")) or ", none refused")
  local rl = {}
  for who, n in pairs(t.recv) do rl[#rl + 1] = who .. " x" .. n end
  table.sort(rl)
  if #rl == 0 then add("Received: nothing yet")
  else for _, line in ipairs(rl) do add("Received from %s", line) end end
  add("Key realm: %s (character realm %s)", ns.KeyRealm and ns.KeyRealm() or "?", ns.MyRealm())
  local state = ns.GuildChannelState and ns.GuildChannelState() or "?"
  if state == "muted" then
    local peers = ns.WhisperPeers and ns.WhisperPeers(false) or {}
    add("Guild channel: our messages don't come back, so sending by whisper to %d FableHub user(s) online", #peers)
  else
    add("Guild channel: %s", state == "ok" and "working (our messages come back)" or state)
  end
  add("")

  add("[Saved data]")
  local g = ns.GuildDB and ns.GuildDB()
  if g then
    local signups = 0
    for _, list in pairs(g.signups or {}) do signups = signups + Count(list) end
    add("Members %d, raid nights %d, sign-ups %d, loot %d, craft requests %d, alts %d, bank tabs %d",
      Count(g.members), Count(g.events), signups, Count(g.loot), Count(g.requests), Count(g.alts),
      Count(g.bank and g.bank.tabs))
  else
    add("No guild data (not in a guild?)")
  end
  add("Messages waiting to send: %d", ns.QueueLength and ns.QueueLength() or 0)
  add("")

  add("[Recent errors]")
  local errs = FableHubDB and FableHubDB.errors or {}
  if #errs == 0 then add("None.") end
  for i = #errs, math.max(1, #errs - 9), -1 do
    local e = errs[i]
    add("%s  v%s  x%d  %s", date("%m-%d %H:%M", e.t or 0), tostring(e.v), e.n or 1, tostring(e.msg))
  end
  return table.concat(L, "\n")
end

------------------------------------------------------------------------
-- Window (its own small frame, so it works even if the main window doesn't)
------------------------------------------------------------------------
local frame
function D.Show()
  local T = ns.Theme
  if not frame then
    frame = CreateFrame("Frame", "FableHubReportFrame", UIParent)
    frame:SetSize(620, 460)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    T.Fill(frame, { T.bg[1], T.bg[2], T.bg[3], 1 })
    T.Border(frame, 0.15)
    local title = T.Text(frame, 15, 1)
    title:SetPoint("TOPLEFT", 14, -12)
    title:SetText("FableHub report")
    local help = T.Text(frame, 11, 0.6)
    help:SetPoint("TOPLEFT", 14, -34)
    help:SetText("The text is selected: press Ctrl+C to copy it, then paste it in Discord.")
    local close = T.CloseButton(frame, function() frame:Hide() end)
    close:SetPoint("TOPRIGHT", -8, -8)

    local box = CreateFrame("Frame", nil, frame)
    box:SetPoint("TOPLEFT", 12, -56)
    box:SetPoint("BOTTOMRIGHT", -12, 44)
    T.Fill(box, T.input)
    T.Border(box, 0.1)
    local scroll = CreateFrame("ScrollFrame", nil, box)
    scroll:SetPoint("TOPLEFT", 8, -8)
    scroll:SetPoint("BOTTOMRIGHT", -8, 8)
    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetMaxLetters(0)
    T.SetFont(edit, 11)
    edit:SetTextColor(1, 1, 1, 0.85)
    edit:SetWidth(570)
    edit:SetScript("OnEscapePressed", function() frame:Hide() end)
    -- read-only: typing puts the report back
    edit:SetScript("OnTextChanged", function(self, user) if user then self:SetText(frame.text or ""); self:HighlightText() end end)
    scroll:SetScrollChild(edit)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
      local max = math.max(0, (edit:GetHeight() or 0) - (self:GetHeight() or 0))
      self:SetVerticalScroll(math.max(0, math.min(max, (self:GetVerticalScroll() or 0) - delta * 40)))
    end)
    box:EnableMouse(true)
    box:SetScript("OnMouseDown", function() edit:SetFocus(); edit:HighlightText() end)
    frame.edit = edit

    local refresh = T.Button(frame, "Refresh", 90, 24)
    refresh:SetPoint("BOTTOMRIGHT", -12, 12)
    refresh:SetScript("OnClick", function() D.Show() end)
    local clear = T.Button(frame, "Clear errors", 110, 24)
    clear:SetPoint("RIGHT", refresh, "LEFT", -6, 0)
    clear:SetScript("OnClick", function() if FableHubDB then FableHubDB.errors = nil end; D.Show() end)
    if UISpecialFrames then table.insert(UISpecialFrames, "FableHubReportFrame") end
  end
  frame.text = D.Report()
  frame.edit:SetText(frame.text)
  frame:Show()
  frame.edit:SetFocus()
  frame.edit:HighlightText()
end

ns.SlashHandlers.bug = function() D.Show() end
ns.SlashHandlers.report = ns.SlashHandlers.bug
ns.SlashHandlers.ping = function(rest)
  if rest == "" then return ns.Print("Usage: /fhub ping Name  (tests whether FableHub whispers reach them)") end
  D.Ping(rest)
end
