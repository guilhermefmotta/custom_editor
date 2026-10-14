package editor

// Remote operations + stash HUD (ticket #7, panel id "remote_ops", ADR 0002).
//
// A small toolbar at the top-right (Fetch / Pull / Rebase / Push / Force /
// Stash / Pop) plus palette commands "Git: Fetch All", "Git: Pull (Merge)",
// "Git: Pull (Rebase)", "Git: Push", "Git: Force Push (with lease)...",
// "Git: Stash Changes...", "Git: Stash Pop". Toggle: Ctrl/Cmd+Alt+R.
//
// Network jobs (fetch, push, the fetch half of pull) run on a queue owned by
// this file so a slow remote never stalls the shared e.git_mgr.queue; the
// merge/rebase half of pull and stash run on the shared queue. One operation
// at a time; progress = op name + spinner + elapsed time. Results go to the
// banner; a pull (or pop) that stops with conflicts opens "merge_resolver".
//
// Public for integration:
//   remote_ops_start(e, op, message = "")  — run an op (force push asks first)
//   remote_ops_busy() -> bool

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strings"
import rl "vendor:raylib"
import "git"

REMOTE_OPS_ID :: "remote_ops"

@(init)
_remote_ops_register :: proc "contextless" () {
	ui_register_panel(Ui_Panel{
		id           = REMOTE_OPS_ID,
		title        = "Remote Operations",
		priority     = 30,
		layer        = .Overlay,
		draw         = _ro_draw,
		input        = _ro_input,
		update       = _ro_update,
		on_close     = _ro_on_close,
		command      = "Git: Remote Operations Toolbar",
		command_desc = "Show/hide the fetch / pull / push / stash toolbar",
		shortcut     = {key = .R, mods = {.Ctrl, .Alt}},
	})
	ui_register_command(Command{"Git: Fetch All", "Fetch all remotes (prune, tags)", _ro_cmd_fetch, _ro_available})
	ui_register_command(Command{"Git: Pull (Merge)", "Fetch upstream and merge it into the current branch", _ro_cmd_pull_merge, _ro_available})
	ui_register_command(Command{"Git: Pull (Rebase)", "Fetch upstream and rebase the current branch onto it", _ro_cmd_pull_rebase, _ro_available})
	ui_register_command(Command{"Git: Push", "Push the current branch (sets upstream on first push)", _ro_cmd_push, _ro_available})
	ui_register_command(Command{"Git: Force Push (with lease)...", "push --force-with-lease, after confirmation", _ro_cmd_force_push, _ro_available})
	ui_register_command(Command{"Git: Stash Changes...", "Stash local changes (incl. untracked) with an optional message", _ro_cmd_stash, _ro_available})
	ui_register_command(Command{"Git: Stash Pop", "Apply and drop the latest stash", _ro_cmd_pop, _ro_available})
}

@(fini)
_remote_ops_fini :: proc "contextless" () {
	context = runtime.default_context()
	git.git_queue_destroy(&_ro.net)
	ui_confirm_destroy(&_ro.confirm)
	delete(_ro.stash_buf)
}

// Phase of the running operation.
Remote_Ops_Phase :: enum u8 { Idle, Running, Integrating }

@(private = "file")
_Remote_Ops :: struct {
	net:        git.Git_Queue, // network jobs (own worker thread)
	phase:      Remote_Ops_Phase,
	op:         git.Remote_Op, // user-facing op (Pull_Merge/Pull_Rebase for pulls)
	started:    f64,
	confirm:    Ui_Confirm,     // force push
	stash_open: bool,
	stash_buf:  [dynamic]u8,
	stash_sel:  bool,
	hud:        rl.Rectangle,   // last drawn HUD rect (mouse capture)
	last:       [128]u8,        // last result, shown in the HUD
	last_len:   int,
	last_ok:    bool,
}
@(private = "file") _ro: _Remote_Ops

remote_ops_busy :: proc() -> bool { return _ro.phase != .Idle }

@(private = "file")
_ro_available :: proc(e: ^Editor) -> bool { return e.git_mgr.root != "" }

@(private = "file") _ro_cmd_fetch       :: proc(e: ^Editor, p: ^Palette) { palette_close(p); remote_ops_start(e, .Fetch_All) }
@(private = "file") _ro_cmd_pull_merge  :: proc(e: ^Editor, p: ^Palette) { palette_close(p); remote_ops_start(e, .Pull_Merge) }
@(private = "file") _ro_cmd_pull_rebase :: proc(e: ^Editor, p: ^Palette) { palette_close(p); remote_ops_start(e, .Pull_Rebase) }
@(private = "file") _ro_cmd_push        :: proc(e: ^Editor, p: ^Palette) { palette_close(p); remote_ops_start(e, .Push) }
@(private = "file") _ro_cmd_force_push  :: proc(e: ^Editor, p: ^Palette) { palette_close(p); remote_ops_start(e, .Force_Push) }
@(private = "file") _ro_cmd_stash       :: proc(e: ^Editor, p: ^Palette) { palette_close(p); remote_ops_start(e, .Stash_Save) }
@(private = "file") _ro_cmd_pop         :: proc(e: ^Editor, p: ^Palette) { palette_close(p); remote_ops_start(e, .Stash_Pop) }

// Entry point for every op. Force push and stash go through their dialog
// first (Force_Push → confirmation, Stash_Save without message → prompt);
// pass `confirmed = true` / a message to skip them.
remote_ops_start :: proc(e: ^Editor, op: git.Remote_Op, message := "", confirmed := false) {
	if e.git_mgr.root == "" { ui_banner_show("Not a git repository", .Warning); return }
	ui_panel_open(e, REMOTE_OPS_ID) // progress indicator lives in the HUD
	if _ro.phase != .Idle {
		ui_banner_show(fmt.tprintf("%s is still running", git.remote_op_name(_ro.op)), .Warning)
		return
	}
	switch {
	case op == .Force_Push && !confirmed:
		ui_confirm_open(&_ro.confirm, "Force push?",
			"Overwrite the remote branch with your local history (git push --force-with-lease). Commits only on the remote may be lost.",
			confirm = "Force Push", danger = true)
		return
	case op == .Stash_Save && message == "" && !confirmed:
		clear(&_ro.stash_buf)
		_ro.stash_open = true
		_ro.stash_sel  = false
		return
	}
	_ro_ensure_net(e)
	_ro.op      = op
	_ro.phase   = .Running
	_ro.started = rl.GetTime()

	q   := &_ro.net
	sub := op
	#partial switch op {
	case .Pull_Merge, .Pull_Rebase: sub = .Fetch_Upstream
	}
	if !git.remote_op_is_network(op) { q = &e.git_mgr.queue }
	id := git.git_request_remote_op(q, sub, message)
	git.git_on_done(q, id, _ro_on_done, e)
}

@(private = "file")
_ro_ensure_net :: proc(e: ^Editor) {
	if _ro.net.inited && _ro.net.root == e.git_mgr.root { return }
	git.git_queue_destroy(&_ro.net) // idle here (phase == .Idle)
	git.git_queue_init(&_ro.net, e.git_mgr.root)
}

@(private = "file")
_ro_on_done :: proc(r: ^git.Git_Result, user: rawptr) {
	e   := (^Editor)(user)
	res := git.remote_op_result(r)
	if res == nil {
		_ro_finish(e, false, fmt.tprintf("%s failed: %s", git.remote_op_name(_ro.op), r.err), .Error)
		return
	}
	// Pull, step 1 done → integrate on the shared queue.
	if res.ok && res.op == .Fetch_Upstream && (_ro.op == .Pull_Merge || _ro.op == .Pull_Rebase) {
		_ro.phase = .Integrating
		step := git.Remote_Op.Merge_Upstream if _ro.op == .Pull_Merge else .Rebase_Upstream
		id := git.git_request_remote_op(&e.git_mgr.queue, step)
		git.git_on_done(&e.git_mgr.queue, id, _ro_on_done, e)
		return
	}
	kind, open_resolver := remote_ops_outcome(res^)
	msg := res.message
	if open_resolver {
		msg = fmt.tprintf("%s — %d file(s) in conflict, opening the resolver", res.message, len(res.state.conflicts))
	}
	_ro_finish(e, res.ok, msg, kind)
	if open_resolver { ui_panel_open(e, "merge_resolver") }
}

// Pure: banner kind for a finished op, and whether the conflict resolver
// should open (repo left merging/rebasing/conflicted with unmerged paths).
remote_ops_outcome :: proc(res: git.Remote_Op_Result) -> (kind: Ui_Banner_Kind, open_resolver: bool) {
	if res.has_state && len(res.state.conflicts) > 0 {
		#partial switch res.state.operation {
		case .Merging, .Rebasing, .Conflicted, .Cherry_Picking, .Reverting: return .Warning, true
		}
	}
	if res.ok { return .Success, false }
	#partial switch res.kind {
	case .Nothing_To_Stash, .No_Stash: return .Info, false
	case .Conflict:                    return .Warning, false
	}
	return .Error, false
}

@(private = "file")
_ro_finish :: proc(e: ^Editor, ok: bool, msg: string, kind: Ui_Banner_Kind) {
	_ro.phase   = .Idle
	_ro.last_ok = ok
	n := min(len(msg), len(_ro.last))
	for n > 0 && n < len(msg) && (msg[n] & 0xC0) == 0x80 { n -= 1 }
	copy(_ro.last[:], msg[:n])
	_ro.last_len = n
	ui_banner_show(msg, kind, 4 if ok else 8)
	git.git_manager_refresh_now(e.git_mgr)
}

@(private = "file")
_ro_update :: proc(e: ^Editor, dt: f32) {
	if _ro.net.inited { git.git_queue_update(&_ro.net) }
}

@(private = "file")
_ro_on_close :: proc(e: ^Editor) {
	_ro.stash_open = false
	ui_confirm_close(&_ro.confirm)
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

@(private = "file")
_ro_input :: proc(e: ^Editor) -> bool {
	if _ro.confirm.open {
		_ro_on_confirm(e, ui_confirm_handle_input(&_ro.confirm))
		return true
	}
	if _ro.stash_open {
		switch {
		case rl.IsKeyPressed(.ESCAPE):
			_ro.stash_open = false
		case rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER):
			_ro_stash_submit(e)
		case:
			text_input_handle(&_ro.stash_buf, &_ro.stash_sel)
		}
		return true
	}
	// Non-modal HUD: only swallow the mouse when it is over the toolbar.
	mp := rl.GetMousePosition()
	if _ro.hud.width > 0 && ui_point_in(mp, _ro.hud) {
		return rl.IsMouseButtonPressed(.LEFT) || rl.IsMouseButtonDown(.LEFT) || rl.GetMouseWheelMove() != 0
	}
	return false
}

@(private = "file")
_ro_stash_submit :: proc(e: ^Editor) {
	_ro.stash_open = false
	msg := strings.clone(string(_ro.stash_buf[:]), context.temp_allocator)
	remote_ops_start(e, .Stash_Save, msg, confirmed = true)
}

@(private = "file")
_ro_on_confirm :: proc(e: ^Editor, r: Ui_Confirm_Result) {
	if r == .Confirm { remote_ops_start(e, .Force_Push, confirmed = true) }
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

@(private = "file")
_RO_BUTTONS := [?]struct { label: string, op: git.Remote_Op }{
	{"Fetch", .Fetch_All}, {"Pull", .Pull_Merge}, {"Pull --rebase", .Pull_Rebase},
	{"Push", .Push}, {"Force...", .Force_Push}, {"Stash...", .Stash_Save}, {"Pop", .Stash_Pop},
}

@(private = "file")
_ro_draw :: proc(e: ^Editor, font: rl.Font, sw, sh: f32) {
	BTN_H :: f32(24)
	PAD   :: f32(6)
	modal := _ro.confirm.open || _ro.stash_open
	size  := FONT_SIZE - 3

	// Measure
	total := PAD
	for b in _RO_BUTTONS { total += ui_button_w(font, b.label) + 4 }
	close_w := ui_button_w(font, "x")
	total += close_w + PAD
	status := _ro_status_text()
	w := max(total, ui_text_w(font, status, size) + 2 * PAD)
	h := PAD + BTN_H + 4 + UI_ROW_H - 4 + PAD
	x := sw - w - 12
	y := UI_BANNER_H + 8
	_ro.hud = {x, y, w, h}

	rl.DrawRectangleRec({x + 3, y + 4, w, h}, {0, 0, 0, 70})
	rl.DrawRectangleRec(_ro.hud, STATUS_BG)
	rl.DrawRectangleLinesEx(_ro.hud, 1, DIVIDER_COL)

	bx := x + PAD
	for b in _RO_BUTTONS {
		bw := ui_button_w(font, b.label)
		r  := rl.Rectangle{bx, y + PAD, bw, BTN_H}
		clicked := ui_button(font, r, b.label, false, false)
		if b.op == .Force_Push { rl.DrawRectangleLinesEx(r, 1, ui_with_alpha(MSG_COL, 160)) }
		if clicked && !modal { remote_ops_start(e, b.op) }
		bx += bw + 4
	}
	if ui_button(font, {bx, y + PAD, close_w, BTN_H}, "x", false, false) && !modal && _ro.phase == .Idle {
		ui_panel_close(e, REMOTE_OPS_ID)
	}

	col := LINENUM
	if _ro.phase != .Idle { col = ACCENT_COL } else if _ro.last_len > 0 { col = _ro.last_ok ? GITD_TEXT : MSG_COL }
	ui_text(font, status, x + PAD, y + PAD + BTN_H + 2, UI_ROW_H - 4, size, col, x + w - PAD)
	if _ro.phase != .Idle { // indeterminate progress bar
		t  := f32(rl.GetTime() - _ro.started)
		bw := w * 0.25
		px := x + (w - bw) * (0.5 + 0.5 * math.sin(t * 3))
		rl.DrawRectangleRec({px, y + h - 3, bw, 2}, ACCENT_COL)
	}

	if _ro.stash_open { _ro_draw_stash_prompt(e, font, sw, sh) }
	_ro_on_confirm(e, ui_confirm_draw(&_ro.confirm, font, sw, sh))
}

@(private = "file")
_ro_status_text :: proc() -> string {
	if _ro.phase != .Idle {
		SPIN := [4]rune{'|', '/', '-', '\\'}
		el := rl.GetTime() - _ro.started
		i  := int(el * 8) % 4
		verb := git.remote_op_name(_ro.op)
		if _ro.phase == .Integrating {
			verb = "Pull: merging" if _ro.op == .Pull_Merge else "Pull: rebasing"
		} else if _ro.op == .Pull_Merge || _ro.op == .Pull_Rebase {
			verb = "Pull: fetching"
		}
		return fmt.tprintf("%c %s... %.1fs", SPIN[i], verb, el)
	}
	if _ro.last_len > 0 { return string(_ro.last[:_ro.last_len]) }
	return "Ready — Ctrl+Alt+R hides this toolbar"
}

@(private = "file")
_ro_draw_stash_prompt :: proc(e: ^Editor, font: rl.Font, sw, sh: f32) {
	W :: f32(460)
	H :: f32(128)
	rl.DrawRectangle(0, 0, i32(sw), i32(sh), {0, 0, 0, 150})
	px, py := (sw - W) * 0.5, sh * 0.25
	rl.DrawRectangleRec({px + 3, py + 4, W, H}, {0, 0, 0, 90})
	rl.DrawRectangleRec({px, py, W, H}, BG)
	rl.DrawRectangleLinesEx({px, py, W, H}, 1, DIVIDER_COL)
	rl.DrawRectangleRec({px, py, W, 34}, STATUS_BG)
	ui_text(font, "Stash local changes", px + 12, py, 34, FONT_SIZE, ACCENT_COL, px + W)

	box := rl.Rectangle{px + 12, py + 46, W - 24, 28}
	rl.DrawRectangleRec(box, STATUS_BG)
	rl.DrawRectangleLinesEx(box, 1, ACCENT_COL)
	txt := string(_ro.stash_buf[:])
	if _ro.stash_sel && txt != "" {
		rl.DrawRectangleRec({box.x + 6, box.y + 4, ui_text_w(font, txt, FONT_SIZE - 1), box.height - 8}, SEL_BG)
	}
	if txt == "" {
		ui_text(font, "Message (optional)", box.x + 6, box.y, box.height, FONT_SIZE - 1, LINENUM, box.x + box.width)
	} else {
		ui_text(font, txt, box.x + 6, box.y, box.height, FONT_SIZE - 1, TEXT, box.x + box.width)
	}
	cx := box.x + 6 + ui_text_w(font, txt, FONT_SIZE - 1) + 1
	if int(rl.GetTime() * 2) % 2 == 0 { rl.DrawRectangleRec({cx, box.y + 5, 2, box.height - 10}, ACCENT_COL) }
	ui_text(font, "Enter stash (incl. untracked)   Esc cancel", px + 12, py + H - 34, 28, FONT_SIZE - 4, LINENUM, px + W)
}
