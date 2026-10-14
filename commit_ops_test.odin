package editor

// Pure tests for commit_ops.odin (features/commit-ops.feature). The git side
// (cherry-pick, revert, reset, rebase -i against real repos) is tested in
// git/commit_ops_test.odin.

import "core:testing"
import git "./git"

// teste: test_commit_ops_menu_items
@(test)
test_commit_ops_menu_items :: proc(t: ^testing.T) {
	items := commit_ops_menu_items()
	testing.expect_value(t, len(items), len(Commit_Menu_Action))
	testing.expect_value(t, items[int(Commit_Menu_Action.Cherry_Pick)], "Cherry-pick")
	testing.expect_value(t, items[int(Commit_Menu_Action.Revert)], "Revert")
	testing.expect_value(t, items[int(Commit_Menu_Action.Reset_Hard)], "Reset hard (discard)...")
	testing.expect_value(t, items[int(Commit_Menu_Action.Interactive_Rebase)], "Interactive rebase...")
	testing.expect_value(t, items[int(Commit_Menu_Action.Create_Branch)], "Create branch here...")
	testing.expect_value(t, items[int(Commit_Menu_Action.Create_Tag)], "Create tag here...")
	testing.expect_value(t, items[int(Commit_Menu_Action.Copy_Hash)], "Copy hash")
	for s in items { testing.expect(t, s != "") }
}

// teste: test_commit_ops_reset_hard_needs_confirm
@(test)
test_commit_ops_reset_hard_needs_confirm :: proc(t: ^testing.T) {
	for a in Commit_Menu_Action {
		testing.expect_value(t, commit_ops_needs_confirm(a), a == .Reset_Hard)
	}
}

@(test)
test_commit_ops_reword_message :: proc(t: ^testing.T) {
	m := commit_ops_reword_message("old subject\n\nbody\nmore", " new ", context.temp_allocator)
	testing.expect_value(t, m, "new\n\nbody\nmore")
	m = commit_ops_reword_message("only", "new", context.temp_allocator)
	testing.expect_value(t, m, "new")
	testing.expect_value(t, commit_ops_first_line("a\nb"), "a")
}

@(test)
test_commit_ops_cycle_action :: proc(t: ^testing.T) {
	testing.expect_value(t, commit_ops_cycle_action(.Pick), git.Rebase_Action.Reword)
	testing.expect_value(t, commit_ops_cycle_action(.Drop), git.Rebase_Action.Pick)
}
