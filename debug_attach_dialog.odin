package editor

// Attach-to-remote-debugger dialog.
// Opened from the debug command palette (Attach Remote... command).
// User enters host + port, presses Enter to connect via TCP.

import rl  "vendor:raylib"
import fmt "core:fmt"
import str "core:strings"
import dbg "./debug"

Debug_Attach_Dialog :: struct {
	open:      bool,
	host_buf:  [dynamic]u8,
	port_buf:  [dynamic]u8,
	focus:     int,    // 0 = host, 1 = port, 2 = protocol
	sel_all:   bool,   // applies to whichever field is focused
	protocol:  dbg.Protocol_Kind, // JDWP by default: the common raw-TCP-attach target is a JVM's -agentlib:jdwp socket, not a DAP adapter
	error_msg: string, // heap; cleared on next open
}

debug_attach_init :: proc(d: ^Debug_Attach_Dialog) {
	d.host_buf = make([dynamic]u8)
	d.port_buf = make([dynamic]u8)
	d.protocol = .JDWP
	// Default host
	for b in transmute([]u8)string("localhost") {
		append(&d.host_buf, b)
	}
}

debug_attach_destroy :: proc(d: ^Debug_Attach_Dialog) {
	delete(d.host_buf)
	delete(d.port_buf)
	delete(d.error_msg)
}

debug_attach_open :: proc(d: ^Debug_Attach_Dialog) {
	d.open    = true
	d.focus   = 1 // start focus on port (host is usually localhost)
	d.sel_all = false
	delete(d.error_msg)
	d.error_msg = ""
	// Keep whatever was typed before — user may re-open with same settings
}

debug_attach_close :: proc(d: ^Debug_Attach_Dialog) {
	d.open = false
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

debug_attach_handle_input :: proc(e: ^Editor, d: ^Debug_Attach_Dialog) {
	if !d.open { return }

	if rl.IsKeyPressed(.ESCAPE) { debug_attach_close(d); return }

	// Tab cycles focus: host -> port -> protocol -> host
	if rl.IsKeyPressed(.TAB) {
		d.focus = (d.focus + 1) % 3
		d.sel_all = false
		return
	}

	// Enter → connect
	if rl.IsKeyPressed(.ENTER) {
		_do_attach(e, d)
		return
	}

	// Left/Right toggle protocol when that row is focused
	if d.focus == 2 {
		if rl.IsKeyPressed(.LEFT) || rl.IsKeyPressed(.RIGHT) {
			d.protocol = .DAP if d.protocol == .JDWP else .JDWP
		}
		return
	}

	text_input_handle(_attach_focused_buf(d), &d.sel_all)
}

// ---------------------------------------------------------------------------
// Draw
// ---------------------------------------------------------------------------

debug_attach_draw :: proc(d: ^Debug_Attach_Dialog, e: ^Editor, font: rl.Font, sw, sh: f32) {
	if !d.open { return }

	PANEL_W  :: f32(440)
	HEADER_H :: f32(36)
	ROW_H    :: f32(42)
	FOOTER_H :: f32(50)
	panel_h  := HEADER_H + ROW_H*3 + FOOTER_H

	// Theme-driven (package-level vars synced every frame in _apply_theme),
	// not hardcoded — this dialog used to ignore the active theme entirely.
	BLUE    := ACCENT_COL
	HDR_BG  := STATUS_BG
	BORDER  := DIVIDER_COL
	SUBDUED := LINENUM
	RED     := MSG_COL
	OVERLAY :: rl.Color{0, 0, 0, 160}

	px := (sw - PANEL_W) * 0.5
	py := sh * 0.30

	rl.DrawRectangle(0, 0, i32(sw), i32(sh), OVERLAY)
	px, py = dlg_begin(px, py, PANEL_W, panel_h, BG, BORDER)

	ref := rl.MeasureTextEx(font, "M", FONT_SIZE, CHAR_SPACING)
	cy  := py

	// Header
	rl.DrawRectangleV({px, cy}, {PANEL_W, HEADER_H}, HDR_BG)
	rl.DrawLineV({px, cy + HEADER_H - 1}, {px + PANEL_W, cy + HEADER_H - 1}, BORDER)
	draw_text(font, "Attach to Remote Debugger", {px+12, cy + (HEADER_H-ref.y)*0.5},
		FONT_SIZE, CHAR_SPACING, BLUE)
	cy += HEADER_H

	// Host row
	_draw_field(font, ref, "Host", string(e.debug_attach.host_buf[:]),
		px, cy, PANEL_W, ROW_H,
		d.focus == 0, BLUE, TEXT, SUBDUED, BORDER, HDR_BG)
	cy += ROW_H

	// Port row
	_draw_field(font, ref, "Port", string(e.debug_attach.port_buf[:]),
		px, cy, PANEL_W, ROW_H,
		d.focus == 1, BLUE, TEXT, SUBDUED, BORDER, HDR_BG)
	cy += ROW_H

	// Protocol row
	{
		proto_label := "JDWP (attach to JVM)" if d.protocol == .JDWP else "DAP (attach to adapter)"
		rl.DrawRectangleV({px, cy}, {PANEL_W, ROW_H}, HDR_BG)
		rl.DrawLineV({px, cy + ROW_H - 1}, {px + PANEL_W, cy + ROW_H - 1}, BORDER)
		draw_text(font, "Protocol", {px+12, cy + (ROW_H-ref.y)*0.5}, FONT_SIZE-2, CHAR_SPACING, SUBDUED)
		bdr := BLUE if d.focus == 2 else BORDER
		lbl_w := rl.MeasureTextEx(font, to_cstring("Protocol"), FONT_SIZE-2, CHAR_SPACING).x + 8
		bx := px + 12 + lbl_w + 10
		bw := PANEL_W - bx + px - 12
		rl.DrawRectangleLinesEx({bx, cy + 7, bw, ROW_H - 14}, 1, bdr)
		dlg_text(font, proto_label, bx+6, cy + (ROW_H-ref.y)*0.5, FONT_SIZE, CHAR_SPACING, TEXT, bx+bw, 6)
	}
	cy += ROW_H

	// Footer
	rl.DrawRectangleV({px, cy}, {PANEL_W, FOOTER_H}, HDR_BG)
	rl.DrawLineV({px, cy}, {px+PANEL_W, cy}, BORDER)

	if d.error_msg != "" {
		dlg_text(font, d.error_msg, px+12, cy+8, FONT_SIZE-2, CHAR_SPACING, RED, px+PANEL_W, 10)
	}

	hint := "Tab switch field  Left/Right toggle protocol  Enter connect  Esc cancel"
	hw   := rl.MeasureTextEx(font, to_cstring(hint), FONT_SIZE-3, CHAR_SPACING).x
	draw_text(font, to_cstring(hint),
		{px + PANEL_W - hw - 10, cy + FOOTER_H - ref.y - 7},
		FONT_SIZE-3, CHAR_SPACING, SUBDUED)

	dlg_end()
}

// ---------------------------------------------------------------------------
// Connect
// ---------------------------------------------------------------------------

_do_attach :: proc(e: ^Editor, d: ^Debug_Attach_Dialog) {
	host := str.trim_space(string(d.host_buf[:]))
	port_s := str.trim_space(string(d.port_buf[:]))

	if host == "" {
		_attach_set_err(d, "Host cannot be empty")
		return
	}
	if port_s == "" {
		_attach_set_err(d, "Port cannot be empty")
		return
	}

	port := 0
	ok   := true
	for ch in port_s {
		if ch < '0' || ch > '9' { ok = false; break }
		port = port*10 + int(ch-'0')
	}
	if !ok || port <= 0 || port > 65535 {
		_attach_set_err(d, fmt.tprintf("Invalid port: %s", port_s))
		return
	}

	err := dbg.session_attach_tcp(&e.debug_mgr, host, port, d.protocol)
	if err != "" {
		_attach_set_err(d, err)
		return
	}

	debug_attach_close(d)
}

_attach_set_err :: proc(d: ^Debug_Attach_Dialog, msg: string) {
	delete(d.error_msg)
	d.error_msg = str.clone(msg)
}

_attach_focused_buf :: proc(d: ^Debug_Attach_Dialog) -> ^[dynamic]u8 {
	if d.focus == 0 { return &d.host_buf }
	return &d.port_buf
}

_draw_field :: proc(font: rl.Font, ref: rl.Vector2,
	label, value: string,
	px, cy, pw, row_h: f32,
	focused: bool,
	active_bdr, text_col, subdued_col, border_col, bg_col: rl.Color) {

	rl.DrawRectangleV({px, cy}, {pw, row_h}, bg_col)
	rl.DrawLineV({px, cy + row_h - 1}, {px + pw, cy + row_h - 1}, border_col)

	lbl_w := rl.MeasureTextEx(font, to_cstring(label), FONT_SIZE-2, CHAR_SPACING).x + 8
	draw_text(font, to_cstring(label),
		{px+12, cy + (row_h-ref.y)*0.5},
		FONT_SIZE-2, CHAR_SPACING, subdued_col)

	// Input box
	bx := px + 12 + lbl_w + 10
	bw := pw - bx + px - 12
	bdr := active_bdr if focused else border_col
	rl.DrawRectangleLinesEx({bx, cy + 7, bw, row_h - 14}, 1, bdr)

	inner_x := bx + 6
	dlg_text(font, value if value != "" else (label == "Host" ? "localhost" : "port number"),
		inner_x, cy + (row_h-ref.y)*0.5,
		FONT_SIZE, CHAR_SPACING,
		text_col if value != "" else subdued_col,
		bx + bw, 6)

	// Cursor beam at end of text when focused
	if focused {
		vw := rl.MeasureTextEx(font, to_cstring(value), FONT_SIZE, CHAR_SPACING).x
		beam_x := inner_x + vw
		if beam_x < bx + bw - 4 {
			rl.DrawRectangleV({beam_x, cy + (row_h-ref.y)*0.5}, {2, ref.y}, active_bdr)
		}
	}
}
