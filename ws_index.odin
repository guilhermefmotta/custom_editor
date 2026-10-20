package editor

// Workspace file index (ADR 0017): the one list of files every search reads
// — Find File (Ctrl+P), the file tree filter and the text search. Built on a
// worker thread, never on the UI thread:
//
//   - inside a git repository: `git ls-files -c -o --exclude-standard`
//     (tracked + untracked, minus what .gitignore excludes). Git answers
//     from its index in a fraction of the time a disk walk takes on a big
//     monorepo; with the setting [editor] search_ignored_files it lists the
//     ignored files too (still without .git/node_modules/...);
//   - anywhere else: fast_walk_files (no per-file stat/open).
//
// Readers get an immutable, reference-counted snapshot, so a rebuild never
// pulls the list from under a running search. The current snapshot keeps
// being served while the next one is built; ws_index_refresh rebuilds when
// it is older than WS_INDEX_MAX_AGE (or was invalidated by a file created,
// renamed or deleted from the editor).

import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "core:os"
import git "./git"
import "./wake"

WS_INDEX_MAX_AGE :: 3 * time.Second

Ws_Snapshot :: struct {
	files:    []string, // workspace-relative, '/' separators
	blob:     string,   // backing text of `files` (git output) — or ""
	owned:    bool,     // files were cloned one by one (walk)
	refs:     i32,      // atomic
	from_git: bool,
	build_ms: f64,
}

ws_snapshot_retain :: proc(s: ^Ws_Snapshot) -> ^Ws_Snapshot {
	if s != nil { sync.atomic_add(&s.refs, 1) }
	return s
}

ws_snapshot_release :: proc(s: ^Ws_Snapshot) {
	if s == nil { return }
	if sync.atomic_sub(&s.refs, 1) != 1 { return }
	if s.owned { for f in s.files { delete(f) } }
	delete(s.files)
	delete(s.blob)
	free(s)
}

Ws_Index :: struct {
	mu:       sync.Mutex,
	cur:      ^Ws_Snapshot, // guarded by mu; holds one reference
	gen:      int,          // bumps with every new snapshot (guarded by mu)
	t:        ^thread.Thread,
	building: bool,         // main thread only
	done:     bool,         // atomic: worker finished
	stop:     bool,         // atomic: abandon the build (shutdown / cwd change)
	dirty:    bool,         // main thread: rebuild on the next refresh
	built_at: time.Tick,
	cwd:      string,       // cwd the current snapshot was built in (heap)
	ignored:  bool,         // include git-ignored files
}

ws_index: Ws_Index

// Current snapshot (retained — release it) and its generation; nil while
// the first build runs.
ws_index_get :: proc() -> (snap: ^Ws_Snapshot, gen: int) {
	sync.mutex_lock(&ws_index.mu)
	defer sync.mutex_unlock(&ws_index.mu)
	return ws_snapshot_retain(ws_index.cur), ws_index.gen
}

ws_index_building :: proc() -> bool { return ws_index.building }

// Snapshot for code that needs the list right now (retained — release it):
// the current one, or one built here when the first build has not finished
// (git ls-files: a fraction of a second even on a big repository).
ws_index_files_now :: proc(include_ignored := false) -> ^Ws_Snapshot {
	if snap, _ := ws_index_get(); snap != nil { return snap }
	return ws_index_build(".", include_ignored)
}

// `rel` (index path) is `abs` (absolute path of an open file)?
ws_same_file :: proc(rel, abs: string) -> bool {
	if len(abs) <= len(rel) { return rel == abs }
	return strings.has_suffix(abs, rel) && (abs[len(abs) - len(rel) - 1] == '/' || abs[len(abs) - len(rel) - 1] == '\\')
}

// Forget the current list on the next refresh (file created / deleted /
// renamed by the editor, workspace changed).
ws_index_invalidate :: proc() { ws_index.dirty = true }

// Starts a rebuild when the list is missing, stale, invalidated, built for
// another folder or with another ignored-files setting. Cheap to call every
// frame. Main thread.
ws_index_refresh :: proc(include_ignored: bool) {
	ws_index_update()
	if ws_index.building { return }
	cwd, _ := os.get_working_directory(context.temp_allocator)
	sync.mutex_lock(&ws_index.mu)
	have := ws_index.cur != nil
	sync.mutex_unlock(&ws_index.mu)
	moved := cwd != ws_index.cwd
	if have && !moved && !ws_index.dirty && include_ignored == ws_index.ignored &&
	   time.tick_since(ws_index.built_at) < WS_INDEX_MAX_AGE {
		return
	}
	if moved {
		// Another workspace: the old list must not be shown meanwhile
		sync.mutex_lock(&ws_index.mu)
		ws_snapshot_release(ws_index.cur)
		ws_index.cur = nil
		ws_index.gen += 1
		sync.mutex_unlock(&ws_index.mu)
		delete(ws_index.cwd)
		ws_index.cwd = strings.clone(cwd)
	}
	ws_index.dirty    = false
	ws_index.ignored  = include_ignored
	ws_index.building = true
	sync.atomic_store(&ws_index.done, false)
	sync.atomic_store(&ws_index.stop, false)
	ws_index.t = thread.create_and_start_with_poly_data(include_ignored, _ws_index_worker, context)
}

// Joins a finished build. Main thread, every frame (ws_index_refresh calls it).
ws_index_update :: proc() {
	if !ws_index.building || !sync.atomic_load(&ws_index.done) { return }
	thread.join(ws_index.t)
	thread.destroy(ws_index.t)
	ws_index.t        = nil
	ws_index.building = false
	ws_index.built_at = time.tick_now()
}

ws_index_shutdown :: proc() {
	if ws_index.t != nil {
		sync.atomic_store(&ws_index.stop, true)
		thread.join(ws_index.t)
		thread.destroy(ws_index.t)
		ws_index.t = nil
	}
	ws_index.building = false
	sync.mutex_lock(&ws_index.mu)
	ws_snapshot_release(ws_index.cur)
	ws_index.cur = nil
	sync.mutex_unlock(&ws_index.mu)
	delete(ws_index.cwd)
	ws_index.cwd = ""
}

@(private="file")
_ws_index_worker :: proc(include_ignored: bool) {
	defer {
		sync.atomic_store(&ws_index.done, true)
		wake.request()
	}
	t0 := time.tick_now()
	snap := ws_index_build(".", include_ignored, &ws_index.stop)
	if snap == nil { return }
	snap.build_ms = time.duration_milliseconds(time.tick_since(t0))
	sync.mutex_lock(&ws_index.mu)
	old := ws_index.cur
	ws_index.cur = snap
	ws_index.gen += 1
	sync.mutex_unlock(&ws_index.mu)
	ws_snapshot_release(old)
}

// Builds a snapshot of `dir` (refs = 1). nil when stopped.
ws_index_build :: proc(dir: string, include_ignored: bool, stop: ^bool = nil) -> ^Ws_Snapshot {
	args := make([dynamic]string, context.temp_allocator)
	append(&args, "ls-files", "-z", "-c", "-o", "--deduplicate")
	if !include_ignored { append(&args, "--exclude-standard") }
	if out, ok := git.git_run(dir, args[:]); ok {
		snap := new(Ws_Snapshot)
		snap.refs, snap.blob, snap.from_git = 1, out, true
		files := make([dynamic]string, 0, strings.count(out, "\x00"))
		rest := out
		for len(rest) > 0 {
			i := strings.index_byte(rest, 0)
			if i < 0 { i = len(rest) }
			f := rest[:i]
			rest = rest[min(i + 1, len(rest)):]
			if f == "" || (include_ignored && ws_path_in_skipped_dir(f)) { continue }
			append(&files, f)
		}
		snap.files = files[:]
		return snap
	}
	if stop != nil && sync.atomic_load(stop) { return nil }
	files := make([dynamic]string)
	fast_walk_files(dir, &files, stop)
	if stop != nil && sync.atomic_load(stop) {
		for f in files { delete(f) }
		delete(files)
		return nil
	}
	snap := new(Ws_Snapshot)
	snap.refs, snap.owned = 1, true
	snap.files = files[:]
	return snap
}

// "a/node_modules/x.js" → true: some folder on the path is one searches skip.
ws_path_in_skipped_dir :: proc(path: string) -> bool {
	rest := path
	for {
		i := strings.index_byte(rest, '/')
		if i < 0 { return false }
		if ws_is_skipped_dir(rest[:i]) { return true }
		rest = rest[i + 1:]
	}
}

// Last path segment ("a/b/c.go" → "c.go").
ws_basename :: proc(path: string) -> string {
	i := strings.last_index_byte(path, '/')
	return path[i + 1:] if i >= 0 else path
}
