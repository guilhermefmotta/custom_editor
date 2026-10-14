package editor

// ===========================================================================
// Working tree panel (ticket #5) — id `working_tree`.
//
// Sections Conflicts / Staged / Unstaged / Untracked (with counts) built from
// e.git_mgr.current; stage/unstage per file, per hunk and per section; stage
// all (never conflicted files) / unstage all (path-limited, keeps a merge);
// discard with confirmation; add to .gitignore; commit (Ctrl/Cmd+Enter),
// amend, undo last commit (soft reset). Clicking a file opens the whole-file
// diff (Diff mode of git_dialog.odin). Every git operation goes through the
// queue (git/worktree_ops.odin); after each one the status is refreshed.
//
// Opened by "Open Git panel" (palette "Git"), "Git: Working Tree" and
// Ctrl/Cmd+Shift+G. Pure row/section logic: working_tree_model.odin.
// ===========================================================================

import "base:runtime"
import "core:fmt"
import "core:strings"
import git "./git"
import rl "vendor:raylib"

WORKING_TREE_ID :: "working_tree"

@(init)
_working_tree_register :: proc "contextless" () {
	ui_register_panel(Ui_Panel{
		id           = WORKING_TREE_ID,
		title        = "Working Tree",
		priority     = 60,
		layer        = .Overlay,
		draw         = _wt_draw,
		input        = _wt_input,
		update       = _wt_update,
		on_open      = _wt_on_open,
		on_close     = _wt_on_close,
		command      = "Git: Working Tree",
		command_desc = "Stage, unstage, discard and commit changes",
		shortcut     = {key = .G, mods = {.Ctrl, .Shift}},
	})
	ui_register_command(Command{"Git: Stage All", "Stage every change except conflicted files", _wt_cmd_stage_all, nil})
	ui_register_command(Command{"Git: Unstage All", "Unstage everything (keeps an in-progress merge)", _wt_cmd_unstage_all, nil})
	ui_register_command(Command{"Git: Undo Last Commit", "Soft reset to the parent commit (changes stay staged)", _wt_cmd_undo, nil})
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

_Wt_Confirm_Action :: enum u8 { None, Discard, Undo_Commit, Abort_Merge }

_Wt_Hunk_View :: struct {
	header, patch, preview: string, // owned
	added, removed: int,
}

_Wt_State :: struct {
	e:            ^Editor,
	nav:          Ui_List_Nav,
	vis:          int,
	list_rect:    rl.Rectangle,
	focus_commit: bool,
	commit_buf:   [dynamic]u8,
	commit_sel_all: bool,
	amend:        bool,

	confirm:        Ui_Confirm,
	confirm_action: _Wt_Confirm_Action,
	confirm_path:   string, // owned
	confirm_section: git.Wt_Section,
	menu:           Ui_Menu,

	// Expanded file (hunk rows under it)
	exp_path:    string, // owned; "" = none
	exp_section: git.Wt_Section,
	hunks:       [dynamic]_Wt_Hunk_View,

	// Repo state (operation, unborn) — refreshed after ops and periodically
	operation:   git.Repo_Operation,
	unborn:      bool,
	state_job:   git.Job_Id,
	state_timer: f32,

	diff_path:    string, // owned, path of the last diff request
	diff_job:     git.Job_Id,

	pending_ops:  int,
	need_refresh: bool,
	msg:          string, // owned
	msg_ok:       bool,
}

@(private="file") _wt: _Wt_State

// ---------------------------------------------------------------------------
// Public procs (for other screens / integration)
// ---------------------------------------------------------------------------

working_tree_open :: proc(e: ^Editor) { ui_panel_open(e, WORKING_TREE_ID) }

// Enqueues stage all (skips conflicted files) and refreshes afterwards.
working_tree_stage_all :: proc(e: ^Editor) { _wt_op(e, .Stage_All, "stage all") }

// Enqueues unstage all (path-limited reset; an in-progress merge is kept).
working_tree_unstage_all :: proc(e: ^Editor) { _wt_op(e, .Unstage_All, "unstage all") }

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

@(private="file")
_wt_on_open :: proc(e: ^Editor) {
	_wt.e = e
	if e.git_mgr.root == "" {
		ui_banner_show("No git repository found", .Warning)
		ui_panel_close(e, WORKING_TREE_ID)
		return
	}
	_wt.nav = {}
	_wt.focus_commit = false
	_rep_key = .KEY_NULL
	git.git_manager_refresh_now(&e.git_mgr)
	_wt_request_state(e)
}

@(private="file")
_wt_on_close :: proc(e: ^Editor) {
	_wt_collapse()
	ui_confirm_destroy(&_wt.confirm)
	_wt.menu = {}
	if _wt.confirm_path != "" { delete(_wt.confirm_path); _wt.confirm_path = "" }
	// commit message survives close/reopen (like a draft)
}

@(fini)
_wt_fini :: proc "contextless" () {
	context = runtime.default_context()
	_wt_collapse()
	delete(_wt.hunks)
	delete(_wt.commit_buf)
	ui_confirm_destroy(&_wt.confirm)
	if _wt.confirm_path != "" { delete(_wt.confirm_path) }
	if _wt.msg != "" { delete(_wt.msg) }
	if _wt.diff_path != "" { delete(_wt.diff_path) }
	_wt = {}
}

@(private="file")
_wt_set_msg :: proc(ok: bool, msg: string) {
	if _wt.msg != "" { delete(_wt.msg) }
	_wt.msg = strings.clone(msg)
	_wt.msg_ok = ok
}

@(private="file")
_wt_collapse :: proc() {
	for h in _wt.hunks { delete(h.header); delete(h.patch); delete(h.preview) }
	clear(&_wt.hunks)
	if _wt.exp_path != "" { delete(_wt.exp_path); _wt.exp_path = "" }
}

// ---------------------------------------------------------------------------
// Async operations
// ---------------------------------------------------------------------------

@(private="file")
_wt_request_state :: proc(e: ^Editor) {
	if _wt.state_job != 0 { return }
	_wt.state_job = git.git_request_repo_state(&e.git_mgr.queue)
	git.git_on_done(&e.git_mgr.queue, _wt.state_job, proc(r: ^git.Git_Result, user: rawptr) {
		_wt.state_job = 0
		if st, ok := r.payload.(git.Repo_State); ok && r.status == .Done {
			_wt.operation = st.operation
			_wt.unborn    = st.unborn
		}
	})
}

// Generic op: label shown in the status line; user carries the op.
@(private="file")
_wt_op :: proc(e: ^Editor, op: git.Wt_Op, label: string, args: ..string) {
	if e.git_mgr.root == "" { return }
	_wt.e = e
	id := git.git_request_wt(&e.git_mgr.queue, op, ..args)
	if id == 0 { _wt_set_msg(false, "git queue unavailable"); return }
	_wt.pending_ops += 1
	_wt_set_msg(true, fmt.tprintf("%s...", label))
	git.git_on_done(&e.git_mgr.queue, id, _wt_on_op_done, rawptr(uintptr(op)))
}

@(private="file")
_wt_on_op_done :: proc(r: ^git.Git_Result, user: rawptr) {
	op := git.Wt_Op(uintptr(user))
	_wt.pending_ops = max(0, _wt.pending_ops - 1)
	_wt.need_refresh = true
	if r.status != .Done {
		_wt_set_msg(false, r.err if r.err != "" else "git operation failed")
		ui_banner_show(r.err if r.err != "" else "git operation failed", .Error)
		return
	}
	#partial switch op {
	case .Commit, .Amend:
		clear(&_wt.commit_buf)
		_wt.amend = false
		_wt.focus_commit = false
		_wt_set_msg(true, "amended" if op == .Amend else "committed")
	case .Undo_Commit:
		_wt_set_msg(true, "last commit undone (changes kept staged)")
	case .Stage_All:   _wt_set_msg(true, "staged all (conflicted files left as conflicts)")
	case .Unstage_All: _wt_set_msg(true, "unstaged all")
	case .Stage, .Apply_Hunk:     _wt_set_msg(true, "staged")
	case .Unstage, .Unapply_Hunk: _wt_set_msg(true, "unstaged")
	case .Discard:     _wt_set_msg(true, "discarded")
	case .Ignore:      _wt_set_msg(true, "added to .gitignore")
	case .Merge_Abort: _wt_set_msg(true, "merge aborted")
	case:              _wt_set_msg(true, "done")
	}
}

@(private="file")
_wt_request_hunks :: proc(e: ^Editor) {
	if _wt.exp_path == "" { return }
	id := git.git_request_wt(&e.git_mgr.queue, .Hunks, _wt.exp_path, "1" if _wt.exp_section == .Staged else "0")
	git.git_on_done(&e.git_mgr.queue, id, proc(r: ^git.Git_Result, user: rawptr) {
		c, ok := r.payload.(git.Git_Custom)
		if !ok { return }
		h := git.git_custom_as(c, git.Wt_Hunks)
		if h == nil || h.path != _wt.exp_path || h.staged != (_wt.exp_section == .Staged) { return } // stale
		for v in _wt.hunks { delete(v.header); delete(v.patch); delete(v.preview) }
		clear(&_wt.hunks)
		for x in h.hunks {
			append(&_wt.hunks, _Wt_Hunk_View{
				header = strings.clone(x.header), patch = strings.clone(x.patch),
				preview = strings.clone(x.preview), added = x.added, removed = x.removed,
			})
		}
	})
}

// Whole-file diff, fetched through the queue, then shown by git_dialog.
@(private="file")
_wt_open_diff :: proc(e: ^Editor, path: string) {
	_wt.e = e
	if _wt.diff_path != "" { delete(_wt.diff_path) }
	_wt.diff_path = strings.clone(path)
	_wt.diff_job = git.git_request_wt(&e.git_mgr.queue, .File_Diff, path)
	git.git_on_done(&e.git_mgr.queue, _wt.diff_job, proc(r: ^git.Git_Result, user: rawptr) {
		if r.id != _wt.diff_job { return } // superseded by a newer click
		_wt.diff_job = 0
		c, ok := r.payload.(git.Git_Custom)
		if !ok || _wt.e == nil || !ui_panel_is_open(WORKING_TREE_ID) {
			if r.status == .Failed { ui_banner_show(r.err, .Error) }
			return
		}
		raw := git.git_custom_as(c, git.Wt_File_Diff_Raw)
		if raw == nil { return }
		text := strings.clone(raw.text) // result arena dies after this callback
		fd := git.file_diff_all_added(text) if raw.all_added else git.parse_unified_diff(text)
		git_dialog_show_diff(_wt.e, _wt.diff_path, fd)
	})
}

@(private="file")
_wt_update :: proc(e: ^Editor, dt: f32) {
	if !ui_panel_is_open(WORKING_TREE_ID) { return }
	_wt.e = e
	if _wt.need_refresh {
		_wt.need_refresh = false
		git.git_manager_refresh_now(&e.git_mgr)
		_wt_request_state(e)
		_wt_request_hunks(e)
	}
	_wt.state_timer -= dt
	if _wt.state_timer <= 0 {
		_wt.state_timer = 4
		_wt_request_state(e)
	}
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

@(private="file")
_wt_cmd_stage_all :: proc(e: ^Editor, p: ^Palette) { palette_close(p); working_tree_stage_all(e) }

@(private="file")
_wt_cmd_unstage_all :: proc(e: ^Editor, p: ^Palette) { palette_close(p); working_tree_unstage_all(e) }

@(private="file")
_wt_cmd_undo :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	working_tree_open(e)
	_wt_ask(.Undo_Commit, "Undo last commit?", "HEAD moves back to its parent (soft reset). The commit's changes stay staged.", "Undo commit")
}

// ---------------------------------------------------------------------------
// Actions on the selection
// ---------------------------------------------------------------------------

@(private="file") _WT_MENU_STAGED    := []string{"Unstage", "Show hunks", "Open diff", "Discard changes...", "Add to .gitignore"}
@(private="file") _WT_MENU_UNSTAGED  := []string{"Stage", "Show hunks", "Open diff", "Discard changes...", "Add to .gitignore"}
@(private="file") _WT_MENU_UNTRACKED := []string{"Stage", "Open diff", "Delete file...", "Add to .gitignore"}
@(private="file") _WT_MENU_CONFLICT  := []string{"Resolve conflict", "Open diff", "Mark resolved (stage)"}
@(private="file") _WT_MENU_HUNK_ST   := []string{"Unstage hunk", "Open diff"}
@(private="file") _WT_MENU_HUNK_UN   := []string{"Stage hunk", "Open diff"}

@(private="file")
_wt_rows :: proc(e: ^Editor) -> []Wt_Row {
	return wt_build_rows(e.git_mgr.current.entries[:], _wt.exp_path, _wt.exp_section, len(_wt.hunks))
}

@(private="file")
_wt_selected :: proc(rows: []Wt_Row) -> (Wt_Row, bool) {
	if _wt.nav.selected < 0 || _wt.nav.selected >= len(rows) { return {}, false }
	return rows[_wt.nav.selected], true
}

@(private="file")
_wt_ask :: proc(action: _Wt_Confirm_Action, title, message, confirm: string, path := "", section := git.Wt_Section.Unstaged) {
	_wt.confirm_action = action
	if _wt.confirm_path != "" { delete(_wt.confirm_path); _wt.confirm_path = "" }
	if path != "" { _wt.confirm_path = strings.clone(path) }
	_wt.confirm_section = section
	ui_confirm_open(&_wt.confirm, title, message, confirm = confirm, danger = true)
}

@(private="file")
_wt_on_confirm :: proc(e: ^Editor, r: Ui_Confirm_Result) {
	if r == .None { return }
	action := _wt.confirm_action
	_wt.confirm_action = .None
	if r != .Confirm { return }
	switch action {
	case .None:
	case .Discard:     _wt_op(e, .Discard, "discarding", _wt.confirm_path, fmt.tprintf("%d", int(_wt.confirm_section)))
	case .Undo_Commit: _wt_op(e, .Undo_Commit, "undoing last commit")
	case .Abort_Merge: _wt_op(e, .Merge_Abort, "aborting merge")
	}
}

@(private="file")
_wt_toggle_stage :: proc(e: ^Editor, row: Wt_Row) {
	entries := e.git_mgr.current.entries[:]
	switch row.kind {
	case .Header:
		switch row.section {
		case .Conflicts: _wt_set_msg(false, "resolve conflicts first (Enter on the file)")
		case .Staged:    _wt_op(e, .Unstage_All, "unstage all")
		case .Unstaged, .Untracked:
			paths := wt_section_paths(entries, row.section)
			if len(paths) > 0 { _wt_op(e, .Stage, "staging", ..paths) }
		}
	case .File:
		en := entries[row.entry]
		if row.section == .Staged {
			if en.old_path != "" { _wt_op(e, .Unstage, "unstaging", en.path, en.old_path) } else { _wt_op(e, .Unstage, "unstaging", en.path) }
		} else {
			_wt_op(e, .Stage, "staging", en.path) // conflicted: refused while it has markers
		}
	case .Hunk:
		if row.hunk < 0 || row.hunk >= len(_wt.hunks) { return }
		op := git.Wt_Op.Unapply_Hunk if row.section == .Staged else git.Wt_Op.Apply_Hunk
		_wt_op(e, op, "applying hunk", _wt.hunks[row.hunk].patch)
	}
}

@(private="file")
_wt_discard :: proc(e: ^Editor, row: Wt_Row) {
	if row.kind != .File { _wt_set_msg(false, "select a file to discard"); return }
	en := e.git_mgr.current.entries[row.entry]
	switch row.section {
	case .Conflicts:
		_wt_set_msg(false, "conflicted file: resolve it or abort the merge")
	case .Untracked:
		_wt_ask(.Discard, "Delete untracked file?", fmt.tprintf("%s will be deleted from disk. This cannot be undone.", en.path), "Delete", en.path, .Untracked)
	case .Unstaged:
		_wt_ask(.Discard, "Discard changes?", fmt.tprintf("Unstaged changes in %s will be lost.", en.path), "Discard", en.path, .Unstaged)
	case .Staged:
		_wt_ask(.Discard, "Discard all changes?", fmt.tprintf("%s will be reset to HEAD (staged and unstaged changes are lost).", en.path), "Discard", en.path, .Staged)
	}
}

@(private="file")
_wt_expand :: proc(e: ^Editor, row: Wt_Row) {
	if row.kind == .Hunk { return }
	if row.kind != .File || (row.section != .Staged && row.section != .Unstaged) {
		_wt_set_msg(false, "hunks are available for staged/unstaged files")
		return
	}
	path := e.git_mgr.current.entries[row.entry].path
	if _wt.exp_path == path && _wt.exp_section == row.section { _wt_collapse(); return }
	_wt_collapse()
	_wt.exp_path    = strings.clone(path)
	_wt.exp_section = row.section
	_wt_request_hunks(e)
}

@(private="file")
_wt_resolve :: proc(e: ^Editor, path: string) {
	merge_resolver_open_file(e, path) // opens the resolver on this file
}

// Enter / click: conflicts go to the resolver (Enter) — everything else
// (and clicks) opens the whole-file diff.
@(private="file")
_wt_activate :: proc(e: ^Editor, row: Wt_Row, from_click: bool) {
	if row.kind == .Header { return }
	path := e.git_mgr.current.entries[row.entry].path
	if row.section == .Conflicts && !from_click { _wt_resolve(e, path); return }
	_wt_open_diff(e, path)
}

@(private="file")
_wt_commit :: proc(e: ^Editor) {
	msg := string(_wt.commit_buf[:])
	op, err := wt_commit_plan(msg, _wt.amend, _wt.operation == .Merging)
	if err != "" { _wt_set_msg(false, err); return }
	_wt_op(e, op, "committing", msg)
}

@(private="file")
_wt_toggle_amend :: proc(e: ^Editor) {
	_wt.amend = !_wt.amend
	if !_wt.amend || len(_wt.commit_buf) > 0 { return }
	id := git.git_request_wt(&e.git_mgr.queue, .Last_Message)
	git.git_on_done(&e.git_mgr.queue, id, proc(r: ^git.Git_Result, user: rawptr) {
		out, ok := r.payload.(git.Command_Output)
		if ok && _wt.amend && len(_wt.commit_buf) == 0 { append(&_wt.commit_buf, out.output) }
	})
}

@(private="file")
_wt_open_menu :: proc(e: ^Editor, row: Wt_Row, pos: rl.Vector2) {
	items: []string
	switch row.kind {
	case .Header: return
	case .Hunk:   items = _WT_MENU_HUNK_ST if row.section == .Staged else _WT_MENU_HUNK_UN
	case .File:
		switch row.section {
		case .Conflicts: items = _WT_MENU_CONFLICT
		case .Staged:    items = _WT_MENU_STAGED
		case .Unstaged:  items = _WT_MENU_UNSTAGED
		case .Untracked: items = _WT_MENU_UNTRACKED
		}
	}
	ui_menu_open(&_wt.menu, pos, items)
}

@(private="file")
_wt_on_menu :: proc(e: ^Editor, i: int) {
	if i < 0 || i >= len(_wt.menu.items) { return }
	row, ok := _wt_selected(_wt_rows(e))
	if !ok { return }
	switch _wt.menu.items[i] {
	case "Stage", "Unstage", "Stage hunk", "Unstage hunk", "Mark resolved (stage)": _wt_toggle_stage(e, row)
	case "Show hunks":         _wt_expand(e, row)
	case "Open diff":          _wt_activate(e, row, true)
	case "Resolve conflict":   _wt_activate(e, row, false)
	case "Discard changes...", "Delete file...": _wt_discard(e, row)
	case "Add to .gitignore":  _wt_op(e, .Ignore, "adding to .gitignore", e.git_mgr.current.entries[row.entry].path)
	}
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

@(private="file")
_wt_input :: proc(e: ^Editor) -> bool {
	_wt.e = e
	// Modal: always consumes input. Topmost sub-widgets first.
	if _wt.confirm.open { _wt_on_confirm(e, ui_confirm_handle_input(&_wt.confirm)); return true }
	if _wt.menu.open {
		if i := ui_menu_handle_input(&_wt.menu); i >= 0 { _wt_on_menu(e, i) }
		return true
	}
	if wt_is_commit_chord(ctrl(), rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER)) {
		_wt_commit(e)
		return true
	}
	if ctrl() && shift() && rl.IsKeyPressed(.A) { _wt_toggle_amend(e); return true }

	if _wt.focus_commit {
		if rl.IsKeyPressed(.ESCAPE) || rl.IsKeyPressed(.TAB) { _wt.focus_commit = false; return true }
		if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) { append(&_wt.commit_buf, '\n'); return true }
		text_input_handle(&_wt.commit_buf, &_wt.commit_sel_all)
		return true
	}

	rows := _wt_rows(e)
	ui_list_handle_nav(&_wt.nav, len(rows), max(1, _wt.vis), _wt.list_rect)
	if ctrl() || alt() { return true } // no editor shortcuts underneath a modal panel

	if rl.IsKeyPressed(.ESCAPE) { ui_panel_close(e, WORKING_TREE_ID); return true }
	if rl.IsKeyPressed(.TAB) || rl.IsKeyPressed(.C) { _wt.focus_commit = true; return true }
	if rl.IsKeyPressed(.R) || rl.IsKeyPressed(.F5) { _wt.need_refresh = true; _wt_set_msg(true, "refreshing..."); return true }
	if rl.IsKeyPressed(.A) {
		if shift() { working_tree_unstage_all(e) } else { working_tree_stage_all(e) }
		return true
	}
	if rl.IsKeyPressed(.U) {
		_wt_ask(.Undo_Commit, "Undo last commit?", "HEAD moves back to its parent (soft reset). The commit's changes stay staged.", "Undo commit")
		return true
	}
	if rl.IsKeyPressed(.B) { git_dialog_open_branch_picker(e); return true }
	if _wt.operation == .Merging {
		if rl.IsKeyPressed(.F) { _wt_commit(e); return true } // empty message = git's merge message
		if rl.IsKeyPressed(.Z) {
			_wt_ask(.Abort_Merge, "Abort merge?", "The merge is cancelled and the working tree goes back to before it started.", "Abort merge")
			return true
		}
	}

	row, ok := _wt_selected(rows)
	if !ok { return true }
	switch {
	case rl.IsKeyPressed(.S) || rl.IsKeyPressed(.SPACE):                 _wt_toggle_stage(e, row)
	case rl.IsKeyPressed(.X) || rl.IsKeyPressed(.DELETE):                _wt_discard(e, row)
	case rl.IsKeyPressed(.I) && row.kind == .File:
		_wt_op(e, .Ignore, "adding to .gitignore", e.git_mgr.current.entries[row.entry].path)
	case rl.IsKeyPressed(.H) || rl.IsKeyPressed(.RIGHT):                 _wt_expand(e, row)
	case rl.IsKeyPressed(.LEFT):                                         _wt_collapse()
	case rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER):          _wt_activate(e, row, false)
	case rl.IsKeyPressed(.D):                                            _wt_activate(e, row, true)
	case rl.IsKeyPressed(.M) && row.kind == .File && row.section == .Conflicts:
		_wt_resolve(e, e.git_mgr.current.entries[row.entry].path)
	}
	return true
}

// ---------------------------------------------------------------------------
// Draw
// ---------------------------------------------------------------------------

WT_COMMIT_LINES :: 4

@(private="file")
_wt_draw :: proc(e: ^Editor, font: rl.Font, sw, sh: f32) {
	if e.git_dialog.visible { return } // diff / merge view on top (drawn earlier by the renderer)
	_wt.e = e
	m    := &e.git_mgr
	busy := _wt.confirm.open || _wt.menu.open
	fs   := FONT_SIZE - 1
	ref  := rl.MeasureTextEx(font, "M", fs, CHAR_SPACING)
	line_h := ref.y + 3

	W := min(f32(920), sw - 60)
	H := sh - 60
	commit_h := GITD_SECTION_H + f32(WT_COMMIT_LINES) * line_h + 10 + 30 + 8
	rl.DrawRectangle(0, 0, i32(sw), i32(sh), {0, 0, 0, 120})
	px, py := dlg_begin((sw - W) * 0.5, (sh - H) * 0.5, W, H, GITD_BG, GITD_BORDER)

	// Header
	merging := _wt.operation == .Merging
	rl.DrawRectangleV({px, py}, {W, GITD_HEADER_H}, GITD_HEADER)
	op_label := ""
	if _wt.operation != .Clean { op_label = fmt.tprintf("  [%s]", strings.to_upper(git.repo_operation_name(_wt.operation), context.temp_allocator)) }
	title := fmt.tprintf(" Working Tree   %s%s", m.current.branch if m.current.branch != "" else "(no branch)", op_label)
	ui_text(font, title, px + 6, py, GITD_HEADER_H, FONT_SIZE, GITD_ORANGE if _wt.operation != .Clean else GITD_BLUE, px + W - 120)
	if m.refreshing || _wt.pending_ops > 0 {
		ind := "working..." if _wt.pending_ops > 0 else "refreshing..."
		iw := ui_text_w(font, ind, FONT_SIZE - 2)
		ui_text(font, ind, px + W - iw - 12, py, GITD_HEADER_H, FONT_SIZE - 2, GITD_SUBDUED, px + W)
	}

	// File list
	rows := _wt_rows(e)
	list_r := rl.Rectangle{px, py + GITD_HEADER_H + 2, W, H - GITD_HEADER_H - 2 - commit_h - GITD_FOOTER_H}
	row_h := GITD_ENTRY_H
	vis := max(1, int(list_r.height / row_h))
	_wt.vis = vis
	_wt.list_rect = list_r
	ui_list_clamp(&_wt.nav, len(rows), vis)

	entries := m.current.entries[:]
	for vi in 0 ..< vis {
		idx := _wt.nav.scroll + vi
		if idx >= len(rows) { break }
		row := rows[idx]
		y   := list_r.y + f32(vi) * row_h
		ty  := y + (row_h - ref.y) * 0.5
		sel := idx == _wt.nav.selected
		switch row.kind {
		case .Header:
			rl.DrawRectangleV({px, y}, {W, row_h}, GITD_SECTION)
			col := GITD_RED if row.section == .Conflicts else GITD_SUBDUED
			ui_text(font, fmt.tprintf("%s (%d)", WT_SECTION_TITLES[row.section], row.count), px + 10, y, row_h, FONT_SIZE - 2, col, px + W)
		case .File, .Hunk:
		}
		if sel {
			rl.DrawRectangleV({px, y}, {W, row_h}, GITD_SEL if !_wt.focus_commit else ui_with_alpha(GITD_SEL, 120))
			rl.DrawRectangleV({px, y}, {3, row_h}, GITD_BLUE)
		}
		if row.kind == .Header { continue }
		en := entries[row.entry]
		if row.kind == .File {
			xy_col := GITD_ORANGE
			switch row.section {
			case .Conflicts: xy_col = GITD_RED
			case .Staged:    xy_col = GITD_GREEN
			case .Unstaged, .Untracked:
			}
			code := en.index if row.section == .Staged else en.worktree
			if row.section == .Conflicts { code = 'U' }
			rl.DrawTextEx(font, to_cstring(fmt.tprintf("%c", rune(code))), {px + 14, ty}, fs, CHAR_SPACING, xy_col)
			expanded := _wt.exp_path == en.path && _wt.exp_section == row.section
			can_expand := row.section == .Staged || row.section == .Unstaged
			if can_expand {
				rl.DrawTextEx(font, "v" if expanded else ">", {px + 30, ty}, fs - 2, CHAR_SPACING, GITD_SUBDUED)
			}
			label := en.path
			if en.old_path != "" && row.section == .Staged { label = fmt.tprintf("%s -> %s", en.old_path, en.path) }
			dlg_text(font, label, px + 46, ty, fs, CHAR_SPACING, GITD_TEXT, px + W - 110, 0)
			if row.section == .Conflicts {
				ui_text(font, "conflict", px + W - 100, y, row_h, FONT_SIZE - 2, GITD_RED, px + W)
			}
		} else if row.hunk < len(_wt.hunks) {
			h := _wt.hunks[row.hunk]
			counts := fmt.tprintf("+%d -%d", h.added, h.removed)
			rl.DrawTextEx(font, to_cstring(counts), {px + 60, ty}, fs - 1, CHAR_SPACING, GITD_SUBDUED)
			cw := ui_text_w(font, counts, fs - 1)
			hdr := h.header
			if j := strings.index(hdr[min(2, len(hdr)):], "@@"); j >= 0 { hdr = hdr[:j + 4] }
			rl.DrawTextEx(font, to_cstring(hdr), {px + 70 + cw, ty}, fs - 1, CHAR_SPACING, GITD_BLUE)
			hw := ui_text_w(font, hdr, fs - 1)
			dlg_text(font, _gitd_expand_tabs(h.preview), px + 82 + cw + hw, ty, fs - 1, CHAR_SPACING, GITD_SUBDUED, px + W, 10)
		}
	}
	if len(rows) == 0 {
		ui_text(font, "No changes — working tree clean", px + 16, list_r.y + 6, row_h, fs, GITD_SUBDUED, px + W)
	}
	if len(rows) > vis {
		th := list_r.height * f32(vis) / f32(len(rows))
		tyy := list_r.y + list_r.height * f32(_wt.nav.scroll) / f32(len(rows))
		rl.DrawRectangleRec({px + W - 4, tyy, 3, th}, GITD_BORDER)
	}

	// Mouse on the list
	mp := rl.GetMousePosition()
	if !busy && ui_point_in(mp, list_r) {
		left, right := rl.IsMouseButtonPressed(.LEFT), rl.IsMouseButtonPressed(.RIGHT)
		if left || right {
			ri := ui_list_row_at(_wt.nav, list_r.y, row_h, mp.y, len(rows), vis)
			if ri >= 0 {
				_wt.nav.selected = ri
				_wt.focus_commit = false
				row := rows[ri]
				if right {
					_wt_open_menu(e, row, mp)
				} else if row.kind == .File {
					// the expand arrow toggles hunks, anywhere else opens the diff
					if mp.x < px + 44 && (row.section == .Staged || row.section == .Unstaged) {
						_wt_expand(e, row)
					} else {
						_wt_activate(e, row, true)
					}
				}
			}
		}
	}

	// Commit area
	cy := list_r.y + list_r.height
	rl.DrawLineV({px, cy}, {px + W, cy}, GITD_BORDER)
	cy += 2
	label := "Commit message  (Ctrl/Cmd+Enter to commit, Enter = new line)"
	if merging { label = "Merge commit message  (empty = git's merge message; Ctrl/Cmd+Enter or F to finalize)" }
	ui_text(font, label, px + 10, cy, GITD_SECTION_H, FONT_SIZE - 3, GITD_SUBDUED, px + W)
	cy += GITD_SECTION_H
	box := rl.Rectangle{px + 8, cy, W - 16, f32(WT_COMMIT_LINES) * line_h + 8}
	rl.DrawRectangleRec(box, GITD_HEADER)
	rl.DrawRectangleLinesEx(box, 1, GITD_BLUE if _wt.focus_commit else GITD_BORDER)
	if !busy && rl.IsMouseButtonPressed(.LEFT) && ui_point_in(mp, box) { _wt.focus_commit = true }
	msg := string(_wt.commit_buf[:])
	if msg == "" {
		ph := "Amend: empty keeps the previous message" if _wt.amend else "Commit message... (Tab or C to focus)"
		rl.DrawTextEx(font, to_cstring(ph), {box.x + 6, box.y + 4}, fs, CHAR_SPACING, GITD_SUBDUED)
	}
	lines := strings.split(msg, "\n", context.temp_allocator)
	first := max(0, len(lines) - WT_COMMIT_LINES)
	last_x := box.x + 6
	last_y := box.y + 4
	if _wt.commit_sel_all && msg != "" { rl.DrawRectangleRec(box, ui_with_alpha(GITD_BLUE, 40)) }
	for li in first ..< len(lines) {
		ly := box.y + 4 + f32(li - first) * line_h
		if lines[li] != "" { dlg_text(font, lines[li], box.x + 6, ly, fs, CHAR_SPACING, GITD_TEXT, box.x + box.width, 6) }
		last_x = box.x + 6 + ui_text_w(font, lines[li], fs)
		last_y = ly
	}
	if _wt.focus_commit {
		rl.DrawLineV({min(last_x + 1, box.x + box.width - 4), last_y}, {min(last_x + 1, box.x + box.width - 4), last_y + ref.y}, GITD_BLUE)
	}
	cy += box.height + 6

	// Buttons: [x] Amend   Commit   Undo last commit      status message
	bx := px + 8
	amend_lbl := "[x] Amend" if _wt.amend else "[ ] Amend"
	aw := ui_button_w(font, amend_lbl)
	if ui_button(font, {bx, cy, aw, 26}, amend_lbl, false, false) && !busy { _wt_toggle_amend(e) }
	bx += aw + 8
	commit_lbl := "Amend" if _wt.amend else ("Commit merge" if merging else "Commit")
	cw := ui_button_w(font, commit_lbl)
	if ui_button(font, {bx, cy, cw, 26}, commit_lbl, false, true) && !busy { _wt_commit(e) }
	bx += cw + 8
	undo_lbl := "Undo last commit"
	uw := ui_button_w(font, undo_lbl)
	if !_wt.unborn {
		if ui_button(font, {bx, cy, uw, 26}, undo_lbl, false, false) && !busy {
			_wt_ask(.Undo_Commit, "Undo last commit?", "HEAD moves back to its parent (soft reset). The commit's changes stay staged.", "Undo commit")
		}
		bx += uw + 8
	}
	if _wt.msg != "" {
		ui_text(font, _wt.msg, bx + 8, cy, 26, FONT_SIZE - 2, GITD_GREEN if _wt.msg_ok else GITD_RED, px + W)
	}

	// Footer
	fy := py + H - GITD_FOOTER_H
	rl.DrawLineV({px, fy}, {px + W, fy}, GITD_BORDER)
	hint := "S stage/unstage  A stage all  Shift+A unstage all  H hunks  X discard  I ignore  Enter/click diff  U undo commit  B merge branch  Tab message  Ctrl+Shift+A amend  Esc close"
	if merging { hint = "Enter/M resolve conflict  F finalize merge  Z abort merge  S stage  A stage all (skips conflicts)  Shift+A unstage all  click diff  Esc close" }
	ui_text(font, hint, px + 10, fy, GITD_FOOTER_H, FONT_SIZE - 4, GITD_SUBDUED, px + W)
	dlg_end()

	if i := ui_menu_draw(&_wt.menu, font, sw, sh); i >= 0 { _wt_on_menu(e, i) }
	_wt_on_confirm(e, ui_confirm_draw(&_wt.confirm, font, sw, sh))
}
