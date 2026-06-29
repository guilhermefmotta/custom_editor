package editor

import "core:fmt"
import "core:strings"
import lsp "./lsp"
import rl "vendor:raylib"

// ---------------------------------------------------------------------------
// LSP Control Dialog
// ---------------------------------------------------------------------------

LSP_Dialog :: struct {
	visible:    bool,
	scroll:     int,    // log scroll (lines from bottom)
	action_msg: string, // result of last Start/Stop/Restart (heap-owned)
	action_ok:  bool,
}

LSPD_W        :: f32(600)
LSPD_HEADER_H :: f32(32)
LSPD_INFO_H   :: f32(88)  // server name, state, root, buttons
LSPD_LOG_H_LN :: f32(20)  // height per log line
LSPD_LOG_MAX  :: 14        // max visible log lines
LSPD_FOOTER_H :: f32(26)

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

lsp_dialog_open :: proc(d: ^LSP_Dialog) {
	d.visible = true
	d.scroll  = 0
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

	// Scroll log
	if key_rep(.UP)   { if d.scroll > 0 { d.scroll -= 1 }; return true }
	if key_rep(.DOWN) { d.scroll += 1;                      return true }

	// Actions
	p := active_pane(e)
	ext := lsp.path_ext(p.filename) if p.filename != "" else ""

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
	_lspd_set_msg(d, true, "starting…")
	d.scroll = 0
}

_lspd_do_stop :: proc(d: ^LSP_Dialog, e: ^Editor, ext: string) {
	if ext == "" { _lspd_set_msg(d, false, "no file open"); return }
	ok, err := lsp.lsp_manager_stop_for_ext(&e.lsp_mgr, ext)
	if !ok { _lspd_set_msg(d, false, err); return }
	_lspd_set_msg(d, true, "stopped")
	d.scroll = 0
}

_lspd_do_restart :: proc(d: ^LSP_Dialog, e: ^Editor, ext: string) {
	if ext == "" { _lspd_set_msg(d, false, "no file open"); return }
	ok, err := lsp.lsp_manager_restart_for_ext(&e.lsp_mgr, ext)
	if !ok { _lspd_set_msg(d, false, err); return }
	lsp_reopen_all_panes(e)
	_lspd_set_msg(d, true, "restarting…")
	d.scroll = 0
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

render_lsp_dialog :: proc(d: ^LSP_Dialog, e: ^Editor, font: rl.Font, sw, sh: f32) {
	if !d.visible { return }

	// Colors (Catppuccin Mocha)
	OVERLAY   :: rl.Color{0,   0,   0,   160}
	PANEL_BG  :: rl.Color{30,  30,  46,  255}
	PANEL_BOR :: rl.Color{58,  60,  78,  255}
	HEADER_BG :: rl.Color{24,  24,  37,  255}
	INFO_BG   :: rl.Color{36,  36,  54,  255}
	SHADOW    :: rl.Color{0,   0,   0,   90}
	ACCENT    :: rl.Color{137, 180, 250, 255}
	GREEN     :: rl.Color{166, 227, 161, 255}
	YELLOW    :: rl.Color{249, 226, 175, 255}
	RED       :: rl.Color{243, 139, 168, 255}
	PEACH     :: rl.Color{250, 179, 135, 255}
	TEXT      :: rl.Color{205, 214, 244, 255}
	SUBDUED   :: rl.Color{108, 112, 134, 255}
	SEL_BG    :: rl.Color{49,  50,  68,  255}

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

	// Clamp scroll
	max_scroll := max(0, log_count - LSPD_LOG_MAX)
	d.scroll = clamp(d.scroll, 0, max_scroll)

	// Overlay
	rl.DrawRectangle(0, 0, i32(sw), i32(sh), OVERLAY)

	// Shadow
	rl.DrawRectangleV({panel_x + 4, panel_y + 4}, {LSPD_W, panel_h}, SHADOW)

	// Panel
	rl.DrawRectangleV({panel_x, panel_y}, {LSPD_W, panel_h}, PANEL_BG)
	rl.DrawRectangleLinesEx({panel_x, panel_y, LSPD_W, panel_h}, 1, PANEL_BOR)

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

	// Action buttons
	{
		btn_start   := "[S] Start"
		btn_stop    := "[T] Stop"
		btn_restart := "[R] Restart"
		gap         := f32(20)

		bw_s := rl.MeasureTextEx(font, to_cstring(btn_start),   FONT_SIZE-1, CHAR_SPACING).x
		bw_t := rl.MeasureTextEx(font, to_cstring(btn_stop),    FONT_SIZE-1, CHAR_SPACING).x
		bw_r := rl.MeasureTextEx(font, to_cstring(btn_restart), FONT_SIZE-1, CHAR_SPACING).x

		// Color buttons based on applicability
		start_col   := GREEN
		stop_col    := RED
		restart_col := YELLOW
		if ext == ""    { start_col = SUBDUED; stop_col = SUBDUED; restart_col = SUBDUED }
		if c == nil     { stop_col = SUBDUED; restart_col = SUBDUED }

		bx := tx
		rl.DrawTextEx(font, to_cstring(btn_start),   {bx, ty}, FONT_SIZE-1, CHAR_SPACING, start_col)
		bx += bw_s + gap
		rl.DrawTextEx(font, to_cstring(btn_stop),    {bx, ty}, FONT_SIZE-1, CHAR_SPACING, stop_col)
		bx += bw_t + gap
		rl.DrawTextEx(font, to_cstring(btn_restart), {bx, ty}, FONT_SIZE-1, CHAR_SPACING, restart_col)

		// Action message on the right
		if d.action_msg != "" {
			msg_col := GREEN if d.action_ok else RED
			mw := rl.MeasureTextEx(font, to_cstring(d.action_msg), FONT_SIZE-2, CHAR_SPACING).x
			rl.DrawTextEx(font, to_cstring(d.action_msg),
				{panel_x + LSPD_W - mw - 12, ty},
				FONT_SIZE-2, CHAR_SPACING, msg_col)
		}

		// Client error_msg if set
		if c != nil && c.error_msg != "" {
			em := fmt.tprintf("! %s", c.error_msg)
			em_col := RED
			em_w   := rl.MeasureTextEx(font, to_cstring(em), FONT_SIZE-2, CHAR_SPACING).x
			if d.action_msg == "" { // don't overlap
				rl.DrawTextEx(font, to_cstring(em),
					{panel_x + LSPD_W - em_w - 12, ty},
					FONT_SIZE-2, CHAR_SPACING, em_col)
			}
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

			lx   := tx
			line_y := ly + f32(vi)*LSPD_LOG_H_LN

			// Level tag
			level_str, level_col := _lspd_log_level(entry.level)
			lsw := rl.MeasureTextEx(font, to_cstring(level_str), FONT_SIZE-3, CHAR_SPACING).x
			rl.DrawTextEx(font, to_cstring(level_str), {lx, line_y + 3}, FONT_SIZE-3, CHAR_SPACING, level_col)
			lx += lsw + 6

			// Message — clip to panel width
			max_mw   := LSPD_W - lsw - 30
			msg_disp := _lspd_clip_str(entry.message, font, max_mw)
			rl.DrawTextEx(font, to_cstring(msg_disp), {lx, line_y + 2}, FONT_SIZE-2, CHAR_SPACING, TEXT)
		}

		// Scrollbar when log overflows
		if log_count > LSPD_LOG_MAX {
			total_h := f32(vis_log) * LSPD_LOG_H_LN
			bar_h   := total_h * f32(LSPD_LOG_MAX) / f32(log_count)
			bar_y   := ly + total_h * f32(d.scroll) / f32(log_count)
			rl.DrawRectangleV({panel_x + LSPD_W - 3, bar_y}, {3, bar_h}, PANEL_BOR)
		}
	}

	// ── Footer ──────────────────────────────────────────────────────────
	footer_y := panel_y + panel_h - LSPD_FOOTER_H
	rl.DrawRectangleV({panel_x, footer_y}, {LSPD_W, LSPD_FOOTER_H}, HEADER_BG)
	rl.DrawLineV({panel_x, footer_y}, {panel_x + LSPD_W, footer_y}, PANEL_BOR)

	hints := "↑↓ scroll log   S start   T stop   R restart   Esc close"
	rl.DrawTextEx(font, to_cstring(hints),
		{panel_x + 10, footer_y + (LSPD_FOOTER_H - ref.y + 2)*0.5},
		FONT_SIZE-3, CHAR_SPACING, SUBDUED)
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

_lspd_state :: proc(c: ^lsp.Language_Client) -> (label: string, col: rl.Color) {
	YELLOW :: rl.Color{249, 226, 175, 255}
	GREEN  :: rl.Color{166, 227, 161, 255}
	RED    :: rl.Color{243, 139, 168, 255}
	SUBDUED :: rl.Color{108, 112, 134, 255}

	if c == nil { return "not started", SUBDUED }
	switch c.state {
	case .Created, .Starting:     return "starting…", YELLOW
	case .Initializing:           return "initializing…", YELLOW
	case .Running:                return "running ●", GREEN
	case .Shutting_Down:          return "stopping…", YELLOW
	case .Stopped:
		if c.error_msg != "" { return "error", RED }
		return "stopped", SUBDUED
	}
	return "unknown", SUBDUED
}

_lspd_log_level :: proc(level: lsp.LSP_Log_Level) -> (label: string, col: rl.Color) {
	RED    :: rl.Color{243, 139, 168, 255}
	ORANGE :: rl.Color{250, 179, 135, 255}
	BLUE   :: rl.Color{137, 180, 250, 255}
	SUBDUED :: rl.Color{108, 112, 134, 255}

	switch level {
	case .Error:   return "[ERR]", RED
	case .Warning: return "[WRN]", ORANGE
	case .Info:    return "[INF]", BLUE
	case .Log:     return "[LOG]", SUBDUED
	}
	return "[???]", SUBDUED
}

_lspd_clip_str :: proc(s: string, font: rl.Font, max_w: f32) -> string {
	if rl.MeasureTextEx(font, to_cstring(s), FONT_SIZE-2, CHAR_SPACING).x <= max_w {
		return s
	}
	end := len(s)
	ellipsis := "…"
	for end > 0 {
		sub := strings.concatenate({s[:end], ellipsis}, context.temp_allocator)
		if rl.MeasureTextEx(font, to_cstring(sub), FONT_SIZE-2, CHAR_SPACING).x <= max_w {
			return sub
		}
		// step back one UTF-8 character
		end -= 1
		for end > 0 && (s[end] & 0xC0) == 0x80 { end -= 1 }
	}
	return ellipsis
}
