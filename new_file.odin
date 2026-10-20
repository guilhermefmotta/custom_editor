package editor

// New files and folders by name: Ctrl/Cmd+N asks for the path first and
// creates the file right away (no "untitled" buffer that asks again on
// save), and the file tree uses the same rules. A name ending in "/" is a
// folder; missing parent folders are created ("src/util/str.odin" works).

import "core:os"
import "core:path/filepath"
import "core:strings"

New_Path_Result :: enum {
	Created_File,
	Created_Dir,
	Exists,  // a file with that name was already there (just open it)
	Invalid, // empty name, or a folder that already exists
	Failed,
}

new_path_is_dir :: proc(name: string) -> bool {
	return strings.has_suffix(name, "/") || strings.has_suffix(name, "\\")
}

// Creates `path` (a file, or a folder when it ends in a separator), with its
// parent folders. An existing file is left untouched.
create_new_path :: proc(path: string) -> New_Path_Result {
	ws_index_invalidate() // searches pick the new entry up
	name := strings.trim_space(path)
	if name == "" { return .Invalid }
	if new_path_is_dir(name) {
		dir := strings.trim_right(name, "/\\")
		if dir == "" || os.exists(dir) { return .Invalid }
		return .Created_Dir if os.make_directory_all(dir) == nil else .Failed
	}
	if os.is_dir(name) { return .Invalid }
	if os.exists(name) { return .Exists }
	if parent := filepath.dir(name); parent != "" && parent != "." && !os.exists(parent) {
		if os.make_directory_all(parent) != nil { return .Failed }
	}
	return .Created_File if os.write_entire_file(name, []u8{}) == nil else .Failed
}

// Prefill for the New File prompt: the folder of the current file relative
// to the workspace ("src/"), or "" at the root / for files outside it.
new_file_prefill :: proc(current, cwd: string, allocator := context.temp_allocator) -> string {
	if current == "" || cwd == "" { return "" }
	dir := filepath.dir(current)
	rel, err := filepath.rel(cwd, dir, context.temp_allocator)
	if err != nil || rel == "." || strings.has_prefix(rel, "..") || filepath.is_abs(rel) { return "" }
	rel, _ = strings.replace_all(rel, "\\", "/", context.temp_allocator)
	return strings.concatenate({rel, "/"}, allocator)
}
