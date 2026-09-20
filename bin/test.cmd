@echo off
rem Runs tests/run.lua in a headless Neovim that loads this config, the same way
rem a normal start does. Meant for after a plugin update. The exit code is the
rem number of failed checks.
rem
rem SHELL is cleared first. Started from Git Bash it is /usr/bin/bash, Neovim
rem takes its 'shell' from it, and the checks would then run under a shell this
rem config is not set up for instead of the cmd.exe a normal start gets.
rem
rem run.lua ends Neovim itself once the checks are done. When the file does not
rem even load, nothing would, and the run would sit there for good; that case
rem exits here with 99.
setlocal
set SHELL=
set NVIM_TEST_FILE=%~dp0..\tests\run.lua
nvim --headless -n -c "lua local ok, err = pcall(dofile, vim.env.NVIM_TEST_FILE) if not ok then io.stdout:write('FAIL  tests/run.lua did not load: ' .. tostring(err) .. string.char(10)) vim.cmd('cquit 99') end"
exit /b %ERRORLEVEL%
