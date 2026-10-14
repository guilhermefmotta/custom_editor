package editor

// Tabs component.
//   active: int                                   // per-screen state
//   ui_tabs_handle_input(&active, len(labels))    // input: Ctrl+Tab / Ctrl+Shift+Tab
//   ui_tabs(font, rect, labels, &active)          // draw: click to switch; returns changed

import rl "vendor:raylib"

UI_TAB_PAD :: f32(14)

// Pure: next active tab, wrapping around.
ui_tabs_cycle :: proc(active, n, dir: int) -> int {
	if n <= 0 { return 0 }
	return ((active + dir) % n + n) % n
}

// Pure: index of the tab containing x given each tab's width laid out from
// x0, or -1.
ui_tabs_hit :: proc(widths: []f32, x0, x: f32) -> int {
	cx := x0
	for w, i in widths {
		if x >= cx && x < cx + w { return i }
		cx += w
	}
	return -1
}

ui_tabs_handle_input :: proc(active: ^int, n: int) -> bool {
	if ctrl() && rl.IsKeyPressed(.TAB) {
		active^ = ui_tabs_cycle(active^, n, -1 if shift() else 1)
		return true
	}
	return false
}

// Draws the tab strip in r and switches on left click. Returns true when the
// active tab changed this frame.
ui_tabs :: proc(font: rl.Font, r: rl.Rectangle, labels: []string, active: ^int, interactive := true) -> bool {
	size := FONT_SIZE - 1
	widths := make([]f32, len(labels), context.temp_allocator)
	for s, i in labels { widths[i] = ui_text_w(font, s, size) + 2 * UI_TAB_PAD }

	rl.DrawRectangleRec(r, STATUS_BG)
	rl.DrawLineV({r.x, r.y + r.height - 1}, {r.x + r.width, r.y + r.height - 1}, DIVIDER_COL)
	mp := rl.GetMousePosition()
	x  := r.x
	for s, i in labels {
		tr := rl.Rectangle{x, r.y, widths[i], r.height}
		on := i == active^
		if on {
			rl.DrawRectangleRec(tr, BG)
			rl.DrawRectangleRec({tr.x, tr.y + tr.height - 2, tr.width, 2}, ACCENT_COL)
		} else if ui_point_in(mp, tr) {
			rl.DrawRectangleRec(tr, ui_with_alpha(SEL_BG, 120))
		}
		ui_text(font, s, x + UI_TAB_PAD, r.y, r.height, size, on ? TEXT : LINENUM, r.x + r.width)
		x += widths[i]
	}

	if interactive && rl.IsMouseButtonPressed(.LEFT) && ui_point_in(mp, r) {
		hit := ui_tabs_hit(widths, r.x, mp.x)
		if hit >= 0 && hit != active^ { active^ = hit; return true }
	}
	return false
}
