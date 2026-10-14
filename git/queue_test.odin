package git

import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

@(private = "file")
Order :: struct {
	mu:   sync.Mutex,
	seen: [dynamic]string,
	tids: [dynamic]int,
}

@(private = "file")
_record_work :: proc(root: string, args: []string, user: rawptr) -> (Git_Payload, string) {
	o := (^Order)(user)
	time.sleep(5 * time.Millisecond)
	sync.mutex_guard(&o.mu)
	append(&o.seen, args[0]) // args live in the job arena: only compare, don't keep
	append(&o.tids, sync.current_thread_id())
	p, c := git_custom_new(int)
	p^ = len(o.seen)
	return c, ""
}

@(private = "file")
_slow_work :: proc(root: string, args: []string, user: rawptr) -> (Git_Payload, string) {
	time.sleep(150 * time.Millisecond)
	return Command_Output{output = strings.clone("slow")}, ""
}

// Requests return immediately, git runs on the worker thread, results arrive
// by polling, jobs run in FIFO order.
@(test)
test_queue_runs_jobs_off_main_thread :: proc(t: ^testing.T) {
	dir := _trepo_new(t, "queue")
	defer _trepo_destroy(dir)
	head := _tcommit(t, dir, "a.txt", "a\n", "first")

	q: Git_Queue
	git_queue_init(&q, dir)
	defer git_queue_destroy(&q)

	// A slow job first: the next request must not wait for it
	slow := git_request_custom(&q, _slow_work)
	start := time.tick_now()
	id := git_request_command(&q, {"rev-parse", "HEAD"})
	testing.expect(t, time.tick_since(start) < 50 * time.Millisecond)
	_, st := git_poll(&q, id)
	testing.expect_value(t, st, Job_Status.Queued) // still behind the slow one
	testing.expect(t, git_queue_busy(&q) >= 1)

	out := _tget(t, &q, id, Command_Output)
	testing.expect_value(t, out.exit_code, 0)
	testing.expect_value(t, strings.trim_space(out.output), head)
	_, slow_st := git_poll(&q, slow)
	testing.expect_value(t, slow_st, Job_Status.Done) // FIFO: slow finished first
	git_release(&q, id)
	git_release(&q, slow)
	_, gone := git_poll(&q, id)
	testing.expect_value(t, gone, Job_Status.Unknown)

	// FIFO order + execution off the calling thread
	order: Order
	defer { delete(order.seen); delete(order.tids) }
	names := []string{"one", "two", "three", "four"}
	ids: [4]Job_Id
	for n, i in names { ids[i] = git_request_custom(&q, _record_work, {n}, &order) }
	for jid, i in ids {
		c := _tget(t, &q, jid, Git_Custom)
		n := git_custom_as(c^, int)
		testing.expect(t, n != nil && n^ == i + 1)
		testing.expect(t, git_custom_as(c^, string) == nil)
		git_release(&q, jid)
	}
	testing.expect_value(t, len(order.seen), 4)
	for n, i in names { testing.expect_value(t, order.seen[i], n) }
	main_tid := sync.current_thread_id()
	for tid in order.tids { testing.expect(t, tid != main_tid) }
	testing.expect_value(t, git_queue_busy(&q), 0)
}

@(private = "file")
Cb_State :: struct {
	calls:    int,
	branches: int,
	tid:      int,
}

// Release cancels queued/running jobs without leaks; callbacks run on the
// calling thread from git_queue_update; failures carry an error.
@(test)
test_queue_release_and_callbacks :: proc(t: ^testing.T) {
	dir := _trepo_new(t, "queuecb")
	defer _trepo_destroy(dir)
	_tcommit(t, dir, "a.txt", "a\n", "first")
	_tgit(t, dir, "branch", "feat")

	q: Git_Queue
	git_queue_init(&q, dir)
	defer git_queue_destroy(&q)

	slow    := git_request_custom(&q, _slow_work)
	queued  := git_request_log(&q, {limit = 10})
	time.sleep(30 * time.Millisecond) // slow is running now
	git_release(&q, queued)           // dropped before running
	git_release(&q, slow)             // discarded when it finishes
	_, s1 := git_poll(&q, queued)
	_, s2 := git_poll(&q, slow)
	testing.expect_value(t, s1, Job_Status.Unknown)
	testing.expect_value(t, s2, Job_Status.Unknown)

	// Failure: unknown revision
	bad := git_request_file_at(&q, "no-such-rev", "a.txt")
	testing.expect_value(t, _twait(t, &q, bad), Job_Status.Failed)
	_, bst, berr := git_poll_as(&q, bad, File_Blob)
	testing.expect_value(t, bst, Job_Status.Failed)
	testing.expect(t, berr != "")
	git_release(&q, bad)

	// Callback style
	state: Cb_State
	main_tid := sync.current_thread_id()
	bid := git_request_branches(&q)
	git_on_done(&q, bid, proc(r: ^Git_Result, user: rawptr) {
		s := (^Cb_State)(user)
		s.calls += 1
		s.tid = sync.current_thread_id()
		if bs, ok := r.payload.([]Branch); ok { s.branches = len(bs) }
	}, &state)
	fid := git_request_reflog(&q, "refs/heads/does-not-exist")
	git_on_done(&q, fid, proc(r: ^Git_Result, user: rawptr) {
		(^Cb_State)(user).calls += 1
	}, &state)
	deadline := time.tick_now()
	for state.calls < 2 && time.tick_since(deadline) < 20 * time.Second {
		git_queue_update(&q)
		time.sleep(time.Millisecond)
	}
	testing.expect_value(t, state.calls, 2)
	testing.expect_value(t, state.branches, 2) // main + feat
	testing.expect_value(t, state.tid, main_tid)
	_, after := git_poll(&q, bid) // released after the callback
	testing.expect_value(t, after, Job_Status.Unknown)

	// Destroy with work still pending must not leak
	git_request_custom(&q, _slow_work)
	git_request_log(&q, {})
	git_request_tags(&q)
}

// Arguments reach git verbatim (no shell expansion): quotes, $, backticks,
// backslashes and newlines.
@(test)
test_git_run_passes_args_verbatim :: proc(t: ^testing.T) {
	dir := _trepo_new(t, "quoting")
	defer _trepo_destroy(dir)
	msg := "it's $HOME `id` \\n back\\slash\n\nsecond \"line\""
	_tcommit(t, dir, "a.txt", "a\n", msg)
	out, ok := git_run(dir, {"log", "-1", "--format=%B"})
	defer delete(out)
	testing.expect(t, ok)
	testing.expect_value(t, strings.trim_right(out, "\n"), msg)
}
