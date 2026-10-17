-- Encode: compact text format for sending records over addon messages.
--
-- record  = "1^<key>^<ts>^<class>^<level>^<prof>~<prof>..."
-- prof    = "<skillLine>:<rank>:<max>:<name>:<recipe>.<recipe>..."
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

function Enc.EncodeRecord(rec)
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
  return table.concat({
    "1", (tostring(rec.key):gsub("[%^~]", "")), Enc.ToB36(rec.ts), Clean(rec.class), Enc.ToB36(rec.level),
    table.concat(profs, "~"),
    Enc.ToB36(spec.tree or 0), (tostring(spec.points or ""):gsub("[^%d/]", "")), table.concat(buffs, "."), Clean(spec.name),
    Enc.EncodeOutputs(rec),
  }, "^")
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

function Enc.DecodeRecord(text)
  local f = Split(text, "^")
  if f[1] ~= "1" or not f[2] or f[2] == "" then return nil end
  local rec = {
    key = f[2],
    ts = Enc.FromB36(f[3]),
    class = (f[4] ~= "" and f[4]) or nil,
    level = Enc.FromB36(f[5]),
    profs = {},
  }
  local tree = Enc.FromB36(f[7])
  if tree > 0 then rec.spec = { tree = tree, points = f[8] or "", name = (f[10] ~= "" and f[10]) or nil } end
  if f[11] and f[11] ~= "" then
    rec.outputs = {}
    for _, pair in ipairs(Split(f[11], ",")) do
      local r, i = pair:match("^(%w+)=(%w+)$")
      if r then rec.outputs[Enc.FromB36(r)] = Enc.FromB36(i) end
    end
  end
  if f[9] and f[9] ~= "" then
    rec.buffs = {}
    for _, id in ipairs(Split(f[9], ".")) do if id ~= "" then rec.buffs[id] = true end end
  end
  for _, ptext in ipairs(Split(f[6] or "", "~")) do
    local pf = Split(ptext, ":")
    local skillLine = Enc.FromB36(pf[1])
    if skillLine > 0 then
      local recipes = {}
      for _, r in ipairs(Split(pf[5] or "", ".")) do
        local id = Enc.FromB36(r)
        if id > 0 then recipes[id] = true end
      end
      rec.profs[skillLine] = {
        rank = Enc.FromB36(pf[2]),
        max = Enc.FromB36(pf[3]),
        name = pf[4] or "",
        recipes = recipes,
      }
    end
  end
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
