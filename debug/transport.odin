package debug

// DAP transport: same Content-Length framing as LSP.
// Supports two modes:
//   Process — spawn adapter via stdin/stdout pipes (local adapters)
//   TCP     — connect to adapter listening on host:port (remote/already-running adapters)

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:net"
import "core:strconv"
import linux "core:sys/linux"
import "core:sys/posix"

// ---------------------------------------------------------------------------
// Write queue
// ---------------------------------------------------------------------------

Write_Queue :: struct {
	items: [dynamic][]u8,
	mu:    sync.Mutex,
	cond:  sync.Cond,
	done:  bool,
}

wq_init    :: proc(q: ^Write_Queue) { q.items = make([dynamic][]u8) }
wq_destroy :: proc(q: ^Write_Queue) { for item in q.items { delete(item) }; delete(q.items) }

wq_push :: proc(q: ^Write_Queue, data: []u8) {
	sync.mutex_lock(&q.mu)
	append(&q.items, data)
	sync.mutex_unlock(&q.mu)
	sync.cond_signal(&q.cond)
}

wq_stop :: proc(q: ^Write_Queue) {
	sync.mutex_lock(&q.mu)
	q.done = true
	sync.mutex_unlock(&q.mu)
	sync.cond_signal(&q.cond)
}

// ---------------------------------------------------------------------------
// Read queue
// ---------------------------------------------------------------------------

Read_Queue :: struct {
	items: [dynamic]Inbox_Msg,
	mu:    sync.Mutex,
}

rq_init    :: proc(q: ^Read_Queue) { q.items = make([dynamic]Inbox_Msg) }
rq_destroy :: proc(q: ^Read_Queue) { for &m in q.items { delete(m.body) }; delete(q.items) }

rq_push :: proc(q: ^Read_Queue, msg: Inbox_Msg) {
	sync.mutex_lock(&q.mu)
	append(&q.items, msg)
	sync.mutex_unlock(&q.mu)
}

rq_drain :: proc(q: ^Read_Queue, out: ^[dynamic]Inbox_Msg) {
	sync.mutex_lock(&q.mu)
	for &m in q.items { append(out, m) }
	clear(&q.items)
	sync.mutex_unlock(&q.mu)
}

// ---------------------------------------------------------------------------
// Adapter process
// ---------------------------------------------------------------------------

Adapter_Process :: struct {
	pid:       linux.Pid,
	stdin_fd:  linux.Fd,
	stdout_fd: linux.Fd,
	running:   bool,
}

spawn_adapter :: proc(cmd: []string) -> (proc_: Adapter_Process, ok: bool) {
	if len(cmd) == 0 { return {}, false }

	stdin_pipe:  [2]linux.Fd
	stdout_pipe: [2]linux.Fd

	if e := linux.pipe2(&stdin_pipe,  {.CLOEXEC}); e != .NONE { return {}, false }
	if e := linux.pipe2(&stdout_pipe, {.CLOEXEC}); e != .NONE {
		linux.close(stdin_pipe[0]); linux.close(stdin_pipe[1]); return {}, false
	}

	argv := make([]cstring, len(cmd) + 1, context.temp_allocator)
	for a, i in cmd { argv[i] = strings.clone_to_cstring(a, context.temp_allocator) }
	argv[len(cmd)] = nil

	pid, fork_err := linux.fork()
	if fork_err != .NONE {
		linux.close(stdin_pipe[0]);  linux.close(stdin_pipe[1])
		linux.close(stdout_pipe[0]); linux.close(stdout_pipe[1])
		return {}, false
	}

	if pid == 0 {
		linux.dup2(stdin_pipe[0],  0)
		linux.dup2(stdout_pipe[1], 1)
		linux.close(stdin_pipe[0]);  linux.close(stdin_pipe[1])
		linux.close(stdout_pipe[0]); linux.close(stdout_pipe[1])
		posix.execvp(argv[0], raw_data(argv))
		linux.exit(1)
	}

	linux.close(stdin_pipe[0])
	linux.close(stdout_pipe[1])

	return Adapter_Process{
		pid       = pid,
		stdin_fd  = stdin_pipe[1],
		stdout_fd = stdout_pipe[0],
		running   = true,
	}, true
}

adapter_kill :: proc(p: ^Adapter_Process) {
	if !p.running { return }
	linux.kill(p.pid, .SIGTERM)
	linux.waitpid(p.pid, nil, {}, nil)
	linux.close(p.stdin_fd)
	linux.close(p.stdout_fd)
	p.running = false
}

// ---------------------------------------------------------------------------
// Read thread
// ---------------------------------------------------------------------------

Read_Thread_Data :: struct {
	fd:    linux.Fd,
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
		n, err := linux.read(d.fd, buf[filled:])
		if err != .NONE || n <= 0 { break }
		filled += n

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

// ---------------------------------------------------------------------------
// Write thread
// ---------------------------------------------------------------------------

Write_Thread_Data :: struct {
	fd:    linux.Fd,
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
					n, err := linux.write(d.fd, item[written:])
					if err != .NONE || n <= 0 { pipe_ok = false; break }
					written += n
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

Transport_Mode :: enum { Process, TCP }

Transport :: struct {
	mode:         Transport_Mode,
	process:      Adapter_Process,   // mode == .Process
	tcp_sock:     net.TCP_Socket,    // mode == .TCP
	tcp_read_fd:  linux.Fd,
	tcp_write_fd: linux.Fd,
	inbox:        Read_Queue,
	outbox:       Write_Queue,
	read_thread:  ^thread.Thread,
	write_thread: ^thread.Thread,
	read_data:    ^Read_Thread_Data,
	write_data:   ^Write_Thread_Data,
	running:      bool,
}

// Start by spawning a child process adapter (stdin/stdout).
transport_start :: proc(t: ^Transport, cmd: []string) -> bool {
	p, ok := spawn_adapter(cmd)
	if !ok { return false }

	t.mode    = .Process
	t.process = p
	_transport_start_threads(t, p.stdout_fd, p.stdin_fd)
	return true
}

// Start by connecting to a remote adapter via TCP.
// host: hostname or IP (e.g. "localhost", "192.168.1.10")
// port: TCP port number
transport_start_tcp :: proc(t: ^Transport, host: string, port: int) -> (ok: bool, err_msg: string) {
	sock, net_err := net.dial_tcp_from_hostname_with_port_override(host, port)
	if net_err != nil {
		return false, fmt.tprintf("connect %s:%d failed: %v", host, port, net_err)
	}

	t.mode         = .TCP
	t.tcp_sock     = sock
	fd             := linux.Fd(i32(sock))
	t.tcp_read_fd  = fd
	t.tcp_write_fd = fd

	_transport_start_threads(t, fd, fd)
	return true, ""
}

@(private="file")
_transport_start_threads :: proc(t: ^Transport, read_fd, write_fd: linux.Fd) {
	rq_init(&t.inbox)
	wq_init(&t.outbox)

	t.read_data        = new(Read_Thread_Data)
	t.read_data.fd     = read_fd
	t.read_data.queue  = &t.inbox

	t.read_thread      = thread.create(_dap_read_thread)
	t.read_thread.data = t.read_data
	thread.start(t.read_thread)

	t.write_data        = new(Write_Thread_Data)
	t.write_data.fd     = write_fd
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
	case .Process:
		linux.close(t.process.stdout_fd) // unblocks read thread
	case .TCP:
		linux.close(t.tcp_read_fd)       // unblocks read thread; same fd as write_fd
	}

	thread.join(t.read_thread)
	thread.join(t.write_thread)
	thread.destroy(t.read_thread)
	thread.destroy(t.write_thread)
	free(t.read_data)
	free(t.write_data)

	switch t.mode {
	case .Process:
		adapter_kill(&t.process)
	case .TCP:
		net.close(t.tcp_sock)
	}

	rq_destroy(&t.inbox)
	wq_destroy(&t.outbox)
}

// ---------------------------------------------------------------------------
// Content-Length header parser
// ---------------------------------------------------------------------------

_parse_header :: proc(data: []u8) -> (content_len: int, end: int) {
	i, n := 0, len(data)
	for i + 3 < n {
		if data[i]=='\r' && data[i+1]=='\n' && data[i+2]=='\r' && data[i+3]=='\n' {
			hdr := string(data[:i])
			pfx := "Content-Length: "
			idx := 0; found := false
			for j := 0; j + len(pfx) <= len(hdr); j += 1 {
				if hdr[j:j+len(pfx)] == pfx { idx = j + len(pfx); found = true; break }
			}
			if !found { return -1, 0 }
			cl := 0
			for idx < len(hdr) && hdr[idx] >= '0' && hdr[idx] <= '9' {
				cl = cl*10 + int(hdr[idx]-'0'); idx += 1
			}
			return cl, i + 4
		}
		i += 1
	}
	return -1, 0
}
