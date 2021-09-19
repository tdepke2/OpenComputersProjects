local wnet = require("wnet")
local component = require("component")
local modem = component.modem
local thread = require("thread")
local event = require("event")

local t1 = thread.create(function()
  event.pull("interrupted")
end)

local t2 = thread.create(function()
  while true do
    local a, p, d = wnet.receive()
    print("recieve", a, p, d)
    --os.sleep(1)    -- only this causes packets to be lost
  end
end)

local t3 = thread.create(function()
  while true do
    os.sleep(5)
    print("there goes 5s, did we miss events?")
  end
end)

modem.open(58008)

thread.waitForAny({t1, t2, t3})
os.exit()