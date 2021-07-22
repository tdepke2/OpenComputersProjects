-- Performance tests for string array vs table with lots of small tables.
-- Conclusion: tables are very good, even lots of small ones are efficient.

local computer = require("computer")

local NUM_VALUES = 1000

-- Get transposer index and side number formatted as a string.
local function formatConnection(transIdx, side)
  return tostring(transIdx) .. ":" .. tostring(side) .. ","
end

-- Get transposer index and side number from a string (starting at init).
local function parseConnections(connections, init)
  local transIdx, side = string.match(connections, "(%d*):(%d*),", init)
  local length = (not transIdx or #transIdx + #side + 2)
  return tonumber(transIdx), tonumber(side), length
end

local function doStringTests()
  local timeStart = os.clock()
  local memStart = computer.freeMemory()
  local arr = ""
  for i = 1, NUM_VALUES do
    arr = arr .. formatConnection(math.random(1, 100), math.random(1, 100))
  end
  
  local sum1, sum2 = 0, 0
  local init = 1
  while true do
    local a, b, c = parseConnections(arr, init)
    if not a then
      break
    end
    sum1 = sum1 + a
    sum2 = sum2 + b
    init = init + c
  end
  local timeEnd = os.clock()
  local memEnd = computer.freeMemory()
  
  io.write("str took " .. timeEnd - timeStart .. ", mem " .. memStart - memEnd .. ", " .. sum1 .. ", " .. sum2 .. "\n")
end

local function doTableTests()
  local timeStart = os.clock()
  local memStart = computer.freeMemory()
  local arr = {}
  for i = 1, NUM_VALUES do
    arr[#arr + 1] = {math.random(1, 100), math.random(1, 100)}
  end
  
  local sum1, sum2 = 0, 0
  for _, v in ipairs(arr) do
    sum1 = sum1 + v[1]
    sum2 = sum2 + v[2]
  end
  local timeEnd = os.clock()
  local memEnd = computer.freeMemory()
  
  io.write("tab took " .. timeEnd - timeStart .. ", mem " .. memStart - memEnd .. ", " .. sum1 .. ", " .. sum2 .. "\n")
end

local function main()
  math.randomseed(computer.uptime())
  doStringTests()
  doTableTests()
  doStringTests()
  doTableTests()
  io.write("free mem: " .. computer.freeMemory() .. "\n")
end

main()
