--[[
When sending a message with the local loopback address and waiting for it to
send, the thread should block until the message is processed. This was not
happening and the mnet.send() call was returning nil (because loopback packets
don't go in mnetSentPackets like the rest of reliable packets). This bug is
fixed in df338d41335db440ca7dbe6b500ef930e1d1b828.
--]]

local event = require("event")
local thread = require("thread")

local include = require("include")
local dlog = include("dlog")
dlog.mode("debug")
local mnet = include("mnet")

mnet.debugSetSmallMTU(true)

local caughtInterrupt = false

local listenerThread = thread.create(function()
  print("too lazy to process packets right now, zzzzz")
  os.sleep(4)
  while not caughtInterrupt do
    local host, port, message = mnet.receive(0.1)
    if host then
      dlog.out("listenerThread", host, ", ", port, ", ", message)
    end
  end
  dlog.out("listenerThread", "shutting down...")
end)

local interruptThread = thread.create(function()
  event.pull("interrupted")
  caughtInterrupt = true
  mnet.debugSetSmallMTU(false)
end)

dlog.out("main", "send results: ", mnet.send("localhost", 123, "my_message", true, true))
dlog.out("main", "send results 2: ", mnet.send("localhost", 123, "this message is longer than 10 chars!", true, true))
