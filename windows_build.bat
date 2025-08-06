@echo off

set mode=%1
set build_log_level=%2

del .\game7.exe

if "%mode%"=="debug" (
    odin run .\build\build.odin -file -debug -- -l %build_log_level%
) else (
    odin run .\build\build.odin -file -- -l %build_log_level%
)

del .\build.exe