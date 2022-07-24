local include = require("include")
local fourth = include("include-test.fourth")
local second = include("include-test.second")
local third = include("include-test.third")

local fifth = {}

fifth.fourth = fourth
fifth.second = second
fifth.third = third

return fifth
