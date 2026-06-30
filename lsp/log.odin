package lsp

import "core:fmt"
import "core:strings"
import linux "core:sys/linux"
import "core:time"

_log_fd: linux.Fd = -1

lsp_log_open :: proc(path: string) {
	flags := linux.Open_Flags{.WRONLY, .CREAT, .TRUNC}
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	fd, err := linux.open(cpath, flags, linux.Mode{.IRUSR, .IWUSR, .IRGRP, .IROTH})
	if err != .NONE { return }
	_log_fd = fd
	_log_write("[lsp] log opened\n")
}

lsp_log_close :: proc() {
	if _log_fd < 0 { return }
	_log_write("[lsp] log closed\n")
	linux.close(_log_fd)
	_log_fd = -1
}

_log_write :: proc(s: string) {
	if _log_fd < 0 { return }
	data := transmute([]u8)s
	written := 0
	for written < len(data) {
		n, err := linux.write(_log_fd, data[written:])
		if err != .NONE || n <= 0 { break }
		written += n
	}
}

log_writef :: proc(level: string, msg: string) {
	if _log_fd < 0 { return }
	now := time.now()
	h, m, s := time.clock_from_time(now)
	line := fmt.tprintf("[%02d:%02d:%02d] [%s] %s\n", h, m, s, level, msg)
	_log_write(line)
}
