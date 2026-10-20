package editor

// Find File (Ctrl+P) over the workspace index (ws_index.odin). Filtering
// runs on the UI thread but under a time budget per frame, so a short query
// over hundreds of thousands of paths streams in over a few frames instead
// of freezing one. When the pass completes, matches whose file name (not
// just the folder) contains the query come first, shorter paths first.

import "core:slice"
import "core:strings"
import "core:time"

PAL_FILES_BUDGET   :: 4 * time.Millisecond
PAL_FILES_SORT_MAX :: 100_000 // bigger result sets keep index order

Pal_Files :: struct {
	snap: ^Ws_Snapshot, // retained
	gen:  int,
	hits: [dynamic]i32, // indices into snap.files
	q:    string,       // heap: query the hits are for
	pos:  int,          // next file to test
	done: bool,
}

pal_files_destroy :: proc(pf: ^Pal_Files) {
	ws_snapshot_release(pf.snap)
	delete(pf.hits)
	delete(pf.q)
	pf^ = {}
}

// Drops the list (workspace switch): the next step takes a fresh snapshot.
pal_files_reset :: proc(pf: ^Pal_Files) {
	ws_snapshot_release(pf.snap)
	pf.snap = nil
	pf.gen  = -1
	clear(&pf.hits)
	pf.pos, pf.done = 0, false
}

// One frame of work: pick up a newer snapshot, restart on a new query,
// test files until the budget runs out.
pal_files_step :: proc(pf: ^Pal_Files, query: string, include_ignored: bool) {
	ws_index_refresh(include_ignored)
	snap, gen := ws_index_get()
	if gen != pf.gen || snap != pf.snap {
		ws_snapshot_release(pf.snap)
		pf.snap, pf.gen = snap, gen
		_pal_files_restart(pf, query)
	} else {
		ws_snapshot_release(snap)
	}
	if query != pf.q { _pal_files_restart(pf, query) }
	if pf.snap == nil || pf.done { return }

	files := pf.snap.files
	deadline := time.tick_now()
	for pf.pos < len(files) {
		if pf.pos & 2047 == 0 && time.tick_since(deadline) > PAL_FILES_BUDGET { return }
		if pal_match(files[pf.pos], query) { append(&pf.hits, i32(pf.pos)) }
		pf.pos += 1
	}
	pf.done = true
	if query != "" && len(pf.hits) <= PAL_FILES_SORT_MAX { pal_files_rank(files, pf.hits[:], query) }
}

@(private="file")
_pal_files_restart :: proc(pf: ^Pal_Files, query: string) {
	delete(pf.q)
	pf.q = strings.clone(query)
	clear(&pf.hits)
	pf.pos, pf.done = 0, false
}

// File-name matches first, then shorter paths, then path order.
pal_files_rank :: proc(files: []string, hits: []i32, query: string) {
	Ctx :: struct { files: []string, q: string }
	ctx := Ctx{files, query}
	context.user_ptr = &ctx
	slice.stable_sort_by(hits, proc(a, b: i32) -> bool {
		c := cast(^Ctx)context.user_ptr
		fa, fb := c.files[a], c.files[b]
		na, nb := pal_match(ws_basename(fa), c.q), pal_match(ws_basename(fb), c.q)
		if na != nb { return na }
		if len(fa) != len(fb) { return len(fa) < len(fb) }
		return fa < fb
	})
}

pal_files_count :: proc(pf: ^Pal_Files) -> int { return len(pf.hits) }

pal_files_at :: proc(pf: ^Pal_Files, i: int) -> string {
	if pf.snap == nil || i < 0 || i >= len(pf.hits) { return "" }
	return pf.snap.files[pf.hits[i]]
}
