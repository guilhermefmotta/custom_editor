package lsp

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

_log_file: ^os.File

lsp_log_open :: proc(path: string) {
	f, err := os.open(path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC)
	if err != nil { return }
	_log_file = f
	_log_write("[lsp] log opened\n")
}

lsp_log_close :: proc() {
	if _log_file == nil { return }
	_log_write("[lsp] log closed\n")
	os.close(_log_file)
	_log_file = nil
}

_log_write :: proc(s: string) {
	if _log_file == nil { return }
	data := transmute([]u8)s
	written := 0
	for written < len(data) {
		n, err := os.write(_log_file, data[written:])
		if err != nil || n <= 0 { break }
		written += n
	}
}

log_writef :: proc(level: string, msg: string) {
	if _log_file == nil { return }
	now := time.now()
	h, m, s := time.clock_from_time(now)
	line := fmt.tprintf("[%02d:%02d:%02d] [%s] %s\n", h, m, s, level, msg)
	_log_write(line)
}
