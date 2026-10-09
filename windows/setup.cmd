@echo off
rem myLinux: the drivers and helpers for a Windows machine (setup.ps1 beside this file), as the administrator or the system
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %*
