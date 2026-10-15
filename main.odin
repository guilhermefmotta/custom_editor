package editor

import "core:math"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sys/posix"
import rl "vendor:raylib"

// Directory the editor was started from: relative font paths resolve against
// it, since the cwd follows the active repository (ADR 0014).
launch_dir: string

// Relative path → launch_dir/path (temp); absolute paths unchanged.
_launch_path :: proc(p: string) -> string {
	if p == "" || launch_dir == "" || p[0] == '/' || (len(p) > 1 && p[1] == ':') { return p }
	return strings.concatenate({launch_dir, "/", p}, context.temp_allocator)
}

FONT_PATHS :: []string{
	"font/ttf/FiraCode-Regular.ttf",
	"JetBrainsMono.ttf",
	"JetBrainsMonoNL-Regular.ttf",
	"/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
	"/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
	"/System/Library/Fonts/Menlo.ttc",
	"C:/Windows/Fonts/consola.ttf",
}

when ODIN_OS != .Windows {
	platform_hide_console :: proc() {} // no-op on non-Windows
}

main :: proc() {
	bench_mark_main() // -define:BENCH=true only (bench.odin)
	elog_init()
	defer elog_close()
	// Paths captured before any repository switch changes the cwd (ADR 0014).
	session_init_path()
	if cwd, err := os.get_working_directory(context.allocator); err == nil { launch_dir = cwd }
	defer delete(launch_dir)
	context.assertion_failure_proc = elog_assertion_failure_proc

	// A dropped TCP debug-adapter connection (DAP or JDWP) makes the debug
	// transport's write thread call write() on a socket the peer already
	// closed. The default SIGPIPE disposition kills the whole process, not
	// just that thread — ignore it so a dead debug connection surfaces as a
	// normal EPIPE write error instead of crashing the editor.
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)

	platform_hide_console() // hides console window on Windows (FreeConsole)
	rl.SetTraceLogLevel(.WARNING)

	flags: rl.ConfigFlags = {.WINDOW_RESIZABLE, .MSAA_4X_HINT}
	// Retina: render at the display's real pixel density instead of 1x
	// upscaled by macOS (which made everything blurry)
	// macOS only. On Windows raylib's WINDOW_HIGHDPI reports the window size
	// already multiplied by the display scale without scaling the drawing, so
	// at 125% everything came out small and dialogs off-center. Text size on
	// Windows is set with the font zoom (Ctrl + = / -) instead.
	when ODIN_OS == .Darwin { flags += {.WINDOW_HIGHDPI} }
	rl.SetConfigFlags(flags)
	rl.InitWindow(1280, 720, "editor")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60) // re-set from editor.toml [window] fps_target below
	rl.SetExitKey(.KEY_NULL) // disable ESC closing window — handled by dialogs

	font_px := font_pixel_size()
	font_gen := settings_font_gen
	font, custom := load_font(font_px)
	defer if custom do rl.UnloadFont(font)

	e := editor_init()
	e.palette.marks = &e.marks  // fix up pointer: editor_init returns by value, so &e.marks inside it was dangling
	defer editor_destroy(&e)

	e.repos.live = true
	recent_repos_load(&e.recent_repos, recent_repos_default_path())

	// Folders given on the command line open as repository tabs (files open
	// in the editor, inside their repository); no args → last session.
	if len(os.args) > 1 {
		dirs := make([dynamic]string, context.temp_allocator)
		for a in os.args[1:] {
			if os.is_dir(a) { append(&dirs, a) } else { editor_open(&e, a) }
		}
		if len(dirs) > 0 {
			if _, err := repos_open_many(&e, dirs[:]); err != "" { ui_banner_show(err, .Error, 8) }
		}
	} else {
		// Start idle on the welcome screen (open / clone / init / recents):
		// nothing opens on its own, not even the working directory. The last
		// session's tabs come back when each repository is opened again.
		session_load_views(&e)
	}

	editor_lsp_init(&e)
	// Files given on the command line open inside their repository. Without
	// arguments nothing opens on its own (not even the working directory's
	// repository): the welcome screen is the starting point.
	if len(os.args) > 1 { editor_git_init(&e) }
	if len(os.args) > 1 {
		lsp_on_open(&e, active_pane(&e))
	}

	// Event-driven render (ADR 0016): render at fps_target while something
	// moves, sleep until an event / thread wake / deadline otherwise.
	fps := e.cfg.window.fps_target if e.cfg.window.fps_target > 0 else 60
	rl.SetTargetFPS(i32(fps))
	frame_pacing.enabled = e.cfg.window.event_driven
	frame_pacing_init()
	defer frame_pacing_shutdown() // before CloseWindow (defers run LIFO)
	bench_start(&e)
	defer bench_shutdown()

	for !rl.WindowShouldClose() && !e.should_quit {
		frame_begin()
		dt := frame_dt

		// Zoom (Ctrl+= / Ctrl+-) or moving to a display with another scale:
		// rebuild the glyph atlas at the new pixel size so text stays 1:1 sharp
		// (also when the settings screen picks another font file)
		if px := font_pixel_size(); px != font_px || font_gen != settings_font_gen {
			if custom do rl.UnloadFont(font)
			font, custom = load_font(px)
			font_px = px
			font_gen = settings_font_gen
		}

		repos_handle_drop(&e) // folders dropped on the window → repo tabs
		bench_inject(&e)      // -define:BENCH=true only
		handle_input(&e, font)
		lsp_update(&e, dt)
		git_update(&e, dt)

		rl.BeginDrawing()
		render(&e, font)
		bench_render_done()
		rl.EndDrawing()
		bench_frame_end()

		mem.free_all(context.temp_allocator)

		if frame_pacing.enabled {
			wi := frame_collect(&e)
			bench_trace(wi) // EDITOR_BENCH_TRACE=1: why each frame was drawn
			frame_wait(frame_wait_policy(wi))
		}
	}

	session_save(&e)
}

// Pixel size of the glyph atlas: the logical FONT_SIZE times the display scale
// (2 on Retina), so glyphs are rasterized at exactly the size they're drawn.
font_pixel_size :: proc() -> i32 {
	scale := rl.GetWindowScaleDPI().x
	if scale < 1 { scale = 1 }
	return i32(math.round(FONT_SIZE * scale))
}

load_font :: proc(pixel_size: i32) -> (font: rl.Font, custom: bool) {
	// ASCII 32-126 (95)
	// Latin-1 Supplement 0xA0-0xFF (96) — covers most European accented chars
	// Latin Extended-A 0x100-0x17F (128) — covers remaining common accents
	// UI symbols (4)
	NUM_CP :: 95 + 96 + 128 + 4
	cps: [NUM_CP]rune
	i := 0
	for c := rune(32); c <= 126; c += 1 { cps[i] = c; i += 1 }
	for c := rune(0xA0); c <= 0xFF; c += 1 { cps[i] = c; i += 1 }
	for c := rune(0x100); c <= 0x17F; c += 1 { cps[i] = c; i += 1 }
	cps[i] = 0x2191; i += 1 // ↑
	cps[i] = 0x2193; i += 1 // ↓
	cps[i] = 0x2261; i += 1 // ≡
	cps[i] = 0x229E; i += 1 // ⊞

	// settings_font_path (settings_panel.odin) first, then the built-in list
	for path, i in FONT_PATHS {
		if i == 0 && settings_font_path != "" {
			f := rl.LoadFontEx(to_cstring(_launch_path(settings_font_path)), pixel_size, raw_data(cps[:]), NUM_CP)
			if f.glyphCount > 0 {
				rl.SetTextureFilter(f.texture, .BILINEAR)
				return f, true
			}
		}
		f := rl.LoadFontEx(to_cstring(_launch_path(path)), pixel_size, raw_data(cps[:]), NUM_CP)
		if f.glyphCount > 0 {
			rl.SetTextureFilter(f.texture, .BILINEAR)
			return f, true
		}
	}
	return rl.GetFontDefault(), false
}
