local component = require("component")
local gpu = component.gpu
local term = require("term")

gpu.setPaletteColor(0, 0x0F0F0F)
for i = 0, 15 do
  gpu.setBackground(i, true)
  io.write(string.format("%X\n", gpu.getPaletteColor(i)))
end

os.exit()

for i = 0, 256 do
  gpu.setBackground(0, true)
  --gpu.setPaletteColor(0, i)    -- Slow operation, also palette is limited to 16 colors.
  term.clearLine()
  io.write(string.format("%X          ", gpu.getPaletteColor(0)))
  
  gpu.setBackground(i)
  --io.write(" ")
  io.write(string.format("%X          ", gpu.getBackground()))
  os.sleep(0.05)
end

--[[
os.sleep(1)
gpu.setPaletteColor(0, 0xFF0000)

for i = 0, 15 do
  gpu.setBackground(i, true)
  io.write(" ")
end

os.sleep(1)
gpu.setPaletteColor(0, 0x0F0F0F)
--]]