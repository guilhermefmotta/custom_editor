package git

// ===========================================================================
// Ref operations for the sidebar (ticket #6): one snapshot job that loads
// everything the sidebar shows, plus branch/tag/stash operations. All of
// them are Git_Work_Procs run through the queue (ADR 0001) — never call the
// `_refs_*` helpers from the UI thread.
//
//   id := git_request_refs_snapshot(&m.queue)        // payload: Git_Custom → ^Refs_Snapshot
//   id := git_request_refs_op(&m.queue, Refs_Op{kind = .Checkout, name = "feat"})
//                                                     // payload: Git_Custom → ^Refs_Op_Result
//
// Outcomes the UI reacts to:
//   .Ok                     done
//   .Blocked_Local_Changes  checkout refused: offer Smart Checkout / Force
//   .Conflicts              merge/rebase/stash pop stopped with conflicts:
//                           open the merge resolver
//   .Not_Merged             `branch -d` refused: offer force delete
//   .Failed                 anything else (message says what)
// ===========================================================================

import "core:fmt"
import "core:strconv"
import "core:strings"

Refs_Snapshot :: struct {
	branches:   []Branch, // local + remote
	remotes:    []Remote,
	tags:       []Tag,
	stashes:    []Stash,
	reflog:     []Reflog_Entry,
	submodules: []Submodule,
	state:      Repo_State,
}

REFS_REFLOG_LIMIT :: 100

Refs_Op_Kind :: enum u8 {
	Checkout,        // name = local branch, or remote branch when flag (creates tracking local)
	Smart_Checkout,  // same operands; stash -u → checkout → stash pop
	Force_Checkout,  // same operands; checkout -f
	Create_Branch,   // name = new branch, target = start point, flag = checkout it
	Rename_Branch,   // name = old, target = new
	Delete_Branch,   // name = local branch, flag = force (-D)
	Delete_Remote_Branch, // name = "origin/feat" (git push origin --delete feat)
	Merge,           // name = branch merged into the current one
	Rebase,          // name = upstream the current branch is rebased onto
	Push,            // name = local branch (git push -u <remote> <branch>)
	Create_Tag,      // name = tag, target = commit-ish ("" = HEAD), message ("" = lightweight)
	Delete_Tag,      // name = tag
	Stash_Apply,     // index
	Stash_Pop,       // index
	Stash_Drop,      // index
	Stash_Push,      // message (optional), includes untracked
}

Refs_Op :: struct {
	kind:    Refs_Op_Kind,
	name:    string,
	target:  string,
	message: string,
	flag:    bool,
	index:   int,
}

Refs_Op_Outcome :: enum u8 {
	Ok,
	Failed,
	Blocked_Local_Changes,
	Conflicts,
	Not_Merged,
}

Refs_Op_Result :: struct {
	outcome:   Refs_Op_Outcome,
	message:   string,   // human readable summary (success or failure)
	branch:    string,   // branch checked out / created, when relevant
	conflicts: []string, // conflicted paths when outcome == .Conflicts
}

// ---------------------------------------------------------------------------
// Requests (main thread)
// ---------------------------------------------------------------------------

git_request_refs_snapshot :: proc(q: ^Git_Queue) -> Job_Id {
	return git_request_custom(q, _refs_snapshot_work)
}

git_request_refs_op :: proc(q: ^Git_Queue, op: Refs_Op) -> Job_Id {
	args := refs_op_to_args(op, context.temp_allocator)
	return git_request_custom(q, _refs_op_work, args)
}

// Pure: (de)serialisation of an op through the job's string args.
refs_op_to_args :: proc(op: Refs_Op, allocator := context.allocator) -> []string {
	out := make([]string, 6, allocator)
	out[0] = fmt.aprintf("%d", int(op.kind), allocator = allocator)
	out[1] = op.name
	out[2] = op.target
	out[3] = op.message
	out[4] = "1" if op.flag else "0"
	out[5] = fmt.aprintf("%d", op.index, allocator = allocator)
	return out
}

refs_op_from_args :: proc(args: []string) -> (op: Refs_Op, ok: bool) {
	if len(args) != 6 { return {}, false }
	k, kok := strconv.parse_int(args[0])
	if !kok || k < 0 || k > int(max(Refs_Op_Kind)) { return {}, false }
	idx, iok := strconv.parse_int(args[5])
	if !iok { return {}, false }
	op = Refs_Op{
		kind = Refs_Op_Kind(k), name = args[1], target = args[2], message = args[3],
		flag = args[4] == "1", index = idx,
	}
	return op, true
}

// Pure: "origin/feature/x" → "feature/x" (strip the remote name).
refs_remote_branch_local_name :: proc(remote_branch: string) -> string {
	if slash := strings.index_byte(remote_branch, '/'); slash >= 0 { return remote_branch[slash+1:] }
	return remote_branch
}

// ---------------------------------------------------------------------------
// Worker side
// ---------------------------------------------------------------------------

@(private = "file")
_refs_snapshot_work :: proc(root: string, args: []string, user: rawptr) -> (Git_Payload, string) {
	snap, payload := git_custom_new(Refs_Snapshot)
	err: string
	if snap.branches, err = git_query_branches(root); err != "" { return nil, err }
	if snap.remotes, err = git_query_remotes(root); err != "" { return nil, err }
	if snap.tags, err = git_query_tags(root); err != "" { return nil, err }
	snap.stashes, _    = git_query_stashes(root) // unborn repo: no stash list
	snap.reflog, _     = git_query_reflog(root, "", 0, REFS_REFLOG_LIMIT)
	snap.submodules, _ = git_query_submodules(root)
	snap.state, _      = git_query_repo_state(root)
	return payload, ""
}

@(private = "file")
_refs_op_work :: proc(root: string, args: []string, user: rawptr) -> (Git_Payload, string) {
	op, ok := refs_op_from_args(args)
	if !ok { return nil, "bad refs op" }
	res, payload := git_custom_new(Refs_Op_Result)
	res^ = _refs_run_op(root, op)
	return payload, ""
}

@(private = "file")
_ok :: proc(msg: string, branch := "") -> Refs_Op_Result {
	return {outcome = .Ok, message = msg, branch = branch}
}

@(private = "file")
_fail :: proc(msg: string) -> Refs_Op_Result {
	return {outcome = .Failed, message = msg}
}

@(private = "file")
_g :: proc(root: string, args: ..string) -> bool {
	_, code := git_run_raw(root, args)
	return code == 0
}

@(private = "file")
_has_local_changes :: proc(root: string) -> bool {
	out, ok := git_run(root, {"status", "--porcelain", "-z"})
	return ok && len(out) > 0
}

@(private = "file")
_conflicts :: proc(root: string) -> []string {
	st, err := git_query_repo_state(root)
	if err != "" { return nil }
	return st.conflicts
}

@(private = "file")
_ref_exists :: proc(root, ref: string) -> bool {
	return _g(root, "show-ref", "--verify", "--quiet", ref)
}

@(private = "file")
_stash_count :: proc(root: string) -> int {
	out, ok := git_run(root, {"rev-list", "--walk-reflogs", "--count", "refs/stash", "--"})
	if !ok { return 0 }
	n, _ := strconv.parse_int(strings.trim_space(out))
	return n
}

// The remote a branch pushes to: its upstream remote, else "origin", else
// the first configured remote.
@(private = "file")
_push_remote :: proc(root, branch: string) -> string {
	if out, ok := git_run(root, {"config", "--get", fmt.tprintf("branch.%s.remote", branch)}); ok {
		r := strings.trim_space(out)
		if r != "" && r != "." { return r }
	}
	out, ok := git_run(root, {"remote"})
	if !ok { return "" }
	first := ""
	rest := out
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if l == "" { continue }
		if l == "origin" { return l }
		if first == "" { first = l }
	}
	return first
}

// Switches to op.name. When op.flag the name is a remote branch: switch to
// (or create) the local branch tracking it.
@(private = "file")
_refs_switch :: proc(root: string, op: Refs_Op, force: bool) -> (ok: bool, branch: string) {
	if !op.flag {
		if force { return _g(root, "checkout", "-f", op.name), op.name }
		return _g(root, "checkout", op.name), op.name
	}
	local := refs_remote_branch_local_name(op.name)
	if _ref_exists(root, fmt.tprintf("refs/heads/%s", local)) {
		ok = _g(root, "checkout", "-f", local) if force else _g(root, "checkout", local)
		if ok {
			// Make sure it tracks the remote branch (Git Crab didn't)
			if !_g(root, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}") {
				_g(root, "branch", fmt.tprintf("--set-upstream-to=%s", op.name), local)
			}
		}
		return ok, local
	}
	if force { return _g(root, "checkout", "-f", "-b", local, "--track", op.name), local }
	return _g(root, "checkout", "-b", local, "--track", op.name), local
}

@(private = "file")
_refs_run_op :: proc(root: string, op: Refs_Op) -> Refs_Op_Result {
	switch op.kind {
	case .Checkout:
		ok, branch := _refs_switch(root, op, false)
		if ok { return _ok(fmt.aprintf("Switched to %s", branch), branch) }
		if _has_local_changes(root) {
			return {outcome = .Blocked_Local_Changes, branch = branch,
			        message = fmt.aprintf("Checkout of %s blocked by local changes", op.name)}
		}
		return _fail(fmt.aprintf("Checkout of %s failed", op.name))

	case .Force_Checkout:
		ok, branch := _refs_switch(root, op, true)
		if ok { return _ok(fmt.aprintf("Switched to %s (local changes discarded)", branch), branch) }
		return _fail(fmt.aprintf("Force checkout of %s failed", op.name))

	case .Smart_Checkout:
		if len(_conflicts(root)) > 0 { return _fail("Resolve existing conflicts before switching branches") }
		before := _stash_count(root)
		if !_g(root, "stash", "push", "-u", "-m", fmt.tprintf("smart-checkout: before %s", op.name)) {
			return _fail("Could not stash local changes")
		}
		stashed := _stash_count(root) > before
		ok, branch := _refs_switch(root, op, false)
		if !ok {
			if stashed { _g(root, "stash", "pop", "--index") }
			return _fail(fmt.aprintf("Checkout of %s failed (local changes restored)", op.name))
		}
		if !stashed { return _ok(fmt.aprintf("Switched to %s", branch), branch) }
		if _g(root, "stash", "pop") {
			return _ok(fmt.aprintf("Switched to %s, local changes restored", branch), branch)
		}
		if c := _conflicts(root); len(c) > 0 {
			return {outcome = .Conflicts, branch = branch, conflicts = c,
			        message = fmt.aprintf("Switched to %s; restoring local changes conflicted (stash kept)", branch)}
		}
		return {outcome = .Failed, branch = branch,
		        message = fmt.aprintf("Switched to %s but could not restore local changes (kept in stash@{{0}})", branch)}

	case .Create_Branch:
		if op.name == "" { return _fail("Branch name is empty") }
		if !_g(root, "check-ref-format", "--branch", op.name) { return _fail(fmt.aprintf("Invalid branch name %q", op.name)) }
		start := op.target if op.target != "" else "HEAD"
		if op.flag {
			if _g(root, "checkout", "-b", op.name, start) { return _ok(fmt.aprintf("Created and switched to %s", op.name), op.name) }
			if _has_local_changes(root) {
				return {outcome = .Blocked_Local_Changes, message = fmt.aprintf("Checkout of new branch %s blocked by local changes", op.name)}
			}
		} else if _g(root, "branch", op.name, start) {
			return _ok(fmt.aprintf("Created branch %s", op.name), op.name)
		}
		return _fail(fmt.aprintf("Could not create branch %s", op.name))

	case .Rename_Branch:
		if op.target == "" { return _fail("Branch name is empty") }
		if !_g(root, "check-ref-format", "--branch", op.target) { return _fail(fmt.aprintf("Invalid branch name %q", op.target)) }
		if _g(root, "branch", "-m", op.name, op.target) { return _ok(fmt.aprintf("Renamed %s to %s", op.name, op.target), op.target) }
		return _fail(fmt.aprintf("Could not rename %s", op.name))

	case .Delete_Branch:
		if _g(root, "branch", "-D" if op.flag else "-d", op.name) { return _ok(fmt.aprintf("Deleted branch %s", op.name)) }
		if !op.flag && _ref_exists(root, fmt.tprintf("refs/heads/%s", op.name)) {
			cur, _ := git_run(root, {"symbolic-ref", "--short", "-q", "HEAD"})
			if strings.trim_space(cur) == op.name { return _fail("Cannot delete the current branch") }
			return {outcome = .Not_Merged, message = fmt.aprintf("Branch %s is not fully merged", op.name)}
		}
		return _fail(fmt.aprintf("Could not delete branch %s", op.name))

	case .Delete_Remote_Branch:
		slash := strings.index_byte(op.name, '/')
		if slash <= 0 { return _fail("Not a remote branch") }
		remote, branch := op.name[:slash], op.name[slash+1:]
		if _g(root, "push", remote, "--delete", branch) { return _ok(fmt.aprintf("Deleted %s", op.name)) }
		return _fail(fmt.aprintf("Could not delete %s on %s", branch, remote))

	case .Merge:
		if _g(root, "merge", "--no-edit", op.name) { return _ok(fmt.aprintf("Merged %s", op.name)) }
		if c := _conflicts(root); len(c) > 0 {
			return {outcome = .Conflicts, conflicts = c, message = fmt.aprintf("Merge of %s has conflicts", op.name)}
		}
		if _has_local_changes(root) { return _fail(fmt.aprintf("Merge of %s failed: commit or stash local changes first", op.name)) }
		return _fail(fmt.aprintf("Merge of %s failed", op.name))

	case .Rebase:
		if _has_local_changes(root) {
			// Untracked files alone don't block a rebase
			out, _ := git_run(root, {"status", "--porcelain", "-z", "--untracked-files=no"})
			if len(out) > 0 { return _fail("Rebase failed: commit or stash local changes first") }
		}
		if _g(root, "rebase", op.name) { return _ok(fmt.aprintf("Rebased onto %s", op.name)) }
		if c := _conflicts(root); len(c) > 0 {
			return {outcome = .Conflicts, conflicts = c, message = fmt.aprintf("Rebase onto %s has conflicts", op.name)}
		}
		return _fail(fmt.aprintf("Rebase onto %s failed", op.name))

	case .Push:
		remote := _push_remote(root, op.name)
		if remote == "" { return _fail("No remote configured") }
		if _g(root, "push", "-u", remote, op.name) { return _ok(fmt.aprintf("Pushed %s to %s", op.name, remote), op.name) }
		return _fail(fmt.aprintf("Push of %s to %s failed (fetch/pull first?)", op.name, remote))

	case .Create_Tag:
		if op.name == "" { return _fail("Tag name is empty") }
		if !_g(root, "check-ref-format", fmt.tprintf("refs/tags/%s", op.name)) { return _fail(fmt.aprintf("Invalid tag name %q", op.name)) }
		target := op.target if op.target != "" else "HEAD"
		ok: bool
		if op.message != "" {
			ok = _g(root, "tag", "-a", op.name, "-m", op.message, target)
		} else {
			ok = _g(root, "tag", op.name, target)
		}
		if ok { return _ok(fmt.aprintf("Created tag %s", op.name)) }
		return _fail(fmt.aprintf("Could not create tag %s (already exists?)", op.name))

	case .Delete_Tag:
		if _g(root, "tag", "-d", op.name) { return _ok(fmt.aprintf("Deleted tag %s", op.name)) }
		return _fail(fmt.aprintf("Could not delete tag %s", op.name))

	case .Stash_Apply, .Stash_Pop:
		ref := fmt.tprintf("stash@{{%d}}", op.index)
		verb := "apply" if op.kind == .Stash_Apply else "pop"
		if _g(root, "stash", verb, ref) { return _ok(fmt.aprintf("Stash %s: %s done", ref, verb)) }
		if c := _conflicts(root); len(c) > 0 {
			return {outcome = .Conflicts, conflicts = c, message = fmt.aprintf("Stash %s has conflicts (stash kept)", verb)}
		}
		return _fail(fmt.aprintf("Stash %s of %s failed (local changes in the way?)", verb, ref))

	case .Stash_Drop:
		ref := fmt.tprintf("stash@{{%d}}", op.index)
		if _g(root, "stash", "drop", ref) { return _ok(fmt.aprintf("Dropped %s", ref)) }
		return _fail(fmt.aprintf("Could not drop %s", ref))

	case .Stash_Push:
		before := _stash_count(root)
		ok: bool
		if op.message != "" { ok = _g(root, "stash", "push", "-u", "-m", op.message) } else { ok = _g(root, "stash", "push", "-u") }
		if !ok { return _fail("Could not stash local changes") }
		if _stash_count(root) == before { return _ok("No local changes to stash") }
		return _ok("Stashed local changes")
	}
	return _fail("unknown operation")
}
