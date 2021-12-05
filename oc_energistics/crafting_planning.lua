
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
  Runs the dependency graph solver. Finds status (ok, missing, error, etc), recipeIndices, recipeBatches, and requiredItems (maps item name to net amount).
  FIXME we really should be using something like netInputs and netOutputs instead of requiredItems. ########################
  Remove dead tickets and create new ticket for this operation.
  Compute the craftProgress (one-time table sent to interface as confirmation).
  FIXME name craftProgress should change to craftRequirements, use craftProgress for persistent data saved in request that we send to interfaces on diff. ############################
  If we good, send "craft_recipe_confirm" with ticket and craftProgress to interface, and send "stor_recipe_reserve" with ticket and requiredItems.
  If we not good, send "craft_recipe_confirm" with "missing" ticket if missing items, or send "craft_recipe_error" with error message if failed.
Storage
  Does some fucking magic to reserve the items from requiredItems. This should probably be changed to only reserve the inputs.
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
