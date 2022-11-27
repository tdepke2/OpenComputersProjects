<!-- MARKDOWN-AUTO-DOCS:START (FILE:src=./simple_preprocess.man) -->
<!-- The below content is automatically added from ./simple_preprocess.man -->
## NAME
  simple_preprocess - minimalistic preprocessor for Lua code.

## SYNOPSIS
  `simple_preprocess [OPTION]... [INPUT-FILE] [OUTPUT-FILE]`

## DESCRIPTION
  This tool allows transforming the contents of a Lua source file to generate new code that is specialized for a certain task. For example, it can be used to build a lookup table for a program before the actual program runs, or compile-out certain bits of code that are only needed for testing. This is done by adding lines called 'directives' in the code that will be executed as a Lua program to build the modified version. Directives start with a `##` or `--##` sequence which must not have any leading characters other than whitespace.
  
  The directives are run in a custom environment that indexes back to `_ENV`, so the regular environment will be accessible as well as any currently defined global variables. This environment also provides the `spwrite()` function that can be called as a directive. The `spwrite()` function behaves very similar to `print()`, but output is sent to the generated file and no whitespace or tabs are added between arguments. The user can also define local variables to add to the custom environment using the `--local-env` option (see `serialization.serialize()` [here](https://ocdoc.cil.li/api:serialization)).
  
  This code is based on the [Simple Lua Preprocessor](http://lua-users.org/wiki/SimpleLuaPreprocessor). The syntax for the inline directives (using `$()`) could be problematic with some code, so `spwrite()` can be used as an alternative.

## OPTIONS
  Input/output files default to `-` to specify standard input/output respectively.
  
  `-h`, `--help`        display help message and exit
  
  `-v`, `--verbose`     print additional debug information to stdout
  
  `--local-env=STRING`  data to append to local environment when processing input (format should use serialization library)

## EXAMPLES
  `simple_preprocess test.lua test.out.lua --local-env={DEBUG=true}`
  
  Input file `test.lua`:
```lua
-- Access a user-defined variable from --local-env.
##if DEBUG then
local function log(fmt, ...) print(string.format(fmt, ...)) end
##else
local function log() end
##end

-- Access a variable in the global environment.
##if math.type then
##spwrite("print(\"math.type is available, we are probably running Lua 5.3+\")")
##end

-- Alternative syntax using '--##'.
--##spwrite("log(\"%s\", \"sample text\")")

-- Build a lookup table.
local lut = {
##for i = 0, 10 do
  ##spwrite("[", i, "] = ", math.sin(math.pi * i / 10), ",")
##end
}

-- The OS environment variables can also be accessed. Also, spwrite() can be used to generate commented code.
##spwrite("-- Current PATH = ", os.getenv().PATH)
```
  
  
  Generated file `test.out.lua`:
```lua
-- Access a user-defined variable from --local-env.
local function log(fmt, ...) print(string.format(fmt, ...)) end

-- Access a variable in the global environment.
print("math.type is available, we are probably running Lua 5.3+")

-- Alternative syntax using '--##'.
log("%s", "sample text")

-- Build a lookup table.
local lut = {
  [0] = 0.0,
  [1] = 0.30901699437495,
  [2] = 0.58778525229247,
  [3] = 0.80901699437495,
  [4] = 0.95105651629515,
  [5] = 1.0,
  [6] = 0.95105651629515,
  [7] = 0.80901699437495,
  [8] = 0.58778525229247,
  [9] = 0.30901699437495,
  [10] = 1.2246467991474e-16,
}

-- The OS environment variables can also be accessed. Also, spwrite() can be used to generate commented code.
-- Current PATH = /bin:/usr/bin:/home/bin:.
```
<!-- MARKDOWN-AUTO-DOCS:END -->
