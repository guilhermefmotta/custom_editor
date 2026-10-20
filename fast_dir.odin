package editor

// Directory listing without per-entry file access. The core:os iterator
// stats every entry (fstatat on POSIX) and on Windows even opens every file
// to read its ID — with an antivirus scanning each open, listing a big
// folder took seconds. These read only the name and type the directory
// itself returns (readdir d_type / FindFirstFileEx basic info).

import "core:strings"

Dir_Entry :: struct {
	name:   string, // allocated with the allocator passed to fast_list_dir
	is_dir: bool, // a link counts as what it points to (POSIX)
	link:   bool, // symlink / junction: walks never descend into it
}

// Folders never shown in searches nor walked by the fallback index.
WS_SKIP_DIRS :: [?]string{".git", "node_modules", "target", "__pycache__",
                          ".cache", "build", "dist", ".next", "vendor"}

ws_is_skipped_dir :: proc(name: string) -> bool {
	if len(name) > 0 && name[0] == '.' { return true }
	for s in WS_SKIP_DIRS { if name == s { return true } }
	return false
}

// Every file under `root` (relative paths, '/' separators), skipping the
// folders above. `stop` is checked between folders so a caller can cancel.
fast_walk_files :: proc(root: string, out: ^[dynamic]string, stop: ^bool = nil, allocator := context.allocator) {
	stack := make([dynamic]string, context.temp_allocator)
	append(&stack, "")
	entries := make([dynamic]Dir_Entry, context.temp_allocator)
	for len(stack) > 0 {
		if stop != nil && stop^ { return }
		rel := pop(&stack)
		dir := root if rel == "" else (rel if root == "." else strings.concatenate({root, "/", rel}, context.temp_allocator))
		clear(&entries)
		if !fast_list_dir(dir, &entries, context.temp_allocator) { continue }
		for en in entries {
			p := en.name if rel == "" else strings.concatenate({rel, "/", en.name}, context.temp_allocator)
			if en.is_dir {
				if !en.link && !ws_is_skipped_dir(en.name) { append(&stack, p) }
			} else {
				append(out, strings.clone(p, allocator))
			}
		}
	}
}
