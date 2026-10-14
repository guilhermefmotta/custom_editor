package git

// ===========================================================================
// Remote operations and stash (ticket #7, ADR 0002).
//
//   id := git_request_remote_op(&queue, .Fetch_All)
//   id := git_request_remote_op(&queue, .Stash_Save, message = "wip")
//   res, st, _ := git_poll_as(&queue, id, Git_Custom) → git_custom_as(res^, Remote_Op_Result)
//   (or git_on_done + remote_op_result(r))
//
// Every job finishes .Done with a Remote_Op_Result; `ok = false` + `kind` +
// `message` describe a failure (the raw git output is kept in `output`).
//
// Network commands run with GIT_TERMINAL_PROMPT=0, GCM_INTERACTIVE=never,
// LC_ALL=C (stable messages to classify) and, unless the user configured an
// ssh command, GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=15":
// a missing credential fails fast with a clear message instead of hanging the
// subprocess on a prompt nobody can answer. stderr is captured (git_run drops
// it), stdin is /dev/null (NUL).
//
// Pull is split in two jobs so the network part never blocks the shared
// queue (ADR 0002): .Fetch_Upstream (network queue), then .Merge_Upstream /
// .Rebase_Upstream (shared queue, serialized with other index writers).
// .Pull_Merge / .Pull_Rebase do both in one job (used by tests/scripts).
// ===========================================================================

import "core:os"
import "core:strings"

Remote_Op :: enum u8 {
	Fetch_All,       // git fetch --all --prune --tags
	Fetch_Upstream,  // fetch only the remote of the current branch's upstream
	Merge_Upstream,  // git merge --no-edit @{u}
	Rebase_Upstream, // git rebase @{u}
	Pull_Merge,      // Fetch_Upstream + Merge_Upstream
	Pull_Rebase,     // Fetch_Upstream + Rebase_Upstream
	Push,            // git push (sets upstream on first push)
	Force_Push,      // git push --force-with-lease
	Stash_Save,      // git stash push --include-untracked [-m msg]
	Stash_Pop,       // git stash pop (latest)
}

Remote_Error_Kind :: enum u8 {
	None,
	Auth,            // authentication / permission denied / host key
	Network,         // DNS, refused, timeout, unreachable
	Remote_Not_Found,// URL is not a repository / repo not found
	No_Remote,       // no remote configured
	No_Upstream,     // current branch has no upstream
	Detached,        // HEAD detached (push/pull need a branch)
	Rejected,        // non-fast-forward push
	Stale_Lease,     // force-with-lease refused: remote moved
	Conflict,        // merge/rebase/pop stopped with conflicts
	Local_Changes,   // local changes would be overwritten / unstaged changes
	Nothing_To_Stash,
	No_Stash,
	Other,
}

Remote_Op_Result :: struct {
	op:       Remote_Op,
	ok:       bool,
	kind:     Remote_Error_Kind,
	message:  string,     // user-facing, one line
	output:   string,     // raw stdout+stderr of the failing (or last) command
	upstream: string,     // "origin/main" when known
	state:    Repo_State, // after the op (merge/rebase/pull/pop only; else zero)
	has_state: bool,
}

remote_op_name :: proc(op: Remote_Op) -> string {
	switch op {
	case .Fetch_All:       return "Fetch"
	case .Fetch_Upstream:  return "Fetch"
	case .Merge_Upstream:  return "Merge"
	case .Rebase_Upstream: return "Rebase"
	case .Pull_Merge:      return "Pull (merge)"
	case .Pull_Rebase:     return "Pull (rebase)"
	case .Push:            return "Push"
	case .Force_Push:      return "Force push"
	case .Stash_Save:      return "Stash"
	case .Stash_Pop:       return "Stash pop"
	}
	return "Git"
}

// Ops that talk to a remote (should run off the shared queue).
remote_op_is_network :: proc(op: Remote_Op) -> bool {
	#partial switch op {
	case .Fetch_All, .Fetch_Upstream, .Pull_Merge, .Pull_Rebase, .Push, .Force_Push: return true
	}
	return false
}

// Enqueue `op`. `message` is the optional stash message.
git_request_remote_op :: proc(q: ^Git_Queue, op: Remote_Op, message := "") -> Job_Id {
	// args[0] = op as text, args[1] = message — the queue clones args.
	op_s := _OP_TAGS[op]
	return git_request_custom(q, _remote_op_work, {op_s, message})
}

// Payload of a finished remote-op job (nil if not one).
remote_op_result :: proc(r: ^Git_Result) -> ^Remote_Op_Result {
	if r == nil { return nil }
	c, ok := r.payload.(Git_Custom)
	if !ok { return nil }
	return git_custom_as(c, Remote_Op_Result)
}

// ---------------------------------------------------------------------------
// Pure helpers (tested)
// ---------------------------------------------------------------------------

// Classifies git's (LC_ALL=C) output of a failed command.
remote_classify_error :: proc(output: string) -> Remote_Error_Kind {
	o := output
	has :: proc(o, s: string) -> bool { return strings.contains(o, s) }
	switch {
	case has(o, "CONFLICT") || has(o, "Merge conflict") || has(o, "could not apply"):
		return .Conflict
	case has(o, "stale info"):
		return .Stale_Lease
	case has(o, "[rejected]") || has(o, "non-fast-forward") || has(o, "fetch first") || has(o, "Updates were rejected"):
		return .Rejected
	case has(o, "Authentication failed") || has(o, "Permission denied") || has(o, "could not read Username") ||
	     has(o, "could not read Password") || has(o, "terminal prompts disabled") ||
	     has(o, "Host key verification failed") || has(o, "The requested URL returned error: 401") ||
	     has(o, "The requested URL returned error: 403") || has(o, "Invalid username or password"):
		return .Auth
	case has(o, "Could not resolve host") || has(o, "Could not resolve hostname") || has(o, "Connection timed out") ||
	     has(o, "Connection refused") || has(o, "Network is unreachable") || has(o, "Operation timed out") ||
	     has(o, "timed out") || has(o, "Failed to connect") || has(o, "Connection reset"):
		return .Network
	case has(o, "does not appear to be a git repository") || has(o, "Repository not found") ||
	     has(o, "not found") && has(o, "repository"):
		return .Remote_Not_Found
	case has(o, "No configured push destination") || has(o, "No remote repository specified"):
		return .No_Remote
	case has(o, "no upstream") || has(o, "has no upstream branch") || has(o, "There is no tracking information"):
		return .No_Upstream
	case has(o, "would be overwritten") || has(o, "Please commit your changes or stash them") ||
	     has(o, "You have unstaged changes") || has(o, "Your index contains uncommitted changes"):
		return .Local_Changes
	case has(o, "No local changes to save"):
		return .Nothing_To_Stash
	case has(o, "No stash entries found") || has(o, "No stash found"):
		return .No_Stash
	}
	return .Other
}

// One-line user message for a failure. `detail` is the raw output: for
// .Other its last meaningful line is used.
remote_error_message :: proc(op: Remote_Op, kind: Remote_Error_Kind, detail: string, allocator := context.allocator) -> string {
	context.allocator = allocator
	name := remote_op_name(op)
	switch kind {
	case .None:             return strings.concatenate({name, " done"})
	case .Auth:             return strings.concatenate({name, " failed: authentication required or denied. Check your SSH agent / credential helper (no interactive prompt is shown)."})
	case .Network:          return strings.concatenate({name, " failed: network error (host unreachable or timed out)."})
	case .Remote_Not_Found: return strings.concatenate({name, " failed: remote repository not found or not a git repository."})
	case .No_Remote:        return strings.concatenate({name, " failed: no remote configured."})
	case .No_Upstream:      return strings.concatenate({name, " failed: current branch has no upstream branch."})
	case .Detached:         return strings.concatenate({name, " failed: HEAD is detached (check out a branch)."})
	case .Rejected:         return strings.concatenate({name, " rejected: the remote has commits you don't have. Pull first (or force push)."})
	case .Stale_Lease:      return strings.concatenate({name, " rejected: the remote changed since your last fetch (lease). Fetch and review before forcing."})
	case .Conflict:         return strings.concatenate({name, " stopped with conflicts. Resolve them to continue."})
	case .Local_Changes:    return strings.concatenate({name, " failed: local changes would be overwritten. Commit or stash them first."})
	case .Nothing_To_Stash: return "Nothing to stash: no local changes."
	case .No_Stash:         return "No stash to pop."
	case .Other:
	}
	line := _last_line(detail)
	if line == "" { return strings.concatenate({name, " failed."}) }
	return strings.concatenate({name, " failed: ", line})
}

// ---------------------------------------------------------------------------
// Worker side
// ---------------------------------------------------------------------------

@(private = "file")
_OP_TAGS := [Remote_Op]string{
	.Fetch_All = "fetch_all", .Fetch_Upstream = "fetch_upstream", .Merge_Upstream = "merge_upstream",
	.Rebase_Upstream = "rebase_upstream", .Pull_Merge = "pull_merge", .Pull_Rebase = "pull_rebase",
	.Push = "push", .Force_Push = "force_push", .Stash_Save = "stash_save", .Stash_Pop = "stash_pop",
}

@(private = "file")
_remote_op_work :: proc(root: string, args: []string, user: rawptr) -> (Git_Payload, string) {
	op := Remote_Op.Fetch_All
	for tag, o in _OP_TAGS { if len(args) > 0 && tag == args[0] { op = o } }
	msg := args[1] if len(args) > 1 else ""

	res, c := git_custom_new(Remote_Op_Result)
	res.op = op
	res.ok = true
	_remote_op_run(root, op, msg, res)
	if res.ok && res.message == "" { res.message = remote_error_message(op, .None, "") }
	return c, ""
}

@(private = "file")
_fail :: proc(res: ^Remote_Op_Result, kind: Remote_Error_Kind, out: string) {
	res.ok      = false
	res.kind    = kind
	res.output  = out
	res.message = remote_error_message(res.op, kind, out)
}

// Runs `git args` with the non-interactive env. ok=false → res failed.
@(private = "file")
_step :: proc(root: string, res: ^Remote_Op_Result, args: ..string) -> (out: string, ok: bool) {
	o, code := remote_exec(root, args)
	res.output = o
	if code != 0 {
		_fail(res, remote_classify_error(o), o)
		return o, false
	}
	return o, true
}

@(private = "file")
_upstream :: proc(root: string, res: ^Remote_Op_Result) -> (remote, branch: string, ok: bool) {
	head, hok := git_run(root, {"symbolic-ref", "-q", "--short", "HEAD"})
	if !hok { _fail(res, .Detached, ""); return }
	head = strings.trim_space(head)
	r, rok := git_run(root, {"config", "--get", strings.concatenate({"branch.", head, ".remote"})})
	u, uok := git_run(root, {"rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"})
	if !rok || !uok {
		_fail(res, .No_Upstream, "")
		return
	}
	res.upstream = strings.trim_space(u)
	return strings.trim_space(r), head, true
}

@(private = "file")
_has_remotes :: proc(root: string) -> bool {
	out, ok := git_run(root, {"remote"})
	return ok && strings.trim_space(out) != ""
}

@(private = "file")
_after_integrate :: proc(root: string, res: ^Remote_Op_Result) {
	s, err := git_query_repo_state(root)
	if err == "" { res.state = s; res.has_state = true }
	if res.has_state && len(s.conflicts) > 0 && (res.ok || res.kind != .Conflict) {
		_fail(res, .Conflict, res.output)
	}
}

@(private = "file")
_remote_op_run :: proc(root: string, op: Remote_Op, msg: string, res: ^Remote_Op_Result) {
	switch op {
	case .Fetch_All:
		if !_has_remotes(root) { _fail(res, .No_Remote, ""); return }
		_step(root, res, "fetch", "--all", "--prune", "--tags")
		if res.ok { res.message = "Fetched all remotes" }

	case .Fetch_Upstream:
		remote, _, ok := _upstream(root, res)
		if !ok { return }
		if remote == "." { return } // local upstream: nothing to fetch
		_step(root, res, "fetch", "--prune", remote)

	case .Merge_Upstream:
		if _, _, ok := _upstream(root, res); !ok { return }
		before := _tgit_head(root)
		_step(root, res, "merge", "--no-edit", "@{u}")
		_after_integrate(root, res)
		if res.ok { res.message = _integrated_msg("Pull (merge)", before, _tgit_head(root), res.upstream) }

	case .Rebase_Upstream:
		if _, _, ok := _upstream(root, res); !ok { return }
		before := _tgit_head(root)
		_step(root, res, "rebase", "@{u}")
		_after_integrate(root, res)
		if res.ok { res.message = _integrated_msg("Pull (rebase)", before, _tgit_head(root), res.upstream) }

	case .Pull_Merge, .Pull_Rebase:
		_remote_op_run(root, .Fetch_Upstream, "", res)
		if !res.ok { return }
		_remote_op_run(root, .Merge_Upstream if op == .Pull_Merge else .Rebase_Upstream, "", res)

	case .Push, .Force_Push:
		head, hok := git_run(root, {"symbolic-ref", "-q", "--short", "HEAD"})
		if !hok { _fail(res, .Detached, ""); return }
		head = strings.trim_space(head)
		force := op == .Force_Push
		u, uok := git_run(root, {"rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"})
		if uok {
			res.upstream = strings.trim_space(u)
			if force { _step(root, res, "push", "--force-with-lease") } else { _step(root, res, "push") }
		} else {
			// First push: set upstream on the branch's remote, else "origin", else the only one.
			remote := _push_remote(root, head)
			if remote == "" { _fail(res, .No_Remote, ""); return }
			res.upstream = strings.concatenate({remote, "/", head})
			if force {
				_step(root, res, "push", "--force-with-lease", "-u", remote, "HEAD")
			} else {
				_step(root, res, "push", "-u", remote, "HEAD")
			}
		}
		if res.ok {
			res.message = strings.concatenate({"Force pushed to " if force else "Pushed to ", res.upstream})
		}

	case .Stash_Save:
		m := strings.trim_space(msg)
		if m != "" {
			_step(root, res, "stash", "push", "--include-untracked", "-m", m)
		} else {
			_step(root, res, "stash", "push", "--include-untracked")
		}
		// git exits 0 with "No local changes to save"
		if res.ok && strings.contains(res.output, "No local changes to save") {
			_fail(res, .Nothing_To_Stash, res.output)
		}
		if res.ok { res.message = "Stashed local changes" if m == "" else strings.concatenate({"Stashed: ", m}) }

	case .Stash_Pop:
		if _, ok := git_run(root, {"rev-parse", "-q", "--verify", "refs/stash"}); !ok {
			_fail(res, .No_Stash, ""); return
		}
		_step(root, res, "stash", "pop")
		_after_integrate(root, res)
		if res.ok { res.message = "Popped latest stash" }
	}
}

@(private = "file")
_push_remote :: proc(root, head: string) -> string {
	if r, ok := git_run(root, {"config", "--get", strings.concatenate({"branch.", head, ".remote"})}); ok {
		if s := strings.trim_space(r); s != "" && s != "." { return s }
	}
	out, ok := git_run(root, {"remote"})
	if !ok { return "" }
	names := strings.fields(out)
	for n in names { if n == "origin" { return n } }
	if len(names) > 0 { return names[0] }
	return ""
}

@(private = "file")
_tgit_head :: proc(root: string) -> string {
	out, ok := git_run(root, {"rev-parse", "HEAD"})
	return strings.trim_space(out) if ok else ""
}

@(private = "file")
_integrated_msg :: proc(name, before, after, upstream: string) -> string {
	if before == after { return strings.concatenate({name, ": already up to date with ", upstream}) }
	return strings.concatenate({name, ": updated from ", upstream})
}

@(private = "file")
_last_line :: proc(s: string) -> string {
	lines := strings.split_lines(strings.trim_space(s), context.temp_allocator)
	#reverse for l in lines {
		t := strings.trim_space(l)
		if t == "" || strings.has_prefix(t, "hint:") { continue }
		t = strings.trim_prefix(t, "fatal: ")
		t = strings.trim_prefix(t, "error: ")
		return t
	}
	return ""
}

// Extra environment for every remote-op command. ssh_cmd is only set when the
// user has no GIT_SSH / GIT_SSH_COMMAND / core.sshCommand of their own.
remote_env :: proc(root: string, allocator := context.temp_allocator) -> [][2]string {
	env := make([dynamic][2]string, allocator)
	append(&env, [2]string{"GIT_TERMINAL_PROMPT", "0"})
	append(&env, [2]string{"GCM_INTERACTIVE", "never"})
	append(&env, [2]string{"LC_ALL", "C"})
	append(&env, [2]string{"LANGUAGE", "C"})
	has_ssh := os.get_env("GIT_SSH_COMMAND", context.temp_allocator) != "" || os.get_env("GIT_SSH", context.temp_allocator) != ""
	if !has_ssh {
		out, ok := git_run(root, {"config", "--get", "core.sshCommand"}, context.temp_allocator)
		has_ssh = ok && strings.trim_space(out) != ""
	}
	if !has_ssh {
		append(&env, [2]string{"GIT_SSH_COMMAND", "ssh -o BatchMode=yes -o ConnectTimeout=15"})
	}
	return env[:]
}

// git -C root <REMOTE_CFG> args, non-interactive, stdout+stderr captured.
// Worker-side only (blocks). Output allocated with `allocator`.
remote_exec :: proc(root: string, args: []string, allocator := context.allocator) -> (output: string, exit_code: int) {
	full := make([dynamic]string, context.temp_allocator)
	// Abort HTTP transfers stuck below 1 KB/s for 30 s.
	append(&full, "-c", "http.lowSpeedLimit=1000", "-c", "http.lowSpeedTime=30")
	append(&full, ..args)
	return _remote_exec(root, full[:], remote_env(root), allocator)
}
