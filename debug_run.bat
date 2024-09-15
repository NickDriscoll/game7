@echo off

del game7.exe
odin run .\build\build.odin -file -debug
.\game7.exe