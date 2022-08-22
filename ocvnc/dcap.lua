-- Display capture

local component = require("component")
local gpu = component.gpu
local term = require("term")
local unicode = require("unicode")

local dcap = {}


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

return dcap
