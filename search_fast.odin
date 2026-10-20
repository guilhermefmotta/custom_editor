package editor

// Workspace text search engines (ADR 0017), run from the search worker
// thread (search.odin):
//
//   1. ripgrep, when `rg` is installed: the de-facto standard (VS Code ships
//      it), multi-threaded, honors .gitignore and skips binary files. Its
//      output is streamed and parsed as it arrives; cancelling a search
//      kills the process (search_stop), so typing never waits on it.
//   2. built-in: the workspace index (ws_index.odin) scanned by a pool of
//      threads, each reusing one read buffer, skipping files over
//      SEARCH_MAX_FILE_SIZE and binary files.
//
// Both report the same thing: case-insensitive literal matches, one result
// per match, at most MAX_SEARCH_RESULTS, grouped by file.

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"

SEARCH_MAX_FILE_SIZE :: 8 << 20
SEARCH_MAX_THREADS   :: 8

Search_Engine :: enum u8 { None, Ripgrep, Builtin }

// ---------------------------------------------------------------------------
// Locating ripgrep
// ---------------------------------------------------------------------------

@(private="file") _rg_path:   string
@(private="file") _rg_looked: bool
@(private="file") _rg_mu:     sync.Mutex

@(fini, private="file")
_rg_fini :: proc "contextless" () {
	context = runtime.default_context()
	delete(_rg_path)
}

// Absolute path of `rg`, or "" when not installed. Looks in PATH and in the
// usual install folders a GUI app's PATH tends to miss (Homebrew, cargo).
ripgrep_path :: proc() -> string {
	sync.mutex_lock(&_rg_mu)
	defer sync.mutex_unlock(&_rg_mu)
	if _rg_looked { return _rg_path }
	_rg_looked = true
	if p := find_executable(SEARCH_RG_EXE); p != "" { _rg_path = p }
	return _rg_path
}

when ODIN_OS == .Windows {
	@(private="file") SEARCH_RG_EXE  :: "rg.exe"
	@(private="file") PATH_LIST_SEP  :: ";"
} else {
	@(private="file") SEARCH_RG_EXE  :: "rg"
	@(private="file") PATH_LIST_SEP  :: ":"
}

// Searches PATH, then a few well-known folders. Heap string or "".
find_executable :: proc(name: string) -> string {
	dirs := make([dynamic]string, context.temp_allocator)
	path_env := os.get_env("PATH", context.temp_allocator)
	for d in strings.split(path_env, PATH_LIST_SEP, context.temp_allocator) {
		if d != "" { append(&dirs, d) }
	}
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" { home = os.get_env("USERPROFILE", context.temp_allocator) }
	append(&dirs, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin")
	if home != "" {
		cargo, _ := filepath.join({home, ".cargo", "bin"}, context.temp_allocator)
		scoop, _ := filepath.join({home, "scoop", "shims"}, context.temp_allocator)
		append(&dirs, cargo, scoop)
	}
	for d in dirs {
		p, _ := filepath.join({d, name}, context.temp_allocator)
		if os.exists(p) && !os.is_dir(p) { return strings.clone(p) }
	}
	return ""
}

// ---------------------------------------------------------------------------
// Entry point (search worker thread)
// ---------------------------------------------------------------------------

// Tests force the built-in engine with this.
search_disable_ripgrep: bool

search_run_workspace :: proc(s: ^Search_State, query: string, include_ignored: bool) {
	if rg := ripgrep_path(); rg != "" && !search_disable_ripgrep {
		if _search_ripgrep(s, rg, query, include_ignored) {
			_search_set_engine(s, .Ripgrep)
			_search_sort_results(s)
			return
		}
	}
	_search_set_engine(s, .Builtin)
	_search_builtin(s, query, include_ignored)
	_search_sort_results(s)
}

@(private="file")
_search_set_engine :: proc(s: ^Search_State, en: Search_Engine) {
	sync.mutex_lock(&s.mu)
	s.engine = en
	sync.mutex_unlock(&s.mu)
}

@(private="file")
_search_should_stop :: proc(s: ^Search_State) -> bool {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	return s.cancel || len(s.results) >= MAX_SEARCH_RESULTS
}

// Results grouped by file (path order), line order inside a file.
@(private="file")
_search_sort_results :: proc(s: ^Search_State) {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	slice.stable_sort_by(s.results[:], proc(a, b: Search_Result) -> bool {
		if a.file != b.file { return a.file < b.file }
		if a.line != b.line { return a.line < b.line }
		return a.col < b.col
	})
}

// ---------------------------------------------------------------------------
// ripgrep
// ---------------------------------------------------------------------------

// false = rg could not be started (the caller falls back to the built-in).
@(private="file")
_search_ripgrep :: proc(s: ^Search_State, rg, query: string, include_ignored: bool) -> bool {
	args := make([dynamic]string, context.temp_allocator)
	append(&args, rg, "--no-config", "--vimgrep", "--null", "--path-separator", "/",
	       "--color", "never", "--fixed-strings", "--ignore-case", "--trim",
	       "--max-columns", "400", "--max-columns-preview",
	       "--max-filesize", "8M")
	if include_ignored {
		append(&args, "--no-ignore")
		for d in WS_SKIP_DIRS { append(&args, "-g", strings.concatenate({"!", d, "/"}, context.temp_allocator)) }
	}
	append(&args, "-e", query, ".")

	r, w, perr := os.pipe()
	if perr != nil { return false }
	pr, serr := os.process_start({command = args[:], stdout = w})
	os.close(w)
	if serr != nil { os.close(r); return false }

	sync.mutex_lock(&s.mu)
	if s.cancel {
		sync.mutex_unlock(&s.mu)
		_ = os.process_kill(pr)
	} else {
		s.rg_proc, s.rg_running = pr, true
		sync.mutex_unlock(&s.mu)
		_rg_read_output(s, r, len(query))
	}
	os.close(r)

	sync.mutex_lock(&s.mu)
	running := s.rg_running
	s.rg_running = false
	sync.mutex_unlock(&s.mu)
	if running { _ = os.process_kill(pr) } // stopped early (limit reached): nothing more to read
	_, _ = os.process_wait(pr)
	return true
}

@(private="file")
_rg_read_output :: proc(s: ^Search_State, r: ^os.File, qlen: int) {
	pending := make([dynamic]u8)
	defer delete(pending)
	chunk: [64 * 1024]u8
	files_seen := ""
	for {
		n, err := os.read(r, chunk[:])
		if n <= 0 || err != nil { break }
		append(&pending, ..chunk[:n])
		start := 0
		for i in 0 ..< len(pending) {
			if pending[i] != '\n' { continue }
			line := string(pending[start:i])
			start = i + 1
			if res, ok := rg_parse_line(line, qlen); ok {
				sync.mutex_lock(&s.mu)
				full := len(s.results) >= MAX_SEARCH_RESULTS || s.cancel
				if !full {
					if res.file != files_seen { s.n_files += 1 }
					append(&s.results, res)
					files_seen = s.results[len(s.results) - 1].file
				} else {
					search_result_free(&res)
				}
				sync.mutex_unlock(&s.mu)
				if full { return }
			}
		}
		remove_range(&pending, 0, start)
	}
}

// One `rg --vimgrep --null` line: "path\0line:col:text". Heap result.
rg_parse_line :: proc(line: string, qlen: int) -> (res: Search_Result, ok: bool) {
	z := strings.index_byte(line, 0)
	if z <= 0 { return }
	path, rest := strings.trim_prefix(line[:z], "./"), line[z + 1:]
	c1 := strings.index_byte(rest, ':')
	if c1 < 0 { return }
	c2 := strings.index_byte(rest[c1 + 1:], ':')
	if c2 < 0 { return }
	c2 += c1 + 1
	ln, lok := strconv.parse_int(rest[:c1])
	col, cok := strconv.parse_int(rest[c1 + 1:c2])
	if !lok || !cok { return }
	text := strings.trim_right(rest[c2 + 1:], "\r")
	return Search_Result{
		file = strings.clone(path), line = ln, col = col,
		ctx = strings.clone(text), match_len = qlen,
	}, true
}

// ---------------------------------------------------------------------------
// Built-in: thread pool over the workspace index
// ---------------------------------------------------------------------------

@(private="file")
_Pool :: struct {
	s:     ^Search_State,
	files: []string,
	next:  int, // atomic
	query: []u8,
}

@(private="file")
_search_builtin :: proc(s: ^Search_State, query: string, include_ignored: bool) {
	snap, _ := ws_index_get()
	if snap == nil {
		// First search before the index exists: build one here (worker thread)
		snap = ws_index_build(".", include_ignored, &s.cancel)
		if snap == nil { return }
	}
	defer ws_snapshot_release(snap)

	pool := _Pool{s = s, files = snap.files, query = transmute([]u8)query}
	n := clamp(os.get_processor_core_count() - 1, 1, SEARCH_MAX_THREADS)
	threads := make([dynamic]^thread.Thread, context.temp_allocator)
	for _ in 0 ..< n {
		append(&threads, thread.create_and_start_with_poly_data(&pool, _search_pool_worker, context))
	}
	for t in threads { thread.join(t); thread.destroy(t) }
}

@(private="file")
_search_pool_worker :: proc(pool: ^_Pool) {
	s := pool.s
	buf := make([dynamic]u8)
	defer delete(buf)
	matches := make([dynamic]Search_Match)
	defer delete(matches)
	for {
		i := sync.atomic_add(&pool.next, 1)
		if i >= len(pool.files) || _search_should_stop(s) { return }
		path := pool.files[i]
		data, ok := _search_read_small(path, &buf)
		if !ok { continue }
		sync.atomic_add(&s.n_files, 1)
		if search_is_binary(data) { continue }
		clear(&matches)
		search_scan_buffer(data, pool.query, MAX_SEARCH_RESULTS, &matches)
		if len(matches) == 0 { continue }
		sync.mutex_lock(&s.mu)
		for m in matches {
			if len(s.results) >= MAX_SEARCH_RESULTS { break }
			ls := m.line_start
			for ls < m.line_end && (data[ls] == ' ' || data[ls] == '\t') { ls += 1 }
			append(&s.results, Search_Result{
				file = strings.clone(path), line = m.line, col = m.col,
				ctx = strings.clone(string(data[ls:m.line_end])), match_len = len(pool.query),
			})
		}
		sync.mutex_unlock(&s.mu)
	}
}

// Whole file into `buf` (reused across files). Skips big files.
@(private="file")
_search_read_small :: proc(path: string, buf: ^[dynamic]u8) -> ([]u8, bool) {
	f, err := os.open(path)
	if err != nil { return nil, false }
	defer os.close(f)
	size, serr := os.file_size(f)
	if serr != nil || size <= 0 || size > SEARCH_MAX_FILE_SIZE { return nil, false }
	resize(buf, int(size))
	total := 0
	for total < int(size) {
		n, rerr := os.read(f, buf[total:])
		if n <= 0 || rerr != nil { break }
		total += n
	}
	return buf[:total], total > 0
}
