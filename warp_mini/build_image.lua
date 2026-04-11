local shell = require("shell")

if not shell.execute("simple_preprocess warp_mini_src.lua warp_mini_sp.lua") then
  os.exit(1)
end
if not shell.execute("crunch warp_mini_sp.lua warp_mini_eeprom.lua --tree --verbose") then
  os.exit(1)
end
