
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
