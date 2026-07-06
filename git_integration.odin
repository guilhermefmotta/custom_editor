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

cmd_git_blame_toggle :: proc(e: ^Editor, p: ^Palette) {
	if e.git_mgr.root == "" {
		e.msg = "No git repository found"
		return
	}
	e.blame_enabled = !e.blame_enabled
	palette_close(p)
	e.msg = "Git Blame: on" if e.blame_enabled else "Git Blame: off"
}

// ---------------------------------------------------------------------------
// Blame gutter (date + author, left of line numbers, toggled via palette)
// ---------------------------------------------------------------------------

BLAME_GUTTER_CHARS :: 22 // "23/08/2017 " (11) + author name (up to 11)
BLAME_ZERO_HASH     :: "0000000000000000000000000000000000000000"

// git_blame_gutter_width returns the extra gutter width (0 when disabled)
// that render_pane must add before the line-number column.
git_blame_gutter_width :: proc(e: ^Editor, cw: f32) -> f32 {
	if !e.blame_enabled { return 0 }
	return f32(BLAME_GUTTER_CHARS)*cw + GUTTER_PAD*2
}

// git_draw_blame_gutter draws date + author for line li (0-based) at the
// left edge of the gutter (ox), but only on the first line of a run of
// consecutive lines that share the same commit — repeats render blank so
// the annotation reads as one block per commit, not noise per line.
git_draw_blame_gutter :: proc(e: ^Editor, filename: string, li: int, ox: f32, y: f32, ch: f32, font: rl.Font) {
	if !e.blame_enabled || filename == "" { return }
	lines := git.git_blame_get(&e.git_mgr, filename)
	if li < 0 || li >= len(lines) { return }
	bl := lines[li]
	if bl.author == "" { return } // no blame info for this line (e.g. binary/empty file)

	is_new_block := li == 0 || lines[li-1].hash != bl.hash
	if !is_new_block { return }

	uncommitted := bl.hash == BLAME_ZERO_HASH
	label: string
	col: rl.Color
	if uncommitted {
		label = "uncommitted"
		col = rl.Color{250, 179, 135, 200} // Catppuccin peach
	} else {
		name := bl.author
		if len(name) > 11 { name = name[:11] }
		label = fmt.tprintf("%s %s", bl.date, name)
		col = rl.Color{147, 153, 178, 255} // Catppuccin subtext0
	}
	ref := rl.MeasureTextEx(font, "M", FONT_SIZE, CHAR_SPACING)
	rl.DrawTextEx(font, to_cstring(label), {ox + GUTTER_PAD, y + (ch - ref.y)*0.5}, FONT_SIZE, CHAR_SPACING, col)
}
