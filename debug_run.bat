@echo off

del -Confirm .\data\shaders\*
slangc -stage vertex -entry vertex_main -o .\data\shaders\test.vert.spv .\shaders\test.slang
slangc -stage fragment -entry fragment_main -o .\data\shaders\test.frag.spv .\shaders\test.slang
del game7.exe
odin build . -debug
.\game7.exe