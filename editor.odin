package editor

import "core:fmt"
import "core:os"
import "core:strings"

Split_Dir :: enum { None, Vertical, Horizontal }

DIVIDER_W :: f32(1)

Save_Dialog :: struct {
	open:   bool,
	rename: bool,
	input:  [dynamic]u8,
}

Mark :: struct {
	filename: string, // heap
	line:     int,    // 1-based
	desc:     string, // heap
}

Mark_Dialog :: struct {
	open:  bool,
	input: [dynamic]u8,
}

Goto_Dialog :: struct {
	open:  bool,
	input: [dynamic]u8,
}

Find_Replace :: struct {
	open:           bool,
	search_buf:     [dynamic]u8,
	replace_buf:    [dynamic]u8,
	focus:          int,            // 0=search  1=replace
	matches:        [dynamic]int,   // sorted buffer start positions
	match_lens:     [dynamic]int,   // parallel; per-match lengths (regex can vary)
	current:        int,
	needs_scan:     bool,
	all_sel:        bool,           // Ctrl+A: next char replaces entire focused input
	case_sensitive: bool,           // Aa toggle
	whole_word:     bool,           // ab toggle
	use_regex:      bool,           // .* toggle
	show_results:   bool,           // ≡ toggle
	results_scroll: int,
	regex_err:      bool,
}

Editor :: struct {
	panes:       [dynamic]Pane,
	active:      int,
	split:       Split_Dir,
	split_ratio: f32,
	msg:         string,
	palette:     Palette,
	save_dlg:    Save_Dialog,
	file_tree:   File_Tree,
	marks:       [dynamic]Mark,
	mark_dlg:    Mark_Dialog,
	goto_dlg:    Goto_Dialog,
	find_rep:    Find_Replace,
	outline:        Outline_Dialog,
	recents:        Recents_Dialog,
	workspace_dlg:  Workspace_Dialog,
	nav_hist:       Nav_History,
	def_picker:     Goto_Def_Picker,
	delete_confirm: bool,
	should_quit:    bool,
}

editor_init :: proc() -> Editor {
	e: Editor
	e.panes           = make([dynamic]Pane)
	e.split_ratio     = 0.5
	e.marks           = make([dynamic]Mark)
	e.palette         = palette_init()
	e.save_dlg.input  = make([dynamic]u8)
	e.mark_dlg.input    = make([dynamic]u8)
	e.goto_dlg.input    = make([dynamic]u8)
	e.find_rep.search_buf  = make([dynamic]u8)
	e.find_rep.replace_buf = make([dynamic]u8)
	e.find_rep.matches     = make([dynamic]int)
	e.find_rep.match_lens  = make([dynamic]int)
	e.file_tree       = file_tree_init()
	e.outline         = outline_init()
	e.recents         = recents_init()
	workspace_dialog_init(&e.workspace_dlg)
	e.nav_hist  = nav_history_init()
	e.def_picker = goto_def_picker_init()
	append(&e.panes, pane_init())
	return e
}

editor_destroy :: proc(e: ^Editor) {
	for &p in e.panes { pane_destroy(&p) }
	delete(e.panes)
	palette_destroy(&e.palette)
	file_tree_destroy(&e.file_tree)
	for &m in e.marks { delete(m.filename); delete(m.desc) }
	delete(e.marks)
	delete(e.save_dlg.input)
	delete(e.mark_dlg.input)
	delete(e.goto_dlg.input)
	delete(e.find_rep.search_buf)
	delete(e.find_rep.replace_buf)
	delete(e.find_rep.matches)
	delete(e.find_rep.match_lens)
	outline_destroy(&e.outline)
	recents_destroy(&e.recents)
	workspace_dialog_destroy(&e.workspace_dlg)
	nav_history_destroy(&e.nav_hist)
	goto_def_picker_destroy(&e.def_picker)
	e^ = {}
}

active_pane :: proc(e: ^Editor) -> ^Pane {
	return &e.panes[e.active]
}

editor_open :: proc(e: ^Editor, path: string) -> bool {
	if !pane_open(active_pane(e), path) { return false }
	recents_push(&e.recents, path)
	return true
}

editor_save :: proc(e: ^Editor) -> bool {
	p := active_pane(e)
	if p.filename == "" {
		save_dialog_open(e)
		return false
	}
	ok, msg := pane_save(p)
	e.msg = msg
	return ok
}

editor_split :: proc(e: ^Editor, dir: Split_Dir) {
	if len(e.panes) >= 2 { e.msg = "Max 2 panes"; return }
	np  := pane_init()
	cur := active_pane(e)
	if cur.filename != "" do pane_open(&np, cur.filename)
	append(&e.panes, np)
	e.split       = dir
	e.split_ratio = 0.5
	e.active      = 1
}

editor_close_split :: proc(e: ^Editor) {
	if len(e.panes) <= 1 { e.msg = "Single pane"; return }
	pane_destroy(&e.panes[e.active])
	ordered_remove(&e.panes, e.active)
	if e.active >= len(e.panes) { e.active = len(e.panes) - 1 }
	if len(e.panes) == 1 { e.split = .None }
}

// ---- Save As dialog ----

save_dialog_open :: proc(e: ^Editor) {
	e.save_dlg.open   = true
	e.save_dlg.rename = false
	clear(&e.save_dlg.input)
	s := "untitled.txt"
	for i in 0 ..< len(s) { append(&e.save_dlg.input, s[i]) }
}

save_dialog_close :: proc(e: ^Editor) {
	e.save_dlg.open   = false
	e.save_dlg.rename = false
	clear(&e.save_dlg.input)
}

save_dialog_confirm :: proc(e: ^Editor) {
	name := string(e.save_dlg.input[:])
	if len(name) == 0 { save_dialog_close(e); return }
	p := active_pane(e)
	if e.save_dlg.rename {
		old := p.filename
		err := os.rename(old, name)
		if err != nil { e.msg = "Rename failed"; save_dialog_close(e); return }
		recents_remove(&e.recents, old)
		delete(p.filename)
		p.filename = strings.clone(name)
		p.lang     = detect_lang(name)
		recents_push(&e.recents, name)
		e.msg = fmt.tprintf("Renamed to %s", path_basename(name))
	} else {
		if p.filename != "" { delete(p.filename) }
		p.filename = strings.clone(name)
		p.lang     = detect_lang(name)
		ok, msg   := pane_save(p)
		e.msg      = msg
		if ok { recents_push(&e.recents, name) }
	}
	save_dialog_close(e)
}

rename_file_open :: proc(e: ^Editor) {
	p := active_pane(e)
	if p.filename == "" { e.msg = "No filename - Save As first"; return }
	clear(&e.save_dlg.input)
	for i in 0..<len(p.filename) { append(&e.save_dlg.input, p.filename[i]) }
	e.save_dlg.rename = true
	e.save_dlg.open   = true
}

delete_file_open :: proc(e: ^Editor) {
	p := active_pane(e)
	if p.filename == "" { e.msg = "No file to delete"; return }
	e.delete_confirm = true
}

delete_file_confirm :: proc(e: ^Editor) {
	p := active_pane(e)
	if p.filename == "" { e.delete_confirm = false; return }
	err := os.remove(p.filename)
	if err != nil {
		e.msg = "Delete failed"
		e.delete_confirm = false
		return
	}
	e.msg = fmt.tprintf("Deleted %s", path_basename(p.filename))
	recents_remove(&e.recents, p.filename)
	delete(p.filename)
	p.filename = ""
	buffer_destroy(&p.buf)
	p.buf         = buffer_init()
	p.cursor      = 0
	p.sel_anchor  = 0
	p.scroll      = 0
	p.scroll_anim = 0
	for &op in p.undo { delete(op.data) }
	clear(&p.undo)
	p.u_merge = 0
	p.dirty   = false
	mc_clear(p)
	e.delete_confirm = false
}

// ---- Mark dialog ----

mark_dialog_open :: proc(e: ^Editor) {
	ap := active_pane(e)
	line, _ := buffer_pos_to_line_col(&ap.buf, ap.cursor)
	ls := buffer_line_start(&ap.buf, line)
	ll := buffer_line_length(&ap.buf, line)

	clear(&e.mark_dlg.input)
	// Pre-fill with current line content (strip leading whitespace)
	start := ls
	for start < ls + ll {
		b := buffer_get_byte(&ap.buf, start)
		if b != ' ' && b != '\t' { break }
		start += 1
	}
	for i in start ..< ls + ll { append(&e.mark_dlg.input, buffer_get_byte(&ap.buf, i)) }
	e.mark_dlg.open = true
}

mark_dialog_close :: proc(e: ^Editor) {
	e.mark_dlg.open = false
	clear(&e.mark_dlg.input)
}

mark_dialog_confirm :: proc(e: ^Editor) {
	desc := strings.clone(string(e.mark_dlg.input[:]))
	ap   := active_pane(e)
	line, _ := buffer_pos_to_line_col(&ap.buf, ap.cursor)
	m := Mark{
		filename = strings.clone(ap.filename),
		line     = line + 1,
		desc     = desc,
	}
	append(&e.marks, m)
	e.msg = fmt.tprintf("Marked line %d", m.line)
	mark_dialog_close(e)
}

// ---- Goto Line dialog ----

goto_dialog_open :: proc(e: ^Editor) {
	clear(&e.goto_dlg.input)
	e.goto_dlg.open = true
}

goto_dialog_close :: proc(e: ^Editor) {
	e.goto_dlg.open = false
	clear(&e.goto_dlg.input)
}

goto_dialog_confirm :: proc(e: ^Editor) {
	n := 0
	for b in e.goto_dlg.input { if b >= '0' && b <= '9' { n = n*10 + int(b - '0') } }
	if n < 1 { goto_dialog_close(e); return }

	ap    := active_pane(e)
	total := buffer_line_count(&ap.buf)
	target := min(n - 1, total - 1)
	ls := buffer_line_start(&ap.buf, target)
	ap.cursor     = ls
	ap.sel_anchor = ls
	ap.scroll     = max(0, target - 10)
	ap.scroll_anim = f32(ap.scroll)
	e.msg = fmt.tprintf("Line %d", target + 1)
	goto_dialog_close(e)
}

// ---- Pane rect ----

get_pane_rect :: proc(e: ^Editor, idx: int, sw, sh: f32) -> (x, y, w, h: f32) {
	if len(e.panes) <= 1 || e.split == .None { return 0, 0, sw, sh }
	switch e.split {
	case .Vertical:
		mid := sw * e.split_ratio
		if idx == 0 { return 0, 0, mid - DIVIDER_W * 0.5, sh }
		return mid + DIVIDER_W * 0.5, 0, sw - mid - DIVIDER_W * 0.5, sh
	case .Horizontal:
		mid := sh * e.split_ratio
		if idx == 0 { return 0, 0, sw, mid - DIVIDER_W * 0.5 }
		return 0, mid + DIVIDER_W * 0.5, sw, sh - mid - DIVIDER_W * 0.5
	case .None:
	}
	return 0, 0, sw, sh
}
