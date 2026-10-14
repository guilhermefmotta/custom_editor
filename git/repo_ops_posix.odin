#+build linux, darwin
package git

import "core:strings"
import "core:sys/posix"

// Like _remote_exec (env + `git -C root args 2>&1 </dev/null`), but hands
// every chunk read to `on_chunk` as it arrives so a long clone can report
// progress. Worker-side only.
@(private)
_repo_exec_stream :: proc(root: string, args: []string, env: [][2]string, on_chunk: proc(user: rawptr, chunk: []u8), user: rawptr, allocator := context.allocator) -> (output: string, exit_code: int) {
	sb: strings.Builder
	strings.builder_init(&sb, context.temp_allocator)
	for kv in env {
		strings.write_string(&sb, kv[0])
		strings.write_byte(&sb, '=')
		_sh_quote(&sb, kv[1])
		strings.write_byte(&sb, ' ')
	}
	strings.write_string(&sb, "git -C ")
	_sh_quote(&sb, root)
	for a in args {
		strings.write_byte(&sb, ' ')
		_sh_quote(&sb, a)
	}
	strings.write_string(&sb, " 2>&1 </dev/null")

	cmd_c := strings.clone_to_cstring(strings.to_string(sb), context.temp_allocator)
	fp := posix.popen(cmd_c, "r")
	if fp == nil { return "", 1 }

	buf := make([dynamic]u8, allocator)
	tmp: [1024]u8
	for {
		// read() on the pipe returns as soon as git writes a progress update
		n := posix.read(posix.fileno(fp), raw_data(tmp[:]), len(tmp))
		if n <= 0 { break }
		append(&buf, ..tmp[:n])
		if on_chunk != nil { on_chunk(user, tmp[:n]) }
	}
	rc := posix.pclose(fp)
	return string(buf[:]), int((u32(rc) >> 8) & 0xFF)
}
