package editor

// Detail of the commit selected in the commit graph (ticket #4): message,
// author, date, hash, parents, refs and changed files; opening a file shows the
// whole-file side-by-side diff of that file in that commit. One file at a time
// (git_request_commit_file_diff), and only visible diff rows are drawn, so big
// commits don't freeze the editor (the Git Crab panel diffed every file at
// once).

import "core:fmt"
import "core:strings"
import "core:time"
import git "./git"
import rl "vendor:raylib"

CD_REQUEST_DELAY :: f32(0.08) // debounce while scrolling through commits
CD_DIFF_LEAD     :: 3

@(private="file")
Commit_Detail_View :: struct {
	want:  string, // owned: hash to show (latest selection)
	hash:  string, // owned: hash of `job`
	delay: f32,
	job:   git.Job_Id,
	d:     ^git.Commit_Detail, // borrowed from job
	err:   string,             // owned

	files:     Ui_List_Nav,
	files_vis: int,

	diff_open:   bool,
	diff_job:    git.Job_Id,
	diff:        ^git.File_Diff, // borrowed from diff_job
	diff_err:    string,         // owned
	diff_file:   int,
	diff_scroll: int,
	diff_change: int,
	diff_vis:    int,
	diff_jumped: bool, // scrolled to the first change after load
}

@(private="file") _cd: Commit_Detail_View

commit_detail_fini :: proc() {
	delete(_cd.want); delete(_cd.hash); delete(_cd.err); delete(_cd.diff_err)
	_cd = {}
}

// Releases every job and forgets the commit.
commit_detail_reset :: proc(e: ^Editor) {
	q := &e.git_mgr.queue
	git.git_release(q, _cd.job)
	git.git_release(q, _cd.diff_job)
	commit_detail_fini()
}

// Show `hash` (debounced; no-op when already shown or requested).
commit_detail_request :: proc(hash: string) {
	if hash == _cd.want { return }
	delete(_cd.want)
	_cd.want  = strings.clone(hash)
	_cd.delay = CD_REQUEST_DELAY
}

commit_detail_update :: proc(e: ^Editor, dt: f32) {
	q := &e.git_mgr.queue
	if _cd.want != "" && _cd.want != _cd.hash {
		_cd.delay -= dt
		if _cd.delay <= 0 {
			git.git_release(q, _cd.job)
			_cd.d = nil
			delete(_cd.err); _cd.err = ""
			delete(_cd.hash)
			_cd.hash  = strings.clone(_cd.want)
			_cd.job   = git.git_request_commit_detail(q, _cd.hash)
			_cd.files = {}
			_cd_close_diff(e)
		}
	}
	if _cd.job != 0 && _cd.d == nil && _cd.err == "" {
		d, st, err := git.git_poll_as(q, _cd.job, git.Commit_Detail)
		#partial switch st {
		case .Done: _cd.d = d
		case .Failed, .Unknown:
			_cd.err = strings.clone(err if err != "" else "could not load commit")
		}
	}
	if _cd.diff_job != 0 && _cd.diff == nil && _cd.diff_err == "" {
		fd, st, err := git.git_poll_as(q, _cd.diff_job, git.File_Diff)
		#partial switch st {
		case .Done:
			_cd.diff = fd
			if !_cd.diff_jumped && len(fd.changed) > 0 {
				_cd.diff_scroll = max(0, fd.changed[0] - CD_DIFF_LEAD)
				_cd.diff_jumped = true
			}
		case .Failed, .Unknown:
			_cd.diff_err = strings.clone(err if err != "" else "could not load diff")
		}
	}
}

commit_detail_file_count :: proc() -> int {
	if _cd.d == nil || _cd.hash != _cd.want { return 0 }
	return len(_cd.d.files)
}

commit_detail_files_nav :: proc() {
	ui_list_handle_nav(&_cd.files, commit_detail_file_count(), max(_cd.files_vis, 1))
}

commit_detail_open_selected_file :: proc(e: ^Editor) {
	_cd_open_file(e, _cd.files.selected)
}

commit_detail_diff_is_open :: proc() -> bool { return _cd.diff_open }

@(private="file")
_cd_open_file :: proc(e: ^Editor, i: int) {
	n := commit_detail_file_count()
	if i < 0 || i >= n { return }
	q := &e.git_mgr.queue
	_cd_close_diff(e)
	f := _cd.d.files[i]
	_cd.diff_file = i
	_cd.files.selected = i
	_cd.diff_open = true
	_cd.diff_job  = git.git_request_commit_file_diff(q, _cd.hash, f.path, f.old_path)
}

@(private="file")
_cd_close_diff :: proc(e: ^Editor) {
	git.git_release(&e.git_mgr.queue, _cd.diff_job)
	_cd.diff_job = 0
	_cd.diff = nil
	delete(_cd.diff_err); _cd.diff_err = ""
	_cd.diff_open = false
	_cd.diff_scroll = 0
	_cd.diff_change = 0
	_cd.diff_jumped = false
}

@(private="file")
_cd_diff_goto :: proc(i: int) {
	if _cd.diff == nil || len(_cd.diff.changed) == 0 { return }
	n := len(_cd.diff.changed)
	_cd.diff_change = ((i % n) + n) % n
	_cd.diff_scroll = max(0, _cd.diff.changed[_cd.diff_change] - CD_DIFF_LEAD)
}

commit_detail_diff_input :: proc(e: ^Editor) {
	rows := len(_cd.diff.rows) if _cd.diff != nil else 0
	vis  := max(_cd.diff_vis, 1)
	switch {
	case rl.IsKeyPressed(.ESCAPE):
		_cd_close_diff(e)
	case rl.IsKeyPressed(.N):                       _cd_diff_goto(_cd.diff_change + 1)
	case rl.IsKeyPressed(.P):                       _cd_diff_goto(_cd.diff_change - 1)
	case rl.IsKeyPressed(.RIGHT_BRACKET):           _cd_open_file(e, _cd.diff_file + 1)
	case rl.IsKeyPressed(.LEFT_BRACKET):            _cd_open_file(e, _cd.diff_file - 1)
	case key_rep(.DOWN):                            _cd.diff_scroll += 1
	case key_rep(.UP):                              _cd.diff_scroll -= 1
	case key_rep(.PAGE_DOWN):                       _cd.diff_scroll += vis
	case key_rep(.PAGE_UP):                         _cd.diff_scroll -= vis
	case rl.IsKeyPressed(.HOME):                    _cd.diff_scroll = 0
	case rl.IsKeyPressed(.END):                     _cd.diff_scroll = rows
	case:
		if w := rl.GetMouseWheelMove(); w != 0 { _cd.diff_scroll += w > 0 ? -3 : 3 }
	}
	_cd.diff_scroll = clamp(_cd.diff_scroll, 0, max(0, rows - vis))
}

// ---------------------------------------------------------------------------
// Drawing: detail pane
// ---------------------------------------------------------------------------

@(private="file") _cd_last_click_row: int = -1
@(private="file") _cd_last_click_t:   f64

commit_detail_draw :: proc(e: ^Editor, font: rl.Font, r: rl.Rectangle, c: ^git.Commit, files_focus, interactive: bool) {
	rl.DrawRectangleRec(r, GITD_HEADER)
	pad  := f32(12)
	x    := r.x + pad
	xr   := r.x + r.width - pad
	y    := r.y + 8
	size := FONT_SIZE - 2
	lh   := size + 6

	if c == nil {
		ui_text(font, "No commit selected", x, y, lh, size, GITD_SUBDUED, xr)
		return
	}
	loaded := _cd.d != nil && _cd.hash == c.hash
	ui_scissor_begin(i32(r.x), i32(r.y), i32(r.width), i32(r.height))
	defer { rl.EndScissorMode(); dlg_restore() }

	// Subject + body
	msg := c.subject
	if loaded { msg = _cd.d.message }
	subject, _, body := strings.partition(msg, "\n")
	ui_text(font, subject, x, y, lh + 2, FONT_SIZE, GITD_TEXT, xr)
	y += lh + 6

	// Meta
	label :: proc(font: rl.Font, k, v: string, x, y, lh, size, xr: f32, col: rl.Color) {
		ui_text(font, k, x, y, lh, size, GITD_SUBDUED, xr)
		ui_text(font, v, x + 70, y, lh, size, col, xr)
	}
	label(font, "Author", fmt.tprintf("%s <%s>", c.author_name, c.author_email), x, y, lh, size, xr, GITD_TEXT); y += lh
	now := time.time_to_unix(time.now())
	label(font, "Date", fmt.tprintf("%s  (%s)", _cd_format_date(c.author_time), cg_relative_time(now, c.author_time)), x, y, lh, size, xr, GITD_TEXT); y += lh

	// Hash: click copies
	label(font, "Hash", c.hash, x, y, lh, size, xr, GITD_ORANGE)
	hash_r := rl.Rectangle{x + 70, y, ui_text_w(font, c.hash, size), lh}
	mp := rl.GetMousePosition()
	if interactive && ui_point_in(mp, hash_r) {
		ui_cursor_request(.POINTING_HAND)
		if rl.IsMouseButtonPressed(.LEFT) {
			rl.SetClipboardText(to_cstring(c.hash))
			ui_banner_show("Commit hash copied", .Success)
		}
	}
	y += lh

	// Parents: click selects the parent in the graph
	ui_text(font, "Parents", x, y, lh, size, GITD_SUBDUED, xr)
	px := x + 70
	if len(c.parents) == 0 { ui_text(font, "(root commit)", px, y, lh, size, GITD_SUBDUED, xr) }
	for p in c.parents {
		short := p[:min(len(p), 7)]
		w := ui_text_w(font, short, size)
		pr := rl.Rectangle{px, y, w, lh}
		hover := interactive && ui_point_in(mp, pr)
		ui_text(font, short, px, y, lh, size, hover ? ACCENT_COL : GITD_BLUE, xr)
		rl.DrawLineV({px, y + lh - 3}, {px + w, y + lh - 3}, ui_with_alpha(GITD_BLUE, 120))
		if hover {
			ui_cursor_request(.POINTING_HAND)
			if rl.IsMouseButtonPressed(.LEFT) {
				hash := strings.clone(p, context.temp_allocator)
				commit_graph_select(e, hash)
				return
			}
		}
		px += w + 12
	}
	y += lh

	// Refs
	if len(c.refs) > 0 {
		ui_text(font, "Refs", x, y, lh, size, GITD_SUBDUED, xr)
		rx := x + 70
		for ref in c.refs {
			name := ref.name
			col := GITD_GREEN
			switch ref.kind {
			case .Branch:        if ref.is_head { name = fmt.tprintf("HEAD -> %s", ref.name) }
			case .Remote_Branch: col = GITD_BLUE
			case .Tag:           col = GITD_YELLOW; name = fmt.tprintf("tag %s", ref.name)
			case .Head:          col = GITD_ORANGE
			}
			w := ui_text_w(font, name, size - 1) + 10
			if rx + w > xr { break }
			rl.DrawRectangleRoundedLinesEx({rx, y + 2, w, lh - 4}, 0.4, 4, 1, col)
			ui_text(font, name, rx + 5, y, lh, size - 1, col, rx + w)
			rx += w + 6
		}
		y += lh
	}

	// Body (up to a few lines)
	body = strings.trim_space(body)
	if body != "" {
		y += 4
		n := 0
		rest := body
		for line in strings.split_lines_iterator(&rest) {
			if n >= 8 { ui_text(font, "...", x, y, lh, size, GITD_SUBDUED, xr); y += lh; break }
			ui_text(font, _cd_expand_tabs(line), x, y, lh, size, GITD_TEXT, xr)
			y += lh
			n += 1
		}
	}
	y += 6
	rl.DrawLineV({r.x, y}, {r.x + r.width, y}, GITD_BORDER)
	y += 4

	if _cd.err != "" && _cd.hash == c.hash {
		ui_text(font, _cd.err, x, y, lh, size, GITD_RED, xr)
		return
	}
	if !loaded {
		ui_text(font, "loading files...", x, y, lh, size, GITD_SUBDUED, xr)
		return
	}

	// Files
	files := _cd.d.files
	ui_text(font, fmt.tprintf("%d file%s changed", len(files), "" if len(files) == 1 else "s"), x, y, lh, size, files_focus ? ACCENT_COL : GITD_SUBDUED, xr)
	y += lh
	row_h := lh + 2
	lr := rl.Rectangle{r.x, y, r.width, r.y + r.height - y}
	vis := max(1, int(lr.height / row_h))
	_cd.files_vis = vis
	ui_list_clamp(&_cd.files, len(files), vis)
	for vi in 0 ..< vis {
		i := _cd.files.scroll + vi
		if i >= len(files) { break }
		f := files[i]
		ry := lr.y + f32(vi) * row_h
		if i == _cd.files.selected {
			rl.DrawRectangleRec({lr.x, ry, lr.width, row_h}, files_focus ? SEL_BG : GITD_SEL)
			if files_focus { rl.DrawRectangleRec({lr.x, ry, 3, row_h}, ACCENT_COL) }
		}
		letter, col := _cd_change_style(f.change)
		ui_text(font, letter, x, ry, row_h, size, col, xr)
		name := f.path
		if f.old_path != "" { name = fmt.tprintf("%s  <-  %s", f.path, f.old_path) }
		ui_text(font, name, x + 22, ry, row_h, size, GITD_TEXT, xr)
	}
	if len(files) > vis {
		th := max(12, lr.height * f32(vis) / f32(len(files)))
		ty := lr.y + (lr.height - th) * f32(_cd.files.scroll) / f32(max(1, len(files) - vis))
		rl.DrawRectangleRec({lr.x + lr.width - 4, ty, 4, th}, GITD_BORDER)
	}

	if interactive && ui_point_in(mp, lr) {
		if w := rl.GetMouseWheelMove(); w != 0 { ui_list_scroll_by(&_cd.files, w > 0 ? -3 : 3, len(files), vis) }
		if rl.IsMouseButtonPressed(.LEFT) {
			row := ui_list_row_at(_cd.files, lr.y, row_h, mp.y, len(files), vis)
			if row >= 0 {
				t := rl.GetTime()
				dbl := row == _cd_last_click_row && t - _cd_last_click_t < 0.35
				_cd.files.selected = row
				_cd_last_click_row = row
				_cd_last_click_t = t
				if dbl { _cd_open_file(e, row) }
			}
		}
	}
}

@(private="file")
_cd_change_style :: proc(c: git.File_Change) -> (string, rl.Color) {
	switch c {
	case .Added:        return "A", GITD_GREEN
	case .Deleted:      return "D", GITD_RED
	case .Modified:     return "M", GITD_ORANGE
	case .Renamed:      return "R", GITD_BLUE
	case .Copied:       return "C", GITD_BLUE
	case .Type_Changed: return "T", GITD_YELLOW
	case .Unmerged:     return "U", GITD_RED
	case .Unknown:      return "?", GITD_SUBDUED
	}
	return "?", GITD_SUBDUED
}

// "2026-10-13 14:22 UTC" (temp-allocated).
@(private="file")
_cd_format_date :: proc(sec: i64) -> string {
	t := time.unix(sec, 0)
	y, mo, d := time.date(t)
	h, mi, _ := time.clock_from_time(t)
	return fmt.tprintf("%04d-%02d-%02d %02d:%02d UTC", y, int(mo), d, h, mi)
}

@(private="file")
_cd_expand_tabs :: proc(s: string) -> string {
	if strings.index_byte(s, '\t') < 0 { return s }
	b := strings.builder_make(context.temp_allocator)
	col := 0
	for r in s {
		if r == '\t' {
			for _ in 0 ..< (4 - col % 4) { strings.write_byte(&b, ' '); col += 1 }
		} else {
			strings.write_rune(&b, r); col += 1
		}
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// Drawing: whole-file side-by-side diff of one file (virtualized)
// ---------------------------------------------------------------------------

commit_detail_draw_diff :: proc(e: ^Editor, font: rl.Font, r: rl.Rectangle) {
	HDR :: f32(34)
	FTR :: f32(26)
	fs := FONT_SIZE - 1
	dy := fs + 4
	cw := ui_text_w(font, "0", fs)
	px, py, pw, ph := r.x, r.y, r.width, r.height

	path := ""
	nfiles := commit_detail_file_count()
	if _cd.d != nil && _cd.diff_file < len(_cd.d.files) { path = _cd.d.files[_cd.diff_file].path }

	rl.DrawRectangleRec({px, py, pw, HDR}, GITD_HEADER)
	n_changes := len(_cd.diff.changed) if _cd.diff != nil else 0
	pos := fmt.tprintf("change %d/%d", _cd.diff_change + 1, n_changes) if n_changes > 0 else "no changes"
	short := _cd.hash[:min(len(_cd.hash), 7)]
	title := fmt.tprintf("%s @ %s   file %d/%d   %s", path, short, _cd.diff_file + 1, nfiles, pos)
	ui_text(font, title, px + 10, py, HDR, fs, GITD_BLUE, px + pw - 10)

	top := py + HDR
	fy  := py + ph - FTR
	ch  := fy - top
	vis := max(1, int(ch / dy))
	_cd.diff_vis = vis

	rl.DrawRectangleRec({px, fy, pw, FTR}, GITD_HEADER)
	ui_text(font, "n/p next/prev change   ] / [ next/prev file   Up/Dn PgUp/PgDn wheel scroll   Esc back", px + 10, fy, FTR, FONT_SIZE - 4, GITD_SUBDUED, px + pw)

	switch {
	case _cd.diff_err != "":
		ui_text(font, _cd.diff_err, px + 16, top + 10, dy, fs, GITD_RED, px + pw)
		return
	case _cd.diff == nil:
		ui_text(font, "loading diff...", px + 16, top + 10, dy, fs, GITD_SUBDUED, px + pw)
		return
	case _cd.diff.binary:
		ui_text(font, "Binary file - no text diff", px + 16, top + 10, dy, fs, GITD_SUBDUED, px + pw)
		return
	case len(_cd.diff.rows) == 0:
		ui_text(font, "No changes in this file", px + 16, top + 10, dy, fs, GITD_SUBDUED, px + pw)
		return
	}

	rows := _cd.diff.rows[:]
	_cd.diff_scroll = clamp(_cd.diff_scroll, 0, max(0, len(rows) - vis))
	half   := (pw - 9) * 0.5
	gutter := cw * 6 + 10
	col_x  := [2]f32{px, px + half + 3}
	rl.DrawRectangleV({px + half + 1, top}, {1, ch}, GITD_BORDER)

	ui_scissor_begin(i32(px), i32(top), i32(pw), i32(ch))
	y := top
	for i := _cd.diff_scroll; i < len(rows) && i < _cd.diff_scroll + vis; i += 1 {
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
			if bg.a != 0   { rl.DrawRectangleV({x, y}, {half, dy}, bg) }
			if mark.a != 0 { rl.DrawRectangleV({x, y}, {3, dy}, mark) }
			if side.line > 0 {
				num := fmt.tprintf("%d", side.line)
				nw := ui_text_w(font, num, fs)
				rl.DrawTextEx(font, to_cstring(num), {x + gutter - 8 - nw, y + 2}, fs, CHAR_SPACING, GITD_SUBDUED)
			}
			if side.text != "" {
				dlg_text(font, _cd_expand_tabs(side.text), x + gutter, y + 2, fs, CHAR_SPACING, GITD_TEXT, x + half, 6)
			}
		}
		y += dy
	}
	rl.EndScissorMode()
	dlg_restore()

	// Scrollbar with change markers
	track_x := px + pw - 6
	rl.DrawRectangleV({track_x, top}, {5, ch}, GITD_HEADER)
	total := f32(len(rows))
	for start in _cd.diff.changed {
		rr := rows[start]
		col := GITD_DIFF_MARK_DEL if rr.right.kind == .Empty else GITD_DIFF_MARK_ADD
		if rr.left.kind == .Delete && rr.right.kind == .Add { col = GITD_YELLOW }
		rl.DrawRectangleV({track_x, top + ch * f32(start) / total}, {5, 2}, col)
	}
	bar_h := max(16, ch * f32(vis) / total)
	bar_y := top + (ch - bar_h) * f32(_cd.diff_scroll) / max(1, total - f32(vis))
	rl.DrawRectangleLinesEx({track_x - 1, bar_y, 7, bar_h}, 1, GITD_SUBDUED)
}
