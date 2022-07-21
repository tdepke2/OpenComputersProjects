<!-- MARKDOWN-AUTO-DOCS:START (FILE:src=./simple_preprocess.man) -->
<!-- The below content is automatically added from ./simple_preprocess.man -->
## NAME
  simple_preprocess - minimalistic preprocessor for Lua code.

## SYNOPSIS
  `simple_preprocess [OPTION]... [INPUT-FILE] [OUTPUT-FILE]`

## DESCRIPTION
  This tool allows transforming the contents of a Lua source file to generate new code that is specialized for a certain task. For example, it can be used to build a lookup table for a program before the actual program runs, or compile-out certain bits of code that are only needed for testing. This is done by adding lines called 'directives' in the code that will be executed as a Lua program to build the modified version. Directives start with a `##` or `--##` sequence which must not have any leading characters other than whitespace.
  
  The directives are run in a custom environment that indexes back to _ENV, so the regular environment will be accessible as well as any currently defined global variables. This environment also provides the `spwrite()` function that can be called as a directive. The `spwrite()` function behaves very similar to `print()`, but output is sent to the generated file and no whitespace or tabs are added between arguments. The user can also define local variables to add to the custom environment using the `--local-env` option (see `serialization.serialize()` [here](https://ocdoc.cil.li/api:serialization)).
  
  This code is based on the [Simple Lua Preprocessor](http://lua-users.org/wiki/SimpleLuaPreprocessor). I thought the syntax for the inline directives (using `$()`) could be problematic with some code, so `spwrite()` can be used instead.

## OPTIONS
  Input/output files default to `-` to specify standard input/output respectively.
  
  `-h`, `--help`                display help message and exit
  
  `-v`, `--verbose`             print additional debug information to stdout
  
        `--local-env=STRING`    data to append to local environment when processing
                                input (format should use serialization library)

## EXAMPLES
  TODO:
  examples from http://lua-users.org/wiki/SimpleLuaPreprocessor
  example showing locals passed in, and os.getenv()
<!-- MARKDOWN-AUTO-DOCS:END -->
