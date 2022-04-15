--[[
Template for lua application code used in various places.

This is some sample code for an application design that seems to scale fairly
well for larger programs. Note that this is not a minimal example, there is
plenty that could be trimmed out depending on the use case.

This program can be run with no arguments, or with "lua app_template.lua test"
to run any implemented tests. Requires the additional libraries listed below to
work properly.
--]]


-- OS libraries.
local component = require("component")
local computer = require("computer")
local event = require("event")
local modem = component.modem
local serialization = require("serialization")
local text = require("text")
local thread = require("thread")

-- User libraries.
local include = require("include")
local dlog = include("dlog")
dlog.osBlockNewGlobals(true)    -- This is used to assert new global variables do not get defined (generally a good practice to avoid the use of globals).
local dstructs = include("dstructs")
local packer = include("packer")
local wnet = include("wnet")

-- Configuration constants.
local COMMS_PORT = 123
local DLOG_FILE_OUT = "/tmp/messages"


-- This function just prints a message.
local function someLocalFunction()
  io.write("hello world!\n")
end


-- MyApp class definition.
local MyApp = {}

-- Hook up errors to throw on access to nil class members (usually a programming
-- error or typo).
setmetatable(MyApp, {
  __index = function(t, k)
    dlog.verboseError("Attempt to read undefined member " .. tostring(k) .. " in MyApp class.", 4)
  end
})

function MyApp:new(vals)
  self.__index = self
  self = setmetatable({}, self)
  
  xassert(#vals >= 3, "size of vals is too small (expected at least 3, got ", #vals, ").")
  self.dat = vals
  
  return self
end


-- A class member function. Utilizes dlog.checkArgs to verify correct arguments
-- passed into the function.
function MyApp:doThing(index)
  dlog.checkArgs(index, "number,nil")
  
  return "selected " .. (index and tostring(self.dat[index]) or "none")
end


-- Callback for handling a received message over the network with the header
-- "test_message" (which won't actually work since this header is not yet
-- defined). See packer module for more details.
function MyApp:handleTestMessage(address, port, message)
  io.write("got message from ", address, ": ", tostring(message), "\n")
  
  -- Send a reply back (also needs to be defined in packer to work).
  wnet.send(modem, address, COMMS_PORT, packer.pack.test_message_reply("hello"))
end
packer.callbacks.test_message = MyApp.handleTestMessage


-- Performs setup and initialization tasks.
function MyApp:setupThreadFunc(mainContext)
  dlog.out("main", "Setup thread starts.")
  modem.open(COMMS_PORT)
  
  someLocalFunction()
  
  io.write(self:doThing(1), "\n")
  io.write(self:doThing(2), "\n")
  io.write(self:doThing(), "\n")
  
  -- Example of a typo that could cause a hard to find bug.
  -- This gets caught and throws an exception thanks to dlog.osBlockNewGlobals().
  --mainContex = {}
  
  -- Report system started to any listening devices.
  --wnet.send(modem, nil, COMMS_PORT, packer.pack.my_app_started())
  
  dlog.out("setup", "Setup done! Enter commands at the prompt for more options, or press Ctrl + C to exit.")
  dlog.out("setup", "Take a look in \"", DLOG_FILE_OUT, "\" to see all dlog messages.")
  
  mainContext.threadSuccess = true
  dlog.out("main", "Setup thread ends.")
end


-- Listens for incoming packets over the network and deals with them.
function MyApp:modemThreadFunc(mainContext)
  dlog.out("main", "Modem thread starts.")
  io.write("Listening for commands on port ", COMMS_PORT, "...\n")
  while true do
    local address, port, message = wnet.receive()
    if port == COMMS_PORT then
      packer.handlePacket(self, address, port, message)
    end
  end
  dlog.out("main", "Modem thread ends.")
end


-- Waits for commands from user-input and executes them.
function MyApp:commandThreadFunc(mainContext)
  dlog.out("main", "Command thread starts.")
  while true do
    io.write("> ")
    local input = io.read()
    if type(input) ~= "string" then
      input = "exit"
    end
    input = text.tokenize(input)
    if input[1] == "help" then    -- Command help
      io.write("Commands:\n")
      io.write("  help\n")
      io.write("    Show this help menu.\n")
      io.write("  exit\n")
      io.write("    Exit program.\n")
    elseif input[1] == "exit" then    -- Command exit
      mainContext.threadSuccess = true
      break
    else
      io.write("Enter \"help\" for command help, or \"exit\" to quit.\n")
    end
  end
  dlog.out("main", "Command thread ends.")
end


-- Get command-line arguments.
local args = {...}

-- Main program starts here.
local function main()
  local mainContext = {}
  mainContext.threadSuccess = false
  mainContext.killProgram = false
  
  -- Wrapper for os.exit() that restores the blocking of globals. Threads
  -- spawned from main() can just call os.exit() instead of this version.
  local function exit(code)
    dlog.osBlockNewGlobals(false)
    os.exit(code)
  end
  
  -- Captures the interrupt signal to stop program.
  local interruptThread = thread.create(function()
    event.pull("interrupted")
  end)
  
  -- Blocks until any of the given threads finish. If threadSuccess is still
  -- false and a thread exits, reports error and exits program.
  local function waitThreads(threads)
    thread.waitForAny(threads)
    if interruptThread:status() == "dead" or mainContext.killProgram then
      exit()
    elseif not mainContext.threadSuccess then
      io.stderr:write("Error occurred in thread, check log file \"/tmp/event.log\" for details.\n")
      exit()
    end
    mainContext.threadSuccess = false
  end
  
  if DLOG_FILE_OUT ~= "" then
    dlog.setFileOut(DLOG_FILE_OUT, "w")
  end
  
  -- Check for any command-line arguments passed to the program.
  if next(args) ~= nil then
    if args[1] == "test" then
      io.write("Tests not yet implemented.\n")
      exit()
    else
      io.stderr:write("Unknown argument \"", tostring(args[1]), "\".\n")
      exit()
    end
  end
  
  local myApp = MyApp:new({"apples", "bananas", "oranges"})
  
  local setupThread = thread.create(MyApp.setupThreadFunc, myApp, mainContext)
  
  waitThreads({interruptThread, setupThread})
  
  local modemThread = thread.create(MyApp.modemThreadFunc, myApp, mainContext)
  local commandThread = thread.create(MyApp.commandThreadFunc, myApp, mainContext)
  
  waitThreads({interruptThread, modemThread, commandThread})
  
  dlog.out("main", "Killing threads and stopping program.")
  interruptThread:kill()
  modemThread:kill()
  commandThread:kill()
end

main()
dlog.osBlockNewGlobals(false)
