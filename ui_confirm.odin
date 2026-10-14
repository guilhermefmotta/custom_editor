package editor

// Confirmation dialog: Confirm / Cancel / optional extra action.
//   cf: Ui_Confirm                                                 // per-screen state
//   ui_confirm_open(&cf, "Discard changes?", "3 files will be reset.",
//                   confirm = "Discard", extra = "Stash instead", danger = true)
//   // input proc (before anything else while cf.open):
//   if cf.open { handle(ui_confirm_handle_input(&cf)); return true }
//   // draw proc (last, it is modal; outside any dlg_begin/dlg_end scissor):
//   handle(ui_confirm_draw(&cf, font, sw, sh))
//   handle :: proc(r: Ui_Confirm_Result) { switch r { case .Confirm: ... case .Extra: ... } }
// Keys: Enter = focused button (Confirm by default), Esc = Cancel,
// Tab/Shift+Tab/Left/Right move focus. Any result closes the dialog.
// The message is copied (may be a temp string); title/labels must outlive
// the dialog (use literals). ui_confirm_destroy frees the copy.

import "core:strings"
import rl "vendor:raylib"

Ui_Confirm_Result :: enum u8 { None, Confirm, Cancel, Extra }

Ui_Confirm :: struct {
	open:          bool,
	title:         string,
	message:       string, // owned
	confirm_label: string,
	cancel_label:  string,
	extra_label:   string, // "" = no extra button
	danger:        bool,   // confirm button drawn in the error color
	focus:         int,    // index into ui_confirm_buttons order
}

ui_confirm_open :: proc(c: ^Ui_Confirm, title, message: string, confirm := "Confirm", cancel := "Cancel", extra := "", danger := false) {
	ui_confirm_destroy(c)
	c^ = {
		open          = true,
		title         = title,
		message       = strings.clone(message),
		confirm_label = confirm,
		cancel_label  = cancel,
		extra_label   = extra,
		danger        = danger,
	}
}

ui_confirm_close :: proc(c: ^Ui_Confirm) {
	c.open = false
}

ui_confirm_destroy :: proc(c: ^Ui_Confirm) {
	if c.message != "" { delete(c.message) }
	c^ = {}
}

// Pure: button results in display order, left to right is
// [Extra?] [Cancel] [Confirm]; focus 0 is Confirm.
ui_confirm_buttons :: proc(c: ^Ui_Confirm) -> (btns: [3]Ui_Confirm_Result, n: int) {
	btns[0] = .Confirm
	btns[1] = .Cancel
	n = 2
	if c.extra_label != "" { btns[2] = .Extra; n = 3 }
	return
}

// Pure: result of a key press given the focused button. Returns .None for
// focus movement (c.focus updated) or unrelated keys.
Ui_Confirm_Key :: enum u8 { None, Enter, Escape, Next, Prev }

ui_confirm_key :: proc(c: ^Ui_Confirm, k: Ui_Confirm_Key) -> Ui_Confirm_Result {
	btns, n := ui_confirm_buttons(c)
	switch k {
	case .None:
	case .Enter:  return btns[clamp(c.focus, 0, n - 1)]
	case .Escape: return .Cancel
	case .Next:   c.focus = ui_tabs_cycle(c.focus, n, 1)
	case .Prev:   c.focus = ui_tabs_cycle(c.focus, n, -1)
	}
	return .None
}

ui_confirm_handle_input :: proc(c: ^Ui_Confirm) -> Ui_Confirm_Result {
	if !c.open { return .None }
	k := Ui_Confirm_Key.None
	switch {
	case rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER): k = .Enter
	case rl.IsKeyPressed(.ESCAPE):                              k = .Escape
	case rl.IsKeyPressed(.TAB):                                 k = .Prev if shift() else .Next
	case rl.IsKeyPressed(.RIGHT):                               k = .Prev
	case rl.IsKeyPressed(.LEFT):                                k = .Next
	}
	r := ui_confirm_key(c, k)
	if r != .None { ui_confirm_close(c) }
	return r
}

// Draws the modal (dim overlay + panel) and handles button clicks.
ui_confirm_draw :: proc(c: ^Ui_Confirm, font: rl.Font, sw, sh: f32) -> Ui_Confirm_Result {
	if !c.open { return .None }
	W     :: f32(460)
	BTN_H :: f32(30)
	size  := FONT_SIZE - 1
	h     := 44 + size * 2 + 24 + BTN_H + 16

	rl.DrawRectangle(0, 0, i32(sw), i32(sh), {0, 0, 0, 150})
	// Own panel chrome instead of dlg_begin: the confirm usually sits on top
	// of another dlg_begin panel, and dlg_* keeps single-dialog state.
	px, py := (sw - W) * 0.5, sh * 0.25
	rl.DrawRectangleRec({px + 6, py + 8, W, h}, {0, 0, 0, 60})
	rl.DrawRectangleRec({px + 2, py + 3, W, h}, {0, 0, 0, 90})
	rl.DrawRectangleRec({px, py, W, h}, BG)
	rl.DrawRectangleLinesEx({px, py, W, h}, 1, DIVIDER_COL)
	rl.DrawRectangleRec({px, py, W, 36}, STATUS_BG)
	ui_text(font, c.title, px + 14, py, 36, FONT_SIZE, c.danger ? MSG_COL : ACCENT_COL, px + W)
	dlg_text(font, c.message, px + 14, py + 50, size, CHAR_SPACING, TEXT, px + W, 14)

	btns, n := ui_confirm_buttons(c)
	labels  := [3]string{c.confirm_label, c.cancel_label, c.extra_label}
	result  := Ui_Confirm_Result.None
	// right to left: Confirm, Cancel, then Extra pinned to the left edge
	bx := px + W - 14
	by := py + h - BTN_H - 14
	for i in 0 ..< n {
		bw := ui_button_w(font, labels[i])
		x  := px + 14 if btns[i] == .Extra else bx - bw
		if btns[i] != .Extra { bx -= bw + 10 }
		primary := btns[i] == .Confirm
		if primary && c.danger {
			rl.DrawRectangleRec({x - 1, by - 1, bw + 2, BTN_H + 2}, MSG_COL)
		}
		if ui_button(font, {x, by, bw, BTN_H}, labels[i], c.focus == i, primary) {
			result = btns[i]
		}
	}
	if result != .None { ui_confirm_close(c) }
	return result
}
