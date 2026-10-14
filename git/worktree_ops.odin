package git

// ===========================================================================
// Working tree operations (ticket #5, panel `working_tree`).
//
// Worker-side, synchronous procs (`wt_*`) plus their queue wrapper
// `git_request_wt`. The UI only ever calls git_request_wt; the wt_* procs run
// on the queue worker (and directly in tests). Inside them context.allocator
// is the job arena, so nothing here frees what it allocates.
//
// Merge safety (bugs fixed in Git Crab, never repeat them here):
// - stage all  = `git add -A -- <paths>` of NON-conflicted paths only
//   (`git diff --name-only --diff-filter=U` lists the conflicted ones); a
//   conflicted file keeps its unmerged index entries and its markers.
// - unstage all = `git reset -q -- <staged paths>`; never a whole-repo reset,
//   which would drop MERGE_HEAD and silently abort the merge.
// ===========================================================================

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

Wt_Section :: enum u8 { Conflicts, Staged, Unstaged, Untracked }

Wt_Op :: enum u8 {
	Stage,        // args: paths...
	Unstage,      // args: paths...
	Stage_All,
	Unstage_All,
	Discard,      // args: path, section (int)
	Ignore,       // args: path
	Commit,       // args: message
	Amend,        // args: message ("" = keep message)
	Undo_Commit,
	Apply_Hunk,   // args: patch            (stage a hunk of the unstaged diff)
	Unapply_Hunk, // args: patch            (unstage a hunk of the staged diff)
	Hunks,        // args: path, "1" = staged diff     → Git_Custom(Wt_Hunks)
	File_Diff,    // args: path                        → Git_Custom(Wt_File_Diff_Raw)
	Last_Message, //                                   → Command_Output{output = message}
	Merge_Abort,
}

Wt_Hunk :: struct {
	header:  string, // "@@ -a,b +c,d @@ ctx"
	patch:   string, // file header + this hunk: input for `git apply --cached`
	added:   int,
	removed: int,
	preview: string, // first changed line (without +/-), for display
}

Wt_Hunks :: struct {
	path:   string,
	staged: bool,
	hunks:  []Wt_Hunk,
}

// Raw whole-file diff text; all_added = text is the file content itself
// (untracked / no HEAD). Turn into a File_Diff with parse_unified_diff or
// file_diff_all_added (after cloning `text`, it lives in the job arena).
Wt_File_Diff_Raw :: struct {
	text:      string,
	all_added: bool,
}

// ---------------------------------------------------------------------------
// Queue wrapper (UI thread)
// ---------------------------------------------------------------------------

git_request_wt :: proc(q: ^Git_Queue, op: Wt_Op, args: ..string) -> Job_Id {
	all := make([]string, len(args) + 1, context.temp_allocator)
	all[0] = fmt.tprintf("%d", int(op))
	copy(all[1:], args)
	return git_request_custom(q, _wt_work, all)
}

@(private)
_wt_work :: proc(root: string, args: []string, user: rawptr) -> (payload: Git_Payload, err: string) {
	if len(args) == 0 { return nil, "no op" }
	n, nok := strconv.parse_int(args[0])
	if !nok { return nil, "bad op" }
	op := Wt_Op(n)
	a := args[1:]
	arg :: proc(a: []string, i: int) -> string { return a[i] if i < len(a) else "" }

	switch op {
	case .Stage:        err = wt_stage(root, a)
	case .Unstage:      err = wt_unstage(root, a)
	case .Stage_All:    err = wt_stage_all(root)
	case .Unstage_All:  err = wt_unstage_all(root)
	case .Discard:
		sec, _ := strconv.parse_int(arg(a, 1))
		err = wt_discard(root, arg(a, 0), Wt_Section(sec))
	case .Ignore:       err = wt_ignore(root, arg(a, 0))
	case .Commit:       err = wt_commit(root, arg(a, 0), false)
	case .Amend:        err = wt_commit(root, arg(a, 0), true)
	case .Undo_Commit:  err = wt_undo_last_commit(root)
	case .Apply_Hunk:   err = wt_apply_patch(root, arg(a, 0), false)
	case .Unapply_Hunk: err = wt_apply_patch(root, arg(a, 0), true)
	case .Hunks:
		p, c := git_custom_new(Wt_Hunks)
		p^ = wt_hunks(root, arg(a, 0), arg(a, 1) == "1")
		return c, ""
	case .File_Diff:
		p, c := git_custom_new(Wt_File_Diff_Raw)
		p^ = wt_file_diff_raw(root, arg(a, 0))
		return c, ""
	case .Last_Message:
		return Command_Output{output = wt_last_message(root)}, ""
	case .Merge_Abort:
		if _, ok := git_run(root, {"merge", "--abort"}); !ok { err = "git merge --abort failed" }
	}
	if err != "" { return nil, err }
	return Command_Output{}, ""
}

// ---------------------------------------------------------------------------
// Queries
// ---------------------------------------------------------------------------

// Unmerged (conflicted) paths: `git diff --name-only --diff-filter=U`.
wt_conflicted_paths :: proc(root: string) -> []string {
	out, ok := git_run(root, {"diff", "--name-only", "-z", "--diff-filter=U"})
	if !ok { return nil }
	return _wt_split_z(out)
}

// Paths with staged changes (conflicted ones excluded).
wt_staged_paths :: proc(root: string) -> []string {
	out, ok := git_run(root, {"diff", "--cached", "--name-only", "--no-renames", "-z"})
	if !ok { return nil }
	conflicted := wt_conflicted_paths(root)
	res := make([dynamic]string)
	for p in _wt_split_z(out) {
		if !_wt_contains(conflicted, p) { append(&res, p) }
	}
	return res[:]
}

wt_has_head :: proc(root: string) -> bool {
	_, ok := git_run(root, {"rev-parse", "-q", "--verify", "HEAD"})
	return ok
}

// True when the file still holds conflict markers.
wt_has_conflict_markers :: proc(root, path: string) -> bool {
	data, err := os.read_entire_file(strings.concatenate({root, "/", path}, context.temp_allocator), context.temp_allocator)
	if err != nil { return false }
	text := string(data)
	return (strings.has_prefix(text, "<<<<<<< ") || strings.contains(text, "\n<<<<<<< ")) &&
	       (strings.has_prefix(text, ">>>>>>> ") || strings.contains(text, "\n>>>>>>> "))
}

wt_last_message :: proc(root: string) -> string {
	out, ok := git_run(root, {"log", "-1", "--format=%B"})
	if !ok { return "" }
	return strings.trim_space(out)
}

// ---------------------------------------------------------------------------
// Stage / unstage
// ---------------------------------------------------------------------------

// Stages paths. A conflicted path that still holds markers is refused:
// staging it would mark the conflict resolved with the markers inside.
wt_stage :: proc(root: string, paths: []string) -> string {
	conflicted := wt_conflicted_paths(root)
	for p in paths {
		if _wt_contains(conflicted, p) && wt_has_conflict_markers(root, p) {
			return fmt.aprintf("%s still has conflict markers — resolve it first", p)
		}
	}
	return _wt_chunked(root, {"add", "-A", "--"}, paths, "git add failed")
}

wt_unstage :: proc(root: string, paths: []string) -> string {
	if len(paths) == 0 { return "" }
	if !wt_has_head(root) {
		return _wt_chunked(root, {"rm", "-q", "-r", "--cached", "--ignore-unmatch", "--"}, paths, "git rm --cached failed")
	}
	// Path-limited reset: index entries go back to HEAD, MERGE_HEAD stays.
	return _wt_chunked(root, {"reset", "-q", "--"}, paths, "git reset failed", tolerate_exit_1 = true)
}

// Stages every change except conflicted files (they stay unmerged).
wt_stage_all :: proc(root: string) -> string {
	conflicted := wt_conflicted_paths(root)
	out, ok := git_run(root, {"status", "--porcelain=v1", "-z", "--untracked-files=all"})
	if !ok { return "git status failed" }
	paths := make([dynamic]string)
	rest := out
	for len(rest) > 0 {
		nul := strings.index_byte(rest, 0)
		rec := rest if nul < 0 else rest[:nul]
		rest = "" if nul < 0 else rest[nul+1:]
		if len(rec) < 4 { continue }
		x, y, path := rec[0], rec[1], rec[3:]
		if x == 'R' || x == 'C' { // next field is the original path
			if n2 := strings.index_byte(rest, 0); n2 >= 0 { rest = rest[n2+1:] } else { rest = "" }
		}
		if wt_xy_conflicted(x, y) || _wt_contains(conflicted, path) { continue }
		if y == ' ' { continue } // nothing unstaged
		append(&paths, path)
	}
	if len(paths) == 0 { return "" }
	return _wt_chunked(root, {"add", "-A", "--"}, paths[:], "git add failed")
}

// Unstages everything staged — path-limited, so an in-progress merge is kept.
wt_unstage_all :: proc(root: string) -> string {
	return wt_unstage(root, wt_staged_paths(root))
}

// XY of `git status --porcelain` for an unmerged path.
wt_xy_conflicted :: proc(x, y: u8) -> bool {
	return x == 'U' || y == 'U' || (x == 'A' && y == 'A') || (x == 'D' && y == 'D')
}

// ---------------------------------------------------------------------------
// Discard / ignore
// ---------------------------------------------------------------------------

wt_discard :: proc(root, path: string, section: Wt_Section) -> string {
	if path == "" { return "no path" }
	abs := strings.concatenate({root, "/", strings.trim_right(path, "/")}, context.temp_allocator)
	switch section {
	case .Conflicts:
		return "conflicted file: resolve it or abort the merge"
	case .Untracked:
		rerr := os.remove_all(abs) if os.is_dir(abs) else os.remove(abs)
		if rerr != nil { return "could not delete file" }
	case .Unstaged:
		if _, ok := git_run(root, {"checkout", "-q", "--", path}); !ok { return "git checkout failed" }
	case .Staged:
		in_head := false
		if wt_has_head(root) {
			_, in_head = git_run(root, {"cat-file", "-e", fmt.tprintf("HEAD:%s", path)})
		}
		if in_head {
			if _, ok := git_run(root, {"checkout", "-q", "HEAD", "--", path}); !ok { return "git checkout HEAD failed" }
		} else {
			if _, ok := git_run(root, {"rm", "-q", "-f", "--", path}); !ok { return "git rm failed" }
		}
	}
	return ""
}

// Appends `path` to the repo's .gitignore (keeps existing lines intact).
wt_ignore :: proc(root, path: string) -> string {
	if path == "" { return "no path" }
	gi := strings.concatenate({root, "/.gitignore"}, context.temp_allocator)
	existing := ""
	if data, err := os.read_entire_file(gi, context.temp_allocator); err == nil { existing = string(data) }
	for line in strings.split_lines(existing, context.temp_allocator) {
		if strings.trim_space(line) == path { return "" } // already there
	}
	sep := "" if existing == "" || strings.has_suffix(existing, "\n") else "\n"
	content := strings.concatenate({existing, sep, path, "\n"}, context.temp_allocator)
	if os.write_entire_file(gi, transmute([]u8)content) != nil { return "could not write .gitignore" }
	return ""
}

// ---------------------------------------------------------------------------
// Commit / amend / undo
// ---------------------------------------------------------------------------

wt_commit :: proc(root, msg: string, amend: bool) -> string {
	m := strings.trim_space(msg)
	merging := false
	if gd, ok := git_run(root, {"rev-parse", "--absolute-git-dir"}); ok {
		merging = os.exists(strings.concatenate({strings.trim_space(gd), "/MERGE_HEAD"}, context.temp_allocator))
	}
	if amend && merging { return "cannot amend during a merge" }
	if !amend {
		if _, clean := git_run(root, {"diff", "--cached", "--quiet"}); clean && !merging && wt_has_head(root) {
			return "nothing staged to commit"
		}
	}
	args := make([dynamic]string, context.temp_allocator)
	append(&args, "commit", "-q")
	if amend { append(&args, "--amend") }
	if m == "" {
		if !amend && !merging { return "commit message is empty" }
		append(&args, "--no-edit")
	} else {
		append(&args, "-m", m)
	}
	if _, ok := git_run(root, args[:]); !ok {
		return "git commit failed (unresolved conflicts or hook rejected?)"
	}
	return ""
}

// Soft reset to HEAD^: the commit disappears, its changes stay staged.
wt_undo_last_commit :: proc(root: string) -> string {
	if _, ok := git_run(root, {"rev-parse", "-q", "--verify", "HEAD^"}); !ok {
		return "no parent commit — cannot undo the initial commit"
	}
	if _, ok := git_run(root, {"reset", "-q", "--soft", "HEAD^"}); !ok {
		return "git reset --soft failed (merge in progress?)"
	}
	return ""
}

// ---------------------------------------------------------------------------
// Hunks
// ---------------------------------------------------------------------------

// Hunks of the unstaged (index→worktree) or staged (HEAD→index) diff of path.
wt_hunks :: proc(root, path: string, staged: bool) -> Wt_Hunks {
	res := Wt_Hunks{path = strings.clone(path), staged = staged}
	args := []string{"diff", "--no-color", "--no-ext-diff", "-U3", "--", path}
	if staged { args = []string{"diff", "--cached", "--no-color", "--no-ext-diff", "-U3", "--", path} }
	out, ok := git_run(root, args)
	if !ok { return res }
	res.hunks = wt_parse_hunks(out)
	return res
}

// Splits a single-file unified diff into self-contained per-hunk patches.
wt_parse_hunks :: proc(diff: string) -> []Wt_Hunk {
	first := strings.index(diff, "\n@@")
	if strings.has_prefix(diff, "@@") { first = -1 }
	if first < 0 { return nil }
	header := diff[:first+1]
	body := diff[first+1:]
	hunks := make([dynamic]Wt_Hunk)
	for len(body) > 0 {
		next := strings.index(body, "\n@@")
		chunk := body if next < 0 else body[:next+1]
		body = "" if next < 0 else body[next+1:]
		h := Wt_Hunk{patch = strings.concatenate({header, chunk})}
		nl := strings.index_byte(chunk, '\n')
		h.header = strings.trim_right(chunk if nl < 0 else chunk[:nl], "\r")
		rest := "" if nl < 0 else chunk[nl+1:]
		for line in strings.split_lines_iterator(&rest) {
			if len(line) == 0 { continue }
			switch line[0] {
			case '+':
				h.added += 1
				if h.preview == "" { h.preview = strings.trim_space(line[1:]) }
			case '-':
				h.removed += 1
				if h.preview == "" { h.preview = strings.trim_space(line[1:]) }
			}
		}
		append(&hunks, h)
	}
	return hunks[:]
}

// `git apply --cached [--reverse]` of a patch (written to a file in the git dir).
wt_apply_patch :: proc(root, patch: string, reverse: bool) -> string {
	if patch == "" { return "empty patch" }
	gd, ok := git_run(root, {"rev-parse", "--absolute-git-dir"})
	if !ok { return "not a git repository" }
	file := strings.concatenate({strings.trim_space(gd), "/editor-hunk.patch"}, context.temp_allocator)
	if os.write_entire_file(file, transmute([]u8)patch) != nil { return "could not write patch" }
	defer os.remove(file)
	args := make([dynamic]string, context.temp_allocator)
	append(&args, "apply", "--cached", "--whitespace=nowarn")
	if reverse { append(&args, "--reverse") }
	append(&args, file)
	if _, aok := git_run(root, args[:]); !aok { return "git apply failed (hunk no longer matches?)" }
	return ""
}

// ---------------------------------------------------------------------------
// Whole-file diff (vs HEAD) for the Diff view
// ---------------------------------------------------------------------------

wt_file_diff_raw :: proc(root, path: string) -> Wt_File_Diff_Raw {
	if out, ok := git_run(root, {"diff", "--no-color", "--no-ext-diff", "-U2147483647", "HEAD", "--", path}); ok && out != "" {
		return {text = out}
	}
	data, err := os.read_entire_file(strings.concatenate({root, "/", path}, context.temp_allocator), context.allocator)
	if err != nil { return {} }
	return {text = string(data), all_added = true}
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

@(private)
_wt_split_z :: proc(out: string) -> []string {
	res := make([dynamic]string)
	rest := out
	for len(rest) > 0 {
		nul := strings.index_byte(rest, 0)
		f := rest if nul < 0 else rest[:nul]
		rest = "" if nul < 0 else rest[nul+1:]
		f = strings.trim_right(f, "\n")
		if f != "" { append(&res, f) }
	}
	return res[:]
}

@(private)
_wt_contains :: proc(list: []string, s: string) -> bool {
	for x in list { if x == s { return true } }
	return false
}

// Runs `git <prefix> <paths...>` in chunks (keeps command lines short).
@(private)
_wt_chunked :: proc(root: string, prefix: []string, paths: []string, fail: string, tolerate_exit_1 := false) -> string {
	CHUNK :: 100
	for i := 0; i < len(paths); i += CHUNK {
		part := paths[i:min(i + CHUNK, len(paths))]
		args := make([dynamic]string, context.temp_allocator)
		append(&args, ..prefix)
		append(&args, ..part)
		out, code := git_run_raw(root, args[:])
		delete(out)
		if code != 0 && !(tolerate_exit_1 && code == 1) { return fail }
	}
	return ""
}
