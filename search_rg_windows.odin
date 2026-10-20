#+build windows
package editor

// ripgrep child process (search_fast.odin) on Windows. Spawned directly
// with CREATE_NO_WINDOW: the editor has no console (FreeConsole), so a
// console program started the default way would flash a console window on
// every search.

import "core:strings"
import win "core:sys/windows"

Rg_Process :: struct {
	process: win.HANDLE,
	out:     win.HANDLE, // read end of rg's stdout
}

rg_spawn :: proc(args: []string) -> (rp: Rg_Process, ok: bool) {
	sb := strings.builder_make(context.temp_allocator)
	for a, i in args {
		if i > 0 { strings.write_byte(&sb, ' ') }
		_rg_win_quote(&sb, a)
	}
	cmd := win.utf8_to_wstring(strings.to_string(sb), context.temp_allocator)

	sa := win.SECURITY_ATTRIBUTES{nLength = size_of(win.SECURITY_ATTRIBUTES), bInheritHandle = true}
	read_pipe, write_pipe: win.HANDLE
	if !win.CreatePipe(&read_pipe, &write_pipe, &sa, 0) { return }
	win.SetHandleInformation(read_pipe, win.HANDLE_FLAG_INHERIT, 0)

	si := win.STARTUPINFOW{
		cb         = size_of(win.STARTUPINFOW),
		dwFlags    = win.STARTF_USESTDHANDLES,
		hStdOutput = write_pipe,
		hStdError  = win.INVALID_HANDLE_VALUE,
		hStdInput  = win.INVALID_HANDLE_VALUE,
	}
	pi: win.PROCESS_INFORMATION
	created := win.CreateProcessW(nil, cmd, nil, nil, true, win.CREATE_NO_WINDOW, nil, nil, &si, &pi)
	win.CloseHandle(write_pipe) // the child holds its copy: EOF when it exits
	if !created { win.CloseHandle(read_pipe); return }
	win.CloseHandle(pi.hThread)
	return Rg_Process{process = pi.hProcess, out = read_pipe}, true
}

// Bytes read into buf; 0 = end of output (or killed).
rg_read :: proc(rp: ^Rg_Process, buf: []u8) -> int {
	n: win.DWORD
	if !win.ReadFile(rp.out, raw_data(buf), win.DWORD(len(buf)), &n, nil) { return 0 }
	return int(n)
}

rg_kill :: proc(rp: ^Rg_Process) { win.TerminateProcess(rp.process, 1) }

// Reaps the process and closes the handles.
rg_close :: proc(rp: ^Rg_Process) {
	win.CloseHandle(rp.out)
	win.WaitForSingleObject(rp.process, win.INFINITE)
	win.CloseHandle(rp.process)
}

// CommandLineToArgvW quoting (same rules as git/process_windows.odin).
@(private="file")
_rg_win_quote :: proc(sb: ^strings.Builder, s: string) {
	strings.write_byte(sb, '"')
	backslashes := 0
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case '\\':
			backslashes += 1
		case '"':
			for _ in 0 ..< backslashes * 2 + 1 { strings.write_byte(sb, '\\') }
			backslashes = 0
			strings.write_byte(sb, '"')
		case:
			for _ in 0 ..< backslashes { strings.write_byte(sb, '\\') }
			backslashes = 0
			strings.write_byte(sb, c)
		}
	}
	for _ in 0 ..< backslashes * 2 { strings.write_byte(sb, '\\') }
	strings.write_byte(sb, '"')
}
