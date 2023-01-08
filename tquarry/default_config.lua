miner = {

  -- Maximum number of attempts for the robot to clear an obstacle until it
  -- considers it is stuck. Having a limit is important so that the robot does not
  -- continue to whittle down the equipped tool's health while whacking a mob with
  -- a massive health pool.
  maxForceAttempts = 50,

  -- The tool health (number of uses remaining) threshold for triggering the robot
  -- to return to restock point. The return threshold is only considered if the
  -- robot is out of spare tools.
  toolHealthReturn = 5,

  -- The tool minimum health. Zero means only one use remains until the tool
  -- breaks (which is good for keeping that precious unbreaking/efficiency/mending
  -- diamond pickaxe for repairs later). If set to negative one, tools will be
  -- used up completely.
  toolHealthMin = 2,

  -- Bias added to the health return/min values when robot is selecting new tools
  -- during resupply (prevents selecting poor quality tools).
  toolHealthBias = 5,

  -- Estimate of the energy units consumed for the robot to move one block. This
  -- is used to call the robot back to the resupply point if the energy required
  -- to get back there is almost more than what the robot has available.
  -- 
  -- Assuming: basic screen and fully lit (1 energy/s), chunkloader active
  -- (1.2 energy/s), runtime cost (0.5 energy/s), a little extra (0.5 energy/s),
  -- robot uses 15 energy to move, and robot pauses 0.4s each movement.
  -- Therefore, N blocks requires N * 15 energy/block + N * 0.4 s/block * 3.2
  -- energy/s or 16.28 energy/block, which we arbitrarily round to 26 for safety.
  energyPerBlock = 26,

  -- Minimum number of empty slots before robot needs to resupply. Setting this to
  -- zero can allow all inventory slots to fill completely, but some items that
  -- fail to stack with others in inventory will get lost.
  emptySlotsMin = 1,

  -- Settings for generator upgrade. These only apply if one or more generators
  -- are installed in the robot.
  generator = {

    -- Energy level for generators to kick in. This can be a number that specifies
    -- the exact energy amount, or a string value with percent sign for a percentage
    -- level.
    enableLevel = "80%",

    -- Number of items to insert into each generator at once. Set this higher if
    -- using fuel with a low burn time.
    batchSize = 2,

    -- Number of ticks to wait in-between each batch before checking if the next one
    -- can be sent. The generator functions just like a furnace burning fuel, so we
    -- use the burn time of coal here.
    batchInterval = 1600,
  },

  -- Item name patterns (supports Lua string patterns, see
  -- https://www.lua.org/manual/5.3/manual.html#6.4.1) for each type of item the
  -- robot keeps stocked. These can be exact items too, like "minecraft:stone/5"
  -- for andesite.
  stockLevelsItems = {
    buildBlock = {
      ".*stone/.*",
      ".*dirt/.*",
    },
    stairBlock = {
      ".*stairs/.*",
    },
    mining = {
      ".*pickaxe.*",
    },
    fuel = {
      "minecraft:coal/.*",
      "minecraft:coal_block/0",
    },
  },

  -- Minimum number of slots the robot must fill for each stock type during
  -- resupply. Zeros are only allowed for consumable stock types that the robot
  -- does not use for construction (like fuel and tools).
  stockLevelsMin = {
    buildBlock = 1,
    stairBlock = 1,
    mining = 0,
    fuel = 0,
  },

  -- Maximum number of slots the robot will fill for each stock type during
  -- resupply. Can be less than the minimum level, and a value of zero will skip
  -- stocking items of that type.
  stockLevelsMax = {
    buildBlock = 0,
    stairBlock = 0,
    mining = 2,
    fuel = 1,
  },
}

-- The side of the robot where items will be taken from (an inventory like a
-- chest is expected to be here). This is from the robot's perspective when at
-- the restock point. Valid sides are: "bottom", "top", "back", "front",
-- "right", and "left".
inventoryInput = "right"

-- Similar to inventoryInput, but for the inventory robot will dump items to.
inventoryOutput = "back"

-- Minimum energy level for quarry to start running or finish a resupply trip.
-- If using only generators on the robot and no charger, set this below the
-- generator.enableLevel value. This can be a number that specifies the exact
-- energy amount, or a string value with percent sign for a percentage level.
energyStartLevel = "99%"

-- Controls mining and building patterns for the quarry, options are: "Basic"
-- simply mines out the rectangular area, "Fast" mines three layers at a time
-- but may not remove all liquids, "FillFloor" ensures a solid floor below each
-- working layer (for when a flight upgrade is not in use), "FillWall" ensures a
-- solid wall at the borders of the rectangular area (prevents liquids from
-- spilling into quarry).
quarryType = "Fast"

-- When set to true, the robot will build a staircase once the quarry is
-- finished (stairs go clockwise around edges of quarry to the top and end at
-- the restock point). This adjusts miner.stockLevelsMax.stairBlock to stock
-- stairs if needed.
buildStaircase = false
