# warp_mini

Simplified version of warp running on a microcontroller. This is cheaper to build and puts less load on the server's resources as OpenOS will not be running on the microcontroller. It may be preferable to use warp_mini for destinations that are used infrequently and use warp for primary locations. In exchange for simplicity, warp_mini has some features cut from warp:

* There is no screen to select a destination. Instead, a button can be pressed to warp to a preset destination (however there is a method to manually select a destination).

* The config update method using named items is not implemented. This isn't a big deal since warp_mini doesn't store the list of all destinations, it only cares about the slot id for itself and the preset destination.

<img>

Reference design for warp_mini. It is identical to the design for warp except that all of the OC parts now fit into the space where the transposer was.

Changes to the materials list:

* OC: microcontroller case (tier 1), EEPROM, redstone card (tier 1), CPU (tier 1), 1 memory (tier 1), transposer.

### Setup instructions:

1. As in the warp setup, build the teleporter structure. You can hold off on building the microcontroller until the EEPROM is ready.

2. Get warp_mini installed on a computer that will be used for flashing the EEPROM (run `oppm install warp_mini`).

3. In the install directory (`cd ~/warp_mini`), edit the code with `edit warp_mini_src.lua`. Change any desired settings and update "thisDestinationSlotId" with the slot id that will be assigned to this teleporter.

4. Run `build_image.lua` to pass the code through a preprocessing stage and compress the size to fit onto a 4KB EEPROM. It can now be flashed onto the EEPROM by running `flash warp_mini_eeprom.lua`.

    * Compression is done using a great Lua code compressor called [crunch](https://github.com/OpenPrograms/mpmxyz-Programs). It does use a fair bit of memory, so the computer used to run this may need some tier 3 memory installed.

5. An assembler can now be used to build the microcontroller, place the microcontroller case in first and then the rest of the components can be added.

    * If the EEPROM needs to be updated (for example to change the settings), a new EEPROM can be made (and flashed) and then crafted with the microcontroller to replace the old one.

    * When placed, the light on the front of the microcontroller indicates the running status. Right-click the block to turn it on or off.

6. Just like for warp, a spatial storage cell will need to be named for this destination and placed into the corresponding slot of the ender chest. Make sure to configure the warp teleporters so that this new destination has a name and is included in the list of destinations.

### Usage:

Sending a redstone signal to the microcontroller (by pressing the button) starts a warp to the preset destination. If there is any problem, like the source or destination storage cell is missing or not labeled properly, then a single beep can be heard. The microcontroller shouldn't crash in normal operation, but if it does an analyzer can be used (via shift right-click) to get some error details.

To manually select a destination to warp to, first place the storage cell of the current teleporter into the spatial IO port, then place the storage cell of the desired destination into the slot the other cell was in (the slot id of the current teleporter), and finally press the button. Note that it must be done in this order for things to work.
