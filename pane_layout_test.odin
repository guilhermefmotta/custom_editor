package editor

import "core:testing"

@(test)
test_layout_splits_nest :: proc(t: ^testing.T) {
	l := layout_single()
	// Ctrl+2 on pane 0: 0 on top, 1 below; Ctrl+3 on pane 1: 1 | 2 below
	testing.expect(t, layout_split(&l, 0, 1, .Horizontal))
	testing.expect(t, layout_split(&l, 1, 2, .Vertical))
	testing.expect(t, layout_valid(&l, 3))
	testing.expect_value(t, layout_encode(&l), "H(0.500,0,V(0.500,1,2))")

	x, y, w, h, ok := layout_rect(&l, 0, 0, 0, 1000, 800, 0)
	testing.expect(t, ok)
	testing.expect_value(t, [4]f32{x, y, w, h}, [4]f32{0, 0, 1000, 400})
	x, y, w, h, ok = layout_rect(&l, 1, 0, 0, 1000, 800, 0)
	testing.expect_value(t, [4]f32{x, y, w, h}, [4]f32{0, 400, 500, 400})
	x, y, w, h, ok = layout_rect(&l, 2, 0, 0, 1000, 800, 0)
	testing.expect_value(t, [4]f32{x, y, w, h}, [4]f32{500, 400, 500, 400})

	// a 4th pane: split pane 0 side by side → 2x2 grid
	testing.expect(t, layout_split(&l, 0, 3, .Vertical))
	testing.expect(t, layout_valid(&l, 4))
	x, y, w, h, ok = layout_rect(&l, 3, 0, 0, 1000, 800, 0)
	testing.expect_value(t, [4]f32{x, y, w, h}, [4]f32{500, 0, 500, 400})

	lines := make([dynamic][4]f32, context.temp_allocator)
	layout_dividers(&l, 0, 0, 1000, 800, &lines)
	testing.expect_value(t, len(lines), 3)
}

@(test)
test_layout_remove_gives_space_to_sibling :: proc(t: ^testing.T) {
	l := layout_single()
	layout_split(&l, 0, 1, .Horizontal)
	layout_split(&l, 1, 2, .Vertical)
	// close pane 1 (bottom-left): pane 2 takes the whole bottom, renumbered to 1
	layout_remove(&l, 1)
	testing.expect(t, layout_valid(&l, 2))
	testing.expect_value(t, layout_encode(&l), "H(0.500,0,1)")
	// close the top one: single pane left
	layout_remove(&l, 0)
	testing.expect(t, layout_valid(&l, 1))
	testing.expect_value(t, layout_encode(&l), "0")

	// many splits/removals never run out of nodes
	l = layout_single()
	for round in 0 ..< 50 {
		for i in 1 ..< MAX_PANES { testing.expect(t, layout_split(&l, i - 1, i, .Vertical if round % 2 == 0 else .Horizontal)) }
		for i := MAX_PANES - 1; i >= 1; i -= 1 { layout_remove(&l, i) }
		testing.expect_value(t, layout_encode(&l), "0")
	}
}

@(test)
test_layout_encode_decode_and_legacy :: proc(t: ^testing.T) {
	src := "V(0.300,H(0.500,0,1),2)"
	l, ok := layout_decode(src)
	testing.expect(t, ok)
	testing.expect(t, layout_valid(&l, 3))
	testing.expect_value(t, layout_encode(&l), src)

	for bad in ([]string{"", "V(0.5,0)", "X(0.5,0,1)", "V(0.5,0,1", "V(2,0,1)", "0,1"}) {
		_, bok := layout_decode(bad)
		testing.expectf(t, !bok, "%q should not decode", bad)
	}
	dup, _ := layout_decode("V(0.500,0,0)")
	testing.expect(t, !layout_valid(&dup, 2))

	leg := layout_from_legacy(2, .Horizontal, 0.4)
	testing.expect_value(t, layout_encode(&leg), "H(0.400,0,1)")
	leg = layout_from_legacy(3, .Horizontal, 0.5)
	testing.expect(t, layout_valid(&leg, 3))
}

@(test)
test_editor_split_close_and_only :: proc(t: ^testing.T) {
	e: Editor
	e.panes = make([dynamic]Pane)
	append(&e.panes, pane_init())
	e.layout = layout_single()
	defer { for &p in e.panes { pane_destroy(&p) }; delete(e.panes) }

	editor_split(&e, .Horizontal) // Ctrl+2
	editor_split(&e, .Vertical)   // Ctrl+3 on the new (bottom) pane
	testing.expect_value(t, len(e.panes), 3)
	testing.expect_value(t, e.active, 2)
	testing.expect_value(t, layout_encode(&e.layout), "H(0.500,0,V(0.500,1,2))")

	e.active = 0
	editor_close_split(&e) // close the top pane
	testing.expect_value(t, len(e.panes), 2)
	testing.expect_value(t, layout_encode(&e.layout), "V(0.500,0,1)")

	editor_split(&e, .Horizontal)
	editor_close_other_panes(&e) // Ctrl+1
	testing.expect_value(t, len(e.panes), 1)
	testing.expect_value(t, e.active, 0)
	testing.expect_value(t, layout_encode(&e.layout), "0")
}
