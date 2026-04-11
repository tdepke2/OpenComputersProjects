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

## NAME
  warp - cross-dimensional teleportation network

## SYNOPSIS
  `warp [OPTION]... DESTINATION`

  `rc warpd [enable | disable | start | stop | restart | status]`

## DESCRIPTION
  The warp and warpd programs run on a computer serving as a teleporter node, and provide the player the ability to teleport to any other nodes in the network (including nodes in other dimensions). Teleportation works by storing the player within an Applied Energistics 2 spatial storage cell and shipping the storage cell to its destination via Ender Storage.

### Setup instructions:
  1. Start by building the teleporter structure, the reference design and materials list are on the GitHub page.

  2. Get OpenOS and OPPM (both have a floppy disk) installed. This will require an internet card but you can remove the card after installing everything. If using a computer case (tier 2) then either swap out the graphics card for a tier 1 version or use a computer case (tier 3) for this initial setup.

      * If the install has been set up on a teleporter already, you can skip this and the next step by mirroring the hard drive. Plug in the new drive and run `df` or `mount` to see its mount point in "/mnt/". Copy the files over with `cp -r /mnt/<current>/* /mnt/<new>` using the current and new drive. After that just label the new drive with the `label` command, and you should have an identical copy of the hard drive.

  3. Get warp installed with `oppm register tdepke2/OpenComputersProjects` and `oppm install warp`, then enable the daemon to run after boot with `rc warpd enable` and reboot the computer (it's recommended to press the power button instead of using the reboot command).

  4. You should see an error about the hostname if it's not set. This is used to identify the name of this teleporter, set it with `hostname <name>`. Now edit the config with `edit /etc/warp.cfg` and add an entry in the destinations array with the chosen hostname. For the slot id, pick a slot in the ender chest (or chests if you have multiple) to use for this destination.

      * If warpd doesn't start up or the "/etc/warp.cfg" file hasn't been created, try `rc warpd status` to check what happened.

  5. Get a spatial storage cell and name the item (using an anvil or other method) with the slot id chosen in the last step. The storage cell should be placed in the corresponding slot of the ender chest.

      * When the player runs the `warp` program, they will be stored in this storage cell and it will be swapped with the storage cell at the destination slot id. At the destination, the `warpd` process will be responsible for taking the player out and swapping the storage cells back.

  6. Run `rc warpd restart`, if it works there should be no warnings or errors and `rc warpd status` should indicate it's running. The `warp` command can now be used to teleport to a destination.

      * If using a gas turbine or other generator next to the transposer, fill the "fuelSlot" (defined in the config, default is down slot 1) in the ender chest with fuel cells and take empty cells out of the "emptyFuelSlot" (default is down slot 2). This can be done with a Fluid Canner and robot arm that puts the fuel cells only into the fuel slot and extracts empty cells with a filter. A teleporter at a remote location will keep itself fueled by exchanging empty cells in the generator with full ones. Note that the generator must start with some empty or full fuel cells for this exchange to happen!

      * When someone is arriving at a destination, the teleporter will make a warning noise to alert any nearby players to stand away from the chamber. Triggering the spatial IO port swaps the contents of the chamber with the contents of the storage cell. If someone happened to be standing in the way they would get sucked into the shadow realm and stranded there for eternity (not actually).

## CONFIGURATION

When starting warpd and no "/etc/warp.cfg" config file is found, the default config is created. The config has the destinations list and therefore should be copied to every teleporter when a change is made. This is a real problem if there are a lot of teleporters that now need their config updated if we just add one more destination. To fix this, all of the config files can be updated at once by placing a special named item in any of the ender chests.

Here are the steps to update the config on all teleporters:

  1. Grab any item (such as a block of cobblestone) and an anvil to name it. You will also need a bit of xp to name the item.

  2. Set the name to either `se:<key>=<value>` for a setting or `de:<slot id>="<name>;<requirements>"` for a destination. Note that the destination follows a key/value form instead of how it appears in the config file itself. Names for items are limited, so you can break up a string value across multiple items if needed.

      * As an example, `se:fuelSlot=nil` will disable the fuel slot, freeing up that slot for a destination to use. The items named `de:d3="mars;space suit a` and `de:nd thermal padding"` will set a destination "mars" in slot d3 with the requirements "space suit and thermal padding".

  3. Place the named item(s) in any of the ender chests (if there are multiple items, they must be ordered left to right). Wait the full scan delay (default is 4 seconds) and then you can remove the items. If it worked, the "/etc/warp.cfg" file should have the updated entry.

      * If any teleporters determine that the config update is invalid they will print a message and reject the change. For example, if a destination is removed the teleporter assigned to that destination will not like that (in this case it won't matter since it's the one getting removed).

## NOTES

If you get stuck in the storage dimension (due to standing in the way when another person was arriving at a teleporter, or a critical error occurred while in transit), here are a few options to escape this empty abyss:

  1. Death.

  2. Cheats (such as the `/dimensiontp` command).

  3. A trustworthy friend with at least two brain cells.

  4. Some other form of dimensional teleportation (the ruby slippers from witchery might work).

Anyone stuck in the storage dimension will be in the storage cell labeled with the teleporter that they warped from. Placing the storage cell into the spatial IO port and giving it a redstone signal will get them out.

## SEE ALSO
  [Applied Energistics 2 spatial IO](https://guide.appliedenergistics.org/1.20.1/ae2-mechanics/spatial-io)
