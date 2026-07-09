#+build windows
package editor

// OS-level crash capture (access violation, illegal instruction, etc.) that
// Odin's own bounds/nil checks never see. The handler reopens the log by
// path (precomputed once, not allocated inside the handler) and appends a
// short marker before letting the default crash behavior proceed.

import win32 "core:sys/windows"

@(private="file")
_log_path_wide: win32.wstring

_crashlog_install_handlers :: proc() {
	_log_path_wide = win32.utf8_to_wstring(_log_path, context.allocator)
	win32.SetUnhandledExceptionFilter(_crashlog_exception_handler)
}

_crashlog_exception_handler :: proc "system" (info: ^win32.EXCEPTION_POINTERS) -> win32.LONG {
	if _log_path_wide != nil {
		h := win32.CreateFileW(
			_log_path_wide, win32.FILE_APPEND_DATA, win32.FILE_SHARE_READ, nil,
			win32.OPEN_ALWAYS, win32.FILE_ATTRIBUTE_NORMAL, nil,
		)
		if h != win32.INVALID_HANDLE_VALUE {
			code: u32 = 0
			if info != nil && info.ExceptionRecord != nil {
				code = info.ExceptionRecord.ExceptionCode
			}
			msg := "\nCRASH: exception 0x"
			written: win32.DWORD
			win32.WriteFile(h, raw_data(msg), u32(len(msg)), &written, nil)
			hex_buf: [8]u8
			hex := _u32_to_hex(code, hex_buf[:])
			win32.WriteFile(h, raw_data(hex), u32(len(hex)), &written, nil)
			nl := "\n"
			win32.WriteFile(h, raw_data(nl), u32(len(nl)), &written, nil)
			win32.CloseHandle(h)
		}
	}
	return win32.EXCEPTION_CONTINUE_SEARCH
}

@(private="file")
_u32_to_hex :: proc "contextless" (v: u32, buf: []u8) -> string {
	digits := "0123456789ABCDEF"
	for i := 0; i < 8; i += 1 {
		shift := uint(28 - i * 4)
		buf[i] = digits[(v >> shift) & 0xF]
	}
	return string(buf[:])
}
