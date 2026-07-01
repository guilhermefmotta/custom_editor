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

Pane :: struct {
	buf:              Gap_Buffer,
	cursor:           int,
	sel_anchor:       int,
	scroll:           int,
	scroll_anim:      f32,
	filename:         string,
	lang:             Lang,
	dirty:            bool,
	undo:             [dynamic]Undo_Op,
	u_merge:          int,
	extras:           [dynamic]Extra_Cursor,
	lsp:              Pane_LSP,
	suggest:          Suggest_Widget,
	show_line_numbers: bool,
}

MAX_UNDO :: 500

pane_init :: proc() -> Pane {
	p: Pane
	p.buf               = buffer_init()
	p.undo              = make([dynamic]Undo_Op)
	p.extras            = make([dynamic]Extra_Cursor)
	p.show_line_numbers = true
	return p
}

pane_destroy :: proc(p: ^Pane) {
	buffer_destroy(&p.buf)
	if p.filename != "" do delete(p.filename)
	for &op in p.undo { delete(op.data) }
	delete(p.undo)
	delete(p.extras)
	pane_lsp_destroy(&p.lsp)
	p^ = {}
}

pane_open :: proc(p: ^Pane, path: string) -> bool {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return false
	defer delete(data)
	buffer_destroy(&p.buf)
	p.buf = buffer_init()
	buffer_insert_string(&p.buf, 0, string(data))
	p.cursor      = 0
	p.sel_anchor  = 0
	p.scroll      = 0
	p.scroll_anim = 0
	clear(&p.extras)
	if p.filename != "" do delete(p.filename)
	p.filename = _pane_abs(path) // always store absolute path so LSP URIs are correct
	p.lang     = detect_lang(path)
	p.dirty    = false
	// Clear undo history on file open
	for &op in p.undo { delete(op.data) }
	clear(&p.undo)
	p.u_merge = 0
	return true
}

pane_save :: proc(p: ^Pane) -> (ok: bool, msg: string) {
	if p.filename == "" { return false, "No filename" }
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
