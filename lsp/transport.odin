package lsp

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import linux "core:sys/linux"
import "core:sys/posix"

// ---------------------------------------------------------------------------
// Write queue — mutex + condvar for efficient blocking write thread
// ---------------------------------------------------------------------------

Write_Queue :: struct {
	items: [dynamic][]u8, // owned slices
	mu:    sync.Mutex,
	cond:  sync.Cond,
	done:  bool,
}

wq_init :: proc(q: ^Write_Queue) {
	q.items = make([dynamic][]u8)
	// Cond is zero-initialized; no explicit init needed in Odin
}

wq_destroy :: proc(q: ^Write_Queue) {
	for item in q.items { delete(item) }
	delete(q.items)
}

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
// Read queue — inbox messages from server
// ---------------------------------------------------------------------------

Read_Queue :: struct {
	items: [dynamic]Inbox_Message,
	mu:    sync.Mutex,
}

rq_init :: proc(q: ^Read_Queue) {
	q.items = make([dynamic]Inbox_Message)
}

rq_destroy :: proc(q: ^Read_Queue) {
	for &m in q.items { delete(m.body) }
	delete(q.items)
}

rq_push :: proc(q: ^Read_Queue, msg: Inbox_Message) {
	sync.mutex_lock(&q.mu)
	append(&q.items, msg)
	sync.mutex_unlock(&q.mu)
}

// Drain all pending items into out. Caller owns the returned bodies.
rq_drain :: proc(q: ^Read_Queue, out: ^[dynamic]Inbox_Message) {
	sync.mutex_lock(&q.mu)
	for &m in q.items { append(out, m) }
	clear(&q.items)
	sync.mutex_unlock(&q.mu)
}

// ---------------------------------------------------------------------------
// Server process
// ---------------------------------------------------------------------------

Server_Process :: struct {
	pid:       linux.Pid,
	stdin_fd:  linux.Fd, // parent writes → server reads
	stdout_fd: linux.Fd, // parent reads  ← server writes
	running:   bool,
}

// Spawn a language server. Returns false on failure.
// On success, caller must eventually call process_kill.
spawn_server :: proc(cmd: []string) -> (proc_: Server_Process, ok: bool) {
	if len(cmd) == 0 { return {}, false }

	// stdin_pipe[0] = server reads, stdin_pipe[1] = parent writes
	// stdout_pipe[0] = parent reads, stdout_pipe[1] = server writes
	stdin_pipe:  [2]linux.Fd
	stdout_pipe: [2]linux.Fd

	if e := linux.pipe2(&stdin_pipe,  {}); e != .NONE { return {}, false }
	if e := linux.pipe2(&stdout_pipe, {}); e != .NONE {
		linux.close(stdin_pipe[0]); linux.close(stdin_pipe[1])
		return {}, false
	}

	// Build argv — these strings live until execve replaces the image
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
		// ---- Child process ----
		linux.dup2(stdin_pipe[0],  0) // stdin
		linux.dup2(stdout_pipe[1], 1) // stdout
		// Close all inherited fds we don't need
		linux.close(stdin_pipe[0]);  linux.close(stdin_pipe[1])
		linux.close(stdout_pipe[0]); linux.close(stdout_pipe[1])

		posix.execvp(argv[0], raw_data(argv))
		linux.exit(1) // exec failed
	}

	// ---- Parent ----
	linux.close(stdin_pipe[0])   // we don't read from server's stdin
	linux.close(stdout_pipe[1])  // we don't write to server's stdout

	return Server_Process{
		pid       = pid,
		stdin_fd  = stdin_pipe[1],
		stdout_fd = stdout_pipe[0],
		running   = true,
	}, true
}

process_kill :: proc(p: ^Server_Process) {
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

_read_thread_proc :: proc(t: ^thread.Thread) {
	d := cast(^Read_Thread_Data)t.data

	// Use a persistent read buffer to accumulate partial data
	buf_cap := 1 << 16 // 64 KiB initial
	buf     := make([]u8, buf_cap)
	defer delete(buf)
	filled := 0

	for !d.done {
		// Ensure buffer has space
		if filled == len(buf) {
			new_buf := make([]u8, len(buf) * 2)
			copy(new_buf, buf)
			delete(buf)
			buf = new_buf
		}

		n, err := linux.read(d.fd, buf[filled:])
		if err != .NONE || n <= 0 { break }
		filled += n

		// Parse all complete messages from buffer
		for {
			content_len, header_end := parse_header(buf[:filled])
			if content_len < 0 { break } // need more data for header

			total := header_end + content_len
			if filled < total { break } // need more data for body

			// Extract body and push to queue
			body := make([]u8, content_len)
			copy(body, buf[header_end:total])
			rq_push(d.queue, Inbox_Message{body = body})

			// Shift remaining data to front
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
		// Steal all pending items
		pending := make([dynamic][]u8)
		for item in d.queue.items { append(&pending, item) }
		clear(&d.queue.items)
		sync.mutex_unlock(&d.queue.mu)

		for item in pending {
			written := 0
			for written < len(item) {
				n, err := linux.write(d.fd, item[written:])
				if err != .NONE || n <= 0 { break }
				written += n
			}
			delete(item)
		}
		delete(pending)
	}
}

// ---------------------------------------------------------------------------
// Transport — wraps process + read/write threads
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

transport_start :: proc(cmd: []string) -> (t: Transport, ok: bool) {
	p, spawned := spawn_server(cmd)
	if !spawned { return {}, false }

	t.process = p
	rq_init(&t.inbox)
	wq_init(&t.outbox)

	// Read thread
	t.read_data        = new(Read_Thread_Data)
	t.read_data.fd     = p.stdout_fd
	t.read_data.queue  = &t.inbox

	t.read_thread      = thread.create(_read_thread_proc)
	t.read_thread.data = t.read_data
	thread.start(t.read_thread)

	// Write thread
	t.write_data        = new(Write_Thread_Data)
	t.write_data.fd     = p.stdin_fd
	t.write_data.queue  = &t.outbox

	t.write_thread = thread.create(_write_thread_proc)
	t.write_thread.data = t.write_data
	thread.start(t.write_thread)

	t.running = true
	return t, true
}

// Send a message body (temp string OK — we frame into heap bytes).
transport_send :: proc(t: ^Transport, body: string) {
	if !t.running { return }
	framed := frame_message(body) // heap-allocated
	wq_push(&t.outbox, framed)
}

// Drain inbox into caller-supplied slice.
transport_drain :: proc(t: ^Transport, out: ^[dynamic]Inbox_Message) {
	rq_drain(&t.inbox, out)
}

transport_stop :: proc(t: ^Transport) {
	if !t.running { return }
	t.running = false
	t.read_data.done = true
	wq_stop(&t.outbox)

	linux.close(t.process.stdout_fd)

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
