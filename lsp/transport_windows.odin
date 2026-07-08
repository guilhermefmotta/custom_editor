#+build windows
package lsp

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import win32 "core:sys/windows"

// ---------------------------------------------------------------------------
// Server process — Windows
// ---------------------------------------------------------------------------

Server_Process :: struct {
	proc_handle: win32.HANDLE,
	stdin_fd:    win32.HANDLE,
	stdout_fd:   win32.HANDLE,
	running:     bool,
}

spawn_server :: proc(cmd: []string) -> (proc_: Server_Process, ok: bool) {
	if len(cmd) == 0 { log_writef("ERR", "spawn_server: empty command"); return {}, false }

	// CreateProcess cannot directly launch a .bat/.cmd file (that's a cmd.exe
	// built-in interpreter feature, not something the OS loader understands —
	// it just fails with "not a valid Win32 application"). Our own installers
	// generate exactly this kind of wrapper for servers that need one (e.g.
	// jdtls, which needs a computed classpath jar + -data dir), so route
	// through cmd.exe /c whenever the resolved binary is a batch script.
	first_lower := strings.to_lower(cmd[0], context.temp_allocator)
	needs_shell := strings.has_suffix(first_lower, ".bat") || strings.has_suffix(first_lower, ".cmd")

	// Build quoted command line — every arg individually quoted (not just
	// ones containing spaces) since that's also required for the cmd.exe /c
	// "..." wrapping trick to parse correctly when a path has spaces in it
	// (e.g. "C:\Users\Jane Doe\AppData\...").
	sb: strings.Builder
	strings.builder_init(&sb, context.temp_allocator)
	if needs_shell { strings.write_string(&sb, `cmd.exe /c "`) }
	for i := 0; i < len(cmd); i += 1 {
		if i > 0 { strings.write_byte(&sb, ' ') }
		strings.write_byte(&sb, '"')
		strings.write_string(&sb, cmd[i])
		strings.write_byte(&sb, '"')
	}
	if needs_shell { strings.write_byte(&sb, '"') }
	cmd_wide := win32.utf8_to_wstring(strings.to_string(sb), context.temp_allocator)

	// Inheritable security attributes for pipe handles
	sa: win32.SECURITY_ATTRIBUTES
	sa.nLength              = size_of(win32.SECURITY_ATTRIBUTES)
	sa.bInheritHandle       = true
	sa.lpSecurityDescriptor = nil

	stdin_read, stdin_write:   win32.HANDLE
	stdout_read, stdout_write: win32.HANDLE

	if !win32.CreatePipe(&stdin_read, &stdin_write, &sa, 0) {
		log_writef("ERR", "CreatePipe(stdin) failed")
		return {}, false
	}
	if !win32.CreatePipe(&stdout_read, &stdout_write, &sa, 0) {
		log_writef("ERR", "CreatePipe(stdout) failed")
		win32.CloseHandle(stdin_read); win32.CloseHandle(stdin_write)
		return {}, false
	}

	// Parent-side handles must NOT be inherited by the child
	win32.SetHandleInformation(stdin_write, win32.HANDLE_FLAG_INHERIT, 0)
	win32.SetHandleInformation(stdout_read, win32.HANDLE_FLAG_INHERIT, 0)

	si: win32.STARTUPINFOW
	si.cb         = size_of(win32.STARTUPINFOW)
	si.hStdInput  = stdin_read
	si.hStdOutput = stdout_write
	si.hStdError  = win32.GetStdHandle(win32.STD_ERROR_HANDLE)
	si.dwFlags    = win32.STARTF_USESTDHANDLES

	pi: win32.PROCESS_INFORMATION
	ok_create := win32.CreateProcessW(
		nil, cmd_wide,
		nil, nil,
		true,
		win32.CREATE_NO_WINDOW,
		nil, nil,
		&si, &pi,
	)
	if !ok_create {
		log_writef("ERR", fmt.tprintf("CreateProcess failed: %v", win32.GetLastError()))
		win32.CloseHandle(stdin_read);  win32.CloseHandle(stdin_write)
		win32.CloseHandle(stdout_read); win32.CloseHandle(stdout_write)
		return {}, false
	}

	// Child-side handles are no longer needed in the parent
	win32.CloseHandle(stdin_read)
	win32.CloseHandle(stdout_write)
	win32.CloseHandle(pi.hThread)

	log_writef("INF", fmt.tprintf("CreateProcess: %s", cmd[0]))

	return Server_Process{
		proc_handle = pi.hProcess,
		stdin_fd    = stdin_write,
		stdout_fd   = stdout_read,
		running     = true,
	}, true
}

process_kill :: proc(p: ^Server_Process) {
	if !p.running { return }
	win32.TerminateProcess(p.proc_handle, 0)
	win32.WaitForSingleObject(p.proc_handle, win32.INFINITE)
	win32.CloseHandle(p.proc_handle)
	win32.CloseHandle(p.stdin_fd)
	win32.CloseHandle(p.stdout_fd)
	p.running = false
}

// Returns (exited, exit_code). Non-blocking check.
process_poll :: proc(p: ^Server_Process) -> (exited: bool, exit_code: int) {
	if !p.running { return true, 0 }
	result := win32.WaitForSingleObject(p.proc_handle, 0)
	if result == 0 { // WAIT_OBJECT_0
		code: win32.DWORD
		win32.GetExitCodeProcess(p.proc_handle, &code)
		p.running = false
		return true, int(code)
	}
	return false, 0
}

// ---------------------------------------------------------------------------
// Read thread
// ---------------------------------------------------------------------------

Read_Thread_Data :: struct {
	fd:    win32.HANDLE,
	queue: ^Read_Queue,
	done:  bool,
}

_read_thread_proc :: proc(t: ^thread.Thread) {
	d := cast(^Read_Thread_Data)t.data

	buf_cap := 1 << 16
	buf     := make([]u8, buf_cap)
	defer delete(buf)
	filled := 0

	for !d.done {
		if filled == len(buf) {
			new_buf := make([]u8, len(buf) * 2)
			copy(new_buf, buf)
			delete(buf)
			buf = new_buf
		}

		n: win32.DWORD
		ok := win32.ReadFile(d.fd, raw_data(buf[filled:]), u32(len(buf) - filled), &n, nil)
		if !ok || n == 0 { break }
		filled += int(n)

		for {
			content_len, header_end := parse_header(buf[:filled])
			if content_len < 0 { break }
			total := header_end + content_len
			if filled < total { break }
			body := make([]u8, content_len)
			copy(body, buf[header_end:total])
			rq_push(d.queue, Inbox_Message{body = body})
			copy(buf, buf[total:filled])
			filled -= total
		}
	}
}

// ---------------------------------------------------------------------------
// Write thread
// ---------------------------------------------------------------------------

Write_Thread_Data :: struct {
	fd:    win32.HANDLE,
	queue: ^Write_Queue,
}

_write_thread_proc :: proc(t: ^thread.Thread) {
	d := cast(^Write_Thread_Data)t.data

	for {
		sync.mutex_lock(&d.queue.mu)
		for len(d.queue.items) == 0 && !d.queue.done {
			sync.cond_wait(&d.queue.cond, &d.queue.mu)
		}
		if d.queue.done && len(d.queue.items) == 0 {
			sync.mutex_unlock(&d.queue.mu)
			break
		}
		pending := make([dynamic][]u8)
		for item in d.queue.items { append(&pending, item) }
		clear(&d.queue.items)
		sync.mutex_unlock(&d.queue.mu)

		pipe_ok := true
		for item in pending {
			if pipe_ok {
				written := 0
				for written < len(item) {
					n: win32.DWORD
					ok := win32.WriteFile(d.fd, raw_data(item[written:]), u32(len(item) - written), &n, nil)
					if !ok || n == 0 { pipe_ok = false; break }
					written += int(n)
				}
			}
			delete(item)
		}
		delete(pending)
		if !pipe_ok { break }
	}
}

// ---------------------------------------------------------------------------
// Transport
// ---------------------------------------------------------------------------

Transport :: struct {
	process:      Server_Process,
	inbox:        Read_Queue,
	outbox:       Write_Queue,
	read_thread:  ^thread.Thread,
	write_thread: ^thread.Thread,
	read_data:    ^Read_Thread_Data,
	write_data:   ^Write_Thread_Data,
	running:      bool,
}

transport_start :: proc(t: ^Transport, cmd: []string) -> bool {
	p, spawned := spawn_server(cmd)
	if !spawned { return false }

	t.process = p
	rq_init(&t.inbox)
	wq_init(&t.outbox)

	t.read_data        = new(Read_Thread_Data)
	t.read_data.fd     = p.stdout_fd
	t.read_data.queue  = &t.inbox

	t.read_thread      = thread.create(_read_thread_proc)
	t.read_thread.data = t.read_data
	thread.start(t.read_thread)

	t.write_data        = new(Write_Thread_Data)
	t.write_data.fd     = p.stdin_fd
	t.write_data.queue  = &t.outbox

	t.write_thread = thread.create(_write_thread_proc)
	t.write_thread.data = t.write_data
	thread.start(t.write_thread)

	t.running = true
	return true
}

transport_send :: proc(t: ^Transport, body: string) {
	if !t.running { return }
	framed := frame_message(body)
	wq_push(&t.outbox, framed)
}

transport_drain :: proc(t: ^Transport, out: ^[dynamic]Inbox_Message) {
	rq_drain(&t.inbox, out)
}

transport_stop :: proc(t: ^Transport) {
	if !t.running { return }
	t.running = false
	t.read_data.done = true
	wq_stop(&t.outbox)

	win32.CloseHandle(t.process.stdout_fd)

	thread.join(t.read_thread)
	thread.join(t.write_thread)
	thread.destroy(t.read_thread)
	thread.destroy(t.write_thread)

	free(t.read_data)
	free(t.write_data)

	process_kill(&t.process)
	rq_destroy(&t.inbox)
	wq_destroy(&t.outbox)
}
