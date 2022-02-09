--[[
Crafting server application code.


--]]

-- OS libraries.
local component = require("component")
local computer = require("computer")
local event = require("event")
local modem = component.modem
local serialization = require("serialization")
local sides = require("sides")
local term = require("term")
local text = require("text")
local thread = require("thread")

-- User libraries.
local include = require("include")
local dlog = include("dlog")
dlog.osBlockNewGlobals(true)
local dstructs = include("dstructs")
local packer = include("packer")
local wnet = include("wnet")

local COMMS_PORT = 0xE298
local DLOG_FILE_OUT = "/tmp/messages"
local ROBOTS_CONFIG_FILENAME = "robots.config"

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
  assert(not string.find(s, "[^%d-]") and x, "String \"" .. s .. "\" has invalid format for integer value.")
  assert(x >= minVal, "Integer must be greater than or equal to " .. minVal .. ".")
  return x
end

-- Parse a recipe file containing information about crafting stations and the
-- recipes made there (item inputs and outputs).
local function loadRecipes(stations, recipes, filename)
  dlog.checkArgs(stations, "table", recipes, "table", filename, "string")
  
  -- Parses one line of the file, checks for errors and syntax, and adds new data to the tables.
  local parseState = ""
  local stationEntry, stationName, recipeEntry
  local function loadRecipesParser(line, lineNum)
    if line == "" then
      assert(parseState == "" or (parseState == "re_inp" and next(recipeEntry.inp)), "End of file reached, missing some data.")
      return
    end
    
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
        assert(#tokens >= 4 and itemLabel, "Expected \'<count> <item name> \"<item label>\" <max stack size>\'.")
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
    loadRecipesParser("", lineNum)
  end)
  if not status then
    assert(false, "In file \"" .. filename .. "\" at line " .. lineNum .. ": " .. msg)
  end
  
  file:close()
end


local function loadRobotsConfig(filename)
  dlog.checkArgs(filename, "string")
  local robotConnections
  
  local function loadRobotsConfigParser(line, lineNum)
    if line == "" then
      assert(robotConnections, "End of file reached, missing some data.")
      return
    end
    
    assert(not robotConnections, "Unexpected data \"" .. line .. "\".")
    robotConnections = serialization.unserialize(line)
  end
  
  -- Open file and for each line trim whitespace, skip empty lines, and lines beginning with comment symbol '#'. Parse the rest.
  local file = io.open(filename, "r")
  local lineNum = 1
  
  local status, msg = pcall(function()
    for line in file:lines() do
      line = text.trim(line)
      if line ~= "" and string.byte(line, 1) ~= string.byte("#", 1) then
        loadRobotsConfigParser(line, lineNum)
      end
      lineNum = lineNum + 1
    end
    loadRobotsConfigParser("", lineNum)
  end)
  if not status then
    assert(false, "In file \"" .. filename .. "\" at line " .. lineNum .. ": " .. msg)
  end
  
  file:close()
  
  return robotConnections
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
      <item name>: <amount>
      ...
    }
    inp: {
      1: {<item name>, <amount>}
      2: {<item name>, <amount>}
      ...
    }
    station: <station name>
  }
  2: {    -- Crafting recipe.
    out: {
      <item name>: <amount>
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
  dlog.checkArgs(stations, "table", recipes, "table")
  for i, recipe in ipairs(recipes) do
    if recipe.station and not stations[recipe.station .. "1"] then
      assert(false, "Recipe " .. i .. " for " .. next(recipe.out) .. " requires station " .. recipe.station .. ", but station not found.")
    end
  end
end

-- Crafting class definition.
local Crafting = {}

-- Hook up errors to throw on access to nil class members (usually a programming
-- error or typo).
setmetatable(Crafting, {
  __index = function(t, k)
    dlog.errorWithTraceback("Attempt to read undefined member " .. tostring(k) .. " in Crafting class.")
  end
})

function Crafting:new()
  self.__index = self
  self = setmetatable({}, self)
  
  --local self.stations, self.recipes, self.storageServerAddress, self.storageItems, self.interfaceServerAddresses
  --local self.pendingCraftRequests, self.activeCraftRequests, self.droneItems, self.droneInventories, self.workers
  
  return self
end

-- Searches for the sequence of recipes and their amounts needed to craft the
-- target item. This uses a recursive algorithm that walks the dependency graph
-- and tries each applicable recipe for the currently needed item one at a time.
-- Returns a string status ("ok", "missing", "error"), two table arrays containing
-- the sequence of recipe indices and the amount of each recipe to craft, and
-- two more tables that match item inputs to their amounts and item outputs to
-- their amounts.
-- Currently this algorithm is not perfect, auto-crafting has been proven to be
-- NP-hard so there is no perfect solution that exists (see
-- https://squiddev.github.io/ae-sat/). Recipes that are recursive (an item is
-- crafted with itself, or a chain like A->B, B->C, C->A) and recipes that
-- should be split to make the item (need 8 torches but only have 1 coal and 1
-- charcoal) can not be solved properly right now.
-- 
-- FIXME if have time, improve this to handle the above drawbacks. ##############################################################################


-- FIXME need to plan for better priority when finding best recipe sequence, a few thoughts:
--   1) minimum number of items tells us the best sequence.
--   2) min batches is best.
--   3) first found is chosen and recipes are ordered during init to define a priority. Maybe order recipe files to load in alphabetical?

local CRAFT_SOLVER_MAX_RECURSION = 1000
local CRAFT_SOLVER_PRIORITY = 0
-- 0 = first found (recipes ordered by priority)
-- 1 = min items
-- 2 = min batches
-- might want to try instead: https://unendli.ch/posts/2016-07-22-enumerations-in-lua.html

local SolverState = {
  defaultZeroMeta = {__index = function() return 0 end}
}

function SolverState:new()
  self.__index = self
  self = setmetatable({}, self)
  
  -- Map of item input totals and non-ancestor output totals.
  -- We need to track non-ancestor outputs so that outputs from a later crafting step (which we will find first while traversing the dependencies from root to leaves) do not get used up in an earlier step.
  -- This assumes that while traversing the dependency "tree" (technically a graph), we do not revisit previously explored branches to try and optimize material inputs already generated in itemNAOutputs.
  -- Otherwise, this could lead to a situation where we have a material cross-dependency between two branches of the "tree", and we run into a deadlock while attempting to craft.
  -- The outputStack is used to populate itemNAOutputs with item outputs when we return from recursive calls, so we can still get tail call optimization.
  self.itemInputs = setmetatable({}, SolverState.defaultZeroMeta)
  self.itemNAOutputs = setmetatable({}, SolverState.defaultZeroMeta)
  self.outputNames = {}
  self.outputAmounts = {}
  self.outputStackSize = 0
  
  -- Stack of recipe name, index, and amount that are scheduled to craft to make the item.
  -- The name and index are kept separate to distinguish between alternative recipes for an item, an index of -1 means we may have to try multiple recipes that make the item.
  -- For the amount, a value of -1 means the corresponding entry has already been processed and is scheduled to be deleted.
  self.craftNames = {}
  self.craftIndices = {}
  self.craftAmounts = {}
  self.craftStackSize = 0
  
  -- Sequence of recipe indices and batches that have been popped off the craft* stacks.
  -- The batches are similar to amounts, except they are scaled down so that batch * recipeOutput = amount.
  -- Beginning of array is the requested item and end of array is the item at the bottom of the dependency chain.
  self.processedIndices = {}
  self.processedBatches = {}
  
  -- Maps a recipeIndex in processedIndices to the array index, used to guarantee only unique recipes are stored.
  self.mapProcessedIndices = {}
  
  return self
end

function SolverState:addItemInput(itemName, amount)
  self.itemInputs[itemName] = self.itemInputs[itemName] + amount
end

function SolverState:addItemOutput(itemName, amount)
  self.outputStackSize = self.outputStackSize + 1
  self.outputNames[self.outputStackSize] = itemName
  self.outputAmounts[self.outputStackSize] = amount
end

function SolverState:buildNextNAOutput()
  local itemName = self.outputNames[self.outputStackSize]
  self.itemNAOutputs[itemName] = self.itemNAOutputs[itemName] + self.outputAmounts[self.outputStackSize]
  
  self.outputNames[self.outputStackSize] = nil
  self.outputAmounts[self.outputStackSize] = nil
  self.outputStackSize = self.outputStackSize - 1
end

function SolverState:craftEmpty()
  return self.craftStackSize == 0
end

function SolverState:craftSize()
  return self.craftStackSize
end

function SolverState:craftTop()
  return self.craftNames[self.craftStackSize], self.craftIndices[self.craftStackSize], self.craftAmounts[self.craftStackSize]
end

function SolverState:craftPush(name, recipeIndex, amount)
  self.craftStackSize = self.craftStackSize + 1
  self.craftNames[self.craftStackSize] = name
  self.craftIndices[self.craftStackSize] = recipeIndex
  self.craftAmounts[self.craftStackSize] = amount
end

function SolverState:craftPop(batchSize)
  -- For the top element in craft* stacks, add it to processed* arrays.
  -- If the recipe index was previously found, then update the existing entry instead of adding a new one.
  local craftIndicesTop = self.craftIndices[self.craftStackSize]
  local i = self.mapProcessedIndices[craftIndicesTop]
  if not i then
    i = #self.processedIndices + 1
    self.mapProcessedIndices[craftIndicesTop] = i
    self.processedIndices[i] = craftIndicesTop
    self.processedBatches[i] = batchSize
  else
    self.processedBatches[i] = self.processedBatches[i] + batchSize
  end
  
  self.craftNames[self.craftStackSize] = nil
  self.craftIndices[self.craftStackSize] = nil
  self.craftAmounts[self.craftStackSize] = nil
  self.craftStackSize = self.craftStackSize - 1
end


function Crafting:solveDependencyGraph(itemName, amount)
  dlog.checkArgs(itemName, "string", amount, "number")
  if not self.recipes[itemName] then
    return "error", "No recipe found for \"" .. itemName .. "\"."
  end
  
  
  
  
  --##########################################################
  --we got a problem, the NA-outputs not populated correctly.
  --option 1: move the depth data from output* to craft*, but how do we know how many values to pop off output* during update?
  --option 2: change output* to store outputs preemptively (basically same as inputs now), amount needs to be set later when we know it?
  --option cool: modify craft* to use similar format to output*, and mark completed outputs instead of deleting them. now we don't even care about the depth
  
  
  
  
  
  
  local solverState = SolverState:new()
  solverState:craftPush(itemName, -1, amount)
  
  local resultStatus, resultIndices, resultBatches, resultInputs, resultOutputs
  
  --local bestCraftingTotal = math.huge    -- Best minimum number of items to craft found thus far.
  local numMissingItems = 0
  local bestNumMissingItems = math.huge
  
  --local recipeStack = dstructs.Deque:new()
  --while not recipeStack:empty() do
    
  --end
  
  dlog.out("recipeSolver", "Crafting " .. amount .. " of " .. itemName)
  
  --local MIX = false
  
  -- Make a partial backup of solverState so we can evaluate the crafting
  -- dependencies at a later time. This assumes that we will call
  -- restoreCraftState() later on within the same recursion depth, and that the
  -- output* stacks and craft* stacks will only be appended to (except the first
  -- element in craft* stacks can be modified).
  local function cacheCraftState(recursionDepth, solverState, cache)
    local spacing = string.rep("  ", recursionDepth)
    dlog.out("recipeSolver", spacing .. "Caching craft state...")
    
    cache.itemInputs = setmetatable({}, SolverState.defaultZeroMeta)
    for k, v in pairs(solverState.itemInputs) do
      cache.itemInputs[k] = v
    end
    cache.itemNAOutputs = setmetatable({}, SolverState.defaultZeroMeta)
    for k, v in pairs(solverState.itemNAOutputs) do
      cache.itemNAOutputs[k] = v
    end
    
    cache.outputNames = {}
    cache.outputAmounts = {}
    cache.outputStackSize = solverState.outputStackSize
    for i = 1, solverState.outputStackSize do
      cache.outputNames[i] = solverState.outputNames[i]
      cache.outputAmounts[i] = solverState.outputAmounts[i]
    end
    
    cache.craftNames = {}
    cache.craftIndices = {}
    cache.craftAmounts = {}
    cache.craftStackSize = solverState.craftStackSize
    for i = 1, solverState.craftStackSize do
      cache.craftNames[i] = solverState.craftNames[i]
      cache.craftIndices[i] = solverState.craftIndices[i]
      cache.craftAmounts[i] = solverState.craftAmounts[i]
    end
    
    cache.processedIndices = {}
    cache.processedBatches = {}
    for i = 1, #solverState.processedIndices do
      cache.processedIndices[i] = solverState.processedIndices[i]
      cache.processedBatches[i] = solverState.processedBatches[i]
    end
    
    cache.mapProcessedIndices = {}
    for k, v in pairs(solverState.mapProcessedIndices) do
      cache.mapProcessedIndices[k] = v
    end
    
    cache.numMissingItems = numMissingItems
    cache.valid = true
    dlog.out("recipeSolver", spacing .. "cache:", cache)
  end
  
  -- Restore solverState. See assumptions made in cacheCraftState().
  local function restoreCraftState(recursionDepth, solverState, cache)
    local spacing = string.rep("  ", recursionDepth)
    dlog.out("recipeSolver", spacing .. "Restoring craft state...")
    assert(cache.valid, "Restore attempted before call to cacheCraftState()")
    
    solverState.itemInputs = cache.itemInputs
    solverState.itemNAOutputs = cache.itemNAOutputs
    
    solverState.outputNames = cache.outputNames
    solverState.outputAmounts = cache.outputAmounts
    solverState.outputStackSize = cache.outputStackSize
    
    solverState.craftNames = cache.craftNames
    solverState.craftIndices = cache.craftIndices
    solverState.craftAmounts = cache.craftAmounts
    solverState.craftStackSize = cache.craftStackSize
    
    solverState.processedIndices = cache.processedIndices
    solverState.processedBatches = cache.processedBatches
    
    solverState.mapProcessedIndices = cache.mapProcessedIndices
    
    numMissingItems = cache.numMissingItems
    cache.valid = nil
  end
  
  -- Forward declares for below functions (cyclic dependency).
  local recursiveSolve, attemptRecipe
  
  recursiveSolve = function(recursionDepth)--spacing, index)
    assert(recursionDepth < 50, "Recipe too complex or not possible.")    -- FIXME may want to limit the max number of calls in addition to max depth. ############################################
    local spacing = string.rep("  ", recursionDepth)
    local currentName, currentIndex, currentAmount = solverState:craftTop()
    dlog.out("recipeSolver", spacing .. "recursiveSolve(" .. recursionDepth .. ")")
    
    -- If recipe for the target item has been pre-selected or there is only one recipe option, then use that one only (tail call optimization).
    -- Else, in the case that there are multiple recipes that make the item, use the following strategy to attempt some combinations of the recipes that are likely to succeed.
    if currentIndex ~= -1 then
      dlog.out("recipeSolver", spacing .. "Recipe " .. currentIndex .. " was pre-selected")
      return attemptRecipe(recursionDepth)
    elseif #self.recipes[currentName] == 1 then
      solverState.craftIndices[solverState.craftStackSize] = self.recipes[currentName][1]
      return attemptRecipe(recursionDepth)
    else
      local solverStateCache = {}
      
      -- Try each alternate recipe independently (no mixing different types).
      dlog.out("recipeSolver", spacing .. "Mix method 1: try each recipe independently.")
      for _, recipeIndex in ipairs(self.recipes[currentName]) do
        cacheCraftState(recursionDepth, solverState, solverStateCache)
        solverState.craftIndices[solverState.craftStackSize] = recipeIndex
        attemptRecipe(recursionDepth)
        restoreCraftState(recursionDepth, solverState, solverStateCache)
        if resultStatus == "ok" then
          -- FIXME we don't want to return if CRAFT_SOLVER_PRIORITY is set to min items/batches! ###############################################################
          return
        end
      end
      
      -- Prepare for mixing recipes together by downscaling each to the limiting raw resource as input to the recipe.
      -- This only looks at the top-level recipe inputs instead of recursively checking children (for performance reasons).
      -- We also take a sum (not considering the math.huge values) and count the positive/real values and the math.huge values respectively.
      local downscaledAmounts = {}
      local downscaledAmountsSum = 0
      local downscaledNumPos = 0
      local downscaledNumInf = 0
      for i, recipeIndex in ipairs(self.recipes[currentName]) do
        local currentRecipe = self.recipes[recipeIndex]
        local mult = math.huge
        
        for _, input in ipairs(currentRecipe.inp) do
          local inputName = input[1]
          local inputAmount = (currentRecipe.station and input[2] or #input - 1)
          local availableAmount = math.max((self.storageItems[inputName] and self.storageItems[inputName].total or 0) - solverState.itemInputs[inputName] + solverState.itemNAOutputs[inputName], 0)
          
          -- Reduce mult if resource does not have a recipe (it's raw) and it's limiting the amount we can craft.
          if not self.recipes[inputName] and mult * inputAmount > availableAmount then
            mult = math.floor(availableAmount / inputAmount)
          end
        end
        
        -- The downscaled amount for the recipe index is zero if there is none left of a raw input, a real number if a raw input is limiting, or math.huge (inf) if none of the inputs are raw.
        downscaledAmounts[i] = mult * currentRecipe.out[currentName]
        if downscaledAmounts[i] == math.huge then
          downscaledNumInf = downscaledNumInf + 1
        elseif downscaledAmounts[i] > 0 then
          downscaledAmountsSum = downscaledAmountsSum + downscaledAmounts[i]
          downscaledNumPos = downscaledNumPos + 1
        end
      end
      dlog.out("recipeSolver", spacing .. "downscaledAmounts:", downscaledAmounts)
      
      -- If all recipes downscaled and total less than amount needed, break early (cannot be crafted).
      if downscaledAmountsSum < currentAmount and downscaledNumInf == 0 then
        dlog.out("recipeSolver", spacing .. "All downscaled to less than total required, crafting not possible.")
        return -- FIXME instead we need to eval attemptRecipe() to get a missing items result (or do we? hmm) #################################################################################
      end
      
      dlog.out("recipeSolver", spacing .. "Mix method 2: try downscaled recipes first, split even across the remainder.")
      local remainingCraftAmount = currentAmount
      cacheCraftState(recursionDepth, solverState, solverStateCache)
      for i, downscaled in ipairs(downscaledAmounts) do
        if downscaled > 0 and downscaled ~= math.huge then
          local newAmount = math.min(downscaled, remainingCraftAmount)
          remainingCraftAmount = remainingCraftAmount - newAmount
          solverState.craftIndices[solverState.craftStackSize] = self.recipes[currentName][i]
          solverState.craftAmounts[solverState.craftStackSize] = newAmount
          dlog.out("recipeSolver", spacing .. "Added amount " .. newAmount .. " for recipe " .. self.recipes[currentName][i] .. " (i = " .. i .. ")")
          
          if remainingCraftAmount == 0 then
            break
          end
          
          -- Add a new craft entry and copy the original item name. The index and amount will get updated in a later iteration.
          solverState:craftPush(currentName, -1, 0)
        end
      end
      if remainingCraftAmount > 0 then
        local remainingNumInf = downscaledNumInf
        for i, downscaled in ipairs(downscaledAmounts) do
          if downscaled == math.huge then
            local newAmount = math.ceil(remainingCraftAmount / remainingNumInf)
            remainingCraftAmount = remainingCraftAmount - newAmount
            remainingNumInf = remainingNumInf - 1
            solverState.craftIndices[solverState.craftStackSize] = self.recipes[currentName][i]
            solverState.craftAmounts[solverState.craftStackSize] = newAmount
            dlog.out("recipeSolver", spacing .. "Added amount " .. newAmount .. " for recipe " .. self.recipes[currentName][i] .. " (i = " .. i .. ")")
            
            if remainingCraftAmount == 0 then
              break
            end
            
            -- Add a new craft entry and copy the original item name. The index and amount will get updated in a later iteration.
            solverState:craftPush(currentName, -1, 0)
          end
        end
      end
      assert(remainingCraftAmount == 0, "Mix method 2 failed: recipe distribution incorrect.")
      attemptRecipe(recursionDepth)
      restoreCraftState(recursionDepth, solverState, solverStateCache)
      if resultStatus == "ok" then
        -- FIXME we don't want to return if CRAFT_SOLVER_PRIORITY is set to min items/batches! ###############################################################
        return
      end
      
      dlog.out("recipeSolver", spacing .. "Mix method 3: split even across all recipes.")
      dlog.out("recipeSolver", spacing .. "oops, NYI")
      
    end
  end
  
  attemptRecipe = function(recursionDepth)--spacing, index, recipeIndex)
    local spacing = string.rep("  ", recursionDepth)
    local currentName, currentIndex, currentAmount = solverState:craftTop()
    dlog.out("recipeSolver", spacing .. "Trying recipe " .. currentIndex .. " for " .. currentName .. " with amount " .. currentAmount)
    local currentRecipe = self.recipes[currentIndex]
    
    -- Compute amount multiplier as the number of items we need to craft over the number of items we get from the recipe (rounded up).
    local mult = math.ceil(currentAmount / currentRecipe.out[currentName])
    
    -- Invalidate the top element in the craft* stacks since we will process it now.
    solverState.craftAmounts[solverState.craftStackSize] = -1
    
    --[[
    -- If mixing, scale the multiplier down to the limiting input in recipe first.
    if MIX then
      for _, input in ipairs(currentRecipe.inp) do
        local inputName = input[1]
        local recipeAmount = (currentRecipe.station and input[2] or #input - 1)
        local availableAmount = math.max((self.storageItems[inputName] and self.storageItems[inputName].total or 0) - requiredItems[inputName], 0)
        
        if mult * recipeAmount > availableAmount and self.recipes[inputName] then
          mult = math.floor(availableAmount / recipeAmount)
        end
      end
    end
    --]]
    
    -- For each recipe input, add the item inputs to solverState and to the craft* stacks as well if we need to craft more of them.
    for _, input in ipairs(currentRecipe.inp) do
      local inputName = input[1]
      local addAmount = mult * (currentRecipe.station and input[2] or #input - 1)
      local availableAmount = math.max((self.storageItems[inputName] and self.storageItems[inputName].total or 0) - solverState.itemInputs[inputName] + solverState.itemNAOutputs[inputName], 0)
      
      -- Check if we need more than what's available.
      if addAmount > availableAmount then
        if self.recipes[inputName] then
          -- Add the addAmount minus availableAmount to craft* stacks if the recipe is known.
          dlog.out("recipeSolver", spacing .. "Craft " .. addAmount - availableAmount .. " of " .. inputName)
          solverState:craftPush(inputName, -1, addAmount - availableAmount)
        else
          -- Recipe not known so this item will prevent crafting, add to numMissingItems.
          dlog.out("recipeSolver", spacing .. "Missing " .. addAmount - availableAmount .. " of " .. inputName)
          numMissingItems = numMissingItems + addAmount - availableAmount
        end
      end
      
      dlog.out("recipeSolver", spacing .. "Require " .. addAmount .. " more of " .. inputName)
      solverState:addItemInput(inputName, addAmount)
    end
    
    -- For each recipe output, add the item outputs to solverState.
    for outputName, amount in pairs(currentRecipe.out) do
      dlog.out("recipeSolver", spacing .. "Add " .. mult * amount .. " of output " .. outputName)
      solverState:addItemOutput(outputName, mult * amount)
      --if requiredItems[outputName] == 0 then    -- FIXME this might be a bug? do we allow zeros in requiredItems or no? seems useful to have. if not bug then need to update any modifications to requiredItems to check for zero! ##################################################
        --requiredItems[outputName] = nil
      --end
    end
    
    -- Purge completed elements from the craft* stacks and swap outputs into the non-ancestors.
    while solverState.craftAmounts[solverState.craftStackSize] == -1 do
      solverState:craftPop(mult)
      solverState:buildNextNAOutput()
    end
    dlog.out("recipeSolver", spacing .. "Update NA outputs completed, solverState.outputStackSize = ", solverState.outputStackSize, ", solverState.itemNAOutputs = ", solverState.itemNAOutputs)
    
    -- If no more recipes remaining, solution found. Otherwise we do recursive call.
    if solverState:craftEmpty() then
      dlog.out("recipeSolver", spacing .. "Found solution, numMissingItems = " .. numMissingItems)
      assert(solverState.outputStackSize == 0, "Got solution, but solverState.outputStackSize not empty.")
      -- Temporarily merge in ancestor item outputs left in the stack to get the full list of outputs.
      -- We do not call solverState:updateOutputs() here because the operation would have no effect (at bottom of dependency "tree").
      --for i = 1, solverState.outputStackSize do
        --local itemName = solverState.outputNames[i]
        --solverState.itemNAOutputs[itemName] = solverState.itemNAOutputs[itemName] + solverState.outputAmounts[i]
      --end
      
      dlog.out("recipeSolver", spacing .. "itemInputs/itemOutputs and processedIndices/processedBatches:", solverState.itemInputs, solverState.itemNAOutputs)
      for i = 1, #solverState.processedIndices do
        dlog.out("recipeSolver", spacing .. i .. ": index " .. solverState.processedIndices[i] .. " batch " .. solverState.processedBatches[i])
      end
      
      --[[
      -- Determine the total number of items to craft and compare with the best found so far.
      local craftingTotal = 0
      for k, v in pairs(requiredItems) do
        craftingTotal = craftingTotal + math.max(v - (self.storageItems[k] and self.storageItems[k].total or 0), 0)
      end
      dlog.out("recipeSolver", "craftingTotal = " .. craftingTotal)
      --]]
      
      -- Check if the total number of missing items is a new low, and update the result if so.
      if numMissingItems < bestNumMissingItems then
        dlog.out("recipeSolver", spacing .. "New best found!")
        bestNumMissingItems = numMissingItems
        if numMissingItems == 0 then
          resultStatus = "ok"
        else
          resultStatus = "missing"
        end
        
        -- Copy the result of recipe indices and batch amounts from processed* arrays.
        -- We iterate in reverse and push to the result array, this puts the preliminary crafting steps at the beginning of the array.
        resultIndices = {}
        resultBatches = {}
        local j = 1
        for i = #solverState.processedIndices, 1, -1 do
          resultIndices[j] = solverState.processedIndices[i]
          resultBatches[j] = solverState.processedBatches[i]
          j = j + 1
        end
        
        -- Save the current itemInputs/itemOutputs corresponding to the result.
        -- Items that appear in both are merged and eliminated to prevent intermediate steps from showing in the result.
        resultInputs = {}
        for k, v in pairs(solverState.itemInputs) do
          local netInput = v - solverState.itemNAOutputs[k]
          if netInput > 0 then
            resultInputs[k] = netInput
          end
        end
        resultOutputs = {}
        for k, v in pairs(solverState.itemNAOutputs) do
          local netOutput = v - solverState.itemInputs[k]
          if netOutput > 0 then
            resultOutputs[k] = netOutput
          end
        end
        dlog.out("recipeSolver", spacing .. "resultInputs = ", resultInputs)
        dlog.out("recipeSolver", spacing .. "resultOutputs = ", resultOutputs)
      end
      
      -- Undo the temporary merge of ancestor item outputs.
      --for i = 1, solverState.outputStackSize do
        --local itemName = solverState.outputNames[i]
        --solverState.itemNAOutputs[itemName] = solverState.itemNAOutputs[itemName] - solverState.outputAmounts[i]
      --end
    else
      return recursiveSolve(recursionDepth + 1)
    end
  end
  
  local status, err = pcall(recursiveSolve, 0)
  if not status then
    dlog.out("recipeSolver", "Error: ", tostring(err))
    return "error", err
  end
  
  dlog.out("recipeSolver", "Done.")
  dlog.out("recipeSolver", "resultStatus, resultIndices, resultBatches, resultInputs, resultOutputs:", resultStatus, resultIndices, resultBatches, resultInputs, resultOutputs)
  return resultStatus, resultIndices, resultBatches, resultInputs, resultOutputs
end

-- Runs some unit tests for the solveDependencyGraph() algorithm.
function Crafting:testDependencySolver()
  io.write("Running solveDependencyGraph() tests...\n")
  self.stations = {}
  self.recipes = {}
  loadRecipes(self.stations, self.recipes, "misc/test_recipes.txt")
  verifyRecipes(self.stations, self.recipes)
  
  local function addStorageItem(itemName, label, total, maxSize)
    self.storageItems[itemName] = {}
    self.storageItems[itemName].maxSize = maxSize
    self.storageItems[itemName].label = label
    self.storageItems[itemName].total = total
  end
  
  local status, recipeIndices, recipeBatches, itemInputs, itemOutputs
  --dlog.out("test", "recipes:", self.recipes)
  
  -- Craft 16 torches, have nothing.
  self.storageItems = {}
  status, recipeIndices, recipeBatches, itemInputs, itemOutputs = self:solveDependencyGraph("minecraft:torch/0", 16)
  assert(status == "missing")
  assert(dstructs.objectsEqual(recipeIndices, {4, 3, 1}))
  assert(dstructs.objectsEqual(recipeBatches, {1, 1, 4}))
  assert(dstructs.objectsEqual(itemInputs, {["minecraft:log/0"] = 1, ["minecraft:coal/0"] = 4}))
  assert(dstructs.objectsEqual(itemOutputs, {["minecraft:torch/0"] = 16, ["minecraft:planks/0"] = 2}))
  
  -- Craft 16 torches, have 1 log and 4 coal.
  self.storageItems = {}
  addStorageItem("minecraft:log/0", "Oak Log", 1, 64)
  addStorageItem("minecraft:coal/0", "Coal", 4, 64)
  status, recipeIndices, recipeBatches, itemInputs, itemOutputs = self:solveDependencyGraph("minecraft:torch/0", 16)
  assert(status == "ok")
  assert(dstructs.objectsEqual(recipeIndices, {4, 3, 1}))
  assert(dstructs.objectsEqual(recipeBatches, {1, 1, 4}))
  assert(dstructs.objectsEqual(itemInputs, {["minecraft:log/0"] = 1, ["minecraft:coal/0"] = 4}))
  assert(dstructs.objectsEqual(itemOutputs, {["minecraft:torch/0"] = 16, ["minecraft:planks/0"] = 2}))
  
  -- Craft 16 torches, have 1 log, 1 charcoal, and 3 coal.
  self.storageItems = {}
  addStorageItem("minecraft:log/0", "Oak Log", 1, 64)
  addStorageItem("minecraft:coal/1", "Charcoal", 1, 64)
  addStorageItem("minecraft:coal/0", "Coal", 3, 64)
  status, recipeIndices, recipeBatches, itemInputs, itemOutputs = self:solveDependencyGraph("minecraft:torch/0", 16)
  --assert(status == "ok")
  --assert(dstructs.objectsEqual(recipeIndices, {4, 3, 2}))
  --assert(dstructs.objectsEqual(recipeBatches, {1, 1, 4}))
  --assert(dstructs.objectsEqual(itemInputs, {["minecraft:log/0"] = 1, ["minecraft:coal/0"] = 4}))
  --assert(dstructs.objectsEqual(itemOutputs, {["minecraft:torch/0"] = 16, ["minecraft:planks/0"] = 2}))
  
--[[


-- Inputs will not have much change, the itemNAOutputs will fill as we step back through recursive calls (find a way to populate this without sacrificing tail calls).
local itemInputs = {}
local itemNAOutputs = {}  -- Non-ancestor outputs.
local outputStack = {}

-- Craft array is now a pure stack, we only work on the tail element.
local craftNames = {itemName}
local craftIndices = {-1}
local craftAmounts = {amount}

-- Popped elements from craft array get appended here, mapProcessedIndices maps a recipe index to the index in processedIndices
local processedIndices = {}
local processedBatches = {}
local mapProcessedIndices = {}


init:
craft* starts with target item
recursiveSolve()

migrateOutputs()
  move items in outputStack to itemNAOutputs while current depth less than stack size

recursiveSolve()
  migrateOutputs() ???
  get tail of craft*, are there multiple recipes?
  if so,
    apply our mix methods
  else,
    return attemptRecipe()

attemptRecipe()
  compute the mult
  pop craft* and add to processed* (using the mult instead of amount)
  add inputs to itemInputs
    add any we don't have stocked in storage to back of craft* if recipe is known
  add outputs to outputStack
  if craft* empty,
    check for solution
    combine outputStack and itemNAOutputs to get itemOutputs
  else,
    return recursiveSolve()
--]]
  
  dlog.out("test", "testDependencySolver() all tests passed.")
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


-- Update the amount of an item in storedItems. This happens when an item
-- arrives in a drone inventory (finished crafting) or when item exported to
-- drone inventory. The storedItems don't all reside in drone inventories
-- though.
local function updateStoredItem(craftRequest, itemName, deltaAmount)
  dlog.checkArgs(craftRequest, "table", itemName, "string", deltaAmount, "number")
  dlog.out("updateStoredItem", "Stored item " .. itemName .. " changed by amount " .. deltaAmount .. " (total now " .. craftRequest.storedItems[itemName].total + deltaAmount .. ").")
  if deltaAmount == 0 then
    return
  end
  craftRequest.storedItems[itemName].total = craftRequest.storedItems[itemName].total + deltaAmount
  if deltaAmount > 0 then
    craftRequest.storedItems[itemName].lastTime = computer.uptime()
  end
  
  -- Mark dependent recipes as dirty (amount changed).
  for _, dependentIndex in ipairs(craftRequest.storedItems[itemName].dependents) do
    craftRequest.recipeStatus[dependentIndex].dirty = true
  end
end

-- Send message over network to each address in the table (or broadcast if nil).
local function sendToAddresses(addresses, message)
  if addresses then
    for address, _ in pairs(addresses) do
      wnet.send(modem, address, COMMS_PORT, message)
    end
  else
    wnet.send(modem, nil, COMMS_PORT, message)
  end
end

--[[

pendingCraftRequests: {
  <ticket>: {
    creationTime: <time>
    recipeIndices: {    -- Indices of the recipes to craft, ordered by raw materials first to final product last.
      1: <recipeIndex>
      2: <recipeIndex>
      ...
    }
    recipeBatches: {    -- Number of batches (multiplied with item output amount to get total number to craft) for each recipe index.
      1: <batchSize>
      2: <batchSize>
      ...
    }
    requiredItems: {    -- All items used in recipes and the total amount required. Negative values mean a net amount of the item is generated.
      <item name>: <amount>    -- FIXME is above really true? see note in solveDependencyGraph() about this. may want to update some other places (like storedItems) that assume requiredItems does NOT have all used items. #############################################
      ...
    }
  }
  ...
}

activeCraftRequests: {
  <ticket>: {
    <all of the same stuff from pendingCraftRequests>
    
    startTime: <time>
    storedItems: {    -- Initialized with requiredItems and all items used in recipe.
      <item name>: {
        total: <total count>
        lastTime: <time>    -- Last time the item was crafted.
        dependents: {    -- All recipes in the request that require this item as an input.
          1: <index of recipeIndices>
          2: <index of recipeIndices>
          ...
        }
      }
      ...
    }
    recipeStartIndex: <index>    -- Index of first nonzero batchSize in recipeBatches.
    recipeStatus: {    -- Corresponds to the recipeIndices and recipeBatches.
      1: {
        dirty: <boolean>    -- True if any of the recipe input amounts changed, false otherwise.
        available: <amount>    -- Number of batches we can craft with current storedItems.
        maxLastTime: <time>    -- Maximum lastTime of all recipe inputs.
      }
      ...
    }
    supplyIndices: {    -- Keeps track of drone inventories that currently contain intermediate crafting materials.
      <droneInvIndex>: <boolean>    -- True if dirty (inventory scan needed), false otherwise.
      ...
    }
    taskCounter: <number>    -- Counter for the running tasks (robots are crafting, drone is in transit, etc). Starts at 1 and is used as the task ID for a new task.
    craftingTasks: {    -- Active crafting jobs that robots are running. This is used to determine item outputs we expect from the operation.
      <task ID>: {
        droneInvIndex: <number>
        numBatches: <number>
        recipe: <single recipe entry from recipes table>
        robots: {
          <address>: true
          ...
        }
      }
      ...
    }
  }
  ...
}

droneInventories: {
  firstFree: <droneInvIndex>    -- Index of first free inventory, or -1.
  firstFreeWithRobot: <droneInvIndex>    -- Index of first free inventory with available robots, or -1.
  pendingInsert: nil|<status>    -- Either nil, "pending", or result of insert operation.
  pendingExtract: nil|<status>
  inv: {
    1: {
      status: free|input|output
      ticket: nil|<ticket>    -- Ticket of corresponding craft request.
    }
    ...
  }
}

workers: {
  robotConnections: {
    1: {    -- Index of drone inventory.
      <address>: <side>    -- The address of the robot that can access the inventory, and what side the robot sees the inventory.
      ...
    }
    ...
  }
  totalRobots: <amount>
  robots: {
    <address>: <status>    -- Either "free", "pending", or "busy".
    ...
  }
  totalDrones: <amount>
  drones: {
    <address>: <status>    -- Either "free" or "busy".
    ...
  }
}

--]]





-- If we get a broadcast that storage started, it must have just rebooted and we
-- need to discover new storageItems.
function Crafting:handleStorStarted(address, _)
  wnet.send(modem, address, COMMS_PORT, packer.pack.stor_discover())
end
packer.callbacks.stor_started = Crafting.handleStorStarted


-- New item list, update storageItems.
function Crafting:handleStorItemList(address, _, items)
  self.storageItems = items
  self.storageServerAddress = address
end
packer.callbacks.stor_item_list = Crafting.handleStorItemList


-- Apply the items diff to storageItems to keep the table synced up.
function Crafting:handleStorItemDiff(_, _, itemsDiff)
  for itemName, diff in pairs(itemsDiff) do
    if diff.total == 0 then
      self.storageItems[itemName] = nil
    elseif self.storageItems[itemName] then
      self.storageItems[itemName].total = diff.total
    else
      self.storageItems[itemName] = {}
      self.storageItems[itemName].maxSize = diff.maxSize
      self.storageItems[itemName].label = diff.label
      self.storageItems[itemName].total = diff.total
    end
  end
end
packer.callbacks.stor_item_diff = Crafting.handleStorItemDiff


-- Set the contents of the drone inventories (the inventory type in the network,
-- not from actual drones).
function Crafting:handleStorDroneItemList(_, _, droneItems)
  self.droneItems = droneItems
  
  -- Set the droneInventories for each drone inventory we have, and initialize to free (not in use).
  self.droneInventories = {}
  self.droneInventories.inv = {}
  for i, inventoryDetails in ipairs(self.droneItems) do
    self.droneInventories.inv[i] = {}
    self.droneInventories.inv[i].status = "free"
    self.droneInventories.inv[i].ticket = nil
  end
  self.droneInventories.firstFree = -1
  self.droneInventories.firstFreeWithRobot = -1
end
packer.callbacks.stor_drone_item_list = Crafting.handleStorDroneItemList


-- Contents of drone inventories has changed (result of insertion or extraction
-- request). Apply the diff to keep it synced.
function Crafting:handleStorDroneItemDiff(_, _, operation, result, droneItemsDiff)
  if operation == "insert" and self.droneInventories.pendingInsert then
    assert(self.droneInventories.pendingInsert == "pending")
    self.droneInventories.pendingInsert = result
  elseif operation == "extract" and self.droneInventories.pendingExtract then
    assert(self.droneInventories.pendingExtract == "pending")
    self.droneInventories.pendingExtract = result
  end
  
  for invIndex, diff in pairs(droneItemsDiff) do
    self.droneItems[invIndex] = diff
    -- If inventory is now empty, remove it from supply lists (assuming it's not dirty).
    if next(diff) == nil then
      for _, craftRequest in pairs(self.activeCraftRequests) do
        if craftRequest.supplyIndices[invIndex] == false then
          self.droneInventories.inv[invIndex].status = "free"
          self.droneInventories.inv[invIndex].ticket = nil
          craftRequest.supplyIndices[invIndex] = nil
        end
      end
    end
  end
end
packer.callbacks.stor_drone_item_diff = Crafting.handleStorDroneItemDiff


-- Device is searching for this crafting server, respond with list of recipes.
function Crafting:handleCraftDiscover(address, _)
  self.interfaceServerAddresses[address] = true
  local recipeItems = {}
  for k, v in pairs(self.recipes) do
    if type(k) == "string" then
      recipeItems[k] = {}
      recipeItems[k].maxSize = v.maxSize
      recipeItems[k].label = v.label
    end
  end
  wnet.send(modem, address, COMMS_PORT, packer.pack.craft_recipe_list(recipeItems))
end
packer.callbacks.craft_discover = Crafting.handleCraftDiscover


-- Prepare to craft an item. Compute the recipe dependencies and reserve a
-- ticket for the operation if successful.
function Crafting:handleCraftCheckRecipe(address, _, itemName, amount)
  self.interfaceServerAddresses[address] = true
  local status, recipeIndices, recipeBatches, itemInputs, itemOutputs = self:solveDependencyGraph(itemName, amount)
  
  dlog.out("craftCheckRecipe", "status = " .. status)
  if status == "ok" or status == "missing" then
    dlog.out("craftCheckRecipe", "recipeIndices/recipeBatches:")
    for i = 1, #recipeIndices do
      dlog.out("craftCheckRecipe", recipeIndices[i] .. " (" .. next(self.recipes[recipeIndices[i]].out) .. ") = " .. recipeBatches[i])
    end
    dlog.out("craftCheckRecipe", "itemInputs/itemOutputs:", itemInputs, itemOutputs)
  end
  
  status = "error"    -- FIXME ################################
  recipeIndices = "cum in my tight bussy"
  
  -- Check for expired tickets and remove them.
  for ticket, request in pairs(self.pendingCraftRequests) do
    if computer.uptime() > request.creationTime + 10 then
      dlog.out("craftCheckRecipe", "Ticket " .. ticket .. " has expired")
      self.pendingCraftRequests[ticket] = nil
    end
  end
  
  -- Reserve a ticket for the crafting request if good to go.
  local ticket = ""
  if status == "ok" then
    while true do
      ticket = "id" .. math.floor(math.random(0, 999)) .. "," .. itemName .. "," .. amount
      if not self.pendingCraftRequests[ticket] and not self.activeCraftRequests[ticket] then
        break
      end
    end
    dlog.out("craftCheckRecipe", "Creating ticket " .. ticket)
    self.pendingCraftRequests[ticket] = {}
    self.pendingCraftRequests[ticket].creationTime = computer.uptime()
    self.pendingCraftRequests[ticket].recipeIndices = recipeIndices
    self.pendingCraftRequests[ticket].recipeBatches = recipeBatches
    self.pendingCraftRequests[ticket].requiredItems = requiredItems
  end
  
  -- Compute the craftProgress table if possible and send to interface/crafting servers. Otherwise we report the error.
  if status == "ok" or status == "missing" then
    local requiresRobots = false
    local requiresDrones = false
    local craftProgress = {}
    -- Set metatable to default to zero for input/output/have if key doesn't exist.
    setmetatable(craftProgress, {__index = function(t, k) rawset(t, k, {inp=0, out=0, hav=0}) return t[k] end})
    for i = 1, #recipeIndices do
      local recipeDetails = self.recipes[recipeIndices[i]]
      if not recipeDetails.station then
        requiresRobots = true
      else
        requiresDrones = true
      end
      for _, input in ipairs(recipeDetails.inp) do
        local inputAmount = (recipeDetails.station and input[2] or #input - 1)
        craftProgress[input[1]].inp = craftProgress[input[1]].inp + inputAmount * recipeBatches[i]
      end
      for outputName, outputAmount in pairs(recipeDetails.out) do
        craftProgress[outputName].out = craftProgress[outputName].out + outputAmount * recipeBatches[i]
      end
    end
    for k, v in pairs(craftProgress) do
      v.hav = (self.storageItems[k] and self.storageItems[k].total or 0)
    end
    
    dlog.out("craftCheckRecipe", "craftProgress:", craftProgress)
    
    if status == "ok" then
      -- Confirm we will not have problems with a crafting recipe that needs robots when we have none (same for drones).
      if (not requiresRobots or self.workers.totalRobots > 0) and (not requiresDrones or self.workers.totalDrones > 0) then
        wnet.send(modem, address, COMMS_PORT, packer.pack.craft_recipe_confirm(ticket, craftProgress))
        wnet.send(modem, self.storageServerAddress, COMMS_PORT, packer.pack.stor_recipe_reserve(ticket, requiredItems))
      else
        local errorMessage = "Recipe requires "
        if requiresRobots then
          if requiresDrones then
            errorMessage = errorMessage .. "robots and drones"
          else
            errorMessage = errorMessage .. "robots"
          end
        else
          errorMessage = errorMessage .. "drones"
        end
        errorMessage = errorMessage .. ", but only " .. self.workers.totalRobots .. " robots and " .. self.workers.totalDrones .. " drones are active."
        
        wnet.send(modem, address, COMMS_PORT, packer.pack.craft_recipe_error("check", errorMessage))
      end
    else
      wnet.send(modem, address, COMMS_PORT, packer.pack.craft_recipe_confirm("missing", craftProgress))
    end
  else
    -- Error status was returned from solveDependencyGraph(), the second return value recipeIndices contains the error message.
    wnet.send(modem, address, COMMS_PORT, packer.pack.craft_recipe_error("check", recipeIndices))
  end
end
packer.callbacks.craft_check_recipe = Crafting.handleCraftCheckRecipe


-- Start crafting operation. Forward request to storage and move entry in
-- pendingCraftRequests to active.
function Crafting:handleCraftRecipeStart(_, _, ticket)
  if not self.pendingCraftRequests[ticket] then
    return
  end
  assert(not self.activeCraftRequests[ticket], "Attempt to start recipe for ticket " .. ticket .. " which is already running.")
  wnet.send(modem, self.storageServerAddress, COMMS_PORT, packer.pack.stor_recipe_start(ticket))
  self.activeCraftRequests[ticket] = self.pendingCraftRequests[ticket]
  self.pendingCraftRequests[ticket] = nil
  
  -- Add/update an item in the storedItems table. The dependentIndex is the
  -- index in recipeIndices corresponding to the recipe that includes this item
  -- as an input.
  local function initializeStoredItem(storedItems, itemName, dependentIndex)
    if not storedItems[itemName] then
      storedItems[itemName] = {}
      storedItems[itemName].total = 0
      storedItems[itemName].lastTime = computer.uptime()
      storedItems[itemName].dependents = {}
    end
    storedItems[itemName].dependents[#storedItems[itemName].dependents + 1] = dependentIndex
  end
  
  self.activeCraftRequests[ticket].startTime = computer.uptime()
  self.activeCraftRequests[ticket].storedItems = {}
  self.activeCraftRequests[ticket].recipeStartIndex = 1
  self.activeCraftRequests[ticket].recipeStatus = {}
  self.activeCraftRequests[ticket].supplyIndices = {}
  self.activeCraftRequests[ticket].taskCounter = 1
  self.activeCraftRequests[ticket].craftingTasks = {}
  
  -- Add each recipe used and inputs/outputs to storedItems.
  for i, recipeIndex in ipairs(self.activeCraftRequests[ticket].recipeIndices) do
    for _, input in ipairs(self.recipes[recipeIndex].inp) do
      initializeStoredItem(self.activeCraftRequests[ticket].storedItems, input[1], i)
    end
    for output, amount in pairs(self.recipes[recipeIndex].out) do
      initializeStoredItem(self.activeCraftRequests[ticket].storedItems, output, nil)
    end
    self.activeCraftRequests[ticket].recipeStatus[i] = {}
    self.activeCraftRequests[ticket].recipeStatus[i].dirty = true
    self.activeCraftRequests[ticket].recipeStatus[i].available = 0
    self.activeCraftRequests[ticket].recipeStatus[i].maxLastTime = 0
  end
  
  -- Update the totals for storedItems from the requiredItems (these have been reserved already in storage).
  for itemName, amount in pairs(self.activeCraftRequests[ticket].requiredItems) do
    self.activeCraftRequests[ticket].storedItems[itemName].total = amount
  end
  
  dlog.out("d", "end of craft_recipe_start, storedItems is:", self.activeCraftRequests[ticket].storedItems)
end
packer.callbacks.craft_recipe_start = Crafting.handleCraftRecipeStart


-- Cancel crafting operation. Forward request to storage and clear entry in
-- pendingCraftRequests.
function Crafting:handleCraftRecipeCancel(_, _, ticket)
  if self.pendingCraftRequests[ticket] or self.activeCraftRequests[ticket] then
    wnet.send(modem, self.storageServerAddress, COMMS_PORT, packer.pack.stor_recipe_cancel(ticket))
    self.pendingCraftRequests[ticket] = nil
    self.activeCraftRequests[ticket] = nil
  end
end
packer.callbacks.craft_recipe_cancel = Crafting.handleCraftRecipeCancel


-- Drone has encountered a compile/runtime error.
function Crafting:handleDroneError(_, _, errType, errMessage)
  dlog.out("drone", "Drone " .. errType .. " error: " .. string.format("%q", errMessage))
end
packer.callbacks.drone_error = Crafting.handleDroneError


-- Robot has results from rlua command, print them to stdout.
function Crafting:handleRobotUploadRluaResult(address, _, message)
  io.write("[" .. string.sub(address, 1, 5) .. "] " .. string.format("%q", message) .. "\n")
end
packer.callbacks.robot_upload_rlua_result = Crafting.handleRobotUploadRluaResult


-- Robot has finished a crafting operation. Verify that all of the robots
-- finished doing stuff before we continue.
function Crafting:handleRobotFinishedCraft(address, _, ticket, taskID)
  assert(self.workers.robots[address] == "busy", "Robot reported finished craft but was not marked busy.")
  self.workers.robots[address] = "free"
  
  local cachedCraftingTask = self.activeCraftRequests[ticket].craftingTasks[taskID]
  assert(cachedCraftingTask.robots[address], "Robot reported finished craft but was not marked for task.")
  cachedCraftingTask.robots[address] = nil
  
  dlog.out("robot", "Robot finished crafting for ticket " .. ticket .. " and task " .. taskID)
  if next(cachedCraftingTask.robots) ~= nil then
    return
  end
  dlog.out("robot", "Task " .. taskID .. " is finished.")
  
  -- Add newly crafted items to storedItems.
  for outputName, amount in pairs(cachedCraftingTask.recipe.out) do
    updateStoredItem(self.activeCraftRequests[ticket], outputName, amount * cachedCraftingTask.numBatches)
  end
  
  -- Mark the drone inventory with crafted items as an input, add it to supply, and remove the crafting task.
  self.droneInventories.inv[cachedCraftingTask.droneInvIndex].status = "input"
  self.activeCraftRequests[ticket].supplyIndices[cachedCraftingTask.droneInvIndex] = true
  self.activeCraftRequests[ticket].craftingTasks[taskID] = nil
end
packer.callbacks.robot_finished_craft = Crafting.handleRobotFinishedCraft


-- Robot has encountered a compile/runtime error.
function Crafting:handleRobotError(_, _, errType, errMessage)
  dlog.out("robot", "Robot " .. errType .. " error: " .. string.format("%q", errMessage))
  
  -- Crafting operation ran into an error and needs to stop. Error gets reported to interface.
  if errType == "crafting_failed" then
    local ticket = string.match(errMessage, "[^;]*")
    errMessage = string.sub(errMessage, #ticket + 2)
    handleCraftRecipeCancel(self, _, _, ticket)
    sendToAddresses(self.interfaceServerAddresses, packer.pack.craft_recipe_error(ticket, errMessage))
  end
end
packer.callbacks.robot_error = Crafting.handleRobotError


-- Performs setup and initialization tasks.
function Crafting:setupThreadFunc(mainContext)
  dlog.out("main", "Setup thread starts.")
  modem.open(COMMS_PORT)
  self.interfaceServerAddresses = {}
  self.pendingCraftRequests = {}
  self.activeCraftRequests = {}
  self.workers = {}
  math.randomseed(os.time())
  
  self:testDependencySolver()
  mainContext.killProgram = true
  os.exit()
  
  io.write("Loading recipes...\n")
  self.stations = {}
  self.recipes = {}
  loadRecipes(self.stations, self.recipes, "recipes/torches.craft")
  loadRecipes(self.stations, self.recipes, "recipes/plates.proc")
  verifyRecipes(self.stations, self.recipes)
  
  --dlog.out("setup", "stations and recipes:", self.stations, self.recipes)
  
  io.write("Loading configuration...\n")
  self.workers.robotConnections = loadRobotsConfig(ROBOTS_CONFIG_FILENAME)
  
  --dlog.out("setup", "robotConnections:", self.workers.robotConnections)
  
  -- Contact the storage server.
  local attemptNumber = 1
  local lastAttemptTime = 0
  self.storageServerAddress = false
  while not self.storageServerAddress do
    if computer.uptime() >= lastAttemptTime + 2 then
      lastAttemptTime = computer.uptime()
      term.clearLine()
      io.write("Trying to contact storage server on port " .. COMMS_PORT .. " (attempt " .. attemptNumber .. ")...")
      wnet.send(modem, nil, COMMS_PORT, packer.pack.stor_discover())
      attemptNumber = attemptNumber + 1
    end
    local address, port, header, data = packer.extractPacket(wnet.receive(0.1))
    if port == COMMS_PORT and header == "stor_item_list" then
      self.storageItems = packer.unpack.stor_item_list(data)
      self.storageServerAddress = address
    end
  end
  io.write("\nSuccess.\n")
  
  --local status, recipeIndices, recipeBatches, requiredItems = self:solveDependencyGraph("minecraft:torch/0", 16)
  
  --self.storageItems["stuff:impossible/0"] = {}
  --self.storageItems["stuff:impossible/0"].maxSize = 64
  --self.storageItems["stuff:impossible/0"].label = "impossible"
  --self.storageItems["stuff:impossible/0"].total = 1
  --local status, recipeIndices, recipeBatches, requiredItems = self:solveDependencyGraph("stuff:nou/0", 100)
  
  --dlog.out("info", "status = " .. status)
  --if status == "ok" or status == "missing" then
    --dlog.out("info", "recipeIndices/recipeBatches:")
    --for i = 1, #recipeIndices do
      --dlog.out("info", recipeIndices[i] .. " (" .. next(self.recipes[recipeIndices[i]].out) .. ") -> " .. recipeBatches[i])
    --end
    --dlog.out("info", "requiredItems:", requiredItems)
  --end
  
  -- Report system started to other listening devices (so they can re-discover the crafting server).
  wnet.send(modem, nil, COMMS_PORT, packer.pack.craft_started())
  
  io.write("\nStarting up robots...\n")
  -- Reset any running robots.
  wnet.send(modem, nil, COMMS_PORT, packer.pack.robot_halt())
  os.sleep(1)
  
  -- Send robot code to active robots.
  local dlogWnetState = dlog.subsystems.wnet
  dlog.setSubsystem("wnet", false)
  for libName, srcCode in include.iterateSrcDependencies("robot_up.lua") do
    wnet.send(modem, nil, COMMS_PORT, packer.pack.robot_upload(libName, srcCode))
  end
  dlog.setSubsystem("wnet", dlogWnetState)
  
  -- Wait for robots to receive the software update and keep track of their addresses.
  self.workers.totalRobots = 0
  self.workers.robots = {}
  while true do
    local address, port, _, data = wnet.waitReceive(nil, COMMS_PORT, "robot_started,", 2)
    if address then
      self.workers.totalRobots = self.workers.totalRobots + (self.workers.robots[address] and 0 or 1)
      self.workers.robots[address] = "free"
    else
      break
    end
  end
  
  io.write("Found " .. self.workers.totalRobots .. " active robots.\n")
  
  self.workers.totalDrones = 0
  self.workers.drones = {}
  
  wnet.send(modem, self.storageServerAddress, COMMS_PORT, packer.pack.stor_get_drone_item_list())
  
  mainContext.threadSuccess = true
  dlog.out("main", "Setup thread ends.")
end


-- Listens for incoming packets over the network and deals with them.
function Crafting:modemThreadFunc(mainContext)
  dlog.out("main", "Modem thread starts.")
  io.write("Listening for commands on port " .. COMMS_PORT .. "...\n")
  while true do
    local address, port, message = wnet.receive()
    if port == COMMS_PORT then
      packer.handlePacket(self, address, port, message)
    end
  end
  dlog.out("main", "Modem thread ends.")
end


-- Iterate the droneInventories starting from startIndex. Stop and return
-- index if we find one with "free" status, or allowInput is true and we find
-- one with "input" status. If none found, return -1.
function Crafting:findNextFreeDroneInv(startIndex, allowInput)
  if startIndex <= 0 then
    return -1
  end
  for i = startIndex, #self.droneInventories.inv do
    if self.droneInventories.inv[i].status == "free" or (allowInput and self.droneInventories.inv[i].status == "input") then
      return i
    end
  end
  return -1
end

-- Similar to findNextFreeDroneInv(), but only counts inventories reachable by
-- robots with at least one robot available. Note that even if the inventory
-- is free now, it may not be later if the only adjacent robot is assigned a
-- task elsewhere.
function Crafting:findNextFreeDroneInvWithRobot(startIndex, allowInput)
  if startIndex <= 0 then
    return -1
  end
  for i = startIndex, #self.droneInventories.inv do
    if self.droneInventories.inv[i].status == "free" or (allowInput and self.droneInventories.inv[i].status == "input") then
      for address, _ in pairs(self.workers.robotConnections[i]) do
        if self.workers.robots[address] == "free" then
          return i
        end
      end
    end
  end
  return -1
end

-- Search for an available spot in droneInventories and reserve it.
-- Inventories with "free" status are chosen first, but if none are found then
-- the first "input" inventory is flushed to make space. Updates the status of
-- the inventory and ticket, and returns the index of the inventory. If no
-- space could be made, returns -1.
-- FIXME if we ever need to use this outside of the crafting thread, this needs to be thread-safe. Use a spin lock to do this. #################################
function Crafting:allocateDroneInventory(ticket, usage, needRobots)
  dlog.checkArgs(ticket, "string,nil", usage, "string", needRobots, "boolean,nil")
  assert(usage == "input" or usage == "output", "Provided usage is not valid.")
  needRobots = needRobots or false
  
  local droneInvIndex
  if not needRobots then
    -- Check if invalid firstFree, and rescan from the beginning to update it.
    if self.droneInventories.firstFree <= 0 then
      self.droneInventories.firstFree = self:findNextFreeDroneInv(1, true)
      if self.droneInventories.firstFree <= 0 then
        return -1
      end
      -- If found an input inventory, flush it back to storage.
      if self.droneInventories.inv[self.droneInventories.firstFree].status == "input" then
        assert(self:flushDroneInventory(ticket, self.droneInventories.firstFree, true), "Failed to flush drone inventory " .. self.droneInventories.firstFree .. " to storage.")
      end
    end
    
    droneInvIndex = self.droneInventories.firstFree
    self.droneInventories.firstFree = self:findNextFreeDroneInv(self.droneInventories.firstFree + 1, false)
    self.droneInventories.firstFreeWithRobot = self:findNextFreeDroneInvWithRobot(self.droneInventories.firstFreeWithRobot, false)
  else
    -- Check if invalid firstFreeWithRobot, and rescan from the beginning to update it.
    if self.droneInventories.firstFreeWithRobot <= 0 then
      self.droneInventories.firstFreeWithRobot = self:findNextFreeDroneInvWithRobot(1, true)
      if self.droneInventories.firstFreeWithRobot <= 0 then
        return -1
      end
      -- If found an input inventory, flush it back to storage.
      if self.droneInventories.inv[self.droneInventories.firstFreeWithRobot].status == "input" then
        assert(self:flushDroneInventory(ticket, self.droneInventories.firstFreeWithRobot, true), "Failed to flush drone inventory " .. self.droneInventories.firstFreeWithRobot .. " to storage.")
      end
    end
    
    droneInvIndex = self.droneInventories.firstFreeWithRobot
    self.droneInventories.firstFree = self:findNextFreeDroneInv(self.droneInventories.firstFree, false)
    self.droneInventories.firstFreeWithRobot = self:findNextFreeDroneInvWithRobot(self.droneInventories.firstFreeWithRobot + 1, false)
  end
  
  self.droneInventories.inv[droneInvIndex].status = usage
  self.droneInventories.inv[droneInvIndex].ticket = ticket
  
  dlog.out("allocateDroneInventory", "Allocated index " .. droneInvIndex .. " as an " .. usage .. " for ticket " .. ticket)
  dlog.out("allocateDroneInventory", "firstFree = " .. self.droneInventories.firstFree .. ", firstFreeWithRobot = " .. self.droneInventories.firstFreeWithRobot)
  
  return droneInvIndex
end

-- Sends a request to storage to move the contents of the drone inventory back
-- into the network. If waitForCompletion is true, this function blocks until
-- a response from storage server is received in modem thread. The ticket can
-- be nil. Returns true if flush succeeded (or waitForCompletion is false), or
-- false if it did not.
function Crafting:flushDroneInventory(ticket, droneInvIndex, waitForCompletion)
  dlog.checkArgs(ticket, "string,nil", droneInvIndex, "number", waitForCompletion, "boolean")
  
  dlog.out("flushDroneInventory", "Requesting flush for index " .. droneInvIndex)
  
  self.droneInventories.pendingInsert = "pending"
  wnet.send(modem, self.storageServerAddress, COMMS_PORT, packer.pack.stor_drone_insert(droneInvIndex, ticket))
  
  local result = true
  if waitForCompletion then
    local i = 1
    while self.droneInventories.pendingInsert == "pending" do
      -- If insert request has not completed in 30 seconds, we assume there has been a problem.
      if i > 600 then
        dlog.out("d", "Oof, insert request took too long (over 30s)")
        error("Craft failed")
      end
      os.sleep(0.05)
      i = i + 1
    end
    
    dlog.out("flushDroneInventory", "Result is " .. self.droneInventories.pendingInsert)
    
    result = (self.droneInventories.pendingInsert == "ok")
    self.droneInventories.pendingInsert = nil
    if result then
      -- Inventory goes back to free, and we need to check if the firstFree indices need to be moved back.
      self.droneInventories.inv[droneInvIndex].status = "free"
      self.droneInventories.inv[droneInvIndex].ticket = nil
      
      if self.droneInventories.firstFree <= 0 or droneInvIndex < self.droneInventories.firstFree then
        self.droneInventories.firstFree = droneInvIndex
      end
      if self.droneInventories.firstFreeWithRobot <= 0 or droneInvIndex < self.droneInventories.firstFreeWithRobot then
        self.droneInventories.firstFreeWithRobot = self:findNextFreeDroneInvWithRobot(droneInvIndex, false)
      end
      
      -- Remove any marker that this is a supply inventory, since it has just been emptied.
      if ticket then
        self.activeCraftRequests[ticket].supplyIndices[droneInvIndex] = nil
      end
    end
  end
  
  return result
end

--[[

Note about assigning robots work:
  When an inventory is allocated for robot work, the robot must finish and
return items to the inventory (which then gets marked as an input). The robot
is added back to the available list. The robot CANNOT accept more work from
that inventory until it is allocated again. We must not get into a situation
where a robot goes from free to busy without updating the firstFreeWithRobot
index (robot could be shared between two inventories and giving it new work
could invalidate our index).

crafting process:
  crafting ticket moves to active
  for each active ticket
    check what new resources have been generated
    if resources needed for current recipe and they are now available, queue up more crafting for it
    
  end

which inventories in use, by who? what for?
what resources have been crafted?
last time each resource was crafted? how fast are they being crafted? (we need to decide how much to batch before sending items into next craft operation to allow pipelining)
when resource gets created, which recipes does it apply to?

--]]

-- 
function Crafting:updateCraftRequest(ticket, craftRequest)
  -- Return early if drone extract is pending (avoid queuing up another request so that we don't overwhelm storage server).
  if self.droneInventories.pendingExtract == "pending" then
    return
  elseif self.droneInventories.pendingExtract then
    if self.droneInventories.pendingExtract ~= "ok" then
      dlog.out("d", "Oh no, drone extract request failed?!")
      error("Craft failed")
    end
    
    dlog.out("d", "Extract request completed, go robots!")
    for address, status in pairs(self.workers.robots) do
      if status == "pending" then
        self.workers.robots[address] = "busy"
        -- Note that we could send droneItems to the robots here, it's probably safe. Probably still better to just spend an extra tick to let robots scan inv themselves (inventory contents will go stale fast).
        wnet.send(modem, address, COMMS_PORT, packer.pack.robot_start_craft())
      end
    end
    self.droneInventories.pendingExtract = nil
  end
  
  for i = craftRequest.recipeStartIndex, #craftRequest.recipeIndices do
    if craftRequest.recipeBatches[i] > 0 then
      local recipeStatus = craftRequest.recipeStatus[i]
      local recipe = self.recipes[craftRequest.recipeIndices[i]]
      
      -- Re-calculate the max amount of batches we can craft and time of most recently crafted item if recipe inputs changed.
      if recipeStatus.dirty then
        local maxLastTime = 0
        local maxBatch = math.huge
        
        -- FIXME may want to factor in the fact that drone inventories are limited, and items have max stack size.
        -- proposed fix: run this in a loop. count up the number of occupied slots as we go and if we run over the inventory size, cut the maxBatch in half and try again.
        -- if reach zero and maxBatch had been reduced in previous iteration, throw error because we are supposed to craft at least some of the item and items don't fit in inventory.
        
        -- For each input item in recipe, scale the maxBatch down if the amount we have is limiting and increase maxLastTime to the max lastTime.
        for _, input in ipairs(recipe.inp) do
          local recipeItemAmount = (recipe.station and input[2] or #input - 1)
          maxBatch = math.min(maxBatch, math.floor(craftRequest.storedItems[input[1]].total / recipeItemAmount))
          maxLastTime = math.max(maxLastTime, craftRequest.storedItems[input[1]].lastTime)
        end
        
        recipeStatus.dirty = false
        recipeStatus.available = maxBatch
        recipeStatus.maxLastTime = maxLastTime
      end
      
      -- FIXME: For now we assume all recipes are crafting here ############################################################
      
      -- Check if we can make some batches now, and that some robots/drones are available to work.
      if recipeStatus.available > 0 then
        -- Verify criteria is met before attempting to allocate an inventory (for processing recipe, we must have some drones ready).
        local nextReadyDrone
        if recipe.station then
          for address, status in pairs(self.workers.drones) do
            if status == "free" then
              nextReadyDrone = address
              break
            end
          end
        end
        local freeIndex = -1
        if not recipe.station or nextReadyDrone then
          freeIndex = self:allocateDroneInventory(ticket, "output", not recipe.station)
        end
        
        if not recipe.station and freeIndex > 0 then
          -- Collect robots ready for this task. Do this here so we can guarantee there hasn't been a context switch after the call to allocateDroneInventory() ends.
          -- Otherwise, some robots could finish their tasks and we could give work to the wrong bots.
          local readyWorkers = {}
          local numReadyWorkers = 0
          for address, side in pairs(self.workers.robotConnections[freeIndex]) do
            if self.workers.robots[address] == "free" then
              readyWorkers[address] = side
              numReadyWorkers = numReadyWorkers + 1
            end
          end
          
          -- Determine the recipe input items we need to move into the allocated inventory (gets sent as request to storage later).
          local extractList = {}
          for i, input in ipairs(recipe.inp) do
            extractList[i] = {input[1], recipeStatus.available * (#input - 1)}
          end
          extractList.supplyIndices = craftRequest.supplyIndices
          
          --[[
          craftingTask: {
            droneInvIndex: <number>
            side: <number>
            numBatches: <number>
            ticket: <ticket>
            recipe: <single recipe entry from recipes table>
            taskID: <number>
          }
          --]]
          
          -- Task sent to robots.
          local craftingTask = {}
          craftingTask.droneInvIndex = freeIndex
          craftingTask.numBatches = math.ceil(recipeStatus.available / numReadyWorkers)
          craftingTask.ticket = ticket
          craftingTask.recipe = recipe
          craftingTask.taskID = craftRequest.taskCounter
          
          -- Task cached by crafting server so we can verify completion later.
          local cachedCraftingTask = {}
          cachedCraftingTask.droneInvIndex = freeIndex
          cachedCraftingTask.numBatches = recipeStatus.available
          cachedCraftingTask.recipe = recipe
          cachedCraftingTask.robots = {}
          craftRequest.craftingTasks[craftRequest.taskCounter] = cachedCraftingTask
          craftRequest.taskCounter = craftRequest.taskCounter + 1
          
          -- Assign task to each of the robots (not all of the readyWorkers will be given a task though, depends on number of robots and number of batches).
          for address, side in pairs(readyWorkers) do
            craftingTask.side = side
            craftingTask.numBatches = math.min(craftingTask.numBatches, recipeStatus.available)
            cachedCraftingTask.robots[address] = true
            
            self.workers.robots[address] = "pending"
            wnet.send(modem, address, COMMS_PORT, packer.pack.robot_prepare_craft(craftingTask))
            
            -- Reduce the total batches-to-craft from the craftRequest, and same for available amount. If no more batches left for next bots we break early.
            craftRequest.recipeBatches[i] = craftRequest.recipeBatches[i] - craftingTask.numBatches
            recipeStatus.available = recipeStatus.available - craftingTask.numBatches
            if recipeStatus.available == 0 then
              break
            end
          end
          
          self.droneInventories.pendingExtract = "pending"
          wnet.send(modem, self.storageServerAddress, COMMS_PORT, packer.pack.stor_drone_extract(freeIndex, ticket, extractList))
          
          -- After extractList sent, unmark the supply indices as dirty because storage will rescan them.
          for i, _ in pairs(craftRequest.supplyIndices) do
            craftRequest.supplyIndices[i] = false
          end
          
          -- Remove the requested extract items from craftRequest.storedItems, then confirm later that the request succeeded.
          for i, extractItem in ipairs(extractList) do
            updateStoredItem(craftRequest, extractItem[1], -(extractItem[2]))
          end
          dlog.out("d", "craftRequest.storedItems is:", craftRequest.storedItems)
          
        elseif recipe.station and freeIndex > 0 then
          
        end
        
        
        
      end
    elseif craftRequest.recipeStartIndex == i then
      -- The recipeStartIndex corresponds to a batch size of zero, shift it down one so we don't keep looping over the leading zero.
      craftRequest.recipeStartIndex = i + 1
    end
  end
  
  -- If the recipeStartIndex passed the array length, no more crafting tasks remain, and supply inventories have all been flushed, the crafting request is complete.
  if craftRequest.recipeStartIndex > #craftRequest.recipeIndices and next(craftRequest.craftingTasks) == nil then
    dlog.out("updateCraftRequest", "Request " .. ticket .. " has finished, returning items to storage.")
    if next(craftRequest.supplyIndices) ~= nil then
      self:flushDroneInventory(ticket, (next(craftRequest.supplyIndices)), true)
    else
      dlog.out("d", "droneInventories is", self.droneInventories)
      dlog.out("d", "workers is", self.workers)
      
      -- Sanity checks to confirm all stored items have an amount of zero and no more drone inventories are bound to this ticket.
      for itemName, storedItem in pairs(craftRequest.storedItems) do
        assert(storedItem.total == 0, "Ticket " .. ticket .. " has finished but storedItem for " .. itemName .. " has amount " .. storedItem.total)
      end
      for i, inv in pairs(self.droneInventories.inv) do
        assert(inv.ticket ~= ticket, "Ticket " .. ticket .. " has finished but drone inventory " .. i .. " still bound to ticket.")
      end
      
      -- FIXME signal that request completed and ticket can be removed. ######################################
      
      dlog.out("updateCraftRequest", "Removing completed request " .. ticket)
      self.activeCraftRequests[ticket] = nil
      
    end
  end
end


-- 
function Crafting:craftingThreadFunc(mainContext)
  while true do
    for ticket, craftRequest in pairs(self.activeCraftRequests) do
      self:updateCraftRequest(ticket, craftRequest)
      dlog.out("craftingThread", "craftRequest:", craftRequest)
    end
    --os.sleep(0.05)
    os.sleep(2)
  end
end

-- Waits for commands from user-input and executes them.
function Crafting:commandThreadFunc(mainContext)
  dlog.out("main", "Command thread starts.")
  while true do
    io.write("> ")
    local input = io.read()
    if type(input) ~= "string" then
      input = "exit"
    end
    input = text.tokenize(input)
    if input[1] == "insert" then    -- FIXME remove these two later, just for testing. ##########################
      local ticket = next(self.pendingCraftRequests)
      wnet.send(modem, self.storageServerAddress, COMMS_PORT, packer.pack.stor_drone_insert(1, ticket))
    elseif input[1] == "extract" then
      local t = {}
      --t[#t + 1] = {"minecraft:cobblestone/0", 1000}
      --t[#t + 1] = {"minecraft:coal/0", 2}
      t[#t + 1] = {"minecraft:coal/0", 3}
      t[#t + 1] = {"minecraft:redstone/0", 6}
      t[#t + 1] = {"minecraft:stick/0", 4}
      t.supplyIndices = {}
      t.supplyIndices[3] = true  -- true for dirty, false for not
      t.supplyIndices[2] = true
      t.supplyIndices[1] = false
      local ticket = next(self.pendingCraftRequests)
      wnet.send(modem, self.storageServerAddress, COMMS_PORT, packer.pack.stor_drone_extract(4, ticket, t))
    elseif input[1] == "update_firmware" then    -- Command update_firmware. Updates firmware on all active devices (robots, drones, etc).
      io.write("Broadcasting firmware to active devices...\n")
      local srcFile, errMessage = io.open("robot.lua", "rb")
      assert(srcFile, "Cannot open source file \"robot.lua\": " .. tostring(errMessage))
      local dlogWnetState = dlog.subsystems.wnet
      dlog.setSubsystem("wnet", false)
      wnet.send(modem, nil, COMMS_PORT, packer.pack.robot_upload_eeprom(srcFile:read("*a")))
      dlog.setSubsystem("wnet", dlogWnetState)
      srcFile:close()
      
      -- Wait a little bit for devices to reprogram themselves and shutdown. Then wake them back up.
      os.sleep(3)
      modem.broadcast(COMMS_PORT, "robot_activate")
      io.write("Update finished. Please start crafting server application again.\n")
      mainContext.threadSuccess = true
      break
    elseif input[1] == "rlua" then    -- Command rlua <device type>. Runs interactive remote-lua interpreter. Intended for devices that don't have a keyboard.
      if input[2] == "robot" or input[2] == "drone" then
        io.write("Enter a statement to run on active " .. input[2] .. "s.\n")
        io.write("Add a return statement to get a value back.\n")
        io.write("Press Ctrl+D to exit.\n")
        while true do
          io.write("rlua> ")
          local inputCmd = io.read()
          if type(inputCmd) ~= "string" then
            io.write("\n")
            break
          end
          if input[2] == "robot" then
            wnet.send(modem, nil, COMMS_PORT, packer.pack.robot_upload_rlua(inputCmd))
          elseif input[2] == "drone" then
            -- FIXME not yet implemented ###########################################################
          end
        end
      else
        io.write("Invalid device type. Accepted types are: robot, drone.\n")
      end
    elseif input[1] == "dlog" then    -- Command dlog [<subsystem> <0, 1, or nil>]
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
    elseif input[1] == "dbg" then
      dlog.out("dbg", "droneItems:", self.droneItems)
    elseif input[1] == "help" then    -- Command help
      io.write("Commands:\n")
      io.write("  update_firmware\n")
      io.write("    Reprograms EEPROMs on all active robots and drones (the devices must be\n")
      io.write("    powered on and have been discovered during initialization stage). This only\n")
      io.write("    works for devices with an existing programmed EEPROM.\n")
      io.write("  rlua <device type>\n")
      io.write("    Start remote-lua interpreter to run commands on active devices (for\n")
      io.write("    debugging). This is similar to the OpenOS lua command, but for devices\n")
      io.write("    without a full operating system. Current device types are: robot, drone.\n")
      io.write("  dlog [<subsystem> <0, 1, or nil>]\n")
      io.write("    Display diagnostics log info (when called with no arguments), or enable/\n")
      io.write("    disable logging for a subsystem. Use a \"*\" to refer to all subsystems,\n")
      io.write("    except ones that are explicitly disabled.\n")
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
      mainContext.threadSuccess = true
      break
    else
      io.write("Enter \"help\" for command help, or \"exit\" to quit.\n")
    end
  end
  dlog.out("main", "Command thread ends.")
end


-- Main program starts here. Runs a few threads to do setup work, listen for
-- packets, manage crafting jobs, etc.
local function main()
  local mainContext = {}
  mainContext.threadSuccess = false
  mainContext.killProgram = false
  
  -- Captures the interrupt signal to stop program.
  local interruptThread = thread.create(function()
    event.pull("interrupted")
  end)
  
  -- Blocks until any of the given threads finish. If threadSuccess is still
  -- false and a thread exits, reports error and exits program.
  local function waitThreads(threads)
    thread.waitForAny(threads)
    if interruptThread:status() == "dead" or mainContext.killProgram then
      dlog.osBlockNewGlobals(false)
      os.exit(1)
    elseif not mainContext.threadSuccess then
      io.stderr:write("Error occurred in thread, check log file \"/tmp/event.log\" for details.\n")
      dlog.osBlockNewGlobals(false)
      os.exit(1)
    end
    mainContext.threadSuccess = false
  end
  
  if DLOG_FILE_OUT ~= "" then
    dlog.setFileOut(DLOG_FILE_OUT, "w")
  end
  
  local crafting = Crafting:new()
  
  local setupThread = thread.create(Crafting.setupThreadFunc, crafting, mainContext)
  
  waitThreads({interruptThread, setupThread})
  
  local modemThread = thread.create(Crafting.modemThreadFunc, crafting, mainContext)
  local craftingThread = thread.create(Crafting.craftingThreadFunc, crafting, mainContext)
  local commandThread = thread.create(Crafting.commandThreadFunc, crafting, mainContext)
  
  waitThreads({interruptThread, modemThread, craftingThread, commandThread})
  
  dlog.out("main", "Killing threads and stopping program.")
  interruptThread:kill()
  modemThread:kill()
  craftingThread:kill()
  commandThread:kill()
end

main()
dlog.osBlockNewGlobals(false)
