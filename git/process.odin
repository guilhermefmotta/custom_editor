package git

import "core:strings"
import "core:sys/posix"
import linux "core:sys/linux"

// git_run_raw returns heap-owned stdout AND exit code regardless of success.
// Caller must always delete(output).
git_run_raw :: proc(root: string, args: []string, allocator := context.allocator) -> (output: string, exit_code: int) {
	return _exec(root, args, allocator)
}

// git_run executes `git -C root <args>` and returns heap-owned stdout.
// ok=false on non-zero exit. Caller must delete(output) when ok=true.
git_run :: proc(root: string, args: []string, allocator := context.allocator) -> (output: string, ok: bool) {
	out, code := _exec(root, args, allocator)
	if code != 0 { delete(out, allocator); return "", false }
	return out, true
}

@(private)
_exec :: proc(root: string, args: []string, allocator := context.allocator) -> (output: string, exit_code: int) {
	// Build argv: ["git", "-C", root, ...args, nil]
	argv := make([]cstring, len(args) + 4, context.temp_allocator)
	argv[0] = strings.clone_to_cstring("git",  context.temp_allocator)
	argv[1] = strings.clone_to_cstring("-C",   context.temp_allocator)
	argv[2] = strings.clone_to_cstring(root,   context.temp_allocator)
	for a, i in args { argv[i+3] = strings.clone_to_cstring(a, context.temp_allocator) }
	argv[len(args)+3] = nil

	pfd: [2]linux.Fd
	if e := linux.pipe2(&pfd, {.CLOEXEC}); e != .NONE { return "", 1 }

	pid, fork_err := linux.fork()
	if fork_err != .NONE {
		linux.close(pfd[0]); linux.close(pfd[1])
		return "", 1
	}

	if pid == 0 {
		// Child: stdout → pipe, stderr → /dev/null, stdin → /dev/null
		linux.dup2(pfd[1], 1)
		null: cstring = "/dev/null"
		devnull, _ := linux.open(null, {.WRONLY}, {})
		linux.dup2(devnull, 2)
		null_r, _ := linux.open(null, linux.Open_Flags{}, {}) // O_RDONLY = 0
		linux.dup2(null_r, 0)
		linux.close(pfd[1])
		posix.execvp(argv[0], raw_data(argv))
		linux.exit(127)
	}

	linux.close(pfd[1])
	buf := make([dynamic]u8, allocator)
	tmp: [8192]u8
	for {
		n, e := linux.read(pfd[0], tmp[:])
		if e != .NONE || n <= 0 { break }
		append(&buf, ..tmp[:n])
	}
	linux.close(pfd[0])

	wstatus: u32
	linux.waitpid(pid, &wstatus, {}, nil)
	return string(buf[:]), int((wstatus >> 8) & 0xFF)
}
