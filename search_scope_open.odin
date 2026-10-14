package editor

// ===========================================================================
// Opening a branch-scoped search result (ticket #12, ADR 0002).
//
//   search_open_result(e, &r, scope)   // palette Enter on a .Search row
//
// - Workspace scope, or the checked-out branch: jump straight to the file.
// - Local branch not checked out: ask "Checkout & edit" / "Open read-only" /
//   Cancel.
// - Remote branch without a local copy: ask to create the local branch with
//   upstream (`git switch -c <local> --track <remote>/<branch>`) and edit.
// - Remote branch whose local copy is checked out: ask to edit the local copy.
// - Checkout blocked by local changes: offer Smart Checkout (stash push -u →
//   switch → stash pop; pop conflicts open the merge resolver panel).
// Every git call runs on the git queue (git_request_custom /
// git_request_file_at), never on the UI thread. The UI lives in the "search"
// panel (id combined in the epic), which only shows the confirm dialog.
// ===========================================================================

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import rl "vendor:raylib"
import "git"

SEARCH_PANEL_ID :: "search"

// Snapshot of a branch, enough for the scope picker and open decisions.
Scope_Branch :: struct {
	name:      string, // "feature", "origin/feature"
	ref:       string, // "refs/heads/feature"
	is_remote: bool,
	is_head:   bool,
}

// Branch list cache (main thread), refreshed by search_scope_refresh_branches.
search_scope_branches: [dynamic]Scope_Branch

@(private="file") _branches_job: git.Job_Id

@(init)
_search_scope_register :: proc "contextless" () {
	ui_register_panel(Ui_Panel{
		id       = SEARCH_PANEL_ID,
		title    = "Search",
		priority = 95,
		layer    = .Overlay,
		draw     = _search_panel_draw,
		input    = _search_panel_input,
		update   = _search_panel_update,
	})
}

@(fini)
_search_scope_fini :: proc "contextless" () {
	context = runtime.default_context()
	_branches_free()
	delete(search_scope_branches)
	_pending_reset()
}

@(private="file")
_branches_free :: proc() {
	for &b in search_scope_branches { delete(b.name); delete(b.ref) }
	clear(&search_scope_branches)
}

// Asynchronously reloads search_scope_branches (no-op without a repo).
search_scope_refresh_branches :: proc(e: ^Editor) {
	if e.git_mgr.root == "" { return }
	_branches_job = git.git_request_branches(&e.git_mgr.queue)
	git.git_on_done(&e.git_mgr.queue, _branches_job, proc(r: ^git.Git_Result, user: rawptr) {
		if r.id != _branches_job { return } // a newer refresh is on its way
		_branches_job = 0
		list, ok := r.payload.([]git.Branch)
		if !ok { return }
		_branches_free()
		for b in list {
			append(&search_scope_branches, Scope_Branch{
				name = strings.clone(b.name), ref = strings.clone(b.ref),
				is_remote = b.is_remote, is_head = b.is_head,
			})
		}
	})
}

// ---------------------------------------------------------------------------
// Pure decision
// ---------------------------------------------------------------------------

Search_Open_Action :: enum u8 {
	Jump,             // open the file on disk directly
	Ask_Checkout,     // local branch exists, not checked out
	Ask_Create_Track, // remote branch with no local copy
	Ask_Edit_Local,   // remote branch whose local copy is checked out
}

// Pure: what opening a result of `scope` should do, given the branch list.
// local_name is the local branch to check out (slice of scope.name).
search_open_decision :: proc(scope: Search_Scope, branches: []Scope_Branch) -> (action: Search_Open_Action, local_name: string) {
	if scope.kind == .Workspace { return .Jump, "" }
	if !scope.is_remote {
		for b in branches {
			if !b.is_remote && b.name == scope.name { return .Jump if b.is_head else .Ask_Checkout, scope.name }
		}
		return .Ask_Checkout, scope.name
	}
	local_name = scope.name
	if slash := strings.index_byte(scope.name, '/'); slash >= 0 { local_name = scope.name[slash + 1:] }
	for b in branches {
		if !b.is_remote && b.name == local_name {
			return .Ask_Edit_Local if b.is_head else .Ask_Checkout, local_name
		}
	}
	return .Ask_Create_Track, local_name
}

// Pure: places the cursor on (line, col) of `p` and selects the match
// (match_len bytes) so the searched term is highlighted.
search_place_cursor :: proc(p: ^Pane, line, col, match_len: int) {
	total  := buffer_line_count(&p.buf)
	target := clamp(line - 1, 0, max(total - 1, 0))
	ls := buffer_line_start(&p.buf, target)
	ll := buffer_line_length(&p.buf, target)
	start := ls + clamp(col - 1, 0, ll)
	end   := ls + clamp(col - 1 + max(match_len, 0), 0, ll)
	p.sel_anchor  = start
	p.cursor      = end
	p.scroll      = max(0, target - 10)
	p.scroll_anim = f32(p.scroll)
}

// ---------------------------------------------------------------------------
// Checkout operations (run on the git queue worker, or directly in tests)
// ---------------------------------------------------------------------------

Checkout_Mode :: enum u8 { Switch, Create_Track, Smart }

Checkout_Outcome :: struct {
	ok:         bool,
	blocked:    bool,     // local changes prevent the checkout → offer Smart Checkout
	conflicted: bool,     // Smart Checkout: stash pop left conflicts
	conflicts:  []string,
	msg:        string,
}

// Pure: does git's stderr say local changes block the checkout?
search_checkout_blocked :: proc(stderr: string) -> bool {
	s := strings.to_lower(stderr, context.temp_allocator)
	if strings.contains(s, "would be overwritten by checkout") || strings.contains(s, "overwritten by checkout") { return true }
	if strings.contains(s, "needs merge") || strings.contains(s, "resolve your current index first") { return true }
	if i := strings.index(s, "conflict"); i >= 0 {
		rest := s[i:]
		if p := strings.index(rest, "prevent"); p >= 0 && p < 20 && strings.contains(rest[p:], "checkout") { return true }
	}
	return false
}

// Synchronous; call only off the UI thread (git queue job, tests).
// remote = "origin/feature" for Create_Track (and Smart when the local
// branch doesn't exist yet). Allocates with context.allocator.
search_checkout_run :: proc(root: string, mode: Checkout_Mode, local, remote: string) -> (o: Checkout_Outcome) {
	switch_args :: proc(root, local, remote: string) -> []string {
		if remote != "" {
			_, _, code := search_git_capture(root, {"show-ref", "--verify", "--quiet", strings.concatenate({"refs/heads/", local}, context.temp_allocator)})
			if code != 0 {
				return slice_clone_tmp({"switch", "-c", local, "--track", remote})
			}
		}
		return slice_clone_tmp({"switch", local})
	}
	slice_clone_tmp :: proc(a: []string) -> []string {
		out := make([]string, len(a), context.temp_allocator)
		copy(out, a)
		return out
	}

	switch mode {
	case .Switch, .Create_Track:
		args := switch_args(root, local, remote if mode == .Create_Track else "")
		_, errs, code := search_git_capture(root, args)
		if code == 0 { o.ok = true; o.msg = fmt.aprintf("Switched to %s", local); return }
		o.blocked = search_checkout_blocked(errs)
		o.msg = strings.clone(_first_line(errs, "git switch failed"))
		return

	case .Smart:
		before, _, _ := search_git_capture(root, {"rev-parse", "-q", "--verify", "refs/stash"})
		_, serr, scode := search_git_capture(root, {"stash", "push", "-u", "-m", fmt.tprintf("Smart Checkout to %s", local)})
		if scode != 0 { o.msg = strings.clone(_first_line(serr, "git stash failed")); return }
		after, _, _ := search_git_capture(root, {"rev-parse", "-q", "--verify", "refs/stash"})
		stashed := strings.trim_space(after) != "" && strings.trim_space(after) != strings.trim_space(before)

		_, werr, wcode := search_git_capture(root, switch_args(root, local, remote))
		if wcode != 0 {
			if stashed { search_git_capture(root, {"stash", "pop"}) } // put the changes back
			o.msg = strings.clone(_first_line(werr, "git switch failed"))
			return
		}
		o.ok = true
		if !stashed { o.msg = fmt.aprintf("Switched to %s", local); return }
		_, _, pcode := search_git_capture(root, {"stash", "pop"})
		if pcode == 0 { o.msg = fmt.aprintf("Switched to %s (local changes restored)", local); return }
		names, _, _ := search_git_capture(root, {"diff", "--name-only", "--diff-filter=U"})
		list := make([dynamic]string)
		for l in strings.split_lines(strings.trim_space(names), context.temp_allocator) {
			if l != "" { append(&list, strings.clone(l)) }
		}
		o.conflicted = true
		o.conflicts  = list[:]
		o.msg = fmt.aprintf("Switched to %s — restoring local changes conflicted in %d file(s) (stash kept)", local, len(list))
		return
	}
	return
}

@(private="file")
_first_line :: proc(s, fallback: string) -> string {
	t := strings.trim_space(s)
	if t == "" { return fallback }
	if nl := strings.index_byte(t, '\n'); nl >= 0 { t = t[:nl] }
	return strings.trim_prefix(t, "error: ")
}

// Runs `git <args>` in root capturing stdout and stderr (temp-allocated).
// Off the UI thread only.
search_git_capture :: proc(root: string, args: []string) -> (stdout, stderr: string, code: int) {
	cmd := make([]string, len(args) + 1, context.temp_allocator)
	cmd[0] = "git"
	copy(cmd[1:], args)
	sync.mutex_lock(&search_proc_mu)
	st, out, errb, err := os.process_exec({working_dir = root, command = cmd}, context.temp_allocator)
	sync.mutex_unlock(&search_proc_mu)
	if err != nil { return "", "failed to run git", -1 }
	return string(out), string(errb), st.exit_code
}

// Git_Work_Proc: args = {mode, local, remote}.
@(private="file")
_checkout_work :: proc(root: string, args: []string, user: rawptr) -> (git.Git_Payload, string) {
	mode := Checkout_Mode(int(args[0][0] - '0'))
	o, payload := git.git_custom_new(Checkout_Outcome)
	o^ = search_checkout_run(root, mode, args[1], args[2])
	return payload, ""
}

// ---------------------------------------------------------------------------
// Pending open (main thread)
// ---------------------------------------------------------------------------

@(private="file")
_Stage :: enum u8 { None, Ask, Ask_Blocked, Busy }

@(private="file")
_Pending :: struct {
	stage:   _Stage,
	cf:      Ui_Confirm,
	result:  Search_Result, // cloned
	scope:   Search_Scope,  // cloned
	local:   string,        // heap
	remote:  string,        // heap ("" unless creating from a remote)
	action:  Search_Open_Action,
	job:     git.Job_Id,
}
@(private="file") _pend: _Pending

@(private="file")
_pending_reset :: proc() {
	search_result_free(&_pend.result)
	search_scope_free(&_pend.scope)
	if _pend.local != ""  { delete(_pend.local) }
	if _pend.remote != "" { delete(_pend.remote) }
	ui_confirm_destroy(&_pend.cf)
	_pend = {}
}

@(private="file")
_clone_result :: proc(r: Search_Result) -> Search_Result {
	return Search_Result{
		file = strings.clone(r.file), line = r.line, col = r.col,
		ctx = strings.clone(r.ctx), match_len = r.match_len,
		path = strings.clone(r.path) if r.path != "" else "",
		line_text = strings.clone(r.line_text) if r.line_text != "" else "",
	}
}

// Opens a search result honoring its scope (see the header comment).
search_open_result :: proc(e: ^Editor, r: ^Search_Result, scope: Search_Scope) {
	action, local := search_open_decision(scope, search_scope_branches[:])
	if action == .Jump || r.path == "" {
		search_jump(e, r)
		return
	}
	_pending_reset()
	_pend.result = _clone_result(r^)
	_pend.scope  = search_scope_clone(scope)
	_pend.local  = strings.clone(local)
	_pend.action = action
	if action == .Ask_Create_Track { _pend.remote = strings.clone(scope.name) }
	_pend.stage = .Ask

	switch action {
	case .Jump:
	case .Ask_Checkout:
		ui_confirm_open(&_pend.cf, "Branch not checked out",
			fmt.tprintf("To edit \"%s\" you need \"%s\" checked out. Check it out now?", r.path, local),
			confirm = "Checkout & edit", extra = "Open read-only")
	case .Ask_Create_Track:
		ui_confirm_open(&_pend.cf, "Branch only exists on the remote",
			fmt.tprintf("\"%s\" isn't available locally. Create local branch \"%s\" tracking it and check it out to edit \"%s\"?", scope.name, local, r.path),
			confirm = "Checkout & edit", extra = "Open read-only")
	case .Ask_Edit_Local:
		ui_confirm_open(&_pend.cf, "Edit your local copy?",
			fmt.tprintf("\"%s\" (checked out) is the local copy of \"%s\". Editing opens the file on disk, which may differ from the remote until you pull.", local, scope.name),
			confirm = "Edit local", extra = "Open read-only")
	}
	ui_panel_open(e, SEARCH_PANEL_ID)
}

@(private="file")
_handle_confirm :: proc(e: ^Editor, res: Ui_Confirm_Result) {
	switch res {
	case .None:
	case .Cancel:
		_pending_reset()
		ui_panel_close(e, SEARCH_PANEL_ID)
	case .Extra:
		_open_read_only(e)
	case .Confirm:
		if _pend.stage == .Ask && _pend.action == .Ask_Edit_Local {
			r := _pend.result
			search_jump(e, &r)
			_pending_reset()
			ui_panel_close(e, SEARCH_PANEL_ID)
			return
		}
		mode := Checkout_Mode.Smart if _pend.stage == .Ask_Blocked else (Checkout_Mode.Create_Track if _pend.remote != "" else Checkout_Mode.Switch)
		mode_s := fmt.tprintf("%d", int(mode))
		_pend.job   = git.git_request_custom(&e.git_mgr.queue, _checkout_work, {mode_s, _pend.local, _pend.remote})
		_pend.stage = .Busy
		ui_banner_show(fmt.tprintf("Checking out %s...", _pend.local), .Info)
	}
}

@(private="file")
_open_read_only :: proc(e: ^Editor) {
	id := git.git_request_file_at(&e.git_mgr.queue, _pend.scope.ref, _pend.result.path)
	_pend.stage = .Busy
	git.git_on_done(&e.git_mgr.queue, id, proc(r: ^git.Git_Result, user: rawptr) {
		e := (^Editor)(user)
		defer { _pending_reset(); ui_panel_close(e, SEARCH_PANEL_ID) }
		blob, ok := r.payload.(git.File_Blob)
		if r.status != .Done || !ok || !blob.present {
			ui_banner_show(fmt.tprintf("Could not read %s at %s", _pend.result.path, _pend.scope.name), .Error)
			return
		}
		path, werr := search_write_read_only(_pend.scope.name, _pend.result.path, blob.text)
		defer delete(path)
		if werr != "" { ui_banner_show(werr, .Error); return }
		res := _pend.result
		res.file = path
		search_jump(e, &res)
		e.msg = fmt.tprintf("Read-only: %s:%s (copy from git, saving is disabled)", _pend.scope.name, _pend.result.path)
	}, e)
}

// Writes `text` to <temp>/editor-branch-view/<branch>/<path> and makes it
// read-only (saving it fails), returning the heap-allocated path.
search_write_read_only :: proc(branch, rel_path, text: string) -> (path: string, err: string) {
	tmp, terr := os.temp_directory(context.temp_allocator)
	if terr != nil { return "", "no temp directory" }
	safe_branch, _ := strings.replace_all(branch, "/", "_", context.temp_allocator)
	path = strings.concatenate({strings.trim_right(tmp, "/\\"), "/editor-branch-view/", safe_branch, "/", rel_path})
	dir := path[:max(strings.last_index_any(path, "/\\"), 0)]
	if os.make_directory_all(dir) != nil && !os.exists(dir) { delete(path); return "", "cannot create temp directory" }
	if os.exists(path) { _ = os.change_mode(path, os.perm_number(0o644)) }
	if os.write_entire_file(path, transmute([]u8)text) != nil { delete(path); return "", "cannot write read-only copy" }
	_ = os.change_mode(path, os.perm_number(0o444))
	return path, ""
}

@(private="file")
_poll_checkout :: proc(e: ^Editor) {
	if _pend.stage != .Busy || _pend.job == 0 { return }
	r, st := git.git_poll(&e.git_mgr.queue, _pend.job)
	if st == .Queued || st == .Running { return }
	defer git.git_release(&e.git_mgr.queue, _pend.job)
	_pend.job = 0
	var_o: ^Checkout_Outcome
	if st == .Done {
		if c, ok := r.payload.(git.Git_Custom); ok { var_o = git.git_custom_as(c, Checkout_Outcome) }
	}
	if var_o == nil {
		ui_banner_show("Checkout failed", .Error)
		_pending_reset(); ui_panel_close(e, SEARCH_PANEL_ID)
		return
	}
	o := var_o^
	if !o.ok && o.blocked {
		_pend.stage = .Ask_Blocked
		ui_confirm_open(&_pend.cf, "Local changes block checkout",
			fmt.tprintf("Your uncommitted changes conflict with \"%s\". Smart Checkout stashes them, switches branch, then restores them (conflicts open in the resolver).", _pend.local),
			confirm = "Smart Checkout", extra = "Open read-only")
		return
	}
	if !o.ok {
		ui_banner_show(o.msg, .Error)
		search_scope_refresh_branches(e) // Create_Track may have created the branch
		_pending_reset(); ui_panel_close(e, SEARCH_PANEL_ID)
		return
	}
	git.git_manager_refresh_now(&e.git_mgr)
	search_scope_refresh_branches(e)
	if o.conflicted {
		ui_banner_show(o.msg, .Warning)
		ui_panel_open(e, "merge_resolver")
	} else {
		ui_banner_show(o.msg, .Success)
	}
	res := _pend.result
	search_jump(e, &res)
	_pending_reset()
	ui_panel_close(e, SEARCH_PANEL_ID)
}

// ---------------------------------------------------------------------------
// Panel procs
// ---------------------------------------------------------------------------

@(private="file")
_search_panel_update :: proc(e: ^Editor, dt: f32) {
	_poll_checkout(e)
}

@(private="file")
_search_panel_input :: proc(e: ^Editor) -> bool {
	if _pend.cf.open {
		_handle_confirm(e, ui_confirm_handle_input(&_pend.cf))
		return true
	}
	return false // busy: let the editor keep working
}

@(private="file")
_search_panel_draw :: proc(e: ^Editor, font: rl.Font, sw, sh: f32) {
	if _pend.cf.open {
		_handle_confirm(e, ui_confirm_draw(&_pend.cf, font, sw, sh))
	}
}
