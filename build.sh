#!/bin/sh

mkdir build 2>/dev/null
glslc src/shader.vert -o build/vert.spv
glslc src/shader.frag -o build/frag.spv

ODIN_FLAGS="-debug"
odin build src -out:mesh_viewer $ODIN_FLAGS

