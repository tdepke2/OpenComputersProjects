# warp

Teleport anywhere, using Applied Energistics 2 and Ender Storage.

<demo>

In GregTech: New Horizons, this is currently obtainable at the IV stage, but the teleporter network should work in other modpacks that have AE2 and some form of item teleportation that behaves like ender chests.

The main points of this system are:

* Multiplayer-friendly, multiple people can be in-flight to different destinations at the same time.

* Scalable with respect to the total destinations (supports up to 27 * 4 = 108 destinations in a network).

* Self-powering using a generator and fuel provided from the ender chest, but this is optional.

* Easy to configure and safe to use (if something goes wrong and a player gets stuck in a storage cell, the program will attempt to rescue them).

<bread teleportation>

Other things can be teleported too, like blocks, entities, and bread (warning: bread may contain tumors after teleporting). Tile entities can be teleported as well but this may be a bad idea, especially if the tile entity is a GregTech machine.

<reference design pics, include signs for the d,u,b,l sides>

Reference design for a teleporter with a 2 x 2 x 2 chamber. The design can be adjusted as needed, for example by using a larger or smaller chamber size. Just make sure that all teleporters have the same chamber size and the x and z dimensions of the chamber are the same (otherwise the teleporters will only work in specific orientations). The placement of the spatial IO port is important as it needs a redstone signal (sent from the back of the computer), and its position defines the "right" side of the transposer. From the transposer's perspective the down, up, back, and left sides will be scanned for ender chests and generators.

Materials list for the reference design:

* AE2: spatial IO port, spatial storage cell 2^3, 12 spatial casing, energy acceptor, energy cell, 4 cable

* OC: computer case (tier 2), graphics card (tier 2), redstone card (tier 1), CPU (tier 1), 2 RAM (tier 1), hard drive (tier 1), 2 screen (tier 2), keyboard, transposer, cable

* Other: turbo gas turbine, ender chest (with fuel in it, such as benzene cells)

It is recommended to build the teleporter within a single chunk as it will need to be chunkloaded in order to function. As with most GregTech machines, don't forget to cover the gas turbine from rain (I have forgotten to do this at least twice now). If you build the teleporter on another planet then make sure to protect it from meteors.

See the man page below for the full details:

---

<!-- MARKDOWN-AUTO-DOCS:START (FILE:src=./warp.man) -->
<!-- MARKDOWN-AUTO-DOCS:END -->
