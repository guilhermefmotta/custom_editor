package editor

// Tests for features/branch-search.feature (ticket #12).

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

// ---- helpers: real temporary git repositories ----

@(private="file")
_tdir :: proc(name: string) -> string {
	base, _ := os.temp_directory(context.temp_allocator)
	dir := fmt.aprintf("%s/editor-bsearch-%s-%d", strings.trim_right(base, "/\\"), name, os.get_pid())
	_ = os.remove_all(dir)
	_ = os.make_directory_all(dir)
	return dir
}

@(private="file")
_tgit :: proc(t: ^testing.T, dir: string, args: ..string, loc := #caller_location) -> string {
	out, errs, code := search_git_capture(dir, args)
	testing.expectf(t, code == 0, "git %v failed: %s", args, errs, loc = loc)
	return strings.trim_space(out)
}

@(private="file")
_twrite :: proc(dir, rel, content: string) {
	path := fmt.tprintf("%s/%s", dir, rel)
	if i := strings.last_index_byte(path, '/'); i > 0 { _ = os.make_directory_all(path[:i]) }
	_ = os.write_entire_file(path, transmute([]u8)content)
}

@(private="file")
_trepo :: proc(t: ^testing.T, name: string) -> string {
	dir := _tdir(name)
	_tgit(t, dir, "init", "-q", "-b", "main")
	_tgit(t, dir, "config", "user.email", "tester@example.com")
	_tgit(t, dir, "config", "user.name", "Tester")
	_tgit(t, dir, "config", "commit.gpgsign", "false")
	_tgit(t, dir, "config", "core.autocrlf", "false")
	_twrite(dir, "a.txt", "hello main\n")
	_tgit(t, dir, "add", "-A")
	_tgit(t, dir, "commit", "-q", "-m", "init")
	return dir
}

@(private="file")
_trm :: proc(dir: string) {
	_ = os.remove_all(dir)
	delete(dir)
}

@(private="file")
_run_search :: proc(t: ^testing.T, s: ^Search_State, root, ref, name, query: string) {
	search_set_scope(s, Search_Scope{kind = .Branch, name = name, ref = ref}, root)
	search_start(s, query)
	deadline := time.tick_now()
	for {
		sync.mutex_lock(&s.mu)
		done := s.phase == .Done
		sync.mutex_unlock(&s.mu)
		if done { break }
		if time.duration_seconds(time.tick_since(deadline)) > 30 { testing.fail_now(t, "search timeout") }
		time.sleep(2 * time.Millisecond)
	}
}

@(private="file")
_outcome_free :: proc(o: ^Checkout_Outcome) {
	delete(o.msg)
	for c in o.conflicts { delete(c) }
	delete(o.conflicts)
}

// ---- pure ----

// # teste: test_ls_tree_parse
@(test)
test_ls_tree_parse :: proc(t: ^testing.T) {
	out := "100644 blob aaaa       12\tsrc/a.txt\x00" +
	       "120000 blob bbbb        5\tlink\x00" +
	       "160000 commit cccc       -\tsub\x00" +
	       "100644 blob dddd  3000000\tbig.bin\x00" +
	       "100755 blob eeee        7\tdir with space/run.sh\x00"
	entries, skipped := search_parse_ls_tree(out, SEARCH_BRANCH_MAX_BLOB)
	defer delete(entries)
	testing.expect_value(t, len(entries), 2)
	testing.expect_value(t, skipped, 1)
	testing.expect_value(t, entries[0].path, "src/a.txt")
	testing.expect_value(t, entries[0].oid, "aaaa")
	testing.expect_value(t, entries[0].size, 12)
	testing.expect_value(t, entries[1].path, "dir with space/run.sh")
}

// # teste: test_search_scope_entries
@(test)
test_search_scope_entries :: proc(t: ^testing.T) {
	br := []Scope_Branch{
		{name = "feature", ref = "refs/heads/feature"},
		{name = "main", ref = "refs/heads/main", is_head = true},
		{name = "origin/feature", ref = "refs/remotes/origin/feature", is_remote = true},
	}
	all := search_scope_entries(br, "")
	testing.expect_value(t, len(all), 4)
	testing.expect_value(t, all[0].scope.kind, Search_Scope_Kind.Workspace)
	testing.expect_value(t, all[1].label, "main") // checked out first
	testing.expect_value(t, all[2].label, "feature")
	testing.expect_value(t, all[3].label, "origin/feature")
	testing.expect(t, all[3].scope.is_remote)
	f := search_scope_entries(br, "FEAT")
	testing.expect_value(t, len(f), 2)
	testing.expect_value(t, search_scope_label(all[0].scope), "workspace")
}

// # teste: test_open_decision
@(test)
test_open_decision :: proc(t: ^testing.T) {
	br := []Scope_Branch{
		{name = "main", is_head = true},
		{name = "feature"},
		{name = "origin/main", is_remote = true},
		{name = "origin/feature", is_remote = true},
		{name = "origin/only-remote", is_remote = true},
	}
	a, l := search_open_decision({kind = .Workspace}, br)
	testing.expect_value(t, a, Search_Open_Action.Jump)
	a, l = search_open_decision({kind = .Branch, name = "main"}, br)
	testing.expect_value(t, a, Search_Open_Action.Jump)
	a, l = search_open_decision({kind = .Branch, name = "feature"}, br)
	testing.expect_value(t, a, Search_Open_Action.Ask_Checkout)
	testing.expect_value(t, l, "feature")
	a, l = search_open_decision({kind = .Branch, name = "origin/feature", is_remote = true}, br)
	testing.expect_value(t, a, Search_Open_Action.Ask_Checkout)
	testing.expect_value(t, l, "feature")
	a, l = search_open_decision({kind = .Branch, name = "origin/main", is_remote = true}, br)
	testing.expect_value(t, a, Search_Open_Action.Ask_Edit_Local)
	a, l = search_open_decision({kind = .Branch, name = "origin/only-remote", is_remote = true}, br)
	testing.expect_value(t, a, Search_Open_Action.Ask_Create_Track)
	testing.expect_value(t, l, "only-remote")
}

// # teste: test_search_place_cursor_selects_term
@(test)
test_search_place_cursor_selects_term :: proc(t: ^testing.T) {
	p := pane_init()
	defer pane_destroy(&p)
	buffer_insert_string(&p.buf, 0, "first line\n  let needle = 1\nlast\n")
	search_place_cursor(&p, 2, 7, len("needle"))
	ls := buffer_line_start(&p.buf, 1)
	testing.expect_value(t, p.sel_anchor, ls + 6)
	testing.expect_value(t, p.cursor, ls + 12)
	sel := buffer_to_string(&p.buf)
	defer delete(sel)
	testing.expect_value(t, sel[p.sel_anchor:p.cursor], "needle")
	// out of range line clamps to the last line, no crash
	search_place_cursor(&p, 999, 1, 3)
}

@(test)
test_search_scan_buffer :: proc(t: ^testing.T) {
	m := make([dynamic]Search_Match)
	defer delete(m)
	data := "abc\nxx FooBar foo\n"
	search_scan_buffer(transmute([]u8)data, transmute([]u8)string("foo"), 10, &m)
	testing.expect_value(t, len(m), 2)
	testing.expect_value(t, m[0].line, 2)
	testing.expect_value(t, m[0].col, 4)
	testing.expect_value(t, data[m[0].line_start:m[0].line_end], "xx FooBar foo")
	testing.expect_value(t, m[1].col, 11)
	testing.expect(t, search_is_binary(transmute([]u8)string("a\x00b")))
	testing.expect(t, !search_is_binary(transmute([]u8)data))
}

@(test)
test_checkout_blocked_classification :: proc(t: ^testing.T) {
	testing.expect(t, search_checkout_blocked("error: Your local changes to the following files would be overwritten by checkout:\n\ta.txt"))
	testing.expect(t, search_checkout_blocked("error: The following untracked working tree files would be overwritten by checkout:"))
	testing.expect(t, search_checkout_blocked("CONFLICT prevents checkout"))
	testing.expect(t, !search_checkout_blocked("fatal: invalid reference: nope"))
}

// ---- real repository ----

// # teste: test_branch_search_finds_text_only_in_branch
@(test)
test_branch_search_finds_text_only_in_branch :: proc(t: ^testing.T) {
	dir := _trepo(t, "only")
	defer _trm(dir)
	_tgit(t, dir, "switch", "-q", "-c", "feature")
	_twrite(dir, "src/deep/feat.odin", "package x\n\n\tSOMENTE_NA_FEATURE := 1\n")
	for i in 0 ..< 150 { _twrite(dir, fmt.tprintf("gen/f%d.txt", i), fmt.tprintf("file %d\n", i)) } // > 1 worker thread
	_tgit(t, dir, "add", "-A")
	_tgit(t, dir, "commit", "-q", "-m", "feat")
	_tgit(t, dir, "switch", "-q", "main")

	s := search_state_init()
	defer search_state_destroy(&s)
	_run_search(t, &s, dir, "refs/heads/feature", "feature", "somente_na_feature")
	testing.expect_value(t, s.err, "")
	testing.expect_value(t, len(s.results), 1)
	if len(s.results) == 1 {
		r := s.results[0]
		testing.expect_value(t, r.path, "src/deep/feat.odin")
		testing.expect_value(t, r.line, 3)
		testing.expect_value(t, r.col, 2)
		testing.expect_value(t, r.match_len, len("somente_na_feature"))
		testing.expect_value(t, r.line_text, "\tSOMENTE_NA_FEATURE := 1")
		testing.expect_value(t, r.ctx, "SOMENTE_NA_FEATURE := 1")
	}
	testing.expect(t, s.n_files >= 150)
	// no checkout happened
	testing.expect_value(t, _tgit(t, dir, "branch", "--show-current"), "main")
	testing.expect(t, !os.exists(fmt.tprintf("%s/src/deep/feat.odin", dir)))

	// same query on main finds nothing
	_run_search(t, &s, dir, "refs/heads/main", "main", "somente_na_feature")
	testing.expect_value(t, len(s.results), 0)
}

// # teste: test_branch_search_skips_binary_and_large
@(test)
test_branch_search_skips_binary_and_large :: proc(t: ^testing.T) {
	dir := _trepo(t, "bin")
	defer _trm(dir)
	_twrite(dir, "img.bin", "PNG\x00\x01MARCADOR_X\n")
	big := strings.repeat("y", SEARCH_BRANCH_MAX_BLOB + 10)
	defer delete(big)
	_twrite(dir, "big.txt", strings.concatenate({"MARCADOR_X\n", big}, context.temp_allocator))
	_twrite(dir, "ok.txt", "MARCADOR_X aqui\n")
	_tgit(t, dir, "add", "-A")
	_tgit(t, dir, "commit", "-q", "-m", "bin")

	s := search_state_init()
	defer search_state_destroy(&s)
	_run_search(t, &s, dir, "refs/heads/main", "main", "marcador_x")
	testing.expect_value(t, len(s.results), 1)
	if len(s.results) == 1 { testing.expect_value(t, s.results[0].path, "ok.txt") }
}

// # teste: test_checkout_existing_local_branch
@(test)
test_checkout_existing_local_branch :: proc(t: ^testing.T) {
	dir := _trepo(t, "co")
	defer _trm(dir)
	_tgit(t, dir, "branch", "feature")
	o := search_checkout_run(dir, .Switch, "feature", "")
	defer _outcome_free(&o)
	testing.expect(t, o.ok)
	testing.expect_value(t, _tgit(t, dir, "branch", "--show-current"), "feature")
}

// # teste: test_checkout_creates_tracking_branch_from_remote
@(test)
test_checkout_creates_tracking_branch_from_remote :: proc(t: ^testing.T) {
	dir := _trepo(t, "trk")
	defer _trm(dir)
	bare := _tdir("trk-bare")
	defer _trm(bare)
	_tgit(t, bare, "init", "-q", "--bare")
	_tgit(t, dir, "remote", "add", "origin", bare)
	_tgit(t, dir, "switch", "-q", "-c", "remota-x")
	_twrite(dir, "r.txt", "remote only\n")
	_tgit(t, dir, "add", "-A")
	_tgit(t, dir, "commit", "-q", "-m", "r")
	_tgit(t, dir, "push", "-q", "origin", "remota-x")
	_tgit(t, dir, "switch", "-q", "main")
	_tgit(t, dir, "branch", "-q", "-D", "remota-x")
	_tgit(t, dir, "fetch", "-q", "origin")

	act, local := search_open_decision({kind = .Branch, name = "origin/remota-x", is_remote = true},
		{{name = "main", is_head = true}, {name = "origin/remota-x", is_remote = true}})
	testing.expect_value(t, act, Search_Open_Action.Ask_Create_Track)

	o := search_checkout_run(dir, .Create_Track, local, "origin/remota-x")
	defer _outcome_free(&o)
	testing.expect(t, o.ok)
	testing.expect_value(t, _tgit(t, dir, "branch", "--show-current"), "remota-x")
	testing.expect_value(t, _tgit(t, dir, "rev-parse", "--abbrev-ref", "remota-x@{upstream}"), "origin/remota-x")
	testing.expect(t, os.exists(fmt.tprintf("%s/r.txt", dir)))
}

// # teste: test_checkout_blocked_then_smart_checkout
@(test)
test_checkout_blocked_then_smart_checkout :: proc(t: ^testing.T) {
	dir := _trepo(t, "smart")
	defer _trm(dir)
	_twrite(dir, "b.txt", "base\n")
	_tgit(t, dir, "add", "-A")
	_tgit(t, dir, "commit", "-q", "-m", "b")
	_tgit(t, dir, "switch", "-q", "-c", "feature")
	_twrite(dir, "a.txt", "hello feature\n")
	_tgit(t, dir, "commit", "-q", "-am", "f")
	_tgit(t, dir, "switch", "-q", "main")
	_twrite(dir, "a.txt", "local edit\n") // conflicts with feature's a.txt
	_twrite(dir, "new.txt", "untracked\n")

	o := search_checkout_run(dir, .Switch, "feature", "")
	defer _outcome_free(&o)
	testing.expect(t, !o.ok)
	testing.expect(t, o.blocked)
	testing.expect_value(t, _tgit(t, dir, "branch", "--show-current"), "main")

	// non-conflicting local change survives the smart checkout
	_tgit(t, dir, "checkout", "--", "a.txt")
	_twrite(dir, "b.txt", "local b edit\n")
	s := search_checkout_run(dir, .Smart, "feature", "")
	defer _outcome_free(&s)
	testing.expect(t, s.ok)
	testing.expect(t, !s.conflicted)
	testing.expect_value(t, _tgit(t, dir, "branch", "--show-current"), "feature")
	b, _ := os.read_entire_file(fmt.tprintf("%s/b.txt", dir), context.temp_allocator)
	testing.expect_value(t, string(b), "local b edit\n")
	testing.expect(t, os.exists(fmt.tprintf("%s/new.txt", dir))) // untracked restored (stash -u)
}

// # teste: test_smart_checkout_conflict_reported
@(test)
test_smart_checkout_conflict_reported :: proc(t: ^testing.T) {
	dir := _trepo(t, "smartc")
	defer _trm(dir)
	_tgit(t, dir, "switch", "-q", "-c", "feature")
	_twrite(dir, "a.txt", "hello feature\n")
	_tgit(t, dir, "commit", "-q", "-am", "f")
	_tgit(t, dir, "switch", "-q", "main")
	_twrite(dir, "a.txt", "local edit\n")

	o := search_checkout_run(dir, .Smart, "feature", "")
	defer _outcome_free(&o)
	testing.expect(t, o.ok)
	testing.expect(t, o.conflicted)
	testing.expect_value(t, len(o.conflicts), 1)
	if len(o.conflicts) == 1 { testing.expect_value(t, o.conflicts[0], "a.txt") }
	testing.expect_value(t, _tgit(t, dir, "branch", "--show-current"), "feature")
}

@(test)
test_read_only_copy :: proc(t: ^testing.T) {
	path, err := search_write_read_only("origin/feat", "dir/x.txt", "content\n")
	defer delete(path)
	testing.expect_value(t, err, "")
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, rerr == nil)
	testing.expect_value(t, string(data), "content\n")
	when ODIN_OS != .Windows {
		testing.expect(t, os.write_entire_file(path, transmute([]u8)string("x")) != nil) // read-only
	}
	// rewriting the copy (opened again later) works
	path2, err2 := search_write_read_only("origin/feat", "dir/x.txt", "v2\n")
	defer delete(path2)
	testing.expect_value(t, err2, "")
}
