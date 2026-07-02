package editor

import win32 "core:sys/windows"

// Hide the console window that Windows allocates by default for CLI executables.
// Called at startup before InitWindow so there's no visible flash.
// belt-and-suspenders alongside -subsystem:windows in build.bat.
platform_hide_console :: proc() {
	win32.FreeConsole()
}
