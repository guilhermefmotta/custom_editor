package editor

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import git "./git"

// Feature: features/multi-repo.feature (ticket #13). Tests build an Editor
// with repos.live = false: no chdir / registry panels (the test runner is
// multi-threaded and shares the cwd and the panel registry).

@(private="file")
_rt_tmp :: proc(name: string) -> string {
	base: string
	when ODIN_OS == .Windows {
		base = os.get_env("TEMP", context.temp_allocator)
	} else {
		base = os.get_env("TMPDIR", context.temp_allocator)
		if base == "" { base = "/tmp" }
	}
	base = strings.trim_right(base, "/\\")
	dir := fmt.aprintf("%s/editor-repos-%s-%d", base, name, os.get_pid())
	_ = os.remove_all(dir)
	_ = os.make_directory_all(dir)
	return dir
}

@(private="file")
_rt_git :: proc(t: ^testing.T, dir: string, args: ..string, loc := #caller_location) {
	out, ok := git.git_run(dir, args)
	delete(out)
	testing.expectf(t, ok, "git %v failed", args, loc = loc)
}

// Git repo with one commit in a fresh temp dir. Caller deletes + frees.
@(private="file")
_rt_repo :: proc(t: ^testing.T, name: string) -> string {
	dir := _rt_tmp(name)
	_rt_git(t, dir, "init", "-q", "-b", "main")
	_rt_git(t, dir, "config", "user.email", "tester@example.com")
	_rt_git(t, dir, "config", "user.name", "Tester")
	_rt_git(t, dir, "config", "commit.gpgsign", "false")
	_ = os.write_entire_file(fmt.tprintf("%s/a.txt", dir), transmute([]u8)fmt.tprintf("%s\n", name))
	_rt_git(t, dir, "add", "-A")
	_rt_git(t, dir, "commit", "-q", "-m", "init")
	return dir
}

@(private="file")
_rt_free_dir :: proc(dir: string) { _ = os.remove_all(dir); delete(dir) }

@(private="file")
_rt_editor :: proc() -> (e: Editor) {
	e.panes = make([dynamic]Pane)
	append(&e.panes, pane_init())
	e.split_ratio = 0.5
	return
}

// e is returned by value; repos_init must run on its final address.
@(private="file")
_rt_editor_destroy :: proc(e: ^Editor) {
	for &p in e.panes { pane_destroy(&p) }
	delete(e.panes)
	repos_destroy(e)
	recent_repos_destroy(&e.recent_repos)
	file_tree_destroy(&e.file_tree)
}

// teste: test_repos_open_switch_close
@(test)
test_repos_open_switch_close :: proc(t: ^testing.T) {
	a := _rt_repo(t, "a"); defer _rt_free_dir(a)
	b := _rt_repo(t, "b"); defer _rt_free_dir(b)
	e := _rt_editor(); repos_init(&e); defer _rt_editor_destroy(&e)

	// Nothing open: e.git_mgr is the empty manager (screens see root "").
	testing.expect(t, e.git_mgr != nil)
	testing.expect_value(t, e.git_mgr.root, "")
	testing.expect_value(t, e.repos.active, -1)
	testing.expect_value(t, repos_bar_h(&e), f32(0))

	ra, err := repos_open(&e, a)
	testing.expect_value(t, err, "")
	testing.expect_value(t, e.repos.active, 0)
	testing.expect(t, e.git_mgr == &ra.git)
	testing.expect_value(t, e.git_mgr.root, repos_norm_root(a, context.temp_allocator))
	testing.expect_value(t, ra.name, fmt.tprintf("editor-repos-a-%d", os.get_pid()))
	testing.expect_value(t, repos_bar_h(&e), REPO_BAR_H)

	// File opened in repo A's view
	fa := fmt.tprintf("%s/a.txt", a)
	testing.expect(t, pane_open(active_pane(&e), fa))

	rb, _ := repos_open(&e, fmt.tprintf("%s/", b)) // trailing slash: same folder
	testing.expect_value(t, len(e.repos.list), 2)
	testing.expect_value(t, e.repos.active, 1)
	testing.expect(t, e.git_mgr == &rb.git)
	testing.expect_value(t, active_pane(&e).filename, "") // fresh view for B
	testing.expect(t, ra.has_view)                        // A's view stashed

	// Opening A again: no duplicate, just activates it (and its view comes back)
	ra2, err2 := repos_open(&e, a)
	testing.expect_value(t, err2, "")
	testing.expect(t, ra2 == ra)
	testing.expect_value(t, len(e.repos.list), 2)
	testing.expect_value(t, e.repos.active, 0)
	testing.expect_value(t, path_basename(active_pane(&e).filename), "a.txt")

	repos_switch_next(&e, 1)
	testing.expect_value(t, e.repos.active, 1)
	repos_switch_next(&e, 1) // wraps
	testing.expect_value(t, e.repos.active, 0)

	// Close the inactive B, then the active A → nothing open again
	testing.expect(t, repos_close(&e, 1))
	testing.expect_value(t, len(e.repos.list), 1)
	testing.expect_value(t, e.repos.active, 0)
	testing.expect(t, repos_close(&e, 0))
	testing.expect_value(t, len(e.repos.list), 0)
	testing.expect_value(t, e.repos.active, -1)
	testing.expect_value(t, e.git_mgr.root, "")
	testing.expect_value(t, len(e.panes), 1)
}

// teste: test_repos_open_errors_and_limit
@(test)
test_repos_open_errors_and_limit :: proc(t: ^testing.T) {
	base := _rt_tmp("limit"); defer _rt_free_dir(base)
	e := _rt_editor(); repos_init(&e); defer _rt_editor_destroy(&e)

	_, err := repos_open(&e, fmt.tprintf("%s/missing", base))
	testing.expect(t, strings.has_prefix(err, "Not a folder"))
	f := fmt.tprintf("%s/file.txt", base)
	_ = os.write_entire_file(f, transmute([]u8)string("x"))
	_, err = repos_open(&e, f)
	testing.expect(t, strings.has_prefix(err, "Not a folder"))

	// Plain folders (no git) open too, with an empty git manager.
	for i in 0 ..< REPOS_MAX {
		d := fmt.tprintf("%s/d%d", base, i)
		_ = os.make_directory(d)
		r, oerr := repos_open(&e, d, activate = false)
		testing.expect_value(t, oerr, "")
		if r != nil { testing.expect_value(t, r.git.root, "") }
	}
	testing.expect_value(t, len(e.repos.list), REPOS_MAX)
	testing.expect_value(t, e.repos.active, -1) // activate = false
	extra := fmt.tprintf("%s/extra", base)
	_ = os.make_directory(extra)
	_, err = repos_open(&e, extra)
	testing.expect(t, strings.has_prefix(err, "Too many open repositories"))
	testing.expect_value(t, len(e.repos.list), REPOS_MAX)
	// An already open folder still activates at the limit
	_, err = repos_open(&e, fmt.tprintf("%s/d3", base))
	testing.expect_value(t, err, "")
	testing.expect_value(t, e.repos.active, 3)
}

// teste: test_repos_open_many
@(test)
test_repos_open_many :: proc(t: ^testing.T) {
	a := _rt_repo(t, "many-a"); defer _rt_free_dir(a)
	b := _rt_repo(t, "many-b"); defer _rt_free_dir(b)
	e := _rt_editor(); repos_init(&e); defer _rt_editor_destroy(&e)
	n, err := repos_open_many(&e, {a, b, fmt.tprintf("%s/nope", a), a})
	testing.expect_value(t, n, 3) // a twice = same tab
	testing.expect(t, strings.has_prefix(err, "Not a folder"))
	testing.expect_value(t, len(e.repos.list), 2)
	testing.expect_value(t, e.repos.active, 0) // first folder of the drop/selection
	// Recents: most recent first, deduplicated
	testing.expect_value(t, len(e.recent_repos.paths), 2)
	testing.expect_value(t, e.recent_repos.paths[0], repos_norm_root(b, context.temp_allocator))
}

@(private="file")
_rt_toplevel :: proc(t: ^testing.T, e: ^Editor) -> string {
	id := git.git_request_command(&e.git_mgr.queue, {"rev-parse", "--show-toplevel"})
	defer git.git_release(&e.git_mgr.queue, id)
	start := time.tick_now()
	for {
		out, st, _ := git.git_poll_as(&e.git_mgr.queue, id, git.Command_Output)
		if st == .Done { return strings.clone(strings.trim_space(out.output), context.temp_allocator) }
		if st == .Failed || st == .Unknown { return "" }
		if time.tick_since(start) > 20 * time.Second { testing.fail_now(t, "timeout") }
		time.sleep(time.Millisecond)
	}
}

// teste: test_repos_switch_changes_git_mgr
@(test)
test_repos_switch_changes_git_mgr :: proc(t: ^testing.T) {
	// The manager's refresh thread allocates with the plain heap and the main
	// thread frees it (git/manager.odin) — keep the tracking allocator out.
	context.allocator = runtime.heap_allocator()
	a := _rt_repo(t, "sw-a"); defer _rt_free_dir(a)
	b := _rt_repo(t, "sw-b"); defer _rt_free_dir(b)
	e := _rt_editor(); repos_init(&e); defer _rt_editor_destroy(&e)
	repos_open(&e, a)
	repos_open(&e, b)

	// Each repo has its own queue/worker; e.git_mgr follows the active one.
	repos_switch(&e, 0)
	ta := _rt_toplevel(t, &e)
	repos_switch(&e, 1)
	tb := _rt_toplevel(t, &e)
	testing.expect_value(t, path_basename(ta), path_basename(a))
	testing.expect_value(t, path_basename(tb), path_basename(b))
	testing.expect(t, &e.repos.list[0].git != &e.repos.list[1].git)

	// Status of a background repo keeps refreshing (repo tabs); the active one too.
	_ = os.write_entire_file(fmt.tprintf("%s/new.txt", a), transmute([]u8)string("x"))
	start := time.tick_now()
	for len(e.repos.list[0].git.current.entries) == 0 {
		git_update(&e, 20) // big dt: refresh timers fire every call
		if time.tick_since(start) > 20 * time.Second { testing.fail_now(t, "background status never refreshed") }
		time.sleep(5 * time.Millisecond)
	}
	testing.expect_value(t, e.repos.list[0].git.current.entries[0].path, "new.txt")
	testing.expect_value(t, e.repos.active, 1)
}

// teste: test_recent_repos_order_dedup_limit
@(test)
test_recent_repos_order_dedup_limit :: proc(t: ^testing.T) {
	dir := _rt_tmp("recents"); defer _rt_free_dir(dir)
	r: Recent_Repos
	defer recent_repos_destroy(&r)
	recent_repos_push(&r, "/p/a")
	recent_repos_push(&r, "/p/b")
	recent_repos_push(&r, "/p/a") // moves to the front, no duplicate
	testing.expect_value(t, len(r.paths), 2)
	testing.expect_value(t, r.paths[0], "/p/a")
	testing.expect_value(t, r.paths[1], "/p/b")
	recent_repos_push(&r, r.paths[1]) // aliasing an entry is safe
	testing.expect_value(t, r.paths[0], "/p/b")
	for i in 0 ..< RECENT_REPOS_MAX + 5 { recent_repos_push(&r, fmt.tprintf("/x/%d", i)) }
	testing.expect_value(t, len(r.paths), RECENT_REPOS_MAX)
	testing.expect_value(t, r.paths[0], fmt.tprintf("/x/%d", RECENT_REPOS_MAX + 4))

	// Persisted one per line; load dedups and caps
	file := fmt.tprintf("%s/cfg/recent_repos", dir)
	recent_repos_load(&r, file) // missing file → empty, remembers path
	testing.expect_value(t, len(r.paths), 0)
	recent_repos_push(&r, "/r/one")
	recent_repos_push(&r, "/r/two")
	testing.expect(t, recent_repos_save(&r))
	r2: Recent_Repos
	defer recent_repos_destroy(&r2)
	_ = os.write_entire_file(fmt.tprintf("%s/cfg/dup", dir), transmute([]u8)string("/r/two\n/r/two\n\n/r/one\n"))
	recent_repos_load(&r2, file)
	testing.expect_value(t, len(r2.paths), 2)
	testing.expect_value(t, r2.paths[0], "/r/two")
	recent_repos_load(&r2, fmt.tprintf("%s/cfg/dup", dir))
	testing.expect_value(t, len(r2.paths), 2)
	recent_repos_remove(&r2, "/r/two")
	testing.expect_value(t, r2.paths[0], "/r/one")
}

// teste: test_session_restores_repos
@(test)
test_session_restores_repos :: proc(t: ^testing.T) {
	a := _rt_repo(t, "ses-a"); defer _rt_free_dir(a)
	b := _rt_repo(t, "ses-b"); defer _rt_free_dir(b)

	doc: string
	{
		e := _rt_editor(); repos_init(&e); defer _rt_editor_destroy(&e)
		repos_open(&e, a)
		pane_open(active_pane(&e), fmt.tprintf("%s/a.txt", a))
		repos_open(&e, b)
		repos_open(&e, fmt.tprintf("%s/gone", a)) // error, not saved
		doc = strings.clone(session_build(&e))
	}
	defer delete(doc)

	e := _rt_editor(); repos_init(&e); defer _rt_editor_destroy(&e)
	testing.expect(t, session_restore_from(&e, doc))
	testing.expect_value(t, len(e.repos.list), 2)
	testing.expect_value(t, e.repos.active, 1) // B was active
	testing.expect_value(t, path_basename(e.git_mgr.root), path_basename(b))
	repos_switch(&e, 0)
	testing.expect_value(t, path_basename(active_pane(&e).filename), "a.txt") // A's buffers came back

	// Old single-view session files still restore (no repos)
	e2 := _rt_editor(); repos_init(&e2); defer _rt_editor_destroy(&e2)
	testing.expect(t, session_restore_from(&e2, `{"active":0,"split":"none","split_ratio":0.5,"panes":[{"filename":"","cursor":0,"scroll":0}]}`))
	testing.expect_value(t, len(e2.repos.list), 0)
}

// teste: test_repos_find_git_root_and_norm
@(test)
test_repos_find_git_root_and_norm :: proc(t: ^testing.T) {
	a := _rt_repo(t, "root"); defer _rt_free_dir(a)
	sub := fmt.tprintf("%s/src/main", a)
	_ = os.make_directory_all(sub)
	testing.expect_value(t, repos_find_git_root(sub), a)
	// Absolute + cleaned (+ symlinks resolved, e.g. macOS /var → /private/var)
	asub := repos_norm_root(sub, context.temp_allocator)
	testing.expect_value(t, repos_norm_root(fmt.tprintf("%s/src/../src/main/", a), context.temp_allocator), asub)
	set: Repo_Set
	testing.expect_value(t, repos_index_of(&set, a), -1)

	// A subfolder of a repo opens as its own tab, with the enclosing git repo.
	e := _rt_editor(); repos_init(&e); defer _rt_editor_destroy(&e)
	r, _ := repos_open(&e, sub)
	if r == nil { return }
	testing.expect_value(t, r.root, asub)
	testing.expect_value(t, r.git.root, repos_norm_root(a, context.temp_allocator))
}

// Startup with no session repositories opens the most recent repository that
// still exists (skipping missing ones) instead of stopping at the welcome screen.
@(test)
test_repos_startup_opens_most_recent :: proc(t: ^testing.T) {
	a := _rt_repo(t, "startup_a"); defer _rt_free_dir(a)
	b := _rt_repo(t, "startup_b"); defer _rt_free_dir(b)
	e := _rt_editor(); repos_init(&e); defer _rt_editor_destroy(&e)
	recent_repos_push(&e.recent_repos, a)
	recent_repos_push(&e.recent_repos, b)
	recent_repos_push(&e.recent_repos, "/no/such/repo-gone") // most recent, but missing

	repos_open_startup_default(&e, "") // working directory isn't a repository

	testing.expect_value(t, len(e.repos.list), 1)
	if len(e.repos.list) == 1 {
		testing.expect_value(t, e.repos.list[0].root, repos_norm_root(b, context.temp_allocator))
	}
}
