-- This file goes in `/usr/lib` and gets run when the systemd_testd program starts.

-- TestDaemon class definition.
local TestDaemon = {}

-- Hook up errors to throw on access to nil class members (usually a programming
-- error or typo).
setmetatable(TestDaemon, {
  __index = function(t, k)
    error("attempt to read undefined member " .. tostring(k) .. " in TestDaemon class.", 2)
  end
})


function TestDaemon:new(...)
  self.__index = self
  self = setmetatable({}, self)

  self.myCounter = 0
  self.args = table.pack(...)
  self.running = true

  return self
end


function TestDaemon:start()
  self.myCounter = self.myCounter + 1
  io.write("TestDaemon:start(), myCounter = ", self.myCounter, ", arg1 = ", self.args[1], "\n")
  while self.running do
    os.sleep(1)
  end
end


function TestDaemon:stop()
  io.write("TestDaemon:stop() called\n")
  self.running = false
end

return TestDaemon
