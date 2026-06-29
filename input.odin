package editor

import "core:fmt"
import re "core:text/regex"
import rl "vendor:raylib"

ctrl  :: proc() -> bool { return rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL) }
shift :: proc() -> bool { return rl.IsKeyDown(.LEFT_SHIFT)   || rl.IsKeyDown(.RIGHT_SHIFT) }
alt   :: proc() -> bool { return rl.IsKeyDown(.LEFT_ALT)     || rl.IsKeyDown(.RIGHT_ALT) }

// --- Key repeat ---
_rep_key:  rl.KeyboardKey = .KEY_NULL
_rep_accum: f32 = 0
_rep_init: bool = false

REP_DELAY :: f32(0.380)
REP_RATE  :: f32(0.040)

key_rep :: proc(key: rl.KeyboardKey) -> bool {
	if rl.IsKeyPressed(key) {
		_rep_key   = key
		_rep_accum = 0
		_rep_init  = false
		return true
	}
	if _rep_key == key {
		if !rl.IsKeyDown(key) { _rep_key = .KEY_NULL; return false }
		_rep_accum += rl.GetFrameTime()
		if !_rep_init {
			if _rep_accum < REP_DELAY { return false }
			_rep_init = true; _rep_accum = 0; return true
		}
		if _rep_accum >= REP_RATE { _rep_accum = 0; return true }
	}
	return false
}

// --- Top-level dispatcher ---

handle_input :: proc(e: ^Editor, font: rl.Font) {
	// Priority: delete_confirm > lsp_dialog > recents > workspace_dlg > save_dlg > file_tree > outline > find_rep > mark_dlg > goto_dlg > palette > normal
	if e.delete_confirm       { delete_confirm_handle_input(e); return }
	if e.lsp_dialog.visible   { lsp_dialog_handle_input(&e.lsp_dialog, e); return }
	if e.recents.open         { recents_handle_input(&e.recents, e); return }
	if e.workspace_dlg.open   { workspace_dialog_handle_input(&e.workspace_dlg, e); return }
	if e.save_dlg.open        { save_dialog_handle_input(e); return }
	if e.file_tree.open       { file_tree_handle_input(&e.file_tree, e); return }
	if e.outline.open    { outline_handle_input(&e.outline, active_pane(e)); return }
	if e.find_rep.open  { find_replace_handle_input(e); return }
	if e.mark_dlg.open  { mark_dialog_handle_input(e); return }
	if e.goto_dlg.open   { goto_dialog_handle_input(e); return }
	if e.def_picker.open { goto_def_picker_handle_input(e); return }

	if e.palette.open {
		palette_handle_input(&e.palette, e)
		return
	}

	if ctrl() && rl.IsKeyPressed(.P) {
		palette_open(&e.palette)
		return
	}

	// LSP manual completion
	if ctrl() && rl.IsKeyPressed(.SPACE) {
		lsp_trigger_completion_manual(e, active_pane(e))
		return
	}

	// Suggest widget intercepts keys when visible
	if active_pane(e).suggest.visible {
		if suggest_handle_input(e, active_pane(e)) { return }
	}

	// Go to Definition / Find References / Navigation history
	if rl.IsKeyPressed(.F12)                     { lsp_goto_definition(e, active_pane(e)); return }
	if ctrl() && rl.IsKeyPressed(.I)             { goto_refs_do(e); return }
	if ctrl() && rl.IsKeyPressed(.LEFT_BRACKET)  { nav_go_back(&e.nav_hist, e); return }
	if ctrl() && rl.IsKeyPressed(.RIGHT_BRACKET) { nav_go_forward(&e.nav_hist, e); return }

	// Ctrl+; open file tree
	if ctrl() && rl.IsKeyPressed(.SEMICOLON) {
		file_tree_open(&e.file_tree)
		return
	}

	// Ctrl+L open LSP control dialog
	if ctrl() && rl.IsKeyPressed(.L) {
		lsp_dialog_open(&e.lsp_dialog)
		return
	}

	// Ctrl+Shift+O: open workspace dialog
	if ctrl() && shift() && rl.IsKeyPressed(.O) {
		workspace_dialog_open(&e.workspace_dlg)
		return
	}

	// Ctrl+O cycle active pane
	if ctrl() && rl.IsKeyPressed(.O) {
		if len(e.panes) > 1 { e.active = (e.active + 1) % len(e.panes) }
		return
	}

	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight()) - MSG_LINE_H

	// Mouse click: switch active pane / position cursor / alt+click adds extra cursor
	if rl.IsMouseButtonPressed(.LEFT) {
		mp := rl.GetMousePosition()
		clicked := -1
		for i in 0 ..< len(e.panes) {
			px2, py2, pw2, ph2 := get_pane_rect(e, i, sw, sh)
			if mp.x >= px2 && mp.x < px2+pw2 && mp.y >= py2 && mp.y < py2+ph2 { clicked = i; break }
		}
		if clicked >= 0 {
			if alt() && clicked == e.active {
				// Alt+click: add extra cursor, keep primary
				px2, py2, _, _ := get_pane_rect(e, e.active, sw, sh)
				mc_add(active_pane(e), mouse_to_cursor(active_pane(e), font, mp, px2, py2))
			} else {
				e.active = clicked
				ap       := active_pane(e)
				mc_clear(ap)
				px2, py2, _, _ := get_pane_rect(e, e.active, sw, sh)
				pos        := mouse_to_cursor(ap, font, mp, px2, py2)
				ap.cursor   = pos
				ap.sel_anchor = pos
			}
		}
	}
	if rl.IsMouseButtonDown(.LEFT) && !rl.IsMouseButtonPressed(.LEFT) {
		p            := active_pane(e)
		px, py, _, _ := get_pane_rect(e, e.active, sw, sh)
		p.cursor      = mouse_to_cursor(p, font, rl.GetMousePosition(), px, py)
	}

	p := active_pane(e)

	// Alt combos — multi-cursor add, word jump, line move
	// Alt+Down/Up:       add cursor (plain Alt only; Ctrl+Alt does nothing)
	// Alt+Right/Left:    word jump/select on all cursors
	// Shift+Alt+Down/Up: move lines
	if alt() {
		s := shift()
		if !s {
			// Only plain Alt adds cursors; Ctrl+Alt is consumed so it won't fall through.
			if key_rep(.DOWN)  { if !ctrl() { mc_add_below(p) };                          return }
			if key_rep(.UP)    { if !ctrl() { mc_add_above(p) };                          return }
			if key_rep(.RIGHT) { if mc_has_extras(p) { mc_word_right_all(p, false) } else { move_word_right(p, false) }; return }
			if key_rep(.LEFT)  { if mc_has_extras(p) { mc_word_left_all(p,  false) } else { move_word_left(p,  false) }; return }
		} else if !ctrl() {
			// Shift+Alt: move lines / word-select
			if key_rep(.DOWN)  { do_move_lines_down(p); lsp_on_text_changed(e, p); return }
			if key_rep(.UP)    { do_move_lines_up(p);   lsp_on_text_changed(e, p); return }
			if key_rep(.RIGHT) { if mc_has_extras(p) { mc_word_right_all(p, true) } else { move_word_right(p, true) }; return }
			if key_rep(.LEFT)  { if mc_has_extras(p) { mc_word_left_all(p,  true) } else { move_word_left(p,  true) }; return }
		}
	}

	// Escape collapses multi-cursor to primary
	if rl.IsKeyPressed(.ESCAPE) && mc_has_extras(p) { mc_clear(p); return }

	if ctrl() {
		if rl.IsKeyPressed(.S) { editor_save(e); lsp_on_save(e, active_pane(e)); return }
		if rl.IsKeyPressed(.Z) { pane_undo(p); lsp_on_text_changed(e, p); return }
		if rl.IsKeyPressed(.D) { do_kill_line(p); lsp_on_text_changed(e, p); return }
		if rl.IsKeyPressed(.A) { mc_clear(p); sel_all(p); return }
		if rl.IsKeyPressed(.C) { copy_sel(p);              return }
		if rl.IsKeyPressed(.X) { cut_sel(p); lsp_on_text_changed(e, p); return }
		if rl.IsKeyPressed(.V) { paste(p); lsp_on_text_changed(e, p); return }
		if rl.IsKeyPressed(.F) { find_replace_open(e); return }
		if rl.IsKeyPressed(.TAB) { recents_open(&e.recents); return }
		if rl.IsKeyPressed(.Q)   { e.should_quit = true; return }
		if rl.IsKeyPressed(.SLASH) { do_comment_toggle(p); lsp_on_text_changed(e, p); return }
		if rl.IsKeyPressed(.EQUAL) { FONT_SIZE = clamp(FONT_SIZE + 2, 8, 72); return }
		if rl.IsKeyPressed(.MINUS) { FONT_SIZE = clamp(FONT_SIZE - 2, 8, 72); return }
		if key_rep(.LEFT)      { mc_clear(p); move_word_left(p,  shift()); return }
		if key_rep(.RIGHT)     { mc_clear(p); move_word_right(p, shift()); return }
		if rl.IsKeyPressed(.HOME) { mc_clear(p); move_doc_start(p, shift()); return }
		if rl.IsKeyPressed(.END)  { mc_clear(p); move_doc_end(p,   shift()); return }
	}

	cursor_before := p.cursor
	if key_rep(.LEFT)      { if mc_has_extras(p) { mc_move_all_left(p,  shift()) } else { move_left(p,  shift()) } }
	if key_rep(.RIGHT)     { if mc_has_extras(p) { mc_move_all_right(p, shift()) } else { move_right(p, shift()) } }
	if key_rep(.UP) {
		if ctrl() { for _ in 0..<10 { move_up(p, shift()) } } else if mc_has_extras(p) { mc_move_all_up(p, shift()) } else { move_up(p, shift()) }
	}
	if key_rep(.DOWN) {
		if ctrl() { for _ in 0..<10 { move_down(p, shift()) } } else if mc_has_extras(p) { mc_move_all_down(p, shift()) } else { move_down(p, shift()) }
	}
	if key_rep(.HOME)      { mc_clear(p); move_bol(p,   shift()) }
	if key_rep(.END)       { mc_clear(p); move_eol(p,   shift()) }
	if key_rep(.PAGE_UP)   { mc_clear(p); move_page(p, -1, shift()) }
	if key_rep(.PAGE_DOWN) { mc_clear(p); move_page(p,  1, shift()) }

	text_changed := false

	if key_rep(.BACKSPACE) {
		if mc_has_extras(p) { mc_backspace(p) } else { do_backspace(p) }
		text_changed = true
	}
	if key_rep(.DELETE) {
		if mc_has_extras(p) { mc_delete_fwd(p) } else { do_delete(p) }
		text_changed = true
	}

	if rl.IsKeyPressed(.ENTER) {
		if mc_has_extras(p) {
			mc_insert_bytes(p, []u8{'\n'})
		} else {
			undo_delete_sel(p)
			undo_push_insert(p, p.cursor, []u8{'\n'}, false)
			undo_break(p)
			buffer_insert_byte(&p.buf, p.cursor, '\n')
			p.cursor     += 1
			p.sel_anchor  = p.cursor
			p.dirty       = true
		}
		text_changed = true
	}

	if rl.IsKeyPressed(.TAB) {
		if mc_has_extras(p) {
			if shift() { mc_backspace(p) } else { mc_insert_bytes(p, []u8{' ',' ',' ',' '}) }
			text_changed = true
		} else if has_selection(p) {
			if shift() { do_dedent_sel(p) } else { do_indent_sel(p) }
			text_changed = true
		} else if shift() {
			do_dedent_line(p)
			text_changed = true
		} else {
			spaces := []u8{' ', ' ', ' ', ' '}
			undo_push_insert(p, p.cursor, spaces, false)
			undo_break(p)
			for _ in 0 ..< 4 {
				buffer_insert_byte(&p.buf, p.cursor, ' ')
				p.cursor += 1
			}
			p.sel_anchor = p.cursor
			p.dirty      = true
			text_changed = true
		}
	}

	// Printable chars — coalesced inserts for single Ctrl+Z to undo a word
	for {
		ch := rl.GetCharPressed()
		if ch == 0 do break
		if ch < 32 do continue
		utf_buf: [4]u8
		n := rune_encode(ch, &utf_buf)
		if mc_has_extras(p) {
			mc_insert_bytes(p, utf_buf[:n])
		} else {
			undo_delete_sel(p)
			undo_push_insert(p, p.cursor, utf_buf[:n], true)
			for i in 0 ..< n { buffer_insert_byte(&p.buf, p.cursor + i, utf_buf[i]) }
			p.cursor     += n
			p.sel_anchor  = p.cursor
			p.dirty       = true
		}
		text_changed = true
	}

	if p.cursor != cursor_before { lsp_on_cursor_moved(e, p) }
	if text_changed { lsp_on_text_changed(e, p) }
}

// --- Delete confirm ---

delete_confirm_handle_input :: proc(e: ^Editor) {
	if rl.IsKeyPressed(.ESCAPE) || rl.IsKeyPressed(.N) { e.delete_confirm = false; return }
	if rl.IsKeyPressed(.Y)                              { delete_file_confirm(e); return }
}

// --- Save dialog ---

save_dialog_handle_input :: proc(e: ^Editor) {
	dlg := &e.save_dlg
	if rl.IsKeyPressed(.ESCAPE) { save_dialog_close(e); return }
	if rl.IsKeyPressed(.ENTER)  { save_dialog_confirm(e); return }
	if key_rep(.BACKSPACE) && len(dlg.input) > 0 { pop(&dlg.input); return }
	for {
		ch := rl.GetCharPressed()
		if ch == 0 do break
		if ch >= 32 && ch < 128 { append(&dlg.input, u8(ch)) }
	}
}

mark_dialog_handle_input :: proc(e: ^Editor) {
	if rl.IsKeyPressed(.ESCAPE) { mark_dialog_close(e); return }
	if rl.IsKeyPressed(.ENTER)  { mark_dialog_confirm(e); return }
	if key_rep(.BACKSPACE) && len(e.mark_dlg.input) > 0 { pop(&e.mark_dlg.input) }
	for {
		ch := rl.GetCharPressed()
		if ch == 0 { break }
		if ch >= 32 { append(&e.mark_dlg.input, u8(ch)) }
	}
}

goto_dialog_handle_input :: proc(e: ^Editor) {
	if rl.IsKeyPressed(.ESCAPE) { goto_dialog_close(e); return }
	if rl.IsKeyPressed(.ENTER)  { goto_dialog_confirm(e); return }
	if key_rep(.BACKSPACE) && len(e.goto_dlg.input) > 0 { pop(&e.goto_dlg.input) }
	for {
		ch := rl.GetCharPressed()
		if ch == 0 { break }
		if ch >= '0' && ch <= '9' { append(&e.goto_dlg.input, u8(ch)) }
	}
}

// --- Cursor movement (all take ^Pane) ---

move_left :: proc(p: ^Pane, selecting: bool) {
	if !selecting && has_selection(p) {
		v := sel_lo(p); p.cursor = v; p.sel_anchor = v
		return
	}
	if p.cursor > 0 {
		p.cursor -= 1
		for p.cursor > 0 && (buffer_get_byte(&p.buf, p.cursor) & 0xC0) == 0x80 {
			p.cursor -= 1
		}
	}
	if !selecting do p.sel_anchor = p.cursor
}

move_right :: proc(p: ^Pane, selecting: bool) {
	if !selecting && has_selection(p) {
		v := sel_hi(p); p.cursor = v; p.sel_anchor = v
		return
	}
	n := buffer_len(&p.buf)
	if p.cursor < n {
		p.cursor += 1
		for p.cursor < n && (buffer_get_byte(&p.buf, p.cursor) & 0xC0) == 0x80 {
			p.cursor += 1
		}
	}
	if !selecting do p.sel_anchor = p.cursor
}

move_up :: proc(p: ^Pane, selecting: bool) {
	line, col := buffer_pos_to_line_col(&p.buf, p.cursor)
	if line == 0 {
		p.cursor = 0
	} else {
		start    := buffer_line_start(&p.buf, line - 1)
		p.cursor  = start + min(col, buffer_line_length(&p.buf, line - 1))
	}
	if !selecting do p.sel_anchor = p.cursor
}

move_down :: proc(p: ^Pane, selecting: bool) {
	line, col := buffer_pos_to_line_col(&p.buf, p.cursor)
	total     := buffer_line_count(&p.buf)
	if line < total - 1 {
		start    := buffer_line_start(&p.buf, line + 1)
		p.cursor  = start + min(col, buffer_line_length(&p.buf, line + 1))
	} else {
		p.cursor = buffer_len(&p.buf)
	}
	if !selecting do p.sel_anchor = p.cursor
}

move_bol :: proc(p: ^Pane, selecting: bool) {
	line, _ := buffer_pos_to_line_col(&p.buf, p.cursor)
	p.cursor = buffer_line_start(&p.buf, line)
	if !selecting do p.sel_anchor = p.cursor
}

move_eol :: proc(p: ^Pane, selecting: bool) {
	line, _ := buffer_pos_to_line_col(&p.buf, p.cursor)
	p.cursor = buffer_line_start(&p.buf, line) + buffer_line_length(&p.buf, line)
	if !selecting do p.sel_anchor = p.cursor
}

move_doc_start :: proc(p: ^Pane, selecting: bool) {
	p.cursor = 0
	if !selecting do p.sel_anchor = 0
}

move_doc_end :: proc(p: ^Pane, selecting: bool) {
	p.cursor = buffer_len(&p.buf)
	if !selecting do p.sel_anchor = p.cursor
}

move_word_left :: proc(p: ^Pane, selecting: bool) {
	if p.cursor > 0 {
		p.cursor -= 1
		for p.cursor > 0 && !is_word(buffer_get_byte(&p.buf, p.cursor)) { p.cursor -= 1 }
		for p.cursor > 0 &&  is_word(buffer_get_byte(&p.buf, p.cursor - 1)) { p.cursor -= 1 }
	}
	if !selecting do p.sel_anchor = p.cursor
}

move_word_right :: proc(p: ^Pane, selecting: bool) {
	n := buffer_len(&p.buf)
	for p.cursor < n &&  is_word(buffer_get_byte(&p.buf, p.cursor)) { p.cursor += 1 }
	for p.cursor < n && !is_word(buffer_get_byte(&p.buf, p.cursor)) { p.cursor += 1 }
	if !selecting do p.sel_anchor = p.cursor
}

move_page :: proc(p: ^Pane, dir: int, selecting: bool) {
	for _ in 0 ..< 20 {
		if dir < 0 { move_up(p, true) } else { move_down(p, true) }
	}
	if !selecting do p.sel_anchor = p.cursor
}

sel_all :: proc(p: ^Pane) {
	p.sel_anchor = 0
	p.cursor     = buffer_len(&p.buf)
}

// --- Edit actions ---

do_backspace :: proc(p: ^Pane) {
	if undo_delete_sel(p) do return
	if p.cursor <= 0 do return
	move_left(p, false)
	// Properly handle multi-byte UTF-8
	first  := buffer_get_byte(&p.buf, p.cursor)
	nbytes := utf8_lead_len(first)
	del    := make([]u8, nbytes, context.temp_allocator)
	for i in 0 ..< nbytes { del[i] = buffer_get_byte(&p.buf, p.cursor + i) }
	undo_push_delete(p, p.cursor, del, true)
	buffer_delete(&p.buf, p.cursor, nbytes)
	p.sel_anchor = p.cursor
	p.dirty      = true
}

do_delete :: proc(p: ^Pane) {
	if undo_delete_sel(p) do return
	n := buffer_len(&p.buf)
	if p.cursor >= n do return
	first  := buffer_get_byte(&p.buf, p.cursor)
	nbytes := utf8_lead_len(first)
	del    := make([]u8, nbytes, context.temp_allocator)
	for i in 0 ..< nbytes { del[i] = buffer_get_byte(&p.buf, p.cursor + i) }
	undo_push_delete(p, p.cursor, del, false)
	buffer_delete(&p.buf, p.cursor, nbytes)
	p.dirty = true
}

copy_sel :: proc(p: ^Pane) {
	if !has_selection(p) do return
	lo  := sel_lo(p); hi := sel_hi(p)
	buf := make([]u8, hi - lo, context.temp_allocator)
	for i in 0 ..< hi - lo { buf[i] = buffer_get_byte(&p.buf, lo + i) }
	rl.SetClipboardText(to_cstring(string(buf)))
}

cut_sel :: proc(p: ^Pane) {
	if !has_selection(p) do return
	copy_sel(p)
	undo_delete_sel(p)
}

paste :: proc(p: ^Pane) {
	raw := rl.GetClipboardText()
	if raw == nil do return
	s := string(raw)
	if len(s) == 0 do return
	undo_delete_sel(p)
	undo_push_insert(p, p.cursor, transmute([]u8)s, false)
	undo_break(p)
	buffer_insert_string(&p.buf, p.cursor, s)
	p.cursor     += len(s)
	p.sel_anchor  = p.cursor
	p.dirty       = true
}

// Ctrl+D: delete entire current line (including newline)
do_kill_line :: proc(p: ^Pane) {
	line, _  := buffer_pos_to_line_col(&p.buf, p.cursor)
	ls       := buffer_line_start(&p.buf, line)
	ll       := buffer_line_length(&p.buf, line)
	total    := buffer_line_count(&p.buf)
	del_len  := ll + 1 if line < total - 1 else ll
	if del_len == 0 do return
	del := make([]u8, del_len, context.temp_allocator)
	for i in 0 ..< del_len { del[i] = buffer_get_byte(&p.buf, ls + i) }
	undo_push_delete(p, ls, del, false)
	undo_break(p)
	buffer_delete(&p.buf, ls, del_len)
	p.cursor     = ls
	p.sel_anchor = ls
	p.dirty      = true
}

// Alt+Down: move current line (or selection) one line down.
do_move_lines_down :: proc(p: ^Pane) {
	total := buffer_line_count(&p.buf)
	line, _ := buffer_pos_to_line_col(&p.buf, p.cursor)

	L1, L2 := line, line
	if has_selection(p) {
		l1, _  := buffer_pos_to_line_col(&p.buf, sel_lo(p))
		l2, c2 := buffer_pos_to_line_col(&p.buf, sel_hi(p))
		L1 = l1; L2 = l2 if c2 > 0 else max(l1, l2 - 1)
	}
	if L2 >= total - 1 { return }

	// block = lines L1..L2 including their trailing \n (L2 < total-1 guaranteed)
	block_start := buffer_line_start(&p.buf, L1)
	block_end   := buffer_line_start(&p.buf, L2 + 1) // start of L2+1 = after L2's \n

	// below = line L2+1 content (may or may not have trailing \n)
	below_start  := block_end
	below_text_len := buffer_line_length(&p.buf, L2 + 1)
	buf_len      := buffer_len(&p.buf)
	below_end    := below_start + below_text_len
	below_has_nl := below_end < buf_len && buffer_get_byte(&p.buf, below_end) == '\n'
	if below_has_nl { below_end += 1 }

	range_len  := below_end - block_start
	orig       := make([]u8, range_len, context.temp_allocator)
	for i in 0..<range_len { orig[i] = buffer_get_byte(&p.buf, block_start + i) }

	block_part := orig[:block_end - block_start] // always ends with \n
	below_part := orig[block_end - block_start:] // may or may not end with \n

	// Swap: below_part + block_part (add \n separator if below has none)
	new_len   := range_len + (0 if below_has_nl else 1)
	new_bytes := make([]u8, new_len, context.temp_allocator)
	if below_has_nl {
		copy(new_bytes,                   below_part)
		copy(new_bytes[len(below_part):], block_part)
	} else {
		copy(new_bytes,                       below_part)
		new_bytes[len(below_part)] = '\n'
		copy(new_bytes[len(below_part) + 1:], block_part)
	}

	cursor_off   := p.cursor - block_start
	below_stride := len(below_part) + (0 if below_has_nl else 1)

	undo_push_delete(p, block_start, orig, false)
	undo_break(p)
	buffer_delete(&p.buf, block_start, range_len)
	undo_push_insert(p, block_start, new_bytes, false)
	undo_break(p)
	buffer_insert_string(&p.buf, block_start, string(new_bytes))

	p.cursor     = block_start + below_stride + cursor_off
	p.sel_anchor = p.cursor
	p.dirty      = true
}

// Alt+Up: move current line (or selection) one line up.
do_move_lines_up :: proc(p: ^Pane) {
	total := buffer_line_count(&p.buf)
	line, _ := buffer_pos_to_line_col(&p.buf, p.cursor)

	L1, L2 := line, line
	if has_selection(p) {
		l1, _  := buffer_pos_to_line_col(&p.buf, sel_lo(p))
		l2, c2 := buffer_pos_to_line_col(&p.buf, sel_hi(p))
		L1 = l1; L2 = l2 if c2 > 0 else max(l1, l2 - 1)
	}
	if L1 == 0 { return }

	// above = line L1-1 including its trailing \n (L1-1 < total-1 since L1 >= 1)
	above_start := buffer_line_start(&p.buf, L1 - 1)
	block_start := buffer_line_start(&p.buf, L1)     // = above_start + len(above) + 1
	above_len   := block_start - above_start          // includes the \n

	// block = lines L1..L2 (may or may not have trailing \n)
	block_text_end := buffer_line_start(&p.buf, L2) + buffer_line_length(&p.buf, L2)
	buf_len        := buffer_len(&p.buf)
	block_end      := block_text_end
	block_has_nl   := block_end < buf_len && buffer_get_byte(&p.buf, block_end) == '\n'
	if block_has_nl { block_end += 1 }

	range_len := block_end - above_start
	orig      := make([]u8, range_len, context.temp_allocator)
	for i in 0..<range_len { orig[i] = buffer_get_byte(&p.buf, above_start + i) }

	above_part := orig[:above_len]          // ends with \n
	block_part := orig[above_len:]          // may or may not end with \n

	// Swap: block_part + above_part (add \n after block if block has none)
	new_len   := range_len + (0 if block_has_nl else 1)
	new_bytes := make([]u8, new_len, context.temp_allocator)
	if block_has_nl {
		copy(new_bytes,                   block_part)
		copy(new_bytes[len(block_part):], above_part)
	} else {
		copy(new_bytes,                       block_part)
		new_bytes[len(block_part)] = '\n'
		copy(new_bytes[len(block_part) + 1:], above_part)
	}

	cursor_off := p.cursor - block_start

	undo_push_delete(p, above_start, orig, false)
	undo_break(p)
	buffer_delete(&p.buf, above_start, range_len)
	undo_push_insert(p, above_start, new_bytes, false)
	undo_break(p)
	buffer_insert_string(&p.buf, above_start, string(new_bytes))

	p.cursor     = above_start + cursor_off
	p.sel_anchor = p.cursor
	p.dirty      = true
	_ = total
}

// Convert screen position to buffer cursor; ox/oy = pane's screen origin.
mouse_to_cursor :: proc(p: ^Pane, font: rl.Font, mp: rl.Vector2, ox, oy: f32) -> int {
	ref    := rl.MeasureTextEx(font, "M", FONT_SIZE, CHAR_SPACING)
	cw     := ref.x
	ch     := ref.y + LINE_SPACING
	digs   := digit_count(buffer_line_count(&p.buf))
	text_x := f32(digs)*cw + GUTTER_PAD*2

	local_x := mp.x - ox
	local_y := mp.y - oy - PANE_TOP_PAD

	line := int(local_y / ch) + p.scroll
	col  := int((local_x - text_x) / cw)
	if col < 0 do col = 0

	total := buffer_line_count(&p.buf)
	line   = clamp(line, 0, total - 1)

	start := buffer_line_start(&p.buf, line)
	return start + min(col, buffer_line_length(&p.buf, line))
}

// --- Helpers ---

utf8_lead_len :: proc(b: u8) -> int {
	if b & 0x80 == 0 { return 1 }
	if b & 0xE0 == 0xC0 { return 2 }
	if b & 0xF0 == 0xE0 { return 3 }
	return 4
}

is_word :: proc(ch: u8) -> bool {
	return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
	       (ch >= '0' && ch <= '9') || ch == '_'
}

rune_encode :: proc(r: rune, buf: ^[4]u8) -> int {
	switch {
	case r < 0x80:
		buf[0] = u8(r)
		return 1
	case r < 0x800:
		buf[0] = u8(0xC0 | (r >> 6))
		buf[1] = u8(0x80 | (r & 0x3F))
		return 2
	case r < 0x10000:
		buf[0] = u8(0xE0 | (r >> 12))
		buf[1] = u8(0x80 | ((r >> 6) & 0x3F))
		buf[2] = u8(0x80 | (r & 0x3F))
		return 3
	case:
		buf[0] = u8(0xF0 | (r >> 18))
		buf[1] = u8(0x80 | ((r >> 12) & 0x3F))
		buf[2] = u8(0x80 | ((r >> 6) & 0x3F))
		buf[3] = u8(0x80 | (r & 0x3F))
		return 4
	}
}

// --- Indent / dedent ---

do_indent_sel :: proc(p: ^Pane) {
	lo_line, _ := buffer_pos_to_line_col(&p.buf, sel_lo(p))
	hi         := sel_hi(p)
	hi_line, hi_col := buffer_pos_to_line_col(&p.buf, hi)
	end_line := hi_line if hi_col > 0 else (max(lo_line, hi_line - 1))

	for li := end_line; li >= lo_line; li -= 1 {
		pos := buffer_line_start(&p.buf, li)
		for i in 0 ..< 4 { buffer_insert_byte(&p.buf, pos + i, ' ') }
		if p.cursor     > pos { p.cursor     += 4 }
		if p.sel_anchor > pos { p.sel_anchor += 4 }
	}
	p.dirty = true
}

do_dedent_sel :: proc(p: ^Pane) {
	lo_line, _ := buffer_pos_to_line_col(&p.buf, sel_lo(p))
	hi         := sel_hi(p)
	hi_line, hi_col := buffer_pos_to_line_col(&p.buf, hi)
	end_line := hi_line if hi_col > 0 else (max(lo_line, hi_line - 1))

	for li := end_line; li >= lo_line; li -= 1 {
		pos := buffer_line_start(&p.buf, li)
		n   := 0
		for n < 4 && pos + n < buffer_len(&p.buf) && buffer_get_byte(&p.buf, pos + n) == ' ' {
			n += 1
		}
		if n == 0 { continue }
		buffer_delete(&p.buf, pos, n)
		if p.cursor > pos + n         { p.cursor     -= n }
		else if p.cursor > pos        { p.cursor      = pos }
		if p.sel_anchor > pos + n     { p.sel_anchor -= n }
		else if p.sel_anchor > pos    { p.sel_anchor  = pos }
	}
	p.dirty = true
}

do_dedent_line :: proc(p: ^Pane) {
	line, _ := buffer_pos_to_line_col(&p.buf, p.cursor)
	pos     := buffer_line_start(&p.buf, line)
	n := 0
	for n < 4 && pos + n < buffer_len(&p.buf) && buffer_get_byte(&p.buf, pos + n) == ' ' {
		n += 1
	}
	if n == 0 { return }
	buffer_delete(&p.buf, pos, n)
	if p.cursor > pos + n { p.cursor -= n } else if p.cursor > pos { p.cursor = pos }
	p.sel_anchor = p.cursor
	p.dirty = true
}

// --- Find / Replace ---

find_replace_open :: proc(e: ^Editor) {
	fr := &e.find_rep
	fr.open    = true
	fr.focus   = 0
	fr.current = 0
	fr.all_sel = false
	clear(&fr.replace_buf)
	clear(&fr.matches)

	p := active_pane(e)
	if has_selection(p) {
		// Pre-fill search with selected text
		lo := sel_lo(p)
		hi := sel_hi(p)
		clear(&fr.search_buf)
		for i in lo ..< hi { append(&fr.search_buf, buffer_get_byte(&p.buf, i)) }
		fr.needs_scan = true
		find_replace_scan(fr, p)
		if len(fr.matches) > 0 { find_replace_jump(fr, p) }
	} else {
		clear(&fr.search_buf)
		fr.needs_scan = false
	}
}

find_replace_close :: proc(e: ^Editor) {
	e.find_rep.open = false
}

_fr_word_char :: #force_inline proc(b: u8) -> bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') || b == '_'
}

find_replace_scan :: proc(fr: ^Find_Replace, p: ^Pane) {
	clear(&fr.matches)
	clear(&fr.match_lens)
	fr.needs_scan = false
	fr.regex_err  = false
	if len(fr.search_buf) == 0 { return }

	n    := buffer_len(&p.buf)
	qlen := len(fr.search_buf)
	q    := fr.search_buf[:]

	if fr.use_regex {
		tmp := make([]u8, n, context.temp_allocator)
		for i in 0..<n { tmp[i] = buffer_get_byte(&p.buf, i) }

		flags: re.Flags = {}
		if !fr.case_sensitive { flags |= {.Case_Insensitive} }

		it, err := re.create_iterator(string(tmp), string(q), flags,
		                              context.temp_allocator, context.temp_allocator)
		if err != nil { fr.regex_err = true; return }

		for {
			capture, _, ok := re.match_iterator(&it)
			if !ok { break }
			if len(capture.pos) == 0 { continue }
			start := capture.pos[0][0]
			end   := capture.pos[0][1]
			if fr.whole_word {
				before := tmp[start - 1] if start > 0 else u8(0)
				after  := tmp[end]       if end < n   else u8(0)
				if _fr_word_char(before) || _fr_word_char(after) { continue }
			}
			append(&fr.matches,    start)
			append(&fr.match_lens, end - start)
		}
	} else {
		for i := 0; i <= n - qlen; i += 1 {
			ok := true
			for j := 0; j < qlen; j += 1 {
				bj := buffer_get_byte(&p.buf, i + j)
				qj := q[j]
				if !fr.case_sensitive {
					if bj >= 'A' && bj <= 'Z' { bj |= 32 }
					if qj >= 'A' && qj <= 'Z' { qj |= 32 }
				}
				if bj != qj { ok = false; break }
			}
			if !ok { continue }
			if fr.whole_word {
				before := buffer_get_byte(&p.buf, i - 1)    if i > 0          else u8(0)
				after  := buffer_get_byte(&p.buf, i + qlen) if i + qlen < n   else u8(0)
				if _fr_word_char(before) || _fr_word_char(after) { continue }
			}
			append(&fr.matches,    i)
			append(&fr.match_lens, qlen)
		}
	}

	if len(fr.matches) == 0 { fr.current = 0 }
	else                     { fr.current = clamp(fr.current, 0, len(fr.matches) - 1) }
}

find_replace_jump :: proc(fr: ^Find_Replace, p: ^Pane) {
	if len(fr.matches) == 0 { return }
	pos          := fr.matches[fr.current]
	mlen         := fr.match_lens[fr.current]
	p.cursor      = pos + mlen
	p.sel_anchor  = pos
	line, _      := buffer_pos_to_line_col(&p.buf, pos)
	p.scroll      = max(0, line - 5)
	p.scroll_anim = f32(p.scroll)
	if fr.current < fr.results_scroll { fr.results_scroll = fr.current }
	if fr.current >= fr.results_scroll + 8 { fr.results_scroll = fr.current - 7 }
}

find_replace_handle_input :: proc(e: ^Editor) {
	fr := &e.find_rep
	p  := active_pane(e)

	if rl.IsKeyPressed(.ESCAPE) { find_replace_close(e); return }

	// Toggle mode (Alt+key) — work in both focus modes
	if alt() && !ctrl() {
		if rl.IsKeyPressed(.C) { fr.case_sensitive = !fr.case_sensitive; fr.needs_scan = true; return }
		if rl.IsKeyPressed(.W) { fr.whole_word     = !fr.whole_word;     fr.needs_scan = true; return }
		if rl.IsKeyPressed(.R) { fr.use_regex      = !fr.use_regex;      fr.needs_scan = true; return }
		if rl.IsKeyPressed(.L) { fr.show_results   = !fr.show_results;                         return }
	}

	if rl.IsKeyPressed(.TAB) { fr.focus = 1 - fr.focus; fr.all_sel = false; return }

	// Ctrl+A — select all in focused input
	if ctrl() && rl.IsKeyPressed(.A) { fr.all_sel = true; return }

	if fr.focus == 0 {
		if rl.IsKeyPressed(.DOWN) || rl.IsKeyPressed(.ENTER) {
			if fr.needs_scan { find_replace_scan(fr, p) }
			if len(fr.matches) > 0 {
				fr.current = (fr.current + 1) % len(fr.matches)
				find_replace_jump(fr, p)
			}
			return
		}
		if rl.IsKeyPressed(.UP) {
			if fr.needs_scan { find_replace_scan(fr, p) }
			if len(fr.matches) > 0 {
				fr.current = (fr.current - 1 + len(fr.matches)) % len(fr.matches)
				find_replace_jump(fr, p)
			}
			return
		}
	}

	if fr.focus == 1 && rl.IsKeyPressed(.ENTER) && !ctrl() {
		find_replace_do_replace(e)
		return
	}
	if ctrl() && rl.IsKeyPressed(.ENTER) {
		find_replace_replace_all(e)
		return
	}

	if key_rep(.BACKSPACE) {
		if fr.all_sel {
			// Clear entire input
			if fr.focus == 0 { clear(&fr.search_buf); fr.needs_scan = true }
			else             { clear(&fr.replace_buf) }
			fr.all_sel = false
		} else {
			if fr.focus == 0 && len(fr.search_buf) > 0 { pop(&fr.search_buf); fr.needs_scan = true }
			else if fr.focus == 1 && len(fr.replace_buf) > 0 { pop(&fr.replace_buf) }
		}
		return
	}

	for {
		ch := rl.GetCharPressed()
		if ch == 0 { break }
		if ch < 32 { continue }
		// If all selected, clear first
		if fr.all_sel {
			if fr.focus == 0 { clear(&fr.search_buf); fr.needs_scan = true }
			else             { clear(&fr.replace_buf) }
			fr.all_sel = false
		}
		var: [4]u8
		nn := rune_encode(ch, &var)
		if fr.focus == 0 {
			for i in 0 ..< nn { append(&fr.search_buf,  var[i]) }
			fr.needs_scan = true
		} else {
			for i in 0 ..< nn { append(&fr.replace_buf, var[i]) }
		}
	}

	if fr.needs_scan { find_replace_scan(fr, p) }
}

find_replace_do_replace :: proc(e: ^Editor) {
	fr := &e.find_rep
	p  := active_pane(e)
	if len(fr.matches) == 0 { return }

	pos   := fr.matches[fr.current]
	qlen  := fr.match_lens[fr.current]
	rtext := string(fr.replace_buf[:])

	del := make([]u8, qlen, context.temp_allocator)
	for i in 0 ..< qlen { del[i] = buffer_get_byte(&p.buf, pos + i) }
	undo_push_delete(p, pos, del, false)
	buffer_delete(&p.buf, pos, qlen)
	undo_push_insert(p, pos, transmute([]u8)rtext, false)
	undo_break(p)
	buffer_insert_string(&p.buf, pos, rtext)

	p.cursor     = pos + len(rtext)
	p.sel_anchor = p.cursor
	p.dirty      = true

	find_replace_scan(fr, p)
	if len(fr.matches) > 0 {
		fr.current = 0
		for i in 0 ..< len(fr.matches) {
			if fr.matches[i] >= pos + len(rtext) { fr.current = i; break }
		}
		find_replace_jump(fr, p)
	}
}

find_replace_replace_all :: proc(e: ^Editor) {
	fr := &e.find_rep
	p  := active_pane(e)
	find_replace_scan(fr, p)
	if len(fr.matches) == 0 { return }

	rtext := string(fr.replace_buf[:])
	count := 0

	for i := len(fr.matches) - 1; i >= 0; i -= 1 {
		pos  := fr.matches[i]
		qlen := fr.match_lens[i]
		del  := make([]u8, qlen, context.temp_allocator)
		for j in 0 ..< qlen { del[j] = buffer_get_byte(&p.buf, pos + j) }
		undo_push_delete(p, pos, del, false)
		buffer_delete(&p.buf, pos, qlen)
		undo_push_insert(p, pos, transmute([]u8)rtext, false)
		buffer_insert_string(&p.buf, pos, rtext)
		count += 1
	}
	undo_break(p)
	p.dirty = true
	find_replace_scan(fr, p)
	e.msg = fmt.tprintf("Replaced %d occurrences", count)
}
