## About This Project

This is a collection of programs for the [OpenComputers mod](https://github.com/MightyPirates/OpenComputers) for Minecraft. OpenComputers provides virtual robots, servers, drones, microcontrollers, and all kinds of hackable hardware, as well as a minimalistic Unix kernel written entirely in Lua. This makes OpenComputers ideal for virtual robotics programming in a simplified voxel-based environment.

All of the programs here use the [OpenPrograms Package Manager (OPPM)](https://ocdoc.cil.li/tutorial:program:oppm) for installation. Try the following steps to get this set up on a new device (computer, server, robot, etc):

1. Install OpenOS and OPPM (floppy disks are available for both). Note that OPPM requires an internet card to function.
2. Run `oppm register tdepke2/OpenComputersProjects`
3. Install any of the packages here with `oppm install <package>`

See the [programs.cfg](programs.cfg) file for specific package names (usually the package name is the same as the directory name in the root of this repository, and includes the prefix "td." for libraries).

## Featured Programs

### Libraries

[td.libapptools](libapptools)

> A few modules to help with multithreading, debugging to log files, automatic require() reloading, and more.

[td.libconfig](libconfig)

> Define user-facing configuration structures, then save and load these from a file.

[td.libdstructs](libdstructs)

> Various data structures like CharArray, ByteArray, Deque, etc.

[td.libembedded](libembedded)

> Utilities for embedded devices (like drones and microcontrollers).

[td.libitem](libitem)

> Simple item hashing and inventory iterators.

[td.libminer](libminer)

> Provides navigation, safe wrappers for robot actions, inventory arrangement, etc.

[td.libmnet](libmnet)

> Networking library with support for reliable/unreliable messaging (like TCP/UDP) and messages of any size. Automatic routing makes the network design very flexible, and the code has a small footprint for embedded devices (fits on EEPROM).

### Robotics

[tquarry](tquarry)

> Digs a specified rectangular area using a robot. The robot is smart enough to deal with obstacles, broken tools, low energy, refueling generators, etc.

### Tools

[oppm_linker](oppm_linker)

> Simplify program development with OPPM by symlinking files in a Git repository to their install location.

[simple_doc](simple_doc)

> Document all the code! Did I mention it's fully automated too?

[simple_preprocess](simple_preprocess)

> Minimalistic preprocessor for Lua code. Use metaprogramming to let the code write new code!

[xprint](xprint)

> Serialize Lua data (tables/numbers/etc) to human-readable strings. Includes a hexdump utility.

### Unmaintained and/or Unfinished

[td.libmatrix](libmatrix)

> Provides vector and matrix objects for mathematic operations. Currently the vector type is finished, but matrix type is not.

[td.libwnet](libwnet)

> A very simple networking module with RPC-like functionality. This is the precursor to td.libmnet.

[minibuilder](minibuilder)

> An automated solution for crafting with a miniaturization field projector (from Compact Machines mod).

[oc_energistics](oc_energistics)

> Modular factory automation system. This is essentially a complete implementation of a matter-energy system (like Applied Energistics 2 or Refined Storage mods), using only hardware provided in OpenComputers. This is the most complex project in this repo, and it may never be finished.

[ocvnc](ocvnc)

> Virtual network computing client/server. Can be used to remotely connect to a system to provide keyboard input and view the screen.

[tgol](tgol)

> Just another implementation of Conway's Game of Life.

[tminer](tminer)

> Robotic miner that uses a geolyzer to analyze locations of ore veins. The robot plans an efficient path to mine all of the ore and minimize digging up other blocks.

## Development

Most of these programs have been designed around Lua 5.3 but a few are also compatible with Lua 5.2. OpenComputers supports both architectures in the CPU item, but defaults to different ones depending on the mod version (shift-right-click the CPU to cycle the architecture).

Programs have been tested with `OpenComputers-MC1.12.2-1.7.5.192`, but newer versions of the mod should be compatible.

Notes related to pending development tasks, bugs, and future program ideas are on the [wiki](https://github.com/tdepke2/OpenComputersProjects/wiki).
