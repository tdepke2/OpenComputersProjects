#!/bin/bash

# Define each source file to create documentation for. The output is sent to the corresponding file at that array index.
declare -a inputs=(
    "../libmnet/mnet_src.lua"
    "../libmnet/mrpc.lua"
)
declare -a outputs=(
    "../libmnet/README.md"
    "../libmnet/README.md"
)

numInputs=${#inputs[@]}

for (( i = 0; i < ${numInputs}; i++ )); do
    echo "Generating docs for ${inputs[$i]}..."
    lua simple_doc.lua "${inputs[$i]}" "${outputs[$i]}" -B --insert-start="<!-- SIMPLE-DOC:START (FILE:${inputs[$i]}) -->" --insert-end="<!-- SIMPLE-DOC:END -->"
done
