-- Announcements: short officer posts shown on the Home page.
-- They disappear after 14 days unless pinned; pinned ones stay until unpinned or deleted.
--
-- g.announcements[id] = { id, by, text, created, ts, pinned, deleted }

local _, ns = ...
local Enc, P = ns.Encode, ns.Plans
local A = {}
ns.Announce = A

A.EXPIRE = 14 * 86400
A.MAX_LEN = 200

local function All()
  local g = ns.GuildDB()
  if not g then return {} end
  g.announcements = g.announcements or {}
  return g.announcements
end
A.All = All

function A.Visible(a)
  if a.deleted then return false end
  return a.pinned or ns.Now() - (a.created or 0) <= A.EXPIRE
end

-- newest first, pinned on top
function A.List()
  local out = {}
  for _, a in pairs(All()) do if A.Visible(a) then out[#out + 1] = a end end
  table.sort(out, function(x, y)
    if (x.pinned and true or false) ~= (y.pinned and true or false) then return x.pinned and true or false end
    return (x.created or 0) > (y.created or 0)
  end)
  return out
end

local function Safe(s) return (tostring(s or ""):gsub("[%^|]", " ")) end

local function Encode(a)
  return table.concat({ "1", Safe(a.id), Safe(a.by), Enc.ToB36(a.created or 0), Enc.ToB36(a.ts or 0),
    a.pinned and "1" or "0", a.deleted and "1" or "0", Safe(a.text) }, "^")
end

local function Decode(text)
  local f = Enc.Split(text, "^")
  if f[1] ~= "1" or not f[2] or f[2] == "" then return nil end
  -- the text may itself contain "^"-free content only (we strip it), so field 8 is the rest
  return { id = f[2], by = f[3], created = Enc.FromB36(f[4]), ts = Enc.FromB36(f[5]), pinned = f[6] == "1" or nil,
           deleted = f[7] == "1" or nil, text = f[8] or "" }
end

local function Save(a)
  if not P.CanEdit("announce") then return nil end
  a.ts = math.max(ns.Now(), (a.ts or 0) + 1)
  a.editor = ns.MyKey()
  All()[a.id] = a
  ns.Send("Z", Encode(a) .. "^" .. Safe(a.editor))
  ns.Fire("ANNOUNCE_CHANGED")
  return a
end

local counter = 0
function A.Post(text, pinned)
  text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return nil end
  counter = counter + 1
  return Save({ id = "a" .. Enc.ToB36(ns.Now()) .. counter, by = ns.MyKey(), text = text:sub(1, A.MAX_LEN),
                created = ns.Now(), pinned = pinned and true or nil })
end

function A.SetPinned(a, pinned)
  local c = {}
  for k, v in pairs(a) do c[k] = v end
  c.pinned = pinned and true or nil
  return Save(c)
end

function A.Delete(a)
  local c = {}
  for k, v in pairs(a) do c[k] = v end
  c.deleted = true
  return Save(c)
end

ns.CommHandlers.Z = function(sender, payload)
  local a = Decode(payload)
  if not a then return end
  local editor = Enc.Split(payload, "^")[9]
  if not ns.OfficerSent(sender, editor, "announce") or not ns.TimeOK(a.ts) then return end
  local cur = All()[a.id]
  if cur and (cur.ts or 0) >= a.ts then return end
  a.editor = editor
  All()[a.id] = a
  ns.Fire("ANNOUNCE_CHANGED")
end

local function Counted()
  local n, maxTs = 0, 0
  for _, a in pairs(All()) do
    if A.Visible(a) then n = n + 1 end
    if (a.ts or 0) > maxTs then maxTs = a.ts end
  end
  return n, maxTs
end

function A.SendDigest()
  local n, maxTs = Counted()
  ns.Send("J", "1^" .. Enc.ToB36(maxTs) .. "^" .. n)
end

ns.CommHandlers.J = function(sender, payload)
  if not ns.AmOfficerRelayFor(sender) then return end -- officer data: officers pass it on
  local f = Enc.Split(payload, "^")
  local theirs = Enc.FromB36(f[2])
  local theirN = tonumber(f[3])
  local everything = theirN and theirN < Counted() -- they're missing some older ones
  for _, a in pairs(All()) do
    if (everything and A.Visible(a) or (a.ts or 0) > theirs) and (A.Visible(a) or a.deleted) then
      ns.Send("Z", Encode(a) .. "^" .. Safe(a.editor or a.by))
    end
  end
end

local function Prune()
  local all = All()
  for id, a in pairs(all) do
    if (a.deleted and ns.Now() - (a.ts or 0) > 30 * 86400) or (not a.pinned and ns.Now() - (a.created or 0) > A.EXPIRE + 30 * 86400) then
      all[id] = nil
    end
  end
end
ns.On("LOGIN", function() C_Timer.After(50, function() if IsInGuild() then Prune() end end) end)

ns.RegisterDigest(function() A.SendDigest() end)
