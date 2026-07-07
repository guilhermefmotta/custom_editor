package config

import "core:fmt"
import "core:os"
import "core:strings"

// config_persist_keymap_mode: patch (or insert) `keymap_mode = "..."` inside the
// [editor] section of editor.toml, preserving everything else in the file
// byte-for-byte. There is no general TOML writer in this codebase — this is a
// narrow, targeted line patch, not a round-trip serializer, so it can't corrupt
// comments/formatting elsewhere in a hand-authored file. Best-effort: a write
// failure never blocks the in-memory mode switch, the caller decides how (or
// whether) to surface it.
config_persist_keymap_mode :: proc(path: string, mode: Keymap_Mode) -> bool {
	value: string
	switch mode {
	case .Normal: value = "normal"
	case .Vim:    value = "vim"
	case .Emacs:  value = "emacs"
	}
	new_line := fmt.tprintf("keymap_mode          = \"%s\" # normal | vim | emacs", value)

	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil || len(data) == 0 {
		content := fmt.tprintf("[editor]\n%s\n", new_line)
		return os.write_entire_file(path, transmute([]byte)content) == nil
	}

	lines := strings.split(string(data), "\n", context.temp_allocator)
	out := make([dynamic]string, 0, len(lines)+1, context.temp_allocator)

	in_editor := false
	found     := false
	for line in lines {
		trimmed := strings.trim_space(line)
		is_header := strings.has_prefix(trimmed, "[")
		if in_editor && is_header && !found {
			// leaving [editor] without seeing the key — insert just before this header
			append(&out, new_line)
			found = true
		}
		in_editor = trimmed == "[editor]" || (in_editor && !is_header)
		if in_editor && !found && strings.has_prefix(trimmed, "keymap_mode") && strings.contains(trimmed, "=") {
			append(&out, new_line)
			found = true
			continue
		}
		append(&out, line)
	}
	if in_editor && !found {
		// [editor] ran to end of file without a closing section
		append(&out, new_line)
		found = true
	}
	if !found {
		// no [editor] section at all — append one
		if len(out) > 0 && strings.trim_space(out[len(out)-1]) != "" { append(&out, "") }
		append(&out, "[editor]")
		append(&out, new_line)
	}

	joined := strings.join(out[:], "\n", context.temp_allocator)
	if !strings.has_suffix(joined, "\n") {
		joined = strings.concatenate({joined, "\n"}, context.temp_allocator)
	}
	return os.write_entire_file(path, transmute([]byte)joined) == nil
}
