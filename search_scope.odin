package editor

// ===========================================================================
// Branch-scoped text search (ticket #12, ADR 0002).
//
// search_start with s.scope.kind == .Branch runs search_branch_run on the
// search thread (never the UI thread): the branch tree is listed with
// `git ls-tree -r -z -l <ref>` and the blobs are read with
// `git cat-file --batch` — one process per worker thread, several worker
// threads — so nothing is checked out and many blobs cost one process each.
// Same skip rules as the workspace search: binary (NUL in the first 8 KiB)
// and files larger than SEARCH_BRANCH_MAX_BLOB are ignored; results are
// capped at MAX_SEARCH_RESULTS.
// ===========================================================================

import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "git"

SEARCH_BRANCH_MAX_BLOB    :: 2 << 20 // 2 MB
SEARCH_BRANCH_MAX_THREADS :: 8
SEARCH_BRANCH_MIN_PER_THREAD :: 64   // blobs; fewer → fewer threads

Tree_Entry :: struct {
	oid:  string,
	path: string,
	size: int,
}

// Pure: parses `git ls-tree -r -z -l` output into blob entries (slices of
// `out`, no copies). Skips non-blobs (submodules), symlinks and blobs bigger
// than max_size (counted in `skipped`).
search_parse_ls_tree :: proc(out: string, max_size: int, allocator := context.allocator) -> (entries: [dynamic]Tree_Entry, skipped: int) {
	entries = make([dynamic]Tree_Entry, allocator)
	rest := out
	for len(rest) > 0 {
		rec := rest
		if nul := strings.index_byte(rest, 0); nul >= 0 {
			rec = rest[:nul]; rest = rest[nul + 1:]
		} else {
			rest = ""
		}
		tab := strings.index_byte(rec, '\t')
		if tab < 0 { continue }
		meta, path := rec[:tab], rec[tab + 1:]
		f := strings.fields(meta, context.temp_allocator)
		if len(f) < 4 { continue }
		if f[1] != "blob" || f[0] == "120000" { continue }
		size, ok := strconv.parse_int(f[3])
		if !ok { continue }
		if size > max_size { skipped += 1; continue }
		append(&entries, Tree_Entry{oid = f[2], path = path, size = size})
	}
	return
}

// Runs on the search thread (see search_worker_proc).
search_branch_run :: proc(s: ^Search_State, root, ref, query: string) {
	set_err :: proc(s: ^Search_State, msg: string) {
		sync.mutex_lock(&s.mu)
		if s.err != "" { delete(s.err) }
		s.err = strings.clone(msg)
		sync.mutex_unlock(&s.mu)
	}
	if root == "" { set_err(s, "not a git repository"); return }

	out, code := git.git_run_raw(root, {"ls-tree", "-r", "-z", "-l", "--full-tree", ref})
	defer delete(out)
	if code != 0 { set_err(s, "git ls-tree failed (unknown branch?)"); return }

	entries, _ := search_parse_ls_tree(out, SEARCH_BRANCH_MAX_BLOB)
	defer delete(entries)
	if len(entries) == 0 { return }

	n := clamp(os.get_processor_core_count(), 1, SEARCH_BRANCH_MAX_THREADS)
	n = clamp((len(entries) + SEARCH_BRANCH_MIN_PER_THREAD - 1) / SEARCH_BRANCH_MIN_PER_THREAD, 1, n)

	jobs := make([]_Branch_Chunk, n)
	defer delete(jobs)
	per := (len(entries) + n - 1) / n
	threads := make([dynamic]^thread.Thread, 0, n)
	defer delete(threads)
	for i in 0 ..< n {
		lo := i * per
		hi := min(lo + per, len(entries))
		if lo >= hi { break }
		jobs[i] = {s = s, root = root, query = query, entries = entries[lo:hi]}
		append(&threads, thread.create_and_start_with_data(&jobs[i], _branch_chunk_proc, context))
	}
	for t in threads { thread.join(t); thread.destroy(t) }
}

@(private="file")
_Branch_Chunk :: struct {
	s:       ^Search_State,
	root:    string,
	query:   string,
	entries: []Tree_Entry,
}

// os.process_start is not thread-safe w.r.t. handle inheritance.
@(private)
search_proc_mu: sync.Mutex

@(private="file")
_stop_requested :: proc(s: ^Search_State) -> bool {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	return s.cancel || len(s.results) >= MAX_SEARCH_RESULTS
}

@(private="file")
_branch_chunk_proc :: proc(data: rawptr) {
	job := (^_Branch_Chunk)(data)
	s := job.s

	// Object ids go through a temp file used as stdin: no writer thread and
	// no pipe deadlock while git streams blobs back.
	tf, terr := os.create_temp_file("", "editor-search-*")
	if terr != nil { return }
	tmp_name := strings.clone(os.name(tf))
	defer { os.close(tf); os.remove(tmp_name); delete(tmp_name) }
	{
		sb := strings.builder_make()
		defer strings.builder_destroy(&sb)
		for e in job.entries { strings.write_string(&sb, e.oid); strings.write_byte(&sb, '\n') }
		if _, werr := os.write(tf, sb.buf[:]); werr != nil { return }
		if _, serr := os.seek(tf, 0, .Start); serr != nil { return }
	}

	sync.mutex_lock(&search_proc_mu)
	r, w, perr := os.pipe()
	if perr != nil { sync.mutex_unlock(&search_proc_mu); return }
	p, sperr := os.process_start({
		working_dir = job.root,
		command     = {"git", "cat-file", "--batch"},
		stdin       = tf,
		stdout      = w,
	})
	os.close(w)
	sync.mutex_unlock(&search_proc_mu)
	defer os.close(r)
	if sperr != nil { return }
	killed := false
	defer {
		if killed { _ = os.process_kill(p) }
		_, _ = os.process_wait(p)
	}

	rd := _Reader{f = r, buf = make([]u8, 64 * 1024)}
	defer delete(rd.buf)
	header := make([dynamic]u8)
	defer delete(header)
	blob := make([dynamic]u8)
	defer delete(blob)
	matches := make([dynamic]Search_Match)
	defer delete(matches)
	q := transmute([]u8)job.query

	for e in job.entries {
		if _stop_requested(s) { killed = true; return }
		if !_rd_line(&rd, &header) { return }
		f := strings.fields(string(header[:]), context.temp_allocator)
		if len(f) < 3 { continue } // "<oid> missing"
		size, ok := strconv.parse_int(f[2])
		if !ok { return }
		resize(&blob, size + 1) // + trailing '\n'
		if !_rd_exact(&rd, blob[:]) { return }
		data := blob[:size]

		sync.mutex_lock(&s.mu)
		s.n_files += 1
		sync.mutex_unlock(&s.mu)

		if search_is_binary(data) { continue }
		clear(&matches)
		search_scan_buffer(data, q, MAX_SEARCH_RESULTS, &matches)
		if len(matches) == 0 { continue }
		_append_branch_results(s, job.root, e.path, data, matches[:], len(q))
	}
}

// Appends all matches of one file at once so results stay grouped by file
// (palette rows group consecutive results of the same file).
@(private="file")
_append_branch_results :: proc(s: ^Search_State, root, path: string, data: []u8, matches: []Search_Match, qlen: int) {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	abs := strings.concatenate({strings.trim_right(root, "/\\"), "/", path}, context.temp_allocator)
	for m in matches {
		if len(s.results) >= MAX_SEARCH_RESULTS { return }
		line := string(data[m.line_start:m.line_end])
		line = strings.trim_right(line, "\r")
		append(&s.results, Search_Result{
			file      = strings.clone(abs),
			line      = m.line,
			col       = m.col,
			ctx       = strings.clone(strings.trim_left(line, " \t")),
			match_len = qlen,
			path      = strings.clone(path),
			line_text = strings.clone(line) if line != "" else "",
		})
	}
}

// ---- tiny buffered reader over a pipe ----

@(private="file")
_Reader :: struct {
	f:      ^os.File,
	buf:    []u8,
	lo, hi: int,
}

@(private="file")
_rd_fill :: proc(r: ^_Reader) -> bool {
	if r.lo == r.hi { r.lo = 0; r.hi = 0 }
	if r.hi == len(r.buf) { return true }
	n, err := os.read(r.f, r.buf[r.hi:])
	if n <= 0 || (err != nil && n <= 0) { return false }
	r.hi += n
	return true
}

@(private="file")
_rd_line :: proc(r: ^_Reader, out: ^[dynamic]u8) -> bool {
	clear(out)
	for {
		if r.lo == r.hi && !_rd_fill(r) { return false }
		chunk := r.buf[r.lo:r.hi]
		if i := index_byte_u8(chunk, '\n'); i >= 0 {
			append(out, ..chunk[:i])
			r.lo += i + 1
			return true
		}
		append(out, ..chunk)
		r.lo = r.hi
	}
}

@(private="file")
_rd_exact :: proc(r: ^_Reader, dst: []u8) -> bool {
	got := 0
	for got < len(dst) {
		if r.lo == r.hi {
			// Large remainder: read straight into dst.
			if len(dst) - got >= len(r.buf) {
				n, _ := os.read(r.f, dst[got:])
				if n <= 0 { return false }
				got += n
				continue
			}
			if !_rd_fill(r) { return false }
		}
		n := copy(dst[got:], r.buf[r.lo:r.hi])
		r.lo += n
		got += n
	}
	return true
}

@(private="file")
index_byte_u8 :: proc(b: []u8, c: u8) -> int {
	for x, i in b { if x == c { return i } }
	return -1
}
