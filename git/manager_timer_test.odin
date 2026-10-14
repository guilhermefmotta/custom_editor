package git

import "base:runtime"
import "core:sync"
import "core:testing"
import "core:time"
import "../wake"

// features/event-driven-render.feature (ADR 0016):
// # teste: refresh de git dispara com dt grande depois de dormir e acorda o loop
@(test)
test_manager_refresh_after_sleep :: proc(t: ^testing.T) {
	// The refresh thread runs with the default (heap) context: keep the
	// manager's state on that allocator so the tracker sees matching frees.
	context.allocator = runtime.heap_allocator()
	dir := _trepo_new(t, "fp-timer")
	defer _trepo_destroy(dir)
	_tcommit(t, dir, "a.txt", "a\n", "init") // temp-allocated hash

	m: Git_Manager
	git_manager_init(&m, dir)
	defer git_manager_destroy(&m)

	before := wake.requests()
	git_manager_update_status(&m, 0.016) // timer 0 → first refresh
	testing.expect(t, m.refresh_thread != nil)
	_wait_ready(t, &m)
	testing.expect(t, wake.requests() > before, "refresh thread wakes the UI loop")

	git_manager_update_status(&m, 0.016) // swap; timer re-armed
	testing.expect(t, m.refresh_thread == nil)
	testing.expect(t, m.timer > 3.9)

	git_manager_update_status(&m, 1) // normal frame, not due
	testing.expect(t, m.refresh_thread == nil)

	git_manager_update_status(&m, 30) // first frame after sleeping 30 s
	testing.expect(t, m.refresh_thread != nil, "overdue refresh starts at once")
	_wait_ready(t, &m)
	git_manager_update_status(&m, 0.016)
}

@(private="file")
_wait_ready :: proc(t: ^testing.T, m: ^Git_Manager) {
	for _ in 0 ..< 500 {
		sync.mutex_lock(&m.mu)
		ok := m.pending_ready
		sync.mutex_unlock(&m.mu)
		if ok { return }
		time.sleep(10 * time.Millisecond)
	}
	testing.fail_now(t, "refresh did not finish")
}
