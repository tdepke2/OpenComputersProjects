-- Drains the energy in a robot (by moving it up and down) until it meets a certain level.
-- Specify the target energy level in first argument, can use percent like `10%`.

local component = require("component")
local computer = require("computer")
local crobot = component.robot
local sides = require("sides")

local energyTarget = select(1, ...)
if energyTarget:find("%%") then
  energyTarget = tonumber(energyTarget:sub(1, -2)) * 0.01 * computer.maxEnergy()
else
  energyTarget = tonumber(energyTarget)
end
assert(energyTarget)

local initialEnergy, numMoves = computer.energy(), 0
local t1 = computer.uptime()
while computer.energy() > energyTarget do
  -- Printing text to screen helps speed up drain a bit (it's the gpu.set() calls that matter), but it's less consistent.
  --io.write(("0"):rep(50), "\n")
  --io.write(("O"):rep(50), "\n")
  crobot.move(sides.top)
  --io.write(("0"):rep(50), "\n")
  --io.write(("O"):rep(50), "\n")
  crobot.move(sides.bottom)
  numMoves = numMoves + 2
end
local t2 = computer.uptime()
print("drained " .. initialEnergy - computer.energy() .. " units in " .. t2 - t1 .. "s and moved " .. numMoves .. " times")
