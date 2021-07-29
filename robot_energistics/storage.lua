local common = require("common")
local component = require("component")
local sides = require("sides")
local tdebug = require("tdebug")
local term = require("term")
local text = require("text")

local ROUTING_CONFIG_FILENAME = "routing.config"

-- Load routing configuration and return a table indexing the transposers and
-- another table specifying the connections.
local function loadRoutingConfig(filename)
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
  return item.name .. "/" .. math.floor(item.damage)
end



-- ############################################################################################################################################################################################################################
-- ############################################################################################################################################################################################################################
-- ############################################################################################################################################################################################################################


-- Register the item stack with the storageItems table. If updateFirstEmpty is
-- true then set storageItems.firstEmptyIndex/Slot to the next empty slot found.
local function addStorageItems(transposers, routing, storageItems, invIndex, slot, item, amount, updateFirstEmpty)
  print("addStorageItems(", transposers, routing, storageItems, invIndex, slot, item, amount, updateFirstEmpty, ")")
  -- If updateFirstEmpty then find the first empty slot in storage system after the current invIndex and slot.
  if updateFirstEmpty then
    storageItems.firstEmptyIndex = nil
    storageItems.firstEmptySlot = nil
    for invIndex2 = invIndex, #routing.storage do
      local transIndex, side = next(routing.storage[invIndex2])
      local itemIter = transposers[transIndex].getAllStacks(side)
      for slot2 = (invIndex2 == invIndex and slot or 1), transposers[transIndex].getInventorySize(side) do
        local item2 = itemIter[slot2]
        print("checking slot " .. slot2)
        if item2.size == 0 then
          print("first empty changed to " .. invIndex2 .. ", " .. slot2)
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
    print("amount is 0, bye")
    return
  end
  
  -- If item does not exist in table, add it. Otherwise update the existing entry.
  local fullName = getItemFullName(item)
  if not storageItems[fullName] then
    print("adding new storageItems entry")
    storageItems[fullName] = {}
    storageItems[fullName].maxDamage = item.maxDamage    -- Maximum damage this item can have.
    storageItems[fullName].maxSize = item.maxSize    -- Maximum stack size.
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
      print("insert point changed to " .. invIndex .. ", " .. slot)
      storageItems[fullName].insertIndex = invIndex
      storageItems[fullName].insertSlot = slot
    elseif invIndex > storageItems[fullName].extractIndex or (invIndex == storageItems[fullName].extractIndex and slot > storageItems[fullName].extractSlot) then
      print("extract point changed to " .. invIndex .. ", " .. slot)
      storageItems[fullName].extractIndex = invIndex
      storageItems[fullName].extractSlot = slot
    end
  end
end

-- Remove the items from the storageItems table, and delete the item stack entry
-- in the table if applicable.
local function removeStorageItems(transposers, routing, storageItems, invIndex, slot, item, amount)
  print("removeStorageItems(", transposers, routing, storageItems, invIndex, slot, item, amount, ")")
  if amount == 0 then
    print("amount is 0, bye")
    return
  end
  
  -- Check if first empty slot has now moved to this invIndex/slot.
  local transIndex, side = next(routing.storage[invIndex])
  local itemsRemaining = transposers[transIndex].getSlotStackSize(side, slot)
  if itemsRemaining == 0 and (invIndex < storageItems.firstEmptyIndex or (invIndex == storageItems.firstEmptyIndex and slot < storageItems.firstEmptySlot)) then
    print("first empty changed to " .. invIndex .. ", " .. slot)
    storageItems.firstEmptyIndex = invIndex
    storageItems.firstEmptySlot = slot
  end
  
  -- Update total and check if we can remove the table entry.
  local fullName = getItemFullName(item)
  storageItems[fullName].total = storageItems[fullName].total - amount
  if storageItems[fullName].total == 0 then    -- FIXME may want to change to <= after testing ####################################################
    print("removing item entry for " .. fullName)
    storageItems[fullName] = nil
    return
  end
  
  -- If item stack empty, search for the next extract point and update insertion point if needed. Otherwise update bounds on insert/extract point.
  if itemsRemaining == 0 then
    print("itemsRemaining is zero, find next extract point")
    for invIndex2 = invIndex, 1, -1 do
      local transIndex, side = next(routing.storage[invIndex2])
      local itemIter = transposers[transIndex].getAllStacks(side)
      for slot2 = (invIndex2 == invIndex and slot or transposers[transIndex].getInventorySize(side)), 1, -1 do
        local item2 = itemIter[slot2]
        if item2.size > 0 and getItemFullName(item2) == fullName then
          print("extract point changed to " .. invIndex2 .. ", " .. slot2)
          storageItems[fullName].extractIndex = invIndex2
          storageItems[fullName].extractSlot = slot2
          if invIndex2 < storageItems[fullName].insertIndex or (invIndex2 == storageItems[fullName].insertIndex and slot2 < storageItems[fullName].insertSlot) then
            print("insert point changed to " .. invIndex2 .. ", " .. slot2)
            storageItems[fullName].insertIndex = invIndex2
            storageItems[fullName].insertSlot = slot2
          end
          return
        end
      end
    end
    assert(false, "removeStorageItems() failed: Unable to find next extractIndex/Slot in storage.")
  else
    if invIndex < storageItems[fullName].insertIndex or (invIndex == storageItems[fullName].insertIndex and slot < storageItems[fullName].insertSlot) then
      print("insert point changed to " .. invIndex .. ", " .. slot)
      storageItems[fullName].insertIndex = invIndex
      storageItems[fullName].insertSlot = slot
    end
    if invIndex < storageItems[fullName].extractIndex or (invIndex == storageItems[fullName].extractIndex and slot < storageItems[fullName].extractSlot) then
      print("extract point changed to " .. invIndex .. ", " .. slot)
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
  local numItemsFound = 0
  local transIndex, side = next(routing[invType][invIndex])
  local itemIter = transposers[transIndex].getAllStacks(side)
  local item = itemIter()
  local slot = 1
  while item do
    if next(item) ~= nil then
      local fullName = getItemFullName(item)
      addStorageItems(transposers, routing, storageItems, invIndex, slot, item, item.size, false)
      numItemsFound = numItemsFound + item.size
    end
    item = itemIter()
    slot = slot + 1
  end
  
  return numItemsFound
end

-- FIXME: Probably just want this as a generic "unpack2Vals" function in common #################################################
-- Parse connection and return the transposer index and side as numbers.
local function unpackConnection(connection)
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
    local amountTransferred = transposers[transIndex].transferItem(side, side, amount, srcSlot, destSlot)
    if amountTransferred ~= amount then
      return amountTransferred, srcInvName, srcSlot
    end
    return amountTransferred
  end
  
  -- Add the initial connections from the source inventory.
  for transIndex, side in pairs(routing[srcType][srcIndex]) do
    searchQueue:push_back({transIndex, side})
    transposerLinks[transIndex .. ":" .. side] = "s"    -- Add start links.
    print("adding", transIndex, side)
  end
  
  -- Run breadth-first search to find destination.
  while not searchQueue:empty() do
    local transIndexFirst, sideFirst = table.unpack(searchQueue:front())
    searchQueue:pop_front()
    print("got vals", transIndexFirst, sideFirst)
    
    -- From the current connection, check inventories that are adjacent to the transposer (except the one we started from).
    for invName, side in pairs(routing.transposer[transIndexFirst]) do
      if side ~= sideFirst then
        print("checking", invName, side)
        if invName == destInvName then
          endTransposerLink = transIndexFirst .. ":" .. side
          transposerLinks[endTransposerLink] = transIndexFirst .. ":" .. sideFirst
          print("found it", invName, side)
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
              print("adding", transIndex2, side2)
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
    
    print(transIndex .. " -> " .. srcSide .. ", " .. sinkSide)
    amountTransferred = transposers[transIndex].transferItem(srcSide, sinkSide, amount, firstConnection and srcSlot or 1, connectionStack:empty() and destSlot or 1)
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

-- Very basic insertion into storage network (this does not protect against
-- fragmentation). Returns false if not all of the items could transfer. The
-- srcSlot and amount can be nil.
--[[
local function simpleInsertStorage(transposers, routing, storageItems, srcType, srcIndex, srcSlot, amount)
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
      return true
    end
  end
  
  local srcItem = transposers[srcTransIndex].getStackInSlot(srcSide, srcSlot)
  local srcFullName = getItemFullName(srcItem)
  amount = amount or srcItem.size
  local currType = srcType
  local currIndex = srcIndex
  local currSlot = srcSlot
  
  -- Iterate through entire storage from highest to lowest priority. Attempt to move items to available slots.
  for invIndex, connections in ipairs(routing.storage) do
    local transIndex, side = next(connections)
    local itemIter = transposers[transIndex].getAllStacks(side)
    local item = itemIter()
    local slot = 1
    while item do
      if next(item) == nil then    -- If found an empty slot then we push items here.
        assert(routeItems(transposers, routing, currType, currIndex, currSlot, "storage", invIndex, slot, amount) == amount)
        addStorageItems(storageItems, srcItem, amount)
        return true
      elseif getItemFullName(item) == srcFullName then    -- Else check if we can add to existing stack.
        local amountTransferred, currInvName
        amountTransferred, currInvName, currSlot = routeItems(transposers, routing, currType, currIndex, currSlot, "storage", invIndex, slot, amount)
        addStorageItems(storageItems, srcItem, amountTransferred)
        if amountTransferred == amount then
          return true
        end
        amount = amount - amountTransferred
        currType = string.match(currInvName, "%a+")
        currIndex = tonumber(string.match(currInvName, "%d+"))
      end
      item = itemIter()
      slot = slot + 1
    end
  end
  
  -- Route any stuck items back to where they came from.
  routeItems(transposers, routing, currType, currIndex, currSlot, srcType, srcIndex, srcSlot)
  return false
end
--]]



--checked: addStorageItems, scanInventory, insertStorage
--need to do thorough testing of adding items next (done)
--need to check: removeStorageItems, extractStorage

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



local function insertStorage(transposers, routing, storageItems, srcType, srcIndex, srcSlot, amount)
  print("insertStorage(", transposers, routing, storageItems, srcType, srcIndex, srcSlot, amount, ")")
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
    print("found srcSlot = " .. srcSlot)
  end
  
  local srcItem = transposers[srcTransIndex].getStackInSlot(srcSide, srcSlot)
  local srcFullName = getItemFullName(srcItem)
  -- Clamp amount to the max stack size, and use the item count for the amount if not specified.
  amount = math.min(amount or srcItem.size, srcItem.maxSize)
  local originalAmount = amount
  local currType = srcType
  local currIndex = srcIndex
  local currSlot = srcSlot
  
  -- First, try to insert the items at the insertIndex if item exists in storage (could be full, could be an over-sized slot, etc).
  if storageItems[srcFullName] then
    print("first try insert point at " .. storageItems[srcFullName].insertIndex .. ", " .. storageItems[srcFullName].insertSlot)
    local amountTransferred, currInvName
    amountTransferred, currInvName, currSlot = routeItems(transposers, routing, currType, currIndex, currSlot, "storage", storageItems[srcFullName].insertIndex, storageItems[srcFullName].insertSlot, amount)
    
    -- FIXME update storageItems ONLY
    addStorageItems(transposers, routing, storageItems, storageItems[srcFullName].insertIndex, storageItems[srcFullName].insertSlot, srcItem, amountTransferred, false)
    
    if amountTransferred == amount then
      return true, originalAmount
    end
    print("rip, only transferred " .. amountTransferred .. " of " .. amount)
    amount = amount - amountTransferred
    currType = string.match(currInvName, "%a+")
    currIndex = tonumber(string.match(currInvName, "%d+"))
  end
  
  -- Second, try to insert items at the next available slot of the same type, until extract point reached. Skip if checkedPartials is true.
  if storageItems[srcFullName] and not storageItems[srcFullName].checkedPartials then
    print("second try insert at next partial")
    for invIndex = storageItems[srcFullName].insertIndex, storageItems[srcFullName].extractIndex do
      local transIndex, side = next(routing.storage[invIndex])
      local itemIter = transposers[transIndex].getAllStacks(side)
      local slotStart = (invIndex == storageItems[srcFullName].insertIndex and storageItems[srcFullName].insertSlot or 1)
      local slotEnd = (invIndex == storageItems[srcFullName].extractIndex and storageItems[srcFullName].extractSlot or transposers[transIndex].getInventorySize(side))
      for slot = slotStart, slotEnd do
        local item = itemIter[slot]
        print("checking " .. invIndex .. ", " .. slot)
        if item.size > 0 and getItemFullName(item) == srcFullName then    -- Check if we can add to existing stack. Items may still fail to move here.
          print("found potential partial slot for " .. srcFullName)
          local amountTransferred, currInvName
          amountTransferred, currInvName, currSlot = routeItems(transposers, routing, currType, currIndex, currSlot, "storage", invIndex, slot, amount)
          
          -- FIXME update storageItems and insertIndex ONLY
          addStorageItems(transposers, routing, storageItems, invIndex, slot, item, amountTransferred, false)
          
          if amountTransferred == amount then
            storageItems[srcFullName].insertIndex = invIndex
            storageItems[srcFullName].insertSlot = slot
            return true, originalAmount
          end
          print("rip, only transferred " .. amountTransferred .. " of " .. amount)
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
    print("third try first empty at " .. storageItems.firstEmptyIndex .. ", " .. storageItems.firstEmptySlot)
    assert(routeItems(transposers, routing, currType, currIndex, currSlot, "storage", storageItems.firstEmptyIndex, storageItems.firstEmptySlot, amount) == amount)
    
    storageItems[srcFullName].insertIndex = storageItems.firstEmptyIndex
    storageItems[srcFullName].insertSlot = storageItems.firstEmptySlot
    
    -- FIXME update storageItems, firstEmptyIndex, insertIndex, and possibly extractIndex
    addStorageItems(transposers, routing, storageItems, storageItems.firstEmptyIndex, storageItems.firstEmptySlot, srcItem, amount, true)
    
    return true, originalAmount
  end
  
  --[[
  -- Third, iterate through entire storage from highest to lowest priority. We need to attempt to insert at each point found in case capacities were upgraded.
  print("third iterate through storage")
  for invIndex, connections in ipairs(routing.storage) do
    local transIndex, side = next(connections)
    local itemIter = transposers[transIndex].getAllStacks(side)
    local item = itemIter()
    local slot = 1
    while item do
      print("checking " .. invIndex .. ", " .. slot)
      if next(item) == nil then    -- If found an empty slot then we push items here.
        print("found empty slot")
        assert(routeItems(transposers, routing, currType, currIndex, currSlot, "storage", invIndex, slot, amount) == amount)
        
        -- FIXME update storageItems, firstEmptyIndex, insertIndex, and possibly extractIndex
        addStorageItems(transposers, routing, storageItems, invIndex, slot, item, amount, true)
        
        return true, originalAmount
      elseif getItemFullName(item) == srcFullName then    -- Else check if we can add to existing stack. Items may still fail to move here.
        print("found partial slot")
        local amountTransferred, currInvName
        amountTransferred, currInvName, currSlot = routeItems(transposers, routing, currType, currIndex, currSlot, "storage", invIndex, slot, amount)
        
        -- FIXME update storageItems, firstEmptyIndex, insertIndex, and possibly extractIndex
        addStorageItems(transposers, routing, storageItems, invIndex, slot, item, amountTransferred, false)
        
        if amountTransferred == amount then
          return true, originalAmount
        end
        print("rip, only transferred " .. amountTransferred .. " of " .. amount)
        amount = amount - amountTransferred
        currType = string.match(currInvName, "%a+")
        currIndex = tonumber(string.match(currInvName, "%d+"))
      end
      item = itemIter()
      slot = slot + 1
    end
  end
  --]]
  
  print("routing stuck items back from " .. currType .. currIndex .. ":" .. currSlot)
  -- Route any stuck items back to where they came from.
  routeItems(transposers, routing, currType, currIndex, currSlot, srcType, srcIndex, srcSlot)
  return false, originalAmount - amount
end



-- Very basic extraction from storage network (also does not protect against
-- fragmentation). Returns false if not all of the amount specified could be
-- extracted. The itemName and amount can be nil.
--[[
local function simpleExtractStorage(transposers, routing, storageItems, destType, destIndex, destSlot, itemName, amount)
  assert(destType == "input" or destType == "output" or destType == "drone")
  itemName = itemName or next(storageItems)
  if not storageItems[itemName] then
    return false
  end
  amount = amount or math.min(storageItems[itemName].total, storageItems[itemName].maxSize)
  
  -- Find the first empty slot to choose as a destination if not given.
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
      return false
    end
  end
  
  
  -- current problem here:
  -- what if we can't stack the items pulled into the same slot? (e.g. memory sticks with NBT)
  -- maybe just consider this for the next version of extractStorage()
  -- possible solution:
  -- 1. consider NBT items as a different item type
  -- 2. extract storage can be called multiple times as needed
  
  
  -- Iterate through entire storage from lowest to highest priority. Attempt to move items to available slots.
  for invIndex = #routing.storage, 1, -1 do
    local transIndex, side = next(routing.storage[invIndex])
    local itemIter = transposers[transIndex].getAllStacks(side)
    for slot = transposers[transIndex].getInventorySize(side), 1, -1 do
      local item = itemIter[slot]
      if item.size > 0 and getItemFullName(item) == itemName then
        local amountTransferred, currInvName, currSlot = routeItems(transposers, routing, "storage", invIndex, slot, destType, destIndex, destSlot, math.min(item.size, amount))
        removeStorageItems(storageItems, item, amountTransferred)
        if amountTransferred == amount then    -- If all items sent, success.
          return true
        elseif amountTransferred < item.size then    -- Else the destination must be full, move the remaining items back.
          local currType = string.match(currInvName, "%a+")
          local currIndex = tonumber(string.match(currInvName, "%d+"))
          routeItems(transposers, routing, currType, currIndex, currSlot, "storage", invIndex, slot, item.size - amountTransferred)
          return false
        end
        amount = amount - amountTransferred
      end
    end
  end
  
  return false
end
--]]


-- ############################################################################################################################################################################################################################
-- ############################################################################################################################################################################################################################
-- ############################################################################################################################################################################################################################


local function extractStorage(transposers, routing, storageItems, destType, destIndex, destSlot, itemName, amount)
  print("extractStorage(", transposers, routing, storageItems, destType, destIndex, destSlot, itemName, amount, ")")
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
  amount = math.min((amount or storageItems[itemName].total), storageItems[itemName].maxSize)
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
    print("found destSlot = " .. destSlot)
  end
  
  -- First, try to extract the items at the extractIndex.
  -- FIXME try to combine items into the partial stack to match the amount by checking nearby slots (only worry about this here, not much point to do it in the storage traversal).
  -- May not always work and this is ok, but when it does we send the items in one routing operation. Note, this could update firstEmptyIndex/insertIndex/extractIndex oof. #########################################################
  do
    print("first try extract point at " .. storageItems[itemName].extractIndex .. ", " .. storageItems[itemName].extractSlot)
    local transIndex, side = next(routing.storage[storageItems[itemName].extractIndex])
    local item = transposers[transIndex].getStackInSlot(side, storageItems[itemName].extractSlot)
    local sendAmount = math.min(item.size, amount)
    local amountTransferred, currInvName, currSlot = routeItems(transposers, routing, "storage", storageItems[itemName].extractIndex, storageItems[itemName].extractSlot, destType, destIndex, destSlot, sendAmount)
    
    if amountTransferred < sendAmount then    -- The destination must be full, move the remaining items back.
      local currType = string.match(currInvName, "%a+")
      local currIndex = tonumber(string.match(currInvName, "%d+"))
      routeItems(transposers, routing, currType, currIndex, currSlot, "storage", storageItems[itemName].extractIndex, storageItems[itemName].extractSlot, sendAmount - amountTransferred)
    end
    
    -- FIXME update storageItems and possibly firstEmptyIndex/insertIndex/extractIndex
    removeStorageItems(transposers, routing, storageItems, storageItems[itemName].extractIndex, storageItems[itemName].extractSlot, item, amountTransferred)
    
    if amountTransferred == amount then
      return true, originalAmount
    elseif amountTransferred < sendAmount then
      return false, amountTransferred
    end
    print("rip, only transferred " .. amountTransferred .. " of " .. amount)
    amount = amount - amountTransferred
  end
  
  -- Second, iterate from storageItems[itemName].extractIndex/Slot going lowest to highest priority to find another instance of the item.
  print("second find next extract point and try extract")
  for invIndex = storageItems[itemName].extractIndex, 1, -1 do
    local transIndex, side = next(routing.storage[invIndex])
    local itemIter = transposers[transIndex].getAllStacks(side)
    for slot = (invIndex == storageItems[itemName].extractIndex and storageItems[itemName].extractSlot or transposers[transIndex].getInventorySize(side)), 1, -1 do
      local item = itemIter[slot]
      print("checking " .. invIndex .. ", " .. slot)
      if item.size > 0 and getItemFullName(item) == itemName then
        print("found extract slot for " .. itemName)
        local sendAmount = math.min(item.size, amount)
        local amountTransferred, currInvName, currSlot = routeItems(transposers, routing, "storage", invIndex, slot, destType, destIndex, destSlot, sendAmount)
        
        if amountTransferred < sendAmount then    -- The destination must be full, move the remaining items back.
          local currType = string.match(currInvName, "%a+")
          local currIndex = tonumber(string.match(currInvName, "%d+"))
          routeItems(transposers, routing, currType, currIndex, currSlot, "storage", invIndex, slot, sendAmount - amountTransferred)
        end
        
        -- FIXME update storageItems, possibly firstEmptyIndex, possibly insertIndex, and extractIndex
        removeStorageItems(transposers, routing, storageItems, invIndex, slot, item, amountTransferred)
        
        if amountTransferred == amount then
          return true, originalAmount
        elseif amountTransferred < sendAmount then
          return false, originalAmount - amount + amountTransferred
        end
        print("rip, only transferred " .. amountTransferred .. " of " .. amount)
        amount = amount - amountTransferred
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
  local transposers, routing = loadRoutingConfig(ROUTING_CONFIG_FILENAME)
  
  print(" - routing - ")
  tdebug.printTable(routing)
  
  io.write("Running full inventory scan, please wait...\n")
  
  -- FIXME we probably want to run a similar process here for transfer and drone inventories to flush out the system. ##################################################
  local storageItems = {}
  addStorageItems(transposers, routing, storageItems, 1, 1, nil, 0, true)    -- Update firstEmptyIndex/Slot.
  for invIndex = 1, #routing.storage do
    print("found items: " .. scanInventory(transposers, routing, storageItems, "storage", invIndex))
  end
  
  print(" - items - ")
  tdebug.printTable(storageItems)
  
  while true do
    io.write("> ")
    local input = io.read()
    input = text.tokenize(input)
    if input[1] == "l" then    -- List.
      io.write("Storage contents:\n")
      for itemName, itemDetails in pairs(storageItems) do
        if itemName ~= "firstEmptyIndex" and itemName ~= "firstEmptySlot" then
          io.write("  " .. itemDetails.total .. "  " .. itemName .. "\n")
        end
      end
    elseif input[1] == "r" then    -- Request.
      print("result = ", extractStorage(transposers, routing, storageItems, "output", 1, nil, input[2], tonumber(input[3])))
    elseif input[1] == "a" then    -- Add.
      print("result = ", insertStorage(transposers, routing, storageItems, "input", 1))
    elseif input[1] == "d" then
      print(" - items - ")
      tdebug.printTable(storageItems)
    elseif input[1] == "exit" then
      break
    else
      print("Enter \"l\" to list, \"r <item> <count>\" to request, \"a\" to add, or \"exit\" to quit.")
    end
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
