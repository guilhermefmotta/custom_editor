package git

// Tests of the commit graph screen's git side (features/commit-graph.feature).

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// teste: test_commit_search_message_author_hash
@(test)
test_commit_search_message_author_hash :: proc(t: ^testing.T) {
	dir := _trepo_new(t, "cgsearch")
	defer _trepo_destroy(dir)
	_tcommit(t, dir, "a.txt", "1\n", "Add parser")
	fix := strings.clone(_tcommit(t, dir, "a.txt", "2\n", "Fix crash in [lexer] *now*"))
	defer delete(fix)
	_tgit(t, dir, "-c", "user.name=Alice Doe", "-c", "user.email=alice@x.io", "commit", "-q", "--allow-empty", "-m", "docs only")
	_tcommit(t, dir, "a.txt", "3\n", "unrelated")

	q: Git_Queue
	git_queue_init(&q, dir)
	defer git_queue_destroy(&q)

	// Message, case-insensitive, regex metacharacters taken literally
	id := git_request_commit_search(&q, "[LEXER] *now*")
	c := _tget(t, &q, id, Git_Custom)
	r := git_custom_as(c^, Commit_Search)
	testing.expect(t, r != nil)
	if r != nil {
		testing.expect_value(t, len(r.commits), 1)
		if len(r.commits) == 1 { testing.expect_value(t, r.commits[0].hash, fix) }
	}
	git_release(&q, id)

	// Author, case-insensitive
	id = git_request_commit_search(&q, "alice")
	r = git_custom_as(_tget(t, &q, id, Git_Custom)^, Commit_Search)
	testing.expect_value(t, len(r.commits), 1)
	if len(r.commits) == 1 { testing.expect_value(t, r.commits[0].subject, "docs only") }
	git_release(&q, id)

	// Hash prefix
	id = git_request_commit_search(&q, fix[:8])
	r = git_custom_as(_tget(t, &q, id, Git_Custom)^, Commit_Search)
	testing.expect(t, len(r.commits) >= 1)
	if len(r.commits) >= 1 { testing.expect_value(t, r.commits[0].hash, fix) }
	git_release(&q, id)

	// No match
	id = git_request_commit_search(&q, "zzz-nothing")
	r = git_custom_as(_tget(t, &q, id, Git_Custom)^, Commit_Search)
	testing.expect_value(t, len(r.commits), 0)
	git_release(&q, id)
}

// teste: test_commit_search_branch_filter
@(test)
test_commit_search_branch_filter :: proc(t: ^testing.T) {
	dir := _trepo_new(t, "cgbranch")
	defer _trepo_destroy(dir)
	_tcommit(t, dir, "a.txt", "1\n", "base work")
	_tgit(t, dir, "checkout", "-q", "-b", "feature")
	_tcommit(t, dir, "f.txt", "1\n", "feature work")
	_tgit(t, dir, "checkout", "-q", "main")
	_tcommit(t, dir, "m.txt", "1\n", "main work")

	q: Git_Queue
	git_queue_init(&q, dir)
	defer git_queue_destroy(&q)

	// Graph filtered by branch: only commits reachable from it
	id := git_request_log(&q, {rev = "feature"})
	page := _tget(t, &q, id, Log_Page)
	testing.expect_value(t, len(page.commits), 2)
	for c in page.commits { testing.expect(t, c.subject != "main work") }
	git_release(&q, id)

	// Search limited to the branch
	id = git_request_commit_search(&q, "work", "feature")
	r := git_custom_as(_tget(t, &q, id, Git_Custom)^, Commit_Search)
	testing.expect_value(t, len(r.commits), 2)
	git_release(&q, id)
	id = git_request_commit_search(&q, "work")
	r = git_custom_as(_tget(t, &q, id, Git_Custom)^, Commit_Search)
	testing.expect_value(t, len(r.commits), 3)
	git_release(&q, id)
}

// teste: test_commit_detail_files
@(test)
test_commit_detail_files :: proc(t: ^testing.T) {
	dir := _trepo_new(t, "cgdetail")
	defer _trepo_destroy(dir)
	_tcommit(t, dir, "a.txt", "one\ntwo\nthree\n", "first")
	_twrite(dir, "b.txt", "new\n")
	h := strings.clone(_tcommit(t, dir, "a.txt", "one\nTWO\nthree\n", "second\n\nbody line"))
	defer delete(h)

	q: Git_Queue
	git_queue_init(&q, dir)
	defer git_queue_destroy(&q)

	id := git_request_commit_detail(&q, h)
	d := _tget(t, &q, id, Commit_Detail)
	testing.expect_value(t, d.message, "second\n\nbody line")
	testing.expect_value(t, d.commit.author_name, "Tester")
	testing.expect_value(t, len(d.commit.parents), 1)
	testing.expect_value(t, len(d.files), 2)
	git_release(&q, id)

	// Whole-file diff of one file of that commit
	id = git_request_commit_file_diff(&q, h, "a.txt")
	fd := _tget(t, &q, id, File_Diff)
	testing.expect_value(t, len(fd.rows), 3) // whole file, not only the hunk
	testing.expect_value(t, len(fd.changed), 1)
	if len(fd.rows) == 3 {
		testing.expect_value(t, fd.rows[1].left.text, "two")
		testing.expect_value(t, fd.rows[1].right.text, "TWO")
		testing.expect_value(t, fd.rows[0].left.kind, Diff_Kind.Context)
	}
	git_release(&q, id)
}

// teste: test_commit_graph_paging_large_repo
// A few thousand commits generated with `git fast-import`; every page of
// 500 must come back quickly, also the deep ones.
@(test)
test_commit_graph_paging_large_repo :: proc(t: ^testing.T) {
	N :: 5000
	PAGE :: 500
	dir := _trepo_new(t, "cgpaging")
	defer _trepo_destroy(dir)

	// fast-import stream: linear history on main
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for i in 1..=N {
		fmt.sbprintf(&b, "commit refs/heads/main\nmark :%d\ncommitter T <t@x> %d +0000\ndata <<EOF\ncommit %d\nEOF\n", i, 1_600_000_000 + i, i)
		if i > 1 { fmt.sbprintf(&b, "from :%d\n", i - 1) }
		fmt.sbprintf(&b, "M 644 inline f.txt\ndata <<EOF\n%d\nEOF\n\n", i)
	}
	stream := fmt.tprintf("%s/../editor-cgpaging-%d.fi", dir, os.get_pid())
	defer os.remove(stream)
	testing.expect(t, os.write_entire_file(stream, b.buf[:]) == nil)

	f, ferr := os.open(stream)
	testing.expect(t, ferr == nil)
	if ferr != nil { return }
	p, perr := os.process_start({working_dir = dir, command = {"git", "fast-import", "--quiet"}, stdin = f})
	testing.expect(t, perr == nil)
	if perr == nil {
		st, _ := os.process_wait(p)
		testing.expect_value(t, st.exit_code, 0)
	}
	os.close(f)
	_tgit(t, dir, "reset", "-q", "--hard", "main")

	q: Git_Queue
	git_queue_init(&q, dir)
	defer git_queue_destroy(&q)

	total := 0
	skip := 0
	slowest: time.Duration
	for {
		start := time.tick_now()
		id := git_request_log(&q, {skip = skip, limit = PAGE})
		page := _tget(t, &q, id, Log_Page)
		el := time.tick_since(start)
		slowest = max(slowest, el)
		if page == nil { break }
		testing.expect_value(t, page.skip, skip)
		total += len(page.commits)
		more := page.has_more
		git_release(&q, id)
		skip += PAGE
		if !more { break }
	}
	testing.expect_value(t, total, N)
	testing.expectf(t, slowest < 2 * time.Second, "slowest page took %v", slowest)
	fmt.printfln("commit graph paging: %d commits, slowest page of %d: %v", N, PAGE, slowest)
}
