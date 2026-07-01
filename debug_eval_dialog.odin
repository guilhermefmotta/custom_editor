package editor

// Expression evaluation dialog — Ctrl+E when debug session active.
// Shows editable expression, evaluates via DAP on Ctrl+Enter,
// displays result value + call stack.

import rl  "vendor:raylib"
import fmt "core:fmt"
import str "core:strings"
import dbg "./debug"

Debug_Eval_Dialog :: struct {
	open:         bool,
	expr_buf:     [dynamic]u8,
	result_scroll: int,
	frame_scroll:  int,
	result_shown:  bool, // becomes true after first evaluate
}

debug_eval_init :: proc(d: ^Debug_Eval_Dialog) {
	d.expr_buf = make([dynamic]u8)
}

debug_eval_destroy :: proc(d: ^Debug_Eval_Dialog) {
	delete(d.expr_buf)
}

debug_eval_open :: proc(d: ^Debug_Eval_Dialog, initial_expr: string) {
	d.open          = true
	d.result_scroll = 0
	d.frame_scroll  = 0
	d.result_shown  = false
	clear(&d.expr_buf)
	for b in transmute([]u8)initial_expr {
		append(&d.expr_buf, b)
	}
}

debug_eval_close :: proc(d: ^Debug_Eval_Dialog) {
	d.open = false
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

debug_eval_handle_input :: proc(e: ^Editor, d: ^Debug_Eval_Dialog) {
	if !d.open { return }

	if rl.IsKeyPressed(.ESCAPE) { debug_eval_close(d); return }

	// Ctrl+Enter = evaluate
	if ctrl() && rl.IsKeyPressed(.ENTER) {
		expr := string(d.expr_buf[:])
		if expr != "" {
			// Store expression in eval_result so manager can echo it
			e.debug_mgr.eval_result.expr = str.clone(expr)
			dbg.debug_evaluate(&e.debug_mgr, expr)
			d.result_shown = true
		}
		return
	}

	// Navigation in frames panel
	if rl.IsKeyPressed(.PAGE_DOWN) {
		d.frame_scroll += 5; return
	}
	if rl.IsKeyPressed(.PAGE_UP) {
		if d.frame_scroll > 5 { d.frame_scroll -= 5 } else { d.frame_scroll = 0 }
		return
	}

	// Backspace in expression
	if rl.IsKeyPressed(.BACKSPACE) && len(d.expr_buf) > 0 {
		pop(&d.expr_buf); return
	}

	// Typed characters
	ch := rl.GetCharPressed()
	for ch != 0 {
		if ch >= 32 {
			buf: [4]u8
			n := encode_utf8(ch, &buf)
			for i in 0..<n { append(&d.expr_buf, buf[i]) }
		}
		ch = rl.GetCharPressed()
	}
}

// ---------------------------------------------------------------------------
// Draw
// ---------------------------------------------------------------------------

debug_eval_draw :: proc(d: ^Debug_Eval_Dialog, e: ^Editor, font: rl.Font, sw, sh: f32) {
	if !d.open { return }

	PANEL_W   :: f32(620)
	HEADER_H  :: f32(36)
	INPUT_H   :: f32(44)
	RESULT_H  :: f32(70)
	STACK_H   :: f32(200)
	FOOTER_H  :: f32(28)
	panel_h   := HEADER_H + INPUT_H + RESULT_H + STACK_H + FOOTER_H

	BLUE   :: rl.Color{137, 180, 250, 255}
	BG     :: rl.Color{30,  30,  46,  255}
	HDR_BG :: rl.Color{24,  24,  37,  255}
	BORDER :: rl.Color{58,  60,  78,  255}
	SEL_BG :: rl.Color{69,  71,  90,  255}
	TEXT   :: rl.Color{205, 214, 244, 255}
	SUBDUED :: rl.Color{108, 112, 134, 255}
	GREEN  :: rl.Color{166, 227, 161, 255}
	RED    :: rl.Color{243, 139, 168, 255}
	YELLOW :: rl.Color{249, 226, 175, 255}
	OVERLAY :: rl.Color{0, 0, 0, 160}

	px := (sw - PANEL_W) * 0.5
	py := (sh - panel_h) * 0.5

	rl.DrawRectangle(0, 0, i32(sw), i32(sh), OVERLAY)
	dlg_begin(px, py, PANEL_W, panel_h, BG, BORDER)

	ref := rl.MeasureTextEx(font, "M", FONT_SIZE, CHAR_SPACING)
	cy  := py

	// ── Header ───────────────────────────────────────────────────
	rl.DrawRectangleV({px, cy}, {PANEL_W, HEADER_H}, HDR_BG)
	rl.DrawLineV({px, cy + HEADER_H - 1}, {px + PANEL_W, cy + HEADER_H - 1}, BORDER)

	state := dbg.manager_get_state(&e.debug_mgr)
	status: string
	status_col := SUBDUED
	switch state {
	case .Idle:     status = "not connected"; status_col = RED
	case .Starting: status = "starting";      status_col = YELLOW
	case .Running:  status = "running";       status_col = GREEN
	case .Paused:   status = "paused";        status_col = BLUE
	case .Stopping: status = "stopping";      status_col = SUBDUED
	}
	rl.DrawTextEx(font, "Evaluate Expression", {px+12, cy + (HEADER_H-ref.y)*0.5},
		FONT_SIZE, CHAR_SPACING, BLUE)
	sw_s := rl.MeasureTextEx(font, to_cstring(status), FONT_SIZE-3, CHAR_SPACING).x
	rl.DrawTextEx(font, to_cstring(status),
		{px + PANEL_W - sw_s - 12, cy + (HEADER_H-ref.y+2)*0.5},
		FONT_SIZE-3, CHAR_SPACING, status_col)
	cy += HEADER_H

	// ── Expression input ─────────────────────────────────────────
	rl.DrawRectangleV({px, cy}, {PANEL_W, INPUT_H}, HDR_BG)
	rl.DrawLineV({px, cy + INPUT_H - 1}, {px + PANEL_W, cy + INPUT_H - 1}, BORDER)

	lbl := to_cstring("> ")
	lbl_w := rl.MeasureTextEx(font, lbl, FONT_SIZE, CHAR_SPACING).x
	rl.DrawTextEx(font, lbl, {px+12, cy + (INPUT_H-ref.y)*0.5}, FONT_SIZE, CHAR_SPACING, BLUE)

	expr_s := string(d.expr_buf[:])
	text_x := px + 12 + lbl_w
	dlg_text(font, expr_s if expr_s != "" else "type expression…",
		text_x, cy + (INPUT_H-ref.y)*0.5,
		FONT_SIZE, CHAR_SPACING, TEXT if expr_s != "" else SUBDUED,
		px+PANEL_W, 8)

	if expr_s != "" {
		ew := rl.MeasureTextEx(font, to_cstring(expr_s), FONT_SIZE, CHAR_SPACING).x
		rl.DrawRectangleV({text_x + ew, cy + (INPUT_H-ref.y)*0.5}, {2, ref.y}, BLUE)
	}
	cy += INPUT_H

	// ── Result panel ──────────────────────────────────────────────
	rl.DrawRectangleV({px, cy}, {PANEL_W, RESULT_H}, rl.Color{20, 20, 34, 255})
	rl.DrawLineV({px, cy + RESULT_H - 1}, {px + PANEL_W, cy + RESULT_H - 1}, BORDER)

	label_y := cy + 6
	rl.DrawTextEx(font, "Result", {px+12, label_y}, FONT_SIZE-3, CHAR_SPACING, SUBDUED)
	label_y += ref.y + 4

	m   := &e.debug_mgr
	res := m.eval_result

	if e.debug_mgr.eval_pending {
		rl.DrawTextEx(font, "evaluating…", {px+12, label_y}, FONT_SIZE-1, CHAR_SPACING, SUBDUED)
	} else if d.result_shown {
		if res.ok {
			val_col := GREEN
			dlg_text(font, res.result, px+12, label_y, FONT_SIZE, CHAR_SPACING, val_col, px+PANEL_W, 8)
			if res.type_ != "" {
				ty_w := rl.MeasureTextEx(font, to_cstring(res.result), FONT_SIZE, CHAR_SPACING).x
				type_x := px + 12 + ty_w + 8
				dlg_text(font, fmt.tprintf("(%s)", res.type_), type_x, label_y + 2,
					FONT_SIZE-3, CHAR_SPACING, SUBDUED, px+PANEL_W, 8)
			}
		} else {
			dlg_text(font, res.result, px+12, label_y, FONT_SIZE-1, CHAR_SPACING, RED, px+PANEL_W, 8)
		}
	} else {
		rl.DrawTextEx(font, "Ctrl+Enter to evaluate", {px+12, label_y},
			FONT_SIZE-1, CHAR_SPACING, SUBDUED)
	}
	cy += RESULT_H

	// ── Call stack ───────────────────────────────────────────────
	rl.DrawRectangleV({px, cy}, {PANEL_W, STACK_H}, BG)
	rl.DrawLineV({px, cy + STACK_H - 1}, {px + PANEL_W, cy + STACK_H - 1}, BORDER)

	rl.DrawTextEx(font, "Call Stack", {px+12, cy + 6}, FONT_SIZE-3, CHAR_SPACING, SUBDUED)

	FRAME_H :: f32(22)
	frames   := dbg.manager_get_frames(m)
	list_top := cy + 6 + ref.y + 6
	n_vis    := int((STACK_H - (list_top - cy)) / FRAME_H)

	if len(frames) == 0 {
		rl.DrawTextEx(font, state == .Idle ? "not connected" : (state == .Running ? "running…" : "no frames"),
			{px+14, list_top + 4}, FONT_SIZE-2, CHAR_SPACING, SUBDUED)
	} else {
		if d.frame_scroll >= len(frames) { d.frame_scroll = max(0, len(frames)-1) }
		for vi in 0..<n_vis {
			fi := d.frame_scroll + vi
			if fi >= len(frames) { break }
			f    := frames[fi]
			fy   := list_top + f32(vi)*FRAME_H
			is_active := fi == m.active_frame

			if is_active {
				rl.DrawRectangleV({px, fy}, {PANEL_W, FRAME_H}, SEL_BG)
				rl.DrawRectangleV({px, fy}, {3, FRAME_H}, YELLOW)
			}

			ty := fy + (FRAME_H - ref.y)*0.5

			// Frame number
			num_s := fmt.tprintf("#%d", fi)
			rl.DrawTextEx(font, to_cstring(num_s), {px+8, ty}, FONT_SIZE-3, CHAR_SPACING, SUBDUED)
			num_w := rl.MeasureTextEx(font, to_cstring(num_s), FONT_SIZE-3, CHAR_SPACING).x

			// Function name
			name_col := BLUE if is_active else TEXT
			dlg_text(font, f.name, px+8+num_w+6, ty, FONT_SIZE-1, CHAR_SPACING, name_col,
				px + PANEL_W*0.55, 4)

			// Source:line on right
			if f.source != "" {
				base := path_basename(f.source)
				loc  := fmt.tprintf("%s:%d", base, f.line)
				lw   := rl.MeasureTextEx(font, to_cstring(loc), FONT_SIZE-3, CHAR_SPACING).x
				rl.DrawTextEx(font, to_cstring(loc),
					{px + PANEL_W - lw - 12, ty + 2},
					FONT_SIZE-3, CHAR_SPACING, SUBDUED)
			}
		}
	}
	cy += STACK_H

	// ── Footer ───────────────────────────────────────────────────
	rl.DrawRectangleV({px, cy}, {PANEL_W, FOOTER_H}, HDR_BG)
	rl.DrawLineV({px, cy}, {px+PANEL_W, cy}, BORDER)
	hint := "Ctrl+Enter evaluate  PgUp/PgDn scroll stack  Esc close"
	hw   := rl.MeasureTextEx(font, to_cstring(hint), FONT_SIZE-3, CHAR_SPACING).x
	rl.DrawTextEx(font, to_cstring(hint),
		{px + PANEL_W - hw - 10, cy + (FOOTER_H-ref.y)*0.5},
		FONT_SIZE-3, CHAR_SPACING, SUBDUED)

	dlg_end()
}

// ---------------------------------------------------------------------------
// UTF-8 encode helper
// ---------------------------------------------------------------------------

encode_utf8 :: proc(r: rune, buf: ^[4]u8) -> int {
	switch {
	case r < 0x80:
		buf[0] = u8(r)
		return 1
	case r < 0x800:
		buf[0] = 0xC0 | u8(r >> 6)
		buf[1] = 0x80 | u8(r & 0x3F)
		return 2
	case r < 0x10000:
		buf[0] = 0xE0 | u8(r >> 12)
		buf[1] = 0x80 | u8((r >> 6) & 0x3F)
		buf[2] = 0x80 | u8(r & 0x3F)
		return 3
	case:
		buf[0] = 0xF0 | u8(r >> 18)
		buf[1] = 0x80 | u8((r >> 12) & 0x3F)
		buf[2] = 0x80 | u8((r >> 6) & 0x3F)
		buf[3] = 0x80 | u8(r & 0x3F)
		return 4
	}
}
