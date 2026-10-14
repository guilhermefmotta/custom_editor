package editor

// Refs sidebar (ticket #6): local branches (ahead/behind), remote branches
// grouped by remote, tags, stashes, submodules and reflog, with per-section
// search and context-menu operations. Panel id "sidebar", toggled by
// "Git: Branches & Refs Sidebar" / Ctrl+Alt+B.
//
// Everything git goes through the queue (git/refs_ops.odin). The pure model
// (rows, actions) is in sidebar_model.odin.
//
// Keys (while focused — the sidebar takes focus on open and on click inside,
// gives it back to the editor on a click outside):
//   Up/Down PgUp/PgDn Home/End  move       Enter   checkout / toggle section
//   Space   show in commit graph           Menu or Shift+F10  context menu
//   Delete  delete                         type    filter the selected section
//   F5      refresh                        Esc     clear filter, then close
//
// Integration points:
//   sidebar_on_branch_activate(e, name) — single click on a branch/tag
//   sidebar_refresh(e)                  — reload refs (e.g. after a fetch)

import "core:fmt"
import "core:strings"
import "base:runtime"
import rl "vendor:raylib"
import "git"

SIDEBAR_ID :: "sidebar"
SIDEBAR_W  :: f32(340)
SIDEBAR_DOUBLE_CLICK :: 0.35

@(init)
_sidebar_register :: proc "contextless" () {
	repos_register_switch_hook(_sb_on_repo_switch) // ADR 0014
	ui_register_panel(Ui_Panel{
		id       = SIDEBAR_ID,
		title    = "Branches & Refs",
		priority = 40,
		layer    = .Overlay,
		draw     = _sb_draw,
		input    = _sb_input,
		update   = _sb_update,
		on_open  = _sb_on_open,
		on_close = _sb_on_close,
		command  = "Git: Branches & Refs Sidebar",
		command_desc = "Branches, remotes, tags, stashes, submodules and reflog",
		shortcut = {key = .B, mods = {.Ctrl, .Alt}},
	})
}

@(fini)
_sidebar_fini :: proc "contextless" () {
	context = runtime.default_context()
	_sb_free_all()
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

@(private="file")
_Sb_Confirm_Kind :: enum u8 { None, Blocked_Checkout, Delete_Branch, Force_Delete, Delete_Remote_Branch, Delete_Tag, Drop_Stash }

@(private="file")
_Sb_Prompt_Kind :: enum u8 { None, New_Branch, Rename, New_Tag }

@(private="file")
_Sb_Prompt :: struct {
	kind:     _Sb_Prompt_Kind,
	title:    string, // literal
	labels:   [2]string,
	fields:   [2][dynamic]u8,
	n_fields: int,
	focus:    int, // 0..n_fields-1 = field, n_fields = checkbox
	sel_all:  bool,
	has_check: bool,
	check:    bool,
	check_label: string,
	subject:  string, // owned: branch being renamed / start point
}

@(private="file")
_Sidebar :: struct {
	snap_id:    git.Job_Id, // displayed snapshot (kept alive until replaced)
	pending_id: git.Job_Id, // snapshot being loaded
	op_id:      git.Job_Id, // operation in flight
	op:         git.Refs_Op, // last op (owned strings) — retried as smart/force/force-delete
	view:       Sidebar_View,
	rows:       [dynamic]Sidebar_Row,
	nav:        Ui_List_Nav,
	vis_rows:   int,
	focused:    bool,
	menu:       Ui_Menu,
	menu_row:   Sidebar_Row,
	menu_acts:  [SIDEBAR_MAX_ACTIONS]Sidebar_Action,
	menu_n:     int,
	menu_labels: [SIDEBAR_MAX_ACTIONS]string,
	confirm:    Ui_Confirm,
	confirm_kind: _Sb_Confirm_Kind,
	confirm_op: git.Refs_Op, // owned strings
	prompt:     _Sb_Prompt,
	last_click_row: int,
	last_click_t:   f64,
	pending_activate: string, // owned; fires after the double-click window
	pending_activate_t: f64,
	err:        string, // owned, snapshot error
}

@(private="file") _sb: _Sidebar = {last_click_row = -1}

// Last branch passed to sidebar_on_branch_activate (owned by the sidebar).
sidebar_active_branch: string

// Active repository changed: the branch filter belonged to the old one.
@(private="file")
_sb_on_repo_switch :: proc(e: ^Editor, phase: Repo_Switch_Phase) {
	if phase == .Leaving && sidebar_active_branch != "" {
		delete(sidebar_active_branch)
		sidebar_active_branch = ""
	}
}

// ---------------------------------------------------------------------------
// Public procs
// ---------------------------------------------------------------------------

// Clicking a branch (or tag) filters the commit graph by it.
sidebar_on_branch_activate :: proc(e: ^Editor, name: string) {
	if name == "" { return }
	if sidebar_active_branch != "" { delete(sidebar_active_branch) }
	sidebar_active_branch = strings.clone(name)
	// Opens the graph filtered by this branch (no editor = just record it)
	if e != nil { commit_graph_show_branch(e, name) }
}

// Reload every list (no-op without a repository).
sidebar_refresh :: proc(e: ^Editor) {
	if e == nil || e.git_mgr.root == "" { return }
	q := &e.git_mgr.queue
	if _sb.pending_id != 0 { git.git_release(q, _sb.pending_id) }
	_sb.pending_id = git.git_request_refs_snapshot(q)
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

@(private="file")
_sb_on_open :: proc(e: ^Editor) {
	_sb.focused = true
	sidebar_refresh(e)
}

@(private="file")
_sb_on_close :: proc(e: ^Editor) {
	if e != nil {
		q := &e.git_mgr.queue
		if _sb.snap_id != 0    { git.git_release(q, _sb.snap_id) }
		if _sb.pending_id != 0 { git.git_release(q, _sb.pending_id) }
	}
	_sb.snap_id, _sb.pending_id = 0, 0
	clear(&_sb.rows)
	_sb.menu = {}
	ui_confirm_destroy(&_sb.confirm)
	_sb_prompt_close()
	// op_id stays: its result is still handled by _sb_update
}

@(private="file")
_sb_free_all :: proc() {
	sidebar_view_destroy(&_sb.view)
	delete(_sb.rows)
	_sb.rows = nil
	ui_confirm_destroy(&_sb.confirm)
	_sb_prompt_close()
	for &f in _sb.prompt.fields { delete(f); f = nil }
	_sb_op_free(&_sb.op)
	_sb_op_free(&_sb.confirm_op)
	if _sb.pending_activate != "" { delete(_sb.pending_activate); _sb.pending_activate = "" }
	if _sb.err != "" { delete(_sb.err); _sb.err = "" }
	if sidebar_active_branch != "" { delete(sidebar_active_branch); sidebar_active_branch = "" }
}

@(private="file")
_sb_op_clone :: proc(op: git.Refs_Op) -> git.Refs_Op {
	o := op
	o.name    = strings.clone(op.name)
	o.target  = strings.clone(op.target)
	o.message = strings.clone(op.message)
	return o
}

@(private="file")
_sb_op_free :: proc(op: ^git.Refs_Op) {
	delete(op.name); delete(op.target); delete(op.message)
	op^ = {}
}

@(private="file")
_sb_snap :: proc(e: ^Editor) -> ^git.Refs_Snapshot {
	if _sb.snap_id == 0 { return nil }
	c, st, _ := git.git_poll_as(&e.git_mgr.queue, _sb.snap_id, git.Git_Custom)
	if st != .Done || c == nil { return nil }
	return git.git_custom_as(c^, git.Refs_Snapshot)
}

@(private="file")
_sb_rebuild :: proc(e: ^Editor) {
	sidebar_build_rows(_sb_snap(e), &_sb.view, &_sb.rows)
	ui_list_clamp(&_sb.nav, len(_sb.rows), max(1, _sb.vis_rows))
}

@(private="file")
_sb_selected :: proc() -> (Sidebar_Row, bool) {
	if _sb.nav.selected < 0 || _sb.nav.selected >= len(_sb.rows) { return {}, false }
	return _sb.rows[_sb.nav.selected], true
}

// ---------------------------------------------------------------------------
// Update: snapshot arrival, op results, delayed single-click activation
// ---------------------------------------------------------------------------

@(private="file")
_sb_update :: proc(e: ^Editor, dt: f32) {
	if e.git_mgr.root == "" { return }
	q := &e.git_mgr.queue

	if _sb.pending_id != 0 {
		_, st, err := git.git_poll_as(q, _sb.pending_id, git.Git_Custom)
		#partial switch st {
		case .Done:
			if _sb.snap_id != 0 { git.git_release(q, _sb.snap_id) }
			_sb.snap_id, _sb.pending_id = _sb.pending_id, 0
			if _sb.err != "" { delete(_sb.err); _sb.err = "" }
			_sb_rebuild(e)
		case .Failed, .Unknown:
			if _sb.err != "" { delete(_sb.err) }
			_sb.err = strings.clone(err if err != "" else "could not read refs")
			git.git_release(q, _sb.pending_id)
			_sb.pending_id = 0
		}
	}

	if _sb.op_id != 0 {
		c, st, err := git.git_poll_as(q, _sb.op_id, git.Git_Custom)
		#partial switch st {
		case .Done:
			if r := git.git_custom_as(c^, git.Refs_Op_Result); r != nil { _sb_on_result(e, r) }
			git.git_release(q, _sb.op_id)
			_sb.op_id = 0
		case .Failed, .Unknown:
			ui_banner_show(fmt.tprintf("Git operation failed: %s", err), .Error)
			git.git_release(q, _sb.op_id)
			_sb.op_id = 0
		}
	}

	if _sb.pending_activate != "" && rl.GetTime() - _sb.pending_activate_t >= SIDEBAR_DOUBLE_CLICK {
		name := _sb.pending_activate
		_sb.pending_activate = ""
		sidebar_on_branch_activate(e, name)
		delete(name)
	}
}

@(private="file")
_sb_run :: proc(e: ^Editor, op: git.Refs_Op) {
	if e.git_mgr.root == "" { return }
	if _sb.op_id != 0 { ui_banner_show("A git operation is already running", .Warning); return }
	_sb_op_free(&_sb.op)
	_sb.op = _sb_op_clone(op)
	_sb.op_id = git.git_request_refs_op(&e.git_mgr.queue, op)
}

@(private="file")
_sb_on_result :: proc(e: ^Editor, r: ^git.Refs_Op_Result) {
	switch r.outcome {
	case .Ok:
		ui_banner_show(r.message, .Success)
	case .Failed:
		ui_banner_show(r.message, .Error, seconds = 8)
	case .Blocked_Local_Changes:
		if _sb.op.kind != .Checkout { ui_banner_show(r.message, .Error, seconds = 8); break }
		_sb_confirm(.Blocked_Checkout, _sb.op, "Local changes block checkout",
			fmt.tprintf("%s.\nSmart Checkout stashes them, switches and restores them.", r.message),
			confirm = "Smart Checkout", extra = "Force checkout")
	case .Conflicts:
		ui_banner_show(fmt.tprintf("%s — %d conflicted file(s)", r.message, len(r.conflicts)), .Warning, seconds = 8)
		ui_panel_open(e, "merge_resolver")
	case .Not_Merged:
		_sb_confirm(.Force_Delete, _sb.op, "Branch not fully merged",
			fmt.tprintf("%s. Delete it anyway? Its commits may be lost.", r.message), confirm = "Force delete", danger = true)
	}
	git.git_manager_refresh_now(e.git_mgr)
	sidebar_refresh(e)
}

// ---------------------------------------------------------------------------
// Confirm / prompt
// ---------------------------------------------------------------------------

@(private="file")
_sb_confirm :: proc(kind: _Sb_Confirm_Kind, op: git.Refs_Op, title, msg: string, confirm := "Confirm", extra := "", danger := false) {
	_sb_op_free(&_sb.confirm_op)
	_sb.confirm_op   = _sb_op_clone(op)
	_sb.confirm_kind = kind
	ui_confirm_open(&_sb.confirm, title, msg, confirm = confirm, extra = extra, danger = danger)
}

@(private="file")
_sb_on_confirm :: proc(e: ^Editor, res: Ui_Confirm_Result) {
	if res == .None { return }
	kind := _sb.confirm_kind
	_sb.confirm_kind = .None
	if res == .Cancel { return }
	op := _sb.confirm_op
	switch kind {
	case .None:
	case .Blocked_Checkout:
		op.kind = .Smart_Checkout if res == .Confirm else .Force_Checkout
		_sb_run(e, op)
	case .Delete_Branch:        op.kind = .Delete_Branch; op.flag = false; _sb_run(e, op)
	case .Force_Delete:         op.kind = .Delete_Branch; op.flag = true;  _sb_run(e, op)
	case .Delete_Remote_Branch: op.kind = .Delete_Remote_Branch; _sb_run(e, op)
	case .Delete_Tag:           op.kind = .Delete_Tag; _sb_run(e, op)
	case .Drop_Stash:           op.kind = .Stash_Drop; _sb_run(e, op)
	}
}

@(private="file")
_sb_prompt_open :: proc(kind: _Sb_Prompt_Kind, title: string, subject: string, initial := "") {
	_sb_prompt_close()
	p := &_sb.prompt
	p.kind    = kind
	p.title   = title
	p.subject = strings.clone(subject)
	p.focus   = 0
	p.sel_all = initial != ""
	for &f in p.fields { clear(&f) }
	append(&p.fields[0], initial)
	switch kind {
	case .None:
	case .New_Branch:
		p.n_fields = 1; p.labels = {"Branch name", ""}
		p.has_check = true; p.check = true; p.check_label = "Checkout after creating"
	case .Rename:
		p.n_fields = 1; p.labels = {"New name", ""}; p.has_check = false
	case .New_Tag:
		p.n_fields = 2; p.labels = {"Tag name", "Message (empty = lightweight tag)"}; p.has_check = false
	}
}

@(private="file")
_sb_prompt_close :: proc() {
	p := &_sb.prompt
	p.kind = .None
	if p.subject != "" { delete(p.subject); p.subject = "" }
}

@(private="file")
_sb_prompt_submit :: proc(e: ^Editor) {
	p := &_sb.prompt
	v0 := strings.trim_space(string(p.fields[0][:]))
	v1 := strings.trim_space(string(p.fields[1][:]))
	if v0 == "" { return }
	switch p.kind {
	case .None:
	case .New_Branch: _sb_run(e, {kind = .Create_Branch, name = v0, target = p.subject, flag = p.check})
	case .Rename:     _sb_run(e, {kind = .Rename_Branch, name = p.subject, target = v0})
	case .New_Tag:    _sb_run(e, {kind = .Create_Tag, name = v0, target = p.subject, message = v1})
	}
	_sb_prompt_close()
}

@(private="file")
_sb_prompt_input :: proc(e: ^Editor) {
	p := &_sb.prompt
	n := p.n_fields + (1 if p.has_check else 0)
	switch {
	case rl.IsKeyPressed(.ESCAPE): _sb_prompt_close()
	case rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER): _sb_prompt_submit(e)
	case rl.IsKeyPressed(.TAB):
		p.focus = ui_tabs_cycle(p.focus, n, -1 if shift() else 1)
		p.sel_all = false
	case p.focus >= p.n_fields:
		if rl.IsKeyPressed(.SPACE) { p.check = !p.check }
		for rl.GetCharPressed() != 0 {} // swallow typed chars
	case:
		text_input_handle(&p.fields[p.focus], &p.sel_all)
	}
}

@(private="file")
_sb_prompt_draw :: proc(e: ^Editor, font: rl.Font, sw, sh: f32) {
	p := &_sb.prompt
	if p.kind == .None { return }
	W     :: f32(460)
	FH    :: f32(28)
	BTN_H :: f32(30)
	size  := FONT_SIZE - 1
	h := 36 + 12 + f32(p.n_fields) * (size + 6 + FH + 10) + (30 if p.has_check else 0) + BTN_H + 24
	rl.DrawRectangle(0, 0, i32(sw), i32(sh), {0, 0, 0, 150})
	px, py := (sw - W) * 0.5, sh * 0.22
	rl.DrawRectangleRec({px + 4, py + 6, W, h}, {0, 0, 0, 80})
	rl.DrawRectangleRec({px, py, W, h}, BG)
	rl.DrawRectangleLinesEx({px, py, W, h}, 1, DIVIDER_COL)
	rl.DrawRectangleRec({px, py, W, 36}, STATUS_BG)
	ui_text(font, p.title, px + 14, py, 36, FONT_SIZE, ACCENT_COL, px + W)
	if p.subject != "" {
		ui_text(font, fmt.tprintf("from %s", p.subject), px + 14 + ui_text_w(font, p.title, FONT_SIZE) + 12, py, 36, FONT_SIZE - 3, LINENUM, px + W - 10)
	}
	mp := rl.GetMousePosition()
	y := py + 36 + 12
	for i in 0 ..< p.n_fields {
		ui_text(font, p.labels[i], px + 14, y, size + 6, size - 1, LINENUM, px + W)
		y += size + 6
		r := rl.Rectangle{px + 14, y, W - 28, FH}
		rl.DrawRectangleRec(r, STATUS_BG)
		rl.DrawRectangleLinesEx(r, 1, ACCENT_COL if p.focus == i else DIVIDER_COL)
		txt := string(p.fields[i][:])
		ty := r.y + (FH - size) * 0.5
		tw := ui_text_w(font, txt, size)
		if p.focus == i && p.sel_all && txt != "" { rl.DrawRectangleRec({r.x + 6, ty - 2, tw + 4, size + 4}, ui_with_alpha(ACCENT_COL, 60)) }
		dlg_text(font, txt, r.x + 8, ty, size, CHAR_SPACING, TEXT, r.x + r.width, 8)
		if p.focus == i { rl.DrawRectangleV({r.x + 8 + min(tw, r.width - 16), ty}, {2, size}, ACCENT_COL) }
		if rl.IsMouseButtonPressed(.LEFT) && ui_point_in(mp, r) { p.focus = i; p.sel_all = false }
		y += FH + 10
	}
	if p.has_check {
		box := rl.Rectangle{px + 14, y + 5, 16, 16}
		rl.DrawRectangleLinesEx(box, 1, ACCENT_COL if p.focus == p.n_fields else DIVIDER_COL)
		if p.check { rl.DrawRectangleRec({box.x + 4, box.y + 4, 8, 8}, ACCENT_COL) }
		row := rl.Rectangle{px + 14, y, W - 28, 26}
		ui_text(font, p.check_label, box.x + 24, y, 26, size - 1, TEXT, px + W)
		if rl.IsMouseButtonPressed(.LEFT) && ui_point_in(mp, row) { p.check = !p.check; p.focus = p.n_fields }
		y += 30
	}
	by := py + h - BTN_H - 14
	ok_label := "Create"
	if p.kind == .Rename { ok_label = "Rename" }
	okw := ui_button_w(font, ok_label)
	cw  := ui_button_w(font, "Cancel")
	if ui_button(font, {px + W - 14 - okw, by, okw, BTN_H}, ok_label, false, true) { _sb_prompt_submit(e); return }
	if ui_button(font, {px + W - 14 - okw - 10 - cw, by, cw, BTN_H}, "Cancel", false, false) { _sb_prompt_close() }
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

@(private="file")
_sb_do :: proc(e: ^Editor, a: Sidebar_Action, r: Sidebar_Row) {
	snap := _sb_snap(e)
	if snap == nil && a != .Refresh { return }
	name := sidebar_row_branch(snap, r) if snap != nil else ""
	switch a {
	case .Checkout:
		_sb_checkout(e, snap, r)
	case .Show_In_Graph:
		sidebar_on_branch_activate(e, name)
	case .New_Branch:
		_sb_prompt_open(.New_Branch, "New branch", sidebar_row_rev(snap, r))
	case .New_Tag:
		_sb_prompt_open(.New_Tag, "New tag", sidebar_row_rev(snap, r))
	case .Rename:
		_sb_prompt_open(.Rename, "Rename branch", name, initial = name)
	case .Delete_Branch:
		_sb_confirm(.Delete_Branch, {name = name}, "Delete branch?", fmt.tprintf("Branch %q will be deleted.", name), confirm = "Delete", danger = true)
	case .Delete_Remote_Branch:
		_sb_confirm(.Delete_Remote_Branch, {name = name}, "Delete remote branch?",
			fmt.tprintf("%q will be deleted on the remote (git push --delete).", name), confirm = "Delete", danger = true)
	case .Merge:
		_sb_run(e, {kind = .Merge, name = name})
	case .Rebase:
		_sb_run(e, {kind = .Rebase, name = name})
	case .Push:
		_sb_run(e, {kind = .Push, name = name})
	case .Delete_Tag:
		_sb_confirm(.Delete_Tag, {name = name}, "Delete tag?", fmt.tprintf("Tag %q will be deleted locally.", name), confirm = "Delete", danger = true)
	case .Stash_Apply:
		_sb_run(e, {kind = .Stash_Apply, index = snap.stashes[r.index].index})
	case .Stash_Pop:
		_sb_run(e, {kind = .Stash_Pop, index = snap.stashes[r.index].index})
	case .Stash_Drop:
		s := snap.stashes[r.index]
		_sb_confirm(.Drop_Stash, {index = s.index}, "Drop stash?", fmt.tprintf("%s (%s) will be deleted.", s.ref, s.message), confirm = "Drop", danger = true)
	case .Stash_Push:
		_sb_run(e, {kind = .Stash_Push})
	case .Copy_Hash:
		h := sidebar_row_hash(snap, r)
		if h != "" { rl.SetClipboardText(to_cstring(h)); ui_banner_show(fmt.tprintf("Copied %s", h)) }
	case .Refresh:
		sidebar_refresh(e)
	}
}

@(private="file")
_sb_checkout :: proc(e: ^Editor, snap: ^git.Refs_Snapshot, r: Sidebar_Row) {
	#partial switch r.kind {
	case .Local_Branch:
		b := snap.branches[r.index]
		if b.is_head { ui_banner_show(fmt.tprintf("Already on %s", b.name)); return }
		_sb_run(e, {kind = .Checkout, name = b.name})
	case .Remote_Branch:
		_sb_run(e, {kind = .Checkout, name = snap.branches[r.index].name, flag = true})
	}
}

@(private="file")
_sb_open_menu :: proc(e: ^Editor, r: Sidebar_Row, pos: rl.Vector2) {
	snap := _sb_snap(e)
	if snap == nil { return }
	acts := sidebar_menu_actions(snap, r, &_sb.menu_acts)
	_sb.menu_n = len(acts)
	for a, i in acts { _sb.menu_labels[i] = SIDEBAR_ACTION_LABELS[a] }
	_sb.menu_row = r
	ui_menu_open(&_sb.menu, pos, _sb.menu_labels[:_sb.menu_n])
}

@(private="file")
_sb_on_menu :: proc(e: ^Editor, i: int) {
	if i < 0 || i >= _sb.menu_n { return }
	_sb_do(e, _sb.menu_acts[i], _sb.menu_row)
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

@(private="file")
_sb_rect :: proc() -> rl.Rectangle {
	return {0, 0, SIDEBAR_W, f32(rl.GetScreenHeight())}
}

@(private="file")
_sb_input :: proc(e: ^Editor) -> bool {
	// Modal sub-widgets first
	if _sb.prompt.kind != .None { _sb_prompt_input(e); return true }
	if _sb.confirm.open { _sb_on_confirm(e, ui_confirm_handle_input(&_sb.confirm)); return true }
	if _sb.menu.open {
		if i := ui_menu_handle_input(&_sb.menu); i >= 0 { _sb_on_menu(e, i) }
		return true
	}

	over := ui_point_in(rl.GetMousePosition(), _sb_rect())
	if rl.IsMouseButtonPressed(.LEFT) || rl.IsMouseButtonPressed(.RIGHT) { _sb.focused = over }
	if !_sb.focused { return over }

	count := len(_sb.rows)
	vis := max(1, _sb.vis_rows)
	row, has := _sb_selected()
	sec := row.section if has else Sidebar_Section.Local

	switch {
	case rl.IsKeyPressed(.ESCAPE):
		if len(_sb.view.filters[sec]) > 0 {
			clear(&_sb.view.filters[sec]); _sb_rebuild(e); _sb_select_section(sec)
		} else {
			ui_panel_close(e, SIDEBAR_ID)
		}
	case rl.IsKeyPressed(.F5):
		sidebar_refresh(e)
	case rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER):
		if has { _sb_activate_row(e, row, true) }
	case rl.IsKeyPressed(.SPACE) && !ctrl():
		if has { sidebar_on_branch_activate(e, sidebar_row_branch(_sb_snap(e), row)) }
		for rl.GetCharPressed() != 0 {}
	case rl.IsKeyPressed(.DELETE):
		if has { _sb_delete_row(e, row) }
	case rl.IsKeyPressed(.MENU) || (shift() && rl.IsKeyPressed(.F10)):
		if has { _sb_open_menu(e, row, {SIDEBAR_W - 40, 60 + f32(_sb.nav.selected - _sb.nav.scroll) * UI_ROW_H}) }
	case ui_list_handle_nav(&_sb.nav, count, vis):
	case:
		sel_all := false
		if text_input_handle(&_sb.view.filters[sec], &sel_all) {
			_sb.view.collapsed[sec] = false
			_sb_rebuild(e)
			_sb_select_section(sec)
		}
	}
	return true
}

// Select the first item row (or header) of `sec` after a rebuild.
@(private="file")
_sb_select_section :: proc(sec: Sidebar_Section) {
	hdr := -1
	for r, i in _sb.rows {
		if r.section != sec { continue }
		if r.kind == .Section { hdr = i; continue }
		if r.kind != .Remote_Group && r.kind != .Empty { ui_list_set(&_sb.nav, i, len(_sb.rows), max(1, _sb.vis_rows)); return }
	}
	if hdr >= 0 { ui_list_set(&_sb.nav, hdr, len(_sb.rows), max(1, _sb.vis_rows)) }
}

@(private="file")
_sb_delete_row :: proc(e: ^Editor, r: Sidebar_Row) {
	snap := _sb_snap(e)
	if snap == nil { return }
	#partial switch r.kind {
	case .Local_Branch:  if !snap.branches[r.index].is_head { _sb_do(e, .Delete_Branch, r) }
	case .Remote_Branch: _sb_do(e, .Delete_Remote_Branch, r)
	case .Tag:           _sb_do(e, .Delete_Tag, r)
	case .Stash:         _sb_do(e, .Stash_Drop, r)
	}
}

// Enter / double click: checkout branches, toggle sections, apply stashes.
@(private="file")
_sb_activate_row :: proc(e: ^Editor, r: Sidebar_Row, keyboard: bool) {
	snap := _sb_snap(e)
	#partial switch r.kind {
	case .Section:
		_sb.view.collapsed[r.section] = !_sb.view.collapsed[r.section]
		_sb_rebuild(e)
	case .Local_Branch, .Remote_Branch:
		if snap != nil { _sb_checkout(e, snap, r) }
	case .Stash:
		if snap != nil { _sb_do(e, .Stash_Apply, r) }
	case .Tag:
		if snap != nil { sidebar_on_branch_activate(e, sidebar_row_branch(snap, r)) }
	}
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

@(private="file")
_sb_draw :: proc(e: ^Editor, font: rl.Font, sw, sh: f32) {
	HDR :: f32(52)
	FTR :: f32(24)
	busy := _sb.menu.open || _sb.confirm.open || _sb.prompt.kind != .None
	r := rl.Rectangle{0, 0, SIDEBAR_W, sh}
	rl.DrawRectangleRec({r.width, 0, 4, sh}, {0, 0, 0, 70}) // edge shadow
	rl.DrawRectangleRec(r, GITD_BG)
	rl.DrawRectangleRec({r.width - 1, 0, 1, sh}, _sb.focused ? ACCENT_COL : GITD_BORDER)

	// Header
	rl.DrawRectangleRec({0, 0, r.width - 1, HDR}, GITD_HEADER)
	ui_text(font, "Branches & Refs", 12, 2, 24, FONT_SIZE, ACCENT_COL, r.width - 10)
	snap := _sb_snap(e)
	sub: string
	switch {
	case e.git_mgr.root == "": sub = "no repository"
	case snap == nil && _sb.err != "": sub = _sb.err
	case snap == nil: sub = "loading..."
	case snap.state.detached: sub = fmt.tprintf("HEAD detached at %s", snap.state.head_hash[:min(7, len(snap.state.head_hash))])
	case snap.state.operation != .Clean: sub = fmt.tprintf("on %s · %s", snap.state.head_branch, git.repo_operation_name(snap.state.operation))
	case: sub = fmt.tprintf("on %s", snap.state.head_branch)
	}
	ui_text(font, sub, 12, 26, 22, FONT_SIZE - 3, GITD_SUBDUED, r.width - 30)
	if _sb.op_id != 0 || _sb.pending_id != 0 {
		ui_text(font, "...", r.width - 30, 2, 24, FONT_SIZE, GITD_YELLOW, r.width)
	}

	// Rows
	lr := rl.Rectangle{0, HDR, r.width - 1, sh - HDR - FTR}
	_sb.vis_rows = max(1, int(lr.height / UI_ROW_H))
	count := len(_sb.rows)
	ui_list_clamp(&_sb.nav, count, _sb.vis_rows)
	rl.BeginScissorMode(i32(lr.x), i32(lr.y), i32(lr.width), i32(lr.height))
	for vi in 0 ..< _sb.vis_rows {
		idx := _sb.nav.scroll + vi
		if idx >= count || snap == nil { break }
		_sb_draw_row(font, snap, _sb.rows[idx], {lr.x, lr.y + f32(vi) * UI_ROW_H, lr.width, UI_ROW_H}, idx == _sb.nav.selected)
	}
	if count > _sb.vis_rows {
		th := lr.height * f32(_sb.vis_rows) / f32(count)
		ty := lr.y + lr.height * f32(_sb.nav.scroll) / f32(count)
		rl.DrawRectangleRec({lr.x + lr.width - 3, ty, 3, th}, DIVIDER_COL)
	}
	rl.EndScissorMode()

	// Mouse
	if !busy && snap != nil { _sb_mouse(e, lr, count) }

	// Footer
	fy := sh - FTR
	rl.DrawRectangleRec({0, fy, r.width - 1, FTR}, GITD_HEADER)
	ui_text(font, "Enter checkout · Space graph · type filter · right-click menu", 10, fy, FTR, FONT_SIZE - 5, GITD_SUBDUED, r.width - 6)

	if i := ui_menu_draw(&_sb.menu, font, sw, sh); i >= 0 { _sb_on_menu(e, i) }
	_sb_on_confirm(e, ui_confirm_draw(&_sb.confirm, font, sw, sh))
	_sb_prompt_draw(e, font, sw, sh)
}

@(private="file")
_sb_mouse :: proc(e: ^Editor, lr: rl.Rectangle, count: int) {
	mp := rl.GetMousePosition()
	if !ui_point_in(mp, lr) { return }
	if wheel := rl.GetMouseWheelMove(); wheel != 0 {
		ui_list_scroll_by(&_sb.nav, wheel > 0 ? -3 : 3, count, _sb.vis_rows)
	}
	left, right := rl.IsMouseButtonPressed(.LEFT), rl.IsMouseButtonPressed(.RIGHT)
	if !left && !right { return }
	idx := ui_list_row_at(_sb.nav, lr.y, UI_ROW_H, mp.y, count, _sb.vis_rows)
	if idx < 0 { return }
	_sb.nav.selected = idx
	row := _sb.rows[idx]
	if right { _sb_open_menu(e, row, mp); return }

	now := rl.GetTime()
	double := idx == _sb.last_click_row && now - _sb.last_click_t < SIDEBAR_DOUBLE_CLICK
	_sb.last_click_row, _sb.last_click_t = idx, now
	if _sb.pending_activate != "" { delete(_sb.pending_activate); _sb.pending_activate = "" }
	switch {
	case row.kind == .Section:
		_sb_activate_row(e, row, false)
	case double:
		_sb.last_click_row = -1
		_sb_activate_row(e, row, false)
	case row.kind == .Local_Branch || row.kind == .Remote_Branch:
		// Single click filters the graph — delayed so a double click
		// (checkout) doesn't also open the graph
		_sb.pending_activate = strings.clone(sidebar_row_branch(_sb_snap(e), row))
		_sb.pending_activate_t = now
	}
}

@(private="file")
_sb_draw_row :: proc(font: rl.Font, snap: ^git.Refs_Snapshot, row: Sidebar_Row, r: rl.Rectangle, selected: bool) {
	size := FONT_SIZE - 2
	if selected {
		rl.DrawRectangleRec(r, _sb.focused ? GITD_SEL : ui_with_alpha(GITD_SEL, 140))
		rl.DrawRectangleRec({r.x, r.y, 3, r.height}, ACCENT_COL)
	}
	x := r.x + 10 + f32(row.depth) * 14
	right := r.x + r.width - 8
	switch row.kind {
	case .Section:
		rl.DrawRectangleRec({r.x, r.y + r.height - 1, r.width, 1}, GITD_SECTION)
		arrow := "+" if _sb.view.collapsed[row.section] else "-"
		ui_text(font, arrow, r.x + 8, r.y, r.height, size, GITD_SUBDUED, right)
		title := fmt.tprintf("%s (%d)", SIDEBAR_SECTION_TITLES[row.section], sidebar_section_count(snap, row.section))
		ui_text(font, title, r.x + 24, r.y, r.height, size - 2, GITD_BLUE, right)
		if f := sidebar_filter(&_sb.view, row.section); f != "" {
			ft := fmt.tprintf("/%s", f)
			fw := ui_text_w(font, ft, size - 1)
			ui_text(font, ft, max(right - fw, r.x + 160), r.y, r.height, size - 1, GITD_YELLOW, right)
		}
	case .Remote_Group:
		ui_text(font, row.group, x, r.y, r.height, size, GITD_SUBDUED, right)
	case .Empty:
		ui_text(font, "(no matches)" if sidebar_filter(&_sb.view, row.section) != "" else "(none)", x, r.y, r.height, size - 1, GITD_SUBDUED, right)
	case .Local_Branch:
		b := snap.branches[row.index]
		if b.is_head { rl.DrawCircleV({x - 8, r.y + r.height * 0.5}, 3.5, GITD_GREEN) }
		ab := sidebar_ahead_behind(b)
		abw := ui_text_w(font, ab, size - 1)
		ui_text(font, b.name, x, r.y, r.height, size, GITD_GREEN if b.is_head else GITD_TEXT, right - abw - 8)
		if ab != "" {
			col := GITD_RED if b.upstream_gone else (GITD_ORANGE if b.behind > 0 else GITD_GREEN)
			ui_text(font, ab, right - abw, r.y, r.height, size - 1, col, right + 4)
		}
	case .Remote_Branch:
		ui_text(font, sidebar_row_name(snap, row), x, r.y, r.height, size, GITD_TEXT, right)
	case .Tag:
		t := snap.tags[row.index]
		h := t.hash[:min(7, len(t.hash))]
		hw := ui_text_w(font, h, size - 2)
		ui_text(font, t.name, x, r.y, r.height, size, GITD_YELLOW, right - hw - 8)
		ui_text(font, h, right - hw, r.y, r.height, size - 2, GITD_SUBDUED, right + 4)
	case .Stash:
		ui_text(font, sidebar_row_name(snap, row), x, r.y, r.height, size, GITD_TEXT, right)
	case .Submodule:
		s := snap.submodules[row.index]
		st: string
		col := GITD_SUBDUED
		switch s.state {
		case .Up_To_Date:    st = "ok"
		case .Uninitialized: st = "not init"
		case .Modified:      st = "modified"; col = GITD_ORANGE
		case .Conflict:      st = "conflict"; col = GITD_RED
		}
		sw := ui_text_w(font, st, size - 2)
		ui_text(font, s.path, x, r.y, r.height, size, GITD_TEXT, right - sw - 8)
		ui_text(font, st, right - sw, r.y, r.height, size - 2, col, right + 4)
	case .Reflog:
		ui_text(font, sidebar_row_name(snap, row), x, r.y, r.height, size - 1, GITD_SUBDUED, right)
	}
}
