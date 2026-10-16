package editor

import "core:os"
import "core:strings"

// Return heap-allocated absolute version of path.
_pane_abs :: proc(path: string) -> string {
	if len(path) > 0 && path[0] == '/' { return strings.clone(path) }
	cwd, err := os.get_working_directory(context.temp_allocator)
	if err != nil || len(cwd) == 0 { return strings.clone(path) }
	if path == "." { return strings.clone(cwd) }
	return strings.concatenate({cwd, "/", path})
}

Undo_Op :: struct {
	insert:   bool,    // true = was insert; false = was delete
	compound: bool,    // true = this op is part of the same compound group as the previous op
	pos:      int,
	data:     [dynamic]u8,
}

Pane_Tab :: struct {
	filename: string, // heap-owned absolute path
	cursor:   int,
	scroll:   int,
	dirty:    bool,
}

Pane :: struct {
	buf:               Gap_Buffer,
	cursor:            int,
	sel_anchor:        int,
	scroll:            int,
	scroll_anim:       f32,
	filename:          string,
	lang:              Lang,
	dirty:             bool,
	undo:              [dynamic]Undo_Op,
	redo:              [dynamic]Undo_Op,
	u_merge:           int,
	extras:            [dynamic]Extra_Cursor,
	lsp:               Pane_LSP,
	suggest:           Suggest_Widget,
	show_line_numbers: bool,
	word_wrap:         bool,
	// Tab management
	tabs:              [dynamic]Pane_Tab,
	cur_tab:           int,
	md_preview:        Md_Preview,
	image:             Image_View, // image file: shown as a picture (image_view.odin)
}

MAX_UNDO :: 500

pane_init :: proc() -> Pane {
	p: Pane
	p.buf               = buffer_init()
	p.undo              = make([dynamic]Undo_Op)
	p.redo              = make([dynamic]Undo_Op)
	p.extras            = make([dynamic]Extra_Cursor)
	p.tabs              = make([dynamic]Pane_Tab)
	p.show_line_numbers = true
	return p
}

pane_destroy :: proc(p: ^Pane) {
	buffer_destroy(&p.buf)
	if p.filename != "" do delete(p.filename)
	for &op in p.undo { delete(op.data) }
	delete(p.undo)
	for &op in p.redo { delete(op.data) }
	delete(p.redo)
	delete(p.extras)
	for &t in p.tabs { if t.filename != "" { delete(t.filename) } }
	delete(p.tabs)
	pane_lsp_destroy(&p.lsp)
	md_preview_destroy(&p.md_preview)
	p^ = {}
}

// Save current buffer state into the current tab slot.
_pane_save_tab_state :: proc(p: ^Pane) {
	if p.cur_tab < 0 || p.cur_tab >= len(p.tabs) { return }
	t := &p.tabs[p.cur_tab]
	if t.filename != "" { delete(t.filename) }
	t.filename = strings.clone(p.filename)
	t.cursor   = p.cursor
	t.scroll   = p.scroll
	t.dirty    = p.dirty
}

// Open a file as a new tab (or switch to existing tab for that file).
pane_open_tab :: proc(p: ^Pane, path: string) -> bool {
	abs_path := _pane_abs(path)
	defer delete(abs_path)

	// Check if already open in a tab
	for i in 0..<len(p.tabs) {
		if p.tabs[i].filename == abs_path {
			_pane_save_tab_state(p)
			p.cur_tab = i
			_pane_load_tab(p, i)
			return true
		}
	}

	// Save current state before switching
	if len(p.tabs) > 0 { _pane_save_tab_state(p) }

	// Open file into buffer
	if !pane_open(p, path) { return false }

	// Add new tab
	new_tab := Pane_Tab{
		filename = strings.clone(p.filename),
		cursor   = 0,
		scroll   = 0,
		dirty    = false,
	}
	// Insert after current tab
	insert_at := p.cur_tab + 1
	if len(p.tabs) == 0 { insert_at = 0 }
	if insert_at > len(p.tabs) { insert_at = len(p.tabs) }
	inject_at(&p.tabs, insert_at, new_tab)
	p.cur_tab = insert_at
	return true
}

// Load tab i into the buffer (switch to it).
_pane_load_tab :: proc(p: ^Pane, i: int) {
	if i < 0 || i >= len(p.tabs) { return }
	t := &p.tabs[i]
	if t.filename == "" { return }
	if !pane_open(p, t.filename) { return }
	blen := buffer_len(&p.buf)
	p.cursor     = clamp(t.cursor, 0, blen)
	p.sel_anchor = p.cursor
	p.scroll     = t.scroll
	p.scroll_anim = f32(p.scroll)
}

// Close current tab; switch to adjacent tab. Returns false if no more tabs.
pane_close_tab :: proc(p: ^Pane) -> bool {
	n := len(p.tabs)
	if n <= 1 {
		// Last tab: clear pane
		if n == 1 {
			if p.tabs[0].filename != "" { delete(p.tabs[0].filename) }
			ordered_remove(&p.tabs, 0)
		}
		buffer_destroy(&p.buf)
		p.buf = buffer_init()
		if p.filename != "" { delete(p.filename); p.filename = "" }
		p.cursor = 0; p.sel_anchor = 0; p.scroll = 0; p.scroll_anim = 0
		p.dirty = false
		p.cur_tab = 0
		return false
	}
	if p.tabs[p.cur_tab].filename != "" { delete(p.tabs[p.cur_tab].filename) }
	ordered_remove(&p.tabs, p.cur_tab)
	if p.cur_tab >= len(p.tabs) { p.cur_tab = len(p.tabs) - 1 }
	_pane_load_tab(p, p.cur_tab)
	return true
}

pane_tab_next :: proc(p: ^Pane) {
	if len(p.tabs) <= 1 { return }
	_pane_save_tab_state(p)
	p.cur_tab = (p.cur_tab + 1) % len(p.tabs)
	_pane_load_tab(p, p.cur_tab)
}

pane_tab_prev :: proc(p: ^Pane) {
	if len(p.tabs) <= 1 { return }
	_pane_save_tab_state(p)
	n := len(p.tabs)
	p.cur_tab = (p.cur_tab + n - 1) % n
	_pane_load_tab(p, p.cur_tab)
}

pane_open :: proc(p: ^Pane, path: string) -> bool {
	if is_image_file(path) { return _pane_open_image(p, path) }
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return false
	defer delete(data)
	buffer_destroy(&p.buf)
	p.buf = buffer_init()
	// Strip \r so CRLF files display correctly
	clean, _ := strings.replace_all(string(data), "\r", "", context.temp_allocator)
	buffer_insert_string(&p.buf, 0, clean)
	p.cursor      = 0
	p.sel_anchor  = 0
	p.scroll      = 0
	p.scroll_anim = 0
	clear(&p.extras)
	if p.filename != "" do delete(p.filename)
	p.filename = _pane_abs(path) // always store absolute path so LSP URIs are correct
	p.lang     = detect_lang(path)
	p.dirty    = false
	md_preview_destroy(&p.md_preview) // stale preview from the previous file must not bleed through
	p.image = {}
	// Clear undo/redo history on file open
	for &op in p.undo { delete(op.data) }
	clear(&p.undo)
	for &op in p.redo { delete(op.data) }
	clear(&p.redo)
	p.u_merge = 0
	return true
}

// Image files: the buffer stays empty (never written back — see pane_save)
// and the pane shows the picture.
@(private="file")
_pane_open_image :: proc(p: ^Pane, path: string) -> bool {
	if !os.exists(path) || os.is_dir(path) { return false }
	buffer_destroy(&p.buf)
	p.buf = buffer_init()
	p.cursor, p.sel_anchor, p.scroll, p.scroll_anim = 0, 0, 0, 0
	clear(&p.extras)
	if p.filename != "" do delete(p.filename)
	p.filename = _pane_abs(path)
	p.lang     = detect_lang(path)
	p.dirty    = false
	md_preview_destroy(&p.md_preview)
	for &op in p.undo { delete(op.data) }
	clear(&p.undo)
	for &op in p.redo { delete(op.data) }
	clear(&p.redo)
	p.u_merge = 0
	image_view_open(p)
	return true
}

pane_save :: proc(p: ^Pane) -> (ok: bool, msg: string) {
	if p.filename == "" { return false, "No filename" }
	if p.image.active { return false, "Images are read-only" } // the buffer is empty: never overwrite the file
	text := buffer_to_string(&p.buf)
	defer delete(text)
	err := os.write_entire_file(p.filename, transmute([]byte)text)
	if err == nil { p.dirty = false; return true, "Saved" }
	return false, "Save failed"
}

// Raw selection helpers — callers wanting undo must use undo_delete_sel
has_selection    :: proc(p: ^Pane) -> bool { return p.sel_anchor != p.cursor }
sel_lo           :: proc(p: ^Pane) -> int  { return min(p.sel_anchor, p.cursor) }
sel_hi           :: proc(p: ^Pane) -> int  { return max(p.sel_anchor, p.cursor) }

delete_selection :: proc(p: ^Pane) -> bool {
	if !has_selection(p) do return false
	lo := sel_lo(p); hi := sel_hi(p)
	buffer_delete(&p.buf, lo, hi - lo)
	p.cursor     = lo
	p.sel_anchor = lo
	p.dirty      = true
	return true
}
