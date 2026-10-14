package git

// Scenarios of features/merge-resolver.feature (git side) against real
// temporary repositories.

import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
_read :: proc(dir, rel: string) -> string {
	data, err := os.read_entire_file(strings.concatenate({dir, "/", rel}, context.temp_allocator), context.temp_allocator)
	if err != nil { return "" }
	return string(data)
}

// main and `feature` both change a.txt and b.txt → `git merge feature`
// stops with 2 conflicted files.
@(private = "file")
_mconflict_repo :: proc(t: ^testing.T, name: string) -> string {
	dir := _trepo_new(t, name)
	_twrite(dir, "a.txt", "base a\n")
	_tcommit(t, dir, "b.txt", "base b\n", "base")
	_tgit(t, dir, "checkout", "-q", "-b", "feature")
	_twrite(dir, "a.txt", "feature a\n")
	_tcommit(t, dir, "b.txt", "feature b\n", "feature")
	_tgit(t, dir, "checkout", "-q", "main")
	_twrite(dir, "a.txt", "main a\n")
	_tcommit(t, dir, "b.txt", "main b\n", "main")
	testing.expect(t, !_tgit_try(dir, "merge", "feature"), "merge should stop with conflicts")
	return dir
}

// # teste: test_merge_resolve_refuses_markers
@(test)
test_merge_resolve_refuses_markers :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := _mconflict_repo(t, "mrrefuse")
	defer _trepo_destroy(dir)

	f, err := merge_load(dir, "a.txt")
	testing.expect_value(t, err, "")
	testing.expect(t, f.exists && !f.binary)
	testing.expect(t, merge_text_has_markers(f.merged))
	testing.expect_value(t, f.operation, Repo_Operation.Merging)
	testing.expect_value(t, f.ours_label, "main")

	r := merge_resolve(dir, "a.txt", f.merged)
	testing.expect(t, !r.ok, "content with markers must be refused")
	testing.expect_value(t, len(r.state.conflicts), 2)

	r = merge_resolve(dir, "a.txt", "main a\n")
	testing.expect(t, r.ok, r.message)
	testing.expect_value(t, len(r.state.conflicts), 1)
	testing.expect_value(t, _read(dir, "a.txt"), "main a\n")

	// Commit refused while a file is still conflicted
	c := merge_complete(dir)
	testing.expect(t, !c.ok)
	testing.expect_value(t, c.state.operation, Repo_Operation.Merging)

	// "=======" alone is not a marker (Markdown underline)
	testing.expect(t, !merge_text_has_markers("Title\n=======\n"))
	testing.expect(t, merge_text_has_markers("x\n>>>>>>> feature\n"))
	testing.expect(t, !merge_text_has_markers("x <<<<<<< not at line start\n"))
}

// # teste: test_merge_complete_commits_two_parents
@(test)
test_merge_complete_commits_two_parents :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := _mconflict_repo(t, "mrcommit")
	defer _trepo_destroy(dir)

	testing.expect(t, merge_resolve(dir, "a.txt", "main a\nfeature a\n").ok)
	testing.expect(t, merge_resolve(dir, "b.txt", "feature b\n").ok)
	c := merge_complete(dir)
	testing.expect(t, c.ok, c.message)
	testing.expect_value(t, c.state.operation, Repo_Operation.Clean)
	parents := strings.fields(_tgit_out(dir, "rev-list", "--parents", "-n", "1", "HEAD"))
	testing.expect_value(t, len(parents), 3) // commit + 2 parents
	testing.expect_value(t, _tgit_out(dir, "status", "--porcelain"), "")
}

// # teste: test_merge_abort_restores
@(test)
test_merge_abort_restores :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := _mconflict_repo(t, "mrabort")
	defer _trepo_destroy(dir)
	head := _tgit_out(dir, "rev-parse", "HEAD")

	testing.expect(t, merge_resolve(dir, "a.txt", "whatever\n").ok)
	r := merge_abort(dir)
	testing.expect(t, r.ok, r.message)
	testing.expect_value(t, r.state.operation, Repo_Operation.Clean)
	testing.expect_value(t, len(r.state.conflicts), 0)
	testing.expect_value(t, _tgit_out(dir, "rev-parse", "HEAD"), head)
	testing.expect_value(t, _read(dir, "a.txt"), "main a\n")
	testing.expect_value(t, _read(dir, "b.txt"), "main b\n")
	testing.expect_value(t, _tgit_out(dir, "status", "--porcelain"), "")

	// Nothing to abort any more
	testing.expect(t, !merge_abort(dir).ok)
}

// # teste: test_merge_rebase_continue
@(test)
test_merge_rebase_continue :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := _trepo_new(t, "mrrebase")
	defer _trepo_destroy(dir)
	_tcommit(t, dir, "a.txt", "base\n", "base")
	_tgit(t, dir, "checkout", "-q", "-b", "topic")
	_tcommit(t, dir, "a.txt", "topic\n", "topic")
	_tgit(t, dir, "checkout", "-q", "main")
	_tcommit(t, dir, "a.txt", "main\n", "main")
	_tgit(t, dir, "checkout", "-q", "topic")
	testing.expect(t, !_tgit_try(dir, "rebase", "main"), "rebase should stop with a conflict")

	st, _ := git_query_repo_state(dir)
	testing.expect_value(t, st.operation, Repo_Operation.Rebasing)
	testing.expect_value(t, merge_complete_label(st.operation), "Continue rebase")

	testing.expect(t, merge_resolve(dir, "a.txt", "main\ntopic\n").ok)
	c := merge_complete(dir)
	testing.expect(t, c.ok, c.message)
	testing.expect_value(t, c.state.operation, Repo_Operation.Clean)
	testing.expect_value(t, _tgit_out(dir, "log", "-1", "--format=%s"), "topic")
	testing.expect_value(t, _read(dir, "a.txt"), "main\ntopic\n")
}

// # teste: test_merge_ops_via_queue
@(test)
test_merge_ops_via_queue :: proc(t: ^testing.T) {
	dir := _mconflict_repo(t, "mrqueue")
	defer _trepo_destroy(dir)
	q: Git_Queue
	git_queue_init(&q, dir)
	defer git_queue_destroy(&q)

	id := git_request_merge_load(&q, "b.txt")
	_twait(t, &q, id)
	r, _ := git_poll(&q, id)
	f := merge_file_result(r)
	testing.expect(t, f != nil && f.path == "b.txt" && merge_text_has_markers(f.merged))
	git_release(&q, id)

	id = git_request_merge_resolve(&q, "b.txt", "main b\n")
	_twait(t, &q, id)
	r, _ = git_poll(&q, id)
	res := merge_op_result(r)
	testing.expect(t, res != nil && res.ok)
	if res != nil { testing.expect_value(t, len(res.state.conflicts), 1) }
	git_release(&q, id)

	id = git_request_merge_abort(&q)
	_twait(t, &q, id)
	r, _ = git_poll(&q, id)
	res = merge_op_result(r)
	testing.expect(t, res != nil && res.ok && res.state.operation == .Clean)
	git_release(&q, id)
}
