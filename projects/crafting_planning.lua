
gui appearance:

-- pending craft
<item name>
- R <amount required>
<item name>
- R <amount required> M <amount missing (cannot start crafting)>
<item name>
- C <amount to craft>
<item name>
- R <amount required> C <amount to craft>

-- active craft
-- note, AE2 does a stored/crafting/scheduled kind of thing. The "scheduled" part is merged with "crafting" in this system.
<item name>
- S <amount stored>
<item name>
- C <amount to craft>
<item name>
- S <amount stored> C <amount to craft>


crafting process:
Interface
  User selects item and amount and sends a "craft_check_recipe" packet to crafting.
Crafting
  Runs the dependency graph solver. Finds status (ok, missing, error, etc), recipeIndices, recipeBatches, itemInputs, and itemOutputs.
  Remove dead tickets and create new ticket for this operation.
  Compute the craftProgress (one-time table sent to interface as confirmation).
  FIXME name craftProgress should change to craftRequirements, use craftProgress for persistent data saved in request that we send to interfaces on diff. ############################
  If we good, send "craft_recipe_confirm" with ticket and craftProgress to interface, and send "stor_recipe_reserve" with ticket and itemInputs.
  If we not good, send "craft_recipe_confirm" with "missing" ticket if missing items, or send "craft_recipe_error" with error message if failed.
Storage
  Does some fucking magic to reserve the items from itemInputs.
Interface
  Display results of craftProgress to user. If submitted before request times out, send "craft_recipe_start" with ticket to crafting.
Crafting
  Forward the start request to storage with "stor_recipe_start".
  Move ticket to active, and add some extra data to it (like storedItems).
  Crafting thread goes brrr.
Crafting Thread
  Repeat following for each active request:
    If waiting on storage extract request, then pause until it's done.
    For each recipe in the crafting sequence:
      Update recipeStatus if dependencies changed, and calc amount that can currently be crafted.
      If that amount is nonzero, attempt to reserve a drone inventory for the task.
      If reserved, create a taskID and craftingTask (which we send to robots in "robot_prepare_craft") and a cachedCraftingTask (which we store internally).
      Also send "stor_drone_extract" with extractList to storage. This adds the items to the reserved inventory.
Robot
  Saves state of craftingTask and gets in position, waiting for confirmation to continue.
Storage
  Extracts items to target drone inventory, and verifies that the items were reserved.
  Responds with a "stor_drone_item_diff" back to crafting that details the changed inventory contents.
Crafting Thread
  Once extract finished, verify that it succeeded and send "robot_start_craft" to robots.
Robot
  Sucks up items from drone inventory and crafts requested item. Outputs back to the same inventory.
  Sends "robot_finished_craft" back to crafting when done.
Crafting Thread
  Once robot finished crafting, add results to storedItems and delete the task.
  Return to processing of more active requests.



algorithm pseudo code:
--------------------------------------------------------------------------------
-- what items are needed thus far, kept between branches.
requiredItems = {}

-- crafting steps required to make the target item.
craftNames = {itemName}
craftIndices = {}
craftAmounts = {amount}

-- similar to above, but order is reversed, items of the same type are grouped together, and counts are the multipliers instead of item amounts. this is the solution.
sequenceIndices = {}
sequenceBatches = {}

function recursiveSolve(index)
  for each recipeIndex that makes craftNames[index] do
    addRecipe(index, recipeIndex, false)
  end
end

-- always set allowPartial true, and set false if it failed and multiple recipes or if disabled further up (cuz we need a failed solution to report)
function addRecipe(index, recipeIndex, allowPartial)
  if multiple recipes then
    backup requiredItems, etc.
  end
  
  craftIndices[index] = recipeIndex    -- mark the recipe down
  
  mult = ceil(craftAmounts[index] / recipeAmount)
  
  for each input in recipes[recipeIndex] do
    addAmount = mult * inputAmount
    availableAmount = max(storage[input].total - requiredItems[input], 0)
    
    if addAmount > availableAmount and recipe for input is known then
      add input to end of craftNames
      add addAmount - availableAmount to end of craftAmounts
    end
    
    requiredItems[input] += addAmount
  end
  
  for each output in recipes[recipeIndex] do
    requiredItems[output] += -mult * outputAmount
  end
  
  if multiple recipes then
    restore requiredItems, etc.
  end
end

recursiveSolve(1)
--------------------------------------------------------------------------------

example: craft 16 torch, nothing available
requiredItems = {}
craftNames =    {torch}
craftIndices =  {}
craftAmounts =  {   16}

example: craft 16 torch, 3 coal available

example: craft 16 torch, 4 coal available

example: craft 16 torch, 3 coal and 1 charcoal available
requiredItems = {}
craftNames =    {torch}
craftIndices =  {}
craftAmounts =  {   16}
  addRecipe()
  mult = 3 (coal limiting)
  requiredItems = {}
  craftNames =    {torch, stick}
  craftIndices =  {    a}
  craftAmounts =  {   12,     3}

example: craft 10 iron_alloy, 2 iron_alloy available
requiredItems = {}
craftNames =    {iron_alloy}
craftIndices =  {}
craftAmounts =  {        10}
  addRecipe()
  mult = 4
  requiredItems = {iron_alloy=8-12, slag=4}
  craftNames =    {iron_alloy, iron_alloy}
  craftIndices =  {         a}
  craftAmounts =  {        10,          6}
    addRecipe()
    mult = 2
    requiredItems = {iron_alloy=-4+4-6, slag=6}
    craftNames =    {iron_alloy, iron_alloy}
    craftIndices =  {         a,          a}
    craftAmounts =  {        10,          6}
not good, slag amount is wrong

example: craft 10 iron_alloy, 2 iron_alloy available (with special case for recursive recipes)
requiredItems = {}
craftNames =    {iron_alloy}
craftIndices =  {}
craftAmounts =  {        10}
  addRecipe()
  detected recursion
  mult = 10
  requiredItems = {iron_alloy=20-30 or 2?, slag=10}
  craftNames =    {iron_alloy, iron_alloy}
  craftIndices =  {         a}
  craftAmounts =  {        10,         20}
this most likely breaks if we try to craft more iron_alloy in another step (maybe that's ok tho)


--------------------------------------------------------------------------------

function solveDependencyGraph(itemName, amount)
  itemInputs = {}
  itemOutputs = {}
  craftNames = {itemName}
  craftIndices = {}
  craftAmounts = {amount}
  
  function recursiveSolve(index)
    for each recipeIndex in recipes[craftNames[index]] do
      craftIndices[index] = recipeIndex
      
      if multiple recipes then
        backup itemInputs, itemOutputs, craftNames, etc.
      end
      
      mult = number of items we need to craft over the number of items we get from the recipe (rounded up)
      
      for each inputName in recipes[recipeIndex].inp do
        addAmount = mult * inputAmount
        availableAmount = math.max(storageItems[inputName].total - itemInputs[inputName], 0)
        
        if addAmount > availableAmount then
          if recipe known for inputName then
            add inputName to end of craftNames
            add (addAmount - availableAmount) to end of craftAmounts
          else
            add to missing items
          end
        end
        
        itemInputs[inputName] += addAmount
      end
      
      for each outputName in recipes[recipeIndex].out do
        itemOutputs[outputName] += mult * outputAmount
      end
      
      if craftNames[index + 1] is nil then
        found a solution
        
        -- Build the result of recipe indices and batch amounts from craftNames/craftIndices/craftAmounts.
        -- We iterate the craft stuff in reverse and push to the result array, if another instance of the same recipe pops up then we combine it with the previous one.
        resultIndices = {}
        resultBatches = {}
        ...
        
        -- Save the current itemInputs/itemOutputs corresponding to the result.
        resultInputs = {}
        for k, v in pairs(itemInputs) do
          local netInput = v - (itemOutputs[k] or 0)
          if netInput > 0 then
            resultInputs[k] = netInput
          end
        end
        resultOutputs = {}
        for k, v in pairs(itemOutputs) do
          local netOutput = v - (itemInputs[k] or 0)
          if netOutput > 0 then
            resultOutputs[k] = netOutput
          end
        end
      else
        recursiveSolve(index + 1)
      end
      
      if multiple recipes then
        restore state of itemInputs, itemOutputs, craftNames, etc.
      end
    end
  end
  
  recursiveSolve(1)
end

-- downscaling (mixing) problem:
-- when multiple recipes, try each independently first (no mix)
-- next, scan through top-level of all the multiple recipes and downscale each amount to the limiting raw resource (non-craftable material)
--   this step may not downscale anything if all recipes have craftable materials
-- if all recipes downscaled and total less than amount needed, break early (cannot be crafted)
-- if any were downscaled, then iterate only those and add them up until we reach total (or split even across the remainder). attempt to craft with this combination.
-- if none downscaled, or last attempt failed, then split even (we need to step through downscaled first, and update the split as we go). attempt to craft with this combination.

-- some tests for this:
-- extra recipe for charcoal: 1 log = 1 charcoal
-- craft 16 torches, have 4 log and 1 coal (we can make them)
-- craft 16 torches, have 2 log and 3 coal (we can make them)
-- craft 16 torches, have 5 log (we can make them)
--   does the order the torch recipes are defined effect outcome? it shouldn't

-- recursive recipes problem:
-- idk I don't want to think about it. might be as simple as just adding outputs to the input?
-- probably need to downscale too

recipes:
a) 1 coal + 1 stick = 4 torch
b) 1 charcoal + 1 stick = 4 torch
c) 2 planks = 4 stick
d) 1 log = 4 planks
e) 2 iron_alloy + 1 slag = 3 iron_alloy
f) 3 copper + 1 silver + 1 bucket_redstone = 4 signalum + 1 bucket
g) 10 redstone + 1 bucket = 1 bucket_redstone
h) 1 carrot + 1 juicer = 1 carrot_juice + 1 juicer
i) 1 egg + 1 seeds = 1 chicken + 1 nest
j) 1 nest = 1 egg

example: craft 16 torch
have: 1 log, 4 coal
steps:
1 log -> 4 planks
2 planks -> 4 stick
4 stick + 4 coal -> 16 torch
solution: 1 log + 4 coal -> 2 planks + 16 torch
itemInputs =    {}
itemOutputs =   {}
craftNames =    {torch}
craftIndices =  {}
craftAmounts =  {   16}
  multiple recipes for torch, make a backup
  mult = 4
    coal: addAmount = 4, availableAmount = 4
    stick: addAmount = 4, availableAmount = 0
  itemInputs =    {coal=4, stick=4}
  itemOutputs =   {torch=16}
  craftNames =    {torch, stick}
  craftIndices =  {    a}
  craftAmounts =  {   16,     4}
    single recipe for stick
    mult = 1
      planks: addAmount = 2, availableAmount = 0
    itemInputs =    {coal=4, stick=4, planks=2}
    itemOutputs =   {torch=16, stick=4}
    craftNames =    {torch, stick, planks}
    craftIndices =  {    a,     c}
    craftAmounts =  {   16,     4,      2}
      single recipe for planks
      mult = 1
        log: addAmount = 1, availableAmount = 1
      itemInputs =    {coal=4, stick=4, planks=2, log=1}
      itemOutputs =   {torch=16, stick=4, planks=4}
      craftNames =    {torch, stick, planks}
      craftIndices =  {    a,     c,      d}
      craftAmounts =  {   16,     4,      2}


example: craft 16 torch
have: 1 log, 1 charcoal, 3 coal
steps:
1 log -> 4 planks
2 planks -> 4 stick
1 stick + 1 charcoal -> 4 torch
3 stick + 3 coal -> 12 torch
solution: 1 log + 1 charcoal + 3 coal -> 2 planks + 16 torch


example: craft 1 iron_alloy
have: 2 iron_alloy, 64 slag
steps:
2 iron_alloy + 1 slag -> 3 iron_alloy
solution: 2 iron_alloy + 1 slag -> 3 iron_alloy


example: craft 10 iron_alloy
have: 2 iron_alloy, 64 slag
steps:
2 iron_alloy + 1 slag -> 3 iron_alloy
2 iron_alloy + 1 slag -> 3 iron_alloy
4 iron_alloy + 2 slag -> 6 iron_alloy
6 iron_alloy + 3 slag -> 9 iron_alloy
6 iron_alloy + 3 slag -> 9 iron_alloy
solution: 2 iron_alloy + 10 slag -> 10 iron_alloy


example: craft 10 iron_alloy
have: 8 iron_alloy, 64 slag
steps:
8 iron_alloy + 4 slag -> 12 iron_alloy
12 iron_alloy + 6 slag -> 18 iron_alloy
solution: 8 iron_alloy + 10 slag -> 10 iron_alloy


example: craft 1 chicken
have: 1 seeds
steps:
solution: not possible
