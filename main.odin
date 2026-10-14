package editor

import "core:math"
import "core:mem"
import "core:os"
import "core:sys/posix"
import rl "vendor:raylib"

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
	elog_init()
	defer elog_close()
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
	when ODIN_OS == .Darwin { flags += {.WINDOW_HIGHDPI} }
	rl.SetConfigFlags(flags)
	rl.InitWindow(1280, 720, "editor")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)
	rl.SetExitKey(.KEY_NULL) // disable ESC closing window — handled by dialogs

	font_px := font_pixel_size()
	font, custom := load_font(font_px)
	defer if custom do rl.UnloadFont(font)

	e := editor_init()
	e.palette.marks = &e.marks  // fix up pointer: editor_init returns by value, so &e.marks inside it was dangling
	defer editor_destroy(&e)

	if len(os.args) > 1 {
		editor_open(&e, os.args[1])
	} else {
		session_restore(&e)
	}

	editor_lsp_init(&e)
	editor_git_init(&e)
	if len(os.args) > 1 {
		lsp_on_open(&e, active_pane(&e))
	}

	for !rl.WindowShouldClose() && !e.should_quit {
		dt := rl.GetFrameTime()

		// Zoom (Ctrl+= / Ctrl+-) or moving to a display with another scale:
		// rebuild the glyph atlas at the new pixel size so text stays 1:1 sharp
		if px := font_pixel_size(); px != font_px {
			if custom do rl.UnloadFont(font)
			font, custom = load_font(px)
			font_px = px
		}

		handle_input(&e, font)
		lsp_update(&e, dt)
		git_update(&e, dt)

		rl.BeginDrawing()
		render(&e, font)
		rl.EndDrawing()

		mem.free_all(context.temp_allocator)
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

	for path in FONT_PATHS {
		f := rl.LoadFontEx(to_cstring(path), pixel_size, raw_data(cps[:]), NUM_CP)
		if f.glyphCount > 0 {
			rl.SetTextureFilter(f.texture, .BILINEAR)
			return f, true
		}
	}
	return rl.GetFontDefault(), false
}
