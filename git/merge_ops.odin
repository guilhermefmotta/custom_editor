package git

// ===========================================================================
// Merge resolver operations (ticket #8, panel `merge_resolver`, ADR 0012).
//
// Worker-side, synchronous procs (`merge_*`) plus queue wrappers
// (`git_request_merge_*`). The UI only calls the wrappers; the merge_* procs
// run on the queue worker (and directly in tests). Inside them
// context.allocator is the job arena, so nothing here frees what it allocates.
//
// Rules carried over from Git Crab (bugs that must not come back):
// - The operation in progress is the Repo_Operation ENUM read from the repo
//   right before acting, never a string (a case-mismatched string compare
//   made "Commit merge" never commit there).
// - Resolve refuses content that still has conflict markers at a line start.
// - Abort / complete pick the git command from the live repo state.
// ===========================================================================

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// A conflicted file as the resolver needs it.
Merge_File :: struct {
	path:         string,          // repo-relative
	exists:       bool,            // working-tree file present
	merged:       string,          // working-tree content (with markers)
	binary:       bool,
	ours_label:   string,
	theirs_label: string,
	operation:    Repo_Operation,
}

// Result of resolve / complete / abort: what happened plus the repo state
// right after it (so the UI updates without another round trip).
Merge_Op_Result :: struct {
	ok:      bool,
	message: string,
	state:   Repo_State,
}

// True when some line of `text` starts with "<<<<<<<" or ">>>>>>>".
// ("=======" alone is not checked: it is also a Markdown heading underline.)
merge_text_has_markers :: proc(text: string) -> bool {
	s := text
	for len(s) > 0 {
		if strings.has_prefix(s, "<<<<<<<") || strings.has_prefix(s, ">>>>>>>") { return true }
		nl := strings.index_byte(s, '\n')
		if nl < 0 { break }
		s = s[nl+1:]
	}
	return false
}

// Label of the "complete" action for an operation ("" = nothing to complete).
merge_complete_label :: proc(op: Repo_Operation) -> string {
	#partial switch op {
	case .Merging:        return "Commit merge"
	case .Rebasing:       return "Continue rebase"
	case .Cherry_Picking: return "Continue cherry-pick"
	case .Reverting:      return "Continue revert"
	case .Conflicted:     return "Finish"
	}
	return ""
}

// ---------------------------------------------------------------------------
// Worker-side procs
// ---------------------------------------------------------------------------

merge_load :: proc(root, path: string) -> (f: Merge_File, err: string) {
	f.path = strings.clone(path)
	c, cerr := git_query_conflict(root, path)
	if cerr == "" {
		f.binary       = c.binary
		f.ours_label   = c.ours_label
		f.theirs_label = c.theirs_label
		f.operation    = c.operation
	} else {
		// Already resolved (staged) or not a conflict: still loadable
		if st, serr := git_query_repo_state(root); serr == "" { f.operation = st.operation }
		f.ours_label, f.theirs_label = "ours", "theirs"
	}
	data, rerr := os.read_entire_file(_merge_abs(root, path), context.allocator)
	if rerr == nil {
		f.exists = true
		f.merged = string(data)
		if !f.binary && strings.index_byte(f.merged, 0) >= 0 { f.binary = true }
	}
	return f, ""
}

// Writes `content` to `path` and stages it. Refuses content with markers.
// delete_file = true removes the file instead (resolving a modify/delete
// conflict as "deleted").
merge_resolve :: proc(root, path, content: string, delete_file := false) -> Merge_Op_Result {
	r: Merge_Op_Result
	if delete_file {
		if _, ok := git_run(root, {"rm", "-q", "-f", "--", path}); !ok {
			r.message = fmt.aprintf("git rm %s failed", path)
			r.state, _ = git_query_repo_state(root)
			return r
		}
	} else {
		if merge_text_has_markers(content) {
			r.message = "Unresolved conflict markers remain (<<<<<<< / >>>>>>>)"
			r.state, _ = git_query_repo_state(root)
			return r
		}
		abs := _merge_abs(root, path)
		_ = os.make_directory_all(filepath.dir(abs))
		if werr := os.write_entire_file(abs, transmute([]u8)content); werr != nil {
			r.message = fmt.aprintf("can't write %s", path)
			r.state, _ = git_query_repo_state(root)
			return r
		}
		if _, ok := git_run(root, {"add", "--", path}); !ok {
			r.message = fmt.aprintf("git add %s failed", path)
			r.state, _ = git_query_repo_state(root)
			return r
		}
	}
	r.ok = true
	r.message = fmt.aprintf("Resolved: %s", path)
	r.state, _ = git_query_repo_state(root)
	return r
}

// Commits the merge (`commit --no-edit`) or continues the rebase /
// cherry-pick / revert, according to the live repo state.
merge_complete :: proc(root: string) -> Merge_Op_Result {
	r: Merge_Op_Result
	st, serr := git_query_repo_state(root)
	if serr != "" { r.message = serr; return r }
	if len(st.conflicts) > 0 {
		r.message = fmt.aprintf("%d file(s) still conflicted", len(st.conflicts))
		r.state = st
		return r
	}
	args: []string
	switch st.operation {
	case .Merging:        args = {"commit", "--no-edit"}
	case .Rebasing:       args = {"-c", "core.editor=true", "rebase", "--continue"}
	case .Cherry_Picking: args = {"-c", "core.editor=true", "cherry-pick", "--continue"}
	case .Reverting:      args = {"-c", "core.editor=true", "revert", "--continue"}
	case .Conflicted, .Clean, .Bisecting:
		// stash pop & co.: nothing to commit, the resolution is staged
		r.ok, r.message, r.state = true, "Conflicts resolved", st
		return r
	}
	_, code := git_run_raw(root, args)
	r.state, _ = git_query_repo_state(root)
	switch {
	case code == 0 && r.state.operation == .Clean:
		r.ok = true
		r.message = "Merge committed" if st.operation == .Merging else fmt.aprintf("%s completed", repo_operation_name(st.operation))
	case len(r.state.conflicts) > 0 && r.state.operation == st.operation:
		// rebase/cherry-pick moved on to the next step and stopped again
		r.ok = true
		r.message = fmt.aprintf("Next %s step: %d file(s) in conflict", repo_operation_name(st.operation), len(r.state.conflicts))
	case code == 0:
		r.ok = true
		r.message = fmt.aprintf("%s continued", repo_operation_name(st.operation))
	case:
		r.message = fmt.aprintf("git %s failed", args[len(args) - 2] if len(args) >= 2 else "commit")
	}
	return r
}

// Aborts the operation in progress, restoring the state before it.
merge_abort :: proc(root: string) -> Merge_Op_Result {
	r: Merge_Op_Result
	st, serr := git_query_repo_state(root)
	if serr != "" { r.message = serr; return r }
	args: []string
	switch st.operation {
	case .Merging:        args = {"merge", "--abort"}
	case .Rebasing:       args = {"rebase", "--abort"}
	case .Cherry_Picking: args = {"cherry-pick", "--abort"}
	case .Reverting:      args = {"revert", "--abort"}
	case .Conflicted:     args = {"reset", "--merge"} // stash pop & co.
	case .Clean, .Bisecting:
		r.message = "No merge/rebase in progress"
		r.state = st
		return r
	}
	_, code := git_run_raw(root, args)
	r.state, _ = git_query_repo_state(root)
	r.ok = code == 0
	r.message = fmt.aprintf("%s aborted - files restored", repo_operation_name(st.operation)) if r.ok else fmt.aprintf("git %s failed", strings.join(args, " "))
	return r
}

@(private)
_merge_abs :: proc(root, path: string) -> string {
	return strings.concatenate({root, "/", path})
}

// ---------------------------------------------------------------------------
// Queue wrappers (UI thread)
// ---------------------------------------------------------------------------

// → Git_Custom(Merge_File)
git_request_merge_load :: proc(q: ^Git_Queue, path: string) -> Job_Id {
	return git_request_custom(q, _merge_work, {"load", path})
}

// → Git_Custom(Merge_Op_Result)
git_request_merge_resolve :: proc(q: ^Git_Queue, path, content: string, delete_file := false) -> Job_Id {
	return git_request_custom(q, _merge_work, {"resolve", path, content, "1" if delete_file else "0"})
}

// → Git_Custom(Merge_Op_Result)
git_request_merge_complete :: proc(q: ^Git_Queue) -> Job_Id {
	return git_request_custom(q, _merge_work, {"complete"})
}

// → Git_Custom(Merge_Op_Result)
git_request_merge_abort :: proc(q: ^Git_Queue) -> Job_Id {
	return git_request_custom(q, _merge_work, {"abort"})
}

// Result of a resolve/complete/abort job (nil if `r` isn't one).
merge_op_result :: proc(r: ^Git_Result) -> ^Merge_Op_Result {
	if r == nil || r.status != .Done { return nil }
	c, ok := r.payload.(Git_Custom)
	if !ok { return nil }
	return git_custom_as(c, Merge_Op_Result)
}

merge_file_result :: proc(r: ^Git_Result) -> ^Merge_File {
	if r == nil || r.status != .Done { return nil }
	c, ok := r.payload.(Git_Custom)
	if !ok { return nil }
	return git_custom_as(c, Merge_File)
}

@(private)
_merge_work :: proc(root: string, args: []string, user: rawptr) -> (payload: Git_Payload, err: string) {
	if len(args) == 0 { return nil, "no op" }
	switch args[0] {
	case "load":
		if len(args) < 2 { return nil, "missing path" }
		f, ferr := merge_load(root, args[1])
		if ferr != "" { return nil, ferr }
		p, c := git_custom_new(Merge_File)
		p^ = f
		return c, ""
	case "resolve":
		if len(args) < 4 { return nil, "missing args" }
		p, c := git_custom_new(Merge_Op_Result)
		p^ = merge_resolve(root, args[1], args[2], args[3] == "1")
		return c, ""
	case "complete":
		p, c := git_custom_new(Merge_Op_Result)
		p^ = merge_complete(root)
		return c, ""
	case "abort":
		p, c := git_custom_new(Merge_Op_Result)
		p^ = merge_abort(root)
		return c, ""
	}
	return nil, "unknown merge op"
}
