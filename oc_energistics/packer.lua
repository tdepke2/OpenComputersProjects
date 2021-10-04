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





FIXME need to refactor wnet to be more consistent with the message = header + data thing (maybe look back at wnet.waitReceive too, should this return message as one thing?) ###################################################
--]]

local serialization = require("serialization")

local dlog = require("dlog")

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
    dlog.out("packer", "No callback registered for header \"" .. key .. "\"")
    return nil
  end
})

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
  local header = string.match(message, "[^,]*")
  if packer.callbacks[header] then
    packer.callbacks[header](obj, address, port, packer.unpack[header](string.sub(message, #header + 2)))
  end
end



function packer.pack.stor_drone_insert(droneInvIndex, ticket)
  return "stor_drone_insert," .. droneInvIndex .. "," .. ticket
end

function packer.unpack.stor_drone_insert(data)
  local droneInvIndex = string.match(data, "[^,]*")
  local ticket = string.sub(data, #droneInvIndex + 2)
  droneInvIndex = tonumber(droneInvIndex)
  if ticket == "" then
    ticket = nil
  end
  return droneInvIndex, ticket
end



function packer.pack.stor_drone_extract(droneInvIndex, ticket, extractList)
  return "stor_drone_extract," .. droneInvIndex .. "," .. ticket .. ";" .. extractList
end

function packer.unpack.stor_drone_extract(data)
  local droneInvIndex = string.match(data, "[^,]*")
  local ticket = string.match(data, "[^;]*", #droneInvIndex + 2)
  local extractList = serialization.unserialize(string.sub(data, #droneInvIndex + #ticket + 3))
  droneInvIndex = tonumber(droneInvIndex)
  if ticket == "" then
    ticket = nil
  end
  return droneInvIndex, ticket, extractList
end

return packer
