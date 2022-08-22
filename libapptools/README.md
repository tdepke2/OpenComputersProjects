# app.lua

Application framework for multithreaded apps.

Makes it easy to handle multiple threads that must run in parallel and catch errors if any of them fail. A cleanup task stack is also available for running functions right before the application stops.

### API

<!-- SIMPLE-DOC:START (FILE:../libapptools/app.lua) -->
`app:new([mainThread: table]): table`

Creates a new application context for tracking threads and cleanup tasks. If
mainThread is not provided, it defaults to the current execution context (the
thread running this function if any). If this function is run inside a thread
where the system process should be used as the main "thread", a value of
false can be passed to mainThread. Returns the new `app` object.

`app:run(func: function, ...)`

Starts the application with body function func in a protected call. Any
additional provided arguments are passed to func (when called from the main
thread, use `...` to pass all arguments sent to the program). After func
completes or returns an error, `app:exit()` is called to run cleanup and end
the program.

`app:pushCleanupTask(func: function, startArgs: any, endArgs: any)`

Adds a function to the top of the cleanup stack. This function will be popped
off the stack and run when `app:doCleanup()` or `app:exit()` is called or a
thread exits unexpectedly. If startArgs is not a table or nil, the function
will be called immediately with this argument. If endArgs is not a table or
nil, the function is called during cleanup with this argument. If either one
is a table then these are unpacked and passed as the arguments instead.

`app:doCleanup(): number`

Starts the cleanup tasks early, the tasks run in first-in-last-out order.
This function is called automatically and generally doesn't need to be
manually run. Returns the number of tasks that executed.

`app:createThread(name: string, threadProc: function, ...): table`

Creates a new thread executing the function threadProc and registers it to
the app. Any additional provided arguments are passed to threadProc. If
`dlog.logErrorsToOutput` is enabled, threadProc is wrapped inside an
`xpcall()` to capture exceptions with a stack trace. Returns the thread
handle.

`app:registerThread(name: string, t: table): number, string|nil`

Registers an existing thread to the app. Returns the index and name if the
thread has already been registered, or just an index if the thread was added
successfully. Registering a dead thread is considered an error.

`app:unregisterThread(t: table): boolean`

Unregisters a thread from the app. The app will not consider this thread in
`app:waitAnyThreads()` or `app:waitAllThreads()` and the thread will no
longer stop the application if an error occurs. Returns true if thread was
removed, or false if thread is not currently registered.

`app:exit([code: boolean|number])`

Stops the app and ends the program, this kills any active threads and runs
cleanup tasks. This must be explicitly called before exiting the program to
run the cleanup (but it is implicitly called when a registered thread throws
an exception). This is designed to replace calls to `os.exit()` and can be
used inside or outside of a thread.

`app:threadDone(): boolean`

Kills the current thread and reports successful execution. If a thread
becomes dead in any other way then this is considered an error and the app
will stop. A thread can end up dead if the function body ends, `os.exit()` is
called, exception is thrown, or thread is suspended while a call to
`app:waitAnyThreads()` or `app:waitAllThreads()` is running. This function
does nothing if called outside of a thread (or within mainThread). Returns
true if thread was killed (but the thread will end execution before that
anyways).

`app:waitAnyThreads([timeout: number])`

Waits for any of the registered threads to complete or for timeout (seconds)
to pass. A thread completes if it dies or is suspended.

`app:waitAllThreads([timeout: number])`

Waits for all of the registered threads to complete or for timeout (seconds)
to pass. A thread completes if it dies or is suspended.
<!-- SIMPLE-DOC:END -->

### Example usage

See [app_template.lua](app_template.lua) for a comprehensive example that uses this.

# dlog.lua

Diagnostic logger and debugging utilities.

Allows writing logging data to standard output and/or a file for debugging code. Log messages include a subsystem name and any number of values (preferably including some extra text to identify the values). Outputs to a file also prefix the message with a timestamp, much like how syslog output appears on unix systems.

Subsystem names can be any strings like "storage", "command:info", "main():debug", etc. Note that logging output is only shown for enabled subsystems, see `dlog.subsystems()`. Also note that through the magic of `require()`, the active subsystems will persist even after a restart of the program that is being tested.

### API

<!-- SIMPLE-DOC:START (FILE:../libapptools/dlog.lua) -->
**Configuration options:**

`dlog.logErrorsToOutput = true`

Set errors to direct to `dlog.out()` using the `error` subsystem.

`dlog.defineGlobalXassert = true`

Enables the `xassert()` call as a global function. To disable, this must be
set to false here before loading dlog module.

`dlog.maxMessageLength = nil`

Sets a maximum string length on the output from `dlog.out()`. A message that
exceeds this size will be trimmed to fit. Set this value to nil for unlimited
size messages.

`dlog.mode([newMode: string]): string`

Configure mode of operation for dlog. The mode sets defaults for logging and
can disable some dlog features completely to increase performance. If newMode
is provided, the mode is set to this value. The valid modes are:
  * debug (all subsystems on, logging enabled for stdout and `/tmp/messages`)
  * release (default mode, only error logging to stdout)
  * optimize1 (function `dlog.osBlockNewGlobals()` is disabled)
  * optimize2 (function `dlog.checkArgs()` is disabled)
  * optimize3 (functions `dlog.out()` and `dlog.fileOutput()` are disabled)
  * optimize4 (functions `xassert()` and `dlog.xassert()` are disabled)

Each mode includes behavior from the previous modes (optimize4 pretty much
disables everything). The mode is intended to be set once right after dlog is
loaded in the main program, it can be changed at any time though. Returns the
current mode.

Note: when using debug mode with multiple threads, be careful to call this
function in the right place (see warnings in `dlog.fileOutput()`).

`dlog.xassert(v: boolean, ...): ...`<br>
`xassert(v: boolean, ...): ...`

Extended assert, a global replacement for the standard `assert()` function.
This improves performance by delaying the concatenation of strings to form
the message until the message is actually needed. The arguments after v are
optional and can be anything that `tostring()` will convert. Returns v and
all other arguments.
Original idea from: http://lua.space/general/assert-usage-caveat

`dlog.handleError(status: boolean, ...): boolean, ...`

Logs an error message/object if status is false and `dlog.logErrorsToOutput`
is enabled. This is designed to be called with the results of `pcall()` or
`xpcall()` to echo any errors that occurred. Returns the same arguments
passed to the function.

`dlog.checkArgs(val: any, typ: string, ...)`

Re-implementation of the `checkArg()` built-in function. Asserts that the
given arguments match the types they are supposed to. This version fixes
issues the original function had with tables as arguments and allows the
types string to be a comma-separated list.

Example:
`dlog.checkArgs(my_first_arg, "number", my_second_arg, "table,nil")`

`dlog.osBlockNewGlobals(state: boolean)`

Modifies the global environment to stop creation/access to new global
variables. This is to help prevent typos in code from unintentionally
creating new global variables that cause bugs later on (also, globals are
generally a bad practice). In the case that some globals are needed in the
code, they can be safely declared before calling this function. Also see
https://www.lua.org/pil/14.2.html for other options and the following link:
https://stackoverflow.com/questions/35910099/how-special-is-the-global-variable-g

Note: this function uses some extreme fuckery and modifies the system
behavior, use at your own risk!

`dlog.osGetGlobalsList(): table`

Collects a table of all global variables currently defined. Specifically,
this shows the contents of _G and any globals accessible by the running
process. This function is designed for debugging purposes only.

`dlog.fileOutput([filename: string[, mode: string]]): table|nil`

Open/close a file to output logging data to. If filename is provided then
this file is opened (an empty string will close any opened one instead).
Default mode is `a` to append to end of file. Returns the currently open file
(or nil if closed).

Note: keep in mind that Lua will close files automatically as part of garbage
collection. If working with detached threads or processes, make sure your log
file is open in the correct thread/process or it might close suddenly!

`dlog.standardOutput([state: boolean]): boolean`

Set output of logging data to standard output. This can be used in
conjunction with file output. If state is provided, logging to standard
output is enabled/disabled based on the value. Returns true if logging to
standard output is enabled and false otherwise.

`dlog.subsystems([subsystems: table]): table`

Set the subsystems to log from the provided table. The table keys are the
subsystem names (strings, case sensitive) and the values should be true or
false. The special subsystem name `*` can be used to enable all subsystems,
except ones that are explicitly disabled with the value of false. If the
subsystems are provided, these overwrite the old table contents. Returns the
current subsystems table.

`dlog.tableToString(t: table): string`

Serializes a table to a string using a user-facing format. String keys/values
in the table are escaped and enclosed in double quotes. Handles nested tables
and tables with cycles. This is just a helper function for `dlog.out()`.

`dlog.out(subsystem: string, ...)`

Writes a string to active logging outputs (the output is suppressed if the
subsystem is not currently being monitored). To enable monitoring of a
subsystem, use `dlog.subsystems()`. The arguments provided after the
subsystem can be anything that can be passed through `tostring()` with a
couple exceptions:
1. Tables will be printed recursively and show key-value pairs.
2. Functions are evaluated and their return value gets output instead of the
   function pointer. This is handy to wrap some potentially slow debugging
   info in an anonymous function and pass it into `dlog.out()` to prevent
   execution if logging is not enabled.
<!-- SIMPLE-DOC:END -->

# include.lua

Module loader (improved version of `require()` function).

Extends the functionality of `require()` to solve an issue with modules getting cached and not reloading. The `include()` function will reload a module (and all modules that depend on it) if it detects that the file has been modified. Any user modules that need to be loaded should use `include()` instead of `require()` for this to work properly (except for the include module itself). Using `include()` for system libraries is not necessary and may not always work. Take a look at the `package.loaded` warnings here: https://ocdoc.cil.li/api:non-standard-lua-libs

In order for `include()` to work properly, a module must meet these requirements:

  1. It must return no more than one value.
  
  2. Any dependencies that the module needs should also use `include()`, and loading should not be intentionally delayed. Using a lazy-loading system can cause incorrect results during dependency calculation.

Note that the tracking of dependencies and reloading parent modules is done in order to avoid stale references. If a module is simply removed from the cache and loaded again, other bits of code that use it could still reference the old version of the module. It's possible to swap the new module contents into the old location in memory with a bit of magic, but this also adds more restrictions on the modules that can be loaded.

Also "included" here is a source tree dependency solver. It's useful for uploading code to a device via network or other medium. This allows the user to send software with multiple dependencies to robots/drones/microcontrollers that only have a small EEPROM storage.

### API

<!-- SIMPLE-DOC:START (FILE:../libapptools/include.lua) -->
`include.requireWithMemCheck(moduleName: string): table`

Simple wrapper for the `require()` function that suppresses errors about
memory allocation while loading a module. Memory allocation errors can happen
occasionally even if a given system has sufficient RAM. Up to three attempts
are made, then the error is just passed along.

`include.load(moduleName: string): table`

Loads a module just like `require()` does. The difference is that the module
will be removed from the internal cache and loaded again if the file
modification timestamp changes. This helps resolve the annoying problem where
a change is made in a module, the module is included with `require()` in a
source file, and the changes made do not show up during testing (because the
module has been cached). Normally you would have to either reboot the machine
to force the module to reload, or remove the entry in `package.loaded`
manually. The `include.load()` function fixes this problem.

`include.isLoaded(moduleName: string): boolean`

Check if a module is currently loaded (already in cache).

`include.reload(moduleName: string): table`

Forces a module to load/reload, regardless of the file modification
timestamp. Be careful not to use this with system libraries!

`include.unload(moduleName: string)`

Unloads the given module (removes it from the internal cache). Be careful not
to use this with system libraries!

`include.unloadAll()`

Unloads all modules that have been loaded with `include()`, `include.load()`,
`include.reload()`, etc. System libraries will not be touched as long as they
were loaded through other means, like `require()`.

`include.iterateSrcDependencies(sourceFilename: string[,
  modPattern: string]): function`

Gets an iterator to walk through the library dependencies for a source code
file. This is designed to help with sending source code over network
communication (useful for remote code upload to devices that use an EEPROM
storage and don't have enough space to store the files themselves). The
iterator returns source code contents starting from the leaves and working up
to the root of the source tree. This means each file will at most depend on
previous returned files or itself.

The sourceFilename is the path to the source code file, modPattern is a
pattern for the `require()` function equivalent. With the default value for
modPattern, the strings `require("")` and `include("")` will be scanned for
to find nested libraries in source code. Note that the nested libraries will
be searched by package name, not by file path. Also, the include module
itself is blacklisted from getting picked up as a dependency (to prevent some
complications).

For each call to the iterator, returns the module name (string) and contents
of the source file (also string). The module name will be an empty string if
the source file corresponds to the original sourceFilename argument. Iterator
returns nil after last source file has been returned.
<!-- SIMPLE-DOC:END -->

### Example usage

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
