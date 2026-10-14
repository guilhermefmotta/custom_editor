package forge

import "core:os"
import "core:strings"
import "core:time"

// Result of running a subprocess. stdout/stderr are owned by the allocator
// passed to the exec proc. started = false when the executable could not be
// launched at all (not installed / not on PATH).
Exec_Result :: struct {
	started:   bool,
	exit_code: int,
	stdout:    string,
	stderr:    string,
}

// Pluggable so tests can run the whole stack without processes or network.
// `stdin_data` is written to the child's stdin and then closed ("" = no stdin).
Exec_Proc :: #type proc(argv: []string, stdin_data: string, dir: string, allocator := context.allocator) -> Exec_Result

exec_result_destroy :: proc(r: ^Exec_Result, allocator := context.allocator) {
	delete(r.stdout, allocator)
	delete(r.stderr, allocator)
	r^ = {}
}

// Real implementation on top of core:os processes. Secrets go through
// stdin, never argv (argv is visible to other users via `ps`).
exec_process :: proc(argv: []string, stdin_data: string, dir: string, allocator := context.allocator) -> Exec_Result {
	if len(argv) == 0 { return {} }
	res := _exec_once(argv, stdin_data, dir, allocator)
	when ODIN_OS == .Darwin || ODIN_OS == .Linux {
		// GUI apps launched from Finder/desktop often get a minimal PATH
		// without Homebrew/local bins: retry well-known locations.
		if !res.started && strings.index_byte(argv[0], '/') < 0 {
			for dir_ in ([]string{"/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/home/linuxbrew/.linuxbrew/bin"}) {
				alt := make([]string, len(argv), context.temp_allocator)
				copy(alt, argv)
				alt[0] = strings.concatenate({dir_, "/", argv[0]}, context.temp_allocator)
				res = _exec_once(alt, stdin_data, dir, allocator)
				if res.started { break }
			}
		}
	}
	return res
}

@(private)
_exec_once :: proc(argv: []string, stdin_data: string, dir: string, allocator := context.allocator) -> (res: Exec_Result) {
	stdout_r, stdout_w, e1 := os.pipe()
	if e1 != nil { return }
	defer os.close(stdout_r)
	stderr_r, stderr_w, e2 := os.pipe()
	if e2 != nil { os.close(stdout_w); return }
	defer os.close(stderr_r)

	stdin_r, stdin_w: ^os.File
	if stdin_data != "" {
		err: os.Error
		stdin_r, stdin_w, err = os.pipe()
		if err != nil { os.close(stdout_w); os.close(stderr_w); return }
		when ODIN_OS == .Windows {
			// Our write end must not leak into the child, or it never sees EOF.
			_set_no_inherit(stdin_w)
		}
	}

	process: os.Process
	{
		defer os.close(stdout_w)
		defer os.close(stderr_w)
		defer if stdin_r != nil { os.close(stdin_r) }
		perr: os.Error
		process, perr = os.process_start({
			command     = argv,
			working_dir = dir,
			stdout      = stdout_w,
			stderr      = stderr_w,
			stdin       = stdin_r,
		})
		if perr != nil {
			if stdin_w != nil { os.close(stdin_w) }
			return
		}
	}
	res.started = true

	if stdin_w != nil {
		os.write_string(stdin_w, stdin_data)
		os.close(stdin_w)
	}

	// Same loop as core:os process_exec (which cannot feed stdin).
	out := make([dynamic]byte, allocator)
	errb := make([dynamic]byte, allocator)
	buf: [4096]u8
	out_done, err_done: bool
	for !out_done || !err_done {
		if !out_done { out_done = _pump(stdout_r, &out, buf[:]) }
		if !err_done { err_done = _pump(stderr_r, &errb, buf[:]) }
	}
	state, _ := os.process_wait(process)
	res.exit_code = state.exit_code
	res.stdout = string(out[:])
	res.stderr = string(errb[:])
	return
}

// Reads what is available; returns true once the pipe is closed/broken.
@(private)
_pump :: proc(f: ^os.File, into: ^[dynamic]byte, buf: []u8) -> (done: bool) {
	has, err := os.pipe_has_data(f)
	n := 0
	if err == nil && !has { time.sleep(time.Millisecond); return false }
	if err == nil { n, err = os.read(f, buf) }
	if err != nil { return true } // EOF, Broken_Pipe or a real error: stop reading
	append(into, ..buf[:n])
	return false
}
