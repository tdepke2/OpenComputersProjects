--------------------------------------------------------------------------------
-- Common functions for item handling.
-- 
-- @author tdepke2
--------------------------------------------------------------------------------


local component = require("component")
-- Check for optional dependencies component.robot and component.inventory_controller.
local crobot = component.isAvailable("robot") and component.robot or nil
local icontroller = component.isAvailable("inventory_controller") and component.inventory_controller or nil

local itemutil = {}

---@alias ItemFullName string

-- Get the unique identifier of an item (internal name and metadata). This is
-- used for table indexing of items and such. Note that items with different NBT
-- can still resolve to the same identifier.
-- 
-- The resulting name has the pattern:
-- `<mod name>:<item id name>/<metadata number>[n]`.
-- For example, `minecraft:iron_pickaxe/0n` is an enchanted iron pickaxe with
-- full durability.
-- 
---@param item Item
---@return ItemFullName itemName
---@nodiscard
function itemutil.getItemFullName(item)
  return item.name .. "/" .. math.floor(item.damage) .. (item.hasTag and "n" or "")
end

-- FIXME getItemFullName() used elsewhere should be replaced with this one ##########################################
-- FIXME these are the real iterators that should be used in storage.lua and related! still need to check if skipping empty is valid in the use cases there, and also the item/slot are swapped around. ####################################################################################################

-- Iterator wrapper for the itemIter returned from `icontroller.getAllStacks()`.
-- Returns the current slot number and item with each call, skipping over empty
-- slots.
-- 
---@param itemIter fun():Item
---@return fun(itemIter: function, slot: integer):integer, Item
---@return fun():Item
---@return integer
---@nodiscard
function itemutil.invIterator(itemIter)
  local function iter(itemIter, slot)
    slot = slot + 1
    local item = itemIter()
    while item do
      if next(item) ~= nil then
        return slot, item
      end
      slot = slot + 1
      item = itemIter()
    end
  end
  
  return iter, itemIter, 0
end


-- Iterator wrapper similar to invIterator(), but does not skip empty slots.
-- Returns the current slot number and item with each call.
-- 
---@param itemIter fun():Item
---@return fun(itemIter: function, slot: integer):integer, Item
---@return fun():Item
---@return integer
---@nodiscard
function itemutil.invIteratorNoSkip(itemIter)
  local function iter(itemIter, slot)
    slot = slot + 1
    local item = itemIter()
    if item then
      return slot, item
    end
  end
  
  return iter, itemIter, 0
end


-- Iterator for scanning a device's internal inventory. For efficiency reasons,
-- the inventory size is passed in as this function blocks for a tick
-- (getStackInInternalSlot() is blocking too). Returns the current slot and item
-- with each call, skipping over empty slots.
-- 
---@param invSize number
---@return fun(invSize: number, slot: integer):integer, Item
---@return number
---@return integer
---@nodiscard
function itemutil.internalInvIterator(invSize)
  local function iter(invSize, slot)
    local item
    while slot < invSize do
      slot = slot + 1
      if crobot.count(slot) > 0 then
        item = icontroller.getStackInInternalSlot(slot)
        if item then
          return slot, item
        end
      end
    end
  end
  
  return iter, invSize, 0
end

return itemutil
