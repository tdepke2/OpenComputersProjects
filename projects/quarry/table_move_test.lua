local x1, x2 = {}, {}
for i = 1, 1000 do
  x1[i] = i
end

local rawset = rawset
local rawget = rawget
function table.move2(a1, f, e, t, a2)
  a2 = a2 or a1
  local delta = t - f
  if f < t then
    for i = e, f, -1 do
      rawset(a2, i + delta, rawget(a1, i))
    end
  else
    for i = f, e do
      rawset(a2, i + delta, rawget(a1, i))
    end
   end
  return a2
end

local function doTest(testName, f)
  local timeStart = os.clock()
  
  for i = 1, 10000 do
    table.move2(x1, 1, 1000, 1, x2)
    f(x2)
  end
  
  local timeEnd = os.clock()
  io.write(testName .. " took " .. timeEnd - timeStart .. "\n")
end

local function clear1(t)
  for i = 1, 1000 do
    t[i] = nil
  end
end

local function clear2(t)
  table.move2(x2, 1001, 2000, 1)
end

doTest("test1", clear1)
doTest("test2", clear2)