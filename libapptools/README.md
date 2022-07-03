## app.lua

Application framework for multithreaded apps.

Makes it easy to handle multiple threads that must run in parallel and catch errors if any of them fail. A cleanup task stack is also available for running functions right before the application stops.

## dlog.lua

Diagnostic logger and debugging utilities.

Allows writing logging data to standard output and/or a file for debugging code. Log messages include a subsystem name and any number of values (preferably including some extra text to identify the values). Outputs to a file also prefix the message with a timestamp, much like how syslog output appears on unix systems.

Subsystem names can be any strings like "storage", "command:info", "main():debug", etc. Note that logging output is only shown for enabled subsystems, see `dlog.setSubsystems()` and `dlog.setSubsystem()`. Also note that through the magic of `require()`, the active subsystems will persist even after a restart of the program that is being tested.

## include.lua

Module loader (improved version of `require()` function).

Extends the functionality of `require()` to solve an issue with modules getting cached and not reloading. The `include()` function will reload a module (and all modules that depend on it) if it detects that the file has been modified. Any user modules that need to be loaded should use `include()` instead of `require()` for this to work properly (except for the include module itself). Using `include()` for system libraries is not necessary and may not always work. Take a look at the `package.loaded` warnings here: [https://ocdoc.cil.li/api:non-standard-lua-libs]()

In order for `include()` to work properly, a module must meet these requirements:

  1. It must return no more than one value.
  
  2. Any dependencies that the module needs should also use `include()`, and loading should not be intentionally delayed. Using a lazy-loading system can cause incorrect results during dependency calculation.

Note that the tracking of dependencies and reloading parent modules is done in order to avoid stale references. If a module is simply removed from the cache and loaded again, other bits of code that use it could still reference the old version of the module. It's possible to swap the new module contents into the old location in memory with a bit of magic, but this also adds more restrictions on the modules that can be loaded.

Also "included" here is a source tree dependency solver. It's useful for uploading code to a device via network or other medium. This allows the user to send software with multiple dependencies to robots/drones/microcontrollers that only have a small EEPROM storage.

Example usage:
```lua
-- OS libraries (just use require() for these).
local component = require("component")
local robot = require("robot")
local transposer = component.transposer

-- User libraries (must require() include first).
local include = require("include")
local packer = include("packer")
local wnet = include("wnet")
```
