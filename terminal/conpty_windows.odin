package term

// PTY backend for Windows: ConPTY (CreatePseudoConsole, Windows 10 1809+).
// Same contract as pty_posix.odin. Pipes are synchronous, so reads poll
// PeekNamedPipe with a short sleep (lets the reader notice `quit` and child
// exit, which does not break the pipe while conhost lives); writes block on
// WriteFile until ClosePseudoConsole breaks the input pipe.
//
// NOTE: written against the Win32 docs; type-checked with
// `odin check ./terminal -target:windows_amd64` but not run on Windows yet.

import "core:strings"
import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

@(private) HPCON :: distinct rawptr
@(private) PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE :: uintptr(0x00020016)

@(private) STARTUPINFOEXW :: struct {
	StartupInfo:     win.STARTUPINFOW,
	lpAttributeList: rawptr,
}

@(private, default_calling_convention = "system")
foreign kernel32 {
	CreatePseudoConsole :: proc(size: win.COORD, hInput, hOutput: win.HANDLE, dwFlags: win.DWORD, phPC: ^HPCON) -> win.HRESULT ---
	ResizePseudoConsole :: proc(hPC: HPCON, size: win.COORD) -> win.HRESULT ---
	ClosePseudoConsole  :: proc(hPC: HPCON) ---
	InitializeProcThreadAttributeList :: proc(lpAttributeList: rawptr, dwAttributeCount: win.DWORD, dwFlags: win.DWORD, lpSize: ^win.SIZE_T) -> win.BOOL ---
	UpdateProcThreadAttribute :: proc(lpAttributeList: rawptr, dwFlags: win.DWORD, Attribute: uintptr, lpValue: rawptr, cbSize: win.SIZE_T, lpPreviousValue: rawptr, lpReturnSize: ^win.SIZE_T) -> win.BOOL ---
	DeleteProcThreadAttributeList :: proc(lpAttributeList: rawptr) ---
}

Pty :: struct {
	hpc:      HPCON,
	in_write: win.HANDLE, // we write keystrokes here
	out_read: win.HANDLE, // we read the console output here
	process:  win.HANDLE,
	attrs:    []u8,       // proc thread attribute list (must outlive the process start)
	closed_pc: bool,
}

default_shell :: proc(allocator := context.allocator) -> []string {
	out := make([]string, 1, allocator)
	buf: [512]u16
	n := win.GetEnvironmentVariableW(win.L("COMSPEC"), raw_data(buf[:]), len(buf))
	if n > 0 && int(n) < len(buf) {
		s, _ := win.utf16_to_utf8(buf[:n], allocator)
		out[0] = s
	} else {
		out[0] = strings.clone("cmd.exe", allocator)
	}
	return out
}

@(private)
_coord :: proc(rows, cols: int) -> win.COORD {
	return {X = i16(max(cols, 1)), Y = i16(max(rows, 1))}
}

// Quotes one argument for CommandLineToArgvW-style parsing.
@(private)
_quote_arg :: proc(b: ^strings.Builder, a: string) {
	if a != "" && strings.index_any(a, " \t\"") < 0 { strings.write_string(b, a); return }
	strings.write_byte(b, '"')
	slashes := 0
	for ch in transmute([]u8)a {
		switch ch {
		case '\\': slashes += 1
		case '"':
			for _ in 0 ..< slashes * 2 + 1 { strings.write_byte(b, '\\') }
			slashes = 0
			strings.write_byte(b, '"')
			continue
		case:
			for _ in 0 ..< slashes { strings.write_byte(b, '\\') }
			slashes = 0
		}
		if ch != '\\' { strings.write_byte(b, ch) }
	}
	for _ in 0 ..< slashes * 2 { strings.write_byte(b, '\\') }
	strings.write_byte(b, '"')
}

pty_spawn :: proc(p: ^Pty, argv: []string, cwd: string, env: []string, rows, cols: int) -> bool {
	if len(argv) == 0 { return false }
	context.allocator = context.temp_allocator

	// Environment overrides go into our own process env (inherited by the
	// child); spawns only happen on the UI thread. Session markers are removed
	// first (see SESSION_ENV_STRIP).
	for k in SESSION_ENV_STRIP { win.SetEnvironmentVariableW(win.utf8_to_wstring(k), nil) }
	for kv in env {
		i := strings.index_byte(kv, '=')
		if i <= 0 { continue }
		win.SetEnvironmentVariableW(win.utf8_to_wstring(kv[:i]), win.utf8_to_wstring(kv[i + 1:]))
	}

	pty_in_read, pty_out_write: win.HANDLE
	if !win.CreatePipe(&pty_in_read, &p.in_write, nil, 0) { return false }
	if !win.CreatePipe(&p.out_read, &pty_out_write, nil, 0) {
		win.CloseHandle(pty_in_read); win.CloseHandle(p.in_write)
		return false
	}
	hr := CreatePseudoConsole(_coord(rows, cols), pty_in_read, pty_out_write, 0, &p.hpc)
	// ConPTY duplicated its ends; ours must go so EOF is seen later.
	win.CloseHandle(pty_in_read)
	win.CloseHandle(pty_out_write)
	if hr < 0 {
		win.CloseHandle(p.in_write); win.CloseHandle(p.out_read)
		p^ = {}
		return false
	}

	size: win.SIZE_T
	InitializeProcThreadAttributeList(nil, 1, 0, &size)
	p.attrs = make([]u8, int(size), context.temp_allocator)
	ok := InitializeProcThreadAttributeList(raw_data(p.attrs), 1, 0, &size) &&
	      UpdateProcThreadAttribute(raw_data(p.attrs), 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
	                                rawptr(p.hpc), size_of(HPCON), nil, nil)
	if !ok { pty_close(p); return false }

	si: STARTUPINFOEXW
	si.StartupInfo.cb = size_of(STARTUPINFOEXW)
	si.lpAttributeList = raw_data(p.attrs)

	b := strings.builder_make()
	for a, i in argv {
		if i > 0 { strings.write_byte(&b, ' ') }
		_quote_arg(&b, a)
	}
	cmdline := win.utf8_to_wstring(strings.to_string(b))
	cwd_w: win.wstring = win.utf8_to_wstring(cwd) if cwd != "" else nil

	pi: win.PROCESS_INFORMATION
	created := win.CreateProcessW(nil, cmdline, nil, nil, false,
		win.EXTENDED_STARTUPINFO_PRESENT | win.CREATE_UNICODE_ENVIRONMENT,
		nil, cwd_w, &si.StartupInfo, &pi)
	DeleteProcThreadAttributeList(raw_data(p.attrs))
	p.attrs = nil
	if !created { pty_close(p); return false }
	win.CloseHandle(pi.hThread)
	p.process = pi.hProcess
	return true
}

pty_read :: proc(p: ^Pty, buf: []u8, timeout_ms: int) -> (n: int, eof: bool) {
	waited := 0
	for {
		avail: win.DWORD
		if !win.PeekNamedPipe(p.out_read, nil, 0, nil, &avail, nil) { return 0, true }
		if avail > 0 {
			got: win.DWORD
			want := win.DWORD(min(int(avail), len(buf)))
			if !win.ReadFile(p.out_read, raw_data(buf), want, &got, nil) { return 0, true }
			return int(got), false
		}
		if p.process != nil && win.WaitForSingleObject(p.process, 0) == win.WAIT_OBJECT_0 {
			// Child gone: drain what's left, then report EOF.
			if win.PeekNamedPipe(p.out_read, nil, 0, nil, &avail, nil) && avail > 0 { continue }
			return 0, true
		}
		if waited >= timeout_ms { return 0, false }
		win.Sleep(5)
		waited += 5
	}
}

pty_write :: proc(p: ^Pty, data: []u8, quit: ^bool) -> bool {
	rest := data
	for len(rest) > 0 {
		if _atomic_load(quit) { return false }
		w: win.DWORD
		if !win.WriteFile(p.in_write, raw_data(rest), win.DWORD(min(len(rest), 1 << 20)), &w, nil) { return false }
		rest = rest[w:]
	}
	return true
}

pty_resize :: proc(p: ^Pty, rows, cols: int) {
	if p.hpc != nil && !p.closed_pc { ResizePseudoConsole(p.hpc, _coord(rows, cols)) }
}

// Closing the pseudo console ends the client and breaks both pipes, which
// unblocks the reader and writer. The reader must still be running here
// (older Windows builds block until the output is drained).
pty_kill :: proc(p: ^Pty) {
	if p.hpc != nil && !p.closed_pc {
		ClosePseudoConsole(p.hpc)
		p.closed_pc = true
	}
}

pty_child_exited :: proc(p: ^Pty) -> bool {
	return p.process == nil || win.WaitForSingleObject(p.process, 0) == win.WAIT_OBJECT_0
}

pty_close :: proc(p: ^Pty) {
	pty_kill(p)
	if p.process != nil {
		if win.WaitForSingleObject(p.process, 200) != win.WAIT_OBJECT_0 {
			win.TerminateProcess(p.process, 1)
		}
		win.CloseHandle(p.process)
	}
	if p.in_write != nil { win.CloseHandle(p.in_write) }
	if p.out_read != nil { win.CloseHandle(p.out_read) }
	p^ = {}
}
