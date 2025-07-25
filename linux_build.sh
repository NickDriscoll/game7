#!/bin/bash

mode=$1
build_log_level=$2

if [ $# -lt 1 ]; then
    mode="release"
fi

rm -f game7
if [ $mode = "debug" ]; then
    odin run ./build/build.odin -file -debug -- -l $build_log_level
else
    odin run ./build/build.odin -file -- -l $build_log_level
fi
rm -f build.bin
