local component = require("component")
local event = require("event")
local modem = component.modem

--print(modem.open(123))
--print(modem.open(124))
print("is wireless:", modem.isWireless())

modem.broadcast(123, "do ya like jazz?")
print("sent message")
modem.broadcast(124, "ya better")
print("sent message 2")