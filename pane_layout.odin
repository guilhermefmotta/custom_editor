package editor

// Window layout as a binary split tree, like Emacs windows: every split
// divides the active pane in two (Ctrl/Cmd+2 stacked, Ctrl/Cmd+3 side by
// side), so splits nest — 2 then 3 gives a pane on top and two side by side
// below. Closing a pane gives its space to its sibling; Ctrl/Cmd+1 keeps only
// the active pane.
//
// Pure and value-typed (a fixed array, no allocation): Repo/Editor views copy
// it freely, and the session stores it as text ("V(0.5,0,H(0.5,1,2))").
// Leaves hold pane indices into e.panes, always exactly 0..n-1.

import "core:fmt"
import "core:strconv"
import "core:strings"

LAYOUT_MAX_NODES :: 2 * MAX_PANES

Layout_Node :: struct {
	split: Split_Dir, // .None = leaf
	pane:  int,       // leaf: index into e.panes
	a, b:  int,       // split: children (a = left/top)
	ratio: f32,       // split: share of a
}

Pane_Layout :: struct {
	nodes: [LAYOUT_MAX_NODES]Layout_Node,
	n:     int, // nodes in use
	root:  int,
}

layout_single :: proc() -> (l: Pane_Layout) {
	l.nodes[0] = {split = .None, pane = 0}
	l.n = 1
	return
}

@(private="file")
_layout_new :: proc(l: ^Pane_Layout, node: Layout_Node) -> int {
	if l.n >= LAYOUT_MAX_NODES { _layout_compact(l) }
	l.nodes[l.n] = node
	l.n += 1
	return l.n - 1
}

@(private="file")
_layout_find_leaf :: proc(l: ^Pane_Layout, node, pane: int) -> (leaf, parent: int) {
	nd := l.nodes[node]
	if nd.split == .None { return (node if nd.pane == pane else -1), -1 }
	if f, p := _layout_find_leaf(l, nd.a, pane); f >= 0 { return f, (node if p < 0 else p) }
	if f, p := _layout_find_leaf(l, nd.b, pane); f >= 0 { return f, (node if p < 0 else p) }
	return -1, -1
}

// Splits the leaf showing `pane`: it keeps the left/top half, `new_pane`
// gets the other one.
layout_split :: proc(l: ^Pane_Layout, pane, new_pane: int, dir: Split_Dir) -> bool {
	if dir == .None { return false }
	if l.n + 2 > LAYOUT_MAX_NODES { _layout_compact(l) }
	if l.n + 2 > LAYOUT_MAX_NODES { return false }
	leaf, _ := _layout_find_leaf(l, l.root, pane)
	if leaf < 0 { return false }
	a := _layout_new(l, {split = .None, pane = pane})
	b := _layout_new(l, {split = .None, pane = new_pane})
	l.nodes[leaf] = {split = dir, a = a, b = b, ratio = 0.5}
	return true
}

// Removes the leaf of `pane` (its sibling takes the parent's place) and
// renumbers the panes after it, matching ordered_remove(&e.panes, pane).
layout_remove :: proc(l: ^Pane_Layout, pane: int) {
	leaf, parent := _layout_find_leaf(l, l.root, pane)
	if leaf < 0 { return }
	if parent < 0 { l^ = layout_single(); return } // last pane
	pn := l.nodes[parent]
	sibling := pn.b if pn.a == leaf else pn.a
	l.nodes[parent] = l.nodes[sibling]
	for i in 0 ..< l.n {
		if l.nodes[i].split == .None && l.nodes[i].pane > pane { l.nodes[i].pane -= 1 }
	}
	_layout_compact(l)
}

// Drops unreachable nodes (left behind by removals).
@(private="file")
_layout_compact :: proc(l: ^Pane_Layout) {
	out: Pane_Layout
	copy_node :: proc(src: ^Pane_Layout, dst: ^Pane_Layout, i: int) -> int {
		nd := src.nodes[i]
		at := dst.n
		dst.n += 1
		if nd.split != .None {
			nd.a = copy_node(src, dst, nd.a)
			nd.b = copy_node(src, dst, nd.b)
		}
		dst.nodes[at] = nd
		return at
	}
	out.root = copy_node(l, &out, l.root)
	l^ = out
}

// Rectangle of `pane` inside (x, y, w, h); dividers of `gap` between panes.
layout_rect :: proc(l: ^Pane_Layout, pane: int, x, y, w, h, gap: f32) -> (rx, ry, rw, rh: f32, ok: bool) {
	rect :: proc(l: ^Pane_Layout, node, pane: int, x, y, w, h, gap: f32) -> (f32, f32, f32, f32, bool) {
		nd := l.nodes[node]
		switch nd.split {
		case .None:
			return x, y, w, h, nd.pane == pane
		case .Vertical:
			mid := w * nd.ratio
			if a, b, c, d, ok := rect(l, nd.a, pane, x, y, mid - gap * 0.5, h, gap); ok { return a, b, c, d, true }
			return rect(l, nd.b, pane, x + mid + gap * 0.5, y, w - mid - gap * 0.5, h, gap)
		case .Horizontal:
			mid := h * nd.ratio
			if a, b, c, d, ok := rect(l, nd.a, pane, x, y, w, mid - gap * 0.5, gap); ok { return a, b, c, d, true }
			return rect(l, nd.b, pane, x, y + mid + gap * 0.5, w, h - mid - gap * 0.5, gap)
		}
		return 0, 0, 0, 0, false
	}
	return rect(l, l.root, pane, x, y, w, h, gap)
}

// Divider lines of the layout inside (x, y, w, h), for drawing.
layout_dividers :: proc(l: ^Pane_Layout, x, y, w, h: f32, out: ^[dynamic][4]f32) {
	walk :: proc(l: ^Pane_Layout, node: int, x, y, w, h: f32, out: ^[dynamic][4]f32) {
		nd := l.nodes[node]
		switch nd.split {
		case .None:
		case .Vertical:
			mid := w * nd.ratio
			append(out, [4]f32{x + mid, y, x + mid, y + h})
			walk(l, nd.a, x, y, mid, h, out)
			walk(l, nd.b, x + mid, y, w - mid, h, out)
		case .Horizontal:
			mid := h * nd.ratio
			append(out, [4]f32{x, y + mid, x + w, y + mid})
			walk(l, nd.a, x, y, w, mid, out)
			walk(l, nd.b, x, y + mid, w, h - mid, out)
		}
	}
	walk(l, l.root, x, y, w, h, out)
}

// Leaves (pane indices) of the tree.
layout_panes :: proc(l: ^Pane_Layout, out: ^[dynamic]int) {
	walk :: proc(l: ^Pane_Layout, node: int, out: ^[dynamic]int) {
		nd := l.nodes[node]
		if nd.split == .None { append(out, nd.pane); return }
		walk(l, nd.a, out)
		walk(l, nd.b, out)
	}
	walk(l, l.root, out)
}

// Is the tree a valid layout for `n` panes (leaves exactly 0..n-1)?
layout_valid :: proc(l: ^Pane_Layout, n: int) -> bool {
	if l.n <= 0 || l.root < 0 || l.root >= l.n { return false }
	seen := make([dynamic]int, context.temp_allocator)
	layout_panes(l, &seen)
	if len(seen) != n { return false }
	got := make([]bool, n, context.temp_allocator)
	for p in seen {
		if p < 0 || p >= n || got[p] { return false }
		got[p] = true
	}
	return true
}

// Layout for `n` panes from the old single-split fields (sessions written
// before the split tree): 2 panes split `dir`, more = side-by-side columns.
layout_from_legacy :: proc(n: int, dir: Split_Dir, ratio: f32) -> Pane_Layout {
	l := layout_single()
	if n < 2 { return l }
	d := dir if dir != .None else .Vertical
	for i in 1 ..< n {
		layout_split(&l, i - 1, i, d if n == 2 else .Vertical)
	}
	if n == 2 && ratio > 0.05 && ratio < 0.95 { l.nodes[l.root].ratio = ratio }
	return l
}

// Text form: leaf = pane index, split = "V(ratio,a,b)" / "H(ratio,a,b)".
layout_encode :: proc(l: ^Pane_Layout, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	walk :: proc(l: ^Pane_Layout, node: int, b: ^strings.Builder) {
		nd := l.nodes[node]
		if nd.split == .None { fmt.sbprintf(b, "%d", nd.pane); return }
		fmt.sbprintf(b, "%s(%.3f,", "V" if nd.split == .Vertical else "H", nd.ratio)
		walk(l, nd.a, b)
		strings.write_byte(b, ',')
		walk(l, nd.b, b)
		strings.write_byte(b, ')')
	}
	walk(l, l.root, &b)
	return strings.to_string(b)
}

layout_decode :: proc(s: string) -> (l: Pane_Layout, ok: bool) {
	src := s
	parse :: proc(l: ^Pane_Layout, s: ^string) -> (int, bool) {
		if l.n >= LAYOUT_MAX_NODES || len(s^) == 0 { return -1, false }
		c := s^[0]
		if c == 'V' || c == 'H' {
			if len(s^) < 2 || s^[1] != '(' { return -1, false }
			s^ = s^[2:]
			comma := strings.index_byte(s^, ',')
			if comma < 0 { return -1, false }
			ratio, rok := strconv.parse_f32(s^[:comma])
			if !rok || ratio <= 0.05 || ratio >= 0.95 { return -1, false }
			s^ = s^[comma + 1:]
			at := l.n
			l.n += 1
			a, aok := parse(l, s)
			if !aok || len(s^) == 0 || s^[0] != ',' { return -1, false }
			s^ = s^[1:]
			b, bok := parse(l, s)
			if !bok || len(s^) == 0 || s^[0] != ')' { return -1, false }
			s^ = s^[1:]
			l.nodes[at] = {split = .Vertical if c == 'V' else .Horizontal, a = a, b = b, ratio = ratio}
			return at, true
		}
		i := 0
		for i < len(s^) && s^[i] >= '0' && s^[i] <= '9' { i += 1 }
		if i == 0 { return -1, false }
		p, _ := strconv.parse_int(s^[:i])
		s^ = s^[i:]
		at := l.n
		l.n += 1
		l.nodes[at] = {split = .None, pane = p}
		return at, true
	}
	root, pok := parse(&l, &src)
	if !pok || len(src) != 0 { return {}, false }
	l.root = root
	return l, true
}
