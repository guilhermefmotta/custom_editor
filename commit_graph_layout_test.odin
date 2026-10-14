package editor

import "core:testing"

// Cenário: Cálculo das raias é lógica pura testada (features/commit-graph.feature)

@(private="file")
_C :: struct { hash: string, parents: []string }

@(private="file")
_layout :: proc(commits: []_C) -> Graph_Layout {
	g: Graph_Layout
	for c in commits { graph_layout_add(&g, c.hash, c.parents) }
	return g
}

@(private="file")
_has_seg :: proc(g: ^Graph_Layout, row: int, kind: Graph_Seg_Kind, from, to: i32) -> bool {
	for s in graph_row_segs(g, row) {
		if s.kind == kind && s.from == from && s.to == to { return true }
	}
	return false
}

// teste: test_graph_linear
@(test)
test_graph_linear :: proc(t: ^testing.T) {
	g := _layout({{"C", {"B"}}, {"B", {"A"}}, {"A", nil}})
	defer graph_layout_destroy(&g)
	testing.expect_value(t, len(g.rows), 3)
	for r in g.rows {
		testing.expect_value(t, r.col, 0)
		testing.expect_value(t, r.width, 1)
		testing.expect_value(t, r.color, g.rows[0].color)
	}
	testing.expect(t, _has_seg(&g, 0, .Out, 0, 0))
	testing.expect_value(t, len(graph_row_segs(&g, 0)), 1) // tip: no incoming line
	testing.expect(t, _has_seg(&g, 1, .In, 0, 0))
	testing.expect(t, _has_seg(&g, 1, .Out, 0, 0))
	testing.expect(t, _has_seg(&g, 2, .In, 0, 0))
	testing.expect_value(t, len(graph_row_segs(&g, 2)), 1) // root: no outgoing line
	testing.expect_value(t, len(g.lanes), 0)
}

// teste: test_graph_branch_merge
@(test)
test_graph_branch_merge :: proc(t: ^testing.T) {
	//  M = merge(C, F); C and F both fork from B
	g := _layout({
		{"M", {"C", "F"}},
		{"F", {"B"}},
		{"C", {"B"}},
		{"B", {"A"}},
		{"A", nil},
	})
	defer graph_layout_destroy(&g)
	testing.expect(t, g.rows[0].merge)
	testing.expect_value(t, g.rows[0].col, 0)
	testing.expect(t, _has_seg(&g, 0, .Out, 0, 0))
	testing.expect(t, _has_seg(&g, 0, .Out, 0, 1))
	testing.expect_value(t, g.rows[0].width, 2)

	testing.expect_value(t, g.rows[1].col, 1) // F on the merged branch lane
	testing.expect(t, _has_seg(&g, 1, .Pass, 0, 0))
	testing.expect(t, g.rows[1].color != g.rows[0].color)

	testing.expect_value(t, g.rows[2].col, 0) // C back on main lane
	testing.expect(t, _has_seg(&g, 2, .Pass, 1, 1))

	testing.expect_value(t, g.rows[3].col, 0) // B: both lanes converge
	testing.expect(t, _has_seg(&g, 3, .In, 0, 0))
	testing.expect(t, _has_seg(&g, 3, .In, 1, 0))

	testing.expect_value(t, g.rows[4].col, 0)
	testing.expect_value(t, g.rows[4].width, 1)
	testing.expect_value(t, len(g.lanes), 0)
}

// teste: test_graph_parallel_branches
@(test)
test_graph_parallel_branches :: proc(t: ^testing.T) {
	g := _layout({
		{"X2", {"X1"}},
		{"Y2", {"Y1"}},
		{"X1", {"R"}},
		{"Y1", {"R"}},
		{"R", nil},
	})
	defer graph_layout_destroy(&g)
	testing.expect_value(t, g.rows[0].col, 0)
	testing.expect_value(t, g.rows[1].col, 1)
	testing.expect(t, g.rows[0].color != g.rows[1].color)
	testing.expect_value(t, g.rows[2].col, 0)
	testing.expect_value(t, g.rows[2].color, g.rows[0].color)
	testing.expect(t, _has_seg(&g, 2, .Pass, 1, 1))
	testing.expect_value(t, g.rows[3].col, 1)
	testing.expect_value(t, g.rows[3].color, g.rows[1].color)
	testing.expect(t, _has_seg(&g, 3, .Pass, 0, 0))
	testing.expect_value(t, g.rows[4].col, 0)
	testing.expect(t, _has_seg(&g, 4, .In, 0, 0))
	testing.expect(t, _has_seg(&g, 4, .In, 1, 0))
}

// teste: test_graph_octopus
@(test)
test_graph_octopus :: proc(t: ^testing.T) {
	g := _layout({
		{"O", {"A", "B", "C"}},
		{"C", {"R"}},
		{"B", {"R"}},
		{"A", {"R"}},
		{"R", nil},
	})
	defer graph_layout_destroy(&g)
	testing.expect(t, g.rows[0].merge)
	testing.expect_value(t, g.rows[0].width, 3)
	testing.expect(t, _has_seg(&g, 0, .Out, 0, 0))
	testing.expect(t, _has_seg(&g, 0, .Out, 0, 1))
	testing.expect(t, _has_seg(&g, 0, .Out, 0, 2))
	testing.expect_value(t, g.rows[1].col, 2)
	testing.expect_value(t, g.rows[2].col, 1)
	testing.expect_value(t, g.rows[3].col, 0)
	// three lanes collapse into R
	testing.expect(t, _has_seg(&g, 4, .In, 0, 0))
	testing.expect(t, _has_seg(&g, 4, .In, 1, 0))
	testing.expect(t, _has_seg(&g, 4, .In, 2, 0))
	// colors of the three parent lanes are all different
	c0 := g.rows[3].color; c1 := g.rows[2].color; c2 := g.rows[1].color
	testing.expect(t, c0 != c1 && c1 != c2 && c0 != c2)
}

// teste: test_graph_multiple_roots
@(test)
test_graph_multiple_roots :: proc(t: ^testing.T) {
	// Two unrelated histories (e.g. gh-pages), then a merge joining them
	g := _layout({
		{"M", {"A2", "P2"}},
		{"P2", {"P1"}},
		{"A2", {"A1"}},
		{"P1", nil}, // root 1
		{"A1", nil}, // root 2
		{"Z", nil},  // a later lone root reuses lane 0
	})
	defer graph_layout_destroy(&g)
	testing.expect_value(t, g.rows[3].col, 1)
	testing.expect_value(t, len(graph_row_segs(&g, 3)), 2) // In + Pass of lane 0, no Out
	testing.expect_value(t, g.rows[4].col, 0)
	testing.expect_value(t, g.rows[4].width, 1)
	testing.expect_value(t, len(g.lanes), 0)
	testing.expect_value(t, g.rows[5].col, 0)
	testing.expect_value(t, len(graph_row_segs(&g, 5)), 0)
}

// teste: test_graph_page_continuity
@(test)
test_graph_page_continuity :: proc(t: ^testing.T) {
	all := []_C{
		{"M", {"C", "F"}},
		{"F", {"E"}},
		{"C", {"B"}},
		// ---- page break: lanes C→B and F→E are open here
		{"E", {"B"}},
		{"B", {"A"}},
		{"A", nil},
	}
	whole := _layout(all)
	defer graph_layout_destroy(&whole)

	paged: Graph_Layout
	defer graph_layout_destroy(&paged)
	for c in all[:3] { graph_layout_add(&paged, c.hash, c.parents) }
	testing.expect_value(t, len(paged.lanes), 2) // state carried to the next page
	for c in all[3:] { graph_layout_add(&paged, c.hash, c.parents) }

	testing.expect_value(t, len(paged.rows), len(whole.rows))
	for i in 0..<len(whole.rows) {
		testing.expect_value(t, paged.rows[i], whole.rows[i])
	}
	testing.expect_value(t, len(paged.segs), len(whole.segs))
	for i in 0..<len(whole.segs) {
		testing.expect_value(t, paged.segs[i], whole.segs[i])
	}
	// E continues the lane F opened on the previous page
	testing.expect_value(t, whole.rows[3].col, 1)
	testing.expect_value(t, whole.rows[3].color, whole.rows[1].color)
}

// teste: test_cg_relative_time
@(test)
test_cg_relative_time :: proc(t: ^testing.T) {
	now := i64(1_700_000_000)
	testing.expect_value(t, cg_relative_time(now, now - 10), "just now")
	testing.expect_value(t, cg_relative_time(now, now - 60), "1 minute ago")
	testing.expect_value(t, cg_relative_time(now, now - 5 * 60), "5 minutes ago")
	testing.expect_value(t, cg_relative_time(now, now - 3 * 3600), "3 hours ago")
	testing.expect_value(t, cg_relative_time(now, now - 2 * 86400), "2 days ago")
	testing.expect_value(t, cg_relative_time(now, now - 14 * 86400), "2 weeks ago")
	testing.expect_value(t, cg_relative_time(now, now - 90 * 86400), "3 months ago")
	testing.expect_value(t, cg_relative_time(now, now - 800 * 86400), "2 years ago")
	testing.expect_value(t, cg_relative_time(now, now + 100), "just now") // clock skew
	free_all(context.temp_allocator)
}

@(test)
test_cg_helpers :: proc(t: ^testing.T) {
	testing.expect(t, cg_looks_like_hash("a1b2c3"))
	testing.expect(t, !cg_looks_like_hash("abc"))
	testing.expect(t, !cg_looks_like_hash("fix bug"))
	testing.expect(t, cg_should_load_more(500, 300, 40, true, false))
	testing.expect(t, !cg_should_load_more(500, 0, 40, true, false))
	testing.expect(t, !cg_should_load_more(500, 300, 40, false, false))
	testing.expect(t, !cg_should_load_more(500, 300, 40, true, true))
}
