local component = require("component")
local computer = require("computer")
local event = require("event")
local gpu = component.gpu
local keyboard = require("keyboard")
local term = require("term")
local thread = require("thread")

local common = require("common")
local dlog = require("dlog")
dlog.osBlockNewGlobals(true)

-- Wrapper for gpu.setBackground() that prevents the direct (slow) GPU call if
-- background already set to the desired color.
local function gpuSetBackground(color, isPaletteIndex)
  isPaletteIndex = isPaletteIndex or false
  local currColor, currIsPalette = gpu.getBackground()
  if color ~= currColor or isPaletteIndex ~= currIsPalette then
    gpu.setBackground(color, isPaletteIndex)
  end
end

-- Same as gpuSetBackground() but for foreground color.
local function gpuSetForeground(color, isPaletteIndex)
  isPaletteIndex = isPaletteIndex or false
  local currColor, currIsPalette = gpu.getForeground()
  if color ~= currColor or isPaletteIndex ~= currIsPalette then
    gpu.setForeground(color, isPaletteIndex)
  end
end

-- Class to model a grid of cells in Conway's Game of Life. In each step of the
-- simulation (each call to update()), all of the cells update simultaneously
-- and either live or die in the next generation. The cell lives or dies based
-- on its neighbors (the 4 cells directly adjacent to it and the 4 on the
-- diagonals) and a set of rules:
-- 
-- 1. Any live cell with fewer than two live neighbors dies, as if by
--    underpopulation.
-- 2. Any live cell with two or three live neighbors lives on to the next
--    generation.
-- 3. Any live cell with more than three live neighbors dies, as if by
--    overpopulation.
-- 4. Any dead cell with exactly three live neighbors becomes a live cell, as if
--    by reproduction.
-- 
-- This implementation of the game of life takes some inspiration from David
-- Stafford's QLIFE for performance improvements.
-- https://www.jagregory.com/abrash-black-book/#chapter-18-its-a-plain-wonderful-life
local CellGrid = {}

function CellGrid:new(obj, width, height)
  obj = obj or {}
  setmetatable(obj, self)
  self.__index = self
  
  assert(width <= 0xFFFFFFFF and height <= 0xFFFFFFFF, "Grid size must be within 32-bits.")
  
  -- Wrap edges of the grid back around (make the grid a toroid).
  self.WRAP_EDGE = true
  
  -- Number of bytes in the string blocks that run the width of the grid.
  --self.CHUNK_SIZE = 4
  
  self.width = width
  self.height = height
  
  local heightMetatable = {
    __index = function(t, key)
      return rawget(t, (key - 1) % self.height + 1)
    end,
    __newindex = function(t, key, value)
      rawset(t, (key - 1) % self.height + 1, value)
    end
  }
  
  local widthMetatable = {
    __index = function(t, key)
      return rawget(t, (key - 1) % self.width + 1)
    end,
    __newindex = function(t, key, value)
      rawset(t, (key - 1) % self.width + 1, value)
    end
  }
  
  self.cells = {}
  for y = 1, height do
    --self.cells[y] = {}
    --for x = 1, (width + self.CHUNK_SIZE - 1) // self.CHUNK_SIZE do
      --self.cells[y][x] = string.rep(".", self.CHUNK_SIZE)
    --end
    --self.cells[y] = string.rep(string.char(0), width)
    
    self.cells[y] = {}
    for x = 1, width do
      self.cells[y][x] = 0
    end
    setmetatable(self.cells[y], widthMetatable)
  end
  setmetatable(self.cells, heightMetatable)
  --self.addedCells = {}
  --self.removedCells = {}
  self.updatedCells = {}
  --self.recentSetCells = nil
  self.redrawNeeded = true
  
  return obj
end

function CellGrid:getCell(x, y)
  assert(x >= 1 and x <= self.width and y >= 1 and y <= self.height)
  --return string.byte(self.cells[y], x) & 0x01 == 0x01
  return self.cells[y][x] & 0x01 == 0x01
end

function CellGrid:changeNeighbor_(x, y, val)
  self.cells[y - 1][x - 1] = self.cells[y - 1][x - 1] + val
  self.cells[y - 1][    x] = self.cells[y - 1][    x] + val
  self.cells[y - 1][x + 1] = self.cells[y - 1][x + 1] + val
  
  self.cells[    y][x - 1] = self.cells[    y][x - 1] + val
  self.cells[    y][x + 1] = self.cells[    y][x + 1] + val
  
  self.cells[y + 1][x - 1] = self.cells[y + 1][x - 1] + val
  self.cells[y + 1][    x] = self.cells[y + 1][    x] + val
  self.cells[y + 1][x + 1] = self.cells[y + 1][x + 1] + val
end

function CellGrid:updateState_(x, y, updates)
  x = (x - 1) % self.width + 1
  y = (y - 1) % self.width + 1
  local cell = self.cells[y][x]
  
  if cell & 0x01 == 0x00 and cell & 0x1E == 0x06 then
    -- Cell dead and has three neighbors, it lives.
    self.cells[y][x] = cell | 0x01
    updates[(y << 32) | x] = true
  elseif cell & 0x01 == 0x01 and cell & 0x1E ~= 0x04 and cell & 0x1E ~= 0x06 then
    -- Cell alive and has less than 2 or more than 3 neighbors, bye bye.
    self.cells[y][x] = cell & 0xFE
    updates[(y << 32) | x] = false
  end
end

--[[
-- dont think we need this

function CellGrid:checkNeighbor_(x, y)
  x = (x - 1) % self.width + 1
  y = (y - 1) % self.width + 1
  
  if self.cells[y][x] & 0x01 == 0x01 and not self.recentSetCells[(y << 32) | x] then
    return 0x02
  else
    return 0x00
  end
end
--]]

function CellGrid:setCell(x, y, state)
  assert(x >= 1 and x <= self.width and y >= 1 and y <= self.height)
  --[[
  local cell = string.byte(self.cells[y], x)
  if state then
    if cell & 0x01 == 0x00 then
      self.addedCells[y] = x
    end
    cell = cell | 0x01
  else
    if cell & 0x01 == 0x01 then
      self.removedCells[y] = x
    end
    cell = cell & 0xFE
  end
  self.cells[y] = string.sub(self.cells[y], 1, x - 1) .. string.char(cell) .. string.sub(self.cells[y], x + 1)
  --]]
  
  --self.recentSetCells = self.recentSetCells or {}
  local cell = self.cells[y][x]
  local pos = (y << 32) | x
  
  if state and cell & 0x01 == 0x00 then
    -- Cell should turn on and is currently off, add/remove cell update and change state to on.
    if self.updatedCells[pos] == nil then
      self.updatedCells[pos] = true
    --else
      --self.updatedCells[pos] = nil
    end
    cell = cell | 0x01
    gpu.set(x, y, "#")
  elseif not state and cell & 0x01 == 0x01 then
    -- Cell should turn off and is currently on, add/remove cell update and change state to off.
    if self.updatedCells[pos] == nil then
      self.updatedCells[pos] = false
    --else
      --self.updatedCells[pos] = nil
    end
    cell = cell & 0xFE
    gpu.set(x, y, ".")
  end
  
  self.cells[y][x] = cell
end

function CellGrid:update()
  --[[
  local updatedCells = {}
  for y, x in pairs(self.addedCells) do
    self:addNeighbor_(x, y)
    updatedCells[(y << 32) | (x & 0xFFFFFFFF)] = true
  end
  
  self.addedCells = newAddedCells
  
  for y, x in pairs(self.removedCells) do
    
  end
  --]]
  
  --in the following, we assume y and x always positive
  
  --(y << 32) | x
  
  -- First pass, update the neighbor counts for each cell that updated and changed state.
  for pos, state in pairs(self.updatedCells) do
    local x = pos & 0xFFFFFFFF
    local y = pos >> 32
    
    -- We add a 2 or -2 since the neighbor count starts at the second bit. Just add a zero if the cell state did not change.
    self:changeNeighbor_(x, y, (self.cells[y][x] & 0x01 == 0x01) == state and (state and 2 or -2) or 0)
  end
  
  -- Second pass, update the state of the cell and neighbors, and find new updates. This can run updateState_() on the same cell more than once, but it's fine.
  local newUpdatedCells = {}
  for pos, state in pairs(self.updatedCells) do
    local x = pos & 0xFFFFFFFF
    local y = pos >> 32
    
    self:updateState_(x - 1, y - 1, newUpdatedCells)
    self:updateState_(    x, y - 1, newUpdatedCells)
    self:updateState_(x + 1, y - 1, newUpdatedCells)
    
    self:updateState_(x - 1,     y, newUpdatedCells)
    self:updateState_(    x,     y, newUpdatedCells)
    self:updateState_(x + 1,     y, newUpdatedCells)
    
    self:updateState_(x - 1, y + 1, newUpdatedCells)
    self:updateState_(    x, y + 1, newUpdatedCells)
    self:updateState_(x + 1, y + 1, newUpdatedCells)
  end
  self.updatedCells = newUpdatedCells
  --self.recentSetCells = nil
end

function CellGrid:draw()
  -- If redraw needed (grid initialized or reset) then draw the whole thing, otherwise just draw the changes.
  if self.redrawNeeded then
    for y = 1, self.height do
      for x = 1, self.width do
        gpu.set(x, y, self.cells[y][x] & 0x01 == 0x01 and "#" or ".")
      end
    end
    self.redrawNeeded = false
  else
    for pos, state in pairs(self.updatedCells) do
      local x = pos & 0xFFFFFFFF
      local y = pos >> 32
      
      gpu.set(x, y, state and "#" or ".")
    end
  end
end

local Game = {}

function Game:new(obj)
  obj = obj or {}
  setmetatable(obj, self)
  self.__index = self
  
  self.cellGrid = CellGrid:new(nil, 10, 10)
  self.cellGrid:setCell(5, 3, true)
  self.cellGrid:setCell(6, 4, true)
  self.cellGrid:setCell(4, 5, true)
  self.cellGrid:setCell(5, 5, true)
  self.cellGrid:setCell(6, 5, true)
  self.cellGrid:draw()
  self:drawDebug()
  
  self.paused = true
  self.currentGeneration = 0
  
  return obj
end

function Game:loop()
  if not self.paused then
    self.cellGrid:update()
    self.cellGrid:draw()
    self:drawDebug()
    self.currentGeneration = self.currentGeneration + 1
    os.sleep(0.1)
  else
    os.sleep(0.05)
  end
end

function Game:drawDebug()
  for y = 1, self.cellGrid.height do
    for x = 1, self.cellGrid.width do
      local cell = self.cellGrid.cells[y][x]
      
      if cell & 0x01 == 0x01 then
        gpuSetBackground(0xFFFFFF)
        gpuSetForeground(0x000000)
      else
        gpuSetBackground(0x000000)
        gpuSetForeground(0xFFFFFF)
      end
      
      gpu.set(x + self.cellGrid.width + 1, y, tostring((cell & 0x1E) >> 1))
    end
  end
  gpuSetBackground(0x000000)
  gpuSetForeground(0xFFFFFF)
end

function Game:handleKeyDown(keyboardAddress, char, code, playerName)
  --dlog.out("event", "handleKeyDown", keyboardAddress, char, code, playerName)
  
  if keyboard.isControl(char) then
    
  elseif char == string.byte(" ") then    -- Press space to play/pause simulation.
    self.paused = not self.paused
  elseif char == string.byte("s") then    -- Press 's' to step one generation.
    self.paused = true
    self.cellGrid:update()
    self.cellGrid:draw()
    self:drawDebug()
  end
end

function Game:handleKeyUp(keyboardAddress, char, code, playerName)
  --dlog.out("event", "handleKeyUp", keyboardAddress, char, code, playerName)
  
end

function Game:handleTouch(screenAddress, x, y, button, playerName)
  --dlog.out("event", "handleTouch", screenAddress, x, y, button, playerName)
  x = math.floor(x)
  y = math.floor(y)
  button = math.floor(button)
  
  if x >= 1 and x <= self.cellGrid.width and y >= 1 and y <= self.cellGrid.height then
    if button == 0 then
      self.cellGrid:setCell(x, y, false)
    elseif button == 1 then
      self.cellGrid:setCell(x, y, true)
    end
    self:drawDebug()
  end
end

--[[

each char: 4 bits neighbor count, 1 (or 2) bits state, 1 bit edge condition

76543210
???xxxxa
x = neighbor count
a = state

update checks each char for changes, if change we update state and add to changelist
update changelist at end

split up strings into chunks?

--]]

--[[
function CellGrid:new(obj, width, height)
  obj = obj or {}
  setmetatable(obj, self)
  self.__index = self
  
  self.WRAP_EDGE = true
  self.width = width
  self.height = height
  
  self.cells = {}
  for y = 1, height do
    self.cells[y] = string.rep(".", width)
  end
  self.drawChanges = {}
  
  return obj
end

function CellGrid:getCell(x, y)
  assert(x >= 1 and x <= self.width and y >= 1 and y <= self.height)
  return string.sub(self.cells[y], x, x) == "#"
end

function CellGrid:setCell(x, y, state, cells)
  cells = cells or self.cells
  cells[y] = string.sub(cells[y], 1, x - 1) .. (state and "#" or ".") .. string.sub(cells[y], x + 1)
end

function CellGrid:numNeighbors(x, y)
  local count = 0
  if self.WRAP_EDGE then
    local yDown = y % self.height + 1
    local yUp = (y + self.height - 2) % self.height + 1
    local xRight = x % self.width + 1
    local xLeft = (x + self.width - 2) % self.width + 1
    
    count = count + (self:getCell(xRight, yDown) and 1 or 0)
    count = count + (self:getCell(     x, yDown) and 1 or 0)
    count = count + (self:getCell( xLeft, yDown) and 1 or 0)
    count = count + (self:getCell(xRight,     y) and 1 or 0)
    count = count + (self:getCell( xLeft,     y) and 1 or 0)
    count = count + (self:getCell(xRight,   yUp) and 1 or 0)
    count = count + (self:getCell(     x,   yUp) and 1 or 0)
    count = count + (self:getCell( xLeft,   yUp) and 1 or 0)
  else
    count = count + ((y < self.height and x < self.width and self.cells[y + 1][x + 1] == "#") and 1 or 0)
    count = count + ((y < self.height and self.cells[y + 1][x] == "#") and 1 or 0)
    count = count + ((y < self.height and x > 1 and self.cells[y + 1][x - 1] == "#") and 1 or 0)
    count = count + ((x < self.width and self.cells[y][x + 1] == "#") and 1 or 0)
    count = count + ((x > 1 and self.cells[y][x - 1] == "#") and 1 or 0)
    count = count + ((y > 1 and x < self.width and self.cells[y - 1][x + 1] == "#") and 1 or 0)
    count = count + ((y > 1 and self.cells[y - 1][x] == "#") and 1 or 0)
    count = count + ((y > 1 and x > 1 and self.cells[y - 1][x - 1] == "#") and 1 or 0)
  end
  return count
end

function CellGrid:update()
  local newCells = {}
  for y = 1, self.height do
    newCells[y] = self.cells[y]
  end
  
  for y = 1, self.height do
    for x = 1, self.width do
      local count = self:numNeighbors(x, y)
      local currState = self:getCell(x, y)
      if not currState and count == 3 then
        self:setCell(x, y, true, newCells)
      elseif currState and count ~= 2 and count ~= 3 then
        self:setCell(x, y, false, newCells)
      end
      --print(x, y, currState, count)
    end
  end
  
  self.cells = newCells
end

function CellGrid:draw()
  for y = 1, self.height do
    gpu.set(1, y, self.cells[y])
  end
end
--]]

local function main()
  local threadSuccess = false
  -- Captures the interrupt signal to stop program.
  local interruptThread = thread.create(function()
    event.pull("interrupted")
  end)
  
  -- Blocks until any of the given threads finish. If threadSuccess is still
  -- false and a thread exits, reports error and exits program.
  local function waitThreads(threads)
    thread.waitForAny(threads)
    if interruptThread:status() == "dead" then
      dlog.osBlockNewGlobals(false)
      os.exit(1)
    elseif not threadSuccess then
      io.stderr:write("Error occurred in thread, check log file \"/tmp/event.log\" for details.\n")
      dlog.osBlockNewGlobals(false)
      os.exit(1)
    end
    threadSuccess = false
  end
  
  local game
  --dlog.setFileOut("/tmp/messages", "w")
  
  -- Performs setup and initialization tasks.
  local setupThread = thread.create(function()
    
    term.clear()
    for i = 1, 11 do
      print("ree")
    end
    
    game = Game:new(nil)
    
    threadSuccess = true
  end)
  
  
  waitThreads({interruptThread, setupThread})
  
  
  local mainThread = thread.create(function()
    while true do
      game:loop()
    end
  end)
  
  -- Listens for keyboard and screen events.
  local userInputThread = thread.create(function()
    local function filterEvents(eventName, ...)
      return eventName == "key_down" or eventName == "key_up" or eventName == "touch"
    end
    while true do
      local ev = {event.pullFiltered(filterEvents)}
      
      if ev[1] == "key_down" then
        game:handleKeyDown(select(2, table.unpack(ev)))
      elseif ev[1] == "key_up" then
        game:handleKeyUp(select(2, table.unpack(ev)))
      elseif ev[1] == "touch" then
        game:handleTouch(select(2, table.unpack(ev)))
      end
    end
  end)
  
  
  waitThreads({interruptThread, mainThread, userInputThread})
  
  
  interruptThread:kill()
  mainThread:kill()
  userInputThread:kill()
end

main()
dlog.osBlockNewGlobals(false)
