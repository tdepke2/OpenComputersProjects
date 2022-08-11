#!/bin/bash

# Define each source file to create documentation for. The output is sent to the corresponding file at that array index.
declare -a inputs=(
    "../libmnet/mnet_src.lua"
)
declare -a outputs=(
    "../libmnet/README.md"
)

numInputs=${#inputs[@]}

for (( i = 0; i < ${numInputs}; i++ )); do
    lua simple_doc.lua "${inputs[$i]}" "${outputs[$i]}" --insert-start="<!-- SIMPLE-DOC:START (FILE:${inputs[$i]}) -->" --insert-end="<!-- SIMPLE-DOC:END -->"
done
