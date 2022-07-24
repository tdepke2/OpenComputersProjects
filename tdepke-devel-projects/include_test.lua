local component = require("component")
local modem = component.modem

local include = require("include")
print("wnet is loaded? " .. tostring(include.isLoaded("wnet")))
local wnet = include("wnet")

wnet.send(modem, nil, 58008, "my_broadcast")

--wnet = include.reload("wnet")

wnet.send(modem, nil, 58008, "my_broadcast_2")

--include.unload("wnet")
--include.unloadAll()
wnet = package.loaded.wnet

wnet.send(modem, nil, 58008, "my_broadcast_2")
