package editor

// Expression evaluation dialog — Ctrl+E (Shift optional) whenever a debug
// session is active, and the palette's "Debug: Evaluate" command. The
// persistent bottom debug panel (Ctrl+... no binding of its own now, opens
// automatically on breakpoint/step pause) still shows call stack/variables/
// console, but Evaluate itself always goes through this modal dialog.
// Modeled on IntelliJ's Evaluate popup: boxed expression input, then a
// Result tree — the evaluated expression is the root row, expandable into
// its fields (or array elements) on demand via manager_expand_variable.

import rl  "vendor:raylib"
import fmt "core:fmt"
import str "core:strings"
import dbg "./debug"

Debug_Eval_Dialog :: struct {
	open:               bool,
	expr_buf:           [dynamic]u8,
	tree_scroll:        int,
	result_shown:       bool, // becomes true after first evaluate
	expanded:           map[int]bool, // variables_ref -> user has expanded this node
	root_auto_expanded: bool, // the current eval_result's root has already been auto-opened once
}

debug_eval_init :: proc(d: ^Debug_Eval_Dialog) {
	d.expr_buf = make([dynamic]u8)
	d.expanded = make(map[int]bool)
}

debug_eval_destroy :: proc(d: ^Debug_Eval_Dialog) {
	delete(d.expr_buf)
	delete(d.expanded)
}

debug_eval_open :: proc(d: ^Debug_Eval_Dialog, initial_expr: string) {
	d.open               = true
	d.tree_scroll        = 0
	d.result_shown       = false
	d.root_auto_expanded = false
	clear(&d.expanded)
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
			e.debug_mgr.eval_result.expr = str.clone(expr)
			dbg.debug_evaluate(&e.debug_mgr, expr)
			d.result_shown       = true
			d.root_auto_expanded = false
			clear(&d.expanded)
		}
		return
	}

	// Scroll the result tree (PageUp/Down, arrows, or mouse wheel — wheel is
	// the main way, since an expanded tree quickly grows past the fixed
	// TREE_H box and there was previously no way to reach the bottom of it)
	if rl.IsKeyPressed(.PAGE_DOWN) { d.tree_scroll += 5; return }
	if rl.IsKeyPressed(.PAGE_UP)   { d.tree_scroll = max(0, d.tree_scroll-5); return }
	if rl.IsKeyPressed(.DOWN)      { d.tree_scroll += 1; return }
	if rl.IsKeyPressed(.UP)        { d.tree_scroll = max(0, d.tree_scroll-1); return }
	wheel := rl.GetMouseWheelMove()
	if wheel != 0 { d.tree_scroll = max(0, d.tree_scroll - int(wheel*3)); return }

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
// Result tree
// ---------------------------------------------------------------------------

Eval_Tree_Row :: struct {
	name:  string,
	value: string,
	type_: string,
	ref:   int,
	depth: int,
}

// Flattens the currently-expanded tree (root = the eval result, children =
// whatever's been expanded so far) into a list of visible rows. Triggers
// manager_expand_variable for any expanded-but-not-yet-loaded node, so the
// fetch is kicked off the first time a row becomes visible.
_eval_collect_rows :: proc(m: ^dbg.Debug_Manager, d: ^Debug_Eval_Dialog, out: ^[dynamic]Eval_Tree_Row) {
	res := m.eval_result
	root := Eval_Tree_Row{name = "result", value = res.result, type_ = res.type_, ref = res.variables_ref, depth = 0}
	append(out, root)
	if res.variables_ref > 0 && (d.expanded[res.variables_ref] or_else false) {
		_eval_collect_children(m, d, res.variables_ref, 1, out)
	}
}

_eval_collect_children :: proc(m: ^dbg.Debug_Manager, d: ^Debug_Eval_Dialog, ref: int, depth: int, out: ^[dynamic]Eval_Tree_Row) {
	children, loaded := dbg.manager_get_children(m, ref)
	if !loaded {
		dbg.manager_expand_variable(m, ref)
		append(out, Eval_Tree_Row{name = "…", value = "", type_ = "", ref = 0, depth = depth})
		return
	}
	if len(children) == 0 {
		append(out, Eval_Tree_Row{name = "(no fields)", value = "", type_ = "", ref = 0, depth = depth})
		return
	}
	for c in children {
		append(out, Eval_Tree_Row{name = c.name, value = c.value, type_ = c.type_, ref = c.variables_ref, depth = depth})
		if c.variables_ref > 0 && (d.expanded[c.variables_ref] or_else false) {
			_eval_collect_children(m, d, c.variables_ref, depth+1, out)
		}
	}
}

// ---------------------------------------------------------------------------
// Draw
// ---------------------------------------------------------------------------

debug_eval_draw :: proc(d: ^Debug_Eval_Dialog, e: ^Editor, font: rl.Font, sw, sh: f32) {
	if !d.open { return }

	PANEL_W    :: f32(620)
	HEADER_H   :: f32(40)
	LABEL_H    :: f32(20)
	INPUT_H    :: f32(34)
	HINT_H     :: f32(20)
	GAP        :: f32(8)
	TREE_H     :: f32(280)
	FOOTER_H   :: f32(44)
	panel_h    := HEADER_H + LABEL_H + INPUT_H + HINT_H + GAP + LABEL_H + TREE_H + FOOTER_H

	BLUE    :: rl.Color{137, 180, 250, 255}
	BG      :: rl.Color{30,  30,  46,  255}
	HDR_BG  :: rl.Color{24,  24,  37,  255}
	BORDER  :: rl.Color{58,  60,  78,  255}
	SEL_BG  :: rl.Color{69,  71,  90,  255}
	TEXT    :: rl.Color{205, 214, 244, 255}
	SUBDUED :: rl.Color{108, 112, 134, 255}
	GREEN   :: rl.Color{166, 227, 161, 255}
	RED     :: rl.Color{243, 139, 168, 255}
	YELLOW  :: rl.Color{249, 226, 175, 255}
	OVERLAY :: rl.Color{0, 0, 0, 160}

	px := (sw - PANEL_W) * 0.5
	py := (sh - panel_h) * 0.5

	rl.DrawRectangle(0, 0, i32(sw), i32(sh), OVERLAY)
	px, py = dlg_begin(px, py, PANEL_W, panel_h, BG, BORDER)

	ref := rl.MeasureTextEx(font, "M", FONT_SIZE, CHAR_SPACING)
	cy  := py
	mouse := rl.GetMousePosition()
	clicked := rl.IsMouseButtonPressed(.LEFT)

	m := &e.debug_mgr
	state := dbg.manager_get_state(m)

	// ── Header: centered title + small state badge ─────────────────
	rl.DrawRectangleV({px, cy}, {PANEL_W, HEADER_H}, HDR_BG)
	rl.DrawLineV({px, cy + HEADER_H - 1}, {px + PANEL_W, cy + HEADER_H - 1}, BORDER)
	title_w := rl.MeasureTextEx(font, "Evaluate", FONT_SIZE+2, CHAR_SPACING).x
	rl.DrawTextEx(font, "Evaluate", {px + (PANEL_W-title_w)*0.5, cy + (HEADER_H-ref.y)*0.5}, FONT_SIZE+2, CHAR_SPACING, TEXT)

	status: string
	status_col := SUBDUED
	switch state {
	case .Idle:     status = "not connected"; status_col = RED
	case .Starting: status = "starting";      status_col = YELLOW
	case .Running:  status = "running";       status_col = GREEN
	case .Paused:   status = "paused";        status_col = BLUE
	case .Stopping: status = "stopping";      status_col = SUBDUED
	}
	sw_s := rl.MeasureTextEx(font, to_cstring(status), FONT_SIZE-3, CHAR_SPACING).x
	rl.DrawTextEx(font, to_cstring(status), {px + PANEL_W - sw_s - 12, cy + (HEADER_H-ref.y+2)*0.5}, FONT_SIZE-3, CHAR_SPACING, status_col)
	cy += HEADER_H + GAP*0.5

	// ── Expression label + boxed input ───────────────────────────────
	rl.DrawTextEx(font, "Expression:", {px+PAD_X, cy}, FONT_SIZE-1, CHAR_SPACING, SUBDUED)
	cy += LABEL_H

	input_rect := rl.Rectangle{px+PAD_X, cy, PANEL_W-PAD_X*2, INPUT_H}
	rl.DrawRectangleRec(input_rect, rl.Color{20, 20, 34, 255})
	rl.DrawRectangleLinesEx(input_rect, 1, BLUE)

	expr_s := string(d.expr_buf[:])
	text_x := input_rect.x + 8
	dlg_text(font, expr_s if expr_s != "" else "type expression…",
		text_x, cy + (INPUT_H-ref.y)*0.5, FONT_SIZE, CHAR_SPACING,
		TEXT if expr_s != "" else SUBDUED, input_rect.x+input_rect.width, 8)
	if expr_s != "" {
		ew := rl.MeasureTextEx(font, to_cstring(expr_s), FONT_SIZE, CHAR_SPACING).x
		rl.DrawRectangleV({text_x + ew, cy + (INPUT_H-ref.y)*0.5}, {2, ref.y}, BLUE)
	}
	cy += INPUT_H

	hint := "Ctrl+Enter to evaluate"
	hint_w := rl.MeasureTextEx(font, to_cstring(hint), FONT_SIZE-3, CHAR_SPACING).x
	rl.DrawTextEx(font, to_cstring(hint), {px+PANEL_W-hint_w-PAD_X, cy+2}, FONT_SIZE-3, CHAR_SPACING, SUBDUED)
	cy += HINT_H + GAP

	// ── Result label + tree ───────────────────────────────────────────
	rl.DrawTextEx(font, "Result:", {px+PAD_X, cy}, FONT_SIZE-1, CHAR_SPACING, SUBDUED)
	cy += LABEL_H

	tree_rect := rl.Rectangle{px+PAD_X, cy, PANEL_W-PAD_X*2, TREE_H}
	rl.DrawRectangleRec(tree_rect, rl.Color{20, 20, 34, 255})
	rl.DrawRectangleLinesEx(tree_rect, 1, BORDER)

	if m.eval_pending {
		rl.DrawTextEx(font, "evaluating…", {tree_rect.x+8, tree_rect.y+6}, FONT_SIZE-1, CHAR_SPACING, SUBDUED)
	} else if !d.result_shown {
		rl.DrawTextEx(font, "Ctrl+Enter to evaluate", {tree_rect.x+8, tree_rect.y+6}, FONT_SIZE-1, CHAR_SPACING, SUBDUED)
	} else if !m.eval_result.ok {
		dlg_text(font, m.eval_result.result, tree_rect.x+8, tree_rect.y+6, FONT_SIZE-1, CHAR_SPACING, RED, tree_rect.x+tree_rect.width-8, 4)
	} else {
		// Auto-expand the root exactly once per evaluate, so an expandable
		// result opens immediately (matches IntelliJ) without extra clicks.
		if !d.root_auto_expanded && m.eval_result.variables_ref > 0 {
			d.expanded[m.eval_result.variables_ref] = true
			dbg.manager_expand_variable(m, m.eval_result.variables_ref)
			d.root_auto_expanded = true
		}

		rows := make([dynamic]Eval_Tree_Row, 0, 32, context.temp_allocator)
		_eval_collect_rows(m, d, &rows)

		ROW_H :: f32(22)
		INDENT_W :: f32(16)
		n_vis := int(TREE_H) / int(ROW_H)
		if d.tree_scroll > max(0, len(rows)-n_vis) { d.tree_scroll = max(0, len(rows)-n_vis) }

		for vi in 0..<n_vis {
			ri := d.tree_scroll + vi
			if ri >= len(rows) { break }
			row := rows[ri]
			ry := tree_rect.y + f32(vi)*ROW_H
			row_rect := rl.Rectangle{tree_rect.x, ry, tree_rect.width, ROW_H}
			is_open := row.ref > 0 && (d.expanded[row.ref] or_else false)

			if clicked && row.ref > 0 && rl.CheckCollisionPointRec(mouse, row_rect) {
				d.expanded[row.ref] = !is_open
				if !is_open { dbg.manager_expand_variable(m, row.ref) }
			}

			tx := tree_rect.x + 8 + f32(row.depth)*INDENT_W
			ty := ry + (ROW_H-ref.y)*0.5

			if row.ref > 0 {
				arrow := is_open ? "-" : "+"
				rl.DrawTextEx(font, to_cstring(arrow), {tx, ty}, FONT_SIZE-1, CHAR_SPACING, SUBDUED)
			}
			name_x := tx + 14

			if row.name == "…" {
				rl.DrawTextEx(font, "loading…", {name_x, ty}, FONT_SIZE-1, CHAR_SPACING, SUBDUED)
				continue
			}
			if row.value == "" && row.ref == 0 {
				rl.DrawTextEx(font, to_cstring(row.name), {name_x, ty}, FONT_SIZE-1, CHAR_SPACING, SUBDUED)
				continue
			}

			name_col := row.depth == 0 ? BLUE : TEXT
			rl.DrawTextEx(font, to_cstring(row.name), {name_x, ty}, FONT_SIZE-1, CHAR_SPACING, name_col)
			name_w := rl.MeasureTextEx(font, to_cstring(row.name), FONT_SIZE-1, CHAR_SPACING).x

			eq_x := name_x + name_w + 6
			rl.DrawTextEx(font, "=", {eq_x, ty}, FONT_SIZE-1, CHAR_SPACING, SUBDUED)
			val_x := eq_x + 12

			view_w: f32 = 0
			if row.ref > 0 && !is_open {
				view_lbl := "View"
				view_w = rl.MeasureTextEx(font, to_cstring(view_lbl), FONT_SIZE-2, CHAR_SPACING).x + 8
				rl.DrawTextEx(font, to_cstring(view_lbl), {tree_rect.x+tree_rect.width-view_w-4, ty}, FONT_SIZE-2, CHAR_SPACING, BLUE)
			}

			val_col := row.ref > 0 ? YELLOW : (row.depth == 0 ? GREEN : TEXT)
			dlg_text(font, row.value, val_x, ty, FONT_SIZE-1, CHAR_SPACING, val_col, tree_rect.x+tree_rect.width-view_w-8, 4)
		}
	}
	cy += TREE_H

	// ── Footer: Close / Evaluate buttons ─────────────────────────────
	rl.DrawRectangleV({px, cy}, {PANEL_W, FOOTER_H}, HDR_BG)
	rl.DrawLineV({px, cy}, {px+PANEL_W, cy}, BORDER)

	BTN_H :: f32(28)
	by := cy + (FOOTER_H-BTN_H)*0.5

	eval_lbl := "Evaluate"
	eval_w := rl.MeasureTextEx(font, to_cstring(eval_lbl), FONT_SIZE-1, CHAR_SPACING).x + 24
	eval_rect := rl.Rectangle{px+PANEL_W-PAD_X-eval_w, by, eval_w, BTN_H}
	eval_hover := rl.CheckCollisionPointRec(mouse, eval_rect)
	rl.DrawRectangleRec(eval_rect, eval_hover ? rl.Color{112, 161, 236, 255} : BLUE)
	ew2 := rl.MeasureTextEx(font, to_cstring(eval_lbl), FONT_SIZE-1, CHAR_SPACING).x
	rl.DrawTextEx(font, to_cstring(eval_lbl), {eval_rect.x + (eval_w-ew2)*0.5, by + (BTN_H-ref.y)*0.5}, FONT_SIZE-1, CHAR_SPACING, rl.Color{17, 17, 27, 255})
	if clicked && eval_hover {
		expr := string(d.expr_buf[:])
		if expr != "" {
			e.debug_mgr.eval_result.expr = str.clone(expr)
			dbg.debug_evaluate(m, expr)
			d.result_shown       = true
			d.root_auto_expanded = false
			clear(&d.expanded)
		}
	}

	close_lbl := "Close"
	close_w := rl.MeasureTextEx(font, to_cstring(close_lbl), FONT_SIZE-1, CHAR_SPACING).x + 24
	close_rect := rl.Rectangle{eval_rect.x-close_w-8, by, close_w, BTN_H}
	close_hover := rl.CheckCollisionPointRec(mouse, close_rect)
	if close_hover { rl.DrawRectangleRec(close_rect, SEL_BG) }
	rl.DrawRectangleLinesEx(close_rect, 1, BORDER)
	cw2 := rl.MeasureTextEx(font, to_cstring(close_lbl), FONT_SIZE-1, CHAR_SPACING).x
	rl.DrawTextEx(font, to_cstring(close_lbl), {close_rect.x + (close_w-cw2)*0.5, by + (BTN_H-ref.y)*0.5}, FONT_SIZE-1, CHAR_SPACING, TEXT)
	if clicked && close_hover { debug_eval_close(d) }

	esc_hint := "Esc close"
	rl.DrawTextEx(font, to_cstring(esc_hint), {px+PAD_X, by + (BTN_H-ref.y)*0.5}, FONT_SIZE-3, CHAR_SPACING, SUBDUED)

	dlg_end()
}

PAD_X :: f32(16)

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
