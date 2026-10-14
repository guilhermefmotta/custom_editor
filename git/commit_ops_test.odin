package git

// Tests for commit_ops.odin (ticket #9, features/commit-ops.feature) against
// real temporary repositories.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
_Co_Res :: struct {
	outcome:   Commit_Op_Outcome,
	operation: Repo_Operation,
	message:   string, // temp
	conflicts: int,
}

@(private = "file")
_co_wait :: proc(t: ^testing.T, q: ^Git_Queue, id: Job_Id, loc := #caller_location) -> _Co_Res {
	c := _tget(t, q, id, Git_Custom, loc)
	defer git_release(q, id)
	if c == nil { return {outcome = .Failed} }
	r := git_custom_as(c^, Commit_Op_Result)
	testing.expect(t, r != nil, loc = loc)
	if r == nil { return {outcome = .Failed} }
	return {r.outcome, r.operation, strings.clone(r.message, context.temp_allocator), len(r.conflicts)}
}

@(private = "file")
_co_run :: proc(t: ^testing.T, q: ^Git_Queue, op: Commit_Op, loc := #caller_location) -> _Co_Res {
	return _co_wait(t, q, git_request_commit_op(q, op), loc)
}

@(private = "file")
_co_read :: proc(dir, rel: string) -> string {
	data, err := os.read_entire_file(fmt.tprintf("%s/%s", dir, rel), context.temp_allocator)
	if err != nil { return "<missing>" }
	return string(data)
}

@(private = "file")
_co_subjects :: proc(dir: string, rng := "HEAD") -> string {
	return _tgit_out(dir, "log", "--reverse", "--format=%s", rng)
}

// teste: test_commit_ops_cherry_pick
@(test)
test_commit_ops_cherry_pick :: proc(t: ^testing.T) {
	dir := _trepo_new(t, "co-cp")
	defer _trepo_destroy(dir)
	_tcommit(t, dir, "a.txt", "a\n", "base")
	_tgit(t, dir, "checkout", "-q", "-b", "feat")
	h := strings.clone(_tcommit(t, dir, "b.txt", "b\n", "add b"))
	defer delete(h)
	_tgit(t, dir, "checkout", "-q", "main")
	_tcommit(t, dir, "c.txt", "c\n", "main only")
	q: Git_Queue
	git_queue_init(&q, dir)
	defer git_queue_destroy(&q)

	r := _co_run(t, &q, {kind = .Cherry_Pick, hash = h})
	testing.expectf(t, r.outcome == .Ok, "outcome %v %q", r.outcome, r.message)
	testing.expect_value(t, r.operation, Repo_Operation.Clean)
	testing.expect_value(t, _co_read(dir, "b.txt"), "b\n")
	testing.expect_value(t, _tgit_out(dir, "log", "-1", "--format=%s"), "add b")
	testing.expect(t, _tgit_out(dir, "rev-parse", "HEAD") != h)

	// Same commit again: nothing to apply → failed, repo clean
	r = _co_run(t, &q, {kind = .Cherry_Pick, hash = h})
	testing.expectf(t, r.outcome == .Failed, "outcome %v", r.outcome)
	testing.expect_value(t, r.operation, Repo_Operation.Clean)
}

// teste: test_commit_ops_cherry_pick_conflict
@(test)
test_commit_ops_cherry_pick_conflict :: proc(t: ^testing.T) {
	dir := _trepo_new(t, "co-cpc")
	defer _trepo_destroy(dir)
	_tcommit(t, dir, "a.txt", "base\n", "base")
	_tgit(t, dir, "checkout", "-q", "-b", "feat")
	h := _tcommit(t, dir, "a.txt", "feat\n", "feat edit")
	_tgit(t, dir, "checkout", "-q", "main")
	_tcommit(t, dir, "a.txt", "main\n", "main edit")
	q: Git_Queue
	git_queue_init(&q, dir)
	defer git_queue_destroy(&q)

	r := _co_run(t, &q, {kind = .Cherry_Pick, hash = h})
	testing.expectf(t, r.outcome == .Conflicts, "outcome %v %q", r.outcome, r.message)
	testing.expect_value(t, r.operation, Repo_Operation.Cherry_Picking)
	testing.expect_value(t, r.conflicts, 1)
	st, err := git_query_repo_state(dir, context.temp_allocator)
	testing.expect_value(t, err, "")
	testing.expect_value(t, st.operation, Repo_Operation.Cherry_Picking)

	// A second op while cherry-picking is refused
	r = _co_run(t, &q, {kind = .Revert, hash = h})
	testing.expect_value(t, r.outcome, Commit_Op_Outcome.Failed)
}

// teste: test_commit_ops_revert
@(test)
test_commit_ops_revert :: proc(t: ^testing.T) {
	dir := _trepo_new(t, "co-rv")
	defer _trepo_destroy(dir)
	_tcommit(t, dir, "a.txt", "one\n", "base")
	h := _tcommit(t, dir, "a.txt", "two\n", "change")
	_tcommit(t, dir, "b.txt", "b\n", "other")
	q: Git_Queue
	git_queue_init(&q, dir)
	defer git_queue_destroy(&q)

	r := _co_run(t, &q, {kind = .Revert, hash = h})
	testing.expectf(t, r.outcome == .Ok, "outcome %v %q", r.outcome, r.message)
	testing.expect_value(t, _co_read(dir, "a.txt"), "one\n")
	testing.expect_value(t, _co_read(dir, "b.txt"), "b\n")
	testing.expect_value(t, _tgit_out(dir, "log", "-1", "--format=%s"), "Revert \"change\"")
	testing.expect_value(t, _tgit_out(dir, "status", "--porcelain"), "")
}

// teste: test_commit_ops_reset_soft_mixed_hard
@(test)
test_commit_ops_reset_soft_mixed_hard :: proc(t: ^testing.T) {
	dir := _trepo_new(t, "co-rs")
	defer _trepo_destroy(dir)
	base := strings.clone(_tcommit(t, dir, "a.txt", "one\n", "base"))
	defer delete(base)
	top := strings.clone(_tcommit(t, dir, "a.txt", "two\n", "change"))
	defer delete(top)
	q: Git_Queue
	git_queue_init(&q, dir)
	defer git_queue_destroy(&q)

	// soft: HEAD moves, change staged
	r := _co_run(t, &q, {kind = .Reset_Soft, hash = base})
	testing.expectf(t, r.outcome == .Ok, "soft %v %q", r.outcome, r.message)
	testing.expect_value(t, _tgit_out(dir, "rev-parse", "HEAD"), base)
	testing.expect_value(t, _tgit_out(dir, "diff", "--cached", "--name-only"), "a.txt")
	testing.expect_value(t, _tgit_out(dir, "diff", "--name-only"), "")

	// mixed: back to top, then mixed reset → change only in the working tree
	_tgit(t, dir, "reset", "-q", "--hard", top)
	r = _co_run(t, &q, {kind = .Reset_Mixed, hash = base})
	testing.expectf(t, r.outcome == .Ok, "mixed %v %q", r.outcome, r.message)
	testing.expect_value(t, _tgit_out(dir, "rev-parse", "HEAD"), base)
	testing.expect_value(t, _tgit_out(dir, "diff", "--cached", "--name-only"), "")
	testing.expect_value(t, _tgit_out(dir, "diff", "--name-only"), "a.txt")
	testing.expect_value(t, _co_read(dir, "a.txt"), "two\n")

	// hard: index and working tree match the commit
	_tgit(t, dir, "reset", "-q", "--hard", top)
	_twrite(dir, "a.txt", "dirty\n")
	r = _co_run(t, &q, {kind = .Reset_Hard, hash = base})
	testing.expectf(t, r.outcome == .Ok, "hard %v %q", r.outcome, r.message)
	testing.expect_value(t, _tgit_out(dir, "rev-parse", "HEAD"), base)
	testing.expect_value(t, _tgit_out(dir, "status", "--porcelain", "--untracked-files=no"), "")
	testing.expect_value(t, _co_read(dir, "a.txt"), "one\n")

	r = _co_run(t, &q, {kind = .Reset_Hard, hash = "no-such-rev"})
	testing.expect_value(t, r.outcome, Commit_Op_Outcome.Failed)
}

// teste: test_commit_ops_rebase_interactive
@(test)
test_commit_ops_rebase_interactive :: proc(t: ^testing.T) {
	dir := _trepo_new(t, "co-ri")
	defer _trepo_destroy(dir)
	base := strings.clone(_tcommit(t, dir, "base.txt", "x\n", "base"))
	defer delete(base)
	_tcommit(t, dir, "a.txt", "a\n", "A")
	_tcommit(t, dir, "b.txt", "b\n", "B")
	_tcommit(t, dir, "c.txt", "c\n", "C")
	_tcommit(t, dir, "d.txt", "d\n", "D")
	_tcommit(t, dir, "e.txt", "e\n", "E")
	q: Git_Queue
	git_queue_init(&q, dir)
	defer git_queue_destroy(&q)

	id := git_request_rebase_commits(&q, base)
	c := _tget(t, &q, id, Git_Custom)
	plan := git_custom_as(c^, Rebase_Plan) if c != nil else nil
	testing.expect(t, plan != nil)
	if plan == nil { git_release(&q, id); return }
	testing.expect_value(t, len(plan.steps), 5)
	testing.expect_value(t, plan.steps[0].subject, "A")
	testing.expect_value(t, plan.steps[4].subject, "E")
	testing.expect_value(t, plan.steps[0].message, "A")

	// Plan: C (reword "C2"), A, B squash into A, D dropped, E fixup into ... B/A
	steps := make([]Rebase_Step, 5, context.temp_allocator)
	for s, i in plan.steps {
		steps[i] = s
		steps[i].hash    = strings.clone(s.hash, context.temp_allocator)
		steps[i].subject = strings.clone(s.subject, context.temp_allocator)
		steps[i].message = strings.clone(s.message, context.temp_allocator)
	}
	git_release(&q, id)
	// order: A B C D E → C A B D E
	testing.expect_value(t, rebase_step_move(steps, 2, -2), 0)
	steps[0].action = .Reword; steps[0].message = "C2\n\nbody line"
	steps[2].action = .Squash // B into A
	steps[3].action = .Drop   // D
	steps[4].action = .Fixup  // E into A+B
	testing.expect_value(t, rebase_steps_validate(steps), "")

	r := _co_wait(t, &q, git_request_rebase_interactive(&q, base, steps))
	testing.expectf(t, r.outcome == .Ok, "outcome %v %q", r.outcome, r.message)
	testing.expect_value(t, r.operation, Repo_Operation.Clean)

	testing.expect_value(t, _co_subjects(dir, fmt.tprintf("%s..HEAD", base)), "C2\nA")
	testing.expect_value(t, _tgit_out(dir, "log", "-1", "--skip=1", "--format=%B"), "C2\n\nbody line")
	// Squash keeps both messages (comments stripped), fixup adds none
	msg := _tgit_out(dir, "log", "-1", "--format=%B")
	testing.expectf(t, strings.contains(msg, "A") && strings.contains(msg, "B") && !strings.contains(msg, "E") && !strings.contains(msg, "#"), "squash msg %q", msg)
	testing.expect_value(t, _co_read(dir, "d.txt"), "<missing>")
	testing.expect_value(t, _co_read(dir, "e.txt"), "e\n")
	testing.expect_value(t, _co_read(dir, "b.txt"), "b\n")
	testing.expect_value(t, _tgit_out(dir, "status", "--porcelain"), "")
}

// teste: test_commit_ops_rebase_conflict
@(test)
test_commit_ops_rebase_conflict :: proc(t: ^testing.T) {
	dir := _trepo_new(t, "co-rc")
	defer _trepo_destroy(dir)
	base := strings.clone(_tcommit(t, dir, "a.txt", "1\n", "base"))
	defer delete(base)
	h1 := strings.clone(_tcommit(t, dir, "a.txt", "2\n", "two"))
	defer delete(h1)
	h2 := strings.clone(_tcommit(t, dir, "a.txt", "3\n", "three"))
	defer delete(h2)
	q: Git_Queue
	git_queue_init(&q, dir)
	defer git_queue_destroy(&q)

	// Swap: "three" first conflicts (it expects "2")
	steps := []Rebase_Step{
		{action = .Pick, hash = h2, subject = "three"},
		{action = .Pick, hash = h1, subject = "two"},
	}
	r := _co_wait(t, &q, git_request_rebase_interactive(&q, base, steps))
	testing.expectf(t, r.outcome == .Conflicts, "outcome %v %q", r.outcome, r.message)
	testing.expect_value(t, r.operation, Repo_Operation.Rebasing)
	testing.expect_value(t, r.conflicts, 1)
	_tgit_try(dir, "rebase", "--abort")

	// Dirty tracked file blocks the rebase
	_twrite(dir, "a.txt", "dirty\n")
	r = _co_wait(t, &q, git_request_rebase_interactive(&q, base, steps))
	testing.expect_value(t, r.outcome, Commit_Op_Outcome.Failed)
}

// teste: test_rebase_todo_build
@(test)
test_rebase_todo_build :: proc(t: ^testing.T) {
	steps := []Rebase_Step{
		{action = .Reword, hash = "aaa", subject = "first"},
		{action = .Squash, hash = "bbb", subject = "multi\nline"},
		{action = .Drop, hash = "ccc", subject = "gone"},
	}
	files := []string{"/tmp/it's/msg-0.txt", "", ""}
	todo := rebase_todo_build(steps, files, context.temp_allocator)
	want := "pick aaa first\n" +
		"exec git commit --amend --allow-empty --no-verify --cleanup=strip -F '/tmp/it'\\''s/msg-0.txt'\n" +
		"squash bbb multi line\n" +
		"drop ccc gone\n"
	testing.expect_value(t, todo, want)
}

// teste: test_rebase_steps_validate
@(test)
test_rebase_steps_validate :: proc(t: ^testing.T) {
	testing.expect(t, rebase_steps_validate(nil) != "")
	ok := []Rebase_Step{{action = .Drop, hash = "a"}, {action = .Pick, hash = "b"}, {action = .Fixup, hash = "c"}}
	testing.expect_value(t, rebase_steps_validate(ok), "")
	bad := []Rebase_Step{{action = .Drop, hash = "a"}, {action = .Squash, hash = "b"}}
	testing.expect(t, rebase_steps_validate(bad) != "")
	empty := []Rebase_Step{{action = .Reword, hash = "a", message = "  "}}
	testing.expect(t, rebase_steps_validate(empty) != "")
}

// teste: test_rebase_step_move
@(test)
test_rebase_step_move :: proc(t: ^testing.T) {
	s := []Rebase_Step{{hash = "a"}, {hash = "b"}, {hash = "c"}, {hash = "d"}}
	testing.expect_value(t, rebase_step_move(s, 0, 2), 2)
	testing.expect_value(t, s[0].hash, "b"); testing.expect_value(t, s[1].hash, "c"); testing.expect_value(t, s[2].hash, "a")
	testing.expect_value(t, rebase_step_move(s, 3, -1), 2)
	testing.expect_value(t, s[2].hash, "d"); testing.expect_value(t, s[3].hash, "a")
	testing.expect_value(t, rebase_step_move(s, 0, -1), 0)
	testing.expect_value(t, rebase_step_move(s, 3, 5), 3)

	// args round trip
	steps := []Rebase_Step{{action = .Squash, hash = "h", subject = "s", message = "m\nx"}}
	args := rebase_to_args("base", steps, context.temp_allocator)
	base, back, ok := rebase_from_args(args, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, base, "base")
	testing.expect_value(t, back[0].action, Rebase_Action.Squash)
	testing.expect_value(t, back[0].message, "m\nx")
}
