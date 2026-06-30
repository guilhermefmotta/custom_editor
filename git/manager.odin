package git

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

Hunk_Kind :: enum { Added, Modified, Deleted }

Hunk :: struct {
	new_start: int, // 1-based line number in new file
	new_count: int, // lines in new file  (0 = deletion)
	old_count: int, // lines in old file  (0 = insertion)
	kind:      Hunk_Kind,
}

Status_Entry :: struct {
	index:    u8, // XY from `git status --porcelain=v1`
	worktree: u8,
	path:     string, // heap-owned, relative to repo root
	old_path: string, // heap-owned, for renames; "" otherwise
}

Git_State :: struct {
	branch:  string,
	entries: [dynamic]Status_Entry,
	hunks:   map[string][dynamic]Hunk, // abs path → hunks
}

Git_Manager :: struct {
	root: string, // abs path, set once at init — no lock needed for reads

	mu:            sync.Mutex,
	pending:       Git_State,
	pending_ready: bool,
	refreshing:    bool,

	current: Git_State, // main-thread only after git_update swaps
	diff_text: string,  // full diff of selected file (main thread, heap)

	refresh_thread: ^thread.Thread,
	timer:          f32,
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

git_manager_init :: proc(m: ^Git_Manager, root: string) {
	m.root            = strings.clone(root)
	m.current.entries = make([dynamic]Status_Entry)
	m.current.hunks   = make(map[string][dynamic]Hunk)
	m.timer           = 0 // refresh immediately on first update
}

git_manager_destroy :: proc(m: ^Git_Manager) {
	if m.refresh_thread != nil {
		thread.join(m.refresh_thread)
		thread.destroy(m.refresh_thread)
		m.refresh_thread = nil
	}
	delete(m.root)
	_free_state(&m.current)
	_free_state(&m.pending)
	if m.diff_text != "" { delete(m.diff_text); m.diff_text = "" }
}

// git_manager_update: call once per frame from main thread.
// Swaps pending→current when refresh is done, triggers next refresh on timer.
git_manager_update :: proc(m: ^Git_Manager, dt: f32) {
	if m.root == "" { return }

	// Check if background refresh finished
	sync.mutex_lock(&m.mu)
	ready := m.pending_ready
	sync.mutex_unlock(&m.mu)

	if ready {
		if m.refresh_thread != nil {
			thread.join(m.refresh_thread)
			thread.destroy(m.refresh_thread)
			m.refresh_thread = nil
		}
		sync.mutex_lock(&m.mu)
		_free_state(&m.current)
		m.current       = m.pending
		m.pending       = {}
		m.pending_ready = false
		m.refreshing    = false
		sync.mutex_unlock(&m.mu)
	}

	// Timer-based refresh kick
	if m.refresh_thread == nil {
		m.timer -= dt
		if m.timer <= 0 {
			m.timer = 4.0
			_start_refresh(m)
		}
	}
}

// Force an immediate refresh (e.g. after stage/unstage/commit).
git_manager_refresh_now :: proc(m: ^Git_Manager) {
	m.timer = 0
}

// ---------------------------------------------------------------------------
// Git operations (blocking, call from main thread — fast)
// ---------------------------------------------------------------------------

git_stage :: proc(m: ^Git_Manager, rel_path: string) -> bool {
	_, ok := git_run(m.root, {"add", "--", rel_path})
	return ok
}

git_unstage :: proc(m: ^Git_Manager, rel_path: string) -> bool {
	_, ok := git_run(m.root, {"restore", "--staged", "--", rel_path})
	return ok
}

git_checkout :: proc(m: ^Git_Manager, rel_path: string) -> bool {
	_, ok := git_run(m.root, {"checkout", "--", rel_path})
	return ok
}

// git_commit returns "" on success, error message on failure.
git_commit :: proc(m: ^Git_Manager, msg: string) -> string {
	out, ok := git_run(m.root, {"commit", "-m", msg})
	if ok { delete(out); return "" }
	return strings.clone("commit failed")
}

// git_merge runs `git merge <branch>`. Returns conflicts=true when merge
// stopped due to conflicts (files have markers, working tree is dirty).
// Returns err_msg="" on success or conflicts, non-empty on hard failure.
git_merge :: proc(m: ^Git_Manager, branch: string) -> (conflicts: bool, err_msg: string) {
	out, code := git_run_raw(m.root, {"merge", branch})
	if code == 0 { delete(out); return false, "" }
	has_conflict := strings.contains(out, "CONFLICT")
	delete(out)
	if has_conflict { return true, "" }
	return false, strings.clone("merge failed — check branch name or working tree state")
}

// git_merge_in_progress returns true when .git/MERGE_HEAD exists.
git_merge_in_progress :: proc(m: ^Git_Manager) -> bool {
	if m.root == "" { return false }
	path := fmt.tprintf("%s/.git/MERGE_HEAD", m.root)
	f, err := os.open(path)
	if err == nil { os.close(f); return true }
	return false
}

// git_merge_abort runs `git merge --abort`.
git_merge_abort :: proc(m: ^Git_Manager) -> bool {
	_, ok := git_run(m.root, {"merge", "--abort"})
	return ok
}

// git_merge_continue commits the resolved merge using the prepared message.
git_merge_continue :: proc(m: ^Git_Manager) -> (err_msg: string) {
	out, ok := git_run(m.root, {"commit", "--no-edit"})
	if ok { delete(out); return "" }
	delete(out)
	return strings.clone("finalize failed — are all conflicts resolved and staged?")
}

// git_list_branches returns heap-owned slice of local branch names.
// Caller must: for s in branches { delete(s) }; delete(branches)
git_list_branches :: proc(m: ^Git_Manager, allocator := context.allocator) -> [dynamic]string {
	out, ok := git_run(m.root, {"branch", "--format=%(refname:short)"})
	result := make([dynamic]string, allocator)
	if !ok { return result }
	defer delete(out)
	s := strings.trim_space(out)
	for len(s) > 0 {
		nl := strings.index_byte(s, '\n')
		line: string
		if nl < 0 { line = strings.trim_space(s); s = "" } else { line = strings.trim_space(s[:nl]); s = s[nl+1:] }
		if line != "" { append(&result, strings.clone(line, allocator)) }
	}
	return result
}

// git_diff_file returns heap-owned unified diff for rel_path vs HEAD.
git_diff_file :: proc(m: ^Git_Manager, rel_path: string) -> string {
	// Try staged first, then unstaged
	out, ok := git_run(m.root, {"diff", "HEAD", "--", rel_path})
	if ok && out != "" { return out }
	if ok { delete(out) }
	out2, ok2 := git_run(m.root, {"diff", "--cached", "--", rel_path})
	if ok2 { return out2 }
	delete(out2)
	return ""
}

// ---------------------------------------------------------------------------
// Background refresh thread
// ---------------------------------------------------------------------------

_start_refresh :: proc(m: ^Git_Manager) {
	sync.mutex_lock(&m.mu)
	if m.refreshing { sync.mutex_unlock(&m.mu); return }
	m.refreshing = true
	sync.mutex_unlock(&m.mu)

	t := thread.create(_refresh_proc)
	t.data = m
	m.refresh_thread = t
	thread.start(t)
}

_refresh_proc :: proc(t: ^thread.Thread) {
	m := cast(^Git_Manager)t.data
	root := m.root // immutable — safe without lock

	// 1. Branch
	branch_out, branch_ok := git_run(root, {"rev-parse", "--abbrev-ref", "HEAD"})
	branch := ""
	if branch_ok {
		branch = strings.clone(strings.trim_space(branch_out))
		delete(branch_out)
	}

	// 2. Status
	entries := make([dynamic]Status_Entry)
	status_out, status_ok := git_run(root, {"status", "--porcelain=v1", "-z"})
	if status_ok {
		_parse_status(status_out, &entries)
		delete(status_out)
	}

	// 3. Hunks (working tree + staged vs HEAD)
	hunks := make(map[string][dynamic]Hunk)
	diff_out, diff_ok := git_run(root, {"diff", "HEAD", "--unified=0", "--no-color"})
	if diff_ok { _parse_hunks(diff_out, root, &hunks); delete(diff_out) }

	// Store under lock
	sync.mutex_lock(&m.mu)
	_free_state(&m.pending)
	m.pending = Git_State{branch = branch, entries = entries, hunks = hunks}
	m.pending_ready = true
	sync.mutex_unlock(&m.mu)
}

// ---------------------------------------------------------------------------
// Parsers
// ---------------------------------------------------------------------------

_parse_status :: proc(output: string, entries: ^[dynamic]Status_Entry) {
	s := output
	for len(s) >= 3 {
		x := s[0]
		y := s[1]
		if s[2] != ' ' {
			// Skip malformed; find next NUL
			nul := strings.index_byte(s, 0)
			if nul < 0 { break }
			s = s[nul+1:]; continue
		}
		s = s[3:]
		nul := strings.index_byte(s, 0)
		if nul < 0 {
			if len(s) > 0 { append(entries, Status_Entry{index=x, worktree=y, path=strings.clone(s)}) }
			break
		}
		path := strings.clone(s[:nul])
		s = s[nul+1:]
		old_path := ""
		if x == 'R' || y == 'R' || x == 'C' || y == 'C' {
			nul2 := strings.index_byte(s, 0)
			if nul2 >= 0 { old_path = strings.clone(s[:nul2]); s = s[nul2+1:] } else if len(s) > 0 { old_path = strings.clone(s); s = "" }
		}
		append(entries, Status_Entry{index=x, worktree=y, path=path, old_path=old_path})
	}
}

_parse_hunks :: proc(diff_output: string, root: string, hunks: ^map[string][dynamic]Hunk) {
	current_path := "" // temp-allocated string used only as lookup key
	lines := strings.split_lines(diff_output, context.temp_allocator)
	for line in lines {
		if strings.has_prefix(line, "+++ ") {
			rest := line[4:]
			if strings.has_prefix(rest, "b/") {
				rel := rest[2:]
				tmp := strings.concatenate({root, "/", rel}, context.temp_allocator)
				current_path = tmp
				if _, exists := hunks[current_path]; !exists {
					perm := strings.clone(current_path) // permanent key
					hunks[perm] = make([dynamic]Hunk)
				}
			} else {
				current_path = ""
			}
		} else if strings.has_prefix(line, "@@ ") && current_path != "" {
			h, ok := _parse_hunk_line(line)
			if ok { append(&hunks[current_path], h) }
		}
	}
}

_parse_hunk_line :: proc(line: string) -> (h: Hunk, ok: bool) {
	s := line
	if !strings.has_prefix(s, "@@ ") { return }
	s = s[3:]
	if len(s) == 0 || s[0] != '-' { return }
	s = s[1:]

	_, s2, ok1 := _parse_uint(s); if !ok1 { return }
	s = s2
	old_count := 1
	if len(s) > 0 && s[0] == ',' {
		s = s[1:]
		oc, s3, ok2 := _parse_uint(s); if !ok2 { return }
		old_count = oc; s = s3
	}

	for len(s) > 0 && s[0] == ' ' { s = s[1:] }
	if len(s) == 0 || s[0] != '+' { return }
	s = s[1:]

	new_start, s4, ok3 := _parse_uint(s); if !ok3 { return }
	s = s4
	new_count := 1
	if len(s) > 0 && s[0] == ',' {
		s = s[1:]
		nc, _, ok4 := _parse_uint(s); if !ok4 { return }
		new_count = nc
	}

	h.new_start = new_start
	h.new_count = new_count
	h.old_count = old_count
	if old_count == 0 { h.kind = .Added } else if new_count == 0 { h.kind = .Deleted } else { h.kind = .Modified }
	ok = true
	return
}

_parse_uint :: proc(s: string) -> (n: int, rest: string, ok: bool) {
	i := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' { i += 1 }
	if i == 0 { return 0, s, false }
	v := 0
	for c in s[:i] { v = v*10 + int(c - '0') }
	return v, s[i:], true
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

_free_state :: proc(st: ^Git_State) {
	if st.branch != "" { delete(st.branch); st.branch = "" }
	for &e in st.entries { delete(e.path); if e.old_path != "" { delete(e.old_path) } }
	delete(st.entries)
	for k, &v in st.hunks { delete(k); delete(v) }
	delete(st.hunks)
	st^ = {}
}
