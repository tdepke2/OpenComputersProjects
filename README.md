## About This Project

This is a collection of programs for the [OpenComputers mod](https://github.com/MightyPirates/OpenComputers) for Minecraft. OpenComputers provides virtual robots, servers, drones, microcontrollers, and all kinds of hackable hardware, as well as a minimalistic Unix kernel written entirely in Lua. This makes OpenComputers ideal for virtual robotics programming in a simplified voxel-based environment.

All of the programs here use the [OpenPrograms Package Manager (OPPM)](https://ocdoc.cil.li/tutorial:program:oppm) for installation. See the [programs.cfg](programs.cfg) file for specific package names (usually the package name is the same as the directory name in the root of this repository, and includes the prefix "td." for libraries).

## Featured Programs

[oppm_linker](oppm_linker)

> Simplify development workflow with OPPM. Also explains setup of the development environment used for all projects here.

[libapptools](libapptools)

> A few modules to help with multithreading, debugging to log files, automatic require() reloading, and more.

[libmnet](libmnet)

> Networking library with support for reliable/unreliable messaging (like TCP/UDP) and messages of any size. Automatic routing makes the network design very flexible, and the code has a small footprint for embedded devices (fits on EEPROM).

[simple_doc](simple_doc)

> Document all the code! Did I mention it's fully automated too?

[simple_preprocess](simple_preprocess)

> Minimalistic preprocessor for Lua code. Use metaprogramming to let the code write new code!

[libconfig](libconfig)

> Define user-facing configuration structures, then save and load these from a file.

## Development

