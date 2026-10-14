package editor

import "core:fmt"
import "core:os"
import "core:strings"
import git "./git"
import rl "vendor:raylib"

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

// .Status = idle: the working tree itself is the `working_tree` panel
// (working_tree.odin); this dialog only hosts the Diff and Merge views (and
// the branch picker) on top of it and hides itself when back to .Status.
Git_Dialog_Mode  :: enum { Status, Diff, Merge }

Conflict_Resolution :: enum { Unresolved, Ours, Theirs, Both }

Conflict_Block :: struct {
	ours_label:   string,   // heap
	theirs_label: string,   // heap
	ours_lines:   []string, // heap (slice of heap strings)
	theirs_lines: []string, // heap
	start_byte:   int,
	end_byte:     int,
	resolution:   Conflict_Resolution,
}

Merge_State :: struct {
	blocks:    [dynamic]Conflict_Block,
	selected:  int,
	ours_scroll:   int,
	theirs_scroll: int,
	file_path: string, // heap (abs)
	content:   []u8,   // heap — original file bytes
}

Git_Dialog :: struct {
	visible:    bool,
	mode:       Git_Dialog_Mode,
	diff_scroll: int,
	diff:        git.File_Diff, // whole-file side-by-side diff (Diff mode)
	diff_path:   string,        // heap, repo-relative path shown in Diff mode
	diff_change: int,           // index into diff.changed of the focused change
	msg:        string, // heap
	msg_ok:     bool,
	merge:      Merge_State,
	// Branch picker overlay
	bp_open:     bool,
	bp_branches: [dynamic]string, // heap
	bp_selected: int,
	bp_scroll:   int,
	bp_filter:   [dynamic]u8,
	bp_filter_sel_all: bool,
}

// Layout
GITD_BP_W   :: f32(460) // branch picker width
GITD_BP_MAX :: 14       // max visible branches
GITD_HEADER_H  :: f32(34)
GITD_ENTRY_H   :: f32(20)
GITD_SECTION_H :: f32(18)
GITD_FOOTER_H  :: f32(26)
GITD_DIFF_LEAD :: 3  // rows of context kept above a change when jumping to it
GITD_DIFF_GUTTER_CH :: 5 // line-number gutter width, in characters

// Rows visible in the last drawn diff (for PageUp/PageDown)
_gitd_diff_page_rows := 20

GITD_DIFF_ADD_BG   := rl.Color{40, 70, 50, 255}
GITD_DIFF_DEL_BG   := rl.Color{80, 40, 48, 255}
GITD_DIFF_EMPTY_BG := rl.Color{30, 30, 44, 255}
GITD_DIFF_MARK_ADD := rl.Color{166, 227, 161, 255}
GITD_DIFF_MARK_DEL := rl.Color{243, 139, 168, 255}

GITD_MERGE_W   :: f32(840) // wider for merge view
GITD_HALF_W    :: (GITD_MERGE_W - 4) / 2
GITD_ROW_MAX   :: 10 // max lines shown per side in merge view

// Colors
GITD_BG       := rl.Color{24,  24,  37,  255}
GITD_BORDER   := rl.Color{58,  60,  78,  255}
GITD_SEL      := rl.Color{45,  50,  70,  255}
GITD_HEADER   := rl.Color{30,  30,  46,  255}
GITD_SECTION  := rl.Color{49,  50,  68,  255}
GITD_GREEN    := rl.Color{166, 227, 161, 255}
GITD_GREEN_BG := rl.Color{30,  50,  35,  255}
GITD_RED      := rl.Color{243, 139, 168, 255}
GITD_RED_BG   := rl.Color{50,  30,  35,  255}
GITD_BLUE     := rl.Color{137, 180, 250, 255}
GITD_ORANGE      :: rl.Color{250, 179, 135, 255}
GITD_YELLOW      :: rl.Color{249, 226, 175, 255}
GITD_SUBDUED     :: rl.Color{108, 112, 134, 255}
GITD_TEXT        :: rl.Color{205, 214, 244, 255}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

git_dialog_init :: proc(d: ^Git_Dialog) {
	d.merge.blocks = make([dynamic]Conflict_Block)
	d.bp_branches = make([dynamic]string)
	d.bp_filter   = make([dynamic]u8)
}

git_dialog_destroy :: proc(d: ^Git_Dialog) {
	if d.msg != "" { delete(d.msg) }
	_merge_destroy(&d.merge)
	_gitd_diff_free(d)
	_bp_free_branches(d)
	delete(d.bp_branches)
	delete(d.bp_filter)
	d^ = {}
}

// "Open Git panel": the Status view became the `working_tree` panel.
git_dialog_open :: proc(d: ^Git_Dialog) {
	e := container_of(d, Editor, "git_dialog")
	ui_panel_open(e, WORKING_TREE_ID)
}

// Shows the whole-file side-by-side diff of rel_path; takes ownership of fd.
git_dialog_show_diff :: proc(e: ^Editor, rel_path: string, fd: git.File_Diff) {
	d := &e.git_dialog
	_gitd_open_diff(d, rel_path, fd)
	d.visible = true
	_rep_key = .KEY_NULL
}

// Opens the (legacy) merge view for a conflicted file (repo-relative path).
git_dialog_open_merge :: proc(e: ^Editor, rel_path: string) {
	d := &e.git_dialog
	m := &e.git_mgr
	d.visible = true
	_gitd_open_merge(d, m, fmt.tprintf("%s/%s", m.root, rel_path))
	_rep_key = .KEY_NULL
}

// Opens the "merge branch into current" picker.
git_dialog_open_branch_picker :: proc(e: ^Editor) {
	d := &e.git_dialog
	d.visible = true
	d.mode    = .Status
	_bp_open(d, &e.git_mgr)
	_rep_key = .KEY_NULL
}

git_dialog_close :: proc(d: ^Git_Dialog) {
	d.visible = false
	_merge_destroy(&d.merge)
	_gitd_diff_free(d)
}

_gitd_diff_free :: proc(d: ^Git_Dialog) {
	git.file_diff_destroy(&d.diff)
	if d.diff_path != "" { delete(d.diff_path); d.diff_path = "" }
}

// Opens the whole-file diff of rel_path (fd: owned, e.g. from the
// working_tree panel's async File_Diff request), scrolled to its first change.
_gitd_open_diff :: proc(d: ^Git_Dialog, rel_path: string, fd: git.File_Diff) {
	_gitd_diff_free(d)
	d.diff        = fd
	d.diff_path   = strings.clone(rel_path)
	d.diff_change = 0
	d.diff_scroll = 0
	if len(d.diff.changed) > 0 { d.diff_scroll = max(0, d.diff.changed[0] - GITD_DIFF_LEAD) }
	d.mode = .Diff
}

// Scrolls so change i sits a few rows below the top
_gitd_diff_goto :: proc(d: ^Git_Dialog, i: int) {
	n := len(d.diff.changed)
	if n == 0 { return }
	d.diff_change = (i % n + n) % n // wrap around both ways
	d.diff_scroll = max(0, d.diff.changed[d.diff_change] - GITD_DIFF_LEAD)
}

// ---------------------------------------------------------------------------
// Branch picker helpers
// ---------------------------------------------------------------------------

_bp_free_branches :: proc(d: ^Git_Dialog) {
	for s in d.bp_branches { delete(s) }
	clear(&d.bp_branches)
}

_bp_open :: proc(d: ^Git_Dialog, m: ^git.Git_Manager) {
	_bp_free_branches(d)
	new_list := git.git_list_branches(m)
	for s in new_list { append(&d.bp_branches, s) }
	delete(new_list)
	d.bp_selected = 0
	d.bp_scroll   = 0
	clear(&d.bp_filter)
	d.bp_filter_sel_all = false
	d.bp_open     = true
}

_bp_close :: proc(d: ^Git_Dialog) {
	d.bp_open = false
}

// Returns temp-allocated list of indices into bp_branches matching filter.
_bp_filtered :: proc(d: ^Git_Dialog) -> []int {
	out    := make([dynamic]int, context.temp_allocator)
	filter := string(d.bp_filter[:])
	for b, i in d.bp_branches {
		if filter == "" || strings.contains(b, filter) { append(&out, i) }
	}
	return out[:]
}

// ---------------------------------------------------------------------------

_gitd_set_msg :: proc(d: ^Git_Dialog, ok: bool, msg: string) {
	if d.msg != "" { delete(d.msg) }
	d.msg = strings.clone(msg)
	d.msg_ok = ok
}

// ---------------------------------------------------------------------------
// Merge helpers
// ---------------------------------------------------------------------------

_merge_destroy :: proc(m: ^Merge_State) {
	for &b in m.blocks {
		delete(b.ours_label); delete(b.theirs_label)
		for s in b.ours_lines   { delete(s) }
		for s in b.theirs_lines { delete(s) }
		delete(b.ours_lines)
		delete(b.theirs_lines)
	}
	delete(m.blocks)
	if m.file_path != "" { delete(m.file_path) }
	if m.content != nil  { delete(m.content) }
	m^ = {blocks = make([dynamic]Conflict_Block)}
}

// Parse conflict markers in `content`. Returns owned blocks.
_parse_conflicts :: proc(content: string) -> [dynamic]Conflict_Block {
	blocks := make([dynamic]Conflict_Block)

	Pstate :: enum { None, Ours, Theirs }
	state := Pstate.None

	cur_ours:   [dynamic]string
	cur_theirs: [dynamic]string
	ours_label:  string
	block_start: int

	s          := content
	byte_pos   := 0

	cur_ours   = make([dynamic]string, context.temp_allocator)
	cur_theirs = make([dynamic]string, context.temp_allocator)

	for len(s) > 0 {
		nl := strings.index_byte(s, '\n')
		line_bytes: string
		line_len:   int
		if nl < 0 {
			line_bytes = s
			line_len   = len(s)
		} else {
			line_bytes = s[:nl]
			line_len   = nl + 1
		}
		// Strip trailing \r
		line := line_bytes
		if len(line) > 0 && line[len(line)-1] == '\r' { line = line[:len(line)-1] }

		if strings.has_prefix(line, "<<<<<<<") && state == .None {
			state       = .Ours
			ours_label  = strings.trim_space(line[7:])
			block_start = byte_pos
			clear(&cur_ours)
			clear(&cur_theirs)
		} else if strings.has_prefix(line, "=======") && state == .Ours {
			state = .Theirs
		} else if strings.has_prefix(line, ">>>>>>>") && state == .Theirs {
			theirs_label := strings.trim_space(line[7:])

			b: Conflict_Block
			b.start_byte  = block_start
			b.end_byte    = byte_pos + line_len
			b.ours_label   = strings.clone(ours_label)
			b.theirs_label = strings.clone(theirs_label)
			b.ours_lines   = make([]string, len(cur_ours))
			for l, i in cur_ours   { b.ours_lines[i]   = strings.clone(l) }
			b.theirs_lines = make([]string, len(cur_theirs))
			for l, i in cur_theirs { b.theirs_lines[i] = strings.clone(l) }
			append(&blocks, b)
			state = .None
		} else if state == .Ours {
			append(&cur_ours, line)
		} else if state == .Theirs {
			append(&cur_theirs, line)
		}

		byte_pos += line_len
		if nl < 0 { break }
		s = s[line_len:]
	}
	return blocks
}

// Open merge view for a conflicted file.
_gitd_open_merge :: proc(d: ^Git_Dialog, m: ^git.Git_Manager, abs_path: string) {
	data, err := os.read_entire_file(abs_path, context.allocator)
	if err != nil { _gitd_set_msg(d, false, "can't read file"); return }
	content := string(data)
	blocks := _parse_conflicts(content)
	if len(blocks) == 0 {
		delete(data)
		_gitd_set_msg(d, false, "no conflict markers found")
		return
	}
	_merge_destroy(&d.merge)
	d.merge.blocks    = blocks
	d.merge.selected  = 0
	d.merge.file_path = strings.clone(abs_path)
	d.merge.content   = data
	d.mode = .Merge
}

// Write resolved file back to disk and stage it.
_gitd_write_and_stage :: proc(d: ^Git_Dialog, m: ^git.Git_Manager) {
	ms := &d.merge
	// Check all resolved
	unresolved := 0
	for b in ms.blocks { if b.resolution == .Unresolved { unresolved += 1 } }
	if unresolved > 0 {
		_gitd_set_msg(d, false, fmt.tprintf("%d conflict(s) not resolved", unresolved))
		return
	}

	// Rebuild file content
	b := strings.builder_make()
	content := string(ms.content)
	pos := 0
	for &blk in ms.blocks {
		strings.write_string(&b, content[pos:blk.start_byte])
		switch blk.resolution {
		case .Ours:
			for line in blk.ours_lines   { strings.write_string(&b, line); strings.write_byte(&b, '\n') }
		case .Theirs:
			for line in blk.theirs_lines { strings.write_string(&b, line); strings.write_byte(&b, '\n') }
		case .Both:
			for line in blk.ours_lines   { strings.write_string(&b, line); strings.write_byte(&b, '\n') }
			for line in blk.theirs_lines { strings.write_string(&b, line); strings.write_byte(&b, '\n') }
		case .Unresolved: // unreachable
		}
		pos = blk.end_byte
	}
	strings.write_string(&b, content[pos:])

	write_err := os.write_entire_file(ms.file_path, b.buf[:])
	strings.builder_destroy(&b)
	if write_err != nil { _gitd_set_msg(d, false, "write failed"); return }

	// Stage
	rel := ms.file_path
	if len(m.root) > 0 && len(ms.file_path) > len(m.root)+1 {
		rel = ms.file_path[len(m.root)+1:]
	}
	git.git_stage(m, rel)
	git.git_manager_refresh_now(m)

	_merge_destroy(&d.merge)
	d.mode = .Status
	_gitd_set_msg(d, true, "conflicts resolved and staged")
}

// ---------------------------------------------------------------------------
// Input handler
// ---------------------------------------------------------------------------

git_dialog_handle_input :: proc(d: ^Git_Dialog, e: ^Editor) {
	if !d.visible { return }
	m := &e.git_mgr

	// Branch picker takes full priority
	if d.bp_open { _git_bp_input(d, m); return }

	// --- Merge mode ---
	if d.mode == .Merge {
		_git_merge_input(d, m)
		return
	}

	// --- Diff mode ---
	if d.mode == .Diff {
		if rl.IsKeyPressed(.ESCAPE) || rl.IsKeyPressed(.B) {
			_gitd_diff_free(d)
			d.mode = .Status
			git_dialog_close(d) // back to the working_tree panel
			return
		}
		page := max(1, _gitd_diff_page_rows - 2)
		if key_rep(.DOWN) || key_rep(.J) { d.diff_scroll += 1 }
		if key_rep(.UP)   || key_rep(.K) { d.diff_scroll = max(0, d.diff_scroll - 1) }
		if key_rep(.PAGE_DOWN) || (ctrl() && key_rep(.D)) { d.diff_scroll += page }
		if key_rep(.PAGE_UP)   || (ctrl() && key_rep(.U)) { d.diff_scroll = max(0, d.diff_scroll - page) }
		if rl.IsKeyPressed(.HOME) { d.diff_scroll = 0 }
		if rl.IsKeyPressed(.END)  { d.diff_scroll = len(d.diff.rows) }
		// Jump between changes: n / p (Shift+N also goes back)
		if rl.IsKeyPressed(.N) { _gitd_diff_goto(d, d.diff_change + (-1 if shift() else 1)) }
		if rl.IsKeyPressed(.P) { _gitd_diff_goto(d, d.diff_change - 1) }
		wheel := rl.GetMouseWheelMove()
		if wheel != 0 { d.diff_scroll = max(0, d.diff_scroll - int(wheel)*3) }
		return
	}

	// --- Status (idle) --- nothing of ours left on screen: hide and hand
	// control back to the working_tree panel, reporting the last message.
	if d.msg != "" {
		ui_banner_show(d.msg, .Success if d.msg_ok else .Error)
		delete(d.msg); d.msg = ""
	}
	git_dialog_close(d)
}

_git_merge_input :: proc(d: ^Git_Dialog, m: ^git.Git_Manager) {
	ms := &d.merge
	n  := len(ms.blocks)

	if rl.IsKeyPressed(.ESCAPE) { d.mode = .Status; return }

	// Navigate conflicts
	if (key_rep(.J) || key_rep(.DOWN) || key_rep(.RIGHT)) && ms.selected < n-1 {
		ms.selected += 1; ms.ours_scroll = 0; ms.theirs_scroll = 0
	}
	if (key_rep(.K) || key_rep(.UP) || key_rep(.LEFT)) && ms.selected > 0 {
		ms.selected -= 1; ms.ours_scroll = 0; ms.theirs_scroll = 0
	}

	// Scroll ours/theirs sections
	wheel := rl.GetMouseWheelMove()
	if wheel != 0 {
		if rl.IsKeyDown(.LEFT_SHIFT) {
			ms.theirs_scroll = max(0, ms.theirs_scroll - int(wheel)*2)
		} else {
			ms.ours_scroll = max(0, ms.ours_scroll - int(wheel)*2)
		}
	}

	if n == 0 { return }
	blk := &ms.blocks[ms.selected]

	if rl.IsKeyPressed(.A) { blk.resolution = .Ours }
	if rl.IsKeyPressed(.B) { blk.resolution = .Theirs }
	if rl.IsKeyPressed(.O) { blk.resolution = .Both }
	if rl.IsKeyPressed(.U) { blk.resolution = .Unresolved } // undo

	if rl.IsKeyPressed(.W) { _gitd_write_and_stage(d, m) }
}

_git_bp_input :: proc(d: ^Git_Dialog, m: ^git.Git_Manager) {
	if rl.IsKeyPressed(.ESCAPE) { _bp_close(d); return }

	filtered := _bp_filtered(d)
	n := len(filtered)

	if key_rep(.DOWN) && d.bp_selected < n-1 {
		d.bp_selected += 1
		if d.bp_selected >= d.bp_scroll + GITD_BP_MAX { d.bp_scroll = d.bp_selected - GITD_BP_MAX + 1 }
	}
	if key_rep(.UP) && d.bp_selected > 0 {
		d.bp_selected -= 1
		if d.bp_selected < d.bp_scroll { d.bp_scroll = d.bp_selected }
	}

	if text_input_handle(&d.bp_filter, &d.bp_filter_sel_all) {
		d.bp_selected = 0; d.bp_scroll = 0
	}

	if rl.IsKeyPressed(.ENTER) && n > 0 {
		branch_idx := filtered[d.bp_selected]
		branch := d.bp_branches[branch_idx]
		conflicts, err := git.git_merge(m, branch)
		_bp_close(d)
		if err != "" {
			_gitd_set_msg(d, false, err); delete(err)
		} else if conflicts {
			_gitd_set_msg(d, true, "merge conflict — select conflicted file then Enter/M to resolve")
		} else {
			_gitd_set_msg(d, true, fmt.tprintf("merged %s", branch))
		}
		git.git_manager_refresh_now(m)
	}
}

// ---------------------------------------------------------------------------
// Draw
// ---------------------------------------------------------------------------

git_dialog_draw :: proc(d: ^Git_Dialog, e: ^Editor, font: rl.Font) {
	if !d.visible { return }
	m := &e.git_mgr

	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())

	switch d.mode {
	case .Merge: _gitd_draw_merge(d, m, font, sw, sh)
	case .Diff:  _gitd_draw_diff(d, m, font, sw, sh)
	case .Status: // idle: the working_tree panel draws itself
	}
	if d.bp_open { _gitd_draw_branch_picker(d, m, font, sw, sh) }
}

// ---------------------------------------------------------------------------
// Diff view
// ---------------------------------------------------------------------------

_gitd_draw_diff :: proc(d: ^Git_Dialog, m: ^git.Git_Manager, font: rl.Font, sw, sh: f32) {
	ref := rl.MeasureTextEx(font, "M", FONT_SIZE, CHAR_SPACING)
	fs  := FONT_SIZE - 1
	dy  := ref.y + 2
	cw  := rl.MeasureTextEx(font, "0", fs, CHAR_SPACING).x

	// Nearly full window: the whole file is shown, so use the space
	pw := sw - 40
	ph := sh - 40
	px, py := dlg_begin((sw - pw) * 0.5, (sh - ph) * 0.5, pw, ph, GITD_BG, GITD_BORDER)

	rows := d.diff.rows[:]
	n_changes := len(d.diff.changed)

	// Header: path, change counter, keys
	rl.DrawRectangleV({px, py}, {pw, GITD_HEADER_H}, GITD_HEADER)
	pos := fmt.tprintf("change %d/%d", d.diff_change + 1, n_changes) if n_changes > 0 else "no changes"
	title := fmt.tprintf(" %s   %s   (n/p next/prev change, ↑↓ PgUp/PgDn scroll, Esc back)", d.diff_path, pos)
	dlg_text(font, title, px + 10, py + (GITD_HEADER_H - ref.y) * 0.5, fs, CHAR_SPACING, GITD_BLUE, px + pw, 10)

	footer_y    := py + ph - GITD_FOOTER_H
	content_top := py + GITD_HEADER_H
	content_h   := footer_y - content_top

	vis := max(1, int(content_h / dy))
	_gitd_diff_page_rows = vis
	d.diff_scroll = clamp(d.diff_scroll, 0, max(0, len(rows) - vis))

	if d.diff.binary || len(rows) == 0 {
		msg := "Binary file — no text diff" if d.diff.binary else "No changes"
		rl.DrawTextEx(font, to_cstring(msg), {px + 16, content_top + 12}, fs, CHAR_SPACING, GITD_SUBDUED)
		dlg_end()
		return
	}

	// Two columns: [gutter | text] old  ‖  [gutter | text] new
	half   := (pw - 3) * 0.5
	gutter := cw * f32(GITD_DIFF_GUTTER_CH) + 10
	col_x  := [2]f32{px, px + half + 3}
	rl.DrawRectangleV({px + half + 1, content_top}, {1, content_h}, GITD_BORDER)

	cy := content_top
	for i := d.diff_scroll; i < len(rows) && i < d.diff_scroll + vis; i += 1 {
		row := rows[i]
		sides := [2]git.Diff_Side{row.left, row.right}
		for side, c in sides {
			x := col_x[c]
			bg: rl.Color
			mark: rl.Color
			switch side.kind {
			case .Context: bg = GITD_BG
			case .Add:     bg = GITD_DIFF_ADD_BG;   mark = GITD_DIFF_MARK_ADD
			case .Delete:  bg = GITD_DIFF_DEL_BG;   mark = GITD_DIFF_MARK_DEL
			case .Empty:   bg = GITD_DIFF_EMPTY_BG
			}
			if side.kind != .Context { rl.DrawRectangleV({x, cy}, {half, dy}, bg) }
			if mark.a != 0 { rl.DrawRectangleV({x, cy}, {3, dy}, mark) }
			if side.line > 0 {
				num := fmt.tprintf("%d", side.line)
				nw  := rl.MeasureTextEx(font, to_cstring(num), fs, CHAR_SPACING).x
				rl.DrawTextEx(font, to_cstring(num), {x + gutter - 8 - nw, cy + 1}, fs, CHAR_SPACING, GITD_SUBDUED)
			}
			if side.text != "" {
				dlg_text(font, _gitd_expand_tabs(side.text), x + gutter, cy + 1, fs, CHAR_SPACING,
				         GITD_TEXT, x + half, 6)
			}
		}
		cy += dy
	}

	// Scrollbar with change markers, so changes are visible across the file
	track_x := px + pw - 6
	rl.DrawRectangleV({track_x, content_top}, {5, content_h}, GITD_HEADER)
	total := f32(len(rows))
	for start in d.diff.changed {
		r := rows[start]
		col := GITD_DIFF_MARK_DEL if r.right.kind == .Empty else GITD_DIFF_MARK_ADD
		if r.left.kind == .Delete && r.right.kind == .Add { col = GITD_YELLOW }
		rl.DrawRectangleV({track_x, content_top + content_h * f32(start) / total}, {5, 2}, col)
	}
	bar_h := max(16, content_h * f32(vis) / total)
	bar_y := content_top + content_h * f32(d.diff_scroll) / total
	rl.DrawRectangleLinesEx({track_x - 1, bar_y, 7, bar_h}, 1, GITD_SUBDUED)

	// Footer
	rl.DrawLineV({px, footer_y}, {px + pw, footer_y}, GITD_BORDER)
	info := fmt.tprintf("line %d/%d", d.diff_scroll + 1, len(rows))
	iw := rl.MeasureTextEx(font, to_cstring(info), FONT_SIZE - 2, CHAR_SPACING).x
	rl.DrawTextEx(font, to_cstring(info), {px + pw - iw - 14, footer_y + (GITD_FOOTER_H - ref.y) * 0.5}, FONT_SIZE - 2, CHAR_SPACING, GITD_SUBDUED)
	dlg_end()
}

// Tabs as spaces for display (raylib draws \t as a missing glyph)
_gitd_expand_tabs :: proc(s: string) -> string {
	if strings.index_byte(s, '\t') < 0 { return s }
	b := strings.builder_make(context.temp_allocator)
	col := 0
	for r in s {
		if r == '\t' {
			for _ in 0..<(4 - col % 4) { strings.write_byte(&b, ' '); col += 1 }
		} else {
			strings.write_rune(&b, r); col += 1
		}
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// Merge view
// ---------------------------------------------------------------------------

_gitd_draw_merge :: proc(d: ^Git_Dialog, m: ^git.Git_Manager, font: rl.Font, sw, sh: f32) {
	ms  := &d.merge
	ref := rl.MeasureTextEx(font, "M", FONT_SIZE, CHAR_SPACING)
	lh  := ref.y + 3

	n   := len(ms.blocks)
	if n == 0 { d.mode = .Status; return }
	blk := &ms.blocks[ms.selected]

	// Count resolved
	resolved := 0
	for b in ms.blocks { if b.resolution != .Unresolved { resolved += 1 } }

	// Panel sizing: header + two side-by-side panels (each GITD_ROW_MAX rows) + action bar + footer
	side_h    := GITD_SECTION_H + f32(GITD_ROW_MAX)*lh + 6
	panel_h   := GITD_HEADER_H + side_h + f32(32) + GITD_FOOTER_H
	panel_h    = min(panel_h, sh - 40)

	px := (sw - GITD_MERGE_W) * 0.5
	py := (sh - panel_h) * 0.5

	px, py = dlg_begin(px, py, GITD_MERGE_W, panel_h, GITD_BG, GITD_BORDER)

	// Header
	rl.DrawRectangleV({px, py}, {GITD_MERGE_W, GITD_HEADER_H}, GITD_HEADER)
	header_str := fmt.tprintf(" Merge Conflicts  %d/%d  —  conflict %d of %d",
		resolved, n, ms.selected+1, n)
	rl.DrawTextEx(font, to_cstring(header_str), {px+10, py + (GITD_HEADER_H-ref.y)*0.5}, FONT_SIZE, CHAR_SPACING, GITD_BLUE)

	// Resolution status: show "2/5" count
	status_str := fmt.tprintf("%d/%d resolved", resolved, n)
	status_w := rl.MeasureTextEx(font, to_cstring(status_str), FONT_SIZE-2, CHAR_SPACING).x
	rl.DrawTextEx(font, to_cstring(status_str), {px + GITD_MERGE_W - status_w - 12, py + (GITD_HEADER_H-ref.y)*0.5}, FONT_SIZE-2, CHAR_SPACING, GITD_SUBDUED)

	cy := py + GITD_HEADER_H

	// Two side-by-side panels
	left_x  := px + 2
	right_x := px + GITD_HALF_W + 4

	_draw_side :: proc(title, label: string, lines_arr: []string, bg_col, label_col: rl.Color,
	                   x, y, w, h: f32, scroll: ^int, font: rl.Font, ref: rl.Vector2, lh: f32) {
		rl.DrawRectangleV({x, y}, {w, GITD_SECTION_H}, GITD_SECTION)
		head := fmt.tprintf(" %s  %s", title, label)
		rl.DrawTextEx(font, to_cstring(head), {x+6, y + (GITD_SECTION_H-ref.y)*0.5}, FONT_SIZE-2, CHAR_SPACING, label_col)
		sy := y + GITD_SECTION_H

		n_lines := len(lines_arr)
		scroll_max := max(0, n_lines - GITD_ROW_MAX)
		scroll^ = clamp(scroll^, 0, scroll_max)

		clip_h := h - GITD_SECTION_H
		rl.BeginScissorMode(i32(x)+1, i32(sy), i32(w)-2, i32(clip_h))
		for i := 0; i < GITD_ROW_MAX && scroll^+i < n_lines; i += 1 {
			ly := sy + f32(i)*lh
			rl.DrawRectangleV({x+1, ly}, {w-2, lh}, bg_col)
			rl.DrawTextEx(font, to_cstring(lines_arr[scroll^+i]), {x+6, ly+1}, FONT_SIZE-1, CHAR_SPACING, GITD_TEXT)
		}
		if n_lines == 0 {
			rl.DrawTextEx(font, "(empty)", {x+8, sy+4}, FONT_SIZE-2, CHAR_SPACING, GITD_SUBDUED)
		}
		rl.EndScissorMode()
	}

	// Left: OURS (HEAD)  |  Right: THEIRS (incoming)
	_draw_side("CURRENT",  blk.ours_label,   blk.ours_lines,   GITD_GREEN_BG, GITD_GREEN,
	           left_x,  cy, GITD_HALF_W, side_h, &ms.ours_scroll,   font, ref, lh)
	dlg_restore() // re-enable panel scissor after _draw_side's EndScissorMode
	_draw_side("INCOMING", blk.theirs_label, blk.theirs_lines, GITD_RED_BG,   GITD_RED,
	           right_x, cy, GITD_HALF_W, side_h, &ms.theirs_scroll, font, ref, lh)
	dlg_restore() // re-enable panel scissor after _draw_side's EndScissorMode

	// Vertical divider between the two panels
	rl.DrawLineV({px + GITD_HALF_W + 2, cy}, {px + GITD_HALF_W + 2, cy + side_h}, GITD_BORDER)

	cy += side_h

	// Resolution buttons / current status
	rl.DrawLineV({px, cy}, {px+GITD_MERGE_W, cy}, GITD_BORDER)
	cy += 6

	res_str: string
	res_col: rl.Color
	switch blk.resolution {
	case .Ours:       res_str = "[v] Accept Current";  res_col = GITD_GREEN
	case .Theirs:     res_str = "[v] Accept Incoming"; res_col = GITD_RED
	case .Both:       res_str = "[v] Accept Both";     res_col = GITD_YELLOW
	case .Unresolved: res_str = "    Unresolved";      res_col = GITD_SUBDUED
	}
	rl.DrawTextEx(font, to_cstring(res_str), {px+10, cy + (ref.y)*0.5 - 2}, FONT_SIZE-1, CHAR_SPACING, res_col)

	// Action key hints on right
	act_hints: cstring = "[A] Current  [B] Incoming  [O] Both  [U] Undo"
	act_w := rl.MeasureTextEx(font, act_hints, FONT_SIZE-2, CHAR_SPACING).x
	rl.DrawTextEx(font, act_hints, {px+GITD_MERGE_W-act_w-10, cy + (ref.y)*0.5 - 2}, FONT_SIZE-2, CHAR_SPACING, GITD_SUBDUED)
	cy += f32(32)

	// Footer
	footer_y := py + panel_h - GITD_FOOTER_H
	rl.DrawLineV({px, footer_y}, {px+GITD_MERGE_W, footer_y}, GITD_BORDER)
	nav_hint: cstring = "J/K navigate conflicts  W write & stage  Esc back  Shift+Scroll = scroll incoming"
	rl.DrawTextEx(font, nav_hint, {px+10, footer_y + (GITD_FOOTER_H-ref.y)*0.5}, FONT_SIZE-2, CHAR_SPACING, GITD_SUBDUED)
	dlg_end()
}

// ---------------------------------------------------------------------------
// Branch picker overlay
// ---------------------------------------------------------------------------

_gitd_draw_branch_picker :: proc(d: ^Git_Dialog, m: ^git.Git_Manager, font: rl.Font, sw, sh: f32) {
	ref := rl.MeasureTextEx(font, "M", FONT_SIZE, CHAR_SPACING)

	BP_ENTRY_H  :: f32(22)
	BP_INPUT_H  :: f32(30)
	BP_FOOTER_H :: f32(24)

	filtered := _bp_filtered(d)
	n_vis    := min(len(filtered), GITD_BP_MAX)
	panel_h  := GITD_HEADER_H + BP_INPUT_H + f32(n_vis)*BP_ENTRY_H + BP_FOOTER_H + 8
	if n_vis == 0 { panel_h += BP_ENTRY_H } // space for "no match" text

	px := (sw - GITD_BP_W) * 0.5
	py := (sh - panel_h)   * 0.5

	// Dim everything behind
	rl.DrawRectangleV({0, 0}, {sw, sh}, rl.Color{0, 0, 0, 120})

	px, py = dlg_begin(px, py, GITD_BP_W, panel_h, GITD_BG, GITD_BORDER)

	// Header
	rl.DrawRectangleV({px, py}, {GITD_BP_W, GITD_HEADER_H}, GITD_HEADER)
	h_str := fmt.tprintf(" Merge Branch into %s", m.current.branch)
	rl.DrawTextEx(font, to_cstring(h_str), {px+10, py + (GITD_HEADER_H-ref.y)*0.5}, FONT_SIZE, CHAR_SPACING, GITD_BLUE)

	cy := py + GITD_HEADER_H

	// Filter input box
	rl.DrawRectangleLinesEx({px+8, cy+4, GITD_BP_W-16, BP_INPUT_H-8}, 1, GITD_BLUE)
	filter_str  := string(d.bp_filter[:])
	filter_cstr := to_cstring(filter_str) if filter_str != "" else cstring("Filter branches...")
	filter_col  := GITD_TEXT if filter_str != "" else GITD_SUBDUED
	text_x      := px + 14
	text_y      := cy + 4 + (BP_INPUT_H-8-ref.y)*0.5
	rl.DrawTextEx(font, filter_cstr, {text_x, text_y}, FONT_SIZE-1, CHAR_SPACING, filter_col)
	// Blinking cursor at end of typed text
	cur_x := text_x + rl.MeasureTextEx(font, to_cstring(filter_str), FONT_SIZE-1, CHAR_SPACING).x
	rl.DrawLineV({cur_x+1, cy+8}, {cur_x+1, cy+BP_INPUT_H-8}, GITD_BLUE)
	cy += BP_INPUT_H

	// Branch list
	list_h := f32(max(n_vis, 1)) * BP_ENTRY_H
	if len(filtered) == 0 {
		no_match: cstring = "no branches match"
		rl.DrawTextEx(font, no_match, {px+14, cy+4}, FONT_SIZE-2, CHAR_SPACING, GITD_SUBDUED)
	} else {
		for i := 0; i < n_vis; i += 1 {
			fi := d.bp_scroll + i
			if fi >= len(filtered) { break }
			bi  := filtered[fi]
			b   := d.bp_branches[bi]
			is_sel     := fi == d.bp_selected
			is_current := b == m.current.branch
			ey  := cy + f32(i)*BP_ENTRY_H
			if is_sel { rl.DrawRectangleV({px, ey}, {GITD_BP_W, BP_ENTRY_H}, GITD_SEL) }
			// Current branch marker
			mark: cstring = "* " if is_current else "  "
			mark_col := GITD_GREEN
			rl.DrawTextEx(font, mark, {px+10, ey + (BP_ENTRY_H-ref.y)*0.5}, FONT_SIZE-1, CHAR_SPACING, mark_col)
			name_col := GITD_YELLOW if is_sel else GITD_TEXT
			dlg_text(font, b, px+28, ey + (BP_ENTRY_H-ref.y)*0.5, FONT_SIZE-1, CHAR_SPACING, name_col, px+GITD_BP_W, 8)
		}
	}
	cy += list_h

	// Footer
	rl.DrawLineV({px, cy}, {px+GITD_BP_W, cy}, GITD_BORDER)
	fp_hint: cstring = "Enter merge  J/K or Up/Down navigate  type to filter  Esc cancel"
	rl.DrawTextEx(font, fp_hint, {px+10, cy + (BP_FOOTER_H-ref.y)*0.5}, FONT_SIZE-2, CHAR_SPACING, GITD_SUBDUED)
	dlg_end()
}
