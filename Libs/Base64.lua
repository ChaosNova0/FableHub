-- Standard Base64 decoding (RFC 4648), used to read That's My BIS exports.
local _, ns = ...
local B = {}
ns.Base64 = B

local MAP = {}
local ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
for i = 1, #ALPHA do MAP[ALPHA:byte(i)] = i - 1 end
MAP[("-"):byte()] = 62 -- URL-safe variants
MAP[("_"):byte()] = 63

function B.Decode(s)
  s = s:gsub("[^%w%+/%-_=]", "")
  local out, n = {}, 0
  local bits, value = 0, 0
  for i = 1, #s do
    local c = s:byte(i)
    if c == 61 then break end -- "="
    local v = MAP[c]
    if v == nil then return nil end
    value = value * 64 + v
    bits = bits + 6
    if bits >= 8 then
      bits = bits - 8
      local byte = math.floor(value / 2 ^ bits)
      value = value - byte * 2 ^ bits
      n = n + 1
      out[n] = string.char(byte)
      -- flush in chunks to keep the table small
      if n >= 4096 then out = { table.concat(out) }; n = 1 end
    end
  end
  return table.concat(out)
end
