package editor

import "core:mem"
import "core:os"
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
	platform_hide_console() // hides console window on Windows (FreeConsole)
	rl.SetTraceLogLevel(.WARNING)

	rl.SetConfigFlags({.WINDOW_RESIZABLE, .MSAA_4X_HINT})
	rl.InitWindow(1280, 720, "editor")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)
	rl.SetExitKey(.KEY_NULL) // disable ESC closing window — handled by dialogs

	font, custom := load_font()
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

load_font :: proc() -> (font: rl.Font, custom: bool) {
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
		f := rl.LoadFontEx(to_cstring(path), 64, raw_data(cps[:]), NUM_CP)
		if f.glyphCount > 0 {
			rl.SetTextureFilter(f.texture, .BILINEAR)
			return f, true
		}
	}
	return rl.GetFontDefault(), false
}
