package editor

// Forge panel (ticket #14, features/forge.feature, ADR 0008): GitHub/GitLab
// pull requests (checks, diff, comments) and pipelines/jobs (trigger, retry).
// Registers itself via @(init) (ADR 0001) — "Forge: Toggle" in the palette,
// Ctrl/Cmd+Alt+P. All network/subprocess work runs on the forge package's
// worker thread; this file only submits ops and applies results each frame.
//
// Keys
//   Ctrl+Tab            Pull Requests / Pipelines
//   Enter (dbl-click)   PR: open diff · Pipeline: open jobs
//   Ctrl+E              PR comments (Enter posts, Shift+Enter newline)
//   Ctrl+T              trigger pipeline on the current branch (confirm)
//   Ctrl+R              jobs view: retry the selected job (confirm)
//   Ctrl+K              set the token for this host (stored in the OS keychain)
//   F5                  refresh · Esc back / close

import "core:fmt"
import "core:os"
import "core:strings"
import "core:unicode/utf8"
import "base:runtime"
import rl "vendor:raylib"
import forge "./forge"

FORGE_PANEL_ID :: "forge"

@(init)
_forge_panel_register :: proc "contextless" () {
	ui_register_panel(Ui_Panel{
		id       = FORGE_PANEL_ID,
		title    = "Forge",
		priority = 60,
		layer    = .Overlay,
		draw     = _forge_draw,
		input    = _forge_input,
		update   = _forge_update,
		on_open  = _forge_on_open,
		command  = "Forge: Toggle",
		command_desc = "GitHub/GitLab pull requests, pipelines and comments",
		shortcut = {key = .P, mods = {.Ctrl, .Alt}},
	})
	ui_register_command(Command{"Forge: Set Token", "Save a GitHub/GitLab token for this repository's host in the OS keychain", _forge_cmd_set_token, nil})
	ui_register_command(Command{"Forge: Refresh", "Reload pull requests and pipelines", _forge_cmd_refresh, nil})
}

@(fini)
_forge_panel_fini :: proc "contextless" () {
	context = runtime.default_context()
	_forge_shutdown()
}

Forge_View :: enum u8 { PRs, Diff, Comments, Pipelines, Jobs, Token }

Forge_Confirm_Action :: enum u8 { None, Trigger, Retry }

// A display line of the comments view.
Forge_Line :: struct {
	text: string, // slice into a comment body or into a label (owned elsewhere)
	kind: u8,     // 0 body, 1 header, 2 blank
}

@(private="file")
_Forge :: struct {
	client:  forge.Client,
	view:    Forge_View,
	tab:     int, // 0 PRs, 1 Pipelines

	header:  string, // "GitHub · acme/editor · via gh · branch x" (owned)
	status:  string, // last message (owned)
	status_err: bool,

	prs:        []forge.Pull_Request,
	pr_labels:  [dynamic]string,
	pr_list:    Ui_List,
	pipes:      []forge.Pipeline,
	pipe_labels:[dynamic]string,
	pipe_list:  Ui_List,
	jobs:       []forge.Job,
	job_labels: [dynamic]string,
	job_list:   Ui_List,

	cur_pr:       i64,
	cur_pipeline: i64,
	title:        string, // title of the open PR/pipeline (owned)

	diff:       string,
	diff_lines: [dynamic]string, // slices into diff
	diff_nav:   Ui_List_Nav,

	comments:      []forge.Comment,
	comment_heads: [dynamic]string, // owned headers
	comment_lines: [dynamic]Forge_Line,
	comment_nav:   Ui_List_Nav,
	wrap_cols:     int,

	input:     [dynamic]u8,
	input_sel: bool,

	waiting:   bit_set[forge.Op],
	confirm:   Ui_Confirm,
	confirm_action: Forge_Confirm_Action,
	confirm_job:    i64,
	vis:       int,
	results:   [dynamic]forge.Result,
}
@(private="file") _fp: _Forge

// ---------------------------------------------------------------------------
// Pure helpers (forge_panel_test.odin)
// ---------------------------------------------------------------------------

// 0 context, 1 added, 2 removed, 3 hunk header, 4 file header
forge_diff_line_kind :: proc(l: string) -> int {
	switch {
	case strings.has_prefix(l, "diff --git"), strings.has_prefix(l, "+++ "), strings.has_prefix(l, "--- "),
	     strings.has_prefix(l, "new file"), strings.has_prefix(l, "deleted file"), strings.has_prefix(l, "index "),
	     strings.has_prefix(l, "rename "):
		return 4
	case strings.has_prefix(l, "@@"): return 3
	case strings.has_prefix(l, "+"):  return 1
	case strings.has_prefix(l, "-"):  return 2
	}
	return 0
}

forge_pr_label :: proc(p: forge.Pull_Request, allocator := context.allocator) -> string {
	return fmt.aprintf("[%s %-9s] #%d %s%s  — @%s  %s -> %s",
		forge.status_glyph(p.checks), forge.status_label(p.checks), p.number,
		"(draft) " if p.draft else "", p.title, p.author, p.source_branch, p.target_branch,
		allocator = allocator)
}

forge_pipeline_label :: proc(p: forge.Pipeline, allocator := context.allocator) -> string {
	return fmt.aprintf("[%s %-8s] %s  — %s  %s", forge.status_glyph(p.status), forge.status_label(p.status),
		p.name, p.branch, _forge_short_date(p.created_at), allocator = allocator)
}

forge_job_label :: proc(j: forge.Job, allocator := context.allocator) -> string {
	dur := fmt.tprintf("%dm%02ds", int(j.duration) / 60, int(j.duration) % 60) if j.duration > 0 else "-"
	return fmt.aprintf("[%s %-8s] %s%s%s  (%s)", forge.status_glyph(j.status), forge.status_label(j.status),
		j.stage, " / " if j.stage != "" else "", j.name, dur, allocator = allocator)
}

@(private="file")
_forge_short_date :: proc(iso: string) -> string {
	// "2026-10-10T12:01:00Z" -> "2026-10-10 12:01"
	if len(iso) >= 16 { return fmt.tprintf("%s %s", iso[:10], iso[11:16]) }
	return iso
}

// Greedy word wrap of `s` at `cols` columns (runes); appends slices of s.
forge_wrap :: proc(s: string, cols: int, out: ^[dynamic]string) {
	cols := max(cols, 10)
	rest := s
	for len(rest) > 0 {
		// find byte index after `cols` runes
		n, cut := 0, len(rest)
		for _, i in rest {
			if n == cols { cut = i; break }
			n += 1
		}
		if cut == len(rest) { append(out, rest); return }
		brk := cut if rest[cut] == ' ' else strings.last_index_byte(rest[:cut], ' ')
		if brk <= 0 { brk = cut }
		append(out, rest[:brk])
		rest = strings.trim_left(rest[brk:], " ")
	}
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

@(private="file")
_forge_start_dir :: proc(e: ^Editor) -> string {
	if e != nil {
		if p := active_pane(e); p != nil && p.filename != "" { return _path_dirname(p.filename) }
	}
	cwd, err := os.get_working_directory(context.temp_allocator)
	return cwd if err == nil else "."
}

@(private="file")
_forge_submit :: proc(op: forge.Op, number: i64 = 0, text := "") {
	forge.client_submit(&_fp.client, op, number, text)
	_fp.waiting += {op}
}

@(private="file")
_forge_on_open :: proc(e: ^Editor) {
	if !forge.client_running(&_fp.client) {
		forge.client_start(&_fp.client, _forge_start_dir(e))
		_forge_submit(.Detect)
	}
	_forge_refresh()
}

@(private="file")
_forge_refresh :: proc() {
	#partial switch _fp.view {
	case .Diff:     _forge_submit(.PR_Diff, _fp.cur_pr)
	case .Comments: _forge_submit(.List_Comments, _fp.cur_pr)
	case .Jobs:     _forge_submit(.List_Jobs, _fp.cur_pipeline)
	case:
		_forge_submit(.List_PRs)
		_forge_submit(.List_Pipelines)
	}
}

@(private="file")
_forge_cmd_refresh :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	if !ui_panel_is_open(FORGE_PANEL_ID) { ui_panel_open(e, FORGE_PANEL_ID); return }
	_forge_refresh()
}

@(private="file")
_forge_cmd_set_token :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	ui_panel_open(e, FORGE_PANEL_ID)
	_forge_set_view(.Token)
}

@(private="file")
_forge_set_view :: proc(v: Forge_View) {
	_forge_clear_input()
	_fp.view = v
	if v == .PRs       { _fp.tab = 0 }
	if v == .Pipelines { _fp.tab = 1 }
}

@(private="file")
_forge_clear_input :: proc() {
	for &b in _fp.input { b = 0 } // may hold a token
	clear(&_fp.input)
	_fp.input_sel = false
}

@(private="file")
_forge_free_labels :: proc(l: ^[dynamic]string) {
	for s in l { delete(s) }
	clear(l)
}

@(private="file")
_forge_shutdown :: proc() {
	forge.client_stop(&_fp.client)
	for &r in _fp.results { forge.result_destroy(&r) }
	delete(_fp.results)
	if _fp.prs != nil       { forge.prs_destroy(_fp.prs) }
	if _fp.pipes != nil     { forge.pipelines_destroy(_fp.pipes) }
	if _fp.jobs != nil      { forge.jobs_destroy(_fp.jobs) }
	if _fp.comments != nil  { forge.comments_destroy(_fp.comments) }
	_forge_free_labels(&_fp.pr_labels);   delete(_fp.pr_labels)
	_forge_free_labels(&_fp.pipe_labels); delete(_fp.pipe_labels)
	_forge_free_labels(&_fp.job_labels);  delete(_fp.job_labels)
	_forge_free_labels(&_fp.comment_heads); delete(_fp.comment_heads)
	delete(_fp.comment_lines)
	delete(_fp.diff_lines)
	delete(_fp.diff)
	delete(_fp.header); delete(_fp.status); delete(_fp.title)
	ui_list_destroy(&_fp.pr_list); ui_list_destroy(&_fp.pipe_list); ui_list_destroy(&_fp.job_list)
	ui_confirm_destroy(&_fp.confirm)
	_forge_clear_input()
	delete(_fp.input)
	_fp = {}
}

// ---------------------------------------------------------------------------
// Results (UI thread, every frame)
// ---------------------------------------------------------------------------

@(private="file")
_forge_set_status :: proc(msg: string, is_err: bool) {
	delete(_fp.status)
	_fp.status = strings.clone(msg)
	_fp.status_err = is_err
}

@(private="file")
_forge_update :: proc(e: ^Editor, dt: f32) {
	if !forge.client_running(&_fp.client) { return }
	forge.client_poll(&_fp.client, &_fp.results)
	for &r in _fp.results {
		_forge_apply(&r)
		forge.result_destroy(&r)
	}
	clear(&_fp.results)
	// Comment wrap width changed (window resize / font size): re-layout.
	if _fp.comments != nil && _fp.wrap_cols != _fp_last_cols { _forge_layout_comments() }
}

@(private="file") _fp_last_cols: int = 80

@(private="file")
_forge_apply :: proc(r: ^forge.Result) {
	_fp.waiting -= {r.op}
	if r.remote.host != "" {
		delete(_fp.header)
		via := r.auth_source if r.auth_source != "" else "anonymous"
		_fp.header = fmt.aprintf("%s · %s/%s · via %s · branch %s",
			forge.kind_label(r.remote.kind), r.remote.host, r.remote.project, via, r.branch if r.branch != "" else "?")
	}
	if r.err != "" {
		_forge_set_status(r.err, true)
		ui_banner_show(fmt.tprintf("Forge: %s", r.err), .Error, 6)
		return
	}
	switch r.op {
	case .Detect:
		_forge_set_status("", false)
	case .List_PRs:
		if _fp.prs != nil { forge.prs_destroy(_fp.prs) }
		_fp.prs = r.prs; r.prs = nil
		_forge_free_labels(&_fp.pr_labels)
		for p in _fp.prs { append(&_fp.pr_labels, forge_pr_label(p)) }
		ui_list_sync(&_fp.pr_list, _fp.pr_labels[:])
		ui_list_apply_filter(&_fp.pr_list, _fp.pr_labels[:])
		_forge_set_status(fmt.tprintf("%d open pull request(s)", len(_fp.prs)), false)
	case .List_Pipelines:
		if _fp.pipes != nil { forge.pipelines_destroy(_fp.pipes) }
		_fp.pipes = r.pipelines; r.pipelines = nil
		_forge_free_labels(&_fp.pipe_labels)
		for p in _fp.pipes { append(&_fp.pipe_labels, forge_pipeline_label(p)) }
		ui_list_apply_filter(&_fp.pipe_list, _fp.pipe_labels[:])
	case .List_Jobs:
		if r.number != _fp.cur_pipeline { return }
		if _fp.jobs != nil { forge.jobs_destroy(_fp.jobs) }
		_fp.jobs = r.jobs; r.jobs = nil
		_forge_free_labels(&_fp.job_labels)
		for j in _fp.jobs { append(&_fp.job_labels, forge_job_label(j)) }
		ui_list_apply_filter(&_fp.job_list, _fp.job_labels[:])
		_forge_set_status(fmt.tprintf("%d job(s)", len(_fp.jobs)), false)
	case .PR_Diff:
		if r.number != _fp.cur_pr { return }
		delete(_fp.diff)
		_fp.diff = r.text; r.text = ""
		clear(&_fp.diff_lines)
		it := _fp.diff
		for line in strings.split_lines_iterator(&it) { append(&_fp.diff_lines, line) }
		_fp.diff_nav = {}
		_forge_set_status(fmt.tprintf("%d diff line(s)", len(_fp.diff_lines)), false)
	case .List_Comments:
		if r.number != _fp.cur_pr { return }
		if _fp.comments != nil { forge.comments_destroy(_fp.comments) }
		_fp.comments = r.comments; r.comments = nil
		_forge_layout_comments()
		_fp.comment_nav.scroll = max(0, len(_fp.comment_lines) - max(1, _fp.vis))
		_forge_set_status(fmt.tprintf("%d comment(s)", len(_fp.comments)), false)
	case .Post_Comment:
		if _fp.view == .Comments { _forge_clear_input() }
		ui_banner_show("Comment posted", .Success)
		_forge_submit(.List_Comments, r.number)
	case .Trigger_Pipeline:
		ui_banner_show(r.text, .Success)
		_forge_set_status(r.text, false)
		_forge_submit(.List_Pipelines)
	case .Retry_Job:
		ui_banner_show(fmt.tprintf("Job %d retried", r.number), .Success)
		_forge_submit(.List_Jobs, _fp.cur_pipeline)
	case .Save_Token:
		ui_banner_show(r.text, .Success)
		_forge_set_status(r.text, false)
		if _fp.view == .Token { _forge_set_view(.PRs) }
		_forge_submit(.List_PRs)
		_forge_submit(.List_Pipelines)
	}
}

@(private="file")
_forge_layout_comments :: proc() {
	_fp.wrap_cols = _fp_last_cols
	clear(&_fp.comment_lines)
	_forge_free_labels(&_fp.comment_heads)
	if len(_fp.comments) == 0 {
		append(&_fp.comment_lines, Forge_Line{text = "(no comments yet)", kind = 2})
		return
	}
	wrapped := make([dynamic]string, context.temp_allocator)
	for c in _fp.comments {
		h := fmt.aprintf("@%s · %s", c.author, _forge_short_date(c.created_at))
		append(&_fp.comment_heads, h)
		append(&_fp.comment_lines, Forge_Line{text = h, kind = 1})
		it := c.body
		for para in strings.split_lines_iterator(&it) {
			clear(&wrapped)
			p := strings.trim_right(para, "\r")
			if p == "" { append(&_fp.comment_lines, Forge_Line{text = "", kind = 0}); continue }
			forge_wrap(p, _fp.wrap_cols, &wrapped)
			for w in wrapped { append(&_fp.comment_lines, Forge_Line{text = w, kind = 0}) }
		}
		append(&_fp.comment_lines, Forge_Line{kind = 2})
	}
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

@(private="file")
_forge_selected_pr :: proc() -> ^forge.Pull_Request {
	i := ui_list_selected_item(&_fp.pr_list)
	return &_fp.prs[i] if i >= 0 && i < len(_fp.prs) else nil
}

@(private="file")
_forge_open_diff :: proc() {
	pr := _forge_selected_pr()
	if pr == nil { return }
	_fp.cur_pr = pr.number
	delete(_fp.title); _fp.title = fmt.aprintf("#%d %s", pr.number, pr.title)
	clear(&_fp.diff_lines)
	_forge_set_view(.Diff)
	_forge_submit(.PR_Diff, pr.number)
}

@(private="file")
_forge_open_comments :: proc() {
	if _fp.view == .PRs {
		pr := _forge_selected_pr()
		if pr == nil { return }
		_fp.cur_pr = pr.number
		delete(_fp.title); _fp.title = fmt.aprintf("#%d %s", pr.number, pr.title)
	}
	if _fp.cur_pr == 0 { return }
	if _fp.comments != nil { forge.comments_destroy(_fp.comments); _fp.comments = nil }
	clear(&_fp.comment_lines)
	_forge_set_view(.Comments)
	_forge_submit(.List_Comments, _fp.cur_pr)
}

@(private="file")
_forge_open_jobs :: proc() {
	i := ui_list_selected_item(&_fp.pipe_list)
	if i < 0 || i >= len(_fp.pipes) { return }
	p := _fp.pipes[i]
	_fp.cur_pipeline = p.id
	delete(_fp.title); _fp.title = strings.clone(p.name)
	if _fp.jobs != nil { forge.jobs_destroy(_fp.jobs); _fp.jobs = nil }
	_forge_free_labels(&_fp.job_labels)
	_forge_set_view(.Jobs)
	_forge_submit(.List_Jobs, p.id)
}

@(private="file")
_forge_ask_trigger :: proc() {
	_fp.confirm_action = .Trigger
	ui_confirm_open(&_fp.confirm, "Run pipeline?", "Trigger CI on the current branch (GitHub: re-run its latest workflow run).", confirm = "Run")
}

@(private="file")
_forge_ask_retry :: proc() {
	i := ui_list_selected_item(&_fp.job_list)
	if i < 0 || i >= len(_fp.jobs) { return }
	_fp.confirm_action = .Retry
	_fp.confirm_job = _fp.jobs[i].id
	ui_confirm_open(&_fp.confirm, "Retry job?", fmt.tprintf("Job %q will run again.", _fp.jobs[i].name), confirm = "Retry")
}

@(private="file")
_forge_on_confirm :: proc(r: Ui_Confirm_Result) {
	if r != .Confirm { if r != .None { _fp.confirm_action = .None }; return }
	switch _fp.confirm_action {
	case .None:
	case .Trigger: _forge_submit(.Trigger_Pipeline)
	case .Retry:   _forge_submit(.Retry_Job, _fp.confirm_job)
	}
	_fp.confirm_action = .None
}

@(private="file")
_forge_back :: proc(e: ^Editor) {
	switch _fp.view {
	case .PRs, .Pipelines: ui_panel_close(e, FORGE_PANEL_ID)
	case .Diff, .Comments: _forge_set_view(.PRs)
	case .Jobs:            _forge_set_view(.Pipelines)
	case .Token:           _forge_set_view(.PRs if _fp.tab == 0 else .Pipelines)
	}
}

@(private="file")
_forge_input :: proc(e: ^Editor) -> bool {
	// Modal: always consumes input.
	if _fp.confirm.open { _forge_on_confirm(ui_confirm_handle_input(&_fp.confirm)); return true }
	vis := max(1, _fp.vis)

	if rl.IsKeyPressed(.F5) { _forge_refresh(); return true }
	if ctrl() && rl.IsKeyPressed(.K) { _forge_set_view(.Token); return true }

	switch _fp.view {
	case .PRs, .Pipelines:
		if ui_tabs_handle_input(&_fp.tab, 2) { _fp.view = .PRs if _fp.tab == 0 else .Pipelines; return true }
		if ctrl() && rl.IsKeyPressed(.T) { _forge_ask_trigger(); return true }
		if _fp.view == .PRs {
			if ctrl() && rl.IsKeyPressed(.E) { _forge_open_comments(); return true }
			#partial switch ui_list_handle_input(&_fp.pr_list, _fp.pr_labels[:], vis) {
			case .Activate: _forge_open_diff()
			case .Cancel:   _forge_back(e)
			}
		} else {
			#partial switch ui_list_handle_input(&_fp.pipe_list, _fp.pipe_labels[:], vis) {
			case .Activate: _forge_open_jobs()
			case .Cancel:   _forge_back(e)
			}
		}
	case .Jobs:
		if ctrl() && rl.IsKeyPressed(.R) { _forge_ask_retry(); return true }
		if ctrl() && rl.IsKeyPressed(.T) { _forge_ask_trigger(); return true }
		#partial switch ui_list_handle_input(&_fp.job_list, _fp.job_labels[:], vis) {
		case .Activate:
			i := ui_list_selected_item(&_fp.job_list)
			if i >= 0 && i < len(_fp.jobs) && _fp.jobs[i].url != "" {
				rl.SetClipboardText(to_cstring(_fp.jobs[i].url))
				ui_banner_show("Job URL copied to the clipboard")
			}
		case .Cancel: _forge_back(e)
		}
	case .Diff:
		if rl.IsKeyPressed(.ESCAPE) { _forge_back(e); return true }
		if ctrl() && rl.IsKeyPressed(.E) { _forge_open_comments(); return true }
		_forge_scroll_nav(&_fp.diff_nav, len(_fp.diff_lines), vis)
	case .Comments:
		if rl.IsKeyPressed(.ESCAPE) { _forge_back(e); return true }
		_forge_scroll_nav(&_fp.comment_nav, len(_fp.comment_lines), vis)
		if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) {
			if shift() {
				append(&_fp.input, '\n')
			} else if len(strings.trim_space(string(_fp.input[:]))) > 0 && .Post_Comment not_in _fp.waiting {
				_forge_submit(.Post_Comment, _fp.cur_pr, string(_fp.input[:]))
			}
			return true
		}
		text_input_handle(&_fp.input, &_fp.input_sel)
	case .Token:
		if rl.IsKeyPressed(.ESCAPE) { _forge_back(e); return true }
		if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) {
			tok := strings.trim_space(string(_fp.input[:]))
			if tok != "" { _forge_submit(.Save_Token, 0, tok) }
			_forge_clear_input()
			return true
		}
		text_input_handle(&_fp.input, &_fp.input_sel)
	}
	return true
}

// Scroll-only navigation for text views (the "selection" is the top line).
@(private="file")
_forge_scroll_nav :: proc(n: ^Ui_List_Nav, count, vis: int) {
	delta := 0
	switch {
	case key_rep(.DOWN):      delta = 1
	case key_rep(.UP):        delta = -1
	case key_rep(.PAGE_DOWN): delta = vis
	case key_rep(.PAGE_UP):   delta = -vis
	case rl.IsKeyPressed(.HOME) && ctrl(): n.scroll = 0
	case rl.IsKeyPressed(.END) && ctrl():  n.scroll = max(0, count - vis)
	}
	n.scroll = clamp(n.scroll + delta, 0, max(0, count - vis))
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

@(private="file") _FORGE_TABS := []string{"Pull Requests", "Pipelines"}

@(private="file")
_forge_draw :: proc(e: ^Editor, font: rl.Font, sw, sh: f32) {
	W := min(f32(1100), sw - 40)
	H := min(f32(680), sh - 40)
	HDR :: f32(34)
	TAB :: f32(30)
	FTR :: f32(26)
	busy := _fp.confirm.open

	rl.DrawRectangle(0, 0, i32(sw), i32(sh), {0, 0, 0, 150})
	px, py := dlg_begin((sw - W) * 0.5, max(20, sh * 0.06), W, H, BG, DIVIDER_COL)

	rl.DrawRectangleRec({px, py, W, HDR}, STATUS_BG)
	ui_text(font, "Forge", px + 12, py, HDR, FONT_SIZE, ACCENT_COL, px + W)
	hdr := _fp.header if _fp.header != "" else "detecting remote..."
	ui_text(font, hdr, px + 80, py, HDR, FONT_SIZE - 3, LINENUM, px + W - 110)
	if _fp.waiting != {} {
		dots := int(rl.GetTime() * 3) % 4
		ui_text(font, fmt.tprintf("loading%s", strings.repeat(".", dots, context.temp_allocator)), px + W - 100, py, HDR, FONT_SIZE - 3, DIAG_WARN_COL, px + W)
	}

	in_lists := _fp.view == .PRs || _fp.view == .Pipelines
	if ui_tabs(font, {px, py + HDR, W, TAB}, _FORGE_TABS, &_fp.tab, !busy && in_lists) {
		_fp.view = .PRs if _fp.tab == 0 else .Pipelines
	}

	body := rl.Rectangle{px + 10, py + HDR + TAB + 8, W - 20, H - HDR - TAB - FTR - 16}
	FH :: f32(28)
	hint: string
	switch _fp.view {
	case .PRs:
		ui_list_filter_draw(&_fp.pr_list, font, {body.x, body.y, body.width, FH}, "Type to filter pull requests...")
		lr := rl.Rectangle{body.x, body.y + FH + 6, body.width, body.height - FH - 6}
		_fp.vis = int(lr.height / UI_ROW_H)
		if _, dbl := ui_list_draw(&_fp.pr_list, font, lr, _fp.pr_labels[:], UI_ROW_H, !busy); dbl { _forge_open_diff() }
		hint = "Enter diff  Ctrl+E comments  Ctrl+T run pipeline  Ctrl+K token  F5 refresh  Ctrl+Tab tabs  Esc close"
	case .Pipelines:
		ui_list_filter_draw(&_fp.pipe_list, font, {body.x, body.y, body.width, FH}, "Type to filter pipelines...")
		lr := rl.Rectangle{body.x, body.y + FH + 6, body.width, body.height - FH - 6}
		_fp.vis = int(lr.height / UI_ROW_H)
		if _, dbl := ui_list_draw(&_fp.pipe_list, font, lr, _fp.pipe_labels[:], UI_ROW_H, !busy); dbl { _forge_open_jobs() }
		hint = "Enter jobs  Ctrl+T run pipeline on current branch  Ctrl+K token  F5 refresh  Ctrl+Tab tabs  Esc close"
	case .Jobs:
		ui_text(font, fmt.tprintf("Jobs of %s", _fp.title), body.x, body.y, FH, FONT_SIZE - 1, ACCENT_COL, body.x + body.width)
		lr := rl.Rectangle{body.x, body.y + FH + 6, body.width, body.height - FH - 6}
		_fp.vis = int(lr.height / UI_ROW_H)
		ui_list_draw(&_fp.job_list, font, lr, _fp.job_labels[:], UI_ROW_H, !busy)
		hint = "Ctrl+R retry job  Enter copy job URL  Ctrl+T run pipeline  F5 refresh  Esc back"
	case .Diff:
		ui_text(font, fmt.tprintf("Diff of %s", _fp.title), body.x, body.y, FH, FONT_SIZE - 1, ACCENT_COL, body.x + body.width)
		tr := rl.Rectangle{body.x, body.y + FH + 6, body.width, body.height - FH - 6}
		_forge_draw_diff(font, tr, busy)
		hint = "Up/Dn PgUp/PgDn wheel scroll  Ctrl+E comments  F5 reload  Esc back"
	case .Comments:
		ui_text(font, fmt.tprintf("Comments on %s", _fp.title), body.x, body.y, FH, FONT_SIZE - 1, ACCENT_COL, body.x + body.width)
		IH :: f32(32)
		tr := rl.Rectangle{body.x, body.y + FH + 6, body.width, body.height - FH - 6 - IH - 8}
		_forge_draw_comments(font, tr, busy)
		_forge_draw_input(font, {body.x, tr.y + tr.height + 8, body.width, IH}, false,
			"Write a comment... (Enter posts, Shift+Enter newline)")
		hint = "Enter post  Shift+Enter newline  Up/Dn PgUp/PgDn scroll  F5 reload  Esc back"
	case .Token:
		host := _fp.header if _fp.header != "" else "this repository's host"
		ui_text(font, "Set token", body.x, body.y, FH, FONT_SIZE, ACCENT_COL, body.x + body.width)
		dlg_text(font, fmt.tprintf("Personal access token for %s", host), body.x, body.y + FH + 4, FONT_SIZE - 2, CHAR_SPACING, TEXT, body.x + body.width, 0)
		dlg_text(font, "Stored in the OS secret store (Keychain / Secret Service / Credential Manager), per host.", body.x, body.y + FH + 28, FONT_SIZE - 3, CHAR_SPACING, LINENUM, body.x + body.width, 0)
		dlg_text(font, "Not needed when `gh` / `glab` is logged in for the host (used first). Scopes: GitHub repo+workflow, GitLab api.", body.x, body.y + FH + 50, FONT_SIZE - 3, CHAR_SPACING, LINENUM, body.x + body.width, 0)
		_forge_draw_input(font, {body.x, body.y + FH + 84, body.width, 32}, true, "Paste the token and press Enter")
		hint = "Enter save  Esc cancel"
	}

	fy := py + H - FTR
	rl.DrawRectangleRec({px, fy, W, FTR}, STATUS_BG)
	if _fp.status != "" {
		col := MSG_COL if _fp.status_err else LINENUM
		ui_text(font, _fp.status, px + 10, fy, FTR, FONT_SIZE - 4, col, px + W)
		if !_fp.status_err { // errors get the whole footer
			stw := ui_text_w(font, _fp.status, FONT_SIZE - 4)
			ui_text(font, fmt.tprintf("|   %s", hint), px + 24 + stw, fy, FTR, FONT_SIZE - 4, LINENUM, px + W)
		}
	} else {
		ui_text(font, hint, px + 10, fy, FTR, FONT_SIZE - 4, LINENUM, px + W)
	}
	dlg_end()

	_forge_on_confirm(ui_confirm_draw(&_fp.confirm, font, sw, sh))
}

@(private="file")
_forge_wheel :: proc(n: ^Ui_List_Nav, r: rl.Rectangle, count, vis: int, busy: bool) {
	if busy || !ui_point_in(rl.GetMousePosition(), r) { return }
	w := rl.GetMouseWheelMove()
	if w != 0 { n.scroll = clamp(n.scroll + (w > 0 ? -3 : 3), 0, max(0, count - vis)) }
}

@(private="file")
_forge_draw_diff :: proc(font: rl.Font, r: rl.Rectangle, busy: bool) {
	rl.DrawRectangleRec(r, STATUS_BG)
	size := FONT_SIZE - 2
	lh := size + 4
	vis := max(1, int(r.height / lh))
	_fp.vis = vis
	_forge_wheel(&_fp.diff_nav, r, len(_fp.diff_lines), vis, busy)
	if len(_fp.diff_lines) == 0 {
		ui_text(font, "loading diff..." if .PR_Diff in _fp.waiting else "(empty diff)", r.x + 8, r.y, lh, size, LINENUM, r.x + r.width)
		return
	}
	rl.BeginScissorMode(i32(r.x), i32(r.y), i32(r.width), i32(r.height))
	for i in 0 ..< vis {
		idx := _fp.diff_nav.scroll + i
		if idx >= len(_fp.diff_lines) { break }
		l := _fp.diff_lines[idx]
		y := r.y + f32(i) * lh
		col := TEXT
		switch forge_diff_line_kind(l) {
		case 1: col = DIFF_ADD_COL; rl.DrawRectangleRec({r.x, y, r.width, lh}, DIFF_ADD_BG)
		case 2: col = DIFF_DEL_COL; rl.DrawRectangleRec({r.x, y, r.width, lh}, DIFF_DEL_BG)
		case 3: col = ACCENT_COL
		case 4: col = DIAG_WARN_COL
		}
		dlg_text(font, _forge_detab(l), r.x + 6, y + 2, size, CHAR_SPACING, col, r.x + r.width, 6)
	}
	rl.EndScissorMode()
	dlg_restore()
}

@(private="file")
_forge_detab :: proc(s: string) -> string {
	if strings.index_byte(s, '\t') < 0 { return s }
	r, _ := strings.replace_all(s, "\t", "    ", context.temp_allocator)
	return r
}

@(private="file")
_forge_draw_comments :: proc(font: rl.Font, r: rl.Rectangle, busy: bool) {
	rl.DrawRectangleRec(r, STATUS_BG)
	size := FONT_SIZE - 2
	lh := size + 6
	vis := max(1, int(r.height / lh))
	_fp.vis = vis
	cw := ui_text_w(font, "M", size) + CHAR_SPACING
	if cw > 0 { _fp_last_cols = max(20, int((r.width - 24) / cw)) }
	_forge_wheel(&_fp.comment_nav, r, len(_fp.comment_lines), vis, busy)
	if len(_fp.comment_lines) == 0 {
		ui_text(font, "loading comments...", r.x + 8, r.y, lh, size, LINENUM, r.x + r.width)
		return
	}
	rl.BeginScissorMode(i32(r.x), i32(r.y), i32(r.width), i32(r.height))
	for i in 0 ..< vis {
		idx := _fp.comment_nav.scroll + i
		if idx >= len(_fp.comment_lines) { break }
		l := _fp.comment_lines[idx]
		y := r.y + f32(i) * lh
		switch l.kind {
		case 1: dlg_text(font, l.text, r.x + 8, y + 3, size, CHAR_SPACING, ACCENT_COL, r.x + r.width, 8)
		case 0: dlg_text(font, _forge_detab(l.text), r.x + 20, y + 3, size, CHAR_SPACING, TEXT, r.x + r.width, 8)
		case 2: if l.text != "" { dlg_text(font, l.text, r.x + 8, y + 3, size, CHAR_SPACING, LINENUM, r.x + r.width, 8) }
		}
	}
	rl.EndScissorMode()
	dlg_restore()
}

@(private="file")
_forge_draw_input :: proc(font: rl.Font, r: rl.Rectangle, masked: bool, placeholder: string) {
	rl.DrawRectangleRec(r, STATUS_BG)
	rl.DrawRectangleLinesEx(r, 1, ACCENT_COL)
	size := FONT_SIZE - 1
	ty := r.y + (r.height - size) * 0.5
	if len(_fp.input) == 0 {
		dlg_text(font, placeholder, r.x + 8, ty, size, CHAR_SPACING, LINENUM, r.x + r.width, 8)
		rl.DrawRectangleV({r.x + 8, ty}, {2, size}, ACCENT_COL)
		return
	}
	shown: string
	if masked {
		shown = strings.repeat("*", min(len(_fp.input), 64), context.temp_allocator)
	} else {
		shown, _ = strings.replace_all(string(_fp.input[:]), "\n", " ⏎ ", context.temp_allocator)
	}
	// Keep the end (caret) visible.
	maxw := r.width - 20
	for len(shown) > 0 && ui_text_w(font, shown, size) > maxw {
		_, n := utf8.decode_rune_in_string(shown)
		shown = shown[n:]
	}
	tw := ui_text_w(font, shown, size)
	if _fp.input_sel { rl.DrawRectangleRec({r.x + 6, ty - 2, tw + 4, size + 4}, ui_with_alpha(ACCENT_COL, 60)) }
	dlg_text(font, shown, r.x + 8, ty, size, CHAR_SPACING, TEXT, r.x + r.width, 8)
	rl.DrawRectangleV({r.x + 8 + tw, ty}, {2, size}, ACCENT_COL)
}
