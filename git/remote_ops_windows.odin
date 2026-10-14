#+build windows
package git

import "core:strings"
import win32 "core:sys/windows"

// CreateProcessW with the parent environment plus `env` (our names replace
// any inherited value), stdout+stderr into one pipe, no stdin, no console.
@(private)
_remote_exec :: proc(root: string, args: []string, env: [][2]string, allocator := context.allocator) -> (output: string, exit_code: int) {
	sb: strings.Builder
	strings.builder_init(&sb, context.temp_allocator)
	strings.write_string(&sb, "git -C ")
	_win_quote(&sb, root)
	for a in args {
		strings.write_byte(&sb, ' ')
		_win_quote(&sb, a)
	}
	cmd_wide := win32.utf8_to_wstring(strings.to_string(sb), context.temp_allocator)

	// Environment block: inherited entries (minus the ones we override) + ours.
	block := make([dynamic]u16, context.temp_allocator)
	if base := win32.GetEnvironmentStringsW(); base != nil {
		p := ([^]u16)(base)
		i := 0
		for p[i] != 0 {
			start := i
			for p[i] != 0 { i += 1 }
			entry := p[start:i]
			name_utf8, _ := win32.utf16_to_utf8(entry, context.temp_allocator)
			keep := true
			for kv in env {
				if len(name_utf8) > len(kv[0]) && name_utf8[len(kv[0])] == '=' &&
				   strings.equal_fold(name_utf8[:len(kv[0])], kv[0]) {
					keep = false
				}
			}
			if keep { append(&block, ..entry); append(&block, 0) }
			i += 1
		}
		win32.FreeEnvironmentStringsW(base)
	}
	for kv in env {
		w := win32.utf8_to_utf16(strings.concatenate({kv[0], "=", kv[1]}, context.temp_allocator), context.temp_allocator)
		append(&block, ..w)
		append(&block, 0)
	}
	append(&block, 0)

	sa: win32.SECURITY_ATTRIBUTES
	sa.nLength        = size_of(win32.SECURITY_ATTRIBUTES)
	sa.bInheritHandle = true

	read_pipe, write_pipe: win32.HANDLE
	if !win32.CreatePipe(&read_pipe, &write_pipe, &sa, 0) { return "", 1 }
	win32.SetHandleInformation(read_pipe, win32.HANDLE_FLAG_INHERIT, 0)

	si: win32.STARTUPINFOW
	si.cb         = size_of(win32.STARTUPINFOW)
	si.hStdOutput = write_pipe
	si.hStdError  = write_pipe
	si.hStdInput  = nil
	si.dwFlags    = win32.STARTF_USESTDHANDLES

	pi: win32.PROCESS_INFORMATION
	flags: win32.DWORD = win32.CREATE_NO_WINDOW | win32.CREATE_UNICODE_ENVIRONMENT
	if !win32.CreateProcessW(nil, cmd_wide, nil, nil, true, flags, raw_data(block), nil, &si, &pi) {
		win32.CloseHandle(read_pipe); win32.CloseHandle(write_pipe)
		return "", 1
	}
	win32.CloseHandle(pi.hThread)
	win32.CloseHandle(write_pipe)

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
