--[[
Experiments with proper object-oriented design in Lua.

https://www.lua.org/pil/16.html
http://lua-users.org/wiki/ObjectOrientationTutorial
--]]



-- Base class. Define "static members" and default values in this table.
local Account = {
  MAX_ACCOUNTS = 100,
  bal = 0
}

-- Constructor (ctor). Call once to initialize and return object.
function Account:new(id)
  -- Essentially does "Account.__index = Account" for step below. Could be moved to Account table definition, but then we would require a ctor to be defined for derived classes.
  self.__index = self
  
  -- Create the object instance and call this self (hides the previous value of self because it refers to the class instead of the object).
  self = setmetatable({}, self)
  
  -- Assign value to member variable.
  self.id = id
  
  return self
end

-- Member functions.
function Account:deposit(v)
  self.bal = self.bal + v
end

function Account:withdraw(v)
  if v > self.bal then
    print("Insufficient funds to withdraw from account " .. self.id)
    return
  end
  self.bal = self.bal - v
end



-- Derived class. Declared as an instance of the base class, with additional functionality added (like a prototype).
local CreditAccount = Account:new()
CreditAccount.CREDIT_TYPE = "fixed limit"

-- Optional. Can leave this out to use the base class ctor.
function CreditAccount:new(id, creditLimit)
  self.__index = self
  self = setmetatable(Account:new(id), self)
  
  self.creditLimit = creditLimit
  
  return self
end

-- Derived member functions (override the corresponding ones in base class).
function CreditAccount:withdraw(v)
  if v - self.bal > self:getCreditLimit() then
    print("Insufficient funds to withdraw from account " .. self.id)
    return
  end
  self.bal = self.bal - v
end

function CreditAccount:getCreditLimit()
  return self.creditLimit or 0
end



print("\nCreate account a")
local a = Account:new(123)
print("a.id = ", a.id)
print("a.bal = ", a.bal)
a:deposit(5)
print("a.bal = ", a.bal)
a:withdraw(3)
print("a.bal = ", a.bal)

print("\nCreate account b")
local b = Account:new(456)
print("b.id = ", b.id)
print("a.id = ", a.id)
print("b.bal = ", b.bal)
b:deposit(3)
print("b.bal = ", b.bal)
b:withdraw(5)
print("b.bal = ", b.bal)

print("\nCreate special account c")
local c = CreditAccount:new(789, 100)
print("c.id = ", c.id)
print("c.creditLimit = ", c.creditLimit)
print("b.id = ", b.id)
print("a.id = ", a.id)
print("c.bal = ", c.bal)
c:deposit(4)
print("c.bal = ", c.bal)
c:withdraw(10)
print("c.bal = ", c.bal)
c:withdraw(100)
print("c.bal = ", c.bal)
print("c:getCreditLimit() = ", c:getCreditLimit())






local function a1(t, k)
  print("ERROR: Attempt access to non-existent key " .. tostring(k))
end

local function a2(t, k, v)
  if t[k] == nil then
    print("ERROR: Attempt write to non-existent key " .. tostring(k))
  else
    rawset(t, k, v)
  end
end

-- Adds error checking for undefined member access to a class. This would ideally protect against typos in member assignment and require all member vars to be defined in the ctor.
-- As a side effect, this causes problems if a member var gets set to nil and then accessed later.
local function makeClassRigid(cls, obj)
  local m1 = getmetatable(cls) or {}
  m1.__index = a1
  setmetatable(cls, m1)
  
  local m2 = getmetatable(obj) or {}
  m2.__newindex = a2
  setmetatable(obj, m2)
end


-- Version 2 of the above. Saves the currently defined members in a table to fix the problem with nil assignment.
local function makeClassRigid2(cls, obj)
  local function invalidRead(t, k)
    --print("__index() invoked")
    --assert(t._makeClassRigid)
    if not t._makeClassRigid[k] then
      print("ERROR: Attempt access to non-existent key " .. tostring(k))
      --print("table is", t)
    end
  end
  
  local function invalidWrite(t, k, v)
    --print("__newindex() invoked")
    --assert(getmetatable(t)._makeClassRigid)
    if not getmetatable(t)._makeClassRigid[k] then
      print("ERROR: Attempt write to non-existent key " .. tostring(k))
      --print("table is", t)
    else
      rawset(t, k, v)
    end
  end
  
  if not cls._makeClassRigid then
    cls._makeClassRigid = {}
    for k, _ in pairs(cls) do
      cls._makeClassRigid[k] = true
    end
    for k, _ in pairs(obj) do
      cls._makeClassRigid[k] = true
    end
    local m1 = getmetatable(cls) or {}
    m1.__index = invalidRead
    setmetatable(cls, m1)
  end
  local m2 = getmetatable(obj) or {}
  m2.__newindex = invalidWrite
  setmetatable(obj, m2)
  
  --print("invalidRead is", invalidRead)
  --print("invalidWrite is", invalidWrite)
end



local Account2 = {
  MAX_ACCOUNTS = 100,
  bal = 0
}

function Account2:new(id)
  local cls = self
  cls.__index = function(t, k) print("Not found key " .. tostring(k) .. ", deferring to base") return cls[k] end
  self = setmetatable({}, self)
  
  self.id = id
  
  --makeClassRigid(Account2, self)
  makeClassRigid2(Account2, self)
  
  return self
end

function Account2:deposit(v)
  self.bal = self.bal + v
end

function Account2:withdraw(v)
  if v > self.bal then
    print("Insufficient funds to withdraw from account " .. self.id)
    return
  end
  self.bal = self.bal - v
end



print("\nCreate account d")
local d = Account2:new(111)


print("contents:")
for k, v in pairs(d) do
  print(k, "->", v)
end


print("d.id = ", d.id)
print("d.bal = ", d.bal)
d:deposit(5)
print("d.bal = ", d.bal)
d:withdraw(3)
print("d.bal = ", d.bal)
print("d.cool = ", d.cool)
d.cool = 3
d.bal = 100
print("d.bal = ", d.bal)
d.id = nil
print("d.id = ", d.id)
