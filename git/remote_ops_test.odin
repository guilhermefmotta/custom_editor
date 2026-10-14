package git

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// Bare "origin" + clone "work" (with one commit on main, upstream set) +
// clone "other". Caller: defer _tremote_destroy(&r).
@(private = "file")
_TRemote :: struct { base, bare, work, other: string }

@(private = "file")
_tremote_new :: proc(t: ^testing.T, name: string) -> (r: _TRemote) {
	r.base  = _trepo_new(t, fmt.tprintf("rops-%s", name)) // used as seed repo
	r.bare  = fmt.aprintf("%s-origin.git", r.base)
	r.work  = fmt.aprintf("%s-work", r.base)
	r.other = fmt.aprintf("%s-other", r.base)
	for d in ([]string{r.bare, r.work, r.other}) { _ = os.remove_all(d) }
	_tcommit(t, r.base, "f.txt", "a\nb\nc\n", "initial")
	_tgit(t, r.base, "clone", "-q", "--bare", r.base, r.bare)
	_tgit(t, r.base, "clone", "-q", r.bare, r.work)
	_tgit(t, r.base, "clone", "-q", r.bare, r.other)
	for d in ([]string{r.work, r.other}) {
		_tgit(t, d, "config", "user.email", "tester@example.com")
		_tgit(t, d, "config", "user.name", "Tester")
		_tgit(t, d, "config", "commit.gpgsign", "false")
		_tgit(t, d, "config", "core.autocrlf", "false")
	}
	return
}

@(private = "file")
_tremote_destroy :: proc(r: ^_TRemote) {
	for d in ([]string{r.bare, r.work, r.other}) { _ = os.remove_all(d); delete(d) }
	_trepo_destroy(r.base)
}

// Runs op on a fresh queue, waits, returns a copy of kind/ok/message checks.
@(private = "file")
_trun :: proc(t: ^testing.T, q: ^Git_Queue, op: Remote_Op, msg := "", loc := #caller_location) -> (res: ^Remote_Op_Result, id: Job_Id) {
	id = git_request_remote_op(q, op, msg)
	c := _tget(t, q, id, Git_Custom, loc)
	if c == nil { return nil, id }
	return git_custom_as(c^, Remote_Op_Result), id
}

// teste: test_remote_ops_fetch_all
@(test)
test_remote_ops_fetch_all :: proc(t: ^testing.T) {
	r := _tremote_new(t, "fetch"); defer _tremote_destroy(&r)
	h := strings.clone(_tcommit(t, r.other, "g.txt", "x\n", "from other")); defer delete(h)
	_tgit(t, r.other, "push", "-q")

	q: Git_Queue; git_queue_init(&q, r.work); defer git_queue_destroy(&q)
	res, id := _trun(t, &q, .Fetch_All); defer git_release(&q, id)
	if res == nil { return }
	testing.expectf(t, res.ok, "fetch failed: %s", res.output)
	testing.expect_value(t, _tgit_out(r.work, "rev-parse", "origin/main"), h)
}

// teste: test_remote_ops_pull_merge
@(test)
test_remote_ops_pull_merge :: proc(t: ^testing.T) {
	r := _tremote_new(t, "pmerge"); defer _tremote_destroy(&r)
	_tcommit(t, r.other, "g.txt", "x\n", "remote side")
	_tgit(t, r.other, "push", "-q")
	_tcommit(t, r.work, "h.txt", "y\n", "local side")

	q: Git_Queue; git_queue_init(&q, r.work); defer git_queue_destroy(&q)
	// Same split the UI uses: network fetch, then integrate.
	f, fid := _trun(t, &q, .Fetch_Upstream); defer git_release(&q, fid)
	if f == nil { return }
	testing.expectf(t, f.ok, "fetch: %s", f.output)
	res, id := _trun(t, &q, .Merge_Upstream); defer git_release(&q, id)
	if res == nil { return }
	testing.expectf(t, res.ok, "merge: %s %s", res.message, res.output)
	parents := strings.fields(_tgit_out(r.work, "rev-list", "--parents", "-n1", "HEAD"), context.temp_allocator)
	testing.expect_value(t, len(parents), 3)
	testing.expect(t, res.has_state && res.state.operation == .Clean)
	testing.expect_value(t, res.upstream, "origin/main")
}

// teste: test_remote_ops_pull_rebase
@(test)
test_remote_ops_pull_rebase :: proc(t: ^testing.T) {
	r := _tremote_new(t, "prebase"); defer _tremote_destroy(&r)
	_tcommit(t, r.other, "g.txt", "x\n", "remote side")
	_tgit(t, r.other, "push", "-q")
	_tcommit(t, r.work, "h.txt", "y\n", "local side")

	q: Git_Queue; git_queue_init(&q, r.work); defer git_queue_destroy(&q)
	res, id := _trun(t, &q, .Pull_Rebase); defer git_release(&q, id)
	if res == nil { return }
	testing.expectf(t, res.ok, "pull rebase: %s %s", res.message, res.output)
	testing.expect_value(t, _tgit_out(r.work, "rev-parse", "HEAD~1"), _tgit_out(r.work, "rev-parse", "origin/main"))
	testing.expect_value(t, _tgit_out(r.work, "rev-list", "--merges", "--count", "HEAD"), "0")
}

// teste: test_remote_ops_push
@(test)
test_remote_ops_push :: proc(t: ^testing.T) {
	r := _tremote_new(t, "push"); defer _tremote_destroy(&r)
	h := strings.clone(_tcommit(t, r.work, "h.txt", "y\n", "to push")); defer delete(h)

	q: Git_Queue; git_queue_init(&q, r.work); defer git_queue_destroy(&q)
	res, id := _trun(t, &q, .Push); defer git_release(&q, id)
	if res == nil { return }
	testing.expectf(t, res.ok, "push: %s", res.output)
	testing.expect_value(t, _tgit_out(r.bare, "rev-parse", "main"), h)

	// First push of a new branch sets the upstream.
	_tgit(t, r.work, "checkout", "-q", "-b", "feat")
	_tcommit(t, r.work, "i.txt", "z\n", "feat")
	res2, id2 := _trun(t, &q, .Push); defer git_release(&q, id2)
	if res2 == nil { return }
	testing.expectf(t, res2.ok, "push new branch: %s", res2.output)
	testing.expect_value(t, res2.upstream, "origin/feat")
	testing.expect_value(t, _tgit_out(r.work, "rev-parse", "--abbrev-ref", "feat@{u}"), "origin/feat")
}

// teste: test_remote_ops_push_rejected
@(test)
test_remote_ops_push_rejected :: proc(t: ^testing.T) {
	r := _tremote_new(t, "rej"); defer _tremote_destroy(&r)
	_tcommit(t, r.other, "g.txt", "x\n", "remote side")
	_tgit(t, r.other, "push", "-q")
	_tcommit(t, r.work, "h.txt", "y\n", "local side")

	q: Git_Queue; git_queue_init(&q, r.work); defer git_queue_destroy(&q)
	res, id := _trun(t, &q, .Push); defer git_release(&q, id)
	if res == nil { return }
	testing.expect(t, !res.ok)
	testing.expect_value(t, res.kind, Remote_Error_Kind.Rejected)
	testing.expect(t, strings.contains(res.message, "Pull first"))
}

// teste: test_remote_ops_force_with_lease
@(test)
test_remote_ops_force_with_lease :: proc(t: ^testing.T) {
	r := _tremote_new(t, "force"); defer _tremote_destroy(&r)
	_tcommit(t, r.work, "h.txt", "y\n", "pushed")
	_tgit(t, r.work, "push", "-q")
	_tgit(t, r.work, "commit", "-q", "--amend", "-m", "rewritten")
	h := strings.clone(_tgit_out(r.work, "rev-parse", "HEAD")); defer delete(h)

	q: Git_Queue; git_queue_init(&q, r.work); defer git_queue_destroy(&q)
	plain, pid := _trun(t, &q, .Push); defer git_release(&q, pid)
	if plain == nil { return }
	testing.expect_value(t, plain.kind, Remote_Error_Kind.Rejected)

	res, id := _trun(t, &q, .Force_Push); defer git_release(&q, id)
	if res == nil { return }
	testing.expectf(t, res.ok, "force: %s", res.output)
	testing.expect_value(t, _tgit_out(r.bare, "rev-parse", "main"), h)

	// Lease: someone else pushes; our stale remote-tracking ref refuses the force.
	_tgit(t, r.other, "pull", "-q", "--rebase=false", "--no-edit")
	_tgit(t, r.other, "reset", "-q", "--hard", "origin/main")
	_tcommit(t, r.other, "g.txt", "x\n", "theirs")
	_tgit(t, r.other, "push", "-q")
	_tgit(t, r.work, "commit", "-q", "--amend", "-m", "rewritten again")
	stale, sid := _trun(t, &q, .Force_Push); defer git_release(&q, sid)
	if stale == nil { return }
	testing.expect(t, !stale.ok)
	testing.expectf(t, stale.kind == .Stale_Lease || stale.kind == .Rejected, "kind %v: %s", stale.kind, stale.output)
}

// teste: test_remote_ops_pull_conflict
@(test)
test_remote_ops_pull_conflict :: proc(t: ^testing.T) {
	r := _tremote_new(t, "conf"); defer _tremote_destroy(&r)
	_tcommit(t, r.other, "f.txt", "a\nREMOTE\nc\n", "remote edit")
	_tgit(t, r.other, "push", "-q")
	_tcommit(t, r.work, "f.txt", "a\nLOCAL\nc\n", "local edit")

	q: Git_Queue; git_queue_init(&q, r.work); defer git_queue_destroy(&q)
	res, id := _trun(t, &q, .Pull_Merge); defer git_release(&q, id)
	if res == nil { return }
	testing.expect(t, !res.ok)
	testing.expect_value(t, res.kind, Remote_Error_Kind.Conflict)
	testing.expect(t, res.has_state)
	testing.expect_value(t, res.state.operation, Repo_Operation.Merging)
	testing.expect_value(t, len(res.state.conflicts), 1)
	if len(res.state.conflicts) == 1 { testing.expect_value(t, res.state.conflicts[0], "f.txt") }
	_tgit(t, r.work, "merge", "--abort")

	reb, rid := _trun(t, &q, .Pull_Rebase); defer git_release(&q, rid)
	if reb == nil { return }
	testing.expect_value(t, reb.kind, Remote_Error_Kind.Conflict)
	testing.expect_value(t, reb.state.operation, Repo_Operation.Rebasing)
	_tgit(t, r.work, "rebase", "--abort")
}

// teste: test_remote_ops_stash_save_pop
@(test)
test_remote_ops_stash_save_pop :: proc(t: ^testing.T) {
	r := _tremote_new(t, "stash"); defer _tremote_destroy(&r)
	q: Git_Queue; git_queue_init(&q, r.work); defer git_queue_destroy(&q)

	none, nid := _trun(t, &q, .Stash_Save); defer git_release(&q, nid)
	if none == nil { return }
	testing.expect_value(t, none.kind, Remote_Error_Kind.Nothing_To_Stash)
	nopop, npid := _trun(t, &q, .Stash_Pop); defer git_release(&q, npid)
	if nopop == nil { return }
	testing.expect_value(t, nopop.kind, Remote_Error_Kind.No_Stash)

	_twrite(r.work, "f.txt", "changed\n")
	_twrite(r.work, "new.txt", "untracked\n")
	s, sid := _trun(t, &q, .Stash_Save, "wip x"); defer git_release(&q, sid)
	if s == nil { return }
	testing.expectf(t, s.ok, "stash: %s", s.output)
	testing.expect_value(t, _tgit_out(r.work, "status", "--porcelain"), "")
	testing.expect_value(t, _tgit_out(r.work, "stash", "list", "--format=%gs"), "On main: wip x")

	// Without message
	_twrite(r.work, "f.txt", "again\n")
	s2, s2id := _trun(t, &q, .Stash_Save, "   "); defer git_release(&q, s2id)
	if s2 == nil { return }
	testing.expect(t, s2.ok)
	testing.expect(t, strings.has_prefix(_tgit_out(r.work, "stash", "list", "-n1", "--format=%gs"), "WIP on main"))

	p, pid := _trun(t, &q, .Stash_Pop); defer git_release(&q, pid)
	if p == nil { return }
	testing.expectf(t, p.ok, "pop: %s", p.output)
	data, _ := os.read_entire_file(fmt.tprintf("%s/f.txt", r.work), context.temp_allocator)
	testing.expect_value(t, string(data), "again\n")
	testing.expect_value(t, _tgit_out(r.work, "stash", "list", "--format=%gs"), "On main: wip x")
}

// teste: test_remote_ops_missing_remote_fails_fast
@(test)
test_remote_ops_missing_remote_fails_fast :: proc(t: ^testing.T) {
	r := _tremote_new(t, "missing"); defer _tremote_destroy(&r)
	_tgit(t, r.work, "remote", "set-url", "origin", fmt.tprintf("%s-does-not-exist.git", r.base))

	q: Git_Queue; git_queue_init(&q, r.work); defer git_queue_destroy(&q)
	start := time.tick_now()
	res, id := _trun(t, &q, .Fetch_All); defer git_release(&q, id)
	if res == nil { return }
	testing.expect(t, time.tick_since(start) < 15 * time.Second)
	testing.expect(t, !res.ok)
	testing.expectf(t, res.kind == .Remote_Not_Found || res.kind == .Network, "kind %v: %s", res.kind, res.output)
	testing.expect(t, res.message != "")

	// Unreachable ssh host must not prompt (BatchMode) and must fail.
	_tgit(t, r.work, "remote", "set-url", "origin", "ssh://nobody@invalid.invalid/repo.git")
	res2, id2 := _trun(t, &q, .Push); defer git_release(&q, id2)
	if res2 == nil { return }
	testing.expect(t, !res2.ok)
	testing.expectf(t, res2.kind == .Network || res2.kind == .Remote_Not_Found || res2.kind == .Auth, "kind %v: %s", res2.kind, res2.output)

	// No remote at all
	_tgit(t, r.work, "remote", "remove", "origin")
	res3, id3 := _trun(t, &q, .Fetch_All); defer git_release(&q, id3)
	if res3 == nil { return }
	testing.expect_value(t, res3.kind, Remote_Error_Kind.No_Remote)
}

// teste: test_remote_ops_classify_errors
@(test)
test_remote_ops_classify_errors :: proc(t: ^testing.T) {
	cases := []struct { out: string, kind: Remote_Error_Kind }{
		{"fatal: Authentication failed for 'https://x/y.git/'", .Auth},
		{"git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.", .Auth},
		{"fatal: could not read Username for 'https://github.com': terminal prompts disabled", .Auth},
		{"ssh: Could not resolve hostname nope: nodename nor servname provided", .Network},
		{"fatal: unable to access 'https://x/': Could not resolve host: x", .Network},
		{"fatal: '/tmp/nope.git' does not appear to be a git repository", .Remote_Not_Found},
		{"remote: Repository not found.", .Remote_Not_Found},
		{" ! [rejected]        main -> main (fetch first)\nerror: failed to push some refs", .Rejected},
		{" ! [rejected]        main -> main (stale info)", .Stale_Lease},
		{"CONFLICT (content): Merge conflict in f.txt", .Conflict},
		{"error: Your local changes to the following files would be overwritten by merge:", .Local_Changes},
		{"No local changes to save", .Nothing_To_Stash},
		{"something weird", .Other},
	}
	for c in cases {
		testing.expectf(t, remote_classify_error(c.out) == c.kind, "%q → %v, want %v", c.out, remote_classify_error(c.out), c.kind)
	}
	m := remote_error_message(.Fetch_All, .Other, "fatal: boom\nhint: ignore me\n", context.temp_allocator)
	testing.expect_value(t, m, "Fetch failed: boom")
	testing.expect(t, remote_op_is_network(.Push) && !remote_op_is_network(.Stash_Pop) && !remote_op_is_network(.Merge_Upstream))
}
