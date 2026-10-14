package editor

// ===========================================================================
// Benchmark instrumentation — ADR 0016, docs/benchmark.md.
// Compiled in only with `-define:BENCH=true`; otherwise every proc is empty.
//
//   BENCH first_frame since_main_ms=<main() → end of first EndDrawing>
//                     wall_ms=<unix epoch ms at that moment>
//   BENCH key <unix-ms> render_ms=<input seen → render done (before swap)>
//             frame_ms=<input seen → EndDrawing returned (swap + pacing)>
//   BENCH latency n=.. render_p50=.. render_p95=.. frame_p50=.. frame_p95=..
//   BENCH idle frames=.. sleeps=.. wakes=..          (every 10 s, and at exit)
//
// Env: EDITOR_BENCH_TERMINALS=N opens N shell tabs at startup.
//      EDITOR_BENCH_EVENT_DRIVEN=0 forces the legacy always-render loop.
//      EDITOR_BENCH_KEYS=N injects N synthetic keystrokes (see below).
//      EDITOR_BENCH_TRACE=1 prints the wait decision after every frame.
//
// Synthetic keystrokes (no way to inject real key events into the window
// without Accessibility permissions): a helper thread, every ~250 ms, stamps
// rl.GetTime() and calls wake.request() — exactly the path an OS key event
// takes to wake a sleeping loop. The next frame inserts (or deletes) one
// character in the active pane like typing does and the time from the stamp
// to EndDrawing returning is recorded:
//   BENCH synth n=.. p50=.. p95=.. max=..   (ms)
// ===========================================================================

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:sync"
import "core:thread"
import "core:time"
import rl "vendor:raylib"
import "./wake"

BENCH :: #config(BENCH, false)

@(private="file") _bench_main:    time.Tick
@(private="file") _bench_first:   bool
@(private="file") _bench_render:  [dynamic]f64
@(private="file") _bench_frame:   [dynamic]f64
@(private="file") _bench_pending: f64 // render-done ms for the current input frame (-1 = none)
@(private="file") _bench_report:  f64
@(private="file") _bench_keys:    int
@(private="file") _bench_post:    f64  // synthetic key stamp (written by the helper thread)
@(private="file") _bench_posted:  bool // atomic: a synthetic key waits for the main loop
@(private="file") _bench_synth_t: f64  // stamp being measured this frame (0 = none)
@(private="file") _bench_synth:   [dynamic]f64
@(private="file") _bench_ins:     bool
@(private="file") _bench_thread:  ^thread.Thread
@(private="file") _bench_quit:    bool

// Top of main().
bench_mark_main :: proc() {
	when BENCH { _bench_main = time.tick_now() }
}

// After the window and the editor exist.
bench_start :: proc(e: ^Editor) {
	when BENCH {
		_bench_pending = -1
		if v := os.get_env("EDITOR_BENCH_TERMINALS", context.temp_allocator); v != "" {
			if n, ok := strconv.parse_int(v); ok && n > 0 {
				got := terminal_panel_open_tabs(e, n)
				fmt.eprintfln("BENCH terminals=%d", got)
			}
		}
		if os.get_env("EDITOR_BENCH_EVENT_DRIVEN", context.temp_allocator) == "0" {
			frame_pacing.enabled = false
			fmt.eprintln("BENCH event_driven=false")
		}
		if v := os.get_env("EDITOR_BENCH_KEYS", context.temp_allocator); v != "" {
			if n, ok := strconv.parse_int(v); ok && n > 0 {
				_bench_keys = n
				_bench_thread = thread.create_and_start(_bench_key_thread)
			}
		}
	}
}

@(private="file")
_bench_key_thread :: proc() {
	time.sleep(4 * time.Second) // let startup settle (LSP, git, first frames)
	for i in 0 ..< _bench_keys {
		if sync.atomic_load(&_bench_quit) { return }
		time.sleep(time.Duration(230 + (i * 37) % 60) * time.Millisecond)
		for sync.atomic_load(&_bench_posted) { time.sleep(time.Millisecond) }
		sync.atomic_store(&_bench_post, rl.GetTime()) // glfwGetTime: thread-safe
		sync.atomic_store(&_bench_posted, true)
		wake.request()
	}
}

// Top of the frame, before handle_input: apply a pending synthetic key.
bench_inject :: proc(e: ^Editor) {
	when BENCH {
		_bench_synth_t = 0
		if !sync.atomic_load(&_bench_posted) { return }
		_bench_synth_t = sync.atomic_load(&_bench_post)
		p := active_pane(e)
		if _bench_ins {
			if p.cursor > 0 {
				buffer_delete(&p.buf, p.cursor - 1, 1)
				p.cursor -= 1
			}
		} else {
			buffer_insert_byte(&p.buf, p.cursor, 'x')
			p.cursor += 1
		}
		_bench_ins = !_bench_ins
		p.sel_anchor = p.cursor
		p.dirty = true
		lsp_on_text_changed(e, p) // what typing does (didChange debounce)
	}
}

// Right before EndDrawing (render work done, not yet swapped).
bench_render_done :: proc() {
	when BENCH {
		// Key-press frames only (not mouse motion / held keys); checked before
		// EndDrawing, whose input poll resets the "pressed" state.
		if frame_pacing.input_t > 0 && _bench_key_frame() { _bench_pending = (rl.GetTime() - frame_pacing.input_t) * 1000 }
	}
}

// Right after EndDrawing.
bench_frame_end :: proc() {
	when BENCH {
		now := rl.GetTime()
		if !_bench_first {
			_bench_first = true
			fmt.eprintfln("BENCH first_frame since_main_ms=%.1f wall_ms=%d",
				time.duration_milliseconds(time.tick_since(_bench_main)), time.now()._nsec / 1e6)
			_bench_report = now
		}
		if _bench_pending >= 0 && frame_pacing.input_t > 0 {
			f := (now - frame_pacing.input_t) * 1000
			append(&_bench_render, _bench_pending)
			append(&_bench_frame, f)
			fmt.eprintfln("BENCH key %d render_ms=%.3f frame_ms=%.3f", time.now()._nsec / 1e6, _bench_pending, f)
		}
		_bench_pending = -1
		if _bench_synth_t > 0 {
			append(&_bench_synth, (now - _bench_synth_t) * 1000)
			_bench_synth_t = 0
			sync.atomic_store(&_bench_posted, false)
			if len(_bench_synth) == _bench_keys { bench_print_summary() }
		}
		if now - _bench_report >= 10 {
			_bench_report = now
			bench_print_summary()
		}
	}
}

@(private="file")
_bench_key_frame :: proc() -> bool {
	for k in 32 ..= 348 { if rl.IsKeyPressed(rl.KeyboardKey(k)) { return true } }
	return false
}

bench_trace :: proc(wi: Frame_Wait_Inputs) {
	when BENCH {
		@(static) on := -1
		if on < 0 { on = 1 if os.get_env("EDITOR_BENCH_TRACE", context.temp_allocator) != "" else 0 }
		if on == 1 { fmt.eprintln("TRACE", rl.GetTime(), wi, frame_wait_policy(wi)) }
	}
}

bench_print_summary :: proc() {
	when BENCH {
		fmt.eprintfln("BENCH idle frames=%d sleeps=%d wakes=%d", frame_pacing.frames, frame_pacing.sleeps, wake.requests())
		pct :: proc(a: []f64, p: f64) -> f64 { return a[min(len(a) - 1, int(p * f64(len(a) - 1) + 0.5))] }
		if len(_bench_synth) > 0 {
			s := slice.clone(_bench_synth[:], context.temp_allocator)
			slice.sort(s)
			fmt.eprintfln("BENCH synth n=%d p50=%.3f p95=%.3f max=%.3f", len(s), pct(s, 0.5), pct(s, 0.95), s[len(s) - 1])
		}
		n := len(_bench_render)
		if n == 0 { return }
		r := slice.clone(_bench_render[:], context.temp_allocator)
		f := slice.clone(_bench_frame[:], context.temp_allocator)
		slice.sort(r); slice.sort(f)
		fmt.eprintfln("BENCH latency n=%d render_p50=%.3f render_p95=%.3f frame_p50=%.3f frame_p95=%.3f",
			n, pct(r, 0.5), pct(r, 0.95), pct(f, 0.5), pct(f, 0.95))
	}
}

bench_shutdown :: proc() {
	when BENCH {
		bench_print_summary()
		if _bench_thread != nil {
			sync.atomic_store(&_bench_quit, true)
			sync.atomic_store(&_bench_posted, false)
			thread.join(_bench_thread); thread.destroy(_bench_thread)
		}
		delete(_bench_render); delete(_bench_frame); delete(_bench_synth)
	}
}
