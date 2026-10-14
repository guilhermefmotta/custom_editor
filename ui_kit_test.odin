package editor

// Unit tests for the pure logic of the UI kit + registry
// (features/ui-kit-registry.feature). Run from the repo root:
//   odin test . -define:ODIN_TEST_THREADS=1
// The root package has `main`, which `odin test` simply ignores; raylib is
// linked but never initialized (only pure procs are called here).

import "core:testing"
import rl "vendor:raylib"

@(test)
test_list_nav_selection_and_scroll :: proc(t: ^testing.T) {
	n: Ui_List_Nav
	COUNT :: 100
	VIS   :: 10
	for _ in 0 ..< 12 { ui_list_move(&n, 1, COUNT, VIS) }
	testing.expect_value(t, n.selected, 12)
	testing.expect_value(t, n.scroll, 3) // 12 is the last visible row

	ui_list_move(&n, VIS, COUNT, VIS) // PgDn
	testing.expect_value(t, n.selected, 22)
	ui_list_move(&n, -VIS, COUNT, VIS) // PgUp x2 -> clamps at 0
	ui_list_move(&n, -VIS, COUNT, VIS)
	ui_list_move(&n, -VIS, COUNT, VIS)
	testing.expect_value(t, n.selected, 0)
	testing.expect_value(t, n.scroll, 0)

	ui_list_set(&n, COUNT - 1, COUNT, VIS) // End
	testing.expect_value(t, n.selected, 99)
	testing.expect_value(t, n.scroll, 90)
	ui_list_move(&n, 5, COUNT, VIS)
	testing.expect_value(t, n.selected, 99)

	empty: Ui_List_Nav = {selected = 4, scroll = 2}
	ui_list_clamp(&empty, 0, VIS)
	testing.expect_value(t, empty, Ui_List_Nav{})
}

@(test)
test_list_wheel_scroll :: proc(t: ^testing.T) {
	n: Ui_List_Nav
	ui_list_scroll_by(&n, 3, 100, 10)
	testing.expect_value(t, n.scroll, 3)
	testing.expect_value(t, n.selected, 3) // dragged into view
	ui_list_scroll_by(&n, 1000, 100, 10)
	testing.expect_value(t, n.scroll, 90) // never past the end
	ui_list_scroll_by(&n, -1000, 100, 10)
	testing.expect_value(t, n.scroll, 0)
	testing.expect_value(t, n.selected, 9) // stays on the last visible row

	short: Ui_List_Nav
	ui_list_scroll_by(&short, 3, 4, 10) // fewer items than rows: no scroll
	testing.expect_value(t, short.scroll, 0)
}

@(test)
test_list_row_hit :: proc(t: ^testing.T) {
	n := Ui_List_Nav{scroll = 5}
	testing.expect_value(t, ui_list_row_at(n, 100, 20, 145, 50, 10), 7)
	testing.expect_value(t, ui_list_row_at(n, 100, 20, 90, 50, 10), -1)  // above
	testing.expect_value(t, ui_list_row_at(n, 100, 20, 305, 50, 10), -1) // past visible rows
	testing.expect_value(t, ui_list_row_at(n, 100, 20, 145, 6, 10), -1)  // past item count
}

@(test)
test_list_filter :: proc(t: ^testing.T) {
	items := []string{"main", "develop", "feature/Graph", "fix/graph-crash", "release"}
	l: Ui_List
	defer ui_list_destroy(&l)

	ui_list_sync(&l, items)
	testing.expect_value(t, ui_list_count(&l), 5)
	ui_list_move(&l.nav, 3, ui_list_count(&l), 10)

	ui_list_set_filter(&l, "GRAPH", items)
	testing.expect_value(t, ui_list_count(&l), 2)
	testing.expect_value(t, l.selected, 0) // reset to first match
	testing.expect_value(t, ui_list_selected_item(&l), 2)
	ui_list_move(&l.nav, 1, ui_list_count(&l), 10)
	testing.expect_value(t, items[ui_list_selected_item(&l)], "fix/graph-crash")

	ui_list_set_filter(&l, "zzz", items)
	testing.expect_value(t, ui_list_count(&l), 0)
	testing.expect_value(t, ui_list_selected_item(&l), -1)

	ui_list_set_filter(&l, "", items)
	testing.expect_value(t, ui_list_count(&l), 5)

	// item count changed → sync rebuilds
	ui_list_sync(&l, items[:3])
	testing.expect_value(t, ui_list_count(&l), 3)
}

@(test)
test_tabs :: proc(t: ^testing.T) {
	testing.expect_value(t, ui_tabs_cycle(2, 3, 1), 0)
	testing.expect_value(t, ui_tabs_cycle(0, 3, -1), 2)
	testing.expect_value(t, ui_tabs_cycle(1, 3, 1), 2)
	testing.expect_value(t, ui_tabs_cycle(0, 0, 1), 0)
	widths := []f32{50, 80, 60}
	testing.expect_value(t, ui_tabs_hit(widths, 10, 10), 0)
	testing.expect_value(t, ui_tabs_hit(widths, 10, 59), 0)
	testing.expect_value(t, ui_tabs_hit(widths, 10, 60), 1)
	testing.expect_value(t, ui_tabs_hit(widths, 10, 199), 2)
	testing.expect_value(t, ui_tabs_hit(widths, 10, 200), -1)
	testing.expect_value(t, ui_tabs_hit(widths, 10, 5), -1)
}

@(test)
test_split_divider :: proc(t: ^testing.T) {
	TOTAL :: f32(1000)
	avail := TOTAL - UI_SPLIT_W
	// follows the mouse
	r := ui_split_ratio_from_mouse(TOTAL, 0, 300 + UI_SPLIT_W * 0.5, 100, 100)
	testing.expect(t, abs(r * avail - 300) < 0.01)
	// clamps to the minimums on both sides
	r = ui_split_ratio_from_mouse(TOTAL, 0, 10, 100, 100)
	testing.expect(t, abs(r * avail - 100) < 0.01)
	r = ui_split_ratio_from_mouse(TOTAL, 0, 990, 100, 150)
	testing.expect(t, abs((1 - r) * avail - 150) < 0.01)
	// origin offset
	r = ui_split_ratio_from_mouse(TOTAL, 200, 200 + 500 + UI_SPLIT_W * 0.5, 100, 100)
	testing.expect(t, abs(r * avail - 500) < 0.01)
	// minimums don't fit → proportional
	r = ui_split_ratio_from_mouse(150, 0, 75, 100, 100)
	testing.expect_value(t, r, f32(0.5))

	a, b, div := ui_split_rects({0, 0, 1000, 400}, Ui_Split{ratio = 0.25})
	testing.expect(t, abs(a.width - avail * 0.25) < 0.01)
	testing.expect(t, abs(a.width + div.width + b.width - 1000) < 0.01)
	testing.expect_value(t, div.x, a.width)
	testing.expect_value(t, b.x, a.width + UI_SPLIT_W)

	a, b, div = ui_split_rects({0, 0, 300, 1000}, Ui_Split{vertical = true}) // ratio 0 → 0.5
	testing.expect_value(t, a.height, b.height)
	testing.expect_value(t, div.y, a.height)
}

@(test)
test_confirm :: proc(t: ^testing.T) {
	c: Ui_Confirm
	defer ui_confirm_destroy(&c)
	ui_confirm_open(&c, "Delete?", "temp message", confirm = "Delete", extra = "Archive")
	testing.expect(t, c.open)
	testing.expect_value(t, ui_confirm_key(&c, .Enter), Ui_Confirm_Result.Confirm)
	testing.expect_value(t, ui_confirm_key(&c, .Escape), Ui_Confirm_Result.Cancel)
	testing.expect_value(t, ui_confirm_key(&c, .Next), Ui_Confirm_Result.None)
	testing.expect_value(t, ui_confirm_key(&c, .Enter), Ui_Confirm_Result.Cancel)
	ui_confirm_key(&c, .Next)
	testing.expect_value(t, ui_confirm_key(&c, .Enter), Ui_Confirm_Result.Extra)
	ui_confirm_key(&c, .Next) // wraps
	testing.expect_value(t, ui_confirm_key(&c, .Enter), Ui_Confirm_Result.Confirm)
	ui_confirm_key(&c, .Prev)
	testing.expect_value(t, ui_confirm_key(&c, .Enter), Ui_Confirm_Result.Extra)

	// reopen without extra: only 2 buttons, message re-cloned (no leak)
	ui_confirm_open(&c, "Sure?", "other")
	_, n := ui_confirm_buttons(&c)
	testing.expect_value(t, n, 2)
	ui_confirm_key(&c, .Next)
	ui_confirm_key(&c, .Next)
	testing.expect_value(t, ui_confirm_key(&c, .Enter), Ui_Confirm_Result.Confirm)
}

@(test)
test_menu_place :: proc(t: ^testing.T) {
	x, y := ui_menu_place(100, 100, 200, 150, 1280, 720)
	testing.expect_value(t, x, f32(100)); testing.expect_value(t, y, f32(100))
	x, y = ui_menu_place(1200, 700, 200, 150, 1280, 720) // flips left and up
	testing.expect_value(t, x, f32(1000)); testing.expect_value(t, y, f32(550))
	x, y = ui_menu_place(50, 50, 200, 150, 120, 100) // bigger than the window
	testing.expect_value(t, x, f32(0)); testing.expect_value(t, y, f32(0))
}

@(test)
test_banner :: proc(t: ^testing.T) {
	b: Ui_Banner
	ui_banner_set(&b, "hello", .Warning, 3, 10)
	testing.expect(t, b.visible)
	testing.expect_value(t, ui_banner_text(&b), "hello")
	ui_banner_update(&b, 12.9)
	testing.expect(t, b.visible)
	ui_banner_update(&b, 13)
	testing.expect(t, !b.visible)

	ui_banner_set(&b, "sticky", .Error, 0, 10)
	ui_banner_update(&b, 1e9)
	testing.expect(t, b.visible)

	long: [UI_BANNER_MAX + 10]u8
	for &c in long { c = 'a' }
	long[UI_BANNER_MAX - 1] = 0xC3 // a 2-byte rune straddling the limit
	long[UI_BANNER_MAX]     = 0xA9
	ui_banner_set(&b, string(long[:]), .Info, 1, 0)
	testing.expect_value(t, b.len, UI_BANNER_MAX - 1)
}

@(test)
test_shortcut_match :: proc(t: ^testing.T) {
	s := Ui_Shortcut{key = .G, mods = {.Ctrl, .Shift}}
	testing.expect(t, ui_shortcut_matches(s, .G, {.Ctrl, .Shift}))
	testing.expect(t, !ui_shortcut_matches(s, .G, {.Ctrl}))
	testing.expect(t, !ui_shortcut_matches(s, .H, {.Ctrl, .Shift}))
	testing.expect(t, !ui_shortcut_matches({}, .KEY_NULL, {}))
}

@(test)
test_registry_order_independent :: proc(t: ^testing.T) {
	// The demo registered itself via @(init) before this test ran.
	found_demo := false
	for c in ui_registered_commands() {
		if c.name == "UI Kit: Demo" { found_demo = true }
	}
	testing.expect(t, found_demo, "@(init) command missing from the registry")
	testing.expect(t, ui_panel_find(UI_DEMO_ID) != nil)

	// Registration order doesn't matter: panels come out by (priority desc, id).
	ui_register_panel({id = "zz_test_b", priority = 10})
	ui_register_panel({id = "zz_test_a", priority = 10})
	ui_register_panel({id = "zz_test_c", priority = 20})
	ui_register_panel({id = "zz_test_a", priority = 10, title = "replaced"}) // same id → replace
	ui_register_command(Command{"zz test 2", "", nil, nil})
	ui_register_command(Command{"zz test 1", "", nil, nil})

	ids: [dynamic]string
	defer delete(ids)
	for p in ui_panels() {
		if len(p.id) > 8 && p.id[:8] == "zz_test_" { append(&ids, p.id) }
	}
	testing.expect_value(t, len(ids), 3)
	if len(ids) == 3 {
		testing.expect_value(t, ids[0], "zz_test_c")
		testing.expect_value(t, ids[1], "zz_test_a")
		testing.expect_value(t, ids[2], "zz_test_b")
	}
	testing.expect_value(t, ui_panel_find("zz_test_a").title, "replaced")

	cmds := ui_registered_commands()
	for i in 1 ..< len(cmds) { testing.expect(t, cmds[i-1].name <= cmds[i].name, "commands not sorted") }

	// open/close/toggle
	testing.expect(t, !ui_panel_is_open("zz_test_c"))
	ui_panel_toggle(nil, "zz_test_c")
	testing.expect(t, ui_panel_is_open("zz_test_c"))
	ui_panel_close(nil, "zz_test_c")
	testing.expect(t, !ui_panel_is_open("zz_test_c"))
	_ = rl.KeyboardKey.KEY_NULL
}
