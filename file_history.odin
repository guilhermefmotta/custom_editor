package editor

// ===========================================================================
// File history + blame screen (ticket #10) — panel id `file_history`.
//
// Two tabs over one file:
//   History — commits that touched the file (follows renames), newest first;
//             the selected commit shows the whole-file side-by-side diff
//             against its first parent.
//   Blame   — every line of the buffer (unsaved edits included) with commit,
//             author and relative date, a background color per commit and a
//             tooltip with the commit message. Lines not committed yet have
//             no author.
//
// Open it with:
//   - palette "Git: File History" (Ctrl/Cmd+Alt+Y) / "Git: Blame"
//     (Ctrl/Cmd+Alt+B) on the active pane's file;
//   - code (file tree, other screens): file_history_open(e, abs_path) /
//     file_blame_open(e, abs_path).
//
// All git work goes through the queue (file_history_git.odin).
// ===========================================================================

import "core:fmt"
import "core:strings"
import "core:time"
import git "./git"
import rl "vendor:raylib"

FILE_HISTORY_ID :: "file_history"

Fh_Tab :: enum u8 { History, Blame }

@(init)
_file_history_register :: proc "contextless" () {
	ui_register_panel(Ui_Panel{
		id       = FILE_HISTORY_ID,
		title    = "File History",
		priority = 60,
		layer    = .Overlay,
		draw     = _fh_draw,
		input    = _fh_input,
		update   = _fh_update,
		on_close = _fh_on_close,
	})
	ui_register_command(Command{"Git: File History", "Commits that changed the current file, with the diff of each", _fh_cmd_history, nil},
	                    shortcut = {key = .Y, mods = {.Ctrl, .Alt}})
	ui_register_command(Command{"Git: Blame", "Author, date and commit of every line of the current file", _fh_cmd_blame, nil},
	                    shortcut = {key = .B, mods = {.Ctrl, .Alt}})
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

// Opens the History tab for abs_path (e.g. from the file tree).
file_history_open :: proc(e: ^Editor, abs_path: string) { _fh_open(e, abs_path, .History) }

// Opens the Blame tab for abs_path.
file_blame_open :: proc(e: ^Editor, abs_path: string) { _fh_open(e, abs_path, .Blame) }

// What the panel currently shows (abs/rel path, tab). For tests/integration.
file_history_current :: proc() -> (abs_path, rel_path: string, tab: Fh_Tab) {
	return _fh.abs_path, _fh.rel_path, Fh_Tab(_fh.tab)
}

// Repo-relative path ("/" separators) of abs_path, or ok=false when it is not
// inside root. Pure.
fh_rel_path :: proc(root, abs_path: string, allocator := context.allocator) -> (rel: string, ok: bool) {
	if root == "" || abs_path == "" { return "", false }
	r, _ := strings.replace_all(root, "\\", "/", context.temp_allocator)
	a, _ := strings.replace_all(abs_path, "\\", "/", context.temp_allocator)
	r = strings.trim_right(r, "/")
	when ODIN_OS == .Windows {
		if len(a) <= len(r) || !strings.equal_fold(a[:len(r)], r) { return "", false }
	} else {
		if len(a) <= len(r) || a[:len(r)] != r { return "", false }
	}
	if a[len(r)] != '/' { return "", false }
	return strings.clone(a[len(r)+1:], allocator), true
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

@(private="file")
_Fh_State :: struct {
	tab:         int, // Fh_Tab
	abs_path:    string, // heap
	rel_path:    string, // heap
	hist_job:    git.Job_Id,
	blame_job:   git.Job_Id,
	diff_job:    git.Job_Id,
	diff_for:    int, // commit index diff_job was requested for (-1 none)
	diff_scroll: int,
	diff_change: int,
	diff_placed: bool, // scrolled to the first change once loaded
	diff_vis:    int,
	nav:         Ui_List_Nav, // commit list
	list_vis:    int,
	list_rect:   rl.Rectangle,
	diff_rect:   rl.Rectangle,
	blame_nav:   Ui_List_Nav,
	blame_vis:   int,
	blame_rect:  rl.Rectangle,
	blame_slots: []int, // heap, color slot per blame line
	pending_hash: string, // heap: select this commit once the history arrives
	split:       Ui_Split,
}

@(private="file") _fh := _Fh_State{diff_for = -1, split = {ratio = 0.32, min_a = 220, min_b = 300}}

@(private="file")
_fh_reset :: proc() {
	q := &_fh_editor_queue
	if q^ != nil {
		if _fh.hist_job  != 0 { git.git_release(q^, _fh.hist_job) }
		if _fh.blame_job != 0 { git.git_release(q^, _fh.blame_job) }
		if _fh.diff_job  != 0 { git.git_release(q^, _fh.diff_job) }
	}
	delete(_fh.abs_path)
	delete(_fh.rel_path)
	delete(_fh.blame_slots)
	delete(_fh.pending_hash)
	split := _fh.split
	_fh = _Fh_State{diff_for = -1, split = split}
}

// Queue the current jobs belong to (released on close/reopen).
@(private="file") _fh_editor_queue: ^git.Git_Queue

@(private="file")
_fh_open :: proc(e: ^Editor, abs_path: string, tab: Fh_Tab) {
	if e.git_mgr.root == "" { e.msg = "No git repository found"; return }
	if abs_path == "" { e.msg = "No file open"; return }
	rel, ok := fh_rel_path(e.git_mgr.root, abs_path)
	if !ok { e.msg = "File is not inside the repository"; return }

	_fh_reset()
	_fh_editor_queue = &e.git_mgr.queue
	_fh.abs_path = strings.clone(abs_path)
	_fh.rel_path = rel
	_fh.tab      = int(tab)

	content, has := _fh_buffer_text(e, abs_path)
	_fh.hist_job  = fh_request_history(&e.git_mgr.queue, rel)
	_fh.blame_job = fh_request_blame(&e.git_mgr.queue, rel, content, has)
	ui_panel_open(e, FILE_HISTORY_ID)
}

// Text of the open buffer for abs_path (temp-allocated), if any pane shows it.
@(private="file")
_fh_buffer_text :: proc(e: ^Editor, abs_path: string) -> (string, bool) {
	for &p in e.panes {
		if p.filename == abs_path { return buffer_to_string(&p.buf, context.temp_allocator), true }
	}
	return "", false
}

@(private="file")
_fh_on_close :: proc(e: ^Editor) { _fh_reset() }

@(private="file")
_fh_cmd_history :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	file_history_open(e, active_pane(e).filename)
}

@(private="file")
_fh_cmd_blame :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	file_blame_open(e, active_pane(e).filename)
}

// ---------------------------------------------------------------------------
// Results
// ---------------------------------------------------------------------------

@(private="file")
_fh_custom :: proc(id: git.Job_Id, $T: typeid) -> (v: ^T, st: git.Job_Status, err: string) {
	if _fh_editor_queue == nil || id == 0 { return nil, .Unknown, "" }
	c: ^git.Git_Custom
	c, st, err = git.git_poll_as(_fh_editor_queue, id, git.Git_Custom)
	if c != nil { v = git.git_custom_as(c^, T) }
	return
}

@(private="file")
_fh_history :: proc() -> []Fh_Commit {
	h, _, _ := _fh_custom(_fh.hist_job, Fh_History)
	return h.commits if h != nil else nil
}

@(private="file")
_fh_blame :: proc() -> ^Fh_Blame {
	b, _, _ := _fh_custom(_fh.blame_job, Fh_Blame)
	return b
}

@(private="file")
_fh_diff :: proc() -> (^git.File_Diff, git.Job_Status) {
	if _fh_editor_queue == nil || _fh.diff_job == 0 { return nil, .Unknown }
	d, st, _ := git.git_poll_as(_fh_editor_queue, _fh.diff_job, git.File_Diff)
	return d, st
}

// Every frame: request the diff of the selected commit, place it, compute
// the blame colors.
@(private="file")
_fh_update :: proc(e: ^Editor, dt: f32) {
	if !ui_panel_is_open(FILE_HISTORY_ID) || _fh_editor_queue == nil { return }
	commits := _fh_history()

	if _fh.pending_hash != "" && commits != nil {
		for c, i in commits {
			if c.hash == _fh.pending_hash { ui_list_set(&_fh.nav, i, len(commits), max(1, _fh.list_vis)); break }
		}
		delete(_fh.pending_hash); _fh.pending_hash = ""
	}

	if len(commits) > 0 {
		sel := clamp(_fh.nav.selected, 0, len(commits) - 1)
		if sel != _fh.diff_for {
			if _fh.diff_job != 0 { git.git_release(_fh_editor_queue, _fh.diff_job) }
			c := commits[sel]
			_fh.diff_job    = git.git_request_commit_file_diff(_fh_editor_queue, c.hash, c.path, c.old_path)
			_fh.diff_for    = sel
			_fh.diff_scroll = 0
			_fh.diff_change = 0
			_fh.diff_placed = false
		}
	}
	if !_fh.diff_placed {
		if d, st := _fh_diff(); st == .Done && d != nil {
			if len(d.changed) > 0 { _fh.diff_scroll = max(0, d.changed[0] - GITD_DIFF_LEAD) }
			_fh.diff_placed = true
		}
	}

	if _fh.blame_slots == nil {
		if b := _fh_blame(); b != nil { _fh.blame_slots = fh_blame_color_slots(b.lines) }
	}
}

// ---------------------------------------------------------------------------
// Input (modal)
// ---------------------------------------------------------------------------

@(private="file")
_fh_input :: proc(e: ^Editor) -> bool {
	if rl.IsKeyPressed(.ESCAPE) { ui_panel_close(e, FILE_HISTORY_ID); return true }
	if ui_tabs_handle_input(&_fh.tab, len(Fh_Tab)) { return true }

	switch Fh_Tab(_fh.tab) {
	case .History:
		commits := _fh_history()
		d, _ := _fh_diff()
		if d != nil && len(d.changed) > 0 {
			if !ctrl() && rl.IsKeyPressed(.N) { _fh_diff_goto(d, _fh.diff_change + 1); return true }
			if !ctrl() && rl.IsKeyPressed(.P) { _fh_diff_goto(d, _fh.diff_change - 1); return true }
		}
		if d != nil && shift() {
			page := max(1, _fh.diff_vis - 2)
			if key_rep(.PAGE_DOWN) { _fh.diff_scroll += page; return true }
			if key_rep(.PAGE_UP)   { _fh.diff_scroll = max(0, _fh.diff_scroll - page); return true }
			if key_rep(.DOWN)      { _fh.diff_scroll += 1; return true }
			if key_rep(.UP)        { _fh.diff_scroll = max(0, _fh.diff_scroll - 1); return true }
		}
		if !ctrl() && rl.IsKeyPressed(.B) { _fh.tab = int(Fh_Tab.Blame); return true }
		ui_list_handle_nav(&_fh.nav, len(commits), max(1, _fh.list_vis), _fh.list_rect)
	case .Blame:
		b := _fh_blame()
		n := len(b.lines) if b != nil else 0
		if !ctrl() && rl.IsKeyPressed(.H) { _fh.tab = int(Fh_Tab.History); return true }
		if (rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER)) && b != nil && _fh.blame_nav.selected < n {
			_fh_show_commit(b.lines[_fh.blame_nav.selected])
			return true
		}
		ui_list_handle_nav(&_fh.blame_nav, n, max(1, _fh.blame_vis), _fh.blame_rect)
	}
	return true
}

// Blame → History: select the commit that last changed this line.
@(private="file")
_fh_show_commit :: proc(l: Fh_Blame_Line) {
	if !l.committed { ui_banner_show("Line not committed yet"); return }
	_fh.tab = int(Fh_Tab.History)
	delete(_fh.pending_hash)
	_fh.pending_hash = strings.clone(l.hash)
}

@(private="file")
_fh_diff_goto :: proc(d: ^git.File_Diff, i: int) {
	n := len(d.changed)
	if n == 0 { return }
	_fh.diff_change = (i % n + n) % n
	_fh.diff_scroll = max(0, d.changed[_fh.diff_change] - GITD_DIFF_LEAD)
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

@(private="file") _FH_TABS := []string{"History", "Blame"}

// Commit colors for blame (Catppuccin: blue, mauve, green, yellow, pink,
// teal, peach, sky) — drawn translucent as row backgrounds.
@(private="file") _FH_SLOT_COLORS := [FH_BLAME_COLORS]rl.Color{
	{137, 180, 250, 255}, {203, 166, 247, 255}, {166, 227, 161, 255}, {249, 226, 175, 255},
	{245, 194, 231, 255}, {148, 226, 213, 255}, {250, 179, 135, 255}, {137, 220, 235, 255},
}

@(private="file")
_fh_draw :: proc(e: ^Editor, font: rl.Font, sw, sh: f32) {
	HDR :: f32(34)
	TAB :: f32(30)
	FTR :: f32(26)
	pw := sw - 40
	ph := sh - 40
	rl.DrawRectangle(0, 0, i32(sw), i32(sh), {0, 0, 0, 150})
	px, py := dlg_begin((sw - pw) * 0.5, (sh - ph) * 0.5, pw, ph, GITD_BG, GITD_BORDER)

	rl.DrawRectangleRec({px, py, pw, HDR}, GITD_HEADER)
	title := fmt.tprintf("%s  %s", "File History" if _fh.tab == int(Fh_Tab.History) else "Blame", _fh.rel_path)
	ui_text(font, title, px + 12, py, HDR, FONT_SIZE, GITD_BLUE, px + pw - 200)
	info := ""
	if commits := _fh_history(); commits != nil {
		info = fmt.tprintf("%d commit%s", len(commits), "" if len(commits) == 1 else "s")
	}
	if b := _fh_blame(); b != nil && _fh.tab == int(Fh_Tab.Blame) {
		info = fmt.tprintf("%d lines%s", len(b.lines), "" if b.tracked else "  (not tracked by git)")
	}
	iw := ui_text_w(font, info, FONT_SIZE - 3)
	ui_text(font, info, px + pw - iw - 14, py, HDR, FONT_SIZE - 3, GITD_SUBDUED, px + pw)

	ui_tabs(font, {px, py + HDR, pw, TAB}, _FH_TABS, &_fh.tab)

	body := rl.Rectangle{px + 1, py + HDR + TAB, pw - 2, ph - HDR - TAB - FTR}
	tooltip: Fh_Blame_Line
	switch Fh_Tab(_fh.tab) {
	case .History: _fh_draw_history(font, body)
	case .Blame:   tooltip = _fh_draw_blame(font, body)
	}

	fy := py + ph - FTR
	rl.DrawRectangleRec({px, fy, pw, FTR}, GITD_HEADER)
	hint := "↑↓ commit  Shift+↑↓/PgUp/PgDn scroll diff  n/p next/prev change  B blame  Ctrl+Tab tabs  Esc close"
	if _fh.tab == int(Fh_Tab.Blame) { hint = "↑↓ PgUp/PgDn line  Enter show commit in history  hover for message  H history  Ctrl+Tab tabs  Esc close" }
	ui_text(font, hint, px + 10, fy, FTR, FONT_SIZE - 4, GITD_SUBDUED, px + pw)
	dlg_end()

	if tooltip.committed { _fh_draw_tooltip(font, tooltip, sw, sh) }
}

@(private="file")
_fh_status_msg :: proc(font: rl.Font, r: rl.Rectangle, st: git.Job_Status, err: string, empty: string) -> bool {
	msg := ""
	#partial switch st {
	case .Queued, .Running: msg = "Loading…"
	case .Failed:           msg = fmt.tprintf("git failed: %s", err)
	case .Unknown:          msg = empty
	}
	if msg == "" { return false }
	ui_text(font, msg, r.x + 16, r.y + 8, UI_ROW_H, FONT_SIZE - 1, GITD_SUBDUED, r.x + r.width)
	return true
}

@(private="file")
_fh_draw_history :: proc(font: rl.Font, body: rl.Rectangle) {
	a, b := ui_split(&_fh.split, body)
	_fh.list_rect = a
	_fh.diff_rect = b

	h, st, err := _fh_custom(_fh.hist_job, Fh_History)
	if h == nil {
		_fh_status_msg(font, a, st, err, "")
		return
	}
	commits := h.commits
	if len(commits) == 0 {
		ui_text(font, "No history: the file is not in any commit", a.x + 12, a.y + 8, UI_ROW_H, FONT_SIZE - 1, GITD_SUBDUED, a.x + a.width)
		return
	}

	// Commit list: two lines per row (hash + subject / author + relative date)
	ROW :: f32(44)
	vis := max(1, int(a.height / ROW))
	_fh.list_vis = vis
	ui_list_clamp(&_fh.nav, len(commits), vis)
	now := time.to_unix_seconds(time.now())
	mp := rl.GetMousePosition()
	rl.BeginScissorMode(i32(a.x), i32(a.y), i32(a.width), i32(a.height))
	for vi in 0..<vis {
		i := _fh.nav.scroll + vi
		if i >= len(commits) { break }
		c := commits[i]
		y := a.y + f32(vi) * ROW
		row := rl.Rectangle{a.x, y, a.width, ROW}
		if i == _fh.nav.selected {
			rl.DrawRectangleRec(row, GITD_SEL)
			rl.DrawRectangleRec({a.x, y, 3, ROW}, GITD_BLUE)
		} else if ui_point_in(mp, row) {
			rl.DrawRectangleRec(row, ui_with_alpha(GITD_SEL, 120))
		}
		fs := FONT_SIZE - 2
		hw := ui_text_w(font, c.short_hash, fs) + 10
		ui_text(font, c.short_hash, a.x + 10, y + 2, ROW * 0.5, fs, GITD_BLUE, a.x + a.width)
		ui_text(font, c.subject, a.x + 10 + hw, y + 2, ROW * 0.5, fs, GITD_TEXT, a.x + a.width - 6)
		meta := fmt.tprintf("%s · %s", c.author, fh_relative_time(now, c.time))
		if c.status == 'R' && c.old_path != "" { meta = fmt.tprintf("%s · renamed from %s", meta, c.old_path) }
		ui_text(font, meta, a.x + 10, y + ROW * 0.5 - 2, ROW * 0.5, FONT_SIZE - 4, GITD_SUBDUED, a.x + a.width - 6)
		rl.DrawLineV({a.x, y + ROW - 1}, {a.x + a.width, y + ROW - 1}, ui_with_alpha(GITD_BORDER, 120))
		if ui_point_in(mp, row) && rl.IsMouseButtonPressed(.LEFT) { _fh.nav.selected = i }
	}
	if len(commits) > vis {
		th := a.height * f32(vis) / f32(len(commits))
		ty := a.y + a.height * f32(_fh.nav.scroll) / f32(len(commits))
		rl.DrawRectangleRec({a.x + a.width - 3, ty, 3, th}, GITD_BORDER)
	}
	rl.EndScissorMode()
	dlg_restore()

	_fh_draw_diff(font, b, commits)
}

@(private="file")
_fh_draw_diff :: proc(font: rl.Font, r: rl.Rectangle, commits: []Fh_Commit) {
	d, st := _fh_diff()
	if d == nil {
		_fh_status_msg(font, r, st, "", "Select a commit")
		return
	}
	fs  := FONT_SIZE - 2
	dy  := fs + 4
	cw  := ui_text_w(font, "0", fs)

	// Header: commit + path + change counter
	HH :: f32(24)
	rl.DrawRectangleRec({r.x, r.y, r.width, HH}, GITD_SECTION)
	path := ""
	if _fh.diff_for >= 0 && _fh.diff_for < len(commits) {
		c := commits[_fh.diff_for]
		path = c.path if c.old_path == "" else fmt.tprintf("%s → %s", c.old_path, c.path)
	}
	n_changes := len(d.changed)
	pos := fmt.tprintf("change %d/%d", _fh.diff_change + 1, n_changes) if n_changes > 0 else "no changes"
	ui_text(font, fmt.tprintf("%s   %s", path, pos), r.x + 8, r.y, HH, fs, GITD_TEXT, r.x + r.width)

	content := rl.Rectangle{r.x, r.y + HH, r.width, r.height - HH}
	rows := d.rows[:]
	vis := max(1, int(content.height / dy))
	_fh.diff_vis = vis
	if ui_point_in(rl.GetMousePosition(), content) {
		if w := rl.GetMouseWheelMove(); w != 0 { _fh.diff_scroll += w > 0 ? -3 : 3 }
	}
	_fh.diff_scroll = clamp(_fh.diff_scroll, 0, max(0, len(rows) - vis))

	if d.binary || len(rows) == 0 {
		msg := "Binary file — no text diff" if d.binary else "No changes to this file in this commit"
		ui_text(font, msg, content.x + 16, content.y + 8, UI_ROW_H, fs, GITD_SUBDUED, content.x + content.width)
		return
	}

	half   := (content.width - 9) * 0.5
	gutter := cw * f32(GITD_DIFF_GUTTER_CH) + 10
	col_x  := [2]f32{content.x, content.x + half + 3}
	rl.BeginScissorMode(i32(content.x), i32(content.y), i32(content.width), i32(content.height))
	rl.DrawRectangleV({content.x + half + 1, content.y}, {1, content.height}, GITD_BORDER)
	cy := content.y
	for i := _fh.diff_scroll; i < len(rows) && i < _fh.diff_scroll + vis; i += 1 {
		row := rows[i]
		sides := [2]git.Diff_Side{row.left, row.right}
		for side, c in sides {
			x := col_x[c]
			bg, mark: rl.Color
			switch side.kind {
			case .Context:
			case .Add:    bg = GITD_DIFF_ADD_BG;   mark = GITD_DIFF_MARK_ADD
			case .Delete: bg = GITD_DIFF_DEL_BG;   mark = GITD_DIFF_MARK_DEL
			case .Empty:  bg = GITD_DIFF_EMPTY_BG
			}
			if bg.a != 0   { rl.DrawRectangleV({x, cy}, {half, dy}, bg) }
			if mark.a != 0 { rl.DrawRectangleV({x, cy}, {3, dy}, mark) }
			if side.line > 0 {
				num := fmt.tprintf("%d", side.line)
				nw  := ui_text_w(font, num, fs)
				rl.DrawTextEx(font, to_cstring(num), {x + gutter - 8 - nw, cy + 2}, fs, CHAR_SPACING, GITD_SUBDUED)
			}
			if side.text != "" {
				dlg_text(font, _fh_expand_tabs(side.text), x + gutter, cy + 2, fs, CHAR_SPACING, GITD_TEXT, x + half, 6)
			}
		}
		cy += dy
	}
	// Scrollbar with change markers
	track_x := content.x + content.width - 6
	rl.DrawRectangleV({track_x, content.y}, {5, content.height}, GITD_HEADER)
	total := f32(len(rows))
	for start in d.changed {
		rr := rows[start]
		col := GITD_DIFF_MARK_DEL if rr.right.kind == .Empty else GITD_DIFF_MARK_ADD
		if rr.left.kind == .Delete && rr.right.kind == .Add { col = GITD_YELLOW }
		rl.DrawRectangleV({track_x, content.y + content.height * f32(start) / total}, {5, 2}, col)
	}
	bar_h := max(16, content.height * f32(vis) / total)
	bar_y := content.y + content.height * f32(_fh.diff_scroll) / total
	rl.DrawRectangleLinesEx({track_x - 1, bar_y, 7, bar_h}, 1, GITD_SUBDUED)
	rl.EndScissorMode()
	dlg_restore()
}

// Returns the line under the mouse (for the tooltip), zero value if none.
@(private="file")
_fh_draw_blame :: proc(font: rl.Font, r: rl.Rectangle) -> (hovered: Fh_Blame_Line) {
	_fh.blame_rect = r
	b, st, err := _fh_custom(_fh.blame_job, Fh_Blame)
	if b == nil {
		_fh_status_msg(font, r, st, err, "")
		return
	}
	lines := b.lines
	if len(lines) == 0 {
		ui_text(font, "Empty file", r.x + 16, r.y + 8, UI_ROW_H, FONT_SIZE - 1, GITD_SUBDUED, r.x + r.width)
		return
	}
	fs := FONT_SIZE - 2
	dy := fs + 5
	cw := ui_text_w(font, "0", fs)
	GUTTER_W :: f32(340)
	num_w := cw * f32(max(4, len(fmt.tprintf("%d", len(lines))))) + 16
	code_x := r.x + GUTTER_W + num_w + 8

	vis := max(1, int(r.height / dy))
	_fh.blame_vis = vis
	ui_list_clamp(&_fh.blame_nav, len(lines), vis)
	now := time.to_unix_seconds(time.now())
	mp  := rl.GetMousePosition()
	slots := _fh.blame_slots

	rl.BeginScissorMode(i32(r.x), i32(r.y), i32(r.width), i32(r.height))
	for vi in 0..<vis {
		i := _fh.blame_nav.scroll + vi
		if i >= len(lines) { break }
		l := lines[i]
		y := r.y + f32(vi) * dy
		row := rl.Rectangle{r.x, y, r.width, dy}
		hover := ui_point_in(mp, row)
		same_hover := hovered.committed && hovered.hash == l.hash

		// Gutter: color per commit; info on the first line of each block
		slot := slots[i] if i < len(slots) else -1
		if slot >= 0 { rl.DrawRectangleRec({r.x, y, GUTTER_W, dy}, ui_with_alpha(_FH_SLOT_COLORS[slot], 38)) }
		if slot >= 0 { rl.DrawRectangleRec({r.x, y, 3, dy}, ui_with_alpha(_FH_SLOT_COLORS[slot], 200)) }
		if i == _fh.blame_nav.selected {
			rl.DrawRectangleRec({r.x + GUTTER_W, y, r.width - GUTTER_W, dy}, GITD_SEL)
		} else if hover || same_hover {
			rl.DrawRectangleRec({r.x + GUTTER_W, y, r.width - GUTTER_W, dy}, ui_with_alpha(GITD_SEL, 110))
		}
		first := i == 0 || i == _fh.blame_nav.scroll || lines[i-1].hash != l.hash || lines[i-1].committed != l.committed
		if l.committed && first {
			x := r.x + 10
			ui_text(font, l.short_hash, x, y, dy, fs - 1, GITD_BLUE, r.x + GUTTER_W)
			x += ui_text_w(font, l.short_hash, fs - 1) + 10
			rel := fh_relative_time(now, l.time)
			rw := ui_text_w(font, rel, fs - 2)
			ui_text(font, l.author, x, y, dy, fs - 1, GITD_TEXT, r.x + GUTTER_W - rw - 14)
			ui_text(font, rel, r.x + GUTTER_W - rw - 8, y, dy, fs - 2, GITD_SUBDUED, r.x + GUTTER_W)
		}
		rl.DrawLineV({r.x + GUTTER_W, y}, {r.x + GUTTER_W, y + dy}, GITD_BORDER)

		num := fmt.tprintf("%d", i + 1)
		nw  := ui_text_w(font, num, fs)
		rl.DrawTextEx(font, to_cstring(num), {r.x + GUTTER_W + num_w - 8 - nw, y + 2}, fs, CHAR_SPACING, GITD_SUBDUED)
		if l.text != "" {
			dlg_text(font, _fh_expand_tabs(l.text), code_x, y + 2, fs, CHAR_SPACING, GITD_TEXT, r.x + r.width, 6)
		}
		if hover {
			hovered = l
			if rl.IsMouseButtonPressed(.LEFT) { _fh.blame_nav.selected = i }
		}
	}
	if len(lines) > vis {
		th := r.height * f32(vis) / f32(len(lines))
		ty := r.y + r.height * f32(_fh.blame_nav.scroll) / f32(len(lines))
		rl.DrawRectangleRec({r.x + r.width - 3, ty, 3, th}, GITD_BORDER)
	}
	rl.EndScissorMode()
	dlg_restore()
	return
}

@(private="file")
_fh_draw_tooltip :: proc(font: rl.Font, l: Fh_Blame_Line, sw, sh: f32) {
	fs := FONT_SIZE - 2
	t := time.unix(l.time, 0)
	y, mo, d := time.date(t)
	hh, mi, _ := time.clock(t)
	lines := [3]string{
		l.summary,
		fmt.tprintf("%s · %04d-%02d-%02d %02d:%02d", l.author, y, int(mo), d, hh, mi),
		l.hash,
	}
	w: f32 = 0
	for s in lines { w = max(w, ui_text_w(font, s, fs)) }
	w = min(w + 20, sw - 20)
	h := f32(len(lines)) * (fs + 6) + 10
	mp := rl.GetMousePosition()
	x := min(mp.x + 16, sw - w - 10)
	yy := mp.y + 18
	if yy + h > sh - 10 { yy = mp.y - h - 8 }
	rl.DrawRectangleRec({x, yy, w, h}, GITD_HEADER)
	rl.DrawRectangleLinesEx({x, yy, w, h}, 1, GITD_BORDER)
	cols := [3]rl.Color{GITD_TEXT, GITD_SUBDUED, GITD_BLUE}
	for s, i in lines {
		dlg_text(font, s, x + 10, yy + 6 + f32(i) * (fs + 6), fs, CHAR_SPACING, cols[i], x + w, 6)
	}
}

// Tabs as spaces for display (raylib draws \t as a missing glyph).
@(private="file")
_fh_expand_tabs :: proc(s: string) -> string {
	if strings.index_byte(s, '\t') < 0 { return s }
	b := strings.builder_make(context.temp_allocator)
	col := 0
	for r in s {
		if r == '\t' {
			for _ in 0..<(4 - col % 4) { strings.write_byte(&b, ' '); col += 1 }
		} else {
			strings.write_rune(&b, r); col += 1
		}
	}
	return strings.to_string(b)
}
