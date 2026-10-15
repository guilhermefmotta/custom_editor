package editor

// List component: selection, scroll (arrows, PgUp/PgDn, Home/End, mouse
// wheel), click-to-select and a case-insensitive text filter.
//
// Two layers:
// - Ui_List_Nav  {selected, scroll} — pure navigation, no allocation. Usable
//   by dialogs that already own their own item array (workspace_dialog).
// - Ui_List      Ui_List_Nav + filter text + the filtered index list.
//
// Typical use in a panel:
//   st: Ui_List                         // package-level, per screen
//   labels := []string{...}
//   // input proc:
//   switch ui_list_handle_input(&st, labels, VIS) {
//   case .Activate: do_something(labels[ui_list_selected_item(&st)])
//   case .Cancel:   close()
//   case .None, .Moved, .Filter_Changed:
//   }
//   // draw proc:
//   ui_list_filter_draw(&st, font, filter_rect, "Filter...")
//   ui_list_draw(&st, font, list_rect, labels)
//   // shutdown: ui_list_destroy(&st)

import rl "vendor:raylib"

Ui_List_Nav :: struct {
	selected: int,
	scroll:   int,
}

Ui_List :: struct {
	using nav: Ui_List_Nav,
	filter:    [dynamic]u8,
	sel_all:   bool,
	visible:   [dynamic]int, // indices into the caller's items passing the filter
	built:     bool,         // visible[] computed at least once
	n_source:  int,          // item count `visible` was built from
}

Ui_List_Event :: enum u8 { None, Moved, Activate, Cancel, Filter_Changed }

// ---------------------------------------------------------------------------
// Pure navigation
// ---------------------------------------------------------------------------

// Clamp selection to [0, count) and scroll so the selection is on screen and
// the viewport never runs past the end.
ui_list_clamp :: proc(n: ^Ui_List_Nav, count, vis_rows: int) {
	if count <= 0 { n.selected = 0; n.scroll = 0; return }
	vis := max(vis_rows, 1)
	n.selected = clamp(n.selected, 0, count - 1)
	if n.selected < n.scroll        { n.scroll = n.selected }
	if n.selected >= n.scroll + vis { n.scroll = n.selected - vis + 1 }
	n.scroll = clamp(n.scroll, 0, max(0, count - vis))
}

ui_list_move :: proc(n: ^Ui_List_Nav, delta, count, vis: int) {
	n.selected += delta
	ui_list_clamp(n, count, vis)
}

ui_list_set :: proc(n: ^Ui_List_Nav, idx, count, vis: int) {
	n.selected = idx
	ui_list_clamp(n, count, vis)
}

// Mouse-wheel scroll: moves the viewport only, then pulls the selection
// along if it fell off screen.
ui_list_scroll_by :: proc(n: ^Ui_List_Nav, delta, count, vis_rows: int) {
	vis := max(vis_rows, 1)
	n.scroll = clamp(n.scroll + delta, 0, max(0, count - vis))
	if count > 0 {
		n.selected = clamp(n.selected, n.scroll, min(count - 1, n.scroll + vis - 1))
	}
}

// Row index under mouse y for a list drawn at top y with row height h, or -1.
ui_list_row_at :: proc(n: Ui_List_Nav, top, row_h, mouse_y: f32, count, vis: int) -> int {
	if mouse_y < top || row_h <= 0 { return -1 }
	r := int((mouse_y - top) / row_h)
	if r >= vis { return -1 }
	idx := n.scroll + r
	return idx if idx < count else -1
}

// ---------------------------------------------------------------------------
// Pure filter
// ---------------------------------------------------------------------------

// Rebuild l.visible from labels with the current filter (case-insensitive
// substring, same as the palette). Resets the selection to the first match.
ui_list_apply_filter :: proc(l: ^Ui_List, labels: []string) {
	clear(&l.visible)
	q := string(l.filter[:])
	for s, i in labels { if pal_match(s, q) { append(&l.visible, i) } }
	l.built    = true
	l.n_source = len(labels)
	l.selected = 0
	l.scroll   = 0
}

ui_list_set_filter :: proc(l: ^Ui_List, text: string, labels: []string) {
	clear(&l.filter)
	append(&l.filter, text)
	ui_list_apply_filter(l, labels)
}

// Ensure visible[] matches labels (first use or the item count changed).
ui_list_sync :: proc(l: ^Ui_List, labels: []string) {
	if !l.built || l.n_source != len(labels) { ui_list_apply_filter(l, labels) }
}

ui_list_count :: proc(l: ^Ui_List) -> int { return len(l.visible) }

// Index into the caller's items of the selected row, or -1.
ui_list_selected_item :: proc(l: ^Ui_List) -> int {
	if l.selected < 0 || l.selected >= len(l.visible) { return -1 }
	return l.visible[l.selected]
}

ui_list_destroy :: proc(l: ^Ui_List) {
	delete(l.filter)
	delete(l.visible)
	l^ = {}
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

// Keyboard navigation (arrows, PgUp/PgDn, Home/End) plus, optionally, the
// mouse wheel: inside wheel_area (if it has a size) or anywhere when
// wheel_anywhere (modal dialogs that don't draw through ui_list_draw).
// Returns true if the selection/scroll changed.
ui_list_handle_nav :: proc(n: ^Ui_List_Nav, count, vis: int, wheel_area := rl.Rectangle{}, wheel_anywhere := false) -> bool {
	before := n^
	switch {
	case key_rep(.UP):        ui_list_move(n, -1, count, vis)
	case key_rep(.DOWN):      ui_list_move(n, +1, count, vis)
	case key_rep(.PAGE_UP):   ui_list_move(n, -vis, count, vis)
	case key_rep(.PAGE_DOWN): ui_list_move(n, +vis, count, vis)
	case rl.IsKeyPressed(.HOME): ui_list_set(n, 0, count, vis)
	case rl.IsKeyPressed(.END):  ui_list_set(n, count - 1, count, vis)
	case:
		wheel := rl.GetMouseWheelMove()
		in_area := wheel_anywhere || (wheel_area.width > 0 && ui_point_in(rl.GetMousePosition(), wheel_area))
		if wheel != 0 && in_area {
			ui_list_scroll_by(n, wheel > 0 ? -3 : 3, count, vis)
		}
	}
	return n^ != before
}

// Full keyboard handling: nav, Enter (Activate), Esc (Cancel) and typing
// into the filter. The mouse (wheel, click) is handled by ui_list_draw.
ui_list_handle_input :: proc(l: ^Ui_List, labels: []string, vis: int) -> Ui_List_Event {
	ui_list_sync(l, labels)
	if rl.IsKeyPressed(.ESCAPE) { return .Cancel }
	if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) {
		return .Activate if ui_list_selected_item(l) >= 0 else .None
	}
	if ui_list_handle_nav(&l.nav, len(l.visible), vis) { return .Moved }
	if text_input_handle(&l.filter, &l.sel_all) {
		ui_list_apply_filter(l, labels)
		return .Filter_Changed
	}
	return .None
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

// Draws the filtered rows in r. Left click selects a row (returns
// clicked=true; double_click=true on a second click on the same row within
// 0.35s). Right click also selects, so callers can then open a context menu.
// interactive = false ignores the mouse (e.g. while a menu/confirm is on top).
ui_list_draw :: proc(l: ^Ui_List, font: rl.Font, r: rl.Rectangle, labels: []string, row_h := UI_ROW_H, interactive := true) -> (clicked, double_click: bool) {
	ui_list_sync(l, labels)
	vis   := max(1, int(r.height / row_h))
	count := len(l.visible)
	ui_list_clamp(&l.nav, count, vis)

	ui_scissor_begin(i32(r.x), i32(r.y), i32(r.width), i32(r.height))
	q    := string(l.filter[:])
	size := FONT_SIZE - 1
	for vi in 0 ..< vis {
		idx := l.scroll + vi
		if idx >= count { break }
		y := r.y + f32(vi) * row_h
		if idx == l.selected {
			rl.DrawRectangleRec({r.x, y, r.width, row_h}, SEL_BG)
			rl.DrawRectangleRec({r.x, y, 3, row_h}, ACCENT_COL)
		}
		_dlg_text_hl(font, labels[l.visible[idx]], q, r.x + 10, y + (row_h - size) * 0.5, size, CHAR_SPACING, TEXT, DIFF_ADD_COL, r.x + r.width, 10)
	}
	if count == 0 {
		ui_text(font, "(no matches)", r.x + 10, r.y, row_h, size, LINENUM, r.x + r.width)
	}
	if count > vis { // scrollbar
		th := r.height * f32(vis) / f32(count)
		ty := r.y + r.height * f32(l.scroll) / f32(count)
		rl.DrawRectangleRec({r.x + r.width - 3, ty, 3, th}, DIVIDER_COL)
	}
	rl.EndScissorMode()
	dlg_restore()

	mp := rl.GetMousePosition()
	if interactive && ui_point_in(mp, r) {
		wheel := rl.GetMouseWheelMove()
		if wheel != 0 { ui_list_scroll_by(&l.nav, wheel > 0 ? -3 : 3, count, vis) }
		if rl.IsMouseButtonPressed(.LEFT) || rl.IsMouseButtonPressed(.RIGHT) {
			row := ui_list_row_at(l.nav, r.y, row_h, mp.y, count, vis)
			if row >= 0 {
				now := rl.GetTime()
				double_click = rl.IsMouseButtonPressed(.LEFT) && row == _ui_list_last_row && now - _ui_list_last_t < 0.35
				_ui_list_last_row = row
				_ui_list_last_t   = now
				l.selected = row
				clicked = true
			}
		}
	}
	return
}

@(private="file") _ui_list_last_row: int = -1
@(private="file") _ui_list_last_t:   f64

// Filter input box (with placeholder) for the list.
ui_list_filter_draw :: proc(l: ^Ui_List, font: rl.Font, r: rl.Rectangle, placeholder := "Filter...") {
	rl.DrawRectangleRec(r, STATUS_BG)
	rl.DrawRectangleLinesEx(r, 1, DIVIDER_COL)
	size := FONT_SIZE - 1
	ty   := r.y + (r.height - size) * 0.5
	q    := string(l.filter[:])
	if q == "" {
		dlg_text(font, placeholder, r.x + 8, ty, size, CHAR_SPACING, LINENUM, r.x + r.width, 8)
		rl.DrawRectangleV({r.x + 8, ty}, {2, size}, ACCENT_COL)
		return
	}
	tw := ui_text_w(font, q, size)
	if l.sel_all { rl.DrawRectangleRec({r.x + 6, ty - 2, tw + 4, size + 4}, ui_with_alpha(ACCENT_COL, 60)) }
	dlg_text(font, q, r.x + 8, ty, size, CHAR_SPACING, TEXT, r.x + r.width, 8)
	rl.DrawRectangleV({r.x + 8 + min(tw, r.width - 16), ty}, {2, size}, ACCENT_COL)
}
