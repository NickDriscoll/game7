@echo off

del .\game7.exe
odin run .\build\build.odin -file -debug -- -l INFO
del .\build.exe