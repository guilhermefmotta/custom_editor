package editor

// Scenarios of features/merge-resolver.feature: pure document model + a
// real-repository end-to-end merge resolved through the model and the queue.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import git "./git"

@(private = "file")
SAMPLE :: "top\n<<<<<<< HEAD\nours 1\n=======\ntheirs 1\ntheirs 1b\n>>>>>>> feature\nmid\n<<<<<<< HEAD\nours 2\nours 2b\nours 2c\n=======\ntheirs 2\n>>>>>>> feature\nafter\n<<<<<<< HEAD\n=======\ntheirs 3\n>>>>>>> feature\nend\n"

// # teste: test_mr_parse_three_conflicts
@(test)
test_mr_parse_three_conflicts :: proc(t: ^testing.T) {
	d: Mr_Doc
	defer mr_doc_destroy(&d)
	mr_doc_init(&d, SAMPLE)
	testing.expect_value(t, len(d.blocks), 3)
	testing.expect_value(t, d.conflicts[0].text[.Ours], "ours 1")
	testing.expect_value(t, d.conflicts[0].text[.Theirs], "theirs 1\ntheirs 1b")
	testing.expect_value(t, d.conflicts[2].lines[.Ours], 0)
	testing.expect_value(t, string(d.side_text[.Ours][:]), "top\nours 1\nmid\nours 2\nours 2b\nours 2c\nafter\nend\n")
	testing.expect_value(t, string(d.side_text[.Theirs][:]), "top\ntheirs 1\ntheirs 1b\nmid\ntheirs 2\nafter\ntheirs 3\nend\n")
	testing.expect_value(t, d.conflicts[1].start[.Ours], 3)
	testing.expect_value(t, d.conflicts[1].start[.Theirs], 4)
	testing.expect(t, strings.has_prefix(mr_block_text(&d, 0), "<<<<<<< HEAD\n"))
	testing.expect(t, strings.has_suffix(mr_block_text(&d, 0), ">>>>>>> feature\n"))
	for i in 0 ..< 3 { testing.expect_value(t, mr_status(&d, i), Mr_Status.Unresolved) }

	// diff3 style: the base section is in neither side
	mr_doc_init(&d, "<<<<<<< ours\na\n||||||| base\nb\n=======\nc\n>>>>>>> theirs\n")
	testing.expect_value(t, len(d.blocks), 1)
	testing.expect_value(t, d.conflicts[0].text[.Ours], "a")
	testing.expect_value(t, d.conflicts[0].text[.Theirs], "c")
}

// # teste: test_mr_map_pos
@(test)
test_mr_map_pos :: proc(t: ^testing.T) {
	// replace [10, 20) with 4 bytes
	testing.expect_value(t, mr_map_pos(5, -1, 10, 20, 4), 5)
	testing.expect_value(t, mr_map_pos(25, 1, 10, 20, 4), 19)
	testing.expect_value(t, mr_map_pos(10, -1, 10, 20, 4), 10)
	testing.expect_value(t, mr_map_pos(20, 1, 10, 20, 4), 14)
	testing.expect_value(t, mr_map_pos(15, -1, 10, 20, 4), 10)
	testing.expect_value(t, mr_map_pos(15, 1, 10, 20, 4), 14)
	// pure insertion of 3 bytes at 10
	testing.expect_value(t, mr_map_pos(10, -1, 10, 10, 3), 10)
	testing.expect_value(t, mr_map_pos(10, 1, 10, 10, 3), 13)
}

// # teste: test_mr_accept_first_replaces_second_appends
@(test)
test_mr_accept_first_replaces_second_appends :: proc(t: ^testing.T) {
	d: Mr_Doc
	defer mr_doc_destroy(&d)
	mr_doc_init(&d, SAMPLE)
	testing.expect(t, mr_handle_side(&d, 0, .Ours, true))
	testing.expect_value(t, mr_block_text(&d, 0), "ours 1\n")
	testing.expect_value(t, mr_status(&d, 0), Mr_Status.Ours)
	testing.expect_value(t, d.sides[0][.Ours], Mr_Side_State.Applied)
	testing.expect_value(t, d.sides[0][.Theirs], Mr_Side_State.Pending)
	testing.expect(t, !mr_handle_side(&d, 0, .Theirs, true)) // block had no markers any more
	testing.expect_value(t, mr_block_text(&d, 0), "ours 1\ntheirs 1\ntheirs 1b\n")
	testing.expect_value(t, mr_status(&d, 0), Mr_Status.Both)
	testing.expect(t, strings.has_prefix(mr_text(&d), "top\nours 1\ntheirs 1\ntheirs 1b\nmid\n"))
	// a decided side can't be decided again
	before := strings.clone(mr_text(&d), context.temp_allocator)
	mr_handle_side(&d, 0, .Ours, true)
	testing.expect_value(t, mr_text(&d), before)
}

// # teste: test_mr_accept_tracks_conflict_by_position
@(test)
test_mr_accept_tracks_conflict_by_position :: proc(t: ^testing.T) {
	d: Mr_Doc
	defer mr_doc_destroy(&d)
	mr_doc_init(&d, SAMPLE)
	mr_handle_side(&d, 0, .Theirs, true)
	testing.expect_value(t, mr_resolved_count(&d), 1)
	// conflict 1 is still conflict 1 (not re-indexed by the remaining markers)
	mr_handle_side(&d, 1, .Ours, true)
	testing.expect_value(t, mr_block_text(&d, 1), "ours 2\nours 2b\nours 2c\n")
	testing.expect_value(t, mr_status(&d, 0), Mr_Status.Theirs)
	testing.expect_value(t, mr_status(&d, 1), Mr_Status.Ours)
	testing.expect_value(t, mr_status(&d, 2), Mr_Status.Unresolved)
	testing.expect_value(t, mr_resolved_count(&d), 2)
	mr_handle_side(&d, 2, .Theirs, true)
	testing.expect(t, mr_all_resolved(&d))
	testing.expect_value(t, mr_text(&d), "top\ntheirs 1\ntheirs 1b\nmid\nours 2\nours 2b\nours 2c\nafter\ntheirs 3\nend\n")

	// typing inside a resolved block keeps it in the block (manual edit)
	mr_edit(&d, d.blocks[1].to, d.blocks[1].to, "typed\n")
	testing.expect(t, strings.has_suffix(mr_block_text(&d, 1), "typed\n"))
	// typing before a block shifts it
	f0 := d.blocks[2].from
	mr_edit(&d, 0, 0, "xx")
	testing.expect_value(t, d.blocks[2].from, f0 + 2)
}

// # teste: test_mr_ignore_unresolved_frees_other_side
@(test)
test_mr_ignore_unresolved_frees_other_side :: proc(t: ^testing.T) {
	d: Mr_Doc
	defer mr_doc_destroy(&d)
	mr_doc_init(&d, SAMPLE)
	testing.expect(t, mr_handle_side(&d, 1, .Ours, false))
	testing.expect_value(t, mr_block_text(&d, 1), "")
	testing.expect_value(t, d.sides[1][.Ours], Mr_Side_State.Ignored)
	testing.expect_value(t, d.sides[1][.Theirs], Mr_Side_State.Pending)
	testing.expect_value(t, mr_status(&d, 1), Mr_Status.Manual)
	testing.expect(t, strings.contains(mr_text(&d), "mid\nafter\n"))
	// the other side is still available and lands in place
	mr_handle_side(&d, 1, .Theirs, true)
	testing.expect_value(t, mr_block_text(&d, 1), "theirs 2\n")
	testing.expect(t, strings.contains(mr_text(&d), "mid\ntheirs 2\nafter\n"))
	testing.expect_value(t, mr_status(&d, 1), Mr_Status.Theirs)
}

// # teste: test_mr_newline_after_resolved_block
@(test)
test_mr_newline_after_resolved_block :: proc(t: ^testing.T) {
	d: Mr_Doc
	defer mr_doc_destroy(&d)
	for side in Mr_Side {
		mr_doc_init(&d, SAMPLE)
		mr_handle_side(&d, 1, side, true)
		testing.expect(t, strings.contains(mr_text(&d), "\nafter\n"), "the line after the block must not stick to it")
		// empty side (conflict 2 ours) also keeps "end" on its own line
		mr_handle_side(&d, 2, .Ours, true)
		testing.expect(t, strings.has_suffix(mr_text(&d), "after\nend\n"))
		mr_handle_side(&d, 2, .Theirs, true)
		testing.expect(t, strings.has_suffix(mr_text(&d), "after\ntheirs 3\nend\n"))
	}
}

// # teste: test_mr_last_conflict_without_newline
@(test)
test_mr_last_conflict_without_newline :: proc(t: ^testing.T) {
	d: Mr_Doc
	defer mr_doc_destroy(&d)
	mr_doc_init(&d, "a\n<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> b")
	testing.expect_value(t, len(d.blocks), 1)
	mr_handle_side(&d, 0, .Ours, true)
	testing.expect_value(t, mr_text(&d), "a\nx")
	mr_handle_side(&d, 0, .Theirs, true)
	testing.expect_value(t, mr_text(&d), "a\nx\ny")
}

// # teste: test_mr_undo_restores_markers_resets_sides
@(test)
test_mr_undo_restores_markers_resets_sides :: proc(t: ^testing.T) {
	d: Mr_Doc
	defer mr_doc_destroy(&d)
	mr_doc_init(&d, SAMPLE)
	mr_handle_side(&d, 0, .Ours, true)
	mr_handle_side(&d, 0, .Theirs, false)
	testing.expect_value(t, mr_status(&d, 0), Mr_Status.Ours)
	testing.expect(t, mr_undo(&d))
	testing.expect_value(t, mr_text(&d), SAMPLE)
	testing.expect_value(t, mr_status(&d, 0), Mr_Status.Unresolved)
	testing.expect_value(t, d.sides[0], [Mr_Side]Mr_Side_State{.Ours = .Pending, .Theirs = .Pending})
	// the block maps back over the whole marker region
	testing.expect(t, strings.has_prefix(mr_block_text(&d, 0), "<<<<<<<"))
	testing.expect(t, strings.has_suffix(mr_block_text(&d, 0), ">>>>>>> feature\n"))
	// both sides can be decided again
	mr_handle_side(&d, 0, .Theirs, true)
	testing.expect_value(t, mr_block_text(&d, 0), "theirs 1\ntheirs 1b\n")
	// redo after a new edit is gone; undo + redo round-trips
	testing.expect(t, !mr_can_redo(&d))
	mr_undo(&d)
	testing.expect(t, mr_redo(&d))
	testing.expect_value(t, mr_block_text(&d, 0), "theirs 1\ntheirs 1b\n")
}

// # teste: test_mr_layout_aligned
@(test)
test_mr_layout_aligned :: proc(t: ^testing.T) {
	d: Mr_Doc
	l: Mr_Layout
	defer mr_doc_destroy(&d)
	defer mr_layout_destroy(&l)
	check :: proc(t: ^testing.T, d: ^Mr_Doc, l: ^Mr_Layout, loc := #caller_location) {
		mr_layout(d, l)
		testing.expect_value(t, len(l.rows[.Ours]), len(l.rows[.Theirs]), loc = loc)
		testing.expect_value(t, len(l.rows[.Ours]), len(l.rows[.Result]), loc = loc)
		for i in 0 ..< len(d.blocks) {
			testing.expect_value(t, l.first_row[.Ours][i], l.first_row[.Result][i], loc = loc)
			testing.expect_value(t, l.first_row[.Theirs][i], l.first_row[.Result][i], loc = loc)
		}
	}
	mr_doc_init(&d, SAMPLE)
	check(t, &d, &l)
	// conflict 0: Result has 5 lines (markers), Local 1, Remote 2 → padded to 5
	testing.expect_value(t, l.first_row[.Result][0], 1)
	testing.expect_value(t, l.rows[.Ours][2].line, -1)
	mr_handle_side(&d, 0, .Ours, true)
	check(t, &d, &l)
	mr_handle_side(&d, 2, .Ours, false) // empty block
	check(t, &d, &l)
	mr_handle_side(&d, 1, .Theirs, true)
	mr_handle_side(&d, 1, .Ours, true)
	check(t, &d, &l)
}

// # teste: test_mr_banner_for
@(test)
test_mr_banner_for :: proc(t: ^testing.T) {
	s, k := merge_resolver_banner_for(.Merging, 3)
	testing.expect(t, strings.has_prefix(s, "3 files in conflict - Resolve"))
	testing.expect_value(t, k, Ui_Banner_Kind.Warning)
	s, _ = merge_resolver_banner_for(.Conflicted, 1)
	testing.expect(t, strings.has_prefix(s, "1 file in conflict"))
	s, k = merge_resolver_banner_for(.Merging, 0)
	testing.expect(t, strings.has_prefix(s, "Merge ready to commit - Commit"))
	s, _ = merge_resolver_banner_for(.Rebasing, 0)
	testing.expect(t, strings.contains(s, "Continue rebase"))
	s, _ = merge_resolver_banner_for(.Clean, 0)
	testing.expect_value(t, s, "")
	testing.expect_value(t, git.merge_complete_label(.Merging), "Commit merge")
	testing.expect_value(t, git.merge_complete_label(.Rebasing), "Continue rebase")
}

// ---------------------------------------------------------------------------
// End to end on a real repository
// ---------------------------------------------------------------------------

@(private = "file")
_e2e_git :: proc(t: ^testing.T, dir: string, args: ..string, loc := #caller_location) -> bool {
	out, ok := git.git_run(dir, args, context.temp_allocator)
	_ = out
	return ok
}

@(private = "file")
_e2e_write :: proc(dir, rel, content: string) {
	p := fmt.tprintf("%s/%s", dir, rel)
	if k := strings.last_index_byte(p, '/'); k > 0 { _ = os.make_directory_all(p[:k]) }
	_ = os.write_entire_file(p, transmute([]u8)content)
}

@(private = "file")
_e2e_wait :: proc(t: ^testing.T, q: ^git.Git_Queue, id: git.Job_Id) -> ^git.Git_Result {
	start := time.tick_now()
	for {
		r, st := git.git_poll(q, id)
		if st == .Done || st == .Failed { return r }
		if st == .Unknown || time.tick_since(start) > 20 * time.Second { testing.fail_now(t, "git job timeout") }
		time.sleep(time.Millisecond)
	}
}

// Same shape as Git Crab's merge_conflict_flow_end_to_end: 3 conflicted
// files (README.md, config.go, web/app.ts) + a clean change from feature.
// # teste: test_mr_merge_flow_end_to_end
@(test)
test_mr_merge_flow_end_to_end :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	base := os.get_env("TMPDIR", context.temp_allocator)
	when ODIN_OS == .Windows { base = os.get_env("TEMP", context.temp_allocator) }
	if base == "" { base = "/tmp" }
	dir := fmt.tprintf("%s/editor-mr-e2e-%d", strings.trim_right(base, "/\\"), os.get_pid())
	_ = os.remove_all(dir)
	_ = os.make_directory_all(dir)
	defer os.remove_all(dir)

	g :: proc(t: ^testing.T, dir: string, args: ..string, loc := #caller_location) {
		testing.expectf(t, _e2e_git(t, dir, ..args), "git %v failed", args, loc = loc)
	}
	g(t, dir, "init", "-q", "-b", "main")
	g(t, dir, "config", "user.email", "t@example.com")
	g(t, dir, "config", "user.name", "T")
	g(t, dir, "config", "commit.gpgsign", "false")
	g(t, dir, "config", "core.autocrlf", "false")
	_e2e_write(dir, "README.md", "# App\n\nVersion: 1\n")
	_e2e_write(dir, "config.go", "package config\n\nvar C = Config{\n\tEnv: \"dev\",\n\tTimeout: 5,\n}\n")
	_e2e_write(dir, "web/app.ts", "export const title = 'app';\nexport const n = 1;\n")
	g(t, dir, "add", "-A"); g(t, dir, "commit", "-q", "-m", "base")
	g(t, dir, "checkout", "-q", "-b", "feature")
	_e2e_write(dir, "README.md", "# App\n\nVersion: 2-feature\n")
	_e2e_write(dir, "config.go", "package config\n\nvar C = Config{\n\tEnv: \"staging\",\n\tTimeout: 30,\n}\n")
	_e2e_write(dir, "web/app.ts", "export const title = 'feature';\nexport const n = 1;\n")
	_e2e_write(dir, "web/feature.ts", "export const f = true;\n")
	g(t, dir, "add", "-A"); g(t, dir, "commit", "-q", "-m", "feature")
	g(t, dir, "checkout", "-q", "main")
	_e2e_write(dir, "README.md", "# App\n\nVersion: 1-main\n")
	_e2e_write(dir, "config.go", "package config\n\nvar C = Config{\n\tEnv: \"prod\",\n\tTimeout: 15,\n}\n")
	_e2e_write(dir, "web/app.ts", "export const title = 'main';\nexport const n = 1;\n")
	g(t, dir, "add", "-A"); g(t, dir, "commit", "-q", "-m", "main")
	testing.expect(t, !_e2e_git(t, dir, "merge", "feature"), "merge must stop with conflicts")

	q: git.Git_Queue
	git.git_queue_init(&q, dir, runtime.heap_allocator()) // worker thread: not the temp allocator
	defer git.git_queue_destroy(&q)

	r := _e2e_wait(t, &q, git.git_request_repo_state(&q))
	st := r.payload.(git.Repo_State)
	testing.expect_value(t, st.operation, git.Repo_Operation.Merging)
	testing.expect_value(t, len(st.conflicts), 3)
	text, _ := merge_resolver_banner_for(st.operation, len(st.conflicts))
	testing.expect(t, strings.has_prefix(text, "3 files in conflict"))
	files := make([]string, len(st.conflicts))
	for f, i in st.conflicts { files[i] = strings.clone(f) }

	for f, i in files {
		r = _e2e_wait(t, &q, git.git_request_merge_load(&q, f))
		mf := git.merge_file_result(r)
		testing.expect(t, mf != nil && git.merge_text_has_markers(mf.merged), f)
		if mf == nil { return }
		d: Mr_Doc
		mr_doc_init(&d, mf.merged)
		defer mr_doc_destroy(&d)
		testing.expect(t, len(d.blocks) >= 1)

		// Done with markers left is refused
		r = _e2e_wait(t, &q, git.git_request_merge_resolve(&q, f, mr_text(&d)))
		res := git.merge_op_result(r)
		testing.expect(t, res != nil && !res.ok, "markers must be refused")

		// Resolve the way the panel does: Local for every conflict
		for b in 0 ..< len(d.blocks) { mr_handle_side(&d, b, .Ours, true) }
		testing.expect(t, mr_all_resolved(&d))
		r = _e2e_wait(t, &q, git.git_request_merge_resolve(&q, f, mr_text(&d)))
		res = git.merge_op_result(r)
		testing.expect(t, res != nil && res.ok, f)
		if res == nil { return }
		testing.expect_value(t, res.state.operation, git.Repo_Operation.Merging)
		testing.expect_value(t, len(res.state.conflicts), len(files) - i - 1)
	}
	text, _ = merge_resolver_banner_for(.Merging, 0)
	testing.expect(t, strings.has_prefix(text, "Merge ready to commit"))

	r = _e2e_wait(t, &q, git.git_request_merge_complete(&q))
	res := git.merge_op_result(r)
	testing.expect(t, res != nil && res.ok)
	if res == nil { return }
	testing.expect_value(t, res.state.operation, git.Repo_Operation.Clean)
	testing.expect_value(t, len(res.state.conflicts), 0)
	text, _ = merge_resolver_banner_for(res.state.operation, 0)
	testing.expect_value(t, text, "")

	out, _ := git.git_run(dir, {"rev-list", "--parents", "-n", "1", "HEAD"}, context.temp_allocator)
	testing.expect_value(t, len(strings.fields(out)), 3) // merge commit + 2 parents
	cfg, _ := os.read_entire_file(fmt.tprintf("%s/config.go", dir), context.temp_allocator)
	testing.expect(t, strings.contains(string(cfg), "\"prod\"") && strings.contains(string(cfg), "Timeout: 15,\n}"), string(cfg))
	testing.expect(t, os.exists(fmt.tprintf("%s/web/feature.ts", dir)), "clean change from feature lost")
	porcelain, _ := git.git_run(dir, {"status", "--porcelain"}, context.temp_allocator)
	testing.expect_value(t, strings.trim_space(porcelain), "")
	testing.expect(t, !os.exists(fmt.tprintf("%s/.git/MERGE_HEAD", dir)))
}
