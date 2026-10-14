package editor

// ===========================================================================
// Event-driven render loop — ADR 0016.
//
// The main loop renders at the target fps only while something is moving;
// otherwise it sleeps in glfwWaitEventsTimeout until an OS event (key, mouse,
// resize, focus), a worker thread's wake.request() (glfwPostEmptyEvent) or
// the nearest scheduled deadline.
//
// Per frame (main thread only), code that needs more frames says so:
//   frame_request_anim()       — "render the next frame too" (smooth scroll,
//                                 spinners, streaming results)
//   frame_request_in(seconds)  — "I need a frame within N seconds" (timers:
//                                 git refresh, Claude status poll, auto save,
//                                 banner expiry, cursor blink)
// Requests are cleared at the start of every frame, so a subsystem keeps
// asking for as long as it needs it. After the frame, frame_wait_policy
// (pure, tested) turns everything into "render again" / "sleep N s" /
// "sleep until an event".
//
// Timers keep working while asleep because `frame_dt` is the real wall time
// since the previous frame (the sleep included): a 4 s timer that slept 4 s
// fires on the first frame after waking. Animations use `frame_anim_dt`
// (clamped) so a scroll that starts right after a long sleep still eases in
// instead of jumping.
// ===========================================================================

import "core:math"
import "core:sync"
import rl   "vendor:raylib"
import git  "./git"
import "./wake"

// GLFW lives inside libraylib (rglfw.c is compiled into it, symbols exported:
// `nm libraylib.a | grep glfwPostEmptyEvent`). Declaring the procs without a
// library binds them to that same copy — no second GLFW, same event queue.
@(default_calling_convention="c")
foreign {
	glfwPostEmptyEvent    :: proc() ---
	glfwWaitEventsTimeout :: proc(timeout: f64) ---
	glfwWaitEvents        :: proc() ---
}

// Keep rendering continuously this long after the last user input: covers
// the short UI debounces (LSP change/hover 0.3/0.5 s, double-click windows,
// palette/graph search debounce) without every one of them scheduling a
// deadline, and keeps typing/scrolling at full rate.
FRAME_INPUT_GRACE :: f64(1.0)
// Cursor blink stops (cursor stays solid) this long after the last input,
// so an idle editor does not wake twice per second forever.
FRAME_BLINK_IDLE_STOP :: f64(10.0)
// Animations never advance more than this per frame (s).
FRAME_ANIM_DT_MAX :: f32(1.0 / 30.0)
FRAME_NO_DEADLINE :: math.INF_F64

// Real seconds since the previous frame (sleep included) — timers.
frame_dt: f32 = 1.0 / 60.0
// Same, clamped for animations (smooth scroll, easing).
frame_anim_dt: f32 = 1.0 / 60.0

Frame_Pacing :: struct {
	enabled:     bool, // false = legacy always-render loop
	anim:        bool, // someone asked for the next frame
	next_in:     f64,  // nearest requested deadline, seconds from frame start
	last_input:  f64,  // rl.GetTime() of the last detected user input
	last_frame:  f64,
	frames:      u64,
	sleeps:      u64,
	// BENCH instrumentation (see docs/benchmark.md)
	input_t:     f64,  // time the current frame's input was seen (0 = none)
}

frame_pacing: Frame_Pacing = {enabled = true, next_in = FRAME_NO_DEADLINE}

// Any code on the main thread: render the next frame too.
frame_request_anim :: proc() { frame_pacing.anim = true }

// Any code on the main thread: a frame is needed within `seconds`.
frame_request_in :: proc(seconds: f64) {
	s := max(seconds, 0)
	if s < frame_pacing.next_in { frame_pacing.next_in = s }
}

// ---------------------------------------------------------------------------
// Pure policy
// ---------------------------------------------------------------------------

Frame_Wait_Inputs :: struct {
	animating:   bool, // anim requested / terminal dirty / jobs in flight
	woken:       bool, // a thread asked for a frame after this one started
	since_input: f64,  // seconds since the last user input
	next_in:     f64,  // nearest deadline (FRAME_NO_DEADLINE = none)
}

Frame_Wait :: struct {
	wait:    bool,
	timeout: f64, // < 0 = until an event; only meaningful when wait
}

// Smallest deadline worth sleeping for: below this, just render the next
// frame (the fps cap already paces it).
FRAME_MIN_SLEEP :: f64(0.002)

frame_wait_policy :: proc(in_: Frame_Wait_Inputs) -> Frame_Wait {
	if in_.animating || in_.woken { return {wait = false} }
	if in_.since_input < FRAME_INPUT_GRACE { return {wait = false} }
	if in_.next_in <= FRAME_MIN_SLEEP { return {wait = false} }
	if in_.next_in == FRAME_NO_DEADLINE || math.is_inf(in_.next_in) { return {wait = true, timeout = -1} }
	return {wait = true, timeout = in_.next_in}
}

// Cursor blink, phase anchored at the last input (solid right after typing).
// Returns whether the cursor is drawn now and the seconds until the next
// visibility change (FRAME_NO_DEADLINE = no more changes: blink off, or idle
// for FRAME_BLINK_IDLE_STOP → solid).
cursor_blink :: proc(enabled: bool, rate_hz: f32, since_input: f64) -> (visible: bool, next_in: f64) {
	if !enabled || rate_hz <= 0 || since_input >= FRAME_BLINK_IDLE_STOP || since_input < 0 {
		return true, FRAME_NO_DEADLINE
	}
	half := 0.5 / f64(rate_hz)
	phase := since_input / half
	k := math.floor(phase)
	visible = int(k) % 2 == 0
	next_in = (k + 1) * half - since_input
	stop_in := FRAME_BLINK_IDLE_STOP - since_input
	if stop_in <= next_in {
		// The next change is the stop itself → it only matters if the cursor
		// is hidden now (it must come back solid).
		if visible { return true, FRAME_NO_DEADLINE }
		return false, stop_in
	}
	return
}

// ---------------------------------------------------------------------------
// Main-loop glue (raylib)
// ---------------------------------------------------------------------------

frame_pacing_init :: proc() {
	wake.set_poster(glfwPostEmptyEvent)
	frame_pacing.last_frame = rl.GetTime()
	frame_pacing.last_input = frame_pacing.last_frame
}

frame_pacing_shutdown :: proc() {
	wake.set_poster(nil)
}

// Start of a frame: measure dt, consume wakes, detect input, clear requests.
frame_begin :: proc() {
	now := rl.GetTime()
	dt := now - frame_pacing.last_frame
	frame_pacing.last_frame = now
	frame_dt      = f32(clamp(dt, 0, 3600))
	frame_anim_dt = min(frame_dt, FRAME_ANIM_DT_MAX)
	wake.take()
	frame_pacing.input_t = 0
	if _frame_input_seen() {
		frame_pacing.last_input = now
		frame_pacing.input_t    = now
	}
	frame_pacing.anim    = false
	frame_pacing.next_in = FRAME_NO_DEADLINE
	frame_pacing.frames += 1
}

frame_since_input :: proc() -> f64 { return rl.GetTime() - frame_pacing.last_input }

// User input this frame? (keys down/pressed/released, mouse buttons, motion,
// wheel). Cheap: ~350 table lookups.
@(private="file")
_frame_input_seen :: proc() -> bool {
	if rl.GetMouseWheelMove() != 0 { return true }
	d := rl.GetMouseDelta()
	if d.x != 0 || d.y != 0 { return true }
	for b in rl.MouseButton.LEFT ..= rl.MouseButton.BACK {
		if rl.IsMouseButtonDown(b) || rl.IsMouseButtonReleased(b) { return true }
	}
	for k in 32 ..= 348 {
		key := rl.KeyboardKey(k)
		if rl.IsKeyDown(key) || rl.IsKeyReleased(key) { return true }
	}
	if rl.IsWindowResized() || rl.IsFileDropped() { return true }
	return false
}

// After EndDrawing: everything that keeps the loop awake without a request.
frame_collect :: proc(e: ^Editor) -> Frame_Wait_Inputs {
	busy := frame_pacing.anim
	if !busy && e.git_mgr != nil && e.git_mgr.root != "" {
		busy = git.git_queue_busy(&e.git_mgr.queue) > 0
	}
	if !busy { busy = git.git_queue_busy(&e.repos.ops) > 0 || remote_ops_busy() || e.repos.pending }
	if !busy {
		s := &e.palette.search
		sync.mutex_lock(&s.mu)
		busy = s.phase == .Running
		sync.mutex_unlock(&s.mu)
	}
	// Terminals need nothing here: their reader threads wake.request() on
	// output and the visible tab's snapshot clears `dirty` (hidden tabs stay
	// dirty without needing frames).

	// Git status refresh timers: active repo + background tabs.
	if e.git_mgr != nil && e.git_mgr.root != "" { _frame_git_deadline(e.git_mgr) }
	act := repos_active(e)
	for r in e.repos.list { if r != act { _frame_git_deadline(&r.git) } }

	return Frame_Wait_Inputs{
		animating   = busy,
		woken       = wake.peek(),
		since_input = frame_since_input(),
		next_in     = frame_pacing.next_in,
	}
}

@(private="file")
_frame_git_deadline :: proc(m: ^git.Git_Manager) {
	if m.root == "" || m.refresh_thread != nil { return } // running: its thread wakes us
	frame_request_in(f64(m.timer))
}

// Sleep per the policy. Events that arrive are queued into raylib's input
// state by GLFW's callbacks, exactly as if raylib's own PollInputEvents had
// waited (it already reset the per-frame state in EndDrawing).
frame_wait :: proc(w: Frame_Wait) {
	if !w.wait { return }
	frame_pacing.sleeps += 1
	if w.timeout < 0 { glfwWaitEvents() } else { glfwWaitEventsTimeout(w.timeout) }
}
