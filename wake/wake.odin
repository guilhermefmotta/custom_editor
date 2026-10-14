package wake

// ===========================================================================
// Thread-safe "wake the UI loop" signal — ADR 0016 (event-driven render).
//
// The main loop sleeps (glfwWaitEventsTimeout) while nothing is animating.
// Any worker thread that produced something the UI must show (git job done,
// LSP message, terminal output, search/forge result...) calls `request()`:
//
//   - sets an atomic "pending" flag (the main loop consumes it with `take()`
//     once per frame and renders at least one more frame);
//   - on the false→true transition only, calls the poster installed by the
//     main loop (glfwPostEmptyEvent), which makes the blocking wait return.
//     A flood of requests (e.g. `cat bigfile` in a terminal) thus posts at
//     most one empty event per frame.
//
// No poster installed (tests, before the window exists, after it closes) →
// only the flag is set. This package has no dependency on raylib/GLFW so the
// subpackages (git, lsp, terminal, forge, debug) and their tests can use it.
// ===========================================================================

import "base:intrinsics"

Poster :: #type proc "c" ()

@(private) _pending: bool
@(private) _poster:  Poster
@(private) _count:   u64 // total requests (diagnostics / tests)

// Any thread. Cheap: one atomic exchange; posts only when the flag was clear.
request :: proc "contextless" () {
	intrinsics.atomic_add(&_count, 1)
	if intrinsics.atomic_exchange(&_pending, true) { return }
	if p := intrinsics.atomic_load(&_poster); p != nil { p() }
}

// Main loop: consumes the flag. true = someone asked for a frame since the last take.
take :: proc "contextless" () -> bool {
	return intrinsics.atomic_exchange(&_pending, false)
}

// Main loop: looks without consuming (decides whether to sleep at all).
peek :: proc "contextless" () -> bool {
	return intrinsics.atomic_load(&_pending)
}

// Main loop: installs (or clears with nil) the proc that interrupts the
// blocking wait. Clear it before the window is destroyed.
set_poster :: proc "contextless" (p: Poster) {
	intrinsics.atomic_store(&_poster, p)
}

requests :: proc "contextless" () -> u64 {
	return intrinsics.atomic_load(&_count)
}
