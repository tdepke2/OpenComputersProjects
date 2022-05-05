local component = require("component")
local modem = component.modem

local include = require("include")
--local dlog = include("dlog")
--dlog.osBlockNewGlobals(true)
--local dstructs = include("dstructs")
--local packer = include("packer")
local wnet = include("wnet")

local function main()
  --dlog.out("main", "Program starts.")
  
  modem.open(123)
  wnet.send(modem, nil, 123, "system started")
  
  --dlog.out("main", "Program ends.")
end

main()
