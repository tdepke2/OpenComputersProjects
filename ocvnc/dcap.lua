-- Display capture

local component = require("component")
local gpu = component.gpu
local term = require("term")
local unicode = require("unicode")

local dcap = {}

local dlog = require("dlog")
dlog.fileOutput("/home/messages", "w")
dlog.mode("debug")
dlog.standardOutput(false)


-- 
function dcap.onComponentRemoved()
  
end


-- 
function dcap.onComponentAdded()
  
end


function dcap.getForeground()
  local color, isPalette = gpu.getForeground()
  return isPalette and -color - 1 or color
end

function dcap.getBackground()
  local color, isPalette = gpu.getBackground()
  return isPalette and -color - 1 or color
end

function dcap.setForeground(color)
  local c, i = gpu.getForeground()
  if (i and -c - 1 or c) ~= color then
    gpu.setForeground(color < 0 and -color - 1 or color, color < 0)
  end
end

function dcap.setBackground(color)
  local c, i = gpu.getBackground()
  if (i and -c - 1 or c) ~= color then
    gpu.setBackground(color < 0 and -color - 1 or color, color < 0)
  end
end


--[[
displayState = {
  depth: <GPU color depth (number)>
  res: {<GPU resolution w (number)>, <GPU resolution h (number)>}
  view: {<GPU viewport w (number)>, <GPU viewport h (number)>}
  palette: {
    1: <GPU palette color 0 (number)>
    2: <GPU palette color 1 (number)>
    ...
    16: <GPU palette color 15 (number)>
  }
  textBuffer: {    -- Sequence representing the text and colors on screen. The data is organized to reduce context switches (which reduces the length of this table).
    1: <x (number)>    -- Position of text on screen.
    2: [<y (number)>]
    3: [<fg (number)>]    -- Color of text. Values in the range [-16, -1] correspond to a palette index.
    4: [<bg (number)>]
    5: <line (string)>
    ...
  }
  cursor: {<cursor x (number)>, <cursor y (number)>}
  bg: <GPU current background (number)>
  fg: <GPU current foreground (number)>
}
--]]

-- 
function dcap.captureDisplayState()
  local displayState = {}
  displayState.depth = gpu.getDepth()
  displayState.res = {gpu.getResolution()}
  displayState.view = {gpu.getViewport()}
  local palette = {}
  for i = 1, 16 do
    palette[i] = gpu.getPaletteColor(i - 1)
  end
  displayState.palette = palette
  
  -- alternative single array design for textBuffer:
  -- {<entry>, ...}
  -- entry types:
  -- x: number[, y: number[, fg: number[, bg: number]]], str: string
  -- ordered to minimize state changes of fg and bg
  -- for fg and bg, negative values means palette index
  
  --[[
  textBufferInflated: {
    <bg (number)>: {
      <fg (number)>: {
        1: <x (number)>
        2: <y (number)>
        3: <line (string)>
        
        4: <x (number)>
        5: <y (number)>
        6: <line (string)>
        ...
      }
      ...
    }
    ...
  }
  --]]
  
  local textBufferInflated = setmetatable({}, {
    __index = function(t, k)
      t[k] = setmetatable({}, {
        __index = function(t2, k2)
          t2[k2] = {}
          return t2[k2]
        end
      })
      return t[k]
    end
  })
  
  -- Scan each character in the screen buffer row-by-row, and insert them into the textBufferInflated. Any white-on-black text that is a contiguous line of spaces is simply discarded to optimize.
  local foundWBNonSpace = false
  local width, height = gpu.getResolution()
  for y = 1, height do
    local x = 1
    while x <= width do
      local char, fg, bg, fgIndex, bgIndex = gpu.get(x, y)
      fg = math.floor(fgIndex and -fgIndex - 1 or fg)
      bg = math.floor(bgIndex and -bgIndex - 1 or bg)
      
      local colorWB = (fg == 0xFFFFFF and bg == 0x0)
      
      if not colorWB or char ~= " " or foundWBNonSpace then
        local lineGroup = textBufferInflated[bg][fg]
        local lineGroupSize = #lineGroup
        
        -- Add the character to the last line if the y and x position line up (considering the true length in characters in case we have unicode ones).
        if lineGroup[lineGroupSize - 1] == y and lineGroup[lineGroupSize - 2] + unicode.wlen(lineGroup[lineGroupSize]) == x then
          if char ~= " " and colorWB then
            foundWBNonSpace = true
          end
          lineGroup[lineGroupSize] = lineGroup[lineGroupSize] .. char
        else
          if foundWBNonSpace then
            local lineGroupWB = textBufferInflated[0x0][0xFFFFFF]
            lineGroupWB[#lineGroupWB] = string.match(lineGroupWB[#lineGroupWB], "(.-) *$")
            foundWBNonSpace = false
          end
          if char ~= " " or not colorWB then
            lineGroup[lineGroupSize + 1] = x
            lineGroup[lineGroupSize + 2] = y
            lineGroup[lineGroupSize + 3] = char
          end
        end
        x = x + unicode.wlen(char)
      else
        x = x + 1
      end
    end
  end
  if foundWBNonSpace then
    local lineGroupWB = textBufferInflated[0x0][0xFFFFFF]
    lineGroupWB[#lineGroupWB] = string.match(lineGroupWB[#lineGroupWB], "(.-) *$")
  end
  
  local textBuffer = {}
  local textBufferSize = 0
  local lineOffset
  for bg, fgGroup in pairs(textBufferInflated) do
    -- Add bg color (color changed).
    textBuffer[textBufferSize + 4] = bg
    lineOffset = 5
    for fg, lineGroup in pairs(fgGroup) do
      -- Add fg color (color changed).
      textBuffer[textBufferSize + 3] = fg
      lineOffset = math.max(lineOffset, 4)
      
      local lastY
      for i = 1, #lineGroup, 3 do
        -- Add x position.
        textBuffer[textBufferSize + 1] = lineGroup[i]
        -- Add y position if it changed.
        if lineGroup[i + 1] ~= lastY then
          lastY = lineGroup[i + 1]
          textBuffer[textBufferSize + 2] = lastY
          lineOffset = math.max(lineOffset, 3)
        end
        -- Add the line to the end.
        textBufferSize = textBufferSize + lineOffset
        textBuffer[textBufferSize] = lineGroup[i + 2]
        lineOffset = 2
      end
    end
  end
  
  
  displayState.textBufferInflated = textBufferInflated
  displayState.textBuffer = textBuffer
  
  displayState.cursor = {term.getCursor()}
  local c, i = gpu.getBackground()
  displayState.bg = i and -c - 1 or c
  c, i = gpu.getForeground()
  displayState.fg = i and -c - 1 or c
  
  return displayState
end


-- 
function dcap.restoreDisplayState(displayState)
  gpu.setDepth(displayState.depth)
  for i = 1, 16 do
    gpu.setPaletteColor(i - 1, displayState.palette[i])
  end
  
  -- Clear entire screen.
  local width, height = gpu.getResolution()
  dcap.setBackground(0x000000)
  dcap.setForeground(0xFFFFFF)
  gpu.fill(1, 1, width, height, " ")
  
  gpu.setResolution(displayState.res[1], displayState.res[2])
  gpu.setViewport(displayState.view[1], displayState.view[2])
  
  -- Draw the new screen contents.
  local i = 1
  local textBuffer = displayState.textBuffer
  local textBufferSize = #textBuffer
  local x, y
  while i < textBufferSize do
    x = textBuffer[i]
    i = i + 1
    if type(textBuffer[i]) == "number" then
      y = textBuffer[i]
      i = i + 1
      if type(textBuffer[i]) == "number" then
        dcap.setForeground(textBuffer[i])
        i = i + 1
        if type(textBuffer[i]) == "number" then
          dcap.setBackground(textBuffer[i])
          i = i + 1
        end
      end
    end
    gpu.set(x, y, textBuffer[i])
    i = i + 1
  end
  
  term.setCursor(displayState.cursor[1], displayState.cursor[2])
  dcap.setBackground(displayState.bg)
  dcap.setForeground(displayState.fg)
end


local resolutionX, resolutionY
local currentBg, currentFg
local lastFrameChars, lastFrameBgs, lastFrameFgs
local currentFrameChars, currentFrameBgs, currentFrameFgs
local minBoundsX, minBoundsY, maxBoundsX, maxBoundsY


-- component.gpu.setForeground(5, true) component.gpu.set(4, 1, "@") component.gpu.setBackground(0, true) component.gpu.set(9, 2, "#")
function dcap.syncFramebuffers()
  lastFrameChars = {}
  lastFrameBgs = {}
  lastFrameFgs = {}
  currentFrameChars = {}
  currentFrameBgs = {}
  currentFrameFgs = {}
  
  for y = 1, resolutionY do
    for x = 1, resolutionX do
      local char, fg, bg, fgIndex, bgIndex = gpu.get(x, y)
      local i = (y - 1) * resolutionX + x
      lastFrameChars[i] = char
      currentFrameChars[i] = char
      lastFrameBgs[i] = bgIndex and -bgIndex - 1 or bg
      currentFrameBgs[i] = bgIndex and -bgIndex - 1 or bg
      lastFrameFgs[i] = fgIndex and -fgIndex - 1 or fg
      currentFrameFgs[i] = fgIndex and -fgIndex - 1 or fg
    end
  end
  
  --dlog.out("deez", "nuts")
  --dlog.out("stuff1", lastFrameChars)
  --dlog.out("stuff2", lastFrameBgs)
  --dlog.out("stuff3", lastFrameFgs)
  
  -- idea: what if we skip capturing the whole frame and only capture parts on screen before they get drawn?
  -- the current frame is created as a new table each time, last frame has a metatable to lookup old pixels, we still swap at the end.
  -- also still store the bounding rectangle area.
end
--dcap.syncFramebuffers()

function dcap.setupFramebuffers()
  resolutionX, resolutionY = gpu.getResolution()
  currentBg = dcap.getBackground()
  currentFg = dcap.getForeground()
  
  minBoundsX = resolutionX + 1
  minBoundsY = resolutionY + 1
  maxBoundsX = 0
  maxBoundsY = 0
  
  lastFrameChars = setmetatable({}, {
    __index = function(t, k)
      local y = math.floor((k - 1) / resolutionX) + 1
      local x = k - (y - 1) * resolutionX
      local char, fg, bg, fgIndex, bgIndex = gpu.get(x, y)
      t[k] = char
      lastFrameBgs[k] = bgIndex and -bgIndex - 1 or bg
      lastFrameFgs[k] = fgIndex and -fgIndex - 1 or fg
    end
  })
  lastFrameBgs = {}
  lastFrameFgs = {}
  
  currentFrameChars = {}
  currentFrameBgs = {}
  currentFrameFgs = {}
end

function dcap.scanFramebufferChanges()
  for y = minBoundsY, maxBoundsY do
    local i = (y - 1) * resolutionX + minBoundsX
    for x = minBoundsX, maxBoundsX do
      if currentFrameChars[i] and (currentFrameChars[i] ~= lastFrameChars[i] or currentFrameBgs[i] ~= lastFrameBgs[i] or currentFrameFgs[i] ~= lastFrameFgs[i]) then
        return x, y
      end
      i = i + 1
    end
  end
end

function dcap.logState()
  local outFile = io.open("/home/dcap_state.txt", "w")
  assert(outFile)
  
  local function drawCharGrid(arr)
    outFile:write("    ")
    for x = 1, resolutionX do
      outFile:write(x > 9 and tostring(math.floor(x / 10) % 10) or " ")
    end
    outFile:write("\n    ")
    for x = 1, resolutionX do
      outFile:write(string.format("%d", x % 10))
    end
    outFile:write("\n")
    local i = 1
    for y = 1, resolutionY do
      outFile:write(string.format("%3d ", y))
      for x = 1, resolutionX do
        if arr[i] == "" then
          outFile:write("\\")
        else
          outFile:write(arr[i] or ".")
        end
        i = i + 1
      end
      outFile:write("\n")
    end
  end
  
  outFile:write("lastFrameChars:\n")
  setmetatable(lastFrameChars, nil)
  drawCharGrid(lastFrameChars)
  
  outFile:write("\ncurrentFrameChars:\n")
  drawCharGrid(currentFrameChars)
  
  outFile:write("\nminBounds (", minBoundsX, ", ", minBoundsY, ")\n")
  outFile:write("\nmaxBounds (", maxBoundsX, ", ", maxBoundsY, ")\n")
  local x, y = dcap.scanFramebufferChanges()
  outFile:write("\nscanFramebufferChanges() = ", tostring(x), ", ", tostring(y), "\n")
  
  outFile:close()
end







local function onGpuSetBackground(color, isPaletteIndex)
  currentBg = isPaletteIndex and -color - 1 or color
end
local function onGpuSetForeground(color, isPaletteIndex)
  currentFg = isPaletteIndex and -color - 1 or color
end
--local function onGpuSetPaletteColor()

--end
local function onGpuSetDepth()

end
local function onGpuSetResolution()

end
local function onGpuSetViewport()

end
local function onGpuSet(x, y, value, vertical)
  --[[if 
  minBoundsX = math.min(minBoundsX, x)
  minBoundsY = math.min(minBoundsY, y)
  if #value == unicode.len(value) then
    if not vertical then
      local stopX = math.min(x + #value - 1, resolutionX)
      local i = (y - 1) * resolutionX + x
      for charIndex = 1, stopX - x + 1 do
        lastFrameChars[i]
        currentFrameChars[i] = value:sub(charIndex, charIndex)
        currentFrameBgs[i] = currentBg
        currentFrameFgs[i] = currentFg
      end
      maxBoundsX = math.max(maxBoundsX, stopX)
      maxBoundsY = math.max(maxBoundsY, y)
    else
      local stopY = math.min(y + #value - 1, resolutionY)
      local i = (y - 1) * resolutionX + x
      for charIndex = 1, stopY - y + 1 do
        lastFrameChars[i]
        currentFrameChars[i] = value:sub(charIndex, charIndex)
        currentFrameBgs[i] = currentBg
        currentFrameFgs[i] = currentFg
      end
      maxBoundsX = math.max(maxBoundsX, x)
      maxBoundsY = math.max(maxBoundsY, stopY)
    end
  elseif not vertical then
    
  else
    local stopY = math.min(y + unicode.len(value) - 1, resolutionY)
    local i = (y - 1) * resolutionX + x
    for charIndex = 1, stopY - y + 1 do
      lastFrameChars[i]
      currentFrameChars[i] = unicode.sub(value, charIndex, charIndex)
      currentFrameBgs[i] = currentBg
      currentFrameFgs[i] = currentFg
    end
    maxBoundsX = math.max(maxBoundsX, x)
    maxBoundsY = math.max(maxBoundsY, stopY)
  end--]]
  
  -- skip perfect unicode handling for now, not really needed
  
  if not vertical then
    if y < 1 or y > resolutionY then
      return
    end
    local startX = math.max(x, 1)
    local stopX = math.min(x + unicode.wlen(value) - 1, resolutionX)
    local i = (y - 1) * resolutionX + startX
    local charIndex = startX - x + 1
    local lastCharWidth = 1
    for blockIndex = charIndex, stopX - x + 1 do
      _ = lastFrameChars[i]
      if lastCharWidth <= 1 then
        local char = unicode.sub(value, charIndex, charIndex)
        if char == "" then
          char = " "
        end
        currentFrameChars[i] = char
        charIndex = charIndex + 1
        lastCharWidth = unicode.charWidth(char)
      else
        currentFrameChars[i] = " "
        lastCharWidth = lastCharWidth - 1
      end
      currentFrameBgs[i] = currentBg
      currentFrameFgs[i] = currentFg
      i = i + 1
    end
    minBoundsX = math.min(minBoundsX, startX)
    minBoundsY = math.min(minBoundsY, y)
    maxBoundsX = math.max(maxBoundsX, stopX)
    maxBoundsY = math.max(maxBoundsY, y)
  else
    if x < 1 or x > resolutionX then
      return
    end
    local startY = math.max(y, 1)
    local stopY = math.min(y + unicode.len(value) - 1, resolutionY)
    local i = (startY - 1) * resolutionX + x
    for charIndex = startY - y + 1, stopY - y + 1 do
      _ = lastFrameChars[i]
      currentFrameChars[i] = unicode.sub(value, charIndex, charIndex)
      currentFrameBgs[i] = currentBg
      currentFrameFgs[i] = currentFg
      i = i + resolutionX
    end
    minBoundsX = math.min(minBoundsX, x)
    minBoundsY = math.min(minBoundsY, startY)
    maxBoundsX = math.max(maxBoundsX, x)
    maxBoundsY = math.max(maxBoundsY, stopY)
  end
end
local function onGpuCopy(x, y, width, height, tx, ty)
  -- Find bounds of copy area and target area that both land on screen.
  local startX = math.max(math.max(x, 1) + tx, 1) - tx
  local startY = math.max(math.max(y, 1) + ty, 1) - ty
  local stopX = math.min(math.min(x + width - 1, resolutionX) + tx, resolutionX) - tx
  local stopY = math.min(math.min(y + height - 1, resolutionY) + ty, resolutionY) - ty
  --tx = tx + x
  --ty = ty + y
  
  
  -- Trim bounds such that target area also lands on screen.
  --startX = math.max(startX + tx, 1) - tx
  --startY = math.max(startY + ty, 1) - ty
  --stopX = math.min(stopX + tx, resolutionX) - tx
  --stopY = math.min(stopY + ty, resolutionY) - ty
  
  if startX <= stopX and startY <= stopY then
    minBoundsX = math.min(minBoundsX, startX + tx)
    minBoundsY = math.min(minBoundsY, startY + ty)
    maxBoundsX = math.max(maxBoundsX, stopX + tx)
    maxBoundsY = math.max(maxBoundsY, stopY + ty)
  end
  
  
  local deltaX = 1
  if tx > 0 then
    startX, stopX = stopX, startX
    deltaX = -1
  end
  local deltaY = 1
  if ty > 0 then
    startY, stopY = stopY, startY
    deltaY = -1
  end
  
  for y = startY, stopY, deltaY do
    local i = (y - 1) * resolutionX + startX
    local ti = (y + ty - 1) * resolutionX + startX + tx
    for x = startX, stopX, deltaX do
      _ = lastFrameChars[ti]
      local char = currentFrameChars[i]
      if char then
        currentFrameChars[ti] = char
        currentFrameBgs[ti] = currentFrameBgs[i]
        currentFrameFgs[ti] = currentFrameFgs[i]
      else
        currentFrameChars[ti] = lastFrameChars[i]
        currentFrameBgs[ti] = lastFrameBgs[i]
        currentFrameFgs[ti] = lastFrameFgs[i]
      end
      i = i + deltaX
      ti = ti + deltaX
    end
  end
end
local function onGpuFill(x, y, width, height, char)
  if char ~= unicode.sub(char, 1, 1) then
    return
  end
  local charWidth = unicode.charWidth(char)
  -- Find bounds of fill area that land on screen.
  local startX = math.max(x, 1)
  local startY = math.max(y, 1)
  local stopX = math.min(x + width * charWidth - 1, resolutionX)
  local stopY = math.min(y + height - 1, resolutionY)
  
  if startX <= stopX and startY <= stopY then
    minBoundsX = math.min(minBoundsX, startX)
    minBoundsY = math.min(minBoundsY, startY)
    maxBoundsX = math.max(maxBoundsX, stopX)
    maxBoundsY = math.max(maxBoundsY, stopY)
  end
  
  for y = startY, stopY do
    local i = (y - 1) * resolutionX + startX
    for x = startX, stopX do
      _ = lastFrameChars[i]
      if charWidth == 1 or (x - startX) % charWidth == 0 then
        currentFrameChars[i] = char
      else
        currentFrameChars[i] = " "
      end
      currentFrameBgs[i] = currentBg
      currentFrameFgs[i] = currentFg
      i = i + 1
    end
  end
end


local gpuRealFuncs
function dcap.debugBind()
  dcap.setupFramebuffers()
  local gpuCallbacks = {
    setBackground = onGpuSetBackground,
    setForeground = onGpuSetForeground,
    setDepth = onGpuSetDepth,
    setResolution = onGpuSetResolution,
    setViewport = onGpuSetViewport,
    set = onGpuSet,
    copy = onGpuCopy,
    fill = onGpuFill,
  }
  
  gpuRealFuncs = {}
  for k, v in pairs(gpu) do
    local gpuCallback = gpuCallbacks[k]
    if gpuCallback then
      gpuRealFuncs[k] = v
      gpu[k] = function(...)
        local status, ret = xpcall(gpuCallback, debug.traceback, ...)
        dlog.out("gpu", k, " called with:", {...}, "status is ", status, " ", ret)
        return v(...)
      end
    end
  end
end

function dcap.debugUnbind()
  for k, v in pairs(gpuRealFuncs) do
    gpu[k] = v
  end
  gpuRealFuncs = nil
end

dlog.out("start")
dcap.debugBind()
--gpu.set(1, 1, "hello world!")
--gpu.set(1, 2, "★star★")
--gpu.set(158, 3, "abcdefgh")
gpu.fill(4, 3, 5, 6, "★")
gpu.set(4, 3, "abcdefghij")
gpu.set(4, 4, "klmnopqrst")
gpu.set(4, 5, "uvwxyz0123")
gpu.set(4, 6, "456789ABCD")
gpu.set(4, 7, "EFGHIJKLMN")
gpu.set(4, 8, "OPQRSTUVWX")
--gpu.copy(4, 3, 10, 6, 47, 155)
--gpu.copy(4, 3, 10, 6, 150, 45)
gpu.fill(160, 50, 1, 0, "x")
dcap.logState()
dcap.debugUnbind()
dlog.out("end")

return dcap
