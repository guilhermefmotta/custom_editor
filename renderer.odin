package editor

import "core:fmt"
import "core:math"
import lsp  "./lsp"
import dbg  "./debug"
import conf "./config"
import rl   "vendor:raylib"

// Cursor blink phase for this frame (render → render_pane).
@(private="file") _cursor_visible := true

// Slow breathing pulse in [0, 1], used for subtle gutter-marker animations
// (breakpoints, LSP warning dots) so they read as "live" without being loud.
// ADR 0016: it never asks for frames — it breathes while the editor renders
// for another reason and holds still when idle (no wake-ups just for it).
_gutter_pulse :: proc() -> f32 {
	return 0.5 + 0.5*math.sin(f32(rl.GetTime()) * 3.2)
}

// Mutable — updated each frame from active theme (default: Catppuccin Mocha)
BG           := rl.Color{30,  30,  46,  255}
TEXT         := rl.Color{205, 214, 244, 255}
CURSOR_COL   := rl.Color{137, 180, 250, 255}
LINENUM      := rl.Color{88,  91,  112, 255}
LINENUM_CUR  := rl.Color{205, 214, 244, 255}
CUR_LINE_BG  := rl.Color{40,  40,  58,  255}
STATUS_BG    := rl.Color{24,  24,  37,  255}
SEL_BG       := rl.Color{69,  71,  90,  255}
MSG_COL      := rl.Color{243, 139, 168, 255}
DIVIDER_COL  := rl.Color{49,  50,  68,  255}
ACCENT_COL   := rl.Color{137, 180, 250, 255}
INACTIVE_TOP := rl.Color{49,  50,  68,  255}
DIAG_WARN_COL:= rl.Color{249, 226, 175, 255}
DIAG_INFO_COL:= rl.Color{137, 180, 250, 255}
DIAG_HINT_COL:= rl.Color{166, 227, 161, 255}
FUNC_COL     := rl.Color{137, 180, 250, 255}
DIFF_ADD_COL := rl.Color{166, 227, 161, 255}
DIFF_ADD_BG  := rl.Color{30,  50,  35,  255}
DIFF_DEL_COL := rl.Color{243, 139, 168, 255}
DIFF_DEL_BG  := rl.Color{50,  30,  35,  255}

FONT_SIZE    : f32 = 18 // mutable — changed by Ctrl+= / Ctrl+-
CHAR_SPACING : f32 : 0
LINE_SPACING : f32 : 3
GUTTER_PAD   : f32 : 8

// Layout constants shared across files
MSG_LINE_H   :: f32(22) // global message bar at very bottom
PANE_TOP_PAD :: f32(2)  // accent strip height at top of each pane
STATUS_H     :: f32(22) // per-pane status bar height
TAB_BAR_H    :: f32(28) // per-pane tab bar height

SCROLL_SPEED :: f32(15) // scroll animation lerp speed

// Convert config.Color [4]u8 → rl.Color
@(private="file")
_c :: #force_inline proc(c: conf.Color) -> rl.Color { return {c[0], c[1], c[2], c[3]} }

// Pull all UI + syntax colors from active theme into package-level mutable vars.
// Called every frame so switching theme takes effect immediately.
_apply_theme :: proc(e: ^Editor) {
	t := conf.registry_active_theme(&e.registry)
	if t == nil { return }
	ui := t.ui
	BG          = _c(ui.background)
	TEXT        = _c(ui.foreground)
	CURSOR_COL  = _c(ui.cursor)
	LINENUM     = _c(ui.line_number)
	LINENUM_CUR = _c(ui.line_number_cur)
	CUR_LINE_BG = _c(ui.line_highlight)
	STATUS_BG   = _c(ui.status_bar_bg)
	SEL_BG      = _c(ui.selection)
	MSG_COL     = _c(ui.diag_error)
	DIVIDER_COL = _c(ui.border)
	ACCENT_COL  = _c(ui.accent)
	INACTIVE_TOP= _c(ui.border)

	// Diagnostic / diff semantic colors
	DIAG_WARN_COL = _c(ui.diag_warn)
	DIAG_INFO_COL = _c(ui.diag_info)
	DIAG_HINT_COL = _c(ui.diag_hint)
	DIFF_ADD_COL  = _c(ui.diag_hint)
	DIFF_DEL_COL  = _c(ui.diag_error)
	DIFF_ADD_BG   = _mix_bg(_c(ui.diag_hint),  _c(ui.background))
	DIFF_DEL_BG   = _mix_bg(_c(ui.diag_error), _c(ui.background))

	// Syntax token colors
	sx := t.syntax
	TOKEN_COLORS[.Default]    = _c(sx.variable)
	TOKEN_COLORS[.Keyword]    = _c(sx.keyword)
	TOKEN_COLORS[.Type]       = _c(sx.type_)
	TOKEN_COLORS[.String_Lit] = _c(sx.string_)
	TOKEN_COLORS[.Number]     = _c(sx.number)
	TOKEN_COLORS[.Comment]    = _c(sx.comment)
	TOKEN_COLORS[.Operator]   = _c(sx.operator)
	TOKEN_COLORS[.Builtin]    = _c(sx.builtin)
	TOKEN_COLORS[.Macro]      = _c(sx.preproc)
	TOKEN_COLORS[.Attribute]  = _c(sx.label)
	FUNC_COL = _c(sx.function_)

	// git_dialog package-level vars
	GITD_BG      = STATUS_BG
	GITD_BORDER  = DIVIDER_COL
	GITD_SEL     = SEL_BG
	GITD_HEADER  = BG
	GITD_SECTION = STATUS_BG
	GITD_GREEN   = DIFF_ADD_COL
	GITD_GREEN_BG= DIFF_ADD_BG
	GITD_RED     = DIFF_DEL_COL
	GITD_RED_BG  = DIFF_DEL_BG
	GITD_BLUE    = ACCENT_COL

	// debug_panel package-level vars
	DBGP_BG      = BG
	DBGP_HDR_BG  = STATUS_BG
	DBGP_BORDER  = DIVIDER_COL
	DBGP_SEL     = SEL_BG
	DBGP_TEXT    = TEXT
	DBGP_SUBDUED = LINENUM
	DBGP_GREEN   = DIFF_ADD_COL
	DBGP_RED     = MSG_COL
	DBGP_YELLOW  = DIAG_WARN_COL
	DBGP_BLUE    = ACCENT_COL

	// tab bar
	TAB_ACTIVE_BG   = STATUS_BG
	TAB_INACTIVE_BG = rl.Color{BG.r, BG.g, BG.b, 180}

	// suggest_widget package-level vars
	SUGGEST_BG      = rl.Color{BG.r, BG.g, BG.b, 245}
	SUGGEST_BORDER  = SEL_BG
	SUGGEST_SEL     = DIVIDER_COL
	SUGGEST_SEL_BDR = ACCENT_COL
	SUGGEST_TEXT    = TEXT
	SUGGEST_DETAIL  = LINENUM
	SUGGEST_KIND_FN = FUNC_COL
	SUGGEST_KIND_KW = TOKEN_COLORS[.Keyword]
	SUGGEST_KIND_TY = TOKEN_COLORS[.Type]
	SUGGEST_KIND_VA = TEXT
	SUGGEST_KIND_SN = TOKEN_COLORS[.Number]
	SUGGEST_KIND_MO = TOKEN_COLORS[.Builtin]
	HOVER_BG        = rl.Color{STATUS_BG.r, STATUS_BG.g, STATUS_BG.b, 240}
	HOVER_BORDER    = SEL_BG
	SIGH_BG         = rl.Color{BG.r, BG.g, BG.b, 230}
	SIGH_NORMAL     = TEXT
	SIGH_BORDER     = SEL_BG
	SIGH_ACTIVE     = DIAG_WARN_COL
}

@(private="file")
_mix_bg :: proc(fg, bg: rl.Color) -> rl.Color {
	m :: proc(a, b: u8, t: f32) -> u8 { return u8(f32(a)*t + f32(b)*(1.0-t)) }
	return {m(fg.r,bg.r,0.22), m(fg.g,bg.g,0.22), m(fg.b,bg.b,0.22), 255}
}

render :: proc(e: ^Editor, font: rl.Font) {
	sw       := f32(screen_w())
	sh       := f32(screen_h())
	usable_h := sh - MSG_LINE_H
	if e.debug_panel.visible { usable_h -= DEBUG_PANEL_H }

	_apply_theme(e)
	dlg_frame_tick()
	// Cursor blink (ADR 0016): wakes only at the blink transitions, and stops
	// (solid cursor) FRAME_BLINK_IDLE_STOP s after the last input.
	blink_next: f64
	_cursor_visible, blink_next = cursor_blink(e.cfg.cursor.blink, e.cfg.cursor.blink_rate, frame_since_input())
	if blink_next != FRAME_NO_DEADLINE { frame_request_in(blink_next) }
	ui_registry_update(e, frame_dt)

	// Pump debug adapter messages every frame
	dbg.debug_tick(&e.debug_mgr)
	debug_panel_update(e, &e.debug_panel)

	rl.ClearBackground(BG)

	// Render each pane in its rect
	for i in 0 ..< len(e.panes) {
		ox, oy, ow, oh := get_pane_rect(e, i, sw, usable_h)
		if ow < 1 || oh < 1 do continue
		ui_scissor_begin(i32(ox), i32(oy), i32(ow), i32(oh))
		render_pane(e, i, font, ox, oy, ow, oh)
		rl.EndScissorMode()
	}

	// Divider(s) between panes
	n_panes := len(e.panes)
	if n_panes == 2 {
		switch e.split {
		case .Vertical:
			mid := sw * e.split_ratio
			rl.DrawRectangleV({mid - DIVIDER_W * 0.5, 0}, {DIVIDER_W, usable_h}, DIVIDER_COL)
		case .Horizontal:
			// below the repo tab strip (repos_bar_h), matching get_pane_rect
			top := repos_bar_h(e)
			mid := top + (usable_h - top) * e.split_ratio
			rl.DrawRectangleV({0, mid - DIVIDER_W * 0.5}, {sw, DIVIDER_W}, DIVIDER_COL)
		case .None:
		}
	} else if n_panes > 2 {
		col_w := sw / f32(n_panes)
		for i in 1 ..< n_panes {
			dx := f32(i) * col_w - DIVIDER_W * 0.5
			rl.DrawRectangleV({dx, 0}, {DIVIDER_W, usable_h}, DIVIDER_COL)
		}
	}

	// Registered dock panels (ui_registry.odin) — above panes, below dialogs
	ui_registry_draw(e, font, .Dock, sw, sh)

	// Global message line — doubles as the Vim Command_Line input (:, /, ?)
	// so what you're typing is actually visible while typing it.
	my := sh - MSG_LINE_H
	rl.DrawRectangleV({0, my}, {sw, MSG_LINE_H}, STATUS_BG)
	if e.cfg.editor.keymap_mode == .Vim && e.vim.mode == .Command_Line {
		kind_buf: [1]u8 = {e.vim.cmdline_kind}
		cmd_str := fmt.tprintf("%s%s", string(kind_buf[:]), string(e.vim.cmdline_buf[:]))
		rl.DrawTextEx(font, to_cstring(cmd_str), {4, my + 3}, FONT_SIZE, CHAR_SPACING, TEXT)
		tw := rl.MeasureTextEx(font, to_cstring(cmd_str), FONT_SIZE, CHAR_SPACING).x
		rl.DrawRectangleV({4 + tw + 2, my + 2}, {2, FONT_SIZE}, CURSOR_COL)
	} else if e.msg != "" {
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

	// Git panel
	git_dialog_draw(&e.git_dialog, e, font)

	// LSP control dialog
	render_lsp_dialog(&e.lsp_dialog, e, font, sw, sh)

	// Go to Definition picker
	render_def_picker(&e.def_picker, font, sw, sh)

	// Rename dialog
	render_rename_dialog(&e.rename_dlg, font, sw, sh)

	// Code action dialog
	render_code_action_dialog(&e.code_action_dlg, font, sw, sh)

	// Delete confirm overlay
	if e.delete_confirm { render_delete_confirm(e, font, sw, sh) }

	// File tree overlay
	render_file_tree(&e.file_tree, font)

	// Debug panel (bottom dock) + attach dialog (above most things)
	debug_panel_draw(e, &e.debug_panel, font, sw, sh, MSG_LINE_H)
	debug_eval_draw(&e.debug_eval, e, font, sw, sh)
	debug_attach_draw(&e.debug_attach, e, font, sw, sh)

	// Registered overlay panels + banner (ui_registry.odin)
	ui_registry_draw(e, font, .Overlay, sw, sh)

	// Palette overlay — always on top
	palette_render(&e.palette, e, font)
}

render_pane :: proc(e: ^Editor, idx: int, font: rl.Font, ox, oy, ow, oh: f32) {
	p         := &e.panes[idx]
	is_active := idx == e.active

	ref := rl.MeasureTextEx(font, "M", FONT_SIZE, CHAR_SPACING)
	cw  := ref.x
	ch  := ref.y + LINE_SPACING

	tab_bar_h   := TAB_BAR_H if len(p.tabs) > 0 else f32(0)
	status_top  := e.cfg.editor.status_bar_position != "bottom"
	text_area_h := oh - STATUS_H - PANE_TOP_PAD - tab_bar_h
	vis_lines   := int(text_area_h / ch)
	if vis_lines < 1 do return

	adjust_scroll(p, vis_lines)

	// Advance smooth scroll animation toward integer target
	// frame_anim_dt: clamped, so a scroll right after a long sleep (ADR 0016)
	// still eases in instead of jumping.
	dt   := frame_anim_dt
	diff := f32(p.scroll) - p.scroll_anim
	if diff > 0.001 || diff < -0.001 {
		p.scroll_anim += diff * min(dt * SCROLL_SPEED, 1.0)
		frame_request_anim()
	} else {
		p.scroll_anim = f32(p.scroll)
	}

	// Pane background
	rl.DrawRectangleV({ox, oy}, {ow, oh}, BG)

	// Top accent strip
	strip_col := ACCENT_COL if is_active else INACTIVE_TOP
	rl.DrawRectangleV({ox, oy}, {ow, PANE_TOP_PAD}, strip_col)

	// Tab bar
	if len(p.tabs) > 0 {
		_render_tab_bar(p, font, ox, oy + PANE_TOP_PAD, ow, TAB_BAR_H, is_active)
	}

	// Markdown preview replaces the raw-text/gutter/status rendering below
	// entirely — own minimal status bar, then bail before the per-line loop.
	if p.md_preview.visible {
		content_top := oy + PANE_TOP_PAD + tab_bar_h + (STATUS_H if status_top else 0)
		content_h   := oh - PANE_TOP_PAD - tab_bar_h - STATUS_H
		md_preview_draw(p, font, ox, content_top, ow, content_h)

		sy := (oy + PANE_TOP_PAD) if status_top else (oy + oh - STATUS_H)
		rl.DrawRectangleV({ox, sy}, {ow, STATUS_H}, STATUS_BG)
		fname := path_basename(p.filename) if p.filename != "" else "untitled"
		rl.DrawTextEx(font, to_cstring(fmt.tprintf(" %s — Markdown Preview (Ctrl+Shift+V to edit)", fname)),
			{ox + 4, sy + 3}, FONT_SIZE, CHAR_SPACING, TEXT)
		return
	}

	total_lines := buffer_line_count(&p.buf)
	digs        := digit_count(total_lines)
	blame_w     := git_blame_gutter_width(e, cw)
	mark_ox     := ox + blame_w // left edge for hunk marks / breakpoints / exec arrow, past the blame column
	text_x      := mark_ox + f32(digs)*cw + GUTTER_PAD*2 if p.show_line_numbers else mark_ox + GUTTER_PAD*2

	cur_line, cur_col := buffer_pos_to_line_col(&p.buf, p.cursor)
	sel_active        := has_selection(p)
	s_lo              := sel_lo(p) if sel_active else 0
	s_hi              := sel_hi(p) if sel_active else 0

	// Pre-compute selection line/col for enhanced rendering
	s_lo_line, s_lo_col, s_hi_line, s_hi_col: int
	if sel_active {
		s_lo_line, s_lo_col = buffer_pos_to_line_col(&p.buf, s_lo)
		s_hi_line, s_hi_col = buffer_pos_to_line_col(&p.buf, s_hi)
		// Selection ending at col 0 of line N visually ends at end of line N-1
		if s_hi_col == 0 && s_hi_line > s_lo_line {
			s_hi_line -= 1
			s_hi_col   = buffer_line_length(&p.buf, s_hi_line)
		}
	}
	sel_first_y: f32 = -1  // y of first selected visible line
	sel_last_y:  f32 = -1  // y of last selected visible line

	// Vim Visual_Block (Ctrl-V): same column range on every line between
	// anchor and cursor, not a linear byte range — draw a rectangle per line
	// instead of the linear first/last/full-width-middle shape below.
	is_block_visual := sel_active && e.cfg.editor.keymap_mode == .Vim && e.vim.mode == .Visual_Block
	block_lo_col, block_hi_col: int
	if is_block_visual {
		_, anchor_col := buffer_pos_to_line_col(&p.buf, p.sel_anchor)
		block_lo_col = min(anchor_col, cur_col)
		block_hi_col = max(anchor_col, cur_col) + 1
	}

	text_top   := oy + PANE_TOP_PAD + tab_bar_h + (STATUS_H if status_top else 0)
	pane_diags := lsp.manager_get_diags(&e.lsp_mgr, p.filename)

	// Bracket match — only for the focused pane's own cursor.
	bm_a, bm_b, bm_ok := 0, 0, false
	bm_a_line, bm_a_col, bm_b_line, bm_b_col: int
	if is_active {
		bm_a, bm_b, bm_ok = find_matching_bracket(p)
		if bm_ok {
			bm_a_line, bm_a_col = buffer_pos_to_line_col(&p.buf, bm_a)
			bm_b_line, bm_b_col = buffer_pos_to_line_col(&p.buf, bm_b)
		}
	}

	// Draw one extra line to fill partial-scroll gaps at top and bottom
	first_li := max(0, int(p.scroll_anim))
	for vi := 0; ; vi += 1 {
		li := first_li + vi
		if li >= total_lines { break }

		y := text_top + (f32(li) - p.scroll_anim) * ch
		if y >= text_top + text_area_h { break }

		line_bytes := buffer_get_line_bytes(&p.buf, li)
		line_start := buffer_line_start(&p.buf, li)

		// Current-line highlight
		if is_active && li == cur_line {
			rl.DrawRectangleV({ox, y}, {ow, ch}, CUR_LINE_BG)
		}

		// Blame gutter (date + author, drawn once per commit block)
		git_draw_blame_gutter(e, p.filename, li, ox, y, ch, font)

		// Git gutter mark (thin colored bar at left edge of gutter)
		git_draw_line_mark(e, p.filename, li + 1, mark_ox, y, ch)

		// Breakpoint marker — outline around the line number when numbers are
		// shown (so the digit stays legible), solid filled block when hidden
		// (nothing to keep visible, so a plain marker reads better). Alpha
		// breathes gently so an active breakpoint reads as "live".
		if p.filename != "" && dbg.bp_has(&e.debug_mgr, p.filename, li + 1) {
			bp_a := u8(140 + _gutter_pulse()*115)
			gx := mark_ox + GUTTER_PAD*0.5
			gw := text_x - mark_ox - GUTTER_PAD*0.5
			if p.show_line_numbers {
				rl.DrawRectangleLinesEx({gx, y + 1, gw, ch - 2}, 1.5, rl.Color{243, 139, 168, bp_a})
			} else {
				rl.DrawRectangleV({gx, y + 1}, {gw, ch - 2}, rl.Color{243, 139, 168, bp_a})
			}
		}

		// Current execution line arrow/highlight (when debugger is paused here)
		if e.debug_mgr.stop_file == p.filename && e.debug_mgr.stop_line == li + 1 {
			rl.DrawRectangleV({ox, y}, {ow, ch}, rl.Color{120, 20, 32, 90})
			// Arrow indicator
			cx := mark_ox + GUTTER_PAD*1.5
			cy := y + ch*0.5
			rl.DrawTriangle(
				{cx - 4, cy - 5}, {cx - 4, cy + 5}, {cx + 5, cy},
				rl.Color{243, 139, 168, 255})
		}

		// Line number — right-aligned in gutter
		if p.show_line_numbers {
			ln_col  := LINENUM_CUR if li == cur_line else LINENUM
			ln_str  := fmt.tprintf("%d", li + 1)
			ln_cstr := to_cstring(ln_str)
			ln_w    := rl.MeasureTextEx(font, ln_cstr, FONT_SIZE, CHAR_SPACING).x
			rl.DrawTextEx(font, ln_cstr, {text_x - ln_w - GUTTER_PAD, y + (ch - ref.y)*0.5}, FONT_SIZE, CHAR_SPACING, ln_col)
		}

		// Selection highlight (primary) — rounded single-line, extended multi-line
		line_end := line_start + len(line_bytes)
		if sel_active && li >= s_lo_line && li <= s_hi_line {
			if is_block_visual {
				xl := text_x + f32(block_lo_col)*cw
				xr := text_x + f32(block_hi_col)*cw
				if sel_first_y < 0 { sel_first_y = y }
				sel_last_y = y
				rl.DrawRectangleV({xl, y}, {xr - xl, ch}, SEL_BG)
			} else {
				is_first_sel := li == s_lo_line
				is_last_sel  := li == s_hi_line
				xl := text_x + f32(s_lo_col if is_first_sel else 0)*cw
				xr := text_x + f32(s_hi_col)*cw if is_last_sel else ox + ow
				if xl < xr {
					if is_first_sel { sel_first_y = y }
					if is_last_sel  { sel_last_y  = y }
					if is_first_sel && is_last_sel {
						rl.DrawRectangleRounded({xl, y + 1, xr - xl, ch - 2}, 0.35, 6, SEL_BG)
					} else {
						rl.DrawRectangleV({xl, y}, {xr - xl, ch}, SEL_BG)
					}
				}
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

		// Bracket-match highlight — the pair box breathes gently, same idea
		// as the breakpoint marker, so it reads as "linked" rather than static.
		if bm_ok && (li == bm_a_line || li == bm_b_line) {
			bm_a_val := u8(160 + _gutter_pulse()*95)
			BM_COL      := rl.Color{ACCENT_COL.r, ACCENT_COL.g, ACCENT_COL.b, bm_a_val}
			BM_FILL_COL := rl.Color{ACCENT_COL.r, ACCENT_COL.g, ACCENT_COL.b, 50}
			if li == bm_a_line {
				bx := text_x + f32(bm_a_col)*cw
				rl.DrawRectangleRounded({bx, y + 1, cw, ch - 2}, 0.3, 4, BM_FILL_COL)
				rl.DrawRectangleRoundedLinesEx({bx, y + 1, cw, ch - 2}, 0.3, 4, 1.5, BM_COL)
			}
			if li == bm_b_line {
				bx := text_x + f32(bm_b_col)*cw
				rl.DrawRectangleRounded({bx, y + 1, cw, ch - 2}, 0.3, 4, BM_FILL_COL)
				rl.DrawRectangleRoundedLinesEx({bx, y + 1, cw, ch - 2}, 0.3, 4, 1.5, BM_COL)
			}
		}

		// Text with syntax highlighting
		draw_highlighted_line(font, line_bytes, text_x, y, p.lang)

		// Diagnostic squiggle + inline message
		if len(pane_diags) > 0 {
			line_end_x := text_x + f32(len(line_bytes))*cw
			for &d in pane_diags {
				if d.range.start.line != li { continue }
				sq_col: rl.Color
				switch d.severity {
				case .Error:       sq_col = {243, 139, 168, 200}
				case .Warning:     sq_col = {249, 226, 175, 200}
				case .Information: sq_col = {137, 220, 235, 200}
				case .Hint:        sq_col = {166, 227, 161, 160}
				}
				// Gutter dot — centered in the row; warnings (the LSP's yellow)
				// breathe with the same pulse as breakpoint markers.
				dot_col := sq_col
				if d.severity == .Warning {
					dot_col.a = u8(140 + _gutter_pulse()*115)
				}
				rl.DrawCircleV({ox + 4, y + ch * 0.5}, 3, dot_col)
				// Squiggle under entire line
				sq_y := y + FONT_SIZE - 1
				sq_x := text_x
				for sq_x + 4 < line_end_x {
					ny := sq_y - 2 if int(sq_x) % 8 < 4 else sq_y + 0
					rl.DrawLineV({sq_x, sq_y}, {sq_x + 4, ny}, sq_col)
					sq_x += 4
				}
				break
			}
		}

		// Cursor — primary (active pane only). Vim mode shows a block cursor
		// in Normal/Visual/Replace (translucent so the glyph underneath still
		// reads) and the usual thin beam in Insert — matches the real editor's
		// modal convention instead of always using the modeless beam.
		if is_active && li == cur_line && _cursor_visible {
			if _vim_cursor_is_block(e) {
				rl.DrawRectangleV({text_x + f32(cur_col)*cw, y}, {cw, ch}, rl.Color{CURSOR_COL.r, CURSOR_COL.g, CURSOR_COL.b, 130})
			} else {
				rl.DrawRectangleV({text_x + f32(cur_col)*cw, y}, {2, ch}, CURSOR_COL)
			}
		}
		// Extra cursor beams
		if is_active && _cursor_visible {
			for &ec in p.extras {
				ec_line, ec_col := buffer_pos_to_line_col(&p.buf, ec.pos)
				if ec_line == li {
					rl.DrawRectangleV({text_x + f32(ec_col)*cw, y}, {2, ch}, CURSOR_COL)
				}
			}
		}
	}

	// Selection border outline — drawn after text so it's always visible
	if sel_active && sel_first_y >= 0 && sel_last_y >= 0 {
		x_lo    := text_x + f32(block_lo_col if is_block_visual else s_lo_col)*cw
		x_hi    := text_x + f32(block_hi_col if is_block_visual else s_hi_col)*cw
		x_right := ox + ow
		y0      := sel_first_y
		y_last  := sel_last_y
		bdr     := rl.Color{ACCENT_COL.r, ACCENT_COL.g, ACCENT_COL.b, 170}

		if is_block_visual {
			rl.DrawRectangleLinesEx({x_lo, y0 + 1, x_hi - x_lo, (y_last - y0) + ch - 2}, 1.5, bdr)
		} else if s_lo_line == s_hi_line {
			rl.DrawRectangleRoundedLinesEx({x_lo, y0 + 1, x_hi - x_lo, ch - 2}, 0.35, 6, 1.5, bdr)
		} else {
			rl.DrawLineEx({x_lo,    y0},         {x_right, y0},         1, bdr)  // top of first row
			rl.DrawLineEx({x_right, y0},         {x_right, y_last},     1, bdr)  // right edge down
			rl.DrawLineEx({x_right, y_last},     {x_hi,    y_last},     1, bdr)  // step: top of last row
			rl.DrawLineEx({x_hi,    y_last},     {x_hi,    y_last+ch},  1, bdr)  // right of last row
			rl.DrawLineEx({x_hi,    y_last+ch},  {text_x,  y_last+ch},  1, bdr)  // bottom
			rl.DrawLineEx({text_x,  y_last+ch},  {text_x,  y0+ch},      1, bdr)  // left edge up
			rl.DrawLineEx({text_x,  y0+ch},      {x_lo,    y0+ch},      1, bdr)  // step: bottom of first row
			rl.DrawLineEx({x_lo,    y0+ch},      {x_lo,    y0},         1, bdr)  // left of first row
		}
	}

	// Per-pane status bar
	sy := (oy + PANE_TOP_PAD) if status_top else (oy + oh - STATUS_H)
	rl.DrawRectangleV({ox, sy}, {ow, STATUS_H}, STATUS_BG)

	name_x := ox + 4
	if badge_text, badge_col := _keymap_badge(e); badge_text != "" {
		badge_w := rl.MeasureTextEx(font, to_cstring(badge_text), FONT_SIZE, CHAR_SPACING).x
		rl.DrawRectangleV({ox, sy}, {badge_w, STATUS_H}, badge_col)
		rl.DrawTextEx(font, to_cstring(badge_text), {ox, sy + 3}, FONT_SIZE, CHAR_SPACING, BG)
		name_x = ox + badge_w + 6
	}

	fname    := path_basename(p.filename) if p.filename != "" else "untitled"
	modified := "* " if p.dirty else ""
	rl.DrawTextEx(font, to_cstring(fmt.tprintf(" %s%s", modified, fname)),
		{name_x, sy + 3}, FONT_SIZE, CHAR_SPACING, TEXT)

	// Breadcrumb: current symbol at cursor
	{
		sym := _breadcrumb_symbol(e, p, cur_line)
		if sym != "" {
			sym_w := rl.MeasureTextEx(font, to_cstring(sym), FONT_SIZE - 2, CHAR_SPACING).x
			sym_x := ox + ow / 2 - sym_w / 2
			rl.DrawTextEx(font, to_cstring(sym), {sym_x, sy + 4}, FONT_SIZE - 2, CHAR_SPACING, LINENUM)
		}
	}

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

	// LSP status badge (right side, before pos)
	{
		lsp_str: string
		lsp_col: rl.Color
		lc := lsp.lsp_manager_find_client_for_path(&e.lsp_mgr, p.filename)
		inst_info := lsp.lsp_manager_install_info_for_path(&e.lsp_mgr, p.filename)
		if lc == nil && inst_info.state == .Running {
			lsp_str = " LSP:installing... "
			lsp_col = rl.Color{249, 226, 175, 255}
		} else if lc == nil {
			lsp_str = " LSP:off "
			lsp_col = rl.Color{88, 91, 112, 255}
		} else {
			switch lc.state {
			case .Created, .Starting, .Initializing:
				lsp_str = " LSP:... "
				lsp_col = rl.Color{249, 226, 175, 255}
			case .Running:
				lsp_str = " LSP:on "
				lsp_col = rl.Color{166, 227, 161, 255}
			case .Shutting_Down, .Stopped:
				lsp_str = " LSP:err "
				lsp_col = rl.Color{243, 139, 168, 255}
			}
		}
		lsp_w := rl.MeasureTextEx(font, to_cstring(lsp_str), FONT_SIZE - 2, CHAR_SPACING).x
		lsp_x := ox + ow - pos_w - lsp_w - 6
		rl.DrawRectangleRounded({lsp_x, sy + 3, lsp_w, STATUS_H - 6}, 0.4, 4, rl.Color{lsp_col.r, lsp_col.g, lsp_col.b, 30})
		rl.DrawTextEx(font, to_cstring(lsp_str), {lsp_x, sy + 4}, FONT_SIZE - 2, CHAR_SPACING, lsp_col)

		// Git branch badge (right side, left of LSP)
		if e.git_mgr.current.branch != "" {
			br_str := fmt.tprintf(" %s ", e.git_mgr.current.branch)
			br_col := rl.Color{166, 227, 161, 255}
			br_w   := rl.MeasureTextEx(font, to_cstring(br_str), FONT_SIZE - 2, CHAR_SPACING).x
			br_x   := lsp_x - br_w - 6
			rl.DrawRectangleRounded({br_x, sy + 3, br_w, STATUS_H - 6}, 0.4, 4, rl.Color{br_col.r, br_col.g, br_col.b, 30})
			rl.DrawTextEx(font, to_cstring(br_str), {br_x, sy + 4}, FONT_SIZE - 2, CHAR_SPACING, br_col)
		}
	}

	// Active pane indicator: accent left border on status bar
	if is_active {
		rl.DrawRectangleV({ox, sy}, {3, STATUS_H}, ACCENT_COL)
	}

	// LSP overlays — only for active pane
	if is_active {
		cursor_x := text_x + f32(cur_col)*cw
		cursor_y  := text_top + (f32(cur_line) - p.scroll_anim) * ch

		c := _get_client(e, p)

		// Signature help bar
		if p.lsp.show_sig_help {
			render_sig_help(c, font, ox, text_top, ow, cursor_y)
		}

		// Suggest / completion widget
		render_suggest_widget(p, font, ox, oy, ow, oh, cursor_x, cursor_y)

		// Hover popup (only when suggest not visible)
		if !p.suggest.visible && p.lsp.show_hover {
			render_hover_popup(c, font, ox, oy, ow, oh, cursor_x, cursor_y)
		}
	}
}

render_save_dialog :: proc(e: ^Editor, font: rl.Font, sw, sh: f32) {
	DIALOG_H  :: f32(38)
	DIALOG_BG := STATUS_BG
	BORDER    := ACCENT_COL
	SUBDUED   := LINENUM

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
	OVERLAY  :: rl.Color{0, 0, 0, 160}
	PANEL_BG := STATUS_BG
	DANGER   := MSG_COL
	SUBDUED  := LINENUM

	px := (sw - PANEL_W) * 0.5
	py := (sh - PANEL_H) * 0.5

	rl.DrawRectangle(0, 0, i32(sw), i32(sh), OVERLAY)
	px, py = dlg_begin(px, py, PANEL_W, PANEL_H, PANEL_BG, DANGER)

	ref := rl.MeasureTextEx(font, "M", FONT_SIZE, CHAR_SPACING)

	rl.DrawTextEx(font, "Delete file?", {px + 16, py + 12}, FONT_SIZE, CHAR_SPACING, DANGER)

	bname := path_basename(p.filename) if p.filename != "" else "untitled"
	dlg_text(font, bname, px + 16, py + 12 + ref.y + 6, FONT_SIZE, CHAR_SPACING, TEXT, px + PANEL_W, 12)

	hint   := to_cstring("Y  confirm  *  Esc / N  cancel")
	hint_w := rl.MeasureTextEx(font, hint, FONT_SIZE - 2, CHAR_SPACING).x
	rl.DrawTextEx(font, hint, {px + (PANEL_W - hint_w)*0.5, py + PANEL_H - ref.y - 10}, FONT_SIZE - 2, CHAR_SPACING, SUBDUED)
	dlg_end()
}

render_mark_dialog :: proc(e: ^Editor, font: rl.Font, sw, sh: f32) {
	DIALOG_H  :: f32(38)
	DIALOG_BG := STATUS_BG
	BORDER    := DIFF_ADD_COL // green accent for marks
	SUBDUED   := LINENUM

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
	DIALOG_BG := STATUS_BG
	BORDER    := TOKEN_COLORS[.Number] // peach/orange accent for goto
	SUBDUED   := LINENUM

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

	// Theme-driven (package-level vars synced every frame in _apply_theme),
	// not hardcoded — this dialog used to ignore the active theme entirely.
	DIALOG_BG    := rl.Color{STATUS_BG.r, STATUS_BG.g, STATUS_BG.b, 248}
	BORDER       := ACCENT_COL
	SUBDUED      := LINENUM
	ACT_BDR      := ACCENT_COL
	INACT_BDR    := DIVIDER_COL
	MATCH_HL_BG  := rl.Color{DIAG_WARN_COL.r, DIAG_WARN_COL.g, DIAG_WARN_COL.b, 80}
	MATCH_HL_FG  := DIAG_WARN_COL
	MATCH_OK_COL := DIFF_ADD_COL
	RESULT_SEL   := SEL_BG
	RESULT_ALT   := rl.Color{STATUS_BG.r, STATUS_BG.g, STATUS_BG.b, 180}
	TOG_ON_BG    := rl.Color{ACCENT_COL.r, ACCENT_COL.g, ACCENT_COL.b, 60}
	TOG_OFF_BG   := rl.Color{STATUS_BG.r, STATUS_BG.g, STATUS_BG.b, 255}

	n_vis := min(MAX_ITEMS, len(fr.matches)) if fr.show_results else 0

	panel_h := PAD + HDR_H + PAD + INPUT_H + PAD + NAV_H + PAD + HINT_H + PAD
	if fr.focus == 1    { panel_h += INPUT_H + PAD }
	if n_vis > 0        { panel_h += SEP_H + f32(n_vis)*ITEM_H + SEP_H }

	px := sw - W - 4
	py := f32(4)

	px, py = dlg_begin(px, py, W, panel_h, DIALOG_BG, BORDER)

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
	ui_scissor_begin(i32(px + PAD + 1), i32(cy + 1), i32(input_w - 2), i32(INPUT_H - 2))
	s0w := rl.MeasureTextEx(font, to_cstring(s0), FONT_SIZE, CHAR_SPACING).x
	if fr.focus == 0 && fr.all_sel && len(fr.search_buf) > 0 {
		rl.DrawRectangleV({s0x, s0ty}, {s0w, ref.y}, SEL_BG)
	}
	rl.DrawTextEx(font, to_cstring(s0), {s0x, s0ty}, FONT_SIZE, CHAR_SPACING, TEXT)
	if fr.focus == 0 && !fr.all_sel {
		rl.DrawRectangleV({s0x + s0w, s0ty}, {2, ref.y}, CURSOR_COL)
	}
	rl.EndScissorMode()
	dlg_restore()

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
		ui_scissor_begin(i32(px + PAD + 1), i32(cy + 1), i32(W - PAD*2 - 2), i32(INPUT_H - 2))
		s1w := rl.MeasureTextEx(font, to_cstring(s1), FONT_SIZE, CHAR_SPACING).x
		if fr.all_sel && len(fr.replace_buf) > 0 {
			rl.DrawRectangleV({s1x, s1ty}, {s1w, ref.y}, SEL_BG)
		}
		rl.DrawTextEx(font, to_cstring(s1), {s1x, s1ty}, FONT_SIZE, CHAR_SPACING, TEXT)
		if !fr.all_sel {
			rl.DrawRectangleV({s1x + s1w, s1ty}, {2, ref.y}, CURSOR_COL)
		}
		rl.EndScissorMode()
		dlg_restore()
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
			ui_scissor_begin(i32(px + LNUM_W + 1), i32(ry), i32(content_w + 4), i32(ITEM_H))
			rl.DrawTextEx(font, to_cstring(pre), {content_x - offset, item_ty},
			              FONT_SIZE, CHAR_SPACING, SUBDUED)
			rl.DrawRectangleV({content_x - offset + pre_w, item_ty}, {mat_w, ref.y}, MATCH_HL_BG)
			rl.DrawTextEx(font, to_cstring(mat), {content_x - offset + pre_w, item_ty},
			              FONT_SIZE, CHAR_SPACING, MATCH_HL_FG)
			rl.DrawTextEx(font, to_cstring(pst), {content_x - offset + pre_w + mat_w, item_ty},
			              FONT_SIZE, CHAR_SPACING, TEXT)
			rl.EndScissorMode()
			dlg_restore()
		}

		cy += f32(n_vis)*ITEM_H + SEP_H
	}

	// ── HINT ROW (two lines) ─────────────────────────────────
	hs := FONT_SIZE - 5
	rl.DrawTextEx(font, "Alt+C:case  Alt+W:word  Alt+R:regex  Alt+L:list",
	              {px + PAD, cy + 2}, hs, CHAR_SPACING, SUBDUED)
	rl.DrawTextEx(font, "Tab:switch  ↑↓:next  Enter:replace  Esc:close",
	              {px + PAD, cy + 2 + hs + 2}, hs, CHAR_SPACING, SUBDUED)
	dlg_end()
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

// ---------------------------------------------------------------------------
// Tab bar
// ---------------------------------------------------------------------------

// Both re-synced from the active theme every frame in _apply_theme — these
// initial values are only what's visible before the first frame runs.
TAB_ACTIVE_BG   := STATUS_BG
TAB_INACTIVE_BG := rl.Color{24, 24, 37, 180}
TAB_DIVIDER    := rl.Color{49, 50, 68, 255}

_render_tab_bar :: proc(p: ^Pane, font: rl.Font, ox, oy, ow, th: f32, is_active: bool) {
	rl.DrawRectangleV({ox, oy}, {ow, th}, TAB_INACTIVE_BG)

	GAP :: f32(2)
	x := ox
	for t, ti in p.tabs {
		label := path_basename(t.filename)
		if label == "" { label = "untitled" }
		dirty_mark := "* " if t.dirty else ""
		tab_label  := fmt.tprintf(" %s%s ", dirty_mark, label)
		tw := rl.MeasureTextEx(font, to_cstring(tab_label), FONT_SIZE - 2, CHAR_SPACING).x + 8

		if ti == p.cur_tab {
			// Active tab reads as a raised card: rounded top corners, sits
			// a touch taller than its inactive siblings, accent underline.
			rl.DrawRectangleRounded({x, oy - 1, tw, th + 1}, 0.22, 6, TAB_ACTIVE_BG)
			col := ACCENT_COL if is_active else INACTIVE_TOP
			rl.DrawRectangleV({x + 3, oy + th - 2}, {tw - 6, 2}, col)
		} else {
			rl.DrawRectangleV({x, oy + 3}, {tw, th - 3}, TAB_INACTIVE_BG)
		}

		text_col := TEXT if ti == p.cur_tab else LINENUM
		ty := oy + (th - rl.MeasureTextEx(font, "M", FONT_SIZE - 2, CHAR_SPACING).y) * 0.5
		rl.DrawTextEx(font, to_cstring(tab_label), {x + 4, ty}, FONT_SIZE - 2, CHAR_SPACING, text_col)

		x += tw + GAP
		if x > ox + ow { break }
	}
}

// ---------------------------------------------------------------------------
// Breadcrumb
// ---------------------------------------------------------------------------

_breadcrumb_symbol :: proc(e: ^Editor, p: ^Pane, cur_line: int) -> string {
	if len(e.outline.symbols) == 0 { return "" }
	best := ""
	for s in e.outline.symbols {
		if s.line <= cur_line { best = s.name }
		else { break }
	}
	if best == "" { return "" }
	return fmt.tprintf("  %s", best)
}
