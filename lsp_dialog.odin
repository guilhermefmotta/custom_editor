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
	scroll:         int,
	auto_scroll:    bool,
	prev_log_count: int,
	action_msg:     string, // heap-owned
	action_ok:      bool,
	log_area_y:     f32,   // set each frame; used for wheel targeting
	log_area_h:     f32,
	vis_log_lines:  int,
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

lsp_dialog_open :: proc(d: ^LSP_Dialog) {
	d.visible     = true
	d.scroll      = 999999
	d.auto_scroll = true
	_rep_key      = .KEY_NULL
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

	// Scroll — keyboard
	if key_rep(.UP) {
		if d.scroll > 0 { d.scroll -= 1; d.auto_scroll = false }
		return true
	}
	if key_rep(.DOWN) {
		d.scroll += 1
		return true
	}

	// Mouse wheel — only when hovering log area
	mx := rl.GetMousePosition().y
	in_log := mx >= d.log_area_y && mx <= d.log_area_y + d.log_area_h
	wheel := rl.GetMouseWheelMove()
	if wheel != 0 && (in_log || d.log_area_h == 0) {
		d.scroll -= int(wheel) * 3
		if wheel > 0 { d.auto_scroll = false }
		return true
	}

	// Keyboard shortcuts for actions (buttons also handle mouse clicks in render)
	p    := active_pane(e)
	path := p.filename
	c    := lsp.lsp_manager_find_client_for_path(&e.lsp_mgr, path)

	if rl.IsKeyPressed(.S) { _lspd_do_start(d, e, path);   return true }
	if rl.IsKeyPressed(.T) { _lspd_do_stop(d, e, path);    return true }
	if rl.IsKeyPressed(.R) { _lspd_do_restart(d, e, path); return true }
	if rl.IsKeyPressed(.C) { _lspd_copy_log(d, c);         return true }
	if rl.IsKeyPressed(.I) {
		inst := lsp.lsp_manager_install_info_for_path(&e.lsp_mgr, path)
		if inst.has_install && inst.state != .Running {
			_lspd_do_install(d, e, path, inst.server_name)
		}
		return true
	}

	return true // swallow all while open
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

_lspd_do_start :: proc(d: ^LSP_Dialog, e: ^Editor, path: string) {
	if path == "" { _lspd_set_msg(d, false, "no file open"); return }
	ok, err := lsp.lsp_manager_start_for_path(&e.lsp_mgr, path)
	if !ok { _lspd_set_msg(d, false, err); return }
	lsp_reopen_all_panes(e)
	_lspd_set_msg(d, true, "starting...")
	d.scroll = 999999; d.auto_scroll = true
}

_lspd_do_stop :: proc(d: ^LSP_Dialog, e: ^Editor, path: string) {
	if path == "" { _lspd_set_msg(d, false, "no file open"); return }
	ok, err := lsp.lsp_manager_stop_for_path(&e.lsp_mgr, path)
	if !ok { _lspd_set_msg(d, false, err); return }
	_lspd_set_msg(d, true, "stopped")
	d.auto_scroll = true
}

_lspd_do_restart :: proc(d: ^LSP_Dialog, e: ^Editor, path: string) {
	if path == "" { _lspd_set_msg(d, false, "no file open"); return }
	ok, err := lsp.lsp_manager_restart_for_path(&e.lsp_mgr, path)
	if !ok { _lspd_set_msg(d, false, err); return }
	lsp_reopen_all_panes(e)
	_lspd_set_msg(d, true, "restarting...")
	d.scroll = 999999; d.auto_scroll = true
}

_lspd_do_install :: proc(d: ^LSP_Dialog, e: ^Editor, path: string, server_name: string) {
	ok := lsp.lsp_manager_trigger_install(&e.lsp_mgr, server_name)
	if ok {
		_lspd_set_msg(d, true, fmt.tprintf("Installing %s...", server_name))
	} else {
		_lspd_set_msg(d, false, fmt.tprintf("No auto-install for %s", server_name))
	}
}

_lspd_copy_log :: proc(d: ^LSP_Dialog, c: ^lsp.Language_Client) {
	if c == nil || len(c.logs) == 0 { _lspd_set_msg(d, false, "no log to copy"); return }
	sb: strings.Builder
	strings.builder_init(&sb, context.temp_allocator)
	for entry in c.logs {
		tag := "[LOG]"
		switch entry.level {
		case .Error:   tag = "[ERR]"
		case .Warning: tag = "[WRN]"
		case .Info:    tag = "[INF]"
		case .Log:     tag = "[LOG]"
		}
		strings.write_string(&sb, tag)
		strings.write_byte(&sb, ' ')
		strings.write_string(&sb, entry.message)
		strings.write_byte(&sb, '\n')
	}
	rl.SetClipboardText(strings.clone_to_cstring(strings.to_string(sb), context.temp_allocator))
	_lspd_set_msg(d, true, "log copied!")
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

render_lsp_dialog :: proc(d: ^LSP_Dialog, e: ^Editor, font: rl.Font, sw, sh: f32) {
	if !d.visible { return }

	OVERLAY   :: rl.Color{0, 0, 0, 170}
	PANEL_BG  := BG
	PANEL_BOR := DIVIDER_COL
	HDR_BG    := STATUS_BG
	ACCENT    := ACCENT_COL
	GREEN     := DIAG_HINT_COL
	YELLOW    := DIAG_WARN_COL
	RED       := MSG_COL
	SUBDUED   := LINENUM

	ref := rl.MeasureTextEx(font, "M", FONT_SIZE, CHAR_SPACING)

	p    := active_pane(e)
	path := p.filename
	ext  := lsp.path_ext(path) if path != "" else ""

	server_name := lsp.lsp_manager_server_name_for_path(&e.lsp_mgr, path)
	c           := lsp.lsp_manager_find_client_for_path(&e.lsp_mgr, path)
	proj_root   := lsp._project_root_for_file(path) if path != "" else e.lsp_mgr.root_path

	log_count := 0
	if c != nil { log_count = len(c.logs) }

	// Layout constants
	W        :: f32(740)
	HDR_H    :: f32(36)
	INFO_H   :: f32(148) // server + file + root + buttons + msg
	LOG_LN_H :: f32(22)
	FOOT_H   :: f32(30)
	SB_W     :: f32(6)   // scrollbar width

	panel_h := sh * 0.88
	if panel_h < 380 { panel_h = 380 }
	log_section_h := panel_h - HDR_H - INFO_H - FOOT_H
	vis := int(log_section_h / LOG_LN_H)
	if vis < 1 { vis = 1 }

	d.vis_log_lines = vis

	px := (sw - W) * 0.5
	py := (sh - panel_h) * 0.5

	// Auto-scroll
	max_scroll := max(0, log_count - vis)
	if log_count != d.prev_log_count {
		d.prev_log_count = log_count
		if d.auto_scroll { d.scroll = max_scroll }
	}
	if d.scroll >= max_scroll { d.auto_scroll = true }
	d.scroll = clamp(d.scroll, 0, max_scroll)

	// Store log area bounds for wheel targeting
	d.log_area_y = py + HDR_H + INFO_H
	d.log_area_h = log_section_h

	rl.DrawRectangle(0, 0, i32(sw), i32(sh), OVERLAY)
	dlg_begin(px, py, W, panel_h, PANEL_BG, PANEL_BOR)

	// ── Header ────────────────────────────────────────────────────────────
	rl.DrawRectangleV({px, py}, {W, HDR_H}, HDR_BG)
	rl.DrawLineV({px, py + HDR_H}, {px + W, py + HDR_H}, PANEL_BOR)
	rl.DrawTextEx(font, "LSP Control",
		{px + 14, py + (HDR_H - ref.y) * 0.5},
		FONT_SIZE, CHAR_SPACING, ACCENT)
	esc_hint := "Esc close"
	esc_w := rl.MeasureTextEx(font, to_cstring(esc_hint), FONT_SIZE - 3, CHAR_SPACING).x
	rl.DrawTextEx(font, to_cstring(esc_hint),
		{px + W - esc_w - 12, py + (HDR_H - ref.y) * 0.5 + 1},
		FONT_SIZE - 3, CHAR_SPACING, SUBDUED)

	// ── Info section ─────────────────────────────────────────────────────
	info_y := py + HDR_H
	rl.DrawRectangleV({px, info_y}, {W, INFO_H}, PANEL_BG)

	tx := px + 16
	ty := info_y + 12

	// Server row
	{
		lbl := "Server"
		lw  := rl.MeasureTextEx(font, to_cstring(lbl), FONT_SIZE - 2, CHAR_SPACING).x
		rl.DrawTextEx(font, to_cstring(lbl), {tx, ty}, FONT_SIZE - 2, CHAR_SPACING, SUBDUED)
		rl.DrawTextEx(font, ":", {tx + lw, ty}, FONT_SIZE - 2, CHAR_SPACING, SUBDUED)
		val_x := tx + lw + 10
		if server_name == "" {
			rl.DrawTextEx(font, "none", {val_x, ty}, FONT_SIZE - 2, CHAR_SPACING, SUBDUED)
		} else {
			rl.DrawTextEx(font, to_cstring(server_name), {val_x, ty}, FONT_SIZE - 2, CHAR_SPACING, TEXT)
			state_str, state_col := _lspd_state(c)
			sw2 := rl.MeasureTextEx(font, to_cstring(state_str), FONT_SIZE - 2, CHAR_SPACING).x
			// State badge with background
			badge_x := px + W - sw2 - 28
			badge_pad_x : f32 = 8
			badge_pad_y : f32 = 2
			badge_w := sw2 + badge_pad_x * 2
			badge_h := ref.y + badge_pad_y * 2
			rl.DrawRectangleV({badge_x - badge_pad_x, ty - badge_pad_y},
				{badge_w, badge_h}, rl.Color{state_col.r, state_col.g, state_col.b, 30})
			rl.DrawRectangleLinesEx({badge_x - badge_pad_x, ty - badge_pad_y, badge_w, badge_h},
				1, rl.Color{state_col.r, state_col.g, state_col.b, 120})
			rl.DrawTextEx(font, to_cstring(state_str), {badge_x, ty}, FONT_SIZE - 2, CHAR_SPACING, state_col)
		}
		ty += ref.y + 7
	}

	// File row
	{
		lbl := "File  "
		lw  := rl.MeasureTextEx(font, to_cstring(lbl), FONT_SIZE - 2, CHAR_SPACING).x
		rl.DrawTextEx(font, to_cstring(lbl), {tx, ty}, FONT_SIZE - 2, CHAR_SPACING, SUBDUED)
		rl.DrawTextEx(font, ":", {tx + lw, ty}, FONT_SIZE - 2, CHAR_SPACING, SUBDUED)
		val_x := tx + lw + 10
		if p.filename != "" {
			fn := fmt.tprintf("%s  (.%s)", path_basename(p.filename), ext)
			rl.DrawTextEx(font, to_cstring(fn), {val_x, ty}, FONT_SIZE - 2, CHAR_SPACING, TEXT)
		} else {
			rl.DrawTextEx(font, "no file open", {val_x, ty}, FONT_SIZE - 2, CHAR_SPACING, SUBDUED)
		}
		ty += ref.y + 7
	}

	// Root row
	{
		lbl := "Root  "
		lw  := rl.MeasureTextEx(font, to_cstring(lbl), FONT_SIZE - 2, CHAR_SPACING).x
		rl.DrawTextEx(font, to_cstring(lbl), {tx, ty}, FONT_SIZE - 2, CHAR_SPACING, SUBDUED)
		rl.DrawTextEx(font, ":", {tx + lw, ty}, FONT_SIZE - 2, CHAR_SPACING, SUBDUED)
		val_x := tx + lw + 10
		dlg_text(font, proj_root, val_x, ty, FONT_SIZE - 2, CHAR_SPACING, TEXT, px + W - 16, 0)
		ty += ref.y + 12
	}

	// Buttons row — clickable
	{
		BTN_H     :: f32(26)
		BTN_PAD_X :: f32(12)
		BTN_GAP   :: f32(8)

		can_act := path != ""
		has_client := c != nil

		bx := tx
		mouse := rl.GetMousePosition()
		clicked := rl.IsMouseButtonPressed(.LEFT)

		_btn :: proc(font: rl.Font, label: string, bx, by, bh, px_: f32, active: bool,
		             fg, bg_hi: rl.Color, mouse: rl.Vector2, clicked: bool,
		             subdued: rl.Color) -> (next_x: f32, was_clicked: bool) {
			PAD :: f32(12)
			tw := rl.MeasureTextEx(font, to_cstring(label), FONT_SIZE - 1, CHAR_SPACING).x
			bw := tw + PAD * 2
			rect := rl.Rectangle{bx, by, bw, bh}
			hovered := rl.CheckCollisionPointRec(mouse, rect)
			col := fg if active else subdued

			if hovered && active {
				rl.DrawRectangleV({bx, by}, {bw, bh},
					rl.Color{col.r, col.g, col.b, 35})
			}
			rl.DrawRectangleLinesEx(rect, 1, col)
			rl.DrawTextEx(font, to_cstring(label), {bx + PAD, by + (bh - FONT_SIZE) * 0.5 + 1},
				FONT_SIZE - 1, CHAR_SPACING, col)
			return bw + BTN_GAP, hovered && active && clicked
		}

		// Install info for current file
		inst := lsp.lsp_manager_install_info_for_path(&e.lsp_mgr, path)
		can_install := inst.has_install && inst.state != .Running && !has_client

		btn_y := ty
		advance: f32
		did_click: bool

		advance, did_click = _btn(font, "S  Start",   bx, btn_y, BTN_H, BTN_PAD_X, can_act,               GREEN,  GREEN,  mouse, clicked, SUBDUED)
		if did_click { _lspd_do_start(d, e, path) }
		bx += advance

		advance, did_click = _btn(font, "T  Stop",    bx, btn_y, BTN_H, BTN_PAD_X, can_act && has_client, RED,    RED,    mouse, clicked, SUBDUED)
		if did_click { _lspd_do_stop(d, e, path) }
		bx += advance

		advance, did_click = _btn(font, "R  Restart", bx, btn_y, BTN_H, BTN_PAD_X, can_act && has_client, YELLOW, YELLOW, mouse, clicked, SUBDUED)
		if did_click { _lspd_do_restart(d, e, path) }
		bx += advance

		_, did_click       = _btn(font, "C  Copy log", bx, btn_y, BTN_H, BTN_PAD_X, has_client,           ACCENT, ACCENT, mouse, clicked, SUBDUED)
		if did_click { _lspd_copy_log(d, c) }

		// Install button — shown when server has auto-install and isn't running
		if inst.has_install {
			install_label_btn: string
			install_col := GREEN
			switch inst.state {
			case .None:    install_label_btn = "I  Install"
			case .Running: install_label_btn = "Installing..."; install_col = YELLOW
			case .Done:    install_label_btn = "Installed ✓"; install_col = GREEN
			case .Failed:  install_label_btn = "Retry Install"; install_col = RED
			}
			bx2 := tx + 380 // right side of button row
			_, did_click = _btn(font, install_label_btn, bx2, btn_y, BTN_H, BTN_PAD_X, can_install || inst.state == .Running, install_col, install_col, mouse, clicked, SUBDUED)
			if did_click && can_install {
				_lspd_do_install(d, e, path, inst.server_name)
			}
		}

		ty += BTN_H + 8

		// Action / error message
		if d.action_msg != "" {
			msg_col := GREEN if d.action_ok else RED
			rl.DrawTextEx(font, to_cstring(d.action_msg), {tx, ty}, FONT_SIZE - 2, CHAR_SPACING, msg_col)
		} else if inst.state == .Running {
			rl.DrawTextEx(font, to_cstring(inst.label if inst.label != "" else "Installing..."),
				{tx, ty}, FONT_SIZE - 2, CHAR_SPACING, YELLOW)
		} else if c != nil && c.error_msg != "" {
			em := fmt.tprintf("! %s", c.error_msg)
			dlg_text(font, em, tx, ty, FONT_SIZE - 2, CHAR_SPACING, RED, px + W - 16, 0)
		} else if server_name == "" && path != "" && !inst.has_install {
			dlg_text(font, fmt.tprintf("no server for '.%s' files", lsp.path_ext(path)),
				tx, ty, FONT_SIZE - 2, CHAR_SPACING, SUBDUED, px + W - 16, 0)
		}
	}

	// Divider before log section
	div_y := info_y + INFO_H - 1
	rl.DrawLineV({px, div_y}, {px + W, div_y}, PANEL_BOR)

	// ── Log section ───────────────────────────────────────────────────────
	log_y := info_y + INFO_H
	log_h := panel_h - HDR_H - INFO_H - FOOT_H

	// Install output takes over log section while installing
	inst2 := lsp.lsp_manager_install_info_for_path(&e.lsp_mgr, path)
	show_install_log := inst2.has_install && (inst2.state == .Running || inst2.state == .Failed || inst2.state == .Done)

	// Log section header
	LOG_HDR_H :: f32(24)
	rl.DrawRectangleV({px, log_y}, {W, LOG_HDR_H}, HDR_BG)
	rl.DrawLineV({px, log_y + LOG_HDR_H}, {px + W, log_y + LOG_HDR_H}, PANEL_BOR)
	log_hdr_text := fmt.tprintf("Install output") if show_install_log else fmt.tprintf("Log  —  %d entries", log_count)
	log_hdr_col  := YELLOW if inst2.state == .Running else (GREEN if inst2.state == .Done else (RED if inst2.state == .Failed else SUBDUED))
	rl.DrawTextEx(font, to_cstring(log_hdr_text),
		{px + 14, log_y + (LOG_HDR_H - ref.y) * 0.5},
		FONT_SIZE - 2, CHAR_SPACING, log_hdr_col if show_install_log else SUBDUED)

	// Auto-scroll indicator
	if !show_install_log && d.auto_scroll && log_count > vis {
		as_str := "auto-scroll"
		as_w := rl.MeasureTextEx(font, to_cstring(as_str), FONT_SIZE - 3, CHAR_SPACING).x
		rl.DrawTextEx(font, to_cstring(as_str),
			{px + W - as_w - 16, log_y + (LOG_HDR_H - ref.y) * 0.5 + 1},
			FONT_SIZE - 3, CHAR_SPACING, ACCENT)
	}

	entries_y := log_y + LOG_HDR_H

	// Install output display
	if show_install_log {
		out_lines := strings.split_lines(inst2.output, context.temp_allocator)
		// Show last `vis` lines of output
		first := max(0, len(out_lines) - vis)
		for i in first..<len(out_lines) {
			row_y := entries_y + f32(i - first) * LOG_LN_H
			if row_y + LOG_LN_H > log_y + log_h { break }
			col := TEXT
			if strings.has_prefix(out_lines[i], "✓") || strings.has_prefix(out_lines[i], "Installed") { col = GREEN }
			if strings.has_prefix(out_lines[i], "✗") || strings.has_prefix(out_lines[i], "error")     { col = RED   }
			if strings.has_prefix(out_lines[i], "WARNING") { col = YELLOW }
			rl.DrawTextEx(font,
				to_cstring(text_clip(font, out_lines[i], W - 32, FONT_SIZE - 2, CHAR_SPACING)),
				{px + 14, row_y + (LOG_LN_H - (FONT_SIZE - 2)) * 0.5},
				FONT_SIZE - 2, CHAR_SPACING, col)
		}
		// After section ends, skip normal log rendering
	}

	if !show_install_log {
	// Log entries
	if log_count == 0 {
		rl.DrawTextEx(font, "no log messages yet",
			{px + 14, entries_y + 10}, FONT_SIZE - 2, CHAR_SPACING, SUBDUED)
	} else {
		for vi in 0..<vis {
			li := d.scroll + vi
			if li >= log_count { break }
			entry := c.logs[li]

			row_y := entries_y + f32(vi) * LOG_LN_H
			_, level_col := _lspd_log_level(entry.level)

			// Alternating row background
			if vi % 2 == 0 {
				rl.DrawRectangleV({px, row_y}, {W, LOG_LN_H},
					rl.Color{0, 0, 0, 12})
			}
			// Error/warning background tint
			switch entry.level {
			case .Error:
				rl.DrawRectangleV({px, row_y}, {W, LOG_LN_H},
					rl.Color{level_col.r, level_col.g, level_col.b, 18})
			case .Warning:
				rl.DrawRectangleV({px, row_y}, {W, LOG_LN_H},
					rl.Color{level_col.r, level_col.g, level_col.b, 10})
			case .Info, .Log:
			}

			// Colored left border
			rl.DrawRectangleV({px, row_y}, {3, LOG_LN_H}, level_col)

			// Level tag
			tag, _ := _lspd_log_level(entry.level)
			tag_w := rl.MeasureTextEx(font, to_cstring(tag), FONT_SIZE - 3, CHAR_SPACING).x
			tag_x := px + 8
			rl.DrawTextEx(font, to_cstring(tag),
				{tag_x, row_y + (LOG_LN_H - (FONT_SIZE - 3)) * 0.5},
				FONT_SIZE - 3, CHAR_SPACING, level_col)

			// Message — clips to available width
			msg_x   := tag_x + tag_w + 6
			max_msg_w := px + W - SB_W - msg_x - 6
			rl.DrawTextEx(font,
				to_cstring(text_clip(font, entry.message, max_msg_w, FONT_SIZE - 2, CHAR_SPACING)),
				{msg_x, row_y + (LOG_LN_H - (FONT_SIZE - 2)) * 0.5},
				FONT_SIZE - 2, CHAR_SPACING, TEXT)
		}
	}

	// Scrollbar track + thumb
	if log_count > vis {
		total_h := f32(vis) * LOG_LN_H
		track_x := px + W - SB_W - 2
		rl.DrawRectangleV({track_x, entries_y}, {SB_W, total_h},
			rl.Color{PANEL_BOR.r, PANEL_BOR.g, PANEL_BOR.b, 60})
		thumb_h := max(20, total_h * f32(vis) / f32(log_count))
		thumb_y := entries_y + (total_h - thumb_h) * f32(d.scroll) / f32(max_scroll)
		rl.DrawRectangleV({track_x, thumb_y}, {SB_W, thumb_h}, PANEL_BOR)
	}
	} // end if !show_install_log

	// ── Footer ────────────────────────────────────────────────────────────
	foot_y := py + panel_h - FOOT_H
	rl.DrawRectangleV({px, foot_y}, {W, FOOT_H}, HDR_BG)
	rl.DrawLineV({px, foot_y}, {px + W, foot_y}, PANEL_BOR)
	hints := "S start   T stop   R restart   C copy   I install   ↑↓ scroll   Esc close"
	hints_w := rl.MeasureTextEx(font, to_cstring(hints), FONT_SIZE - 3, CHAR_SPACING).x
	rl.DrawTextEx(font, to_cstring(hints),
		{px + (W - hints_w) * 0.5, foot_y + (FOOT_H - ref.y) * 0.5 + 1},
		FONT_SIZE - 3, CHAR_SPACING, SUBDUED)

	dlg_end()
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

_lspd_state :: proc(c: ^lsp.Language_Client) -> (label: string, col: rl.Color) {
	if c == nil { return "not started", LINENUM }
	switch c.state {
	case .Created, .Starting:  return "starting...", DIAG_WARN_COL
	case .Initializing:        return "initializing...", DIAG_WARN_COL
	case .Running:             return "running", DIAG_HINT_COL
	case .Shutting_Down:       return "stopping...", DIAG_WARN_COL
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
