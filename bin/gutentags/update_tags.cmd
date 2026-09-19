@echo off
rem Stands in for the update_tags.cmd that ships with vim-gutentags.
rem
rem That script writes its progress to CON when it is given no log file, and
rem CON is the console itself, not the pipe Neovim reads: the lines land on top
rem of the editor's screen on every index run and on every save in a project
rem that has a tags file. The only setting that hands it a log file is
rem g:gutentags_trace, which also echoes every step as a message.
rem
rem So the original is called with its log sent to NUL. GUTENTAGS_PLAT_DIR is
rem the directory it lives in, set in lua/plugins/gutentags.lua. A failed run
rem is still reported: gutentags warns on a non-zero exit code.
call "%GUTENTAGS_PLAT_DIR%update_tags.cmd" %* -l NUL
exit /b %ERRORLEVEL%
