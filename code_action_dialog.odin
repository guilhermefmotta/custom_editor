package editor

import "core:fmt"
import "core:encoding/json"
import rl "vendor:raylib"

Code_Action :: struct {
	title:        string, // heap-owned
	kind:         string, // heap-owned, may be ""
	has_edit:     bool,
	edit_json:    string, // heap-owned raw JSON of workspaceEdit
	has_cmd:      bool,
	cmd_id:       string, // heap-owned command identifier
	cmd_args:     string, // heap-owned raw JSON args array or ""
	is_preferred: bool,
	// Deep-cloned copy of the original CodeAction object as sent by the
	// server. Some servers (e.g. jdtls, once the client declares
	// codeActionLiteralSupport.resolveSupport) omit `edit`/`command` up
	// front and expect the client to send this back verbatim via
	// codeAction/resolve to get them. nil once resolved/unneeded.
	raw_json:     json.Value,
}

code_action_destroy :: proc(a: ^Code_Action) {
	delete(a.title)
	delete(a.kind)
	delete(a.edit_json)
	delete(a.cmd_id)
	delete(a.cmd_args)
	if a.raw_json != nil { json.destroy_value(a.raw_json) }
}

Code_Action_Dialog :: struct {
	open:    bool,
	actions: [dynamic]Code_Action,
	sel:     int,
	scroll:  int,
}

CA_MAX_VIS :: 12
CA_ITEM_H  :: f32(28)
CA_HDR_H   :: f32(32)
CA_FOOT_H  :: f32(26)
CA_W       :: f32(560)

code_action_dialog_init :: proc() -> Code_Action_Dialog {
	d: Code_Action_Dialog
	d.actions = make([dynamic]Code_Action)
	return d
}

code_action_dialog_destroy :: proc(d: ^Code_Action_Dialog) {
	for &a in d.actions { code_action_destroy(&a) }
	delete(d.actions)
	d^ = {}
}

code_action_dialog_clear :: proc(d: ^Code_Action_Dialog) {
	for &a in d.actions { code_action_destroy(&a) }
	clear(&d.actions)
	d.sel    = 0
	d.scroll = 0
}

code_action_dialog_open :: proc(d: ^Code_Action_Dialog) {
	d.open   = true
	d.sel    = 0
	d.scroll = 0
}

code_action_dialog_close :: proc(d: ^Code_Action_Dialog) {
	d.open = false
}

code_action_dialog_handle_input :: proc(d: ^Code_Action_Dialog) -> (consumed: bool, selected: int) {
	if !d.open { return false, -1 }
	n := len(d.actions)

	if rl.IsKeyPressed(.ESCAPE) { d.open = false; return true, -1 }

	if rl.IsKeyPressed(.ENTER) && d.sel < n {
		d.open = false
		return true, d.sel
	}

	if key_rep(.UP) && d.sel > 0 {
		d.sel -= 1
		if d.sel < d.scroll { d.scroll = d.sel }
		return true, -1
	}
	if key_rep(.DOWN) && d.sel < n-1 {
		d.sel += 1
		if d.sel >= d.scroll + CA_MAX_VIS { d.scroll = d.sel - CA_MAX_VIS + 1 }
		return true, -1
	}

	wheel := rl.GetMouseWheelMove()
	if wheel != 0 {
		d.scroll = clamp(d.scroll - int(wheel)*2, 0, max(0, n - CA_MAX_VIS))
		return true, -1
	}

	return true, -1
}

render_code_action_dialog :: proc(d: ^Code_Action_Dialog, font: rl.Font, sw, sh: f32) {
	if !d.open { return }

	OVERLAY  :: rl.Color{0, 0, 0, 160}
	PANEL_BG := BG
	BORDER   := DIVIDER_COL
	HDR_BG   := STATUS_BG
	ACCENT   := ACCENT_COL
	SUBDUED  := LINENUM
	SEL      := SEL_BG
	PREF_COL := DIAG_HINT_COL

	n       := len(d.actions)
	vis     := min(n, CA_MAX_VIS)
	panel_h := CA_HDR_H + f32(vis)*CA_ITEM_H + CA_FOOT_H

	px := (sw - CA_W) * 0.5
	py := sh * 0.2

	rl.DrawRectangle(0, 0, i32(sw), i32(sh), OVERLAY)
	px, py = dlg_begin(px, py, CA_W, panel_h, PANEL_BG, BORDER)

	// Header
	rl.DrawRectangleV({px, py}, {CA_W, CA_HDR_H}, HDR_BG)
	rl.DrawLineV({px, py + CA_HDR_H}, {px + CA_W, py + CA_HDR_H}, BORDER)
	ref := rl.MeasureTextEx(font, "M", FONT_SIZE, CHAR_SPACING)
	draw_text(font, "Code Actions", {px + 12, py + (CA_HDR_H - ref.y) * 0.5}, FONT_SIZE, CHAR_SPACING, ACCENT)
	cnt_s := fmt.tprintf("%d actions", n)
	cnt_w := rl.MeasureTextEx(font, to_cstring(cnt_s), FONT_SIZE - 3, CHAR_SPACING).x
	draw_text(font, to_cstring(cnt_s),
		{px + CA_W - cnt_w - 12, py + (CA_HDR_H - ref.y) * 0.5 + 1},
		FONT_SIZE - 3, CHAR_SPACING, SUBDUED)

	// Items
	max_s  := max(0, n - CA_MAX_VIS)
	if d.scroll > max_s { d.scroll = max_s }
	item_y := py + CA_HDR_H

	for vi in 0..<vis {
		fi    := d.scroll + vi
		if fi >= n { break }
		a     := d.actions[fi]
		row_y := item_y + f32(vi) * CA_ITEM_H

		if fi == d.sel {
			rl.DrawRectangleV({px, row_y}, {CA_W, CA_ITEM_H}, SEL)
			rl.DrawRectangleV({px, row_y}, {3, CA_ITEM_H}, ACCENT)
		}

		tx := px + 14
		if a.is_preferred {
			draw_text(font, "\xe2\x98\x85", {tx, row_y + (CA_ITEM_H - ref.y) * 0.5},
				FONT_SIZE - 2, CHAR_SPACING, PREF_COL)
			tx += 18
		}

		dlg_text(font, a.title, tx, row_y + (CA_ITEM_H - ref.y) * 0.5,
			FONT_SIZE - 1, CHAR_SPACING, TEXT, px + CA_W - 10, 8)

		if a.kind != "" {
			kw := rl.MeasureTextEx(font, to_cstring(a.kind), FONT_SIZE - 4, CHAR_SPACING).x
			draw_text(font, to_cstring(a.kind),
				{px + CA_W - kw - 10, row_y + (CA_ITEM_H - ref.y) * 0.5 + 1},
				FONT_SIZE - 4, CHAR_SPACING, SUBDUED)
		}
	}

	// Footer
	fy := item_y + f32(vis) * CA_ITEM_H
	rl.DrawRectangleV({px, fy}, {CA_W, CA_FOOT_H}, HDR_BG)
	rl.DrawLineV({px, fy}, {px + CA_W, fy}, BORDER)
	hint := "\xe2\x86\x91\xe2\x86\x93 navigate  \xc2\xb7  Enter apply  \xc2\xb7  Esc close"
	hw   := rl.MeasureTextEx(font, to_cstring(hint), FONT_SIZE - 3, CHAR_SPACING).x
	draw_text(font, to_cstring(hint),
		{px + (CA_W - hw) * 0.5, fy + (CA_FOOT_H - ref.y) * 0.5},
		FONT_SIZE - 3, CHAR_SPACING, SUBDUED)

	dlg_end()
}
