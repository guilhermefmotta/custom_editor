#+build linux, darwin
package lsp

import "core:c"
import "core:sys/posix"
import "core:strings"
import "core:fmt"
import "core:os"

// ---------------------------------------------------------------------------
// Binary presence check  (POSIX)
// ---------------------------------------------------------------------------

server_binary_exists :: proc(name: string) -> (found: bool, full_path: string) {
	path_env := os.get_env("PATH", context.temp_allocator)
	dirs     := strings.split(path_env, ":", context.temp_allocator)
	for dir in dirs {
		if dir == "" { continue }
		full := strings.concatenate({dir, "/", name}, context.temp_allocator)
		if os.exists(full) && !os.is_dir(full) {
			return true, strings.clone(full)
		}
	}
	// Also check common non-PATH install locations, including the
	// editor-owned install dir (~/.config/editor/lsp/<name>/<name>)
	// used by our own auto-installer.
	home := os.get_env("HOME", context.temp_allocator)
	extras := []string{
		strings.concatenate({lsp_home_dir(name), "/", name}, context.temp_allocator),
		strings.concatenate({home, "/.local/bin/", name}, context.temp_allocator),
		strings.concatenate({home, "/go/bin/", name}, context.temp_allocator),
		strings.concatenate({home, "/.cargo/bin/", name}, context.temp_allocator),
	}
	for p in extras {
		if os.exists(p) && !os.is_dir(p) { return true, strings.clone(p) }
	}
	return false, ""
}

// ---------------------------------------------------------------------------
// Install job — fire-and-forget subprocess, output captured to LSP log
// ---------------------------------------------------------------------------

Install_Job :: struct {
	pid:    posix.pid_t,
	out_fd: posix.FD, // read end of stdout+stderr pipe
	active: bool,
}

install_job_start :: proc(cmd: []string) -> (job: Install_Job, ok: bool) {
	if len(cmd) == 0 { return {}, false }

	pipe_fds: [2]posix.FD
	if posix.pipe(&pipe_fds) != .OK { return {}, false }

	argv := make([]cstring, len(cmd) + 1, context.temp_allocator)
	for a, i in cmd { argv[i] = strings.clone_to_cstring(a, context.temp_allocator) }
	argv[len(cmd)] = nil

	log_writef("INF", fmt.tprintf("installer: fork+exec %s", strings.join(cmd, " ", context.temp_allocator)))

	pid := posix.fork()
	if pid < 0 {
		posix.close(pipe_fds[0]); posix.close(pipe_fds[1])
		return {}, false
	}

	if pid == 0 {
		// Child: redirect stdout+stderr to pipe write end; stdin = /dev/null
		null_fd := posix.open("/dev/null", posix.O_Flags{})
		if null_fd >= 0 { posix.dup2(null_fd, posix.FD(0)); posix.close(null_fd) }
		posix.dup2(pipe_fds[1], posix.FD(1))
		posix.dup2(pipe_fds[1], posix.FD(2))
		posix.close(pipe_fds[0]); posix.close(pipe_fds[1])
		posix.execvp(argv[0], raw_data(argv))
		posix.exit(127)
	}

	// Parent
	posix.close(pipe_fds[1])
	// Make read end non-blocking so we can poll
	flags := posix.fcntl(pipe_fds[0], .GETFL)
	posix.fcntl(pipe_fds[0], .SETFL, c.int(flags) | c.int(posix.O_Flags{.NONBLOCK}))

	return Install_Job{pid = pid, out_fd = pipe_fds[0], active = true}, true
}

// Returns (exited, success). Drains available output to log_buf.
install_job_poll :: proc(job: ^Install_Job, log_buf: ^[dynamic]u8) -> (exited: bool, success: bool) {
	if !job.active { return true, false }

	// Drain available output
	buf: [512]u8
	for {
		n := posix.read(job.out_fd, raw_data(buf[:]), 512)
		if n <= 0 { break }
		append(log_buf, ..buf[:n])
	}

	status: c.int
	wpid := posix.waitpid(job.pid, &status, {.NOHANG})
	if wpid > 0 {
		// Drain remaining output after process exit
		for {
			n := posix.read(job.out_fd, raw_data(buf[:]), 512)
			if n <= 0 { break }
			append(log_buf, ..buf[:n])
		}
		posix.close(job.out_fd)
		job.active = false
		code := int((u32(status) >> 8) & 0xff)
		log_writef("INF", fmt.tprintf("installer: exited with code %d", code))
		return true, code == 0
	}
	return false, false
}

install_job_kill :: proc(job: ^Install_Job) {
	if !job.active { return }
	posix.kill(job.pid, .SIGTERM)
	posix.waitpid(job.pid, nil, {})
	posix.close(job.out_fd)
	job.active = false
}
