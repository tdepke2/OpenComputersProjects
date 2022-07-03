--------------------------------------------------------------------------------
-- Template for lua application code used in various places.
-- 
-- This is some sample code for an application design that seems to scale fairly
-- well for larger programs. Note that this is not a minimal example, there is
-- plenty that could be trimmed out depending on the use case.
-- 
-- This program can be run with no arguments, or "./app_template.lua test" to
-- run any implemented tests. Requires the additional libraries listed below to
-- work properly.
-- 
-- @see file://libapptools/README.md
-- @see file://libmnet/README.md
-- @author tdepke2
--------------------------------------------------------------------------------


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
local app = include("app"):new()
local dlog = include("dlog")
-- This is used to assert new global variables do not get defined (generally a good practice to avoid the use of globals).
-- It runs in a cleanup task to undo the globals blocking right before the application stops.
app:pushCleanupTask(dlog.osBlockNewGlobals, true, false)
local dstructs = include("dstructs")
local mnet = include("mnet")
local mrpc_server = include("mrpc").newServer(456)


-- Declarations for the mrpc_server. This is usually done in a separate file and
-- loaded in with mrpc_server.addDeclarations(dofile(...)).
mrpc_server.addDeclarations({
  -- Sample RPC declaration, a single string parameter is defined.
  test_message = {
    {
      "message", "string",
    },
  },
})


-- Configuration constants.
local MRPC_PORT = mrpc_server.port
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


-- Constructor for MyApp.
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


-- Callback for handling a remote procedure call request from another server.
-- See mrpc module for more details.
function MyApp:handleTestMessage(host, message)
  dlog.out("handleTestMessage", "Got message from ", host, ": ", message)
  
  -- Send a reply back (needs to be declared in mrpc_server to work).
  --mrpc_server.sync.test_message_reply(host, "hey I got your message!")
end
mrpc_server.functions.test_message = MyApp.handleTestMessage


-- Performs setup and initialization tasks.
function MyApp:setupThreadFunc()
  -- Example of a typo that could cause a hard to find bug.
  -- This gets caught and throws an exception thanks to dlog.osBlockNewGlobals().
  --io.write("MRPC is using port ", tostring(MRPC_ORT), " for comms.\n")
  
  io.write("MRPC is using port ", tostring(MRPC_PORT), " for comms.\n")
  
  someLocalFunction()
  
  io.write(self:doThing(1), "\n")
  io.write(self:doThing(2), "\n")
  io.write(self:doThing(), "\n")
  
  -- Send a message to any active servers.
  mrpc_server.async.test_message("*", "hello! anyone there?")
  
  dlog.out("setup", "Setup done! Enter commands at the prompt for more options, or press Ctrl + C to exit.")
  dlog.out("setup", "Take a look in \"", DLOG_FILE_OUT, "\" to see all dlog messages.")
  
  app:threadDone()
end


-- Listens for incoming packets over the network and deals with them.
function MyApp:networkThreadFunc()
  io.write("Listening for network events on port ", mnet.port, "...\n")
  while true do
    local host, port, message = mnet.receive(0.1)
    mrpc_server.handleMessage(self, host, port, message)
  end
end


-- Waits for commands from user-input and executes them.
function MyApp:commandThreadFunc()
  while true do
    io.write("> ")
    local input = io.read()
    if type(input) ~= "string" then
      input = ""
    end
    input = text.tokenize(input)
    if input[1] == "help" then    -- Command help
      io.write("Commands:\n")
      io.write("  help\n")
      io.write("    Show this help menu.\n")
      io.write("  exit\n")
      io.write("    Exit program.\n")
    elseif input[1] == "exit" then    -- Command exit
      app:exit()
    else
      io.write("Enter \"help\" for command help, or \"exit\" to quit.\n")
    end
  end
end


-- Get command-line arguments.
local args = {...}

-- Main program starts here.
local function main()
  if DLOG_FILE_OUT ~= "" then
    dlog.setFileOut(DLOG_FILE_OUT, "w")
  end
  
  -- Check for any command-line arguments passed to the program.
  if next(args) ~= nil then
    if args[1] == "test" then
      io.write("Tests not yet implemented.\n")
      app:exit(1)
    else
      io.stderr:write("Unknown argument \"", tostring(args[1]), "\".\n")
      app:exit(1)
    end
  end
  
  local myApp = MyApp:new({"apples", "bananas", "oranges"})
  
  -- Captures the interrupt signal to stop program.
  app:createThread("Interrupt", function()
    event.pull("interrupted")
    app:exit(1)
  end)
  
  app:createThread("Setup", MyApp.setupThreadFunc, myApp)
  
  app:waitAnyThreads()
  
  app:createThread("Network", MyApp.networkThreadFunc, myApp)
  app:createThread("Command", MyApp.commandThreadFunc, myApp)
  
  app:waitAnyThreads()
end

main()
app:exit()
