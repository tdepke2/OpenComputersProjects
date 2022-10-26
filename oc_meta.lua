-- Definitions for classes and types in OpenComputers. This code is not executed
-- by programs here, but is provided for Lua Language Server
-- (https://github.com/sumneko/lua-language-server).
-- 
-- A bunch of these definitions are pulled straight from the OC docs, see:
-- https://ocdoc.cil.li/api:non-standard-lua-libs
-- 
---@meta


-- Returns the value of the process environment.
-- 
-- [View documents](http://www.lua.org/manual/5.3/manual.html#pdf-os.getenv)
-- 
---@return string?
function os.getenv() end


-- Allows pausing a script for the specified amount of time. `os.sleep` consumes
-- events but registered event handlers and threads are still receiving events
-- during the sleep. Rephrased, signals will still be processed by event
-- handlers while the sleep is active, i.e. you cannot pull signals that were
-- accumulated during the sleep after it ended, since no signals will remain in
-- the queue (or at least not all of them).
-- 
---@param seconds number
function os.sleep(seconds) end


-- Item structure: https://ocdoc.cil.li/component:inventory_controller
-- 
---@class Item              Data about an item as provided by the inventory_controller component.
---@field damage number     The current damage value of the item.
---@field maxDamage number  The maximum damage this item can have before it breaks.
---@field size number       The current stack size of the item.
---@field maxSize number    The maximum stack size of this item.
---@field name string       The untranslated item name, which is an internal Minecraft value like `oc:item.FloppyDisk`.
---@field label string      The translated item name.
---@field hasTag boolean    Whether or not the item has an NBT tag associated with it.


-- Sides API: https://ocdoc.cil.li/api:sides
-- 
---@alias Sides
---| '0' # bottom, down,  negy
---| '1' # top,    up,    posy
---| '2' # back,   north, negz
---| '3' # front,  south, posz, forward
---| '4' # right,  west,  negx
---| '5' # left,   east,  posx
