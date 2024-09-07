@echo off

del game7.exe
odin build . -debug
.\game7.exe --log-level DEBUG