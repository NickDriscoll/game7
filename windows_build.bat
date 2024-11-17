@echo off

set build_log_level=%1

del .\game7.exe
odin run .\build\build.odin -file -debug -- -l %build_log_level%
del .\build.exe