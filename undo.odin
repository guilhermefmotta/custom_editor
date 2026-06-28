package editor

// undo_push_insert: record an insert for undo, with optional char-by-char coalescing.
undo_push_insert :: proc(p: ^Pane, pos: int, data: []u8, coalesce: bool) {
	if coalesce && p.u_merge == 1 && len(p.undo) > 0 {
		top := &p.undo[len(p.undo)-1]
		if top.insert && top.pos + len(top.data) == pos {
			for b in data { append(&top.data, b) }
			return
		}
	}
	// Trim oldest entry when history is full
	if len(p.undo) >= MAX_UNDO {
		delete(p.undo[0].data)
		ordered_remove(&p.undo, 0)
	}
	op := Undo_Op{insert = true, pos = pos, data = make([dynamic]u8)}
	for b in data { append(&op.data, b) }
	append(&p.undo, op)
	p.u_merge = 1 if coalesce else 0
}

// undo_push_delete: record a delete for undo.
// backspace=true  → consecutive backspaces prepend into one op (going left)
// backspace=false → consecutive forward-deletes append into one op (going right)
undo_push_delete :: proc(p: ^Pane, pos: int, data: []u8, backspace: bool) {
	if len(p.undo) > 0 {
		top := &p.undo[len(p.undo)-1]
		if !top.insert {
			if backspace && p.u_merge == -1 && pos + len(data) == top.pos {
				// Prepend: going leftward via backspace
				for i := len(data) - 1; i >= 0; i -= 1 {
					inject_at(&top.data, 0, data[i])
				}
				top.pos = pos
				return
			}
			if !backspace && p.u_merge == 2 && top.pos == pos {
				// Append: going rightward via Delete key
				for b in data { append(&top.data, b) }
				return
			}
		}
	}
	if len(p.undo) >= MAX_UNDO {
		delete(p.undo[0].data)
		ordered_remove(&p.undo, 0)
	}
	op := Undo_Op{insert = false, pos = pos, data = make([dynamic]u8)}
	for b in data { append(&op.data, b) }
	append(&p.undo, op)
	p.u_merge = -1 if backspace else 2
}

undo_break :: proc(p: ^Pane) {
	p.u_merge = 0
}

// undo_delete_sel: record + perform selection delete. Returns true if selection existed.
undo_delete_sel :: proc(p: ^Pane) -> bool {
	if !has_selection(p) do return false
	lo := sel_lo(p); hi := sel_hi(p)
	del_bytes := make([]u8, hi - lo, context.temp_allocator)
	for i in 0 ..< hi - lo { del_bytes[i] = buffer_get_byte(&p.buf, lo + i) }
	undo_push_delete(p, lo, del_bytes, false)
	undo_break(p)
	buffer_delete(&p.buf, lo, hi - lo)
	p.cursor     = lo
	p.sel_anchor = lo
	p.dirty      = true
	return true
}

// undo_push_mc: push an undo op as part of a multi-cursor compound group.
// first=true marks the root (compound=false); subsequent calls use first=false (compound=true).
// LIFO undo loops while compound=true, stopping at the root — so one Ctrl+Z undoes all cursors.
undo_push_mc :: proc(p: ^Pane, insert: bool, pos: int, data: []u8, first: bool) {
	if len(p.undo) >= MAX_UNDO {
		delete(p.undo[0].data)
		ordered_remove(&p.undo, 0)
	}
	op := Undo_Op{insert = insert, compound = !first, pos = pos, data = make([dynamic]u8)}
	for b in data { append(&op.data, b) }
	append(&p.undo, op)
	p.u_merge = 0
}

// pane_undo: pop the last undo op (and the entire compound group it belongs to) and reverse it.
pane_undo :: proc(p: ^Pane) {
	if len(p.undo) == 0 do return
	p.u_merge = 0
	for {
		if len(p.undo) == 0 { break }
		op := pop(&p.undo)
		defer delete(op.data)
		if op.insert {
			buffer_delete(&p.buf, op.pos, len(op.data))
			p.cursor = op.pos
		} else {
			buffer_insert_string(&p.buf, op.pos, string(op.data[:]))
			p.cursor = op.pos + len(op.data)
		}
		p.sel_anchor = p.cursor
		p.dirty      = true
		if !op.compound { break }
	}
}
