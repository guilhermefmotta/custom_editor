package editor

// ===========================================================================
// Merge resolver panel (ticket #8, id "merge_resolver", ADR 0012).
//
// IntelliJ-style three panes: Local (ours) | Result (editable) | Remote
// (theirs), aligned conflict by conflict. Each side of each conflict has
// Accept / Ignore; Done (Ctrl/Cmd+Enter) writes the result, stages it and
// jumps to the next conflicted file; after the last one the panel offers
// Commit merge / Continue rebase. Abort restores the state before the merge.
// The document model lives in merge_resolver_model.odin (pure, tested); git
// operations in git/merge_ops.odin (always through the queue).
//
// Also owns the main-window banner: "N file(s) in conflict - Resolve" /
// "Merge ready to commit - Commit", refreshed from the repo state; clicking
// it (or Ctrl+Alt+M) opens this panel.
//
// Public entry points: merge_resolver_open_file(e, path) (open on a given
// conflicted file), merge_resolver_refresh_state(e) (re-read the repo state
// now, e.g. after another screen ran a merge).
// ===========================================================================

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import git "./git"
import rl "vendor:raylib"

MERGE_RESOLVER_ID :: "merge_resolver"

@(init)
_merge_resolver_register :: proc "contextless" () {
	ui_register_panel(Ui_Panel{
		id           = MERGE_RESOLVER_ID,
		title        = "Merge Resolver",
		priority     = 80,
		layer        = .Overlay,
		draw         = _mr_draw,
		input        = _mr_input,
		update       = _mr_update,
		on_open      = _mr_on_open,
		on_close     = _mr_on_close,
		command      = "Git: Resolve Conflicts",
		command_desc = "Three-pane conflict resolver (Local | Result | Remote)",
		shortcut     = {key = .M, mods = {.Ctrl, .Alt}},
	})
	ui_register_command(Command{"Git: Abort Merge / Rebase", "Abort the merge, rebase, cherry-pick or revert in progress", _mr_cmd_abort, nil})
	ui_register_command(Command{"Git: Commit Merge / Continue Rebase", "Finish the merge (or continue the rebase) once every conflict is staged", _mr_cmd_complete, nil})
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

@(private="file")
_Mr_Confirm :: enum u8 { None, Abort, Discard_Edits }

@(private="file")
_Mr :: struct {
	e:            ^Editor,
	// repository
	op:           git.Repo_Operation,
	head:         string,   // owned
	files:        [dynamic]string, // owned; conflicted files when the list was built
	resolved:     [dynamic]bool,
	current:      int,      // index into files; -1 = none (all done view)
	want_path:    string,   // owned; file to select once the list arrives
	state_job:    git.Job_Id,
	// current file
	loading:      bool,
	loaded:       bool,
	exists:       bool,
	binary:       bool,
	labels:       [Mr_Side]string, // owned
	doc:          Mr_Doc,
	layout:       Mr_Layout,
	active:       int,  // active conflict
	scroll:       int,  // first visible row (all panes)
	goal_col:     int,
	follow:       bool, // scroll to the cursor on next draw
	busy:         bool, // resolve / complete / abort running
	msg:          string, // owned
	msg_ok:       bool,
	confirm:      Ui_Confirm,
	confirm_act:  _Mr_Confirm,
	confirm_file: int,
	vis_rows:     int,
	// banner
	bg_timer:     f32,
	bg_job:       git.Job_Id,
	banner_key:   string, // owned; banner text we last showed ("" = none)
}

@(private="file") _mr: _Mr

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

// Opens the resolver on `rel_path` (repo-relative). Used by working_tree and
// git_dialog_open_merge.
merge_resolver_open_file :: proc(e: ^Editor, rel_path: string) {
	_mr_set_str(&_mr.want_path, rel_path)
	if ui_panel_is_open(MERGE_RESOLVER_ID) {
		_mr_request_state(e)
	} else {
		ui_panel_open(e, MERGE_RESOLVER_ID)
	}
}

// Re-reads the repo state now (banner + panel).
merge_resolver_refresh_state :: proc(e: ^Editor) {
	_mr.bg_timer = 0
	if ui_panel_is_open(MERGE_RESOLVER_ID) { _mr_request_state(e) }
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

@(private="file")
_mr_on_open :: proc(e: ^Editor) {
	_mr.e = e
	_mr_clear_file()
	_mr_clear_list()
	_mr.current = -1
	_mr.busy = false
	_mr_set_msg(true, "")
	if e.git_mgr.root == "" { _mr_set_msg(false, "No git repository"); return }
	_mr_hide_own_banner()
	_mr_request_state(e)
}

@(private="file")
_mr_on_close :: proc(e: ^Editor) {
	_mr_clear_file()
	_mr_clear_list()
	_mr.current = -1
	ui_confirm_destroy(&_mr.confirm)
	_mr_set_str(&_mr.want_path, "")
	_mr.bg_timer = 0 // banner reflects the new state right away
}

@(private="file")
_mr_clear_file :: proc() {
	mr_doc_destroy(&_mr.doc)
	mr_layout_destroy(&_mr.layout)
	for s in Mr_Side { _mr_set_str(&_mr.labels[s], "") }
	_mr.loading, _mr.loaded, _mr.exists, _mr.binary = false, false, false, false
	_mr.active, _mr.scroll, _mr.goal_col = 0, 0, 0
}

@(private="file")
_mr_clear_list :: proc() {
	for f in _mr.files { delete(f) }
	delete(_mr.files); _mr.files = {}
	delete(_mr.resolved); _mr.resolved = {}
}

@(private="file")
_mr_set_str :: proc(dst: ^string, s: string) {
	if dst^ != "" { delete(dst^) }
	dst^ = strings.clone(s) if s != "" else ""
}

@(private="file")
_mr_set_msg :: proc(ok: bool, msg: string) {
	_mr_set_str(&_mr.msg, msg)
	_mr.msg_ok = ok
}

// ---------------------------------------------------------------------------
// Async: repo state, file load, operations
// ---------------------------------------------------------------------------

@(private="file")
_mr_request_state :: proc(e: ^Editor) {
	if _mr.state_job != 0 || e.git_mgr.root == "" { return }
	_mr.state_job = git.git_request_repo_state(&e.git_mgr.queue)
	git.git_on_done(&e.git_mgr.queue, _mr.state_job, proc(r: ^git.Git_Result, user: rawptr) {
		_mr.state_job = 0
		e := (^Editor)(user)
		st, ok := r.payload.(git.Repo_State)
		if !ok || r.status != .Done { _mr_set_msg(false, r.err if r.err != "" else "git status failed"); return }
		_mr_apply_state(e, st)
	}, e)
}

// New conflicted-file list from the repo state; keeps the current file when
// it is still conflicted, else selects want_path / the first one.
@(private="file")
_mr_apply_state :: proc(e: ^Editor, st: git.Repo_State) {
	_mr.op = st.operation
	_mr_set_str(&_mr.head, st.head_branch)
	keep := ""
	if _mr.current >= 0 && _mr.current < len(_mr.files) { keep = strings.clone(_mr.files[_mr.current], context.temp_allocator) }
	_mr_clear_list()
	for c in st.conflicts { append(&_mr.files, strings.clone(c)); append(&_mr.resolved, false) }

	pick := -1
	want := _mr.want_path if _mr.want_path != "" else keep
	for f, i in _mr.files { if f == want { pick = i } }
	_mr_set_str(&_mr.want_path, "")
	if pick < 0 && len(_mr.files) > 0 { pick = 0 }
	if pick >= 0 && _mr.loaded && keep == _mr.files[pick] {
		_mr.current = pick // same file, keep edits
		return
	}
	_mr_select(e, pick)
}

@(private="file")
_mr_select :: proc(e: ^Editor, idx: int) {
	_mr_clear_file()
	_mr.current = idx
	if idx < 0 || idx >= len(_mr.files) { _mr.current = -1; return }
	_mr.loading = true
	id := git.git_request_merge_load(&e.git_mgr.queue, _mr.files[idx])
	git.git_on_done(&e.git_mgr.queue, id, proc(r: ^git.Git_Result, user: rawptr) {
		f := git.merge_file_result(r)
		if f == nil {
			_mr.loading = false
			_mr_set_msg(false, r.err if r.err != "" else "can't load file")
			return
		}
		// Stale result (another file was selected meanwhile)?
		if _mr.current < 0 || _mr.current >= len(_mr.files) || _mr.files[_mr.current] != f.path { return }
		_mr.loading = false
		_mr.loaded  = true
		_mr.exists  = f.exists
		_mr.binary  = f.binary
		_mr_set_str(&_mr.labels[.Ours], f.ours_label)
		_mr_set_str(&_mr.labels[.Theirs], f.theirs_label)
		if !f.binary { mr_doc_init(&_mr.doc, f.merged) }
		_mr.active = 0
		_mr.follow = true
		_mr_relayout()
	})
}

@(private="file")
_mr_relayout :: proc() {
	if !_mr.loaded || _mr.binary { return }
	mr_layout(&_mr.doc, &_mr.layout)
}

// Done: write + stage the result, then go to the next conflicted file.
@(private="file")
_mr_done :: proc(e: ^Editor) {
	if _mr.busy || !_mr.loaded || _mr.current < 0 { return }
	if _mr.binary { _mr_set_msg(false, "Binary file: resolve it outside the editor, or Skip"); return }
	text := mr_text(&_mr.doc)
	if git.merge_text_has_markers(text) {
		_mr_set_msg(false, fmt.tprintf("Unresolved conflict markers remain (%d/%d conflicts resolved)", mr_resolved_count(&_mr.doc), len(_mr.doc.blocks)))
		return
	}
	_mr.busy = true
	_mr_set_msg(true, "Saving...")
	delete_file := !_mr.exists && text == ""
	id := git.git_request_merge_resolve(&e.git_mgr.queue, _mr.files[_mr.current], text, delete_file)
	git.git_on_done(&e.git_mgr.queue, id, _mr_on_resolved, e)
}

@(private="file")
_mr_on_resolved :: proc(r: ^git.Git_Result, user: rawptr) {
	e := (^Editor)(user)
	_mr.busy = false
	res := git.merge_op_result(r)
	if res == nil { _mr_set_msg(false, r.err if r.err != "" else "resolve failed"); return }
	if !res.ok { _mr_set_msg(false, res.message); return }
	_mr_set_msg(true, res.message)
	git.git_manager_refresh_now(e.git_mgr)
	_mr.op = res.state.operation
	if _mr.current >= 0 && _mr.current < len(_mr.resolved) { _mr.resolved[_mr.current] = true }
	_mr_select(e, _mr_next_file(_mr.current))
}

// Next file not yet resolved after `cur` (wrapping); -1 when all are done.
@(private="file")
_mr_next_file :: proc(cur: int) -> int {
	n := len(_mr.files)
	for k in 1 ..= n {
		i := (cur + k) % n
		if !_mr.resolved[i] { return i }
	}
	return -1
}

@(private="file")
_mr_complete :: proc(e: ^Editor) {
	if _mr.busy || e.git_mgr.root == "" { return }
	for r in _mr.resolved { if !r { _mr_set_msg(false, "Resolve every file first"); return } }
	_mr.busy = true
	_mr_set_msg(true, fmt.tprintf("%s...", git.merge_complete_label(_mr.op)))
	id := git.git_request_merge_complete(&e.git_mgr.queue)
	git.git_on_done(&e.git_mgr.queue, id, proc(r: ^git.Git_Result, user: rawptr) {
		e := (^Editor)(user)
		_mr.busy = false
		res := git.merge_op_result(r)
		_mr_after_repo_change(e)
		if res == nil { _mr_set_msg(false, r.err if r.err != "" else "git failed"); return }
		if !res.ok {
			_mr_set_msg(false, res.message)
			ui_banner_show(res.message, .Error, seconds = 8)
			return
		}
		if len(res.state.conflicts) > 0 {
			// rebase / cherry-pick sequence stopped again: next round
			_mr_set_msg(true, res.message)
			ui_banner_show(res.message, .Warning)
			_mr.current = -1
			_mr_apply_state(e, res.state)
			return
		}
		ui_banner_show(res.message, .Success)
		ui_panel_close(e, MERGE_RESOLVER_ID)
	}, e)
}

@(private="file")
_mr_abort :: proc(e: ^Editor) {
	if _mr.busy || e.git_mgr.root == "" { return }
	_mr.busy = true
	_mr_set_msg(true, "Aborting...")
	id := git.git_request_merge_abort(&e.git_mgr.queue)
	git.git_on_done(&e.git_mgr.queue, id, proc(r: ^git.Git_Result, user: rawptr) {
		e := (^Editor)(user)
		_mr.busy = false
		res := git.merge_op_result(r)
		_mr_after_repo_change(e)
		if res == nil { _mr_set_msg(false, r.err if r.err != "" else "abort failed"); return }
		if !res.ok { _mr_set_msg(false, res.message); ui_banner_show(res.message, .Error, seconds = 8); return }
		ui_banner_show(res.message, .Success)
		ui_panel_close(e, MERGE_RESOLVER_ID)
	}, e)
}

// After a commit / abort: everything that shows merge state refreshes now.
@(private="file")
_mr_after_repo_change :: proc(e: ^Editor) {
	git.git_manager_refresh_now(e.git_mgr)
	sidebar_refresh(e)
	_mr.bg_timer = 0
}

@(private="file")
_mr_ask_abort :: proc() {
	what := git.repo_operation_name(_mr.op)
	_mr.confirm_act = .Abort
	ui_confirm_open(&_mr.confirm, "Abort?",
		fmt.tprintf("Abort the %s? Every file goes back to how it was before it started; resolutions made here are lost.", what),
		confirm = "Abort", danger = true)
}

@(private="file")
_mr_cmd_abort :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	if !ui_panel_is_open(MERGE_RESOLVER_ID) { ui_panel_open(e, MERGE_RESOLVER_ID) }
	_mr_ask_abort()
}

@(private="file")
_mr_cmd_complete :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	if !ui_panel_is_open(MERGE_RESOLVER_ID) { ui_panel_open(e, MERGE_RESOLVER_ID); return }
	if _mr.current < 0 { _mr_complete(e) }
}

// ---------------------------------------------------------------------------
// Banner (main window) — refreshed from the repo state every few seconds
// ---------------------------------------------------------------------------

MR_BANNER_PERIOD :: f32(3)

// Pure: banner text and kind for a repo state ("" = no banner).
merge_resolver_banner_for :: proc(op: git.Repo_Operation, conflicts: int) -> (text: string, kind: Ui_Banner_Kind) {
	if op == .Clean || op == .Bisecting { return "", .Info }
	if conflicts > 0 {
		return fmt.tprintf("%d file%s in conflict - Resolve (click or Ctrl+Alt+M)", conflicts, "" if conflicts == 1 else "s"), .Warning
	}
	#partial switch op {
	case .Merging:  return "Merge ready to commit - Commit (click or Ctrl+Alt+M)", .Info
	case .Rebasing: return "Rebase step resolved - Continue rebase (click or Ctrl+Alt+M)", .Info
	case .Cherry_Picking, .Reverting:
		return fmt.tprintf("%s resolved - Continue (click or Ctrl+Alt+M)", git.repo_operation_name(op)), .Info
	}
	return "", .Info
}

@(private="file")
_mr_hide_own_banner :: proc() {
	if _mr.banner_key != "" && ui_banner.visible && ui_banner_text(&ui_banner) == _mr.banner_key { ui_banner_hide() }
	_mr_set_str(&_mr.banner_key, "")
}

@(private="file")
_mr_update :: proc(e: ^Editor, dt: f32) {
	_mr.e = e
	if e.git_mgr.root == "" { return }

	// Click on our banner (not on its X) opens the resolver
	if _mr.banner_key != "" && ui_banner.visible && ui_banner_text(&ui_banner) == _mr.banner_key &&
	   rl.IsMouseButtonPressed(.LEFT) {
		mp := rl.GetMousePosition()
		sw := f32(screen_w())
		if mp.y < UI_BANNER_H && mp.x < sw - UI_BANNER_H {
			_mr_hide_own_banner()
			ui_panel_open(e, MERGE_RESOLVER_ID)
			return
		}
	}

	_mr.bg_timer -= dt
	if _mr.bg_timer > 0 || _mr.bg_job != 0 { return }
	_mr.bg_timer = MR_BANNER_PERIOD
	_mr.bg_job = git.git_request_repo_state(&e.git_mgr.queue)
	git.git_on_done(&e.git_mgr.queue, _mr.bg_job, proc(r: ^git.Git_Result, user: rawptr) {
		_mr.bg_job = 0
		st, ok := r.payload.(git.Repo_State)
		if !ok || r.status != .Done { return }
		if ui_panel_is_open(MERGE_RESOLVER_ID) { _mr_hide_own_banner(); return }
		text, kind := merge_resolver_banner_for(st.operation, len(st.conflicts))
		if text == _mr.banner_key { return } // unchanged (also: dismissed stays dismissed)
		_mr_hide_own_banner()
		if text == "" { return }
		_mr_set_str(&_mr.banner_key, text)
		ui_banner_show(text, kind, seconds = 0)
	})
}

// ---------------------------------------------------------------------------
// Editing helpers (Result pane)
// ---------------------------------------------------------------------------

@(private="file")
_mr_line_bounds :: proc(line: int) -> (from, to: int) {
	ls := _mr.layout.line_starts[:]
	from = ls[line]
	to = len(_mr.doc.text)
	if line + 1 < len(ls) { to = ls[line + 1] - 1 }
	return
}

@(private="file")
_mr_cursor_line_col :: proc() -> (line, col: int) {
	line = mr_line_of(_mr.layout.line_starts[:], _mr.doc.cursor)
	from, _ := _mr_line_bounds(line)
	col = utf8.rune_count(_mr.doc.text[from:_mr.doc.cursor])
	return
}

@(private="file")
_mr_set_cursor_line_col :: proc(line, col: int) {
	l := clamp(line, 0, len(_mr.layout.line_starts) - 1)
	from, to := _mr_line_bounds(l)
	pos := from
	for c := 0; c < col && pos < to; c += 1 {
		_, n := utf8.decode_rune(_mr.doc.text[pos:to])
		pos += max(n, 1)
	}
	_mr.doc.cursor = pos
}

@(private="file")
_mr_insert :: proc(s: string) {
	mr_edit(&_mr.doc, _mr.doc.cursor, _mr.doc.cursor, s)
	_mr_after_edit()
}

@(private="file")
_mr_after_edit :: proc() {
	_mr_relayout()
	_, _mr.goal_col = _mr_cursor_line_col()
	_mr.follow = true
}

@(private="file")
_mr_side_action :: proc(i: int, side: Mr_Side, accept: bool) {
	if !_mr.loaded || i < 0 || i >= len(_mr.doc.blocks) { return }
	_mr.active = i
	was := mr_handle_side(&_mr.doc, i, side, accept)
	_mr_relayout()
	// After the first decision move on to the next conflict still showing markers
	if was {
		if nx := mr_next_unresolved(&_mr.doc, i, 1); nx > i { _mr.active = nx }
	}
	_mr.doc.cursor = _mr.doc.blocks[_mr.active].from
	_mr.follow = true
}

@(private="file")
_mr_goto_conflict :: proc(i: int) {
	if !_mr.loaded || len(_mr.doc.blocks) == 0 { return }
	_mr.active = clamp(i, 0, len(_mr.doc.blocks) - 1)
	_mr.doc.cursor = _mr.doc.blocks[_mr.active].from
	_mr_relayout()
	if _mr.active < len(_mr.layout.first_row[.Result]) {
		_mr.scroll = max(0, _mr.layout.first_row[.Result][_mr.active] - max(2, _mr.vis_rows / 3))
	}
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

@(private="file")
_mr_input :: proc(e: ^Editor) -> bool {
	_mr.e = e
	if _mr.confirm.open {
		switch ui_confirm_handle_input(&_mr.confirm) {
		case .Confirm: _mr_confirmed(e)
		case .Cancel, .Extra, .None:
		}
		return true
	}
	if rl.IsKeyPressed(.ESCAPE) { ui_panel_close(e, MERGE_RESOLVER_ID); return true }

	c := ctrl()
	// Done / complete
	if c && (rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER)) {
		if _mr.current >= 0 { _mr_done(e) } else if len(_mr.files) > 0 || _mr.op != .Clean { _mr_complete(e) }
		_mr_drain_chars()
		return true
	}

	wheel := rl.GetMouseWheelMove()
	if wheel != 0 { _mr.scroll = max(0, _mr.scroll - int(wheel * 3)) }

	if !_mr.loaded || _mr.binary || _mr.busy { _mr_drain_chars(); return true }
	d := &_mr.doc

	// Conflict navigation and decisions
	if (c && key_rep(.DOWN)) || (rl.IsKeyPressed(.F7) && !shift()) {
		if nx := mr_next_unresolved(d, _mr.active, 1); nx >= 0 { _mr_goto_conflict(nx) } else { _mr_goto_conflict(_mr.active + 1) }
		return true
	}
	if (c && key_rep(.UP)) || (rl.IsKeyPressed(.F7) && shift()) { _mr_goto_conflict(_mr.active - 1); return true }
	if alt() && len(d.blocks) > 0 {
		if rl.IsKeyPressed(.LEFT)  { _mr_side_action(_mr.active, .Ours, !shift()) }
		if rl.IsKeyPressed(.RIGHT) { _mr_side_action(_mr.active, .Theirs, !shift()) }
		_mr_drain_chars()
		return true
	}

	// Undo / redo
	if c && rl.IsKeyPressed(.Z) {
		if shift() { mr_redo(d) } else { mr_undo(d) }
		_mr_after_edit(); return true
	}
	if c && rl.IsKeyPressed(.Y) { mr_redo(d); _mr_after_edit(); return true }
	if c && rl.IsKeyPressed(.V) {
		if raw := rl.GetClipboardText(); raw != nil {
			s, _ := strings.replace_all(string(raw), "\r\n", "\n", context.temp_allocator)
			_mr_insert(s)
		}
		return true
	}
	if c && rl.IsKeyPressed(.C) {
		line, _ := _mr_cursor_line_col()
		from, to := _mr_line_bounds(line)
		rl.SetClipboardText(to_cstring(string(d.text[from:to])))
		return true
	}

	// Cursor movement
	line, col := _mr_cursor_line_col()
	nlines := len(_mr.layout.line_starts)
	moved := true
	switch {
	case key_rep(.LEFT):
		if d.cursor > 0 {
			d.cursor -= 1
			for d.cursor > 0 && (d.text[d.cursor] & 0xC0) == 0x80 { d.cursor -= 1 }
		}
		_, _mr.goal_col = _mr_cursor_line_col()
	case key_rep(.RIGHT):
		if d.cursor < len(d.text) {
			_, n := utf8.decode_rune(d.text[d.cursor:])
			d.cursor += max(n, 1)
		}
		_, _mr.goal_col = _mr_cursor_line_col()
	case key_rep(.UP):        _mr_set_cursor_line_col(line - 1, _mr.goal_col)
	case key_rep(.DOWN):      _mr_set_cursor_line_col(line + 1, _mr.goal_col)
	case key_rep(.PAGE_UP):   _mr_set_cursor_line_col(line - max(1, _mr.vis_rows - 2), _mr.goal_col)
	case key_rep(.PAGE_DOWN): _mr_set_cursor_line_col(line + max(1, _mr.vis_rows - 2), _mr.goal_col)
	case rl.IsKeyPressed(.HOME):
		if c { d.cursor = 0 } else { _mr_set_cursor_line_col(line, 0) }
		_mr.goal_col = 0
	case rl.IsKeyPressed(.END):
		if c { d.cursor = len(d.text) } else { _, to := _mr_line_bounds(line); d.cursor = to }
		_, _mr.goal_col = _mr_cursor_line_col()
	case:
		moved = false
	}
	_ = col; _ = nlines
	if moved { _mr.follow = true; _mr_drain_chars(); return true }

	// Text editing
	switch {
	case key_rep(.BACKSPACE):
		if d.cursor > 0 {
			from := d.cursor - 1
			for from > 0 && (d.text[from] & 0xC0) == 0x80 { from -= 1 }
			mr_edit(d, from, d.cursor, "")
			_mr_after_edit()
		}
	case key_rep(.DELETE):
		if d.cursor < len(d.text) {
			_, n := utf8.decode_rune(d.text[d.cursor:])
			pos := d.cursor
			mr_edit(d, pos, pos + max(n, 1), "")
			d.cursor = pos
			_mr_after_edit()
		}
	case key_rep(.ENTER) || key_rep(.KP_ENTER):
		_mr_insert("\n")
	case key_rep(.TAB):
		_mr_insert("\t")
	}

	if c || alt() { _mr_drain_chars(); return true }
	buf := make([dynamic]u8, context.temp_allocator)
	for {
		ch := rl.GetCharPressed()
		if ch == 0 { break }
		if ch < 32 { continue }
		b, n := utf8.encode_rune(ch)
		append(&buf, ..b[:n])
	}
	if len(buf) > 0 { _mr_insert(string(buf[:])) }
	return true
}

@(private="file")
_mr_drain_chars :: proc() { for rl.GetCharPressed() != 0 {} }

@(private="file")
_mr_confirmed :: proc(e: ^Editor) {
	act := _mr.confirm_act
	_mr.confirm_act = .None
	switch act {
	case .None:
	case .Abort: _mr_abort(e)
	case .Discard_Edits: _mr_select(e, _mr.confirm_file)
	}
}

// Switch file; asks first when the current result has unsaved edits.
@(private="file")
_mr_pick_file :: proc(e: ^Editor, i: int) {
	if i == _mr.current { return }
	if _mr.loaded && mr_can_undo(&_mr.doc) {
		_mr.confirm_act = .Discard_Edits
		_mr.confirm_file = i
		ui_confirm_open(&_mr.confirm, "Discard edits?", "The result of this file was not saved (Done). Switch file anyway?", confirm = "Switch file", danger = true)
		return
	}
	_mr_select(e, i)
}

// ---------------------------------------------------------------------------
// Draw
// ---------------------------------------------------------------------------

MR_FILES_W   :: f32(230)
MR_BTN_H     :: f32(24)
MR_GAP       :: f32(3)

MR_OURS_BG    :: rl.Color{36, 62, 44, 255}
MR_THEIRS_BG  :: rl.Color{34, 48, 78, 255}
MR_BOTH_BG    :: rl.Color{70, 62, 36, 255}
MR_MANUAL_BG  :: rl.Color{52, 52, 72, 255}
MR_MARKER_BG  :: rl.Color{78, 44, 52, 255}
MR_PHANTOM_BG :: rl.Color{28, 28, 40, 255}
MR_ACTIVE     :: rl.Color{249, 226, 175, 255}

@(private="file")
_mr_draw :: proc(e: ^Editor, font: rl.Font, sw, sh: f32) {
	_mr.e = e
	pw := sw - 40
	ph := sh - 40
	px, py := dlg_begin(20, 20, pw, ph, GITD_BG, GITD_BORDER)
	fs  := FONT_SIZE - 1
	ref := rl.MeasureTextEx(font, "M", fs, CHAR_SPACING)

	// Header
	rl.DrawRectangleV({px, py}, {pw, GITD_HEADER_H}, GITD_HEADER)
	title := fmt.tprintf(" Resolve conflicts  -  %s", git.repo_operation_name(_mr.op))
	if _mr.head != "" { title = fmt.tprintf("%s into %s", title, _mr.head) }
	done_files := 0
	for r in _mr.resolved { if r { done_files += 1 } }
	title = fmt.tprintf("%s   %d/%d files", title, done_files, len(_mr.files))
	hx := _mr_draw_header_buttons(e, font, px, py, pw)
	if !ui_panel_is_open(MERGE_RESOLVER_ID) { dlg_end(); return } // closed by a button
	dlg_text(font, title, px + 8, py + (GITD_HEADER_H - ref.y) * 0.5, fs, CHAR_SPACING, GITD_BLUE, hx, 8)

	top    := py + GITD_HEADER_H
	footer := py + ph - GITD_FOOTER_H

	// File list
	_mr_draw_files(e, font, px, top, MR_FILES_W, footer - top)
	rl.DrawRectangleV({px + MR_FILES_W, top}, {1, footer - top}, GITD_BORDER)

	bx := px + MR_FILES_W + 1
	bw := pw - MR_FILES_W - 1
	switch {
	case _mr.current < 0:     _mr_draw_all_done(e, font, bx, top, bw, footer - top)
	case _mr.loading:         _mr_center_text(font, "Loading...", bx, top, bw, footer - top, GITD_SUBDUED)
	case !_mr.loaded:         _mr_center_text(font, "Can't load this file", bx, top, bw, footer - top, GITD_RED)
	case _mr.binary:          _mr_center_text(font, "Binary file - resolve it outside the editor, or Skip", bx, top, bw, footer - top, GITD_YELLOW)
	case:                     _mr_draw_panes(e, font, bx, top, bw, footer - top)
	}

	// Footer: message or hints
	rl.DrawLineV({px, footer}, {px + pw, footer}, GITD_BORDER)
	hint := "Alt+Left/Right accept Local/Remote  Alt+Shift+Left/Right ignore  Ctrl+Down/Up next/prev conflict  Ctrl+Z/Ctrl+Shift+Z undo/redo  Ctrl+Enter Done  Esc close"
	col := GITD_SUBDUED
	if _mr.msg != "" { hint = _mr.msg; col = GITD_GREEN if _mr.msg_ok else GITD_RED }
	if _mr.loaded && !_mr.binary && _mr.msg == "" {
		n := len(_mr.doc.blocks)
		left := n - mr_resolved_count(&_mr.doc)
		if n == 0 {
			hint = "No conflict markers in this file - Done stages it as it is" if _mr.exists else "File deleted in the working tree - Done stages the deletion"
		} else if left == 0 {
			hint = "All conflicts resolved - Done (Ctrl/Cmd+Enter) saves, stages and opens the next file"
		}
	}
	dlg_text(font, hint, px + 10, footer + (GITD_FOOTER_H - ref.y) * 0.5, FONT_SIZE - 2, CHAR_SPACING, col, px + pw, 10)
	dlg_end()

	switch ui_confirm_draw(&_mr.confirm, font, sw, sh) {
	case .Confirm: _mr_confirmed(e)
	case .Cancel, .Extra, .None:
	}
}

@(private="file")
_mr_center_text :: proc(font: rl.Font, s: string, x, y, w, h: f32, col: rl.Color) {
	tw := ui_text_w(font, s, FONT_SIZE - 1)
	dlg_text(font, s, x + max(10, (w - tw) * 0.5), y + h * 0.4, FONT_SIZE - 1, CHAR_SPACING, col, x + w, 10)
}

// Buttons right-aligned in the header; returns the x where they start.
@(private="file")
_mr_draw_header_buttons :: proc(e: ^Editor, font: rl.Font, px, py, pw: f32) -> f32 {
	x := px + pw - 8
	y := py + (GITD_HEADER_H - MR_BTN_H) * 0.5
	btn :: proc(font: rl.Font, x: ^f32, y: f32, label: string, primary := false, enabled := true) -> bool {
		w := ui_button_w(font, label)
		x^ -= w
		r := rl.Rectangle{x^, y, w, MR_BTN_H}
		x^ -= 6
		if !enabled {
			rl.DrawRectangleRec(r, GITD_HEADER)
			rl.DrawRectangleLinesEx(r, 1, GITD_BORDER)
			tw := ui_text_w(font, label, FONT_SIZE - 2)
			rl.DrawTextEx(font, to_cstring(label), {r.x + (w - tw) * 0.5, r.y + (MR_BTN_H - (FONT_SIZE - 2)) * 0.5}, FONT_SIZE - 2, CHAR_SPACING, GITD_SUBDUED)
			return false
		}
		return ui_button(font, r, label, false, primary)
	}
	if _mr.confirm.open { return x - 400 } // keep it inert under the modal

	if btn(font, &x, y, "Close") { ui_panel_close(e, MERGE_RESOLVER_ID); return x }
	in_op := _mr.op != .Clean && _mr.op != .Bisecting
	abort_lbl := "Abort"
	#partial switch _mr.op {
	case .Merging:  abort_lbl = "Abort merge"
	case .Rebasing: abort_lbl = "Abort rebase"
	}
	if btn(font, &x, y, abort_lbl, enabled = in_op && !_mr.busy) { _mr_ask_abort() }
	if _mr.current < 0 { return x }

	if btn(font, &x, y, "Skip", enabled = !_mr.busy && len(_mr.files) > 1) {
		n := len(_mr.files)
		for k in 1 ..< n {
			i := (_mr.current + k) % n
			if !_mr.resolved[i] { _mr_pick_file(e, i); break }
		}
	}
	ready := _mr.loaded && !_mr.binary && !_mr.busy && mr_all_resolved(&_mr.doc)
	if btn(font, &x, y, "Done", primary = ready, enabled = _mr.loaded && !_mr.binary && !_mr.busy) { _mr_done(e) }
	if !_mr.loaded || _mr.binary { return x }
	d := &_mr.doc
	n := len(d.blocks)
	if n > 0 {
		if btn(font, &x, y, ">", enabled = _mr.active < n - 1) { _mr_goto_conflict(_mr.active + 1) }
		prog := fmt.tprintf("%d/%d resolved", mr_resolved_count(d), n)
		tw := ui_text_w(font, prog, FONT_SIZE - 2)
		x -= tw
		rl.DrawTextEx(font, to_cstring(prog), {x, y + (MR_BTN_H - (FONT_SIZE - 2)) * 0.5}, FONT_SIZE - 2, CHAR_SPACING, GITD_SUBDUED)
		x -= 6
		if btn(font, &x, y, "<", enabled = _mr.active > 0) { _mr_goto_conflict(_mr.active - 1) }
	}
	if n > 1 {
		if btn(font, &x, y, "All Remote") { mr_accept_all(d, .Theirs); _mr_after_edit() }
		if btn(font, &x, y, "All Local")  { mr_accept_all(d, .Ours);   _mr_after_edit() }
	}
	if btn(font, &x, y, "Redo", enabled = mr_can_redo(d)) { mr_redo(d); _mr_after_edit() }
	if btn(font, &x, y, "Undo", enabled = mr_can_undo(d)) { mr_undo(d); _mr_after_edit() }
	return x
}

@(private="file")
_mr_draw_files :: proc(e: ^Editor, font: rl.Font, x, y, w, h: f32) {
	rl.DrawRectangleV({x, y}, {w, GITD_SECTION_H + 4}, GITD_SECTION)
	fs := FONT_SIZE - 2
	ui_text(font, fmt.tprintf("Conflicted files (%d)", len(_mr.files)), x + 8, y, GITD_SECTION_H + 4, fs, GITD_SUBDUED, x + w)
	ry := y + GITD_SECTION_H + 4
	row_h := GITD_ENTRY_H + 2
	mp := rl.GetMousePosition()
	for f, i in _mr.files {
		if ry + row_h > y + h { break }
		r := rl.Rectangle{x, ry, w, row_h}
		if i == _mr.current { rl.DrawRectangleRec(r, GITD_SEL) }
		cx := x + 14
		cy := ry + row_h * 0.5
		if _mr.resolved[i] { _mr_draw_check(cx, cy, 5, GITD_GREEN) } else { rl.DrawCircleV({cx, cy}, 4, GITD_YELLOW) }
		name := f
		if k := strings.last_index_byte(f, '/'); k >= 0 { name = f[k + 1:] }
		col := GITD_SUBDUED if _mr.resolved[i] else (GITD_TEXT if i == _mr.current else GITD_TEXT)
		ui_text(font, name, x + 26, ry, row_h, fs, col, x + w)
		if !_mr.confirm.open && ui_point_in(mp, r) && rl.IsMouseButtonPressed(.LEFT) && !_mr.busy { _mr_pick_file(e, i) }
		ry += row_h
	}
}

@(private="file")
_mr_draw_all_done :: proc(e: ^Editor, font: rl.Font, x, y, w, h: f32) {
	label := git.merge_complete_label(_mr.op)
	msg: string
	switch {
	case len(_mr.files) > 0:
		msg = fmt.tprintf("All %d file%s resolved", len(_mr.files), "" if len(_mr.files) == 1 else "s")
	case _mr.state_job != 0:
		msg = "Reading repository state..."
	case label == "":
		msg = "No merge or rebase in progress"
	case:
		msg = "No conflicted files left"
	}
	cy := y + h * 0.38
	_mr_draw_check(x + w * 0.5, cy - 30, 12, GITD_GREEN)
	tw := ui_text_w(font, msg, FONT_SIZE)
	rl.DrawTextEx(font, to_cstring(msg), {x + (w - tw) * 0.5, cy}, FONT_SIZE, CHAR_SPACING, GITD_TEXT)
	if label == "" || _mr.confirm.open { return }
	if _mr.busy { label = "Working..." }
	bw := ui_button_w(font, label) + 20
	if ui_button(font, {x + (w - bw) * 0.5, cy + 40, bw, 32}, label, true, true) && !_mr.busy { _mr_complete(e) }
	hint := "Ctrl/Cmd+Enter"
	hw := ui_text_w(font, hint, FONT_SIZE - 3)
	rl.DrawTextEx(font, to_cstring(hint), {x + (w - hw) * 0.5, cy + 80}, FONT_SIZE - 3, CHAR_SPACING, GITD_SUBDUED)
}

// Vector glyphs: the editor font has no ✓ / ✕.
@(private="file")
_mr_draw_check :: proc(cx, cy, s: f32, col: rl.Color) {
	rl.DrawLineEx({cx - s, cy}, {cx - s * 0.3, cy + s * 0.7}, 2, col)
	rl.DrawLineEx({cx - s * 0.3, cy + s * 0.7}, {cx + s, cy - s * 0.8}, 2, col)
}

@(private="file")
_mr_draw_cross :: proc(cx, cy, s: f32, col: rl.Color) {
	rl.DrawLineEx({cx - s, cy - s}, {cx + s, cy + s}, 2, col)
	rl.DrawLineEx({cx - s, cy + s}, {cx + s, cy - s}, 2, col)
}

@(private="file")
_Mr_Line_Kind :: enum u8 { Context, Marker, Ours, Theirs, Base }

@(private="file")
_mr_draw_panes :: proc(e: ^Editor, font: rl.Font, x, y, w, h: f32) {
	d  := &_mr.doc
	L  := &_mr.layout
	fs := FONT_SIZE - 1
	ref := rl.MeasureTextEx(font, "M", fs, CHAR_SPACING)
	cw  := rl.MeasureTextEx(font, "0", fs, CHAR_SPACING).x
	dy  := ref.y + 2
	pane_w := (w - 2 * MR_GAP) / 3
	gutter := cw * 4 + 10

	// Column headers
	hdr_h := GITD_SECTION_H + 4
	titles := [Mr_Pane]string{
		.Ours   = fmt.tprintf("Local (ours)  %s", _mr.labels[.Ours]),
		.Result = fmt.tprintf("Result - editable  %s", _mr.files[_mr.current]),
		.Theirs = fmt.tprintf("Remote (theirs)  %s", _mr.labels[.Theirs]),
	}
	tcol := [Mr_Pane]rl.Color{.Ours = GITD_GREEN, .Result = GITD_SUBDUED, .Theirs = GITD_BLUE}
	for p in Mr_Pane {
		px := x + f32(int(p)) * (pane_w + MR_GAP)
		rl.DrawRectangleV({px, y}, {pane_w, hdr_h}, GITD_SECTION)
		ui_text(font, titles[p], px + 8, y, hdr_h, FONT_SIZE - 2, tcol[p], px + pane_w)
	}
	top := y + hdr_h
	ch  := h - hdr_h
	vis := max(1, int(ch / dy))
	_mr.vis_rows = vis

	nrows := 0
	for p in Mr_Pane { nrows = max(nrows, len(L.rows[p])) }

	// Keep the cursor visible after keyboard moves / edits
	if _mr.follow {
		_mr.follow = false
		line := mr_line_of(L.line_starts[:], d.cursor)
		if line < len(L.line_row) {
			row := L.line_row[line]
			if row < _mr.scroll { _mr.scroll = max(0, row - 2) }
			if row >= _mr.scroll + vis { _mr.scroll = row - vis + 3 }
		}
		// active conflict follows the cursor
		for b, i in d.blocks { if d.cursor >= b.from && d.cursor <= b.to { _mr.active = i } }
	}
	_mr.scroll = clamp(_mr.scroll, 0, max(0, nrows - vis + 2))

	// Line kinds inside unresolved blocks of the result
	kinds := make([]_Mr_Line_Kind, len(L.line_starts), context.temp_allocator)
	for b, i in d.blocks {
		if mr_status(d, i) != .Unresolved { continue }
		l0 := mr_line_of(L.line_starts[:], b.from)
		k  := _Mr_Line_Kind.Ours
		for li := l0; li < len(L.line_starts) && L.line_starts[li] < b.to; li += 1 {
			from, to := _mr_line_bounds(li)
			s := string(d.text[from:to])
			switch {
			case strings.has_prefix(s, "<<<<<<<"): kinds[li] = .Marker; k = .Ours
			case strings.has_prefix(s, "|||||||"): kinds[li] = .Marker; k = .Base
			case strings.has_prefix(s, "======="): kinds[li] = .Marker; k = .Theirs
			case strings.has_prefix(s, ">>>>>>>"): kinds[li] = .Marker; k = .Context
			case: kinds[li] = k
			}
		}
	}

	cur_line, cur_col := _mr_cursor_line_col()
	mp := rl.GetMousePosition()
	clicked := rl.IsMouseButtonPressed(.LEFT) && !_mr.confirm.open && !_mr.busy

	for p in Mr_Pane {
		px := x + f32(int(p)) * (pane_w + MR_GAP)
		rows := L.rows[p][:]
		ui_scissor_begin(i32(px), i32(top), i32(pane_w), i32(ch))
		for vi in 0 ..< vis {
			ri := _mr.scroll + vi
			ry := top + f32(vi) * dy
			if ri >= len(rows) { break }
			row := rows[ri]
			// Background
			bg := rl.Color{}
			if row.conflict >= 0 {
				st := mr_status(d, row.conflict)
				switch p {
				case .Ours:   bg = MR_OURS_BG
				case .Theirs: bg = MR_THEIRS_BG
				case .Result:
					switch st {
					case .Unresolved:
						if row.line >= 0 {
							switch kinds[row.line] {
							case .Marker:  bg = MR_MARKER_BG
							case .Ours:    bg = MR_OURS_BG
							case .Theirs:  bg = MR_THEIRS_BG
							case .Base:    bg = MR_MANUAL_BG
							case .Context: bg = MR_MARKER_BG
							}
						} else { bg = MR_MARKER_BG }
					case .Ours:   bg = MR_OURS_BG
					case .Theirs: bg = MR_THEIRS_BG
					case .Both:   bg = MR_BOTH_BG
					case .Manual: bg = MR_MANUAL_BG
					}
				}
				if p != .Result && st != .Unresolved { bg = ui_with_alpha(bg, 120) }
			}
			if row.line < 0 { bg = MR_PHANTOM_BG if bg.a == 0 else ui_with_alpha(bg, 70) }
			if bg.a != 0 { rl.DrawRectangleV({px, ry}, {pane_w, dy}, bg) }
			if row.conflict >= 0 && row.conflict == _mr.active { rl.DrawRectangleV({px, ry}, {3, dy}, MR_ACTIVE) }
			if row.line < 0 { continue }
			// Gutter + text
			text: string
			if p == .Result {
				from, to := _mr_line_bounds(row.line)
				text = string(d.text[from:to])
			} else {
				side := Mr_Side.Ours if p == .Ours else Mr_Side.Theirs
				text = mr_line_text(d.side_text[side][:], L.side_starts[side][:], row.line)
			}
			text = strings.trim_right(text, "\r")
			num := fmt.tprintf("%d", row.line + 1)
			nw := ui_text_w(font, num, fs - 1)
			rl.DrawTextEx(font, to_cstring(num), {px + gutter - 8 - nw, ry + 1}, fs - 1, CHAR_SPACING, GITD_SUBDUED)
			if text != "" {
				dlg_text(font, _gitd_expand_tabs(text), px + gutter, ry + 1, fs, CHAR_SPACING, GITD_TEXT, px + pane_w, 4)
			}
			if p == .Result && row.line == cur_line {
				from, _ := _mr_line_bounds(row.line)
				vcol := _mr_visual_col(string(d.text[from:d.cursor]))
				_ = cur_col
				cx := px + gutter + f32(vcol) * cw
				rl.DrawRectangleV({cx, ry + 1}, {2, dy - 2}, GITD_YELLOW)
			}
		}
		rl.EndScissorMode()
		dlg_restore()
		if p != .Theirs { rl.DrawRectangleV({px + pane_w + 1, top}, {1, ch}, GITD_BORDER) }

		// Click in the result: place the cursor
		if p == .Result && clicked && ui_point_in(mp, {px, top, pane_w, ch}) {
			ri := _mr.scroll + int((mp.y - top) / dy)
			if ri < len(rows) {
				row := rows[ri]
				if row.line >= 0 {
					from, to := _mr_line_bounds(row.line)
					want := int((mp.x - px - gutter) / cw + 0.5)
					_mr.doc.cursor = _mr_pos_at_visual_col(from, to, want)
					_, _mr.goal_col = _mr_cursor_line_col()
				}
				if row.conflict >= 0 { _mr.active = row.conflict }
			}
		}
	}

	// Accept / Ignore controls (drawn after the text so they sit on top;
	// a click is applied after the loop, which walks the layout)
	_mr_click = {}
	for side in Mr_Side {
		pane := Mr_Pane.Ours if side == .Ours else .Theirs
		px := x + f32(int(pane)) * (pane_w + MR_GAP)
		for fr, i in L.first_row[pane] {
			vi := fr - _mr.scroll
			if vi < 0 || vi >= vis { continue }
			ry := top + f32(vi) * dy
			_mr_draw_side_controls(font, side, i, px, ry, pane_w, dy, clicked, mp)
		}
	}
	if _mr_click.set { _mr_side_action(_mr_click.conflict, _mr_click.side, _mr_click.accept) }
}

@(private="file") _mr_click: struct { conflict: int, side: Mr_Side, accept: bool, set: bool }

@(private="file")
_mr_draw_side_controls :: proc(font: rl.Font, side: Mr_Side, i: int, px, ry, pane_w, dy: f32, clicked: bool, mp: rl.Vector2) {
	state := _mr.doc.sides[i][side]
	fs := FONT_SIZE - 3
	h  := dy
	if state != .Pending {
		w := h + 4
		bx := px + pane_w - w if side == .Ours else px
		rl.DrawRectangleRec({bx, ry, w, h}, GITD_HEADER)
		rl.DrawRectangleLinesEx({bx, ry, w, h}, 1, GITD_BORDER)
		if state == .Applied {
			_mr_draw_check(bx + w * 0.5, ry + h * 0.5, h * 0.28, GITD_GREEN)
		} else {
			_mr_draw_cross(bx + w * 0.5, ry + h * 0.5, h * 0.22, GITD_SUBDUED)
		}
		return
	}
	acc := ">> Accept" if side == .Ours else "Accept <<"
	ign := "x Ignore"
	aw := ui_text_w(font, acc, fs) + 12
	iw := ui_text_w(font, ign, fs) + 12
	// Ignore sits on the outer edge, Accept next to the result pane
	ar, ir: rl.Rectangle
	if side == .Ours {
		ar = {px + pane_w - aw, ry, aw, h}
		ir = {ar.x - iw, ry, iw, h}
	} else {
		ar = {px, ry, aw, h}
		ir = {px + aw, ry, iw, h}
	}
	acol := GITD_GREEN if side == .Ours else GITD_BLUE
	for pair in ([2]struct{ r: rl.Rectangle, label: string, col: rl.Color, accept: bool }{
		{ar, acc, acol, true}, {ir, ign, GITD_SUBDUED, false},
	}) {
		hover := ui_point_in(mp, pair.r)
		rl.DrawRectangleRec(pair.r, GITD_SEL if hover else GITD_HEADER)
		rl.DrawRectangleLinesEx(pair.r, 1, ui_with_alpha(pair.col, 120))
		col := pair.col
		if hover && !pair.accept { col = GITD_RED }
		rl.DrawTextEx(font, to_cstring(pair.label), {pair.r.x + 6, ry + (h - fs) * 0.5}, fs, CHAR_SPACING, col)
		if hover && clicked { _mr_click = {i, side, pair.accept, true} }
	}
}

@(private="file")
_mr_visual_col :: proc(s: string) -> int {
	col := 0
	for r in s {
		if r == '\t' { col += 4 - col % 4 } else if r != '\r' { col += 1 }
	}
	return col
}

@(private="file")
_mr_pos_at_visual_col :: proc(from, to, want: int) -> int {
	pos := from
	col := 0
	for pos < to && col < want {
		r, n := utf8.decode_rune(_mr.doc.text[pos:to])
		if r == '\t' { col += 4 - col % 4 } else { col += 1 }
		pos += max(n, 1)
	}
	return pos
}
