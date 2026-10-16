package editor

// Shared helpers for the ui_* components (ADR 0001 §3).
//
// Convention for every component:
// - Pure logic (selection, scroll, filter, divider math, placement) lives in
//   procs with no raylib calls, covered by ui_kit_test.odin.
// - Keyboard is handled in `ui_<x>_handle_input` procs, called from the
//   panel's `input` proc (registry) or a dialog's input handler.
// - Mouse is handled immediate-mode inside the `ui_<x>_draw` / `ui_<x>`
//   procs, which know the rects they draw into, and is reported through
//   their return values. The panel's `input` proc should still return true
//   while the mouse is over it, so the editor underneath ignores the click.
// - Colors come from the active theme globals (BG, TEXT, ACCENT_COL, ...),
//   so components follow theme switches like the rest of the editor.

import rl "vendor:raylib"

UI_ROW_H :: f32(24)
UI_PAD   :: f32(8)

ui_point_in :: proc(p: rl.Vector2, r: rl.Rectangle) -> bool {
	return p.x >= r.x && p.x < r.x + r.width && p.y >= r.y && p.y < r.y + r.height
}

ui_text_w :: proc(font: rl.Font, s: string, size: f32) -> f32 {
	if s == "" { return 0 }
	return rl.MeasureTextEx(font, to_cstring(s), size, CHAR_SPACING).x
}

// Text vertically centered in a row of height h.
ui_text :: proc(font: rl.Font, s: string, x, y, h, size: f32, col: rl.Color, right_edge: f32) {
	ty := y + (h - size) * 0.5
	dlg_text(font, s, x, ty, size, CHAR_SPACING, col, right_edge, 4)
}

ui_with_alpha :: proc(c: rl.Color, a: u8) -> rl.Color { return {c.r, c.g, c.b, a} }

// Clickable button. `focused` draws the keyboard-focus ring, `primary`
// fills with the accent color. Returns true when clicked this frame.
ui_button :: proc(font: rl.Font, r: rl.Rectangle, label: string, focused, primary: bool) -> bool {
	mp    := rl.GetMousePosition()
	hover := ui_point_in(mp, r)
	bg    := STATUS_BG
	fg    := TEXT
	if primary { bg = ACCENT_COL; fg = BG }
	if hover   { bg = ui_with_alpha(primary ? ACCENT_COL : SEL_BG, 220) }
	rl.DrawRectangleRec(r, bg)
	rl.DrawRectangleLinesEx(r, 1, focused ? ACCENT_COL : DIVIDER_COL)
	if focused { rl.DrawRectangleLinesEx({r.x - 2, r.y - 2, r.width + 4, r.height + 4}, 1, ui_with_alpha(ACCENT_COL, 120)) }
	size := FONT_SIZE - 2
	tw   := ui_text_w(font, label, size)
	draw_text(font, to_cstring(label), {r.x + (r.width - tw) * 0.5, r.y + (r.height - size) * 0.5}, size, CHAR_SPACING, fg)
	return hover && rl.IsMouseButtonPressed(.LEFT)
}

// Width a ui_button needs for `label`.
ui_button_w :: proc(font: rl.Font, label: string) -> f32 {
	return ui_text_w(font, label, FONT_SIZE - 2) + 2 * 14
}

// Right-click inside r this frame?
ui_right_clicked :: proc(r: rl.Rectangle) -> bool {
	return rl.IsMouseButtonPressed(.RIGHT) && ui_point_in(rl.GetMousePosition(), r)
}

// Mouse cursor requested by components this frame; applied once per frame by
// ui_cursor_flush (end of ui_registry_draw) so it resets when nothing asks.
@(private="file") _ui_cursor_want: rl.MouseCursor
@(private="file") _ui_cursor_cur:  rl.MouseCursor

ui_cursor_request :: proc(c: rl.MouseCursor) { _ui_cursor_want = c }

ui_cursor_flush :: proc() {
	if _ui_cursor_want != _ui_cursor_cur {
		rl.SetMouseCursor(_ui_cursor_want)
		_ui_cursor_cur = _ui_cursor_want
	}
	_ui_cursor_want = .DEFAULT
}
