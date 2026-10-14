package git

// Tests for refs_ops.odin (ticket #6, features/sidebar-refs.feature) against
// real temporary repositories, including a local bare "remote".

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
_Fixture :: struct {
	dir:  string, // working repo
	bare: string, // bare remote "origin"
	q:    Git_Queue,
}

// Repo with main pushed to a bare origin and tracking origin/main.
@(private = "file")
_fx_new :: proc(t: ^testing.T, name: string) -> ^_Fixture {
	fx := new(_Fixture)
	fx.dir = _trepo_new(t, name)
	fx.bare = fmt.aprintf("%s-bare.git", fx.dir)
	_ = os.remove_all(fx.bare)
	_tgit(t, fx.dir, "init", "-q", "--bare", "-b", "main", fx.bare)
	_tcommit(t, fx.dir, "a.txt", "base\n", "base")
	_tgit(t, fx.dir, "remote", "add", "origin", fx.bare)
	_tgit(t, fx.dir, "push", "-q", "-u", "origin", "main")
	git_queue_init(&fx.q, fx.dir)
	return fx
}

@(private = "file")
_fx_destroy :: proc(fx: ^_Fixture) {
	git_queue_destroy(&fx.q)
	_ = os.remove_all(fx.bare)
	delete(fx.bare)
	_trepo_destroy(fx.dir)
	free(fx)
}

// Runs op and returns a copy of outcome + message (temp).
@(private = "file")
_op :: proc(t: ^testing.T, fx: ^_Fixture, op: Refs_Op, loc := #caller_location) -> (Refs_Op_Outcome, string) {
	id := git_request_refs_op(&fx.q, op)
	c := _tget(t, &fx.q, id, Git_Custom, loc)
	defer git_release(&fx.q, id)
	if c == nil { return .Failed, "" }
	r := git_custom_as(c^, Refs_Op_Result)
	testing.expect(t, r != nil, loc = loc)
	if r == nil { return .Failed, "" }
	return r.outcome, strings.clone(r.message, context.temp_allocator)
}

@(private = "file")
_cur :: proc(dir: string) -> string { return _tgit_out(dir, "symbolic-ref", "--short", "HEAD") }

@(private = "file")
_read :: proc(dir, rel: string) -> string {
	data, err := os.read_entire_file(fmt.tprintf("%s/%s", dir, rel), context.temp_allocator)
	if err != nil { return "" }
	return string(data)
}

@(test)
test_refs_op_args_roundtrip :: proc(t: ^testing.T) {
	op := Refs_Op{kind = .Create_Tag, name = "v1", target = "HEAD~1", message = "msg", flag = true, index = 3}
	args := refs_op_to_args(op, context.temp_allocator)
	back, ok := refs_op_from_args(args)
	testing.expect(t, ok)
	testing.expect_value(t, back, op)
	_, bad := refs_op_from_args({"99", "", "", "", "0", "0"})
	testing.expect(t, !bad)
	testing.expect_value(t, refs_remote_branch_local_name("origin/feature/x"), "feature/x")
}

// teste: test_refs_snapshot_ahead_behind_with_bare_remote
@(test)
test_refs_snapshot_ahead_behind_with_bare_remote :: proc(t: ^testing.T) {
	fx := _fx_new(t, "refs-ab")
	defer _fx_destroy(fx)
	// origin gets a commit we don't have (behind 1), we get one it lacks (ahead 1)
	_tcommit(t, fx.dir, "b.txt", "remote\n", "remote side")
	_tgit(t, fx.dir, "push", "-q", "origin", "main")
	_tgit(t, fx.dir, "reset", "-q", "--hard", "HEAD~1")
	_tcommit(t, fx.dir, "c.txt", "local\n", "local side")
	_tgit(t, fx.dir, "branch", "feat")
	_tgit(t, fx.dir, "push", "-q", "origin", "feat")

	id := git_request_refs_snapshot(&fx.q)
	c := _tget(t, &fx.q, id, Git_Custom)
	defer git_release(&fx.q, id)
	snap := git_custom_as(c^, Refs_Snapshot)
	testing.expect(t, snap != nil)
	if snap == nil { return }
	found_main, found_remote := false, false
	for b in snap.branches {
		if b.name == "main" && !b.is_remote {
			found_main = true
			testing.expect_value(t, b.upstream, "origin/main")
			testing.expect_value(t, b.ahead, 1)
			testing.expect_value(t, b.behind, 1)
			testing.expect(t, b.is_head)
		}
		if b.name == "origin/feat" { found_remote = true; testing.expect_value(t, b.remote, "origin") }
	}
	testing.expect(t, found_main && found_remote)
	testing.expect_value(t, len(snap.remotes), 1)
	testing.expect(t, len(snap.reflog) > 0)
	testing.expect_value(t, snap.state.head_branch, "main")
}

// teste: test_refs_snapshot_lists_everything
@(test)
test_refs_snapshot_lists_everything :: proc(t: ^testing.T) {
	fx := _fx_new(t, "refs-all")
	defer _fx_destroy(fx)
	_tgit(t, fx.dir, "tag", "v0")
	_twrite(fx.dir, "a.txt", "dirty\n")
	_tgit(t, fx.dir, "stash", "push", "-q")
	// A submodule pointing at the bare repo
	_tgit(t, fx.dir, "-c", "protocol.file.allow=always", "submodule", "add", "-q", fx.bare, "sub")
	_tgit(t, fx.dir, "commit", "-q", "-m", "add sub")

	id := git_request_refs_snapshot(&fx.q)
	c := _tget(t, &fx.q, id, Git_Custom)
	defer git_release(&fx.q, id)
	snap := git_custom_as(c^, Refs_Snapshot)
	if snap == nil { testing.fail(t); return }
	testing.expect_value(t, len(snap.tags), 1)
	testing.expect_value(t, len(snap.stashes), 1)
	testing.expect_value(t, len(snap.submodules), 1)
	if len(snap.submodules) == 1 { testing.expect_value(t, snap.submodules[0].path, "sub") }
	testing.expect(t, len(snap.reflog) >= 2)
}

// teste: test_refs_op_checkout_blocked_then_smart
@(test)
test_refs_op_checkout_blocked_then_smart :: proc(t: ^testing.T) {
	fx := _fx_new(t, "refs-smart")
	defer _fx_destroy(fx)
	_tgit(t, fx.dir, "checkout", "-q", "-b", "other")
	_tcommit(t, fx.dir, "b.txt", "other\n", "other only")
	_tgit(t, fx.dir, "checkout", "-q", "main")
	_tcommit(t, fx.dir, "a.txt", "main v2\n", "main v2") // a.txt differs between branches
	_twrite(fx.dir, "a.txt", "my local edit\n")

	out, _ := _op(t, fx, {kind = .Checkout, name = "other"})
	testing.expect_value(t, out, Refs_Op_Outcome.Blocked_Local_Changes)
	testing.expect_value(t, _cur(fx.dir), "main")

	out2, msg := _op(t, fx, {kind = .Smart_Checkout, name = "other"})
	// Popping "my local edit" over other's a.txt ("base") conflicts or merges;
	// either way we are on "other" and the edit is not lost.
	testing.expectf(t, out2 == .Ok || out2 == .Conflicts, "outcome %v %q", out2, msg)
	testing.expect_value(t, _cur(fx.dir), "other")
	testing.expect(t, strings.contains(_read(fx.dir, "a.txt"), "my local edit"))
}

@(test)
test_refs_op_smart_checkout_restores_changes :: proc(t: ^testing.T) {
	fx := _fx_new(t, "refs-smart2")
	defer _fx_destroy(fx)
	_tgit(t, fx.dir, "branch", "other")
	_twrite(fx.dir, "a.txt", "edit\n")
	_twrite(fx.dir, "new.txt", "untracked\n")
	out, msg := _op(t, fx, {kind = .Smart_Checkout, name = "other"})
	testing.expectf(t, out == .Ok, "outcome %v %q", out, msg)
	testing.expect_value(t, _cur(fx.dir), "other")
	testing.expect_value(t, _read(fx.dir, "a.txt"), "edit\n")
	testing.expect_value(t, _read(fx.dir, "new.txt"), "untracked\n")
	testing.expect_value(t, _tgit_out(fx.dir, "stash", "list"), "")
}

// teste: test_refs_op_force_checkout_discards
@(test)
test_refs_op_force_checkout_discards :: proc(t: ^testing.T) {
	fx := _fx_new(t, "refs-force")
	defer _fx_destroy(fx)
	_tgit(t, fx.dir, "checkout", "-q", "-b", "other")
	_tcommit(t, fx.dir, "a.txt", "other\n", "other a")
	_tgit(t, fx.dir, "checkout", "-q", "main")
	_twrite(fx.dir, "a.txt", "local\n")
	out, _ := _op(t, fx, {kind = .Force_Checkout, name = "other"})
	testing.expect_value(t, out, Refs_Op_Outcome.Ok)
	testing.expect_value(t, _cur(fx.dir), "other")
	testing.expect_value(t, _read(fx.dir, "a.txt"), "other\n")
}

// teste: test_refs_op_checkout_remote_creates_tracking_branch
@(test)
test_refs_op_checkout_remote_creates_tracking_branch :: proc(t: ^testing.T) {
	fx := _fx_new(t, "refs-track")
	defer _fx_destroy(fx)
	_tgit(t, fx.dir, "checkout", "-q", "-b", "feat")
	_tcommit(t, fx.dir, "f.txt", "f\n", "feat")
	_tgit(t, fx.dir, "push", "-q", "origin", "feat")
	_tgit(t, fx.dir, "checkout", "-q", "main")
	_tgit(t, fx.dir, "branch", "-q", "-D", "feat")

	out, msg := _op(t, fx, {kind = .Checkout, name = "origin/feat", flag = true})
	testing.expectf(t, out == .Ok, "%v %q", out, msg)
	testing.expect_value(t, _cur(fx.dir), "feat")
	testing.expect_value(t, _tgit_out(fx.dir, "rev-parse", "--abbrev-ref", "feat@{u}"), "origin/feat")

	// Existing local without upstream: checkout of the remote sets it
	_tgit(t, fx.dir, "checkout", "-q", "main")
	_tgit(t, fx.dir, "branch", "-q", "--unset-upstream", "feat")
	out, _ = _op(t, fx, {kind = .Checkout, name = "origin/feat", flag = true})
	testing.expect_value(t, out, Refs_Op_Outcome.Ok)
	testing.expect_value(t, _tgit_out(fx.dir, "rev-parse", "--abbrev-ref", "feat@{u}"), "origin/feat")
}

// teste: test_refs_op_create_rename_delete_branch
@(test)
test_refs_op_create_rename_delete_branch :: proc(t: ^testing.T) {
	fx := _fx_new(t, "refs-crud")
	defer _fx_destroy(fx)
	first := _tgit_out(fx.dir, "rev-parse", "HEAD")
	_tcommit(t, fx.dir, "b.txt", "b\n", "second")

	out, _ := _op(t, fx, {kind = .Create_Branch, name = "from-first", target = first})
	testing.expect_value(t, out, Refs_Op_Outcome.Ok)
	testing.expect_value(t, _tgit_out(fx.dir, "rev-parse", "from-first"), first)
	testing.expect_value(t, _cur(fx.dir), "main")

	out, _ = _op(t, fx, {kind = .Create_Branch, name = "co", flag = true})
	testing.expect_value(t, out, Refs_Op_Outcome.Ok)
	testing.expect_value(t, _cur(fx.dir), "co")

	out, _ = _op(t, fx, {kind = .Create_Branch, name = "bad..name"})
	testing.expect_value(t, out, Refs_Op_Outcome.Failed)

	out, _ = _op(t, fx, {kind = .Rename_Branch, name = "from-first", target = "renamed"})
	testing.expect_value(t, out, Refs_Op_Outcome.Ok)
	testing.expect(t, _tgit_try(fx.dir, "rev-parse", "--verify", "-q", "refs/heads/renamed"))

	out, _ = _op(t, fx, {kind = .Delete_Branch, name = "renamed"}) // ancestor of HEAD: merged
	testing.expect_value(t, out, Refs_Op_Outcome.Ok)
	testing.expect(t, !_tgit_try(fx.dir, "rev-parse", "--verify", "-q", "refs/heads/renamed"))

	out, _ = _op(t, fx, {kind = .Delete_Branch, name = "co"}) // current branch
	testing.expect_value(t, out, Refs_Op_Outcome.Failed)
}

// teste: test_refs_op_delete_unmerged_needs_force
@(test)
test_refs_op_delete_unmerged_needs_force :: proc(t: ^testing.T) {
	fx := _fx_new(t, "refs-unmerged")
	defer _fx_destroy(fx)
	_tgit(t, fx.dir, "checkout", "-q", "-b", "wip")
	_tcommit(t, fx.dir, "w.txt", "w\n", "wip")
	_tgit(t, fx.dir, "checkout", "-q", "main")
	out, _ := _op(t, fx, {kind = .Delete_Branch, name = "wip"})
	testing.expect_value(t, out, Refs_Op_Outcome.Not_Merged)
	out, _ = _op(t, fx, {kind = .Delete_Branch, name = "wip", flag = true})
	testing.expect_value(t, out, Refs_Op_Outcome.Ok)

	// Remote branch delete
	_tgit(t, fx.dir, "push", "-q", "origin", "main:gone")
	_tgit(t, fx.dir, "fetch", "-q", "origin")
	out, _ = _op(t, fx, {kind = .Delete_Remote_Branch, name = "origin/gone"})
	testing.expect_value(t, out, Refs_Op_Outcome.Ok)
	testing.expect(t, !_tgit_try(fx.bare, "rev-parse", "--verify", "-q", "refs/heads/gone"))
}

// teste: test_refs_op_merge_and_rebase
@(test)
test_refs_op_merge_and_rebase :: proc(t: ^testing.T) {
	fx := _fx_new(t, "refs-mr")
	defer _fx_destroy(fx)
	_tgit(t, fx.dir, "checkout", "-q", "-b", "feat")
	_tcommit(t, fx.dir, "f.txt", "f\n", "feat")
	_tgit(t, fx.dir, "checkout", "-q", "main")
	_tcommit(t, fx.dir, "m.txt", "m\n", "main")

	// rebase feat onto main
	_tgit(t, fx.dir, "checkout", "-q", "feat")
	out, msg := _op(t, fx, {kind = .Rebase, name = "main"})
	testing.expectf(t, out == .Ok, "%v %q", out, msg)
	testing.expect(t, _tgit_try(fx.dir, "merge-base", "--is-ancestor", "main", "feat"))

	// merge feat into main
	_tgit(t, fx.dir, "checkout", "-q", "main")
	out, msg = _op(t, fx, {kind = .Merge, name = "feat"})
	testing.expectf(t, out == .Ok, "%v %q", out, msg)
	testing.expect_value(t, _read(fx.dir, "f.txt"), "f\n")
}

// teste: test_refs_op_merge_conflict_reports_conflicts
@(test)
test_refs_op_merge_conflict_reports_conflicts :: proc(t: ^testing.T) {
	fx := _fx_new(t, "refs-conf")
	defer _fx_destroy(fx)
	_tgit(t, fx.dir, "checkout", "-q", "-b", "feat")
	_tcommit(t, fx.dir, "a.txt", "feat\n", "feat a")
	_tgit(t, fx.dir, "checkout", "-q", "main")
	_tcommit(t, fx.dir, "a.txt", "main\n", "main a")

	id := git_request_refs_op(&fx.q, {kind = .Merge, name = "feat"})
	c := _tget(t, &fx.q, id, Git_Custom)
	r := git_custom_as(c^, Refs_Op_Result)
	testing.expect_value(t, r.outcome, Refs_Op_Outcome.Conflicts)
	testing.expect_value(t, len(r.conflicts), 1)
	git_release(&fx.q, id)
	_tgit(t, fx.dir, "merge", "--abort")

	_tgit(t, fx.dir, "checkout", "-q", "feat")
	out, _ := _op(t, fx, {kind = .Rebase, name = "main"})
	testing.expect_value(t, out, Refs_Op_Outcome.Conflicts)
	_tgit(t, fx.dir, "rebase", "--abort")
}

// teste: test_refs_op_push_sets_upstream
@(test)
test_refs_op_push_sets_upstream :: proc(t: ^testing.T) {
	fx := _fx_new(t, "refs-push")
	defer _fx_destroy(fx)
	_tgit(t, fx.dir, "checkout", "-q", "-b", "pub")
	_tcommit(t, fx.dir, "p.txt", "p\n", "pub")
	out, msg := _op(t, fx, {kind = .Push, name = "pub"})
	testing.expectf(t, out == .Ok, "%v %q", out, msg)
	testing.expect_value(t, _tgit_out(fx.dir, "rev-parse", "--abbrev-ref", "pub@{u}"), "origin/pub")
	testing.expect_value(t, _tgit_out(fx.bare, "rev-parse", "pub"), _tgit_out(fx.dir, "rev-parse", "pub"))
}

// teste: test_refs_op_tags
@(test)
test_refs_op_tags :: proc(t: ^testing.T) {
	fx := _fx_new(t, "refs-tags")
	defer _fx_destroy(fx)
	out, _ := _op(t, fx, {kind = .Create_Tag, name = "v1"})
	testing.expect_value(t, out, Refs_Op_Outcome.Ok)
	out, _ = _op(t, fx, {kind = .Create_Tag, name = "v2", message = "release 2"})
	testing.expect_value(t, out, Refs_Op_Outcome.Ok)
	testing.expect_value(t, _tgit_out(fx.dir, "cat-file", "-t", "v2"), "tag")
	out, _ = _op(t, fx, {kind = .Create_Tag, name = "v1"}) // duplicate
	testing.expect_value(t, out, Refs_Op_Outcome.Failed)
	out, _ = _op(t, fx, {kind = .Delete_Tag, name = "v1"})
	testing.expect_value(t, out, Refs_Op_Outcome.Ok)
	testing.expect_value(t, _tgit_out(fx.dir, "tag", "-l"), "v2")
}

// teste: test_refs_op_stashes
@(test)
test_refs_op_stashes :: proc(t: ^testing.T) {
	fx := _fx_new(t, "refs-stash")
	defer _fx_destroy(fx)
	out, msg := _op(t, fx, {kind = .Stash_Push})
	testing.expect_value(t, out, Refs_Op_Outcome.Ok)
	testing.expect_value(t, msg, "No local changes to stash")

	_twrite(fx.dir, "a.txt", "one\n")
	out, _ = _op(t, fx, {kind = .Stash_Push, message = "first"})
	testing.expect_value(t, out, Refs_Op_Outcome.Ok)
	testing.expect_value(t, _read(fx.dir, "a.txt"), "base\n")

	out, _ = _op(t, fx, {kind = .Stash_Apply, index = 0})
	testing.expect_value(t, out, Refs_Op_Outcome.Ok)
	testing.expect_value(t, _read(fx.dir, "a.txt"), "one\n")
	testing.expect(t, _tgit_out(fx.dir, "stash", "list") != "") // apply keeps it

	_tgit(t, fx.dir, "checkout", "--", "a.txt")
	out, _ = _op(t, fx, {kind = .Stash_Pop, index = 0})
	testing.expect_value(t, out, Refs_Op_Outcome.Ok)
	testing.expect_value(t, _tgit_out(fx.dir, "stash", "list"), "")

	out, _ = _op(t, fx, {kind = .Stash_Push})
	out, _ = _op(t, fx, {kind = .Stash_Drop, index = 0})
	testing.expect_value(t, out, Refs_Op_Outcome.Ok)
	testing.expect_value(t, _tgit_out(fx.dir, "stash", "list"), "")
	testing.expect_value(t, _read(fx.dir, "a.txt"), "base\n")
}
