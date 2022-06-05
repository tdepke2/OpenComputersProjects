local component = require("component")
local computer = require("computer")
local event = require("event")
local keyboard = require("keyboard")
local serialization = require("serialization")
local thread = require("thread")

local include = require("include")
local dlog = include("dlog")
dlog.osBlockNewGlobals(true)
local mnet = include("mnet")

local MODEM_RANGE_SHORT = 12
local MODEM_RANGE_MAX = 400
local TEST_TIME_SECONDS = 5

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
local results = {}

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
      if string.find(message, "\0") then
        local messageType, messageData = string.match(message, "^([^\0]*)\0(.*)")
        if messageType == "hostname" and not sentData[host] then
          remoteHosts[#remoteHosts + 1] = host
          sentData[host] = {}
          receivedData[host] = {}
          if testState == TestState.standby then
            dlog.out("state", "Got start request.")
            mnet.send("*", 123, "hostname\0", false)
            testState = testState + 1
            stateTimer = computer.uptime() + 5
          end
        elseif messageType == "sentData" and not results[host] then
          local remoteSent = serialization.unserialize(messageData)
          local receivedSize = #receivedData[host]
          
          -- Data measurements we collect now and report later.
          local numErrors = 0
          local numConnectionResets = 0
          local reliableMessages = {
            lastIndex = 1,
            sent = 0,
            lost = 0,
            wrongOrder = 0,
            reportedLost = 0,
            latencyMin = math.huge,
            latencyMax = -math.huge,
            latencySum = 0
          }
          local unreliableMessages = {
            lastIndex = 1,
            sent = 0,
            lost = 0,
            wrongOrder = 0,
            reportedLost = 0,
            latencyMin = math.huge,
            latencyMax = -math.huge,
            latencySum = 0
          }
          
          -- Iterate through each message the sender sent to us.
          for i, sent in ipairs(remoteSent[mnet.hostname]) do
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
          
          results[host] = {numErrors, numConnectionResets, reliableMessages, unreliableMessages}
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
  dlog.setSubsystem("mnet", false)
  
  mnet.debugEnableLossy(false)
  mnet.debugSetSmallMTU(false)
  for address in component.list("modem", true) do
    component.proxy(address).setStrength(MODEM_RANGE_MAX)
  end
  
  dlog.out("init", "Mesh test ready, press \'s\' to start. I am ", mnet.hostname)
  
  local listenerThread = thread.create(listenerThreadFunc)
  
  local sendTimer = 0
  while true do
    -- Check if time to send a new packet.
    if testState == TestState.running and computer.uptime() >= sendTimer then
      local host = remoteHosts[math.random(1, #remoteHosts)]
      local port = math.floor(math.random(1, 65535))
      local message = randomString(math.random(1, 64))
      local reliable = math.random() < 1.5
      
      sentData[host][#sentData[host] + 1] = {os.time(), message .. "\0" .. port, reliable}
      mnet.send(host, port, message, reliable)
      sendTimer = computer.uptime() + 2.0 * math.random()
    end
    
    -- Check for state transition.
    if stateTimer and computer.uptime() >= stateTimer then
      if testState == TestState.getHosts then
        dlog.out("state", "Running...")
        
        mnet.debugEnableLossy(false)
        mnet.debugSetSmallMTU(true)
        
        dlog.out("d", "hosts: ", remoteHosts)
        stateTimer = computer.uptime() + TEST_TIME_SECONDS
      elseif testState == TestState.running then
        dlog.out("state", "Pausing...")
        stateTimer = computer.uptime() + 20
      elseif testState == TestState.paused then
        dlog.out("state", "Sending transmitted data...")
        
        mnet.debugEnableLossy(false)
        mnet.debugSetSmallMTU(false)
        
        --dlog.out("d", "sentData: ", sentData)
        --dlog.out("d", "receivedData: ", receivedData)
        mnet.send("*", 123, "sentData\0" .. serialization.serialize(sentData), false)
        stateTimer = computer.uptime() + 5
      elseif testState == TestState.getSentData then
        dlog.out("state", "Done.")
        --dlog.out("d", "results: ", results)
        
        local function displayResults(host, r)
          local reliableLatencyAvg = r[3].latencySum / (r[3].sent - r[3].lost)
          local unreliableLatencyAvg = r[4].latencySum / (r[4].sent - r[4].lost)
          dlog.out("d", string.format("%s:\t %4d   %4d |   %4d %4d    %4d   %4d %5.2f %5.2f %5.2f  |   %4d %4d    %4d   %4d %5.2f %5.2f %5.2f",
            host, r[1], r[2],
            r[3].sent, r[3].lost, r[3].wrongOrder, r[3].reportedLost, r[3].latencyMin, r[3].latencyMax, reliableLatencyAvg == reliableLatencyAvg and reliableLatencyAvg or 0,
            r[4].sent, r[4].lost, r[4].wrongOrder, r[4].reportedLost, r[4].latencyMin, r[4].latencyMax, unreliableLatencyAvg == unreliableLatencyAvg and unreliableLatencyAvg or 0
          ))
        end
        
        local function addMessageResults(total, m)
          total.sent = (total.sent or 0) + m.sent
          total.lost = (total.lost or 0) + m.lost
          total.wrongOrder = (total.wrongOrder or 0) + m.wrongOrder
          total.reportedLost = (total.reportedLost or 0) + m.reportedLost
          total.latencyMin = math.min(total.latencyMin or math.huge, m.latencyMin)
          total.latencyMax = math.max(total.latencyMax or -math.huge, m.latencyMax)
          total.latencySum = (total.latencySum or 0) + m.latencySum
        end
        
        dlog.out("d", "host    errors resets | r(sent lost w_order r_lost t_min t_max t_avg) | u(sent lost w_order r_lost t_min t_max t_avg)")
        local totalResults = {0, 0, {}, {}}
        for k, v in pairs(results) do
          displayResults(k, v)
          totalResults[1] = totalResults[1] + v[1]
          totalResults[2] = totalResults[2] + v[2]
          addMessageResults(totalResults[3], v[3])
          addMessageResults(totalResults[4], v[4])
        end
        displayResults("total", totalResults)
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
          
          mnet.send("*", 123, "hostname\0", false)
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
