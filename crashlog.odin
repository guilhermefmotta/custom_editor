package editor

// Per-run crash/diagnostic log. A fresh timestamped file is created every
// time the editor starts, right next to the editor executable — easy to
// find, no hunting through config dirs.
// Odin-level panics/asserts/bounds failures are routed here via
// context.assertion_failure_proc; OS-level crashes (segfault, etc.) are
// caught by a platform signal/exception handler in crashlog_posix.odin /
// crashlog_windows.odin so a crash always leaves a trail.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

@(private="file")
_log_file: ^os.File

@(private)
_log_path: string

// Null-terminated copy of _log_path for use by async-signal-safe crash
// handlers, which cannot safely allocate.
@(private)
_log_path_cstr: cstring

elog_home_dir :: proc() -> string {
	dir, err := os.get_executable_directory(context.temp_allocator)
	if err != nil || dir == "" { return "." }
	return dir
}

elog_init :: proc() {
	dir := elog_home_dir()

	now := time.now()
	y, mo, d := time.date(now)
	h, mi, s := time.clock_from_time(now)
	sep := "/" when ODIN_OS != .Windows else "\\"
	_log_path = fmt.aprintf("%s%s%s.log", dir, sep,
		fmt.tprintf("editor_%4d-%02d-%02d_%02d%02d%02d", y, int(mo), d, h, mi, s))
	_log_path_cstr = strings.clone_to_cstring(_log_path)

	f, err := os.create(_log_path)
	if err != nil { return } // no log dir writable — editor still runs fine
	_log_file = f

	elog("editor started — %s %s", ODIN_OS, ODIN_ARCH)
	_crashlog_install_handlers()
}

// context is an implicit per-call parameter, not a global — assigning
// context.assertion_failure_proc here would only affect this proc's own
// scope. Callers must set it themselves: context.assertion_failure_proc =
// elog_assertion_failure_proc, right after calling elog_init().
elog_assertion_failure_proc :: proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
	// elog() flushes every write, so the PANIC line is durable on disk
	// without needing a clean close — and we're about to trap/crash anyway.
	elog("PANIC: %s: %s (%s:%d:%d)", prefix, message, loc.file_path, loc.line, loc.column)
	runtime.default_assertion_failure_proc(prefix, message, loc)
}

elog :: proc(format: string, args: ..any) {
	if _log_file == nil { return }
	now := time.now()
	h, mi, s := time.clock_from_time(now)
	line := fmt.tprintf("[%02d:%02d:%02d] ", h, mi, s)
	os.write_string(_log_file, line)
	msg := fmt.tprintf(format, ..args)
	os.write_string(_log_file, msg)
	os.write_string(_log_file, "\n")
	os.flush(_log_file)
}

elog_close :: proc() {
	if _log_file == nil { return }
	elog("editor exited normally")
	os.close(_log_file)
	_log_file = nil
}
