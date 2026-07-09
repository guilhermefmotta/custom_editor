#+build linux, darwin
package editor

// OS-level crash capture (segfault, illegal instruction, etc.) that Odin's
// own bounds/nil checks never see. Handlers do only async-signal-safe work
// (raw fd open/write/close, no allocation) since the process is mid-crash.

import "core:sys/posix"

_crash_signals := [?]posix.Signal{.SIGSEGV, .SIGABRT, .SIGILL, .SIGFPE, .SIGBUS}

_crashlog_install_handlers :: proc() {
	for sig in _crash_signals {
		posix.signal(sig, _crashlog_signal_handler)
	}
}

_crashlog_signal_handler :: proc "c" (sig: posix.Signal) {
	if _log_path_cstr != nil {
		fd := posix.open(_log_path_cstr, {.WRONLY, .APPEND, .CREAT}, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
		if fd >= 0 {
			prefix := "\nCRASH: signal "
			posix.write(fd, raw_data(prefix), len(prefix))
			msg := posix.strsignal(sig)
			if msg != nil {
				s := string(msg)
				posix.write(fd, raw_data(s), len(s))
			}
			posix.write(fd, raw_data(string("\n")), 1)
			posix.close(fd)
		}
	}
	posix.signal(sig, auto_cast posix.SIG_DFL)
	posix.raise(sig)
}
