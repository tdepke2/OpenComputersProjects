--[[

--]]

-- OS libraries.
local component = require("component")
local computer = require("computer")
local event = require("event")
local thread = require("thread")

-- User libraries.
local include = require("include")
local dlog = include("dlog")
dlog.osBlockNewGlobals(true)
local mnet = include("mnet")
local mrpc = include("mrpc").registerPort(123)
mrpc.addDeclarations(include("net_testing/mrpc_ocvnc"))

mrpc.async.stor_discover("*")

mrpc.functions.stor_extract = function() print("ok") end
