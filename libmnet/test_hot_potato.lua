--[[
Set up a bunch of servers to play a game of hot potato. This is used to test
routing and static routes in mnet.

Based on the demo shown here for Minitel:
https://www.reddit.com/r/feedthebeast/comments/d82oqe/zeroconfig_smart_routing_in_opencomputers_using/
--]]

local component = require("component")
local computer = require("computer")
local event = require("event")
local keyboard = require("keyboard")
local serialization = require("serialization")
local term = require("term")
local thread = require("thread")

local include = require("include")
local dlog = include("dlog")
dlog.osBlockNewGlobals(true)
local mnet = include.reload("mnet")

local MAX_POTATO_TOSSES = 5
local MESSAGE_RELIABLE_CHANCE = 1.0--0.5
local MESSAGE_BROADCAST_CHANCE = 0.4

--[[
local HOSTS = {
  "1315ba5c",
  "2f2cacf9",
  "7f55a49f"
}
--]]

local HOSTS = {
  "0a19fb45",
  --"a70c251f",
  "d2c6b1ec",
  "42f05607",
  --"be0613db",
--"401a1951",
  --"b3a6106d",
--"5e40b6c6"
}

local potato


-- Passes the potato off to a random host.
local function sendPotato()
  if potato.target ~= mnet.hostname then
    potato = nil
    return
  end
  potato.senders[#potato.senders + 1] = mnet.hostname
  potato.tosses = potato.tosses + 1
  if potato.tosses > MAX_POTATO_TOSSES then
    mnet.send("*", 100, "test_finished", false)
    potato = nil
    os.exit()
  end
  
  while potato.target == mnet.hostname do
    potato.target = HOSTS[math.random(1, #HOSTS)]
  end
  if math.random() < MESSAGE_RELIABLE_CHANCE then
    mnet.send(potato.target, 100, serialization.serialize(potato), true)
  elseif math.random() < MESSAGE_BROADCAST_CHANCE then
    mnet.send("*", 100, serialization.serialize(potato), false)
  else
    mnet.send(potato.target, 100, serialization.serialize(potato), false)
  end
  potato = nil
end


-- Listens for packets and handles them.
local function listenerThreadFunc()
  while true do
    local host, port, message = mnet.receive(0.1)
    if host then
      dlog.out("receive", host, " ", port, " ", message)
      if message == "test_finished" then
        os.exit()
      end
      potato = serialization.unserialize(message)
      potato.sendTime = computer.uptime() + 6
      
      if potato.target == mnet.hostname then
        dlog.out("d", "I have the potato!\27[7m\n.\n.\n.\n.\n.\n.\27[0m")
      else
        dlog.out("d", "I have part of the potato.\27[7m\n.\n.\27[0m\n.\n.\n.\n.")
      end
    end
  end
end


local function main()
  dlog.setFileOut("/tmp/messages", "w")
  dlog.setSubsystem("mnet", true)
  
  mnet.debugEnableLossy(false)
  mnet.debugSetSmallMTU(false)
  
  dlog.out("init", "Hot potato ready, press \'s\' to send a potato. I am ", mnet.hostname)
  
  local listenerThread = thread.create(listenerThreadFunc)
  
  while true do
    if potato and computer.uptime() >= potato.sendTime then
      potato.sendTime = nil
      local _, r = term.getCursor()
      for r2 = r - 1, r - 6, -1 do
        term.setCursor(1, r2)
        term.clearLine()
      end
      sendPotato()
    end
    
    -- Handle events.
    local event = {event.pull(0.05)}
    if event[1] == "interrupted" then
      dlog.out("d", "interrupted")
      break
    elseif event[1] == "key_down" then
      if not keyboard.isControl(event[3]) then
        if event[3] == string.byte("s") then
          dlog.out("state", "Sending potato...")
          potato = {
            target = mnet.hostname,
            senders = {},
            tosses = 0
          }
          sendPotato()
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
