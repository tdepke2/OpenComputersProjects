local component = require("component")
local crobot = component.robot
local sides = require("sides")

local robnav = require("robnav")

-- Quarry class definition.
local Quarry = {}

-- Hook up errors to throw on access to nil class members (usually a programming
-- error or typo).
setmetatable(Quarry, {
  __index = function(t, k)
    dlog.errorWithTraceback("Attempt to read undefined member " .. tostring(k) .. " in Quarry class.")
  end
})

function Quarry:new()
  self.__index = self
  setmetatable({}, self)
  
  return self
end

-- Get command-line arguments.
local args = {...}

local function main()
  
end
