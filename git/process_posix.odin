#+build linux, darwin
package git

import "core:strings"
import "core:sys/posix"

@(private)
_exec :: proc(root: string, args: []string, allocator := context.allocator) -> (output: string, exit_code: int) {
	sb: strings.Builder
	strings.builder_init(&sb, context.temp_allocator)
	strings.write_string(&sb, "git -C ")
	strings.write_quoted_string(&sb, root)
	for a in args {
		strings.write_byte(&sb, ' ')
		strings.write_quoted_string(&sb, a)
	}
	strings.write_string(&sb, " 2>/dev/null")

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
