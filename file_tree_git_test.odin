package editor

// Tests for the file tree git badges (#11) — features/tree-git-badges.feature.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import git "./git"

@(private="file")
_E :: proc(xy: string, path: string, old := "") -> git.Status_Entry {
	return git.Status_Entry{index = xy[0], worktree = xy[1], path = path, old_path = old}
}

// # teste: test_tree_git_classify_porcelain
@(test)
test_tree_git_classify_porcelain :: proc(t: ^testing.T) {
	Case :: struct { xy: string, want: Tree_Git_Kind }
	cases := []Case{
		{" M", .Modified}, {"M ", .Modified}, {"MM", .Modified}, {" T", .Modified}, {"T ", .Modified},
		{"A ", .Added}, {"AM", .Added}, {"C ", .Added},
		{"??", .Untracked},
		{" D", .Deleted}, {"D ", .Deleted}, {"MD", .Deleted}, {"AD", .Deleted}, {"RD", .Deleted},
		{"R ", .Renamed}, {"RM", .Renamed}, {" R", .Renamed},
		{"UU", .Conflicted}, {"AA", .Conflicted}, {"DD", .Conflicted},
		{"DU", .Conflicted}, {"UD", .Conflicted}, {"AU", .Conflicted}, {"UA", .Conflicted},
		{"!!", .None}, {"  ", .None},
	}
	for c in cases {
		got := tree_git_classify(c.xy[0], c.xy[1])
		testing.expectf(t, got == c.want, "%q: got %v, want %v", c.xy, got, c.want)
	}
}

// # teste: test_tree_git_letters_and_colors
@(test)
test_tree_git_letters_and_colors :: proc(t: ^testing.T) {
	testing.expect_value(t, tree_git_letter(.Modified), "M")
	testing.expect_value(t, tree_git_letter(.Added), "A")
	testing.expect_value(t, tree_git_letter(.Untracked), "U")
	testing.expect_value(t, tree_git_letter(.Deleted), "D")
	testing.expect_value(t, tree_git_letter(.Renamed), "R")
	testing.expect_value(t, tree_git_letter(.Conflicted), "!")
	testing.expect_value(t, tree_git_letter(.None), "")
	testing.expect(t, tree_git_color(.Modified) == GITD_YELLOW)
	testing.expect(t, tree_git_color(.Added) == GITD_GREEN)
	testing.expect(t, tree_git_color(.Untracked) == GITD_GREEN)
	testing.expect(t, tree_git_color(.Deleted) == GITD_RED)
	testing.expect(t, tree_git_color(.Renamed) == GITD_BLUE)
	testing.expect(t, tree_git_color(.Conflicted) == TREE_GIT_PURPLE)
	// Priority order used by folder dots
	testing.expect(t, Tree_Git_Kind.Conflicted > .Deleted && Tree_Git_Kind.Deleted > .Modified &&
		Tree_Git_Kind.Modified > .Renamed && Tree_Git_Kind.Renamed > .Added && Tree_Git_Kind.Added > .Untracked)
}

// # teste: test_tree_git_index_dir_priority
@(test)
test_tree_git_index_dir_priority :: proc(t: ^testing.T) {
	entries := []git.Status_Entry{
		_E("??", "src/a/new.txt"),
		_E(" M", "src/b/mod.odin"),
		_E("UU", "src/b/c/conf.odin"),
		_E("R ", "docs/new.md", "docs/old.md"),
		_E("A ", "docs/added.md"),
		_E(" D", "gone/x/y.txt"),
		_E("!!", "ignored.bin"),
	}
	idx: Tree_Git_Index
	defer tree_git_index_destroy(&idx)
	tree_git_index_build(&idx, entries, "/r", "/r")

	testing.expect_value(t, tree_git_file_kind(&idx, "src/a/new.txt"), Tree_Git_Kind.Untracked)
	testing.expect_value(t, tree_git_file_kind(&idx, "./src/b/mod.odin"), Tree_Git_Kind.Modified)
	testing.expect_value(t, tree_git_file_kind(&idx, "docs/new.md"), Tree_Git_Kind.Renamed)
	testing.expect_value(t, tree_git_file_kind(&idx, "ignored.bin"), Tree_Git_Kind.None)
	testing.expect_value(t, tree_git_file_kind(&idx, "README"), Tree_Git_Kind.None)
	testing.expect_value(t, tree_git_dir_kind(&idx, "src"), Tree_Git_Kind.Conflicted)
	testing.expect_value(t, tree_git_dir_kind(&idx, "src/a"), Tree_Git_Kind.Untracked)
	testing.expect_value(t, tree_git_dir_kind(&idx, "src/b"), Tree_Git_Kind.Conflicted)
	testing.expect_value(t, tree_git_dir_kind(&idx, "docs"), Tree_Git_Kind.Renamed)
	testing.expect_value(t, tree_git_dir_kind(&idx, "gone"), Tree_Git_Kind.Deleted)
	testing.expect_value(t, tree_git_dir_kind(&idx, "clean"), Tree_Git_Kind.None)
	testing.expect_value(t, idx.repo_rel["docs/new.md"], "docs/new.md")

	// Tree rooted in a subfolder of the repo: keys relative to it, outside dropped.
	sub: Tree_Git_Index
	defer tree_git_index_destroy(&sub)
	tree_git_index_build(&sub, entries, "/r", "/r/src")
	testing.expect_value(t, tree_git_file_kind(&sub, "b/mod.odin"), Tree_Git_Kind.Modified)
	testing.expect_value(t, tree_git_dir_kind(&sub, "b"), Tree_Git_Kind.Conflicted)
	testing.expect_value(t, tree_git_file_kind(&sub, "docs/new.md"), Tree_Git_Kind.None)
	testing.expect_value(t, len(sub.files), 3)
	testing.expect_value(t, sub.repo_rel["b/mod.odin"], "src/b/mod.odin")
}

// # teste: test_tree_git_index_untracked_dir
@(test)
test_tree_git_index_untracked_dir :: proc(t: ^testing.T) {
	entries := []git.Status_Entry{_E("??", "tools/gen/"), _E(" M", "tools/run.sh")}
	idx: Tree_Git_Index
	defer tree_git_index_destroy(&idx)
	tree_git_index_build(&idx, entries, "/r", "/r")
	testing.expect_value(t, tree_git_dir_kind(&idx, "tools/gen"), Tree_Git_Kind.Untracked)
	testing.expect_value(t, tree_git_file_kind(&idx, "tools/gen/deep/x.c"), Tree_Git_Kind.Untracked)
	testing.expect_value(t, tree_git_dir_kind(&idx, "tools/gen/deep"), Tree_Git_Kind.Untracked)
	testing.expect_value(t, tree_git_dir_kind(&idx, "tools"), Tree_Git_Kind.Modified)
	testing.expect_value(t, tree_git_file_kind(&idx, "tools/generator"), Tree_Git_Kind.None)
}

// # teste: test_tree_git_deleted_children
@(test)
test_tree_git_deleted_children :: proc(t: ^testing.T) {
	entries := []git.Status_Entry{
		_E(" D", "top.txt"), _E("D ", "a/one.txt"), _E(" D", "a/b/two.txt"),
		_E(" D", "a/b/three.txt"), _E(" M", "a/kept.txt"), _E(" D", "ab.txt"),
	}
	idx: Tree_Git_Index
	defer tree_git_index_destroy(&idx)
	tree_git_index_build(&idx, entries, "/r", "/r")

	f, d := tree_git_deleted_children(&idx, ".")
	testing.expect_value(t, len(f), 2)
	if len(f) == 2 { testing.expect_value(t, f[0], "ab.txt"); testing.expect_value(t, f[1], "top.txt") }
	testing.expect_value(t, len(d), 1)
	if len(d) == 1 { testing.expect_value(t, d[0], "a") }

	f, d = tree_git_deleted_children(&idx, "a")
	testing.expect_value(t, len(f), 1)
	testing.expect_value(t, len(d), 1)
	f, d = tree_git_deleted_children(&idx, "./a/b")
	testing.expect_value(t, len(f), 2)
	testing.expect_value(t, len(d), 0)
	f, d = tree_git_deleted_children(&idx, "zzz")
	testing.expect_value(t, len(f) + len(d), 0)
}

// # teste: test_tree_git_inject_deleted
@(test)
test_tree_git_inject_deleted :: proc(t: ^testing.T) {
	ft := file_tree_init()
	defer file_tree_destroy(&ft)
	entries := []git.Status_Entry{_E(" D", "a/gone.txt"), _E(" D", "a/sub/x.txt"), _E(" D", "a/here/y.txt")}
	tree_git_index_build(&ft.git_idx, entries, "/r", "/r")

	dirs  := make([dynamic]File_Tree_Node, context.temp_allocator)
	files := make([dynamic]File_Tree_Node, context.temp_allocator)
	append(&dirs, File_Tree_Node{name = strings.clone("here"), path = strings.clone("a/here"), is_dir = true, depth = 1})
	_ft_inject_deleted(&ft, "a", 1, &dirs, &files)
	defer for n in dirs  { delete(n.name); delete(n.path) }
	defer for n in files { delete(n.name); delete(n.path) }

	testing.expect_value(t, len(dirs), 2) // "here" exists on disk, "sub" injected
	testing.expect_value(t, len(files), 1)
	if len(files) == 1 {
		testing.expect_value(t, files[0].path, "a/gone.txt")
		testing.expect(t, files[0].ghost)
		testing.expect_value(t, files[0].depth, 1)
	}
	if len(dirs) == 2 {
		testing.expect(t, !dirs[0].ghost)
		testing.expect_value(t, dirs[1].path, "a/sub")
		testing.expect(t, dirs[1].ghost && dirs[1].is_dir)
	}
}

@(private="file")
_row_str :: proc(rows: []File_Tree_Node) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r in rows {
		for _ in 0..<r.depth { strings.write_string(&b, "  ") }
		strings.write_string(&b, r.name)
		if r.is_dir { strings.write_string(&b, "/" if r.expanded else "/+") }
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// # teste: test_tree_git_changed_rows
@(test)
test_tree_git_changed_rows :: proc(t: ^testing.T) {
	paths := []string{"src/b/z.odin", "README.md", "src/a.odin", "src/b/c/d.odin", "gen", "docs/x.md"}
	collapsed: map[string]bool
	rows := tree_git_changed_rows(paths, {"gen"}, collapsed, context.temp_allocator)
	want := "docs/\n  x.md\ngen/+\nsrc/\n  b/\n    c/\n      d.odin\n    z.odin\n  a.odin\nREADME.md\n"
	testing.expect_value(t, _row_str(rows[:]), want)
	testing.expect_value(t, rows[len(rows)-1].path, "README.md")
	testing.expect_value(t, rows[6].path, "src/b/c/d.odin")
}

// # teste: test_tree_git_changed_rows_collapsed
@(test)
test_tree_git_changed_rows_collapsed :: proc(t: ^testing.T) {
	paths := []string{"src/b/z.odin", "src/a.odin", "top.txt"}
	collapsed := make(map[string]bool, allocator = context.temp_allocator)
	collapsed["src/b"] = true
	rows := tree_git_changed_rows(paths, {}, collapsed, context.temp_allocator)
	testing.expect_value(t, _row_str(rows[:]), "src/\n  b/+\n  a.odin\ntop.txt\n")
}

// # teste: test_tree_git_status_hash
@(test)
test_tree_git_status_hash :: proc(t: ^testing.T) {
	a := []git.Status_Entry{_E(" M", "a.txt"), _E("??", "b.txt")}
	b := []git.Status_Entry{_E(" M", "a.txt"), _E("??", "b.txt")}
	c := []git.Status_Entry{_E("M ", "a.txt"), _E("??", "b.txt")}
	d := []git.Status_Entry{_E(" M", "a.txt")}
	testing.expect(t, tree_git_status_hash(a) == tree_git_status_hash(b))
	testing.expect(t, tree_git_status_hash(a) != tree_git_status_hash(c))
	testing.expect(t, tree_git_status_hash(a) != tree_git_status_hash(d))
}

// Real repository: porcelain from git itself → kinds; deleted file content at HEAD.
// # teste: test_tree_git_real_repo_status
@(test)
test_tree_git_real_repo_status :: proc(t: ^testing.T) {
	base: string
	when ODIN_OS == .Windows {
		base = os.get_env("TEMP", context.temp_allocator)
	} else {
		base = os.get_env("TMPDIR", context.temp_allocator)
		if base == "" { base = "/tmp" }
	}
	dir := fmt.tprintf("%s/editor-tree-git-%d", strings.trim_right(base, "/\\"), os.get_pid())
	_ = os.remove_all(dir)
	_ = os.make_directory(dir)
	defer os.remove_all(dir)

	run :: proc(t: ^testing.T, dir: string, args: ..string) {
		out, ok := git.git_run(dir, args)
		delete(out)
		testing.expectf(t, ok, "git %v failed", args)
	}
	write :: proc(dir, rel, content: string) {
		p := fmt.tprintf("%s/%s", dir, rel)
		_ = os.make_directory_all(p[:strings.last_index_byte(p, '/')])
		_ = os.write_entire_file(p, transmute([]u8)content)
	}
	run(t, dir, "init", "-q", "-b", "main")
	run(t, dir, "config", "user.email", "t@example.com")
	run(t, dir, "config", "user.name", "T")
	run(t, dir, "config", "commit.gpgsign", "false")
	run(t, dir, "config", "core.autocrlf", "false")
	write(dir, "mod.txt", "a\n")
	write(dir, "del/gone.txt", "old content\n")
	write(dir, "ren.txt", "rename me\n")
	write(dir, "conf.txt", "base\n")
	run(t, dir, "add", "-A")
	run(t, dir, "commit", "-q", "-m", "base")
	run(t, dir, "checkout", "-q", "-b", "other")
	write(dir, "conf.txt", "theirs\n")
	run(t, dir, "commit", "-q", "-am", "theirs")
	run(t, dir, "checkout", "-q", "main")
	write(dir, "conf.txt", "ours\n")
	run(t, dir, "commit", "-q", "-am", "ours")
	{ out, _ := git.git_run(dir, {"merge", "-q", "other"}); delete(out) } // conflicts on purpose

	write(dir, "mod.txt", "b\n")
	_ = os.remove(fmt.tprintf("%s/del/gone.txt", dir))
	run(t, dir, "mv", "ren.txt", "renamed.txt")
	write(dir, "staged.txt", "s\n")
	run(t, dir, "add", "staged.txt")
	write(dir, "untracked.txt", "u\n")

	out, ok := git.git_run(dir, {"status", "--porcelain=v1", "-z"})
	defer delete(out)
	testing.expect(t, ok)
	entries := make([dynamic]git.Status_Entry)
	defer {
		for en in entries { delete(en.path); if en.old_path != "" { delete(en.old_path) } }
		delete(entries)
	}
	git._parse_status(out, &entries)

	idx: Tree_Git_Index
	defer tree_git_index_destroy(&idx)
	tree_git_index_build(&idx, entries[:], dir, dir)
	testing.expect_value(t, tree_git_file_kind(&idx, "mod.txt"), Tree_Git_Kind.Modified)
	testing.expect_value(t, tree_git_file_kind(&idx, "del/gone.txt"), Tree_Git_Kind.Deleted)
	testing.expect_value(t, tree_git_file_kind(&idx, "renamed.txt"), Tree_Git_Kind.Renamed)
	testing.expect_value(t, tree_git_file_kind(&idx, "staged.txt"), Tree_Git_Kind.Added)
	testing.expect_value(t, tree_git_file_kind(&idx, "untracked.txt"), Tree_Git_Kind.Untracked)
	testing.expect_value(t, tree_git_file_kind(&idx, "conf.txt"), Tree_Git_Kind.Conflicted)
	testing.expect_value(t, tree_git_dir_kind(&idx, "del"), Tree_Git_Kind.Deleted)
	f, d := tree_git_deleted_children(&idx, ".")
	testing.expect_value(t, len(f), 0)
	testing.expect_value(t, len(d), 1) // "del" only exists in git now

	// Deleted file opens its HEAD version (what tree_head_view requests).
	blob, err := git.git_query_file_at(dir, "HEAD", idx.repo_rel["del/gone.txt"], context.temp_allocator)
	testing.expect_value(t, err, "")
	testing.expect(t, blob.present)
	testing.expect_value(t, blob.text, "old content\n")
}
