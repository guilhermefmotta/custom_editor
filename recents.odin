package editor

import "core:strings"
import rl "vendor:raylib"

RECENTS_MAX :: 10

Recents_Dialog :: struct {
	open:  bool,
	sel:   int,
	paths: [dynamic]string,
}

recents_init :: proc() -> Recents_Dialog {
	rd: Recents_Dialog
	rd.paths = make([dynamic]string)
	return rd
}

recents_destroy :: proc(rd: ^Recents_Dialog) {
	for p in rd.paths { delete(p) }
	delete(rd.paths)
	rd^ = {}
}

// Clone first to avoid use-after-free if path points into rd.paths itself.
recents_push :: proc(rd: ^Recents_Dialog, path: string) {
	if path == "" { return }
	new_str := strings.clone(path)
	for i in 0..<len(rd.paths) {
		if rd.paths[i] == path {
			delete(rd.paths[i])
			ordered_remove(&rd.paths, i)
			break
		}
	}
	inject_at(&rd.paths, 0, new_str)
	for len(rd.paths) > RECENTS_MAX {
		s := pop(&rd.paths)
		delete(s)
	}
}

recents_remove :: proc(rd: ^Recents_Dialog, path: string) {
	for i in 0..<len(rd.paths) {
		if rd.paths[i] == path {
			delete(rd.paths[i])
			ordered_remove(&rd.paths, i)
			return
		}
	}
}

// Open switcher: start on index 1 (previous file), like Alt+Tab.
recents_open :: proc(rd: ^Recents_Dialog) {
	if len(rd.paths) == 0 { return }
	rd.open = true
	rd.sel  = min(1, len(rd.paths) - 1)
}

recents_close :: proc(rd: ^Recents_Dialog) {
	rd.open = false
}

recents_jump :: proc(rd: ^Recents_Dialog, e: ^Editor) {
	if len(rd.paths) == 0 || rd.sel >= len(rd.paths) { recents_close(rd); return }
	sel := rd.sel
	// editor_open may call recents_push which deletes rd.paths[sel].
	// Save the index; if open fails, path is still valid (push wasn't called).
	ok := editor_open(e, rd.paths[sel])
	if !ok {
		if sel < len(rd.paths) {
			delete(rd.paths[sel])
			ordered_remove(&rd.paths, sel)
		}
		if len(rd.paths) == 0 { rd.open = false }
		return
	}
	recents_close(rd)
}

recents_handle_input :: proc(rd: ^Recents_Dialog, e: ^Editor) {
	// Release Ctrl → jump (Alt+Tab / Ctrl+Tab style)
	if rl.IsKeyReleased(.LEFT_CONTROL) || rl.IsKeyReleased(.RIGHT_CONTROL) {
		recents_jump(rd, e)
		return
	}
	if rl.IsKeyPressed(.ESCAPE) { recents_close(rd); return }
	if rl.IsKeyPressed(.ENTER)  { recents_jump(rd, e); return }
	n := len(rd.paths)
	if n == 0 { return }
	if rl.IsKeyPressed(.TAB) {
		if shift() { rd.sel = (rd.sel - 1 + n) % n } else { rd.sel = (rd.sel + 1) % n }
		return
	}
	if key_rep(.DOWN) { rd.sel = (rd.sel + 1) % n }
	if key_rep(.UP)   { rd.sel = (rd.sel - 1 + n) % n }
}

render_recents_dialog :: proc(rd: ^Recents_Dialog, font: rl.Font, sw, sh: f32) {
	if !rd.open { return }
	n := len(rd.paths)
	if n == 0 { return }

	ref := rl.MeasureTextEx(font, "M", FONT_SIZE, CHAR_SPACING)

	PANEL_W  :: f32(480)
	HEADER_H :: f32(34)
	ITEM_H   :: f32(38)
	FOOTER_H :: f32(26)

	OVERLAY  :: rl.Color{0,   0,   0,   180}
	PANEL_BG :: rl.Color{30,  30,  46,  255}
	BORDER   :: rl.Color{58,  60,  78,  255}
	SEL_BG_C :: rl.Color{69,  71,  90,  255}
	ACCENT   :: rl.Color{137, 180, 250, 255}
	SUBDUED  :: rl.Color{108, 112, 134, 255}
	INPUT_BG :: rl.Color{24,  24,  37,  255}

	panel_h := HEADER_H + f32(n)*ITEM_H + FOOTER_H
	panel_x := (sw - PANEL_W) * 0.5
	panel_y := sh * 0.10

	rl.DrawRectangle(0, 0, i32(sw), i32(sh), OVERLAY)
	dlg_begin(panel_x, panel_y, PANEL_W, panel_h, PANEL_BG, BORDER)

	// Header
	rl.DrawRectangleV({panel_x, panel_y}, {PANEL_W, HEADER_H}, INPUT_BG)
	rl.DrawLineV({panel_x, panel_y + HEADER_H - 1}, {panel_x + PANEL_W, panel_y + HEADER_H - 1}, BORDER)
	rl.DrawTextEx(font, "Recent Files", {panel_x + 10, panel_y + 8}, FONT_SIZE, CHAR_SPACING, ACCENT)

	// Items
	items_top := panel_y + HEADER_H
	for i in 0..<n {
		iy := items_top + f32(i)*ITEM_H
		if i == rd.sel {
			rl.DrawRectangleV({panel_x, iy}, {PANEL_W, ITEM_H}, SEL_BG_C)
			rl.DrawRectangleV({panel_x, iy}, {3, ITEM_H}, ACCENT)
		}
		base    := path_basename(rd.paths[i])
		txt_col := ACCENT if i == rd.sel else TEXT
		ty_base := iy + (ITEM_H - ref.y*2 - 3) * 0.5
		right   := panel_x + PANEL_W
		dlg_text(font, base,          panel_x + 12, ty_base,            FONT_SIZE,     CHAR_SPACING, txt_col, right, 8)
		dlg_text(font, rd.paths[i],   panel_x + 12, ty_base + ref.y + 3, FONT_SIZE - 3, CHAR_SPACING, SUBDUED, right, 8)
	}

	// Footer
	fy := panel_y + HEADER_H + f32(n)*ITEM_H
	rl.DrawRectangleV({panel_x, fy}, {PANEL_W, FOOTER_H}, INPUT_BG)
	rl.DrawRectangleLinesEx({panel_x, fy, PANEL_W, FOOTER_H}, 1, BORDER)
	hint := "Tab next  *  Shift+Tab prev  *  release Ctrl jump  *  Esc cancel"
	rl.DrawTextEx(font, to_cstring(hint), {panel_x + 10, fy + 5}, FONT_SIZE - 3, CHAR_SPACING, SUBDUED)
	dlg_end()
}
