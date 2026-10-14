package git

import "core:fmt"
import "core:os"
import "core:testing"

// Feature: features/multi-repo.feature — clone / init scenarios.

// teste: test_repo_ops_clone_parse_progress
@(test)
test_repo_ops_clone_parse_progress :: proc(t: ^testing.T) {
	ph, pct, ok := clone_parse_progress("Receiving objects:  45% (450/1000), 1.20 MiB | 2.00 MiB/s")
	testing.expect(t, ok)
	testing.expect_value(t, ph, "Receiving objects")
	testing.expect_value(t, pct, 45)
	ph, pct, ok = clone_parse_progress("remote: Counting objects: 100% (12/12), done.")
	testing.expect(t, ok)
	testing.expect_value(t, ph, "Counting objects")
	testing.expect_value(t, pct, 100)
	_, _, ok = clone_parse_progress("Cloning into 'x'...")
	testing.expect(t, !ok)
	_, _, ok = clone_parse_progress("fatal: repository 'x' does not exist")
	testing.expect(t, !ok)

	testing.expect_value(t, clone_repo_name("https://github.com/acme/editor.git"), "editor")
	testing.expect_value(t, clone_repo_name("git@github.com:acme/api"), "api")
	testing.expect_value(t, clone_repo_name("/srv/git/thing.git/"), "thing")
	testing.expect_value(t, clone_repo_name("  ssh://h/x/y  "), "y")
}

// teste: test_repo_ops_clone_local_bare
@(test)
test_repo_ops_clone_local_bare :: proc(t: ^testing.T) {
	seed := _trepo_new(t, "rclone"); defer _trepo_destroy(seed)
	_tcommit(t, seed, "f.txt", "hello\n", "initial")
	bare := fmt.aprintf("%s-origin.git", seed); defer { _ = os.remove_all(bare); delete(bare) }
	dest := fmt.aprintf("%s-clone/sub/work", seed)
	defer { _ = os.remove_all(fmt.tprintf("%s-clone", seed)); delete(dest) }
	_ = os.remove_all(bare)
	_ = os.remove_all(fmt.tprintf("%s-clone", seed))
	_tgit(t, seed, "clone", "-q", "--bare", seed, bare)

	q: Git_Queue; git_queue_init(&q, ""); defer git_queue_destroy(&q)
	prog := new(Clone_Progress); defer clone_progress_destroy(prog)
	prog.percent = -1
	id := git_request_clone(&q, bare, dest, prog); defer git_release(&q, id)
	c := _tget(t, &q, id, Git_Custom)
	if c == nil { return }
	res := git_custom_as(c^, Repo_Op_Result)
	testing.expectf(t, res.ok, "clone failed: %s / %s", res.message, res.output)
	testing.expect_value(t, res.op, Repo_Op.Clone)
	testing.expect(t, os.exists(fmt.tprintf("%s/f.txt", dest)))
	testing.expect_value(t, _tgit_out(dest, "log", "-1", "--format=%s"), "initial")
	testing.expect_value(t, _tgit_out(dest, "rev-parse", "--abbrev-ref", "HEAD@{u}"), "origin/main")

	// Same destination again: refused with a clear message, nothing touched.
	id2 := git_request_clone(&q, bare, dest); defer git_release(&q, id2)
	c2 := _tget(t, &q, id2, Git_Custom)
	if c2 == nil { return }
	r2 := git_custom_as(c2^, Repo_Op_Result)
	testing.expect(t, !r2.ok)
	testing.expectf(t, len(r2.message) > 0 && r2.message[:13] == "Clone failed:", "message: %s", r2.message)
}

// teste: test_repo_ops_clone_bad_url
@(test)
test_repo_ops_clone_bad_url :: proc(t: ^testing.T) {
	base := _trepo_new(t, "rclonebad"); defer _trepo_destroy(base)
	dest := fmt.aprintf("%s/clone-here", base); defer delete(dest)
	q: Git_Queue; git_queue_init(&q, ""); defer git_queue_destroy(&q)
	id := git_request_clone(&q, fmt.tprintf("%s/does-not-exist.git", base), dest); defer git_release(&q, id)
	c := _tget(t, &q, id, Git_Custom)
	if c == nil { return }
	res := git_custom_as(c^, Repo_Op_Result)
	testing.expect(t, !res.ok)
	testing.expect_value(t, res.kind, Remote_Error_Kind.Remote_Not_Found)
	testing.expectf(t, res.message == "Clone failed: repository not found (check the URL and your access).", "message: %s", res.message)
	testing.expect(t, !os.exists(fmt.tprintf("%s/.git", dest)))

	// Empty URL fails fast without running git.
	id2 := git_request_clone(&q, "", dest); defer git_release(&q, id2)
	c2 := _tget(t, &q, id2, Git_Custom)
	if c2 == nil { return }
	testing.expect_value(t, git_custom_as(c2^, Repo_Op_Result).message, "Clone failed: empty URL.")
}

// teste: test_repo_ops_init
@(test)
test_repo_ops_init :: proc(t: ^testing.T) {
	base := _trepo_new(t, "rinit"); defer _trepo_destroy(base)
	dir := fmt.aprintf("%s/nested/new-repo", base); defer delete(dir)
	q: Git_Queue; git_queue_init(&q, ""); defer git_queue_destroy(&q)
	id := git_request_init(&q, dir); defer git_release(&q, id)
	c := _tget(t, &q, id, Git_Custom)
	if c == nil { return }
	res := git_custom_as(c^, Repo_Op_Result)
	testing.expectf(t, res.ok, "init: %s %s", res.message, res.output)
	testing.expect(t, os.is_dir(fmt.tprintf("%s/.git", dir)))
	testing.expect_value(t, _tgit_out(dir, "rev-parse", "--is-inside-work-tree"), "true")

	// A file in the way: clear error.
	file := fmt.tprintf("%s/afile", base)
	_ = os.write_entire_file(file, transmute([]u8)string("x"))
	id2 := git_request_init(&q, file); defer git_release(&q, id2)
	c2 := _tget(t, &q, id2, Git_Custom)
	if c2 == nil { return }
	r2 := git_custom_as(c2^, Repo_Op_Result)
	testing.expect(t, !r2.ok)
	testing.expectf(t, r2.message[:len("Init failed: not a directory")] == "Init failed: not a directory", "message: %s", r2.message)
}
