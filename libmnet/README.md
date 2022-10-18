# mnet.lua

Mesh networking protocol with minimalistic API.

The mnet protocol stack covers layers 3 and 4 of the OSI model and is designed for general purpose mesh networking using reliable or unreliable communication (much like TCP and UDP). The interface is kept as simple as possible for performance and to allow embedded devices with a small EEPROM to run it. Much of the inspiration for mnet came from minitel: https://github.com/ShadowKatStudios/OC-Minitel

### Key features

* Supports unicast, routed, reliable, in-order, arbitrary-length messages.
* Supports unicast/broadcast, routed, unreliable, arbitrary-length messages.
* Automatic configuration of routes.
* No background service to handle packets keeps things simple and fast.
* Minified version runs on embedded hardware like drones and microcontrollers.
* Loopback interface.
* Static routes can be configured.
* Supports wired/wireless cards and linked cards, in addition to custom communication devices.

### Limitations

* Hostnames are used as addresses, they must be unique (no DNS or DHCP built in).
* No congestion control, the network can get overloaded in extreme cases.

### How it works

Each message consists of a string sent to a target host (or broadcasted to all hosts in the network) and a virtual port. The virtual port is used to specify which process on the host the message is intended for. All messages are sent over the modem using a common port number `mnet.port` (port 2048 by default). This hardware port number can be changed to separate networks with overlapping range.

> **Note**
> 
> If changing `mnet.port` after mnet is loaded, you should iterate `mnet.getDevices()` to close the old port and open the new one.

When sending a message, there is a choice between reliable transfer and unreliable transfer. With the reliable option, the sender expects the message to be acknowledged to confirm successful transmission. The sender will retransmit the message until an "ack" is received, or the message may time out (see mnet configuration options). When unreliable is used, the message will only be sent once and the receiver will not send an "ack" back to the sender. This can reduce latency, but the message may not be received or it might arrive in a different order. One thing to note is that there is no interface to establish a connection for reliable messaging. Connections are managed internally by mnet and are allowed to persist forever (no "keepalive" like we have in TCP).

For both reliable and unreliable transmission, if the message size is larger than the maximum transmission unit the modem supports (default is 8192) then it will be fragmented. A fragmented message gets split into multiple packets and sent one at a time, then they are recombined on the receiving end and the full message is returned. This means there is no worry about sending a message with too much data.

Packets are composed of 7 fields, see the table below for details:

| Field    | Type    | Description |
| -------- | ------- | ----------- |
| id       | number  | A unique identifier for the packet (used to prevent feedback loop in routing) generated from a random number in range \[0, 1). It's theoretically possible for the number to not be unique, but this just results with a dropped packet. |
| sequence | integer | Sequences start as a random positive integer and are specific to each host (along with reliable/unreliable protocol). The value increases by one for each message sent. Similar to TCP sequence, but also used for unreliable protocol to identify fragment ordering. |
| flags    | string  | List of letter-number pairs. Options are 's' for synchronize (begin new connection), 'r' for requires acknowledgment, 'a' for acknowledged, or 'f' for fragment count/more fragments. |
| dest     | string  | Hostname of the target host the packet should go to. |
| src      | string  | Hostname of the sender. |
| port     | integer | Virtual port number (which process on the target host the message is intended for). |
| message  | string  | The message data, or a fragment of the whole if the MTU size would be exceeded. |

Routing in mnet is very simple and in practice roughly mimics shortest path first algorithm. When a packet needs to be sent to a receiver, the address of the modem to forward it to may be unknown (and we may need to broadcast the packet to everyone). However, the address it came from is known so we will remember which way to send the next one destined for that sender. When combined with reliable messaging, a single message and "ack" pair will populate the routing cache with the current best route between the two hosts (assuming all routing hosts are processing packets at the same rate).

Note that there are significant differences between the version of mnet that runs on OpenOS and the minified version for embedded systems. Specifically, only `mnet.send()` and `mnet.receive()` are available for the latter. This is because the minified version is designed to fit onto a tiny 4KB EEPROM, so a lot of optional features are stripped out. Since mnet is compiled into these different versions using [simple_preprocess](../simple_preprocess), it's very easy to build your own version by setting the preprocessor flags for only the features you need. These are the available flags: `OPEN_OS`, `USE_DLOG`, `EXPERIMENTAL_DEBUG`, `ENABLE_LINK_CARD`, `ENABLE_LOOPBACK`, `ENABLE_STATIC_ROUTES`. See the Bakefile for an example.

### API

<!-- SIMPLE-DOC:START (FILE:../libmnet/mnet_src.lua) -->
* `mnet.hostname = <env HOSTNAME or first 8 characters of computer address>`
  
  Unique address for the machine running this instance of mnet. Do not set this
  to the string `*` (asterisk is the broadcast address).

* `mnet.port = 2048`
  
  Common hardware port used by all hosts in this network.

* `mnet.route = true`
  
  Enables forwarding of packets to other hosts (packets with a different
  destination than `mnet.hostname`). Can be disabled for network nodes that
  function as endpoints.

* `mnet.routeTime = 30`
  
  Time in seconds for entries in the routing cache to persist (set this longer
  for static networks and shorter for dynamically changing ones).

* `mnet.retransmitTime = 3`
  
  Time in seconds for reliable messages to be retransmitted while no "ack" is
  received.

* `mnet.dropTime = 12`
  
  Time in seconds until packets in the cache are dropped or reliable messages
  time out.

* `mnet.registerDevice(address: string[, proxy: table]): table|nil`
  
  Adds a device that mnet can use for communication with other hosts in the
  network. Usually, the address should be the component address of a modem
  (wired/wireless card) or tunnel (linked card) plugged into the machine and
  proxy should be left as nil. To add a custom device for communication, a
  proxy table should be provided (must implement the functions `open()`,
  `close()`, `send()`, and `broadcast()` much like the modem component) with an
  address that is not currently in use. The custom communication device must
  also push a `modem_message` signal when data is received. Returns the proxy
  object for the device, or nil if the address does not point to a valid
  network device.

* `mnet.getDevices(): table`
  
  Returns the table of registered network devices that mnet is using. The keys
  in the table are string addresses and values are proxy objects, like in
  `mnet.registerDevice()`. When mnet first loads, this table is initialized
  with all wired/wireless/linked cards plugged in to the machine.
  
  To allow hot swapping network cards while mnet is running, make a call to
  `mnet.getDevices()[address] = nil` on `component_removed` signals and call
  `mnet.registerDevice(address)` on `component_added` signals.

* `mnet.debugEnableLossy(lossy: boolean)`
  
  **For debugging usage only.**<br>
  Sets lossy mode for packet transmission. This hooks into each network
  interface in the modems table and overrides `modem.send()` and
  `modem.broadcast()` to have a percent chance to drop (delete) or swap the
  ordering of a packet during transmit. This mimics real behavior of wireless
  packet transfer when the receiver is close to the maximum range of the
  wireless transmitter. Packets can also arrive in a different order than the
  order they are sent in large networks where routing paths are frequently
  changing. This is purely for testing the performance and correctness of mnet.

* `mnet.debugSetSmallMTU(b: boolean)`
  
  **For debugging usage only.**<br>
  Sets small MTU mode for testing how mnet behaves when a message is fragmented
  into many small pieces.

* `mnet.getStaticRoutes(): table`
  
  Returns the static routes table for getting/setting a route. A static route
  specifies which network interface on the local and remote sides to use when
  sending a packet to a specific host. Each entry in the static routes table
  has a hostname key and table value, where the value stores the network
  interface address for the local and remote devices (keys 1 and 2
  respectively). The special hostname `*` can be used to route all packets
  through a specific network interface (other static routes will still take
  priority). The `*` static route will disable automatic routing behavior and
  broadcast messages will be sent only to the specified interface.
  
  Example:
  ```lua
  -- Route all packets (besides broadcast) going to host123 through modem at
  -- "0a19..." to remote "d2c6..." (need to use the full address).
  mnet.getStaticRoutes()["host123"] = {"0a19...", "d2c6..."}
  ```

* `mnet.send(host: string, port: number, message: string, reliable: boolean[,
    waitForAck: boolean]): string|nil`
  
  Sends a message with a virtual port number to another host in the network.
  The message can be any length and contain binary data. The host `*` can be
  used to broadcast the message to all other hosts (reliable must be set to
  false in this case). The host `localhost` or `mnet.hostname` allow the
  machine to send a message to itself (loopback interface).
  
  When reliable is true, this function returns a string concatenating the host
  and last used sequence number separated by a comma (the host also begins with
  an `r` or `u` character indicating reliability, like `rHOST,SEQUENCE`). The
  sent message is expected to be acknowledged in this case (think TCP). When
  reliable is false, nil is returned and no "ack" is expected (think UDP). If
  reliable and waitForAck are true, this function will block until the "ack" is
  received or the message times out (nil is returned if it timed out).

* `mnet.receive(timeout: number[, connectionLostCallback: function]): nil |
    (string, number, string)`<br>
  *On embedded systems, pass an event (in a table) instead of timeout:*<br>
  `mnet.receive(ev: table[, connectionLostCallback: function]): nil |
    (string, number, string)`
  
  Pulls events up to the timeout duration and returns the sender host, virtual
  port, and message if any data destined for this host was received. The
  connectionLostCallback is used to catch reliable messages that failed to send
  from this host. If provided, the function is called with a string
  host-sequence pair, a virtual port number, and string fragment. The
  host-sequence pair corresponds to the return values from `mnet.send()`. Note
  that the host in this pair has an `r` character prefix, and the sequence
  number will only match a previous return value from `mnet.send()` if it
  corresponds to the last fragment of the original message.
<!-- SIMPLE-DOC:END -->

### Example usage

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

# mrpc.lua

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

### API

<!-- SIMPLE-DOC:START (FILE:../libmnet/mrpc.lua) -->
* `mrpc.newServer(port: number[, allowDuplicatePorts: boolean]): table`
  
  Creates a new instance of an RPC server with a given port number. This server
  is used for both requesting functions to run on a remote machine (and
  optionally get return values back), and handling function call requests from
  other machines. Once a server has been created on the sender and receiver
  (with same port number), a remote call defined on both sides, and a function
  bound on the receiving end, the sender can start sending requests to the
  receiver.
  
  New servers are added as listeners of network messages and all of them
  respond to `mrpc.handleMessage()`. For this reason, the port chosen should be
  unique so that servers do not conflict. For example, two servers with the
  same port running on the same machine (potentially from different programs)
  could define the same RPC function names, resulting in undefined behavior. To
  disable safety checks for this, set `allowDuplicatePorts` to true. When a
  server gets garbage collected it is automatically removed from the listeners,
  but it is good practice to call `MrpcServer.destroy()` when finished using
  the server.
  
  Note that the object this function returns is an instance of `MrpcServer`,
  and unlike most class designs the methods are invoked with a dot instead of
  colon operator (this enables the syntax with the sync and async methods).

* `mrpc.handleMessage(obj: any[, host: string, port: number,
    message: string]): boolean`
  
  When called with the results of `mnet.receive()`, checks if the port and
  message match an incoming request to run a function (or results from a sent
  request). If the message is requesting to run a function and the matching
  function has been assigned to `MrpcServer.functions.<call name>`, it is
  called with obj, host, and all of the sent arguments. The obj argument should
  be used if the bound function is a class member. Otherwise, nil can be passed
  for obj and the first argument in the function can be ignored. Returns true
  if the message was handled by any listening servers, or false if not.

* `MrpcServer.sync.<call name>(host: string, ...): ...`
  
  Requests the given host to run a function call with the given arguments. The
  host must not be the broadcast address. As this is the synchronous version,
  the function will block the current process until return values are received
  from the remote host or the request times out. Any other synchronous calls
  made to this `MrpcServer` instance in other threads will wait their turn to
  run. Returns the results from the remote function call, or throws an error if
  request timed out (or other error occurred).

* `MrpcServer.async.<call name>(host: string, ...): string`
  
  Similar to `MrpcServer.sync`, requests the given host(s) to run a function
  call with the given arguments. The host can be the broadcast address. This
  asynchronous version will not block the current process but also does not
  return the results of the remote call. This internally uses the reliable
  message protocol in mnet, so async calls are guaranteed to arrive in the same
  order they were sent (even alternating sync and async calls guarantees
  in-order delivery). Returns the host-sequence pair of the sent message (can
  be used to check for connection failure, see mnet for details).

* `MrpcServer.unpack.<call name>(message: string): ...`
  
  Helper function that deserializes the given RPC formatted message to extract
  the arguments. The message format is `<type>,<call name>{<packed table>}`
  where type is either `s`, `a`, or `r` (for sync, async, and results), call
  name is the name bound to the function call, and packed table is a serialized
  table of the arguments with key `n` storing the total.

* `MrpcServer.declareFunction(callName: string, arguments: table|nil,
    results: table|nil)`
  
  Specifies a function declaration and optionally the expected data types for
  arguments and return values. A function needs to be declared the same way on
  two machines before one can call the function on the other. The callName
  specifies the name bound to the function. If the arguments and results are
  provided, they should each be a sequence with the format {name1: string,
  types1: string, ...} where name1 is the first parameter name (purely for
  making it clear what the value represents) and types1 is a comma-separated
  list of accepted types (or the string `any`).

* `MrpcServer.addDeclarations(declarationMap: table)`
  
  Iterates a table and calls `MrpcServer.declareFunction()` for each entry.
  Each key in declarationMap should be the call name of the function to declare
  and the value should be another table containing the same arguments and
  results tables that would be passed to `MrpcServer.declareFunction()`. The
  intended way to use this is create a Lua script that returns the
  declarationMap table, then use `dofile()` to pass it into this function.

* `MrpcServer.handleMessage(obj: any[, host: string, port: number,
    message: string]): boolean`
  
  Alias for `mrpc.handleMessage()`, either function can be used.

* `MrpcServer.destroy()`
  
  Stops the RPC server instance from responding to network messages (this frees
  the port the server was using). Ideally, this should be called every time a
  server is finished running instead of assuming that garbage collection will
  delete it in a timely fashion.
<!-- SIMPLE-DOC:END -->

### Example usage

```lua
-- Create server on port 530.
local mrpc_server = mrpc.newServer(530)

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
