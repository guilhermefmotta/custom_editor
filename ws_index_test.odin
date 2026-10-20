package editor

// Workspace index, fast directory listing and search helpers (ADR 0017).

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import git "./git"

@(private="file")
_tmp_tree :: proc(name: string) -> string {
	base := os.get_env("TMPDIR", context.temp_allocator)
	if base == "" { base = "/tmp" }
	dir := fmt.tprintf("%s/editor-%s-%d", strings.trim_right(base, "/\\"), name, os.get_pid())
	_ = os.remove_all(dir)
	_ = os.make_directory(dir)
	write :: proc(dir, rel, content: string) {
		p := fmt.tprintf("%s/%s", dir, rel)
		_ = os.make_directory_all(p[:strings.last_index_byte(p, '/')])
		_ = os.write_entire_file(p, transmute([]u8)content)
	}
	write(dir, "src/main.go", "package main\n")
	write(dir, "src/util/str.go", "package util\n")
	write(dir, "README.md", "hi\n")
	write(dir, "node_modules/dep/index.js", "x\n")
	write(dir, ".hidden/secret.txt", "x\n")
	write(dir, "logs/app.log", "x\n")
	return dir
}

@(private="file")
_sorted :: proc(files: []string) -> []string {
	out := slice.clone(files, context.temp_allocator)
	slice.sort(out)
	return out
}

@(test)
test_fast_list_and_walk :: proc(t: ^testing.T) {
	dir := _tmp_tree("fastdir")
	defer os.remove_all(dir)

	entries := make([dynamic]Dir_Entry, context.temp_allocator)
	testing.expect(t, fast_list_dir(dir, &entries, context.temp_allocator))
	kinds := make(map[string]bool, context.temp_allocator)
	for en in entries { kinds[en.name] = en.is_dir }
	testing.expect_value(t, len(entries), 5)
	testing.expect(t, kinds["src"])
	testing.expect(t, !kinds["README.md"])
	testing.expect(t, !fast_list_dir(fmt.tprintf("%s/nope", dir), &entries, context.temp_allocator))

	// A link back to the root must not be followed (no endless walk)
	when ODIN_OS != .Windows {
		_ = os.symlink(dir, fmt.tprintf("%s/src/loop", dir))
	}

	files := make([dynamic]string, context.temp_allocator)
	fast_walk_files(dir, &files, nil, context.temp_allocator)
	got := _sorted(files[:])
	testing.expect_value(t, len(got), 4)
	if len(got) == 4 {
		testing.expect_value(t, got[0], "README.md")
		testing.expect_value(t, got[1], "logs/app.log")
		testing.expect_value(t, got[2], "src/main.go")
		testing.expect_value(t, got[3], "src/util/str.go")
	}
}

@(test)
test_ws_index_build_git_and_fallback :: proc(t: ^testing.T) {
	dir := _tmp_tree("wsindex")
	defer os.remove_all(dir)

	// Not a repository: disk walk
	snap := ws_index_build(dir, false)
	testing.expect(t, snap != nil && !snap.from_git)
	if snap != nil { testing.expect_value(t, len(snap.files), 4) }
	ws_snapshot_release(snap)

	run :: proc(dir: string, args: ..string) {
		out, _ := git.git_run(dir, args)
		delete(out)
	}
	run(dir, "init", "-q")
	_ = os.write_entire_file(fmt.tprintf("%s/.gitignore", dir), transmute([]u8)string("*.log\nnode_modules/\n"))
	run(dir, "add", "src/main.go")

	// Tracked + untracked, minus .gitignore (README and str.go are untracked)
	snap = ws_index_build(dir, false)
	testing.expect(t, snap != nil && snap.from_git)
	if snap != nil {
		got := _sorted(snap.files)
		testing.expect_value(t, len(got), 5)
		if len(got) == 5 {
			testing.expect_value(t, got[0], ".gitignore")
			testing.expect_value(t, got[1], ".hidden/secret.txt")
			testing.expect_value(t, got[2], "README.md")
			testing.expect_value(t, got[3], "src/main.go")
			testing.expect_value(t, got[4], "src/util/str.go")
		}
	}
	ws_snapshot_release(snap)

	// Ignored files included on request, but never node_modules/.git
	snap = ws_index_build(dir, true)
	if snap != nil {
		got := _sorted(snap.files)
		testing.expect(t, slice.contains(got, "logs/app.log"))
		testing.expect(t, !slice.contains(got, "node_modules/dep/index.js"))
	}
	ws_snapshot_release(snap)
}

@(test)
test_ws_path_helpers :: proc(t: ^testing.T) {
	testing.expect(t, ws_path_in_skipped_dir("a/node_modules/x.js"))
	testing.expect(t, ws_path_in_skipped_dir(".git/config"))
	testing.expect(t, !ws_path_in_skipped_dir("src/build.go")) // a file named like a skipped folder
	testing.expect_value(t, ws_basename("a/b/c.go"), "c.go")
	testing.expect_value(t, ws_basename("c.go"), "c.go")
	testing.expect(t, ws_same_file("src/a.go", "/w/src/a.go"))
	testing.expect(t, !ws_same_file("a.go", "/w/src/ba.go"))
}

@(test)
test_rg_parse_line :: proc(t: ^testing.T) {
	res, ok := rg_parse_line("src/a.go\x0012:5:foo := bar:baz", 3)
	testing.expect(t, ok)
	testing.expect_value(t, res.file, "src/a.go")
	testing.expect_value(t, res.line, 12)
	testing.expect_value(t, res.col, 5)
	testing.expect_value(t, res.ctx, "foo := bar:baz")
	testing.expect_value(t, res.match_len, 3)
	search_result_free(&res)
	_, ok = rg_parse_line("no null byte here", 3)
	testing.expect(t, !ok)
	_, ok = rg_parse_line("a\x00x:y:z", 3)
	testing.expect(t, !ok)
}

@(test)
test_pal_files_rank :: proc(t: ^testing.T) {
	files := []string{"src/main/long/path/x.go", "main.go", "pkg/main/y.go", "cmd/main.go"}
	hits := []i32{0, 1, 2, 3}
	pal_files_rank(files, hits, "main")
	// File names containing "main" first (shorter first), folders-only after
	testing.expect_value(t, files[hits[0]], "main.go")
	testing.expect_value(t, files[hits[1]], "cmd/main.go")
	testing.expect_value(t, files[hits[2]], "pkg/main/y.go")
	testing.expect_value(t, files[hits[3]], "src/main/long/path/x.go")
}
