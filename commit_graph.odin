package editor

// Commit graph screen (ticket #4) — panel id "commit_graph".
//
// Graph of every ref (or one branch) in colored lanes with branch/tag/HEAD
// badges, author and relative date; incremental paging through the git queue
// (pages are kept alive and fed to the pure lane layout of
// commit_graph_layout.odin, ADR 0006); search by message/author/hash; detail
// of the selected commit with its changed files and the whole-file diff of one
// file at a time (commit_detail.odin). Only visible rows are drawn.
//
// Public procs for other screens:
//   commit_graph_show_branch(e, branch)  open filtered by a branch ("" = all)
//   commit_graph_select(e, hash)         open and select a commit (loads pages
//                                        until it is found)
//   commit_graph_reload(e)               reload the history (after a git op)
//
// Right click on a row (or Menu / Shift+F10) opens the commit context menu of
// commit_ops.odin (ticket #9).

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:time"
import git "./git"
import rl "vendor:raylib"

CG_ID        :: "commit_graph"
CG_PAGE      :: 500
CG_LANE_W    :: f32(14)
CG_MAX_LANES :: 24  // lanes drawn; wider graphs are clipped
CG_SEARCH_DELAY :: f32(0.25)

CG_COLORS := [GRAPH_COLORS]rl.Color{
	{79, 142, 247, 255},  // blue
	{162, 89, 255, 255},  // purple
	{249, 115, 22, 255},  // orange
	{34, 197, 94, 255},   // green
	{236, 72, 153, 255},  // pink
	{6, 182, 212, 255},   // cyan
	{234, 179, 8, 255},   // yellow
	{239, 68, 68, 255},   // red
}

Cg_Focus :: enum u8 { Graph, Files }

@(private="file")
Commit_Graph :: struct {
	// History (graph mode): finished log pages are kept alive and borrowed
	pages:       [dynamic]git.Job_Id,
	rows:        [dynamic]^git.Commit,
	index:       map[string]int, // hash → row
	layout:      Graph_Layout,
	pending:     git.Job_Id,
	has_more:    bool,
	started:     bool,
	head:        string, // borrowed from a page
	err:         string, // owned
	graph_nav:   Ui_List_Nav,
	vis:         int,
	list_r:      rl.Rectangle, // last drawn list area (context menu anchor)
	row_h:       f32,

	branch:      string, // owned; "" = all refs

	// Search
	search:      [dynamic]u8,
	search_sel:  bool,
	search_t:    f32, // debounce countdown (> 0 = waiting)
	search_job:  git.Job_Id,
	search_res:  ^git.Commit_Search, // borrowed from search_job
	search_nav:  Ui_List_Nav,

	focus:       Cg_Focus,
	split:       Ui_Split,
	want_hash:   string, // owned: select once loaded (commit_graph_select)

	// Branch picker
	picker_open:  bool,
	picker:       Ui_List,
	picker_job:   git.Job_Id,
	picker_items: [dynamic]string, // owned
}

@(private="file") _cg: Commit_Graph = {split = {ratio = 0.6, min_a = 260, min_b = 260}}

@(init)
_commit_graph_register :: proc "contextless" () {
	ui_register_panel(Ui_Panel{
		id       = CG_ID,
		title    = "Commit Graph",
		priority = 60,
		layer    = .Overlay,
		draw     = _cg_draw,
		input    = _cg_input,
		update   = _cg_update,
		on_open  = _cg_on_open,
		on_close = _cg_on_close,
		command  = "Git: Commit Graph",
		command_desc = "History of every branch as a graph, with commit detail and diffs",
		shortcut = {key = .G, mods = {.Ctrl, .Alt}},
	})
}

@(fini)
_commit_graph_fini :: proc "contextless" () {
	context = runtime.default_context()
	// The git queue is gone by now (editor_destroy): only free our own memory
	delete(_cg.pages); delete(_cg.rows); delete(_cg.index)
	graph_layout_destroy(&_cg.layout)
	delete(_cg.err); delete(_cg.branch); delete(_cg.want_hash)
	delete(_cg.search)
	ui_list_destroy(&_cg.picker)
	for s in _cg.picker_items { delete(s) }
	delete(_cg.picker_items)
	commit_detail_fini()
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

// Opens the graph filtered by `branch` ("" = every ref).
commit_graph_show_branch :: proc(e: ^Editor, branch: string) {
	if !ui_panel_is_open(CG_ID) || branch != _cg.branch {
		_cg_reset(e)
		delete(_cg.branch)
		_cg.branch = strings.clone(branch)
	}
	_cg_clear_search(e)
	ui_panel_open(e, CG_ID)
}

// Opens the graph and selects `hash` (full or abbreviated), loading more
// pages until it shows up.
commit_graph_select :: proc(e: ^Editor, hash: string) {
	ui_panel_open(e, CG_ID)
	_cg_clear_search(e)
	_cg.focus = .Graph
	if !_cg_try_select(hash) {
		delete(_cg.want_hash)
		_cg.want_hash = strings.clone(hash)
	}
}

// Reloads the history keeping the branch filter (no-op when closed).
commit_graph_reload :: proc(e: ^Editor) {
	if !ui_panel_is_open(CG_ID) { return }
	keep := strings.clone(_cg.branch, context.temp_allocator)
	_cg_reset(e)
	delete(_cg.branch); _cg.branch = strings.clone(keep)
	if _cg_searching() { _cg.search_t = 0.001 }
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

@(private="file")
_cg_q :: proc(e: ^Editor) -> ^git.Git_Queue { return &e.git_mgr.queue }

@(private="file")
_cg_searching :: proc() -> bool { return len(_cg.search) > 0 }

@(private="file")
_cg_nav :: proc() -> ^Ui_List_Nav { return &_cg.search_nav if _cg_searching() else &_cg.graph_nav }

@(private="file")
_cg_count :: proc() -> int {
	if _cg_searching() {
		return len(_cg.search_res.commits) if _cg.search_res != nil else 0
	}
	return len(_cg.rows)
}

@(private="file")
_cg_commit :: proc(i: int) -> ^git.Commit {
	if i < 0 || i >= _cg_count() { return nil }
	if _cg_searching() { return &_cg.search_res.commits[i] }
	return _cg.rows[i]
}

cg_selected_commit :: proc() -> ^git.Commit { return _cg_commit(_cg_nav().selected) }

@(private="file")
_cg_reset :: proc(e: ^Editor) {
	q := _cg_q(e)
	for id in _cg.pages { git.git_release(q, id) }
	git.git_release(q, _cg.pending)
	clear(&_cg.pages); clear(&_cg.rows); clear(&_cg.index)
	graph_layout_reset(&_cg.layout)
	_cg.pending = 0; _cg.has_more = false; _cg.started = false; _cg.head = ""
	delete(_cg.err); _cg.err = ""
	_cg.graph_nav = {}
	commit_detail_reset(e)
}

@(private="file")
_cg_clear_search :: proc(e: ^Editor) {
	clear(&_cg.search)
	_cg.search_sel = false
	_cg.search_t = 0
	git.git_release(_cg_q(e), _cg.search_job)
	_cg.search_job = 0
	_cg.search_res = nil
	_cg.search_nav = {}
}

@(private="file")
_cg_on_open :: proc(e: ^Editor) {
	_cg.focus = .Graph
}

@(private="file")
_cg_on_close :: proc(e: ^Editor) {
	_cg_reset(e)
	_cg_clear_search(e)
	git.git_release(_cg_q(e), _cg.picker_job)
	_cg.picker_job = 0
	_cg.picker_open = false
	delete(_cg.want_hash); _cg.want_hash = ""
}

@(private="file")
_cg_request_page :: proc(e: ^Editor) {
	_cg.pending = git.git_request_log(_cg_q(e), {rev = _cg.branch, skip = len(_cg.rows), limit = CG_PAGE})
	_cg.started = true
}

@(private="file")
_cg_try_select :: proc(hash: string) -> bool {
	if hash == "" { return false }
	row, ok := _cg.index[hash]
	if !ok && len(hash) < 40 {
		for c, i in _cg.rows { if strings.has_prefix(c.hash, hash) { row = i; ok = true; break } }
	}
	if !ok { return false }
	ui_list_set(&_cg.graph_nav, row, len(_cg.rows), max(_cg.vis, 1))
	// center it
	_cg.graph_nav.scroll = clamp(row - max(_cg.vis, 1) / 2, 0, max(0, len(_cg.rows) - max(_cg.vis, 1)))
	return true
}

@(private="file")
_cg_update :: proc(e: ^Editor, dt: f32) {
	if !ui_panel_is_open(CG_ID) || e.git_mgr.root == "" { return }
	q := _cg_q(e)
	_cg_apply_pending_pick(e)

	if !_cg.started { _cg_request_page(e) }

	// Next history page
	if _cg.pending != 0 {
		page, st, err := git.git_poll_as(q, _cg.pending, git.Log_Page)
		#partial switch st {
		case .Done:
			append(&_cg.pages, _cg.pending)
			_cg.pending = 0
			if page.head != "" { _cg.head = page.head }
			for &c in page.commits {
				_cg.index[c.hash] = len(_cg.rows)
				append(&_cg.rows, &c)
				graph_layout_add(&_cg.layout, c.hash, c.parents)
			}
			_cg.has_more = page.has_more
		case .Failed:
			git.git_release(q, _cg.pending)
			_cg.pending = 0
			delete(_cg.err)
			_cg.err = strings.clone(err if err != "" else "git log failed")
			_cg.has_more = false
		case .Unknown:
			_cg.pending = 0
		}
	}

	if _cg.want_hash != "" {
		if _cg_try_select(_cg.want_hash) {
			delete(_cg.want_hash); _cg.want_hash = ""
		} else if !_cg.has_more && _cg.pending == 0 && _cg.started && len(_cg.pages) > 0 {
			ui_banner_show(fmt.tprintf("Commit %s not found in this history", _cg.want_hash), .Warning)
			delete(_cg.want_hash); _cg.want_hash = ""
		} else if _cg.has_more && _cg.pending == 0 {
			_cg_request_page(e)
		}
	}

	// Incremental paging: keep a reserve of rows below the viewport
	if !_cg_searching() && cg_should_load_more(len(_cg.rows), _cg.graph_nav.scroll, _cg.vis, _cg.has_more, _cg.pending != 0) {
		_cg_request_page(e)
	}

	// Search (debounced)
	if _cg.search_t > 0 {
		_cg.search_t -= dt
		if _cg.search_t <= 0 {
			git.git_release(q, _cg.search_job)
			_cg.search_res = nil
			_cg.search_job = 0
			if _cg_searching() {
				_cg.search_job = git.git_request_commit_search(q, string(_cg.search[:]), _cg.branch)
			}
		}
	}
	if _cg.search_job != 0 && _cg.search_res == nil {
		c, st, _ := git.git_poll_as(q, _cg.search_job, git.Git_Custom)
		if st == .Done {
			_cg.search_res = git.git_custom_as(c^, git.Commit_Search)
			_cg.search_nav = {}
		} else if st == .Failed || st == .Unknown {
			git.git_release(q, _cg.search_job)
			_cg.search_job = 0
		}
	}

	// Branch list for the picker
	if _cg.picker_job != 0 {
		bs, st, _ := git.git_poll_as(q, _cg.picker_job, []git.Branch)
		if st == .Done {
			for s in _cg.picker_items { delete(s) }
			clear(&_cg.picker_items)
			append(&_cg.picker_items, strings.clone("(all branches)"))
			for b in bs^ { append(&_cg.picker_items, strings.clone(b.name)) }
			ui_list_apply_filter(&_cg.picker, _cg.picker_items[:])
		}
		if st != .Queued && st != .Running {
			git.git_release(q, _cg.picker_job)
			_cg.picker_job = 0
		}
	}

	// Detail follows the selection
	if c := cg_selected_commit(); c != nil {
		commit_detail_request(c.hash)
	}
	commit_detail_update(e, dt)
}

// ---------------------------------------------------------------------------
// Input (modal: always consumes)
// ---------------------------------------------------------------------------

@(private="file")
_cg_input :: proc(e: ^Editor) -> bool {
	if commit_detail_diff_is_open() {
		commit_detail_diff_input(e)
		return true
	}
	if _cg.picker_open {
		#partial switch ui_list_handle_input(&_cg.picker, _cg.picker_items[:], 12) {
		case .Activate:
			i := ui_list_selected_item(&_cg.picker)
			if i >= 0 && i < len(_cg.picker_items) {
				commit_graph_show_branch(e, "" if i == 0 else _cg.picker_items[i])
			}
			_cg.picker_open = false
		case .Cancel:
			_cg.picker_open = false
		}
		return true
	}
	if ctrl() && rl.IsKeyPressed(.B) { _cg_open_picker(e); return true }
	if rl.IsKeyPressed(.F5) || (ctrl() && rl.IsKeyPressed(.R)) {
		commit_graph_reload(e)
		return true
	}
	if _cg.focus == .Graph && (rl.IsKeyPressed(.MENU) || (shift() && rl.IsKeyPressed(.F10))) {
		nav := _cg_nav()
		y := _cg.list_r.y + f32(nav.selected - nav.scroll + 1) * _cg.row_h
		commit_ops_open_menu(e, cg_selected_commit(), {_cg.list_r.x + 60, y})
		return true
	}
	if rl.IsKeyPressed(.TAB) {
		_cg.focus = .Files if _cg.focus == .Graph else .Graph
		return true
	}

	if _cg.focus == .Files {
		switch {
		case rl.IsKeyPressed(.ESCAPE), rl.IsKeyPressed(.LEFT):
			_cg.focus = .Graph
		case rl.IsKeyPressed(.ENTER), rl.IsKeyPressed(.KP_ENTER), rl.IsKeyPressed(.RIGHT):
			commit_detail_open_selected_file(e)
		case:
			commit_detail_files_nav()
		}
		return true
	}

	switch {
	case rl.IsKeyPressed(.ESCAPE):
		if _cg_searching() { _cg_clear_search(e) } else { ui_panel_close(e, CG_ID) }
	case rl.IsKeyPressed(.ENTER), rl.IsKeyPressed(.KP_ENTER), rl.IsKeyPressed(.RIGHT):
		if commit_detail_file_count() > 0 { _cg.focus = .Files }
	case:
		if ui_list_handle_nav(_cg_nav(), _cg_count(), max(_cg.vis, 1)) { break }
		if text_input_handle(&_cg.search, &_cg.search_sel) {
			if _cg_searching() {
				_cg.search_t = CG_SEARCH_DELAY
			} else {
				_cg_clear_search(e)
			}
		}
	}
	return true
}

@(private="file")
_cg_open_picker :: proc(e: ^Editor) {
	_cg.picker_open = true
	ui_list_set_filter(&_cg.picker, "", _cg.picker_items[:])
	git.git_release(_cg_q(e), _cg.picker_job)
	_cg.picker_job = git.git_request_branches(_cg_q(e))
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

@(private="file")
_cg_draw :: proc(e: ^Editor, font: rl.Font, sw, sh: f32) {
	HDR :: f32(38)
	FTR :: f32(26)
	rl.DrawRectangle(0, 0, i32(sw), i32(sh), {0, 0, 0, 140})
	pw := sw - 40
	ph := sh - 40
	px, py := dlg_begin(20, 20, pw, ph, GITD_BG, GITD_BORDER)
	defer dlg_end()

	if e.git_mgr.root == "" {
		ui_text(font, "No git repository open.  (Esc to close)", px + 16, py + 16, UI_ROW_H, FONT_SIZE, GITD_SUBDUED, px + pw)
		return
	}
	if commit_detail_diff_is_open() {
		commit_detail_draw_diff(e, font, {px, py, pw, ph})
		return
	}
	busy := _cg.picker_open || ui_panel_is_open("commit_ops")

	// Header: title, branch filter, search box, status
	rl.DrawRectangleRec({px, py, pw, HDR}, GITD_HEADER)
	ui_text(font, "Commit Graph", px + 12, py, HDR, FONT_SIZE, GITD_BLUE, px + pw)
	bx := px + 12 + ui_text_w(font, "Commit Graph", FONT_SIZE) + 18
	blabel := fmt.tprintf("Branch: %s  v", _cg.branch if _cg.branch != "" else "all")
	bw := ui_button_w(font, blabel)
	if ui_button(font, {bx, py + 5, bw, HDR - 10}, blabel, false, _cg.branch != "") && !busy { _cg_open_picker(e) }

	sx := bx + bw + 12
	sw_ := min(f32(360), pw * 0.35)
	sr := rl.Rectangle{sx, py + 5, sw_, HDR - 10}
	_cg_search_box(font, sr)

	status: string
	switch {
	case _cg.err != "":
		status = _cg.err
	case _cg_searching():
		if _cg.search_res == nil {
			status = "searching..."
		} else {
			status = fmt.tprintf("%d match%s%s", len(_cg.search_res.commits), "" if len(_cg.search_res.commits) == 1 else "es", " (first 500)" if _cg.search_res.truncated else "")
		}
	case:
		more := "+" if _cg.has_more else ""
		status = fmt.tprintf("%d%s commits%s", len(_cg.rows), more, "  loading..." if _cg.pending != 0 else "")
	}
	ui_text(font, status, sx + sw_ + 12, py, HDR, FONT_SIZE - 3, _cg.err != "" ? GITD_RED : GITD_SUBDUED, px + pw - 8)

	// Body
	body := rl.Rectangle{px, py + HDR, pw, ph - HDR - FTR}
	a, b := ui_split(&_cg.split, body, !busy)
	_cg_draw_list(e, font, a, !busy)
	commit_detail_draw(e, font, b, cg_selected_commit(), _cg.focus == .Files, !busy)

	// Footer
	fy := py + ph - FTR
	rl.DrawRectangleRec({px, fy, pw, FTR}, GITD_HEADER)
	hint := "type to search (message/author/hash)  Up/Dn PgUp/PgDn  Tab/Enter files  Ctrl+B branch  F5 refresh  Esc close"
	if _cg.focus == .Files { hint = "Files: Up/Dn select  Enter open diff  Tab/Esc back to graph" }
	ui_text(font, hint, px + 10, fy, FTR, FONT_SIZE - 4, GITD_SUBDUED, px + pw)

	if _cg.picker_open { _cg_draw_picker(font, sw, sh) }
}

@(private="file")
_cg_search_box :: proc(font: rl.Font, r: rl.Rectangle) {
	rl.DrawRectangleRec(r, GITD_BG)
	rl.DrawRectangleLinesEx(r, 1, _cg.focus == .Graph ? ACCENT_COL : GITD_BORDER)
	size := FONT_SIZE - 2
	ty := r.y + (r.height - size) * 0.5
	q := string(_cg.search[:])
	if q == "" {
		dlg_text(font, "Search message, author or hash...", r.x + 8, ty, size, CHAR_SPACING, GITD_SUBDUED, r.x + r.width, 8)
		return
	}
	tw := ui_text_w(font, q, size)
	if _cg.search_sel { rl.DrawRectangleRec({r.x + 6, ty - 2, tw + 4, size + 4}, ui_with_alpha(ACCENT_COL, 60)) }
	dlg_text(font, q, r.x + 8, ty, size, CHAR_SPACING, GITD_TEXT, r.x + r.width, 8)
	if _cg.focus == .Graph { rl.DrawRectangleV({r.x + 8 + min(tw, r.width - 16), ty}, {2, size}, ACCENT_COL) }
}

@(private="file") _cg_last_click_row: int = -1
@(private="file") _cg_last_click_t:   f64

@(private="file")
_cg_draw_list :: proc(e: ^Editor, font: rl.Font, r: rl.Rectangle, interactive: bool) {
	row_h := max(UI_ROW_H, FONT_SIZE + 8)
	nav   := _cg_nav()
	count := _cg_count()
	vis   := max(1, int(r.height / row_h))
	_cg.vis = vis
	_cg.list_r = r
	_cg.row_h = row_h
	ui_list_clamp(nav, count, vis)
	searching := _cg_searching()

	if count == 0 {
		msg := "loading..."
		switch {
		case _cg.err != "":                       msg = _cg.err
		case searching && _cg.search_res != nil:  msg = "(no matching commits)"
		case searching:                           msg = "searching..."
		case _cg.pending == 0 && _cg.started:     msg = "(no commits)"
		}
		ui_text(font, msg, r.x + 14, r.y + 8, row_h, FONT_SIZE - 1, GITD_SUBDUED, r.x + r.width)
		return
	}

	// Graph column width: widest visible row (compact), capped
	lanes := 1
	if !searching {
		for i in nav.scroll ..< min(count, nav.scroll + vis) { lanes = max(lanes, int(_cg.layout.rows[i].width)) }
	}
	lanes = min(lanes, CG_MAX_LANES)
	gx := r.x + 6
	gw := f32(lanes) * CG_LANE_W
	tx := gx + gw + 8

	now := time.time_to_unix(time.now())
	size := FONT_SIZE - 2
	DATE_W :: f32(110)
	HASH_W :: f32(72)
	AUTH_W :: f32(150)
	right := r.x + r.width - 8
	hash_x := right - HASH_W
	date_x := hash_x - DATE_W
	auth_x := date_x - AUTH_W
	compact := auth_x - tx < 200 // narrow pane: drop author/date columns
	text_right := hash_x - 8 if compact else auth_x - 10

	rl.BeginScissorMode(i32(r.x), i32(r.y), i32(r.width), i32(r.height))
	for vi in 0 ..< vis {
		i := nav.scroll + vi
		if i >= count { break }
		c := _cg_commit(i)
		y := r.y + f32(vi) * row_h
		if i == nav.selected {
			rl.DrawRectangleRec({r.x, y, r.width, row_h}, _cg.focus == .Graph ? SEL_BG : GITD_SEL)
			rl.DrawRectangleRec({r.x, y, 3, row_h}, ACCENT_COL)
		}

		// Lanes + node
		node_col := rl.Color(GITD_BLUE)
		if searching {
			cx := gx + CG_LANE_W * 0.5
			rl.DrawCircleV({cx, y + row_h * 0.5}, 4.5, GITD_BLUE)
		} else {
			grow := _cg.layout.rows[i]
			node_col = CG_COLORS[grow.color]
			_cg_draw_lanes(gx, y, row_h, grow, graph_row_segs(&_cg.layout, i), c.hash == _cg.head)
		}

		// Badges, subject
		x := tx
		for ref in c.refs {
			if x > text_right - 60 { break }
			x += _cg_badge(font, ref, x, y, row_h, node_col, text_right) + 4
		}
		ui_text(font, c.subject, x + 2, y, row_h, size, GITD_TEXT, text_right)

		if !compact {
			ui_text(font, c.author_name, auth_x, y, row_h, size, GITD_SUBDUED, date_x - 8)
			ui_text(font, cg_relative_time(now, c.author_time), date_x, y, row_h, size, GITD_SUBDUED, hash_x - 8)
		}
		ui_text(font, c.short_hash, hash_x, y, row_h, size, GITD_ORANGE, right + 8)
	}
	if count > vis { // scrollbar
		th := max(12, r.height * f32(vis) / f32(count))
		ty := r.y + (r.height - th) * f32(nav.scroll) / f32(max(1, count - vis))
		rl.DrawRectangleRec({r.x + r.width - 4, ty, 4, th}, GITD_BORDER)
	}
	rl.EndScissorMode()
	dlg_restore()

	// Mouse
	mp := rl.GetMousePosition()
	if interactive && ui_point_in(mp, r) {
		if wheel := rl.GetMouseWheelMove(); wheel != 0 {
			ui_list_scroll_by(nav, wheel > 0 ? -3 : 3, count, vis)
		}
		if rl.IsMouseButtonPressed(.LEFT) {
			row := ui_list_row_at(nav^, r.y, row_h, mp.y, count, vis)
			if row >= 0 {
				nav.selected = row
				_cg.focus = .Graph
				now_t := rl.GetTime()
				if row == _cg_last_click_row && now_t - _cg_last_click_t < 0.35 && commit_detail_file_count() > 0 {
					_cg.focus = .Files
				}
				_cg_last_click_row = row
				_cg_last_click_t = now_t
			}
		}
		if rl.IsMouseButtonPressed(.RIGHT) {
			row := ui_list_row_at(nav^, r.y, row_h, mp.y, count, vis)
			if row >= 0 {
				nav.selected = row
				_cg.focus = .Graph
				commit_ops_open_menu(e, _cg_commit(row), mp)
			}
		}
	}
}

@(private="file")
_cg_draw_lanes :: proc(gx, y, h: f32, row: Graph_Row, segs: []Graph_Seg, is_head: bool) {
	lane_x :: proc(gx: f32, c: i32) -> f32 { return gx + CG_LANE_W * f32(c) + CG_LANE_W * 0.5 }
	top := y
	mid := y + h * 0.5
	bot := y + h
	T :: f32(2)
	for s in segs {
		if s.from >= CG_MAX_LANES && s.to >= CG_MAX_LANES { continue }
		col := CG_COLORS[s.color]
		switch s.kind {
		case .Pass:
			x := lane_x(gx, s.from)
			rl.DrawLineEx({x, top}, {x, bot}, T, col)
		case .In:
			a := rl.Vector2{lane_x(gx, s.from), top}
			b := rl.Vector2{lane_x(gx, s.to), mid}
			if a.x == b.x { rl.DrawLineEx(a, b, T, col) } else { rl.DrawLineBezier(a, b, T, col) }
		case .Out:
			a := rl.Vector2{lane_x(gx, s.from), mid}
			b := rl.Vector2{lane_x(gx, s.to), bot}
			if a.x == b.x { rl.DrawLineEx(a, b, T, col) } else { rl.DrawLineBezier(a, b, T, col) }
		}
	}
	if row.col >= CG_MAX_LANES { return }
	c := rl.Vector2{lane_x(gx, row.col), mid}
	ncol := CG_COLORS[row.color]
	if is_head { rl.DrawCircleV(c, 7, ACCENT_COL); rl.DrawCircleV(c, 5.5, GITD_BG) }
	rl.DrawCircleV(c, 4.5, ncol)
	if row.merge { rl.DrawCircleV(c, 2, GITD_BG) }
}

// Draws a ref badge; returns its width.
@(private="file")
_cg_badge :: proc(font: rl.Font, ref: git.Ref_Label, x, y, h: f32, lane_col: rl.Color, right: f32) -> f32 {
	size := FONT_SIZE - 4
	label := ref.name
	bg := lane_col
	fg := GITD_BG
	switch ref.kind {
	case .Branch:
		if ref.is_head { label = fmt.tprintf("HEAD -> %s", ref.name) }
	case .Remote_Branch:
		bg = GITD_SECTION; fg = GITD_TEXT
	case .Tag:
		bg = GITD_YELLOW; label = fmt.tprintf("tag %s", ref.name)
	case .Head:
		bg = GITD_ORANGE
	}
	w := min(ui_text_w(font, label, size) + 12, max(30, right - x))
	r := rl.Rectangle{x, y + 4, w, h - 8}
	rl.DrawRectangleRounded(r, 0.4, 4, bg)
	if ref.is_head { rl.DrawRectangleRoundedLinesEx(r, 0.4, 4, 1, GITD_TEXT) }
	dlg_text(font, label, x + 6, y + (h - size) * 0.5, size, CHAR_SPACING, fg, x + w, 4)
	return w
}

@(private="file")
_cg_draw_picker :: proc(font: rl.Font, sw, sh: f32) {
	W :: f32(420)
	ROWS :: 12
	H := f32(ROWS) * UI_ROW_H + 28 + 24
	x := (sw - W) * 0.5
	y := sh * 0.18
	rl.DrawRectangleRec({x - 1, y - 1, W + 2, H + 2}, GITD_BORDER)
	rl.DrawRectangleRec({x, y, W, H}, GITD_BG)
	ui_list_filter_draw(&_cg.picker, font, {x + 8, y + 8, W - 16, 28}, "Filter branches...")
	lr := rl.Rectangle{x + 8, y + 44, W - 16, f32(ROWS) * UI_ROW_H}
	if len(_cg.picker_items) == 0 {
		ui_text(font, "loading branches...", lr.x + 8, lr.y, UI_ROW_H, FONT_SIZE - 2, GITD_SUBDUED, lr.x + lr.width)
		return
	}
	_, dbl := ui_list_draw(&_cg.picker, font, lr, _cg_picker_items_slice())
	if dbl {
		i := ui_list_selected_item(&_cg.picker)
		_cg.picker_open = false
		if i >= 0 { _cg_pending_branch_pick = i }
	}
}

@(private="file") _cg_pending_branch_pick: int = -1

@(private="file")
_cg_picker_items_slice :: proc() -> []string { return _cg.picker_items[:] }

// Applied from the update hook (drawing has no ^Editor-safe place to reset).
@(private="file")
_cg_apply_pending_pick :: proc(e: ^Editor) {
	if _cg_pending_branch_pick < 0 { return }
	i := _cg_pending_branch_pick
	_cg_pending_branch_pick = -1
	if i < len(_cg.picker_items) {
		commit_graph_show_branch(e, "" if i == 0 else _cg.picker_items[i])
	}
}
