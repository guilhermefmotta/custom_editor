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
// (working_tree.odin); this dialog only hosts the Diff view (and the branch
// picker) on top of it and hides itself when back to .Status. Conflicts are
// resolved in the `merge_resolver` panel (merge_resolver.odin).
Git_Dialog_Mode  :: enum { Status, Diff }

Git_Dialog :: struct {
	visible:    bool,
	mode:       Git_Dialog_Mode,
	diff_scroll: int,
	diff:        git.File_Diff, // whole-file side-by-side diff (Diff mode)
	diff_path:   string,        // heap, repo-relative path shown in Diff mode
	diff_change: int,           // index into diff.changed of the focused change
	msg:        string, // heap
	msg_ok:     bool,
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
	d.bp_branches = make([dynamic]string)
	d.bp_filter   = make([dynamic]u8)
}

git_dialog_destroy :: proc(d: ^Git_Dialog) {
	if d.msg != "" { delete(d.msg) }
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

// Opens the conflict resolver (`merge_resolver` panel) on a conflicted file
// (repo-relative path). The old in-dialog Merge mode is gone (ADR 0012).
git_dialog_open_merge :: proc(e: ^Editor, rel_path: string) {
	merge_resolver_open_file(e, rel_path)
	_rep_key = .KEY_NULL
}

// Opens the "merge branch into current" picker.
git_dialog_open_branch_picker :: proc(e: ^Editor) {
	d := &e.git_dialog
	d.visible = true
	d.mode    = .Status
	_bp_open(d, e.git_mgr)
	_rep_key = .KEY_NULL
}

git_dialog_close :: proc(d: ^Git_Dialog) {
	d.visible = false
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
// Input handler
// ---------------------------------------------------------------------------

git_dialog_handle_input :: proc(d: ^Git_Dialog, e: ^Editor) {
	if !d.visible { return }
	m := e.git_mgr

	// Branch picker takes full priority
	if d.bp_open { _git_bp_input(d, m); return }

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
			_gitd_set_msg(d, true, "merge conflict - opening the resolver")
			merge_resolver_open_file(container_of(d, Editor, "git_dialog"), "")
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
	m := e.git_mgr

	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())

	switch d.mode {
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
