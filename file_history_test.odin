package editor

// Tests for features/file-history.feature (ticket #10). Git scenarios drive a
// real temporary repository; work procs are called directly (as the queue
// worker would, with an arena as context.allocator) and through the queue.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import git "./git"

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

@(private="file")
_fht_repo :: proc(t: ^testing.T, name: string) -> string {
	base: string
	when ODIN_OS == .Windows {
		base = os.get_env("TEMP", context.temp_allocator)
	} else {
		base = os.get_env("TMPDIR", context.temp_allocator)
		if base == "" { base = "/tmp" }
	}
	base = strings.trim_right(base, "/\\")
	dir := fmt.aprintf("%s/editor-fh-%s-%d", base, name, os.get_pid())
	_ = os.remove_all(dir)
	_ = os.make_directory(dir)
	_fht_git(t, dir, "init", "-q", "-b", "main")
	_fht_git(t, dir, "config", "user.email", "tester@example.com")
	_fht_git(t, dir, "config", "user.name", "Tester")
	_fht_git(t, dir, "config", "commit.gpgsign", "false")
	_fht_git(t, dir, "config", "core.autocrlf", "false")
	return dir
}

@(private="file")
_fht_destroy :: proc(dir: string) {
	_ = os.remove_all(dir)
	delete(dir)
}

@(private="file")
_fht_git :: proc(t: ^testing.T, dir: string, args: ..string, loc := #caller_location) {
	out, ok := git.git_run(dir, args)
	delete(out)
	testing.expectf(t, ok, "git %v failed", args, loc = loc)
}

@(private="file")
_fht_write :: proc(dir, rel, content: string) {
	_ = os.write_entire_file(fmt.tprintf("%s/%s", dir, rel), transmute([]u8)content)
}

@(private="file")
_fht_commit :: proc(t: ^testing.T, dir, rel, content, msg: string, author := "Tester", loc := #caller_location) {
	if rel != "" { _fht_write(dir, rel, content) }
	_fht_git(t, dir, "add", "-A", loc = loc)
	_fht_git(t, dir, "-c", fmt.tprintf("user.name=%s", author), "commit", "-q", "-m", msg, loc = loc)
}

@(private="file")
_fht_wait :: proc(t: ^testing.T, q: ^git.Git_Queue, id: git.Job_Id) -> git.Job_Status {
	start := time.tick_now()
	for {
		_, st := git.git_poll(q, id)
		if st == .Done || st == .Failed || st == .Unknown { return st }
		if time.tick_since(start) > 20 * time.Second { testing.fail_now(t, "timeout waiting for git job") }
		time.sleep(time.Millisecond)
	}
}

@(private="file")
_fht_custom :: proc(t: ^testing.T, q: ^git.Git_Queue, id: git.Job_Id, $T: typeid) -> ^T {
	testing.expect_value(t, _fht_wait(t, q, id), git.Job_Status.Done)
	c, _, _ := git.git_poll_as(q, id, git.Git_Custom)
	if c == nil { return nil }
	return git.git_custom_as(c^, T)
}

// Repo: a.txt (v1) → unrelated other.txt → rename a.txt → b.txt with an edit
// → edit b.txt.
@(private="file")
_fht_history_repo :: proc(t: ^testing.T, name: string) -> string {
	dir := _fht_repo(t, name)
	_fht_commit(t, dir, "a.txt", "one\ntwo\nthree\nfour\nfive\n", "add a")
	_fht_commit(t, dir, "other.txt", "x\n", "unrelated")
	_fht_git(t, dir, "mv", "a.txt", "b.txt")
	_fht_commit(t, dir, "b.txt", "one\ntwo\nthree\nfour\nfive\nsix\n", "rename to b")
	_fht_commit(t, dir, "b.txt", "one\nTWO\nthree\nfour\nfive\nsix\n", "edit b")
	return dir
}

// ---------------------------------------------------------------------------
// Cenário: Histórico de um arquivo com o diff do arquivo inteiro de cada commit
// ---------------------------------------------------------------------------

@(test)
test_fh_history_lists_commits_following_renames :: proc(t: ^testing.T) {
	dir := _fht_history_repo(t, "hist")
	defer _fht_destroy(dir)
	defer free_all(context.temp_allocator)

	context.allocator = context.temp_allocator // stands in for the job arena
	payload, err := fh_history_work(dir, {"b.txt"}, nil)
	testing.expect_value(t, err, "")
	c := payload.(git.Git_Custom)
	h := git.git_custom_as(c, Fh_History)
	if !testing.expect(t, h != nil) { return }
	if !testing.expect_value(t, len(h.commits), 3) { return }

	testing.expect_value(t, h.commits[0].subject, "edit b")
	testing.expect_value(t, h.commits[0].path, "b.txt")
	testing.expect_value(t, h.commits[0].old_path, "")
	testing.expect_value(t, h.commits[1].subject, "rename to b")
	testing.expect_value(t, h.commits[1].status, u8('R'))
	testing.expect_value(t, h.commits[1].path, "b.txt")
	testing.expect_value(t, h.commits[1].old_path, "a.txt")
	testing.expect_value(t, h.commits[2].subject, "add a")
	testing.expect_value(t, h.commits[2].path, "a.txt") // known by its old name
	for cm in h.commits {
		testing.expect(t, cm.subject != "unrelated")
		testing.expect_value(t, len(cm.hash), 40)
		testing.expect_value(t, cm.author, "Tester")
		testing.expect(t, cm.time > 0)
	}

	// Untracked / unknown path: empty history, no error
	payload2, err2 := fh_history_work(dir, {"nope.txt"}, nil)
	testing.expect_value(t, err2, "")
	h2 := git.git_custom_as(payload2.(git.Git_Custom), Fh_History)
	testing.expect_value(t, len(h2.commits), 0)
}

@(test)
test_fh_history_diff_per_commit_through_queue :: proc(t: ^testing.T) {
	dir := _fht_history_repo(t, "histq")
	defer _fht_destroy(dir)

	q: git.Git_Queue
	git.git_queue_init(&q, dir)
	defer git.git_queue_destroy(&q)

	id := fh_request_history(&q, "b.txt")
	defer git.git_release(&q, id)
	h := _fht_custom(t, &q, id, Fh_History)
	if !testing.expect(t, h != nil && len(h.commits) == 3) { return }

	// Each commit: whole-file diff against its parent (all rows, not only hunks)
	expect_rows := [3]int{6, 6, 5}
	for c, i in h.commits {
		did := git.git_request_commit_file_diff(&q, c.hash, c.path, c.old_path)
		testing.expect_value(t, _fht_wait(t, &q, did), git.Job_Status.Done)
		d, _, _ := git.git_poll_as(&q, did, git.File_Diff)
		if testing.expectf(t, d != nil, "diff for %s", c.subject) {
			changed := 0
			for r in d.rows { if r.right.kind == .Add || r.left.kind == .Delete { changed += 1 } }
			testing.expectf(t, changed > 0, "%s: no changed rows", c.subject)
			right := 0
			for r in d.rows { if r.right.line > 0 { right += 1 } }
			testing.expectf(t, right == expect_rows[i], "%s: %d new-side rows, want %d", c.subject, right, expect_rows[i])
		}
		git.git_release(&q, did)
	}
}

// ---------------------------------------------------------------------------
// Cenário: Blame por linha com autor, data relativa, commit, cor e mensagem
// ---------------------------------------------------------------------------

@(test)
test_fh_blame_lines_with_author_and_summary :: proc(t: ^testing.T) {
	dir := _fht_repo(t, "blame")
	defer _fht_destroy(dir)
	defer free_all(context.temp_allocator)
	_fht_commit(t, dir, "f.txt", "alpha\nbeta\n", "first commit", author = "Alice")
	_fht_commit(t, dir, "f.txt", "alpha\nbeta\ngamma\n", "second commit", author = "Bob")

	context.allocator = context.temp_allocator
	// From disk (has_content = "0")
	payload, err := fh_blame_work(dir, {"f.txt", "", "0"}, nil)
	testing.expect_value(t, err, "")
	b := git.git_custom_as(payload.(git.Git_Custom), Fh_Blame)
	if !testing.expect(t, b != nil && len(b.lines) == 3) { return }
	testing.expect(t, b.tracked)
	testing.expect_value(t, b.lines[0].author, "Alice")
	testing.expect_value(t, b.lines[0].summary, "first commit")
	testing.expect_value(t, b.lines[0].text, "alpha")
	testing.expect_value(t, b.lines[1].author, "Alice")
	testing.expect_value(t, b.lines[2].author, "Bob")
	testing.expect_value(t, b.lines[2].summary, "second commit")
	testing.expect_value(t, len(b.lines[2].short_hash), 8)
	testing.expect(t, strings.has_prefix(b.lines[2].hash, b.lines[2].short_hash))
	testing.expect(t, b.lines[0].hash != b.lines[2].hash)
	for l in b.lines { testing.expect(t, l.committed && l.time > 0) }
	testing.expect_value(t, fh_relative_time(b.lines[0].time + 5, b.lines[0].time), "just now")
}

@(test)
test_fh_relative_time :: proc(t: ^testing.T) {
	now := i64(1_800_000_000)
	testing.expect_value(t, fh_relative_time(now, now), "just now")
	testing.expect_value(t, fh_relative_time(now, now + 100), "just now") // clock skew
	testing.expect_value(t, fh_relative_time(now, now - 60), "1 minute ago")
	testing.expect_value(t, fh_relative_time(now, now - 5 * 60), "5 minutes ago")
	testing.expect_value(t, fh_relative_time(now, now - 3 * 3600), "3 hours ago")
	testing.expect_value(t, fh_relative_time(now, now - 86400), "1 day ago")
	testing.expect_value(t, fh_relative_time(now, now - 45 * 86400), "1 month ago")
	testing.expect_value(t, fh_relative_time(now, now - 800 * 86400), "2 years ago")
}

@(test)
test_fh_blame_colors_by_commit :: proc(t: ^testing.T) {
	lines := []Fh_Blame_Line{
		{committed = true, hash = "a"}, {committed = true, hash = "a"},
		{committed = true, hash = "b"}, {committed = false},
		{committed = true, hash = "a"}, {committed = true, hash = "c"},
	}
	slots := fh_blame_color_slots(lines)
	defer delete(slots)
	testing.expect_value(t, slots[0], 0)
	testing.expect_value(t, slots[1], 0)
	testing.expect_value(t, slots[2], 1)
	testing.expect_value(t, slots[3], -1) // uncommitted: no commit color
	testing.expect_value(t, slots[4], 0)  // same commit, same color
	testing.expect_value(t, slots[5], 2)

	// More commits than colors: slots cycle
	many := make([]Fh_Blame_Line, FH_BLAME_COLORS + 1)
	defer delete(many)
	names := make([]string, len(many))
	defer { for n in names { delete(n) }; delete(names) }
	for &l, i in many { names[i] = fmt.aprintf("h%d", i); l = {committed = true, hash = names[i]} }
	s2 := fh_blame_color_slots(many)
	defer delete(s2)
	testing.expect_value(t, s2[FH_BLAME_COLORS], 0)
}

// ---------------------------------------------------------------------------
// Cenário: Linhas não commitadas aparecem sem autor
// ---------------------------------------------------------------------------

@(test)
test_fh_blame_uncommitted_lines_have_no_author :: proc(t: ^testing.T) {
	dir := _fht_repo(t, "blameu")
	defer _fht_destroy(dir)
	_fht_commit(t, dir, "f.txt", "alpha\nbeta\n", "first", author = "Alice")

	q: git.Git_Queue
	git.git_queue_init(&q, dir)
	defer git.git_queue_destroy(&q)

	// Buffer edited (not saved): a new line in the middle
	id := fh_request_blame(&q, "f.txt", "alpha\nNEW LINE\nbeta\n", true)
	defer git.git_release(&q, id)
	b := _fht_custom(t, &q, id, Fh_Blame)
	if !testing.expect(t, b != nil && len(b.lines) == 3) { return }
	testing.expect(t, b.lines[0].committed)
	testing.expect_value(t, b.lines[0].author, "Alice")
	testing.expect(t, !b.lines[1].committed)
	testing.expect_value(t, b.lines[1].author, "")
	testing.expect_value(t, b.lines[1].hash, "")
	testing.expect_value(t, b.lines[1].time, i64(0))
	testing.expect_value(t, b.lines[1].text, "NEW LINE")
	testing.expect(t, b.lines[2].committed)
	testing.expect_value(t, b.lines[2].author, "Alice")

	// Untracked file: every line without author
	_fht_write(dir, "new.txt", "x\ny\n")
	id2 := fh_request_blame(&q, "new.txt", "x\ny\n", true)
	defer git.git_release(&q, id2)
	b2 := _fht_custom(t, &q, id2, Fh_Blame)
	if testing.expect(t, b2 != nil && len(b2.lines) == 2) {
		testing.expect(t, !b2.tracked)
		for l in b2.lines { testing.expect(t, !l.committed && l.author == "") }
	}
}

// ---------------------------------------------------------------------------
// Cenário: Abrir pelo arquivo atual e pela árvore de arquivos
// ---------------------------------------------------------------------------

@(test)
test_fh_open_targets_panel :: proc(t: ^testing.T) {
	rel, ok := fh_rel_path("/repo", "/repo/src/a.odin")
	testing.expect(t, ok)
	testing.expect_value(t, rel, "src/a.odin")
	delete(rel)
	_, ok = fh_rel_path("/repo", "/repository/a.odin")
	testing.expect(t, !ok)
	_, ok = fh_rel_path("/repo", "/other/a.odin")
	testing.expect(t, !ok)
	rel, ok = fh_rel_path("C:\\repo", "C:\\repo\\src\\a.odin")
	testing.expect(t, ok)
	testing.expect_value(t, rel, "src/a.odin")
	delete(rel)

	dir := _fht_repo(t, "open")
	defer _fht_destroy(dir)
	_fht_commit(t, dir, "f.txt", "alpha\n", "first")

	e: Editor
	mgr: git.Git_Manager
	e.git_mgr = &mgr
	e.git_mgr.root = dir
	git.git_queue_init(&e.git_mgr.queue, dir)
	defer git.git_queue_destroy(&e.git_mgr.queue)

	abs := fmt.tprintf("%s/f.txt", dir)
	file_history_open(&e, abs) // what the file tree calls
	testing.expect(t, ui_panel_is_open(FILE_HISTORY_ID))
	a, r, tab := file_history_current()
	testing.expect_value(t, a, abs)
	testing.expect_value(t, r, "f.txt")
	testing.expect_value(t, tab, Fh_Tab.History)

	file_blame_open(&e, abs) // reopen on the Blame tab (releases previous jobs)
	_, _, tab = file_history_current()
	testing.expect_value(t, tab, Fh_Tab.Blame)

	ui_panel_close(&e, FILE_HISTORY_ID)
	testing.expect(t, !ui_panel_is_open(FILE_HISTORY_ID))
	a, _, _ = file_history_current()
	testing.expect_value(t, a, "")

	// Outside the repository: refused with a message, panel stays closed
	file_history_open(&e, "/definitely/not/in/repo.txt")
	testing.expect(t, !ui_panel_is_open(FILE_HISTORY_ID))
	free_all(context.temp_allocator)
}
