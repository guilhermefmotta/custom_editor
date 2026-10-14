package editor

// ===========================================================================
// Claude Code sessions — UI (ticket #17, ADR 0015). Model in
// claude_sessions_model.odin.
//
//   Ctrl/Cmd+J            "Claude: Toggle Session" — show/hide the session of
//                         the active repository (started on first use) in the
//                         terminal panel. Other repos' sessions keep running.
//   Ctrl/Cmd+Shift+J      "Claude: Sessions" — every session with its status.
//   Ctrl/Cmd+Alt+J        "Claude: Review Changes" (review_mode.odin).
//   "Claude: Stop Session" kills the active repository's session.
//
// Status is polled from the hook status files (every 0.25 s, all sessions);
// a session that starts waiting for you raises a desktop notification
// (unless you're looking at it) and an in-editor banner. Each repository tab
// gets a dot in its session's status color (repos_tab_dot).
// ===========================================================================

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import git "./git"
import rl "vendor:raylib"

CLAUDE_SESSIONS_ID :: "claude_sessions"
CLAUDE_POLL_EVERY  :: f32(0.25)
CLAUDE_POLL_IDLE   :: f32(2.0) // no session working (ADR 0016)

@(private="file") _cs: Claude_Sessions
@(private="file") _cs_ready: bool

@(private="file")
_Cs_Ui :: struct {
	nav:         Ui_List_Nav,
	list_rect:   rl.Rectangle,
	vis:         int,
	poll:        f32,
	show_on_enter: bool,   // the leaving repo's session was on screen
	pending_show:  string, // root whose session to show after a switch, owned
	pending_review: string, // root whose review to open after a switch, owned
}
@(private="file") _csu: _Cs_Ui

@(init)
_claude_sessions_register :: proc "contextless" () {
	ui_register_panel(Ui_Panel{
		id           = CLAUDE_SESSIONS_ID,
		title        = "Claude Sessions",
		priority     = 58,
		layer        = .Overlay,
		draw         = _cs_draw,
		input        = _cs_input,
		update       = _cs_update,
		command      = "Claude: Sessions",
		command_desc = "All Claude Code sessions (one per repository) with their status",
		shortcut     = {key = .J, mods = {.Ctrl, .Shift}},
	})
	ui_register_command(Command{"Claude: Toggle Session", "Show/hide Claude Code for the active repository (starts it in the repo root)", _cs_cmd_toggle, nil},
	                    shortcut = {key = .J, mods = {.Ctrl}})
	ui_register_command(Command{"Claude: Stop Session", "Stop the Claude Code session of the active repository", _cs_cmd_stop, _cs_has_active})
	repos_register_switch_hook(_cs_on_switch)
	repos_tab_dot = _cs_tab_dot
}

@(fini)
_claude_sessions_fini :: proc "contextless" () {
	context = runtime.default_context()
	if _cs_ready { claude_sessions_destroy(&_cs) }
	delete(_csu.pending_show)
	delete(_csu.pending_review)
}

@(private="file")
_cs_ensure :: proc() -> ^Claude_Sessions {
	if !_cs_ready {
		claude_sessions_init(&_cs, claude_sessions_default_dir())
		_cs_ready = true
	}
	return &_cs
}

// ---------------------------------------------------------------------------
// Public procs (other screens / integration)
// ---------------------------------------------------------------------------

// Session of the active repository (nil if none).
claude_session_active :: proc(e: ^Editor) -> ^Claude_Session {
	if !_cs_ready || e.git_mgr.root == "" { return nil }
	return claude_sessions_find(&_cs, e.git_mgr.root)
}

// Session of a repository root (nil if none).
claude_session_of :: proc(root: string) -> ^Claude_Session {
	if !_cs_ready || root == "" { return nil }
	return claude_sessions_find(&_cs, root)
}

claude_status_color :: proc(s: ^Claude_Session) -> rl.Color {
	if s.exited { return GITD_SUBDUED }
	switch s.status {
	case .Working: return GITD_BLUE
	case .Waiting: return GITD_ORANGE
	case .Stopped: return GITD_GREEN
	}
	return GITD_SUBDUED
}

claude_status_text :: proc(s: ^Claude_Session) -> string {
	return "exited" if s.exited else CLAUDE_STATUS_LABEL[s.status]
}

// Ctrl/Cmd+J: hide the active repo's session if it's on screen, otherwise
// show it (starting Claude Code in the repo root if needed).
claude_session_toggle :: proc(e: ^Editor) {
	if e.git_mgr.root == "" { ui_banner_show("Claude: open a git repository first", .Warning); return }
	if s := claude_session_active(e); s != nil && !s.exited && terminal_panel_shows(s.t) {
		ui_panel_close(e, TERMINAL_PANEL_ID)
		return
	}
	claude_session_show(e, e.git_mgr.root)
}

// Shows (starting if needed) the session of `root` — must be the active repo.
claude_session_show :: proc(e: ^Editor, root: string) -> ^Claude_Session {
	cs := _cs_ensure()
	if old := claude_sessions_find(cs, root); old != nil && (old.exited || _cs_exited_now(old)) {
		terminal_panel_detach(e, old.t) // the tab must go before the terminal is freed
	}
	s, created, err := claude_sessions_get_or_start(cs, root)
	if s == nil { ui_banner_show(err, .Error); return nil }
	if created {
		if s.base_rev == "" && root == e.git_mgr.root {
			s.base_job = git.git_request_command(&e.git_mgr.queue, {"rev-parse", "--verify", "-q", "HEAD"})
			git.git_on_done(&e.git_mgr.queue, s.base_job, _cs_on_base)
		}
		e.msg = fmt.tprintf("Claude Code started in %s", s.root)
	}
	terminal_panel_attach(e, s.t, fmt.tprintf("claude · %s", s.name))
	return s
}

@(private="file")
_cs_exited_now :: proc(s: ^Claude_Session) -> bool {
	claude_session_poll(s)
	return s.exited
}

// Stops (kills) the session of `root` and forgets it.
claude_session_stop :: proc(e: ^Editor, root: string) {
	s := claude_session_of(root)
	if s == nil { return }
	terminal_panel_detach(e, s.t)
	if _csu.nav.selected >= len(_cs.list) - 1 { _csu.nav.selected = max(0, len(_cs.list) - 2) }
	claude_sessions_remove(&_cs, s)
}

// ---------------------------------------------------------------------------
// Commands / hooks
// ---------------------------------------------------------------------------

@(private="file")
_cs_cmd_toggle :: proc(e: ^Editor, p: ^Palette) { palette_close(p); claude_session_toggle(e) }

@(private="file")
_cs_cmd_stop :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	if s := claude_session_active(e); s != nil {
		name := strings.clone(s.name, context.temp_allocator)
		claude_session_stop(e, e.git_mgr.root)
		e.msg = fmt.tprintf("Claude session of %s stopped", name)
	}
}

@(private="file")
_cs_has_active :: proc(e: ^Editor) -> bool { return claude_session_active(e) != nil }

@(private="file")
_cs_on_base :: proc(r: ^git.Git_Result, user: rawptr) {
	for s in _cs.list {
		if s.base_job != r.id { continue }
		s.base_job = 0
		if out, ok := r.payload.(git.Command_Output); ok && out.exit_code == 0 {
			delete(s.base_rev)
			s.base_rev = strings.clone(strings.trim_space(out.output))
		}
	}
}

@(private="file")
_cs_set :: proc(dst: ^string, v: string) { delete(dst^); dst^ = strings.clone(v) }

// Repo switch (ADR 0014): the leaving repo's session tab is detached (it
// keeps running); if it was on screen, the new repo's session is shown.
@(private="file")
_cs_on_switch :: proc(e: ^Editor, phase: Repo_Switch_Phase) {
	if !_cs_ready { return }
	switch phase {
	case .Leaving:
		_csu.show_on_enter = false
		for s in _cs.list {
			if s.root != e.git_mgr.root { continue }
			if terminal_panel_shows(s.t) { _csu.show_on_enter = true }
			terminal_panel_detach(e, s.t)
		}
	case .Entered:
		root := e.git_mgr.root
		if root != "" && root == _csu.pending_show {
			claude_session_show(e, root)
		} else if root != "" && _csu.show_on_enter {
			if s := claude_session_of(root); s != nil && !s.exited { terminal_panel_attach(e, s.t, fmt.tprintf("claude · %s", s.name)) }
		}
		if root != "" && root == _csu.pending_review { review_mode_open(e) }
		_cs_set(&_csu.pending_show, "")
		_cs_set(&_csu.pending_review, "")
		_csu.show_on_enter = false
	}
}

@(private="file")
_cs_tab_dot :: proc(r: ^Repo) -> (rl.Color, bool) {
	s := claude_session_of(r.git.root)
	if s == nil { return {}, false }
	return claude_status_color(s), true
}

// Index of the open repository whose git root is `root` (-1 if none).
@(private="file")
_cs_repo_index :: proc(e: ^Editor, root: string) -> int {
	for r, i in e.repos.list { if r.git.root == root { return i } }
	return -1
}

// Switches to the session's repository (if needed), then runs `then`.
@(private="file")
_cs_goto :: proc(e: ^Editor, s: ^Claude_Session, review: bool) {
	ui_panel_close(e, CLAUDE_SESSIONS_ID)
	if s.root == e.git_mgr.root {
		if review { review_mode_open(e) } else { claude_session_show(e, s.root) }
		return
	}
	idx := _cs_repo_index(e, s.root)
	if idx < 0 { ui_banner_show(fmt.tprintf("%s is not open as a repository tab", s.root), .Warning); return }
	if review { _cs_set(&_csu.pending_review, s.root) } else { _cs_set(&_csu.pending_show, s.root) }
	repos_switch(e, idx)
}

// ---------------------------------------------------------------------------
// Polling + notifications
// ---------------------------------------------------------------------------

@(private="file")
_cs_update :: proc(e: ^Editor, dt: f32) {
	if !_cs_ready || len(_cs.list) == 0 { return }
	_csu.poll += dt
	// ADR 0016: the loop may sleep — ask for a frame at the next poll. A
	// working session is polled every CLAUDE_POLL_EVERY; idle ones (waiting /
	// stopped: their next change follows your input or terminal output,
	// which wake the loop anyway) every CLAUDE_POLL_IDLE.
	every := CLAUDE_POLL_IDLE
	for s in _cs.list { if s.status == .Working { every = CLAUDE_POLL_EVERY; break } }
	frame_request_in(f64(every - _csu.poll))
	if _csu.poll < every { return }
	_csu.poll = 0
	for s in _cs.list {
		_, notify := claude_session_poll(s)
		if !notify { continue }
		looking := terminal_panel_shows(s.t) && rl.IsWindowFocused()
		if looking { continue }
		body := s.message if s.message != "" else "Claude is waiting for your input"
		claude_notify(fmt.tprintf("Claude: %s", s.name), body)
		if s.root != e.git_mgr.root || !terminal_panel_shows(s.t) {
			ui_banner_show(fmt.tprintf("Claude (%s) is waiting for you — Ctrl/Cmd+Shift+J", s.name), .Info, 6)
		}
	}
}

// Desktop notification, fire-and-forget on a short-lived thread (never
// blocks the UI).
claude_notify :: proc(title, body: string) {
	argv := claude_notify_command(title, body, context.allocator)
	thread.create_and_start_with_poly_data(argv, proc(argv: []string) {
		sync.mutex_lock(&search_proc_mu) // process_start isn't thread-safe w.r.t. handle inheritance
		p, err := os.process_start({command = argv})
		sync.mutex_unlock(&search_proc_mu)
		if err == nil { _, _ = os.process_wait(p) }
		for a in argv { delete(a) }
		delete(argv)
	}, self_cleanup = true)
}

// ---------------------------------------------------------------------------
// Sessions panel
// ---------------------------------------------------------------------------

@(private="file")
_cs_elapsed :: proc(t: time.Time) -> string {
	d := int(time.duration_seconds(time.since(t)))
	switch {
	case d < 60:   return fmt.tprintf("%ds", d)
	case d < 3600: return fmt.tprintf("%dm", d / 60)
	}
	return fmt.tprintf("%dh%02dm", d / 3600, (d % 3600) / 60)
}

@(private="file")
_cs_selected :: proc() -> ^Claude_Session {
	if !_cs_ready || len(_cs.list) == 0 { return nil }
	return _cs.list[clamp(_csu.nav.selected, 0, len(_cs.list) - 1)]
}

@(private="file")
_cs_input :: proc(e: ^Editor) -> bool {
	n := len(_cs.list) if _cs_ready else 0
	ui_list_handle_nav(&_csu.nav, n, max(1, _csu.vis), _csu.list_rect)
	if ctrl() || alt() { return true }
	if rl.IsKeyPressed(.ESCAPE) { ui_panel_close(e, CLAUDE_SESSIONS_ID); return true }
	if rl.IsKeyPressed(.N) {
		ui_panel_close(e, CLAUDE_SESSIONS_ID)
		if e.git_mgr.root != "" { claude_session_show(e, e.git_mgr.root) } else { ui_banner_show("Claude: open a git repository first", .Warning) }
		return true
	}
	s := _cs_selected()
	if s == nil { return true }
	switch {
	case rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER): _cs_goto(e, s, false)
	case rl.IsKeyPressed(.R):                                    _cs_goto(e, s, true)
	case rl.IsKeyPressed(.X) || rl.IsKeyPressed(.DELETE):        claude_session_stop(e, s.root)
	}
	return true
}

@(private="file")
_cs_draw :: proc(e: ^Editor, font: rl.Font, sw, sh: f32) {
	n := len(_cs.list) if _cs_ready else 0
	fs := FONT_SIZE - 1
	row_h := GITD_ENTRY_H + 6
	W := min(f32(860), sw - 60)
	H := min(sh - 80, GITD_HEADER_H + f32(max(n, 3)) * row_h + GITD_FOOTER_H + 16)
	rl.DrawRectangle(0, 0, i32(sw), i32(sh), {0, 0, 0, 120})
	px, py := dlg_begin((sw - W) * 0.5, sh * 0.12, W, H, GITD_BG, GITD_BORDER)

	rl.DrawRectangleV({px, py}, {W, GITD_HEADER_H}, GITD_HEADER)
	counts: [Claude_Status]int
	if _cs_ready { counts = claude_sessions_counts(&_cs) }
	title := fmt.tprintf(" Claude Sessions   %d working · %d waiting · %d stopped", counts[.Working], counts[.Waiting], counts[.Stopped])
	ui_text(font, title, px + 6, py, GITD_HEADER_H, FONT_SIZE, GITD_BLUE, px + W)

	list_r := rl.Rectangle{px, py + GITD_HEADER_H + 4, W, H - GITD_HEADER_H - GITD_FOOTER_H - 8}
	_csu.list_rect = list_r
	_csu.vis = max(1, int(list_r.height / row_h))
	ui_list_clamp(&_csu.nav, n, _csu.vis)
	if n == 0 {
		ui_text(font, "No sessions yet — Ctrl/Cmd+J (or N) starts Claude Code in the active repository.", px + 14, list_r.y, row_h, fs, GITD_SUBDUED, px + W)
	}
	mp := rl.GetMousePosition()
	for vi in 0 ..< _csu.vis {
		idx := _csu.nav.scroll + vi
		if idx >= n { break }
		s := _cs.list[idx]
		y := list_r.y + f32(vi) * row_h
		r := rl.Rectangle{px, y, W, row_h}
		if idx == _csu.nav.selected {
			rl.DrawRectangleRec(r, GITD_SEL)
			rl.DrawRectangleV({px, y}, {3, row_h}, GITD_BLUE)
		}
		col := claude_status_color(s)
		rl.DrawCircleV({px + 16, y + row_h * 0.5}, 5, col)
		active := s.root == e.git_mgr.root
		ui_text(font, fmt.tprintf("%s%s", s.name, " (active)" if active else ""), px + 30, y, row_h, fs, GITD_TEXT, px + 260)
		ui_text(font, claude_status_text(s), px + 260, y, row_h, fs, col, px + 400)
		ui_text(font, _cs_elapsed(s.since), px + 400, y, row_h, fs - 1, GITD_SUBDUED, px + 460)
		detail := s.message if s.status == .Waiting && s.message != "" else s.root
		ui_text(font, detail, px + 470, y, row_h, fs - 1, GITD_SUBDUED, px + W - 8)
		if ui_point_in(mp, r) && rl.IsMouseButtonPressed(.LEFT) {
			if idx == _csu.nav.selected { _cs_goto(e, s, false); dlg_end(); return }
			_csu.nav.selected = idx
		}
	}

	fy := py + H - GITD_FOOTER_H
	rl.DrawRectangleV({px, fy}, {W, GITD_FOOTER_H}, GITD_HEADER)
	ui_text(font, "Enter show · R review changes · X stop · N new (active repo) · Esc close", px + 10, fy, GITD_FOOTER_H, FONT_SIZE - 3, GITD_SUBDUED, px + W)
	dlg_end()
}
