--[[
Data structures


--]]

local common = {}

-- Array of characters with a fixed size. Similar to a string, but the
-- individual characters can be modified (without much performance loss for
-- large sizes). The chunkSize determines the length of the strings used
-- internally, and should be chosen to get a balance between performance and
-- memory efficiency.
common.CharArray = {}

-- common.CharArray:new(obj: table|nil, size: number[, chunkSize: number[, fillChar: string]]): table
-- 
-- Creates a new CharArray with the specified size. If the chunkSize is
-- provided, this is used as the length for each string in the internal table
-- (defaults to 16). If the fillChar is provided, each value in the array is
-- initialized to this character (defaults to 0).
function common.CharArray:new(obj, size, chunkSize, fillChar)
  obj = obj or {}
  setmetatable(obj, self)
  self.__index = self
  
  chunkSize = chunkSize or 16
  fillChar = fillChar or string.char(0)
  
  self.size = size
  self.chunkSize = chunkSize
  self.arr = {}
  self:clear(fillChar)
  
  return obj
end

-- common.CharArray:get(i: number): string
-- 
-- Get the character at the specified index.
function common.CharArray:get(i)
  assert(i >= 1 and i <= self.size, "Index out of bounds.")
  return string.sub(self.arr[(i - 1) // self.chunkSize + 1], (i - 1) % self.chunkSize + 1, (i - 1) % self.chunkSize + 1)
end

-- common.CharArray:set(i: number, char: string)
-- 
-- Set the character at the specified index.
function common.CharArray:set(i, char)
  assert(i >= 1 and i <= self.size, "Index out of bounds.")
  assert(#char == 1, "Char string must contain a single character.")
  local chunk = self.arr[(i - 1) // self.chunkSize + 1]
  self.arr[(i - 1) // self.chunkSize + 1] = string.sub(chunk, 1, (i - 1) % self.chunkSize) .. char .. string.sub(chunk, (i - 1) % self.chunkSize + 2)
end

-- common.CharArray:sub(i: number[, j: number])
-- 
-- Get a substring of the character array between the two indicies. Works just
-- like string.sub() does. If j is not provided, defaults to -1 (last character
-- in array).
function common.CharArray:sub(i, j)
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

-- common.CharArray:clear(char: string)
-- 
-- Clear the contents of the array, and replace each character with char if
-- provided. Characters are set to 0 otherwise.
function common.CharArray:clear(char)
  assert(#char == 1, "Char string must contain a single character.")
  char = char or string.char(0)
  for i = 1, (self.size + self.chunkSize - 1) // self.chunkSize do
    self.arr[i] = string.rep(char, self.chunkSize)
  end
end



-- Array of bytes with a fixed size. Each byte is individually addressable and
-- assignable. This is designed to work like a table full of numbers (and
-- internally works this way), but uses about eight times less memory.
common.ByteArray = {}

-- common.ByteArray:new(obj: table|nil, size: number[, fillVal: number]): table
-- 
-- Creates a new ByteArray with the specified size. If the fillVal is provided,
-- each byte will be initialized with this value. The bytes will be initialized
-- to zero otherwise. Note that the fillVal, and other val arguments passed to
-- functions of this class, must fit into an unsigned byte (0 <= val <= 255).
function common.ByteArray:new(obj, size, fillVal)
  obj = obj or {}
  setmetatable(obj, self)
  self.__index = self
  
  fillVal = fillVal or 0
  
  self.size = size
  self.arr = {}
  self:clear(fillVal)
  
  return obj
end

-- common.ByteArray:get(i: number): number
-- 
-- Get the value at the specified index.
function common.ByteArray:get(i)
  assert(i >= 1 and i <= self.size, "Index out of bounds.")
  local sh = (i - 1) % 8 * 8
  return (self.arr[(i - 1) // 8 + 1] & (0xFF << sh)) >> sh
end

-- common.ByteArray:set(i: number, val: number)
-- 
-- Set the value at the specified index.
function common.ByteArray:set(i, val)
  assert(i >= 1 and i <= self.size, "Index out of bounds.")
  assert(val >= 0 and val <= 0xFF, "Value must be unsigned byte.")
  local sh = (i - 1) % 8 * 8
  self.arr[(i - 1) // 8 + 1] = self.arr[(i - 1) // 8 + 1] & ~(0xFF << sh) | (val << sh)
end

-- common.ByteArray:clear([val: number])
-- 
-- Clear the contents of the array, and replace each byte with val if provided.
-- Bytes are set to zero otherwise.
function common.ByteArray:clear(val)
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



-- Deque class (like a deck of cards). Works like a queue or a stack.
common.Deque = {}

function common.Deque:new(obj)
  obj = obj or {}
  setmetatable(obj, self)
  self.__index = self
  
  self.backIndex = 1
  self.length = 0
  
  return obj
end

function common.Deque:empty()
  return self.length == 0
end

function common.Deque:size()
  return self.length
end

function common.Deque:front()
  return self[self.backIndex + self.length - 1]
end

function common.Deque:back()
  return self[self.backIndex]
end

function common.Deque:push_front(val)
  self[self.backIndex + self.length] = val
  self.length = self.length + 1
end

function common.Deque:push_back(val)
  self.backIndex = self.backIndex - 1
  self[self.backIndex] = val
  self.length = self.length + 1
end

function common.Deque:pop_front()
  self[self.backIndex + self.length - 1] = nil
  self.length = self.length - 1
end

function common.Deque:pop_back()
  self[self.backIndex] = nil
  self.backIndex = self.backIndex + 1
  self.length = self.length - 1
end

function common.Deque:clear()
  while self.length > 0 do
    self[self.backIndex + self.length - 1] = nil
    self.length = self.length - 1
  end
end

return common
