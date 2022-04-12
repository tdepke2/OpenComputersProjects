local component = require("component")
local computer = require("computer")
local gpu = component.gpu

local startTime = computer.uptime()

local function gpuSetBackground(color, isPaletteIndex)
  isPaletteIndex = isPaletteIndex or false
  local currColor, currIsPalette = gpu.getBackground()
  if color ~= currColor or isPaletteIndex ~= currIsPalette then
    gpu.setBackground(color, isPaletteIndex)
  end
end

for i = 1, 10000 do
  gpuSetBackground(1, true)
  --gpu.getBackground()
  gpuSetBackground(1, true)
  --gpu.getForeground()
end

local endTime = computer.uptime()

print("took " .. endTime - startTime)