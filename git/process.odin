package git

import "core:fmt"
import "core:strings"
import "core:sys/posix"
import "core:c"

// git_run_raw returns heap-owned stdout AND exit code regardless of success.
// Caller must always delete(output).
git_run_raw :: proc(root: string, args: []string, allocator := context.allocator) -> (output: string, exit_code: int) {
	return _exec(root, args, allocator)
}

// git_run executes `git -C root <args>` and returns heap-owned stdout.
// ok=false on non-zero exit. Caller must delete(output) when ok=true.
git_run :: proc(root: string, args: []string, allocator := context.allocator) -> (output: string, ok: bool) {
	out, code := _exec(root, args, allocator)
	if code != 0 { delete(out, allocator); return "", false }
	return out, true
}

@(private)
_exec :: proc(root: string, args: []string, allocator := context.allocator) -> (output: string, exit_code: int) {
	// Build shell command: git -C "<root>" arg1 arg2 ...
	sb: strings.Builder
	strings.builder_init(&sb, context.temp_allocator)
	strings.write_string(&sb, "git -C ")
	strings.write_quoted_string(&sb, root)
	for a in args {
		strings.write_byte(&sb, ' ')
		strings.write_quoted_string(&sb, a)
	}
	// Suppress stderr across all platforms
	strings.write_string(&sb, " 2>")
	when ODIN_OS == .Windows {
		strings.write_string(&sb, "nul")
	} else {
		strings.write_string(&sb, "/dev/null")
	}

	cmd := strings.to_string(sb)
	cmd_c := strings.clone_to_cstring(cmd, context.temp_allocator)

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
	// pclose returns wait status on POSIX; extract actual exit code
	code := int(rc)
	when ODIN_OS != .Windows {
		code = int((u32(rc) >> 8) & 0xFF)
	}
	return string(buf[:]), code
}
