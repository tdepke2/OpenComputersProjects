local computer = require("computer")
local uuid = require("uuid")

local function randString()
  local str = ""
  for i = 1, 8 do
    str = str .. tostring(math.floor(math.random(0, 9)))
  end
  return str
end

-- More efficient somehow? Small sequences must be well optimized.
local function thing1(n)
  local vals = {}
  for i = 1, n do
    local k = math.random()
    vals[k] = {computer.uptime(), uuid.next(), uuid.next()}
  end
  return vals
end

local function thing2(n)
  local vals1 = {}
  local vals2 = {}
  local vals3 = {}
  for i = 1, n do
    local k = math.random()
    vals1[k] = computer.uptime()
    vals2[k] = uuid.next()
    vals3[k] = uuid.next()
  end
  return vals1, vals2, vals3
end

local c1 = os.clock()
local f1 = computer.freeMemory()

local vals = thing1(1000)
--for k, v in pairs(vals) do
--  print(k, v[1], v[2], v[3])
--end

--local vals1, vals2, vals3 = thing2(1000)

local c2 = os.clock()
local f2 = computer.freeMemory()

print("time = ", c2 - c1)
print("mem = ", f1 - f2)
