@echo off
set OUT=%1
if "%OUT%"=="" set OUT=editor.exe

rem Embedded terminal: vendored libvterm as a static lib (ADR 0004).
rem Needs MSVC on PATH (Developer Command Prompt / vcvars64.bat).
call "%~dp0terminal\libvterm\build.bat"
if errorlevel 1 exit /b 1

odin build . -out:"%OUT%" -subsystem:windows

if errorlevel 1 (
    echo Build failed.
    exit /b 1
)

echo Built: %OUT%
