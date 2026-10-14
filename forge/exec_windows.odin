#+build windows
package forge

import "core:os"
import win32 "core:sys/windows"

@(private)
_set_no_inherit :: proc(f: ^os.File) {
	win32.SetHandleInformation(win32.HANDLE(os.fd(f)), win32.HANDLE_FLAG_INHERIT, 0)
}
