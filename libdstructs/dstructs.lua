--[[
Data structures and data helpers.


--]]

local dstructs = {}

-- dstructs.rawObjectsEqual(obj1: any, obj2: any): boolean
-- 
-- Checks two tables (or other data) to determine if they are equivalent using a
-- recursive comparison. This does a "raw" comparison meaning any metamethods
-- like __index, __newindex, __eq, and __pairs will be ignored. Currently this
-- does not compare metatables and assumes there are no cycles caused by tables
-- referencing previous ones. Returns true if and only if all key-value pairs in
-- obj1 and obj2 are equivalent.
function dstructs.rawObjectsEqual(obj1, obj2)
  if type(obj1) ~= type(obj2) then
    return false
  elseif type(obj1) ~= "table" then
    return obj1 == obj2
  end
  
  -- Confirm all items in obj1 are in obj2 (and they are equal).
  local n1 = 0
  for k1, v1 in next, obj1 do
    local v2 = rawget(obj2, k1)
    if v2 == nil or not dstructs.rawObjectsEqual(v1, v2) then
      return false
    end
    n1 = n1 + 1
  end
  
  -- Count items in obj2, and confirm this matches the length of obj1.
  local n2 = 0
  for k2, _ in next, obj2 do
    n2 = n2 + 1
  end
  
  return n1 == n2
end

-- dstructs.moveTableReference(src: table, dest: table)
-- 
-- Performs a move (copy) operation from table src into table dest, this allows
-- changing the memory address of the original table. If the dest table has a
-- metatable with the __metatable field defined, an error is raised. If the src
-- table has a reference back to itself, an error is raised as this would imply
-- that the reference was not fully moved.
function dstructs.moveTableReference(src, dest)
  -- Clear contents of dest.
  setmetatable(dest, nil)
  for k, _ in next, dest do
    dest[k] = nil
  end
  assert(next(dest) == nil and getmetatable(dest) == nil)
  
  -- Shallow copy contents over.
  for k, v in next, src do
    dest[k] = v
  end
  setmetatable(dest, getmetatable(src))
  
  -- Verify no cyclic references back to src (not perfect, does not check metatables).
  local searched = {}
  local function recursiveSearch(t)
    if searched[t] then
      return
    end
    searched[t] = true
    assert(not rawequal(t, src), "Found a reference back to source table.")
    for k, v in next, t do
      if type(k) == "table" then
        recursiveSearch(k)
      end
      if type(v) == "table" then
        recursiveSearch(v)
      end
    end
  end
  recursiveSearch(dest)
end

-- Makes a deep copy of a table (or just returns the given argument otherwise).
-- This uses raw iteration (metamethods are ignored) and also makes deep copies
-- of metatables. Currently does not behave with cycles in tables.
-- 
---@param src any
---@return any srcCopy
function dstructs.deepCopy(src)
  if type(src) == "table" then
    local srcCopy = {}
    for k, v in next, src do
      srcCopy[k] = dstructs.deepCopy(v)
    end
    local meta = getmetatable(src)
    if meta ~= nil then
      setmetatable(srcCopy, dstructs.deepCopy(meta))
    end
    return srcCopy
  else
    return src
  end
end

-- Recursively updates `dest` to become the union of tables `src` and `dest`
-- (these don't have to be tables though). Values from `src` will overwrite ones
-- in `dest`, except when `src` is nil. The same process is applied to
-- metatables in `src` and `dest`.
-- 
---@param src any
---@param dest any
---@return any merged
function dstructs.mergeTables(src, dest)
  if type(src) == "table" then
    if type(dest) == "table" then
      for k, v in next, src do
        dest[k] = dstructs.mergeTables(v, dest[k])
      end
      local srcMeta, destMeta = getmetatable(src), getmetatable(dest)
      if srcMeta ~= nil or destMeta ~= nil then
        setmetatable(dest, dstructs.mergeTables(srcMeta, destMeta))
      end
    else
      return dstructs.deepCopy(src)
    end
  elseif src ~= nil then
    return src
  end
  return dest
end



-- Array of characters with a fixed size. Similar to a string, but the
-- individual characters can be modified (without much performance loss for
-- large sizes). The chunkSize determines the length of the strings used
-- internally, and should be chosen to get a balance between performance and
-- memory efficiency.
dstructs.CharArray = {}

-- dstructs.CharArray:new(size: number[, chunkSize: number[,
--   fillChar: string]]): table
-- 
-- Creates a new CharArray with the specified size. If the chunkSize is
-- provided, this is used as the length for each string in the internal table
-- (defaults to 16). If the fillChar is provided, each value in the array is
-- initialized to this character (defaults to 0).
function dstructs.CharArray:new(size, chunkSize, fillChar)
  self.__index = self
  self = setmetatable({}, self)
  
  chunkSize = chunkSize or 16
  fillChar = fillChar or string.char(0)
  
  self.size = size
  self.chunkSize = chunkSize
  self.arr = {}
  self:clear(fillChar)
  
  return self
end

-- dstructs.CharArray:get(i: number): string
-- 
-- Get the character at the specified index.
function dstructs.CharArray:get(i)
  assert(i >= 1 and i <= self.size, "Index out of bounds.")
  return string.sub(self.arr[(i - 1) // self.chunkSize + 1], (i - 1) % self.chunkSize + 1, (i - 1) % self.chunkSize + 1)
end

-- dstructs.CharArray:set(i: number, char: string)
-- 
-- Set the character at the specified index.
function dstructs.CharArray:set(i, char)
  assert(i >= 1 and i <= self.size, "Index out of bounds.")
  assert(#char == 1, "Char string must contain a single character.")
  local chunk = self.arr[(i - 1) // self.chunkSize + 1]
  self.arr[(i - 1) // self.chunkSize + 1] = string.sub(chunk, 1, (i - 1) % self.chunkSize) .. char .. string.sub(chunk, (i - 1) % self.chunkSize + 2)
end

-- dstructs.CharArray:sub(i: number[, j: number])
-- 
-- Get a substring of the character array between the two indicies. Works just
-- like string.sub() does. If j is not provided, defaults to -1 (last character
-- in array).
function dstructs.CharArray:sub(i, j)
  j = j or -1
  if i < 0 then
    i = math.max(self.size + i + 1, 1)
  end
  if j < 0 then
    j = self.size + j + 1
  end
  j = math.min(j, self.size)
  if i > j then
    return ""
  end
  
  local s = ""
  -- If i does not align to the start of the chunk, add the partial beginning of the chunk so that it does.
  if i % self.chunkSize ~= 1 then
    s = string.sub(self.arr[(i - 1) // self.chunkSize + 1], (i - 1) % self.chunkSize + 1)
    i = i + #s
  end
  -- Add consecutive chunks until we get at least the characters up to j.
  while i <= j do
    s = s .. self.arr[(i - 1) // self.chunkSize + 1]
    i = i + self.chunkSize
  end
  -- Clip off any extra characters in the last chunk.
  return string.sub(s, 1, j - i)
end

-- dstructs.CharArray:clear(char: string)
-- 
-- Clear the contents of the array, and replace each character with char if
-- provided. Characters are set to 0 otherwise.
function dstructs.CharArray:clear(char)
  assert(#char == 1, "Char string must contain a single character.")
  char = char or string.char(0)
  for i = 1, (self.size + self.chunkSize - 1) // self.chunkSize do
    self.arr[i] = string.rep(char, self.chunkSize)
  end
end



-- Array of bytes with a fixed size. Each byte is individually addressable and
-- assignable. This is designed to work like a table full of numbers (and
-- internally works this way), but uses about eight times less memory.
dstructs.ByteArray = {}

-- dstructs.ByteArray:new(size: number[, fillVal: number]): table
-- 
-- Creates a new ByteArray with the specified size. If the fillVal is provided,
-- each byte will be initialized with this value. The bytes will be initialized
-- to zero otherwise. Note that the fillVal, and other val arguments passed to
-- functions of this class, must fit into an unsigned byte (0 <= val <= 255).
function dstructs.ByteArray:new(size, fillVal)
  self.__index = self
  self = setmetatable({}, self)
  
  fillVal = fillVal or 0
  
  self.size = size
  self.arr = {}
  self:clear(fillVal)
  
  return self
end

-- dstructs.ByteArray:get(i: number): number
-- 
-- Get the value at the specified index.
function dstructs.ByteArray:get(i)
  assert(i >= 1 and i <= self.size, "Index out of bounds.")
  local sh = (i - 1) % 8 * 8
  return (self.arr[(i - 1) // 8 + 1] & (0xFF << sh)) >> sh
end

-- dstructs.ByteArray:set(i: number, val: number)
-- 
-- Set the value at the specified index.
function dstructs.ByteArray:set(i, val)
  assert(i >= 1 and i <= self.size, "Index out of bounds.")
  assert(val >= 0 and val <= 0xFF, "Value must be unsigned byte.")
  local sh = (i - 1) % 8 * 8
  self.arr[(i - 1) // 8 + 1] = self.arr[(i - 1) // 8 + 1] & ~(0xFF << sh) | (val << sh)
end

-- dstructs.ByteArray:clear([val: number])
-- 
-- Clear the contents of the array, and replace each byte with val if provided.
-- Bytes are set to zero otherwise.
function dstructs.ByteArray:clear(val)
  assert(val >= 0 and val <= 0xFF, "Value must be unsigned byte.")
  val = val or 0
  local chunkVal = 0
  for i = 1, 8 do
    chunkVal = (chunkVal << 8) | val
  end
  for i = 1, (self.size + 7) // 8 do
    self.arr[i] = chunkVal
  end
end



-- The deque is a double-ended queue (like a deck of cards). This can be used as
-- a queue or a stack. As a queue, push new items to the back and pop items from
-- the front. As a stack, push new items to the front and pop from the front.
-- 
-- The underlying implementation uses a table sequence that starts at an
-- arbitrary index. We assume that this starting index will never grow beyond
-- the bounds of a double-precision integer (this would cause the deque to
-- break). It would take approximately 1.84467e+19 push operations to do this.
dstructs.Deque = {}

-- dstructs.Deque:new()
-- 
-- Creates a new Deque with empty contents.
function dstructs.Deque:new()
  self.__index = self
  self = setmetatable({}, self)
  
  self:clear()
  
  return self
end

-- dstructs.Deque:empty(): boolean
-- 
-- Check if empty contents.
function dstructs.Deque:empty()
  return self.length == 0
end

-- dstructs.Deque:size(): number
-- 
-- Get the length of the deque. Returns zero if empty.
function dstructs.Deque:size()
  return self.length
end

-- dstructs.Deque:front(): any
-- 
-- Get the item at the front (or top) of the deque. If empty, returns nil.
function dstructs.Deque:front()
  return self.arr[self.backIndex + self.length - 1]
end

-- dstructs.Deque:back(): any
-- 
-- Get the item at the back (or bottom) of the deque. If empty, returns nil.
function dstructs.Deque:back()
  return self.arr[self.backIndex]
end

-- dstructs.Deque:push_front(val: any)
-- 
-- Add a value to the front of the deque. Increases the size by 1.
function dstructs.Deque:push_front(val)
  self.arr[self.backIndex + self.length] = val
  self.length = self.length + 1
end

-- dstructs.Deque:push_back(val: any)
-- 
-- Add a value to the back of the deque. Increases the size by 1.
function dstructs.Deque:push_back(val)
  self.backIndex = self.backIndex - 1
  self.arr[self.backIndex] = val
  self.length = self.length + 1
end

-- dstructs.Deque:pop_front()
-- 
-- Remove a value from the front of the deque. Decreases the size by 1.
function dstructs.Deque:pop_front()
  self.arr[self.backIndex + self.length - 1] = nil
  self.length = self.length - 1
end

-- dstructs.Deque:pop_back()
-- 
-- Remove a value from the back of the deque. Decreases the size by 1.
function dstructs.Deque:pop_back()
  self.arr[self.backIndex] = nil
  self.backIndex = self.backIndex + 1
  self.length = self.length - 1
end

-- dstructs.Deque:clear()
-- 
-- Erase all of the contents of the deque. Resets the size to zero.
function dstructs.Deque:clear()
  self.arr = {}
  self.backIndex = 1
  self.length = 0
end

return dstructs
