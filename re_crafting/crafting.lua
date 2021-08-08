
local component = require("component")
local event = require("event")
local modem = component.modem
local text = require("text")
local thread = require("thread")
local wnet = require("wnet")

local COMMS_PORT = 0xE298

local function main()
  local threadSuccess = false
  -- Captures the interrupt signal to stop program.
  local interruptThread = thread.create(function()
    event.pull("interrupted")
  end)
  
  local netLog = ""
  
  -- Performs setup and initialization tasks.
  local setupThread = thread.create(function()
    modem.open(COMMS_PORT)
    wnet.debug = false
    
    threadSuccess = true
  end)
  
  thread.waitForAny({interruptThread, setupThread})
  if interruptThread:status() == "dead" then
    os.exit(1)
  elseif not threadSuccess then
    io.stderr:write("Error occurred in thread, check log file \"/tmp/event.log\" for details.\n")
    os.exit(1)
  end
  threadSuccess = false
  
  local listenThread = thread.create(function()
    while true do
      local address, port, data = wnet.receive()
      if address then
        netLog = netLog .. "Packet from " .. string.sub(address, 1, 5) .. ":" .. port .. " <- " .. string.format("%q", data) .. "\n"
      end
    end
  end)
  
  local commandThread = thread.create(function()
    while true do
      io.write("> ")
      local input = io.read()
      input = text.tokenize(input)
      if input[1] == "up" then
        local file = io.open("drone_up.lua")
        local sourceCode = file:read(10000000)
        io.write("Uploading \"drone_up.lua\"...\n")
        wnet.send(modem, nil, COMMS_PORT, "drone_upload," .. sourceCode)
      elseif input[1] == "exit" then
        threadSuccess = true
        break
      elseif input[1] == "log" then
        io.write(netLog)
      else
        io.write("Enter \"up\" to upload, or \"exit\" to quit.\n")
      end
    end
  end)
  
  thread.waitForAny({interruptThread, listenThread, commandThread})
  if interruptThread:status() == "dead" then
    os.exit(1)
  elseif not threadSuccess then
    io.stderr:write("Error occurred in thread, check log file \"/tmp/event.log\" for details.\n")
    os.exit(1)
  end
  
  interruptThread:kill()
  listenThread:kill()
  commandThread:kill()
end

main()
