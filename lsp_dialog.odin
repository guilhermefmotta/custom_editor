package editor

import "core:fmt"
import "core:strings"
import lsp "./lsp"
import rl "vendor:raylib"

// ---------------------------------------------------------------------------
// LSP Control Dialog
// ---------------------------------------------------------------------------

LSP_Dialog :: struct {
	visible:        bool,
	scroll:         int,    // log scroll index (0 = oldest visible at top)
	auto_scroll:    bool,   // track newest; reset when user manually scrolls up
	prev_log_count: int,    // detect new entries for auto-scroll
	action_msg:     string, // result of last Start/Stop/Restart (heap-owned)
	action_ok:      bool,
}

LSPD_W        :: f32(620)
LSPD_HEADER_H :: f32(32)
LSPD_INFO_H   :: f32(122)  // server name, state, root, buttons row, msg row
LSPD_LOG_H_LN :: f32(20)   // height per log line
LSPD_LOG_MAX  :: 14         // max visible log lines
LSPD_FOOTER_H :: f32(26)

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

lsp_dialog_open :: proc(d: ^LSP_Dialog) {
	d.visible     = true
	d.scroll      = 999999 // clamped to max_scroll in render → shows newest
	d.auto_scroll = true
	_rep_key      = .KEY_NULL // clear any held key from editor so UP/DOWN work immediately
}

lsp_dialog_close :: proc(d: ^LSP_Dialog) {
	d.visible = false
	_lspd_clear_msg(d)
}

lsp_dialog_destroy :: proc(d: ^LSP_Dialog) {
	_lspd_clear_msg(d)
	d^ = {}
}

_lspd_set_msg :: proc(d: ^LSP_Dialog, ok: bool, msg: string) {
	_lspd_clear_msg(d)
	d.action_msg = strings.clone(msg)
	d.action_ok  = ok
}

_lspd_clear_msg :: proc(d: ^LSP_Dialog) {
	if d.action_msg != "" { delete(d.action_msg); d.action_msg = "" }
}

// ---------------------------------------------------------------------------
// Input handler
// ---------------------------------------------------------------------------

lsp_dialog_handle_input :: proc(d: ^LSP_Dialog, e: ^Editor) -> (consumed: bool) {
	if !d.visible { return false }

	if rl.IsKeyPressed(.ESCAPE) {
		lsp_dialog_close(d)
		return true
	}

	// Scroll log — keyboard + mouse wheel; UP = older, DOWN = newer
	if key_rep(.UP)   { if d.scroll > 0 { d.scroll -= 1; d.auto_scroll = false }; return true }
	if key_rep(.DOWN) { d.scroll += 1; return true }
	wheel := rl.GetMouseWheelMove()
	if wheel != 0 {
		d.scroll -= int(wheel) * 3
		if wheel > 0 { d.auto_scroll = false }
		return true
	}

	// Actions
	p := active_pane(e)
	ext := lsp.path_ext(p.filename) if p.filename != "" else ""
	c   := lsp.lsp_manager_find_client_for_path(&e.lsp_mgr, p.filename)

	if rl.IsKeyPressed(.S) {
		_lspd_do_start(d, e, ext)
		return true
	}
	if rl.IsKeyPressed(.T) {
		_lspd_do_stop(d, e, ext)
		return true
	}
	if rl.IsKeyPressed(.R) {
		_lspd_do_restart(d, e, ext)
		return true
	}
	if rl.IsKeyPressed(.C) {
		_lspd_copy_log(d, c)
		return true
	}

	return true // swallow all keys while dialog is open
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

_lspd_do_start :: proc(d: ^LSP_Dialog, e: ^Editor, ext: string) {
	if ext == "" { _lspd_set_msg(d, false, "no file open"); return }
	ok, err := lsp.lsp_manager_start_for_ext(&e.lsp_mgr, ext)
	if !ok { _lspd_set_msg(d, false, err); return }
	lsp_reopen_all_panes(e)
	_lspd_set_msg(d, true, "starting...")
	d.scroll      = 999999
	d.auto_scroll = true
}

_lspd_do_stop :: proc(d: ^LSP_Dialog, e: ^Editor, ext: string) {
	if ext == "" { _lspd_set_msg(d, false, "no file open"); return }
	ok, err := lsp.lsp_manager_stop_for_ext(&e.lsp_mgr, ext)
	if !ok { _lspd_set_msg(d, false, err); return }
	_lspd_set_msg(d, true, "stopped")
	d.auto_scroll = true
}

_lspd_do_restart :: proc(d: ^LSP_Dialog, e: ^Editor, ext: string) {
	if ext == "" { _lspd_set_msg(d, false, "no file open"); return }
	ok, err := lsp.lsp_manager_restart_for_ext(&e.lsp_mgr, ext)
	if !ok { _lspd_set_msg(d, false, err); return }
	lsp_reopen_all_panes(e)
	_lspd_set_msg(d, true, "restarting...")
	d.scroll      = 999999
	d.auto_scroll = true
}

_lspd_copy_log :: proc(d: ^LSP_Dialog, c: ^lsp.Language_Client) {
	if c == nil || len(c.logs) == 0 { _lspd_set_msg(d, false, "no log to copy"); return }
	sb: strings.Builder
	strings.builder_init(&sb, context.temp_allocator)
	for entry in c.logs {
		level_str := "[LOG]"
		switch entry.level {
		case .Error:   level_str = "[ERR]"
		case .Warning: level_str = "[WRN]"
		case .Info:    level_str = "[INF]"
		case .Log:     level_str = "[LOG]"
		}
		strings.write_string(&sb, level_str)
		strings.write_byte(&sb, ' ')
		strings.write_string(&sb, entry.message)
		strings.write_byte(&sb, '\n')
	}
	text := strings.to_string(sb)
	rl.SetClipboardText(strings.clone_to_cstring(text, context.temp_allocator))
	_lspd_set_msg(d, true, "log copied!")
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

render_lsp_dialog :: proc(d: ^LSP_Dialog, e: ^Editor, font: rl.Font, sw, sh: f32) {
	if !d.visible { return }

	OVERLAY   :: rl.Color{0, 0, 0, 160}
	SHADOW    :: rl.Color{0, 0, 0, 90}
	PANEL_BG  := BG
	PANEL_BOR := DIVIDER_COL
	HEADER_BG := STATUS_BG
	INFO_BG   := BG
	ACCENT    := ACCENT_COL
	GREEN     := DIAG_HINT_COL
	YELLOW    := DIAG_WARN_COL
	RED       := MSG_COL
	PEACH     := DIAG_WARN_COL
	SUBDUED   := LINENUM
	// TEXT and SEL_BG shadow package-level vars of same name — use them directly

	ref := rl.MeasureTextEx(font, "M", FONT_SIZE, CHAR_SPACING)

	p   := active_pane(e)
	ext := lsp.path_ext(p.filename) if p.filename != "" else ""

	// Gather server info
	server_name := lsp.lsp_manager_server_name_for_path(&e.lsp_mgr, p.filename)
	c           := lsp.lsp_manager_find_client_for_path(&e.lsp_mgr, p.filename)

	// Log lines
	log_count := 0
	if c != nil { log_count = len(c.logs) }
	vis_log := min(log_count, LSPD_LOG_MAX)

	panel_h := LSPD_HEADER_H + LSPD_INFO_H + f32(vis_log)*LSPD_LOG_H_LN + LSPD_FOOTER_H + 8
	panel_x := (sw - LSPD_W) * 0.5
	panel_y := (sh - panel_h) * 0.5

	// Auto-scroll: jump to newest when entries arrive (or when re-enabled)
	max_scroll := max(0, log_count - LSPD_LOG_MAX)
	if log_count != d.prev_log_count {
		d.prev_log_count = log_count
		if d.auto_scroll { d.scroll = max_scroll }
	}
	// Resume auto-scroll if user scrolled to the bottom
	if d.scroll >= max_scroll { d.auto_scroll = true }
	d.scroll = clamp(d.scroll, 0, max_scroll)

	// Overlay
	rl.DrawRectangle(0, 0, i32(sw), i32(sh), OVERLAY)

	// Panel (shadow + body + border)
	dlg_begin(panel_x, panel_y, LSPD_W, panel_h, PANEL_BG, PANEL_BOR)

	// ── Header ─────────────────────────────────────────────────────────
	rl.DrawRectangleV({panel_x, panel_y}, {LSPD_W, LSPD_HEADER_H}, HEADER_BG)
	rl.DrawLineV(
		{panel_x, panel_y + LSPD_HEADER_H - 1},
		{panel_x + LSPD_W, panel_y + LSPD_HEADER_H - 1},
		PANEL_BOR,
	)
	rl.DrawTextEx(font, "LSP Control",
		{panel_x + 12, panel_y + (LSPD_HEADER_H - ref.y)*0.5},
		FONT_SIZE, CHAR_SPACING, ACCENT)

	hint := "Esc close"
	hint_w := rl.MeasureTextEx(font, to_cstring(hint), FONT_SIZE - 3, CHAR_SPACING).x
	rl.DrawTextEx(font, to_cstring(hint),
		{panel_x + LSPD_W - hint_w - 10, panel_y + (LSPD_HEADER_H - ref.y + 2)*0.5},
		FONT_SIZE - 3, CHAR_SPACING, SUBDUED)

	// ── Info / status section ───────────────────────────────────────────
	iy := panel_y + LSPD_HEADER_H
	rl.DrawRectangleV({panel_x, iy}, {LSPD_W, LSPD_INFO_H}, INFO_BG)
	rl.DrawLineV(
		{panel_x, iy + LSPD_INFO_H - 1},
		{panel_x + LSPD_W, iy + LSPD_INFO_H - 1},
		PANEL_BOR,
	)

	tx := panel_x + 14
	ty := iy + 10

	// Server label row
	{
		label := "Server: "
		lw    := rl.MeasureTextEx(font, to_cstring(label), FONT_SIZE-1, CHAR_SPACING).x
		rl.DrawTextEx(font, to_cstring(label), {tx, ty}, FONT_SIZE-1, CHAR_SPACING, SUBDUED)

		if server_name == "" {
			rl.DrawTextEx(font, "none (no server for this file type)", {tx+lw, ty}, FONT_SIZE-1, CHAR_SPACING, SUBDUED)
		} else {
			rl.DrawTextEx(font, to_cstring(server_name), {tx+lw, ty}, FONT_SIZE-1, CHAR_SPACING, TEXT)

			// State badge on right
			state_str, state_col := _lspd_state(c)
			badge_w := rl.MeasureTextEx(font, to_cstring(state_str), FONT_SIZE-2, CHAR_SPACING).x
			rl.DrawTextEx(font, to_cstring(state_str),
				{panel_x + LSPD_W - badge_w - 12, ty},
				FONT_SIZE-2, CHAR_SPACING, state_col)
		}
		ty += ref.y + 6
	}

	// File row
	{
		file_label := "File:   "
		flw        := rl.MeasureTextEx(font, to_cstring(file_label), FONT_SIZE-1, CHAR_SPACING).x
		rl.DrawTextEx(font, to_cstring(file_label), {tx, ty}, FONT_SIZE-1, CHAR_SPACING, SUBDUED)
		if p.filename != "" {
			fn := fmt.tprintf("%s (.%s)", path_basename(p.filename), ext)
			rl.DrawTextEx(font, to_cstring(fn), {tx+flw, ty}, FONT_SIZE-1, CHAR_SPACING, TEXT)
		} else {
			rl.DrawTextEx(font, "no file open", {tx+flw, ty}, FONT_SIZE-1, CHAR_SPACING, SUBDUED)
		}
		ty += ref.y + 6
	}

	// Root row
	{
		root_label := "Root:   "
		rlw        := rl.MeasureTextEx(font, to_cstring(root_label), FONT_SIZE-1, CHAR_SPACING).x
		rl.DrawTextEx(font, to_cstring(root_label), {tx, ty}, FONT_SIZE-1, CHAR_SPACING, SUBDUED)
		root := e.lsp_mgr.root_path
		rl.DrawTextEx(font, to_cstring(root), {tx+rlw, ty}, FONT_SIZE-1, CHAR_SPACING, TEXT)
		ty += ref.y + 8
	}

	// Action buttons row — drawn as pill buttons
	{
		BTN_PAD_X :: f32(10)
		BTN_PAD_Y :: f32(4)
		BTN_GAP   :: f32(8)
		BTN_H     :: f32(22)

		// Color buttons based on applicability
		start_col   := GREEN
		stop_col    := RED
		restart_col := YELLOW
		copy_col    := ACCENT
		if ext == "" { start_col = SUBDUED; stop_col = SUBDUED; restart_col = SUBDUED; copy_col = SUBDUED }
		if c == nil  { stop_col = SUBDUED; restart_col = SUBDUED }

		_draw_btn :: proc(font: rl.Font, label: string, bx, by, bh, pad_x, pad_y: f32,
		                  gap: f32, text_col: rl.Color, border_col: rl.Color) -> f32 {
			tw := rl.MeasureTextEx(font, to_cstring(label), FONT_SIZE-1, CHAR_SPACING).x
			bw := tw + pad_x * 2
			rl.DrawRectangleLinesEx({bx, by, bw, bh}, 1, border_col)
			rl.DrawTextEx(font, to_cstring(label), {bx + pad_x, by + pad_y}, FONT_SIZE-1, CHAR_SPACING, text_col)
			return bw + gap
		}

		btn_y := ty
		bx := tx
		bx += _draw_btn(font, "S Start",   bx, btn_y, BTN_H, BTN_PAD_X, BTN_PAD_Y, BTN_GAP, start_col,   start_col)
		bx += _draw_btn(font, "T Stop",    bx, btn_y, BTN_H, BTN_PAD_X, BTN_PAD_Y, BTN_GAP, stop_col,    stop_col)
		bx += _draw_btn(font, "R Restart", bx, btn_y, BTN_H, BTN_PAD_X, BTN_PAD_Y, BTN_GAP, restart_col, restart_col)
		_draw_btn(font, "C Copy Log", bx, btn_y, BTN_H, BTN_PAD_X, BTN_PAD_Y, BTN_GAP, copy_col, copy_col)

		ty += BTN_H + BTN_GAP

		// Action / error message below buttons
		if d.action_msg != "" {
			msg_col := GREEN if d.action_ok else RED
			rl.DrawTextEx(font, to_cstring(d.action_msg), {tx, ty}, FONT_SIZE-2, CHAR_SPACING, msg_col)
		} else if c != nil && c.error_msg != "" {
			em := fmt.tprintf("! %s", c.error_msg)
			rl.DrawTextEx(font, to_cstring(em), {tx, ty}, FONT_SIZE-2, CHAR_SPACING, RED)
		}
	}

	// ── Log section ─────────────────────────────────────────────────────
	ly := iy + LSPD_INFO_H + 4

	// "── Log ──" separator
	sep_y := ly - 4
	rl.DrawTextEx(font, "── Log", {tx, sep_y}, FONT_SIZE-3, CHAR_SPACING, SUBDUED)

	if c == nil || log_count == 0 {
		rl.DrawTextEx(font, "no log messages",
			{tx, ly + 2}, FONT_SIZE-2, CHAR_SPACING, SUBDUED)
	} else {
		// Show vis_log lines starting from scroll offset
		start_i := d.scroll
		for vi in 0..<vis_log {
			li := start_i + vi
			if li >= log_count { break }
			entry := c.logs[li]

			lx     := tx
			line_y := ly + f32(vi)*LSPD_LOG_H_LN

			// Level tag
			level_str, level_col := _lspd_log_level(entry.level)
			lsw := rl.MeasureTextEx(font, to_cstring(level_str), FONT_SIZE-3, CHAR_SPACING).x
			rl.DrawTextEx(font, to_cstring(level_str), {lx, line_y + 3}, FONT_SIZE-3, CHAR_SPACING, level_col)
			lx += lsw + 6

			// Message — ellipsized to fit panel width
			max_mw := panel_x + LSPD_W - lx - 12
			rl.DrawTextEx(font, to_cstring(text_clip(font, entry.message, max_mw, FONT_SIZE-2, CHAR_SPACING)),
			              {lx, line_y + 2}, FONT_SIZE-2, CHAR_SPACING, TEXT)
		}
	}

	// Scrollbar when log overflows
	if log_count > LSPD_LOG_MAX {
		total_h := f32(vis_log) * LSPD_LOG_H_LN
		bar_h   := total_h * f32(LSPD_LOG_MAX) / f32(log_count)
		bar_y   := ly + total_h * f32(d.scroll) / f32(log_count)
		rl.DrawRectangleV({panel_x + LSPD_W - 3, bar_y}, {3, bar_h}, PANEL_BOR)
	}

	// ── Footer ──────────────────────────────────────────────────────────
	footer_y := panel_y + panel_h - LSPD_FOOTER_H
	rl.DrawRectangleV({panel_x, footer_y}, {LSPD_W, LSPD_FOOTER_H}, HEADER_BG)
	rl.DrawLineV({panel_x, footer_y}, {panel_x + LSPD_W, footer_y}, PANEL_BOR)

	hints := "↑↓ wheel scroll   S start   T stop   R restart   C copy log   Esc close"
	rl.DrawTextEx(font, to_cstring(hints),
		{panel_x + 10, footer_y + (LSPD_FOOTER_H - ref.y + 2)*0.5},
		FONT_SIZE-3, CHAR_SPACING, SUBDUED)
	dlg_end()
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

_lspd_state :: proc(c: ^lsp.Language_Client) -> (label: string, col: rl.Color) {
	if c == nil { return "not started", LINENUM }
	switch c.state {
	case .Created, .Starting:     return "starting...", DIAG_WARN_COL
	case .Initializing:           return "initializing...", DIAG_WARN_COL
	case .Running:                return "running", DIAG_HINT_COL
	case .Shutting_Down:          return "stopping...", DIAG_WARN_COL
	case .Stopped:
		if c.error_msg != "" { return "error", MSG_COL }
		return "stopped", LINENUM
	}
	return "unknown", LINENUM
}

_lspd_log_level :: proc(level: lsp.LSP_Log_Level) -> (label: string, col: rl.Color) {

	switch level {
	case .Error:   return "[ERR]", MSG_COL
	case .Warning: return "[WRN]", DIAG_WARN_COL
	case .Info:    return "[INF]", ACCENT_COL
	case .Log:     return "[LOG]", LINENUM
	}
	return "[???]", LINENUM
}

