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
  -- FIXME still need to implement this ###############################################################################################################################################
  
  self.width = width
  self.height = height
  
  self:clear()
  
  return obj
end

function CellGrid:getCell(x, y)
  assert(x >= 1 and x <= self.width and y >= 1 and y <= self.height)
  return self.cells:get((y - 1) * self.width + x) & 0x01 == 0x01
end

function CellGrid:setCell(x, y, state)
  assert(x >= 1 and x <= self.width and y >= 1 and y <= self.height)
  
  local cell = self.cells:get((y - 1) * self.width + x)
  local pos = (y << 32) | x
  
  if state and cell & 0x01 == 0x00 then
    -- Cell should turn on and is currently off, add cell update if none found and change state to on.
    if self.updatedCells[pos] == nil then
      self.updatedCells[pos] = true
    end
    cell = cell | 0x01
    gpu.set(x, y, "#")
  elseif not state and cell & 0x01 == 0x01 then
    -- Cell should turn off and is currently on, add cell update if none found and change state to off.
    if self.updatedCells[pos] == nil then
      self.updatedCells[pos] = false
    end
    cell = cell & 0xFE
    gpu.set(x, y, ".")
  end
  
  self.cells:set((y - 1) * self.width + x, cell)
end

function CellGrid:clear()
  self.cells = common.ByteArray:new(nil, self.width * self.height)
  
  -- Set edge flag in top and bottom row.
  for x = 1, self.width do
    self.cells:set((1 - 1) * self.width + x, 0x20)
    self.cells:set((self.height - 1) * self.width + x, 0x20)
  end
  -- Set edge flag in left and right column.
  for y = 1, self.height do
    self.cells:set((y - 1) * self.width + 1, 0x20)
    self.cells:set((y - 1) * self.width + self.width, 0x20)
  end
  
  self.updatedCells = {}
  self.redrawNeeded = true
end

function CellGrid:changeNeighbor_(x, y, val)
  if self.cells:get((y - 1) * self.width + x) & 0x20 == 0x00 then
    -- Common case, cell not on edge.
    local index = (y - 2) * self.width + x - 1
    self.cells:set(    index, self.cells:get(    index) + val)
    self.cells:set(index + 1, self.cells:get(index + 1) + val)
    self.cells:set(index + 2, self.cells:get(index + 2) + val)
    
    index = index + self.width
    self.cells:set(    index, self.cells:get(    index) + val)
    self.cells:set(index + 2, self.cells:get(index + 2) + val)
    
    index = index + self.width
    self.cells:set(    index, self.cells:get(    index) + val)
    self.cells:set(index + 1, self.cells:get(index + 1) + val)
    self.cells:set(index + 2, self.cells:get(index + 2) + val)
  else
    -- Cell is on an edge, need to check for edge behavior.
    local yDown = y % self.height + 1
    local yUp = (y + self.height - 2) % self.height + 1
    local xRight = x % self.width + 1
    local xLeft = (x + self.width - 2) % self.width + 1
    
    self.cells:set((  yUp - 1) * self.width +  xLeft, self.cells:get((  yUp - 1) * self.width +  xLeft) + val)
    self.cells:set((  yUp - 1) * self.width +      x, self.cells:get((  yUp - 1) * self.width +      x) + val)
    self.cells:set((  yUp - 1) * self.width + xRight, self.cells:get((  yUp - 1) * self.width + xRight) + val)
    
    self.cells:set((    y - 1) * self.width +  xLeft, self.cells:get((    y - 1) * self.width +  xLeft) + val)
    self.cells:set((    y - 1) * self.width + xRight, self.cells:get((    y - 1) * self.width + xRight) + val)
    
    self.cells:set((yDown - 1) * self.width +  xLeft, self.cells:get((yDown - 1) * self.width +  xLeft) + val)
    self.cells:set((yDown - 1) * self.width +      x, self.cells:get((yDown - 1) * self.width +      x) + val)
    self.cells:set((yDown - 1) * self.width + xRight, self.cells:get((yDown - 1) * self.width + xRight) + val)
  end
end

function CellGrid:updateState_(x, y, index, updates)
  local cell = self.cells:get(index)
  
  if cell & 0x01 == 0x00 and cell & 0x1E == 0x06 then
    -- Cell dead and has three neighbors, it lives.
    self.cells:set(index, cell | 0x01)
    updates[(y << 32) | x] = true
  elseif cell & 0x01 == 0x01 and cell & 0x1E ~= 0x04 and cell & 0x1E ~= 0x06 then
    -- Cell alive and has less than 2 or more than 3 neighbors, bye bye.
    self.cells:set(index, cell & 0xFE)
    updates[(y << 32) | x] = false
  end
end

function CellGrid:update()
  -- First pass, update the neighbor counts for each cell that updated and changed state.
  for pos, state in pairs(self.updatedCells) do
    local x = pos & 0xFFFFFFFF
    local y = pos >> 32
    
    -- We add a 2 or -2 since the neighbor count starts at the second bit. Just add a zero if the cell state did not change.
    self:changeNeighbor_(x, y, (self.cells:get((y - 1) * self.width + x) & 0x01 == 0x01) == state and (state and 2 or -2) or 0)
  end
  
  -- Second pass, update the state of the cell and neighbors, and find new updates. This can run updateState_() on the same cell more than once, but it's fine.
  local newUpdatedCells = {}
  for pos, state in pairs(self.updatedCells) do
    local x = pos & 0xFFFFFFFF
    local y = pos >> 32
    
    if self.cells:get((y - 1) * self.width + x) & 0x20 == 0x00 then
      -- Common case, cell not on edge.
      local index = (y - 2) * self.width + x - 1
      self:updateState_(x - 1, y - 1,     index, newUpdatedCells)
      self:updateState_(    x, y - 1, index + 1, newUpdatedCells)
      self:updateState_(x + 1, y - 1, index + 2, newUpdatedCells)
      
      index = index + self.width
      self:updateState_(x - 1,     y,     index, newUpdatedCells)
      self:updateState_(    x,     y, index + 1, newUpdatedCells)
      self:updateState_(x + 1,     y, index + 2, newUpdatedCells)
      
      index = index + self.width
      self:updateState_(x - 1, y + 1,     index, newUpdatedCells)
      self:updateState_(    x, y + 1, index + 1, newUpdatedCells)
      self:updateState_(x + 1, y + 1, index + 2, newUpdatedCells)
    else
      -- Cell is on an edge, need to check for edge behavior.
      local yDown = y % self.height + 1
      local yUp = (y + self.height - 2) % self.height + 1
      local xRight = x % self.width + 1
      local xLeft = (x + self.width - 2) % self.width + 1
      
      self:updateState_( xLeft,   yUp, (  yUp - 1) * self.width +  xLeft, newUpdatedCells)
      self:updateState_(     x,   yUp, (  yUp - 1) * self.width +      x, newUpdatedCells)
      self:updateState_(xRight,   yUp, (  yUp - 1) * self.width + xRight, newUpdatedCells)
      
      self:updateState_( xLeft,     y, (    y - 1) * self.width +  xLeft, newUpdatedCells)
      self:updateState_(     x,     y, (    y - 1) * self.width +      x, newUpdatedCells)
      self:updateState_(xRight,     y, (    y - 1) * self.width + xRight, newUpdatedCells)
      
      self:updateState_( xLeft, yDown, (yDown - 1) * self.width +  xLeft, newUpdatedCells)
      self:updateState_(     x, yDown, (yDown - 1) * self.width +      x, newUpdatedCells)
      self:updateState_(xRight, yDown, (yDown - 1) * self.width + xRight, newUpdatedCells)
    end
  end
  self.updatedCells = newUpdatedCells
end

function CellGrid:draw()
  -- If redraw needed (grid initialized or reset) then draw the whole thing, otherwise just draw the changes.
  if self.redrawNeeded then
    for y = 1, self.height do
      for x = 1, self.width do
        gpu.set(x, y, self.cells:get((y - 1) * self.width + x) & 0x01 == 0x01 and "#" or ".")
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
      local cell = self.cellGrid.cells:get((y - 1) * self.cellGrid.width + x)
      
      if cell & 0x01 == 0x01 then
        if cell & 0x20 == 0x20 then
          gpuSetBackground(0x808080)
        else
          gpuSetBackground(0xFFFFFF)
        end
        gpuSetForeground(0x000000)
      else
        if cell & 0x20 == 0x20 then
          gpuSetBackground(0x808080)
        else
          gpuSetBackground(0x000000)
        end
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
??exxxxa
x = neighbor count
a = state
e = edge

update checks each char for changes, if change we update state and add to changelist
update changelist at end

split up strings into chunks?

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
