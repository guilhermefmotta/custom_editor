package git

// Scenarios of features/working-tree.feature against real temporary repos.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
_exists :: proc(dir, rel: string) -> bool {
	return os.exists(strings.concatenate({dir, "/", rel}, context.temp_allocator))
}

@(private = "file")
_read :: proc(dir, rel: string) -> string {
	data, err := os.read_entire_file(strings.concatenate({dir, "/", rel}, context.temp_allocator), context.temp_allocator)
	if err != nil { return "" }
	return string(data)
}

// main and `other` both change c.txt → `git merge other` stops with a
// conflict in c.txt (markers on disk). Returns the repo dir.
@(private = "file")
_conflict_repo :: proc(t: ^testing.T, name: string) -> string {
	dir := _trepo_new(t, name)
	_tcommit(t, dir, "c.txt", "base\n", "base")
	_tcommit(t, dir, "o.txt", "one\n", "o")
	_tgit(t, dir, "checkout", "-q", "-b", "other")
	_tcommit(t, dir, "c.txt", "theirs\n", "theirs")
	_tgit(t, dir, "checkout", "-q", "main")
	_tcommit(t, dir, "c.txt", "ours\n", "ours")
	testing.expect(t, !_tgit_try(dir, "merge", "other"), "merge should stop with a conflict")
	testing.expect(t, _exists(dir, ".git/MERGE_HEAD"))
	return dir
}

// # teste: test_wt_stage_all_skips_conflicts
@(test)
test_wt_stage_all_skips_conflicts :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := _conflict_repo(t, "stageall")
	defer _trepo_destroy(dir)
	_twrite(dir, "o.txt", "changed\n")
	_twrite(dir, "new.txt", "new\n")

	testing.expect_value(t, wt_stage_all(dir), "")

	staged := wt_staged_paths(dir)
	testing.expect(t, _wt_contains(staged, "o.txt"), "o.txt staged")
	testing.expect(t, _wt_contains(staged, "new.txt"), "new.txt staged")
	testing.expect(t, !_wt_contains(staged, "c.txt"), "c.txt must not be staged")
	conflicted := wt_conflicted_paths(dir)
	testing.expect_value(t, len(conflicted), 1)
	if len(conflicted) == 1 { testing.expect_value(t, conflicted[0], "c.txt") }
	testing.expect(t, strings.contains(_tgit_out(dir, "ls-files", "-u", "--", "c.txt"), "c.txt"), "unmerged index entries kept")
	testing.expect(t, wt_has_conflict_markers(dir, "c.txt"))
	testing.expect(t, _exists(dir, ".git/MERGE_HEAD"), "merge still in progress")

	// Staging the conflicted file explicitly is refused while it has markers
	testing.expect(t, wt_stage(dir, {"c.txt"}) != "")
	testing.expect_value(t, len(wt_conflicted_paths(dir)), 1)
}

// # teste: test_wt_unstage_all_keeps_merge
@(test)
test_wt_unstage_all_keeps_merge :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := _conflict_repo(t, "unstageall")
	defer _trepo_destroy(dir)
	_twrite(dir, "c.txt", "resolved\n")
	testing.expect_value(t, wt_stage(dir, {"c.txt"}), "") // resolved: no markers
	_twrite(dir, "o.txt", "changed\n")
	testing.expect_value(t, wt_stage(dir, {"o.txt"}), "")
	testing.expect_value(t, len(wt_staged_paths(dir)), 2)

	testing.expect_value(t, wt_unstage_all(dir), "")

	testing.expect_value(t, len(wt_staged_paths(dir)), 0)
	testing.expect(t, _exists(dir, ".git/MERGE_HEAD"), "merge was aborted")
	testing.expect_value(t, _read(dir, "c.txt"), "resolved\n")
	testing.expect_value(t, _read(dir, "o.txt"), "changed\n")
}

// # teste: test_wt_stage_unstage_file
@(test)
test_wt_stage_unstage_file :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := _trepo_new(t, "file")
	defer _trepo_destroy(dir)
	_tcommit(t, dir, "a.txt", "a\n", "init")
	_twrite(dir, "a.txt", "b\n")
	testing.expect_value(t, wt_stage(dir, {"a.txt"}), "")
	testing.expect_value(t, _tgit_out(dir, "diff", "--cached", "--name-only"), "a.txt")
	testing.expect_value(t, wt_unstage(dir, {"a.txt"}), "")
	testing.expect_value(t, _tgit_out(dir, "diff", "--cached", "--name-only"), "")
	testing.expect_value(t, _tgit_out(dir, "diff", "--name-only"), "a.txt")

	// Unborn repo: unstage falls back to rm --cached
	dir2 := _trepo_new(t, "file-unborn")
	defer _trepo_destroy(dir2)
	_twrite(dir2, "x.txt", "x\n")
	testing.expect_value(t, wt_stage(dir2, {"x.txt"}), "")
	testing.expect_value(t, len(wt_staged_paths(dir2)), 1)
	testing.expect_value(t, wt_unstage_all(dir2), "")
	testing.expect_value(t, len(wt_staged_paths(dir2)), 0)
	testing.expect(t, _exists(dir2, "x.txt"))
}

// # teste: test_wt_stage_unstage_hunk
@(test)
test_wt_stage_unstage_hunk :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := _trepo_new(t, "hunk")
	defer _trepo_destroy(dir)
	b := strings.builder_make()
	for i in 0..<30 { strings.write_string(&b, fmt.tprintf("line %d\n", i)) }
	orig := strings.to_string(b)
	_tcommit(t, dir, "h.txt", orig, "init")
	lines := strings.split_lines(strings.trim_right(orig, "\n"))
	lines[1]  = "FIRST"
	lines[27] = "SECOND"
	_twrite(dir, "h.txt", strings.concatenate({strings.join(lines, "\n"), "\n"}))

	hs := wt_hunks(dir, "h.txt", false)
	testing.expect_value(t, len(hs.hunks), 2)
	if len(hs.hunks) != 2 { return }
	testing.expect_value(t, hs.hunks[0].added, 1)
	testing.expect_value(t, hs.hunks[0].removed, 1)
	testing.expect_value(t, hs.hunks[0].preview, "line 1")

	testing.expect_value(t, wt_apply_patch(dir, hs.hunks[0].patch, false), "")
	cached := _tgit_out(dir, "diff", "--cached")
	testing.expect(t, strings.contains(cached, "+FIRST"), "first hunk staged")
	testing.expect(t, !strings.contains(cached, "+SECOND"), "second hunk not staged")
	testing.expect(t, strings.contains(_tgit_out(dir, "diff"), "+SECOND"), "second hunk still unstaged")

	st := wt_hunks(dir, "h.txt", true)
	testing.expect_value(t, len(st.hunks), 1)
	if len(st.hunks) != 1 { return }
	testing.expect_value(t, wt_apply_patch(dir, st.hunks[0].patch, true), "")
	testing.expect_value(t, _tgit_out(dir, "diff", "--cached"), "")
	testing.expect_value(t, len(wt_hunks(dir, "h.txt", false).hunks), 2)
}

// # teste: test_wt_discard_and_ignore
@(test)
test_wt_discard_and_ignore :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := _trepo_new(t, "discard")
	defer _trepo_destroy(dir)
	_tcommit(t, dir, "a.txt", "a\n", "init")

	_twrite(dir, "a.txt", "dirty\n")
	testing.expect_value(t, wt_discard(dir, "a.txt", .Unstaged), "")
	testing.expect_value(t, _read(dir, "a.txt"), "a\n")

	_twrite(dir, "a.txt", "dirty\n")
	_tgit(t, dir, "add", "a.txt")
	testing.expect_value(t, wt_discard(dir, "a.txt", .Staged), "")
	testing.expect_value(t, _read(dir, "a.txt"), "a\n")
	testing.expect_value(t, _tgit_out(dir, "status", "--porcelain"), "")

	_twrite(dir, "n.txt", "n\n")
	_tgit(t, dir, "add", "n.txt")
	testing.expect_value(t, wt_discard(dir, "n.txt", .Staged), "") // not in HEAD
	testing.expect(t, !_exists(dir, "n.txt"))

	_twrite(dir, "u.txt", "u\n")
	testing.expect_value(t, wt_discard(dir, "u.txt", .Untracked), "")
	testing.expect(t, !_exists(dir, "u.txt"))

	testing.expect(t, wt_discard(dir, "a.txt", .Conflicts) != "")

	_twrite(dir, ".gitignore", "*.log") // no trailing newline
	_twrite(dir, "build.out", "x")
	testing.expect_value(t, wt_ignore(dir, "build.out"), "")
	testing.expect_value(t, wt_ignore(dir, "build.out"), "") // idempotent
	testing.expect_value(t, _read(dir, ".gitignore"), "*.log\nbuild.out\n")
	testing.expect(t, !strings.contains(_tgit_out(dir, "status", "--porcelain"), "build.out"))
}

// # teste: test_wt_commit_amend_undo
@(test)
test_wt_commit_amend_undo :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := _trepo_new(t, "commit")
	defer _trepo_destroy(dir)
	_twrite(dir, "a.txt", "a\n")
	_tgit(t, dir, "add", "a.txt")
	testing.expect_value(t, wt_commit(dir, "first", false), "")
	testing.expect(t, wt_undo_last_commit(dir) != "", "initial commit can't be undone")
	first := strings.clone(_tgit_out(dir, "rev-parse", "HEAD"))

	testing.expect_value(t, wt_commit(dir, "nothing", false), "nothing staged to commit")
	testing.expect_value(t, wt_commit(dir, "  ", false), "nothing staged to commit")

	_twrite(dir, "a.txt", "b\n")
	_tgit(t, dir, "add", "a.txt")
	testing.expect_value(t, wt_commit(dir, "", false), "commit message is empty")
	testing.expect_value(t, wt_commit(dir, "second\n\nbody", false), "")
	testing.expect_value(t, wt_last_message(dir), "second\n\nbody")

	testing.expect_value(t, wt_commit(dir, "second (amended)", true), "")
	testing.expect_value(t, _tgit_out(dir, "log", "-1", "--format=%s"), "second (amended)")
	testing.expect_value(t, _tgit_out(dir, "rev-parse", "HEAD^"), first)
	testing.expect_value(t, _tgit_out(dir, "rev-list", "--count", "HEAD"), "2")

	testing.expect_value(t, wt_undo_last_commit(dir), "")
	testing.expect_value(t, _tgit_out(dir, "rev-parse", "HEAD"), first)
	testing.expect_value(t, _tgit_out(dir, "diff", "--cached", "--name-only"), "a.txt")
	testing.expect_value(t, _read(dir, "a.txt"), "b\n")
}

// # teste: test_wt_file_diff_raw
@(test)
test_wt_file_diff_raw :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := _trepo_new(t, "fdiff")
	defer _trepo_destroy(dir)
	_tcommit(t, dir, "a.txt", "1\n2\n3\n", "init")
	_twrite(dir, "a.txt", "1\nX\n3\n")
	r := wt_file_diff_raw(dir, "a.txt")
	testing.expect(t, !r.all_added)
	testing.expect(t, strings.contains(r.text, "+X"))
	_twrite(dir, "u.txt", "new\n")
	u := wt_file_diff_raw(dir, "u.txt")
	testing.expect(t, u.all_added)
	testing.expect_value(t, u.text, "new\n")
}

// # teste: test_wt_queue_ops_and_refresh_order
@(test)
test_wt_queue_ops_and_refresh_order :: proc(t: ^testing.T) {
	dir := _conflict_repo(t, "queue")
	defer _trepo_destroy(dir)
	_twrite(dir, "o.txt", "changed\n")

	q: Git_Queue
	git_queue_init(&q, dir)
	defer git_queue_destroy(&q)

	id1 := git_request_wt(&q, .Stage_All)
	id2 := git_request_repo_state(&q) // FIFO: sees the result of stage all
	testing.expect_value(t, _twait(t, &q, id1), Job_Status.Done)
	st := _tget(t, &q, id2, Repo_State)
	if st != nil {
		testing.expect_value(t, st.operation, Repo_Operation.Merging)
		testing.expect_value(t, len(st.conflicts), 1)
		testing.expect_value(t, st.staged, 1)
	}
	git_release(&q, id1)
	git_release(&q, id2)

	id3 := git_request_wt(&q, .Discard, "c.txt", "0") // conflicts section: refused
	testing.expect_value(t, _twait(t, &q, id3), Job_Status.Failed)
	git_release(&q, id3)

	id4 := git_request_wt(&q, .Hunks, "o.txt", "1")
	_twait(t, &q, id4)
	r, _ := git_poll(&q, id4)
	if c, ok := r.payload.(Git_Custom); ok {
		h := git_custom_as(c, Wt_Hunks)
		testing.expect(t, h != nil && h.staged && len(h.hunks) == 1)
	} else {
		testing.fail(t)
	}
	git_release(&q, id4)

	id5 := git_request_wt(&q, .Unstage_All)
	testing.expect_value(t, _twait(t, &q, id5), Job_Status.Done)
	git_release(&q, id5)
	testing.expect(t, _exists(dir, ".git/MERGE_HEAD"))
}
