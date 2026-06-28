package editor

import "core:fmt"
import rl "vendor:raylib"

// Catppuccin Mocha
BG          :: rl.Color{30,  30,  46,  255}
TEXT        :: rl.Color{205, 214, 244, 255}
CURSOR_COL  :: rl.Color{137, 180, 250, 255}
LINENUM     :: rl.Color{88,  91,  112, 255}
LINENUM_CUR :: rl.Color{205, 214, 244, 255}
STATUS_BG   :: rl.Color{24,  24,  37,  255}
SEL_BG      :: rl.Color{69,  71,  90,  255}
MSG_COL     :: rl.Color{243, 139, 168, 255}
DIVIDER_COL :: rl.Color{49,  50,  68,  255}
ACCENT_COL  :: rl.Color{137, 180, 250, 255}
INACTIVE_TOP:: rl.Color{49,  50,  68,  255}

FONT_SIZE    : f32 = 18 // mutable — changed by Ctrl+= / Ctrl+-
CHAR_SPACING : f32 : 0
LINE_SPACING : f32 : 3
GUTTER_PAD   : f32 : 8

// Layout constants shared across files
MSG_LINE_H   :: f32(22) // global message bar at very bottom
PANE_TOP_PAD :: f32(2)  // accent strip height at top of each pane
STATUS_H     :: f32(22) // per-pane status bar height

SCROLL_SPEED :: f32(15) // scroll animation lerp speed

render :: proc(e: ^Editor, font: rl.Font) {
	sw       := f32(rl.GetScreenWidth())
	sh       := f32(rl.GetScreenHeight())
	usable_h := sh - MSG_LINE_H

	rl.ClearBackground(BG)

	// Render each pane in its rect
	for i in 0 ..< len(e.panes) {
		ox, oy, ow, oh := get_pane_rect(e, i, sw, usable_h)
		if ow < 1 || oh < 1 do continue
		rl.BeginScissorMode(i32(ox), i32(oy), i32(ow), i32(oh))
		render_pane(e, i, font, ox, oy, ow, oh)
		rl.EndScissorMode()
	}

	// Divider between panes
	if len(e.panes) > 1 {
		switch e.split {
		case .Vertical:
			mid := sw * e.split_ratio
			rl.DrawRectangleV({mid - DIVIDER_W * 0.5, 0}, {DIVIDER_W, usable_h}, DIVIDER_COL)
		case .Horizontal:
			mid := usable_h * e.split_ratio
			rl.DrawRectangleV({0, mid - DIVIDER_W * 0.5}, {sw, DIVIDER_W}, DIVIDER_COL)
		case .None:
		}
	}

	// Global message line
	my := sh - MSG_LINE_H
	rl.DrawRectangleV({0, my}, {sw, MSG_LINE_H}, STATUS_BG)
	if e.msg != "" {
		rl.DrawTextEx(font, to_cstring(e.msg), {4, my + 3}, FONT_SIZE, CHAR_SPACING, MSG_COL)
	}

	// Save-as dialog — above message line, below palette
	if e.save_dlg.open {
		render_save_dialog(e, font, sw, sh)
	}

	// Mark / Goto dialogs
	if e.mark_dlg.open { render_mark_dialog(e, font, sw, sh) }
	if e.goto_dlg.open { render_goto_dialog(e, font, sw, sh) }

	// Find/replace overlay
	if e.find_rep.open { render_find_replace(e, font, sw, sh) }

	// Outline overlay
	render_outline(&e.outline, active_pane(e), font, sw, sh)

	// Recent files switcher
	render_recents_dialog(&e.recents, font, sw, sh)

	// Workspace picker — rendered above everything except palette
	render_workspace_dialog(&e.workspace_dlg, font, sw, sh)

	// Go to Definition picker
	render_def_picker(&e.def_picker, font, sw, sh)

	// Delete confirm overlay
	if e.delete_confirm { render_delete_confirm(e, font, sw, sh) }

	// File tree overlay
	render_file_tree(&e.file_tree, font)

	// Palette overlay — always on top
	palette_render(&e.palette, font)
}

render_pane :: proc(e: ^Editor, idx: int, font: rl.Font, ox, oy, ow, oh: f32) {
	p         := &e.panes[idx]
	is_active := idx == e.active

	ref := rl.MeasureTextEx(font, "M", FONT_SIZE, CHAR_SPACING)
	cw  := ref.x
	ch  := ref.y + LINE_SPACING

	text_area_h := oh - STATUS_H - PANE_TOP_PAD
	vis_lines   := int(text_area_h / ch)
	if vis_lines < 1 do return

	adjust_scroll(p, vis_lines)

	// Advance smooth scroll animation toward integer target
	dt   := rl.GetFrameTime()
	diff := f32(p.scroll) - p.scroll_anim
	if diff > 0.001 || diff < -0.001 {
		p.scroll_anim += diff * min(dt * SCROLL_SPEED, 1.0)
	} else {
		p.scroll_anim = f32(p.scroll)
	}

	// Pane background
	rl.DrawRectangleV({ox, oy}, {ow, oh}, BG)

	// Top accent strip
	strip_col := ACCENT_COL if is_active else INACTIVE_TOP
	rl.DrawRectangleV({ox, oy}, {ow, PANE_TOP_PAD}, strip_col)

	total_lines := buffer_line_count(&p.buf)
	digs        := digit_count(total_lines)
	text_x      := ox + f32(digs)*cw + GUTTER_PAD*2

	cur_line, cur_col := buffer_pos_to_line_col(&p.buf, p.cursor)
	sel_active        := has_selection(p)
	s_lo              := sel_lo(p) if sel_active else 0
	s_hi              := sel_hi(p) if sel_active else 0

	text_top := oy + PANE_TOP_PAD

	// Draw one extra line to fill partial-scroll gaps at top and bottom
	first_li := max(0, int(p.scroll_anim))
	for vi := 0; ; vi += 1 {
		li := first_li + vi
		if li >= total_lines { break }

		y := text_top + (f32(li) - p.scroll_anim) * ch
		if y >= text_top + text_area_h { break }

		line_bytes := buffer_get_line_bytes(&p.buf, li)
		line_start := buffer_line_start(&p.buf, li)

		// Line number — right-aligned in gutter
		ln_col  := LINENUM_CUR if li == cur_line else LINENUM
		ln_str  := fmt.tprintf("%d", li + 1)
		ln_cstr := to_cstring(ln_str)
		ln_w    := rl.MeasureTextEx(font, ln_cstr, FONT_SIZE, CHAR_SPACING).x
		rl.DrawTextEx(font, ln_cstr, {text_x - ln_w - GUTTER_PAD, y}, FONT_SIZE, CHAR_SPACING, ln_col)

		// Selection highlight (primary)
		line_end := line_start + len(line_bytes)
		if sel_active {
			ov_lo := max(s_lo, line_start)
			ov_hi := min(s_hi, line_end)
			if ov_lo < ov_hi {
				rl.DrawRectangleV(
					{text_x + f32(ov_lo - line_start)*cw, y},
					{f32(ov_hi - ov_lo)*cw, ch},
					SEL_BG)
			}
		}
		// Extra cursor selections
		for &ec in p.extras {
			if ec.pos == ec.anchor { continue }
			ec_lo := min(ec.pos, ec.anchor)
			ec_hi := max(ec.pos, ec.anchor)
			ov_lo := max(ec_lo, line_start)
			ov_hi := min(ec_hi, line_end)
			if ov_lo < ov_hi {
				rl.DrawRectangleV(
					{text_x + f32(ov_lo - line_start)*cw, y},
					{f32(ov_hi - ov_lo)*cw, ch},
					SEL_BG)
			}
		}

		// Find/replace match highlights (rounded, strong)
		// Odin slice iteration: for value, index in slice
		fr := &e.find_rep
		if fr.open && len(fr.search_buf) > 0 && len(fr.matches) > 0 {
			line_end := line_start + len(line_bytes)
			for mpos, midx in fr.matches {
				mlen  := fr.match_lens[midx]
				m_end := mpos + mlen
				if mpos >= line_end || m_end <= line_start { continue }
				ov_lo := max(mpos, line_start)
				ov_hi := min(m_end, line_end)
				rx    := text_x + f32(ov_lo - line_start)*cw
				rw    := f32(ov_hi - ov_lo)*cw
				rec   := rl.Rectangle{rx, y + 1, rw, ch - 2}
				round := f32(0.35)
				segs  := i32(6)
				if midx == fr.current {
					rl.DrawRectangleRounded(rec, round, segs, rl.Color{250, 219, 20, 170})
					rl.DrawRectangleRoundedLinesEx(rec, round, segs, 1.5, rl.Color{250, 200, 0, 255})
				} else {
					rl.DrawRectangleRounded(rec, round, segs, rl.Color{250, 219, 20, 70})
					rl.DrawRectangleRoundedLinesEx(rec, round, segs, 1, rl.Color{250, 219, 20, 160})
				}
			}
		}

		// Text with syntax highlighting
		draw_highlighted_line(font, line_bytes, text_x, y, p.lang)

		// Beam cursor — primary (active pane only)
		if is_active && li == cur_line {
			rl.DrawRectangleV({text_x + f32(cur_col)*cw, y}, {2, ch}, CURSOR_COL)
		}
		// Extra cursor beams
		if is_active {
			for &ec in p.extras {
				ec_line, ec_col := buffer_pos_to_line_col(&p.buf, ec.pos)
				if ec_line == li {
					rl.DrawRectangleV({text_x + f32(ec_col)*cw, y}, {2, ch}, CURSOR_COL)
				}
			}
		}
	}

	// Per-pane status bar
	sy := oy + oh - STATUS_H
	rl.DrawRectangleV({ox, sy}, {ow, STATUS_H}, STATUS_BG)

	fname    := p.filename if p.filename != "" else "untitled"
	modified := "● " if p.dirty else ""
	rl.DrawTextEx(font, to_cstring(fmt.tprintf(" %s%s", modified, fname)),
		{ox + 4, sy + 3}, FONT_SIZE, CHAR_SPACING, TEXT)

	pos_str := fmt.tprintf(" Ln %d, Col %d ", cur_line + 1, cur_col + 1)
	pos_w   := rl.MeasureTextEx(font, to_cstring(pos_str), FONT_SIZE, CHAR_SPACING).x
	rl.DrawTextEx(font, to_cstring(pos_str),
		{ox + ow - pos_w, sy + 3}, FONT_SIZE, CHAR_SPACING, TEXT)

	if mc_has_extras(p) {
		mc_str := fmt.tprintf(" %d cursors ", len(p.extras) + 1)
		mc_w   := rl.MeasureTextEx(font, to_cstring(mc_str), FONT_SIZE, CHAR_SPACING).x
		rl.DrawTextEx(font, to_cstring(mc_str),
			{ox + ow - pos_w - mc_w, sy + 3}, FONT_SIZE, CHAR_SPACING, ACCENT_COL)
	}

	// Active pane indicator: accent left border on status bar
	if is_active {
		rl.DrawRectangleV({ox, sy}, {3, STATUS_H}, ACCENT_COL)
	}
}

render_save_dialog :: proc(e: ^Editor, font: rl.Font, sw, sh: f32) {
	DIALOG_H  :: f32(38)
	DIALOG_BG :: rl.Color{30,  32,  48,  255}
	BORDER    :: rl.Color{137, 180, 250, 255}
	SUBDUED   :: rl.Color{108, 112, 134, 255}

	dy := sh - MSG_LINE_H - DIALOG_H
	rl.DrawRectangleV({0, dy}, {sw, DIALOG_H}, DIALOG_BG)
	rl.DrawRectangleLinesEx({0, dy, sw, DIALOG_H}, 1, BORDER)

	ref := rl.MeasureTextEx(font, "M", FONT_SIZE, CHAR_SPACING)
	ty  := dy + (DIALOG_H - ref.y) * 0.5

	// Label
	label  := to_cstring("Rename: " if e.save_dlg.rename else "Save As: ")
	label_w := rl.MeasureTextEx(font, label, FONT_SIZE, CHAR_SPACING).x
	rl.DrawTextEx(font, label, {8, ty}, FONT_SIZE, CHAR_SPACING, LINENUM_CUR)

	// Input text + beam cursor
	inp_s := string(e.save_dlg.input[:])
	inp_x := f32(8) + label_w
	rl.DrawTextEx(font, to_cstring(inp_s), {inp_x, ty}, FONT_SIZE, CHAR_SPACING, TEXT)
	inp_w := rl.MeasureTextEx(font, to_cstring(inp_s), FONT_SIZE, CHAR_SPACING).x
	rl.DrawRectangleV({inp_x + inp_w, ty}, {2, ref.y}, CURSOR_COL)

	// Hint right-aligned
	hint   := to_cstring("Enter to rename · Esc to cancel" if e.save_dlg.rename else "Enter to save · Esc to cancel")
	hint_w := rl.MeasureTextEx(font, hint, FONT_SIZE - 2, CHAR_SPACING).x
	rl.DrawTextEx(font, hint, {sw - hint_w - 8, ty + 2}, FONT_SIZE - 2, CHAR_SPACING, SUBDUED)
}

render_delete_confirm :: proc(e: ^Editor, font: rl.Font, sw, sh: f32) {
	p := active_pane(e)

	PANEL_W  :: f32(420)
	PANEL_H  :: f32(100)
	OVERLAY  :: rl.Color{0,   0,   0,   160}
	PANEL_BG :: rl.Color{30,  30,  46,  255}
	DANGER   :: rl.Color{243, 139, 168, 255}
	SUBDUED  :: rl.Color{108, 112, 134, 255}

	px := (sw - PANEL_W) * 0.5
	py := (sh - PANEL_H) * 0.5

	rl.DrawRectangle(0, 0, i32(sw), i32(sh), OVERLAY)
	rl.DrawRectangleV({px, py}, {PANEL_W, PANEL_H}, PANEL_BG)
	rl.DrawRectangleLinesEx({px, py, PANEL_W, PANEL_H}, 1, DANGER)

	ref := rl.MeasureTextEx(font, "M", FONT_SIZE, CHAR_SPACING)

	rl.DrawTextEx(font, "Delete file?", {px + 16, py + 12}, FONT_SIZE, CHAR_SPACING, DANGER)

	bname := to_cstring(path_basename(p.filename) if p.filename != "" else "untitled")
	rl.DrawTextEx(font, bname, {px + 16, py + 12 + ref.y + 6}, FONT_SIZE, CHAR_SPACING, TEXT)

	hint   := to_cstring("Y  confirm  *  Esc / N  cancel")
	hint_w := rl.MeasureTextEx(font, hint, FONT_SIZE - 2, CHAR_SPACING).x
	rl.DrawTextEx(font, hint, {px + (PANEL_W - hint_w)*0.5, py + PANEL_H - ref.y - 10}, FONT_SIZE - 2, CHAR_SPACING, SUBDUED)
}

render_mark_dialog :: proc(e: ^Editor, font: rl.Font, sw, sh: f32) {
	DIALOG_H  :: f32(38)
	DIALOG_BG :: rl.Color{30, 32, 48, 255}
	BORDER    :: rl.Color{166, 227, 161, 255} // green accent for marks
	SUBDUED   :: rl.Color{108, 112, 134, 255}

	dy := sh - MSG_LINE_H - DIALOG_H - 40 // above save dialog position
	rl.DrawRectangleV({0, dy}, {sw, DIALOG_H}, DIALOG_BG)
	rl.DrawRectangleLinesEx({0, dy, sw, DIALOG_H}, 1, BORDER)

	ref := rl.MeasureTextEx(font, "M", FONT_SIZE, CHAR_SPACING)
	ty  := dy + (DIALOG_H - ref.y) * 0.5

	label   := to_cstring("Mark: ")
	label_w := rl.MeasureTextEx(font, label, FONT_SIZE, CHAR_SPACING).x
	rl.DrawTextEx(font, label, {8, ty}, FONT_SIZE, CHAR_SPACING, BORDER)

	inp_s := string(e.mark_dlg.input[:])
	inp_x := f32(8) + label_w
	rl.DrawTextEx(font, to_cstring(inp_s), {inp_x, ty}, FONT_SIZE, CHAR_SPACING, TEXT)
	inp_w := rl.MeasureTextEx(font, to_cstring(inp_s), FONT_SIZE, CHAR_SPACING).x
	rl.DrawRectangleV({inp_x + inp_w, ty}, {2, ref.y}, CURSOR_COL)

	hint   := to_cstring("Enter to mark · Esc to cancel")
	hint_w := rl.MeasureTextEx(font, hint, FONT_SIZE - 2, CHAR_SPACING).x
	rl.DrawTextEx(font, hint, {sw - hint_w - 8, ty + 2}, FONT_SIZE - 2, CHAR_SPACING, SUBDUED)
}

render_goto_dialog :: proc(e: ^Editor, font: rl.Font, sw, sh: f32) {
	DIALOG_H  :: f32(38)
	DIALOG_BG :: rl.Color{30, 32, 48, 255}
	BORDER    :: rl.Color{250, 179, 135, 255} // peach accent for goto
	SUBDUED   :: rl.Color{108, 112, 134, 255}

	dy := sh - MSG_LINE_H - DIALOG_H - 40
	rl.DrawRectangleV({0, dy}, {sw, DIALOG_H}, DIALOG_BG)
	rl.DrawRectangleLinesEx({0, dy, sw, DIALOG_H}, 1, BORDER)

	ref := rl.MeasureTextEx(font, "M", FONT_SIZE, CHAR_SPACING)
	ty  := dy + (DIALOG_H - ref.y) * 0.5

	label   := to_cstring("Go to line: ")
	label_w := rl.MeasureTextEx(font, label, FONT_SIZE, CHAR_SPACING).x
	rl.DrawTextEx(font, label, {8, ty}, FONT_SIZE, CHAR_SPACING, BORDER)

	inp_s := string(e.goto_dlg.input[:])
	inp_x := f32(8) + label_w
	rl.DrawTextEx(font, to_cstring(inp_s), {inp_x, ty}, FONT_SIZE, CHAR_SPACING, TEXT)
	inp_w := rl.MeasureTextEx(font, to_cstring(inp_s), FONT_SIZE, CHAR_SPACING).x
	rl.DrawRectangleV({inp_x + inp_w, ty}, {2, ref.y}, CURSOR_COL)

	hint   := to_cstring("Enter to jump · Esc to cancel")
	hint_w := rl.MeasureTextEx(font, hint, FONT_SIZE - 2, CHAR_SPACING).x
	rl.DrawTextEx(font, hint, {sw - hint_w - 8, ty + 2}, FONT_SIZE - 2, CHAR_SPACING, SUBDUED)
}

render_find_replace :: proc(e: ^Editor, font: rl.Font, sw, sh: f32) {
	fr := &e.find_rep
	p  := active_pane(e)

	W        :: f32(420)
	PAD      :: f32(6)
	HDR_H    :: f32(22)
	INPUT_H  :: f32(32)
	NAV_H    :: f32(26)
	ITEM_H   :: f32(22)
	HINT_H   :: f32(32)
	SEP_H    :: f32(1)
	BTN_W    :: f32(26)
	BTN_H    :: f32(22)
	LNUM_W   :: f32(46)
	MAX_ITEMS :: 8

	DIALOG_BG    :: rl.Color{24, 24, 40, 248}
	BORDER       :: rl.Color{137, 180, 250, 255}
	SUBDUED      :: rl.Color{108, 112, 134, 255}
	ACT_BDR      :: rl.Color{137, 180, 250, 255}
	INACT_BDR    :: rl.Color{58,  60,  78,  255}
	MATCH_HL_BG  :: rl.Color{249, 226, 175,  80}
	MATCH_HL_FG  :: rl.Color{249, 226, 175, 255}
	MATCH_OK_COL :: rl.Color{166, 227, 161, 255}
	RESULT_SEL   :: rl.Color{56,  84, 160,  255}
	RESULT_ALT   :: rl.Color{32,  32,  52,  180}
	TOG_ON_BG    :: rl.Color{41,  54,  82,  255}
	TOG_OFF_BG   :: rl.Color{32,  33,  50,  255}

	n_vis := min(MAX_ITEMS, len(fr.matches)) if fr.show_results else 0

	panel_h := PAD + HDR_H + PAD + INPUT_H + PAD + NAV_H + PAD + HINT_H + PAD
	if fr.focus == 1    { panel_h += INPUT_H + PAD }
	if n_vis > 0        { panel_h += SEP_H + f32(n_vis)*ITEM_H + SEP_H }

	px := sw - W - 4
	py := f32(4)

	rl.DrawRectangleV({px, py}, {W, panel_h}, DIALOG_BG)
	rl.DrawRectangleLinesEx({px, py, W, panel_h}, 1, BORDER)

	ref := rl.MeasureTextEx(font, "M", FONT_SIZE, CHAR_SPACING)
	cy  := py + PAD

	// ── HEADER ──────────────────────────────────────────────
	hdr_label := to_cstring("find") if fr.focus == 0 else to_cstring("replace")
	rl.DrawTextEx(font, hdr_label, {px + PAD, cy + (HDR_H - ref.y)*0.5}, FONT_SIZE, CHAR_SPACING, SUBDUED)

	if fr.regex_err {
		err_label := to_cstring("invalid regex")
		err_w := rl.MeasureTextEx(font, err_label, FONT_SIZE - 2, CHAR_SPACING).x
		rl.DrawTextEx(font, err_label, {px + W - err_w - PAD, cy + (HDR_H - ref.y)*0.5},
		              FONT_SIZE - 2, CHAR_SPACING, MSG_COL)
	} else if len(fr.search_buf) > 0 {
		cnt_str: string
		cnt_col: rl.Color
		if len(fr.matches) == 0 {
			cnt_str = "no matches"
			cnt_col = MSG_COL
		} else {
			cnt_str = fmt.tprintf("%d / %d", fr.current + 1, len(fr.matches))
			cnt_col = MATCH_OK_COL
		}
		cnt_w := rl.MeasureTextEx(font, to_cstring(cnt_str), FONT_SIZE - 2, CHAR_SPACING).x
		rl.DrawTextEx(font, to_cstring(cnt_str), {px + W - cnt_w - PAD, cy + (HDR_H - ref.y)*0.5},
		              FONT_SIZE - 2, CHAR_SPACING, cnt_col)
	}
	cy += HDR_H + PAD

	// ── SEARCH INPUT + TOGGLE BUTTONS ───────────────────────
	btns_total := f32(3)*(BTN_W + 2) - 2
	input_w    := W - PAD*2 - PAD - btns_total
	row0_bdr   := ACT_BDR if fr.focus == 0 else INACT_BDR
	rl.DrawRectangleLinesEx({px + PAD, cy, input_w, INPUT_H}, 1, row0_bdr)

	s0   := string(fr.search_buf[:])
	s0x  := px + PAD + 4
	s0ty := cy + (INPUT_H - ref.y)*0.5
	rl.BeginScissorMode(i32(px + PAD + 1), i32(cy + 1), i32(input_w - 2), i32(INPUT_H - 2))
	s0w := rl.MeasureTextEx(font, to_cstring(s0), FONT_SIZE, CHAR_SPACING).x
	if fr.focus == 0 && fr.all_sel && len(fr.search_buf) > 0 {
		rl.DrawRectangleV({s0x, s0ty}, {s0w, ref.y}, SEL_BG)
	}
	rl.DrawTextEx(font, to_cstring(s0), {s0x, s0ty}, FONT_SIZE, CHAR_SPACING, TEXT)
	if fr.focus == 0 && !fr.all_sel {
		rl.DrawRectangleV({s0x + s0w, s0ty}, {2, ref.y}, CURSOR_COL)
	}
	rl.EndScissorMode()

	// Toggle buttons: [Aa] [ab] [.*]
	tog_labels  := [3]cstring{"Aa", "ab", " *"}
	tog_active  := [3]bool{fr.case_sensitive, fr.whole_word, fr.use_regex}
	btns_x      := px + PAD + input_w + PAD
	btn_ty      := cy + (INPUT_H - BTN_H) * 0.5
	for t in 0..<3 {
		bx     := btns_x + f32(t)*(BTN_W + 2)
		on     := tog_active[t]
		bg     := TOG_ON_BG  if on else TOG_OFF_BG
		bdr    := ACT_BDR    if on else INACT_BDR
		lbl_c  := ACCENT_COL if on else SUBDUED
		rl.DrawRectangleV({bx, btn_ty}, {BTN_W, BTN_H}, bg)
		rl.DrawRectangleLinesEx({bx, btn_ty, BTN_W, BTN_H}, 1, bdr)
		lbl_w := rl.MeasureTextEx(font, tog_labels[t], FONT_SIZE - 2, CHAR_SPACING).x
		rl.DrawTextEx(font, tog_labels[t], {bx + (BTN_W - lbl_w)*0.5, cy + (INPUT_H - ref.y)*0.5},
		              FONT_SIZE - 2, CHAR_SPACING, lbl_c)
	}
	cy += INPUT_H + PAD

	// ── REPLACE INPUT (when focus == 1) ─────────────────────
	if fr.focus == 1 {
		rl.DrawRectangleLinesEx({px + PAD, cy, W - PAD*2, INPUT_H}, 1, ACT_BDR)
		s1   := string(fr.replace_buf[:])
		s1x  := px + PAD + 4
		s1ty := cy + (INPUT_H - ref.y)*0.5
		rl.BeginScissorMode(i32(px + PAD + 1), i32(cy + 1), i32(W - PAD*2 - 2), i32(INPUT_H - 2))
		s1w := rl.MeasureTextEx(font, to_cstring(s1), FONT_SIZE, CHAR_SPACING).x
		if fr.all_sel && len(fr.replace_buf) > 0 {
			rl.DrawRectangleV({s1x, s1ty}, {s1w, ref.y}, SEL_BG)
		}
		rl.DrawTextEx(font, to_cstring(s1), {s1x, s1ty}, FONT_SIZE, CHAR_SPACING, TEXT)
		if !fr.all_sel {
			rl.DrawRectangleV({s1x + s1w, s1ty}, {2, ref.y}, CURSOR_COL)
		}
		rl.EndScissorMode()
		cy += INPUT_H + PAD
	}

	// ── NAV ROW ─────────────────────────────────────────────
	nav_btn_ty := cy + (NAV_H - BTN_H)*0.5
	// Up arrow
	rl.DrawRectangleLinesEx({px + PAD, nav_btn_ty, BTN_W, BTN_H}, 1, INACT_BDR)
	up_s := to_cstring("↑")
	up_w := rl.MeasureTextEx(font, up_s, FONT_SIZE, CHAR_SPACING).x
	rl.DrawTextEx(font, up_s, {px + PAD + (BTN_W - up_w)*0.5, nav_btn_ty + (BTN_H - ref.y)*0.5},
	              FONT_SIZE, CHAR_SPACING, TEXT)
	// Down arrow
	rl.DrawRectangleLinesEx({px + PAD + BTN_W + 2, nav_btn_ty, BTN_W, BTN_H}, 1, INACT_BDR)
	dn_s := to_cstring("↓")
	dn_w := rl.MeasureTextEx(font, dn_s, FONT_SIZE, CHAR_SPACING).x
	rl.DrawTextEx(font, dn_s, {px + PAD + BTN_W + 2 + (BTN_W - dn_w)*0.5, nav_btn_ty + (BTN_H - ref.y)*0.5},
	              FONT_SIZE, CHAR_SPACING, TEXT)
	// Results toggle ≡
	res_btn_x := px + W - PAD - BTN_W
	res_on    := fr.show_results
	res_bg    := TOG_ON_BG  if res_on else TOG_OFF_BG
	res_bdr   := ACT_BDR    if res_on else INACT_BDR
	rl.DrawRectangleV({res_btn_x, nav_btn_ty}, {BTN_W, BTN_H}, res_bg)
	rl.DrawRectangleLinesEx({res_btn_x, nav_btn_ty, BTN_W, BTN_H}, 1, res_bdr)
	eq_s := to_cstring("≡")
	eq_w := rl.MeasureTextEx(font, eq_s, FONT_SIZE, CHAR_SPACING).x
	eq_c := ACCENT_COL if res_on else SUBDUED
	rl.DrawTextEx(font, eq_s, {res_btn_x + (BTN_W - eq_w)*0.5, nav_btn_ty + (BTN_H - ref.y)*0.5},
	              FONT_SIZE, CHAR_SPACING, eq_c)
	cy += NAV_H + PAD

	// ── RESULTS LIST ─────────────────────────────────────────
	if n_vis > 0 {
		rl.DrawRectangleV({px, cy}, {W, SEP_H}, INACT_BDR)
		cy += SEP_H

		content_x := px + LNUM_W + 4
		content_w := W - LNUM_W - PAD - 4
		ref_sm    := rl.MeasureTextEx(font, "M", FONT_SIZE - 2, CHAR_SPACING)

		for i in 0..<n_vis {
			idx := fr.results_scroll + i
			if idx >= len(fr.matches) { break }

			pos  := fr.matches[idx]
			mlen := fr.match_lens[idx]
			line, col := buffer_pos_to_line_col(&p.buf, pos)
			lb   := buffer_get_line_bytes(&p.buf, line)

			ry := cy + f32(i)*ITEM_H

			if idx == fr.current {
				rl.DrawRectangleV({px + 1, ry}, {W - 2, ITEM_H}, RESULT_SEL)
			} else if i % 2 == 1 {
				rl.DrawRectangleV({px + 1, ry}, {W - 2, ITEM_H}, RESULT_ALT)
			}

			// Line number (right-aligned in LNUM_W column)
			ln_str := fmt.tprintf("%d", line + 1)
			ln_w   := rl.MeasureTextEx(font, to_cstring(ln_str), FONT_SIZE - 2, CHAR_SPACING).x
			rl.DrawTextEx(font, to_cstring(ln_str),
			              {px + LNUM_W - ln_w - 4, ry + (ITEM_H - ref_sm.y)*0.5},
			              FONT_SIZE - 2, CHAR_SPACING, SUBDUED)
			rl.DrawRectangleV({px + LNUM_W, ry}, {SEP_H, ITEM_H}, INACT_BDR)

			// Line content with match highlighted
			safe_col := min(col, len(lb))
			safe_end := min(col + mlen, len(lb))
			pre      := string(lb[:safe_col])
			mat      := string(lb[safe_col:safe_end])
			pst      := string(lb[safe_end:])

			pre_w := rl.MeasureTextEx(font, to_cstring(pre), FONT_SIZE, CHAR_SPACING).x
			mat_w := rl.MeasureTextEx(font, to_cstring(mat), FONT_SIZE, CHAR_SPACING).x

			// Offset so match stays visible (at most 35% from left)
			offset := max(f32(0), pre_w - content_w*0.35)

			item_ty := ry + (ITEM_H - ref.y)*0.5
			rl.BeginScissorMode(i32(px + LNUM_W + 1), i32(ry), i32(content_w + 4), i32(ITEM_H))
			rl.DrawTextEx(font, to_cstring(pre), {content_x - offset, item_ty},
			              FONT_SIZE, CHAR_SPACING, SUBDUED)
			rl.DrawRectangleV({content_x - offset + pre_w, item_ty}, {mat_w, ref.y}, MATCH_HL_BG)
			rl.DrawTextEx(font, to_cstring(mat), {content_x - offset + pre_w, item_ty},
			              FONT_SIZE, CHAR_SPACING, MATCH_HL_FG)
			rl.DrawTextEx(font, to_cstring(pst), {content_x - offset + pre_w + mat_w, item_ty},
			              FONT_SIZE, CHAR_SPACING, TEXT)
			rl.EndScissorMode()
		}

		cy += f32(n_vis)*ITEM_H + SEP_H
	}

	// ── HINT ROW (two lines) ─────────────────────────────────
	hs := FONT_SIZE - 5
	rl.DrawTextEx(font, "Alt+C:case  Alt+W:word  Alt+R:regex  Alt+L:list",
	              {px + PAD, cy + 2}, hs, CHAR_SPACING, SUBDUED)
	rl.DrawTextEx(font, "Tab:switch  ↑↓:next  Enter:replace  Esc:close",
	              {px + PAD, cy + 2 + hs + 2}, hs, CHAR_SPACING, SUBDUED)
}

adjust_scroll :: proc(p: ^Pane, vis: int) {
	line, _ := buffer_pos_to_line_col(&p.buf, p.cursor)
	if line < p.scroll {
		p.scroll = line
	} else if vis > 0 && line >= p.scroll + vis {
		p.scroll = line - vis + 1
	}
	// Also ensure the most recently added extra cursor is visible
	if len(p.extras) > 0 {
		el, _ := buffer_pos_to_line_col(&p.buf, p.extras[len(p.extras)-1].pos)
		if el < p.scroll { p.scroll = el }
		else if vis > 0 && el >= p.scroll + vis { p.scroll = el - vis + 1 }
	}
}

digit_count :: proc(n: int) -> int {
	if n <= 0 do return 1
	c, x := 0, n
	for x > 0 { c += 1; x /= 10 }
	return c
}

to_cstring :: proc(s: string) -> cstring {
	buf := make([]u8, len(s) + 1, context.temp_allocator)
	copy(buf, s)
	buf[len(s)] = 0
	return cstring(raw_data(buf))
}
