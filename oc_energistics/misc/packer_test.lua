local packer = require("packer")

-- Option 1, function is not bound to any class (not very scalable because we have to lexically scope any persistent data or make it global)
packer.callbacks.stor_drone_insert = function(_, _, _, droneInvIndex, ticket)
  print("insert callback invoked with droneInvIndex = " .. tostring(droneInvIndex) .. ", ticket = " .. tostring(ticket))
end

local MyClass = {}

function MyClass:new(obj)
  obj = obj or {}
  setmetatable(obj, self)
  self.__index = self
  
  self.dat = 123
  
  return obj
end

-- Option 2, nice to keep the class method bound to the class. Also, easy to switch out callbacks later on.
function MyClass:handleStorDroneExtract(address, port, droneInvIndex, ticket, extractList)
  print("extract callback invoked with droneInvIndex = " .. tostring(droneInvIndex) .. ", ticket = " .. tostring(ticket) .. ", extractList = " .. tostring(extractList))
  self.dat = self.dat + 3
  print("self.dat is now " .. self.dat)
  print("packet had arrived from " .. address .. " on port " .. port)
end
packer.callbacks.stor_drone_extract = MyClass.handleStorDroneExtract

-- Option 3, may be more preferred to reduce the number of packet header names in code?
--[[
packer.callbacks.stor_drone_extract = function(self, droneInvIndex, ticket, extractList)
  print("extract callback invoked with droneInvIndex = " .. tostring(droneInvIndex) .. ", ticket = " .. tostring(ticket) .. ", extractList = " .. tostring(extractList))
  self.dat = self.dat + 1
  print("self.dat is now " .. self.dat)
end
--]]

do
  local myClass = MyClass:new()
  
  packer.handlePacket(nil, "my_address", 58008, "stor_drone_insert,1,id123,minecraft:coal/1,16")
  packer.handlePacket(nil, "my_address", 58008, "idk,beans")
  packer.handlePacket(nil, "my_address", 58008, "")
  packer.handlePacket(nil, "my_address", 58008, ",")
  packer.handlePacket(myClass, "my_address", 58008, "stor_drone_extract,1,;{\"banana\",123}")
  packer.handlePacket(myClass, "my_address", 58008, "stor_drone_extract,2,ticket_name;{\"orange\",456}")
  
  local sent = packer.pack.stor_drone_insert(5, "id2,thermal:copper_dust/0,1")
  print("wnet.send: " .. sent)
  packer.handlePacket(nil, "my_address", 58008, sent)
end
