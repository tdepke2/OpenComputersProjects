local dstructs = require("dstructs")
local computer = require("computer")

local charArr = dstructs.CharArray:new(33, 4)
--local charArr = dstructs.CharArray:new(31, 4)

print("charArr.arr:")
for i, str in ipairs(charArr.arr) do
  print(i .. " = [" .. str .. "]")
end

print("clearing with char...")
charArr:clear("#")

print("charArr.arr:")
for i, str in ipairs(charArr.arr) do
  print(i .. " = [" .. str .. "]")
end

print("filling with chars...")
for i = 1, charArr.size do
  charArr:set(i, string.char(string.byte("a") - 1 + i))
end

print("charArr.arr:")
for i, str in ipairs(charArr.arr) do
  print(i .. " = [" .. str .. "]")
end

print("confirming chars...")
for i = 1, charArr.size do
  assert(charArr:get(i) == string.char(string.byte("a") - 1 + i))
end

print("substring 1, nil = [" .. charArr:sub(1) .. "]")
print("substring 2, nil = [" .. charArr:sub(2) .. "]")
print("substring 1, 0 = [" .. charArr:sub(1, 0) .. "]")
print("substring -1, -1 = [" .. charArr:sub(-1, -1) .. "]")
print("substring -2, -1 = [" .. charArr:sub(-2, -1) .. "]")
print("substring -3, -1 = [" .. charArr:sub(-3, -1) .. "]")
print("substring -4, -1 = [" .. charArr:sub(-4, -1) .. "]")

print("substring 1, 1 = [" .. charArr:sub(1, 1) .. "]")
print("substring 2, 2 = [" .. charArr:sub(2, 2) .. "]")
print("substring 3, 3 = [" .. charArr:sub(3, 3) .. "]")
print("substring 4, 4 = [" .. charArr:sub(4, 4) .. "]")
print("substring 5, 5 = [" .. charArr:sub(5, 5) .. "]")

print("substring 1, 4 = [" .. charArr:sub(1, 4) .. "]")
print("substring 2, 5 = [" .. charArr:sub(2, 5) .. "]")
print("substring 3, 6 = [" .. charArr:sub(3, 6) .. "]")
print("substring 4, 7 = [" .. charArr:sub(4, 7) .. "]")
print("substring 5, 8 = [" .. charArr:sub(5, 8) .. "]")
print()



local charArr2 = dstructs.CharArray:new(16)

print("charArr2.arr:")
for i, str in ipairs(charArr2.arr) do
  print(i .. " = [" .. str .. "]")
end

print("clearing with char...")
charArr2:clear(".")

print("charArr2.arr:")
for i, str in ipairs(charArr2.arr) do
  print(i .. " = [" .. str .. "]")
end

print("setting chars 1, 5, 16...")
charArr2:set(16, "c")
charArr2:set(1, "a")
charArr2:set(5, "b")

print("charArr2.arr:")
for i, str in ipairs(charArr2.arr) do
  print(i .. " = [" .. str .. "]")
end
print()



--local m1 = computer.freeMemory()
local byteArr = dstructs.ByteArray:new(33)
--local m2 = computer.freeMemory()
--print("mem", m1 - m2)

print("byteArr.arr:")
for i, b in ipairs(byteArr.arr) do
  print(i .. " = " .. string.format("0x%x", b))
end

--local t1 = os.clock()
print("clearing with byte...")
byteArr:clear(0xAB)

print("byteArr.arr:")
for i, b in ipairs(byteArr.arr) do
  print(i .. " = " .. string.format("0x%x", b))
end

print("filling with bytes...")
for i = 1, byteArr.size do
  byteArr:set(i, (i & 0xFF))
end

print("byteArr.arr:")
for i, b in ipairs(byteArr.arr) do
  print(i .. " = " .. string.format("0x%x", b))
end

print("confirming bytes...")
for i = 1, byteArr.size do
  assert(byteArr:get(i) == (i & 0xFF))
end
--local t2 = os.clock()
--print("took", t2 - t1)

print("setting bytes 1, 5, 16...")
byteArr:set(16, 0xCC)
byteArr:set(1, 0xAA)
byteArr:set(5, 0xBB)

print("byteArr.arr:")
for i, b in ipairs(byteArr.arr) do
  print(i .. " = " .. string.format("0x%x", b))
end
print()
