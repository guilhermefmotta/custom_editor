package editor

// Top-of-window banner (one global instance, drawn by the registry above
// overlay panels).
//   ui_banner_show("Pushed 3 commits to origin/main", .Success)        // 4s
//   ui_banner_show("Merge conflict in 2 files", .Error, seconds = 0)  // sticky until X
//   ui_banner_hide()
// The text is copied into a fixed buffer (temp strings are fine).

import rl "vendor:raylib"

Ui_Banner_Kind :: enum u8 { Info, Success, Warning, Error }

UI_BANNER_H   :: f32(30)
UI_BANNER_MAX :: 256

Ui_Banner :: struct {
	visible: bool,
	kind:    Ui_Banner_Kind,
	buf:     [UI_BANNER_MAX]u8,
	len:     int,
	until:   f64, // 0 = sticky
}

ui_banner: Ui_Banner

// Pure: show at time `now`.
ui_banner_set :: proc(b: ^Ui_Banner, text: string, kind: Ui_Banner_Kind, seconds, now: f64) {
	n := min(len(text), UI_BANNER_MAX)
	for n > 0 && n < len(text) && (text[n] & 0xC0) == 0x80 { n -= 1 } // don't split a UTF-8 rune
	copy(b.buf[:], text[:n])
	b.len     = n
	b.kind    = kind
	b.visible = true
	b.until   = now + seconds if seconds > 0 else 0
}

ui_banner_text :: proc(b: ^Ui_Banner) -> string { return string(b.buf[:b.len]) }

// Pure: expire at time `now`.
ui_banner_update :: proc(b: ^Ui_Banner, now: f64) {
	if b.visible && b.until > 0 && now >= b.until { b.visible = false }
}

ui_banner_show :: proc(text: string, kind := Ui_Banner_Kind.Info, seconds: f64 = 4) {
	ui_banner_set(&ui_banner, text, kind, seconds, f64(rl.GetTime()))
}

ui_banner_hide :: proc() { ui_banner.visible = false }

@(private="file")
_ui_banner_close_rect :: proc(sw: f32) -> rl.Rectangle {
	return {sw - UI_BANNER_H, 0, UI_BANNER_H, UI_BANNER_H}
}

// Click on the X: called from ui_registry_handle_input so the click doesn't
// reach the editor. Returns true if consumed.
ui_banner_handle_input :: proc(b: ^Ui_Banner) -> bool {
	if !b.visible || !rl.IsMouseButtonPressed(.LEFT) { return false }
	mp := rl.GetMousePosition()
	sw := f32(rl.GetScreenWidth())
	if ui_point_in(mp, _ui_banner_close_rect(sw)) { b.visible = false; return true }
	return ui_point_in(mp, {0, 0, sw, UI_BANNER_H})
}

ui_banner_draw :: proc(b: ^Ui_Banner, font: rl.Font, sw: f32) {
	if !b.visible { return }
	col: rl.Color
	switch b.kind {
	case .Info:    col = ACCENT_COL
	case .Success: col = DIFF_ADD_COL
	case .Warning: col = DIAG_WARN_COL
	case .Error:   col = MSG_COL
	}
	rl.DrawRectangleRec({0, 0, sw, UI_BANNER_H}, STATUS_BG)
	rl.DrawRectangleRec({0, 0, sw, UI_BANNER_H}, ui_with_alpha(col, 40))
	rl.DrawRectangleRec({0, UI_BANNER_H - 2, sw, 2}, col)
	rl.DrawRectangleRec({0, 0, 4, UI_BANNER_H}, col)
	ui_text(font, ui_banner_text(b), 14, 0, UI_BANNER_H, FONT_SIZE - 1, TEXT, sw - UI_BANNER_H)
	xr := _ui_banner_close_rect(sw)
	hover := ui_point_in(rl.GetMousePosition(), xr)
	ui_text(font, "x", xr.x + 10, 0, UI_BANNER_H, FONT_SIZE, hover ? TEXT : LINENUM, sw)
}
