package editor

// Pure-model tests for the refs sidebar (features/sidebar-refs.feature).

import "core:testing"
import "git"

@(private="file")
_sb_test_snap :: proc() -> git.Refs_Snapshot {
	@(static) branches := [?]git.Branch{
		{name = "main", is_head = true, upstream = "origin/main", ahead = 1, behind = 1, hash = "aaaaaaa1"},
		{name = "feat", hash = "bbbbbbb2"},
		{name = "origin/main", is_remote = true, remote = "origin", hash = "ccccccc3"},
		{name = "origin/feat", is_remote = true, remote = "origin", hash = "ddddddd4"},
		{name = "upstream/x", is_remote = true, remote = "upstream", hash = "eeeeeee5"},
	}
	@(static) tags := [?]git.Tag{{name = "v1", hash = "ffffffff"}}
	@(static) stashes := [?]git.Stash{{index = 0, ref = "stash@{0}", message = "WIP on main", hash = "1234567"}}
	@(static) reflog := [?]git.Reflog_Entry{{hash = "abcdef012", action = "commit", message = "x"}}
	return git.Refs_Snapshot{branches = branches[:], tags = tags[:], stashes = stashes[:], reflog = reflog[:]}
}

// teste: test_sidebar_rows_sections_and_remote_groups
@(test)
test_sidebar_rows_sections_and_remote_groups :: proc(t: ^testing.T) {
	snap := _sb_test_snap()
	v: Sidebar_View
	defer sidebar_view_destroy(&v)
	rows: [dynamic]Sidebar_Row
	defer delete(rows)
	sidebar_build_rows(&snap, &v, &rows)

	kinds := [?]Sidebar_Row_Kind{
		.Section, .Local_Branch, .Local_Branch,
		.Section, .Remote_Group, .Remote_Branch, .Remote_Branch, .Remote_Group, .Remote_Branch,
		.Section, .Tag,
		.Section, .Stash,
		.Section, .Empty,
		.Section, .Reflog,
	}
	testing.expect_value(t, len(rows), len(kinds))
	for k, i in kinds {
		if i < len(rows) { testing.expectf(t, rows[i].kind == k, "row %d: %v != %v", i, rows[i].kind, k) }
	}
	testing.expect_value(t, rows[4].group, "origin")
	testing.expect_value(t, rows[7].group, "upstream")
	testing.expect_value(t, sidebar_row_name(&snap, rows[5]), "main") // remote prefix stripped under its group
	testing.expect_value(t, sidebar_section_count(&snap, .Remote), 3)
	testing.expect_value(t, sidebar_section_count(&snap, .Local), 2)

	v.collapsed[.Remote] = true
	sidebar_build_rows(&snap, &v, &rows)
	testing.expect_value(t, len(rows), len(kinds) - 5)
}

// teste: test_sidebar_filter_is_per_section
@(test)
test_sidebar_filter_is_per_section :: proc(t: ^testing.T) {
	snap := _sb_test_snap()
	v: Sidebar_View
	defer sidebar_view_destroy(&v)
	rows: [dynamic]Sidebar_Row
	defer delete(rows)
	append(&v.filters[.Remote], "fe")
	sidebar_build_rows(&snap, &v, &rows)
	locals, remotes, groups := 0, 0, 0
	for r in rows {
		#partial switch r.kind {
		case .Local_Branch:  locals += 1
		case .Remote_Branch: remotes += 1; testing.expect_value(t, snap.branches[r.index].name, "origin/feat")
		case .Remote_Group:  groups += 1
		}
	}
	testing.expect_value(t, locals, 2)  // other sections untouched
	testing.expect_value(t, remotes, 1)
	testing.expect_value(t, groups, 1)  // "upstream" group hidden: no matches

	clear(&v.filters[.Remote]); append(&v.filters[.Remote], "zzz")
	sidebar_build_rows(&snap, &v, &rows)
	found_empty := false
	for r in rows { if r.section == .Remote && r.kind == .Empty { found_empty = true } }
	testing.expect(t, found_empty)
}

// teste: test_sidebar_ahead_behind_label
@(test)
test_sidebar_ahead_behind_label :: proc(t: ^testing.T) {
	testing.expect_value(t, sidebar_ahead_behind({ahead = 1, behind = 1}), "↑1 ↓1")
	testing.expect_value(t, sidebar_ahead_behind({ahead = 3}), "↑3")
	testing.expect_value(t, sidebar_ahead_behind({behind = 2}), "↓2")
	testing.expect_value(t, sidebar_ahead_behind({}), "")
	testing.expect_value(t, sidebar_ahead_behind({upstream_gone = true, ahead = 1}), "gone")
}

@(private="file")
_has :: proc(acts: []Sidebar_Action, a: Sidebar_Action) -> bool {
	for x in acts { if x == a { return true } }
	return false
}

// teste: test_sidebar_menu_actions_by_row_kind
@(test)
test_sidebar_menu_actions_by_row_kind :: proc(t: ^testing.T) {
	snap := _sb_test_snap()
	buf: [SIDEBAR_MAX_ACTIONS]Sidebar_Action

	feat := sidebar_menu_actions(&snap, {kind = .Local_Branch, index = 1}, &buf)
	for a in ([]Sidebar_Action{.Checkout, .New_Branch, .Rename, .Delete_Branch, .Merge, .Rebase, .Push, .Show_In_Graph}) {
		testing.expectf(t, _has(feat, a), "feat menu lacks %v", a)
	}
	head := sidebar_menu_actions(&snap, {kind = .Local_Branch, index = 0}, &buf)
	testing.expect(t, !_has(head, .Checkout) && !_has(head, .Delete_Branch) && !_has(head, .Merge))
	testing.expect(t, _has(head, .Push) && _has(head, .Rename))

	remote := sidebar_menu_actions(&snap, {kind = .Remote_Branch, index = 3, group = "origin"}, &buf)
	testing.expect(t, _has(remote, .Checkout) && _has(remote, .Delete_Remote_Branch) && !_has(remote, .Rename))

	stash := sidebar_menu_actions(&snap, {kind = .Stash, index = 0}, &buf)
	testing.expect(t, _has(stash, .Stash_Apply) && _has(stash, .Stash_Pop) && _has(stash, .Stash_Drop))

	tag := sidebar_menu_actions(&snap, {kind = .Tag, index = 0}, &buf)
	testing.expect(t, _has(tag, .Delete_Tag))
	tags_hdr := sidebar_menu_actions(&snap, {kind = .Section, section = .Tags}, &buf)
	testing.expect(t, _has(tags_hdr, .New_Tag))

	testing.expect_value(t, sidebar_row_rev(&snap, {kind = .Remote_Branch, index = 3}), "origin/feat")
	for a in Sidebar_Action { testing.expect(t, SIDEBAR_ACTION_LABELS[a] != "") }
}

// teste: test_sidebar_activate_records_branch
@(test)
test_sidebar_activate_records_branch :: proc(t: ^testing.T) {
	// commit_graph isn't registered in this base: the open is a no-op
	sidebar_on_branch_activate(nil, "feat")
	testing.expect_value(t, sidebar_active_branch, "feat")
	sidebar_on_branch_activate(nil, "origin/main")
	testing.expect_value(t, sidebar_active_branch, "origin/main")
	delete(sidebar_active_branch)
	sidebar_active_branch = ""
}
