package git

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "../wake"

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

// Blame_Line describes the last commit that touched one line of a file, as
// reported by `git blame --porcelain`. hash == "0000000000000000000000000000000000000000"
// means the line is uncommitted (working-tree change).
Blame_Line :: struct {
	hash:   string, // heap, 40 hex chars
	author: string, // heap
	date:   string, // heap, "DD/MM/YYYY"
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

	refresh_thread: ^thread.Thread,
	timer:          f32,
	status_gen:     int, // bumps every time `current` is swapped (main thread)

	// Large repositories (ADR 0017). The refresh measures itself and the next
	// one waits at least REFRESH_SLOW_FACTOR times as long; hunks (gutter
	// marks) are only diffed for the files open in the editor; a slow status
	// reports once whether core.fsmonitor could help.
	last_refresh_ms: f64,      // guarded by mu
	diff_paths:      [dynamic]string, // guarded by mu (heap, absolute)
	slow_hint:       string,   // guarded by mu; heap, taken by git_manager_take_hint
	hint_checked:    bool,     // refresh thread only

	// Blame runs on its own thread; finished results wait here (guarded by mu).
	blame_pending: map[string]bool,  // main thread; keys heap
	blame_done:    [dynamic]Blame_Result,
	blame_running: int, // atomic: blame threads still running

	blame_cache: map[string][dynamic]Blame_Line, // abs path → per-line blame (main thread, lazy)

	// Async request queue for every new git query/operation (ADR 0001, see
	// queue.odin). Worker thread starts on the first request.
	queue: Git_Queue,
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

REFRESH_SLOW_FACTOR :: 5
REFRESH_MAX_INTERVAL :: f32(60)
SLOW_STATUS_MS      :: 1500

Blame_Result :: struct {
	path:  string, // heap
	lines: [dynamic]Blame_Line,
}

git_manager_init :: proc(m: ^Git_Manager, root: string) {
	m.root            = strings.clone(root)
	m.current.entries = make([dynamic]Status_Entry)
	m.current.hunks   = make(map[string][dynamic]Hunk)
	m.blame_cache     = make(map[string][dynamic]Blame_Line)
	m.timer           = 0 // refresh immediately on first update
	git_queue_init(&m.queue, root)
}

git_manager_destroy :: proc(m: ^Git_Manager) {
	if m.refresh_thread != nil {
		thread.join(m.refresh_thread)
		thread.destroy(m.refresh_thread)
		m.refresh_thread = nil
	}
	git_queue_destroy(&m.queue)
	for sync.atomic_load(&m.blame_running) > 0 { time.sleep(time.Millisecond) }
	delete(m.root)
	_free_state(&m.current)
	_free_state(&m.pending)
	for k, &v in m.blame_cache { delete(k); _free_blame_lines(&v) }
	delete(m.blame_cache)
	sync.mutex_lock(&m.mu) // blame threads may still deliver (they are detached)
	for &r in m.blame_done { delete(r.path); _free_blame_lines(&r.lines); delete(r.lines) }
	delete(m.blame_done)
	for p in m.diff_paths { delete(p) }
	delete(m.diff_paths)
	delete(m.slow_hint)
	sync.mutex_unlock(&m.mu)
	for k in m.blame_pending { delete(k) }
	delete(m.blame_pending)
}

// git_manager_update: call once per frame from main thread.
// Swaps pending→current when refresh is done, triggers next refresh on timer.
git_manager_update :: proc(m: ^Git_Manager, dt: f32) {
	if m.root == "" { return }

	git_queue_update(&m.queue) // run callbacks of finished async jobs
	git_manager_update_status(m, dt)
}

// Status half of git_manager_update (swap finished refresh, kick the next one
// on the timer) WITHOUT pumping the queue callbacks. Used for repositories
// open in the background (ADR 0014): their status stays fresh for the repo
// tabs, while queue callbacks only ever run for the active repository.
// `interval` is the delay before the next refresh.
git_manager_update_status :: proc(m: ^Git_Manager, dt: f32, interval: f32 = 4.0) {
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
		last := m.last_refresh_ms
		sync.mutex_unlock(&m.mu)
		m.status_gen += 1
		// A slow repository is not refreshed again right away
		if m.timer > 0 { m.timer = max(m.timer, min(REFRESH_MAX_INTERVAL, f32(last / 1000) * REFRESH_SLOW_FACTOR)) }
	}
	_blame_collect(m)

	// Timer-based refresh kick
	if m.refresh_thread == nil {
		m.timer -= dt
		if m.timer <= 0 {
			sync.mutex_lock(&m.mu)
			last := m.last_refresh_ms
			sync.mutex_unlock(&m.mu)
			m.timer = max(interval, min(REFRESH_MAX_INTERVAL, f32(last / 1000) * REFRESH_SLOW_FACTOR))
			_start_refresh(m)
		}
	}
}

// Force an immediate refresh (e.g. after stage/unstage/commit).
git_manager_refresh_now :: proc(m: ^Git_Manager) {
	if m == nil { return }
	m.timer = 0
}

// Files whose hunks (gutter marks) the refresh diffs — the ones open in the
// editor. Absolute paths. A changed set triggers a refresh. Main thread.
git_manager_set_diff_paths :: proc(m: ^Git_Manager, paths: []string) {
	if m.root == "" { return }
	sync.mutex_lock(&m.mu)
	same := len(paths) == len(m.diff_paths)
	if same { for p, i in paths { if p != m.diff_paths[i] { same = false; break } } }
	if !same {
		for p in m.diff_paths { delete(p) }
		clear(&m.diff_paths)
		for p in paths { append(&m.diff_paths, strings.clone(p)) }
	}
	sync.mutex_unlock(&m.mu)
	if !same { m.timer = 0 }
}

// One-time advice when `git status` is slow (heap string, "" if none). Main thread.
git_manager_take_hint :: proc(m: ^Git_Manager) -> string {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	h := m.slow_hint
	m.slow_hint = ""
	return h
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

// git_blame_get returns per-line blame for abs_path, computing and caching it
// on first request. Cache is invalidated by git_blame_invalidate (call after
// save).
//
// Never blocks: a missing entry starts `git blame` on its own thread and
// returns nothing until the result is collected by git_manager_update.
git_blame_get :: proc(m: ^Git_Manager, abs_path: string) -> [dynamic]Blame_Line {
	if cached, ok := m.blame_cache[abs_path]; ok { return cached }
	if m.root == "" || abs_path in m.blame_pending { return nil }
	m.blame_pending[strings.clone(abs_path)] = true
	Job :: struct { m: ^Git_Manager, path: string }
	job := new(Job)
	job^ = {m, strings.clone(abs_path)}
	sync.atomic_add(&m.blame_running, 1)
	t := thread.create_and_start_with_poly_data(job, proc(job: ^Job) {
		lines := git_blame_compute(job.m.root, job.path)
		sync.mutex_lock(&job.m.mu)
		append(&job.m.blame_done, Blame_Result{path = job.path, lines = lines})
		sync.mutex_unlock(&job.m.mu)
		sync.atomic_sub(&job.m.blame_running, 1)
		free(job)
		wake.request()
	}, context, self_cleanup = true)
	_ = t
	return nil
}

// Moves finished blames into the cache. Main thread.
@(private="file")
_blame_collect :: proc(m: ^Git_Manager) {
	sync.mutex_lock(&m.mu)
	done := m.blame_done[:]
	defer { clear(&m.blame_done); sync.mutex_unlock(&m.mu) }
	for r in done {
		if r.path in m.blame_pending { k, _ := delete_key(&m.blame_pending, r.path); delete(k) }
		if old, has := m.blame_cache[r.path]; has {
			o := old
			_free_blame_lines(&o)
			delete(o)
			m.blame_cache[r.path] = r.lines
			delete(r.path)
		} else {
			m.blame_cache[r.path] = r.lines
		}
	}
}

// `git blame` of one file (any thread).
git_blame_compute :: proc(root, abs_path: string) -> [dynamic]Blame_Line {
	rel := abs_path
	if strings.has_prefix(abs_path, root) {
		rel = strings.trim_prefix(abs_path[len(root):], "/")
	}
	lines := make([dynamic]Blame_Line)
	if out, ok := git_run(root, {"blame", "--porcelain", "--", rel}); ok {
		_parse_blame(out, &lines)
		delete(out)
	}
	return lines
}


git_blame_invalidate :: proc(m: ^Git_Manager, abs_path: string) {
	if m == nil { return }
	found_key := ""
	for k, v in m.blame_cache {
		if k == abs_path {
			vv := v
			_free_blame_lines(&vv)
			delete(vv)
			found_key = k
			break
		}
	}
	if found_key != "" {
		delete_key(&m.blame_cache, found_key)
		delete(found_key)
	}
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
	t0 := time.tick_now()

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

	// 3. Hunks (working tree + staged vs HEAD) — only for the open files:
	// diffing a whole monorepo every refresh was the expensive part
	hunks := make(map[string][dynamic]Hunk)
	diff_args := make([dynamic]string, context.temp_allocator)
	append(&diff_args, "diff", "HEAD", "--unified=0", "--no-color", "--")
	sync.mutex_lock(&m.mu)
	for p in m.diff_paths {
		if strings.has_prefix(p, root) { append(&diff_args, strings.clone(p, context.temp_allocator)) }
	}
	sync.mutex_unlock(&m.mu)
	if len(diff_args) > 5 {
		diff_out, diff_ok := git_run(root, diff_args[:])
		if diff_ok { _parse_hunks(diff_out, root, &hunks); delete(diff_out) }
	}

	took := time.duration_milliseconds(time.tick_since(t0))
	hint := ""
	if took > SLOW_STATUS_MS && !m.hint_checked {
		m.hint_checked = true
		if out, ok := git_run(root, {"config", "--get", "core.fsmonitor"}); !ok || strings.trim_space(out) != "true" {
			hint = fmt.aprintf("git status took %.1fs here. For big repositories run: git config core.fsmonitor true && git config core.untrackedCache true", took / 1000)
			if ok { delete(out) }
		} else {
			delete(out)
		}
	}

	// Store under lock
	sync.mutex_lock(&m.mu)
	_free_state(&m.pending)
	m.pending = Git_State{branch = branch, entries = entries, hunks = hunks}
	m.pending_ready = true
	m.last_refresh_ms = took
	if hint != "" { delete(m.slow_hint); m.slow_hint = hint }
	sync.mutex_unlock(&m.mu)
	wake.request() // ADR 0016: new status → wake the UI loop
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

// _parse_blame parses `git blame --porcelain` output. Per-commit metadata
// (author, author-time, ...) is only emitted the first time a hash appears
// in the stream, so we cache it by hash as we go and reuse it for the
// abbreviated repeat blocks.
_parse_blame :: proc(output: string, lines: ^[dynamic]Blame_Line) {
	Blame_Info :: struct { author: string, date: string }
	info_cache := make(map[string]Blame_Info, context.temp_allocator)

	s := output
	for len(s) > 0 {
		header: string
		if nl := strings.index_byte(s, '\n'); nl >= 0 { header = s[:nl]; s = s[nl+1:] } else { header = s; s = "" }
		if len(header) < 40 { continue }
		hash := header[:40]

		rest := strings.trim_left_space(header[40:])
		_, rest2, ok1 := _parse_uint(rest)
		if !ok1 { continue }
		rest2 = strings.trim_left_space(rest2)
		final_line, _, ok2 := _parse_uint(rest2)
		if !ok2 { continue }

		info, has_info := info_cache[hash]
		for len(s) > 0 {
			lnl := strings.index_byte(s, '\n')
			line: string
			if lnl >= 0 { line = s[:lnl]; s = s[lnl+1:] } else { line = s; s = "" }
			if len(line) > 0 && line[0] == '\t' { break } // content line — end of this block

			if strings.has_prefix(line, "author ") {
				info.author = strings.trim_space(line[len("author "):])
				has_info = true
			} else if strings.has_prefix(line, "author-time ") {
				ts_str := strings.trim_space(line[len("author-time "):])
				if ts, pok := strconv.parse_i64(ts_str); pok {
					info.date = _format_epoch_date(ts)
				}
				has_info = true
			}
		}
		if !has_info {
			info = Blame_Info{author = "unknown", date = ""}
		}
		info_cache[hash] = info

		if final_line > 0 {
			for len(lines^) < final_line { append(lines, Blame_Line{}) }
			lines[final_line-1] = Blame_Line{
				hash   = strings.clone(hash),
				author = strings.clone(info.author),
				date   = strings.clone(info.date),
			}
		}
	}
}

_format_epoch_date :: proc(sec: i64) -> string {
	t := time.unix(sec, 0)
	year, month, day := time.date(t)
	return fmt.aprintf("%02d/%02d/%04d", day, int(month), year)
}

_free_blame_lines :: proc(lines: ^[dynamic]Blame_Line) {
	for &l in lines {
		if l.hash != ""   { delete(l.hash) }
		if l.author != "" { delete(l.author) }
		if l.date != ""   { delete(l.date) }
	}
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
