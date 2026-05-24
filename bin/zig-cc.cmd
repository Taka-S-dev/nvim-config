@echo off
rem Wrapper that invokes `zig cc` while rewriting clang-style 4-component
rem target triples to zig's 3-component form. tree-sitter CLI passes
rem `x86_64-pc-windows-msvc` etc., which zig rejects with
rem `UnknownOperatingSystem` because it expects `x86_64-windows-msvc`.
setlocal enabledelayedexpansion
set "args="
:loop
if "%~1"=="" goto run
set "a=%~1"
set "a=!a:x86_64-pc-windows-msvc=x86_64-windows-gnu!"
set "a=!a:i686-pc-windows-msvc=x86-windows-gnu!"
set "a=!a:aarch64-pc-windows-msvc=aarch64-windows-gnu!"
set "args=!args! "!a!""
shift
goto loop
:run
zig cc%args%
endlocal & exit /b %ERRORLEVEL%
