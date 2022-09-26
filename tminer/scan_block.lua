local component = require("component")
local geolyzer = component.geolyzer
local serialization = require("serialization")
local sides = require("sides")

local analyzeResults = geolyzer.analyze(sides.top)
print("Block data:")
print(serialization.serialize(analyzeResults, math.huge))
print("Obstruction: ", geolyzer.detect(sides.top))
