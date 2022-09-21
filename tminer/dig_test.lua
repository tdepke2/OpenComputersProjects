
local dstructs = {}

-- Priority queue using a binary heap.
dstructs.PriorityQueue = {}

local function heapify(arr, comp, length, i)
  local bestIndex = i
  local best = arr[i]
  
  if i * 2 <= length and comp(best, arr[i * 2]) then
    bestIndex = i * 2
    best = arr[bestIndex]
  end
  if i * 2 + 1 <= length and comp(best, arr[i * 2 + 1]) then
    bestIndex = i * 2 + 1
    best = arr[bestIndex]
  end
  if bestIndex ~= i then
    arr[bestIndex] = arr[i]
    arr[i] = best
    return heapify(arr, comp, length, bestIndex)
  end
end

--- dstructs.PriorityQueue:new([arr: table[, comp: function]]): table
-- Construction from an array takes O(n) time.
-- The comp is less-than by default (max heap).
function dstructs.PriorityQueue:new(arr, comp)
  self.__index = self
  self = setmetatable({}, self)
  
  self.comp = comp or function(a, b)
    return a < b
  end
  if arr == nil then
    self.arr = {}
    self.length = 0
  else
    self.arr = arr
    self.length = #arr
    for i = math.floor(self.length / 2), 1, -1 do
      heapify(self.arr, self.comp, self.length, i)
    end
  end
  
  return self
end

--- dstructs.PriorityQueue:empty(): boolean
function dstructs.PriorityQueue:empty()
  return self.length == 0
end

--- dstructs.PriorityQueue:size(): number
function dstructs.PriorityQueue:size()
  return self.length
end

--- dstructs.PriorityQueue:top(): any
function dstructs.PriorityQueue:top()
  return self.arr[1]
end

--- dstructs.PriorityQueue:push(val: any)
-- Uses heapify-up. Time complexity is O(log n)
function dstructs.PriorityQueue:push(val)
  self.length = self.length + 1
  self.arr[self.length] = val
  
  local i = self.length
  local parent = math.floor(i / 2)
  while i > 1 and self.comp(self.arr[parent], self.arr[i]) do
    self.arr[i], self.arr[parent] = self.arr[parent], self.arr[i]
    i = parent
    parent = math.floor(i / 2)
  end
end

--- dstructs.PriorityQueue:pop(): any
-- Uses heapify-down. Time complexity is O(log n)
function dstructs.PriorityQueue:pop()
  local topElement = self.arr[1]
  self.arr[1] = self.arr[self.length]
  self.arr[self.length] = nil
  self.length = self.length - 1
  
  heapify(self.arr, self.comp, self.length, 1)
  return topElement
end


local reprioritizeCounter = 0
local reprioritizeCounterFalse = 0
local reprioritizeCounterAvgIndex = 0


--- dstructs.PriorityQueue:updateKey(oldVal: any, newVal: any[, compResult: boolean]): boolean
-- Time complexity is O(n)
function dstructs.PriorityQueue:updateKey(oldVal, newVal, compResult)
  reprioritizeCounter = reprioritizeCounter + 1
  compResult = compResult or self.comp(oldVal, newVal)
  local i = 1
  while i <= self.length and self.arr[i] ~= oldVal do
    i = i + 1
  end
  reprioritizeCounterAvgIndex = reprioritizeCounterAvgIndex + i
  if i > self.length then
    print("updateKey() false")
    reprioritizeCounterFalse = reprioritizeCounterFalse + 1
    return false
  end
  
  self.arr[i] = newVal
  if compResult then
    --print("updateKey() heap-up")
    local parent = math.floor(i / 2)
    while i > 1 and self.comp(self.arr[parent], self.arr[i]) do
      self.arr[i], self.arr[parent] = self.arr[parent], self.arr[i]
      i = parent
      parent = math.floor(i / 2)
    end
  else
    --print("updateKey() heap-down")
    heapify(self.arr, self.comp, self.length, i)
  end
  return true
end

--[[
local function checkQueue(q, arr)
  table.sort(arr)--, function(a, b) return a > b end)
  local minIndex, maxIndex = math.huge, 0
  for k, v in pairs(q.arr) do
    minIndex = math.min(minIndex, k)
    maxIndex = math.max(maxIndex, k)
  end
  assert(#arr == maxIndex and (maxIndex == 0 or minIndex == 1))
  assert(q:size() == maxIndex)
  assert(q:top() == arr[maxIndex])
  print("size = " .. q:size() .. ", top = " .. tostring(q:top()))
end

local arr = {}
local arrCopy = {}
for i = 1, 70 do
  local num = math.random() * 200 - 100
  arr[i] = num
  arrCopy[i] = num
end
local q = dstructs.PriorityQueue:new(arrCopy)--, function(a, b) return a > b end)
checkQueue(q, arr)
for i = 1, 100 do
  local chance = math.random()
  if chance < 0.33 and not q:empty() then
    q:pop()
    arr[#arr] = nil
    checkQueue(q, arr)
  elseif chance < 0.66 and not q:empty() then
    local num = math.random() * 200 - 100
    local index = math.random(1, #arr)
    assert(q:updateKey(arr[index], num))
    arr[index] = num
    checkQueue(q, arr)
  else
    local num = math.random() * 200 - 100
    q:push(num)
    arr[#arr + 1] = num
    checkQueue(q, arr)
  end
end
print("emptying queue...")
while not q:empty() do
  q:pop()
  arr[#arr] = nil
  checkQueue(q, arr)
end
os.exit()
--]]


--[[
-- priority queue using sort(), we get different results when priority values are changed!!
dstructs.PriorityQueue2 = {}
function dstructs.PriorityQueue2:new(arr, comp)
  self.__index = self
  self = setmetatable({}, self)
  
  self.comp = comp or function(a, b)
    return a < b
  end
  self.arr = {}
  self.length = 0
  if arr ~= nil then
    for i, v in ipairs(arr) do
      self:push(v)
    end
  end
  
  return self
end
function dstructs.PriorityQueue2:empty()
  return self.length == 0
end
function dstructs.PriorityQueue2:size()
  return self.length
end
function dstructs.PriorityQueue2:push(val)
  self.length = self.length + 1
  self.arr[self.length] = val
end
function dstructs.PriorityQueue2:pop()
  table.sort(self.arr, self.comp)
  local topElement = self.arr[self.length]
  self.arr[self.length] = nil
  self.length = self.length - 1
  
  return topElement
end
--]]

local checkNeighborCounter = 0

local function findPath(grid, paths, pathChar, start, stop, heuristicBias)
  local function heuristicFunc(node)
    local x1 = (node - 1) % grid.xMax + 1
    local y1 = math.floor((node - 1) / grid.xMax) + 1
    
    local x2 = (stop - 1) % grid.xMax + 1
    local y2 = math.floor((stop - 1) / grid.xMax) + 1
    
    return (math.abs(x1 - x2) + math.abs(y1 - y2)) * heuristicBias
  end
  
  local cameFrom = {}
  local gScore = setmetatable({[start] = 0}, {
    __index = function()
      return math.huge
    end
  })
  local fScore = setmetatable({[start] = 0--[[could also use: heuristicFunc(start)]]}, {
    __index = function()
      return math.huge
    end
  })
  
  local function reconstructPath()
    local node = stop
    while node do
      local x = (node - 1) % grid.xMax + 1
      local y = math.floor((node - 1) / grid.xMax) + 1
      --print("(" .. x .. ", " .. y .. ")")
      assert(grid[node] >= 0 and grid[node] < 10 and not paths[node])
      paths[node] = pathChar
      node = cameFrom[node]
    end
    print("gScore[stop] = " .. gScore[stop])
    print("fScore[stop] = " .. fScore[stop])
    assert(paths[start] == pathChar and paths[stop] == pathChar)
    paths[start] = "A"
    paths[stop] = "B"
    print()
    return true
  end
  
  local fringeNodes = dstructs.PriorityQueue:new({start}, function(a, b) return fScore[a] > fScore[b] end)
  --local fringeSet = {[start] = true}
  
  local function checkNeighbor(current, x, y, baseMovementCost)
    checkNeighborCounter = checkNeighborCounter + 1
    if x < 1 or x > grid.xMax or y < 1 or y > grid.yMax then
      return
    end
    local neighbor = (y - 1) * grid.xMax + x
    if grid[neighbor] == 100 then
      return
    end
    local oldGScore = gScore[neighbor]
    local newGScore = gScore[current] + baseMovementCost + grid[neighbor]
    --io.write("checkNeighbor(" .. current .. ", " .. x .. ", " .. y .. "), newGScore = " .. newGScore .. ", oldGScore = " .. gScore[neighbor])
    if newGScore < oldGScore then
      --io.write(" (greater)\n")
      if oldGScore ~= math.huge then
        --io.write("score was increased for existing node!\n")
      end
      cameFrom[neighbor] = current
      gScore[neighbor] = newGScore
      fScore[neighbor] = newGScore + heuristicFunc(neighbor)
      -- The neighbor is added to fringe if it hasn't been found before, or it has and is not currently in the fringe.
      -- Another way to do this is to always add it (allow duplicates), but this doesn't work so well when we store the priorities outside of the queue (the heap can get invalidated).
      if oldGScore == math.huge or not fringeNodes:updateKey(neighbor, neighbor, true) then
        fringeNodes:push(neighbor)
      end
      --[[if fringeSet[neighbor] then
        fringeNodes:updateKey(neighbor, neighbor, true)
      else
        fringeNodes:push(neighbor)
        fringeSet[neighbor] = true
      end--]]
    else
      --io.write(" (less)\n")
    end
  end
  
  while not fringeNodes:empty() do
    -- debug to confirm min value in queue
    local minNode = nil
    local minValue = math.huge
    for i, v in ipairs(fringeNodes.arr) do
      if fScore[v] < minValue then
        minNode = v
        minValue = fScore[v]
      end
    end
    
    
    local current = fringeNodes:pop()
    --fringeSet[current] = nil
    assert(minValue == fScore[current], "minNode = " .. minNode .. ", current = " .. current)
    if current == stop then
      return reconstructPath()
    end
    local x = (current - 1) % grid.xMax + 1
    local y = math.floor((current - 1) / grid.xMax) + 1
    --io.write("current = " .. current .. ", (" .. x .. ", " .. y .. ")\n")
    
    -- Prefer straight line paths by adding a small cost when turning.
    local xMovementCost, yMovementCost
    if cameFrom[current] and math.abs(current - cameFrom[current]) == 1 then
      xMovementCost = 1
      yMovementCost = 1.001
    else
      xMovementCost = 1.001
      yMovementCost = 1
    end
    
    checkNeighbor(current, x, y + 1, yMovementCost)
    checkNeighbor(current, x + 1, y, xMovementCost)
    checkNeighbor(current, x, y - 1, yMovementCost)
    checkNeighbor(current, x - 1, y, xMovementCost)
  end
  
  paths[start] = "A"
  paths[stop] = "B"
  print("no path!\n")
  return false
end

local function printGrid(grid, paths)
  io.write("grid.xMax = ", tostring(grid.xMax), ", grid.yMax = ", tostring(grid.yMax), "\n")
  local i = 1
  for y = 1, grid.yMax do
    for x = 1, grid.xMax do
      if grid[i] == 100 then
        io.write("██")
      else
        io.write(tostring(grid[i]))
        io.write(paths[i] or " ")
      end
      i = i + 1
    end
    io.write("\n")
  end
  io.write("\n")
end

--[=[
local grid = {}
grid.xMax = 10--40--9
grid.yMax = 10--40--12
local paths = {}

--math.randomseed(10)
math.randomseed(436758)
for i = 1, grid.xMax * grid.yMax do
  local num = math.random()
  grid[i] = num < 0.0 and 100 or math.floor((num - 0.0) * 10)
end

--[[
findPath(grid, paths, "#", 1, grid.xMax * grid.yMax, 1)--1.1)
reprioritizeCounterAvgIndex = reprioritizeCounterAvgIndex / reprioritizeCounter
print("reprioritizeCounter = " .. reprioritizeCounter .. ", reprioritizeCounterFalse = " .. reprioritizeCounterFalse .. ", reprioritizeCounterAvgIndex = " .. reprioritizeCounterAvgIndex)
print("checkNeighborCounter = " .. checkNeighborCounter .. "\n")
printGrid(grid, paths)
--]]

local pos = 1
while true do
  local i = 1
  while i <= grid.xMax * grid.yMax and grid[i] ~= 3 do
    i = i + 1
  end
  if i > grid.xMax * grid.yMax then
    break
  end
  local paths = {}
  local result = findPath(grid, paths, "#", pos, i, 1)
  printGrid(grid, paths)
  if not result then
    break
  end
  
  for j = 1, grid.xMax * grid.yMax do
    if paths[j] then
      grid[j] = 0
    end
  end
  pos = i
end
--]=]

-- https://www.redblobgames.com/pathfinding/a-star/implementation.html
-- https://www.geeksforgeeks.org/a-search-algorithm/
-- https://en.wikipedia.org/wiki/A*_search_algorithm
-- https://en.wikipedia.org/wiki/Travelling_salesman_problem
-- see "ant colony" optimization of tsp
-- probably a good idea to ditch the grid layout for TSP solver, and use a fast method to approximate path costs between nodes (such as straight line paths to goal, and sum the hardness values along path, use DP to cache?)

local rand = {}

--- rand.discreteDistribution(weights: table[, n: number]): function
-- 
-- Uses Vose's Alias Method, see https://www.keithschwarz.com/darts-dice-coins/
-- See also paper "A Linear Algorithm For Generating Random Numbers With a Given Distribution" by Michael Vose
function rand.discreteDistribution(weights, n)
  n = n or #weights
  local weightSum = 0
  for i = 1, n do
    weightSum = weightSum + weights[i]
  end
  
  local weightAverage = weightSum / n
  local alias, prob = {}, {}
  local smallStack, largeStack, smallStackSize, largeStackSize = {}, {}, 0, 0
  
  -- Add each weight to small or large stack depending on the weightAverage threshold.
  for i = 1, n do
    if weights[i] < weightAverage then
      smallStackSize = smallStackSize + 1
      smallStack[smallStackSize] = i
    else
      largeStackSize = largeStackSize + 1
      largeStack[largeStackSize] = i
    end
  end
  
  local modifiedWeights = setmetatable({}, {
    __index = weights
  })
  
  -- While neither stack is empty, add a small weight and a fraction of a large weight to fill a bucket in prob corresponding to the small weight.
  -- The large weight gets reduced by this fraction and added to alias so we track where it came from.
  while smallStackSize > 0 and largeStackSize > 0 do
    local topSmall = smallStack[smallStackSize]
    smallStackSize = smallStackSize - 1
    local topLarge = largeStack[largeStackSize]
    largeStackSize = largeStackSize - 1
    
    -- Scale the weight and track the alias (if the weights sum to 1, a value of 1/n becomes 1).
    prob[topSmall] = modifiedWeights[topSmall] / weightSum * n
    alias[topSmall] = topLarge
    
    -- Part of the topLarge weight has gone in the bucket. Reduce it by the amount lost and check if it's now a small weight.
    modifiedWeights[topLarge] = (modifiedWeights[topLarge] + modifiedWeights[topSmall]) - weightAverage
    if modifiedWeights[topLarge] < weightAverage then
      smallStackSize = smallStackSize + 1
      smallStack[smallStackSize] = topLarge
    else
      largeStackSize = largeStackSize + 1
      largeStack[largeStackSize] = topLarge
    end
  end
  
  -- The remaining weights should all have a probability of 1, add them appropriately.
  while largeStackSize > 0 do
    prob[largeStack[largeStackSize]] = 1
    largeStackSize = largeStackSize - 1
  end
  while smallStackSize > 0 do
    prob[smallStack[smallStackSize]] = 1
    smallStackSize = smallStackSize - 1
  end
  
  --print("prob, alias:")
  --for i, v in ipairs(prob) do
    --print(i, v, "\t", alias[i])
  --end
  
  -- When called with a random number generator such as math.random(), returns index of one of the original weights.
  return function(randFunc)
    local i = randFunc(1, n)
    return randFunc() < prob[i] and i or alias[i]
  end
end

local timerDat = {}
local timerStr = {}
local function timer(str)
  timerDat[#timerDat + 1] = os.clock()
  timerStr[#timerStr + 1] = str
end
local function showTimer()
  for i = 1, #timerDat do
    print(timerStr[i], "\t", timerDat[i] - timerDat[1], i > 1 and "(delta " .. timerDat[i] - timerDat[i - 1] .. ")" or "")
  end
end

--[[
local weights = {40, 10, 10, 40}--{1/8, 1/5, 1/10, 1/4, 1/10, 1/10, 1/8}
local weightsCopy = {}
print("weights:")
for i, v in ipairs(weights) do
  print(i, v)
  weightsCopy[i] = v
end

local d = rand.discreteDistribution(weights)
local numTrials = 1000000
local results = setmetatable({}, {
  __index = function()
    return 0
  end
})
local numWeights = #weights
for _ = 1, numTrials do
  local k = d(math.random)
  assert(k >= 1 and k <= numWeights)
  results[k] = results[k] + 1
end
setmetatable(results, nil)
print("results:")
for i, v in ipairs(results) do
  print(i, v, "\t", "~" .. v / numTrials)
end

for k, v in pairs(weightsCopy) do
  assert(weights[k] == v)
end

os.exit()
--]]

--[[ WI29 - Western Sahara, length 27603
local tspPoints = {
  {20833.3333, 17100.0000},
  {20900.0000, 17066.6667},
  {21300.0000, 13016.6667},
  {21600.0000, 14150.0000},
  {21600.0000, 14966.6667},
  {21600.0000, 16500.0000},
  {22183.3333, 13133.3333},
  {22583.3333, 14300.0000},
  {22683.3333, 12716.6667},
  {23616.6667, 15866.6667},
  {23700.0000, 15933.3333},
  {23883.3333, 14533.3333},
  {24166.6667, 13250.0000},
  {25149.1667, 12365.8333},
  {26133.3333, 14500.0000},
  {26150.0000, 10550.0000},
  {26283.3333, 12766.6667},
  {26433.3333, 13433.3333},
  {26550.0000, 13850.0000},
  {26733.3333, 11683.3333},
  {27026.1111, 13051.9444},
  {27096.1111, 13415.8333},
  {27153.6111, 13203.3333},
  {27166.6667, 9833.3333},
  {27233.3333, 10450.0000},
  {27233.3333, 11783.3333},
  {27266.6667, 10383.3333},
  {27433.3333, 12400.0000},
  {27462.5000, 12992.2222},
}--]]
--[ Oliver30, length 423.741
-- https://stevedower.id.au/research/oliver-30
local tspPoints = {
  {54, 67},
  {54, 62},
  {37, 84},
  {41, 94},
  { 2, 99},
  { 7, 64},
  {25, 62},
  {22, 60},
  {18, 54},
  { 4, 50},
  {13, 40},
  {18, 40},
  {24, 42},
  {25, 38},
  {44, 35},
  {41, 26},
  {45, 21},
  {58, 35},
  {62, 32},
  {82,  7},
  {91, 38},
  {83, 46},
  {71, 44},
  {64, 60},
  {68, 58},
  {83, 69},
  {87, 76},
  {74, 78},
  {71, 71},
  {58, 69},
}--]]
--[[
local tspPoints = {
  {1, 1},
  {3, 4},
  {6, 7},
  {5, 4},
}--]]

-- Draw a line between two points on the grid. Uses Bresenham line algorithm.
-- From: https://en.wikipedia.org/wiki/Bresenham%27s_line_algorithm
local function drawLine(grid, gridSize, x0, y0, x1, y1)
  local dx, sx = math.abs(x1 - x0), x0 < x1 and 1 or -1
  local dy, sy = -math.abs(y1 - y0), y0 < y1 and 1 or -1
  local err = dx + dy
  
  while true do
    grid[(y0 - 1) * gridSize + x0] = 100
    if x0 == x1 and y0 == y1 then
      break
    end
    local err2 = 2 * err
    if err2 >= dy then
      if x0 == x1 then break end
      err = err + dy
      x0 = x0 + sx
    end
    if err2 <= dx then
      if y0 == y1 then break end
      err = err + dx
      y0 = y0 + sy
    end
  end
end

-- Draws a square grid containing the points in the TSP problem. The points are scaled to fit within the grid.
-- If given bestTour, draws these as lines on the grid.
local function printTSP(gridSize, tspPoints, bestTour)
  local xMin, xMax = math.huge, -math.huge
  local yMin, yMax = math.huge, -math.huge
  for i, point in ipairs(tspPoints) do
    xMin = math.min(xMin, point[1])
    xMax = math.max(xMax, point[1])
    yMin = math.min(yMin, point[2])
    yMax = math.max(yMax, point[2])
  end
  local scaling = math.max(xMax - xMin, yMax - yMin)
  
  local function pointToGridCoords(point)
    local x = math.floor((point[1] - xMin) / scaling * (gridSize - 1) + 0.5) + 1
    local y = gridSize - math.floor((point[2] - yMin) / scaling * (gridSize - 1) + 0.5)
    return x, y
  end
  
  local grid = {}
  
  if bestTour then
    local x0, y0 = pointToGridCoords(tspPoints[bestTour[#bestTour]])
    for i, v in ipairs(bestTour) do
      local x1, y1 = pointToGridCoords(tspPoints[v])
      drawLine(grid, gridSize, x0, y0, x1, y1)
      x0 = x1
      y0 = y1
    end
  end
  
  for i, point in ipairs(tspPoints) do
    local x, y = pointToGridCoords(point)
    --print(x, y)
    grid[(y - 1) * gridSize + x] = i
  end
  
  io.write("gridSize = " .. gridSize .. ", numPoints = " .. #tspPoints .. "\n")
  local i = 1
  for y = 1, gridSize do
    for x = 1, gridSize do
      io.write(grid[i] and (grid[i] == 100 and " ▄" or string.format("%2d", grid[i])) or " .")
      i = i + 1
    end
    io.write("\n")
  end
  io.write("\n")
end

-- estimatePathLength(tspPointsSize: number, findDistance: function): number
-- 
-- Calculates a rough estimate for the optimal tour length in TSP. This uses the nearest-neighbor approach, time complexity is O(n^2).
-- The findDistance function takes two points (as indices) and returns the distance between them.
local function estimatePathLength(tspPointsSize, findDistance)
  local pathLength = 0
  local current = 1
  local unvisited, unvisitedSize = {}, tspPointsSize - 1
  for i = 1, unvisitedSize do
    unvisited[i] = i + 1
  end
  
  -- Repeatedly find the next node with the shortest distance, and move to it.
  while unvisitedSize > 0 do
    local minDistance, minIndex = math.huge, 1
    for i = 1, unvisitedSize do
      local d = findDistance(current, unvisited[i])
      if d < minDistance then
        minDistance = d
        minIndex = i
      end
    end
    current = unvisited[minIndex]
    pathLength = pathLength + minDistance
    unvisited[minIndex] = unvisited[unvisitedSize]
    unvisited[unvisitedSize] = nil
    unvisitedSize = unvisitedSize - 1
  end
  if current ~= 1 then
    pathLength = pathLength + findDistance(current, 1)
  end
  print("NN gave ", pathLength)
  return pathLength
end

-- FIXME we can remove the silly asserts ###############

-- Initialization step for solveTourACS().
local function initACS(tspPoints, tspPointsSize, candidateListSize)
  -- Computes an array index corresponding to the top-right triangular region of a matrix.
  -- The diagonal of the matrix is excluded (so a must not equal b).
  -- This implementation assumes the matrix is symmetrical across the diagonal (as in the case of a distance matrix for nodes in TSP), and sorts the a and b arguments.
  -- https://jamesmccaffrey.wordpress.com/2010/05/14/converting-a-triangular-matrix-to-an-array/
  local function triangularMatrixIndex(a, b)
    if a > b then
      a, b = b, a
    end
    assert(a ~= b)
    return tspPointsSize * (a - 1) - a * (a + 1) / 2 + b
  end
  local triangularMatrixSize = tspPointsSize * (tspPointsSize - 1) / 2
  
  -- Pre-compute the top-right triangular matrix of distance comparisons.
  local distanceMat = {}
  local distanceAverage = 0
  local i = 1
  for a = 1, tspPointsSize - 1 do
    for b = a + 1, tspPointsSize do
      distanceMat[i] = math.sqrt((tspPoints[a][1] - tspPoints[b][1]) ^ 2 + (tspPoints[a][2] - tspPoints[b][2]) ^ 2)
      distanceAverage = distanceAverage + distanceMat[i]
      i = i + 1
    end
  end
  distanceAverage = distanceAverage / triangularMatrixSize
  
  -- Compute a candidate list. This stores the top n closest cities for each city.
  -- A heap is used to build this list in O(n^2) time.
  local candidateList = {}
  for i = 1, tspPointsSize do
    local neighbors = {}
    for j = 1, tspPointsSize - 1 do
      neighbors[j] = j
    end
    if i ~= tspPointsSize then
      neighbors[i] = tspPointsSize
    end
    
    local candidates = {}
    candidateList[i] = candidates
    local candidateQueue = dstructs.PriorityQueue:new(neighbors, function(a, b)
      return distanceMat[triangularMatrixIndex(a, i)] > distanceMat[triangularMatrixIndex(b, i)]
    end)
    --io.write("" .. i .. ": ")
    for j = 1, candidateListSize do
      candidates[j] = candidateQueue:pop()
      --io.write(candidates[j] .. " ")
    end
    --io.write("\n")
  end
  
  -- Estimate the solution with nearest-neighbor algorithm, and initialize pheromone constants.
  local function findDistance(a, b)
    return distanceMat[triangularMatrixIndex(a, b)]
  end
  local lengthNN = estimatePathLength(tspPointsSize, findDistance)
  local basePheromone = 1 / (tspPointsSize * lengthNN)
  local maxPheromone = tspPointsSize / lengthNN
  local minPheromone = 1 / (distanceAverage * tspPointsSize ^ 2)
  
  print("distanceAverage = ", distanceAverage)
  print("basePheromone = ", basePheromone)
  print("maxPheromone = ", maxPheromone, ", minPheromone = ", minPheromone)
  
  -- Initialize top-right triangular matrix of pheromone levels. By starting with maxPheromone, we encourage more exploration at beginning of simulation.
  local pheromoneMat = {}
  for i = 1, triangularMatrixSize do
    pheromoneMat[i] = maxPheromone
  end
  
  assert(#distanceMat == triangularMatrixSize)
  assert(#pheromoneMat == triangularMatrixSize)
  
  return distanceMat, pheromoneMat, triangularMatrixIndex, triangularMatrixSize, basePheromone, maxPheromone, minPheromone, candidateList
end

-- solveTourACS(tspPoints: table[, tspPointsSize: number]): number, table
-- 
-- Finds an estimate to the optimal TSP tour using ACS-MMAS hybrid method. The
-- tspPoints is a sequence of 3D Cartesian coordinates (each one a table with x,
-- y, and z in indices 1, 2, and 3 respectively) corresponding to the positions
-- of cities. Returns the length of the found tour (Hamiltonian cycle), and a
-- table sequence that stores the tour as indices of elements in tspPoints. This
-- resulting tour visits every city once and minimizes the Euclidean distance
-- along the path. The resulting tour is not guaranteed to be optimal, however
-- the solution will converge to the optimal tour based on the number of
-- iterations run and random chance.
-- 
-- In a nutshell, ACS works by creating virtual ants to explore the graph of
-- cities and find a complete tour. Ants check pheromone levels at each edge and
-- the length of the edge to determine the next city to move to. The ant that
-- finds the shortest tour is allowed to deposit pheromone along the edges in
-- that tour (so that more ants choose that edge). In MMAS, we bound the
-- pheromone levels to prevent stagnation of exploration due to extremely
-- low/high pheromone levels.
-- 
-- See the following research papers for details.
-- Ant Colony System: A Cooperative Learning Approach To The Traveling Salesman
-- Problem
--   https://people.idsia.ch/~luca/acs-ec97.pdf
-- Improvements on the Ant-System: Introducing the MAX-MIN Ant System
--   https://link.springer.com/chapter/10.1007/978-3-7091-6492-1_54
local function solveTourACS(tspPoints, tspPointsSize)
  timer("solveTourACS()")
  tspPointsSize = tspPointsSize or #tspPoints
  
  -- Constant parameters for ACS.
  local distanceExponent = -2
  local pheromoneDecay = 0.1
  local exploitationChance = 0.8
  local candidateListSize = math.min(15, tspPointsSize - 1)
  
  if tspPointsSize <= 1 then
    return 0, {1}
  end
  
  local distanceMat, pheromoneMat, triangularMatrixIndex, triangularMatrixSize, basePheromone, maxPheromone, minPheromone, candidateList = initACS(tspPoints, tspPointsSize, candidateListSize)
  timer("init ends")
  
  local globalBestLength = math.huge
  local globalBestTour = {}
  local invPheromoneDecay = 1 - pheromoneDecay
  local basePheromoneDecayed = pheromoneDecay * basePheromone
  
  -- Begin iterations of the simulation.
  -- The number of iterations is scaled down as the total cities increases. This helps performance by sacrificing the quality of the solution.
  -- In the OpenComputers configs, the "timeout" parameter controls the max number of seconds a chunk of non-blocking code can run for.
  -- The default value is 5, so we target about a maximum of 2.5 seconds for the simulation here to avoid a crash.
  -- With 32 cities, numIterations = 400 (average about 2.61s).
  -- With 64 cities, numIterations = 200 (average about 2.68s).
  -- With 128 cities, numIterations = 100 (average about 2.88s).
  local numIterations = math.max(math.min(math.floor(400 * 32 / tspPointsSize), 400), 100)
  print("numIterations = ", numIterations)
  
  for iteration = 1, numIterations do
    -- Each ant starts at a random city such that there is at most one ant in every city. If there are more ants than cities, the remaining ants are assigned randomly.
    local startPositions, startPositionsSize = {}, tspPointsSize
    for i = 1, tspPointsSize do
      startPositions[i] = i
    end
    
    for ant = 1, 10 do
      -- Initialize starting point, and track visited/unvisited points. The unvisited points represent the remaining places the ant could move to.
      local pathLength = 0
      local start
      if startPositionsSize > 0 then
        local i = math.random(1, startPositionsSize)
        start = startPositions[i]
        startPositions[i] = startPositions[startPositionsSize]
        startPositions[startPositionsSize] = nil
        startPositionsSize = startPositionsSize - 1
      else
        start = math.random(1, tspPointsSize)
      end
      
      local visited, visitedSize = {start}, 1
      local unvisited = {}
      for i = 1, tspPointsSize do
        unvisited[i] = i
      end
      unvisited[start] = nil
      
      -- For each of the remaining cities, choose which one to move to next based on ACS state transition rule and move there.
      local current = start
      for _ = 1, tspPointsSize - 1 do
        local target
        local candidates = candidateList[current]
        if math.random() < exploitationChance then
          -- Find the best edge with the largest pheromone-closeness product (exploitation). Search the candidate list first.
          local bestPcp = -math.huge
          for _, city in ipairs(candidates) do
            if unvisited[city] then
              local tmi = triangularMatrixIndex(current, city)
              local pcp = pheromoneMat[tmi] * distanceMat[tmi] ^ distanceExponent
              if pcp > bestPcp then
                bestPcp = pcp
                target = city
              end
            end
          end
          if not target then
            -- No options in candidate list, search all of the unvisited cities.
            for city in pairs(unvisited) do
              local tmi = triangularMatrixIndex(current, city)
              local pcp = pheromoneMat[tmi] * distanceMat[tmi] ^ distanceExponent
              if pcp > bestPcp then
                bestPcp = pcp
                target = city
              end
            end
          end
        else
          -- Pick an edge by sampling from a non-uniform discrete distribution. Search the candidate list first.
          local weights, weightCities, weightsSize = {}, {}, 0
          for _, city in ipairs(candidates) do
            if unvisited[city] then
              local tmi = triangularMatrixIndex(current, city)
              weightsSize = weightsSize + 1
              weights[weightsSize] = pheromoneMat[tmi] * distanceMat[tmi] ^ distanceExponent
              weightCities[weightsSize] = city
            end
          end
          if weightsSize == 0 then
            -- No options in candidate list, search all of the unvisited cities.
            for city in pairs(unvisited) do
              local tmi = triangularMatrixIndex(current, city)
              weightsSize = weightsSize + 1
              weights[weightsSize] = pheromoneMat[tmi] * distanceMat[tmi] ^ distanceExponent
              weightCities[weightsSize] = city
            end
          end
          target = weightCities[rand.discreteDistribution(weights, weightsSize)(math.random)]
        end
        
        -- Add the chosen city to visited, and apply ACS local updating rule to decay the pheromone levels on the corresponding edge to the chosen city.
        visitedSize = visitedSize + 1
        visited[visitedSize] = target
        local tmi = triangularMatrixIndex(current, target)
        pathLength = pathLength + distanceMat[tmi]
        pheromoneMat[tmi] = pheromoneMat[tmi] * invPheromoneDecay + basePheromoneDecayed
        
        current = target
        unvisited[target] = nil
      end
      -- Apply ACS local updating rule for edge back to the start.
      local tmi = triangularMatrixIndex(current, start)
      pathLength = pathLength + distanceMat[tmi]
      pheromoneMat[tmi] = pheromoneMat[tmi] * invPheromoneDecay + basePheromoneDecayed
      
      --[[
      for i, v in ipairs(visited) do
        io.write(tostring(v) .. " ")
      end
      print("-> " .. pathLength)
      --]]
      if pathLength < globalBestLength then
        globalBestLength = pathLength
        globalBestTour = visited
      end
    end
    
    -- After each ant has finished a tour, apply ACS global updating rule. All pheromone decays, and pheromone levels that are part of the global best tour are increased.
    -- The pheromone levels are also loosely bounded by a min and max amount to prevent limits on path exploration (as per MMAS).
    for i = 1, triangularMatrixSize do
      local newPheromone = pheromoneMat[i] * invPheromoneDecay
      if newPheromone < minPheromone then
        newPheromone = minPheromone
      elseif newPheromone > maxPheromone then
        newPheromone = maxPheromone
      end
      pheromoneMat[i] = newPheromone
    end
    --print("best edges visited:")
    local globalBestPheromone = pheromoneDecay / globalBestLength
    for i = 1, tspPointsSize do
      --print(globalBestTour[i], globalBestTour[i % tspPointsSize + 1])
      local tmi = triangularMatrixIndex(globalBestTour[i], globalBestTour[i % tspPointsSize + 1])
      pheromoneMat[tmi] = pheromoneMat[tmi] + globalBestPheromone
    end
  end
  
  --[[
  print("ending pheromone levels:")
  for a = 1, tspPointsSize - 1 do
    for b = a + 1, tspPointsSize do
      print(a, b, " -> ", pheromoneMat[triangularMatrixIndex(a, b)])
    end
  end
  --]]
  timer("solveTourACS() ends")
  return globalBestLength, globalBestTour
end

-- Re-orders the nodes in a TSP tour to put the first one at the first index and the next smallest at the second index.
local function normalizeTour(pathLength, tour)
  local tourSize = #tour
  local normalizedTour = {}
  local tourIndex = 1
  while tourIndex <= tourSize and tour[tourIndex] ~= 1 do
    tourIndex = tourIndex + 1
  end
  local deltaIndex = (tour[tourIndex % tourSize + 1] < tour[(tourIndex - 2) % tourSize + 1] and 1 or -1)
  for i = 1, tourSize do
    normalizedTour[i] = tour[tourIndex]
    tourIndex = (tourIndex + deltaIndex - 1) % tourSize + 1
  end
  return pathLength, normalizedTour
end

local function generateRandomTSP(n)
  local tspPoints = {}
  for i = 1, n do
    tspPoints[i] = {math.random() * 100, math.random() * 100}
    --print("(" .. tspPoints[i][1] .. ", " .. tspPoints[i][2] .. ")")
  end
  return tspPoints
end

--[
--math.randomseed(123)
tspPoints = generateRandomTSP(99)

local bestLength, bestTour = solveTourACS(tspPoints)
print("bestTour")
for i, v in ipairs(bestTour) do
  io.write(tostring(v) .. " ")
end
print("-> " .. bestLength)

local _, normalizedTour = normalizeTour(bestLength, bestTour)
for i, v in ipairs(normalizedTour) do
  io.write(tostring(v) .. " ")
end
print("(normalized)")
if #tspPoints > 1 then
  printTSP(35, tspPoints, bestTour) --(7
end
showTimer()
os.exit()
--]]

local world = {
  xSize = 16,
  ySize = 4,
  zSize = 4
}
local decoration = {}
local function getBlock(x, y, z)
  return world[(y * world.zSize + z) * world.xSize + x + 1]
end
local function setBlock(x, y, z, val)
  world[(y * world.zSize + z) * world.xSize + x + 1] = val
end
--for i = 1, world.xMax * world.yMax * world.zMax do
  --world[i] = i
  --i = i + 1
--end
local i = 1
for y = 0, world.ySize - 1 do
  for z = 0, world.zSize - 1 do
    for x = 0, world.xSize - 1 do
      setBlock(x, y, z, math.random(0, 9))
      i = i + 1
    end
  end
end

local function drawWorld(world, decoration, robot)
  local i = 1
  for y = 0, world.ySize - 1 do
    io.write("layer y" .. y .. (y == 0 and " (x increases right, z increases down)\n" or "\n"))
    for z = 0, world.zSize - 1 do
      for x = 0, world.xSize - 1 do
        if world[i] == 0 then
          if x == robot.x and y == robot.y and z == robot.z then
            io.write(" @")
          else
            io.write(" .")
          end
        elseif world[i] == 3 then
          io.write(" ▄")
        else
          io.write(string.format("%2x", world[i]))
        end
        i = i + 1
      end
      io.write("\n")
    end
    io.write("\n")
  end
end

local Robot = {}

function Robot:new(x, y, z)
  self.__index = self
  self = setmetatable({}, self)
  
  self.x = x
  self.y = y
  self.z = z
  setBlock(x, y, z, 0)
  
  return self
end

function Robot:moveX(dx)
  assert(math.abs(dx) == 1 and self.x + dx >= 0 and self.x + dx < world.xSize)
  setBlock(self.x + dx, self.y, self.z, 0)
  self.x = self.x + dx
end
function Robot:moveY(dy)
  assert(math.abs(dy) == 1 and self.y + dy >= 0 and self.y + dy < world.ySize)
  setBlock(self.x, self.y + dy, self.z, 0)
  self.y = self.y + dy
end
function Robot:moveZ(dz)
  assert(math.abs(dz) == 1 and self.z + dz >= 0 and self.z + dz < world.zSize)
  setBlock(self.x, self.y, self.z + dz, 0)
  self.z = self.z + dz
end

function Robot:digScanTunnel()
  setBlock(self.x, self.y + 1, self.z, 0)
  while self.z < world.zSize - 1 do
    self:moveZ(1)
    setBlock(self.x, self.y + 1, self.z, 0)
  end
end

local robot = Robot:new(7, 1, 0)
robot:digScanTunnel()
drawWorld(world, decoration, robot)
