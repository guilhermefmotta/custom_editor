#+build windows
package git

import "core:strings"
import win32 "core:sys/windows"

@(private)
_exec :: proc(root: string, args: []string, allocator := context.allocator) -> (output: string, exit_code: int) {
	// Build: git -C "<root>" <args> 2>nul
	sb: strings.Builder
	strings.builder_init(&sb, context.temp_allocator)
	strings.write_string(&sb, "git -C ")
	strings.write_quoted_string(&sb, root)
	for a in args {
		strings.write_byte(&sb, ' ')
		strings.write_quoted_string(&sb, a)
	}
	strings.write_string(&sb, " 2>nul")
	cmd_wide := win32.utf8_to_wstring(strings.to_string(sb), context.temp_allocator)

	// Create stdout pipe
	sa: win32.SECURITY_ATTRIBUTES
	sa.nLength        = size_of(win32.SECURITY_ATTRIBUTES)
	sa.bInheritHandle = true

	read_pipe, write_pipe: win32.HANDLE
	if !win32.CreatePipe(&read_pipe, &write_pipe, &sa, 0) { return "", 1 }
	win32.SetHandleInformation(read_pipe, win32.HANDLE_FLAG_INHERIT, 0)

	si: win32.STARTUPINFOW
	si.cb         = size_of(win32.STARTUPINFOW)
	si.hStdOutput = write_pipe
	si.hStdError  = win32.GetStdHandle(win32.STD_ERROR_HANDLE)
	si.hStdInput  = win32.GetStdHandle(win32.STD_INPUT_HANDLE)
	si.dwFlags    = win32.STARTF_USESTDHANDLES

	pi: win32.PROCESS_INFORMATION
	if !win32.CreateProcessW(nil, cmd_wide, nil, nil, true, win32.CREATE_NO_WINDOW, nil, nil, &si, &pi) {
		win32.CloseHandle(read_pipe); win32.CloseHandle(write_pipe)
		return "", 1
	}
	win32.CloseHandle(pi.hThread)
	win32.CloseHandle(write_pipe) // close child's end so ReadFile sees EOF

	buf := make([dynamic]u8, allocator)
	tmp: [8192]u8
	for {
		n: win32.DWORD
		ok := win32.ReadFile(read_pipe, raw_data(tmp[:]), size_of(tmp), &n, nil)
		if !ok || n == 0 { break }
		append(&buf, ..tmp[:n])
	}
	win32.CloseHandle(read_pipe)

	win32.WaitForSingleObject(pi.hProcess, win32.INFINITE)
	code: win32.DWORD
	win32.GetExitCodeProcess(pi.hProcess, &code)
	win32.CloseHandle(pi.hProcess)

	return string(buf[:]), int(code)
}
