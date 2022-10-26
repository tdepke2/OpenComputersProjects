local include = require("include")
local bitset = include("bitset")

local b1 = bitset:new(1)
assert(b1:test(0) == false)
assert(b1:count() == 0)
b1:set(0)
assert(b1:test(0) == false)
assert(b1:count() == 0)
b1:set(0, true)
assert(b1:test(0) == true)
assert(b1:count() == 1)
b1:set(0, false)
assert(b1:test(0) == false)
assert(b1:count() == 0)
b1:clear(true)
assert(b1:test(0) == true)
assert(b1:count() == 1)
b1:clear(false)
assert(b1:test(0) == false)
assert(b1:count() == 0)

local b2 = bitset:new(8, 0x76)
local b3 = bitset:new(8, 0x93)
local b4 = bitset:new(8, -1)
local b5 = bitset:new(8, 0xff)

assert(b4 == b5)
assert(b2:band(b3):tostring() == "00010010")
assert(b2:bor(b3):tostring() == "11110111")
assert(b2:bxor(b3):tostring() == "11100101")
assert(b2:band(b3) == bitset:new(8, 0x12))
assert(b2:bor(b3) == bitset:new(8, 0xf7))
assert(b2:bxor(b3) == bitset:new(8, 0xe5))
assert(b2:band(b4) == b2)
assert(b2:bor(b4) == b4)
assert(b2 ~= b4)
assert(b2:bnot() == bitset:new(8, 0x89))
assert(b4:bnot() == bitset:new(8))
assert(b2:lshift(1) == bitset:new(8, 0xec))
assert(b3:lshift(1) == bitset:new(8, 0x26))
assert(b4:lshift(1) == bitset:new(8, 0xfe))
assert(b2:rshift(1) == bitset:new(8, 0x3b))
assert(b3:rshift(1) == bitset:new(8, 0x49))
assert(b4:rshift(1) == bitset:new(8, 0x7f))
assert(b2:lshift(-1) == b2:rshift(1))
assert(b3:lshift(-1) == b3:rshift(1))
assert(b4:lshift(-1) == b4:rshift(1))
assert(b2:rshift(-1) == b2:lshift(1))
assert(b3:rshift(-1) == b3:lshift(1))
assert(b4:rshift(-1) == b4:lshift(1))

local b6 = bitset:new(70, 0x01, 0x23456789, 0xabcdefed)

assert(b6:tostring() == "0000010010001101000101011001111000100110101011110011011110111111101101")
assert(b6:lshift(1)  == bitset:new(70, 0x02, 0x468acf13, 0x579bdfda))
assert(b6:lshift(32) == bitset:new(70, 0x09, 0xabcdefed, 0x00000000))
assert(b6:lshift(33) == bitset:new(70, 0x13, 0x579bdfda, 0x00000000))
assert(b6:lshift(66) == bitset:new(70, 0x34, 0x00000000, 0x00000000))
assert(b6:rshift(1)  == bitset:new(70, 0x00, 0x91a2b3c4, 0xd5e6f7f6))
assert(b6:rshift(32) == bitset:new(70,  0x1, 0x23456789))
assert(b6:rshift(33) == bitset:new(70, 0x91a2b3c4))
assert(b6:rshift(63) == bitset:new(70, 2))
assert(b6:rshift(66) == bitset:new(70, 0))
assert(b6:bxor(b6:lshift(5))        == bitset:new(70, 0x25, 0x4be996bc, 0xd270124d))
assert(b6:bxor(b6:lshift(5)):bnot() == bitset:new(70, 0x1a, 0xb4166943, 0x2d8fedb2))

local function testN(size)
  local arr = {}
  for i = 0, size - 1 do
    arr[i] = false
  end
  local b = bitset:new(size)
  
  -- Fill b and arr with random bits.
  for _ = 1, size do
    local index = math.random(0, size - 1)
    local value = math.random() < 0.5
    b:set(index, value)
    arr[index] = value
  end
  
  -- Test each bit, build string, count bits, etc.
  local arrBitCount = 0
  local arrString = ""
  local arrSetBits = {}
  for i = 0, size - 1 do
    assert(b:test(i) == arr[i])
    arrString = (arr[i] and "1" or "0") .. arrString
    arrBitCount = arrBitCount + (arr[i] and 1 or 0)
    if arr[i] then
      arrSetBits[#arrSetBits + 1] = i
    end
  end
  assert(arrBitCount == b:count())
  --print(b)
  assert(arrString == b:tostring())
  
  -- Confirm iteration order.
  local i = 1
  for j in b:iterateSetBits() do
    assert(arrSetBits[i] == j)
    i = i + 1
  end
  assert(arrSetBits[i] == nil)
  
  -- Clear b and confirm bits and count.
  b:clear(true)
  for i = 0, size - 1 do
    assert(b:test(i) == true)
  end
  assert(b:count() == size)
  
  -- Confirm iteration order again (for cleared bitset).
  local i = 0
  for j in b:iterateSetBits() do
    assert(i == j)
    i = i + 1
  end
  assert(i == size)
  
  --print(b)
end

local t1 = os.clock()
for i = 1, 140 do
  testN(i)
end
local t2 = os.clock()

print("tests passed")
print("elapsed:", t2 - t1)
