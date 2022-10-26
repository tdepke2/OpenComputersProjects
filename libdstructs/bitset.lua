-- 
-- Inspiration taken from:
-- https://en.cppreference.com/w/cpp/utility/bitset
-- https://github.com/bsm/bitset.lua

local band = function(a, b) return a & b end
local bor = function(a, b) return a | b end
local bxor = function(a, b) return a ~ b end
local bnot = function(a) return ~a end
local lshift = function(a, b) return a << b end
local rshift = function(a, b) return a >> b end
local floor = math.floor

-- Constant lookup tables.
local NIBBLE_BIT_COUNTS = {
  [0] = 0, 1, 1, 2, 1, 2, 2, 3,
  1, 2, 2, 3, 2, 3, 3, 4
}
local MOD_37_BIT_POSITIONS = {
  [0] = 32, 0, 1, 26, 2, 23, 27, 0, 3, 16, 24, 30, 28, 11, 0, 13, 4,
  7, 17, 0, 25, 22, 31, 15, 29, 10, 12, 6, 0, 21, 14, 9, 5,
  20, 8, 19, 18
}

local Bitset = {}

-- Bitset:new(size: number[, value1: number, ...]): table
-- Bitset:new(bitset: table): table
-- 
-- Creates a new bitset. This functions similar to a table sequence of boolean
-- values, but is much more memory efficient and supports bitwise operations.
-- There are also fast operations to count the number of true bits, and iterate
-- through the true bits. Bits are indexed from 0 to bitset.size - 1.
-- 
-- If size is given, this must be a positive integer. If value1, value2, etc.
-- are provided to initialize the bitset, they must be provided with
-- most-significant value first and least-significant value last (think
-- big-endian). The values will also be truncated to 32 bits. If another bitset
-- object is provided, a copy is returned.
function Bitset:new(size, ...)
  self.__index = self
  self = setmetatable({}, self)
  
  if type(size) == "number" then
    assert(size > 0 and floor(size) == size, "bitset size must be positive integer.")
    self.size = size
    -- Stores the 32-bit "blocks" that make up the bitset.
    self.arr = {}
    -- Mask for the last block in the bitset.
    self.lastBlockMask = rshift(0xffffffff, 31 - (size - 1) % 32)
    
    -- If numeric values are provided to initialize, add each one to arr. Otherwise just fill with zero bits.
    local argc = select("#", ...)
    if argc > 0 then
      local varargs = {...}
      local arrIndex = 1
      for i = size, 33, -32 do
        self.arr[arrIndex] = band(varargs[argc - arrIndex + 1] or 0, 0xffffffff)
        arrIndex = arrIndex + 1
      end
      self.arr[arrIndex] = band(varargs[argc - arrIndex + 1] or 0, self.lastBlockMask)
    else
      self:clear()
    end
  elseif type(size) == "table" then
    self.size = size.size
    self.arr = {}
    for i, v in ipairs(size.arr) do
      self.arr[i] = v
    end
    self.lastBlockMask = size.lastBlockMask
  end
  
  return self
end

-- Bitset:test(pos: number): boolean
-- 
-- 
function Bitset:test(pos)
  return band(self.arr[floor(pos / 32) + 1], lshift(1, pos % 32)) ~= 0
end

-- Bitset:set(pos: number, value: boolean)
-- 
-- 
function Bitset:set(pos, value)
  local arrIndex = floor(pos / 32) + 1
  if value then
    self.arr[arrIndex] = bor(self.arr[arrIndex], lshift(1, pos % 32))
  else
    self.arr[arrIndex] = band(self.arr[arrIndex], bnot(lshift(1, pos % 32)))
  end
end

-- Bitset:clear(value: boolean)
-- 
-- 
function Bitset:clear(value)
  value = (value and 0xffffffff or 0)
  local arrIndex = 1
  for i = self.size, 33, -32 do
    self.arr[arrIndex] = value
    arrIndex = arrIndex + 1
  end
  self.arr[arrIndex] = band(value, self.lastBlockMask)
end

-- Bitset:count(): number
-- 
-- Counts up the number of bits that are set to true, and returns this amount.
-- 
-- Idea for the lookup table came from:
-- https://stackoverflow.com/questions/9949935/calculate-number-of-bits-set-in-byte
function Bitset:count()
  local count = 0
  local arrIndex = 1
  for i = self.size, 1, -32 do
    local block = self.arr[arrIndex]
    count = count + NIBBLE_BIT_COUNTS[band(block, 0xf)]
                  + NIBBLE_BIT_COUNTS[band(rshift(block,  4), 0xf)]
                  + NIBBLE_BIT_COUNTS[band(rshift(block,  8), 0xf)]
                  + NIBBLE_BIT_COUNTS[band(rshift(block, 12), 0xf)]
                  + NIBBLE_BIT_COUNTS[band(rshift(block, 16), 0xf)]
                  + NIBBLE_BIT_COUNTS[band(rshift(block, 20), 0xf)]
                  + NIBBLE_BIT_COUNTS[band(rshift(block, 24), 0xf)]
                  + NIBBLE_BIT_COUNTS[band(rshift(block, 28), 0xf)]
    arrIndex = arrIndex + 1
  end
  return count
end

-- Bitset:band(rhs: table): table
-- 
-- 
function Bitset:band(rhs)
  local resultArr = {}
  local arrIndex = 1
  for i = self.size, 1, -32 do
    resultArr[arrIndex] = band(self.arr[arrIndex], rhs.arr[arrIndex])
    arrIndex = arrIndex + 1
  end
  return setmetatable({size = self.size, arr = resultArr, lastBlockMask = self.lastBlockMask}, Bitset)
end

-- Bitset:bor(rhs: table): table
-- 
-- 
function Bitset:bor(rhs)
  local resultArr = {}
  local arrIndex = 1
  for i = self.size, 1, -32 do
    resultArr[arrIndex] = bor(self.arr[arrIndex], rhs.arr[arrIndex])
    arrIndex = arrIndex + 1
  end
  return setmetatable({size = self.size, arr = resultArr, lastBlockMask = self.lastBlockMask}, Bitset)
end

-- Bitset:bxor(rhs: table): table
-- 
-- 
function Bitset:bxor(rhs)
  local resultArr = {}
  local arrIndex = 1
  for i = self.size, 1, -32 do
    resultArr[arrIndex] = bxor(self.arr[arrIndex], rhs.arr[arrIndex])
    arrIndex = arrIndex + 1
  end
  return setmetatable({size = self.size, arr = resultArr, lastBlockMask = self.lastBlockMask}, Bitset)
end

-- Bitset:bnot(): table
-- 
-- 
function Bitset:bnot()
  local resultArr = {}
  local arrIndex = 1
  for i = self.size, 33, -32 do
    resultArr[arrIndex] = band(bnot(self.arr[arrIndex]), 0xffffffff)
    arrIndex = arrIndex + 1
  end
  resultArr[arrIndex] = band(bnot(self.arr[arrIndex]), self.lastBlockMask)
  return setmetatable({size = self.size, arr = resultArr, lastBlockMask = self.lastBlockMask}, Bitset)
end

-- Bitset:lshift(disp: number): table
-- 
-- 
function Bitset:lshift(disp)
  if disp < 0 then
    return self:rshift(-disp)
  end
  local resultArr = {}
  local arrIndexMax = floor((self.size - 1) / 32) + 1
  local srcIndex = -floor(disp / 32) + 1
  disp = disp % 32
  for arrIndex = 1, arrIndexMax do
    local a = (srcIndex > 0 and lshift(self.arr[srcIndex], disp) or 0)
    local b = (srcIndex - 1 > 0 and rshift(self.arr[srcIndex - 1], 32 - disp) or 0)
    resultArr[arrIndex] = band(bor(a, b), arrIndex ~= arrIndexMax and 0xffffffff or self.lastBlockMask)
    srcIndex = srcIndex + 1
  end
  return setmetatable({size = self.size, arr = resultArr, lastBlockMask = self.lastBlockMask}, Bitset)
end

-- Bitset:rshift(disp: number): table
-- 
-- 
function Bitset:rshift(disp)
  if disp < 0 then
    return self:lshift(-disp)
  end
  local resultArr = {}
  local arrIndexMax = floor((self.size - 1) / 32) + 1
  local srcIndex = floor(disp / 32) + 1
  disp = disp % 32
  for arrIndex = 1, arrIndexMax do
    local a = (srcIndex <= arrIndexMax and rshift(self.arr[srcIndex], disp) or 0)
    local b = (srcIndex + 1 <= arrIndexMax and lshift(self.arr[srcIndex + 1], 32 - disp) or 0)
    resultArr[arrIndex] = band(bor(a, b), arrIndex ~= arrIndexMax and 0xffffffff or self.lastBlockMask)
    srcIndex = srcIndex + 1
  end
  return setmetatable({size = self.size, arr = resultArr, lastBlockMask = self.lastBlockMask}, Bitset)
end

-- Bitset:equals(rhs: table): boolean
-- 
-- 
function Bitset:equals(rhs)
  local arrIndex = 1
  for i = self.size, 1, -32 do
    if self.arr[arrIndex] ~= rhs.arr[arrIndex] then
      return false
    end
    arrIndex = arrIndex + 1
  end
  return true
end
Bitset.__eq = Bitset.equals

-- Bitset:tostring(): string
-- 
-- 
function Bitset:tostring()
  local chunks, chunksSize = {}, 0
  local chunk = ""
  local pos = self.size - 1
  local arrIndex = floor(pos / 32) + 1
  while pos >= 0 do
    chunk = chunk .. (band(self.arr[arrIndex], lshift(1, pos % 32)) ~= 0 and "1" or "0")
    if pos % 32 == 0 then
      chunksSize = chunksSize + 1
      chunks[chunksSize] = chunk
      chunk = ""
      arrIndex = arrIndex - 1
    end
    pos = pos - 1
  end
  return table.concat(chunks, "", 1, chunksSize)
end
Bitset.__tostring = Bitset.tostring

--[[function Bitset:iterateSetBits()
  local pos = -1
  
  local function bitIter()
    pos = pos + 1
    while pos < self.size do
      if band(self.arr[floor(pos / 32) + 1], lshift(1, pos % 32)) ~= 0 then
        return pos
      end
      pos = pos + 1
    end
  end
  return bitIter
end--]]

--[[function Bitset:iterateSetBits()
  local arrIndex = 1
  local maxIndex = floor((self.size - 1) / 32) + 1
  local block = self.arr[arrIndex]
  
  local function bitIter()
    while arrIndex <= maxIndex do
      if block ~= 0 then
        local lsb = band(block, -block)
        local pos = MOD_37_BIT_POSITIONS[lsb % 37] + (arrIndex - 1) * 32
        block = bxor(block, lsb)
        return pos
      else
        arrIndex = arrIndex + 1
        block = self.arr[arrIndex]
      end
    end
  end
  return bitIter
end--]]

-- Bitset:iterateSetBits(): function
-- 
-- Returns a function (stateful iterator) to step through all of the bits that
-- are true. This can be considerably faster than iterating from 0 to
-- bitset.size - 1 when there are few bits set to true.
-- 
-- Uses techniques for counting consecutive trailing zero bits found here:
-- http://graphics.stanford.edu/~seander/bithacks.html
-- See also:
-- https://lemire.me/blog/2018/02/21/iterating-over-set-bits-quickly/
-- https://en.wikipedia.org/wiki/Find_first_set
function Bitset:iterateSetBits()
  local posOffset = 0
  local block = self.arr[1]
  
  local function bitIter()
    while posOffset < self.size do
      if block ~= 0 then
        -- Find the least-significant bit in the block, and determine its position with a lookup table.
        local lsb = band(block, -block)
        local pos = MOD_37_BIT_POSITIONS[lsb % 37] + posOffset
        block = bxor(block, lsb)
        return pos
      else
        -- Grab the next block in arr.
        posOffset = posOffset + 32
        block = self.arr[posOffset / 32 + 1]
      end
    end
  end
  return bitIter
end

return Bitset
