--[[
Storage server application code.


--]]

local component = require("component")
local computer = require("computer")
local event = require("event")
local modem = component.modem
local rs = component.redstone
local serialization = require("serialization")
local sides = require("sides")
local text = require("text")
local thread = require("thread")

local common = require("common")
local dlog = require("dlog")
local wnet = require("wnet")

local COMMS_PORT = 0xE298
local ROUTING_CONFIG_FILENAME = "routing.config"
local INPUT_DELAY_SECONDS = 2

-- Load routing configuration and return a table indexing the transposers and
-- another table specifying the connections.
local function loadRoutingConfig(filename)
  dlog.checkArg(1, filename, "string")
  local transposers = {}
  local routing = {}
  routing.storage = {}
  routing.input = {}
  routing.output = {}
  routing.transfer = {}
  routing.drone = {}
  routing.transposer = {}
  
  -- Add the connections to the routing category for inventoryType.
  local function addToRouting(inventoryType, line)
    local connections = string.match(line, "\"[^\"]*\";%s*connections%s*=%s*([%d:,]+)")
    assert(connections, "Bad format for inventory name and connections")
    local routingInventory = routing[inventoryType]
    routingInventory[#routingInventory + 1] = {}
    local routingInventoryLast = routingInventory[#routingInventory]
    
    for transIndex, side in string.gmatch(connections, "(%d+):(%d+),") do
      transIndex = tonumber(transIndex)
      side = tonumber(side)
      routingInventoryLast[transIndex] = side
      routing.transposer[transIndex][inventoryType .. #routingInventory] = side
    end
    assert(next(routingInventoryLast) ~= nil, "Invalid connections format")
  end
  
  -- Use a coroutine to load the file.
  local co
  local function loadRoutingParser(line, lineNum)
    if not co then
      co = coroutine.create(function(line)
        -- Line "transposers:"
        assert(line == "transposers:", "Expected \"transposers:\"")
        line = coroutine.yield()
        while line ~= "storage:" do
          -- Line "<index> = <uuid>"
          local index, address = string.match(line, "(%d+)%s*=%s*([%w%-]+)")
          assert(index, "Bad format for index and UUID")
          assert(tonumber(index) == #transposers + 1, "Index is incorrect")
          local validatedAddress = component.get(address, "transposer")
          assert(validatedAddress, "Unable to find transposer " .. address)
          transposers[#transposers + 1] = component.proxy(validatedAddress)
          routing.transposer[#transposers] = {}
          line = coroutine.yield()
        end
        -- Line "storage:"
        assert(line == "storage:", "Expected \"storage:\"")
        line = coroutine.yield()
        while line ~= "input:" do
          addToRouting("storage", line)
          line = coroutine.yield()
        end
        assert(#routing.storage > 0, "Network must contain at least one storage inventory, ")
        -- Line "input:"
        assert(line == "input:", "Expected \"input:\"")
        line = coroutine.yield()
        while line ~= "output:" do
          addToRouting("input", line)
          line = coroutine.yield()
        end
        assert(#routing.input == 1, "Network must contain exactly one input inventory, ")
        -- Line "output:"
        assert(line == "output:", "Expected \"output:\"")
        line = coroutine.yield()
        while line ~= "transfer:" do
          addToRouting("output", line)
          line = coroutine.yield()
        end
        assert(#routing.output == 1, "Network must contain exactly one output inventory, ")
        -- Line "transfer:"
        assert(line == "transfer:", "Expected \"transfer:\"")
        line = coroutine.yield()
        while line ~= "drone:" do
          addToRouting("transfer", line)
          line = coroutine.yield()
        end
        -- Line "drone:"
        assert(line == "drone:", "Expected \"drone:\"")
        line = coroutine.yield()
        while line ~= "" do
          addToRouting("drone", line)
          line = coroutine.yield()
        end
        return
      end)
    elseif coroutine.status(co) == "dead" then
      assert(false, "Unexpected data at line " .. lineNum .. " of \"" .. filename .. "\".")
    end
    
    local status, msg = coroutine.resume(co, line)
    if not status then
      assert(false, msg .. " at line " .. lineNum .. " of \"" .. filename .. "\".")
    end
  end
  
  -- Open file and for each line trim whitespace, skip empty lines, and lines beginning with comment symbol '#'. Parse the rest.
  local file = io.open(filename, "r")
  if not file then
    return nil
  end
  local lineNum = 1
  for line in file:lines() do
    line = text.trim(line)
    if line ~= "" and string.byte(line, 1) ~= string.byte("#", 1) then
      loadRoutingParser(line, lineNum)
    end
    lineNum = lineNum + 1
  end
  file:close()
  
  loadRoutingParser("", lineNum)
  assert(coroutine.status(co) == "dead", "Missing some data, end of file \"" .. filename .. "\" reached.")
  
  return transposers, routing
end


-- Get the unique identifier of an item (internal name and metadata). This is
-- used for table indexing of items and such. Note that items with different NBT
-- can still resolve to the same identifier.
local function getItemFullName(item)
  dlog.checkArg(1, item, "table")
  return item.name .. "/" .. math.floor(item.damage) .. (item.hasTag and "n" or "")
end


-- Register the item stack with the storageItems table. If updateFirstEmpty is
-- true then set storageItems.data.firstEmptyIndex/Slot to the next empty slot found.
local function addStorageItems(transposers, routing, storageItems, invIndex, slot, item, amount, updateFirstEmpty)
  dlog.checkArg(1, transposers, "table", 2, routing, "table", 3, storageItems, "table", 4, invIndex, "number", 5, slot, "number", 6, item, "table", 7, amount, "number", 8, updateFirstEmpty, "boolean")
  --dlog.out("addStor", "addStorageItems(", transposers, routing, storageItems, invIndex, slot, item, amount, updateFirstEmpty, ")")
  -- If updateFirstEmpty then find the first empty slot in storage system after the current invIndex and slot.
  if updateFirstEmpty then
    storageItems.data.firstEmptyIndex = nil
    storageItems.data.firstEmptySlot = nil
    for invIndex2 = invIndex, #routing.storage do
      local transIndex, side = next(routing.storage[invIndex2])
      local itemIter = transposers[transIndex].getAllStacks(side)
      for slot2 = (invIndex2 == invIndex and slot or 1), transposers[transIndex].getInventorySize(side) do
        local item2 = itemIter[slot2]
        dlog.out("addStor", "Checking slot " .. slot2)
        if item2.size == 0 then
          dlog.out("addStor", "First empty changed to index " .. invIndex2 .. ", slot " .. slot2)
          storageItems.data.firstEmptyIndex = invIndex2
          storageItems.data.firstEmptySlot = slot2
          break
        end
      end
      if storageItems.data.firstEmptyIndex then
        break
      end
    end
  end
  
  if amount == 0 then
    dlog.out("addStor", "Amount is 0, done")
    return
  end
  
  -- Check if we need to cache the previous storage total.
  local fullName = getItemFullName(item)
  if storageItems.data.changes and not storageItems.data.changes[fullName] then
    storageItems.data.changes[fullName] = storageItems[fullName] and storageItems[fullName].total or 0
  end
  
  -- If item does not exist in table, add it. Otherwise update the existing entry.
  if not storageItems[fullName] then
    dlog.out("addStor", "Adding new storageItems entry")
    storageItems[fullName] = {}
    storageItems[fullName].maxDamage = math.floor(item.maxDamage)    -- Maximum damage this item can have.
    storageItems[fullName].maxSize = math.floor(item.maxSize)    -- Maximum stack size.
    --storageItems[fullName].id = item.id    -- Minecraft id of the item.
    storageItems[fullName].label = item.label    -- Translated item name.
    storageItems[fullName].total = amount
    storageItems[fullName].insertIndex = invIndex    -- First available place to insert items (the partial stack, could be a cache or regular inventory).
    storageItems[fullName].insertSlot = slot
    storageItems[fullName].checkedPartials = false    -- Whether the stacks (for this item type) after the initial insert index have been confirmed to reach their max size.
    storageItems[fullName].extractIndex = invIndex    -- Last available place to pull items (usually same index/slot as above, but not always).
    storageItems[fullName].extractSlot = slot
  else
    storageItems[fullName].total = storageItems[fullName].total + amount
    
    -- Update the insert/extract point to maintain the bounds. We do not update these locations if the item.size reaches the item.maxSize (because over-sized slots).
    if invIndex < storageItems[fullName].insertIndex or (invIndex == storageItems[fullName].insertIndex and slot < storageItems[fullName].insertSlot) then
      dlog.out("addStor", "Insert point changed to index " .. invIndex .. ", slot " .. slot)
      storageItems[fullName].insertIndex = invIndex
      storageItems[fullName].insertSlot = slot
    elseif invIndex > storageItems[fullName].extractIndex or (invIndex == storageItems[fullName].extractIndex and slot > storageItems[fullName].extractSlot) then
      dlog.out("addStor", "Extract point changed to index " .. invIndex .. ", slot " .. slot)
      storageItems[fullName].extractIndex = invIndex
      storageItems[fullName].extractSlot = slot
    end
  end
end


-- Remove the items from the storageItems table, and delete the item stack entry
-- in the table if applicable.
local function removeStorageItems(transposers, routing, storageItems, invIndex, slot, item, amount)
  dlog.checkArg(1, transposers, "table", 2, routing, "table", 3, storageItems, "table", 4, invIndex, "number", 5, slot, "number", 6, item, "table", 7, amount, "number")
  --dlog.out("removeStor", "removeStorageItems(", transposers, routing, storageItems, invIndex, slot, item, amount, ")")
  if amount == 0 then
    dlog.out("removeStor", "Amount is 0, done")
    return
  end
  
  -- Check if first empty slot has now moved to this invIndex/slot.
  local transIndex, side = next(routing.storage[invIndex])
  local itemsRemaining = transposers[transIndex].getSlotStackSize(side, slot)
  if itemsRemaining == 0 and (not storageItems.data.firstEmptyIndex or invIndex < storageItems.data.firstEmptyIndex or (invIndex == storageItems.data.firstEmptyIndex and slot < storageItems.data.firstEmptySlot)) then
    dlog.out("removeStor", "First empty changed to index " .. invIndex .. ", slot " .. slot)
    storageItems.data.firstEmptyIndex = invIndex
    storageItems.data.firstEmptySlot = slot
  end
  
  -- Check if we need to cache the previous storage total.
  local fullName = getItemFullName(item)
  if storageItems.data.changes and not storageItems.data.changes[fullName] then
    storageItems.data.changes[fullName] = storageItems[fullName].total
  end
  
  -- Update total and check if we can remove the table entry.
  storageItems[fullName].total = storageItems[fullName].total - amount
  if storageItems[fullName].total == 0 then    -- FIXME may want to change to <= after testing ####################################################
    dlog.out("removeStor", "Removing item entry for " .. fullName)
    storageItems[fullName] = nil
    return
  end
  
  -- If item stack empty, search for the next extract point and update insertion point if needed. Otherwise update bounds on insert/extract point.
  if itemsRemaining == 0 then
    dlog.out("removeStor", "itemsRemaining is zero, find next extract point")
    for invIndex2 = invIndex, 1, -1 do
      local transIndex, side = next(routing.storage[invIndex2])
      local itemIter = transposers[transIndex].getAllStacks(side)
      for slot2 = (invIndex2 == invIndex and slot or transposers[transIndex].getInventorySize(side)), 1, -1 do
        local item2 = itemIter[slot2]
        if item2.size > 0 and getItemFullName(item2) == fullName then
          dlog.out("removeStor", "Extract point changed to index " .. invIndex2 .. ", slot " .. slot2)
          storageItems[fullName].extractIndex = invIndex2
          storageItems[fullName].extractSlot = slot2
          if invIndex2 < storageItems[fullName].insertIndex or (invIndex2 == storageItems[fullName].insertIndex and slot2 < storageItems[fullName].insertSlot) then
            dlog.out("removeStor", "Insert point changed to index " .. invIndex2 .. ", slot " .. slot2)
            storageItems[fullName].insertIndex = invIndex2
            storageItems[fullName].insertSlot = slot2
          end
          return
        end
      end
    end
    assert(false, "removeStorageItems() failed: Unable to find next extractIndex/Slot in storage for " .. fullName)
  else
    if invIndex < storageItems[fullName].insertIndex or (invIndex == storageItems[fullName].insertIndex and slot < storageItems[fullName].insertSlot) then
      dlog.out("removeStor", "Insert point changed to index " .. invIndex .. ", slot " .. slot)
      storageItems[fullName].insertIndex = invIndex
      storageItems[fullName].insertSlot = slot
    end
    if invIndex < storageItems[fullName].extractIndex or (invIndex == storageItems[fullName].extractIndex and slot < storageItems[fullName].extractSlot) then
      dlog.out("removeStor", "Extract point changed to index " .. invIndex .. ", slot " .. slot)
      storageItems[fullName].extractIndex = invIndex
      storageItems[fullName].extractSlot = slot
    end
  end
end


-- Scan through the inventory at the type and index, and return total count of
-- the items found. Updates the storageItems table with details about the item
-- (max stack size, id, label, etc) including the total amount and where the
-- items are (insertion/extraction point, and first empty slot).
local function scanInventory(transposers, routing, storageItems, invType, invIndex)
  dlog.checkArg(1, transposers, "table", 2, routing, "table", 3, storageItems, "table", 4, invType, "string", 5, invIndex, "number")
  local numItemsFound = 0
  local transIndex, side = next(routing[invType][invIndex])
  local itemIter = transposers[transIndex].getAllStacks(side)
  local item = itemIter()
  local slot = 1
  while item do
    if next(item) ~= nil then
      local fullName = getItemFullName(item)
      addStorageItems(transposers, routing, storageItems, invIndex, slot, item, math.floor(item.size), false)
      numItemsFound = numItemsFound + math.floor(item.size)
    end
    item = itemIter()
    slot = slot + 1
  end
  
  return numItemsFound
end


-- FIXME: Probably just want this as a generic "unpack2Vals" function in common #################################################
-- Parse connection and return the transposer index and side as numbers.
local function unpackConnection(connection)
  dlog.checkArg(1, connection, "string")
  local transIndex, side = string.match(connection, "(%d+):(%d+)")
  return tonumber(transIndex), tonumber(side)
end


-- Transfers an item stack between any two locations in the storage network.
-- Returns the amount that was transferred (and name/slot of last inventory item
-- was in if not all of the items were sent). Amount can be nil (transfers whole
-- stack).
-- Note: It is an error to specify an amount greater than the number of items in
-- the source slot.
-- Example usage: routeItems(transposers, routing, "storage", 1, 1, "output", 1, 1, 64)
local function routeItems(transposers, routing, srcType, srcIndex, srcSlot, destType, destIndex, destSlot, amount)
  dlog.checkArg(1, transposers, "table", 2, routing, "table", 3, srcType, "string", 4, srcIndex, "number", 5, srcSlot, "number", 6, destType, "string", 7, destIndex, "number", 8, destSlot, "number")
  local srcInvName = srcType .. srcIndex
  local destInvName = destType .. destIndex
  local visitedTransfers = {}
  local transposerLinks = {}
  local endTransposerLink
  local searchQueue = common.Deque:new()
  
  if not amount then
    local transIndex, side = next(routing[srcType][srcIndex])
    amount = transposers[transIndex].getSlotStackSize(side, srcSlot)
  end
  if amount == 0 then
    return 0
  end
  
  -- Trivial case where the item is already in the destination.
  if srcInvName == destInvName then
    local transIndex, side = next(routing[srcType][srcIndex])
    local amountTransferred = math.floor(transposers[transIndex].transferItem(side, side, amount, srcSlot, destSlot))
    if amountTransferred ~= amount then
      return amountTransferred, srcInvName, srcSlot
    end
    return amountTransferred
  end
  
  -- Add the initial connections from the source inventory.
  for transIndex, side in pairs(routing[srcType][srcIndex]) do
    searchQueue:push_back({transIndex, side})
    transposerLinks[transIndex .. ":" .. side] = "s"    -- Add start links.
    dlog.out("routeItems", "Adding", transIndex, side)
  end
  
  -- Run breadth-first search to find destination.
  while not searchQueue:empty() do
    local transIndexFirst, sideFirst = table.unpack(searchQueue:front())
    searchQueue:pop_front()
    dlog.out("routeItems", "Got vals", transIndexFirst, sideFirst)
    
    -- From the current connection, check inventories that are adjacent to the transposer (except the one we started from).
    for invName, side in pairs(routing.transposer[transIndexFirst]) do
      if side ~= sideFirst then
        dlog.out("routeItems", "Checking", invName, side)
        if invName == destInvName then
          endTransposerLink = transIndexFirst .. ":" .. side
          transposerLinks[endTransposerLink] = transIndexFirst .. ":" .. sideFirst
          dlog.out("routeItems", "Found destination", invName, side)
          searchQueue:clear()
          break
        end
        
        -- Get the type and index of the inventory, and branch if it is a transfer type and has not yet been visited.
        local invType = string.match(invName, "%a+")
        local invIndex = tonumber(string.match(invName, "%d+"))
        if invType == "transfer" and not visitedTransfers[invIndex] then
          for transIndex2, side2 in pairs(routing.transfer[invIndex]) do
            if transIndex2 ~= transIndexFirst then
              searchQueue:push_back({transIndex2, side2})
              transposerLinks[transIndex2 .. ":" .. side2] = transIndexFirst .. ":" .. side
              dlog.out("routeItems", "Adding", transIndex2, side2)
            else
              transposerLinks[transIndex2 .. ":" .. side2] = transIndexFirst .. ":" .. sideFirst
            end
          end
          visitedTransfers[invIndex] = true
        end
      end
    end
  end
  
  assert(endTransposerLink, "Routing item from " .. srcInvName .. " to " .. destInvName .. " could not be determined, the routing table may be invalid.")
  
  -- Follow the links in transposerLinks to get back to the start, add these to a stack to reverse the ordering.
  local connectionStack = common.Deque:new()
  while endTransposerLink ~= "s" do
    connectionStack:push_front(endTransposerLink)
    endTransposerLink = transposerLinks[endTransposerLink]
  end
  
  -- Pop them back off the stack in the correct order, then transfer the items.
  local firstConnection = true
  local amountTransferred
  while not connectionStack:empty() do
    local transIndex = string.match(connectionStack:front(), "%d+")
    local srcSide = tonumber(string.match(connectionStack:front(), "%d+", #transIndex + 1))
    connectionStack:pop_front()
    local sinkSide = tonumber(string.match(connectionStack:front(), "%d+", #transIndex + 1))
    transIndex = tonumber(transIndex)
    connectionStack:pop_front()
    
    dlog.out("routeItems", transIndex .. " -> " .. srcSide .. ", " .. sinkSide)
    amountTransferred = math.floor(transposers[transIndex].transferItem(srcSide, sinkSide, amount, firstConnection and srcSlot or 1, connectionStack:empty() and destSlot or 1))
    
    
    -- Confirm that item moved, or if at the end lookup the inventory that the remaining items are now stuck in.
    if not connectionStack:empty() then
      assert(amountTransferred == amount)
    elseif amountTransferred ~= amount then
      for invName, side in pairs(routing.transposer[transIndex]) do
        if side == srcSide then
          return amountTransferred, invName, firstConnection and srcSlot or 1
        end
      end
    end
    firstConnection = false
  end
  
  return amountTransferred
end

-- fucking bitch lasagna, new plan:
--[[
Considered defragmentation algorithm:
  Would need to choose each item type in storage (going lowest-to-highest
  priority) and try-insert to each item slot for that type. Time complexity of
  this operation is not fun. Could be faster if it was possible to identify the
  max slot size in each inventory, oof.

Init:
  Insert_Point starts at first item stack (later, may or may not be first stack, but always less than/equal to Extract_Point).
  Extract_Point starts at last item stack (always stays at last one).
  Checked_Partials starts false.
  First_Empty starts at first empty slot (always stays at first one).

Insertion:
  First insert to Insert_Point.
  Then if not Checked_Partials, move Insert_Point down and try-insert while less than Extract_Point.
    If we get to the end, Checked_Partials goes to true.
  Then insert to First_Empty.
  Else, storage "full" (well, maybe, tell user to reboot system).

Extraction:
  First extract from Extract_Point.
  Then iterate back to first inventory and extract/update Extract_Point as we go.
--]]


-- Insert items into storage network. Proactively prevents storage fragmentation
-- by tracking the location of the "partial" stack and pushing here first (the
-- item stack with less than the max stack size). This means that storage
-- priority is not followed all the time, but we can avoid expensive
-- defragmentation algorithm as a trade-off. This function also considers cases
-- with special inventories, like ones with a single slot that store a lot of
-- items (drawers and void drawers).
-- Returns false if not all of the items could transfer, and the number of items
-- that did transfer. The srcSlot and amount can be nil.
local function insertStorage(transposers, routing, storageItems, srcType, srcIndex, srcSlot, amount)
  dlog.checkArg(1, transposers, "table", 2, routing, "table", 3, storageItems, "table", 4, srcType, "string", 5, srcIndex, "number")
  --dlog.out("insertStor", "insertStorage(", transposers, routing, storageItems, srcType, srcIndex, srcSlot, amount, ")")
  assert(srcType == "input" or srcType == "output" or srcType == "drone")
  local srcTransIndex, srcSide = next(routing[srcType][srcIndex])
  
  -- Find the first slot to choose as a source if not given.
  if not srcSlot then
    local itemIter = transposers[srcTransIndex].getAllStacks(srcSide)
    local item = itemIter()
    local slot = 1
    while item do
      if next(item) ~= nil then
        srcSlot = slot
        break
      end
      item = itemIter()
      slot = slot + 1
    end
    if not srcSlot then
      return true, 0
    end
    dlog.out("insertStor", "Found srcSlot = " .. srcSlot)
  end
  
  local srcItem = transposers[srcTransIndex].getStackInSlot(srcSide, srcSlot)
  if not srcItem then
    return false, 0
  end
  local srcFullName = getItemFullName(srcItem)
  -- Clamp amount to the current and max stack size, and use the item count for the amount if not specified.
  amount = math.floor(math.min(amount or srcItem.size, srcItem.maxSize))
  local originalAmount = amount
  local currType = srcType
  local currIndex = srcIndex
  local currSlot = srcSlot
  
  -- First, try to insert the items at the insertIndex if item exists in storage (could be full, could be an over-sized slot, etc).
  if storageItems[srcFullName] then
    dlog.out("insertStor", "First try insert point at " .. storageItems[srcFullName].insertIndex .. ", " .. storageItems[srcFullName].insertSlot)
    local amountTransferred, currInvName
    amountTransferred, currInvName, currSlot = routeItems(transposers, routing, currType, currIndex, currSlot, "storage", storageItems[srcFullName].insertIndex, storageItems[srcFullName].insertSlot, amount)
    
    addStorageItems(transposers, routing, storageItems, storageItems[srcFullName].insertIndex, storageItems[srcFullName].insertSlot, srcItem, amountTransferred, false)
    
    if amountTransferred == amount then
      return true, originalAmount
    end
    dlog.out("insertStor", "Oof, only transferred " .. amountTransferred .. " of " .. amount)
    amount = amount - amountTransferred
    currType = string.match(currInvName, "%a+")
    currIndex = tonumber(string.match(currInvName, "%d+"))
  end
  
  -- Second, try to insert items at the next available slot of the same type, until extract point reached. Skip if checkedPartials is true.
  if storageItems[srcFullName] and not storageItems[srcFullName].checkedPartials then
    dlog.out("insertStor", "Second try insert at next partial")
    for invIndex = storageItems[srcFullName].insertIndex, storageItems[srcFullName].extractIndex do
      local transIndex, side = next(routing.storage[invIndex])
      local itemIter = transposers[transIndex].getAllStacks(side)
      local slotStart = (invIndex == storageItems[srcFullName].insertIndex and storageItems[srcFullName].insertSlot + 1 or 1)
      local slotEnd = (invIndex == storageItems[srcFullName].extractIndex and storageItems[srcFullName].extractSlot or transposers[transIndex].getInventorySize(side))
      for slot = slotStart, slotEnd do
        local item = itemIter[slot]
        dlog.out("insertStor", "Checking " .. invIndex .. ", " .. slot)
        if item.size > 0 and getItemFullName(item) == srcFullName then    -- Check if we can add to existing stack. Items may still fail to move here.
          dlog.out("insertStor", "Found potential partial slot for " .. srcFullName)
          local amountTransferred, currInvName
          amountTransferred, currInvName, currSlot = routeItems(transposers, routing, currType, currIndex, currSlot, "storage", invIndex, slot, amount)
          
          addStorageItems(transposers, routing, storageItems, invIndex, slot, item, amountTransferred, false)
          
          if amountTransferred == amount then
            storageItems[srcFullName].insertIndex = invIndex
            storageItems[srcFullName].insertSlot = slot
            return true, originalAmount
          end
          dlog.out("insertStor", "Oof, only transferred " .. amountTransferred .. " of " .. amount)
          amount = amount - amountTransferred
          currType = string.match(currInvName, "%a+")
          currIndex = tonumber(string.match(currInvName, "%d+"))
        end
      end
    end
    storageItems[srcFullName].checkedPartials = true
  end
  
  -- Third, try to insert items at the firstEmptyIndex.
  if storageItems.data.firstEmptyIndex then
    dlog.out("insertStor", "Third try first empty at " .. storageItems.data.firstEmptyIndex .. ", " .. storageItems.data.firstEmptySlot)
    
    assert(routeItems(transposers, routing, currType, currIndex, currSlot, "storage", storageItems.data.firstEmptyIndex, storageItems.data.firstEmptySlot, amount) == amount)
    
    if storageItems[srcFullName] then
      storageItems[srcFullName].insertIndex = storageItems.data.firstEmptyIndex
      storageItems[srcFullName].insertSlot = storageItems.data.firstEmptySlot
    end
    
    addStorageItems(transposers, routing, storageItems, storageItems.data.firstEmptyIndex, storageItems.data.firstEmptySlot, srcItem, amount, true)
    
    return true, originalAmount
  end
  
  -- Route any stuck items back to where they came from.
  dlog.out("insertStor", "Routing stuck items back from " .. currType .. currIndex .. ":" .. currSlot)
  local currInvName
  _, currInvName, currSlot = routeItems(transposers, routing, currType, currIndex, currSlot, srcType, srcIndex, srcSlot)
  if currInvName and currIndex ~= srcIndex then
    currType = string.match(currInvName, "%a+")
    currIndex = tonumber(string.match(currInvName, "%d+"))
    
    local itemIter = transposers[srcTransIndex].getAllStacks(srcSide)
    local item = itemIter()
    local slot = 1
    while item do
      if next(item) == nil then
        assert(routeItems(transposers, routing, currType, currIndex, currSlot, srcType, srcIndex, slot) == amount, "Failed to transfer items back to source location.")
        break
      end
      item = itemIter()
      slot = slot + 1
    end
  end
  return false, originalAmount - amount
end


-- Extract items from storage network. Just like insertStorage() this also
-- follows rules for fragmentation prevention.
-- Returns false if some items failed to extract, and the amount that was
-- extracted. Requesting over a stack of items is not an error, but only the
-- amount up to the stack size will be given. The destSlot, itemName, amount,
-- and reservedItems can be nil. If reserved items are specified, the storage
-- will purposefully fail to extract these items.
local function extractStorage(transposers, routing, storageItems, destType, destIndex, destSlot, itemName, amount, reservedItems)
  dlog.checkArg(1, transposers, "table", 2, routing, "table", 3, storageItems, "table", 4, destType, "string", 5, destIndex, "number")
  --dlog.out("extractStor", "extractStorage(", transposers, routing, storageItems, destType, destIndex, destSlot, itemName, amount, ")")
  assert(destType == "input" or destType == "output" or destType == "drone")
  if not itemName then
    for itemName2, itemDetails in pairs(storageItems) do
      if itemName2 ~= "data" then
        itemName = itemName2
        break
      end
    end
  end
  if not storageItems[itemName] then
    return false, 0
  end
  
  -- Find amount available taking into account the reservedItems if provided. If this amount is less than the amount asked for, we reduce it.
  local amountAvailable = math.max(storageItems[itemName].total - math.max(reservedItems and reservedItems[itemName] or 0, 0), 0)
  -- Clamp amount to the max stack size, and use the amountAvailable for the amount if not specified.
  amount = math.floor(math.min((amount or amountAvailable), storageItems[itemName].maxSize))
  local isAmountNotReduced = true
  if amount > amountAvailable then
    amount = amountAvailable
    isAmountNotReduced = false
  end
  if amount == 0 then
    return isAmountNotReduced, 0
  end
  local originalAmount = amount
  
  -- Find the first empty slot to choose as a destination if not given.
  -- We will not choose a slot that already contains the item type because that will not always work (different NBT tags).
  if not destSlot then
    local transIndex, side = next(routing[destType][destIndex])
    local itemIter = transposers[transIndex].getAllStacks(side)
    local item = itemIter()
    local slot = 1
    while item do
      if next(item) == nil then
        destSlot = slot
        break
      end
      item = itemIter()
      slot = slot + 1
    end
    if not destSlot then
      return false, 0
    end
    dlog.out("extractStor", "Found destSlot = " .. destSlot)
  end
  
  -- First, try to extract the items at the extractIndex.
  do
    dlog.out("extractStor", "First try extract point at " .. storageItems[itemName].extractIndex .. ", " .. storageItems[itemName].extractSlot)
    local transIndex, side = next(routing.storage[storageItems[itemName].extractIndex])
    local item = transposers[transIndex].getStackInSlot(side, storageItems[itemName].extractSlot)
    local sendAmount = math.floor(math.min(item.size, amount))
    
    -- Search for previous slot in inventory to combine into this stack if the item count is less than the amount requested.
    -- This has the potential to create two partial stacks if insertion fails later on due to full output, but this should never be a problem.
    if item.size < amount then
      local invIndex = storageItems[itemName].extractIndex
      local itemIter = transposers[transIndex].getAllStacks(side)
      for slot = storageItems[itemName].extractSlot - 1, 1, -1 do
        local item2 = itemIter[slot]
        dlog.out("extractStor", "Checking to combine " .. invIndex .. ", " .. slot)
        if item2.size > 0 and getItemFullName(item2) == itemName then
          dlog.out("extractStor", "Combining items from slot " .. slot)
          local amountTransferred = math.floor(transposers[transIndex].transferItem(side, side, amount - item.size, slot, storageItems[itemName].extractSlot))
          if amountTransferred == item2.size then
            dlog.out("extractStor", "Special case: we created an empty slot at " .. slot)
            if not storageItems.data.firstEmptyIndex or invIndex < storageItems.data.firstEmptyIndex or (invIndex == storageItems.data.firstEmptyIndex and slot < storageItems.data.firstEmptySlot) then
              dlog.out("extractStor", "First empty changed to " .. invIndex .. ", " .. slot)
              storageItems.data.firstEmptyIndex = invIndex
              storageItems.data.firstEmptySlot = slot
            end
            if invIndex < storageItems[itemName].insertIndex or (invIndex == storageItems[itemName].insertIndex and slot < storageItems[itemName].insertSlot) then
              dlog.out("extractStor", "Insert point changed to " .. invIndex .. ", " .. slot)
              storageItems[itemName].insertIndex = invIndex
              storageItems[itemName].insertSlot = slot
            end
          end
          sendAmount = sendAmount + amountTransferred
          break
        end
      end
    end
    
    local amountTransferred, currInvName, currSlot = routeItems(transposers, routing, "storage", storageItems[itemName].extractIndex, storageItems[itemName].extractSlot, destType, destIndex, destSlot, sendAmount)
    
    if amountTransferred < sendAmount then    -- The destination must be full, move the remaining items back.
      local currType = string.match(currInvName, "%a+")
      local currIndex = tonumber(string.match(currInvName, "%d+"))
      routeItems(transposers, routing, currType, currIndex, currSlot, "storage", storageItems[itemName].extractIndex, storageItems[itemName].extractSlot, sendAmount - amountTransferred)
    end
    
    removeStorageItems(transposers, routing, storageItems, storageItems[itemName].extractIndex, storageItems[itemName].extractSlot, item, amountTransferred)
    
    if amountTransferred == amount then
      return isAmountNotReduced, originalAmount
    elseif amountTransferred < sendAmount then
      return false, amountTransferred
    end
    dlog.out("extractStor", "Oof, only transferred " .. amountTransferred .. " of " .. amount)
    amount = amount - amountTransferred
  end
  
  -- Second, iterate from storageItems[itemName].extractIndex/Slot going lowest to highest priority to find another instance of the item.
  dlog.out("extractStor", "Second find next extract point and try extract")
  if storageItems[itemName] then
    for invIndex = storageItems[itemName].extractIndex, 1, -1 do
      local transIndex, side = next(routing.storage[invIndex])
      local itemIter = transposers[transIndex].getAllStacks(side)
      for slot = (invIndex == storageItems[itemName].extractIndex and storageItems[itemName].extractSlot or transposers[transIndex].getInventorySize(side)), 1, -1 do
        local item = itemIter[slot]
        dlog.out("extractStor", "Checking " .. invIndex .. ", " .. slot)
        if item.size > 0 and getItemFullName(item) == itemName then
          dlog.out("extractStor", "Found extract slot for " .. itemName)
          local sendAmount = math.floor(math.min(item.size, amount))
          local amountTransferred, currInvName, currSlot = routeItems(transposers, routing, "storage", invIndex, slot, destType, destIndex, destSlot, sendAmount)
          
          if amountTransferred < sendAmount then    -- The destination must be full, move the remaining items back.
            local currType = string.match(currInvName, "%a+")
            local currIndex = tonumber(string.match(currInvName, "%d+"))
            routeItems(transposers, routing, currType, currIndex, currSlot, "storage", invIndex, slot, sendAmount - amountTransferred)
          end
          
          removeStorageItems(transposers, routing, storageItems, invIndex, slot, item, amountTransferred)
          
          if amountTransferred == amount then
            return isAmountNotReduced, originalAmount
          elseif amountTransferred < sendAmount then
            return false, originalAmount - amount + amountTransferred
          end
          dlog.out("extractStor", "Oof, only transferred " .. amountTransferred .. " of " .. amount)
          amount = amount - amountTransferred
        end
      end
    end
  end
  
  return false, originalAmount - amount
end


-- Send data over network to each address in the table (or broadcast if nil).
local function sendToAddresses(addresses, data)
  if addresses then
    for address, _ in pairs(addresses) do
      wnet.send(modem, address, COMMS_PORT, data)
    end
  else
    wnet.send(modem, nil, COMMS_PORT, data)
  end
end


-- Strip off the unnecessary data in storageItems and send over the network to
-- specified addresses (or broadcast if nil). Items that are reserved are hidden
-- away.
local function sendAvailableItems(addresses, storageItems, reservedItems)
  local items = {}
  for itemName, itemDetails in pairs(storageItems) do
    if itemName ~= "data" and itemDetails.total > (reservedItems[itemName] or 0) then
      items[itemName] = {}
      items[itemName].maxSize = itemDetails.maxSize
      items[itemName].label = itemDetails.label
      items[itemName].total = itemDetails.total - math.max(reservedItems[itemName] or 0, 0)
    end
  end
  items = serialization.serialize(items)
  sendToAddresses(addresses, "any:item_list," .. items)
end


-- Compiles the changes made to storageItems since the last call to this
-- function, and sends the changes over network to the addresses (or broadcast
-- if nil). Items that are reserved are hidden away.
local function sendAvailableItemsDiff(addresses, storageItems, reservedItems)
  -- Merge changes from storageItems and reservedItems together.
  local mergedChanges = {}
  for itemName, _ in pairs(storageItems.data.changes) do
    mergedChanges[itemName] = true
  end
  for itemName, _ in pairs(reservedItems.data.changes) do
    mergedChanges[itemName] = true
  end
  
  -- Pull changes from storageItems and reservedItems to build a diff.
  local itemsDiff = {}
  for itemName, _ in pairs(mergedChanges) do
    -- Find previous and current amount available.
    -- We clamp to non-negative values to discard negative reserved amounts and account for reservations greater than what is stored.
    local currentTotal = (storageItems[itemName] and storageItems[itemName].total or 0)
    local previousAvailable = math.max((storageItems.data.changes[itemName] or currentTotal) - math.max(reservedItems.data.changes[itemName] or reservedItems[itemName] or 0, 0), 0)
    local currentAvailable = math.max(currentTotal - math.max(reservedItems[itemName] or 0, 0), 0)
    
    if currentAvailable ~= 0 then
      if previousAvailable ~= currentAvailable then
        itemsDiff[itemName] = {}
        itemsDiff[itemName].maxSize = storageItems[itemName].maxSize
        itemsDiff[itemName].label = storageItems[itemName].label
        itemsDiff[itemName].total = currentAvailable
      end
    elseif previousAvailable ~= 0 then
      itemsDiff[itemName] = {}
      itemsDiff[itemName].total = 0
    end
    storageItems.data.changes[itemName] = nil
    reservedItems.data.changes[itemName] = nil
  end
  if next(itemsDiff) ~= nil then
    itemsDiff = serialization.serialize(itemsDiff)
    sendToAddresses(addresses, "any:item_diff," .. itemsDiff)
  end
end


-- Set amount for a reserved item. Adds a new entry to changes to keep track of
-- previous amount.
local function setReservedItemAmount(reservedItems, itemName, amount)
  if not reservedItems.data.changes[itemName] then
    reservedItems.data.changes[itemName] = (reservedItems[itemName] or 0)
  end
  if amount ~= 0 then
    reservedItems[itemName] = amount
  else
    reservedItems[itemName] = nil
  end
end


-- Same as setReservedItemAmount(), but adds amount to the current value.
local function changeReservedItemAmount(reservedItems, itemName, amount)
  setReservedItemAmount(reservedItems, itemName, (reservedItems[itemName] or 0) + amount)
end


-- 
local function setDroneItemsSlot(droneItems, i, slot, size, maxSize, fullName)
  if size == 0 then
    if droneItems[i][slot] then
      droneItems[i][slot] = nil
      droneItems[i].dirty = true
    end
  elseif not droneItems[i][slot] then
    droneItems[i][slot] = {}
    droneItems[i][slot].size = size
    droneItems[i][slot].maxSize = maxSize
    droneItems[i][slot].fullName = fullName
    droneItems[i].dirty = true
  elseif droneItems[i][slot].size ~= size then
    droneItems[i][slot].size = size
    droneItems[i].dirty = true
  end
end



-- FIXME not sure what to do with these, they probably should not be here. maybe group them into a few classes that handle them? ###########################################################
local transposers, routing, storageItems, reservedItems
local craftInterServerAddresses, pendingCraftRequests, droneItems



local function handleDroneInsert(address, droneInvIndex, ticket)
  local result = "ok"
  dlog.out("hDroneInsert", "reservedItems before:", reservedItems)
  dlog.out("hDroneInsert", "droneItems before:", droneItems)
  
  local transIndex, side = next(routing.drone[droneInvIndex])
  local itemIter = transposers[transIndex].getAllStacks(side)
  local item = itemIter()
  local slot = 1
  while item do
    if next(item) == nil then
      setDroneItemsSlot(droneItems, droneInvIndex, slot, 0)
    else
      local itemName = getItemFullName(item)
      
      dlog.out("hDroneInsert", "Found item in slot, inserting " .. itemName .. " with count " .. math.floor(item.size))
      
      local success, amountTransferred = insertStorage(transposers, routing, storageItems, "drone", droneInvIndex, slot, item.size)
      dlog.out("hDroneInsert", "insertStorage() returned " .. tostring(success) .. ", " .. amountTransferred)
      if not success then
        result = "full";
      end
      
      if ticket then
        -- Reserve the items that were added to storage.
        pendingCraftRequests[ticket].reserved[itemName] = (pendingCraftRequests[ticket].reserved[itemName] or 0) + amountTransferred
        changeReservedItemAmount(reservedItems, itemName, amountTransferred)
      end
      
      setDroneItemsSlot(droneItems, droneInvIndex, slot, math.floor(item.size) - amountTransferred, math.floor(item.maxSize), itemName)
    end
    item = itemIter()
    slot = slot + 1
  end
  
  dlog.out("hDroneInsert", "reservedItems after:", reservedItems)
  dlog.out("hDroneInsert", "droneItems after:", droneItems)
  
  -- Create a diff of the changes made, and send back to address with the result status.
  -- We always send the contents at droneInvIndex whether it updated or not.
  local droneItemsDiff = {}
  droneItems[droneInvIndex].dirty = nil
  droneItemsDiff[droneInvIndex] = droneItems[droneInvIndex]
  
  sendAvailableItemsDiff(craftInterServerAddresses, storageItems, reservedItems)
  wnet.send(modem, address, COMMS_PORT, "any:drone_item_diff," .. result .. "," .. serialization.serialize(droneItemsDiff))
end


-- Note: it is an error to specify a supply index that is the same as droneInvIndex.
local function handleDroneExtract(address, droneInvIndex, ticket, extractList)
  local extractIdx = 1
  local extractItemName = extractList[extractIdx][1]
  local extractItemAmount = extractList[extractIdx][2]
  local result = "ok"
  assert(extractList.supplyIndices[droneInvIndex] == nil, "Cannot specify supply index that matches droneInvIndex (index is " .. droneInvIndex .. ").")
  
  dlog.out("hDroneExtract", "reservedItems before:", reservedItems)
  
  -- Check if we can pull directly from other drone inventories
  -- (supplyIndices) and transfer items to current one.
  local function pullFromSupplyInventories(destSlot, amount)
    for supplyIndex, _ in pairs(extractList.supplyIndices) do
      for slot, itemDetails in pairs(droneItems[supplyIndex]) do
        if slot ~= "dirty" and itemDetails.fullName == extractItemName then
          dlog.out("hDroneExtract", "Found supply items in container " .. supplyIndex .. " slot " .. slot)
          
          -- Clamp amount to the total in that slot, and confirm items transfer to new slot.
          local transferAmount = math.min(amount, itemDetails.size)
          local maxSize = itemDetails.maxSize
          assert(routeItems(transposers, routing, "drone", supplyIndex, slot, "drone", droneInvIndex, destSlot, transferAmount) == transferAmount, "Failed to transfer items between drone inventories.")
          setDroneItemsSlot(droneItems, supplyIndex, slot, itemDetails.size - transferAmount)
          setDroneItemsSlot(droneItems, droneInvIndex, destSlot, (droneItems[droneInvIndex][destSlot] and droneItems[droneInvIndex][destSlot].size or 0) + transferAmount, maxSize, extractItemName)
          return true, transferAmount, maxSize
        end
      end
    end
    return false
  end
  
  -- Re-scan inventories marked as dirty (crafting operation had changed or is adding items into inventory).
  for supplyIndex, dirty in pairs(extractList.supplyIndices) do
    if dirty then
      local transIndex, side = next(routing.drone[supplyIndex])
      local itemIter = transposers[transIndex].getAllStacks(side)
      local item = itemIter()
      local slot = 1
      while item do
        if next(item) == nil then
          setDroneItemsSlot(droneItems, supplyIndex, slot, 0)
        else
          setDroneItemsSlot(droneItems, supplyIndex, slot, math.floor(item.size), math.floor(item.maxSize), getItemFullName(item))
        end
        
        item = itemIter()
        slot = slot + 1
      end
      -- Explicitly mark index as dirty because we need to send updated data anyways.
      droneItems[supplyIndex].dirty = true
    end
  end
  
  dlog.out("hDroneExtract", "droneItems before:", droneItems)
  
  -- Scan inventory at droneInvIndex for empty slots we can push items to. Items are prioritized from other drone "supply" inventories, then from storage.
  local transIndex, side = next(routing.drone[droneInvIndex])
  local itemIter = transposers[transIndex].getAllStacks(side)
  local item = itemIter()
  local slot = 1
  while item do
    if next(item) == nil then
      -- Amount of items to extract clamped to the max stack size (clamped later once we know this size).
      local slotAmountRemaining = extractItemAmount
      dlog.out("hDroneExtract", "Found free slot, extracting " .. extractItemName .. " with count " .. slotAmountRemaining)
      
      -- Repeatedly pull from other drone inventories that contain the target item.
      local supplyItemsFound = true
      while supplyItemsFound and slotAmountRemaining > 0 do
        local amountTransferred, maxSize
        supplyItemsFound, amountTransferred, maxSize = pullFromSupplyInventories(slot, slotAmountRemaining)
        if supplyItemsFound then
          slotAmountRemaining = math.min(slotAmountRemaining, maxSize) - amountTransferred
          extractItemAmount = extractItemAmount - amountTransferred
        end
      end
      
      -- If we still need items, attempt to pull items from storage.
      if slotAmountRemaining > 0 then
        if ticket then
          -- Confirm we can take the items (they must have been reserved).
          if not pendingCraftRequests[ticket].reserved[extractItemName] or pendingCraftRequests[ticket].reserved[extractItemName] < slotAmountRemaining then
            assert(false, "Item " .. extractItemName .. " with count " .. slotAmountRemaining .. " was not reserved! Crafting operation unable to extract items from storage.")
          end
          -- Remove reservation of the items we need.
          pendingCraftRequests[ticket].reserved[extractItemName] = pendingCraftRequests[ticket].reserved[extractItemName] - slotAmountRemaining
          changeReservedItemAmount(reservedItems, extractItemName, -slotAmountRemaining)
        end
        
        -- Attempt to grab the items.
        local previousSlotTotal = (droneItems[droneInvIndex][slot] and droneItems[droneInvIndex][slot].size or 0)
        local maxSize = (storageItems[extractItemName] and storageItems[extractItemName].maxSize or 0)
        local success, amountTransferred = extractStorage(transposers, routing, storageItems, "drone", droneInvIndex, slot, extractItemName, slotAmountRemaining, reservedItems)
        dlog.out("hDroneExtract", "extractStorage() returned " .. tostring(success) .. ", " .. amountTransferred)
        setDroneItemsSlot(droneItems, droneInvIndex, slot, previousSlotTotal + amountTransferred, maxSize, extractItemName)
        if not success then
          dlog.out("hDroneExtract", "OH NO, what da fuq? extractStorage() failed... guess we move on to next item")  -- ########################################################################
          result = "missing"
          extractItemAmount = 0
        else
          extractItemAmount = extractItemAmount - amountTransferred
        end
        
        -- Re-reserve items we didn't take out.
        if ticket then
          pendingCraftRequests[ticket].reserved[extractItemName] = pendingCraftRequests[ticket].reserved[extractItemName] + slotAmountRemaining - amountTransferred
          changeReservedItemAmount(reservedItems, extractItemName, slotAmountRemaining - amountTransferred)
        end
      end
      
      -- Move on to next item if we got them all.
      if extractItemAmount == 0 then
        extractIdx = extractIdx + 1
        if not extractList[extractIdx] then
          break
        end
        extractItemName = extractList[extractIdx][1]
        extractItemAmount = extractList[extractIdx][2]
      end
      
      --[[
      test cases:
      items in storage, none in drone, extract to drone
      items in another drone, extract to drone
      items in multiple drones (different types), extract to drone
      items in multiple drones (same type), extract to drone
      items in storage, items in multiple drones (same/different types), extract to drone
      --]]
      
      --[[
      use cases:
      need to craft items, request to extract to drone inventory (currently an output), robots do some shit, inventory becomes an input and marked dirty
      need to export items for manufacturing (we have a ticket), inventory stays an output?
      need to import items from manufacturing (we have a ticket), inventory is an input, marked dirty when we add stuff
      generic export of items (no ticket)
      generic import of items (no ticket)
      --]]
    end
    item = itemIter()
    slot = slot + 1
  end
  if result == "ok" and extractList[extractIdx] then
    result = "full"
  end
  
  dlog.out("hDroneExtract", "reservedItems after:", reservedItems)
  dlog.out("hDroneExtract", "droneItems after:", droneItems)
  
  -- Create a diff of the changes made, and send back to address with the result status.
  local droneItemsDiff = {}
  for i, inventoryDetails in ipairs(droneItems) do
    if inventoryDetails.dirty then
      inventoryDetails.dirty = nil
      droneItemsDiff[i] = inventoryDetails
    end
  end
  sendAvailableItemsDiff(craftInterServerAddresses, storageItems, reservedItems)
  wnet.send(modem, address, COMMS_PORT, "any:drone_item_diff," .. result .. "," .. serialization.serialize(droneItemsDiff))
  
end


-- Main program starts here. Runs a few threads to do setup work, listen for
-- packets, redstone events, etc.
local function main()
  local threadSuccess = false
  -- Captures the interrupt signal to stop program.
  local interruptThread = thread.create(function()
    event.pull("interrupted")
  end)
  
  --dlog.setFileOut("/tmp/messages", "w")
  
  -- Performs setup and initialization tasks.
  local setupThread = thread.create(function()
    dlog.out("main", "Setup thread starts.")
    modem.open(COMMS_PORT)
    craftInterServerAddresses = {}
    pendingCraftRequests = {}
    
    transposers, routing = loadRoutingConfig(ROUTING_CONFIG_FILENAME)
    if not transposers then
      io.write("Routing config file \"" .. ROUTING_CONFIG_FILENAME .. "\" not found.\n")
      io.write("Please run the setup utility to create this file.\n")
      interruptThread:kill()
      os.exit()
    end
    
    --dlog.out("setup", "routing:", routing)
    
    io.write("Running full inventory scan, please wait...\n")
    
    -- FIXME we need to run a similar process here for transfer and drone inventories to flush out the system. ##################################################
    storageItems = {}
    storageItems.data = {}
    addStorageItems(transposers, routing, storageItems, 1, 1, {}, 0, true)    -- Update firstEmptyIndex/Slot.
    for invIndex = 1, #routing.storage do
      io.write("  Found storage containing " .. scanInventory(transposers, routing, storageItems, "storage", invIndex) .. " items.\n")
    end
    io.write("\n")
    storageItems.data.changes = {}    -- Add changes table now to track changes in item totals.
    
    -- Reserved items start empty, these are items that will appear invisible in storage system. Crafting jobs use this to hide away intermediate crafting ingredients.
    reservedItems = {}
    reservedItems.data = {}
    reservedItems.data.changes = {}
    
    -- Drone items are the contents of all the drone inventories (stored by index and slot location instead of one complete total). Used by crafting jobs for robot/drone transfers.
    droneItems = {}
    for i = 1, #routing.drone do
      droneItems[i] = {}
    end
    
    --dlog.out("setup", "items:", storageItems)
    
    -- Report system started to other listening devices (so they can re-discover the storage).
    wnet.send(modem, nil, COMMS_PORT, "any:stor_started,")
    
    threadSuccess = true
    dlog.out("main", "Setup thread ends.")
  end)
  
  thread.waitForAny({interruptThread, setupThread})
  if interruptThread:status() == "dead" then
    os.exit(1)
  elseif not threadSuccess then
    io.stderr:write("Error occurred in thread, check log file \"/tmp/event.log\" for details.\n")
    os.exit(1)
  end
  threadSuccess = false
  
  -- Listens for incoming packets over the network and deals with them.
  local modemThread = thread.create(function()
    dlog.out("main", "Modem thread starts.")
    io.write("Listening for commands on port " .. COMMS_PORT .. "...\n")
    while true do
      local address, port, data = wnet.receive()
      if port == COMMS_PORT then
        local dataHeader = string.match(data, "[^,]*")
        data = string.sub(data, #dataHeader + 2)
        
        if dataHeader == "stor:discover" then
          -- Device is searching for this storage server, respond with storage items list.
          craftInterServerAddresses[address] = true
          sendAvailableItems({[address]=true}, storageItems, reservedItems)
        elseif dataHeader == "stor:insert" then
          -- Device requested to insert items into the network.
          dlog.out("cmdInsert", "result = ", insertStorage(transposers, routing, storageItems, "input", 1))
          sendAvailableItemsDiff(craftInterServerAddresses, storageItems, reservedItems)
        elseif dataHeader == "stor:extract" then
          -- Device has requested to extract items from network.
          local itemName = string.match(data, "[^,]*")
          local amount = string.match(data, "[^,]*", #itemName + 2)
          if itemName == "" then
            itemName = nil
          end
          dlog.out("cmdExtract", "Extract with item " .. tostring(itemName) .. " and amount " .. amount .. ".")
          -- Continuously extract item until we reach the amount or run out (or output full).
          amount = tonumber(amount)
          while amount > 0 do
            local success, amountTransferred = extractStorage(transposers, routing, storageItems, "output", 1, nil, itemName, amount, reservedItems)
            dlog.out("cmdExtract", "result = ", success, amountTransferred)
            if not success then
              break
            end
            amount = amount - amountTransferred
          end
          sendAvailableItemsDiff(craftInterServerAddresses, storageItems, reservedItems)
        elseif dataHeader == "stor:recipe_reserve" then
          -- Crafting server is requesting to reserve items for crafting operation.
          local ticket = string.match(data, "[^;]*")
          data = string.sub(data, #ticket + 2)
          
          -- Check for expired tickets and remove them.
          for ticketName, request in pairs(pendingCraftRequests) do
            if computer.uptime() > request.creationTime + 10 then
              dlog.out("cmdRecipeReserve", "Ticket " .. ticketName .. " has expired")
              
              for itemName, amount in pairs(request.reserved) do
                changeReservedItemAmount(reservedItems, itemName, -amount)
              end
              pendingCraftRequests[ticketName] = nil
            end
          end
          
          -- Add all required items for crafting directly to the reserved list.
          -- This includes the negative ones (recipe outputs), a negative reservation means the item can be reserved later once inserted into network but will show up anyways.
          local requiredItems = serialization.unserialize(data)
          local reserveFailed = false
          for itemName, amount in pairs(requiredItems) do
            changeReservedItemAmount(reservedItems, itemName, amount)
            if (reservedItems[itemName] or 0) > (storageItems[itemName] and storageItems[itemName].total or 0) then
              reserveFailed = true
            end
          end
          
          -- If we successfully reserved the items then add the ticket to pending. Otherwise we undo the reservation.
          if not reserveFailed then
            pendingCraftRequests[ticket] = {}
            pendingCraftRequests[ticket].creationTime = computer.uptime()
            pendingCraftRequests[ticket].reserved = requiredItems
          else
            for itemName, amount in pairs(requiredItems) do
              changeReservedItemAmount(reservedItems, itemName, -amount)
            end
            wnet.send(modem, address, COMMS_PORT, "craft:recipe_cancel," .. ticket)
          end
          
          sendAvailableItemsDiff(craftInterServerAddresses, storageItems, reservedItems)
        elseif dataHeader == "stor:recipe_cancel" then
          -- Crafting server is requesting to cancel a crafting operation.
          if pendingCraftRequests[data] then
            for itemName, amount in pairs(pendingCraftRequests[data].reserved) do
              changeReservedItemAmount(reservedItems, itemName, -amount)
            end
            pendingCraftRequests[data] = nil
            
            sendAvailableItemsDiff(craftInterServerAddresses, storageItems, reservedItems)
          end
        elseif dataHeader == "stor:get_drone_item_list" then
          --[[
          this may not be a great idea to maintain drone item info here (well actually maybe it works well). 2 options:
            store all drone inventory data with crafting, only send info about number of inventories and number of slots here
            store it all here, then crafting requests bulk of items needed in an inventory, storage responds with did it succeed and diff of just that inventory index (in one packet)
              also need to let crafting tell storage to suck all of inventory back into network (when items need to be returned). yikes what happens if full??
          --]]
          
          wnet.send(modem, address, COMMS_PORT, "any:drone_item_list," .. serialization.serialize(droneItems))
        elseif dataHeader == "stor:drone_insert" then
          local droneInvIndex = string.match(data, "[^,]*")
          local ticket = string.sub(data, #droneInvIndex + 2)
          droneInvIndex = tonumber(droneInvIndex)
          if ticket == "" then
            ticket = nil
          end
          
          handleDroneInsert(address, droneInvIndex, ticket)
          
        elseif dataHeader == "stor:drone_extract" then
          local droneInvIndex = string.match(data, "[^,]*")
          local ticket = string.match(data, "[^;]*", #droneInvIndex + 2)
          local extractList = serialization.unserialize(string.sub(data, #droneInvIndex + #ticket + 3))
          droneInvIndex = tonumber(droneInvIndex)
          if ticket == "" then
            ticket = nil
          end
          
          handleDroneExtract(address, droneInvIndex, ticket, extractList)
          
        elseif dataHeader == "stor:debug" then
          dlog.out("cmdDebug", "storageItems:", storageItems)
        end
      end
    end
    dlog.out("main", "Modem thread ends.")
  end)
  
  -- Occasionally checks for redstone signal from I/O block and imports items from input into storage.
  local inputSensorThread = thread.create(function()
    dlog.out("main", "Input sensor thread starts.")
    io.write("Input sensor waiting for redstone event...\n")
    while true do
      --local _, address, side, _, newValue = event.pull("redstone_changed")
      --dlog.out("inputSensor", "Redstone update: ", address, side, old, new)
      local redstoneLevel = 0
      for i = 0, 5 do
        redstoneLevel = math.max(redstoneLevel, math.floor(rs.getInput(i)))
      end
      if redstoneLevel > 0 then
        local transIndex, side = next(routing.input[1])
        local itemIter = transposers[transIndex].getAllStacks(side)
        local item = itemIter()
        local slot = 1
        while item do
          if next(item) ~= nil then
            local success, amountTransferred = insertStorage(transposers, routing, storageItems, "input", 1, slot)
            dlog.out("inputSensor", "insertStorage() result = ", success, amountTransferred)
            sendAvailableItemsDiff(craftInterServerAddresses, storageItems, reservedItems)
            os.sleep(0)    -- Yield to let other threads do I/O with storage if they need to.
          end
          item = itemIter()
          slot = slot + 1
        end
      end
      os.sleep(INPUT_DELAY_SECONDS)
    end
    dlog.out("main", "Input sensor thread ends.")
  end)
  
  -- Waits for commands from user-input and executes them.
  local commandThread = thread.create(function()
    dlog.out("main", "Command thread starts.")
    while true do
      io.write("> ")
      local input = io.read()
      if type(input) ~= "string" then
        input = "exit"
      end
      input = text.tokenize(input)
      if input[1] == "dlog" then    -- Command dlog [<subsystem> <0, 1, or nil>]
        if input[2] then
          if input[3] == "0" then
            dlog.setSubsystem(input[2], false)
          elseif input[3] == "1" then
            dlog.setSubsystem(input[2], true)
          else
            dlog.setSubsystem(input[2], nil)
          end
        else
          io.write("Outputs: std_out=" .. tostring(dlog.stdOutput) .. ", file_out=" .. tostring(io.type(dlog.fileOutput)) .. "\n")
          io.write("Monitored subsystems:\n")
          for k, v in pairs(dlog.subsystems) do
            io.write(text.padRight(k, 20) .. (v and "1" or "0") .. "\n")
          end
        end
      elseif input[1] == "dlog_file" then    -- Command dlog_file [<filename>]
        dlog.setFileOut(input[2] or "")
      elseif input[1] == "dlog_std" then    -- Command dlog_std <0 or 1>
        dlog.setStdOut(input[2] == "1")
      elseif input[1] == "help" then    -- Command help
        io.write("Commands:\n")
        io.write("  dlog [<subsystem> <0, 1, or nil>]\n")
        io.write("    Display diagnostics log info (when called with no arguments), or enable/\n")
        io.write("    disable logging for a subsystem. Use a \"*\" to refer to all subsystems, except\n")
        io.write("    ones that are explicitly disabled.\n")
        io.write("    Ex: Run \"dlog * 1\" then \"dlog wnet:d 0\" to enable all logs except \"wnet:d\".\n")
        io.write("  dlog_file [<filename>]\n")
        io.write("    Set logging output file. Skip the filename argument to disable file output.\n")
        io.write("    Note: the file will close automatically when the command thread ends.\n")
        io.write("  dlog_std <0 or 1>\n")
        io.write("    Set logging to standard output (0 to disable and 1 to enable).\n")
        io.write("  help\n")
        io.write("    Show this help menu.\n")
        io.write("  exit\n")
        io.write("    Exit program.\n")
      elseif input[1] == "exit" then    -- Command exit
        threadSuccess = true
        break
      else
        io.write("Enter \"help\" for command help, or \"exit\" to quit.\n")
      end
    end
    dlog.out("main", "Command thread ends.")
  end)
  
  thread.waitForAny({interruptThread, modemThread, inputSensorThread, commandThread})
  if interruptThread:status() == "dead" then
    os.exit(1)
  elseif not threadSuccess then
    io.stderr:write("Error occurred in thread, check log file \"/tmp/event.log\" for details.\n")
    os.exit(1)
  end
  
  dlog.out("main", "Killing threads and stopping program.")
  interruptThread:kill()
  modemThread:kill()
  inputSensorThread:kill()
  commandThread:kill()
end

main()

--[[
Pulling from storage grabs the last slot item from the lowest priority container.
  We optimize by transferring items of the same type in the inventory into the
  partial stack to match the amount (up to the stack size), then route the
  partial/full stack to the destination.

Adding to storage places item in the first available slot, or first partial slot
if it exists (of highest priority container).
  We always send the full stack, and if not all of the items transfer then we
  attempt to transfer to the next occurrence and repeat until reaching the
  extract slot. If there are still some left over, send the rest to the first
  empty slot. The initial "attempt transfer to each occurrence" is only
  performed the first time we try to transfer that item type.

Ideally we should have only one partial stack for each item type, but this can
change from user intervention or priority changes.


transposers = {
  1: <transposer proxy>
  2: <transposer proxy>
  ...
}

routing = {
  storage: {
    1: {
      <transIndex>: <side>    -- Each of these is a "connection". By this logic, an inventory connects to a transposer on a single side.
    }
    2: {
      <transIndex>: <side>
    }
  }
  input: {
    1: {
      <transIndex>: <side>
    }
  }
  output: {
    1: {
      <transIndex>: <side>
    }
  }
  transfer: {
    1: {
      <transIndex>: <side>
      <transIndex>: <side>
    }
    2: {
      <transIndex>: <side>
      <transIndex>: <side>
      <transIndex>: <side>
    }
  }
  drone: {
    1: {
      <transIndex>: <side>
    }
    2: {
      <transIndex>: <side>
    }
  }
  
  transposer: {
    1: {
      "<storage type><index>": <side>    -- Similar connection, but with different index. A transposer connects to an inventory on a single side.
      ...
    }
    ...
  }
}

storageItems = {
  <item full name>: {
    maxDamage: ...
    maxSize: ...
    id: ...    -- Not currently used.
    label: ...
    total: <total count>
    insertIndex: <storage index>    -- First available place to insert items (the partial stack, could be a cache or regular inventory). Try and insert here and remainder to the firstEmptyIndex/Slot.
    insertSlot: <slot number>
    checkedPartials: true/false    -- Whether the stacks (for this item type) after the initial insert index have been confirmed to reach their max size.
    extractIndex: <storage index>    -- Last available place to pull items (usually same index/slot as above, but not always). Try to pull from here and remainder from previous slots.
    extractSlot: <slot number>
  }
  ...
  data: {
    firstEmptyIndex = <storage index>    -- First empty slot of highest-priority storage container.
    firstEmptySlot = <slot number>
    changes: {    -- This table is left nonexistent until we need it (after first storage scan).
      <item full name>: <previous total>    -- List of changes made to items that will need to be communicated over network.
      ...
    }
  }
}

droneItems = {
  1: {
    <slot num>: {
      size: <item amount>
      maxSize: <max stack size>
      fullName: <item full name>
    }
    ...
    dirty: true    -- Dirty flag marks if data may have changed. Nil if not dirty.
  }
  2: {
    ...
  }
  ...
}

[a, b,  ,  , c]
[a,  , a, a,  ]



-- Old idea for storageItems[<item name>][locations]
locations: {
  <storage index>: {    -- Note: index not contiguous. This is a bit of a problem though.
    <slot number>: <count>    -- Maybe instead do location1, location2, etc then we search when need location (lowest to highest for insert and opposite for extract).
    ...
  }
  ...
}

--]]
