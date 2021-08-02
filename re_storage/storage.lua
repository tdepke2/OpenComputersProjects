--[[

--]]

local COMMS_PORT = 0xE298
local ROUTING_CONFIG_FILENAME = "routing.config"
local INPUT_DELAY_SECONDS = 2

local common = require("common")
local component = require("component")
local computer = require("computer")
local event = require("event")
local modem = component.modem
local rs = component.redstone
local serialization = require("serialization")
local sides = require("sides")
local tdebug = require("tdebug")
local text = require("text")
local thread = require("thread")
local wnet = require("wnet")

-- Load routing configuration and return a table indexing the transposers and
-- another table specifying the connections.
local function loadRoutingConfig(filename)
  checkArg(1, filename, "string")
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
  local lineNum = 1
  local parserStage = 1
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
  checkArg(1, item, "table")
  return item.name .. "/" .. math.floor(item.damage)
end


-- Register the item stack with the storageItems table. If updateFirstEmpty is
-- true then set storageItems.firstEmptyIndex/Slot to the next empty slot found.
local function addStorageItems(transposers, routing, storageItems, invIndex, slot, item, amount, updateFirstEmpty)
  checkArg(1, transposers, "table", 2, routing, "table", 3, storageItems, "table", 4, invIndex, "number", 5, slot, "number", 6, item, "table", 7, amount, "number", 8, updateFirstEmpty, "boolean")
  --print("addStorageItems(", transposers, routing, storageItems, invIndex, slot, item, amount, updateFirstEmpty, ")")
  -- If updateFirstEmpty then find the first empty slot in storage system after the current invIndex and slot.
  if updateFirstEmpty then
    storageItems.firstEmptyIndex = nil
    storageItems.firstEmptySlot = nil
    for invIndex2 = invIndex, #routing.storage do
      local transIndex, side = next(routing.storage[invIndex2])
      local itemIter = transposers[transIndex].getAllStacks(side)
      for slot2 = (invIndex2 == invIndex and slot or 1), transposers[transIndex].getInventorySize(side) do
        local item2 = itemIter[slot2]
        --print("checking slot " .. slot2)
        if item2.size == 0 then
          --print("first empty changed to " .. invIndex2 .. ", " .. slot2)
          storageItems.firstEmptyIndex = invIndex2
          storageItems.firstEmptySlot = slot2
          break
        end
      end
      if storageItems.firstEmptyIndex then
        break
      end
    end
  end
  
  if amount == 0 then
    --print("amount is 0, bye")
    return
  end
  
  -- If item does not exist in table, add it. Otherwise update the existing entry.
  local fullName = getItemFullName(item)
  if not storageItems[fullName] then
    --print("adding new storageItems entry")
    storageItems[fullName] = {}
    storageItems[fullName].maxDamage = math.floor(item.maxDamage)    -- Maximum damage this item can have.
    storageItems[fullName].maxSize = math.floor(item.maxSize)    -- Maximum stack size.
    storageItems[fullName].id = item.id    -- Minecraft id of the item.
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
      --print("insert point changed to " .. invIndex .. ", " .. slot)
      storageItems[fullName].insertIndex = invIndex
      storageItems[fullName].insertSlot = slot
    elseif invIndex > storageItems[fullName].extractIndex or (invIndex == storageItems[fullName].extractIndex and slot > storageItems[fullName].extractSlot) then
      --print("extract point changed to " .. invIndex .. ", " .. slot)
      storageItems[fullName].extractIndex = invIndex
      storageItems[fullName].extractSlot = slot
    end
  end
end


-- Remove the items from the storageItems table, and delete the item stack entry
-- in the table if applicable.
local function removeStorageItems(transposers, routing, storageItems, invIndex, slot, item, amount)
  checkArg(1, transposers, "table", 2, routing, "table", 3, storageItems, "table", 4, invIndex, "number", 5, slot, "number", 6, item, "table", 7, amount, "number")
  --print("removeStorageItems(", transposers, routing, storageItems, invIndex, slot, item, amount, ")")
  if amount == 0 then
    --print("amount is 0, bye")
    return
  end
  
  -- Check if first empty slot has now moved to this invIndex/slot.
  local transIndex, side = next(routing.storage[invIndex])
  local itemsRemaining = transposers[transIndex].getSlotStackSize(side, slot)
  if itemsRemaining == 0 and (not storageItems.firstEmptyIndex or invIndex < storageItems.firstEmptyIndex or (invIndex == storageItems.firstEmptyIndex and slot < storageItems.firstEmptySlot)) then
    --print("first empty changed to " .. invIndex .. ", " .. slot)
    storageItems.firstEmptyIndex = invIndex
    storageItems.firstEmptySlot = slot
  end
  
  -- Update total and check if we can remove the table entry.
  local fullName = getItemFullName(item)
  storageItems[fullName].total = storageItems[fullName].total - amount
  if storageItems[fullName].total == 0 then    -- FIXME may want to change to <= after testing ####################################################
    --print("removing item entry for " .. fullName)
    storageItems[fullName] = nil
    return
  end
  
  -- If item stack empty, search for the next extract point and update insertion point if needed. Otherwise update bounds on insert/extract point.
  if itemsRemaining == 0 then
    --print("itemsRemaining is zero, find next extract point")
    for invIndex2 = invIndex, 1, -1 do
      local transIndex, side = next(routing.storage[invIndex2])
      local itemIter = transposers[transIndex].getAllStacks(side)
      for slot2 = (invIndex2 == invIndex and slot or transposers[transIndex].getInventorySize(side)), 1, -1 do
        local item2 = itemIter[slot2]
        if item2.size > 0 and getItemFullName(item2) == fullName then
          --print("extract point changed to " .. invIndex2 .. ", " .. slot2)
          storageItems[fullName].extractIndex = invIndex2
          storageItems[fullName].extractSlot = slot2
          if invIndex2 < storageItems[fullName].insertIndex or (invIndex2 == storageItems[fullName].insertIndex and slot2 < storageItems[fullName].insertSlot) then
            --print("insert point changed to " .. invIndex2 .. ", " .. slot2)
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
      --print("insert point changed to " .. invIndex .. ", " .. slot)
      storageItems[fullName].insertIndex = invIndex
      storageItems[fullName].insertSlot = slot
    end
    if invIndex < storageItems[fullName].extractIndex or (invIndex == storageItems[fullName].extractIndex and slot < storageItems[fullName].extractSlot) then
      --print("extract point changed to " .. invIndex .. ", " .. slot)
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
  checkArg(1, transposers, "table", 2, routing, "table", 3, storageItems, "table", 4, invType, "string", 5, invIndex, "number")
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
  checkArg(1, connection, "string")
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
  checkArg(1, transposers, "table", 2, routing, "table", 3, srcType, "string", 4, srcIndex, "number", 5, srcSlot, "number", 6, destType, "string", 7, destIndex, "number", 8, destSlot, "number")
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
    --print("adding", transIndex, side)
  end
  
  -- Run breadth-first search to find destination.
  while not searchQueue:empty() do
    local transIndexFirst, sideFirst = table.unpack(searchQueue:front())
    searchQueue:pop_front()
    --print("got vals", transIndexFirst, sideFirst)
    
    -- From the current connection, check inventories that are adjacent to the transposer (except the one we started from).
    for invName, side in pairs(routing.transposer[transIndexFirst]) do
      if side ~= sideFirst then
        --print("checking", invName, side)
        if invName == destInvName then
          endTransposerLink = transIndexFirst .. ":" .. side
          transposerLinks[endTransposerLink] = transIndexFirst .. ":" .. sideFirst
          --print("found it", invName, side)
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
              --print("adding", transIndex2, side2)
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
    
    --print(transIndex .. " -> " .. srcSide .. ", " .. sinkSide)
    amountTransferred = math.floor(transposers[transIndex].transferItem(srcSide, sinkSide, amount, firstConnection and srcSlot or 1, connectionStack:empty() and destSlot or 1))
    firstConnection = false
    
    -- Confirm that item moved, or if at the end lookup the inventory that the remaining items are now stuck in.
    if not connectionStack:empty() then
      assert(amountTransferred == amount)
    elseif amountTransferred ~= amount then
      for invName, side in pairs(routing.transposer[transIndex]) do
        if side == srcSide then
          return amountTransferred, invName, 1
        end
      end
    end
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
  checkArg(1, transposers, "table", 2, routing, "table", 3, storageItems, "table", 4, srcType, "string", 5, srcIndex, "number")
  --print("insertStorage(", transposers, routing, storageItems, srcType, srcIndex, srcSlot, amount, ")")
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
    --print("found srcSlot = " .. srcSlot)
  end
  
  local srcItem = transposers[srcTransIndex].getStackInSlot(srcSide, srcSlot)
  local srcFullName = getItemFullName(srcItem)
  -- Clamp amount to the current and max stack size, and use the item count for the amount if not specified.
  amount = math.floor(math.min(amount or srcItem.size, srcItem.maxSize))
  local originalAmount = amount
  local currType = srcType
  local currIndex = srcIndex
  local currSlot = srcSlot
  
  -- First, try to insert the items at the insertIndex if item exists in storage (could be full, could be an over-sized slot, etc).
  if storageItems[srcFullName] then
    --print("first try insert point at " .. storageItems[srcFullName].insertIndex .. ", " .. storageItems[srcFullName].insertSlot)
    local amountTransferred, currInvName
    amountTransferred, currInvName, currSlot = routeItems(transposers, routing, currType, currIndex, currSlot, "storage", storageItems[srcFullName].insertIndex, storageItems[srcFullName].insertSlot, amount)
    
    addStorageItems(transposers, routing, storageItems, storageItems[srcFullName].insertIndex, storageItems[srcFullName].insertSlot, srcItem, amountTransferred, false)
    
    if amountTransferred == amount then
      return true, originalAmount
    end
    --print("rip, only transferred " .. amountTransferred .. " of " .. amount)
    amount = amount - amountTransferred
    currType = string.match(currInvName, "%a+")
    currIndex = tonumber(string.match(currInvName, "%d+"))
  end
  
  -- Second, try to insert items at the next available slot of the same type, until extract point reached. Skip if checkedPartials is true.
  if storageItems[srcFullName] and not storageItems[srcFullName].checkedPartials then
    --print("second try insert at next partial")
    for invIndex = storageItems[srcFullName].insertIndex, storageItems[srcFullName].extractIndex do
      local transIndex, side = next(routing.storage[invIndex])
      local itemIter = transposers[transIndex].getAllStacks(side)
      local slotStart = (invIndex == storageItems[srcFullName].insertIndex and storageItems[srcFullName].insertSlot + 1 or 1)
      local slotEnd = (invIndex == storageItems[srcFullName].extractIndex and storageItems[srcFullName].extractSlot or transposers[transIndex].getInventorySize(side))
      for slot = slotStart, slotEnd do
        local item = itemIter[slot]
        --print("checking " .. invIndex .. ", " .. slot)
        if item.size > 0 and getItemFullName(item) == srcFullName then    -- Check if we can add to existing stack. Items may still fail to move here.
          --print("found potential partial slot for " .. srcFullName)
          local amountTransferred, currInvName
          amountTransferred, currInvName, currSlot = routeItems(transposers, routing, currType, currIndex, currSlot, "storage", invIndex, slot, amount)
          
          addStorageItems(transposers, routing, storageItems, invIndex, slot, item, amountTransferred, false)
          
          if amountTransferred == amount then
            storageItems[srcFullName].insertIndex = invIndex
            storageItems[srcFullName].insertSlot = slot
            return true, originalAmount
          end
          --print("rip, only transferred " .. amountTransferred .. " of " .. amount)
          amount = amount - amountTransferred
          currType = string.match(currInvName, "%a+")
          currIndex = tonumber(string.match(currInvName, "%d+"))
        end
      end
    end
    storageItems[srcFullName].checkedPartials = true
  end
  
  -- Third, try to insert items at the firstEmptyIndex.
  if storageItems.firstEmptyIndex then
    --print("third try first empty at " .. storageItems.firstEmptyIndex .. ", " .. storageItems.firstEmptySlot)
    assert(routeItems(transposers, routing, currType, currIndex, currSlot, "storage", storageItems.firstEmptyIndex, storageItems.firstEmptySlot, amount) == amount)
    
    if storageItems[srcFullName] then
      storageItems[srcFullName].insertIndex = storageItems.firstEmptyIndex
      storageItems[srcFullName].insertSlot = storageItems.firstEmptySlot
    end
    
    addStorageItems(transposers, routing, storageItems, storageItems.firstEmptyIndex, storageItems.firstEmptySlot, srcItem, amount, true)
    
    return true, originalAmount
  end
  
  --print("routing stuck items back from " .. currType .. currIndex .. ":" .. currSlot)
  -- Route any stuck items back to where they came from.
  local amountTransferred, currInvName
  amountTransferred, currInvName, currSlot = routeItems(transposers, routing, currType, currIndex, currSlot, srcType, srcIndex, srcSlot)
  if currInvName then
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
-- Returns false if not all of the amount specified could be extracted. The
-- destSlot, itemName, and amount can be nil.
local function extractStorage(transposers, routing, storageItems, destType, destIndex, destSlot, itemName, amount)
  checkArg(1, transposers, "table", 2, routing, "table", 3, storageItems, "table", 4, destType, "string", 5, destIndex, "number")
  --print("extractStorage(", transposers, routing, storageItems, destType, destIndex, destSlot, itemName, amount, ")")
  assert(destType == "input" or destType == "output" or destType == "drone")
  if not itemName then
    for itemName2, itemDetails in pairs(storageItems) do
      if itemName2 ~= "firstEmptyIndex" and itemName2 ~= "firstEmptySlot" then
        itemName = itemName2
        break
      end
    end
  end
  if not storageItems[itemName] then
    return false, 0
  end
  -- Clamp amount to the max stack size, and use the storage total for the amount if not specified.
  amount = math.floor(math.min((amount or storageItems[itemName].total), storageItems[itemName].maxSize))
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
    --print("found destSlot = " .. destSlot)
  end
  
  -- First, try to extract the items at the extractIndex.
  do
    --print("first try extract point at " .. storageItems[itemName].extractIndex .. ", " .. storageItems[itemName].extractSlot)
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
        --print("checking to combine " .. invIndex .. ", " .. slot)
        if item2.size > 0 and getItemFullName(item2) == itemName then
          --print("combining items from slot " .. slot)
          local amountTransferred = math.floor(transposers[transIndex].transferItem(side, side, amount - item.size, slot, storageItems[itemName].extractSlot))
          if amountTransferred == item2.size then
            --print("special case: we created an empty slot at " .. slot)
            if not storageItems.firstEmptyIndex or invIndex < storageItems.firstEmptyIndex or (invIndex == storageItems.firstEmptyIndex and slot < storageItems.firstEmptySlot) then
              --print("first empty changed to " .. invIndex .. ", " .. slot)
              storageItems.firstEmptyIndex = invIndex
              storageItems.firstEmptySlot = slot
            end
            if invIndex < storageItems[itemName].insertIndex or (invIndex == storageItems[itemName].insertIndex and slot < storageItems[itemName].insertSlot) then
              --print("insert point changed to " .. invIndex .. ", " .. slot)
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
      return true, originalAmount
    elseif amountTransferred < sendAmount then
      return false, amountTransferred
    end
    --print("rip, only transferred " .. amountTransferred .. " of " .. amount)
    amount = amount - amountTransferred
  end
  
  -- Second, iterate from storageItems[itemName].extractIndex/Slot going lowest to highest priority to find another instance of the item.
  --print("second find next extract point and try extract")
  if storageItems[itemName] then
    for invIndex = storageItems[itemName].extractIndex, 1, -1 do
      local transIndex, side = next(routing.storage[invIndex])
      local itemIter = transposers[transIndex].getAllStacks(side)
      for slot = (invIndex == storageItems[itemName].extractIndex and storageItems[itemName].extractSlot or transposers[transIndex].getInventorySize(side)), 1, -1 do
        local item = itemIter[slot]
        --print("checking " .. invIndex .. ", " .. slot)
        if item.size > 0 and getItemFullName(item) == itemName then
          --print("found extract slot for " .. itemName)
          local sendAmount = math.floor(math.min(item.size, amount))
          local amountTransferred, currInvName, currSlot = routeItems(transposers, routing, "storage", invIndex, slot, destType, destIndex, destSlot, sendAmount)
          
          if amountTransferred < sendAmount then    -- The destination must be full, move the remaining items back.
            local currType = string.match(currInvName, "%a+")
            local currIndex = tonumber(string.match(currInvName, "%d+"))
            routeItems(transposers, routing, currType, currIndex, currSlot, "storage", invIndex, slot, sendAmount - amountTransferred)
          end
          
          removeStorageItems(transposers, routing, storageItems, invIndex, slot, item, amountTransferred)
          
          if amountTransferred == amount then
            return true, originalAmount
          elseif amountTransferred < sendAmount then
            return false, originalAmount - amount + amountTransferred
          end
          --print("rip, only transferred " .. amountTransferred .. " of " .. amount)
          amount = amount - amountTransferred
        end
      end
    end
  end
  
  return false, originalAmount - amount
end


--[[
Pulling from storage grabs the last slot item from the lowest priority container.
  Can optimize by transferring items before the partial into the partial to match
  the amount (up to the stack size), then route the partial to the destination.

Adding to storage places item in the first available slot, or first partial slot
if it exists (of highest priority container).
  We always send the full stack, and if not all of the items transfer then
  transfer again from the nearby transfer buffer to the first empty slot.

Ideally we should have only one partial stack for each item type, but this can
change from user intervention or priority changes.



Request item from storage:
  Look up the table entry for the item and see how much we have.
  Find the storage with lowest priority that contains it, and get the slot/count.
  Find the next available slot in output (should allow stacking )

Add item to storage:
  Look through storage and cache the first empty slot found, and stop at
--]]

local function main()
  -- Captures the interrupt signal to stop program.
  local interruptThread = thread.create(function()
    event.pull("interrupted")
  end)
  
  local transposers, routing, storageItems
  
  -- Performs setup and initialization tasks.
  local setupThread = thread.create(function()
    transposers, routing = loadRoutingConfig(ROUTING_CONFIG_FILENAME)
    
    print(" - routing - ")
    tdebug.printTable(routing)
    
    io.write("Running full inventory scan, please wait...\n")
    
    -- FIXME we probably want to run a similar process here for transfer and drone inventories to flush out the system. ##################################################
    storageItems = {}
    addStorageItems(transposers, routing, storageItems, 1, 1, nil, 0, true)    -- Update firstEmptyIndex/Slot.
    for invIndex = 1, #routing.storage do
      print("found items: " .. scanInventory(transposers, routing, storageItems, "storage", invIndex))
    end
    
    print(" - items - ")
    tdebug.printTable(storageItems)
  end)
  
  thread.waitForAny({interruptThread, setupThread})
  if interruptThread:status() == "dead" then
    os.exit(1)
  end
  
  local exitSuccess = false
  
  -- Listens for incoming packets over the network and deals with them.
  local modemThread = thread.create(function()
    modem.open(COMMS_PORT)
    wnet.debug = true
    
    io.write("Listening for commands on port " .. COMMS_PORT .. "...\n")
    while true do
      local address, port, data = wnet.receive()
      if port == COMMS_PORT then
        local dataType = string.match(data, "[^,]*")
        data = string.sub(data, #dataType + 2)
        
        if dataType == "stor_discover" then
          wnet.send(modem, address, COMMS_PORT, "stor_item_list," .. serialization.serialize(storageItems))
        elseif dataType == "stor_insert" then
          print("result = ", insertStorage(transposers, routing, storageItems, "input", 1))
        elseif dataType == "stor_extract" then
          local itemName = string.match(data, "[^,]*")
          local amount = string.match(data, "[^,]*", #itemName + 2)
          if itemName == "" then
            itemName = nil
          end
          print("extract with item " .. tostring(itemName) .. " and amount " .. amount .. ".")
          print("result = ", extractStorage(transposers, routing, storageItems, "output", 1, nil, itemName, tonumber(amount)))
        end
      end
    end
  end)
  
  local inputSensorThread = thread.create(function()
    io.write("Input sensor waiting for redstone event...\n")
    while true do
      --local _, address, side, _, newValue = event.pull("redstone_changed")
      --print("Redstone update: ", address, side, old, new)
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
            print("result = ", success, amountTransferred)
            -- FIXME add back in to prevent starvation of other processes ###########################################################################################################
            --os.sleep(0.05)    -- Yield to let other threads do I/O with storage if they need to.
          end
          item = itemIter()
          slot = slot + 1
        end
      end
      os.sleep(INPUT_DELAY_SECONDS)
    end
  end)
  
  thread.waitForAny({interruptThread, modemThread, inputSensorThread})
  if interruptThread:status() == "dead" then
    os.exit(1)
  end
  
  interruptThread:kill()
  modemThread:kill()
  inputSensorThread:kill()
  
  if not exitSuccess then
    io.stderr:write("Error occurred in thread, check log file \"/tmp/event.log\" for details.\n")
  end
end

main()

--[[

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
  firstEmptyIndex = <storage index>    -- First empty slot of highest-priority storage container.
  firstEmptySlot = <slot number>
  <item full name>: {
    maxDamage: ...
    maxSize: ...
    id: ...
    label: ...
    total: <total count>
    insertIndex: <storage index>    -- First available place to insert items (the partial stack, could be a cache or regular inventory). Try and insert here and remainder to the firstEmptyIndex/Slot.
    insertSlot: <slot number>
    checkedPartials: true/false    -- Whether the stacks (for this item type) after the initial insert index have been confirmed to reach their max size.
    extractIndex: <storage index>    -- Last available place to pull items (usually same index/slot as above, but not always). Try to pull from here and remainder from previous slots.
    extractSlot: <slot number>
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
