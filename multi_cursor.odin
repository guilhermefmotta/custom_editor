package editor

Extra_Cursor :: struct { pos, anchor: int }

mc_clear      :: proc(p: ^Pane) { clear(&p.extras) }
mc_has_extras :: proc(p: ^Pane) -> bool { return len(p.extras) > 0 }

mc_add :: proc(p: ^Pane, pos: int) {
	if p.cursor == pos { return }
	for ec in p.extras { if ec.pos == pos { return } }
	append(&p.extras, Extra_Cursor{pos, pos})
}

// Primary cursor moves to the next/prev line; its old position is pinned as an extra.
// This gives clear visual feedback: cursor always moves when Alt+Down/Up is pressed.
mc_add_below :: proc(p: ^Pane) {
	line, col := buffer_pos_to_line_col(&p.buf, p.cursor)
	total     := buffer_line_count(&p.buf)
	if line >= total - 1 { return }
	ns      := buffer_line_start(&p.buf, line + 1)
	nl      := buffer_line_length(&p.buf, line + 1)
	new_pos := ns + min(col, nl)
	// Pin current primary as an extra, then move primary forward
	append(&p.extras, Extra_Cursor{p.cursor, p.cursor})
	p.cursor     = new_pos
	p.sel_anchor = new_pos
}

mc_add_above :: proc(p: ^Pane) {
	line, col := buffer_pos_to_line_col(&p.buf, p.cursor)
	if line == 0 { return }
	ps      := buffer_line_start(&p.buf, line - 1)
	pl      := buffer_line_length(&p.buf, line - 1)
	new_pos := ps + min(col, pl)
	// Pin current primary as an extra, then move primary backward
	append(&p.extras, Extra_Cursor{p.cursor, p.cursor})
	p.cursor     = new_pos
	p.sel_anchor = new_pos
}

// ---- Move all cursors (selecting=true extends each cursor's selection) ----

mc_move_all_down :: proc(p: ^Pane, sel: bool) {
	total := buffer_line_count(&p.buf)
	move_down(p, sel)
	for i in 0..<len(p.extras) {
		ec := &p.extras[i]
		line, col := buffer_pos_to_line_col(&p.buf, ec.pos)
		if line < total - 1 {
			ns := buffer_line_start(&p.buf, line + 1)
			nl := buffer_line_length(&p.buf, line + 1)
			ec.pos = ns + min(col, nl)
		} else {
			ec.pos = buffer_len(&p.buf)
		}
		if !sel { ec.anchor = ec.pos }
	}
}

mc_move_all_up :: proc(p: ^Pane, sel: bool) {
	move_up(p, sel)
	for i in 0..<len(p.extras) {
		ec := &p.extras[i]
		line, col := buffer_pos_to_line_col(&p.buf, ec.pos)
		if line > 0 {
			ps := buffer_line_start(&p.buf, line - 1)
			pl := buffer_line_length(&p.buf, line - 1)
			ec.pos = ps + min(col, pl)
		} else {
			ec.pos = 0
		}
		if !sel { ec.anchor = ec.pos }
	}
}

mc_move_all_left :: proc(p: ^Pane, sel: bool) {
	move_left(p, sel)
	for i in 0..<len(p.extras) {
		ec := &p.extras[i]
		if ec.pos > 0 {
			ec.pos -= 1
			for ec.pos > 0 && (buffer_get_byte(&p.buf, ec.pos) & 0xC0) == 0x80 { ec.pos -= 1 }
		}
		if !sel { ec.anchor = ec.pos }
	}
}

mc_move_all_right :: proc(p: ^Pane, sel: bool) {
	move_right(p, sel)
	n := buffer_len(&p.buf)
	for i in 0..<len(p.extras) {
		ec := &p.extras[i]
		if ec.pos < n {
			ec.pos += 1
			for ec.pos < n && (buffer_get_byte(&p.buf, ec.pos) & 0xC0) == 0x80 { ec.pos += 1 }
		}
		if !sel { ec.anchor = ec.pos }
	}
}

// Word jump/select for all cursors (Alt+Left/Right)
mc_word_right_all :: proc(p: ^Pane, sel: bool) {
	move_word_right(p, sel)
	n := buffer_len(&p.buf)
	for i in 0..<len(p.extras) {
		ec := &p.extras[i]
		for ec.pos < n &&  is_word(buffer_get_byte(&p.buf, ec.pos)) { ec.pos += 1 }
		for ec.pos < n && !is_word(buffer_get_byte(&p.buf, ec.pos)) { ec.pos += 1 }
		if !sel { ec.anchor = ec.pos }
	}
}

mc_word_left_all :: proc(p: ^Pane, sel: bool) {
	move_word_left(p, sel)
	for i in 0..<len(p.extras) {
		ec := &p.extras[i]
		if ec.pos > 0 {
			ec.pos -= 1
			for ec.pos > 0 && !is_word(buffer_get_byte(&p.buf, ec.pos)) { ec.pos -= 1 }
			for ec.pos > 0 &&  is_word(buffer_get_byte(&p.buf, ec.pos - 1)) { ec.pos -= 1 }
		}
		if !sel { ec.anchor = ec.pos }
	}
}

// ---- Internal: sorted cursor list ----

_MCE :: struct { pos, anchor, idx: int } // idx 0=primary, 1+=extras[idx-1]

_mc_collect :: proc(p: ^Pane) -> [dynamic]_MCE {
	all := make([dynamic]_MCE, context.temp_allocator)
	append(&all, _MCE{p.cursor, p.sel_anchor, 0})
	for i in 0..<len(p.extras) {
		ec := p.extras[i]
		append(&all, _MCE{ec.pos, ec.anchor, i + 1})
	}
	for i in 1..<len(all) {
		key := all[i]; j := i - 1
		for j >= 0 && min(all[j].pos, all[j].anchor) > min(key.pos, key.anchor) {
			all[j+1] = all[j]; j -= 1
		}
		all[j+1] = key
	}
	return all
}

_mc_scatter :: proc(p: ^Pane, all: [dynamic]_MCE) {
	for e in all {
		if e.idx == 0 { p.cursor = e.pos; p.sel_anchor = e.anchor }
		else          { p.extras[e.idx-1].pos = e.pos; p.extras[e.idx-1].anchor = e.anchor }
	}
}

_mc_adjust_up :: proc(all: [dynamic]_MCE, from_i, lo, hi, delta: int) {
	for j in from_i..<len(all) {
		if all[j].pos    >= hi    { all[j].pos    += delta } else if all[j].pos    > lo { all[j].pos    = lo }
		if all[j].anchor >= hi    { all[j].anchor += delta } else if all[j].anchor > lo { all[j].anchor = lo }
	}
}

mc_insert_bytes :: proc(p: ^Pane, bytes: []u8) {
	n     := len(bytes)
	all   := _mc_collect(p)
	first := true

	for i in 0..<len(all) {
		e  := &all[i]
		lo := min(e.pos, e.anchor)
		hi := max(e.pos, e.anchor)

		if lo < hi {
			del_bytes := make([]u8, hi-lo, context.temp_allocator)
			for j in 0..<hi-lo { del_bytes[j] = buffer_get_byte(&p.buf, lo+j) }
			undo_push_mc(p, false, lo, del_bytes, first); first = false
			buffer_delete(&p.buf, lo, hi - lo)
			dl := hi - lo
			e.pos = lo; e.anchor = lo
			_mc_adjust_up(all, i+1, lo, hi, -dl)
		}

		undo_push_mc(p, true, e.pos, bytes, first); first = false
		for bi in 0..<n { buffer_insert_byte(&p.buf, e.pos + bi, bytes[bi]) }
		e.pos += n; e.anchor = e.pos
		for j in i+1..<len(all) { all[j].pos += n; all[j].anchor += n }
	}

	_mc_scatter(p, all)
	undo_break(p)
	p.dirty = true
}

mc_backspace :: proc(p: ^Pane) {
	all   := _mc_collect(p)
	first := true

	for i in 0..<len(all) {
		e  := &all[i]
		lo := min(e.pos, e.anchor)
		hi := max(e.pos, e.anchor)

		if lo < hi {
			del_bytes := make([]u8, hi-lo, context.temp_allocator)
			for j in 0..<hi-lo { del_bytes[j] = buffer_get_byte(&p.buf, lo+j) }
			undo_push_mc(p, false, lo, del_bytes, first); first = false
			buffer_delete(&p.buf, lo, hi - lo)
			dl := hi - lo
			e.pos = lo; e.anchor = lo
			_mc_adjust_up(all, i+1, lo, hi, -dl)
		} else if e.pos > 0 {
			prev := e.pos - 1
			for prev > 0 && (buffer_get_byte(&p.buf, prev) & 0xC0) == 0x80 { prev -= 1 }
			nb := e.pos - prev
			del_bytes := make([]u8, nb, context.temp_allocator)
			for j in 0..<nb { del_bytes[j] = buffer_get_byte(&p.buf, prev+j) }
			undo_push_mc(p, false, prev, del_bytes, first); first = false
			buffer_delete(&p.buf, prev, nb)
			e.pos = prev; e.anchor = prev
			for j in i+1..<len(all) { all[j].pos -= nb; all[j].anchor -= nb }
		}
	}

	_mc_scatter(p, all)
	undo_break(p)
	p.dirty = true
}

mc_delete_fwd :: proc(p: ^Pane) {
	all   := _mc_collect(p)
	buf_n := buffer_len(&p.buf)
	first := true

	for i in 0..<len(all) {
		e  := &all[i]
		lo := min(e.pos, e.anchor)
		hi := max(e.pos, e.anchor)

		if lo < hi {
			del_bytes := make([]u8, hi-lo, context.temp_allocator)
			for j in 0..<hi-lo { del_bytes[j] = buffer_get_byte(&p.buf, lo+j) }
			undo_push_mc(p, false, lo, del_bytes, first); first = false
			buffer_delete(&p.buf, lo, hi - lo)
			dl := hi - lo
			e.pos = lo; e.anchor = lo
			_mc_adjust_up(all, i+1, lo, hi, -dl)
			buf_n -= dl
		} else if e.pos < buf_n {
			nb := utf8_lead_len(buffer_get_byte(&p.buf, e.pos))
			if e.pos + nb > buf_n { nb = buf_n - e.pos }
			del_bytes := make([]u8, nb, context.temp_allocator)
			for j in 0..<nb { del_bytes[j] = buffer_get_byte(&p.buf, e.pos+j) }
			undo_push_mc(p, false, e.pos, del_bytes, first); first = false
			buffer_delete(&p.buf, e.pos, nb)
			for j in i+1..<len(all) { all[j].pos -= nb; all[j].anchor -= nb }
			buf_n -= nb
		}
	}

	_mc_scatter(p, all)
	undo_break(p)
	p.dirty = true
}

// ---- Comment toggle (Ctrl+/) with proper undo ----

lang_comment_prefix :: proc(lang: Lang) -> string {
	switch lang {
	case .Python: return "#"
	case .None, .Odin, .C, .Go, .JavaScript, .Rust, .Java: return "//"
	}
	return "//"
}

_cmt_add_lines :: proc(p: ^Pane, lmap: ^map[int]bool, lo_pos, hi_pos: int) {
	l1, _  := buffer_pos_to_line_col(&p.buf, lo_pos)
	l2, c2 := buffer_pos_to_line_col(&p.buf, hi_pos)
	end    := l2 if c2 > 0 else max(l1, l2 - 1)
	for l := l1; l <= end; l += 1 { lmap[l] = true }
}

do_comment_toggle :: proc(p: ^Pane) {
	pfx := lang_comment_prefix(p.lang)
	pl  := len(pfx)

	// Collect affected lines
	lmap := make(map[int]bool, 16, context.temp_allocator)
	if has_selection(p) {
		_cmt_add_lines(p, &lmap, sel_lo(p), sel_hi(p))
	} else {
		l, _ := buffer_pos_to_line_col(&p.buf, p.cursor)
		lmap[l] = true
	}
	for ec in p.extras {
		if ec.pos != ec.anchor {
			_cmt_add_lines(p, &lmap, min(ec.pos, ec.anchor), max(ec.pos, ec.anchor))
		} else {
			l, _ := buffer_pos_to_line_col(&p.buf, ec.pos)
			lmap[l] = true
		}
	}

	// Sort lines ASCENDING — required for delta-based undo to work correctly
	lines := make([dynamic]int, context.temp_allocator)
	for l in lmap { append(&lines, l) }
	for i in 1..<len(lines) {
		key := lines[i]; j := i - 1
		for j >= 0 && lines[j] > key { lines[j+1] = lines[j]; j -= 1 }
		lines[j+1] = key
	}

	if len(lines) == 0 { return }

	// Capture original line starts BEFORE any modifications
	orig_starts := make([dynamic]int, context.temp_allocator)
	for l in lines { append(&orig_starts, buffer_line_start(&p.buf, l)) }

	// Check all_cmt using original positions (no modifications yet)
	all_cmt := true
	for i in 0..<len(lines) {
		ls := orig_starts[i]
		ll := buffer_line_length(&p.buf, lines[i])
		if ll == 0 { continue } // skip empty lines
		has := ll >= pl
		if has {
			for j in 0..<pl { if buffer_get_byte(&p.buf, ls + j) != pfx[j] { has = false; break } }
		}
		if !has { all_cmt = false; break }
	}

	// Apply ASCENDING with cumulative delta — each op's position accounts for prior ops.
	// Compound undo groups all line ops so one Ctrl+Z reverses the entire toggle.
	delta := 0
	first := true
	if all_cmt {
		// Remove prefix from each line
		for i in 0..<len(lines) {
			ap := orig_starts[i] + delta // adjusted position in current buffer
			ll := buffer_line_length(&p.buf, lines[i])
			if ll < pl { continue }
			// Verify prefix still present (safety check)
			has := true
			for j in 0..<pl { if buffer_get_byte(&p.buf, ap + j) != pfx[j] { has = false; break } }
			if !has { continue }
			del_bytes := make([]u8, pl, context.temp_allocator)
			for j in 0..<pl { del_bytes[j] = pfx[j] }
			undo_push_mc(p, false, ap, del_bytes, first); first = false
			buffer_delete(&p.buf, ap, pl)
			delta -= pl
		}
	} else {
		// Add prefix to lines that don't have it
		for i in 0..<len(lines) {
			ap := orig_starts[i] + delta
			if ap >= buffer_len(&p.buf) { continue }
			b  := buffer_get_byte(&p.buf, ap)
			if b == '\n' { continue } // empty line
			// Check if already has prefix
			already := true
			for j in 0..<pl {
				if ap + j >= buffer_len(&p.buf) || buffer_get_byte(&p.buf, ap + j) != pfx[j] {
					already = false; break
				}
			}
			if already { continue }
			pfx_bytes := transmute([]u8)pfx
			undo_push_mc(p, true, ap, pfx_bytes, first); first = false
			for j in 0..<pl { buffer_insert_byte(&p.buf, ap + j, pfx[j]) }
			delta += pl
		}
	}

	undo_break(p)
	p.dirty = true
}
