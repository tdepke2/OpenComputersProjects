local component = require("component")
local event = require("event")
local keyboard = require("keyboard")
local modem = component.modem
local thread = require("thread")

local include = require("include")
local dlog = include("dlog")
dlog.osBlockNewGlobals(true)
local mnet = include("mnet")

local PORT = 456
local MODEM_RANGE_SHORT = 12
local MODEM_RANGE_MAX = 400
local TEST_TIME_SECONDS = 60

-- Creates a new enumeration from a given table (matches keys to values and vice
-- versa). The given table is intended to use numeric keys and string values,
-- but doesn't have to be a sequence.
-- Based on: https://unendli.ch/posts/2016-07-22-enumerations-in-lua.html
local function enum(t)
  local result = {}
  for i, v in pairs(t) do
    result[i] = v
    result[v] = i
  end
  return result
end

local TestState = enum {
  "standby",
  "getHosts",
  "running",
  "paused",
  "getSentData",
  "done"
}
local testState = TestState.standby
local stateTimer

local remoteHosts = {}
local receivedData = {}

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
      if string.find(message, ",") then
        local messageType, messageData = string.match(message, "^([^,]*),(.*)")
        if messageType == "hostname" then
          remoteHosts[messageData] = true
          receivedData[messageData] = {}
          if testState == TestState.standby then
            dlog.out("state", "Got start request.")
            mnet.send("*", PORT, "hostname," .. mnet.hostname, false)
            testState = testState + 1
            stateTimer = computer.uptime() + 10
          end
        end
      else
        receivedData[host][#receivedData[host] + 1] = message
      end
    end
  end
end

local function sendPacket(host, port, message)
  dlog.out("send", mnet.send(host, port, message))
  sentData[#sentData + 1] = message
end

local function main()
  --dlog.setFileOut("/tmp/messages", "w")
  
  mnet.debugEnableLossy(false)
  for address in component.list("modem", true) do
    modems[address].setStrength(MODEM_RANGE_MAX)
  end
  
  dlog.out("init", "Mesh test ready, press \'s\' to start. I am ", mnet.hostname)
  
  local listenerThread = thread.create(listenerThreadFunc)
  
  while true do
    if stateTimer and computer.uptime() >= stateTimer then
      if testState == TestState.getHosts then
        dlog.out("state", "Running...")
        dlog.out("d", "hosts: ", remoteHosts)
        stateTimer = computer.uptime() + TEST_TIME_SECONDS
      elseif testState == TestState.running then
        dlog.out("state", "Pausing...")
        stateTimer = computer.uptime() + 45
      elseif testState == TestState.paused then
        dlog.out("state", "Sending results...")
        dlog.out("d", "receivedData: ", receivedData)
        stateTimer = computer.uptime() + 10
      elseif testState == TestState.getSentData then
        dlog.out("state", "Done.")
        stateTimer = nil
      end
      testState = testState + 1
    end
    
    local event = {event.pull(0.05)}
    if event[1] == "interrupted" then
      dlog.out("d", "interrupted")
      break
    elseif event[1] == "key_down" then
      if not keyboard.isControl(event[3]) then
        if event[3] == string.byte("s") and testState == TestState.standby then
          dlog.out("state", "Starting test...")
          
          mnet.send("*", PORT, "hostname," .. mnet.hostname, false)
          testState = testState + 1
          stateTimer = computer.uptime() + 10
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
