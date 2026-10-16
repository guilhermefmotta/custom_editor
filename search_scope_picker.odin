package editor

// Scope picker of the search palette (ticket #12): Tab (or a click on the
// scope chip) swaps the result list for "Workspace (disk)" + local + remote
// branches; type to filter, Enter picks, Esc/Tab goes back. Choosing a scope
// re-runs the current query in it. palette.odin's .Search mode calls in here.

import "base:runtime"
import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

Scope_Entry :: struct {
	label:  string, // branch name or "Workspace (disk)"
	detail: string, // "local" / "remote" / "checked out" / "files on disk"
	scope:  Search_Scope, // strings borrowed from search_scope_branches
}

@(private="file")
_Picker :: struct {
	open:    bool,
	filter:  [dynamic]u8,
	sel_all: bool,
	sel:     int,
	scroll:  int,
	chip:    rl.Rectangle, // last drawn chip rect (mouse)
}
@(private="file") _pk: _Picker

@(fini)
_search_picker_fini :: proc "contextless" () {
	context = runtime.default_context()
	delete(_pk.filter)
}

// Pure: entries shown by the picker, filtered (case-insensitive substring).
// Order: workspace, local branches (checked-out first), remote branches.
search_scope_entries :: proc(branches: []Scope_Branch, filter: string, allocator := context.temp_allocator) -> [dynamic]Scope_Entry {
	out := make([dynamic]Scope_Entry, allocator)
	f := strings.to_lower(filter, context.temp_allocator)
	keep :: proc(name, f: string) -> bool {
		return f == "" || strings.contains(strings.to_lower(name, context.temp_allocator), f)
	}
	if keep("workspace (disk)", f) {
		append(&out, Scope_Entry{label = "Workspace (disk)", detail = "files on disk", scope = {kind = .Workspace}})
	}
	for pass in 0 ..< 3 {
		for b in branches {
			want := (pass == 0 && !b.is_remote && b.is_head) || (pass == 1 && !b.is_remote && !b.is_head) || (pass == 2 && b.is_remote)
			if !want || !keep(b.name, f) { continue }
			detail := "remote" if b.is_remote else ("checked out" if b.is_head else "local")
			append(&out, Scope_Entry{label = b.name, detail = detail, scope = {
				kind = .Branch, name = b.name, ref = b.ref, is_remote = b.is_remote, is_head = b.is_head,
			}})
		}
	}
	return out
}

// Short label of a scope for the chip / footer.
search_scope_label :: proc(sc: Search_Scope) -> string {
	if sc.kind == .Workspace { return "workspace" }
	return sc.name
}

search_scope_picker_is_open :: proc() -> bool { return _pk.open }

search_scope_picker_close :: proc() {
	_pk.open = false
}

search_scope_picker_count :: proc() -> int {
	return len(search_scope_entries(search_scope_branches[:], string(_pk.filter[:])))
}

@(private="file")
_picker_open :: proc(e: ^Editor) {
	_pk.open = true
	_pk.sel = 0
	_pk.scroll = 0
	clear(&_pk.filter)
	search_scope_refresh_branches(e)
}

// Called first by palette_handle_input in .Search mode. true = consumed.
search_scope_picker_input :: proc(p: ^Palette, e: ^Editor, max_vis: int) -> bool {
	clicked_chip := rl.IsMouseButtonPressed(.LEFT) && rl.CheckCollisionPointRec(rl.GetMousePosition(), _pk.chip)
	if !_pk.open {
		if (rl.IsKeyPressed(.TAB) && !ctrl()) || clicked_chip { _picker_open(e); return true }
		return false
	}
	if rl.IsKeyPressed(.ESCAPE) || rl.IsKeyPressed(.TAB) || clicked_chip { _pk.open = false; return true }
	entries := search_scope_entries(search_scope_branches[:], string(_pk.filter[:]))
	n := len(entries)
	if key_rep(.UP)   { if _pk.sel > 0 { _pk.sel -= 1 } }
	if key_rep(.DOWN) { if _pk.sel < n - 1 { _pk.sel += 1 } }
	if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) {
		if _pk.sel >= 0 && _pk.sel < n {
			search_set_scope(&p.search, entries[_pk.sel].scope, e.git_mgr.root)
			_pk.open = false
			clear(&p.search_expanded)
			p.selected = 0; p.scroll = 0
			q := string(p.query[:])
			if len(strings.trim_space(q)) > 0 { search_start(&p.search, q) } else { search_start(&p.search, "") }
		}
		return true
	}
	if text_input_handle(&_pk.filter, &_pk.sel_all) { _pk.sel = 0; _pk.scroll = 0 }
	_pk.sel = clamp(_pk.sel, 0, max(n - 1, 0))
	if _pk.sel < _pk.scroll { _pk.scroll = _pk.sel }
	if _pk.sel >= _pk.scroll + max_vis { _pk.scroll = _pk.sel - max_vis + 1 }
	return true
}

// Draws the scope chip right-aligned in the query box, ending at right_x.
search_scope_draw_chip :: proc(font: rl.Font, sc: Search_Scope, right_x, y, h: f32, accent, subdued, bg: rl.Color) {
	label := fmt.tprintf("in: %s  [Tab]", search_scope_label(sc))
	size  := FONT_SIZE - 3
	w := rl.MeasureTextEx(font, to_cstring(label), size, CHAR_SPACING).x + 16
	r := rl.Rectangle{right_x - w, y + (h - 24) * 0.5, w, 24}
	_pk.chip = r
	col := accent if sc.kind == .Branch else subdued
	rl.DrawRectangleRec(r, bg)
	rl.DrawRectangleLinesEx(r, 1, col)
	draw_text(font, to_cstring(label), {r.x + 8, r.y + (24 - size) * 0.5}, size, CHAR_SPACING, col)
}

// Draws the picker rows (filter line + entries) inside the palette list area.
search_scope_picker_draw :: proc(font: rl.Font, x, y, w, item_h: f32, max_vis: int, text, subdued, accent, sel_bg: rl.Color) {
	entries := search_scope_entries(search_scope_branches[:], string(_pk.filter[:]))
	size := FONT_SIZE - 2
	ch := rl.MeasureTextEx(font, "M", size, CHAR_SPACING).y
	for i := _pk.scroll; i < len(entries) && i - _pk.scroll < max_vis; i += 1 {
		en := entries[i]
		iy := y + f32(i - _pk.scroll) * item_h
		ty := iy + (item_h - ch) * 0.5
		if i == _pk.sel {
			rl.DrawRectangleV({x, iy}, {w, item_h}, sel_bg)
			rl.DrawRectangleV({x, iy}, {3, item_h}, accent)
		}
		col := accent if en.scope.kind == .Workspace else text
		dlg_text(font, en.label, x + 16, ty, size, CHAR_SPACING, col, x + w - 140, 0)
		dw := rl.MeasureTextEx(font, to_cstring(en.detail), size - 1, CHAR_SPACING).x
		draw_text(font, to_cstring(en.detail), {x + w - 16 - dw, ty + 1}, size - 1, CHAR_SPACING, subdued)
	}
}

search_scope_picker_filter :: proc() -> string { return string(_pk.filter[:]) }
