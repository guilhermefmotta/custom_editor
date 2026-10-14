package editor

// Two panes with a mouse-draggable divider.
//   sp := Ui_Split{ratio = 0.4, min_a = 120, min_b = 120}   // per-screen state
//   a, b := ui_split(&sp, rect)                             // in draw: drag + divider
//   ... draw into a and b ...
// vertical = false → side by side (divider is a vertical bar, drag on x);
// vertical = true  → stacked (divider is horizontal, drag on y).

import rl "vendor:raylib"

UI_SPLIT_W :: f32(4) // divider thickness (also the grab area, plus slop)

Ui_Split :: struct {
	ratio:    f32, // share of the first pane, 0..1 (0 → treated as 0.5)
	vertical: bool,
	min_a:    f32, // minimum size in px of each side
	min_b:    f32,
	dragging: bool,
}

// Pure: ratio for a divider dragged to `mouse` within [origin, origin+total),
// clamped so neither side is smaller than its minimum. If both minimums
// don't fit, splits proportionally to the minimums.
ui_split_ratio_from_mouse :: proc(total, origin, mouse, min_a, min_b: f32) -> f32 {
	avail := total - UI_SPLIT_W
	if avail <= 0 { return 0.5 }
	if min_a + min_b >= avail {
		if min_a + min_b <= 0 { return 0.5 }
		return min_a / (min_a + min_b)
	}
	a := clamp(mouse - origin - UI_SPLIT_W * 0.5, min_a, avail - min_b)
	return a / avail
}

// Pure: rects of the first pane, second pane and divider.
ui_split_rects :: proc(r: rl.Rectangle, s: Ui_Split) -> (a, b, div: rl.Rectangle) {
	ratio := s.ratio if s.ratio > 0 else 0.5
	if s.vertical {
		avail := max(0, r.height - UI_SPLIT_W)
		ha := avail * ratio
		a   = {r.x, r.y, r.width, ha}
		div = {r.x, r.y + ha, r.width, UI_SPLIT_W}
		b   = {r.x, r.y + ha + UI_SPLIT_W, r.width, avail - ha}
	} else {
		avail := max(0, r.width - UI_SPLIT_W)
		wa := avail * ratio
		a   = {r.x, r.y, wa, r.height}
		div = {r.x + wa, r.y, UI_SPLIT_W, r.height}
		b   = {r.x + wa + UI_SPLIT_W, r.y, avail - wa, r.height}
	}
	return
}

// Handles the drag, draws the divider, returns the two pane rects.
ui_split :: proc(s: ^Ui_Split, r: rl.Rectangle, interactive := true) -> (a, b: rl.Rectangle) {
	_, _, div := ui_split_rects(r, s^)
	mp   := rl.GetMousePosition()
	grab := rl.Rectangle{div.x - 3, div.y, div.width + 6, div.height}
	if s.vertical { grab = {div.x, div.y - 3, div.width, div.height + 6} }
	hover := interactive && ui_point_in(mp, grab)

	if s.dragging {
		if rl.IsMouseButtonDown(.LEFT) {
			if s.vertical {
				s.ratio = ui_split_ratio_from_mouse(r.height, r.y, mp.y, s.min_a, s.min_b)
			} else {
				s.ratio = ui_split_ratio_from_mouse(r.width, r.x, mp.x, s.min_a, s.min_b)
			}
		} else {
			s.dragging = false
		}
	} else if hover && rl.IsMouseButtonPressed(.LEFT) {
		s.dragging = true
	}

	a, b, div = ui_split_rects(r, s^)
	col := ACCENT_COL if s.dragging || hover else DIVIDER_COL
	rl.DrawRectangleRec(div, col)
	if hover || s.dragging {
		ui_cursor_request(.RESIZE_NS if s.vertical else .RESIZE_EW)
	}
	return
}
