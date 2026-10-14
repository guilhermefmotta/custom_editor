package editor

// Pure logic of the working_tree panel (no raylib): sections, rows and the
// commit plan. Covered by working_tree_test.odin.

import "core:strings"
import git "./git"

Wt_Row_Kind :: enum u8 { Header, File, Hunk }

Wt_Row :: struct {
	kind:    Wt_Row_Kind,
	section: git.Wt_Section,
	entry:   int, // index into the status entries (File/Hunk rows)
	hunk:    int, // index into the expanded file's hunks (Hunk rows)
	count:   int, // files in the section (Header rows)
}

WT_SECTION_TITLES := [git.Wt_Section]string{
	.Conflicts = "Conflicts",
	.Staged    = "Staged",
	.Unstaged  = "Unstaged",
	.Untracked = "Untracked",
}

// Which sections an entry belongs to. A file with staged and unstaged
// changes is in both; a conflicted file only in Conflicts.
wt_entry_in_section :: proc(en: git.Status_Entry, s: git.Wt_Section) -> bool {
	x, y := en.index, en.worktree
	conflicted := git.wt_xy_conflicted(x, y)
	switch s {
	case .Conflicts: return conflicted
	case .Untracked: return x == '?' && y == '?'
	case .Staged:    return !conflicted && x != ' ' && x != '?' && x != '!'
	case .Unstaged:  return !conflicted && y != ' ' && y != '?' && y != '!'
	}
	return false
}

// Rows in display order: for every non-empty section a header (with count)
// then its files; the expanded file (exp_path in exp_section) is followed by
// n_hunks hunk rows.
wt_build_rows :: proc(entries: []git.Status_Entry, exp_path: string, exp_section: git.Wt_Section, n_hunks: int, allocator := context.temp_allocator) -> []Wt_Row {
	rows := make([dynamic]Wt_Row, allocator)
	for s in git.Wt_Section {
		n := 0
		for en in entries { if wt_entry_in_section(en, s) { n += 1 } }
		if n == 0 { continue }
		append(&rows, Wt_Row{kind = .Header, section = s, entry = -1, hunk = -1, count = n})
		for en, i in entries {
			if !wt_entry_in_section(en, s) { continue }
			append(&rows, Wt_Row{kind = .File, section = s, entry = i, hunk = -1})
			if exp_path != "" && s == exp_section && en.path == exp_path {
				for h in 0..<n_hunks {
					append(&rows, Wt_Row{kind = .Hunk, section = s, entry = i, hunk = h})
				}
			}
		}
	}
	return rows[:]
}

// Paths of every file in a section (renames in Staged also carry the old
// path, so unstaging restores both sides).
wt_section_paths :: proc(entries: []git.Status_Entry, s: git.Wt_Section, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	for en in entries {
		if !wt_entry_in_section(en, s) { continue }
		append(&out, en.path)
		if s == .Staged && en.old_path != "" { append(&out, en.old_path) }
	}
	return out[:]
}

// What Ctrl/Cmd+Enter does with the current message: the op to enqueue, or
// an error to show. An empty message is allowed for amend (keeps the old
// message) and while merging (git's prepared merge message).
wt_commit_plan :: proc(msg: string, amend, merging: bool) -> (op: git.Wt_Op, err: string) {
	if amend && merging { return .Amend, "cannot amend during a merge" }
	if strings.trim_space(msg) == "" && !amend && !merging { return .Commit, "commit message is empty" }
	return .Amend if amend else .Commit, ""
}

// Commit chord: Enter (or keypad Enter) with Ctrl held (Cmd on macOS).
wt_is_commit_chord :: proc(ctrl_held, enter_pressed: bool) -> bool {
	return ctrl_held && enter_pressed
}
