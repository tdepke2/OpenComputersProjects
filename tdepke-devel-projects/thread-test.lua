local thread = require("thread")
local event = require("event")
local component = require("component")
local transposer = component.transposer

local function bigTransfer()
  for i = 1, 10 do
    transposer.transferItem(1, 4, 1, 1, 1)
    transposer.transferItem(4, 1, 1, 1, 1)
  end
end

--[[
-- Didn't work so great, running detached or not this lags the whole system.
local transfer_thread = thread.create(function()
  while true do
    bigTransfer()
    os.sleep(0.1)
  end
end):detach()
--]]

local cleanup_thread = thread.create(function()
  event.pull("interrupted")
  io.write("cleaning up resources\n")
end)

local main_thread = thread.create(function()
  io.write("main program\n")
  while true do
    io.write("input: ")
    local input = io.read()
    io.write("you entered " .. tostring(input) .. "\n")
    if input == "transfer" then
      local i = 1
      while true do
        bigTransfer()
        print(i)
        i = i + 1
        os.sleep(0.1)
      end
    end
  end
end)

thread.waitForAny({cleanup_thread, main_thread})
io.write("ok bye\n")
os.exit(0)