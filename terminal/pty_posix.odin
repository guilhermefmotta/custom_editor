#+build linux, darwin, freebsd, openbsd, netbsd
package term

// PTY backend for macOS/Linux/BSD: forkpty + execve. The master fd is
// non-blocking; the reader thread polls it with a timeout so it can notice
// `quit`, and writes retry on EAGAIN so a child that stops reading never
// wedges a thread forever.

import "core:c"
import "core:strings"
import "core:sys/posix"

when ODIN_OS == .Linux {
	foreign import util "system:util"
} else when ODIN_OS == .Darwin {
	foreign import util "system:System"
} else {
	foreign import util "system:util"
}

@(private)
Winsize :: struct {
	ws_row, ws_col, ws_xpixel, ws_ypixel: u16,
}

when ODIN_OS == .Linux {
	@(private) TIOCSWINSZ :: c.ulong(0x5414)
} else {
	@(private) TIOCSWINSZ :: c.ulong(0x80087467)
}

@(private, default_calling_convention = "c")
foreign util {
	forkpty :: proc(amaster: ^c.int, name: [^]u8, termp: rawptr, winp: ^Winsize) -> posix.pid_t ---
	ioctl   :: proc(fd: c.int, request: c.ulong, #c_vararg args: ..any) -> c.int ---
}

Pty :: struct {
	fd:  posix.FD,
	pid: posix.pid_t,
	reaped: bool,
}

// Absolute path of `name` looked up in $PATH (or `name` itself when it has a
// slash). Allocated with `allocator`; "" when not found.
@(private)
_resolve_exe :: proc(name: string, allocator := context.allocator) -> string {
	if strings.contains_rune(name, '/') { return strings.clone(name, allocator) }
	path := string(posix.getenv("PATH"))
	if path == "" { path = "/usr/bin:/bin" }
	for dir in strings.split_iterator(&path, ":") {
		full := strings.concatenate({dir if dir != "" else ".", "/", name}, allocator)
		cs := strings.clone_to_cstring(full, context.temp_allocator)
		if posix.access(cs, {.X_OK}) == .OK { return full }
		delete(full, allocator)
	}
	return ""
}

// Default interactive shell: $SHELL (login shell on macOS, like Terminal.app).
default_shell :: proc(allocator := context.allocator) -> []string {
	sh := string(posix.getenv("SHELL"))
	if sh == "" { sh = "/bin/sh" }
	when ODIN_OS == .Darwin {
		out := make([]string, 2, allocator)
		out[0] = strings.clone(sh, allocator)
		out[1] = strings.clone("-l", allocator)
	} else {
		out := make([]string, 1, allocator)
		out[0] = strings.clone(sh, allocator)
	}
	return out
}

// Spawns argv[0] on a new PTY of rows×cols, cwd = `cwd` ("" = inherit),
// environment = inherited + `env` overrides ("KEY=VALUE").
pty_spawn :: proc(p: ^Pty, argv: []string, cwd: string, env: []string, rows, cols: int) -> bool {
	if len(argv) == 0 { return false }
	context.allocator = context.temp_allocator // everything below is freed by the caller's temp scope

	exe := _resolve_exe(argv[0])
	if exe == "" { return false }
	exe_c := strings.clone_to_cstring(exe)
	cwd_c := strings.clone_to_cstring(cwd) if cwd != "" else nil

	args := make([]cstring, len(argv) + 1)
	for a, i in argv { args[i] = strings.clone_to_cstring(a) }

	// Inherited environment minus the keys we override.
	envp := make([dynamic]cstring)
	outer: for i := 0; posix.environ[i] != nil; i += 1 {
		kv := string(posix.environ[i])
		if env_is_session_marker(kv) { continue }
		for o in env {
			k := o[:strings.index_byte(o, '=') + 1]
			if strings.has_prefix(kv, k) { continue outer }
		}
		append(&envp, posix.environ[i])
	}
	for o in env { append(&envp, strings.clone_to_cstring(o)) }
	append(&envp, nil)

	ws := Winsize{ws_row = u16(max(rows, 1)), ws_col = u16(max(cols, 1))}
	master: c.int
	pid := forkpty(&master, nil, nil, &ws)
	if pid < 0 { return false }
	if pid == 0 {
		// Child: only async-signal-safe calls from here on.
		// Undo what the editor may have set (ignored SIGPIPE would make
		// `yes | head` spin forever; blocked signals would survive exec).
		for s in ([?]posix.Signal{.SIGPIPE, .SIGINT, .SIGQUIT, .SIGTERM, .SIGHUP, .SIGCHLD, .SIGTSTP, .SIGTTIN, .SIGTTOU}) {
			posix.signal(s, auto_cast posix.SIG_DFL)
		}
		empty: posix.sigset_t
		posix.sigemptyset(&empty)
		posix.sigprocmask(.SETMASK, &empty, nil)
		// Don't leak the editor's fds (LSP pipes, other terminals' masters).
		for fd in 3 ..< 1024 { posix.close(posix.FD(fd)) }
		if cwd_c != nil { posix.chdir(cwd_c) }
		posix.execve(exe_c, raw_data(args), raw_data(envp[:]))
		posix._exit(127)
	}

	p.fd = posix.FD(master)
	p.pid = pid
	p.reaped = false
	flags := posix.fcntl(p.fd, .GETFL)
	posix.fcntl(p.fd, .SETFL, flags | c.int(posix.O_NONBLOCK))
	posix.fcntl(p.fd, .SETFD, c.int(posix.FD_CLOEXEC))
	return true
}

// Waits up to timeout_ms for output. eof = the child side is gone.
pty_read :: proc(p: ^Pty, buf: []u8, timeout_ms: int) -> (n: int, eof: bool) {
	pfd := posix.pollfd{fd = p.fd, events = {.IN}}
	r := posix.poll(&pfd, 1, c.int(timeout_ms))
	if r < 0 { return 0, posix.errno() != .EINTR }
	if r == 0 { return 0, false }
	got := posix.read(p.fd, raw_data(buf), c.size_t(len(buf)))
	if got > 0 { return int(got), false }
	if got < 0 {
		e := posix.errno()
		if e == .EAGAIN || e == .EINTR { return 0, false }
	}
	return 0, true // 0 = EOF; EIO = slave closed (Linux)
}

// Writes all of data unless `quit` becomes true or the pty breaks.
pty_write :: proc(p: ^Pty, data: []u8, quit: ^bool) -> bool {
	rest := data
	for len(rest) > 0 {
		w := posix.write(p.fd, raw_data(rest), c.size_t(len(rest)))
		if w > 0 { rest = rest[w:]; continue }
		e := posix.errno()
		if w < 0 && (e == .EAGAIN || e == .EINTR) {
			if _atomic_load(quit) { return false }
			pfd := posix.pollfd{fd = p.fd, events = {.OUT}}
			posix.poll(&pfd, 1, 50)
			continue
		}
		return false
	}
	return true
}

pty_resize :: proc(p: ^Pty, rows, cols: int) {
	ws := Winsize{ws_row = u16(max(rows, 1)), ws_col = u16(max(cols, 1))}
	ioctl(c.int(p.fd), TIOCSWINSZ, &ws)
}

// Asks the child (its whole process group) to hang up. Non-blocking.
pty_kill :: proc(p: ^Pty) {
	if p.pid <= 0 || p.reaped { return }
	posix.kill(-p.pid, .SIGHUP)
	posix.kill(p.pid, .SIGHUP)
}

// True once the child has exited (reaps it).
pty_child_exited :: proc(p: ^Pty) -> bool {
	if p.pid <= 0 || p.reaped { return true }
	status: c.int
	r := posix.waitpid(p.pid, &status, {.NOHANG})
	if r == p.pid || r < 0 { p.reaped = true }
	return p.reaped
}

// Releases the fd and reaps the child (SIGKILL after ~200ms of grace).
// Call after the I/O threads are joined.
pty_close :: proc(p: ^Pty) {
	if p.pid > 0 && !p.reaped {
		pty_kill(p)
		for _ in 0 ..< 40 {
			if pty_child_exited(p) { break }
			_sleep_ms(5)
		}
		if !p.reaped {
			posix.kill(-p.pid, .SIGKILL)
			posix.kill(p.pid, .SIGKILL)
			status: c.int
			posix.waitpid(p.pid, &status, {})
			p.reaped = true
		}
	}
	if p.fd > 0 { posix.close(p.fd); p.fd = -1 }
}
