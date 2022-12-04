<!-- MARKDOWN-AUTO-DOCS:START (FILE:src=./tquarry.man) -->
<!-- The below content is automatically added from ./tquarry.man -->
## NAME
  tquarry - digs a specified rectangular area using a robot.

## SYNOPSIS
  `tquarry [OPTION]... LENGTH WIDTH HEIGHT`

## DESCRIPTION
  This program is designed to automate digging out large quarry areas, much like the quarry from BuildCraft. A single robot acts like the drill head and mines layer-by-layer using digging tools that must be provided by the user. The robot returns to a restock point to dump off collected items and replenish energy, tools, and other things before going back to the spot it left off. Multiple robots can be run in parallel to mine the quarry by partitioning the rectangular area for each robot (such that the area each robot mines does not overlap with others).
  
  Before running this program, a robot is needed with these components (use an Electronics Assembler to build the robot):
  
  * Computer Case (at least tier 1)
  
  * Central Processing Unit (at least tier 1, recommended architecture is Lua 5.3)
  
  * Memory (at least 2 of the tier 1 cards)
  
  * EEPROM with Lua BIOS
  
  * Hard Disk Drive (at least tier 1, recommended to have OpenOS and tquarry installed already)
  
  * Graphics Card (at least tier 1)
  
  * Screen (tier 1)
  
  * Keyboard
  
  * Inventory Upgrade (at least 1, each upgrade adds 16 inventory slots)
  
  * Inventory Controller Upgrade (you will need an Upgrade Container (Tier 2) to use this with a tier 1 Computer Case)
  
  Optional components:
  
  * Hover Upgrade (at least tier 1, recommended if the robot could be digging near large caves)
  
  * Angel Upgrade (highly recommended if the robot needs to place any blocks, such as with the `FillFloor` and `FillWall` quarry types or when staircase building is enabled)
  
  * Battery Upgrade (extra energy storage)
  
  * Chunkloader Upgrade (keeps robot's chunk loaded)
  
  * Experience Upgrade (improves robot stats while it digs)
  
  * Generator Upgrade (refuels the robot on the go, see `tquarry.cfg` for details)
  
  * Solar Generator Upgrade
  
  Once the robot is assembled, it should be placed at the quarry "restock point" (also called the home position). The restock point should have a Charger (provided with RF and activated with a redstone signal) and an inventory or two (like a Chest). These blocks can be adjacent to the top or sides of the robot (but not the bottom since the robot digs this direction). With the robot at the restock point, running the program will mine out the rectangular area immediately below the robot defined by LENGTH, WIDTH, and HEIGHT. From the robot's perspective, these dimensions correspond to the number of blocks to the left-side (minus 1), in front of (minus 1), and below the robot.
  
  The first time the program is run, it will create a configuration file in `/etc/tquarry.cfg`. Edit this file to tweak various settings, such as which sides the input/output inventories are located, what items the robot considers as digging tools, whether to build a staircase when finished, etc. The default configuration can be restored by deleting/renaming this file.

## OPTIONS
  `-h`, `--help`  display help message and exit
<!-- MARKDOWN-AUTO-DOCS:END -->
