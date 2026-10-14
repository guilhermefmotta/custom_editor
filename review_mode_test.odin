package editor

// Review mode (features/claude-sessions.feature) on a real temporary repo,
// through a real git queue.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import git "./git"

@(private="file")
_rvt_git :: proc(t: ^testing.T, dir: string, args: ..string, loc := #caller_location) -> string {
	out, ok := git.git_run(dir, args, context.temp_allocator)
	testing.expectf(t, ok, "git %v failed", args, loc = loc)
	return strings.trim_space(out)
}

@(private="file")
_rvt_write :: proc(dir, rel, content: string) {
	_ = os.write_entire_file(fmt.tprintf("%s/%s", dir, rel), transmute([]u8)content)
}

@(private="file")
_rvt_repo :: proc(t: ^testing.T, name: string) -> (dir, base: string) {
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if tmp == "" { tmp = os.get_env("TEMP", context.temp_allocator) }
	if tmp == "" { tmp = "/tmp" }
	dir = fmt.aprintf("%s/editor-review-%s-%d", strings.trim_right(tmp, "/\\"), name, os.get_pid())
	_ = os.remove_all(dir)
	_ = os.make_directory_all(dir)
	_rvt_git(t, dir, "init", "-q", "-b", "main")
	_rvt_git(t, dir, "config", "user.email", "tester@example.com")
	_rvt_git(t, dir, "config", "user.name", "Tester")
	_rvt_git(t, dir, "config", "commit.gpgsign", "false")
	_rvt_write(dir, "a.txt", "one\ntwo\nthree\n")
	_rvt_write(dir, "b.txt", "bee\n")
	_rvt_write(dir, "keep.txt", "same\n")
	_rvt_git(t, dir, "add", "-A")
	_rvt_git(t, dir, "commit", "-q", "-m", "init")
	base = strings.clone(_rvt_git(t, dir, "rev-parse", "HEAD"))
	return
}

@(private="file")
_rvt_wait :: proc(q: ^git.Git_Queue, id: git.Job_Id) -> (^git.Git_Result, git.Job_Status) {
	start := time.tick_now()
	for time.duration_seconds(time.tick_since(start)) < 10 {
		r, st := git.git_poll(q, id)
		if st == .Done || st == .Failed { return r, st }
		time.sleep(5 * time.Millisecond)
	}
	return nil, .Unknown
}

// # teste: test_review_parse_changes
@(test)
test_review_parse_changes :: proc(t: ^testing.T) {
	files := review_parse_changes("M\x00z.txt\x00D\x00gone.txt\x00A\x00a b.txt\x00", "new.txt\x00", context.temp_allocator)
	testing.expect_value(t, len(files), 4)
	if len(files) != 4 { return }
	testing.expect_value(t, files[0].path, "a b.txt")
	testing.expect_value(t, files[0].status, u8('A'))
	testing.expect_value(t, files[1].path, "gone.txt")
	testing.expect_value(t, files[2].status, u8('?'))
	testing.expect_value(t, files[3].path, "z.txt")
	testing.expect_value(t, len(review_parse_changes("", "", context.temp_allocator)), 0)
	testing.expect_value(t, review_base_or_empty(""), REVIEW_EMPTY_TREE)
}

// # teste: test_review_lists_changed_files_and_marks_reviewed
@(test)
test_review_lists_changed_files_and_marks_reviewed :: proc(t: ^testing.T) {
	dir, base := _rvt_repo(t, "list")
	defer { _ = os.remove_all(dir); delete(dir); delete(base) }

	// What "Claude" did during the session: edit, create, delete, and commit one change.
	_rvt_write(dir, "a.txt", "one\nTWO\nthree\n")
	_rvt_write(dir, "novo.txt", "fresh\n")
	_rvt_write(dir, "b.txt", "bee\nsting\n")
	_rvt_git(t, dir, "commit", "-q", "-am", "claude: b")
	_ = os.remove(fmt.tprintf("%s/keep.txt", dir))
	_rvt_write(dir, "keep.txt", "same\n") // restored: no net change → not listed

	q: git.Git_Queue
	git.git_queue_init(&q, dir)
	defer git.git_queue_destroy(&q)

	id := git.git_request_custom(&q, review_list_work, {base})
	r, st := _rvt_wait(&q, id)
	testing.expectf(t, st == .Done, "list job: %v %s", st, r.err if r != nil else "")
	if st != .Done { return }
	l := git.git_custom_as(r.payload.(git.Git_Custom), Review_List)
	testing.expect(t, l != nil)
	paths := make([dynamic]string, context.temp_allocator)
	for f in l.files { append(&paths, fmt.tprintf("%c %s", f.status, f.path)) }
	// b.txt is listed although Claude committed it (diff vs the session start).
	testing.expect_value(t, len(paths), 3)
	if len(paths) == 3 {
		testing.expect_value(t, paths[0], "M a.txt")
		testing.expect_value(t, paths[1], "M b.txt")
		testing.expect_value(t, paths[2], "? novo.txt")
	}
	files := make([]Review_File, len(l.files), context.temp_allocator)
	copy(files, l.files)
	for &f in files { f.path = strings.clone(f.path, context.temp_allocator) }
	git.git_release(&q, id)

	// Mark reviewed (in memory, per session).
	s: Claude_Session
	defer { for k in s.reviewed { delete(k) }; delete(s.reviewed) }
	done, total := review_progress(&s, files)
	testing.expect(t, done == 0 && total == 3)
	review_toggle(&s, "a.txt")
	testing.expect(t, review_is_reviewed(&s, "a.txt"))
	done, total = review_progress(&s, files)
	testing.expect(t, done == 1 && total == 3)
	review_toggle(&s, "a.txt")
	testing.expect(t, !review_is_reviewed(&s, "a.txt"))
	review_set(&s, "a.txt", true)
	review_set(&s, "novo.txt", true)
	review_set(&s, "b.txt", true)
	done, _ = review_progress(&s, files)
	testing.expect_value(t, done, 3)
}

// # teste: test_review_diff_vs_session_base
@(test)
test_review_diff_vs_session_base :: proc(t: ^testing.T) {
	dir, base := _rvt_repo(t, "diff")
	defer { _ = os.remove_all(dir); delete(dir); delete(base) }
	_rvt_write(dir, "b.txt", "bee\nsting\n")
	_rvt_git(t, dir, "commit", "-q", "-am", "claude: b")
	_rvt_write(dir, "novo.txt", "x\ny\n")

	q: git.Git_Queue
	git.git_queue_init(&q, dir)
	defer git.git_queue_destroy(&q)

	// Committed change: still diffed against the session base, whole file.
	id := git.git_request_custom(&q, review_diff_work, {base, "b.txt"})
	r, st := _rvt_wait(&q, id)
	testing.expect_value(t, st, git.Job_Status.Done)
	if st == .Done {
		raw := git.git_custom_as(r.payload.(git.Git_Custom), Review_Diff_Raw)
		testing.expect(t, raw != nil && !raw.all_added)
		fd := git.parse_unified_diff(raw.text)
		testing.expect_value(t, len(fd.rows), 2)
		if len(fd.rows) == 2 {
			testing.expect_value(t, fd.rows[0].right.kind, git.Diff_Kind.Context)
			testing.expect_value(t, fd.rows[1].right.kind, git.Diff_Kind.Add)
			testing.expect_value(t, fd.rows[1].right.text, "sting")
		}
		delete(fd.rows); delete(fd.changed)
	}
	git.git_release(&q, id)

	// Untracked file: all added.
	id = git.git_request_custom(&q, review_diff_work, {base, "novo.txt"})
	r, st = _rvt_wait(&q, id)
	testing.expect_value(t, st, git.Job_Status.Done)
	if st == .Done {
		raw := git.git_custom_as(r.payload.(git.Git_Custom), Review_Diff_Raw)
		testing.expect(t, raw != nil && raw.all_added && raw.text == "x\ny\n")
	}
	git.git_release(&q, id)
}
