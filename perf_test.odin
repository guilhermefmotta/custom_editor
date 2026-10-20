package editor

// Large-workspace performance probe (docs/perf-large-repos.md). Skipped
// unless EDITOR_PERF_REPO points at a big checkout, e.g.
//
//   EDITOR_PERF_REPO=/path/to/monorepo odin test . -define:ODIN_TEST_NAMES=editor.test_perf_large_repo
//
// Prints the main-thread cost per frame (max step) and the total time of
// each search the UI runs, so changes can be compared before/after.

import "core:fmt"
import "core:os"
import "core:sync"
import "core:testing"
import "core:time"

@(private="file")
_ms :: proc(d: time.Duration) -> f64 { return time.duration_milliseconds(d) }

@(test)
test_perf_large_repo :: proc(t: ^testing.T) {
	repo := os.get_env("EDITOR_PERF_REPO", context.temp_allocator)
	if repo == "" { return }
	old, _ := os.get_working_directory(context.temp_allocator)
	_ = os.set_working_directory(repo)
	defer os.set_working_directory(old)

	// Workspace index (worker thread) — what every search reads
	{
		t0 := time.tick_now()
		ws_index_invalidate()
		ws_index_refresh(false)
		for ws_index_building() {
			time.sleep(2 * time.Millisecond)
			ws_index_update()
		}
		snap, _ := ws_index_get()
		defer ws_snapshot_release(snap)
		fmt.printfln("PERF index files=%d from_git=%v build_ms=%.0f wall_ms=%.0f",
			len(snap.files) if snap != nil else 0, snap != nil && snap.from_git,
			snap.build_ms if snap != nil else 0, _ms(time.tick_since(t0)))
	}

	// Ctrl+P: filter stepped once per frame (index already built)
	{
		pf: Pal_Files
		pf.gen = -1
		defer pal_files_destroy(&pf)
		t0 := time.tick_now()
		max_step: f64
		frames := 0
		for !pf.done {
			s := time.tick_now()
			pal_files_step(&pf, "file042", false)
			max_step = max(max_step, _ms(time.tick_since(s)))
			frames += 1
		}
		fmt.printfln("PERF quick_open files=%d frames=%d max_frame_ms=%.1f total_ms=%.0f matches=%d",
			len(pf.snap.files), frames, max_step, _ms(time.tick_since(t0)), pal_files_count(&pf))
	}

	// File tree: root listing + recursive name filter
	{
		ft := file_tree_init()
		defer file_tree_destroy(&ft)
		s := time.tick_now()
		file_tree_open(&ft)
		open_ms := _ms(time.tick_since(s))
		for c in "file042" { append(&ft.filter, u8(c)) }
		t0 := time.tick_now()
		_ft_rebuild_search(&ft)
		max_step: f64
		frames := 0
		for ft.search_active {
			s2 := time.tick_now()
			_ft_search_step(&ft)
			max_step = max(max_step, _ms(time.tick_since(s2)))
			frames += 1
		}
		fmt.printfln("PERF tree open_ms=%.1f filter_frames=%d max_frame_ms=%.1f total_ms=%.0f results=%d",
			open_ms, frames, max_step, _ms(time.tick_since(t0)), len(ft.results))
	}

	// Text search (worker thread), each engine
	for builtin in ([]bool{false, true}) {
		search_disable_ripgrep = builtin
		defer search_disable_ripgrep = false
		st := search_state_init()
		defer search_state_destroy(&st)
		t0 := time.tick_now()
		search_start(&st, "NEEDLE_UNIQUE_TOKEN")
		for {
			sync.mutex_lock(&st.mu)
			done := st.phase == .Done
			sync.mutex_unlock(&st.mu)
			if done { break }
			time.sleep(5 * time.Millisecond)
		}
		fmt.printfln("PERF text_search engine=%v total_ms=%.0f files=%d results=%d",
			st.engine, _ms(time.tick_since(t0)), st.n_files, len(st.results))

		// Cancelling a search that is still running (typing a new query)
		search_start(&st, "e")
		time.sleep(50 * time.Millisecond)
		s := time.tick_now()
		search_start(&st, "")
		fmt.printfln("PERF text_search_cancel engine=%v stop_ms=%.1f", st.engine, _ms(time.tick_since(s)))
	}
	ws_index_shutdown()
}
