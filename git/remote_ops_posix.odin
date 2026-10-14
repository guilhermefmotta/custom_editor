#+build linux, darwin
package git

import "core:strings"
import "core:sys/posix"

// `VAR='v' ... git -C root args 2>&1 </dev/null` through popen: stderr is
// captured with stdout and git never sees a terminal on stdin.
@(private)
_remote_exec :: proc(root: string, args: []string, env: [][2]string, allocator := context.allocator) -> (output: string, exit_code: int) {
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
	tmp: [8192]u8
	for {
		n := posix.fread(raw_data(tmp[:]), 1, len(tmp), fp)
		if n <= 0 { break }
		append(&buf, ..tmp[:n])
	}
	rc := posix.pclose(fp)
	return string(buf[:]), int((u32(rc) >> 8) & 0xFF)
}
