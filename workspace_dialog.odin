package editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import rl "vendor:raylib"

// ---------------------------------------------------------------
// Types
// ---------------------------------------------------------------

WS_Entry :: struct {
	name:   string, // owned
	is_dir: bool,
}

Workspace_Dialog :: struct {
	open:        bool,
	input:       [dynamic]u8,       // full path the user is typing
	sel_all:     bool,
	entries:     [dynamic]WS_Entry, // visible directory entries
	selected:    int,
	scroll:      int,
	current_dir: string,            // owned; directory we are listing right now
	error_msg:   string,            // static string (no heap)
	workspace:   string,            // owned; currently active workspace root
	marked:      [dynamic]string,   // owned; folders picked for multi-open (ticket #13)
}

WS_MAX_VIS     :: 18
WS_MAX_ENTRIES :: 3000 // cap to prevent OOM / freeze on huge directories
WS_ITEM_H  :: f32(22)
WS_PANEL_W :: f32(640)
WS_INPUT_H :: f32(44)
WS_HEADER_H :: f32(30)
WS_FOOTER_H :: f32(28)

// ---------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------

workspace_dialog_init :: proc(d: ^Workspace_Dialog) {
	d.input   = make([dynamic]u8)
	d.entries = make([dynamic]WS_Entry)
	d.marked  = make([dynamic]string)
}

workspace_dialog_destroy :: proc(d: ^Workspace_Dialog) {
	_ws_free_entries(d)
	delete(d.entries)
	for m in d.marked { delete(m) }
	delete(d.marked)
	delete(d.input)
	if d.current_dir != "" { delete(d.current_dir) }
	if d.workspace   != "" { delete(d.workspace) }
	d^ = {}
}

workspace_dialog_open :: proc(d: ^Workspace_Dialog, start_dir := "") {
	d.open      = true
	d.selected  = 0
	d.scroll    = 0
	d.error_msg = ""
	d.sel_all   = false
	clear(&d.input)
	for m in d.marked { delete(m) }
	clear(&d.marked)

	// Pre-fill with the start folder (default: cwd) + trailing slash so the
	// listing starts immediately
	cwd, err := os.get_working_directory(context.temp_allocator)
	if start_dir != "" && os.is_dir(start_dir) { cwd, err = start_dir, nil }
	if err == nil {
		cwd = _ws_norm_seps(cwd)
		append(&d.input, cwd)
		if len(cwd) == 0 || cwd[len(cwd)-1] != '/' { append(&d.input, u8('/')) }
	} else {
		append(&d.input, u8('/'))
	}

	_ws_refresh(d)
}

workspace_dialog_close :: proc(d: ^Workspace_Dialog) {
	d.open      = false
	d.error_msg = ""
}

// Ctrl+Enter: commit a directory as the workspace root.
//
// Priority for what becomes the target:
//   1. The full typed path, if it IS a directory (user typed it fully).
//   2. current_dir (last successfully listed directory) as fallback —
//      covers the case where the user navigated via Enter keys.
workspace_dialog_confirm :: proc(d: ^Workspace_Dialog, e: ^Editor) {
	// Several folders marked (Shift+Enter / Ctrl+Space): open them all, one
	// repository tab each (ticket #13).
	if len(d.marked) > 0 {
		paths := make([]string, len(d.marked), context.temp_allocator)
		for m, i in d.marked { paths[i] = strings.clone(m, context.temp_allocator) }
		n, err := repos_open_many(e, paths)
		if n == 0 {
			d.error_msg = "Cannot open the selected folders"
			if err != "" { ui_banner_show(err, .Error, 6) }
			return
		}
		if err != "" { ui_banner_show(err, .Warning, 6) }
		e.msg = fmt.tprintf("Opened %d folder(s)", n)
		_ws_set_workspace(d, paths[0])
		workspace_dialog_close(d)
		return
	}

	// Candidate 1: what the user typed (strip trailing slash for stat)
	typed := _ws_norm_seps(string(d.input[:]))
	typed_clean := _ws_clean_for_stat(typed)

	target := ""
	if os.is_dir(typed_clean) {
		target = typed_clean
	} else if len(d.current_dir) > 0 {
		// Candidate 2: the directory we are currently listing
		cur := _ws_clean_for_stat(d.current_dir)
		if os.is_dir(cur) {
			target = cur
		}
	}

	if len(target) == 0 {
		d.error_msg = "Not a directory"
		return
	}

	// The folder becomes a repository tab (and the cwd, file tree, palette
	// and git screens follow it — repos.odin). The file list is still
	// scanned lazily by "Find File in Workspace".
	r, err := repos_open(e, target)
	if err != "" || r == nil {
		d.error_msg = "Cannot open: check permissions"
		ui_banner_show(err, .Error, 6)
		return
	}
	_ws_set_workspace(d, target)
	// Show the file tree of the new folder (now, or when the switch completes).
	if r == repos_active(e) && !e.repos.pending { file_tree_open(&e.file_tree) } else { r.tree_open = true }

	name := path_basename(target)
	if name == "" { name = target }
	e.msg = fmt.tprintf("Workspace → %s", name)

	workspace_dialog_close(d)
}

@(private="file")
_ws_set_workspace :: proc(d: ^Workspace_Dialog, path: string) {
	if d.workspace != "" { delete(d.workspace) }
	d.workspace = strings.clone(path)
}

// Shift+Enter / Ctrl+Space: mark or unmark the selected folder for
// multi-open. Returns the number of marked folders.
workspace_dialog_toggle_mark :: proc(d: ^Workspace_Dialog) -> int {
	if d.selected < 0 || d.selected >= len(d.entries) { return len(d.marked) }
	en := d.entries[d.selected]
	if !en.is_dir || en.name == ".." { d.error_msg = "Select a folder to mark"; return len(d.marked) }
	full := _ws_entry_path(d, en.name)
	for m, i in d.marked {
		if m == full { delete(m); ordered_remove(&d.marked, i); return len(d.marked) }
	}
	append(&d.marked, strings.clone(full))
	return len(d.marked)
}

@(private="file")
_ws_entry_path :: proc(d: ^Workspace_Dialog, name: string) -> string {
	dir := _ws_clean_for_stat(d.current_dir)
	if strings.has_suffix(dir, "/") { return strings.concatenate({dir, name}, context.temp_allocator) }
	return strings.concatenate({dir, "/", name}, context.temp_allocator)
}

@(private="file")
_ws_is_marked :: proc(d: ^Workspace_Dialog, name: string) -> bool {
	if len(d.marked) == 0 { return false }
	full := _ws_entry_path(d, name)
	for m in d.marked { if m == full { return true } }
	return false
}

// ---------------------------------------------------------------
// Input handler
// ---------------------------------------------------------------

workspace_dialog_handle_input :: proc(d: ^Workspace_Dialog, e: ^Editor) {
	// Escape: close
	if rl.IsKeyPressed(.ESCAPE) {
		workspace_dialog_close(d)
		return
	}

	// Shift+Enter / Ctrl+Space: mark the selected folder (multi-open)
	if (shift() && rl.IsKeyPressed(.ENTER)) || (ctrl() && rl.IsKeyPressed(.SPACE)) {
		workspace_dialog_toggle_mark(d)
		return
	}

	// Ctrl+Enter: confirm current directory as workspace
	if ctrl() && rl.IsKeyPressed(.ENTER) {
		workspace_dialog_confirm(d, e)
		return
	}

	// Enter: navigate into selected directory
	if rl.IsKeyPressed(.ENTER) {
		_ws_enter_selected(d)
		return
	}

	// Tab: autocomplete from first entry (or selected)
	if rl.IsKeyPressed(.TAB) {
		_ws_autocomplete(d)
		return
	}

	// Up/Down, PgUp/PgDn, Home/End, mouse wheel: shared list component (ui_list.odin)
	nav := Ui_List_Nav{d.selected, d.scroll}
	if ui_list_handle_nav(&nav, len(d.entries), WS_MAX_VIS, wheel_anywhere = true) {
		d.selected, d.scroll = nav.selected, nav.scroll
		return
	}

	// Ctrl+Backspace: delete back to previous path separator (must be
	// checked before text_input_handle's own Backspace below, since
	// Ctrl+Backspace also satisfies its held-repeat check).
	if ctrl() && rl.IsKeyPressed(.BACKSPACE) {
		n := len(d.input)
		if n == 0 { return }
		// Skip trailing separator
		end := n
		if end > 0 && _ws_is_sep(d.input[end-1]) { end -= 1 }
		// Walk back to previous separator
		for end > 0 && !_ws_is_sep(d.input[end-1]) { end -= 1 }
		resize(&d.input, end)
		d.selected  = 0
		d.scroll    = 0
		d.error_msg = ""
		_ws_refresh(d)
		return
	}

	if text_input_handle(&d.input, &d.sel_all, nil, _ws_backslash_to_slash) {
		d.selected  = 0
		d.scroll    = 0
		d.error_msg = ""
		_ws_refresh(d)
	}
}

// Normalize Windows-style backslashes to forward slashes as the user types.
_ws_backslash_to_slash :: proc(r: rune) -> rune { return '/' if r == '\\' else r }

// ---------------------------------------------------------------
// Navigation helpers
// ---------------------------------------------------------------

// Enter key: navigate into selected directory entry.
_ws_enter_selected :: proc(d: ^Workspace_Dialog) {
	if len(d.entries) == 0 { return }
	sel := d.selected
	if sel < 0 || sel >= len(d.entries) { return }

	entry := &d.entries[sel]

	if !entry.is_dir {
		d.error_msg = "Select a directory (not a file)"
		return
	}

	base := entry.name

	// Resolve ".." → go to parent of current_dir
	new_path: string
	if base == ".." {
		// Strip trailing separators, then walk back to previous separator
		dir := d.current_dir
		end := len(dir)
		for end > 0 && _ws_is_sep(dir[end-1]) { end -= 1 }
		dir = dir[:end]
		idx := end - 1
		for idx > 0 && !_ws_is_sep(dir[idx]) { idx -= 1 }
		if idx <= 0 {
			// Unix root or Windows drive root with no leading slash (e.g. "C:")
			when ODIN_OS == .Windows {
				if len(dir) == 2 && dir[1] == ':' {
					new_path = strings.concatenate({dir, "/"}, context.temp_allocator)
				} else {
					new_path = "/"
				}
			} else {
				new_path = "/"
			}
		} else {
			// Check if parent is a Windows drive root ("C:" after stripping)
			parent := dir[:idx]
			when ODIN_OS == .Windows {
				if len(parent) == 2 && parent[1] == ':' {
					new_path = strings.concatenate({parent, "/"}, context.temp_allocator)
				} else {
					new_path = strings.concatenate({dir[:idx+1]}, context.temp_allocator)
				}
			} else {
				new_path = strings.concatenate({dir[:idx+1]}, context.temp_allocator)
			}
		}
	} else {
		// Compose: current_dir + entry.name + "/"
		dir := d.current_dir
		if len(dir) == 0 || !_ws_is_sep(dir[len(dir)-1]) {
			new_path = strings.concatenate({dir, "/", base, "/"}, context.temp_allocator)
		} else {
			new_path = strings.concatenate({dir, base, "/"}, context.temp_allocator)
		}
	}

	// Replace input with new_path
	clear(&d.input)
	append(&d.input, new_path)

	d.selected  = 0
	d.scroll    = 0
	d.error_msg = ""
	_ws_refresh(d)
}

// Tab: complete input to the currently selected (or first) entry.
_ws_autocomplete :: proc(d: ^Workspace_Dialog) {
	if len(d.entries) == 0 { return }

	// Pick the selected entry (or first one)
	idx := d.selected
	if idx < 0 || idx >= len(d.entries) { idx = 0 }
	entry := &d.entries[idx]

	base := entry.name
	if base == ".." { _ws_enter_selected(d); return }

	dir := d.current_dir
	sep := "/" if len(dir) > 0 && !_ws_is_sep(dir[len(dir)-1]) else ""
	trail := "/" if entry.is_dir else ""
	new_path := strings.concatenate({dir, sep, base, trail}, context.temp_allocator)

	clear(&d.input)
	append(&d.input, new_path)

	d.selected  = 0
	d.scroll    = 0
	d.error_msg = ""
	_ws_refresh(d)
}

// ---------------------------------------------------------------
// Directory refresh — called after every input change
// ---------------------------------------------------------------

_ws_refresh :: proc(d: ^Workspace_Dialog) {
	path := _ws_norm_seps(string(d.input[:]))
	dir, prefix := _ws_split_path(path)

	// Free old entries
	_ws_free_entries(d)

	// Try to open the directory
	f, ferr := os.open(dir)
	if ferr != nil {
		d.error_msg = "Cannot open directory"
		return
	}
	defer os.close(f)

	it := os.read_directory_iterator_create(f)
	defer os.read_directory_iterator_destroy(&it)

	// Update tracked current_dir
	if d.current_dir != "" { delete(d.current_dir) }
	d.current_dir = strings.clone(dir)
	d.error_msg   = ""

	// Build two separate slices (dirs first, then files) for sorted display
	dirs  := make([dynamic]WS_Entry, context.temp_allocator)
	files := make([dynamic]WS_Entry, context.temp_allocator)

	capped := false
	for {
		fi, _, ok := os.read_directory_iterator(&it)
		if !ok { break }
		if len(dirs) + len(files) >= WS_MAX_ENTRIES { capped = true; break }

		name   := fi.name
		is_dir := fi.type == .Directory
		// A link to a folder is navigable like a folder
		if fi.type == .Symlink && os.is_dir(fi.fullpath) { is_dir = true }

		// Filter by prefix (case-sensitive, matches shell autocomplete behaviour)
		if len(prefix) > 0 && !strings.has_prefix(name, prefix) { continue }

		entry := WS_Entry{
			name   = strings.clone(name), // clone before iterator invalidates
			is_dir = is_dir,
		}
		if is_dir { append(&dirs, entry) } else { append(&files, entry) }
	}

	// Sort each group alphabetically (insertion sort — small N, simple)
	_ws_sort :: proc(arr: ^[dynamic]WS_Entry) {
		for i in 1..<len(arr) {
			key := arr[i]; j := i - 1
			for j >= 0 && arr[j].name > key.name { arr[j+1] = arr[j]; j -= 1 }
			arr[j+1] = key
		}
	}
	_ws_sort(&dirs)
	_ws_sort(&files)

	// ".." entry at the top — only when not at filesystem root and the user
	// isn't mid-filter (otherwise it would always win index 0 / Tab-complete
	// instead of the actual text match).
	if !_ws_is_root(dir) && len(prefix) == 0 {
		append(&d.entries, WS_Entry{ name = strings.clone(".."), is_dir = true })
	}
	for e in dirs  { append(&d.entries, e) }
	for e in files { append(&d.entries, e) }

	if capped { d.error_msg = "Directory too large (showing first 3000 entries)" }

	// Clamp selection after list changed
	if len(d.entries) == 0 {
		d.selected = 0
	} else if d.selected >= len(d.entries) {
		d.selected = len(d.entries) - 1
	}
}

// Split a path into (directory-to-list, filter-prefix).
// "/home/evil/De"  → ("/home/evil/", "De")
// "/home/evil/"   → ("/home/evil/", "")
// ""              → ("/", "")
_ws_split_path :: proc(path: string) -> (dir: string, prefix: string) {
	if len(path) == 0 { return "/", "" }

	// Ends with separator → dir IS the path, no filter
	if _ws_is_sep(path[len(path)-1]) { return path, "" }

	// Find last separator
	for i := len(path)-1; i >= 0; i -= 1 {
		if _ws_is_sep(path[i]) {
			return path[:i+1], path[i+1:]
		}
	}

	// No separator at all → relative path; list current directory
	return "./", path
}

_ws_free_entries :: proc(d: ^Workspace_Dialog) {
	for e in d.entries { delete(e.name) }
	clear(&d.entries)
}

// Accept both '/' and '\\' as path separators (Windows compat).
_ws_is_sep :: #force_inline proc(c: u8) -> bool { return c == '/' || c == '\\' }

// Replace '\\' with '/' throughout. Uses temp_allocator by default.
_ws_norm_seps :: proc(s: string, allocator := context.temp_allocator) -> string {
	out := make([]u8, len(s), allocator)
	copy(out, transmute([]u8)s)
	for i in 0..<len(out) { if out[i] == '\\' { out[i] = '/' } }
	return string(out)
}

// True when dir is a filesystem root ("/", or Windows "C:/", "D:/", etc.)
_ws_is_root :: proc(dir: string) -> bool {
	if dir == "/" { return true }
	when ODIN_OS == .Windows {
		d := strings.trim_right(dir, "/\\")
		if len(d) == 2 && d[1] == ':' { return true }
	}
	return false
}

// Strip trailing separators for use with os.is_dir / os.change_directory,
// but preserve Windows drive roots ("C:/" stays "C:/").
_ws_clean_for_stat :: proc(path: string, allocator := context.temp_allocator) -> string {
	result := strings.trim_right(path, "/\\")
	when ODIN_OS == .Windows {
		if len(result) == 2 && result[1] == ':' {
			return strings.concatenate({result, "/"}, allocator)
		}
	}
	if len(result) == 0 { return "/" }
	return result
}

// ---------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------

render_workspace_dialog :: proc(d: ^Workspace_Dialog, font: rl.Font, sw, sh: f32) {
	if !d.open { return }

	OVERLAY   :: rl.Color{0, 0, 0, 170}
	SHADOW    :: rl.Color{0, 0, 0, 90}
	PANEL_BG  := BG
	PANEL_BOR := DIVIDER_COL
	INPUT_BG  := STATUS_BG
	HEADER_BG := STATUS_BG
	SEL_BG_W  := SEL_BG
	ACCENT    := ACCENT_COL
	SUBDUED   := LINENUM
	DIR_COL   := DIAG_HINT_COL
	FILE_COL  := TEXT
	ERR_COL   := MSG_COL
	WARN_COL  := DIAG_WARN_COL

	ref := rl.MeasureTextEx(font, "M", FONT_SIZE, CHAR_SPACING)
	ch  := ref.y + LINE_SPACING

	vis_count := min(len(d.entries), WS_MAX_VIS)
	panel_h   := WS_HEADER_H + WS_INPUT_H + f32(vis_count)*WS_ITEM_H + WS_FOOTER_H

	panel_x := (sw - WS_PANEL_W) * 0.5
	panel_y := sh * 0.08

	// Clamp scroll
	max_scroll := max(0, len(d.entries) - WS_MAX_VIS)
	if d.scroll > max_scroll { d.scroll = max_scroll }
	if d.scroll < 0          { d.scroll = 0 }

	// ── Overlay ──────────────────────────────────────────────────────
	rl.DrawRectangle(0, 0, i32(sw), i32(sh), OVERLAY)

	// ── Panel (shadow + body + border) ───────────────────────────────
	panel_x, panel_y = dlg_begin(panel_x, panel_y, WS_PANEL_W, panel_h, PANEL_BG, PANEL_BOR)

	// ── Header row: title + workspace tag ────────────────────────────
	rl.DrawRectangleV({panel_x, panel_y}, {WS_PANEL_W, WS_HEADER_H}, HEADER_BG)
	rl.DrawLineV(
		{panel_x, panel_y + WS_HEADER_H - 1},
		{panel_x + WS_PANEL_W, panel_y + WS_HEADER_H - 1},
		PANEL_BOR,
	)

	rl.DrawTextEx(font, "Open Folder(s)",
		{panel_x + 12, panel_y + (WS_HEADER_H - ref.y)*0.5},
		FONT_SIZE, CHAR_SPACING, ACCENT)

	if len(d.marked) > 0 {
		ws_label := fmt.tprintf("%d folder(s) marked - Ctrl+Enter opens all", len(d.marked))
		ws_w     := rl.MeasureTextEx(font, to_cstring(ws_label), FONT_SIZE - 3, CHAR_SPACING).x
		rl.DrawTextEx(font, to_cstring(ws_label),
			{panel_x + WS_PANEL_W - ws_w - 10, panel_y + (WS_HEADER_H - ref.y + 2)*0.5},
			FONT_SIZE - 3, CHAR_SPACING, ACCENT)
	} else if d.workspace != "" {
		ws_label := fmt.tprintf("  current: %s", path_basename(d.workspace) if path_basename(d.workspace) != "" else d.workspace)
		ws_w     := rl.MeasureTextEx(font, to_cstring(ws_label), FONT_SIZE - 3, CHAR_SPACING).x
		rl.DrawTextEx(font, to_cstring(ws_label),
			{panel_x + WS_PANEL_W - ws_w - 10, panel_y + (WS_HEADER_H - ref.y + 2)*0.5},
			FONT_SIZE - 3, CHAR_SPACING, SUBDUED)
	}

	// ── Path input box ────────────────────────────────────────────────
	input_y := panel_y + WS_HEADER_H
	rl.DrawRectangleV({panel_x, input_y}, {WS_PANEL_W, WS_INPUT_H}, INPUT_BG)
	rl.DrawLineV(
		{panel_x, input_y + WS_INPUT_H - 1},
		{panel_x + WS_PANEL_W, input_y + WS_INPUT_H - 1},
		PANEL_BOR,
	)

	// "Path:" label
	label     := to_cstring("Path: ")
	label_w   := rl.MeasureTextEx(font, label, FONT_SIZE, CHAR_SPACING).x
	label_y   := input_y + (WS_INPUT_H - ref.y) * 0.5
	rl.DrawTextEx(font, label, {panel_x + 12, label_y}, FONT_SIZE, CHAR_SPACING, SUBDUED)

	// Input text — clip to panel width
	inp_s  := string(d.input[:])
	inp_x  := panel_x + 12 + label_w
	inp_w  := WS_PANEL_W - 12 - label_w - 12

	// If text is wider than the available box, only show the tail
	full_text_w := rl.MeasureTextEx(font, to_cstring(inp_s), FONT_SIZE, CHAR_SPACING).x
	display_s   := inp_s
	if full_text_w > inp_w {
		// Trim from the left until it fits
		for len(display_s) > 0 && rl.MeasureTextEx(font, to_cstring(display_s), FONT_SIZE, CHAR_SPACING).x > inp_w - 16 {
			display_s = display_s[1:]
			// Skip continuation bytes
			for len(display_s) > 0 && (display_s[0] & 0xC0) == 0x80 { display_s = display_s[1:] }
		}
	}

	rl.BeginScissorMode(i32(inp_x), i32(input_y), i32(inp_w), i32(WS_INPUT_H))
	rl.DrawTextEx(font, to_cstring(display_s), {inp_x, label_y}, FONT_SIZE, CHAR_SPACING, FILE_COL)
	rl.EndScissorMode()
	dlg_restore()

	// Beam cursor at end of text
	vis_text_w := rl.MeasureTextEx(font, to_cstring(display_s), FONT_SIZE, CHAR_SPACING).x
	rl.DrawRectangleV({inp_x + vis_text_w, label_y}, {2, ref.y}, ACCENT)

	// Error message (overlaid on right side of input row when present)
	if d.error_msg != "" {
		err_w := rl.MeasureTextEx(font, to_cstring(d.error_msg), FONT_SIZE - 2, CHAR_SPACING).x
		rl.DrawTextEx(font, to_cstring(d.error_msg),
			{panel_x + WS_PANEL_W - err_w - 10, label_y + 2},
			FONT_SIZE - 2, CHAR_SPACING, ERR_COL)
	}

	// ── Entry list ────────────────────────────────────────────────────
	list_y := input_y + WS_INPUT_H

	for vi in 0..<vis_count {
		ni := d.scroll + vi
		if ni >= len(d.entries) { break }
		entry := &d.entries[ni]

		iy := list_y + f32(vi) * WS_ITEM_H

		// Selection highlight
		if ni == d.selected {
			rl.DrawRectangleV({panel_x, iy}, {WS_PANEL_W, WS_ITEM_H}, SEL_BG_W)
			rl.DrawRectangleV({panel_x, iy}, {3, WS_ITEM_H}, ACCENT)
		}

		text_y := iy + (WS_ITEM_H - ref.y) * 0.5
		ix     := panel_x + 14

		if entry.name == ".." {
			// Parent directory arrow
			rl.DrawTextEx(font, "↑", {ix, text_y}, FONT_SIZE, CHAR_SPACING, SUBDUED)
			rl.DrawTextEx(font, to_cstring(entry.name), {ix + ref.x + 4, text_y}, FONT_SIZE - 1, CHAR_SPACING, SUBDUED)
		} else if entry.is_dir {
			if _ws_is_marked(d, entry.name) {
				rl.DrawRectangleV({panel_x + 3, iy + 3}, {5, WS_ITEM_H - 6}, ACCENT)
				rl.DrawRectangleV({panel_x, iy}, {WS_PANEL_W, WS_ITEM_H}, ui_with_alpha(ACCENT, 28))
			}
			// Folder: simple coloured square icon + "/"
			icon_sz := f32(10)
			iy_mid  := iy + (WS_ITEM_H - icon_sz)*0.5
			// Tab nub
			rl.DrawRectangleV({ix, iy_mid + 3}, {icon_sz,     icon_sz - 3}, DIR_COL)
			rl.DrawRectangleV({ix, iy_mid},     {5,           3},            DIR_COL)
			name_with_slash := fmt.tprintf("%s/", entry.name)
			rl.DrawTextEx(font, to_cstring(name_with_slash),
				{ix + icon_sz + 6, text_y}, FONT_SIZE - 1, CHAR_SPACING, DIR_COL)
		} else {
			// File: small rectangle icon
			icon_sz := f32(10)
			iy_mid  := iy + (WS_ITEM_H - icon_sz)*0.5
			rl.DrawRectangleV({ix,             iy_mid},          {icon_sz - 3, icon_sz},     LINENUM)
			rl.DrawRectangleV({ix + icon_sz - 3, iy_mid + 3},   {3,           icon_sz - 3}, LINENUM)
			rl.DrawTextEx(font, to_cstring(entry.name),
				{ix + icon_sz + 6, text_y}, FONT_SIZE - 1, CHAR_SPACING, SUBDUED)
		}

		// Selected entry full path hint on the right (right-aligned, clipped on left via scissor)
		if ni == d.selected && entry.name != ".." {
			sep := "/" if len(d.current_dir) > 0 && !_ws_is_sep(d.current_dir[len(d.current_dir)-1]) else ""
			full := fmt.tprintf("%s%s%s", d.current_dir, sep, entry.name)
			hint_w := rl.MeasureTextEx(font, to_cstring(full), FONT_SIZE - 3, CHAR_SPACING).x
			rl.DrawTextEx(font, to_cstring(full),
				{panel_x + WS_PANEL_W - hint_w - 10, text_y + 2},
				FONT_SIZE - 3, CHAR_SPACING, SUBDUED)
		}
	}

	// Scrollbar hint when list is larger than viewport
	if len(d.entries) > WS_MAX_VIS {
		bar_h_total := f32(vis_count) * WS_ITEM_H
		bar_h       := bar_h_total * f32(WS_MAX_VIS) / f32(len(d.entries))
		bar_y       := list_y + bar_h_total * f32(d.scroll) / f32(len(d.entries))
		rl.DrawRectangleV({panel_x + WS_PANEL_W - 3, bar_y}, {3, bar_h}, PANEL_BOR)
	}

	// ── Footer ───────────────────────────────────────────────────────
	footer_y := list_y + f32(vis_count)*WS_ITEM_H
	rl.DrawRectangleV({panel_x, footer_y}, {WS_PANEL_W, WS_FOOTER_H}, INPUT_BG)
	rl.DrawLineV(
		{panel_x, footer_y},
		{panel_x + WS_PANEL_W, footer_y},
		PANEL_BOR,
	)

	// Show dir count / file count
	n_dirs, n_files := 0, 0
	for e in d.entries { if e.is_dir { n_dirs += 1 } else { n_files += 1 } }
	count_str := fmt.tprintf("%d dirs  %d files", n_dirs, n_files)
	count_w   := rl.MeasureTextEx(font, to_cstring(count_str), FONT_SIZE - 3, CHAR_SPACING).x

	footer_hint := "Enter open dir  Shift+Enter mark  Tab complete  Ctrl+Enter open folder(s)  Esc"
	col := WARN_COL if d.error_msg != "" else SUBDUED
	rl.DrawTextEx(font, to_cstring(footer_hint),
		{panel_x + 10, footer_y + (WS_FOOTER_H - ref.y + 2)*0.5},
		FONT_SIZE - 3, CHAR_SPACING, col)

	rl.DrawTextEx(font, to_cstring(count_str),
		{panel_x + WS_PANEL_W - count_w - 10, footer_y + (WS_FOOTER_H - ref.y + 2)*0.5},
		FONT_SIZE - 3, CHAR_SPACING, SUBDUED)
	dlg_end()
}
