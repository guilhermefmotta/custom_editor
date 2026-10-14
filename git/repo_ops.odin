package git

// ===========================================================================
// Repository creation: clone by URL and init (ticket #13, ADR 0014).
//
//   prog := new(Clone_Progress)                 // owned by the caller, outlives the job
//   id   := git_request_clone(&queue, url, dest, prog)
//   ...  clone_progress_read(prog) → (phase, percent) every frame
//   r, st, _ := git_poll_as(&queue, id, Git_Custom) → git_custom_as(r^, Repo_Op_Result)
//
//   id := git_request_init(&queue, path)        // mkdir -p + git init
//
// Both run on a Git_Queue that is not bound to a repository (the queue root is
// ignored: clone runs in the destination's parent, init in the target dir).
// Clone uses the same non-interactive environment as the remote ops
// (remote_env: GIT_TERMINAL_PROMPT=0, GCM_INTERACTIVE=never, ssh BatchMode,
// LC_ALL=C), so a missing credential fails fast with a clear message instead
// of hanging on a prompt. Failures are classified with remote_classify_error.
// ===========================================================================

import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"

Repo_Op :: enum u8 { Clone, Init }

Repo_Op_Result :: struct {
	op:      Repo_Op,
	ok:      bool,
	kind:    Remote_Error_Kind, // clone failures; .None on success / init
	message: string,            // user-facing, one line
	output:  string,            // raw git output
	path:    string,            // absolute path of the new repository
}

// Live progress of a clone, written by the worker, read by the UI.
Clone_Progress :: struct {
	mu:      sync.Mutex,
	phase:   [48]u8,
	phase_n: int,
	percent: int, // -1 = unknown
	tail:    [dynamic]u8, // incomplete last line (worker only)
}

clone_progress_read :: proc(p: ^Clone_Progress, buf: []u8) -> (phase: string, percent: int) {
	if p == nil { return "", -1 }
	sync.mutex_guard(&p.mu)
	n := copy(buf, p.phase[:p.phase_n])
	return string(buf[:n]), p.percent
}

clone_progress_destroy :: proc(p: ^Clone_Progress) {
	if p == nil { return }
	delete(p.tail)
	free(p)
}

// Parses one line of `git clone --progress` output ("Receiving objects:  45%
// (450/1000), 1.2 MiB | ..."). Pure (tested).
clone_parse_progress :: proc(line: string) -> (phase: string, percent: int, ok: bool) {
	l := strings.trim_space(line)
	l = strings.trim_prefix(l, "remote: ")
	colon := strings.index(l, ": ")
	if colon <= 0 { return "", -1, false }
	ph := l[:colon]
	rest := strings.trim_left_space(l[colon+2:])
	pct := strings.index_byte(rest, '%')
	if pct <= 0 { return "", -1, false }
	v, vok := strconv.parse_int(strings.trim_space(rest[:pct]))
	if !vok || v < 0 || v > 100 { return "", -1, false }
	return ph, v, true
}

// Default destination folder name for a clone URL:
// "https://github.com/a/b.git" → "b", "git@host:a/b" → "b", "/srv/x.git/" → "x".
clone_repo_name :: proc(url: string) -> string {
	u := strings.trim_space(url)
	u = strings.trim_right(u, "/\\")
	u = strings.trim_suffix(u, ".git")
	i := strings.last_index_any(u, "/\\:")
	name := u[i+1:] if i >= 0 else u
	return name
}

git_request_clone :: proc(q: ^Git_Queue, url, dest: string, progress: ^Clone_Progress = nil) -> Job_Id {
	return git_request_custom(q, _clone_work, {url, dest}, progress)
}

git_request_init :: proc(q: ^Git_Queue, path: string) -> Job_Id {
	return git_request_custom(q, _init_work, {path})
}

repo_op_result :: proc(r: ^Git_Result) -> ^Repo_Op_Result {
	if r == nil { return nil }
	c, ok := r.payload.(Git_Custom)
	if !ok { return nil }
	return git_custom_as(c, Repo_Op_Result)
}

// Pure: user message for a failed clone.
clone_error_message :: proc(kind: Remote_Error_Kind, output: string, allocator := context.allocator) -> string {
	context.allocator = allocator
	#partial switch kind {
	case .Auth:             return strings.clone("Clone failed: authentication required or denied. Check your SSH agent / credential helper (no interactive prompt is shown).")
	case .Network:          return strings.clone("Clone failed: network error (host unreachable or timed out).")
	case .Remote_Not_Found: return strings.clone("Clone failed: repository not found (check the URL and your access).")
	}
	line := _repo_last_line(output)
	if line == "" { return strings.clone("Clone failed.") }
	return strings.concatenate({"Clone failed: ", line})
}

// ---------------------------------------------------------------------------
// Worker side
// ---------------------------------------------------------------------------

@(private = "file")
_abs :: proc(p: string) -> string {
	a, err := filepath.abs(p, context.allocator)
	if err == nil { return a }
	// realpath fails on a path that does not exist yet (the clone target)
	if filepath.is_abs(p) { return strings.clone(p) }
	cwd, cerr := os.get_working_directory(context.temp_allocator)
	if cerr != nil { return strings.clone(p) }
	j, _ := filepath.join({cwd, p}, context.allocator)
	return j
}

@(private = "file")
_dir_has_entries :: proc(dir: string) -> bool {
	f, err := os.open(dir)
	if err != nil { return false }
	defer os.close(f)
	it := os.read_directory_iterator_create(f)
	defer os.read_directory_iterator_destroy(&it)
	_, _, ok := os.read_directory_iterator(&it)
	return ok
}

@(private = "file")
_clone_work :: proc(root: string, args: []string, user: rawptr) -> (Git_Payload, string) {
	res, payload := git_custom_new(Repo_Op_Result)
	res.op = .Clone
	url  := strings.trim_space(args[0])
	dest := _abs(strings.trim_space(args[1]))
	res.path = dest
	prog := (^Clone_Progress)(user)

	switch {
	case url == "":
		res.message = "Clone failed: empty URL."
		return payload, ""
	case args[1] == "":
		res.message = "Clone failed: empty destination."
		return payload, ""
	case os.exists(dest) && (!os.is_dir(dest) || _dir_has_entries(dest)):
		res.message = strings.concatenate({"Clone failed: destination already exists and is not empty: ", dest})
		return payload, ""
	}
	parent := filepath.dir(dest)
	if !os.exists(parent) {
		if err := os.make_directory_all(parent); err != nil {
			res.message = strings.concatenate({"Clone failed: cannot create ", parent})
			return payload, ""
		}
	}

	full := make([dynamic]string, context.temp_allocator)
	append(&full, "-c", "http.lowSpeedLimit=1000", "-c", "http.lowSpeedTime=30")
	append(&full, "clone", "--progress", "--", url, dest)
	out, code := _repo_exec_stream(parent, full[:], remote_env(parent), _clone_on_chunk, prog)
	res.output = out
	if code == 0 && os.is_dir(dest) {
		res.ok = true
		res.message = strings.concatenate({"Cloned into ", dest})
		return payload, ""
	}
	res.kind = remote_classify_error(out)
	if res.kind == .Other && strings.contains(out, "repository") && strings.contains(out, "does not exist") {
		res.kind = .Remote_Not_Found // local path / file:// URL
	}
	res.message = clone_error_message(res.kind, out)
	return payload, ""
}

// Feeds progress lines (split on \r and \n) into the shared progress.
@(private = "file")
_clone_on_chunk :: proc(user: rawptr, chunk: []u8) {
	p := (^Clone_Progress)(user)
	if p == nil { return }
	append(&p.tail, ..chunk)
	s := string(p.tail[:])
	last_nl := strings.last_index_any(s, "\r\n")
	if last_nl < 0 { return }
	done := s[:last_nl]
	// Use the last complete line that parses.
	lines := strings.split_multi(done, {"\r", "\n"}, context.temp_allocator)
	#reverse for l in lines {
		ph, pct, ok := clone_parse_progress(l)
		if !ok { continue }
		sync.mutex_lock(&p.mu)
		p.phase_n = copy(p.phase[:], ph)
		p.percent = pct
		sync.mutex_unlock(&p.mu)
		break
	}
	rest := len(s) - (last_nl + 1)
	copy(p.tail[:], p.tail[last_nl+1:])
	resize(&p.tail, rest)
}

@(private = "file")
_init_work :: proc(root: string, args: []string, user: rawptr) -> (Git_Payload, string) {
	res, payload := git_custom_new(Repo_Op_Result)
	res.op = .Init
	if strings.trim_space(args[0]) == "" {
		res.message = "Init failed: empty path."
		return payload, ""
	}
	dir := _abs(strings.trim_space(args[0]))
	res.path = dir
	if os.exists(dir) && !os.is_dir(dir) {
		res.message = strings.concatenate({"Init failed: not a directory: ", dir})
		return payload, ""
	}
	if !os.exists(dir) {
		if err := os.make_directory_all(dir); err != nil {
			res.message = strings.concatenate({"Init failed: cannot create ", dir})
			return payload, ""
		}
	}
	out, code := _remote_exec(dir, {"init"}, {{"LC_ALL", "C"}}, context.allocator)
	res.output = out
	if code != 0 {
		line := _repo_last_line(out)
		res.message = strings.concatenate({"Init failed: ", line if line != "" else "git init returned an error"})
		return payload, ""
	}
	res.ok = true
	res.message = strings.concatenate({"Initialized empty repository in ", dir})
	return payload, ""
}

// Last meaningful line of git output ("fatal: "/"error: " stripped, hints skipped).
@(private = "file")
_repo_last_line :: proc(s: string) -> string {
	lines := strings.split_multi(strings.trim_space(s), {"\r", "\n"}, context.temp_allocator)
	#reverse for l in lines {
		t := strings.trim_space(l)
		if t == "" || strings.has_prefix(t, "hint:") { continue }
		if _, _, is_prog := clone_parse_progress(t); is_prog { continue }
		t = strings.trim_prefix(t, "fatal: ")
		t = strings.trim_prefix(t, "error: ")
		return t
	}
	return ""
}
