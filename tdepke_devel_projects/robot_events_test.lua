--[[
Experiment with capturing events during robot actions.

It was observed that using event.listen() to wait for events and having a robot
do some work (mining blocks and moving) prevented processing of said events.
Normally placing computer.pullSignal(0) or os.sleep(0) calls in the code are a
non-blocking way to implicitly allow a context switch into the event handler,
but this seems to not work as well during robot actions.
--]]

local computer = require("computer")
local component = require("component")
local crobot = component.robot
local event = require("event")
local sides = require("sides")
local keyboard = require("keyboard")

local function interruptHandler()
  print("sigint!")
  return false
end

-- This method is working well for capturing the control-c event. Experiments
-- show that keyboard events are much more reliable to collect than the actual
-- "interrupted" signal.
local function keyHandler(eventName, keyboardAddress, char, code, playerName)
  if keyboard.isControl(char) then
    if code == keyboard.keys.c then
      print("sigint!")
      return false
    elseif code == keyboard.keys.lcontrol then
      print("lctrl")
      -- Pull for a bit longer since we anticipate the control-c.
      computer.pullSignal(0.1)
    end
  end
end

-- This method didn't work, the keyboard check functions rely on event.listen() so this doesn't make a difference.
local function checkInterrupt()
  if keyboard.isControlDown() then
    os.sleep(0.1)
  end
end

print("listen:", event.listen("key_down", keyHandler))

print("dig time")
local t1 = computer.uptime()
for i = 1, 20 do
  crobot.swing(sides.front)
  computer.pullSignal(0)
  --checkInterrupt()
end
local t2 = computer.uptime()
print("done, took " .. t2 - t1 .. "s")

print("ignore:", event.ignore("key_down", keyHandler))
