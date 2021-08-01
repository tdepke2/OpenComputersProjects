local component = require("component")
local event = require("event")
local modem = component.modem

print(modem.open(123))
print(modem.open(124))
print("is wireless:", modem.isWireless())

local _, _, from, port, distance, message = event.pull("modem_message")
print("got message from " .. from .. " on port " .. port .. " at " .. distance .. " blocks away: " .. message)

local _, _, from, port, distance, message = event.pull("modem_message")
print("got message from " .. from .. " on port " .. port .. " at " .. distance .. " blocks away: " .. message)