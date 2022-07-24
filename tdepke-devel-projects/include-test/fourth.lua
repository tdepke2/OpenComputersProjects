local include = require("include")
local first = include("include-test.first")
local x = include("include-test.x")

local fourth = {}

fourth.first = first
fourth.x = x

return fourth
