@echo off
rem Open a file as a new tab in the running nvim on \\.\pipe\nvim and jump
rem to a specific line. Designed to be invoked from external "open in editor"
rem integrations (browser extensions, file managers, etc.).
rem
rem Usage: open-in-nvim.cmd <file> <line>
rem
rem Requires a primary nvim launched with --listen \\.\pipe\nvim (use the
rem 'nv' PowerShell alias). Uses nvim's built-in --server / --remote-* so
rem there is no Python or nvr dependency.

if "%~1"=="" goto :usage
if "%~2"=="" goto :usage

rem cmd.exe 'if exist' cannot detect named pipes, but PowerShell's
rem Test-Path can. Shell out to check before invoking nvim --server,
rem which would otherwise block indefinitely if no listener exists.
powershell -NoProfile -Command "if (-not (Test-Path '\\.\pipe\nvim')) { exit 1 }"
if errorlevel 1 (
    echo ERROR: No nvim listening on \\.\pipe\nvim.
    echo Start the primary nvim first with the 'nv' PowerShell alias.
    exit /b 1
)

nvim --server \\.\pipe\nvim --remote-tab "%~1" >nul 2>&1
nvim --server \\.\pipe\nvim --remote-send "<C-\><C-N>:%~2<CR>" >nul 2>&1
exit /b 0

:usage
echo Usage: open-in-nvim.cmd ^<file^> ^<line^>
exit /b 1
