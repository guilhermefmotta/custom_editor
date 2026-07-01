#+build windows
package debug

import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:thread"
import win32 "core:sys/windows"

// ---------------------------------------------------------------------------
// Adapter process — Windows
// ---------------------------------------------------------------------------

Adapter_Process :: struct {
	proc_handle: win32.HANDLE,
	stdin_fd:    win32.HANDLE,
	stdout_fd:   win32.HANDLE,
	running:     bool,
}

spawn_adapter :: proc(cmd: []string) -> (proc_: Adapter_Process, ok: bool) {
	if len(cmd) == 0 { return {}, false }

	sb: strings.Builder
	strings.builder_init(&sb, context.temp_allocator)
	for i := 0; i < len(cmd); i += 1 {
		if i > 0 { strings.write_byte(&sb, ' ') }
		a := cmd[i]
		has_space := strings.contains(a, " ")
		if has_space { strings.write_byte(&sb, '"') }
		strings.write_string(&sb, a)
		if has_space { strings.write_byte(&sb, '"') }
	}
	cmd_wide := win32.utf8_to_wstring(strings.to_string(sb), context.temp_allocator)

	sa: win32.SECURITY_ATTRIBUTES
	sa.nLength              = size_of(win32.SECURITY_ATTRIBUTES)
	sa.bInheritHandle       = true
	sa.lpSecurityDescriptor = nil

	stdin_read, stdin_write:   win32.HANDLE
	stdout_read, stdout_write: win32.HANDLE

	if !win32.CreatePipe(&stdin_read,  &stdin_write,  &sa, 0) { return {}, false }
	if !win32.CreatePipe(&stdout_read, &stdout_write, &sa, 0) {
		win32.CloseHandle(stdin_read); win32.CloseHandle(stdin_write)
		return {}, false
	}

	win32.SetHandleInformation(stdin_write, win32.HANDLE_FLAG_INHERIT, 0)
	win32.SetHandleInformation(stdout_read, win32.HANDLE_FLAG_INHERIT, 0)

	si: win32.STARTUPINFOW
	si.cb         = size_of(win32.STARTUPINFOW)
	si.hStdInput  = stdin_read
	si.hStdOutput = stdout_write
	si.hStdError  = win32.GetStdHandle(win32.STD_ERROR_HANDLE)
	si.dwFlags    = win32.STARTF_USESTDHANDLES

	pi: win32.PROCESS_INFORMATION
	if !win32.CreateProcessW(nil, cmd_wide, nil, nil, true, win32.CREATE_NO_WINDOW, nil, nil, &si, &pi) {
		win32.CloseHandle(stdin_read);  win32.CloseHandle(stdin_write)
		win32.CloseHandle(stdout_read); win32.CloseHandle(stdout_write)
		return {}, false
	}

	win32.CloseHandle(stdin_read)
	win32.CloseHandle(stdout_write)
	win32.CloseHandle(pi.hThread)

	return Adapter_Process{
		proc_handle = pi.hProcess,
		stdin_fd    = stdin_write,
		stdout_fd   = stdout_read,
		running     = true,
	}, true
}

adapter_kill :: proc(p: ^Adapter_Process) {
	if !p.running { return }
	win32.TerminateProcess(p.proc_handle, 0)
	win32.WaitForSingleObject(p.proc_handle, win32.INFINITE)
	win32.CloseHandle(p.proc_handle)
	win32.CloseHandle(p.stdin_fd)
	win32.CloseHandle(p.stdout_fd)
	p.running = false
}

// ---------------------------------------------------------------------------
// Thread data — Windows handles both pipe HANDLEs and TCP sockets
// ---------------------------------------------------------------------------

Read_Thread_Data :: struct {
	pipe:  win32.HANDLE,
	sock:  net.TCP_Socket,
	mode:  Transport_Mode,
	queue: ^Read_Queue,
	done:  bool,
}

_dap_read_thread :: proc(t: ^thread.Thread) {
	d      := cast(^Read_Thread_Data)t.data
	buf    := make([]u8, 1 << 16)
	defer delete(buf)
	filled := 0

	for !d.done {
		if filled == len(buf) {
			nb := make([]u8, len(buf) * 2)
			copy(nb, buf); delete(buf); buf = nb
		}

		n_read: int
		switch d.mode {
		case .Process:
			n: win32.DWORD
			ok := win32.ReadFile(d.pipe, raw_data(buf[filled:]), u32(len(buf) - filled), &n, nil)
			if !ok || n == 0 { return }
			n_read = int(n)
		case .TCP:
			nr, err := net.recv_tcp(d.sock, buf[filled:])
			if err != nil || nr <= 0 { return }
			n_read = nr
		}
		filled += n_read

		for {
			content_len, header_end := _parse_header(buf[:filled])
			if content_len < 0 { break }
			total := header_end + content_len
			if filled < total { break }
			body := make([]u8, content_len)
			copy(body, buf[header_end:total])
			rq_push(d.queue, Inbox_Msg{body = body})
			copy(buf, buf[total:filled])
			filled -= total
		}
	}
}

Write_Thread_Data :: struct {
	pipe:  win32.HANDLE,
	sock:  net.TCP_Socket,
	mode:  Transport_Mode,
	queue: ^Write_Queue,
}

_dap_write_thread :: proc(t: ^thread.Thread) {
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
					switch d.mode {
					case .Process:
						n: win32.DWORD
						ok := win32.WriteFile(d.pipe, raw_data(item[written:]), u32(len(item) - written), &n, nil)
						if !ok || n == 0 { pipe_ok = false }
						else { written += int(n) }
					case .TCP:
						nw, err := net.send_tcp(d.sock, item[written:])
						if err != nil || nw <= 0 { pipe_ok = false }
						else { written += nw }
					}
					if !pipe_ok { break }
				}
			}
			delete(item)
		}
		delete(pending)
		if !pipe_ok { break }
	}
}

// ---------------------------------------------------------------------------
// Transport — Windows
// ---------------------------------------------------------------------------

Transport :: struct {
	mode:         Transport_Mode,
	process:      Adapter_Process,
	tcp_sock:     net.TCP_Socket,
	inbox:        Read_Queue,
	outbox:       Write_Queue,
	read_thread:  ^thread.Thread,
	write_thread: ^thread.Thread,
	read_data:    ^Read_Thread_Data,
	write_data:   ^Write_Thread_Data,
	running:      bool,
}

transport_start :: proc(t: ^Transport, cmd: []string) -> bool {
	p, ok := spawn_adapter(cmd)
	if !ok { return false }
	t.mode    = .Process
	t.process = p
	_transport_start_threads(t, p.stdout_fd, p.stdin_fd, p.stdout_fd, .Process, {})
	return true
}

transport_start_tcp :: proc(t: ^Transport, host: string, port: int) -> (ok: bool, err_msg: string) {
	sock, net_err := net.dial_tcp_from_hostname_with_port_override(host, port)
	if net_err != nil {
		return false, fmt.tprintf("connect %s:%d failed: %v", host, port, net_err)
	}
	t.mode     = .TCP
	t.tcp_sock = sock
	_transport_start_threads(t, nil, nil, nil, .TCP, sock)
	return true, ""
}

@(private="file")
_transport_start_threads :: proc(
	t: ^Transport,
	read_pipe, write_pipe, close_pipe: win32.HANDLE,
	mode: Transport_Mode,
	sock: net.TCP_Socket,
) {
	rq_init(&t.inbox)
	wq_init(&t.outbox)

	t.read_data        = new(Read_Thread_Data)
	t.read_data.pipe   = read_pipe
	t.read_data.sock   = sock
	t.read_data.mode   = mode
	t.read_data.queue  = &t.inbox

	t.read_thread      = thread.create(_dap_read_thread)
	t.read_thread.data = t.read_data
	thread.start(t.read_thread)

	t.write_data        = new(Write_Thread_Data)
	t.write_data.pipe   = write_pipe
	t.write_data.sock   = sock
	t.write_data.mode   = mode
	t.write_data.queue  = &t.outbox

	t.write_thread      = thread.create(_dap_write_thread)
	t.write_thread.data = t.write_data
	thread.start(t.write_thread)

	t.running = true
}

transport_send :: proc(t: ^Transport, body: string) {
	if !t.running { return }
	header := fmt.tprintf("Content-Length: %d\r\n\r\n", len(body))
	buf    := make([]u8, len(header) + len(body))
	copy(buf[:len(header)], transmute([]u8)header)
	copy(buf[len(header):], transmute([]u8)body)
	wq_push(&t.outbox, buf)
}

transport_drain :: proc(t: ^Transport, out: ^[dynamic]Inbox_Msg) {
	rq_drain(&t.inbox, out)
}

transport_stop :: proc(t: ^Transport) {
	if !t.running { return }
	t.running        = false
	t.read_data.done = true
	wq_stop(&t.outbox)

	switch t.mode {
	case .Process: win32.CloseHandle(t.process.stdout_fd)
	case .TCP:     net.close(t.tcp_sock)
	}

	thread.join(t.read_thread)
	thread.join(t.write_thread)
	thread.destroy(t.read_thread)
	thread.destroy(t.write_thread)
	free(t.read_data)
	free(t.write_data)

	switch t.mode {
	case .Process: adapter_kill(&t.process)
	case .TCP:     // already closed above
	}

	rq_destroy(&t.inbox)
	wq_destroy(&t.outbox)
}
