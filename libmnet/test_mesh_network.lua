--[[
Test messaging/routing between multiple servers.

Any server can start the test, then the test runs for a fixed amount of time on
all listening servers. Randomized data is generated and sent to other machines,
packets may be intentionally dropped or re-order depending on settings. Results
are displayed at the end.

The basic idea:
  * Machine that starts the test sends broadcast about its hostname.
  * Other machines get the message and broadcast their hostnames too, each one
    makes a list of the other hosts.
  * After a fixed period of time, we move to "running" where each machine
    enables lossy transmission and picks a host at random and sends some data.
  * After another period of time, move to "paused" where each machine disables
    lossy transmission and sends a copy of the sent data to each corresponding
    host.
  * Each machine shows results.
--]]


local component = require("component")
local computer = require("computer")
local event = require("event")
local keyboard = require("keyboard")
local serialization = require("serialization")
local thread = require("thread")

local include = require("include")
local dlog = include("dlog")
dlog.osBlockNewGlobals(true)
local mnet = include.reload("mnet")

local MODEM_RANGE_SHORT = 12
local MODEM_RANGE_MAX = 400

-- Test parameters. See mnet for drop and swap probabilities.
local TEST_TIME_SECONDS = 60
-- Min/max delay to wait after sending a message. These may need to be increased based on the number of servers in the test.
local MESSAGE_DELAY_MIN = 1.0
local MESSAGE_DELAY_MAX = 3.0
-- Min/max number of randomized characters in each message.
local MESSAGE_LENGTH_MIN = 0
local MESSAGE_LENGTH_MAX = 32
-- Probability to use reliable protocol (range [0, 1]).
local MESSAGE_RELIABLE_CHANCE = 0.5
-- Probability to send a broadcast if reliable was not chosen (range [0, 1]).
local MESSAGE_BROADCAST_CHANCE = 0.2
-- If true, each server adds itself to the list of remote hosts.
local MESSAGE_ALLOW_LOOPBACK = true

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
local sentData = {}
local receivedData = {}
local connectionResets = {}
local reportedLost = {}
local results = {}

-- Class to wrap networking functions in a generic interface (to make it easier
-- to test other networking protocols).
local NetInterface = {}

-- Hook up errors to throw on access to nil class members (usually a programming
-- error or typo).
setmetatable(NetInterface, {
  __index = function(t, k)
    dlog.verboseError("Attempt to read undefined member " .. tostring(k) .. " in NetInterface class.", 4)
  end
})

function NetInterface:new()
  self.__index = self
  self = setmetatable({}, self)
  
  return self
end

function NetInterface:getHostname()
  return mnet.hostname
end

function NetInterface:setTestingMode(b)
  if b then
    mnet.debugEnableLossy(true)
    mnet.debugSetSmallMTU(true)
  else
    mnet.debugEnableLossy(false)
    mnet.debugSetSmallMTU(false)
  end
  
  -- The wireless NIC can be physically tested by reducing the max range. This is more accurate to a real scenario but much harder to debug which packets are actually lost.
  --for address in component.list("modem", true) do
    --component.proxy(address).setStrength(MODEM_RANGE_MAX)
  --end
end

--[[
function NetInterface:clearConnectionCache()
  mnet.lastSent = {}
  mnet.lastReceived = {}
end
--]]

function NetInterface:send(host, port, message, reliable)
  return mnet.send(host, port, message, reliable)
end

function NetInterface:receive(timeout, connectionLostCallback)
  return mnet.receive(timeout, connectionLostCallback)
end

local netInterface = NetInterface:new()

-- Capture lost connection and add to counter for this host.
local function connectionLostCallback(hostSeq, port, fragment)
  dlog.out("receive", "Connection lost, hostSeq=", hostSeq, ", port=", port, ", fragment=", fragment)
  local host, sequence = string.match(hostSeq, ".(.*),([^,]+)$")
  dlog.out("d", "reportedLost:", reportedLost)
  dlog.out("d", "reportedLost at [", host, "] = ", reportedLost[host])
  reportedLost[host] = reportedLost[host] + 1
end

-- Start tracking a new remote host and add them to data collection tables.
local function addHost(host)
  remoteHosts[#remoteHosts + 1] = host
  sentData[host] = {}
  receivedData[host] = {}
  connectionResets[host] = 0
  reportedLost[host] = 0
end

-- Compare the contents of another host's sentData table with the messages we
-- got from them (from receivedData). The errors and latency measurements are
-- calculated and added to results.
local function addResults(host, remoteSent)
  local receivedSize = #receivedData[host]
  
  -- Data measurements we collect now and report later.
  local numErrors = 0
  local numConnectionResets = connectionResets[host]
  local numReportedLost = reportedLost[host]
  local reliableMessages = {
    lastIndex = 1,
    sent = 0,
    lost = 0,
    wrongOrder = 0,
    latencyMin = math.huge,
    latencyMax = -math.huge,
    latencySum = 0
  }
  local unreliableMessages = {
    lastIndex = 1,
    sent = 0,
    lost = 0,
    wrongOrder = 0,
    latencyMin = math.huge,
    latencyMax = -math.huge,
    latencySum = 0
  }
  
  -- Iterate through each message the sender sent to us.
  for i, sent in ipairs(remoteSent[netInterface:getHostname()]) do
    local m = sent[3] and reliableMessages or unreliableMessages
    m.sent = m.sent + 1
    
    -- Scan through a range [i - 16, size] of receivedData to find the entry where the messages match.
    local received
    for i = math.max(m.lastIndex - 16, 1), receivedSize do
      local r = receivedData[host][i]
      if r and sent[2] == r[2] then
        received = r
        receivedData[host][i] = nil
        
        -- If message was found prior to the index, it is out of order.
        if i < m.lastIndex then
          m.wrongOrder = m.wrongOrder + 1
        end
        while i <= receivedSize and not receivedData[host][i] do
          i = i + 1
        end
        m.lastIndex = i
        break
      end
    end
    
    if received then
      -- Convert in-game time to real seconds.
      local latency = (received[1] - sent[1]) * 3 / 216
      m.latencyMin = math.min(m.latencyMin, latency)
      m.latencyMax = math.max(m.latencyMax, latency)
      m.latencySum = m.latencySum + latency
    else
      m.lost = m.lost + 1
    end
  end
  
  for i, received in pairs(receivedData[host]) do
    numErrors = numErrors + 1
  end
  
  results[host] = {numErrors, numConnectionResets, numReportedLost, reliableMessages, unreliableMessages}
end

-- Listens for incoming network messages and handles them. Command messages
-- always contain a null character, while generic messages we add to
-- receivedData do not.
local function listenerThreadFunc()
  while true do
    local host, port, message = netInterface:receive(0.1, connectionLostCallback)
    if host then
      dlog.out("receive", host, " ", port, " ", message)
      if string.find(message, "\0") then
        local messageType, messageData = string.match(message, "^([^\0]*)\0(.*)")
        if messageType == "hostname" and not sentData[host] then
          if testState == TestState.standby then
            dlog.out("state", "Got start request.")
            if MESSAGE_ALLOW_LOOPBACK then
              addHost(netInterface:getHostname())
            end
            addHost(host)
            netInterface:send("*", 123, "hostname\0", false)
            testState = testState + 1
            stateTimer = computer.uptime() + 5
          else
            addHost(host)
          end
        elseif messageType == "sentData" and not results[host] then
          addResults(host, serialization.unserialize(messageData))
        end
      else
        receivedData[host][#receivedData[host] + 1] = {os.time(), message .. "\0" .. port}
      end
    end
  end
end

-- Get a random ASCII string of length n.
local function randomString(n)
  local arr = {}
  for i = 1, n do
    arr[i] = math.random(32, 126)
  end
  return string.char(table.unpack(arr))
end

local function main()
  --dlog.setFileOut("/tmp/messages", "w")
  dlog.setSubsystem("mnet", true)
  
  netInterface:setTestingMode(false)
  
  dlog.out("init", "Mesh test ready, press \'s\' to start. I am ", netInterface:getHostname())
  
  local listenerThread = thread.create(listenerThreadFunc)
  
  local sendTimer = 0
  while true do
    -- Check if time to send a new packet.
    if testState == TestState.running and computer.uptime() >= sendTimer then
      local host = remoteHosts[math.random(1, #remoteHosts)]
      local port = math.floor(math.random(1, 65535))
      local message = randomString(math.random(MESSAGE_LENGTH_MIN, MESSAGE_LENGTH_MAX))
      local reliable = math.random() < MESSAGE_RELIABLE_CHANCE
      if not reliable and math.random() < MESSAGE_BROADCAST_CHANCE then
        host = "*"
      end
      
      --[[
      -- Skip this, it doesn't simulate a "receiver reboot" very well.
      if math.random() < 0.0 then
        dlog.out("d", "\27[31mClearing connection cache (receiver reset).\27[0m")
        netInterface:clearConnectionCache()
        connectionResets[host] = connectionResets[host] + 1
      end
      --]]
      
      local sent = {os.time(), message .. "\0" .. port, reliable}
      if host ~= "*" then
        sentData[host][#sentData[host] + 1] = sent
      else
        for i, v in pairs(remoteHosts) do
          if v ~= netInterface:getHostname() then
            sentData[v][#sentData[v] + 1] = sent
          end
        end
      end
      
      sendTimer = computer.uptime() + (MESSAGE_DELAY_MAX - MESSAGE_DELAY_MIN) * math.random() + MESSAGE_DELAY_MIN
      netInterface:send(host, port, message, reliable)
    end
    
    -- Check for state transition.
    if stateTimer and computer.uptime() >= stateTimer then
      if testState == TestState.getHosts then
        dlog.out("state", "Running...")
        
        netInterface:setTestingMode(true)
        
        dlog.out("d", "hosts: ", remoteHosts)
        stateTimer = computer.uptime() + TEST_TIME_SECONDS
      elseif testState == TestState.running then
        dlog.out("state", "Pausing...")
        stateTimer = computer.uptime() + 20
      elseif testState == TestState.paused then
        dlog.out("state", "Sending transmitted data...")
        
        netInterface:setTestingMode(false)
        
        --dlog.out("d", "sentData: ", sentData)
        --dlog.out("d", "receivedData: ", receivedData)
        if MESSAGE_ALLOW_LOOPBACK then
          addResults(netInterface:getHostname(), sentData)
        end
        netInterface:send("*", 123, "sentData\0" .. serialization.serialize(sentData), false)
        stateTimer = computer.uptime() + 5
      elseif testState == TestState.getSentData then
        dlog.out("state", "Done.")
        --dlog.out("d", "results: ", results)
        
        local function displayResults(host, r)
          local reliableLatencyAvg = r[4].latencySum / (r[4].sent - r[4].lost)
          local unreliableLatencyAvg = r[5].latencySum / (r[5].sent - r[5].lost)
          dlog.out("d", string.format("%-14s %4d   %4d   %4d |   %4d %4d    %4d %5.2f %5.2f %5.2f  |   %4d %4d    %4d %5.2f %5.2f %5.2f",
            host .. (host ~= netInterface:getHostname() and ":" or " (me):"), r[1], r[2], r[3],
            r[4].sent, r[4].lost, r[4].wrongOrder, r[4].latencyMin, r[4].latencyMax, reliableLatencyAvg == reliableLatencyAvg and reliableLatencyAvg or 0,
            r[5].sent, r[5].lost, r[5].wrongOrder, r[5].latencyMin, r[5].latencyMax, unreliableLatencyAvg == unreliableLatencyAvg and unreliableLatencyAvg or 0
          ))
        end
        
        local function addMessageResults(total, m)
          total.sent = (total.sent or 0) + m.sent
          total.lost = (total.lost or 0) + m.lost
          total.wrongOrder = (total.wrongOrder or 0) + m.wrongOrder
          total.latencyMin = math.min(total.latencyMin or math.huge, m.latencyMin)
          total.latencyMax = math.max(total.latencyMax or -math.huge, m.latencyMax)
          total.latencySum = (total.latencySum or 0) + m.latencySum
        end
        
        dlog.out("d", "host         errors resets r_lost | r(sent lost w_order t_min t_max t_avg) | u(sent lost w_order t_min t_max t_avg)")
        local totalResults = {0, 0, 0, {}, {}}
        for _, host in ipairs(remoteHosts) do
          local r = results[host]
          results[host] = nil
          if r then
            displayResults(host, r)
            totalResults[1] = totalResults[1] + r[1]
            totalResults[2] = totalResults[2] + r[2]
            totalResults[3] = totalResults[3] + r[3]
            addMessageResults(totalResults[4], r[4])
            addMessageResults(totalResults[5], r[5])
          else
            dlog.out("d", "ERROR: no data for host " .. host)
          end
        end
        dlog.out("d", string.rep(" ", 34), "|", string.rep(" ", 40), "|")
        displayResults("total", totalResults)
        assert(next(results) == nil, "got data from unregistered host \"" .. tostring(next(results)) .. "\"")
        break
      end
      testState = testState + 1
    end
    
    -- Handle events.
    local event = {event.pull(0.05)}
    if event[1] == "interrupted" then
      dlog.out("d", "interrupted")
      break
    elseif event[1] == "key_down" then
      if not keyboard.isControl(event[3]) then
        if event[3] == string.byte("s") and testState == TestState.standby then
          dlog.out("state", "Starting test...")
          
          if MESSAGE_ALLOW_LOOPBACK then
            addHost(netInterface:getHostname())
          end
          netInterface:send("*", 123, "hostname\0", false)
          testState = testState + 1
          stateTimer = computer.uptime() + 5
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
