@echo off
set OUT=%1
if "%OUT%"=="" set OUT=editor.exe

odin build . -out:"%OUT%" -subsystem:windows

if errorlevel 1 (
    echo Build failed.
    exit /b 1
)

echo Built: %OUT%
