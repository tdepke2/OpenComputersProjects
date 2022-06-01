local component = require("component")
local event = require("event")
local keyboard = require("keyboard")
local modem = component.modem
local thread = require("thread")

local include = require("include")
local dlog = include("dlog")
dlog.osBlockNewGlobals(true)
local mnet = include("mnet")

local MODEM_RANGE_SHORT = 12
local MODEM_RANGE_MAX = 400
local TEST_TIME_SECONDS = 60

local testState = 0

--[[

the rough idea here:
any one machine starts the test, sends broadcast about its hostname.
other machines get the message and broadcast their hostnames too, each one makes a list of the other hosts.
after a fixed period of time, we move to stage 2 where each machine picks a host at random and sends some data.
after another period of time, move to stage 3 where each machine ups the modem strength to the max and sends a copy of the sent data to each corresponding host.
each machine shows results.

--]]

local function listenerThreadFunc()
  while true do
    local host, port, message = mnet.receive(0.1)
    if host then
      dlog.out("receive", host, " ", port, " ", message)
      receivedData[#receivedData + 1] = message
    end
  end
end

local function sendPacket(host, port, message)
  dlog.out("send", mnet.send(host, port, message))
  sentData[#sentData + 1] = message
end

local function main()
  --dlog.setFileOut("/tmp/messages", "w")
  
  dlog.out("init", "Mesh test ready, press \'s\' to start. I am ", mnet.hostname)
  for address in component.list("modem", true) do
    modems[address].setStrength(MODEM_RANGE_MAX)
  end
  
  local listenerThread = thread.create(listenerThreadFunc)
  
  while true do
    local event = {event.pull(0.05)}
    if event[1] == "interrupted" then
      dlog.out("d", "interrupted")
      break
    elseif event[1] == "key_down" then
      if not keyboard.isControl(event[3]) then
        if event[3] == string.byte("s") and testState == 0 then
          dlog.out("start", "Starting test...")
          
          
        end
      end
    end
    
    if listenerThread:status() == "dead" then
      break
    end
  end
  
  listenerThread:kill()
end
main()
dlog.osBlockNewGlobals(false)
