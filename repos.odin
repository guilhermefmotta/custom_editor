package editor

// ===========================================================================
// Multiple open repositories (ticket #13, ADR 0014).
//
// The editor keeps a list of open folders ("repos", one tab each). Each Repo
// owns its own git.Git_Manager (status + async queue + worker threads) and,
// while it is in the background, the editor view it had (panes/buffers/split,
// the repo-bound panels that were open, file tree visibility).
//
//   e.git_mgr  — ^git.Git_Manager of the ACTIVE repo. Every screen keeps using
//                `e.git_mgr.root`, `&e.git_mgr.queue`, `e.git_mgr.current`;
//                with no repo active it points at an empty manager (root "").
//   process cwd — the active repo folder (walkers, file palette, search,
//                terminal, file tree all work relative to ".").
//
// Switching (repos_switch / Ctrl+Alt+1..9 / tabs / "Repo: Switch"):
//   1. Leaving: Repo_Switch_Hook(.Leaving) runs (e.git_mgr = old repo), every
//      repo-bound registered panel is closed (its on_close releases its jobs on
//      the old queue) and remembered, palette search/file scan stopped.
//   2. Wait until the old queue has no queued/running job and no remote op is
//      running (+2 frames so update procs consume finished results), max
//      REPOS_SWITCH_MAX_WAIT seconds. Job ids are per queue, so a screen must
//      never poll an id of repo A on repo B's queue.
//   3. Swap: view stashed into the old repo, e.git_mgr/cwd/view of the new one
//      loaded, file tree reset, Repo_Switch_Hook(.Entered), its remembered
//      panels reopened (they reload from the new repo on open).
//
// Screens with state outside on_close (caches, clients bound to a root)
// subscribe with repos_register_switch_hook (callable from @(init)).
//
// Background repos: their status refresh keeps running (slower) so the tabs
// show branch + change count; their queue callbacks only run when active.
// ===========================================================================

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import git "./git"
import rl "vendor:raylib"

REPOS_MAX              :: 16
REPOS_SWITCH_MAX_WAIT  :: f32(3)
REPOS_BG_REFRESH       :: f32(15) // seconds between status refreshes of background repos
REPO_BAR_H             :: f32(26)
REPO_TABS_ID           :: "repo_tabs"
REPO_SWITCHER_ID       :: "repo_switcher"

Repo :: struct {
	root: string, // absolute folder (tab identity), owned
	name: string, // basename, owned
	git:  git.Git_Manager, // root = enclosing git repo ("" when not in one)

	// View while in the background (has_view = false → fresh single pane)
	has_view:    bool,
	panes:       [dynamic]Pane,
	active:      int,
	split:       Split_Dir,
	split_ratio: f32,
	tree_open:   bool,
	panels:      [dynamic]string, // registered panel ids (literals) to reopen
}

Repo_Switch_Phase :: enum u8 { Leaving, Entered }
Repo_Switch_Hook  :: #type proc(e: ^Editor, phase: Repo_Switch_Phase)

Repo_Set :: struct {
	list:   [dynamic]^Repo,
	active: int,   // index into list; -1 = none (welcome / scratch)
	none:   ^Repo, // pseudo-repo for "no repo": empty git manager + scratch view
	live:   bool,  // real app: chdir, panels, palette. false in tests.

	// Pending switch (see header)
	pending:     bool,
	pending_to:  ^Repo, // nil = none
	closing:     ^Repo, // destroyed once the switch away from it completes
	leaving:     bool,
	idle_frames: int,
	wait:        f32,
	close_armed: ^Repo, // dirty repo: second close request discards

	ops: git.Git_Queue, // clone / init (not bound to a repository)
}

@(private="file") _repo_hooks: [dynamic]Repo_Switch_Hook

// Optional colored dot drawn at the left of each repository tab (set from
// @(init) by another screen; ticket #17 shows the Claude session status).
repos_tab_dot: proc(r: ^Repo) -> (col: rl.Color, ok: bool)

// Subscribe to active-repo changes. Callable from @(init).
repos_register_switch_hook :: proc "contextless" (hook: Repo_Switch_Hook) {
	context = runtime.default_context()
	for h in _repo_hooks { if h == hook { return } }
	append(&_repo_hooks, hook)
}

@(fini)
_repos_fini :: proc "contextless" () {
	context = runtime.default_context()
	delete(_repo_hooks)
	_repo_hooks = nil
}

@(private="file")
_repos_run_hooks :: proc(e: ^Editor, phase: Repo_Switch_Phase) {
	for h in _repo_hooks { h(e, phase) }
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

repos_init :: proc(e: ^Editor) {
	e.repos.list   = make([dynamic]^Repo)
	e.repos.active = -1
	e.repos.none   = new(Repo)
	e.git_mgr      = &e.repos.none.git
	git.git_queue_init(&e.repos.ops, "")
}

repos_destroy :: proc(e: ^Editor) {
	git.git_queue_destroy(&e.repos.ops)
	// The active repo's view lives in e.panes (freed by editor_destroy).
	for r in e.repos.list { _repo_free(r, nil) }
	delete(e.repos.list)
	if e.repos.none != nil { _repo_free(e.repos.none, nil) }
	e.repos = {}
	e.git_mgr = nil
}

// Frees a repo: git manager (joins its threads), stashed view, strings.
// With e != nil, documents of the stashed panes are closed on the LSP first.
@(private="file")
_repo_free :: proc(r: ^Repo, e: ^Editor) {
	git.git_manager_destroy(&r.git)
	_repo_free_view(r, e)
	delete(r.panels)
	delete(r.root)
	delete(r.name)
	free(r)
}

@(private="file")
_repo_free_view :: proc(r: ^Repo, e: ^Editor) {
	for &p in r.panes {
		if e != nil && p.filename != "" { lsp_on_close(e, &p) }
		pane_lsp_destroy(&p.lsp)
		pane_destroy(&p)
	}
	delete(r.panes)
	r.panes = nil
	r.has_view = false
}

// ---------------------------------------------------------------------------
// Pure helpers (tested)
// ---------------------------------------------------------------------------

// Absolute, cleaned folder path without trailing separator (allocator).
repos_norm_root :: proc(path: string, allocator := context.allocator) -> string {
	p := strings.trim_space(path)
	if p == "" { return strings.clone("", allocator) }
	abs, err := filepath.abs(p, context.temp_allocator) // realpath: symlinks resolved
	if err != nil {
		abs = p // missing path: make it absolute by hand
		if !filepath.is_abs(p) {
			if cwd, cerr := os.get_working_directory(context.temp_allocator); cerr == nil {
				abs, _ = filepath.join({cwd, p}, context.temp_allocator)
			}
		}
	}
	c, _ := filepath.clean(abs, context.temp_allocator)
	when ODIN_OS == .Windows {
		c, _ = strings.replace_all(c, "\\", "/", context.temp_allocator)
	}
	if len(c) > 1 && (c[len(c)-1] == '/' || c[len(c)-1] == '\\') { c = c[:len(c)-1] }
	return strings.clone(c, allocator)
}

repos_index_of :: proc(set: ^Repo_Set, root: string) -> int {
	for r, i in set.list { if r.root == root { return i } }
	return -1
}

// Closest folder at or above `dir` holding a `.git` (dir or file, so
// worktrees/submodules count). "" when none. Temp-allocated.
repos_find_git_root :: proc(dir: string) -> string {
	d := dir
	for d != "" {
		if os.exists(fmt.tprintf("%s/.git", d)) { return d }
		parent := filepath.dir(d)
		if parent == d || parent == "" || parent == "." { break }
		d = parent
	}
	return ""
}

repos_active :: proc(e: ^Editor) -> ^Repo {
	if e.repos.active < 0 || e.repos.active >= len(e.repos.list) { return nil }
	return e.repos.list[e.repos.active]
}

// Height of the repo tab strip (0 when no repo is open).
repos_bar_h :: proc(e: ^Editor) -> f32 {
	return REPO_BAR_H if len(e.repos.list) > 0 else 0
}

// ---------------------------------------------------------------------------
// Open / close
// ---------------------------------------------------------------------------

// Opens `path` (a folder) as a repo tab and, with activate, switches to it.
// An already open folder is just activated. err != "" on failure.
repos_open :: proc(e: ^Editor, path: string, activate := true) -> (r: ^Repo, err: string) {
	root := repos_norm_root(path, context.temp_allocator)
	if root == "" { return nil, "Empty path" }
	if !os.is_dir(root) { return nil, fmt.tprintf("Not a folder: %s", root) }
	if i := repos_index_of(&e.repos, root); i >= 0 {
		r = e.repos.list[i]
		if activate { repos_switch(e, i) }
		return r, ""
	}
	if len(e.repos.list) >= REPOS_MAX {
		return nil, fmt.tprintf("Too many open repositories (max %d) - close one first", REPOS_MAX)
	}
	r = new(Repo)
	r.root = strings.clone(root)
	r.name = strings.clone(filepath.base(root))
	r.split_ratio = 0.5
	if groot := repos_find_git_root(root); groot != "" {
		git.git_manager_init(&r.git, groot)
	}
	append(&e.repos.list, r)
	recent_repos_push(&e.recent_repos, root)
	if e.repos.live { recent_repos_save(&e.recent_repos) }
	if activate { repos_switch(e, len(e.repos.list) - 1) }
	return r, ""
}

// Opens every folder (files in the list are opened in the editor), each in
// its own tab, and activates the first folder. Returns how many folders
// opened and the first error.
repos_open_many :: proc(e: ^Editor, paths: []string) -> (opened: int, first_err: string) {
	first: ^Repo
	files := make([dynamic]string, context.temp_allocator)
	for p in paths {
		if !os.is_dir(p) && os.exists(p) { append(&files, p); continue }
		r, err := repos_open(e, p, activate = false)
		if err != "" {
			if first_err == "" { first_err = err }
			continue
		}
		opened += 1
		if first == nil { first = r }
	}
	if first != nil {
		for r, i in e.repos.list { if r == first { repos_switch(e, i); break } }
	}
	for f in files { editor_open(e, f) }
	return
}

// Any unsaved buffer in the repo's view (the live one when active)?
repos_has_dirty :: proc(e: ^Editor, r: ^Repo) -> bool {
	panes := e.panes[:] if r == repos_active(e) else r.panes[:]
	for &p in panes {
		if p.dirty { return true }
		for t in p.tabs { if t.dirty { return true } }
	}
	return false
}

// Closes repo `idx`. A repo with unsaved buffers needs a second request.
repos_close :: proc(e: ^Editor, idx: int, force := false) -> bool {
	if idx < 0 || idx >= len(e.repos.list) { return false }
	r := e.repos.list[idx]
	if !force && repos_has_dirty(e, r) && e.repos.close_armed != r {
		e.repos.close_armed = r
		e.msg = fmt.tprintf("%s has unsaved changes - close again to discard them", r.name)
		return false
	}
	e.repos.close_armed = nil
	if idx != e.repos.active {
		_repos_remove(e, r)
		e.msg = fmt.tprintf("Closed %s", r.name)
		lsp_stop_clients_under(e, r.root)
		_repo_free(r, e)
		return true
	}
	// Active: switch away first (neighbor, or none), destroy afterwards.
	to: ^Repo
	if idx + 1 < len(e.repos.list) { to = e.repos.list[idx+1] } else if idx > 0 { to = e.repos.list[idx-1] }
	e.repos.closing = r
	_repos_request(e, to)
	return true
}

@(private="file")
_repos_remove :: proc(e: ^Editor, r: ^Repo) {
	act := repos_active(e)
	for x, i in e.repos.list {
		if x == r { ordered_remove(&e.repos.list, i); break }
	}
	e.repos.active = -1
	for x, i in e.repos.list { if x == act { e.repos.active = i } }
}

// ---------------------------------------------------------------------------
// Switching
// ---------------------------------------------------------------------------

// Requests a switch to repo `idx` (done over the next frames, see header;
// immediately when nothing can be in flight).
repos_switch :: proc(e: ^Editor, idx: int) {
	if idx < 0 || idx >= len(e.repos.list) { return }
	to := e.repos.list[idx]
	if to == repos_active(e) && !e.repos.pending { return }
	_repos_request(e, to)
}

// Switches right away (startup / session restore: nothing is in flight yet).
repos_switch_now :: proc(e: ^Editor, idx: int) {
	if idx < 0 || idx >= len(e.repos.list) { return }
	e.repos.pending, e.repos.pending_to = true, e.repos.list[idx]
	_repos_finish_switch(e)
}

repos_switch_next :: proc(e: ^Editor, dir: int) {
	n := len(e.repos.list)
	if n == 0 { return }
	cur := max(e.repos.active, 0)
	repos_switch(e, ((cur + dir) % n + n) % n)
}

@(private="file")
_repos_request :: proc(e: ^Editor, to: ^Repo) {
	e.repos.pending    = true
	e.repos.pending_to = to
	e.repos.wait       = 0
	e.repos.idle_frames = 0
	// Nothing can be in flight without a live app or from the empty manager.
	if !e.repos.live || e.repos.active < 0 {
		_repos_finish_switch(e)
	}
}

// Every frame (git_update): drives a pending switch.
repos_update :: proc(e: ^Editor, dt: f32) {
	if !e.repos.pending { return }
	if !e.repos.leaving {
		_repos_leave(e)
		e.repos.leaving = true
	}
	busy := git.git_queue_busy(&e.git_mgr.queue) > 0 || remote_ops_busy()
	e.repos.wait += dt
	if busy { e.repos.idle_frames = 0 } else { e.repos.idle_frames += 1 }
	if e.repos.idle_frames >= 2 || e.repos.wait >= REPOS_SWITCH_MAX_WAIT {
		_repos_finish_switch(e)
	} else if busy {
		e.msg = "Switching repository after the running git operation..."
	}
}

// Leaving phase (live app only): hooks, close repo-bound panels, stop
// palette search/scan.
@(private="file")
_repos_leave :: proc(e: ^Editor) {
	cur := repos_active(e)
	if cur == nil { cur = e.repos.none }
	_repos_run_hooks(e, .Leaving)
	clear(&cur.panels)
	ids := make([dynamic]string, context.temp_allocator)
	for p in ui_panels() {
		if p.open && !_repos_panel_kept(p.id) { append(&ids, p.id) }
	}
	for id in ids {
		append(&cur.panels, id)
		ui_panel_close(e, id)
	}
	git_dialog_close(&e.git_dialog)
	pal := &e.palette
	if pal.open { palette_close(pal) }
	search_start(&pal.search, "") // cancels + joins a running search
	search_set_scope(&pal.search, {}, "")
	if pal.scan_active { _palette_scan_stop(pal) }
	for f in pal.files { delete(f) }
	clear(&pal.files)
}

// Panels that are not about one repository stay open across switches.
@(private="file")
_repos_panel_kept :: proc(id: string) -> bool {
	switch id {
	case TERMINAL_PANEL_ID, SETTINGS_PANEL_ID, UI_DEMO_ID, REPO_TABS_ID, REPO_SWITCHER_ID,
	     WELCOME_ID, REPO_DIALOG_ID:
		return true
	}
	return false
}

@(private="file")
_repos_finish_switch :: proc(e: ^Editor) {
	set := &e.repos
	if set.live && !set.leaving { _repos_leave(e) }
	to      := set.pending_to
	closing := set.closing
	set.pending, set.leaving, set.pending_to, set.closing = false, false, nil, nil

	from := repos_active(e)
	if from == nil { from = set.none }
	target := to if to != nil else set.none

	// Stash the current view, or hand the scratch view (files opened before
	// any repo, e.g. from the command line) to a repo opened for the first time.
	adopt := from == set.none && to != nil && !to.has_view && repos_view_has_files(e)
	if adopt {
		to.panes, to.active, to.split, to.split_ratio = e.panes, e.active, e.split, e.split_ratio
		to.has_view = true
		e.panes = nil
	} else {
		_repo_take_view(from, e)
	}
	from.tree_open = e.file_tree.open

	// Activate the target
	set.active = -1
	for r, i in set.list { if r == to { set.active = i } }
	e.git_mgr = &target.git
	_repo_give_view(target, e)

	if closing != nil {
		_repos_remove(e, closing)
		lsp_stop_clients_under(e, closing.root)
		name := strings.clone(closing.name, context.temp_allocator)
		_repo_free(closing, e)
		e.msg = fmt.tprintf("Closed %s", name)
	}

	if set.live {
		if to != nil { _ = os.change_directory(to.root) }
		if e.palette.cwd != "" { delete(e.palette.cwd) }
		e.palette.cwd, _ = os.get_working_directory(context.allocator)
		// File tree lists "." — rebuild it for the new folder.
		was_open := target.tree_open
		file_tree_destroy(&e.file_tree)
		e.file_tree = file_tree_init()
		if was_open { file_tree_open(&e.file_tree) }
	}
	git.git_manager_refresh_now(e.git_mgr)
	if set.live {
		_repos_run_hooks(e, .Entered)
		for id in target.panels { ui_panel_open(e, id) }
		clear(&target.panels)
		if to != nil {
			ui_panel_close(e, WELCOME_ID)
			if closing == nil { e.msg = fmt.tprintf("Repository: %s", to.name) }
		}
	}
}

// Any file open in the live view?
repos_view_has_files :: proc(e: ^Editor) -> bool {
	for p in e.panes { if p.filename != "" || len(p.tabs) > 0 { return true } }
	return false
}

// Moves the editor's live view into r (e.panes is left nil).
@(private="file")
_repo_take_view :: proc(r: ^Repo, e: ^Editor) {
	if r.has_view { _repo_free_view(r, nil) }
	r.panes, r.active, r.split, r.split_ratio = e.panes, e.active, e.split, e.split_ratio
	r.has_view = true
	e.panes = nil
}

// Moves r's stashed view into the editor (fresh single pane if none).
@(private="file")
_repo_give_view :: proc(r: ^Repo, e: ^Editor) {
	if e.panes != nil {
		for &p in e.panes { pane_lsp_destroy(&p.lsp); pane_destroy(&p) }
		delete(e.panes)
	}
	if r.has_view && len(r.panes) > 0 {
		e.panes, e.active, e.split, e.split_ratio = r.panes, r.active, r.split, r.split_ratio
		r.panes = nil
		r.has_view = false
	} else {
		if r.has_view { delete(r.panes); r.panes = nil; r.has_view = false }
		e.panes = make([dynamic]Pane)
		append(&e.panes, pane_init())
		e.active, e.split, e.split_ratio = 0, .None, 0.5
	}
	e.active = clamp(e.active, 0, len(e.panes) - 1)
	if len(e.panes) < 2 { e.split = .None }
	if e.split_ratio <= 0 { e.split_ratio = 0.5 }
}

// ---------------------------------------------------------------------------
// Git per frame (called from git_update)
// ---------------------------------------------------------------------------

repos_git_update :: proc(e: ^Editor, dt: f32) {
	act := repos_active(e)
	for r in e.repos.list {
		if r == act { continue }
		git.git_manager_update_status(&r.git, dt, REPOS_BG_REFRESH)
	}
	git.git_queue_update(&e.repos.ops)
	repos_update(e, dt)
}

// Folders dropped on the window open as repo tabs; files open in the editor.
repos_handle_drop :: proc(e: ^Editor) {
	if !rl.IsFileDropped() { return }
	list := rl.LoadDroppedFiles()
	defer rl.UnloadDroppedFiles(list)
	paths := make([dynamic]string, context.temp_allocator)
	for i in 0 ..< int(list.count) {
		append(&paths, strings.clone_from_cstring(list.paths[i], context.temp_allocator))
	}
	n, err := repos_open_many(e, paths[:])
	if err != "" {
		ui_banner_show(err, .Error, 6)
	} else if n > 1 {
		e.msg = fmt.tprintf("Opened %d repositories", n)
	}
}

// ---------------------------------------------------------------------------
// Tab strip (Dock panel, always open) + switcher + commands
// ---------------------------------------------------------------------------

@(private="file") _rt_rects:  [REPOS_MAX]rl.Rectangle
@(private="file") _rt_close:  [REPOS_MAX]rl.Rectangle
@(private="file") _rt_plus:   rl.Rectangle
@(private="file") _rt_n:      int
@(private="file") _rs_list:   Ui_List

@(init)
_repos_register :: proc "contextless" () {
	ui_register_panel(Ui_Panel{
		id = REPO_TABS_ID, title = "Repository Tabs", priority = 95, layer = .Dock,
		open = true, draw = _rt_draw, input = _rt_input,
	})
	ui_register_panel(Ui_Panel{
		id = REPO_SWITCHER_ID, title = "Switch Repository", priority = 92, layer = .Overlay,
		draw = _rs_draw, input = _rs_input, on_close = _rs_on_close,
		command = "Repo: Switch...", command_desc = "Pick one of the open repositories",
	})
	ui_register_command(Command{"Repo: Next", "Switch to the next open repository", _cmd_repo_next, nil},
	                    shortcut = {key = .RIGHT_BRACKET, mods = {.Ctrl, .Alt}})
	ui_register_command(Command{"Repo: Previous", "Switch to the previous open repository", _cmd_repo_prev, nil},
	                    shortcut = {key = .LEFT_BRACKET, mods = {.Ctrl, .Alt}})
	ui_register_command(Command{"Repo: Close", "Close the active repository tab", _cmd_repo_close, nil},
	                    shortcut = {key = .W, mods = {.Ctrl, .Alt}})
	ui_register_command(Command{"Repo: Open Folders...", "Open one or more folders as repository tabs", _cmd_repo_open, nil},
	                    shortcut = {key = .O, mods = {.Ctrl, .Alt}})
	KEYS := [9]rl.KeyboardKey{.ONE, .TWO, .THREE, .FOUR, .FIVE, .SIX, .SEVEN, .EIGHT, .NINE}
	NAMES := [9]string{"Repo: Switch to 1", "Repo: Switch to 2", "Repo: Switch to 3", "Repo: Switch to 4",
	                   "Repo: Switch to 5", "Repo: Switch to 6", "Repo: Switch to 7", "Repo: Switch to 8", "Repo: Switch to 9"}
	for i in 0 ..< 9 {
		ui_register_command(Command{NAMES[i], "Switch to the repository tab with this number", _cmd_repo_nth, nil},
		                    shortcut = {key = KEYS[i], mods = {.Ctrl, .Alt}})
	}
}

@(private="file")
_cmd_repo_next :: proc(e: ^Editor, p: ^Palette) { palette_close(p); repos_switch_next(e, 1) }
@(private="file")
_cmd_repo_prev :: proc(e: ^Editor, p: ^Palette) { palette_close(p); repos_switch_next(e, -1) }
@(private="file")
_cmd_repo_close :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	if e.repos.active < 0 { e.msg = "No repository open"; return }
	repos_close(e, e.repos.active)
}
@(private="file")
_cmd_repo_open :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	workspace_dialog_open(&e.workspace_dlg)
}
@(private="file")
_cmd_repo_nth :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	name := ui_command_running
	if len(name) == 0 { return }
	n := int(name[len(name)-1] - '0')
	if n < 1 || n > len(e.repos.list) { e.msg = fmt.tprintf("No repository #%d", n); return }
	repos_switch(e, n - 1)
}

// Tab label: "1 name  branch  ●3" (number = shortcut).
@(private="file")
_rt_label :: proc(r: ^Repo, i: int) -> string {
	br := r.git.current.branch
	n  := len(r.git.current.entries)
	num := fmt.tprintf("%d ", i + 1) if i < 9 else ""
	switch {
	case r.git.root == "": return fmt.tprintf("%s%s", num, r.name)
	case n > 0:            return fmt.tprintf("%s%s  %s  +%d", num, r.name, br, n)
	}
	return fmt.tprintf("%s%s  %s", num, r.name, br)
}

@(private="file")
_rt_draw :: proc(e: ^Editor, font: rl.Font, sw, sh: f32) {
	_rt_n = 0
	if len(e.repos.list) == 0 { return }
	bar := rl.Rectangle{0, 0, sw, REPO_BAR_H}
	rl.DrawRectangleRec(bar, STATUS_BG)
	rl.DrawLineV({0, REPO_BAR_H - 1}, {sw, REPO_BAR_H - 1}, DIVIDER_COL)
	size := FONT_SIZE - 3
	mp := rl.GetMousePosition()
	x := f32(0)
	for r, i in e.repos.list {
		if i >= REPOS_MAX { break }
		label := _rt_label(r, i)
		w := min(ui_text_w(font, label, size) + 2 * 12 + 18, 320)
		tr := rl.Rectangle{x, 0, w, REPO_BAR_H - 1}
		on := i == e.repos.active
		pend := e.repos.pending && e.repos.pending_to == r
		if on {
			rl.DrawRectangleRec(tr, BG)
			rl.DrawRectangleRec({tr.x, tr.height - 2, tr.width, 2}, ACCENT_COL)
		} else if ui_point_in(mp, tr) || pend {
			rl.DrawRectangleRec(tr, ui_with_alpha(SEL_BG, 120))
		}
		col := TEXT if on else LINENUM
		if !on && r.git.root != "" && len(r.git.current.entries) > 0 { col = GITD_YELLOW }
		ui_text(font, label, x + 12, 0, REPO_BAR_H, size, col, x + w - 18)
		if repos_tab_dot != nil {
			if dc, ok := repos_tab_dot(r); ok { rl.DrawCircleV({x + 6, REPO_BAR_H * 0.5}, 3.5, dc) }
		}
		cr := rl.Rectangle{x + w - 18, (REPO_BAR_H - 14) * 0.5, 14, 14}
		if ui_point_in(mp, cr) { rl.DrawRectangleRec(cr, ui_with_alpha(GITD_RED, 90)) }
		ui_text(font, "×", cr.x + 3, 0, REPO_BAR_H, size, LINENUM, cr.x + cr.width)
		rl.DrawLineV({x + w, 4}, {x + w, REPO_BAR_H - 4}, DIVIDER_COL)
		_rt_rects[i] = tr
		_rt_close[i] = cr
		_rt_n = i + 1
		x += w
	}
	_rt_plus = {x + 2, 2, 22, REPO_BAR_H - 5}
	if ui_point_in(mp, _rt_plus) { rl.DrawRectangleRec(_rt_plus, ui_with_alpha(SEL_BG, 160)) }
	ui_text(font, "+", _rt_plus.x + 6, 0, REPO_BAR_H, FONT_SIZE - 1, ACCENT_COL, _rt_plus.x + _rt_plus.width)
}

@(private="file")
_rt_input :: proc(e: ^Editor) -> bool {
	if len(e.repos.list) == 0 { return false }
	mp := rl.GetMousePosition()
	if mp.y < 0 || mp.y >= REPO_BAR_H { return false }
	for p in ui_panels() { if p.open && p.layer == .Overlay { return false } } // drawn over the strip
	left, mid := rl.IsMouseButtonPressed(.LEFT), rl.IsMouseButtonPressed(.MIDDLE)
	if !left && !mid { return rl.IsMouseButtonDown(.LEFT) }
	if left && ui_point_in(mp, _rt_plus) { workspace_dialog_open(&e.workspace_dlg); return true }
	for i in 0 ..< min(_rt_n, len(e.repos.list)) {
		if !ui_point_in(mp, _rt_rects[i]) { continue }
		if mid || ui_point_in(mp, _rt_close[i]) { repos_close(e, i) } else { repos_switch(e, i) }
		return true
	}
	return true
}

// ---- Switcher overlay ("Repo: Switch...") ----

@(private="file")
_rs_labels :: proc(e: ^Editor) -> []string {
	out := make([]string, len(e.repos.list), context.temp_allocator)
	for r, i in e.repos.list { out[i] = fmt.tprintf("%s   %s", _rt_label(r, i), r.root) }
	return out
}

@(private="file")
_rs_on_close :: proc(e: ^Editor) { ui_list_destroy(&_rs_list) }

@(private="file")
_rs_input :: proc(e: ^Editor) -> bool {
	labels := _rs_labels(e)
	switch ui_list_handle_input(&_rs_list, labels, 12) {
	case .Activate:
		i := ui_list_selected_item(&_rs_list)
		ui_panel_close(e, REPO_SWITCHER_ID)
		if i >= 0 { repos_switch(e, i) }
	case .Cancel:
		ui_panel_close(e, REPO_SWITCHER_ID)
	case .None, .Moved, .Filter_Changed:
	}
	return true
}

@(private="file")
_rs_draw :: proc(e: ^Editor, font: rl.Font, sw, sh: f32) {
	if len(e.repos.list) == 0 {
		ui_banner_show("No repository open", .Info, 3)
		ui_panel_close(e, REPO_SWITCHER_ID)
		return
	}
	labels := _rs_labels(e)
	W  := min(f32(760), sw - 40)
	H  := f32(12) * UI_ROW_H + 30 + 34 + 8
	px := (sw - W) * 0.5
	py := sh * 0.12
	rl.DrawRectangle(0, 0, i32(sw), i32(sh), {0, 0, 0, 150})
	px, py = dlg_begin(px, py, W, H, BG, DIVIDER_COL)
	ui_text(font, "Switch Repository   (Ctrl/Cmd+Alt+1..9)", px + 12, py, 30, FONT_SIZE - 1, ACCENT_COL, px + W)
	ui_list_filter_draw(&_rs_list, font, {px + 8, py + 30, W - 16, 28}, "Filter repositories...")
	lr := rl.Rectangle{px + 8, py + 64, W - 16, f32(12) * UI_ROW_H}
	if _, dbl := ui_list_draw(&_rs_list, font, lr, labels); dbl {
		i := ui_list_selected_item(&_rs_list)
		dlg_end()
		ui_panel_close(e, REPO_SWITCHER_ID)
		if i >= 0 { repos_switch(e, i) }
		return
	}
	dlg_end()
}
