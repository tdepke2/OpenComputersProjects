--[[


more research sources to look into:

factorio solvers using simplex algo:
http://kirkmcdonald.github.io/posts/calculation.html
https://github.com/factoriolab/factorio-lab/wiki/Optimizing-the-Solution

linear programming/simplex solver:
https://en.wikipedia.org/wiki/Linear_programming
https://en.wikipedia.org/wiki/Simplex_algorithm
https://en.wikipedia.org/wiki/Revised_simplex_method

other:
https://wiki.factorio.com/


--]]

local include = require("include")
local dlog = include("dlog")
local dstructs = include("dstructs")

local solver = {}

local CRAFT_SOLVER_MAX_RECURSION = 1000
local CRAFT_SOLVER_PRIORITY = 0
-- 0 = first found (recipes ordered by priority)
-- 1 = min items
-- 2 = min batches
-- might want to try instead: https://unendli.ch/posts/2016-07-22-enumerations-in-lua.html

-- Class to wrap the state of the dependency solver into a single object. Helps
-- reduce the amount of data needed in the local scope and abstracts some common
-- operations.
local SolverState = {
  defaultZeroMeta = {__index = function() return 0 end}
}

-- Creates a new SolverState instance.
function SolverState:new(recipes, storageItems)
  self.__index = self
  self = setmetatable({}, self)
  
  self.recipes = recipes
  self.storageItems = storageItems
  
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
  -- For the amount, a negative value corresponds to a batch size (not really an amount) and has already been processed.
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
  
  --self.bestCraftingTotal = math.huge    -- Best minimum number of items to craft found thus far.
  self.numMissingItems = 0
  self.bestNumMissingItems = math.huge
  
  -- Current best result found.
  --self.resultStatus = ""
  --self.resultIndices = {}
  --self.resultBatches = {}
  --self.resultInputs = {}
  --self.resultOutputs = {}
  
  return self
end

-- Directly adds an input to itemInputs.
function SolverState:addItemInput(itemName, amount)
  self.itemInputs[itemName] = self.itemInputs[itemName] + amount
end

-- Indirectly adds an output to itemNAOutputs. The item must be registered to
-- this table at a later time with SolverState:buildNextNAOutput() once a branch
-- is completed and trimmed.
function SolverState:addItemOutput(itemName, amount)
  self.outputStackSize = self.outputStackSize + 1
  self.outputNames[self.outputStackSize] = itemName
  self.outputAmounts[self.outputStackSize] = amount
end

-- Register the last-added output to itemNAOutputs (FILO order).
function SolverState:buildNextNAOutput()
  local itemName = self.outputNames[self.outputStackSize]
  self.itemNAOutputs[itemName] = self.itemNAOutputs[itemName] + self.outputAmounts[self.outputStackSize]
  
  self.outputNames[self.outputStackSize] = nil
  self.outputAmounts[self.outputStackSize] = nil
  self.outputStackSize = self.outputStackSize - 1
end

-- Check if craft* stacks empty.
function SolverState:craftEmpty()
  return self.craftStackSize == 0
end

-- Get size of craft* stacks.
function SolverState:craftSize()
  return self.craftStackSize
end

-- Get top element in craft* stacks.
function SolverState:craftTop()
  return self.craftNames[self.craftStackSize], self.craftIndices[self.craftStackSize], self.craftAmounts[self.craftStackSize]
end

-- Push new element to craft* stacks.
function SolverState:craftPush(name, recipeIndex, amount)
  self.craftStackSize = self.craftStackSize + 1
  self.craftNames[self.craftStackSize] = name
  self.craftIndices[self.craftStackSize] = recipeIndex
  self.craftAmounts[self.craftStackSize] = amount
end

-- Pop the top element from craft* stacks. As a consequence, this first adds the
-- element to the processed* arrays, caching it as part of the solution in the
-- crafting chain.
function SolverState:craftPop()
  local craftIndicesTop = self.craftIndices[self.craftStackSize]
  -- Get the multiplier that was set in attemptRecipe().
  local mult = -self.craftAmounts[self.craftStackSize]
  local i = self.mapProcessedIndices[craftIndicesTop]
  
  -- If the recipe index was previously found, then update the existing entry instead of adding a new one.
  if not i then
    i = #self.processedIndices + 1
    self.mapProcessedIndices[craftIndicesTop] = i
    self.processedIndices[i] = craftIndicesTop
    self.processedBatches[i] = mult
  else
    self.processedBatches[i] = self.processedBatches[i] + mult
  end
  
  self.craftNames[self.craftStackSize] = nil
  self.craftIndices[self.craftStackSize] = nil
  self.craftAmounts[self.craftStackSize] = nil
  self.craftStackSize = self.craftStackSize - 1
end


-- Make a deep copy of solverState (besides data that persists across crafting
-- attempts, like the best result found) so we can evaluate the crafting
-- dependencies at a later time. This assumes that we will call
-- restoreCraftState() later on within the same recursion depth.
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
  
  cache.numMissingItems = solverState.numMissingItems
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
  
  solverState.numMissingItems = cache.numMissingItems
  cache.valid = nil
end

-- Forward declares for below functions (cyclic dependency).
local recursiveSolve, attemptRecipe

-- Primary recursive step in the dependency solver, expects a target item in
-- solverState craft* stacks. The recursionDepth starts at zero, and represents
-- the number of items processed from the craft* stacks (not the same as the
-- dependency "tree" depth).
recursiveSolve = function(recursionDepth, solverState)
  assert(recursionDepth < 50, "Recipe too complex or not possible.")    -- FIXME may want to limit the max number of calls in addition to max depth. ############################################
  local spacing = string.rep("  ", recursionDepth)
  local currentName, currentIndex, currentAmount = solverState:craftTop()
  dlog.out("recipeSolver", spacing .. "recursiveSolve(" .. recursionDepth .. ")")
  
  -- If recipe for the target item has been pre-selected or there is only one recipe option, then use that one only (tail call optimization).
  -- Else, in the case that there are multiple recipes that make the item, use the following strategy to attempt some combinations of the recipes that are likely to succeed.
  if currentIndex ~= -1 then
    dlog.out("recipeSolver", spacing .. "Recipe " .. currentIndex .. " was pre-selected")
    return attemptRecipe(recursionDepth, solverState)
  elseif #solverState.recipes[currentName] == 1 then
    solverState.craftIndices[solverState.craftStackSize] = solverState.recipes[currentName][1]
    return attemptRecipe(recursionDepth, solverState)
  else
    local solverStateCache = {}
    
    -- Try each alternate recipe independently (no mixing different types).
    dlog.out("recipeSolver", spacing .. "Mix method 1: try each recipe independently.")
    for _, recipeIndex in ipairs(solverState.recipes[currentName]) do
      cacheCraftState(recursionDepth, solverState, solverStateCache)
      solverState.craftIndices[solverState.craftStackSize] = recipeIndex
      attemptRecipe(recursionDepth, solverState)
      restoreCraftState(recursionDepth, solverState, solverStateCache)
      if solverState.resultStatus == "ok" then
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
    for i, recipeIndex in ipairs(solverState.recipes[currentName]) do
      local currentRecipe = solverState.recipes[recipeIndex]
      local mult = math.huge
      
      for _, input in ipairs(currentRecipe.inp) do
        local inputName = input[1]
        local inputAmount = (currentRecipe.station and input[2] or #input - 1)
        local availableAmount = math.max((solverState.storageItems[inputName] and solverState.storageItems[inputName].total or 0) - solverState.itemInputs[inputName] + solverState.itemNAOutputs[inputName], 0)
        
        -- Reduce mult if resource does not have a recipe (it's raw) and it's limiting the amount we can craft.
        if not solverState.recipes[inputName] and mult * inputAmount > availableAmount then
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
        solverState.craftIndices[solverState.craftStackSize] = solverState.recipes[currentName][i]
        solverState.craftAmounts[solverState.craftStackSize] = newAmount
        dlog.out("recipeSolver", spacing .. "Added amount " .. newAmount .. " for recipe " .. solverState.recipes[currentName][i] .. " (i = " .. i .. ")")
        
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
          solverState.craftIndices[solverState.craftStackSize] = solverState.recipes[currentName][i]
          solverState.craftAmounts[solverState.craftStackSize] = newAmount
          dlog.out("recipeSolver", spacing .. "Added amount " .. newAmount .. " for recipe " .. solverState.recipes[currentName][i] .. " (i = " .. i .. ")")
          
          if remainingCraftAmount == 0 then
            break
          end
          
          -- Add a new craft entry and copy the original item name. The index and amount will get updated in a later iteration.
          solverState:craftPush(currentName, -1, 0)
        end
      end
    end
    assert(remainingCraftAmount == 0, "Mix method 2 failed: recipe distribution incorrect.")
    attemptRecipe(recursionDepth, solverState)
    restoreCraftState(recursionDepth, solverState, solverStateCache)
    if solverState.resultStatus == "ok" then
      -- FIXME we don't want to return if CRAFT_SOLVER_PRIORITY is set to min items/batches! ###############################################################
      return
    end
    
    dlog.out("recipeSolver", spacing .. "Mix method 3: split even across all recipes.")
    dlog.out("recipeSolver", spacing .. "oops, NYI")
    
  end
end

-- Secondary recursive step in the dependency solver. Evaluates a single recipe
-- to determine inputs required (and schedule these where possible), outputs
-- generated, and whether we have found a solution.
attemptRecipe = function(recursionDepth, solverState)
  local spacing = string.rep("  ", recursionDepth)
  local currentName, currentIndex, currentAmount = solverState:craftTop()
  dlog.out("recipeSolver", spacing .. "Trying recipe " .. currentIndex .. " for " .. currentName .. " with amount " .. currentAmount)
  local currentRecipe = solverState.recipes[currentIndex]
  
  -- Compute amount multiplier as the number of items we need to craft over the number of items we get from the recipe (rounded up).
  local mult = math.ceil(currentAmount / currentRecipe.out[currentName])
  
  -- Mark the top element in the craft* stacks as processed since we do that now.
  -- The value changes from the amount to the multiplier so we can add to processedBatches later.
  solverState.craftAmounts[solverState.craftStackSize] = -mult
  
  -- For each recipe input, add the item inputs to solverState and to the craft* stacks as well if we need to craft more of them.
  for _, input in ipairs(currentRecipe.inp) do
    local inputName = input[1]
    local addAmount = mult * (currentRecipe.station and input[2] or #input - 1)
    local availableAmount = math.max((solverState.storageItems[inputName] and solverState.storageItems[inputName].total or 0) - solverState.itemInputs[inputName] + solverState.itemNAOutputs[inputName], 0)
    
    -- Check if we need more than what's available.
    if addAmount > availableAmount then
      if solverState.recipes[inputName] then
        -- Add the addAmount minus availableAmount to craft* stacks if the recipe is known.
        dlog.out("recipeSolver", spacing .. "Craft " .. addAmount - availableAmount .. " of " .. inputName)
        solverState:craftPush(inputName, -1, addAmount - availableAmount)
      else
        -- Recipe not known so this item will prevent crafting, add to numMissingItems.
        dlog.out("recipeSolver", spacing .. "Missing " .. addAmount - availableAmount .. " of " .. inputName)
        solverState.numMissingItems = solverState.numMissingItems + addAmount - availableAmount
      end
    end
    
    dlog.out("recipeSolver", spacing .. "Require " .. addAmount .. " more of " .. inputName)
    solverState:addItemInput(inputName, addAmount)
  end
  
  -- For each recipe output, add the item outputs to solverState.
  for outputName, amount in pairs(currentRecipe.out) do
    dlog.out("recipeSolver", spacing .. "Add " .. mult * amount .. " of output " .. outputName)
    solverState:addItemOutput(outputName, mult * amount)
  end
  
  -- Purge completed elements from the craft* stacks and swap outputs into the non-ancestors.
  while (solverState.craftAmounts[solverState.craftStackSize] or 0) < 0 do
    solverState:craftPop()
    solverState:buildNextNAOutput()
  end
  dlog.out("recipeSolver", spacing .. "Update NA outputs completed, solverState.outputStackSize = ", solverState.outputStackSize, ", solverState.itemNAOutputs = ", solverState.itemNAOutputs)
  
  -- If no more recipes remaining, solution found. Otherwise we do recursive call.
  if solverState:craftEmpty() then
    dlog.out("recipeSolver", spacing .. "Found solution, numMissingItems = " .. solverState.numMissingItems)
    assert(solverState.outputStackSize == 0, "Got solution, but solverState.outputStackSize not empty.")
    
    dlog.out("recipeSolver", spacing .. "itemInputs/itemOutputs and processedIndices/processedBatches:", solverState.itemInputs, solverState.itemNAOutputs)
    for i = 1, #solverState.processedIndices do
      dlog.out("recipeSolver", spacing .. i .. ": index " .. solverState.processedIndices[i] .. " batch " .. solverState.processedBatches[i])
    end
    
    --[[
    -- Determine the total number of items to craft and compare with the best found so far.
    local craftingTotal = 0
    for k, v in pairs(requiredItems) do
      craftingTotal = craftingTotal + math.max(v - (storageItems[k] and storageItems[k].total or 0), 0)
    end
    dlog.out("recipeSolver", "craftingTotal = " .. craftingTotal)
    --]]
    
    -- Check if the total number of missing items is a new low, and update the result if so.
    if solverState.numMissingItems < solverState.bestNumMissingItems then
      dlog.out("recipeSolver", spacing .. "New best found!")
      solverState.bestNumMissingItems = solverState.numMissingItems
      if solverState.numMissingItems == 0 then
        solverState.resultStatus = "ok"
      else
        solverState.resultStatus = "missing"
      end
      
      -- Move the recipe indices and batch amounts from processed* arrays into the result.
      solverState.resultIndices = solverState.processedIndices
      solverState.processedIndices = nil
      solverState.resultBatches = solverState.processedBatches
      solverState.processedBatches = nil
      
      -- Save the current itemInputs/itemOutputs corresponding to the result.
      -- Items that appear in both are merged and eliminated to prevent intermediate steps from showing up.
      solverState.resultInputs = {}
      for k, v in pairs(solverState.itemInputs) do
        local netInput = v - solverState.itemNAOutputs[k]
        if netInput > 0 then
          solverState.resultInputs[k] = netInput
        end
      end
      solverState.resultOutputs = {}
      for k, v in pairs(solverState.itemNAOutputs) do
        local netOutput = v - solverState.itemInputs[k]
        if netOutput > 0 then
          solverState.resultOutputs[k] = netOutput
        end
      end
      dlog.out("recipeSolver", spacing .. "resultInputs = ", solverState.resultInputs)
      dlog.out("recipeSolver", spacing .. "resultOutputs = ", solverState.resultOutputs)
    end
  else
    return recursiveSolve(recursionDepth + 1, solverState)
  end
end


-- Searches for the sequence of recipes and their amounts needed to craft the
-- target item. This uses a recursive algorithm that walks the dependency graph
-- and tries each applicable recipe for the currently needed item one at a time.
-- Returns a string status ("ok", "missing", "error"), two table arrays
-- containing the sequence of recipe indices and the amount of each recipe to
-- craft, and two more tables that match item inputs to their amounts and item
-- outputs to their amounts.
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

function solver.solveDependencyGraph(recipes, storageItems, itemName, amount)
  dlog.checkArgs(itemName, "string", amount, "number")
  if not recipes[itemName] then
    return "error", "No recipe found for \"" .. itemName .. "\"."
  end
  
  local solverState = SolverState:new(recipes, storageItems)
  solverState:craftPush(itemName, -1, amount)
  
  dlog.out("recipeSolver", "Crafting " .. amount .. " of " .. itemName)
  
  local status, err = pcall(recursiveSolve, 0, solverState)
  if not status then
    dlog.out("recipeSolver", "Error: ", tostring(err))
    return "error", err
  end
  
  dlog.out("recipeSolver", "Done.")
  dlog.out("recipeSolver", "resultStatus, resultIndices, resultBatches, resultInputs, resultOutputs:", solverState.resultStatus, solverState.resultIndices, solverState.resultBatches, solverState.resultInputs, solverState.resultOutputs)
  return solverState.resultStatus, solverState.resultIndices, solverState.resultBatches, solverState.resultInputs, solverState.resultOutputs
end


-- Runs some unit tests for the solveDependencyGraph() algorithm.
function solver.testDependencySolver(loadRecipesFunc, verifyRecipesFunc)
  io.write("Running solveDependencyGraph() tests...\n")
  local stations = {}
  local recipes = {}
  local storageItems
  loadRecipesFunc(stations, recipes, "misc/test_recipes.txt")
  verifyRecipesFunc(stations, recipes)
  
  local function addStorageItem(itemName, label, total, maxSize)
    storageItems[itemName] = {}
    storageItems[itemName].maxSize = maxSize
    storageItems[itemName].label = label
    storageItems[itemName].total = total
  end
  
  local status, recipeIndices, recipeBatches, itemInputs, itemOutputs
  --dlog.out("test", "recipes:", recipes)
  
  -- Craft 16 torches, have nothing.
  storageItems = {}
  status, recipeIndices, recipeBatches, itemInputs, itemOutputs = solver.solveDependencyGraph(recipes, storageItems, "minecraft:torch/0", 16)
  assert(status == "missing")
  assert(dstructs.rawObjectsEqual(recipeIndices, {4, 3, 1}))
  assert(dstructs.rawObjectsEqual(recipeBatches, {1, 1, 4}))
  assert(dstructs.rawObjectsEqual(itemInputs, {["minecraft:log/0"] = 1, ["minecraft:coal/0"] = 4}))
  assert(dstructs.rawObjectsEqual(itemOutputs, {["minecraft:torch/0"] = 16, ["minecraft:planks/0"] = 2}))
  
  -- Craft 16 torches, have 1 log and 4 coal.
  storageItems = {}
  addStorageItem("minecraft:log/0", "Oak Log", 1, 64)
  addStorageItem("minecraft:coal/0", "Coal", 4, 64)
  status, recipeIndices, recipeBatches, itemInputs, itemOutputs = solver.solveDependencyGraph(recipes, storageItems, "minecraft:torch/0", 16)
  assert(status == "ok")
  assert(dstructs.rawObjectsEqual(recipeIndices, {4, 3, 1}))
  assert(dstructs.rawObjectsEqual(recipeBatches, {1, 1, 4}))
  assert(dstructs.rawObjectsEqual(itemInputs, {["minecraft:log/0"] = 1, ["minecraft:coal/0"] = 4}))
  assert(dstructs.rawObjectsEqual(itemOutputs, {["minecraft:torch/0"] = 16, ["minecraft:planks/0"] = 2}))
  
  -- Craft 16 torches, have 1 log, 1 charcoal, and 3 coal.
  storageItems = {}
  addStorageItem("minecraft:log/0", "Oak Log", 1, 64)
  addStorageItem("minecraft:coal/1", "Charcoal", 1, 64)
  addStorageItem("minecraft:coal/0", "Coal", 3, 64)
  status, recipeIndices, recipeBatches, itemInputs, itemOutputs = solver.solveDependencyGraph(recipes, storageItems, "minecraft:torch/0", 16)
  assert(status == "ok")
  assert(dstructs.rawObjectsEqual(recipeIndices, {4, 3, 2, 1}))
  assert(dstructs.rawObjectsEqual(recipeBatches, {1, 1, 1, 3}))
  assert(dstructs.rawObjectsEqual(itemInputs, {["minecraft:log/0"] = 1, ["minecraft:coal/0"] = 3, ["minecraft:coal/1"] = 1}))
  assert(dstructs.rawObjectsEqual(itemOutputs, {["minecraft:torch/0"] = 16, ["minecraft:planks/0"] = 2}))
  
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

return solver

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
