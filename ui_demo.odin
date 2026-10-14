package editor

// Living example of the UI registry + kit (ADR 0001). This file is NOT
// referenced by palette.odin, input.odin or renderer.odin: it registers
// itself via @(init) and shows up as "UI Kit: Demo" in the palette
// (Ctrl/Cmd+Shift+P) and on Ctrl/Cmd+Shift+U.
//
// Shows: tabs, filterable list, resizable split, confirmation dialog with
// an extra action, right-click context menu and the top banner.

import "core:fmt"
import "base:runtime"
import rl "vendor:raylib"

UI_DEMO_ID :: "ui_demo"

@(init)
_ui_demo_register :: proc "contextless" () {
	ui_register_panel(Ui_Panel{
		id       = UI_DEMO_ID,
		title    = "UI Kit Demo",
		priority = 100,
		layer    = .Overlay,
		draw     = _ui_demo_draw,
		input    = _ui_demo_input,
		on_close = _ui_demo_on_close,
		command  = "UI Kit: Demo",
		command_desc = "Living example of the UI kit (list, tabs, split, confirm, menu, banner)",
		shortcut = {key = .U, mods = {.Ctrl, .Shift}},
	})
	ui_register_command(Command{"UI Kit: Show Banner", "Show a sample banner at the top of the window", _ui_demo_banner_cmd, nil})
}

@(fini)
_ui_demo_fini :: proc "contextless" () {
	context = runtime.default_context()
	_ui_demo_on_close(nil)
}

@(private="file") _UI_DEMO_TABS  := []string{"List", "Split", "Dialogs"}
@(private="file") _UI_DEMO_MENU  := []string{"Show in banner", "Filter by this", "Delete..."}
@(private="file") _UI_DEMO_ITEMS := []string{
	"main", "develop", "feature/commit-graph", "feature/working-tree", "feature/sidebar",
	"feature/conflict-resolver", "feature/stash-list", "feature/blame-view", "feature/branch-picker",
	"fix/merge-staging", "fix/crlf-diff", "fix/huge-commit-freeze", "release/v0.7.0", "release/v0.8.0",
	"chore/ci-windows", "chore/update-raylib", "docs/adr-0001", "spike/async-git", "spike/lsp-pool",
	"hotfix/palette-crash", "experiment/minimap", "experiment/vim-registers", "origin/main",
	"origin/develop", "origin/feature/commit-graph", "tags/v0.6.0", "tags/v0.7.0",
}

@(private="file")
_Ui_Demo :: struct {
	tab:      int,
	list:     Ui_List,
	list_vis: int,
	split:    Ui_Split,
	confirm:  Ui_Confirm,
	menu:     Ui_Menu,
	last:     string, // last action, shown in the footer
}
@(private="file") _demo: _Ui_Demo = {split = {ratio = 0.45, min_a = 140, min_b = 140}}

@(private="file")
_ui_demo_banner_cmd :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	ui_banner_show("Banner from a command registered via @(init) in ui_demo.odin", .Success)
}

@(private="file")
_ui_demo_on_close :: proc(e: ^Editor) {
	ui_list_destroy(&_demo.list)
	ui_confirm_destroy(&_demo.confirm)
	_demo.menu = {}
}

@(private="file")
_ui_demo_selected :: proc() -> string {
	i := ui_list_selected_item(&_demo.list)
	return _UI_DEMO_ITEMS[i] if i >= 0 else ""
}

@(private="file")
_ui_demo_on_menu :: proc(i: int) {
	name := _ui_demo_selected()
	switch i {
	case 0: ui_banner_show(fmt.tprintf("Context menu on %q", name))
	case 1: ui_list_set_filter(&_demo.list, name, _UI_DEMO_ITEMS)
	case 2: ui_confirm_open(&_demo.confirm, "Delete branch?", fmt.tprintf("Branch %q will be deleted.", name),
	                        confirm = "Delete", extra = "Archive instead", danger = true)
	}
}

@(private="file")
_ui_demo_on_confirm :: proc(r: Ui_Confirm_Result) {
	switch r {
	case .None:
	case .Confirm: _demo.last = "confirmed";      ui_banner_show("Confirmed", .Error)
	case .Cancel:  _demo.last = "cancelled"
	case .Extra:   _demo.last = "extra action";   ui_banner_show("Extra action chosen", .Warning)
	}
}

@(private="file")
_ui_demo_input :: proc(e: ^Editor) -> bool {
	// Modal: always consumes input. Topmost sub-widgets first.
	if _demo.confirm.open { _ui_demo_on_confirm(ui_confirm_handle_input(&_demo.confirm)); return true }
	if _demo.menu.open {
		if i := ui_menu_handle_input(&_demo.menu); i >= 0 { _ui_demo_on_menu(i) }
		return true
	}
	if ui_tabs_handle_input(&_demo.tab, len(_UI_DEMO_TABS)) { return true }

	switch _demo.tab {
	case 0, 1:
		#partial switch ui_list_handle_input(&_demo.list, _UI_DEMO_ITEMS, max(1, _demo.list_vis)) {
		case .Activate: ui_banner_show(fmt.tprintf("Selected %q", _ui_demo_selected()))
		case .Cancel:   ui_panel_close(e, UI_DEMO_ID)
		}
	case 2:
		if rl.IsKeyPressed(.ESCAPE) { ui_panel_close(e, UI_DEMO_ID) }
		if rl.IsKeyPressed(.ENTER)  { _ui_demo_open_confirm() }
	}
	return true
}

@(private="file")
_ui_demo_open_confirm :: proc() {
	ui_confirm_open(&_demo.confirm, "Discard local changes?", "3 modified files will be reset to HEAD.",
	                confirm = "Discard", extra = "Stash instead")
}

@(private="file")
_ui_demo_draw :: proc(e: ^Editor, font: rl.Font, sw, sh: f32) {
	W :: f32(780)
	H :: f32(480)
	HDR :: f32(34)
	TAB :: f32(30)
	FTR :: f32(26)
	busy := _demo.confirm.open || _demo.menu.open // a widget on top owns the mouse

	rl.DrawRectangle(0, 0, i32(sw), i32(sh), {0, 0, 0, 150})
	px, py := dlg_begin((sw - W) * 0.5, sh * 0.1, W, H, BG, DIVIDER_COL)

	rl.DrawRectangleRec({px, py, W, HDR}, STATUS_BG)
	ui_text(font, "UI Kit: Demo", px + 12, py, HDR, FONT_SIZE, ACCENT_COL, px + W)
	ui_text(font, "registered via @(init) in ui_demo.odin", px + 160, py, HDR, FONT_SIZE - 3, LINENUM, px + W)

	ui_tabs(font, {px, py + HDR, W, TAB}, _UI_DEMO_TABS, &_demo.tab, !busy)

	body := rl.Rectangle{px + 10, py + HDR + TAB + 10, W - 20, H - HDR - TAB - FTR - 20}
	switch _demo.tab {
	case 0:
		_ui_demo_list(font, body, busy)
	case 1:
		a, b := ui_split(&_demo.split, body, !busy)
		_ui_demo_list(font, a, busy)
		rl.DrawRectangleRec(b, STATUS_BG)
		sel := _ui_demo_selected()
		ui_text(font, "Details", b.x + 10, b.y + 4, UI_ROW_H, FONT_SIZE, ACCENT_COL, b.x + b.width)
		ui_text(font, sel if sel != "" else "(nothing selected)", b.x + 10, b.y + 4 + UI_ROW_H, UI_ROW_H, FONT_SIZE - 1, TEXT, b.x + b.width)
		ui_text(font, "Drag the divider to resize.", b.x + 10, b.y + 4 + 2 * UI_ROW_H, UI_ROW_H, FONT_SIZE - 3, LINENUM, b.x + b.width)
	case 2:
		bw := ui_button_w(font, "Open confirmation...")
		if ui_button(font, {body.x, body.y, bw, 30}, "Open confirmation...", true, true) && !busy { _ui_demo_open_confirm() }
		kinds := [4]Ui_Banner_Kind{.Info, .Success, .Warning, .Error}
		x := body.x
		for k in kinds {
			label := fmt.tprintf("Banner: %v", k)
			w := ui_button_w(font, label)
			if ui_button(font, {x, body.y + 50, w, 30}, label, false, false) && !busy {
				ui_banner_show(fmt.tprintf("This is a %v banner", k), k)
			}
			x += w + 10
		}
	}

	fy := py + H - FTR
	rl.DrawRectangleRec({px, fy, W, FTR}, STATUS_BG)
	hint := "Ctrl+Tab tabs  Up/Dn PgUp/PgDn wheel  type to filter  Enter select  right-click menu  Esc close"
	if _demo.last != "" { hint = fmt.tprintf("last confirm: %s   |   %s", _demo.last, hint) }
	ui_text(font, hint, px + 10, fy, FTR, FONT_SIZE - 4, LINENUM, px + W)
	dlg_end()

	if i := ui_menu_draw(&_demo.menu, font, sw, sh); i >= 0 { _ui_demo_on_menu(i) }
	_ui_demo_on_confirm(ui_confirm_draw(&_demo.confirm, font, sw, sh))
}

@(private="file")
_ui_demo_list :: proc(font: rl.Font, r: rl.Rectangle, busy: bool) {
	FH :: f32(28)
	ui_list_filter_draw(&_demo.list, font, {r.x, r.y, r.width, FH}, "Type to filter branches...")
	lr := rl.Rectangle{r.x, r.y + FH + 6, r.width, r.height - FH - 6}
	_demo.list_vis = int(lr.height / UI_ROW_H)
	_, dbl := ui_list_draw(&_demo.list, font, lr, _UI_DEMO_ITEMS, UI_ROW_H, !busy)
	if dbl { ui_banner_show(fmt.tprintf("Opened %q", _ui_demo_selected())) }
	if !busy && ui_right_clicked(lr) && ui_list_selected_item(&_demo.list) >= 0 {
		ui_menu_open(&_demo.menu, rl.GetMousePosition(), _UI_DEMO_MENU)
	}
}
