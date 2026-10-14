package editor

// Context menu (right click).
//   menu: Ui_Menu                                          // per-screen state
//   ITEMS :: []string{"Copy", "Rename", "Delete"}          // must outlive the open menu
//   // draw proc, after drawing the thing that was right-clicked (outside any
//   // dlg_begin/dlg_end scissor, so the menu isn't clipped):
//   if ui_right_clicked(row_rect) { ui_menu_open(&menu, rl.GetMousePosition(), ITEMS) }
//   if i := ui_menu_draw(&menu, font, sw, sh); i >= 0 { run(ITEMS[i]) }
//   // input proc (first, while open):
//   if menu.open { if i := ui_menu_handle_input(&menu); i >= 0 { run(ITEMS[i]) }; return true }
// Up/Down + Enter choose, Esc or a click outside closes without a choice.

import rl "vendor:raylib"

UI_MENU_ROW_H :: f32(24)
UI_MENU_W     :: f32(200)

Ui_Menu :: struct {
	open:     bool,
	pos:      rl.Vector2, // requested position (top-left = mouse)
	items:    []string,   // borrowed
	selected: int,
	opened_t: f64,        // ignore the click that opened the menu
}

ui_menu_open :: proc(m: ^Ui_Menu, pos: rl.Vector2, items: []string) {
	m.open     = len(items) > 0
	m.pos      = pos
	m.items    = items
	m.selected = 0
	m.opened_t = rl.GetTime()
}

ui_menu_close :: proc(m: ^Ui_Menu) { m.open = false }

// Pure: top-left so a w×h menu requested at (x, y) fits inside sw×sh —
// flips left/up past the right/bottom edge, then clamps to 0.
ui_menu_place :: proc(x, y, w, h, sw, sh: f32) -> (f32, f32) {
	px, py := x, y
	if px + w > sw { px = x - w }
	if py + h > sh { py = y - h }
	if px + w > sw { px = sw - w }
	if py + h > sh { py = sh - h }
	return max(px, 0), max(py, 0)
}

ui_menu_handle_input :: proc(m: ^Ui_Menu) -> int {
	if !m.open { return -1 }
	n := len(m.items)
	switch {
	case rl.IsKeyPressed(.ESCAPE): ui_menu_close(m)
	case key_rep(.UP):             m.selected = ui_tabs_cycle(m.selected, n, -1)
	case key_rep(.DOWN):           m.selected = ui_tabs_cycle(m.selected, n, 1)
	case rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER):
		ui_menu_close(m)
		return m.selected
	}
	return -1
}

// Draws the menu and handles the mouse. Returns the chosen item index or -1.
ui_menu_draw :: proc(m: ^Ui_Menu, font: rl.Font, sw, sh: f32) -> int {
	if !m.open { return -1 }
	h := f32(len(m.items)) * UI_MENU_ROW_H + 8
	x, y := ui_menu_place(m.pos.x, m.pos.y, UI_MENU_W, h, sw, sh)
	r := rl.Rectangle{x, y, UI_MENU_W, h}

	rl.DrawRectangleRec({x + 3, y + 4, r.width, r.height}, {0, 0, 0, 80})
	rl.DrawRectangleRec(r, STATUS_BG)
	rl.DrawRectangleLinesEx(r, 1, DIVIDER_COL)

	mp     := rl.GetMousePosition()
	chosen := -1
	fresh  := rl.GetTime() - m.opened_t < 0.05
	for s, i in m.items {
		row := rl.Rectangle{x + 4, y + 4 + f32(i) * UI_MENU_ROW_H, UI_MENU_W - 8, UI_MENU_ROW_H}
		if ui_point_in(mp, row) && (rl.GetMouseDelta() != {0, 0}) { m.selected = i }
		if i == m.selected { rl.DrawRectangleRec(row, SEL_BG) }
		ui_text(font, s, row.x + 8, row.y, row.height, FONT_SIZE - 1, TEXT, row.x + row.width)
		if !fresh && rl.IsMouseButtonPressed(.LEFT) && ui_point_in(mp, row) { chosen = i }
	}
	if chosen >= 0 {
		ui_menu_close(m)
	} else if !fresh && (rl.IsMouseButtonPressed(.LEFT) || rl.IsMouseButtonPressed(.RIGHT)) && !ui_point_in(mp, r) {
		ui_menu_close(m)
	}
	return chosen
}
