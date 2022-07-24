
-- Example of closures.
-- For more performance examples see: https://www.lua.org/gems/sample.pdf

-- Function that generates a closure every time.
-- The "x" in f() is the only upvalue used, this will generate a closure on call to dothing().
-- Removing "x" in the return or adding it to the parameters of f() will prevent creation of closure.
local function dothing(x)
    local function f() return "foobar", x end
    return f
end

local x1 = dothing(1)
print(x1, x1())
print(debug.getupvalue(x1, 1))    -- Prints "x    1" since we have an upvalue.
local x2 = dothing(2)
print(x2, x2())
print(debug.getupvalue(x1, 1))    -- Prints "x    1" since we have an upvalue.
print()



-- Examples functions that resuse the same closures (making a closure requires a slight bit of overhead).
local icontroller = {}

function icontroller.getStackInInternalSlot(slot)
    return {
        name = "item in " .. slot,
        count = 10
    }
end

local function invIterator(itemIter)
  local function iter(itemIter, slot)
    slot = slot + 1
    local item = itemIter()
    while item do
      if next(item) ~= nil then
        return slot, item
      end
      slot = slot + 1
      item = itemIter()
    end
  end
  
  return iter, itemIter, 0
end

local function internalInvIterator(invSize)
  local function iter(invSize, slot)
    local item
    while slot < invSize do
      slot = slot + 1
      item = icontroller.getStackInInternalSlot(slot)
      if item then
        return slot, item
      end
    end
  end
  
  return iter, invSize, 0
end


local function getAllStacks()
    local x = 0
    return function()
        x = x + 1
        if x > 3 then return end
        return icontroller.getStackInInternalSlot(x)
    end
end

local it, state, val

print("my items 1")
it, state, val = invIterator(getAllStacks())
print(it)
print(debug.getupvalue(it, 1))    -- Prints "_ENV    table: 0x5648de4a0bc0"
print(debug.getupvalue(it, 2))    -- Prints ""
for slot, item in it, state, val do
  print(slot, item.name)
end

print("my items 2")
it, state, val = invIterator(getAllStacks())
print(it)
print(debug.getupvalue(it, 1))    -- Prints "_ENV    table: 0x5648de4a0bc0"
print(debug.getupvalue(it, 2))    -- Prints ""
for slot, item in it, state, val do
  print(slot, item.name)
end
print()


print("my items 1")
it, state, val = internalInvIterator(3)
print(it)
print(debug.getupvalue(it, 1))    -- Prints "icontroller    table: 0x5648de4a3ef0"
print(debug.getupvalue(it, 2))    -- Prints ""
for slot, item in it, state, val do
  print(slot, item.name)
end

print("my items 2")
it, state, val = internalInvIterator(3)
print(it)
print(debug.getupvalue(it, 1))    -- Prints "icontroller    table: 0x5648de4a3ef0"
print(debug.getupvalue(it, 2))    -- Prints ""
for slot, item in it, state, val do
  print(slot, item.name)
end
