package editor

// Review mode — git side and pure logic (ticket #17, ADR 0015).
//
// "What the session changed" = `git diff <base>` against the working tree,
// where <base> is HEAD when the session started (Claude_Session.base_rev),
// plus untracked files. Diffing against the start point (not the current
// HEAD) keeps changes visible even after Claude commits them. A repo with
// no commits uses the empty tree.
//
// The work procs run on the repository's git queue (git_request_custom);
// the panel is review_mode.odin.

import "core:os"
import "core:slice"
import "core:strings"
import git "./git"

REVIEW_EMPTY_TREE :: "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

Review_File :: struct {
	path:   string,
	status: u8, // 'M' modified, 'A' added, 'D' deleted, 'T' type change, '?' untracked
}

Review_List :: struct {
	files: []Review_File,
}

Review_Diff_Raw :: struct {
	text:      string,
	all_added: bool,
}

review_base_or_empty :: proc(base: string) -> string {
	return base if base != "" else REVIEW_EMPTY_TREE
}

// Parses `git diff --name-status --no-renames -z` and
// `git ls-files --others --exclude-standard -z`; sorted by path.
review_parse_changes :: proc(name_status, untracked: string, allocator := context.allocator) -> []Review_File {
	out := make([dynamic]Review_File, allocator)
	parts := strings.split(name_status, "\x00", context.temp_allocator)
	for i := 0; i + 1 < len(parts); i += 2 {
		st := parts[i]
		if st == "" { break }
		append(&out, Review_File{path = strings.clone(parts[i + 1], allocator), status = st[0]})
	}
	for p in strings.split(untracked, "\x00", context.temp_allocator) {
		if p == "" { continue }
		append(&out, Review_File{path = strings.clone(p, allocator), status = '?'})
	}
	slice.sort_by(out[:], proc(a, b: Review_File) -> bool { return a.path < b.path })
	return out[:]
}

// Work proc: args = {base}. Payload Git_Custom(Review_List).
review_list_work :: proc(root: string, args: []string, user: rawptr) -> (payload: git.Git_Payload, err: string) {
	base := review_base_or_empty(args[0] if len(args) > 0 else "")
	ns, ok := git.git_run(root, {"diff", "--name-status", "--no-renames", "-z", base})
	if !ok { return nil, "git diff failed (is the session's start commit still there?)" }
	un, _ := git.git_run(root, {"ls-files", "--others", "--exclude-standard", "-z"})
	l, c := git.git_custom_new(Review_List)
	l.files = review_parse_changes(ns, un)
	return c, ""
}

// Work proc: args = {base, path}. Payload Git_Custom(Review_Diff_Raw).
review_diff_work :: proc(root: string, args: []string, user: rawptr) -> (payload: git.Git_Payload, err: string) {
	if len(args) < 2 { return nil, "bad request" }
	base, path := review_base_or_empty(args[0]), args[1]
	d, c := git.git_custom_new(Review_Diff_Raw)
	if out, ok := git.git_run(root, {"diff", "-U2147483647", base, "--", path}); ok && out != "" {
		d.text = out
		return c, ""
	}
	// Not in base and not tracked: the whole file is new.
	abs := strings.concatenate({root, "/", path})
	if data, rerr := os.read_entire_file(abs, context.allocator); rerr == nil {
		d.text, d.all_added = string(data), true
		return c, ""
	}
	return nil, "no changes"
}

// Sets / toggles the reviewed mark of `path` in the session (in memory).
review_set :: proc(s: ^Claude_Session, path: string, on: bool) {
	if path in s.reviewed { s.reviewed[path] = on; return }
	s.reviewed[strings.clone(path)] = on
}

review_toggle :: proc(s: ^Claude_Session, path: string) {
	review_set(s, path, !review_is_reviewed(s, path))
}

review_is_reviewed :: proc(s: ^Claude_Session, path: string) -> bool {
	return s.reviewed[path] or_else false
}

// (reviewed, total) among `files`.
review_progress :: proc(s: ^Claude_Session, files: []Review_File) -> (done, total: int) {
	for f in files { if review_is_reviewed(s, f.path) { done += 1 } }
	return done, len(files)
}
