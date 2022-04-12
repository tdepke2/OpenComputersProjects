--[[
Network packet packing/unpacking/handling for all packet types.

Each packet sent over the network contains a header and a data segment,
separated by a comma. There's a bit more added on by wnet, like sequence number
and count, but that won't be discussed here. Each packet header identifies the
type of packet, like a request to move items from storage network to output
inventory or a notification that a robot has powered on. The header is composed
of a class that it belongs to and type of message (using alphanumeric and
underscore characters only, just makes it easier to type in function defs). Each
header should be unique for its type of message, reusing the same header for
back-and-forth message passing is not a great idea.

The main function used in here is packer.handlePacket(). It looks up the
callback that has been registered to a given packet's header and executes it.
The callbacks should be set in the application code for each packet header that
the application cares about. To set a callback, add a new function to
packer.callbacks using the packet header as the key. It is also necessary to add
pack/unpack functions for each header, so that the data arguments can be
separated and passed to the callback. These usually just involve string
concatenation with commas, but other separators are sometimes used when table
serialization is involved. Receiving packets is done by just calling
packer.handlePacket() with the packet message, while sending looks something
like:
wnet.send(packer.pack.my_packet_header(myArguments))

Note that the "pack" functions take only the data arguments and return the
header with data (full message). The "unpack" functions take only the data
(header should be stripped off) and return the data arguments.

Before this module existed, the packet handling code was spread across all of
the application code. This made it a real pain to make changes to the data
segment because the parsing had to be updated in a few different places. It also
didn't help that I used one big switch-case kind of function to manage all
packet actions, yikes! Unifying all packet types into one module like this may
not be the best idea, but it does seem a lot better than before.
--]]

local serialization = require("serialization")

local packer = {}

-- Functions to "pack" the data arguments into the message.
packer.pack = {}

-- Functions to "unpack" the data segment of message into the data arguments.
packer.unpack = {}

-- Functions to apply an action for a given packet header.
packer.callbacks = {}

-- Sets the action to take when no callback is registered for the given packet
-- header. Normally this should do nothing, but it is possible to override the
-- metatable to log the event here or even throw an error.
setmetatable(packer.callbacks, {
  __index = function(t, key)
    --dlog.out("packer", "No callback registered for header \"" .. key .. "\"")
    print("No callback registered for packet header \"" .. key .. "\".")
    return nil
  end
})

-- packer.handlePacket(obj: table, address: string, port: number,
--   message: string)
-- 
-- Looks up the packet handler in packer.callbacks for the given packet, and
-- executes the action. If no callback is registered, behavior depends on the
-- metatable of packer.callbacks (nothing happens by default). The obj argument
-- should be used if the callbacks are set to class member functions. Otherwise,
-- nil can be passed for obj and the first argument in a callback can be
-- ignored. The address, port, and message arguments are the same as returned
-- from wnet.receive (message contains the full packet with header and data
-- segments).
-- 
-- Note that it is an error to register a callback for a header that has no
-- corresponding unpack operation. If that happens, this function will throw an
-- exception if a packet with that header is received.
function packer.handlePacket(obj, address, port, message)
  if not address then
    return
  end
  local header = string.match(message, "[^,]*")
  if packer.callbacks[header] then
    packer.callbacks[header](obj, address, port, packer.unpack[header](string.sub(message, #header + 2)))
  end
end

-- packer.extractPacket(address: string, port: number, message: string):
--     nil|string, number, string, string
-- 
-- Convenience function to break a packet's header and data segments into
-- separate parts. Removes the extra step of doing this when manually handling a
-- packet. If address is nil, returns nil.
function packer.extractPacket(address, port, message)
  if not address then
    return nil
  end
  local header = string.match(message, "[^,]*")
  return address, port, header, string.sub(message, #header + 2)
end



-- Request storage server address.
function packer.pack.stor_discover()
  return "stor_discover,"
end
function packer.unpack.stor_discover(data)
  return nil
end

-- Request storage to insert items into storage network.
function packer.pack.stor_insert()
  return "stor_insert,"
end
function packer.unpack.stor_insert(data)
  return nil
end

-- Request storage to extract items from storage network.
function packer.pack.stor_extract(itemName, amount)
  return "stor_extract," .. (itemName or "") .. "," .. amount
end
function packer.unpack.stor_extract(data)
  local itemName = string.match(data, "[^,]*")
  local amount = string.sub(data, #itemName + 2)
  if itemName == "" then
    itemName = nil
  end
  return itemName, tonumber(amount)
end

-- Request storage to reserve items in network for crafting operation.
function packer.pack.stor_recipe_reserve(ticket, requiredItems)
  return "stor_recipe_reserve," .. ticket .. ";" .. serialization.serialize(requiredItems)
end
function packer.unpack.stor_recipe_reserve(data)
  local ticket = string.match(data, "[^;]*")
  local requiredItems = serialization.unserialize(string.sub(data, #ticket + 2))
  return ticket, requiredItems
end

-- Request storage to start crafting operation.
function packer.pack.stor_recipe_start(ticket)
  return "stor_recipe_start," .. ticket
end
function packer.unpack.stor_recipe_start(data)
  return data
end

-- Request storage to cancel crafting operation.
function packer.pack.stor_recipe_cancel(ticket)
  return "stor_recipe_cancel," .. ticket
end
function packer.unpack.stor_recipe_cancel(data)
  return data
end

-- Request storage's drone inventories item list.
function packer.pack.stor_get_drone_item_list()
  return "stor_get_drone_item_list,"
end
function packer.unpack.stor_get_drone_item_list(data)
  return nil
end

-- Request storage to flush items from drone inventory into network.
function packer.pack.stor_drone_insert(droneInvIndex, ticket)
  return "stor_drone_insert," .. droneInvIndex .. "," .. (ticket or "")
end
function packer.unpack.stor_drone_insert(data)
  local droneInvIndex = string.match(data, "[^,]*")
  local ticket = string.sub(data, #droneInvIndex + 2)
  if ticket == "" then
    ticket = nil
  end
  return tonumber(droneInvIndex), ticket
end

-- Request storage to pull items from network into drone inventory.
function packer.pack.stor_drone_extract(droneInvIndex, ticket, extractList)
  return "stor_drone_extract," .. droneInvIndex .. "," .. (ticket or "") .. ";" .. serialization.serialize(extractList)
end
function packer.unpack.stor_drone_extract(data)
  local droneInvIndex = string.match(data, "[^,]*")
  local ticket = string.match(data, "[^;]*", #droneInvIndex + 2)
  local extractList = serialization.unserialize(string.sub(data, #droneInvIndex + #ticket + 3))
  if ticket == "" then
    ticket = nil
  end
  return tonumber(droneInvIndex), ticket, extractList
end

-- Storage is reporting system has started up.
function packer.pack.stor_started()
  return "stor_started,"
end
function packer.unpack.stor_started(data)
  return nil
end

-- Storage is reporting the (trimmed) contents of storageItems.
function packer.pack.stor_item_list(items)
  return "stor_item_list," .. serialization.serialize(items)
end
function packer.unpack.stor_item_list(data)
  local items = serialization.unserialize(data)
  return items
end

-- Storage is reporting a change in storageItems.
function packer.pack.stor_item_diff(itemsDiff)
  return "stor_item_diff," .. serialization.serialize(itemsDiff)
end
function packer.unpack.stor_item_diff(data)
  local itemsDiff = serialization.unserialize(data)
  return itemsDiff
end

-- Storage is reporting the contents of droneItems.
function packer.pack.stor_drone_item_list(droneItems)
  return "stor_drone_item_list," .. serialization.serialize(droneItems)
end
function packer.unpack.stor_drone_item_list(data)
  local droneItems = serialization.unserialize(data)
  return droneItems
end

-- Storage is reporting a change in droneItems.
function packer.pack.stor_drone_item_diff(operation, result, droneItemsDiff)
  return "stor_drone_item_diff," .. operation .. "," .. result .. "," .. serialization.serialize(droneItemsDiff)
end
function packer.unpack.stor_drone_item_diff(data)
  local operation = string.match(data, "[^,]*")
  local result = string.match(data, "[^,]*", #operation + 2)
  local droneItemsDiff = serialization.unserialize(string.sub(data, #operation + #result + 3))
  return operation, result, droneItemsDiff
end



-- Request crafting server address.
function packer.pack.craft_discover()
  return "craft_discover,"
end
function packer.unpack.craft_discover(data)
  return nil
end

-- Request crafting to compute a crafting operation and create a ticket.
function packer.pack.craft_check_recipe(itemName, amount)
  return "craft_check_recipe," .. itemName .. "," .. amount
end
function packer.unpack.craft_check_recipe(data)
  local itemName = string.match(data, "[^,]*")
  local amount = string.sub(data, #itemName + 2)
  return itemName, tonumber(amount)
end

-- Request crafting to start a crafting operation.
function packer.pack.craft_recipe_start(ticket)
  return "craft_recipe_start," .. ticket
end
function packer.unpack.craft_recipe_start(data)
  return data
end

-- Request crafting to cancel a crafting operation.
function packer.pack.craft_recipe_cancel(ticket)
  return "craft_recipe_cancel," .. ticket
end
function packer.unpack.craft_recipe_cancel(data)
  return data
end

-- Crafting is reporting system has started up.
function packer.pack.craft_started()
  return "craft_started,"
end
function packer.unpack.craft_started(data)
  return nil
end

-- Crafting is reporting the available craftable items from the recipes table.
function packer.pack.craft_recipe_list(recipeItems)
  return "craft_recipe_list," .. serialization.serialize(recipeItems)
end
function packer.unpack.craft_recipe_list(data)
  local recipeItems = serialization.unserialize(data)
  return recipeItems
end

-- Crafting is reporting "success" or "missing items" results from a recent
-- craft_recipe_start request.
function packer.pack.craft_recipe_confirm(ticket, craftProgress)
  return "craft_recipe_confirm," .. ticket .. ";" .. serialization.serialize(craftProgress)
end
function packer.unpack.craft_recipe_confirm(data)
  local ticket = string.match(data, "[^;]*")
  local craftProgress = serialization.unserialize(string.sub(data, #ticket + 2))
  return ticket, craftProgress
end

-- Crafting is reporting failure of a recent craft_recipe_start request, or a
-- running crafting operation.
function packer.pack.craft_recipe_error(ticket, errMessage)
  return "craft_recipe_error," .. ticket .. ";" .. errMessage
end
function packer.unpack.craft_recipe_error(data)
  local ticket = string.match(data, "[^;]*")
  local errMessage = string.sub(data, #ticket + 2)
  return ticket, errMessage
end



-- Request drone to run a software update.
function packer.pack.drone_upload(sourceCode)
  return "drone_upload," .. sourceCode
end
function packer.unpack.drone_upload(data)
  return data
end

-- Drone is reporting system has started up.
function packer.pack.drone_started()
  return "drone_started,"
end
function packer.unpack.drone_started(data)
  return nil
end

-- Drone is reporting compile/runtime error.
function packer.pack.drone_error(errType, errMessage)
  return "drone_error," .. errType .. "," .. errMessage
end
function packer.unpack.drone_error(data)
  local errType = string.match(data, "[^,]*")
  local errMessage = string.sub(data, #errType + 2)
  return errType, errMessage
end



-- Request robot to run a software update (run program or cache library code).
function packer.pack.robot_upload(libName, srcCode)
  return "robot_upload," .. libName .. "," .. srcCode
end
function packer.unpack.robot_upload(data)
  local libName = string.match(data, "[^,]*")
  local srcCode = string.sub(data, #libName + 2)
  return libName, srcCode
end

-- Request robot to run a firmware update.
function packer.pack.robot_upload_eeprom(srcCode)
  return "robot_upload_eeprom," .. srcCode
end
function packer.unpack.robot_upload_eeprom(data)
  return data
end

-- Request robot to run a line of code (for debugging purposes).
function packer.pack.robot_upload_rlua(srcCode)
  return "robot_upload_rlua," .. srcCode
end
function packer.unpack.robot_upload_rlua(data)
  return data
end

-- Request robot to scan adjacent inventories for target item.
function packer.pack.robot_scan_adjacent(itemName, slotNum)
  return "robot_scan_adjacent," .. itemName .. "," .. slotNum
end
function packer.unpack.robot_scan_adjacent(data)
  local itemName = string.match(data, "[^,]*")
  local slotNum = string.sub(data, #itemName + 2)
  return itemName, tonumber(slotNum)
end

-- Request robot to prepare to craft a number of items.
function packer.pack.robot_prepare_craft(craftingTask)
  return "robot_prepare_craft," .. serialization.serialize(craftingTask)
end
function packer.unpack.robot_prepare_craft(data)
  local craftingTask = serialization.unserialize(data)
  return craftingTask
end

-- Request robot to start a pending crafting request.
function packer.pack.robot_start_craft()
  return "robot_start_craft,"
end
function packer.unpack.robot_start_craft(data)
  return nil
end

-- Request robot to exit software (return to firmware loop).
function packer.pack.robot_halt()
  return "robot_halt,"
end
function packer.unpack.robot_halt(data)
  return nil
end

-- Robot is reporting system has started up.
function packer.pack.robot_started()
  return "robot_started,"
end
function packer.unpack.robot_started(data)
  return nil
end

-- Robot is reporting result of rlua execution.
function packer.pack.robot_upload_rlua_result(message)
  return "robot_upload_rlua_result," .. message
end
function packer.unpack.robot_upload_rlua_result(data)
  return data
end

-- Robot is reporting result of request to scan adjacent inventories.
function packer.pack.robot_scan_adjacent_result(foundSide)
  return "robot_scan_adjacent_result," .. tostring(foundSide)
end
function packer.unpack.robot_scan_adjacent_result(data)
  return tonumber(data)
end

-- Robot is reporting result of crafting request.
function packer.pack.robot_finished_craft(ticket, taskID)
  return "robot_finished_craft," .. ticket .. ";" .. tostring(taskID)
end
function packer.unpack.robot_finished_craft(data)
  local ticket = string.match(data, "[^;]*")
  local taskID = string.sub(data, #ticket + 2)
  return ticket, tonumber(taskID)
end

-- Robot is reporting compile/runtime error.
function packer.pack.robot_error(errType, errMessage)
  return "robot_error," .. errType .. "," .. errMessage
end
function packer.unpack.robot_error(data)
  local errType = string.match(data, "[^,]*")
  local errMessage = string.sub(data, #errType + 2)
  return errType, errMessage
end



return packer
