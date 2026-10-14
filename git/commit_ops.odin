package git

// ===========================================================================
// Commit operations (ticket #9, ADR 0013): cherry-pick, revert, reset
// soft/mixed/hard and interactive rebase. All of them are Git_Work_Procs run
// through the queue (ADR 0001) — never call the `_co_*` helpers from the UI
// thread.
//
//   id := git_request_commit_op(&m.queue, Commit_Op{kind = .Cherry_Pick, hash = h})
//                                       // payload: Git_Custom → ^Commit_Op_Result
//   id := git_request_rebase_commits(&m.queue, base)
//                                       // payload: Git_Custom → ^Rebase_Plan
//   id := git_request_rebase_interactive(&m.queue, base, steps)
//                                       // payload: Git_Custom → ^Commit_Op_Result
//
// Outcomes the UI reacts to:
//   .Ok         done
//   .Conflicts  stopped with unmerged paths (operation = Cherry_Picking /
//               Reverting / Rebasing): open the merge resolver
//   .Stopped    an operation is in progress without conflicts (e.g. an
//               interactive rebase stopped on an exec): open the resolver,
//               it owns continue/abort
//   .Failed     nothing changed (message says why)
//
// Every git command here runs with GIT_EDITOR=":" (no editor ever opens) and
// stdin closed; the interactive rebase writes its own todo and feeds it with
// GIT_SEQUENCE_EDITOR (see ADR 0013).
// ===========================================================================

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

Commit_Op_Kind :: enum u8 {
	Cherry_Pick,
	Revert,
	Reset_Soft,
	Reset_Mixed,
	Reset_Hard,
}

Commit_Op :: struct {
	kind:  Commit_Op_Kind,
	hash:  string,
	merge: bool, // the commit is a merge: cherry-pick/revert against its first parent (-m 1)
}

Commit_Op_Outcome :: enum u8 {
	Ok,
	Failed,
	Conflicts,
	Stopped,
}

Commit_Op_Result :: struct {
	outcome:   Commit_Op_Outcome,
	message:   string,
	operation: Repo_Operation, // state of the repo after the operation
	conflicts: []string,
}

Rebase_Action :: enum u8 { Pick, Reword, Squash, Fixup, Drop }

Rebase_Step :: struct {
	action:     Rebase_Action,
	hash:       string,
	short_hash: string,
	subject:    string,
	message:    string, // full message; for .Reword the new message
}

// Commits an interactive rebase onto `base` would replay (oldest first).
Rebase_Plan :: struct {
	base:   string,
	steps:  []Rebase_Step,
	merges: int, // merge commits in base..HEAD (rebase -i drops them)
}

// ---------------------------------------------------------------------------
// Requests (main thread)
// ---------------------------------------------------------------------------

git_request_commit_op :: proc(q: ^Git_Queue, op: Commit_Op) -> Job_Id {
	args := []string{fmt.tprintf("%d", int(op.kind)), op.hash, "1" if op.merge else "0"}
	return git_request_custom(q, _co_op_work, args)
}

git_request_rebase_commits :: proc(q: ^Git_Queue, base: string) -> Job_Id {
	return git_request_custom(q, _co_plan_work, []string{base})
}

git_request_rebase_interactive :: proc(q: ^Git_Queue, base: string, steps: []Rebase_Step) -> Job_Id {
	return git_request_custom(q, _co_rebase_work, rebase_to_args(base, steps, context.temp_allocator))
}

// ---------------------------------------------------------------------------
// Pure helpers (tested in commit_ops_test.odin)
// ---------------------------------------------------------------------------

rebase_action_word :: proc(a: Rebase_Action) -> string {
	switch a {
	case .Pick:   return "pick"
	case .Reword: return "reword"
	case .Squash: return "squash"
	case .Fixup:  return "fixup"
	case .Drop:   return "drop"
	}
	return "pick"
}

// Steps through the job's string args: [base, (action, hash, subject, message)*].
rebase_to_args :: proc(base: string, steps: []Rebase_Step, allocator := context.allocator) -> []string {
	out := make([]string, 1 + 4 * len(steps), allocator)
	out[0] = base
	for s, i in steps {
		out[1 + 4*i]     = fmt.aprintf("%d", int(s.action), allocator = allocator)
		out[1 + 4*i + 1] = s.hash
		out[1 + 4*i + 2] = s.subject
		out[1 + 4*i + 3] = s.message
	}
	return out
}

rebase_from_args :: proc(args: []string, allocator := context.allocator) -> (base: string, steps: []Rebase_Step, ok: bool) {
	if len(args) < 1 || (len(args) - 1) % 4 != 0 { return "", nil, false }
	n := (len(args) - 1) / 4
	steps = make([]Rebase_Step, n, allocator)
	for i in 0 ..< n {
		a, aok := strconv.parse_int(args[1 + 4*i])
		if !aok || a < 0 || a > int(max(Rebase_Action)) { delete(steps, allocator); return "", nil, false }
		steps[i] = Rebase_Step{
			action  = Rebase_Action(a),
			hash    = args[1 + 4*i + 1],
			subject = args[1 + 4*i + 2],
			message = args[1 + 4*i + 3],
		}
	}
	return args[0], steps, true
}

// "" when the plan can run, else why not.
rebase_steps_validate :: proc(steps: []Rebase_Step) -> string {
	if len(steps) == 0 { return "No commits to rebase" }
	for s in steps {
		if s.action == .Drop { continue }
		if s.action == .Squash || s.action == .Fixup {
			return "The first kept commit can't be squash/fixup (nothing to meld into)"
		}
		break
	}
	for s in steps {
		if s.action == .Reword && strings.trim_space(s.message) == "" {
			return fmt.tprintf("Reword of %s has an empty message", s.short_hash if s.short_hash != "" else s.hash)
		}
	}
	return ""
}

// Moves steps[i] by delta (-1 up / +1 down); returns the new index.
rebase_step_move :: proc(steps: []Rebase_Step, i, delta: int) -> int {
	if i < 0 || i >= len(steps) { return i }
	j := clamp(i + delta, 0, len(steps) - 1)
	if j == i { return i }
	moved := steps[i]
	if j > i { copy(steps[i:j], steps[i+1:j+1]) } else { copy(steps[j+1:i+1], steps[j:i]) }
	steps[j] = moved
	return j
}

// POSIX shell single-quoting (git runs editors/exec lines through sh, also
// on Windows — Git for Windows ships one).
co_sh_quote :: proc(s: string, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_byte(&sb, '\'')
	for i in 0 ..< len(s) {
		if s[i] == '\'' { strings.write_string(&sb, "'\\''") } else { strings.write_byte(&sb, s[i]) }
	}
	strings.write_byte(&sb, '\'')
	return strings.to_string(sb)
}

// The git-rebase-todo for `steps`. A reword is written as `pick` followed by
// `exec git commit --amend -F <msg_files[i]>` so no editor is needed; squash
// keeps git's combined message (GIT_EDITOR=":"), fixup the first one.
rebase_todo_build :: proc(steps: []Rebase_Step, msg_files: []string, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	for s, i in steps {
		action := s.action
		if action == .Reword { action = .Pick }
		subj, _ := strings.replace_all(s.subject, "\n", " ", context.temp_allocator)
		fmt.sbprintf(&sb, "%s %s %s\n", rebase_action_word(action), s.hash, subj)
		if s.action == .Reword && i < len(msg_files) && msg_files[i] != "" {
			fmt.sbprintf(&sb, "exec git commit --amend --allow-empty --no-verify --cleanup=strip -F %s\n",
				co_sh_quote(msg_files[i], context.temp_allocator))
		}
	}
	return strings.to_string(sb)
}

// Last meaningful line of git's stderr (no hints, no "error:" prefix).
co_error_line :: proc(s: string) -> string {
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

// ---------------------------------------------------------------------------
// Worker side
// ---------------------------------------------------------------------------

@(private = "file")
_co_env :: proc(seq_editor := "") -> [][2]string {
	env := make([dynamic][2]string, context.temp_allocator)
	append(&env, [2]string{"GIT_EDITOR", ":"})
	append(&env, [2]string{"GIT_MERGE_AUTOEDIT", "no"})
	append(&env, [2]string{"GIT_TERMINAL_PROMPT", "0"})
	append(&env, [2]string{"LC_ALL", "C"})
	append(&env, [2]string{"LANGUAGE", "C"})
	if seq_editor != "" { append(&env, [2]string{"GIT_SEQUENCE_EDITOR", seq_editor}) }
	return env[:]
}

// Runs git non-interactively; output = stdout+stderr.
@(private = "file")
_co_git :: proc(root: string, args: []string, seq_editor := "") -> (out: string, ok: bool) {
	o, code := _remote_exec(root, args, _co_env(seq_editor))
	return o, code == 0
}

@(private = "file")
_co_short :: proc(h: string) -> string { return h[:min(len(h), 7)] }

@(private = "file")
_co_tracked_changes :: proc(root: string) -> bool {
	out, ok := git_run(root, {"status", "--porcelain", "-z", "--untracked-files=no"})
	return ok && len(out) > 0
}

// After a failed cherry-pick/revert/rebase: what state are we in?
@(private = "file")
_co_after_failure :: proc(root, what, out: string) -> Commit_Op_Result {
	st, err := git_query_repo_state(root)
	msg := co_error_line(out)
	if err != "" { return {outcome = .Failed, message = fmt.aprintf("%s failed: %s", what, msg)} }
	if len(st.conflicts) > 0 {
		return {outcome = .Conflicts, operation = st.operation, conflicts = st.conflicts,
		        message = fmt.aprintf("%s stopped with %d conflicted file(s)", what, len(st.conflicts))}
	}
	if st.operation != .Clean {
		return {outcome = .Stopped, operation = st.operation,
		        message = fmt.aprintf("%s stopped: %s", what, msg if msg != "" else "operation in progress")}
	}
	if msg == "" { msg = "unknown error" }
	return {outcome = .Failed, message = fmt.aprintf("%s failed: %s", what, msg)}
}

@(private = "file")
_co_op_work :: proc(root: string, args: []string, user: rawptr) -> (Git_Payload, string) {
	if len(args) != 3 { return nil, "bad commit op" }
	k, kok := strconv.parse_int(args[0])
	if !kok || k < 0 || k > int(max(Commit_Op_Kind)) { return nil, "bad commit op" }
	op := Commit_Op{kind = Commit_Op_Kind(k), hash = args[1], merge = args[2] == "1"}
	res, payload := git_custom_new(Commit_Op_Result)
	res^ = _co_run_op(root, op)
	if res.outcome == .Ok || res.outcome == .Failed {
		st, _ := git_query_repo_state(root)
		res.operation = st.operation
	}
	return payload, ""
}

@(private = "file")
_co_run_op :: proc(root: string, op: Commit_Op) -> Commit_Op_Result {
	if op.hash == "" { return {outcome = .Failed, message = "No commit selected"} }
	short := _co_short(op.hash)
	switch op.kind {
	case .Cherry_Pick, .Revert:
		pick := op.kind == .Cherry_Pick
		what := fmt.tprintf("%s of %s", "Cherry-pick" if pick else "Revert", short)
		if st, err := git_query_repo_state(root); err == "" && st.operation != .Clean {
			return {outcome = .Failed, message = fmt.aprintf("%s: finish the %s in progress first", what, repo_operation_name(st.operation))}
		}
		cmd := make([dynamic]string, context.temp_allocator)
		append(&cmd, "cherry-pick" if pick else "revert")
		if !pick { append(&cmd, "--no-edit") }
		if op.merge { append(&cmd, "-m", "1") }
		append(&cmd, op.hash)
		out, ok := _co_git(root, cmd[:])
		if ok { return {outcome = .Ok, message = fmt.aprintf("%s done", what)} }
		res := _co_after_failure(root, what, out)
		// Nothing left to apply (already in HEAD): undo the half-started op
		if res.outcome == .Stopped && (res.operation == .Cherry_Picking || res.operation == .Reverting) {
			_co_git(root, {"cherry-pick" if pick else "revert", "--abort"})
			return {outcome = .Failed, message = fmt.aprintf("%s: nothing to apply, the changes are already in HEAD", what)}
		}
		return res

	case .Reset_Soft, .Reset_Mixed, .Reset_Hard:
		mode := "--soft"
		if op.kind == .Reset_Mixed { mode = "--mixed" }
		if op.kind == .Reset_Hard { mode = "--hard" }
		out, ok := _co_git(root, {"reset", mode, op.hash})
		if ok { return {outcome = .Ok, message = fmt.aprintf("Reset (%s) to %s", mode[2:], short)} }
		return {outcome = .Failed, message = fmt.aprintf("Reset to %s failed: %s", short, co_error_line(out))}
	}
	return {outcome = .Failed, message = "unknown operation"}
}

@(private = "file")
_co_plan_work :: proc(root: string, args: []string, user: rawptr) -> (Git_Payload, string) {
	if len(args) != 1 || args[0] == "" { return nil, "no base commit" }
	base := args[0]
	if _, ok := git_run(root, {"merge-base", "--is-ancestor", base, "HEAD"}); !ok {
		return nil, "the selected commit is not an ancestor of HEAD"
	}
	plan, payload := git_custom_new(Rebase_Plan)
	plan.base = base
	rng := fmt.tprintf("%s..HEAD", base)
	out, ok := git_run(root, {"log", "--reverse", "--topo-order", "--no-merges",
		"--format=%H%x1f%h%x1f%s%x1f%B%x1e", rng})
	if !ok { return nil, "git log failed" }
	steps := make([dynamic]Rebase_Step)
	rest := out
	for rec in strings.split_iterator(&rest, "\x1e") {
		r := strings.trim_left(rec, "\n")
		if r == "" { continue }
		f := strings.split_n(r, "\x1f", 4, context.temp_allocator)
		if len(f) < 4 { continue }
		append(&steps, Rebase_Step{action = .Pick, hash = f[0], short_hash = f[1], subject = f[2],
		                           message = strings.trim_right_space(f[3])})
	}
	plan.steps = steps[:]
	if c, cok := git_run(root, {"rev-list", "--count", "--merges", rng}); cok {
		plan.merges, _ = strconv.parse_int(strings.trim_space(c))
	}
	return payload, ""
}

@(private = "file")
_co_rebase_work :: proc(root: string, args: []string, user: rawptr) -> (Git_Payload, string) {
	base, steps, ok := rebase_from_args(args)
	if !ok { return nil, "bad rebase plan" }
	res, payload := git_custom_new(Commit_Op_Result)
	res^ = _co_rebase(root, base, steps)
	return payload, ""
}

@(private = "file")
_co_rebase :: proc(root, base: string, steps: []Rebase_Step) -> Commit_Op_Result {
	if msg := rebase_steps_validate(steps); msg != "" { return {outcome = .Failed, message = strings.clone(msg)} }
	st, err := git_query_repo_state(root)
	if err != "" { return {outcome = .Failed, message = "not a git repository"} }
	if st.operation != .Clean {
		return {outcome = .Failed, operation = st.operation,
		        message = fmt.aprintf("Finish the %s in progress first", repo_operation_name(st.operation))}
	}
	if _co_tracked_changes(root) {
		return {outcome = .Failed, message = "Interactive rebase: commit or stash local changes first"}
	}

	// Todo + reword messages live in <git-dir>/custom-editor-rebase/. Kept
	// after a stop (the exec lines still need the messages); wiped on the next
	// rebase.
	dir := fmt.tprintf("%s/custom-editor-rebase", st.git_dir)
	_ = os.remove_all(dir)
	if os.make_directory(dir) != nil { return {outcome = .Failed, message = "Could not write the rebase todo"} }
	msg_files := make([]string, len(steps))
	for s, i in steps {
		if s.action != .Reword { continue }
		msg_files[i] = fmt.aprintf("%s/msg-%d.txt", dir, i)
		text := strings.concatenate({strings.trim_space(s.message), "\n"})
		if os.write_entire_file(msg_files[i], transmute([]u8)text) != nil {
			return {outcome = .Failed, message = "Could not write the reword message"}
		}
	}
	todo := fmt.aprintf("%s/todo", dir)
	if os.write_entire_file(todo, transmute([]u8)rebase_todo_build(steps, msg_files)) != nil {
		return {outcome = .Failed, message = "Could not write the rebase todo"}
	}

	seq := fmt.tprintf("cp %s", co_sh_quote(todo, context.temp_allocator))
	out, ok := _co_git(root, {"rebase", "-i", base}, seq_editor = seq)
	if ok {
		after, _ := git_query_repo_state(root)
		if after.operation == .Clean {
			_ = os.remove_all(dir)
			return {outcome = .Ok, message = fmt.aprintf("Rebased %d commit(s) onto %s", len(steps), _co_short(base))}
		}
	}
	return _co_after_failure(root, "Interactive rebase", out)
}
