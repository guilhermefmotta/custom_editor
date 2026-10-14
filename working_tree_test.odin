package editor

// Pure logic of the working_tree panel (features/working-tree.feature).

import "core:testing"
import git "./git"

// # teste: test_wt_sections_group_and_count
@(test)
test_wt_sections_group_and_count :: proc(t: ^testing.T) {
	entries := []git.Status_Entry{
		{index = 'M', worktree = ' ', path = "staged.txt"},
		{index = ' ', worktree = 'M', path = "mod.txt"},
		{index = '?', worktree = '?', path = "new.txt"},
		{index = 'U', worktree = 'U', path = "conflict.txt"},
		{index = 'M', worktree = 'M', path = "both.txt"},
		{index = 'A', worktree = 'A', path = "addadd.txt"},
		{index = 'R', worktree = ' ', path = "b.txt", old_path = "a.txt"},
	}
	rows := wt_build_rows(entries, "", .Staged, 0)

	headers := make([dynamic]Wt_Row, context.temp_allocator)
	for r in rows { if r.kind == .Header { append(&headers, r) } }
	testing.expect_value(t, len(headers), 4)
	if len(headers) != 4 { return }
	order := [4]git.Wt_Section{.Conflicts, .Staged, .Unstaged, .Untracked}
	counts := [4]int{2, 3, 2, 1}
	for h, i in headers {
		testing.expect_value(t, h.section, order[i])
		testing.expect_value(t, h.count, counts[i])
	}
	testing.expect_value(t, len(rows), 4 + 2 + 3 + 2 + 1)

	in_sec :: proc(rows: []Wt_Row, entries: []git.Status_Entry, path: string, s: git.Wt_Section) -> bool {
		for r in rows { if r.kind == .File && r.section == s && entries[r.entry].path == path { return true } }
		return false
	}
	testing.expect(t, in_sec(rows, entries, "both.txt", .Staged) && in_sec(rows, entries, "both.txt", .Unstaged))
	testing.expect(t, in_sec(rows, entries, "conflict.txt", .Conflicts))
	testing.expect(t, !in_sec(rows, entries, "conflict.txt", .Staged) && !in_sec(rows, entries, "conflict.txt", .Unstaged))
	testing.expect(t, !in_sec(rows, entries, "addadd.txt", .Staged))

	// Expanded file gets hunk rows right after it
	rows2 := wt_build_rows(entries, "both.txt", .Unstaged, 3)
	testing.expect_value(t, len(rows2), len(rows) + 3)
	for r, i in rows2 {
		if r.kind == .File && r.section == .Unstaged && entries[r.entry].path == "both.txt" {
			testing.expect_value(t, rows2[i + 1].kind, Wt_Row_Kind.Hunk)
			testing.expect_value(t, rows2[i + 3].hunk, 2)
		}
	}

	// Section paths: staged renames carry the old path too
	sp := wt_section_paths(entries, .Staged)
	testing.expect_value(t, len(sp), 4)
	testing.expect_value(t, len(wt_section_paths(entries, .Untracked)), 1)

	testing.expect_value(t, len(wt_build_rows(nil, "", .Staged, 0)), 0)
}

// # teste: test_wt_commit_shortcut
@(test)
test_wt_commit_shortcut :: proc(t: ^testing.T) {
	testing.expect(t, wt_is_commit_chord(true, true))
	testing.expect(t, !wt_is_commit_chord(false, true)) // plain Enter = new line in the message
	testing.expect(t, !wt_is_commit_chord(true, false))

	op, err := wt_commit_plan("fix: thing", false, false)
	testing.expect_value(t, op, git.Wt_Op.Commit)
	testing.expect_value(t, err, "")
	_, err = wt_commit_plan("   ", false, false)
	testing.expect(t, err != "")
	op, err = wt_commit_plan("", true, false)
	testing.expect_value(t, op, git.Wt_Op.Amend)
	testing.expect_value(t, err, "")
	op, err = wt_commit_plan("", false, true) // merge: git's prepared message
	testing.expect_value(t, op, git.Wt_Op.Commit)
	testing.expect_value(t, err, "")
	_, err = wt_commit_plan("x", true, true)
	testing.expect(t, err != "")
}
