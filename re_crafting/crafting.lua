
local common = require("common")
local component = require("component")
local computer = require("computer")
local event = require("event")
local modem = component.modem
local serialization = require("serialization")
local sides = require("sides")
local tdebug = require("tdebug")
local term = require("term")
local text = require("text")
local thread = require("thread")
local wnet = require("wnet")

local COMMS_PORT = 0xE298

-- FIXME this should be used everywhere #############################################################################################################
-- As of writing, the checkArg() builtin is bugged out for table types. Here is
-- a fixed implementation.
local function checkArg2(...)
  local arg = table.pack(...)
  for i = 1, arg.n do
    if i % 3 == 0 then
      assert(arg[i] == type(arg[i - 1]), "bad argument #" .. arg[i - 2] .. " (" .. arg[i] .. " expected, got " .. type(arg[i - 1]) .. ")")
    end
  end
end

-- Verify string has item name format "<mod name>:<item name>/<damage>[n]".
-- Allows skipping the damage value (which then defaults to zero).
local function stringToItemName(s)
  s = string.lower(s)
  if not string.find(s, "/") then
    s = s .. "/0"
  end
  assert(string.match(s, "[%w_]+:[%w_]+/%d+n?") == s, "Item name does not have valid format.")
  return s
end

-- Verify string has integer format (no decimals). If minVal is provided then
-- this is the lower bound for the integer.
local function stringToInteger(s, minVal)
  minVal = minVal or math.mininteger
  local x = tonumber(s)
  assert(not string.find(s, "[^%d-]") and x, "Invalid format for integer value.")
  assert(x >= minVal, "Integer must be greater than or equal to " .. minVal .. ".")
  return x
end

local function loadRecipes(stations, recipes, filename)
  checkArg2(1, stations, "table", 2, recipes, "table", 3, filename, "string")
  
  -- Parses one line of the file, checks for errors and syntax, and adds new data to the tables.
  local parseState = ""
  local stationEntry, stationName, recipeEntry
  local function loadRecipesParser(line, lineNum)
    local tokens = text.tokenize(line)
    if parseState == "re_inp" then    -- Within recipe inputs definition.
      if not (next(tokens) == nil or string.byte(tokens[1], #tokens[1]) == string.byte(":", 1) or tokens[1] == "station") then
        if stationName == "craft" then    -- <item name> <slot index 1> <slot index 2> ...
          assert(tokens[2], "Expected \"<item name> <slot index 1> <slot index 2> ...\".")
          local itemName = stringToItemName(tokens[1])
          local usedSlots = {}
          for _, input in ipairs(recipeEntry.inp) do
            if input[1] == itemName then
              assert(false, "Duplicate input item name \"" .. itemName .. "\".")
            end
            for i = 2, #input do
              usedSlots[input[i]] = true
            end
          end
          recipeEntry.inp[#recipeEntry.inp + 1] = {itemName}
          local recipeInputEntry = recipeEntry.inp[#recipeEntry.inp]
          for i = 2, #tokens do
            local slotNumber = stringToInteger(tokens[i], 1)
            assert(not usedSlots[slotNumber], "Duplicate slot number " .. slotNumber .. ".")
            recipeInputEntry[#recipeInputEntry + 1] = slotNumber
            usedSlots[slotNumber] = true
          end
        else    -- <count> <item name>
          assert(not tokens[3], "Expected \"<count> <item name>\".")
          local itemName = stringToItemName(tokens[2])
          for _, input in ipairs(recipeEntry.inp) do
            if input[1] == itemName then
              assert(false, "Duplicate input item name \"" .. itemName .. "\".")
            end
          end
          recipeEntry.inp[#recipeEntry.inp + 1] = {itemName, stringToInteger(tokens[1], 1)}
        end
        return
      end
    end
    
    if parseState == "re_out" then    -- Within recipe outputs definition.
      if tokens[1] == "with" then
        assert(not tokens[2], "Unexpected data after \"with\".")
        parseState = "re_inp"
      else    -- <count> <item name> "<item label>"
        local itemLabel = string.match(line, "\"(.*)\"")
        assert(itemLabel, "Expected \'<count> <item name> \"<item label>\"\'.")
        assert(not recipeEntry.out[stringToItemName(tokens[2])], "Duplicate output item name \"" .. stringToItemName(tokens[2]) .. "\".")
        recipeEntry.out[stringToItemName(tokens[2])] = stringToInteger(tokens[1], 1)
        recipes[stringToItemName(tokens[2])] = recipes[stringToItemName(tokens[2])] or {}
        local itemNameEntry = recipes[stringToItemName(tokens[2])]
        itemNameEntry.label = itemLabel
        itemNameEntry[#itemNameEntry + 1] = #recipes
      end
    elseif parseState == "st" then    -- Within station definition.
      if tokens[1] == "in" then    -- in <x> <y> <z> <down|up|north|south|west|east>
        assert(sides[tokens[5]] and not tokens[6], "Expected \"in <x> <y> <z> <down|up|north|south|west|east>\" with integer coords.")
        assert(not stationEntry.inp, "Station must have only one input.")
        stationEntry.inp = {stringToInteger(tokens[2]), stringToInteger(tokens[3]), stringToInteger(tokens[4]), sides[tokens[5]]}
      elseif tokens[1] == "out" then    -- out <x> <y> <z> <down/up/north/south/west/east>
        assert(sides[tokens[5]] and not tokens[6], "Expected \"out <x> <y> <z> <down|up|north|south|west|east>\" with integer coords.")
        assert(not stationEntry.out, "Station must have only one output.")
        stationEntry.out = {stringToInteger(tokens[2]), stringToInteger(tokens[3]), stringToInteger(tokens[4]), sides[tokens[5]]}
      elseif tokens[1] == "path" then    -- path<n> <x> <y> <z>
        
      elseif tokens[1] == "time" then    -- time <average seconds for 1 unit>
        
      elseif tokens[1] == "type" then    -- type default|sequential|bulk
        
      elseif tokens[1] == "end" then    -- end
        assert(not tokens[2], "Unexpected data after \"end\".")
        assert(stationEntry.inp, "No input provided for station.")
        stationEntry.out = stationEntry.out or stationEntry.inp
        parseState = ""
      else
        assert(false, "Unexpected data \"" .. tokens[1] .. "\".")
      end
    elseif string.byte(tokens[1], #tokens[1]) == string.byte(":", 1) then    -- <station name>:
      assert(#tokens[1] > 1 and string.find(tokens[1], "[^%w_]") == #tokens[1] and not tokens[2], "Station name must contain only alphanumeric characters and underscores (with a colon at end).")
      stationName = string.sub(tokens[1], 1, #tokens[1] - 1)
      recipes[#recipes + 1] = {}
      recipeEntry = recipes[#recipes]
      recipeEntry.out = {}
      recipeEntry.inp = {}
      if stationName ~= "craft" then
        recipeEntry.station = stationName
      end
      parseState = "re_out"
    elseif tokens[1] == "station" then    -- station <station name>
      assert(not (string.find(tokens[2], "[^%w_]") or tokens[3]), "Station name must contain only alphanumeric characters and underscores.")
      local n = 1
      while stations[tokens[2] .. n] do
        n = n + 1
      end
      stations[tokens[2] .. n] = {}
      stationEntry = stations[tokens[2] .. n]
      parseState = "st"
    else
      assert(false, "Unexpected data \"" .. tokens[1] .. "\".")
    end
  end
  
  -- Open file and for each line trim whitespace, skip empty lines, and lines beginning with comment symbol '#'. Parse the rest.
  local file = io.open(filename, "r")
  local lineNum = 1
  
  local status, msg = pcall(function()
    for line in file:lines() do
      line = text.trim(line)
      if line ~= "" and string.byte(line, 1) ~= string.byte("#", 1) then
        loadRecipesParser(line, lineNum)
      end
      lineNum = lineNum + 1
    end
  end)
  if not status then
    assert(false, "In file \"" .. filename .. "\" at line " .. lineNum .. ": " .. msg)
  end
  
  file:close()
end

--[[

stations: {
  <station name><num>: {
    inp: {<x>, <y>, <z>, <down/up/north/south/west/east>}
    [out: {<x>, <y>, <z>, <down/up/north/south/west/east>}]
    [path1: {<x>, <y>, <z>}]
    time: <average seconds for 1 unit, 0 if not provided>
    type: <nil/sequential/bulk>
  }
  craft1: {
    inp: {<x>, <y>, <z>, <down/up/north/south/west/east>}
    [out: {<x>, <y>, <z>, <down/up/north/south/west/east>}]
    [path1: {<x>, <y>, <z>}]                                 -- may not need most of these if we do the robot-adjacent-to-drone-inventory idea.
    time: <average seconds for 1 unit, 0 if not provided>    -- do we need this for crafting??
  }
  ...
}

recipes: {
  1: {    -- Processing recipe.
    out: {
      <item name>: amount
      ...
    }
    inp: {
      1: {<item name>, amount}
      2: {<item name>, amount}
      ...
    }
    station: <station name>
  }
  2: {    -- Crafting recipe.
    out: {
      <item name>: amount
      ...
    }
    inp: {
      1: {<item name>, <slot num>}
      2: {<item name>, <slot num>, <slot num>}
      ...
    }
  }
  ...
  <item name>: {
    label: <item label>
    1: <recipe index>
    ...
  }
  ...
}

--]]

-- Called once after each recipe file has been scanned in. Confirms that for
-- each recipe, its corresponding station has been defined.
local function verifyRecipes(stations, recipes)
  checkArg2(1, stations, "table", 2, recipes, "table")
  for i, recipe in ipairs(recipes) do
    if recipe.station and not stations[recipe.station .. "1"] then
      assert(false, "Recipe " .. i .. " for " .. next(recipe.out) .. " requires station " .. recipe.station .. ", but station not found.")
    end
  end
end

local function solveDependencyGraph(stations, recipes, storageItems, itemName, amount)
  checkArg2(1, stations, "table", 2, recipes, "table", 3, storageItems, "table", 4, itemName, "string", 5, amount, "number")
  local defaultZeroMeta = {__index = function() return 0 end}
  local requiredItems = {}
  setmetatable(requiredItems, defaultZeroMeta)
  local remainingRecipes = {[itemName]=amount}
  setmetatable(remainingRecipes, defaultZeroMeta)
  
  
  local bestCraftingAmount = math.huge    -- Best minimum number of items to craft found thus far.
  
  --local recipeStack = common.Deque:new()
  --while not recipeStack:empty() do
    
  --end
  
  print("crafting " .. amount .. " of " .. itemName)
  
  local function recursiveBuild(spacing)
    spacing = spacing or ""
    print(spacing .. "recursiveBuild()")
    local recipeName, recipeAmount = next(remainingRecipes)
    for _, idx in ipairs(recipes[recipeName]) do
      print(spacing .. "trying recipe " .. idx .. " for " .. recipeName)
      
      -- If there are multiple recipe options, make a backup copy of requiredItems/remainingRecipes first and restore them later.
      local requiredItems2, remainingRecipes2
      if #recipes[recipeName] > 1 then
        print(spacing .. "multiple recipes, making copy of tables...")
        
        requiredItems2 = requiredItems
        requiredItems = {}
        for k, v in pairs(requiredItems2) do
          requiredItems[k] = v
        end
        setmetatable(requiredItems, defaultZeroMeta)
        
        remainingRecipes2 = remainingRecipes
        remainingRecipes = {}
        for k, v in pairs(remainingRecipes2) do
          remainingRecipes[k] = v
        end
        setmetatable(remainingRecipes, defaultZeroMeta)
      end
      
      -- Compute amount multiplier as the number of items we need to craft over the number of items we get from the recipe (rounded up).
      local mult = math.ceil(recipeAmount / recipes[idx].out[recipeName])
      
      -- For each recipe input, add the items to requiredItems and to remainingRecipes as well if we need to craft more of them.
      for _, input in ipairs(recipes[idx].inp) do
        local inputName = input[1]
        local addAmount = mult * (recipes[idx].station and input[2] or #input - 1)
        local availableAmount = (storageItems[inputName] and storageItems[inputName].total or 0) - requiredItems[inputName]
        
        -- Add the addAmount minus positive component of availableAmount to remainingRecipes if we need more than what's available and the recipe is known.
        if addAmount > availableAmount and recipes[inputName] then
          print(spacing .. "craft " .. addAmount - math.max(availableAmount, 0) .. " more of " .. inputName)
          remainingRecipes[inputName] = remainingRecipes[inputName] + addAmount - math.max(availableAmount, 0)
        end
        
        print(spacing .. "require " .. addAmount .. " more of " .. inputName)
        requiredItems[inputName] = requiredItems[inputName] + addAmount
      end
      
      -- For each recipe output, remove from requiredItems.
      for outputName, amount in pairs(recipes[idx].out) do
        print(spacing .. "add " .. -mult * amount .. " of output " .. outputName)
        requiredItems[outputName] = requiredItems[outputName] - mult * amount
        if requiredItems[outputName] == 0 then
          requiredItems[outputName] = nil
        end
      end
      
      -- If no more recipes remaining, solution found. Otherwise we do recursive call.
      remainingRecipes[recipeName] = nil
      if next(remainingRecipes) == nil then
        print(spacing .. "found solution")
        print("requiredItems:")
        tdebug.printTable(requiredItems)
        local totalCraftingAmount = 0
        for k, v in pairs(requiredItems) do
          totalCraftingAmount = totalCraftingAmount + math.max(v - (storageItems[k] and storageItems[k].total or 0), 0)
        end
        print("totalCraftingAmount = " .. totalCraftingAmount)
        if totalCraftingAmount < bestCraftingAmount then
          print("new best found!!!")
          bestCraftingAmount = totalCraftingAmount
        end
      else
        recursiveBuild(spacing .. "  ")
      end
      
      -- Restore state of requiredItems and remainingRecipes.
      print(spacing .. "end of recipe loop, restore state")
      if #recipes[recipeName] > 1 then
        requiredItems = requiredItems2
        remainingRecipes = remainingRecipes2
      else
        remainingRecipes[recipeName] = recipeAmount
      end
    end
  end
  recursiveBuild()
  
  print("done, requiredItems:")
  tdebug.printTable(requiredItems)
  print("remainingRecipes:")
  tdebug.printTable(remainingRecipes)
end

--[[

edge cases:
crafting requested for a non-craftable item?
recipe impossible to craft? (crafting 1 of x requires 1 of x not possible, but crafting 4 of x with 1 of x may be possible)

ex:
16 torch
  try coal recipe
  4 stick
  4 coal (don't have coal, but we keep going since no solution yet)
    try stick recipe
    2 planks
      try planks recipe
      1 wood (+2 planks left over) <- add negative value to requiredItems
        Found a potential solution.
  no coal, try charcoal recipe
  ...

requiredItems = {}
remainingRecipes = {[itemName]=amount}
storageAmount for anything = actualStorageAmount - (requiredItems[item] or 0)

get first targetItem from remainingRecipes
  for each recipe that makes targetItem do
    make copy of requiredItems and remainingRecipes if more than one recipe
    multiplier = ceil(itemAmount / recipeAmount)
    for each recipe input do
      add input to requiredItems with amount multiplier * inputAmount
      if amount > storageAmount and solution found already and we don't have recipe for input, skip to next recipe in outer for loop
      add input to remainingRecipes if amount > storageAmount and we have recipe for input
        this amount is multiplier * inputAmount - storageAmount
    end
    add output to requiredItems with amount -1 * multiplier * recipeAmount
    if requiredItems[output] is zero, remove the entry
    remove targetItem from remainingRecipes


craft:
4 minecraft:planks "Oak Wood Planks"
with
minecraft:log 1

craft:
4 minecraft:stick "Stick"
with
minecraft:planks 1 4

craft:
4 minecraft:torch "Torch"
with
minecraft:coal 1
minecraft:stick 4

craft:
4 minecraft:torch "Torch"
with
minecraft:coal/1 1
minecraft:stick 4

requiredItems = {}
remainingRecipes = {torch=16}
targetItem = torch 16
  recipe = coal type
    multiplier = ceil(16 / 4) = 4
    input = coal
      requiredItems = {coal=0+4}
      (don't have coal recipe)
    input = stick
      requiredItems = {coal=4, stick=0+4}
      remainingRecipes = {torch=16, stick=0+4-0}
    requiredItems = {coal=4, stick=0+4, torch=0-16}
    remainingRecipes = {stick=0+4-0}
    targetItem = stick 4
      recipe = stick
        multiplier = ceil(4 / 4) = 1
        input = planks
          
  recipe = charcoal type
    multiplier = ceil(16 / 4) = 4
    input = charcoal
    input = stick

new idea instead of remainingRecipes:
recipeItems   = {torch, charcoal, stick, log, planks, log}  (log made from wood essence)
recipeAmounts = {   16,        4,     4,   4,      2,   1}
now run collation over tables to find crafting steps required. can also group itemName and amount together if needed.
  by collation, we risk creating a scenario where the item needs itself to craft and we don't have all the required amount, need to handle this by confirming we have all ingredients.
we iterate tables in reverse to find the sequence of steps to run in parallel.

3 x = 2 x + 1 y
100 x from 2 x = ? y

2 3 4 5 6 7 ... 100

0 1 2 3 4 5 ... 98

--]]

local function main()
  local threadSuccess = false
  -- Captures the interrupt signal to stop program.
  local interruptThread = thread.create(function()
    event.pull("interrupted")
  end)
  
  local stations, recipes, storageServerAddress, storageItems, interfaceServerAddresses
  local netLog = ""
  
  -- Performs setup and initialization tasks.
  local setupThread = thread.create(function()
    modem.open(COMMS_PORT)
    wnet.debug = true
    interfaceServerAddresses = {}
    
    io.write("Loading recipes...\n")
    stations = {}
    recipes = {}
    loadRecipes(stations, recipes, "recipes/torches.craft")
    loadRecipes(stations, recipes, "recipes/plates.proc")
    verifyRecipes(stations, recipes)
    
    --tdebug.printTable(stations)
    --tdebug.printTable(recipes)
    
    -- Contact the storage server.
    local attemptNumber = 1
    local lastAttemptTime = 0
    while not storageServerAddress do
      if computer.uptime() >= lastAttemptTime + 2 then
        lastAttemptTime = computer.uptime()
        term.clearLine()
        io.write("Trying to contact storage server on port " .. COMMS_PORT .. " (attempt " .. attemptNumber .. ")...")
        wnet.send(modem, nil, COMMS_PORT, "stor_discover,")
        attemptNumber = attemptNumber + 1
      end
      local address, port, data = wnet.receive(0.1)
      if port == COMMS_PORT then
        local dataType = string.match(data, "[^,]*")
        data = string.sub(data, #dataType + 2)
        if dataType == "craftinter_item_list" then
          storageItems = serialization.unserialize(data)
          storageServerAddress = address
        end
      end
    end
    io.write("\nSuccess.\n")
    
    solveDependencyGraph(stations, recipes, storageItems, "minecraft:torch/0", 16)
    
    threadSuccess = true
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
    while true do
      local address, port, data = wnet.receive()
      if port == COMMS_PORT then
        local dataType = string.match(data, "[^,]*")
        data = string.sub(data, #dataType + 2)
        
        if dataType == "craftinter_item_diff" then
          -- Apply the items diff to storageItems to keep the table synced up.
          local itemsDiff = serialization.unserialize(data)
          for itemName, diff in pairs(itemsDiff) do
            if diff.total == 0 then
              storageItems[itemName] = nil
            elseif storageItems[itemName] then
              storageItems[itemName].total = diff.total
            else
              storageItems[itemName] = {}
              storageItems[itemName].label = diff.label
              storageItems[itemName].total = diff.total
            end
          end
        elseif dataType == "craftinter_stor_started" then
          -- If we get a broadcast that storage started, it must have just rebooted and we need to discover new storageItems.
          wnet.send(modem, address, COMMS_PORT, "stor_discover,")
        elseif dataType == "craftinter_item_list" then
          -- New item list, update storageItems.
          storageItems = serialization.unserialize(data)
          storageServerAddress = address
        elseif dataType == "craft_discover" then
          -- Interface is searching for this crafting server, respond with list of recipes.
          interfaceServerAddresses[address] = true
          local recipeItems = {}
          for k, v in pairs(recipes) do
            if type(k) == "string" then
              recipeItems[k] = v.label
            end
          end
          wnet.send(modem, address, COMMS_PORT, "inter_recipe_list," .. serialization.serialize(recipeItems))
        elseif dataType == "craft_check_recipe" then
          interfaceServerAddresses[address] = true
          local itemName = string.match(data, "[^,]*")
          local amount = string.match(data, "[^,]*", #itemName + 2)
          print("crafting item " .. itemName .. " and amount " .. amount .. ".")
          print("result = ", tonumber(amount))
        end
      end
    end
  end)
  
  --[[
  local listenThread = thread.create(function()
    while true do
      local address, port, data = wnet.receive()
      if address then
        netLog = netLog .. "Packet from " .. string.sub(address, 1, 5) .. ":" .. port .. " <- " .. string.format("%q", data) .. "\n"
      end
    end
  end)
  --]]
  
  local commandThread = thread.create(function()
    while true do
      io.write("> ")
      local input = io.read()
      input = text.tokenize(input)
      if input[1] == "up" then
        local file = io.open("drone_up.lua")
        local sourceCode = file:read(10000000)
        io.write("Uploading \"drone_up.lua\"...\n")
        wnet.send(modem, nil, COMMS_PORT, "drone_upload," .. sourceCode)
      elseif input[1] == "exit" then
        threadSuccess = true
        break
      elseif input[1] == "log" then
        io.write(netLog)
      else
        io.write("Enter \"up\" to upload, or \"exit\" to quit.\n")
      end
    end
  end)
  
  thread.waitForAny({interruptThread, modemThread, commandThread})
  if interruptThread:status() == "dead" then
    os.exit(1)
  elseif not threadSuccess then
    io.stderr:write("Error occurred in thread, check log file \"/tmp/event.log\" for details.\n")
    os.exit(1)
  end
  
  interruptThread:kill()
  modemThread:kill()
  commandThread:kill()
end

main()
