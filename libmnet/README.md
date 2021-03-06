## mnet.lua

Mesh networking protocol with minimalistic API.

The mnet protocol stack covers layers 3 and 4 of the OSI model and is designed for general purpose mesh networking using reliable or unreliable communication (much like TCP and UDP). The interface is kept as simple as possible for performance and to allow embedded devices with a small EEPROM to run it. Much of the inspiration for mnet came from minitel: https://github.com/ShadowKatStudios/OC-Minitel

Key features:

* Supports unicast, routed, reliable, in-order, arbitrary-length messages.
* Supports unicast/broadcast, routed, unreliable, arbitrary-length messages.
* Automatic configuration of routes.
* No background service to handle packets keeps things simple and fast.
* Minified version runs on embedded hardware like drones and microcontrollers.

Limitations:

* Hostnames are used as addresses, they must be unique (no DNS or DHCP).
* No congestion control, the network can get overloaded in extreme cases.
* No loopback interface (machine cannot send messages to itself).

Each message consists of a string sent to a target host (or broadcasted to all hosts in the network) and a virtual port. The virtual port is used to specify which process on the host the message is intended for. All messages are sent over the modem using a common port number `mnet.port`. This hardware port number can be changed to separate networks with overlapping range.

When sending a message, there is a choice between reliable transfer and unreliable transfer. With the reliable option, the sender expects the message to be acknowledged to confirm successful transmission. The sender will retransmit the message until an "ack" is received, or the message may time out (see mnet configuration options). When unreliable is used, the message will only be sent once and the receiver will not send an "ack" back to the sender. This can reduce latency, but the message may not be received or it might arrive in a different order. One thing to note is that there is no interface to establish a connection for reliable messaging. Connections are managed internally by mnet and are allowed to persist forever (no "keepalive" like we have in TCP).

For both reliable and unreliable transmission, if the message size is larger than the maximum transmission unit the modem supports (default is 8192) then it will be fragmented. A fragmented message gets split into multiple packets and sent one at a time, then they are recombined into the full message on the receiving end. This means there is no worry about sending a message with too much data.

Routing in mnet is very simple and in practice roughly mimics shortest path first algorithm. When a packet needs to be sent to a receiver, the address of the modem to forward it to may be unknown (and we may need to broadcast the packet to everyone). However, the address it came from is known so we will remember which way to send the next one destined for that sender. When combined with reliable messaging, a single message and "ack" pair will populate the routing cache with the current best route between the two hosts (assuming all routing hosts are processing packets at the same rate).

Example usage:
```lua
-- Send a message.
mnet.send("my_target_host", 123, "hello remote host on port 123!", true)

-- Receive messages (preferably done within a thread to run in the background).
-- This should be run even if received messages will be ignored.
local listenerThread = thread.create(function()
  while true do
    local host, port, message = mnet.receive(0.1)
    if message then
      -- Do something with the message, such as parsing the string data to check
      -- for a specific command or pass it to RPC.
    end
  end
end)
```

## mrpc.lua

Remote procedure calls for mnet.

The mrpc module can be used to create RPC servers that manage incoming and outgoing requests to run functions on a remote system. Multiple server instances can run on one machine, as long as each one is using a unique port number (same as the virtual port in mnet). There is also support for synchronous and asynchronous calls. Synchronous calls will block the current process while waiting for the remote call to finish execution and return results (more like traditional RPC). Asynchronous calls do not block, and therefore have some performance benefits. The downside of using async is that the results of the remote function are not returned. However, this can be resolved by having the receiving side run an async call with the results back to the original sender.

When setting up the RPC server, function declarations must be given before a remote call can be issued. It is required to specify the "call names" that can be used, and optional to specify the expected arguments and return values. This requirement is put in place to encourage the user to define a common interface of the remote calls that an RPC server accepts. It's best to put this interface in a separate Lua script and use `MrpcServer.addDeclarations()` to pull it in.

> **Warning**
> 
> It is not advised to save a reference to the functions returned by addressing a call name (such as from `MrpcServer.sync.<call name>`). The function context is only valid during indexing from the `MrpcServer` instance because of the way that metatables are used to cache state.

> **Note**
> 
> Be careful when binding functions that take a long time to process. Running them in the same thread as `mnet.receive()` can block handling of other network messages. One option to prevent this is to run the slow functions in a separate thread and pass results from `mnet.receive()` over a queue.

Most of this code was adapted from the old packer.lua module. The packer module was an early RPC prototype and was independent from the underlying network protocol (wnet at the time). This was great for modularity, but packer also had functions registered in a global table and an ugly call syntax.

Example usage:
```lua
-- Create server on port 1024.
local mrpc_server = mrpc.newServer(1024)

-- Declare function say_hello.
mrpc_server.declareFunction("say_hello", {
  "senderMessage", "string",
  "extraData", "any",
})

-- Register function to run when we receive a say_hello request.
mrpc_server.functions.say_hello = function(obj, host, senderMessage, extraData)
  print("Hello from " .. host .. ": " .. senderMessage)
  print(tostring(extraData))
end

-- Request other active servers to run say_hello.
mrpc_server.async.say_hello("*", "anyone out there?", {"extra", "data"})
print("Sent request to run say_hello on other servers.")

-- Respond to requests from other servers.
local listenerThread = thread.create(function()
  while true do
    local host, port, message = mnet.receive(0.1)
    mrpc_server.handleMessage(nil, host, port, message)
  end
end)
```
