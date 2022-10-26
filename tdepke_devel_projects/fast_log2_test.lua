-- testing log2(x) functions when x is a known power of 2

-- about 1.00s
local function log2Fast1(v)
  local r = (v & 0xAAAAAAAA ~= 0 and 1 or 0)
  if v & 0xCCCCCCCC ~= 0 then r = r + 2 end
  if v & 0xF0F0F0F0 ~= 0 then r = r + 4 end
  if v & 0xFF00FF00 ~= 0 then r = r + 8 end
  if v & 0xFFFF0000 ~= 0 then r = r + 16 end
  return r
end

-- about 1.35s
local function log2Fast2(v)
  local r = (v & 0xAAAAAAAA ~= 0 and 1 or 0)
  r = r + (v & 0xCCCCCCCC ~= 0 and 2 or 0)
  r = r + (v & 0xF0F0F0F0 ~= 0 and 4 or 0)
  r = r + (v & 0xFF00FF00 ~= 0 and 8 or 0)
  r = r + (v & 0xFFFF0000 ~= 0 and 16 or 0)
  return r
end

-- about 0.37s (fastest)
local Mod37BitPosition = {
  [0] = 32, 0, 1, 26, 2, 23, 27, 0, 3, 16, 24, 30, 28, 11, 0, 13, 4,
  7, 17, 0, 25, 22, 31, 15, 29, 10, 12, 6, 0, 21, 14, 9, 5,
  20, 8, 19, 18
}
local function log2Fast3(v)
  return Mod37BitPosition[v % 37]
end

-- about 0.64s
local log = math.log
local function log2Fast4(v)
  return log(v, 2)
end

--[[
local log2Fast = log2Fast4
local t1 = os.clock()
for i = 1, 100000 do
  log2Fast(0x1)
  log2Fast(0x2)
  log2Fast(0x4)
  log2Fast(0x8)
  log2Fast(0x10)
  log2Fast(0x20)
  log2Fast(0x40)
  log2Fast(0x80)
  log2Fast(0x100)
  log2Fast(0x200)
  log2Fast(0x400)
  log2Fast(0x800)
  log2Fast(0x1000)
  log2Fast(0x2000)
  log2Fast(0x4000)
  log2Fast(0x8000)
  log2Fast(0x10000)
  log2Fast(0x20000)
  log2Fast(0x40000)
  log2Fast(0x80000)
  log2Fast(0x100000)
  log2Fast(0x200000)
  log2Fast(0x400000)
  log2Fast(0x800000)
  log2Fast(0x1000000)
  log2Fast(0x2000000)
  log2Fast(0x4000000)
  log2Fast(0x8000000)
  log2Fast(0x10000000)
  log2Fast(0x20000000)
  log2Fast(0x40000000)
  log2Fast(0x80000000)
end
local t2 = os.clock()
print(t2 - t1)
--]]

local function findAllSet(x)
  io.write(string.format("%d 0x%2x: ", x, x))
  while x ~= 0 do
    local lsb = x & -x
    
    io.write(Mod37BitPosition[lsb % 37] .. " ")
    
    x = x ~ lsb
  end
  io.write("\n")
end

findAllSet(0)
for i = 1, 10 do
  findAllSet(math.random(1, 100))
end
