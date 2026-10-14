package editor

// ===========================================================================
// Review mode (ticket #17, ADR 0015) — panel `claude_review`.
//
// Files the active repository's Claude session changed (diff between the
// HEAD recorded when the session started and the working tree, plus
// untracked files — review_mode_model.odin). Enter/D opens the whole-file
// diff against that start point (Diff mode of git_dialog.odin); Space marks
// the file reviewed (in memory, per session); C opens the Working Tree
// panel to commit. Git goes through the active repo's queue.
// ===========================================================================

import "base:runtime"
import "core:fmt"
import "core:strings"
import git "./git"
import rl "vendor:raylib"

REVIEW_MODE_ID :: "claude_review"

@(init)
_review_mode_register :: proc "contextless" () {
	ui_register_panel(Ui_Panel{
		id           = REVIEW_MODE_ID,
		title        = "Claude Review",
		priority     = 59,
		layer        = .Overlay,
		draw         = _rv_draw,
		input        = _rv_input,
		on_open      = _rv_on_open,
		on_close     = _rv_on_close,
		command      = "Claude: Review Changes",
		command_desc = "Files the Claude session changed: whole-file diff, mark reviewed, commit",
		shortcut     = {key = .J, mods = {.Ctrl, .Alt}},
	})
}

@(private="file")
_Rv :: struct {
	e:         ^Editor,
	root:      string, // session's repo root, owned
	base:      string, // owned ("" until the session's base is known → HEAD)
	files:     [dynamic]Review_File, // paths owned
	loaded:    bool,
	list_job:  git.Job_Id,
	diff_job:  git.Job_Id,
	diff_path: string, // owned
	nav:       Ui_List_Nav,
	vis:       int,
	list_rect: rl.Rectangle,
	msg:       string, // owned
}
@(private="file") _rv: _Rv

review_mode_open :: proc(e: ^Editor) { ui_panel_open(e, REVIEW_MODE_ID) }

@(private="file")
_rv_set :: proc(dst: ^string, v: string) { delete(dst^); dst^ = strings.clone(v) }

@(private="file")
_rv_free_files :: proc() {
	for f in _rv.files { delete(f.path) }
	clear(&_rv.files)
}

@(private="file")
_rv_session :: proc() -> ^Claude_Session { return claude_session_of(_rv.root) }

@(private="file")
_rv_on_open :: proc(e: ^Editor) {
	_rv.e = e
	s := claude_session_active(e)
	if s == nil {
		ui_banner_show("No Claude session in this repository — Ctrl/Cmd+J starts one", .Warning)
		ui_panel_close(e, REVIEW_MODE_ID)
		return
	}
	_rv_set(&_rv.root, s.root)
	_rv_set(&_rv.base, s.base_rev)
	_rv.nav = {}
	_rep_key = .KEY_NULL
	_rv_refresh(e)
}

@(private="file")
_rv_on_close :: proc(e: ^Editor) {
	// Jobs live on this repo's queue: drop them (a switch closes us first).
	if _rv.list_job != 0 { git.git_release(&e.git_mgr.queue, _rv.list_job); _rv.list_job = 0 }
	if _rv.diff_job != 0 { git.git_release(&e.git_mgr.queue, _rv.diff_job); _rv.diff_job = 0 }
	_rv_free_files()
	delete(_rv.files); _rv.files = nil
	_rv_set(&_rv.msg, "")
	_rv.loaded = false
}

@(private="file")
_rv_refresh :: proc(e: ^Editor) {
	if _rv.list_job != 0 { git.git_release(&e.git_mgr.queue, _rv.list_job) }
	base := _rv.base if _rv.base != "" else "HEAD"
	_rv.list_job = git.git_request_custom(&e.git_mgr.queue, review_list_work, {base})
	git.git_on_done(&e.git_mgr.queue, _rv.list_job, proc(r: ^git.Git_Result, user: rawptr) {
		if r.id != _rv.list_job { return }
		_rv.list_job = 0
		if !ui_panel_is_open(REVIEW_MODE_ID) { return }
		if r.status == .Failed { _rv_set(&_rv.msg, r.err); return }
		c, ok := r.payload.(git.Git_Custom)
		if !ok { return }
		l := git.git_custom_as(c, Review_List)
		if l == nil { return }
		_rv_free_files()
		for f in l.files { append(&_rv.files, Review_File{path = strings.clone(f.path), status = f.status}) }
		_rv.loaded = true
		_rv_set(&_rv.msg, "")
	})
}

@(private="file")
_rv_open_diff :: proc(e: ^Editor, path: string) {
	_rv_set(&_rv.diff_path, path)
	if _rv.diff_job != 0 { git.git_release(&e.git_mgr.queue, _rv.diff_job) }
	base := _rv.base if _rv.base != "" else "HEAD"
	_rv.diff_job = git.git_request_custom(&e.git_mgr.queue, review_diff_work, {base, path})
	git.git_on_done(&e.git_mgr.queue, _rv.diff_job, proc(r: ^git.Git_Result, user: rawptr) {
		if r.id != _rv.diff_job { return }
		_rv.diff_job = 0
		if !ui_panel_is_open(REVIEW_MODE_ID) || _rv.e == nil { return }
		if r.status == .Failed { ui_banner_show(r.err, .Warning); return }
		c, ok := r.payload.(git.Git_Custom)
		if !ok { return }
		raw := git.git_custom_as(c, Review_Diff_Raw)
		if raw == nil { return }
		text := strings.clone(raw.text) // the result arena dies after this callback
		fd := git.file_diff_all_added(text) if raw.all_added else git.parse_unified_diff(text)
		git_dialog_show_diff(_rv.e, _rv.diff_path, fd)
	})
}

@(private="file")
_rv_commit :: proc(e: ^Editor) {
	ui_panel_close(e, REVIEW_MODE_ID)
	working_tree_open(e)
}

@(private="file")
_rv_input :: proc(e: ^Editor) -> bool {
	_rv.e = e
	n := len(_rv.files)
	ui_list_handle_nav(&_rv.nav, n, max(1, _rv.vis), _rv.list_rect)
	if ctrl() || alt() { return true }
	if rl.IsKeyPressed(.ESCAPE) { ui_panel_close(e, REVIEW_MODE_ID); return true }
	if rl.IsKeyPressed(.C) { _rv_commit(e); return true }
	if rl.IsKeyPressed(.R) || rl.IsKeyPressed(.F5) { _rv_refresh(e); return true }
	if n == 0 { return true }
	sel := clamp(_rv.nav.selected, 0, n - 1)
	f := _rv.files[sel]
	switch {
	case rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) || rl.IsKeyPressed(.D):
		_rv_open_diff(e, f.path)
	case rl.IsKeyPressed(.SPACE) || rl.IsKeyPressed(.V):
		if s := _rv_session(); s != nil {
			review_toggle(s, f.path)
			if review_is_reviewed(s, f.path) { ui_list_move(&_rv.nav, 1, n, max(1, _rv.vis)) }
		}
	}
	return true
}

@(private="file")
_rv_draw :: proc(e: ^Editor, font: rl.Font, sw, sh: f32) {
	if e.git_dialog.visible { return } // the diff is on top
	_rv.e = e
	s := _rv_session()
	fs := FONT_SIZE - 1
	row_h := GITD_ENTRY_H
	W := min(f32(900), sw - 60)
	H := sh - 80
	rl.DrawRectangle(0, 0, i32(sw), i32(sh), {0, 0, 0, 120})
	px, py := dlg_begin((sw - W) * 0.5, (sh - H) * 0.5, W, H, GITD_BG, GITD_BORDER)

	rl.DrawRectangleV({px, py}, {W, GITD_HEADER_H}, GITD_HEADER)
	name := s.name if s != nil else "?"
	done, total := 0, len(_rv.files)
	if s != nil { done, total = review_progress(s, _rv.files[:]) }
	base := _rv.base[:min(8, len(_rv.base))] if _rv.base != "" else "HEAD"
	title := fmt.tprintf(" Review · %s   %d/%d reviewed   since %s", name, done, total, base)
	ui_text(font, title, px + 6, py, GITD_HEADER_H, FONT_SIZE, GITD_GREEN if total > 0 && done == total else GITD_BLUE, px + W - 120)
	if _rv.list_job != 0 || _rv.diff_job != 0 {
		ind := "loading..."
		iw := ui_text_w(font, ind, FONT_SIZE - 2)
		ui_text(font, ind, px + W - iw - 12, py, GITD_HEADER_H, FONT_SIZE - 2, GITD_SUBDUED, px + W)
	}

	list_r := rl.Rectangle{px, py + GITD_HEADER_H + 2, W, H - GITD_HEADER_H - GITD_FOOTER_H - 4}
	_rv.list_rect = list_r
	_rv.vis = max(1, int(list_r.height / row_h))
	n := len(_rv.files)
	ui_list_clamp(&_rv.nav, n, _rv.vis)
	if _rv.msg != "" {
		ui_text(font, _rv.msg, px + 14, list_r.y, row_h, fs, GITD_RED, px + W)
	} else if _rv.loaded && n == 0 {
		ui_text(font, "Nothing changed since the session started.", px + 14, list_r.y, row_h, fs, GITD_SUBDUED, px + W)
	}
	mp := rl.GetMousePosition()
	for vi in 0 ..< _rv.vis {
		idx := _rv.nav.scroll + vi
		if idx >= n { break }
		f := _rv.files[idx]
		y := list_r.y + f32(vi) * row_h
		r := rl.Rectangle{px, y, W, row_h}
		if idx == _rv.nav.selected {
			rl.DrawRectangleRec(r, GITD_SEL)
			rl.DrawRectangleV({px, y}, {3, row_h}, GITD_BLUE)
		}
		rev := s != nil && review_is_reviewed(s, f.path)
		ui_text(font, "[x]" if rev else "[ ]", px + 10, y, row_h, fs, GITD_GREEN if rev else GITD_SUBDUED, px + 44)
		scol := GITD_ORANGE
		switch f.status {
		case 'A', '?': scol = GITD_GREEN
		case 'D':      scol = GITD_RED
		}
		ui_text(font, f.status == '?' ? "U" : fmt.tprintf("%c", f.status), px + 50, y, row_h, fs, scol, px + 66)
		ui_text(font, f.path, px + 72, y, row_h, fs, GITD_SUBDUED if rev else GITD_TEXT, px + W - 8)
		if ui_point_in(mp, r) && rl.IsMouseButtonPressed(.LEFT) {
			if idx == _rv.nav.selected { _rv_open_diff(e, f.path) }
			_rv.nav.selected = idx
		}
	}

	fy := py + H - GITD_FOOTER_H
	rl.DrawRectangleV({px, fy}, {W, GITD_FOOTER_H}, GITD_HEADER)
	ui_text(font, "Enter/D diff · Space mark reviewed · C commit (Working Tree) · R refresh · Esc close", px + 10, fy, GITD_FOOTER_H, FONT_SIZE - 3, GITD_SUBDUED, px + W)
	dlg_end()
}

@(fini)
_review_mode_fini :: proc "contextless" () {
	context = runtime.default_context()
	_rv_free_files()
	delete(_rv.files)
	delete(_rv.root); delete(_rv.base); delete(_rv.diff_path); delete(_rv.msg)
}
