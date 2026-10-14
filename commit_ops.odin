package editor

// Commit operations (ticket #9) — panel id "commit_ops".
//
// Context menu on a commit of the graph (right click on a row, or the Menu
// key / Shift+F10 on the selection): cherry-pick, revert, reset
// soft/mixed/hard (hard asks for an explicit confirmation), interactive
// rebase from that commit, create branch/tag there (through the sidebar's
// git/refs_ops.odin) and copy hash. The interactive rebase is a modal list of
// the commits after the base (oldest first) with pick/reword/squash/fixup/drop
// and reordering; it runs without any external editor (git/commit_ops.odin,
// ADR 0013).
//
// After every operation: git manager refresh + graph reload; when the
// operation stops with conflicts (or an operation in progress) the merge
// resolver ("merge_resolver", ticket #8) is opened — continue/abort live there.
//
// Public procs for other screens:
//   commit_ops_open_menu(e, commit, pos)     context menu for a commit
//   commit_ops_run(e, action, commit)        run one menu action directly
//   commit_ops_cherry_pick(e, hash, merge)   / commit_ops_revert(e, hash, merge)
//   commit_ops_reset(e, hash, mode)          .Reset_Hard asks for confirmation
//   commit_ops_interactive_rebase(e, base)   open the rebase list for base..HEAD

import "base:runtime"
import "core:fmt"
import "core:strings"
import git "./git"
import rl "vendor:raylib"

CO_ID :: "commit_ops"

Commit_Menu_Action :: enum u8 {
	Cherry_Pick,
	Revert,
	Reset_Soft,
	Reset_Mixed,
	Reset_Hard,
	Interactive_Rebase,
	Create_Branch,
	Create_Tag,
	Copy_Hash,
}

// Index = Commit_Menu_Action (same order).
COMMIT_OPS_MENU := [len(Commit_Menu_Action)]string{
	"Cherry-pick",
	"Revert",
	"Reset soft (keep index)",
	"Reset mixed (keep files)",
	"Reset hard (discard)...",
	"Interactive rebase...",
	"Create branch here...",
	"Create tag here...",
	"Copy hash",
}

// Pure: menu labels in display order (index = Commit_Menu_Action).
commit_ops_menu_items :: proc() -> []string { return COMMIT_OPS_MENU[:] }

// Pure: does the action need an explicit confirmation before running?
commit_ops_needs_confirm :: proc(a: Commit_Menu_Action) -> bool { return a == .Reset_Hard }

// Pure: reword keeps the original body, replacing only the subject line.
commit_ops_reword_message :: proc(original, subject: string, allocator := context.allocator) -> string {
	nl := strings.index_byte(original, '\n')
	if nl < 0 { return strings.clone(strings.trim_space(subject), allocator) }
	return strings.concatenate({strings.trim_space(subject), original[nl:]}, allocator)
}

// Pure: first line of a message.
commit_ops_first_line :: proc(s: string) -> string {
	if nl := strings.index_byte(s, '\n'); nl >= 0 { return s[:nl] }
	return s
}

// Pure: next action for the rebase list's Space / click cycle.
commit_ops_cycle_action :: proc(a: git.Rebase_Action) -> git.Rebase_Action {
	return git.Rebase_Action((int(a) + 1) % (int(max(git.Rebase_Action)) + 1))
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

@(private="file")
_Co_Target :: struct { hash, short, subject: string, merge: bool } // owned strings

@(private="file")
_Co_Prompt_Kind :: enum u8 { None, Branch, Tag, Reword }

@(private="file")
_Commit_Ops :: struct {
	target:   _Co_Target,
	menu:     Ui_Menu,
	confirm:  Ui_Confirm,

	prompt:       _Co_Prompt_Kind,
	fields:       [2][dynamic]u8,
	focus:        int,
	sel_all:      bool,
	check:        bool, // branch: checkout after creating

	op_id:    git.Job_Id, // commit op / rebase in flight
	op_what:  string,     // literal, for errors
	refs_id:  git.Job_Id, // create branch/tag in flight

	// Interactive rebase
	rebasing:  bool,      // list is open
	plan_id:   git.Job_Id,
	base:      _Co_Target,
	steps:     [dynamic]git.Rebase_Step, // owned strings
	merges:    int,
	nav:       Ui_List_Nav,
	vis:       int,
	rb_err:    string, // owned
}

@(private="file") _co: _Commit_Ops

@(init)
_commit_ops_register :: proc "contextless" () {
	ui_register_panel(Ui_Panel{
		id       = CO_ID,
		title    = "Commit Operations",
		priority = 70, // above the graph (60)
		layer    = .Overlay,
		draw     = _co_draw,
		input    = _co_input,
		update   = _co_update,
		on_close = _co_on_close,
	})
}

@(fini)
_commit_ops_fini :: proc "contextless" () {
	context = runtime.default_context()
	_co_target_free(&_co.target)
	_co_target_free(&_co.base)
	_co_steps_clear()
	delete(_co.steps)
	for &f in _co.fields { delete(f) }
	delete(_co.rb_err)
	ui_confirm_destroy(&_co.confirm)
}

@(private="file")
_co_target_set :: proc(t: ^_Co_Target, c: ^git.Commit) {
	_co_target_free(t)
	t.hash    = strings.clone(c.hash)
	t.short   = strings.clone(c.short_hash if c.short_hash != "" else c.hash[:min(7, len(c.hash))])
	t.subject = strings.clone(c.subject)
	t.merge   = len(c.parents) > 1
}

@(private="file")
_co_target_free :: proc(t: ^_Co_Target) {
	delete(t.hash); delete(t.short); delete(t.subject)
	t^ = {}
}

@(private="file")
_co_steps_clear :: proc() {
	for s in _co.steps { delete(s.hash); delete(s.short_hash); delete(s.subject); delete(s.message) }
	clear(&_co.steps)
}

@(private="file")
_co_active :: proc() -> bool {
	return _co.menu.open || _co.confirm.open || _co.prompt != .None || _co.rebasing
}

// Close the panel once nothing of ours is showing.
@(private="file")
_co_maybe_close :: proc(e: ^Editor) {
	if !_co_active() { ui_panel_close(e, CO_ID) }
}

@(private="file")
_co_on_close :: proc(e: ^Editor) {
	ui_menu_close(&_co.menu)
	ui_confirm_close(&_co.confirm)
	_co.prompt = .None
	_co_rebase_close(e)
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

commit_ops_open_menu :: proc(e: ^Editor, c: ^git.Commit, pos: rl.Vector2) {
	if c == nil || e.git_mgr.root == "" { return }
	_co_target_set(&_co.target, c)
	ui_menu_open(&_co.menu, pos, commit_ops_menu_items())
	ui_panel_open(e, CO_ID)
}

commit_ops_run :: proc(e: ^Editor, a: Commit_Menu_Action, c: ^git.Commit) {
	if c == nil { return }
	_co_target_set(&_co.target, c)
	_co_do(e, a)
}

commit_ops_cherry_pick :: proc(e: ^Editor, hash: string, merge := false) {
	_co_start(e, {kind = .Cherry_Pick, hash = hash, merge = merge}, "Cherry-pick")
}

commit_ops_revert :: proc(e: ^Editor, hash: string, merge := false) {
	_co_start(e, {kind = .Revert, hash = hash, merge = merge}, "Revert")
}

// mode: .Reset_Soft / .Reset_Mixed run at once; .Reset_Hard asks first.
commit_ops_reset :: proc(e: ^Editor, hash: string, mode: git.Commit_Op_Kind) {
	if mode == .Reset_Hard {
		if _co.target.hash != hash {
			_co_target_free(&_co.target)
			_co.target.hash  = strings.clone(hash)
			_co.target.short = strings.clone(hash[:min(7, len(hash))])
		}
		ui_confirm_open(&_co.confirm, "Reset --hard?",
			fmt.tprintf("HEAD moves to %s and every uncommitted change in tracked files is discarded. This can't be undone.", _co.target.short),
			confirm = "Reset hard", danger = true)
		ui_panel_open(e, CO_ID)
		return
	}
	_co_start(e, {kind = mode, hash = hash}, "Reset")
}

// Opens the interactive rebase list for the commits after `base` up to HEAD.
commit_ops_interactive_rebase :: proc(e: ^Editor, base: ^git.Commit) {
	if base == nil || e.git_mgr.root == "" { return }
	_co_rebase_close(e)
	_co_target_set(&_co.base, base)
	_co.rebasing = true
	_co.nav = {}
	_co.plan_id = git.git_request_rebase_commits(&e.git_mgr.queue, base.hash)
	ui_panel_open(e, CO_ID)
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

@(private="file")
_co_do :: proc(e: ^Editor, a: Commit_Menu_Action) {
	t := &_co.target
	if t.hash == "" { return }
	switch a {
	case .Cherry_Pick: commit_ops_cherry_pick(e, t.hash, t.merge)
	case .Revert:      commit_ops_revert(e, t.hash, t.merge)
	case .Reset_Soft:  commit_ops_reset(e, t.hash, .Reset_Soft)
	case .Reset_Mixed: commit_ops_reset(e, t.hash, .Reset_Mixed)
	case .Reset_Hard:  commit_ops_reset(e, t.hash, .Reset_Hard)
	case .Interactive_Rebase:
		c := git.Commit{hash = t.hash, short_hash = t.short, subject = t.subject}
		commit_ops_interactive_rebase(e, &c)
	case .Create_Branch: _co_prompt_open(e, .Branch)
	case .Create_Tag:    _co_prompt_open(e, .Tag)
	case .Copy_Hash:
		rl.SetClipboardText(to_cstring(t.hash))
		ui_banner_show(fmt.tprintf("Copied %s", t.hash), .Info, seconds = 2)
	}
}

@(private="file")
_co_busy :: proc() -> bool {
	if _co.op_id != 0 || _co.refs_id != 0 {
		ui_banner_show("A commit operation is already running", .Warning)
		return true
	}
	return false
}

@(private="file")
_co_start :: proc(e: ^Editor, op: git.Commit_Op, what: string) {
	if e.git_mgr.root == "" || op.hash == "" || _co_busy() { return }
	_co.op_what = what
	_co.op_id = git.git_request_commit_op(&e.git_mgr.queue, op)
	ui_banner_show(fmt.tprintf("%s %s...", what, op.hash[:min(7, len(op.hash))]), .Info, seconds = 0)
}

// Banner, resolver, refresh — after any commit op or rebase.
@(private="file")
_co_on_result :: proc(e: ^Editor, r: ^git.Commit_Op_Result) {
	switch r.outcome {
	case .Ok:
		ui_banner_show(r.message, .Success)
	case .Failed:
		ui_banner_show(r.message, .Error, seconds = 8)
	case .Conflicts, .Stopped:
		ui_banner_show(r.message, .Warning, seconds = 8)
	}
	if r.outcome == .Conflicts || r.outcome == .Stopped || len(r.conflicts) > 0 {
		ui_panel_open(e, "merge_resolver")
	}
	_co_after_op(e)
}

@(private="file")
_co_after_op :: proc(e: ^Editor) {
	git.git_manager_refresh_now(e.git_mgr)
	commit_graph_reload(e)
}

// ---------------------------------------------------------------------------
// Update
// ---------------------------------------------------------------------------

@(private="file")
_co_update :: proc(e: ^Editor, dt: f32) {
	q := &e.git_mgr.queue
	if _co.op_id != 0 {
		c, st, err := git.git_poll_as(q, _co.op_id, git.Git_Custom)
		#partial switch st {
		case .Done:
			if r := git.git_custom_as(c^, git.Commit_Op_Result); r != nil { _co_on_result(e, r) }
			git.git_release(q, _co.op_id)
			_co.op_id = 0
		case .Failed, .Unknown:
			ui_banner_show(fmt.tprintf("%s failed: %s", _co.op_what, err), .Error, seconds = 8)
			git.git_release(q, _co.op_id)
			_co.op_id = 0
			_co_after_op(e)
		}
	}
	if _co.refs_id != 0 {
		c, st, err := git.git_poll_as(q, _co.refs_id, git.Git_Custom)
		#partial switch st {
		case .Done:
			if r := git.git_custom_as(c^, git.Refs_Op_Result); r != nil {
				ui_banner_show(r.message, .Success if r.outcome == .Ok else .Error, seconds = 4 if r.outcome == .Ok else 8)
			}
			git.git_release(q, _co.refs_id)
			_co.refs_id = 0
			_co_after_op(e)
		case .Failed, .Unknown:
			ui_banner_show(fmt.tprintf("Git operation failed: %s", err), .Error, seconds = 8)
			git.git_release(q, _co.refs_id)
			_co.refs_id = 0
		}
	}
	if _co.plan_id != 0 {
		c, st, err := git.git_poll_as(q, _co.plan_id, git.Git_Custom)
		#partial switch st {
		case .Done:
			if p := git.git_custom_as(c^, git.Rebase_Plan); p != nil {
				_co_steps_clear()
				for s in p.steps {
					append(&_co.steps, git.Rebase_Step{
						action = .Pick, hash = strings.clone(s.hash), short_hash = strings.clone(s.short_hash),
						subject = strings.clone(s.subject), message = strings.clone(s.message),
					})
				}
				_co.merges = p.merges
				if len(_co.steps) == 0 { _co_set_err("No commits after this one on the current branch") }
			}
			git.git_release(q, _co.plan_id)
			_co.plan_id = 0
		case .Failed, .Unknown:
			_co_set_err(err if err != "" else "could not list commits")
			git.git_release(q, _co.plan_id)
			_co.plan_id = 0
		}
	}
}

@(private="file")
_co_set_err :: proc(msg: string) {
	delete(_co.rb_err)
	_co.rb_err = strings.clone(msg)
}

// ---------------------------------------------------------------------------
// Prompt (branch / tag name, reword message)
// ---------------------------------------------------------------------------

@(private="file")
_co_prompt_open :: proc(e: ^Editor, kind: _Co_Prompt_Kind, initial := "") {
	_co.prompt = kind
	for &f in _co.fields { clear(&f) }
	append(&_co.fields[0], initial)
	_co.focus = 0
	_co.sel_all = initial != ""
	_co.check = true
	ui_panel_open(e, CO_ID)
}

@(private="file")
_co_prompt_fields :: proc() -> (n: int, has_check: bool) {
	switch _co.prompt {
	case .None:   return 0, false
	case .Branch: return 1, true
	case .Tag:    return 2, false
	case .Reword: return 1, false
	}
	return 0, false
}

@(private="file")
_co_prompt_submit :: proc(e: ^Editor) {
	v0 := strings.trim_space(string(_co.fields[0][:]))
	v1 := strings.trim_space(string(_co.fields[1][:]))
	if v0 == "" { return }
	kind := _co.prompt
	_co.prompt = .None
	switch kind {
	case .None:
	case .Branch, .Tag:
		if e.git_mgr.root == "" || _co_busy() { return }
		op := git.Refs_Op{kind = .Create_Branch, name = v0, target = _co.target.hash, flag = _co.check}
		if kind == .Tag { op = {kind = .Create_Tag, name = v0, target = _co.target.hash, message = v1} }
		_co.refs_id = git.git_request_refs_op(&e.git_mgr.queue, op)
	case .Reword:
		i := _co.nav.selected
		if i >= 0 && i < len(_co.steps) {
			s := &_co.steps[i]
			msg := commit_ops_reword_message(s.message, v0)
			delete(s.message)
			s.message = msg
			s.action = .Reword
		}
	}
}

@(private="file")
_co_prompt_input :: proc(e: ^Editor) {
	n, has_check := _co_prompt_fields()
	total := n + (1 if has_check else 0)
	switch {
	case rl.IsKeyPressed(.ESCAPE): _co.prompt = .None
	case rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER): _co_prompt_submit(e)
	case rl.IsKeyPressed(.TAB):
		_co.focus = ui_tabs_cycle(_co.focus, total, -1 if shift() else 1)
		_co.sel_all = false
	case _co.focus >= n:
		if rl.IsKeyPressed(.SPACE) { _co.check = !_co.check }
		for rl.GetCharPressed() != 0 {}
	case:
		text_input_handle(&_co.fields[_co.focus], &_co.sel_all)
	}
}

@(private="file")
_co_prompt_draw :: proc(e: ^Editor, font: rl.Font, sw, sh: f32) {
	if _co.prompt == .None { return }
	n, has_check := _co_prompt_fields()
	title, ok_label := "New branch", "Create"
	labels := [2]string{"Branch name", ""}
	switch _co.prompt {
	case .None:
	case .Branch:
	case .Tag:    title = "New tag"; labels = {"Tag name", "Message (empty = lightweight tag)"}
	case .Reword: title = "Reword"; ok_label = "OK"; labels = {"New subject (body is kept)", ""}
	}
	W     :: f32(480)
	FH    :: f32(28)
	BTN_H :: f32(30)
	size  := FONT_SIZE - 1
	h := 36 + 12 + f32(n) * (size + 6 + FH + 10) + (30 if has_check else 0) + BTN_H + 24
	rl.DrawRectangle(0, 0, i32(sw), i32(sh), {0, 0, 0, 150})
	px, py := (sw - W) * 0.5, sh * 0.22
	rl.DrawRectangleRec({px + 4, py + 6, W, h}, {0, 0, 0, 80})
	rl.DrawRectangleRec({px, py, W, h}, BG)
	rl.DrawRectangleLinesEx({px, py, W, h}, 1, DIVIDER_COL)
	rl.DrawRectangleRec({px, py, W, 36}, STATUS_BG)
	ui_text(font, title, px + 14, py, 36, FONT_SIZE, ACCENT_COL, px + W)
	if _co.prompt != .Reword {
		ui_text(font, fmt.tprintf("at %s", _co.target.short), px + 14 + ui_text_w(font, title, FONT_SIZE) + 12, py, 36, FONT_SIZE - 3, LINENUM, px + W - 10)
	}
	mp := rl.GetMousePosition()
	y := py + 36 + 12
	for i in 0 ..< n {
		ui_text(font, labels[i], px + 14, y, size + 6, size - 1, LINENUM, px + W)
		y += size + 6
		r := rl.Rectangle{px + 14, y, W - 28, FH}
		rl.DrawRectangleRec(r, STATUS_BG)
		rl.DrawRectangleLinesEx(r, 1, ACCENT_COL if _co.focus == i else DIVIDER_COL)
		txt := string(_co.fields[i][:])
		ty := r.y + (FH - size) * 0.5
		tw := ui_text_w(font, txt, size)
		if _co.focus == i && _co.sel_all && txt != "" { rl.DrawRectangleRec({r.x + 6, ty - 2, tw + 4, size + 4}, ui_with_alpha(ACCENT_COL, 60)) }
		dlg_text(font, txt, r.x + 8, ty, size, CHAR_SPACING, TEXT, r.x + r.width, 8)
		if _co.focus == i { rl.DrawRectangleV({r.x + 8 + min(tw, r.width - 16), ty}, {2, size}, ACCENT_COL) }
		if rl.IsMouseButtonPressed(.LEFT) && ui_point_in(mp, r) { _co.focus = i; _co.sel_all = false }
		y += FH + 10
	}
	if has_check {
		box := rl.Rectangle{px + 14, y + 5, 16, 16}
		rl.DrawRectangleLinesEx(box, 1, ACCENT_COL if _co.focus == n else DIVIDER_COL)
		if _co.check { rl.DrawRectangleRec({box.x + 4, box.y + 4, 8, 8}, ACCENT_COL) }
		row := rl.Rectangle{px + 14, y, W - 28, 26}
		ui_text(font, "Checkout after creating", box.x + 24, y, 26, size - 1, TEXT, px + W)
		if rl.IsMouseButtonPressed(.LEFT) && ui_point_in(mp, row) { _co.check = !_co.check; _co.focus = n }
	}
	by := py + h - BTN_H - 14
	okw := ui_button_w(font, ok_label)
	cw  := ui_button_w(font, "Cancel")
	if ui_button(font, {px + W - 14 - okw, by, okw, BTN_H}, ok_label, false, true) { _co_prompt_submit(e); return }
	if ui_button(font, {px + W - 14 - okw - 10 - cw, by, cw, BTN_H}, "Cancel", false, false) { _co.prompt = .None }
}

// ---------------------------------------------------------------------------
// Interactive rebase list
// ---------------------------------------------------------------------------

@(private="file")
_co_rebase_close :: proc(e: ^Editor) {
	_co.rebasing = false
	if _co.plan_id != 0 { git.git_release(&e.git_mgr.queue, _co.plan_id); _co.plan_id = 0 }
	_co_steps_clear()
	_co_target_free(&_co.base)
	delete(_co.rb_err); _co.rb_err = ""
	_co.merges = 0
}

@(private="file")
_co_rebase_start :: proc(e: ^Editor) {
	if msg := git.rebase_steps_validate(_co.steps[:]); msg != "" { _co_set_err(msg); return }
	if _co_busy() { return }
	_co.op_what = "Interactive rebase"
	_co.op_id = git.git_request_rebase_interactive(&e.git_mgr.queue, _co.base.hash, _co.steps[:])
	ui_banner_show(fmt.tprintf("Rebasing %d commit(s) onto %s...", len(_co.steps), _co.base.short), .Info, seconds = 0)
	_co_rebase_close(e)
	_co_maybe_close(e)
}

@(private="file")
_co_set_action :: proc(e: ^Editor, a: git.Rebase_Action) {
	i := _co.nav.selected
	if i < 0 || i >= len(_co.steps) { return }
	if a == .Reword {
		_co_prompt_open(e, .Reword, commit_ops_first_line(_co.steps[i].message))
		return
	}
	_co.steps[i].action = a
	delete(_co.rb_err); _co.rb_err = ""
}

@(private="file")
_co_move :: proc(delta: int) {
	_co.nav.selected = git.rebase_step_move(_co.steps[:], _co.nav.selected, delta)
	ui_list_clamp(&_co.nav, len(_co.steps), max(_co.vis, 1))
}

@(private="file")
_co_rebase_input :: proc(e: ^Editor) {
	n := len(_co.steps)
	mod := ctrl() || alt()
	switch {
	case rl.IsKeyPressed(.ESCAPE):
		_co_rebase_close(e)
	case mod && (rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER)):
		_co_rebase_start(e)
	case mod && key_rep(.UP):   _co_move(-1)
	case mod && key_rep(.DOWN): _co_move(1)
	case rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER):
		_co_set_action(e, .Reword)
	case rl.IsKeyPressed(.SPACE):
		i := _co.nav.selected
		if i >= 0 && i < n { _co_set_action(e, commit_ops_cycle_action(_co.steps[i].action)) }
	case rl.IsKeyPressed(.P): _co_set_action(e, .Pick)
	case rl.IsKeyPressed(.R): _co_set_action(e, .Reword)
	case rl.IsKeyPressed(.S): _co_set_action(e, .Squash)
	case rl.IsKeyPressed(.F): _co_set_action(e, .Fixup)
	case rl.IsKeyPressed(.D), rl.IsKeyPressed(.DELETE): _co_set_action(e, .Drop)
	case:
		ui_list_handle_nav(&_co.nav, n, max(_co.vis, 1), wheel_anywhere = true)
	}
	for rl.GetCharPressed() != 0 {} // letters are commands here
}

@(private="file")
_co_action_col :: proc(a: git.Rebase_Action) -> rl.Color {
	switch a {
	case .Pick:   return GITD_TEXT
	case .Reword: return GITD_YELLOW
	case .Squash: return GITD_BLUE
	case .Fixup:  return {203, 166, 247, 255}
	case .Drop:   return GITD_RED
	}
	return GITD_TEXT
}

@(private="file")
_co_rebase_draw :: proc(e: ^Editor, font: rl.Font, sw, sh: f32, interactive: bool) {
	HDR :: f32(38)
	FTR :: f32(26)
	BTN :: f32(40)
	rl.DrawRectangle(0, 0, i32(sw), i32(sh), {0, 0, 0, 150})
	pw := min(sw - 80, f32(900))
	ph := min(sh - 80, f32(620))
	px, py := dlg_begin((sw - pw) * 0.5, (sh - ph) * 0.5, pw, ph, GITD_BG, GITD_BORDER)
	defer dlg_end()

	rl.DrawRectangleRec({px, py, pw, HDR}, GITD_HEADER)
	title := "Interactive rebase"
	ui_text(font, title, px + 12, py, HDR, FONT_SIZE, GITD_BLUE, px + pw)
	tx := px + 12 + ui_text_w(font, title, FONT_SIZE) + 14
	ui_text(font, fmt.tprintf("onto %s  %s", _co.base.short, _co.base.subject), tx, py, HDR, FONT_SIZE - 3, GITD_SUBDUED, px + pw - 10)

	size  := FONT_SIZE - 2
	row_h := max(UI_ROW_H, FONT_SIZE + 8)
	info_y := py + HDR + 4
	info := fmt.tprintf("%d commit(s), oldest first — top is applied first", len(_co.steps))
	if _co.merges > 0 { info = fmt.tprintf("%s.  %d merge commit(s) will be flattened", info, _co.merges) }
	ui_text(font, info, px + 12, info_y, row_h, size, GITD_SUBDUED, px + pw)

	list := rl.Rectangle{px, info_y + row_h + 2, pw, ph - HDR - FTR - BTN - row_h - 8}
	vis := max(1, int(list.height / row_h))
	_co.vis = vis
	n := len(_co.steps)
	ui_list_clamp(&_co.nav, n, vis)
	mp := rl.GetMousePosition()
	ACT_W :: f32(80)

	if _co.plan_id != 0 {
		ui_text(font, "loading...", list.x + 14, list.y, row_h, size, GITD_SUBDUED, list.x + list.width)
	}
	rl.BeginScissorMode(i32(list.x), i32(list.y), i32(list.width), i32(list.height))
	for vi in 0 ..< vis {
		i := _co.nav.scroll + vi
		if i >= n { break }
		s := &_co.steps[i]
		y := list.y + f32(vi) * row_h
		if i == _co.nav.selected {
			rl.DrawRectangleRec({list.x, y, list.width, row_h}, SEL_BG)
			rl.DrawRectangleRec({list.x, y, 3, row_h}, ACCENT_COL)
		}
		col := _co_action_col(s.action)
		act := rl.Rectangle{list.x + 10, y + 2, ACT_W, row_h - 4}
		rl.DrawRectangleLinesEx(act, 1, ui_with_alpha(col, 120))
		ui_text(font, git.rebase_action_word(s.action), act.x + 8, y, row_h, size, col, act.x + act.width)
		hx := act.x + ACT_W + 10
		ui_text(font, s.short_hash, hx, y, row_h, size, GITD_ORANGE, hx + 70)
		subj := s.subject
		if s.action == .Reword { subj = commit_ops_first_line(s.message) }
		sub_col := GITD_SUBDUED if s.action == .Drop else (GITD_YELLOW if s.action == .Reword else GITD_TEXT)
		sx := hx + 78
		ui_text(font, subj, sx, y, row_h, size, sub_col, list.x + list.width - 10)
		if s.action == .Drop {
			rl.DrawRectangleRec({sx, y + row_h * 0.5, min(ui_text_w(font, subj, size), list.x + list.width - 10 - sx), 1}, GITD_SUBDUED)
		}
		if interactive && rl.IsMouseButtonPressed(.LEFT) && ui_point_in(mp, {list.x, y, list.width, row_h}) && ui_point_in(mp, list) {
			_co.nav.selected = i
			if ui_point_in(mp, act) { _co_set_action(e, commit_ops_cycle_action(s.action)) }
		}
	}
	rl.EndScissorMode()
	dlg_restore()

	// Buttons
	by := py + ph - FTR - BTN + 5
	bh := BTN - 10
	bx := px + 12
	labels := [?]string{"Move up", "Move down", "pick", "reword", "squash", "fixup", "drop"}
	for l, k in labels {
		w := ui_button_w(font, l)
		if ui_button(font, {bx, by, w, bh}, l, false, false) && interactive {
			switch k {
			case 0: _co_move(-1)
			case 1: _co_move(1)
			case:   _co_set_action(e, git.Rebase_Action(k - 2))
			}
		}
		bx += w + 6
	}
	sl := "Start rebase"
	sw_ := ui_button_w(font, sl)
	cw := ui_button_w(font, "Cancel")
	if ui_button(font, {px + pw - 12 - sw_, by, sw_, bh}, sl, false, true) && interactive { _co_rebase_start(e); return }
	if ui_button(font, {px + pw - 12 - sw_ - 8 - cw, by, cw, bh}, "Cancel", false, false) && interactive { _co_rebase_close(e); return }

	fy := py + ph - FTR
	rl.DrawRectangleRec({px, fy, pw, FTR}, GITD_HEADER)
	if _co.rb_err != "" {
		ui_text(font, _co.rb_err, px + 10, fy, FTR, FONT_SIZE - 3, GITD_RED, px + pw)
	} else {
		ui_text(font, "p/r/s/f/d or Space: action  Enter: reword  Ctrl/Alt+Up/Dn: move  Ctrl+Enter: start  Esc: cancel",
			px + 10, fy, FTR, FONT_SIZE - 4, GITD_SUBDUED, px + pw)
	}
}

// ---------------------------------------------------------------------------
// Panel hooks
// ---------------------------------------------------------------------------

@(private="file")
_co_on_confirm :: proc(e: ^Editor, r: Ui_Confirm_Result) {
	if r == .Confirm { _co_start(e, {kind = .Reset_Hard, hash = _co.target.hash}, "Reset") }
}

@(private="file")
_co_input :: proc(e: ^Editor) -> bool {
	defer _co_maybe_close(e)
	switch {
	case _co.confirm.open:
		_co_on_confirm(e, ui_confirm_handle_input(&_co.confirm))
	case _co.prompt != .None:
		_co_prompt_input(e)
	case _co.menu.open:
		if i := ui_menu_handle_input(&_co.menu); i >= 0 { _co_do(e, Commit_Menu_Action(i)) }
	case _co.rebasing:
		_co_rebase_input(e)
	case:
		return false
	}
	return true
}

@(private="file")
_co_draw :: proc(e: ^Editor, font: rl.Font, sw, sh: f32) {
	defer _co_maybe_close(e)
	if _co.rebasing {
		_co_rebase_draw(e, font, sw, sh, !_co.confirm.open && _co.prompt == .None && !_co.menu.open)
	}
	if i := ui_menu_draw(&_co.menu, font, sw, sh); i >= 0 { _co_do(e, Commit_Menu_Action(i)) }
	_co_prompt_draw(e, font, sw, sh)
	_co_on_confirm(e, ui_confirm_draw(&_co.confirm, font, sw, sh))
}
