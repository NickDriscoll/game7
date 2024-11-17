#!/bin/bash

build_log_level=$1

rm -f game7
odin run ./build/build.odin -file -debug -- -l $build_log_level
rm -f build.bin
