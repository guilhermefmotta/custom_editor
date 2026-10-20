package editor

import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "./wake"

MAX_SEARCH_RESULTS :: 500

Search_Result :: struct {
	file: string, // heap-owned
	line: int,    // 1-based
	col:  int,    // 1-based
	ctx:  string, // heap-owned, trimmed line content
	match_len: int,    // bytes of the match (query length) — selected on open
	// Branch scope only (search_scope.odin): repo-relative path inside the
	// branch tree and the untrimmed line (the file isn't on disk). Heap-owned.
	path:      string,
	line_text: string,
}

search_result_free :: proc(r: ^Search_Result) {
	delete(r.file); delete(r.ctx)
	if r.path != ""      { delete(r.path) }
	if r.line_text != "" { delete(r.line_text) }
	r^ = {}
}

// Where a search runs: the workspace on disk, or the tree of a branch read
// straight from git objects (no checkout) — see search_scope.odin.
Search_Scope_Kind :: enum u8 { Workspace, Branch }

Search_Scope :: struct {
	kind:      Search_Scope_Kind,
	name:      string, // short branch name ("feature", "origin/feature"); heap
	ref:       string, // full ref ("refs/heads/feature"); heap
	is_remote: bool,
	is_head:   bool,   // checked-out local branch when the scope was chosen
}

search_scope_clone :: proc(sc: Search_Scope) -> Search_Scope {
	out := sc
	out.name = strings.clone(sc.name) if sc.name != "" else ""
	out.ref  = strings.clone(sc.ref)  if sc.ref  != "" else ""
	return out
}

search_scope_free :: proc(sc: ^Search_Scope) {
	if sc.name != "" { delete(sc.name) }
	if sc.ref  != "" { delete(sc.ref) }
	sc^ = {}
}

Search_Phase :: enum { Idle, Running, Done }

Search_State :: struct {
	phase:   Search_Phase,
	mu:      sync.Mutex,
	cancel:  bool,
	results: [dynamic]Search_Result,
	n_files: int,
	t:       ^thread.Thread,
	// Scope of the next/current search (main thread sets it via
	// search_set_scope; the worker reads its own copy). root = git root used
	// by branch scope.
	scope:   Search_Scope,
	root:    string,
	elapsed_ms: f64,    // wall time of the last finished search
	err:        string, // heap; set by the branch worker on failure
	// Workspace scope (search_fast.odin): which engine ran, and the running
	// ripgrep process so search_stop can kill it instead of waiting.
	engine:          Search_Engine,
	rg_proc:         os.Process,
	rg_running:      bool,
	include_ignored: bool, // [editor] search_ignored_files; main thread sets it
}

Search_Thread_Args :: struct {
	state: ^Search_State,
	query: string, // heap-owned, freed by worker
	scope: Search_Scope, // own copy, freed by worker
	root:  string,       // heap-owned, freed by worker
	include_ignored: bool,
}

search_state_init :: proc() -> Search_State {
	s: Search_State
	s.results = make([dynamic]Search_Result)
	return s
}

search_state_destroy :: proc(s: ^Search_State) {
	_search_stop(s)
	for &r in s.results { search_result_free(&r) }
	delete(s.results)
	search_scope_free(&s.scope)
	if s.root != "" { delete(s.root) }
	if s.err != ""  { delete(s.err) }
}

@(private="file")
_search_stop :: proc(s: ^Search_State) {
	if s.t != nil {
		sync.mutex_lock(&s.mu)
		s.cancel = true
		if s.rg_running {
			_ = os.process_kill(s.rg_proc) // the worker is blocked reading its output
			s.rg_running = false
		}
		sync.mutex_unlock(&s.mu)
		thread.join(s.t)
		thread.destroy(s.t)
		s.t = nil
	}
}

// Sets the scope (and git root) used by the next search_start. Copies both.
search_set_scope :: proc(s: ^Search_State, scope: Search_Scope, root: string) {
	// Clone before freeing: scope/root may alias s.scope/s.root.
	nsc   := search_scope_clone(scope)
	nroot := strings.clone(root) if root != "" else ""
	search_scope_free(&s.scope)
	if s.root != "" { delete(s.root) }
	s.scope = nsc
	s.root  = nroot
}

search_start :: proc(s: ^Search_State, query_str: string) {
	// Cancel any in-flight search
	_search_stop(s)
	// Reset
	for &r in s.results { search_result_free(&r) }
	clear(&s.results)
	if s.err != "" { delete(s.err); s.err = "" }
	s.cancel  = false
	s.n_files = 0
	s.elapsed_ms = 0
	s.engine  = .None
	s.phase   = .Running

	if len(strings.trim_space(query_str)) == 0 {
		s.phase = .Done
		return
	}

	args       := new(Search_Thread_Args)
	args.state  = s
	args.query  = strings.clone(query_str)
	args.scope  = search_scope_clone(s.scope)
	args.root   = strings.clone(s.root) if s.root != "" else ""
	args.include_ignored = s.include_ignored

	s.t = thread.create_and_start_with_data(args, search_worker_proc, context)
}

search_worker_proc :: proc(data: rawptr) {
	args := cast(^Search_Thread_Args)data
	s    := args.state
	t0   := time.tick_now()
	defer {
		delete(args.query)
		search_scope_free(&args.scope)
		if args.root != "" { delete(args.root) }
		free(args)
		sync.mutex_lock(&s.mu)
		s.elapsed_ms = time.duration_milliseconds(time.tick_since(t0))
		s.phase = .Done
		sync.mutex_unlock(&s.mu)
		wake.request() // ADR 0016: search finished → wake the UI loop
	}

	if args.scope.kind == .Branch {
		search_branch_run(s, args.root, args.scope.ref, args.query)
		return
	}

	search_run_workspace(s, args.query, args.include_ignored)
}

// One match found by search_scan_buffer. line/col are 1-based; the line
// spans data[line_start:line_end] (without the '\n').
Search_Match :: struct {
	line, col:            int,
	line_start, line_end: int,
}

// ASCII case-insensitive scan of a whole in-memory buffer (same matching
// rules as search_file). Appends up to `limit` matches to `out`.
search_scan_buffer :: proc(data: []u8, query: []u8, limit: int, out: ^[dynamic]Search_Match) {
	qlen := len(query)
	if qlen == 0 || qlen > len(data) || limit <= 0 { return }
	lower :: #force_inline proc "contextless" (b: u8) -> u8 { return b | 32 if b >= 'A' && b <= 'Z' else b }
	q0 := lower(query[0])
	line, line_start := 1, 0
	found := 0
	for i := 0; i + qlen <= len(data); i += 1 {
		b := data[i]
		if b == '\n' { line += 1; line_start = i + 1; continue }
		if lower(b) != q0 { continue }
		ok := true
		for j in 1 ..< qlen {
			if lower(data[i + j]) != lower(query[j]) { ok = false; break }
		}
		if !ok { continue }
		e := i + qlen
		for e < len(data) && data[e] != '\n' { e += 1 }
		append(out, Search_Match{line = line, col = i - line_start + 1, line_start = line_start, line_end = e})
		found += 1
		if found >= limit { return }
	}
}

// Pure: true when `data` looks binary (NUL byte in the first 8 KiB).
search_is_binary :: proc(data: []u8) -> bool {
	for b in data[:min(len(data), 8192)] { if b == 0 { return true } }
	return false
}
