#+build windows
package git

import "core:strings"
import win32 "core:sys/windows"

@(private)
_exec :: proc(root: string, args: []string, allocator := context.allocator) -> (output: string, exit_code: int) {
	// Build: git -C "<root>" <args>. CreateProcessW runs no shell, so no
	// redirections here (a "2>nul" would reach git as an argument); stderr is
	// the parent's (no console: CREATE_NO_WINDOW).
	sb: strings.Builder
	strings.builder_init(&sb, context.temp_allocator)
	strings.write_string(&sb, "git -C ")
	_win_quote(&sb, root)
	for a in args {
		strings.write_byte(&sb, ' ')
		_win_quote(&sb, a)
	}
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

// Quotes one argument for CommandLineToArgvW / the MSVC CRT parser (no cmd.exe
// involved): wrapped in "..."; a " is escaped as \" and backslashes are
// doubled only when they precede a " (or the closing quote). Everything else,
// newlines included, is literal.
@(private)
_win_quote :: proc(sb: ^strings.Builder, s: string) {
	strings.write_byte(sb, '"')
	backslashes := 0
	for i in 0..<len(s) {
		c := s[i]
		switch c {
		case '\\':
			backslashes += 1
		case '"':
			for _ in 0..<backslashes*2 + 1 { strings.write_byte(sb, '\\') }
			backslashes = 0
			strings.write_byte(sb, '"')
		case:
			for _ in 0..<backslashes { strings.write_byte(sb, '\\') }
			backslashes = 0
			strings.write_byte(sb, c)
		}
	}
	for _ in 0..<backslashes*2 { strings.write_byte(sb, '\\') }
	strings.write_byte(sb, '"')
}
