@echo off

del .\game7.exe
odin run .\build\build.odin -file -debug
del .\build.exe