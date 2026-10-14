package editor

// ===========================================================================
// Merge resolver — pure document model (no raylib), ticket #8 / ADR 0012.
//
// Mirrors Git Crab's ThreePaneEditor + cm/conflictExt.ts:
// - The result document is plain bytes edited through mr_edit (one change =
//   replace [from, to) with `insert`), with an undo/redo stack of changes.
// - Every original conflict i is tracked by POSITION through every change
//   (blocks[i] = {from, to}; `from` maps with assoc -1, `to` with assoc +1,
//   exactly like CodeMirror's mapPos). Conflicts are NEVER re-indexed by
//   re-parsing markers: that made Accept land on the wrong conflict after
//   the first one was resolved in Git Crab.
// - Each side of each conflict is Pending / Applied / Ignored. Accepting the
//   first side replaces the marker block (keeping its trailing newline);
//   accepting the other one appends below. Ignore on a block that still has
//   markers deletes the block, leaving the other side to decide. When an
//   undo brings the markers back both sides go back to Pending.
// - Side panes (Local / Remote) are rebuilt from the merged file: context +
//   that side's lines, so the three panes align conflict by conflict.
// ===========================================================================

import "core:strings"
import git "./git"

Mr_Side       :: enum u8 { Ours, Theirs }
Mr_Side_State :: enum u8 { Pending, Applied, Ignored }
Mr_Status     :: enum u8 { Unresolved, Ours, Theirs, Both, Manual }

Mr_Conflict :: struct {
	text:  [Mr_Side]string, // that side's lines joined by "\n" (owned)
	lines: [Mr_Side]int,    // line count of each side
	start: [Mr_Side]int,    // first line (0-based) in that side's pane
}

Mr_Block :: struct { from, to: int }

@(private="file")
Mr_Edit :: struct {
	from:   int,
	old:    string, // owned: removed text
	new:    string, // owned: inserted text
	cursor: int,    // cursor before the edit
}

Mr_Doc :: struct {
	text:      [dynamic]u8,
	side_text: [Mr_Side][dynamic]u8, // Local / Remote panes
	conflicts: [dynamic]Mr_Conflict,
	blocks:    [dynamic]Mr_Block,
	sides:     [dynamic][Mr_Side]Mr_Side_State,
	undo:      [dynamic]Mr_Edit,
	redo:      [dynamic]Mr_Edit,
	cursor:    int,
}

// ---------------------------------------------------------------------------
// Lifecycle / parsing
// ---------------------------------------------------------------------------

mr_doc_init :: proc(d: ^Mr_Doc, merged: string) {
	mr_doc_destroy(d)
	append(&d.text, merged)

	Pstate :: enum { None, Ours, Base, Theirs }
	state := Pstate.None
	cur: [Mr_Side][dynamic]string
	cur[.Ours]   = make([dynamic]string, context.temp_allocator)
	cur[.Theirs] = make([dynamic]string, context.temp_allocator)
	pending_ctx := make([dynamic]string, context.temp_allocator) // lines of an open block
	block_from := 0
	side_line: [Mr_Side]int

	add_side_line :: proc(d: ^Mr_Doc, s: Mr_Side, line: string, side_line: ^[Mr_Side]int) {
		append(&d.side_text[s], line)
		append(&d.side_text[s], '\n')
		side_line[s] += 1
	}

	pos := 0
	s := merged
	for len(s) > 0 {
		nl := strings.index_byte(s, '\n')
		line_len := len(s) if nl < 0 else nl + 1
		line := s[:nl] if nl >= 0 else s

		switch {
		case state == .None && strings.has_prefix(line, "<<<<<<<"):
			state = .Ours
			block_from = pos
			clear(&cur[.Ours]); clear(&cur[.Theirs]); clear(&pending_ctx)
			append(&pending_ctx, line)
		case state == .Ours && strings.has_prefix(line, "|||||||"):
			state = .Base
			append(&pending_ctx, line)
		case (state == .Ours || state == .Base) && strings.has_prefix(line, "======="):
			state = .Theirs
			append(&pending_ctx, line)
		case state == .Theirs && strings.has_prefix(line, ">>>>>>>"):
			c: Mr_Conflict
			for side in Mr_Side {
				c.text[side]  = strings.join(cur[side][:], "\n")
				c.lines[side] = len(cur[side])
				c.start[side] = side_line[side]
				for l in cur[side] { add_side_line(d, side, l, &side_line) }
			}
			append(&d.conflicts, c)
			append(&d.blocks, Mr_Block{block_from, pos + line_len})
			append(&d.sides, [Mr_Side]Mr_Side_State{})
			state = .None
		case state == .Ours:
			append(&cur[.Ours], line); append(&pending_ctx, line)
		case state == .Base:
			append(&pending_ctx, line)
		case state == .Theirs:
			append(&cur[.Theirs], line); append(&pending_ctx, line)
		case:
			for side in Mr_Side { add_side_line(d, side, line, &side_line) }
		}
		pos += line_len
		if nl < 0 { break }
		s = s[line_len:]
	}
	// Unterminated block: it is just text (Done refuses it while it has markers)
	if state != .None {
		for l in pending_ctx { for side in Mr_Side { add_side_line(d, side, l, &side_line) } }
	}
	// Side panes end like the merged file (no phantom empty last line)
	if !strings.has_suffix(merged, "\n") {
		for side in Mr_Side { if len(d.side_text[side]) > 0 { pop(&d.side_text[side]) } }
	}
	d.cursor = 0
	if len(d.blocks) > 0 { d.cursor = d.blocks[0].from }
}

mr_doc_destroy :: proc(d: ^Mr_Doc) {
	for c in d.conflicts { for side in Mr_Side { delete(c.text[side]) } }
	_mr_free_edits(&d.undo)
	_mr_free_edits(&d.redo)
	delete(d.text); delete(d.conflicts); delete(d.blocks); delete(d.sides)
	delete(d.undo); delete(d.redo)
	for side in Mr_Side { delete(d.side_text[side]) }
	d^ = {}
}

@(private="file")
_mr_free_edits :: proc(list: ^[dynamic]Mr_Edit) {
	for e in list { delete(e.old); delete(e.new) }
	clear(list)
}

mr_text :: proc(d: ^Mr_Doc) -> string { return string(d.text[:]) }

// ---------------------------------------------------------------------------
// Position mapping (CodeMirror ChangeSet.mapPos for a single change)
// ---------------------------------------------------------------------------

// Maps `pos` through "replace [cf, ct) with `ins` bytes". assoc < 0 sticks to
// the left of inserted text, assoc > 0 to the right.
mr_map_pos :: proc(pos, assoc, cf, ct, ins: int) -> int {
	if pos < cf { return pos }
	if pos > ct { return pos + ins - (ct - cf) }
	if cf == ct { return cf if assoc < 0 else cf + ins } // pure insertion at pos
	if pos == ct { return cf + ins }
	if pos == cf { return cf }
	return cf if assoc < 0 else cf + ins
}

// ---------------------------------------------------------------------------
// Editing
// ---------------------------------------------------------------------------

// Replaces [from, to) with `insert`, maps the conflict blocks, records undo.
mr_edit :: proc(d: ^Mr_Doc, from, to: int, insert: string) {
	from := clamp(from, 0, len(d.text))
	to   := clamp(to, from, len(d.text))
	if from == to && insert == "" { return }
	ed := Mr_Edit{from = from, old = strings.clone(string(d.text[from:to])), new = strings.clone(insert), cursor = d.cursor}
	_mr_apply(d, from, to, insert)
	d.cursor = from + len(insert)
	append(&d.undo, ed)
	_mr_free_edits(&d.redo)
	mr_sync_sides(d)
}

@(private="file")
_mr_apply :: proc(d: ^Mr_Doc, from, to: int, insert: string) {
	n := len(d.text)
	tail := strings.clone(string(d.text[to:n]), context.temp_allocator)
	resize(&d.text, from)
	append(&d.text, insert)
	append(&d.text, tail)
	for &b in d.blocks {
		f := mr_map_pos(b.from, -1, from, to, len(insert))
		t := mr_map_pos(b.to, 1, from, to, len(insert))
		b = {f, max(f, t)}
	}
}

mr_can_undo :: proc(d: ^Mr_Doc) -> bool { return len(d.undo) > 0 }
mr_can_redo :: proc(d: ^Mr_Doc) -> bool { return len(d.redo) > 0 }

mr_undo :: proc(d: ^Mr_Doc) -> bool {
	if len(d.undo) == 0 { return false }
	ed := pop(&d.undo)
	_mr_apply(d, ed.from, ed.from + len(ed.new), ed.old)
	d.cursor = ed.cursor
	append(&d.redo, ed)
	mr_sync_sides(d)
	return true
}

mr_redo :: proc(d: ^Mr_Doc) -> bool {
	if len(d.redo) == 0 { return false }
	ed := pop(&d.redo)
	_mr_apply(d, ed.from, ed.from + len(ed.old), ed.new)
	d.cursor = ed.from + len(ed.new)
	append(&d.undo, ed)
	mr_sync_sides(d)
	return true
}

// Blocks whose markers came back (undo) make both sides available again.
mr_sync_sides :: proc(d: ^Mr_Doc) {
	for i in 0 ..< len(d.blocks) {
		if git.merge_text_has_markers(mr_block_text(d, i)) { d.sides[i] = {} }
	}
}

// ---------------------------------------------------------------------------
// Conflict queries
// ---------------------------------------------------------------------------

mr_block_text :: proc(d: ^Mr_Doc, i: int) -> string {
	b := d.blocks[i]
	return string(d.text[b.from:b.to])
}

mr_status :: proc(d: ^Mr_Doc, i: int) -> Mr_Status {
	if git.merge_text_has_markers(mr_block_text(d, i)) { return .Unresolved }
	o := d.sides[i][.Ours] == .Applied
	t := d.sides[i][.Theirs] == .Applied
	switch {
	case o && t: return .Both
	case o:      return .Ours
	case t:      return .Theirs
	}
	return .Manual
}

mr_resolved_count :: proc(d: ^Mr_Doc) -> int {
	n := 0
	for i in 0 ..< len(d.blocks) { if mr_status(d, i) != .Unresolved { n += 1 } }
	return n
}

mr_all_resolved :: proc(d: ^Mr_Doc) -> bool { return mr_resolved_count(d) == len(d.blocks) }

// Line count of conflict i's current text in the result.
mr_block_lines :: proc(d: ^Mr_Doc, i: int) -> int {
	t := mr_block_text(d, i)
	if t == "" { return 0 }
	return strings.count(t, "\n") + (0 if strings.has_suffix(t, "\n") else 1)
}

// Next (dir = 1) / previous (dir = -1) conflict still showing markers,
// starting after `from`, wrapping. -1 when none.
mr_next_unresolved :: proc(d: ^Mr_Doc, from, dir: int) -> int {
	n := len(d.blocks)
	for k in 1 ..= n {
		i := ((from + dir * k) % n + n) % n
		if mr_status(d, i) == .Unresolved { return i }
	}
	return -1
}

// ---------------------------------------------------------------------------
// Accept / Ignore (IntelliJ style) — handleSide/applySide of Git Crab
// ---------------------------------------------------------------------------

// Applies `side` of conflict i: the first side replaces the marker block
// (keeping the newline after it), the other one is appended below.
mr_apply_side :: proc(d: ^Mr_Doc, i: int, side: Mr_Side) -> bool {
	if i < 0 || i >= len(d.blocks) { return false }
	b := d.blocks[i]
	text := d.conflicts[i].text[side]
	if d.conflicts[i].lines[side] == 0 { text = "" }
	block_text := mr_block_text(d, i)
	if git.merge_text_has_markers(block_text) {
		insert := text
		if text != "" && strings.has_suffix(block_text, "\n") { insert = strings.concatenate({text, "\n"}, context.temp_allocator) }
		mr_edit(d, b.from, b.to, insert)
	} else if d.conflicts[i].lines[side] > 0 {
		insert: string
		switch {
		case strings.has_suffix(block_text, "\n"): insert = strings.concatenate({text, "\n"}, context.temp_allocator)
		case block_text != "":                     insert = strings.concatenate({"\n", text}, context.temp_allocator)
		case b.to < len(d.text):                   insert = strings.concatenate({text, "\n"}, context.temp_allocator)
		case b.from > 0 && d.text[b.from - 1] != '\n': insert = strings.concatenate({"\n", text}, context.temp_allocator)
		case:                                      insert = text
		}
		mr_edit(d, b.to, b.to, insert)
	}
	return true
}

// Accept (apply) or ignore one side. Ignoring a side of a block that still
// has markers drops the markers (and both texts), leaving the other side
// to accept or ignore. Returns whether the block had markers before.
mr_handle_side :: proc(d: ^Mr_Doc, i: int, side: Mr_Side, accept: bool) -> (was_unresolved: bool) {
	if i < 0 || i >= len(d.blocks) { return false }
	if d.sides[i][side] != .Pending { return false }
	was_unresolved = git.merge_text_has_markers(mr_block_text(d, i))
	if accept {
		mr_apply_side(d, i, side)
	} else if was_unresolved {
		b := d.blocks[i]
		mr_edit(d, b.from, b.to, "")
	}
	d.sides[i][side] = .Applied if accept else .Ignored
	return
}

// Accept one side for every conflict still showing markers.
mr_accept_all :: proc(d: ^Mr_Doc, side: Mr_Side) -> int {
	n := 0
	for i in 0 ..< len(d.blocks) {
		if mr_status(d, i) == .Unresolved {
			mr_handle_side(d, i, side, true)
			n += 1
		}
	}
	return n
}

// ---------------------------------------------------------------------------
// Aligned layout: rows of the three panes (phantom rows pad each conflict to
// the tallest of Local / Result / Remote).
// ---------------------------------------------------------------------------

Mr_Row :: struct {
	line:     int, // line index in that pane; -1 = phantom (padding)
	conflict: int, // conflict this row belongs to; -1 = context
}

Mr_Pane :: enum u8 { Ours, Result, Theirs }

Mr_Layout :: struct {
	rows:        [Mr_Pane][dynamic]Mr_Row,
	first_row:   [Mr_Pane][dynamic]int, // per conflict: first row (incl. phantoms)
	line_starts: [dynamic]int,           // result line starts (byte offsets)
	side_starts: [Mr_Side][dynamic]int,  // Local / Remote pane line starts
	line_row:    [dynamic]int,           // result line → row
}

mr_layout_destroy :: proc(l: ^Mr_Layout) {
	for p in Mr_Pane { delete(l.rows[p]); delete(l.first_row[p]) }
	delete(l.line_starts); delete(l.line_row)
	for s in Mr_Side { delete(l.side_starts[s]) }
	l^ = {}
}

// Byte offsets where each line of `text` starts (always at least one line).
mr_line_starts :: proc(text: []u8, out: ^[dynamic]int) {
	clear(out)
	append(out, 0)
	for c, i in text { if c == '\n' { append(out, i + 1) } }
}

// Text of line `line` of a pane given its line starts (without the "\n").
mr_line_text :: proc(text: []u8, starts: []int, line: int) -> string {
	if line < 0 || line >= len(starts) { return "" }
	to := len(text) if line + 1 >= len(starts) else starts[line + 1] - 1
	return string(text[starts[line]:to])
}

// Line containing byte `pos` (binary search over starts).
mr_line_of :: proc(starts: []int, pos: int) -> int {
	lo, hi := 0, len(starts) - 1
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if starts[mid] <= pos { lo = mid } else { hi = mid - 1 }
	}
	return lo
}

@(private="file")
_mr_emit :: proc(rows: ^[dynamic]Mr_Row, first: ^[dynamic]int, nlines: int, starts, counts, heights: []int) {
	clear(rows)
	resize(first, len(starts))
	for &f in first { f = -1 }
	pad :: proc(rows: ^[dynamic]Mr_Row, n, c: int) { for _ in 0 ..< n { append(rows, Mr_Row{-1, c}) } }
	owner := -1
	for li in 0 ..< nlines {
		for c in 0 ..< len(starts) {
			if counts[c] == 0 && starts[c] == li {
				first[c] = len(rows)
				pad(rows, heights[c], c)
			}
		}
		if owner >= 0 && li >= starts[owner] + counts[owner] { owner = -1 }
		for c in 0 ..< len(starts) {
			if counts[c] > 0 && starts[c] == li { owner = c; first[c] = len(rows) }
		}
		append(rows, Mr_Row{li, owner})
		for c in 0 ..< len(starts) {
			if counts[c] > 0 && starts[c] + counts[c] - 1 == li { pad(rows, heights[c] - counts[c], c) }
		}
	}
	for c in 0 ..< len(starts) {
		if first[c] < 0 { first[c] = len(rows); pad(rows, heights[c], c) }
	}
}

mr_layout :: proc(d: ^Mr_Doc, l: ^Mr_Layout) {
	n := len(d.blocks)
	heights := make([]int, n, context.temp_allocator)
	starts  := make([]int, n, context.temp_allocator)
	counts  := make([]int, n, context.temp_allocator)

	mr_line_starts(d.text[:], &l.line_starts)
	for i in 0 ..< n {
		c := d.conflicts[i]
		heights[i] = max(c.lines[.Ours], c.lines[.Theirs], mr_block_lines(d, i), 1)
	}
	for side in Mr_Side {
		pane := Mr_Pane.Ours if side == .Ours else .Theirs
		side_starts := &l.side_starts[side]
		mr_line_starts(d.side_text[side][:], side_starts)
		for i in 0 ..< n { starts[i] = d.conflicts[i].start[side]; counts[i] = d.conflicts[i].lines[side] }
		_mr_emit(&l.rows[pane], &l.first_row[pane], len(side_starts), starts, counts, heights)
	}
	for i in 0 ..< n {
		starts[i] = mr_line_of(l.line_starts[:], d.blocks[i].from)
		counts[i] = mr_block_lines(d, i)
	}
	_mr_emit(&l.rows[.Result], &l.first_row[.Result], len(l.line_starts), starts, counts, heights)

	resize(&l.line_row, len(l.line_starts))
	for r, ri in l.rows[.Result] { if r.line >= 0 { l.line_row[r.line] = ri } }
}
