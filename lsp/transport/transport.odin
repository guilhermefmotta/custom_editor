// Package lsp_transport — I/O abstraction layer.
//
// Responsibilities:
//   - Transport vtable interface: any bidirectional byte stream
//   - Stdio_Transport: child process stdin/stdout via Linux pipes
//   - TCP_Transport placeholder (socket-based servers)
//
// The generic Connection in lsp_conn only sees Transport — it never knows
// whether bytes flow through a pipe, a TCP socket, or a mock buffer.
// This makes the entire RPC stack testable and transport-swappable.
//
// Thread model: write() is called from the write thread; read() blocks
// in the read thread.  close() can be called from any thread to signal
// EOF — both threads must handle EINTR / EPIPE gracefully.
package lsp_transport

import linux "core:sys/linux"
import "core:sync"
import "core:strings"
import "core:sys/posix"

// ---------------------------------------------------------------------------
// Transport vtable interface
// ---------------------------------------------------------------------------

Transport_VTable :: struct {
	// read: fill buf with up to len(buf) bytes. Returns n > 0 on success,
	// n == 0 on clean EOF, n < 0 on error.
	read:  proc(self: rawptr, buf: []u8) -> int,
	// write: send all bytes in data. Returns false on error.
	write: proc(self: rawptr, data: []u8) -> bool,
	// close: signal EOF; wake blocked readers/writers.
	close: proc(self: rawptr),
	// destroy: free all resources.
	destroy: proc(self: rawptr),
}

Transport :: struct {
	vtable: ^Transport_VTable,
	data:   rawptr,
}

transport_read    :: #force_inline proc(t: ^Transport, buf: []u8) -> int    { return t.vtable.read(t.data, buf) }
transport_write   :: #force_inline proc(t: ^Transport, data: []u8) -> bool  { return t.vtable.write(t.data, data) }
transport_close   :: #force_inline proc(t: ^Transport)                      { t.vtable.close(t.data) }
transport_destroy :: #force_inline proc(t: ^Transport)                      { t.vtable.destroy(t.data); t^ = {} }

// ---------------------------------------------------------------------------
// Server_Process — spawned child process
// ---------------------------------------------------------------------------

Server_Process :: struct {
	pid:       linux.Pid,
	stdin_fd:  linux.Fd,   // parent writes → server reads
	stdout_fd: linux.Fd,   // parent reads ← server writes
	alive:     bool,
}

// spawn_server forks and execs cmd.  On success the caller owns the
// returned Server_Process and must eventually call process_kill.
// CLOEXEC on both pipe pairs prevents FD leaking into the child.
spawn_server :: proc(cmd: []string) -> (p: Server_Process, ok: bool) {
	if len(cmd) == 0 { return {}, false }

	stdin_pipe, stdout_pipe: [2]linux.Fd
	if e := linux.pipe2(&stdin_pipe,  {.CLOEXEC}); e != .NONE { return {}, false }
	if e := linux.pipe2(&stdout_pipe, {.CLOEXEC}); e != .NONE {
		linux.close(stdin_pipe[0]);  linux.close(stdin_pipe[1])
		return {}, false
	}

	argv := make([]cstring, len(cmd) + 1, context.temp_allocator)
	for s, i in cmd { argv[i] = strings.clone_to_cstring(s, context.temp_allocator) }
	argv[len(cmd)] = nil

	pid, fork_err := linux.fork()
	if fork_err != .NONE {
		linux.close(stdin_pipe[0]);  linux.close(stdin_pipe[1])
		linux.close(stdout_pipe[0]); linux.close(stdout_pipe[1])
		return {}, false
	}

	if pid == 0 {
		// Child: wire pipes to stdin/stdout, then exec.
		// dup2 creates FDs without CLOEXEC, so they survive exec.
		linux.dup2(stdin_pipe[0],  0)
		linux.dup2(stdout_pipe[1], 1)
		linux.close(stdin_pipe[0]);  linux.close(stdin_pipe[1])
		linux.close(stdout_pipe[0]); linux.close(stdout_pipe[1])
		posix.execvp(argv[0], raw_data(argv))
		linux.exit(1)
	}

	// Parent: close child ends.
	linux.close(stdin_pipe[0])
	linux.close(stdout_pipe[1])

	return Server_Process{
		pid       = pid,
		stdin_fd  = stdin_pipe[1],
		stdout_fd = stdout_pipe[0],
		alive     = true,
	}, true
}

process_kill :: proc(p: ^Server_Process) {
	if !p.alive { return }
	linux.kill(p.pid, .SIGTERM)
	linux.waitpid(p.pid, nil, {}, nil)
	linux.close(p.stdin_fd)
	linux.close(p.stdout_fd)
	p.alive = false
}

// Poll whether the child has exited. Returns (true, exit_code) if done.
process_poll :: proc(p: ^Server_Process) -> (done: bool, exit_code: int) {
	if !p.alive { return true, 0 }
	status: u32
	wpid, _ := linux.waitpid(p.pid, &status, {.WNOHANG}, nil)
	if wpid <= 0 { return false, 0 }
	p.alive = false
	return true, int((status >> 8) & 0xff)
}

// ---------------------------------------------------------------------------
// Stdio_Transport — wraps Server_Process for generic transport use
// ---------------------------------------------------------------------------

Stdio_Transport :: struct {
	process: Server_Process,
	mu:      sync.Mutex,  // serialises concurrent write() calls
	closed:  bool,
}

@(private)
_stdio_read :: proc(self: rawptr, buf: []u8) -> int {
	t := cast(^Stdio_Transport)self
	for {
		n, err := linux.read(t.process.stdout_fd, buf)
		if err == .EINTR { continue }
		if err != .NONE || n <= 0 { return 0 }
		return n
	}
}

@(private)
_stdio_write :: proc(self: rawptr, data: []u8) -> bool {
	t := cast(^Stdio_Transport)self
	sync.mutex_lock(&t.mu)
	defer sync.mutex_unlock(&t.mu)
	if t.closed { return false }
	written := 0
	for written < len(data) {
		n, err := linux.write(t.process.stdin_fd, data[written:])
		if err == .EINTR { continue }
		if err != .NONE || n <= 0 { return false }
		written += n
	}
	return true
}

@(private)
_stdio_close :: proc(self: rawptr) {
	t := cast(^Stdio_Transport)self
	sync.mutex_lock(&t.mu)
	t.closed = true
	linux.close(t.process.stdin_fd)
	sync.mutex_unlock(&t.mu)
}

@(private)
_stdio_destroy :: proc(self: rawptr) {
	t := cast(^Stdio_Transport)self
	process_kill(&t.process)
	free(t)
}

_stdio_vtable := Transport_VTable{
	read    = _stdio_read,
	write   = _stdio_write,
	close   = _stdio_close,
	destroy = _stdio_destroy,
}

// stdio_transport_create spawns the server and returns a heap-allocated
// Transport wrapping it.  destroy() kills the process and frees memory.
stdio_transport_create :: proc(cmd: []string) -> (^Transport, bool) {
	process, ok := spawn_server(cmd)
	if !ok { return nil, false }

	t := new(Stdio_Transport)
	t.process = process
	wrap := new(Transport)
	wrap.vtable = &_stdio_vtable
	wrap.data   = t
	return wrap, true
}
