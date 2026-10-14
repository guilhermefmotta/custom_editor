package editor

// Pure (no raylib) lane layout for the commit graph — see ADR 0006.
//
// Commits arrive in graph order (children before parents, `git log
// --date-order`), page by page. graph_layout_add assigns each commit a lane
// (column) and records the line segments to draw in its row. The open lanes
// (the hash each lane is waiting for) persist between calls, so feeding page
// 1 then page 2 yields exactly the same rows as feeding everything at once.
//
// Row geometry: every row is split at its middle (where the node sits).
//   .Pass  lane `from` at the row top → same lane at the row bottom
//   .In    lane `from` at the row top → the node (`to` = node column) at mid
//   .Out   the node (`from` = node column) at mid → lane `to` at the bottom
//
// Hash strings are borrowed: the caller keeps them alive while the layout
// uses them (the commit graph keeps every loaded page until reset).

import "core:strings"

GRAPH_COLORS :: 8

Graph_Seg_Kind :: enum u8 { Pass, In, Out }

Graph_Seg :: struct {
	from, to: i32,
	color:    u8,
	kind:     Graph_Seg_Kind,
}

Graph_Row :: struct {
	col:       i32,
	color:     u8,
	seg_start: i32,
	seg_count: i32,
	width:     i32, // lanes this row touches (max column + 1)
	merge:     bool, // more than one parent
}

Graph_Layout :: struct {
	lanes:      [dynamic]string, // hash expected next in each lane; "" = free
	colors:     [dynamic]u8,
	next_color: u8,
	rows:       [dynamic]Graph_Row,
	segs:       [dynamic]Graph_Seg,
}

graph_layout_reset :: proc(g: ^Graph_Layout) {
	clear(&g.lanes)
	clear(&g.colors)
	clear(&g.rows)
	clear(&g.segs)
	g.next_color = 0
}

graph_layout_destroy :: proc(g: ^Graph_Layout) {
	delete(g.lanes)
	delete(g.colors)
	delete(g.rows)
	delete(g.segs)
	g^ = {}
}

graph_row_segs :: proc(g: ^Graph_Layout, row: int) -> []Graph_Seg {
	r := g.rows[row]
	return g.segs[r.seg_start:][:r.seg_count]
}

@(private="file")
_graph_new_color :: proc(g: ^Graph_Layout) -> u8 {
	c := g.next_color
	g.next_color = (g.next_color + 1) % GRAPH_COLORS
	return c
}

@(private="file")
_graph_free_lane :: proc(g: ^Graph_Layout) -> int {
	for l, i in g.lanes { if l == "" { return i } }
	append(&g.lanes, "")
	append(&g.colors, 0)
	return len(g.lanes) - 1
}

// Appends the row of one commit. `parents` first-parent first.
graph_layout_add :: proc(g: ^Graph_Layout, hash: string, parents: []string) {
	col := -1
	for l, i in g.lanes {
		if l == hash { col = i; break }
	}
	if col < 0 {
		// New tip (no child seen): open a lane with a fresh color
		col = _graph_free_lane(g)
		g.colors[col] = _graph_new_color(g)
	}
	color := g.colors[col]

	row := Graph_Row{col = i32(col), color = color, seg_start = i32(len(g.segs)), merge = len(parents) > 1}
	width := col + 1

	// Upper half: lanes waiting for this commit converge on the node, every
	// other open lane passes straight through
	for l, i in g.lanes {
		if l == "" { continue }
		kind := Graph_Seg_Kind.In if l == hash else .Pass
		to   := col if kind == .In else i
		append(&g.segs, Graph_Seg{from = i32(i), to = i32(to), color = g.colors[i], kind = kind})
		width = max(width, i + 1)
	}
	for &l in g.lanes { if l == hash { l = "" } }

	// Lower half: first parent continues this lane; other parents join a lane
	// already waiting for them or open a new one
	if len(parents) > 0 {
		g.lanes[col] = parents[0]
		append(&g.segs, Graph_Seg{from = i32(col), to = i32(col), color = color, kind = .Out})
		for p in parents[1:] {
			k := -1
			for l, i in g.lanes { if l == p { k = i; break } }
			if k < 0 {
				k = _graph_free_lane(g)
				g.lanes[k]  = p
				g.colors[k] = _graph_new_color(g)
			}
			append(&g.segs, Graph_Seg{from = i32(col), to = i32(k), color = g.colors[k], kind = .Out})
			width = max(width, k + 1)
		}
	}

	// Drop trailing free lanes so the graph narrows again
	for len(g.lanes) > 0 && g.lanes[len(g.lanes) - 1] == "" {
		pop(&g.lanes)
		pop(&g.colors)
	}

	row.seg_count = i32(len(g.segs)) - row.seg_start
	row.width     = i32(width)
	append(&g.rows, row)
}

// ---------------------------------------------------------------------------
// Other pure helpers of the commit graph screen
// ---------------------------------------------------------------------------

// "just now", "5 minutes ago", "3 hours ago", "2 days ago", "4 months ago"...
// Temp-allocated.
cg_relative_time :: proc(now, t: i64) -> string {
	d := now - t
	if d < 0 { d = 0 }
	plural :: proc(n: i64, unit: string) -> string {
		if n == 1 { return strings.concatenate({"1 ", unit, " ago"}, context.temp_allocator) }
		buf: [32]u8
		return strings.concatenate({_cg_itoa(buf[:], n), " ", unit, "s ago"}, context.temp_allocator)
	}
	switch {
	case d < 60:            return "just now"
	case d < 3600:          return plural(d / 60, "minute")
	case d < 86400:         return plural(d / 3600, "hour")
	case d < 7 * 86400:     return plural(d / 86400, "day")
	case d < 30 * 86400:    return plural(d / (7 * 86400), "week")
	case d < 365 * 86400:   return plural(d / (30 * 86400), "month")
	}
	return plural(d / (365 * 86400), "year")
}

@(private="file")
_cg_itoa :: proc(buf: []u8, n: i64) -> string {
	n := n
	i := len(buf)
	if n == 0 { i -= 1; buf[i] = '0' }
	for n > 0 && i > 0 { i -= 1; buf[i] = u8('0' + n % 10); n /= 10 }
	return string(buf[i:])
}

// Does `s` look like a (possibly abbreviated) commit hash?
cg_looks_like_hash :: proc(s: string) -> bool {
	if len(s) < 4 || len(s) > 40 { return false }
	for c in transmute([]u8)s {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) { return false }
	}
	return true
}

// Rows to keep in reserve: when fewer than this remain below the viewport,
// the next page is requested.
CG_PREFETCH_ROWS :: 200

// Should the next page be requested? Pure so it can be tested.
cg_should_load_more :: proc(loaded, scroll, vis: int, has_more, pending: bool) -> bool {
	if !has_more || pending { return false }
	return scroll + vis + CG_PREFETCH_ROWS >= loaded
}
