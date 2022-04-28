--[[
Network serialization/deserialization of arbitrary data to messages that can be
sent in a packet (similar to RPC).

Each packet sent over the network contains a header and a data segment. There's
a bit more added on by wnet, like sequence number and count, but that won't be
discussed here. The packet header identifies the type of packet, like a request
to move items from storage network to output inventory or a notification that a
robot has powered on. As a convention, the header is composed of a class that it
belongs to and type of message (using alphanumeric and underscore characters
only). Each header should be unique for its type of message, reusing the same
header for back-and-forth message passing is not a great idea.

The main function used in here is packer.handlePacket(). It looks up the
callback that has been registered to a given packet's header and executes it.
The callbacks should be set in the application code for each packet header that
the application cares about. To set a callback, add a new function to
packer.callbacks using the packet header as the key. It is also necessary to
define the types of headers used with packer.defineHeader(). This is done in the
packer module itself to keep a common interface specification for network
communication. Receiving packets is done by just calling packer.handlePacket()
with the packet message, while sending looks something like:
wnet.send(packer.pack.my_packet_header(myArguments))

Note that the "pack" functions take only the data arguments and return the
header with data (full message). The "unpack" functions take the full message
and return the data arguments.

Before this module existed, the packet handling code was spread across all of
the application code. This made it a real pain to make changes to the data
segment because the parsing had to be updated in a few different places. It also
didn't help that I used one big switch-case kind of function to manage all
packet actions, yikes! Unifying all packet types into one module like this may
not be the best idea, but it does seem a lot better than before.
--]]

local serialization = require("serialization")

-- Check for optional dependency dlog.
local dlog, xassert
do
  local status, ret = pcall(require, "dlog")
  if status then
    dlog = ret
    xassert = dlog.xassert
  else
    -- Fallback option for xassert if dlog not found.
    xassert = function(v, ...)
      assert(v, string.rep("%s", select("#", ...)):format(...))
    end
  end
end

local packer = {}

-- Functions to apply an action for a given packet header.
packer.callbacks = {}

-- Sets the action to take when no callback is registered for the given packet
-- header. Normally this should do nothing, but it is possible to override the
-- metatable to log the event here or even throw an error.
setmetatable(packer.callbacks, {
  __index = function(t, k)
    if dlog then
      dlog.out("packer", "No callback registered for header \"", k, "\".")
    end
    return nil
  end
})

-- Definitions of packet headers and expected data types. Each header has a
-- table of strings for these expected types, or a value of "true" if there are
-- none for that header.
packer.headers = {}

setmetatable(packer.headers, {
  __index = function(t, k)
    xassert(false, "attempt to index packer.headers for \"", k, "\" failed (header is undefined).")
  end
})

-- Serializes the given arguments into a table and returns a string containing
-- the header and this table. The arguments are not verified for correct types.
local function doPack(...)
  local header = packer.packCache
  if type(packer.headers[header]) == "table" then
    return header .. serialization.serialize(table.pack(...))
  else
    return header .. "{n=0}"
  end
end

-- Unserializes the given string message (contains the header and table data)
-- and returns the original data. An error is thrown if data in the message does
-- not match the specified types defined for the header.
local function doUnpack(message)
  local header = packer.unpackCache
  if type(packer.headers[header]) == "table" then
    local arg = serialization.unserialize(string.sub(message, #header + 1))
    xassert(arg, "failed to unserialize the provided message.")
    if #packer.headers[header] ~= arg.n then
      xassert(false, "number of arguments passed for header \"", header, "\" is incorrect (", #packer.headers[header], " expected, got ", arg.n, ").")
    end
    for i, validTypes in ipairs(packer.headers[header]) do
      if not string.find(validTypes, type(arg[i]), 1, true) and validTypes ~= "any" then
        xassert(false, "bad argument for header \"", header, "\" at index #", i, " (", validTypes, " expected, got ", type(arg[i]), ").")
      end
    end
    return table.unpack(arg, 1, arg.n)
  elseif message ~= header .. "{n=0}" then
    xassert(false, "number of arguments passed for header \"", header, "\" is incorrect (0 expected).")
  end
end

packer.pack = setmetatable({}, {
  __index = function(t, k)
    packer.packCache = k
    return doPack
  end
})

packer.unpack = setmetatable({}, {
  __index = function(t, k)
    packer.unpackCache = k
    return doUnpack
  end
})

-- packer.defineHeader(header: string[, name1: string, types1: string, ...])
-- 
-- Define a packet header and the list of accepted values. For each value, give
-- a name (purely for making it clearer what the value represents in the code)
-- and a comma-separated list of types. The string "any" can also be used for
-- the types to allow any value.
function packer.defineHeader(header, ...)
  xassert(type(header) == "string", "packet header must be a string.")
  local typeList = {}
  local arg = table.pack(...)
  for i = 1, arg.n / 2 do
    typeList[i] = arg[i * 2]
    xassert(type(typeList[i]) == "string", "packet types definition at index #", i * 2 + 1, " must be a string.")
  end
  packer.headers[header] = (next(typeList) == nil and true or typeList)
end

-- packer.handlePacket(obj: table|nil[, address: string, port: number,
--   message: string])
-- 
-- Looks up the packet handler in packer.callbacks for the given packet, and
-- executes the action. If no callback is registered, behavior depends on the
-- metatable of packer.callbacks (nothing happens by default). The obj argument
-- should be used if the callbacks are set to class member functions. Otherwise,
-- nil can be passed for obj and the first argument in a callback can be
-- ignored. The address, port, and message arguments are the same as returned
-- from wnet.receive (message contains the full packet with header and data
-- segments).
function packer.handlePacket(obj, address, port, message)
  if type(message) ~= "string" then
    return
  end
  local header = string.match(message, "[^{]*")
  if packer.callbacks[header] then
    packer.callbacks[header](obj, address, port, packer.unpack[header](message))
  end
end

-- packer.extractHeader([address: string, port: number, message: string]):
--     string|nil, number|nil, string|nil, string|nil
-- 
-- Convenience function to find the header attached to a packet. Returns the
-- address, port, header, and message (message is unmodified and still contains
-- the header). If message is not a string, returns nil.
function packer.extractHeader(address, port, message)
  if type(message) ~= "string" then
    return
  end
  local header = string.match(message, "[^{]*")
  return address, port, header, message
end



-- Request storage server address.
packer.defineHeader("stor_discover")

-- Request storage to insert items into storage network.
packer.defineHeader("stor_insert")

-- Request storage to extract items from storage network.
packer.defineHeader("stor_extract",
  "itemName", "string,nil",
  "amount", "number"
)

-- Request storage to reserve items in network for crafting operation.
packer.defineHeader("stor_recipe_reserve",
  "ticket", "string",
  "itemInputs", "table"
)

-- Request storage to start crafting operation.
packer.defineHeader("stor_recipe_start",
  "ticket", "string"
)

-- Request storage to cancel crafting operation.
packer.defineHeader("stor_recipe_cancel",
  "ticket", "string"
)

-- Request storage's drone inventories item list.
packer.defineHeader("stor_get_drone_item_list")

-- Request storage to flush items from drone inventory into network.
packer.defineHeader("stor_drone_insert",
  "droneInvIndex", "number",
  "ticket", "string,nil"
)

-- Request storage to pull items from network into drone inventory.
packer.defineHeader("stor_drone_extract",
  "droneInvIndex", "number",
  "ticket", "string,nil",
  "extractList", "table"
)

-- Storage is reporting system has started up.
packer.defineHeader("stor_started")

-- Storage is reporting the (trimmed) contents of storageItems.
packer.defineHeader("stor_item_list",
  "items", "table"
)

-- Storage is reporting a change in storageItems.
packer.defineHeader("stor_item_diff",
  "itemsDiff", "table"
)

-- Storage is reporting the contents of droneItems.
packer.defineHeader("stor_drone_item_list",
  "droneItems", "table"
)

-- Storage is reporting a change in droneItems.
packer.defineHeader("stor_drone_item_diff",
  "operation", "string",
  "result", "string",
  "droneItemsDiff", "table"
)



-- Request crafting server address.
packer.defineHeader("craft_discover")

-- Request crafting to compute a crafting operation and create a ticket.
packer.defineHeader("craft_check_recipe",
  "itemName", "string",
  "amount", "number"
)

-- Request crafting to start a crafting operation.
packer.defineHeader("craft_recipe_start",
  "ticket", "string"
)

-- Request crafting to cancel a crafting operation.
packer.defineHeader("craft_recipe_cancel",
  "ticket", "string"
)

-- Crafting is reporting system has started up.
packer.defineHeader("craft_started")

-- Crafting is reporting the available craftable items from the recipes table.
packer.defineHeader("craft_recipe_list",
  "recipeItems", "table"
)

-- Crafting is reporting "success" or "missing items" results from a recent
-- craft_recipe_start request.
packer.defineHeader("craft_recipe_confirm",
  "ticket", "string",
  "craftProgress", "table"
)

-- Crafting is reporting failure of a recent craft_recipe_start request, or a
-- running crafting operation.
packer.defineHeader("craft_recipe_error",
  "ticket", "string",
  "errMessage", "string"
)

-- Crafting is reporting completion of a running crafting operation.
packer.defineHeader("craft_recipe_finished",
  "ticket", "string"
)

-- FIXME update this to match the same way robot does it. ########################################################
-- Request drone to run a software update.
packer.defineHeader("drone_upload",
  "sourceCode", "string"
)

-- Drone is reporting system has started up.
packer.defineHeader("drone_started")

-- Drone is reporting compile/runtime error.
packer.defineHeader("drone_error",
  "errType", "string",
  "errMessage", "string"
)



-- Request robot to run a software update (run program or cache library code).
packer.defineHeader("robot_upload",
  "libName", "string",
  "srcCode", "string"
)

-- Request robot to run a firmware update.
packer.defineHeader("robot_upload_eeprom",
  "srcCode", "string"
)

-- Request robot to run a line of code (for debugging purposes).
packer.defineHeader("robot_upload_rlua",
  "srcCode", "string"
)

-- Request robot to scan adjacent inventories for target item.
packer.defineHeader("robot_scan_adjacent",
  "itemName", "string",
  "slotNum", "number"
)

-- Request robot to prepare to craft a number of items.
packer.defineHeader("robot_prepare_craft",
  "craftingTask", "table"
)

-- Request robot to start a pending crafting request.
packer.defineHeader("robot_start_craft")

-- Request robot to exit software (return to firmware loop).
packer.defineHeader("robot_halt")

-- Robot is reporting system has started up.
packer.defineHeader("robot_started")

-- Robot is reporting result of rlua execution.
packer.defineHeader("robot_upload_rlua_result",
  "message", "string"
)

-- Robot is reporting result of request to scan adjacent inventories.
packer.defineHeader("robot_scan_adjacent_result",
  "foundSide", "number,nil"
)

-- Robot is reporting result of crafting request.
packer.defineHeader("robot_finished_craft",
  "ticket", "string",
  "taskID", "number"
)

-- Robot is reporting compile/runtime error.
packer.defineHeader("robot_error",
  "errType", "string",
  "errMessage", "string"
)


return packer
