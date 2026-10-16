package editor

import "core:strings"
import rl "vendor:raylib"

// ---------------------------------------------------------------------------
// Emacs keymap mode — Ctrl/Meta chords, no separate Normal/Insert split
// (Emacs types via self-insert; movement/typing not claimed by a chord below
// falls through to the same shared handle_cursor_movement/handle_text_editing/
// handle_character_input Normal mode uses).
//
// Mark reuse win: C-SPC just sets p.sel_anchor = p.cursor and mark_active =
// true; every plain motion chord below then passes `selecting = mark_active`
// into the existing move_* procs (input.odin) — since selecting=true already
// skips their anchor-collapse, the region tracks and renders via the same
// selection highlight as everything else, no separate "region" concept.
//
// Kill-ring is deliberately separate from the system clipboard (Ctrl+C/X/V
// in Normal mode still use rl.SetClipboardText via copy_sel/cut_sel/paste,
// untouched) — matches real Emacs's own kill-ring/clipboard distinction.
// ---------------------------------------------------------------------------

Emacs_Prefix :: enum { None, C_x }

Emacs_State :: struct {
	prefix:            Emacs_Prefix,
	universal_arg:     int,  // -1 = not set (C-u not active)
	mark_active:       bool, // C-SPC sets this; region = sel_anchor..cursor
	kill_ring:         [dynamic][dynamic]u8, // ring, newest appended last
	last_cmd_was_yank: bool, // gates whether M-y is legal this keystroke
	last_yank_start:   int,
	last_yank_end:     int,
	last_yank_idx:     int,
	isearch: struct {
		active:       bool,
		forward:      bool,
		query:        [dynamic]u8,
		matches:      [dynamic]int,
		match_lens:   [dynamic]int,
		current:      int,
		start_cursor: int,
	},
}

emacs_init :: proc() -> Emacs_State {
	es: Emacs_State
	es.universal_arg      = -1
	es.kill_ring          = make([dynamic][dynamic]u8)
	es.isearch.query       = make([dynamic]u8)
	es.isearch.matches     = make([dynamic]int)
	es.isearch.match_lens  = make([dynamic]int)
	return es
}

emacs_destroy :: proc(es: ^Emacs_State) {
	for k in es.kill_ring { delete(k) }
	delete(es.kill_ring)
	delete(es.isearch.query)
	delete(es.isearch.matches)
	delete(es.isearch.match_lens)
}

// emacs_reset: called by keymap_switch_reset when leaving Emacs mode (or
// switching into it fresh) so no half-finished prefix/isearch state survives
// a mode switch. Kill-ring is left intact — harmless to keep across a
// temporary excursion into another keymap.
emacs_reset :: proc(es: ^Emacs_State) {
	es.prefix        = .None
	es.universal_arg = -1
	es.mark_active   = false
	es.last_cmd_was_yank = false
	es.isearch.active = false
	clear(&es.isearch.query)
	clear(&es.isearch.matches)
	clear(&es.isearch.match_lens)
}

// ---------------------------------------------------------------------------
// Top-level dispatch
// ---------------------------------------------------------------------------

emacs_handle_input :: proc(e: ^Editor, p: ^Pane) {
	es := &e.emacs

	if es.isearch.active {
		emacs_handle_isearch(e, p, es)
		return
	}

	if ctrl() && rl.IsKeyPressed(.G) {
		es.prefix        = .None
		es.universal_arg = -1
		es.mark_active   = false
		p.sel_anchor      = p.cursor
		return
	}

	if es.prefix == .C_x {
		emacs_handle_prefix_x(e, p, es)
		return
	}

	if ctrl() && rl.IsKeyPressed(.U) {
		es.universal_arg = es.universal_arg < 0 ? 4 : es.universal_arg * 4
		return
	}

	count := es.universal_arg > 0 ? es.universal_arg : 1

	if ctrl() {
		switch {
		case rl.IsKeyPressed(.X):
			es.prefix = .C_x
			return
		case rl.IsKeyPressed(.S):
			emacs_isearch_start(es, p, true)
			return
		case rl.IsKeyPressed(.R):
			emacs_isearch_start(es, p, false)
			return
		case rl.IsKeyPressed(.SPACE):
			es.mark_active = true
			p.sel_anchor = p.cursor
			es.universal_arg = -1
			return
		case rl.IsKeyPressed(.F):
			for _ in 0..<count { move_right(p, es.mark_active) }
			es.universal_arg = -1
			return
		case rl.IsKeyPressed(.B):
			for _ in 0..<count { move_left(p, es.mark_active) }
			es.universal_arg = -1
			return
		case rl.IsKeyPressed(.N):
			for _ in 0..<count { move_down(p, es.mark_active) }
			es.universal_arg = -1
			return
		case rl.IsKeyPressed(.P):
			for _ in 0..<count { move_up(p, es.mark_active) }
			es.universal_arg = -1
			return
		case rl.IsKeyPressed(.A):
			move_bol(p, es.mark_active)
			es.universal_arg = -1
			return
		case rl.IsKeyPressed(.E):
			move_eol(p, es.mark_active)
			es.universal_arg = -1
			return
		case rl.IsKeyPressed(.D):
			for _ in 0..<count { do_delete(p) }
			es.universal_arg = -1
			es.last_cmd_was_yank = false
			return
		case rl.IsKeyPressed(.H):
			for _ in 0..<count { do_backspace(p) }
			es.universal_arg = -1
			es.last_cmd_was_yank = false
			return
		case rl.IsKeyPressed(.K):
			emacs_kill_line(p, es)
			es.universal_arg = -1
			return
		case rl.IsKeyPressed(.W):
			emacs_kill_region(p, es)
			es.universal_arg = -1
			return
		case rl.IsKeyPressed(.Y):
			emacs_yank(p, es)
			es.universal_arg = -1
			return
		case rl.IsKeyPressed(.SLASH):
			pane_undo(p)
			es.universal_arg = -1
			es.last_cmd_was_yank = false
			return
		}
	}

	if alt() {
		switch {
		case rl.IsKeyPressed(.F):
			for _ in 0..<count { move_word_right(p, es.mark_active) }
			es.universal_arg = -1
			return
		case rl.IsKeyPressed(.B):
			for _ in 0..<count { move_word_left(p, es.mark_active) }
			es.universal_arg = -1
			return
		case rl.IsKeyPressed(.W):
			emacs_copy_region(p, es)
			es.universal_arg = -1
			return
		case rl.IsKeyPressed(.X):
			palette_open(&e.palette)
			es.universal_arg = -1
			return
		case rl.IsKeyPressed(.Y):
			emacs_yank_pop(p, es)
			return
		case shift() && rl.IsKeyPressed(.COMMA):
			move_doc_start(p, es.mark_active)
			es.universal_arg = -1
			return
		case shift() && rl.IsKeyPressed(.PERIOD):
			move_doc_end(p, es.mark_active)
			es.universal_arg = -1
			return
		}
	}

	cursor_before := p.cursor
	handle_cursor_movement(p)
	text_changed := false
	text_changed |= handle_text_editing(p)
	text_changed |= handle_character_input(p)
	if text_changed {
		es.last_cmd_was_yank = false
		es.universal_arg     = -1
		es.mark_active        = false
	}
	if p.cursor != cursor_before { lsp_on_cursor_moved(e, p) }
	if text_changed { lsp_on_text_changed(e, p) }
}

emacs_handle_prefix_x :: proc(e: ^Editor, p: ^Pane, es: ^Emacs_State) {
	es.prefix = .None
	switch {
	case ctrl() && rl.IsKeyPressed(.S):
		editor_save(e)
		lsp_on_save(e, p)
	case ctrl() && rl.IsKeyPressed(.C):
		e.should_quit = true
	case ctrl() && rl.IsKeyPressed(.F):
		palette_open_files(&e.palette, e)
	case rl.IsKeyPressed(.B):
		recents_open(&e.recents)
	case rl.IsKeyPressed(.K):
		pane_close_tab(p)
	case rl.IsKeyPressed(.O):
		if len(e.panes) > 1 { e.active = (e.active + 1) % len(e.panes) }
	case rl.IsKeyPressed(.TWO):
		editor_split(e, .Horizontal)
	case rl.IsKeyPressed(.THREE):
		editor_split(e, .Vertical)
	case rl.IsKeyPressed(.ONE):
		editor_close_other_panes(e)
	case rl.IsKeyPressed(.ZERO):
		editor_close_split(e)
	}
}

// ---------------------------------------------------------------------------
// Kill-ring
// ---------------------------------------------------------------------------

_emacs_kill_push :: proc(es: ^Emacs_State, data: []u8) {
	if len(data) == 0 { return }
	d := make([dynamic]u8, len(data))
	copy(d[:], data)
	append(&es.kill_ring, d)
	if len(es.kill_ring) > 64 {
		old := es.kill_ring[0]
		delete(old)
		ordered_remove(&es.kill_ring, 0)
	}
}

emacs_kill_line :: proc(p: ^Pane, es: ^Emacs_State) {
	line, _ := buffer_pos_to_line_col(&p.buf, p.cursor)
	ls := buffer_line_start(&p.buf, line)
	ll := buffer_line_length(&p.buf, line)
	eol := ls + ll
	total := buffer_line_count(&p.buf)
	del_len := p.cursor < eol ? eol - p.cursor : (line < total-1 ? 1 : 0)
	if del_len <= 0 { return }
	del := make([]u8, del_len, context.temp_allocator)
	for i in 0..<del_len { del[i] = buffer_get_byte(&p.buf, p.cursor+i) }
	_emacs_kill_push(es, del)
	undo_push_delete(p, p.cursor, del, false)
	undo_break(p)
	buffer_delete(&p.buf, p.cursor, del_len)
	p.sel_anchor = p.cursor
	p.dirty = true
	es.last_cmd_was_yank = false
}

emacs_kill_region :: proc(p: ^Pane, es: ^Emacs_State) {
	if !has_selection(p) { es.mark_active = false; return }
	lo, hi := sel_lo(p), sel_hi(p)
	del := make([]u8, hi-lo, context.temp_allocator)
	for i in 0..<hi-lo { del[i] = buffer_get_byte(&p.buf, lo+i) }
	_emacs_kill_push(es, del)
	undo_delete_sel(p)
	es.mark_active = false
	es.last_cmd_was_yank = false
}

emacs_copy_region :: proc(p: ^Pane, es: ^Emacs_State) {
	if !has_selection(p) { es.mark_active = false; return }
	lo, hi := sel_lo(p), sel_hi(p)
	data := make([]u8, hi-lo, context.temp_allocator)
	for i in 0..<hi-lo { data[i] = buffer_get_byte(&p.buf, lo+i) }
	_emacs_kill_push(es, data)
	p.cursor = lo
	p.sel_anchor = p.cursor
	es.mark_active = false
}

emacs_yank :: proc(p: ^Pane, es: ^Emacs_State) {
	if len(es.kill_ring) == 0 { return }
	text := string(es.kill_ring[len(es.kill_ring)-1][:])
	if len(text) == 0 { return }
	start := p.cursor
	undo_push_insert(p, p.cursor, transmute([]u8)text, false)
	undo_break(p)
	buffer_insert_string(&p.buf, p.cursor, text)
	p.cursor += len(text)
	p.sel_anchor = p.cursor
	p.dirty = true
	es.last_yank_start    = start
	es.last_yank_end      = p.cursor
	es.last_yank_idx      = len(es.kill_ring)-1
	es.last_cmd_was_yank  = true
}

// M-y — only legal immediately after a yank; swaps the just-inserted text
// for the next-older kill-ring entry.
emacs_yank_pop :: proc(p: ^Pane, es: ^Emacs_State) {
	if !es.last_cmd_was_yank || len(es.kill_ring) == 0 { return }
	idx := es.last_yank_idx - 1
	if idx < 0 { idx = len(es.kill_ring)-1 }
	text := string(es.kill_ring[idx][:])
	old_len := es.last_yank_end - es.last_yank_start
	del := make([]u8, old_len, context.temp_allocator)
	for i in 0..<old_len { del[i] = buffer_get_byte(&p.buf, es.last_yank_start+i) }
	undo_push_delete(p, es.last_yank_start, del, false)
	buffer_delete(&p.buf, es.last_yank_start, old_len)
	undo_push_insert(p, es.last_yank_start, transmute([]u8)text, false)
	buffer_insert_string(&p.buf, es.last_yank_start, text)
	undo_break(p)
	es.last_yank_end = es.last_yank_start + len(text)
	es.last_yank_idx = idx
	p.cursor = es.last_yank_end
	p.sel_anchor = p.cursor
	p.dirty = true
	es.last_cmd_was_yank = true
}

// ---------------------------------------------------------------------------
// Incremental search (C-s/C-r) — true jump-as-you-type, unlike the Find/Replace
// dialog (input.odin) which only jumps on explicit Enter/arrow. Self-contained
// rather than sharing find_replace_scan, to avoid touching that dialog's code
// under this already-large change.
// ---------------------------------------------------------------------------

emacs_isearch_start :: proc(es: ^Emacs_State, p: ^Pane, forward: bool) {
	if es.isearch.active {
		emacs_isearch_step(es, p, forward)
		return
	}
	es.isearch.active       = true
	es.isearch.forward      = forward
	es.isearch.start_cursor = p.cursor
	clear(&es.isearch.query)
	clear(&es.isearch.matches)
	clear(&es.isearch.match_lens)
	es.isearch.current = -1
}

emacs_handle_isearch :: proc(e: ^Editor, p: ^Pane, es: ^Emacs_State) {
	if rl.IsKeyPressed(.ESCAPE) || (ctrl() && rl.IsKeyPressed(.G)) {
		p.cursor = es.isearch.start_cursor
		p.sel_anchor = p.cursor
		es.isearch.active = false
		return
	}
	if rl.IsKeyPressed(.ENTER) {
		p.sel_anchor = p.cursor
		es.isearch.active = false
		return
	}
	if ctrl() && rl.IsKeyPressed(.S) { emacs_isearch_step(es, p, true);  return }
	if ctrl() && rl.IsKeyPressed(.R) { emacs_isearch_step(es, p, false); return }
	if rl.IsKeyPressed(.BACKSPACE) {
		if len(es.isearch.query) > 0 { ordered_remove(&es.isearch.query, len(es.isearch.query)-1) }
		_emacs_isearch_rescan(es, p)
		return
	}
	ch := rl.GetCharPressed()
	typed := false
	for ch != 0 {
		if ch >= 32 {
			buf: [4]u8
			n := rune_encode(ch, &buf)
			for i in 0..<n { append(&es.isearch.query, buf[i]) }
			typed = true
		}
		ch = rl.GetCharPressed()
	}
	if typed { _emacs_isearch_rescan(es, p) }
}

emacs_isearch_step :: proc(es: ^Emacs_State, p: ^Pane, forward: bool) {
	if len(es.isearch.matches) == 0 { return }
	es.isearch.forward = forward
	if forward {
		es.isearch.current = (es.isearch.current + 1) % len(es.isearch.matches)
	} else {
		es.isearch.current = (es.isearch.current - 1 + len(es.isearch.matches)) % len(es.isearch.matches)
	}
	p.cursor = es.isearch.matches[es.isearch.current]
	p.sel_anchor = p.cursor + len(es.isearch.query)
}

_emacs_isearch_rescan :: proc(es: ^Emacs_State, p: ^Pane) {
	clear(&es.isearch.matches)
	q := string(es.isearch.query[:])
	if len(q) == 0 { es.isearch.current = -1; return }

	text := buffer_to_string(&p.buf, context.temp_allocator)
	qlow := strings.to_lower(q, context.temp_allocator)
	tlow := strings.to_lower(text, context.temp_allocator)

	start := 0
	for {
		idx := strings.index(tlow[start:], qlow)
		if idx < 0 { break }
		pos := start + idx
		append(&es.isearch.matches, pos)
		start = pos + 1
	}
	if len(es.isearch.matches) == 0 { es.isearch.current = -1; return }

	from := p.cursor
	best := 0
	if es.isearch.forward {
		found := false
		for m, i in es.isearch.matches { if m >= from { best = i; found = true; break } }
		if !found { best = 0 }
	} else {
		found := false
		for i := len(es.isearch.matches)-1; i >= 0; i -= 1 {
			if es.isearch.matches[i] <= from { best = i; found = true; break }
		}
		if !found { best = len(es.isearch.matches)-1 }
	}
	es.isearch.current = best
	p.cursor = es.isearch.matches[best]
	p.sel_anchor = p.cursor + len(q)
}
