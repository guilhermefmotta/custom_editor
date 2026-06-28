package editor

import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"

MAX_SEARCH_RESULTS :: 500
SEARCH_CHUNK       :: 4 << 20 // 4 MB per read

Search_Result :: struct {
	file: string, // heap-owned
	line: int,    // 1-based
	col:  int,    // 1-based
	ctx:  string, // heap-owned, trimmed line content
}

Search_Phase :: enum { Idle, Running, Done }

Search_State :: struct {
	phase:   Search_Phase,
	mu:      sync.Mutex,
	cancel:  bool,
	results: [dynamic]Search_Result,
	n_files: int,
	t:       ^thread.Thread,
}

Search_Thread_Args :: struct {
	state: ^Search_State,
	query: string, // heap-owned, freed by worker
}

search_state_init :: proc() -> Search_State {
	s: Search_State
	s.results = make([dynamic]Search_Result)
	return s
}

search_state_destroy :: proc(s: ^Search_State) {
	if s.t != nil {
		sync.mutex_lock(&s.mu)
		s.cancel = true
		sync.mutex_unlock(&s.mu)
		thread.join(s.t)
		thread.destroy(s.t)
		s.t = nil
	}
	for &r in s.results { delete(r.file); delete(r.ctx) }
	delete(s.results)
}

search_start :: proc(s: ^Search_State, query_str: string) {
	// Cancel any in-flight search
	if s.t != nil {
		sync.mutex_lock(&s.mu)
		s.cancel = true
		sync.mutex_unlock(&s.mu)
		thread.join(s.t)
		thread.destroy(s.t)
		s.t = nil
	}
	// Reset
	for &r in s.results { delete(r.file); delete(r.ctx) }
	clear(&s.results)
	s.cancel  = false
	s.n_files = 0
	s.phase   = .Running

	if len(strings.trim_space(query_str)) == 0 {
		s.phase = .Done
		return
	}

	args       := new(Search_Thread_Args)
	args.state  = s
	args.query  = strings.clone(query_str)

	s.t = thread.create_and_start_with_data(args, search_worker_proc)
}

search_worker_proc :: proc(data: rawptr) {
	args := cast(^Search_Thread_Args)data
	s    := args.state
	q    := transmute([]u8)args.query
	defer {
		delete(args.query)
		free(args)
		sync.mutex_lock(&s.mu)
		s.phase = .Done
		sync.mutex_unlock(&s.mu)
	}

	SKIP :: [?]string{".git", "node_modules", "target", "__pycache__",
	                  ".cache", "build", "dist", ".next", "vendor"}

	w: os.Walker
	os.walker_init(&w, ".")
	defer os.walker_destroy(&w)

	for {
		sync.mutex_lock(&s.mu)
		stop := s.cancel || len(s.results) >= MAX_SEARCH_RESULTS
		sync.mutex_unlock(&s.mu)
		if stop { break }

		info, ok := os.walker_walk(&w)
		if !ok { break }

		if info.type == .Directory {
			skip := len(info.name) > 0 && info.name[0] == '.'
			if !skip {
				for d in SKIP { if info.name == d { skip = true; break } }
			}
			if skip { os.walker_skip_dir(&w) }
			continue
		}

		search_file(s, info.fullpath, q)
		sync.mutex_lock(&s.mu)
		s.n_files += 1
		sync.mutex_unlock(&s.mu)
	}
}

// Linear scan with overlap so matches across chunk boundaries are found.
// Tracks line/col incrementally — O(file_size) per file regardless of match count.
search_file :: proc(s: ^Search_State, path: string, query: []u8) {
	qlen := len(query)
	if qlen == 0 { return }

	f, ferr := os.open(path)
	if ferr != nil { return }
	defer os.close(f)

	ov  := qlen - 1
	buf := make([]u8, SEARCH_CHUNK + ov + 1)
	defer delete(buf)

	prev     := 0
	cur_line := 1
	cur_col  := 0
	is_first := true

	for {
		sync.mutex_lock(&s.mu)
		stop := s.cancel || len(s.results) >= MAX_SEARCH_RESULTS
		sync.mutex_unlock(&s.mu)
		if stop { return }

		n, _ := os.read(f, buf[prev:prev + SEARCH_CHUNK])
		if n == 0 { break }

		window  := buf[:prev + n]
		win_len := len(window)

		// Binary detection: bail on null byte in first 8 KB
		if is_first {
			check := min(8192, n)
			for i in 0..<check {
				if window[i] == 0 { return }
			}
			is_first = false
		}

		// Checkpoint: line/col state just before the overlap we'll keep
		ckpt_pos  := win_len - ov if ov > 0 && win_len > ov else 0
		ckpt_line := cur_line
		ckpt_col  := cur_col
		ckpt_set  := ov == 0

		for i in 0..<win_len {
			b := window[i]

			if !ckpt_set && i == ckpt_pos {
				ckpt_line = cur_line
				ckpt_col  = cur_col
				ckpt_set  = true
			}

			// Report match if it uses at least one byte from new data and fits in window.
			// This catches cross-chunk-boundary matches via the overlap.
			if i + qlen > prev && i + qlen <= win_len {
				bl := b; if bl >= 'A' && bl <= 'Z' { bl |= 32 }
				ql := query[0]; if ql >= 'A' && ql <= 'Z' { ql |= 32 }
				if bl == ql {
					ok := true
					for j in 1..<qlen {
						bj := window[i+j]; if bj >= 'A' && bj <= 'Z' { bj |= 32 }
						qj := query[j];    if qj >= 'A' && qj <= 'Z' { qj |= 32 }
						if bj != qj { ok = false; break }
					}
					if ok {
						sync.mutex_lock(&s.mu)
						can_add := len(s.results) < MAX_SEARCH_RESULTS
						sync.mutex_unlock(&s.mu)
						if can_add {
							ctx_s := i
							for ctx_s > 0 && window[ctx_s-1] != '\n' { ctx_s -= 1 }
							ctx_e := i + qlen
							for ctx_e < win_len && window[ctx_e] != '\n' { ctx_e += 1 }
							// trim leading whitespace
							for ctx_s < ctx_e && (window[ctx_s] == ' ' || window[ctx_s] == '\t') {
								ctx_s += 1
							}
							r := Search_Result{
								file = strings.clone(path),
								line = cur_line,
								col  = cur_col + 1,
								ctx  = strings.clone(string(window[ctx_s:ctx_e])),
							}
							sync.mutex_lock(&s.mu)
							append(&s.results, r)
							sync.mutex_unlock(&s.mu)
						}
					}
				}
			}

			if b == '\n' { cur_line += 1; cur_col = 0 } else { cur_col += 1 }
		}

		// Carry overlap to next chunk
		if ov > 0 && ckpt_pos < win_len {
			copy(buf, window[ckpt_pos:])
			prev     = win_len - ckpt_pos
			cur_line = ckpt_line
			cur_col  = ckpt_col
		} else {
			prev = 0
		}

		if n < SEARCH_CHUNK { break }
	}
}
