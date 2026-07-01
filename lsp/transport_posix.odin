#+build linux, darwin
package lsp

import "core:c"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:sys/posix"

// ---------------------------------------------------------------------------
// Server process — POSIX (Linux / macOS)
// ---------------------------------------------------------------------------

Server_Process :: struct {
	pid:       posix.pid_t,
	stdin_fd:  posix.FD,
	stdout_fd: posix.FD,
	running:   bool,
}

spawn_server :: proc(cmd: []string) -> (proc_: Server_Process, ok: bool) {
	if len(cmd) == 0 { log_writef("ERR", "spawn_server: empty command"); return {}, false }

	stdin_pipe:  [2]posix.FD
	stdout_pipe: [2]posix.FD

	if posix.pipe(&stdin_pipe) != .OK {
		log_writef("ERR", "pipe(stdin) failed")
		return {}, false
	}
	if posix.pipe(&stdout_pipe) != .OK {
		log_writef("ERR", "pipe(stdout) failed")
		posix.close(stdin_pipe[0]); posix.close(stdin_pipe[1])
		return {}, false
	}

	argv := make([]cstring, len(cmd) + 1, context.temp_allocator)
	for a, i in cmd { argv[i] = strings.clone_to_cstring(a, context.temp_allocator) }
	argv[len(cmd)] = nil

	log_writef("INF", fmt.tprintf("fork+exec: %s", cmd[0]))
	pid := posix.fork()
	if pid < 0 {
		log_writef("ERR", "fork failed")
		posix.close(stdin_pipe[0]);  posix.close(stdin_pipe[1])
		posix.close(stdout_pipe[0]); posix.close(stdout_pipe[1])
		return {}, false
	}

	if pid == 0 {
		// Child process
		posix.dup2(stdin_pipe[0],  posix.FD(0))
		posix.dup2(stdout_pipe[1], posix.FD(1))
		posix.close(stdin_pipe[0]);  posix.close(stdin_pipe[1])
		posix.close(stdout_pipe[0]); posix.close(stdout_pipe[1])
		posix.execvp(argv[0], raw_data(argv))
		posix.exit(1)
	}

	// Parent
	posix.close(stdin_pipe[0])
	posix.close(stdout_pipe[1])

	return Server_Process{
		pid       = pid,
		stdin_fd  = stdin_pipe[1],
		stdout_fd = stdout_pipe[0],
		running   = true,
	}, true
}

process_kill :: proc(p: ^Server_Process) {
	if !p.running { return }
	posix.kill(p.pid, .SIGTERM)
	posix.waitpid(p.pid, nil, {})
	posix.close(p.stdin_fd)
	posix.close(p.stdout_fd)
	p.running = false
}

// Returns (exited, exit_code). Non-blocking check.
process_poll :: proc(p: ^Server_Process) -> (exited: bool, exit_code: int) {
	if !p.running { return true, 0 }
	status: c.int
	wpid := posix.waitpid(p.pid, &status, {.NOHANG})
	if wpid > 0 {
		p.running = false
		return true, int((u32(status) >> 8) & 0xff)
	}
	return false, 0
}

// ---------------------------------------------------------------------------
// Read thread
// ---------------------------------------------------------------------------

Read_Thread_Data :: struct {
	fd:    posix.FD,
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

		n := posix.read(d.fd, raw_data(buf[filled:]), c.size_t(uint(len(buf)) - uint(filled)))
		if n <= 0 { break }
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
	fd:    posix.FD,
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
					n := posix.write(d.fd, raw_data(item[written:]), c.size_t(uint(len(item)) - uint(written)))
					if n <= 0 { pipe_ok = false; break }
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

	posix.close(t.process.stdout_fd)

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
