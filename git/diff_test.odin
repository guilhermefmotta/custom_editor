package git

import "core:strings"
import "core:testing"

@(test)
test_full_diff_pairs_changes_and_keeps_context :: proc(t: ^testing.T) {
	raw := strings.clone(`diff --git a/f.go b/f.go
index 1..2 100644
--- a/f.go
+++ b/f.go
@@ -1,6 +1,7 @@
 package main
-old one
-old two
+new one
+new two
+new three
 middle
-gone
 end
\ No newline at end of file
`)
	fd := parse_unified_diff(raw)
	defer file_diff_destroy(&fd)

	testing.expect(t, !fd.binary)
	testing.expect_value(t, len(fd.rows), 7)
	// context
	testing.expect_value(t, fd.rows[0].left.text, "package main")
	testing.expect_value(t, fd.rows[0].right.line, 1)
	// modified run: 2 deletions paired with 3 additions, padded on the left
	testing.expect_value(t, fd.rows[1].left.kind, Diff_Kind.Delete)
	testing.expect_value(t, fd.rows[1].right.text, "new one")
	testing.expect_value(t, fd.rows[3].left.kind, Diff_Kind.Empty)
	testing.expect_value(t, fd.rows[3].right.line, 4)
	// context after the change keeps both line numbers in sync
	testing.expect_value(t, fd.rows[4].left.line, 4)
	testing.expect_value(t, fd.rows[4].right.line, 5)
	// pure deletion
	testing.expect_value(t, fd.rows[5].left.text, "gone")
	testing.expect_value(t, fd.rows[5].right.kind, Diff_Kind.Empty)
	testing.expect_value(t, fd.rows[6].right.text, "end")
	// one jump target per change
	testing.expect_value(t, len(fd.changed), 2)
	testing.expect_value(t, fd.changed[0], 1)
	testing.expect_value(t, fd.changed[1], 5)
}

@(test)
test_new_file_is_all_added :: proc(t: ^testing.T) {
	fd := file_diff_all_added(strings.clone("a\nb\n"))
	defer file_diff_destroy(&fd)
	testing.expect_value(t, len(fd.rows), 2)
	testing.expect_value(t, fd.rows[1].right.line, 2)
	testing.expect_value(t, fd.rows[1].left.kind, Diff_Kind.Empty)
}

@(test)
test_binary_detected :: proc(t: ^testing.T) {
	fd := parse_unified_diff(strings.clone("diff --git a/x b/x\nBinary files a/x and b/x differ\n"))
	defer file_diff_destroy(&fd)
	testing.expect(t, fd.binary)
}

import "core:fmt"
import "core:os"

// Real git: modified tracked file (whole file returned, changes paired) and an
// untracked file (all added).
@(test)
test_git_diff_file_full_against_repo :: proc(t: ^testing.T) {
	dir := fmt.aprintf("%s/editor-diff-test-%d", os.get_env("TMPDIR", context.temp_allocator), os.get_pid())
	defer delete(dir)
	run :: proc(dir: string, args: ..string) -> bool {
		out, ok := git_run(dir, args)
		delete(out)
		return ok
	}
	_ = os.make_directory(dir)
	testing.expect(t, run(dir, "init", "-q", "-b", "main"))
	run(dir, "config", "user.email", "t@t")
	run(dir, "config", "user.name", "t")
	_ = os.write_entire_file(fmt.tprintf("%s/a.txt", dir), transmute([]u8)string("one\ntwo\nthree\nfour\nfive\n"))
	testing.expect(t, run(dir, "add", "."))
	testing.expect(t, run(dir, "commit", "-qm", "base"))
	_ = os.write_entire_file(fmt.tprintf("%s/a.txt", dir), transmute([]u8)string("one\nTWO\nthree\nfour\nfive\nsix\n"))
	_ = os.write_entire_file(fmt.tprintf("%s/new.txt", dir), transmute([]u8)string("x\ny\n"))

	m := Git_Manager{root = dir}

	fd := git_diff_file_full(&m, "a.txt")
	defer file_diff_destroy(&fd)
	testing.expect_value(t, len(fd.rows), 6)          // every line of the file
	testing.expect_value(t, fd.rows[0].left.kind, Diff_Kind.Context)
	testing.expect_value(t, fd.rows[1].left.text, "two")
	testing.expect_value(t, fd.rows[1].right.text, "TWO")
	testing.expect_value(t, fd.rows[5].right.kind, Diff_Kind.Add)
	testing.expect_value(t, len(fd.changed), 2)

	nf := git_diff_file_full(&m, "new.txt")
	defer file_diff_destroy(&nf)
	testing.expect_value(t, len(nf.rows), 2)
	testing.expect_value(t, nf.rows[0].right.kind, Diff_Kind.Add)

	_ = os.remove_all(dir)
}
