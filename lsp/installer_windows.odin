#+build windows
package lsp

import "core:os"
import "core:strings"
import "core:fmt"
import win32 "core:sys/windows"

// ---------------------------------------------------------------------------
// Binary presence check  (Windows)
// ---------------------------------------------------------------------------

server_binary_exists :: proc(name: string) -> (found: bool, full_path: string) {
	path_env := os.get_env("PATH", context.temp_allocator)
	dirs     := strings.split(path_env, ";", context.temp_allocator)
	exts     := []string{".exe", ".cmd", ".bat"}
	for dir in dirs {
		if dir == "" { continue }
		for ext in exts {
			full := strings.concatenate({dir, "\\", name, ext}, context.temp_allocator)
			if os.exists(full) && !os.is_dir(full) { return true, strings.clone(full) }
		}
	}
	// Editor-owned install dir (%LOCALAPPDATA%\editor\lsp\<name>\<name>.*)
	// used by our own auto-installer.
	home_dir := lsp_home_dir(name)
	for ext in exts {
		full := strings.concatenate({home_dir, "\\", name, ext}, context.temp_allocator)
		if os.exists(full) && !os.is_dir(full) { return true, strings.clone(full) }
	}

	// Common npm/go/cargo locations
	appdata := os.get_env("APPDATA", context.temp_allocator)
	profile := os.get_env("USERPROFILE", context.temp_allocator)
	extras  := []string{
		strings.concatenate({appdata, "\\npm\\", name, ".cmd"}, context.temp_allocator),
		strings.concatenate({profile, "\\go\\bin\\", name, ".exe"}, context.temp_allocator),
		strings.concatenate({profile, "\\.cargo\\bin\\", name, ".exe"}, context.temp_allocator),
	}
	for p in extras {
		if os.exists(p) && !os.is_dir(p) { return true, strings.clone(p) }
	}
	return false, ""
}

// ---------------------------------------------------------------------------
// Install job  (Windows)
// ---------------------------------------------------------------------------

Install_Job :: struct {
	proc_handle: win32.HANDLE,
	out_read:    win32.HANDLE,
	active:      bool,
}

install_job_start :: proc(cmd: []string) -> (job: Install_Job, ok: bool) {
	if len(cmd) == 0 { return {}, false }

	// Build command line
	sb: strings.Builder
	strings.builder_init(&sb, context.temp_allocator)
	for a, i in cmd {
		if i > 0 { strings.write_byte(&sb, ' ') }
		if strings.contains(a, " ") {
			strings.write_byte(&sb, '"')
			strings.write_string(&sb, a)
			strings.write_byte(&sb, '"')
		} else {
			strings.write_string(&sb, a)
		}
	}
	cmd_wide := win32.utf8_to_wstring(strings.to_string(sb), context.temp_allocator)

	sa: win32.SECURITY_ATTRIBUTES
	sa.nLength        = size_of(win32.SECURITY_ATTRIBUTES)
	sa.bInheritHandle = true

	out_read, out_write: win32.HANDLE
	if !win32.CreatePipe(&out_read, &out_write, &sa, 0) { return {}, false }
	win32.SetHandleInformation(out_read, win32.HANDLE_FLAG_INHERIT, 0)

	si: win32.STARTUPINFOW
	si.cb         = size_of(win32.STARTUPINFOW)
	si.dwFlags    = win32.STARTF_USESTDHANDLES | win32.STARTF_USESHOWWINDOW
	si.wShowWindow = u16(win32.SW_HIDE)
	si.hStdInput  = win32.INVALID_HANDLE_VALUE
	si.hStdOutput = out_write
	si.hStdError  = out_write

	pi: win32.PROCESS_INFORMATION
	flags: u32 = win32.CREATE_NO_WINDOW | win32.CREATE_UNICODE_ENVIRONMENT
	ok2 := win32.CreateProcessW(nil, cmd_wide, nil, nil, true, flags, nil, nil, &si, &pi)
	win32.CloseHandle(out_write)
	if !ok2 {
		win32.CloseHandle(out_read)
		return {}, false
	}
	win32.CloseHandle(pi.hThread)
	log_writef("INF", fmt.tprintf("installer: started PID %d", pi.dwProcessId))
	return Install_Job{proc_handle = pi.hProcess, out_read = out_read, active = true}, true
}

// Returns (exited, success). Drains available output.
install_job_poll :: proc(job: ^Install_Job, log_buf: ^[dynamic]u8) -> (exited: bool, success: bool) {
	if !job.active { return true, false }

	// Drain available output (non-blocking via PeekNamedPipe)
	buf: [512]u8
	for {
		avail: win32.DWORD
		if !win32.PeekNamedPipe(job.out_read, nil, 0, nil, &avail, nil) { break }
		if avail == 0 { break }
		read: win32.DWORD
		if !win32.ReadFile(job.out_read, raw_data(buf[:]), 512, &read, nil) { break }
		if read == 0 { break }
		append(log_buf, ..buf[:read])
	}

	res := win32.WaitForSingleObject(job.proc_handle, 0)
	if res == win32.WAIT_OBJECT_0 {
		// Drain remaining
		for {
			avail: win32.DWORD
			if !win32.PeekNamedPipe(job.out_read, nil, 0, nil, &avail, nil) { break }
			if avail == 0 { break }
			read: win32.DWORD
			if !win32.ReadFile(job.out_read, raw_data(buf[:]), 512, &read, nil) { break }
			if read == 0 { break }
			append(log_buf, ..buf[:read])
		}

		exit_code: win32.DWORD
		win32.GetExitCodeProcess(job.proc_handle, &exit_code)
		win32.CloseHandle(job.proc_handle)
		win32.CloseHandle(job.out_read)
		job.active = false
		log_writef("INF", fmt.tprintf("installer: exited with code %d", exit_code))
		return true, exit_code == 0
	}
	return false, false
}

install_job_kill :: proc(job: ^Install_Job) {
	if !job.active { return }
	win32.TerminateProcess(job.proc_handle, 1)
	win32.CloseHandle(job.proc_handle)
	win32.CloseHandle(job.out_read)
	job.active = false
}
