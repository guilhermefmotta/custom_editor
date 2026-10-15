package editor

// Font size from the keyboard and the palette, in every keymap mode:
// Cmd/Ctrl + = / - / 0, and "Font: Increase / Decrease / Reset Size". The new
// size is applied (main.odin rebuilds the glyph atlas) and saved to the user's
// editor.toml, the same way the settings screen does.

import "core:fmt"
import conf "./config"

FONT_ZOOM_STEP :: 2

@(init)
_font_zoom_register :: proc "contextless" () {
	ui_register_command(Command{"Font: Increase Size", "Bigger text (Cmd/Ctrl + =)", _cmd_font_bigger, nil})
	ui_register_command(Command{"Font: Decrease Size", "Smaller text (Cmd/Ctrl + -)", _cmd_font_smaller, nil})
	ui_register_command(Command{"Font: Reset Size", "Default text size (Cmd/Ctrl + 0)", _cmd_font_reset, nil})
}

@(private="file") _cmd_font_bigger  :: proc(e: ^Editor, p: ^Palette) { palette_close(p); font_zoom(e, +FONT_ZOOM_STEP) }
@(private="file") _cmd_font_smaller :: proc(e: ^Editor, p: ^Palette) { palette_close(p); font_zoom(e, -FONT_ZOOM_STEP) }
@(private="file") _cmd_font_reset   :: proc(e: ^Editor, p: ^Palette) { palette_close(p); font_zoom_reset(e) }

// Changes the font size by `delta` pixels (clamped to the allowed range).
font_zoom :: proc(e: ^Editor, delta: int) {
	size := clamp(int(FONT_SIZE) + delta, conf.FONT_SIZE_MIN, conf.FONT_SIZE_MAX)
	_font_zoom_set(e, size)
}

font_zoom_reset :: proc(e: ^Editor) {
	_font_zoom_set(e, conf.config_defaults().font.size)
}

@(private="file")
_font_zoom_set :: proc(e: ^Editor, size: int) {
	err, save_err := settings_apply(e, .Font_Size, fmt.tprintf("%d", size), settings_user_path())
	switch {
	case err != "":      e.msg = err
	case save_err != "": e.msg = fmt.tprintf("Font size %d (not saved: %s)", size, save_err)
	case:                e.msg = fmt.tprintf("Font size %d", size)
	}
}
