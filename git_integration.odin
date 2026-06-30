package editor

import "core:fmt"
import "core:os"
import git "./git"
import rl "vendor:raylib"

// ---------------------------------------------------------------------------
// Git gutter mark colors (defined here, shared with renderer)
// ---------------------------------------------------------------------------

GIT_ADDED    :: rl.Color{166, 227, 161, 255} // Catppuccin green
GIT_MODIFIED :: rl.Color{250, 179, 135, 255} // Catppuccin peach
GIT_DELETED  :: rl.Color{243, 139, 168, 255} // Catppuccin red

// ---------------------------------------------------------------------------
// Init — find git root and start manager (call after editor_lsp_init)
// ---------------------------------------------------------------------------

editor_git_init :: proc(e: ^Editor) {
	root := _git_find_root(e)
	if root == "" { return }
	git.git_manager_init(&e.git_mgr, root)
}

_git_find_root :: proc(e: ^Editor) -> string {
	cwd, cwd_err := os.get_working_directory(context.temp_allocator)
	if cwd_err != nil { cwd = "." }
	p := active_pane(e)
	start := cwd
	if p.filename != "" { start = _path_dirname(p.filename) }
	dir := start
	for dir != "" && dir != "/" {
		if _file_exists(fmt.tprintf("%s/.git", dir)) { return dir }
		parent := _path_dirname(dir)
		if parent == dir || parent == "" { break }
		dir = parent
	}
	// Also check cwd
	if _file_exists(fmt.tprintf("%s/.git", cwd)) { return cwd }
	return ""
}

// ---------------------------------------------------------------------------
// git_update — call once per frame from main thread
// ---------------------------------------------------------------------------

git_update :: proc(e: ^Editor, dt: f32) {
	if e.git_mgr.root == "" { return }
	git.git_manager_update(&e.git_mgr, dt)
}

// ---------------------------------------------------------------------------
// Draw gutter mark for one line (called from renderer)
// ---------------------------------------------------------------------------

git_draw_line_mark :: proc(e: ^Editor, filename: string, line_1based: int, ox: f32, y: f32, ch: f32) {
	if e.git_mgr.root == "" { return }
	hunks, has := e.git_mgr.current.hunks[filename]
	if !has { return }
	for h in hunks {
		switch h.kind {
		case .Added, .Modified:
			if line_1based >= h.new_start && line_1based < h.new_start + h.new_count {
				col := GIT_ADDED if h.kind == .Added else GIT_MODIFIED
				rl.DrawRectangleV({ox, y}, {3, ch}, col)
				return
			}
		case .Deleted:
			// Show deletion mark as thin bar at bottom of the line just before deletion
			if line_1based == h.new_start || (h.new_start == 0 && line_1based == 1) {
				rl.DrawRectangleV({ox, y + ch - 3}, {3, 3}, GIT_DELETED)
				return
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Palette command handler
// ---------------------------------------------------------------------------

cmd_git_panel :: proc(e: ^Editor, p: ^Palette) {
	if e.git_mgr.root == "" {
		e.msg = "No git repository found"
		return
	}
	palette_close(p)
	git_dialog_open(&e.git_dialog)
}
