package editor

import "core:strings"
import rl "vendor:raylib"

// ---------------------------------------------------------------------------
// Rename Symbol Dialog  (F2)
// ---------------------------------------------------------------------------

Rename_Dialog :: struct {
	open:     bool,
	input:    [dynamic]u8,
	sel_all:  bool,
	orig:     string, // heap-owned — original symbol name
}

rename_dialog_init :: proc() -> Rename_Dialog {
	d: Rename_Dialog
	d.input = make([dynamic]u8)
	return d
}

rename_dialog_destroy :: proc(d: ^Rename_Dialog) {
	delete(d.input)
	if d.orig != "" { delete(d.orig) }
	d^ = {}
}

rename_dialog_open :: proc(d: ^Rename_Dialog, current_word: string) {
	clear(&d.input)
	append(&d.input, ..transmute([]u8)current_word)
	if d.orig != "" { delete(d.orig) }
	d.orig    = strings.clone(current_word)
	d.open    = true
	d.sel_all = false
}

rename_dialog_close :: proc(d: ^Rename_Dialog) {
	d.open    = false
	d.sel_all = false
}

// Returns (new_name, confirmed). new_name is temp-allocated.
rename_dialog_handle_input :: proc(d: ^Rename_Dialog) -> (new_name: string, confirmed: bool) {
	if !d.open { return "", false }

	if rl.IsKeyPressed(.ESCAPE) { d.open = false; return "", false }

	if rl.IsKeyPressed(.ENTER) {
		if len(d.input) > 0 {
			d.open = false
			return string(d.input[:]), true
		}
		return "", false
	}

	text_input_handle(&d.input, &d.sel_all)

	return "", false
}

render_rename_dialog :: proc(d: ^Rename_Dialog, font: rl.Font, sw, sh: f32) {
	if !d.open { return }

	DIALOG_H :: f32(38)
	DIALOG_BG := STATUS_BG
	BORDER    := ACCENT_COL
	SUBDUED   := LINENUM

	dy := sh - MSG_LINE_H - DIALOG_H
	rl.DrawRectangleV({0, dy}, {sw, DIALOG_H}, DIALOG_BG)
	rl.DrawRectangleLinesEx({0, dy, sw, DIALOG_H}, 1, BORDER)

	ref := rl.MeasureTextEx(font, "M", FONT_SIZE, CHAR_SPACING)
	ty  := dy + (DIALOG_H - ref.y) * 0.5

	label  := to_cstring("Rename: ")
	label_w := rl.MeasureTextEx(font, label, FONT_SIZE, CHAR_SPACING).x
	rl.DrawTextEx(font, label, {8, ty}, FONT_SIZE, CHAR_SPACING, ACCENT_COL)

	inp_s := string(d.input[:])
	inp_x := f32(8) + label_w
	rl.DrawTextEx(font, to_cstring(inp_s), {inp_x, ty}, FONT_SIZE, CHAR_SPACING, TEXT)
	inp_w := rl.MeasureTextEx(font, to_cstring(inp_s), FONT_SIZE, CHAR_SPACING).x
	rl.DrawRectangleV({inp_x + inp_w, ty}, {2, ref.y}, CURSOR_COL)

	hint   := to_cstring("Enter to rename  ·  Esc to cancel")
	hint_w := rl.MeasureTextEx(font, hint, FONT_SIZE-2, CHAR_SPACING).x
	rl.DrawTextEx(font, hint, {sw - hint_w - 8, ty + 2}, FONT_SIZE-2, CHAR_SPACING, SUBDUED)
}
