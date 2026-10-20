#+build linux, darwin, freebsd, openbsd, netbsd
package editor

// ripgrep child process (search_fast.odin): stdout through a pipe, killable
// from another thread.

import "core:os"

Rg_Process :: struct {
	p:   os.Process,
	out: ^os.File,
}

rg_spawn :: proc(args: []string) -> (rp: Rg_Process, ok: bool) {
	r, w, perr := os.pipe()
	if perr != nil { return }
	p, serr := os.process_start({command = args, stdout = w})
	os.close(w)
	if serr != nil { os.close(r); return }
	return Rg_Process{p = p, out = r}, true
}

// Bytes read into buf; 0 = end of output (or killed).
rg_read :: proc(rp: ^Rg_Process, buf: []u8) -> int {
	n, err := os.read(rp.out, buf)
	if err != nil { return 0 }
	return n
}

rg_kill :: proc(rp: ^Rg_Process) { _ = os.process_kill(rp.p) }

// Reaps the process and closes the pipe.
rg_close :: proc(rp: ^Rg_Process) {
	os.close(rp.out)
	_, _ = os.process_wait(rp.p)
}
