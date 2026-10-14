@echo off
rem Builds the vendored libvterm (0.3.3, MIT - see LICENSE) into
rem terminal\libvterm\lib\vterm.lib with MSVC (needs cl.exe/lib.exe on PATH:
rem run from a "Developer Command Prompt" or after vcvars64.bat; CI uses
rem ilammy/msvc-dev-cmd). terminal\vterm.odin links it statically.
setlocal
set HERE=%~dp0
if not exist "%HERE%lib\obj" mkdir "%HERE%lib\obj"
pushd "%HERE%lib\obj"
cl /nologo /c /O2 /MT /W0 /std:c11 /I"%HERE%include" "%HERE%src\*.c"
if errorlevel 1 ( popd & echo libvterm build failed. & exit /b 1 )
lib /nologo /OUT:"%HERE%lib\vterm.lib" *.obj
if errorlevel 1 ( popd & echo libvterm lib failed. & exit /b 1 )
popd
rmdir /s /q "%HERE%lib\obj"
echo Built: %HERE%lib\vterm.lib
endlocal
