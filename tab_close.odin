package editor

// Closing file tabs: Cmd+W (macOS) / Ctrl+W (normal keymap), the "Close Tab"
// command and vim's :q. A tab with unsaved changes asks first (Save & Close /
// Discard / Cancel). Closing the last tab leaves an empty pane — it never
// quits the editor (quitting is :qa / Cmd+Q).

import "core:fmt"
import "core:path/filepath"
import rl "vendor:raylib"

TAB_CLOSE_ID :: "tab_close_confirm"

@(private="file") _tc: struct { confirm: Ui_Confirm }

@(init)
_tab_close_register :: proc "contextless" () {
	ui_register_panel(Ui_Panel{
		id = TAB_CLOSE_ID, title = "Close Tab", priority = 96, layer = .Overlay,
		draw = _tc_draw, input = _tc_input,
	})
	ui_register_command(Command{"Close Tab", "Close the current file tab (Cmd/Ctrl+W; asks if there are unsaved changes)", _cmd_close_tab, nil})
}

@(private="file")
_cmd_close_tab :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	editor_close_tab_request(e)
}

// Closes the active pane's current tab, asking first when it has unsaved changes.
editor_close_tab_request :: proc(e: ^Editor) {
	p := active_pane(e)
	if p.filename == "" && len(p.tabs) == 0 && !p.dirty { return } // nothing open
	if p.dirty {
		name := filepath.base(p.filename) if p.filename != "" else "untitled"
		ui_confirm_open(&_tc.confirm, "Unsaved changes", fmt.tprintf("%s has unsaved changes.", name),
			confirm = "Save & Close", cancel = "Cancel", extra = "Discard")
		ui_panel_open(e, TAB_CLOSE_ID)
		return
	}
	editor_close_tab_now(e)
}

// Closes without asking. Last tab → empty pane (the editor stays open).
editor_close_tab_now :: proc(e: ^Editor) {
	p := active_pane(e)
	pane_close_tab(p)
	lsp_on_open(e, p)
}

@(private="file")
_tc_result :: proc(e: ^Editor, r: Ui_Confirm_Result) {
	switch r {
	case .None:
		return
	case .Confirm: // Save & Close (keeps the tab if saving didn't happen, e.g. no file name yet)
		if editor_save(e) { editor_close_tab_now(e) }
	case .Extra: // Discard
		active_pane(e).dirty = false
		editor_close_tab_now(e)
	case .Cancel:
	}
	editor_close_tab_dismiss(e)
}

// Drops a pending "unsaved changes" question without closing anything.
editor_close_tab_dismiss :: proc(e: ^Editor) {
	ui_confirm_destroy(&_tc.confirm) // frees the message
	ui_panel_close(e, TAB_CLOSE_ID)
}

@(private="file")
_tc_input :: proc(e: ^Editor) -> bool {
	if !_tc.confirm.open { ui_panel_close(e, TAB_CLOSE_ID); return false }
	_tc_result(e, ui_confirm_handle_input(&_tc.confirm))
	return true
}

@(private="file")
_tc_draw :: proc(e: ^Editor, font: rl.Font, sw, sh: f32) {
	_tc_result(e, ui_confirm_draw(&_tc.confirm, font, sw, sh))
}
