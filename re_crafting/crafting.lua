
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

-- Parse a recipe file containing information about crafting stations and the
-- recipes made there (item inputs and outputs).
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
      else    -- <count> <item name> "<item label>" <max stack size>
        local itemLabel = string.match(line, "\"(.*)\"")
        assert(itemLabel, "Expected \'<count> <item name> \"<item label>\"\'.")
        assert(not recipeEntry.out[stringToItemName(tokens[2])], "Duplicate output item name \"" .. stringToItemName(tokens[2]) .. "\".")
        recipeEntry.out[stringToItemName(tokens[2])] = stringToInteger(tokens[1], 1)
        recipes[stringToItemName(tokens[2])] = recipes[stringToItemName(tokens[2])] or {}
        local itemNameEntry = recipes[stringToItemName(tokens[2])]
        itemNameEntry.maxSize = stringToInteger(tokens[#tokens], 1)
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
    maxSize: <max stack size>
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

-- Searches for the sequence of recipes and their amounts needed to craft the
-- target item. This uses a recursive algorithm that walks the dependency graph
-- and tries each applicable recipe for the currently needed item one at a time.
-- Returns a string status ("ok", "missing", etc), two table arrays containing
-- the sequence of recipe indices and the amount of each recipe to craft, and a
-- third table that matches required items to their amounts (using negative
-- values for output items).
-- Currently this algorithm is not perfect, auto-crafting has been proven to be
-- NP-hard so there is no perfect solution that exists (see
-- https://squiddev.github.io/ae-sat/). Recipes that are recursive (an item is
-- crafted with itself, or a chain like A->B, B->C, C->A) and recipes that
-- should be split to make the item (need 8 torches but only have 1 coal and 1
-- charcoal) can not be solved properly right now.
-- 
-- FIXME if have time, improve this to handle the above drawbacks. ##############################################################################
local function solveDependencyGraph(stations, recipes, storageItems, itemName, amount)
  checkArg2(1, stations, "table", 2, recipes, "table", 3, storageItems, "table", 4, itemName, "string", 5, amount, "number")
  if not recipes[itemName] then
    return "No recipe found for \"" .. itemName .. "\"."
  end
  
  local defaultZeroMeta = {__index = function() return 0 end}
  local requiredItems = {}
  setmetatable(requiredItems, defaultZeroMeta)
  
  -- Sequence of recipe name, index, and amount we need to craft to make the item.
  -- Beginning of array is the requested item and end of array is the item at the bottom of the dependency chain.
  local craftNames = {itemName}
  local craftIndices = {}
  local craftAmounts = {amount}
  
  local resultStatus, resultIndices, resultBatches, resultItems
  
  --local bestCraftingTotal = math.huge    -- Best minimum number of items to craft found thus far.
  local numMissingItems = 0
  local bestMissingItems = math.huge
  
  --local recipeStack = common.Deque:new()
  --while not recipeStack:empty() do
    
  --end
  
  print("crafting " .. amount .. " of " .. itemName)
  
  --local MIX = false
  
  local function recursiveSolve(spacing, index)
    assert(index < 50, "Recipe too complex or not possible.")    -- FIXME may want to limit the max number of calls in addition to max depth. ############################################
    print(spacing .. "recursiveSolve(" .. index .. ")")
    for _, recipeIndex in ipairs(recipes[craftNames[index]]) do
      print(spacing .. "trying recipe " .. recipeIndex .. " for " .. craftNames[index])
      craftIndices[index] = recipeIndex
      
      -- If there are multiple recipe options, make a backup copy of requiredItems, length of craftNames, and numMissingItems to restore later.
      local requiredItems2, lastCraftNamesLength, numMissingItems2
      if #recipes[craftNames[index]] > 1 then
        print(spacing .. "multiple recipes, making copy of table...")
        
        requiredItems2 = requiredItems
        requiredItems = {}
        for k, v in pairs(requiredItems2) do
          requiredItems[k] = v
        end
        setmetatable(requiredItems, defaultZeroMeta)
        
        lastCraftNamesLength = #craftNames
        numMissingItems2 = numMissingItems
      end
      
      -- Compute amount multiplier as the number of items we need to craft over the number of items we get from the recipe (rounded up).
      local mult = math.ceil(craftAmounts[index] / recipes[recipeIndex].out[craftNames[index]])
      
      --[[
      -- If mixing, scale the multiplier down to the limiting input in recipe first.
      if MIX then
        for _, input in ipairs(recipes[recipeIndex].inp) do
          local inputName = input[1]
          local recipeAmount = (recipes[recipeIndex].station and input[2] or #input - 1)
          local availableAmount = math.max((storageItems[inputName] and storageItems[inputName].total or 0) - requiredItems[inputName], 0)
          
          if mult * recipeAmount > availableAmount and recipes[inputName] then
            mult = math.floor(availableAmount / recipeAmount)
          end
        end
      end
      --]]
      
      -- For each recipe input, add the items to requiredItems and to craftNames/craftAmounts as well if we need to craft more of them.
      for _, input in ipairs(recipes[recipeIndex].inp) do
        local inputName = input[1]
        local addAmount = mult * (recipes[recipeIndex].station and input[2] or #input - 1)
        local availableAmount = math.max((storageItems[inputName] and storageItems[inputName].total or 0) - requiredItems[inputName], 0)
        
        -- Check if we need more than what's available.
        if addAmount > availableAmount then
          if recipes[inputName] then
            -- Add the addAmount minus availableAmount to craftNames/craftAmounts if the recipe is known.
            print(spacing .. "craft " .. addAmount - availableAmount .. " more of " .. inputName)
            craftNames[#craftNames + 1] = inputName
            craftAmounts[#craftAmounts + 1] = addAmount - availableAmount
          else
            -- Recipe not known so this item will prevent crafting, add to numMissingItems.
            print(spacing .. "missing " .. addAmount - availableAmount .. " of " .. inputName)
            numMissingItems = numMissingItems + addAmount - availableAmount
          end
        end
        
        print(spacing .. "require " .. addAmount .. " more of " .. inputName)
        requiredItems[inputName] = requiredItems[inputName] + addAmount
      end
      
      -- For each recipe output, remove from requiredItems.
      for outputName, amount in pairs(recipes[recipeIndex].out) do
        print(spacing .. "add " .. -mult * amount .. " of output " .. outputName)
        requiredItems[outputName] = requiredItems[outputName] - mult * amount
        if requiredItems[outputName] == 0 then
          requiredItems[outputName] = nil
        end
      end
      
      -- If no more recipes remaining, solution found. Otherwise we do recursive call.
      if not craftNames[index + 1] then
        print(spacing .. "found solution, numMissingItems = " .. numMissingItems)
        print("requiredItems and craftNames/craftIndices/craftAmounts:")
        tdebug.printTable(requiredItems)
        for i = 1, #craftNames do
          print(craftNames[i] .. " index " .. craftIndices[i] .. " amount " .. craftAmounts[i])
        end
        
        --[[
        -- Determine the total number of items to craft and compare with the best found so far.
        local craftingTotal = 0
        for k, v in pairs(requiredItems) do
          craftingTotal = craftingTotal + math.max(v - (storageItems[k] and storageItems[k].total or 0), 0)
        end
        print("craftingTotal = " .. craftingTotal)
        --]]
        -- Check if the total number of missing items is a new low, and update the result if so.
        if numMissingItems < bestMissingItems then
          print("new best found!!!")
          bestMissingItems = numMissingItems
          if numMissingItems == 0 then
            resultStatus = "ok"
          else
            resultStatus = "missing"
          end
          
          -- Build the result of recipe indices and batch amounts from craftNames/craftIndices/craftAmounts.
          -- We iterate the craft stuff in reverse and push to the result array, if another instance of the same recipe pops up then we combine it with the previous one.
          resultIndices = {}
          resultBatches = {}
          local indicesMapping = {}
          local j = 1
          for i = #craftNames, 1, -1 do
            local recipeIndex = craftIndices[i]
            -- Compute the multiplier exactly as we did before.
            local mult = math.ceil(craftAmounts[i] / recipes[recipeIndex].out[craftNames[i]])
            
            -- If this recipe index not discovered yet, add it to the end and update mapping. Otherwise we just add the mult to the existing entry.
            if not indicesMapping[recipeIndex] then
              resultIndices[j] = recipeIndex
              resultBatches[j] = mult
              indicesMapping[recipeIndex] = j
            else
              resultBatches[indicesMapping[recipeIndex]] = resultBatches[indicesMapping[recipeIndex]] + mult
            end
            j = j + 1
          end
          
          -- Save the current requiredItems corresponding to the result.
          resultItems = {}
          for k, v in pairs(requiredItems) do
            resultItems[k] = v
          end
        end
      else
        recursiveSolve(spacing .. "  ", index + 1)
      end
      
      -- Restore state of requiredItems, craftNames/craftAmounts, and numMissingItems.
      print(spacing .. "end of recipe, restore state")
      if requiredItems2 then
        requiredItems = requiredItems2
        for i = lastCraftNamesLength + 1, #craftNames do
          craftNames[i] = nil
          craftIndices[i] = nil
          craftAmounts[i] = nil
        end
        numMissingItems = numMissingItems2
        
        --[[
        for i = #craftNames, lastCraftNamesLength + 1, -1 do
          
        end
        --]]
      end
    end
  end
  local status, err = pcall(recursiveSolve, "", 1)
  if not status then
    return err
  end
  
  print("done.")
  return resultStatus, resultIndices, resultBatches, resultItems
end

--[[

crafting algorithm v2:
requiredItems = {}
craftNames = {itemName}
craftIndices = {}
craftAmounts = {amount}
resultIndices = {}
resultBatches = {}

get current targetItem/targetAmount from craftNames/craftAmounts at current index
  for each recipe that makes targetItem do
    set craftIndices at current index to the recipe index
    if more than one recipe available
      make backup copy of requiredItems to restore later
      make copy of craftNames length
    
    multiplier = round_up(targetAmount / recipeAmount)
    
    for each recipe input do
      let addAmount be multiplier * inputAmount
      add input to craftNames/craftAmounts if addAmount > actualStorageAmount - requiredItems[input] and we have recipe for input
        this new amount is addAmount - max(actualStorageAmount - requiredItems[input], 0)
      add input to requiredItems with amount addAmount
    
    for each recipe output do
      add output to requiredItems with amount -1 * multiplier * recipeAmount
      if requiredItems[output] is zero, remove the entry
    
    if next index goes out of bounds of craftNames, we are done
      check if new best and save it
    else
      do recursive call with next index
    
    time to restore if we did the backup step at beginning of loop
      reset requiredItems to the backup
      remove extra entries added to craftNames/craftIndices/craftAmounts before this loop ran

goal:
want 3 tables, requiredItems, resultIndices, and resultBatches
requiredItems =   {torch=-16, coal=4, stick=0, planks=-2, log=1}
resultIndices = {<planks>, <stick>, <torch>}
resultBatches = {       1,       1,       4}

edge cases:
crafting requested for a non-craftable item?
recipe impossible to craft? (crafting 1 of x requires 1 of x not possible, but crafting 4 of x with 1 of x may be possible).
can recipes be mixed to craft the item? with torch example, if we have 2 coal and 2 charcoal we can make 16 torches.
  currently this case will not work with the algorithm.

new algorithm idea:
make a memoization table of recipe ratios
8 stick from 1 log
1 stick from 1/8 log? (probably doesn't work, what if we had 2 ways to get planks from log? now we can't say that 1/8 log from this recipe and 7/8 from another recipe really add up)

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

ex:
20 nou with 1 impossible
{}
{nou}
{ 20}
  try nou recipe
  need 20 impossible, only have 1
  get 1 nou, 1 impossible
  {nou=-1, imp=0}
  {nou, imp}
  { 20,   1}
  craft 1 impossible
    try impossible recipe
    get 1 nou, 1 impossible
    craft 1 impossible
      try impossible recipe
      ...

ex:
16 torch, have 1 coal, have 3 charcoal
{}
{torch}
{   16}
  {torch=-4, coal=1, stick=1}
  {torch, stick}
  {   16,     1}
    {torch=-4, coal=1, stick=-3, planks=2}
    {torch, stick, planks}
    {   16,     1,      2}
      {torch=-4, coal=1, stick=-3, planks=-2, log=1}
      {torch, stick, planks}
      {   16,     1,      2}
  {torch=-16, coal=1, stick=-3, planks=-2, log=1, charcoal=3}
  {torch, torch, stick, planks}
  {   12,     4,     1,      2}

when we get multiple recipes we can try: mix of them, then only first/second/etc.

ex:
5 chain, have 1 cycle1
inp {}
out {}
cra {chain}
amo {    5}
  inp {cycle2=5}
  out {cycle1=5, chain=5}
  cra {chain, cycle2}
  amo {    5,      5}
    inp {cycle2=5, cycle3=5}
    out {cycle1=5, chain=5, cycle2=5}
    cra {chain, cycle2, cycle3}
    amo {    5,      5,      5}
      inp {cycle2=5, cycle3=5, cycle1=5}
      out {cycle1=5, chain=5, cycle2=5, cycle3=5}
      cra {chain, cycle2, cycle3, cycle1}
      amo {    5,      5,      5,      5}

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
craftNames   = {torch, charcoal, stick, log, planks, log}  (log made from wood essence)
craftAmounts = {   16,        4,     4,   4,      2,   1}
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
    
    local status, recipeIndices, recipeBatches, requiredItems = solveDependencyGraph(stations, recipes, storageItems, "minecraft:torch/0", 16)
    
    --storageItems["stuff:impossible/0"] = {}
    --storageItems["stuff:impossible/0"].maxSize = 64
    --storageItems["stuff:impossible/0"].label = "impossible"
    --storageItems["stuff:impossible/0"].total = 1
    --local status, recipeIndices, recipeBatches, requiredItems = solveDependencyGraph(stations, recipes, storageItems, "stuff:nou/0", 100)
    
    print("status = " .. status)
    if status == "ok" or status == "missing" then
      print("recipeIndices/recipeBatches and requiredItems")
      for i = 1, #recipeIndices do
        print(recipeIndices[i] .. " (" .. next(recipes[recipeIndices[i]].out) .. ") -> " .. recipeBatches[i])
      end
      tdebug.printTable(requiredItems)
    end
    
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
              storageItems[itemName].maxSize = diff.maxSize
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
              recipeItems[k] = {}
              recipeItems[k].maxSize = v.maxSize
              recipeItems[k].label = v.label
            end
          end
          wnet.send(modem, address, COMMS_PORT, "inter_recipe_list," .. serialization.serialize(recipeItems))
        elseif dataType == "craft_check_recipe" then
          -- Interface is requesting to craft an item, compute the recipe dependencies and reserve a ticket for the operation if successful.
          interfaceServerAddresses[address] = true
          local itemName = string.match(data, "[^,]*")
          local amount = string.match(data, "[^,]*", #itemName + 2)
          
          local status, recipeIndices, recipeBatches, requiredItems = solveDependencyGraph(stations, recipes, storageItems, itemName, 16)
          
          print("status = " .. status)
          if status == "ok" or status == "missing" then
            print("recipeIndices/recipeBatches and requiredItems")
            for i = 1, #recipeIndices do
              print(recipeIndices[i] .. " (" .. next(recipes[recipeIndices[i]].out) .. ") -> " .. recipeBatches[i])
            end
            tdebug.printTable(requiredItems)
          end
          
          
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
