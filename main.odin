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

main :: proc() {
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
		// Notify LSP about the initial file after LSP is running
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
}

load_font :: proc() -> (font: rl.Font, custom: bool) {
	// ASCII 32-126 + UI arrow/symbol codepoints needed by find panel
	cps: [99]rune
	for i in 0..<95 { cps[i] = rune(32 + i) }
	cps[95] = 0x2191 // ↑
	cps[96] = 0x2193 // ↓
	cps[97] = 0x2261 // ≡
	cps[98] = 0x229E // ⊞

	for path in FONT_PATHS {
		f := rl.LoadFontEx(to_cstring(path), 64, raw_data(cps[:]), 99)
		if f.glyphCount > 0 {
			rl.SetTextureFilter(f.texture, .BILINEAR)
			return f, true
		}
	}
	return rl.GetFontDefault(), false
}
