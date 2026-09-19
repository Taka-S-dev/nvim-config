@echo off
rem Runs tests/run.lua in a headless Neovim that loads this config, the same way
rem a normal start does. Meant for after a plugin update. The exit code is the
rem number of failed checks.
rem
rem SHELL is cleared first. Started from Git Bash it is /usr/bin/bash, Neovim
rem takes its 'shell' from it, and the checks would then run under a shell this
rem config is not set up for instead of the cmd.exe a normal start gets.
setlocal
set SHELL=
nvim --headless -n -c "luafile %~dp0..\tests\run.lua"
exit /b %ERRORLEVEL%
