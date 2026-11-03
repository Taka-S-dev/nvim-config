@echo off
rem Links each skill of skills\ into the personal skill folders of the agents
rem that read them (skills\README.md), so the one copy here is the one they
rem all read. A junction needs no administrator, as a symbolic link would.
rem
rem A link already there is made again, so this is run again after the
rem repository moves. A folder of the same name that is not a link is left
rem as it is, and said so: it may hold a skill of its own.
setlocal enabledelayedexpansion
set SKILLS=%~dp0..\skills
for %%T in ("%USERPROFILE%\.claude\skills" "%USERPROFILE%\.codex\skills" "%USERPROFILE%\.agents\skills") do (
  if not exist "%%~T" mkdir "%%~T"
  for /d %%S in ("%SKILLS%\*") do (
    if exist "%%~fS\SKILL.md" call :link "%%~T\%%~nxS" "%%~fS"
  )
)
exit /b 0

:link
fsutil reparsepoint query "%~1" >nul 2>&1 && rmdir "%~1"
if exist "%~1" (
  echo kept: %~1 is a folder, not a link
  exit /b 0
)
mklink /J "%~1" "%~2" >nul && echo linked: %~1
exit /b 0
