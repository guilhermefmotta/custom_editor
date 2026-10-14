package editor

// features/event-driven-render.feature — pure parts of the event-driven loop
// (ADR 0016). The raylib glue (glfwWaitEventsTimeout, input detection) is
// covered by the benchmark (docs/benchmark.md) and manual testing.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:sync"
import "core:testing"
import conf "./config"
import git  "./git"

// frame_pacing is a global: tests that touch it run one at a time.
@(private="file") _fp_mu: sync.Mutex

// # teste: parado sem nada pendente dorme até chegar evento
// # teste: animando / thread acordou / logo após input renderiza direto
// # teste: deadline vira timeout
@(test)
test_frame_wait_policy :: proc(t: ^testing.T) {
	idle := Frame_Wait_Inputs{since_input = 60, next_in = FRAME_NO_DEADLINE}

	w := frame_wait_policy(idle)
	testing.expect(t, w.wait, "idle → sleep")
	testing.expect(t, w.timeout < 0, "no deadline → until an event")

	a := idle; a.animating = true
	testing.expect(t, !frame_wait_policy(a).wait, "animating (scroll, dirty terminal, jobs) → render")

	k := idle; k.woken = true
	testing.expect(t, !frame_wait_policy(k).wait, "thread woke us mid-frame → render again")

	i := idle; i.since_input = 0.2
	testing.expect(t, !frame_wait_policy(i).wait, "typing/scrolling → full rate")
	i.since_input = FRAME_INPUT_GRACE + 0.01
	testing.expect(t, frame_wait_policy(i).wait, "grace over → sleep")

	d := idle; d.next_in = 0.25 // Claude poll
	w = frame_wait_policy(d)
	testing.expect(t, w.wait)
	testing.expect_value(t, w.timeout, 0.25)

	d.next_in = 0.0005 // deadline already due
	testing.expect(t, !frame_wait_policy(d).wait)
}

// # teste: cursor piscando acorda só nas transições
@(test)
test_cursor_blink :: proc(t: ^testing.T) {
	// Off → always visible, never wakes.
	v, n := cursor_blink(false, 1, 0.3)
	testing.expect(t, v)
	testing.expect_value(t, n, FRAME_NO_DEADLINE)

	// 1 Hz → 0.5 s on, 0.5 s off, anchored at the last input.
	v, n = cursor_blink(true, 1, 0.1)
	testing.expect(t, v)
	testing.expect(t, abs(n - 0.4) < 1e-9, fmt.tprint(n))
	v, n = cursor_blink(true, 1, 0.75)
	testing.expect(t, !v)
	testing.expect(t, abs(n - 0.25) < 1e-9, fmt.tprint(n))

	// Idle long enough → solid, no more wake-ups.
	v, n = cursor_blink(true, 1, FRAME_BLINK_IDLE_STOP + 3)
	testing.expect(t, v)
	testing.expect_value(t, n, FRAME_NO_DEADLINE)
	// Last "off" phase before the stop → wake once to come back solid.
	v, n = cursor_blink(true, 1, FRAME_BLINK_IDLE_STOP - 0.2)
	testing.expect(t, !v)
	testing.expect(t, abs(n - 0.2) < 1e-9, fmt.tprint(n))
	// "On" phase whose next change would be the stop itself → no wake at all.
	v, n = cursor_blink(true, 0.33, FRAME_BLINK_IDLE_STOP - 0.5) // on 9.09–10.6 s
	testing.expect(t, v, fmt.tprint(v))
	testing.expect_value(t, n, FRAME_NO_DEADLINE)
}

@(test)
test_frame_request_keeps_nearest :: proc(t: ^testing.T) {
	sync.mutex_lock(&_fp_mu); defer sync.mutex_unlock(&_fp_mu)
	saved := frame_pacing
	defer frame_pacing = saved
	frame_pacing.next_in = FRAME_NO_DEADLINE
	frame_pacing.anim = false
	frame_request_in(4)
	frame_request_in(0.25)
	frame_request_in(15)
	frame_request_in(-1) // overdue → clamped to "now"
	testing.expect_value(t, frame_pacing.next_in, 0.0)
	frame_request_anim()
	testing.expect(t, frame_pacing.anim)
}

// # teste: timers avançam com dt grande depois de dormir (banner)
@(test)
test_banner_expires_after_sleep :: proc(t: ^testing.T) {
	b: Ui_Banner
	ui_banner_set(&b, "Pushed", .Success, 4, 100)
	ui_banner_update(&b, 101) // a normal frame
	testing.expect(t, b.visible)
	ui_banner_update(&b, 100 + 4 + 30) // first frame after sleeping 30 s
	testing.expect(t, !b.visible)
}

// # teste: timers avançam com dt grande depois de dormir (auto save)
@(test)
test_autosave_after_sleep :: proc(t: ^testing.T) {
	sync.mutex_lock(&_settings_globals_mu); defer sync.mutex_unlock(&_settings_globals_mu)
	sync.mutex_lock(&_fp_mu); defer sync.mutex_unlock(&_fp_mu)
	saved_fp := frame_pacing
	defer frame_pacing = saved_fp
	saved_font := FONT_SIZE
	defer FONT_SIZE = saved_font

	base := os.get_env("TMPDIR", context.temp_allocator)
	if base == "" { base = os.get_env("TEMP", context.temp_allocator) }
	if base == "" { base = "." }
	path, _ := filepath.join({base, fmt.tprintf("editor_fp_autosave_%d.txt", os.get_pid())}, context.temp_allocator)
	defer os.remove(path)

	mgr: git.Git_Manager
	defer delete(mgr.blame_cache)
	e: Editor
	e.git_mgr = &mgr
	e.cfg = conf.config_defaults()
	defer conf.config_destroy(&e.cfg)
	e.cfg.editor.auto_save = true
	e.cfg.editor.auto_save_delay = 1.0
	e.panes = make([dynamic]Pane)
	append(&e.panes, pane_init())
	defer { for &p in e.panes { pane_destroy(&p) }; delete(e.panes) }
	defer { delete(settings_font_path); settings_font_path = "" }

	p := &e.panes[0]
	p.filename = fmt.aprintf("%s", path)
	buffer_insert_string(&p.buf, 0, "hello")
	p.cursor = 5
	p.dirty = true

	settings_panel_update(&e, 0.016) // edit seen: idle restarts
	frame_pacing.next_in = FRAME_NO_DEADLINE
	settings_panel_update(&e, 0.016) // idle, not due yet → asks for a frame at the deadline
	testing.expect(t, p.dirty)
	testing.expect(t, frame_pacing.next_in > 0.9 && frame_pacing.next_in < 1.0, fmt.tprint(frame_pacing.next_in))

	settings_panel_update(&e, 45) // first frame after a long sleep
	testing.expect(t, !p.dirty, "saved on the first frame after waking")
	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, err == nil && string(data) == "hello")
}
