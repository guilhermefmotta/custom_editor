package editor

import "core:fmt"
import re  "core:text/regex"
import dbg "./debug"
import rl  "vendor:raylib"

// On macOS Command acts as Ctrl for every editor shortcut (Cmd+P, Cmd+Shift+F…);
// the physical Ctrl key keeps working too.
when ODIN_OS == .Darwin {
	ctrl :: proc() -> bool {
		return rl.IsKeyDown(.LEFT_SUPER) || rl.IsKeyDown(.RIGHT_SUPER) ||
		       rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
	}
	ctrl_released :: proc() -> bool {
		return rl.IsKeyReleased(.LEFT_SUPER) || rl.IsKeyReleased(.RIGHT_SUPER) ||
		       rl.IsKeyReleased(.LEFT_CONTROL) || rl.IsKeyReleased(.RIGHT_CONTROL)
	}
} else {
	ctrl :: proc() -> bool { return rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL) }
	ctrl_released :: proc() -> bool { return rl.IsKeyReleased(.LEFT_CONTROL) || rl.IsKeyReleased(.RIGHT_CONTROL) }
}
shift :: proc() -> bool { return rl.IsKeyDown(.LEFT_SHIFT)   || rl.IsKeyDown(.RIGHT_SHIFT) }
alt   :: proc() -> bool { return rl.IsKeyDown(.LEFT_ALT)     || rl.IsKeyDown(.RIGHT_ALT) }

// --- Key repeat ---
_rep_key:  rl.KeyboardKey = .KEY_NULL
_rep_accum: f32 = 0
_rep_init: bool = false

REP_DELAY :: f32(0.380)
REP_RATE  :: f32(0.040)

key_rep :: proc(key: rl.KeyboardKey) -> bool {
	if rl.IsKeyPressed(key) {
		_rep_key   = key
		_rep_accum = 0
		_rep_init  = false
		return true
	}
	if _rep_key == key {
		if !rl.IsKeyDown(key) { _rep_key = .KEY_NULL; return false }
		_rep_accum += frame_dt // real dt (ADR 0016: GetFrameTime lags one frame and includes sleeps)
		if !_rep_init {
			if _rep_accum < REP_DELAY { return false }
			_rep_init = true; _rep_accum = 0; return true
		}
		if _rep_accum >= REP_RATE { _rep_accum = 0; return true }
	}
	return false
}

// --- Top-level dispatcher ---
//
// Input pipeline, in order:
//   Global shortcuts -> Debug shortcuts -> Modal dialogs -> Panels ->
//   LSP shortcuts -> Navigation -> Mouse -> Edit shortcuts ->
//   Cursor movement -> Text editing -> Character insertion
//
// Each phase either fully handles the frame's input and returns `true`
// (caller stops immediately, matching the original early-`return`s), or
// returns `false` and the next phase gets a turn. Order matches the
// original monolithic function exactly, so behavior is unchanged.

handle_input :: proc(e: ^Editor, font: rl.Font) {
	if handle_global_shortcuts(e)      { return }
	if handle_debug_shortcuts(e)       { return }
	if handle_dialogs(e)               { return }
	if handle_panels(e)                { return }
	if handle_lsp_shortcuts(e)         { return }
	if handle_navigation(e)            { return }

	handle_mouse(e, font)
	p := active_pane(e)

	// Markdown preview is read-only and swallows keyboard input uniformly
	// across Normal/Vim/Emacs — checked here, before the mode switch below,
	// so it doesn't have to be special-cased into each mode's own dispatch.
	if handle_md_preview(e, p) { return }
	if handle_image_view(e, p) { return }

	// Dialogs/palette/LSP-shortcuts/navigation/mouse above are shared across every
	// keymap mode. Only "core buffer editing" (the rest of this proc, historically)
	// diverges per mode — Vim/Emacs own 100% of key interpretation in their modal
	// states, so they don't call handle_edit_shortcuts/handle_cursor_movement/
	// handle_text_editing/handle_character_input the way Normal mode does.
	switch e.cfg.editor.keymap_mode {
	case .Normal:
		if handle_edit_shortcuts(e, p) { return }

		cursor_before := p.cursor
		handle_cursor_movement(p)

		text_changed := false
		text_changed |= handle_text_editing(p)
		text_changed |= handle_character_input(p)

		if p.cursor != cursor_before { lsp_on_cursor_moved(e, p) }
		if text_changed { lsp_on_text_changed(e, p) }
	case .Vim:
		vim_handle_input(e, p)
	case .Emacs:
		emacs_handle_input(e, p)
	}
}

// -----------------------------------------------------
// Global shortcuts
// -----------------------------------------------------

handle_global_shortcuts :: proc(e: ^Editor) -> bool {
	// Ctrl+Q always quits, regardless of any open dialog
	if ctrl() && rl.IsKeyPressed(.Q) { e.should_quit = true; return true }
	return false
}

// -----------------------------------------------------
// Debug shortcuts
// -----------------------------------------------------

handle_debug_shortcuts :: proc(e: ^Editor) -> bool {
	// ── Debug stepping shortcuts — global, work even with the debug panel
	// or another dialog open, so you can keep it visible while stepping ──
	// F9 / Ctrl+B → toggle breakpoint at current line
	// (Ctrl+B skipped in Emacs keymap — that's C-b/move-left there)
	if rl.IsKeyPressed(.F9) || (ctrl() && !shift() && rl.IsKeyPressed(.B) && e.cfg.editor.keymap_mode != .Emacs) {
		p := active_pane(e)
		if p.filename != "" {
			line, _ := buffer_pos_to_line_col(&p.buf, p.cursor)
			_dbg_bp_toggle(e, p.filename, line + 1)
		}
		return true
	}
	// F5 → start or continue
	if rl.IsKeyPressed(.F5) {
		import_dbg_start_or_continue(e)
		return true
	}
	// Shift+F5 → stop
	if shift() && rl.IsKeyPressed(.F5) {
		import_dbg_stop(e)
		return true
	}
	// F10 → step over
	if rl.IsKeyPressed(.F10) {
		import_dbg_next(e)
		return true
	}
	// F11 → step into
	if rl.IsKeyPressed(.F11) && !shift() {
		import_dbg_step_in(e)
		return true
	}
	// Shift+F11 → step out
	if shift() && rl.IsKeyPressed(.F11) {
		import_dbg_step_out(e)
		return true
	}

	// Debug panel is a persistent (non-modal) dock, not a dialog: it only eats
	// keyboard input while focused. Clicking inside its rect focuses it;
	// clicking elsewhere (e.g. back in the editor) releases focus so normal
	// editing keeps working while the panel stays visible. ESC closes it even
	// when unfocused, since there'd otherwise be no way to dismiss it without
	// clicking back into it first.
	if e.debug_panel.visible {
		if rl.IsMouseButtonPressed(.LEFT) {
			mp := rl.GetMousePosition()
			panel_top := f32(screen_h()) - MSG_LINE_H - DEBUG_PANEL_H
			e.debug_panel.focused = mp.y >= panel_top && mp.y < panel_top+DEBUG_PANEL_H
		}
		// Skip when a modal debug dialog is open on top — that should eat ESC
		// first (handled later, in handle_panels/handle_dialogs), not this
		// panel underneath it.
		if !e.debug_panel.focused && !e.debug_eval.open && !e.debug_attach.open && rl.IsKeyPressed(.ESCAPE) {
			debug_panel_close(e, &e.debug_panel)
			return true
		}
	}

	return false
}

// -----------------------------------------------------
// Modal dialogs
// -----------------------------------------------------

handle_dialogs :: proc(e: ^Editor) -> bool {
	// Priority: delete_confirm > lsp_dialog > recents > workspace_dlg > save_dlg > file_tree > outline > find_rep > mark_dlg > goto_dlg > palette > normal
	if e.delete_confirm       { delete_confirm_handle_input(e); return true }
	if e.git_dialog.visible   { git_dialog_handle_input(&e.git_dialog, e); return true }
	if e.lsp_dialog.visible   { lsp_dialog_handle_input(&e.lsp_dialog, e); return true }
	if e.recents.open         { recents_handle_input(&e.recents, e); return true }
	if e.workspace_dlg.open   { workspace_dialog_handle_input(&e.workspace_dlg, e); return true }
	if e.save_dlg.open        { save_dialog_handle_input(e); return true }
	if e.file_tree.open       { file_tree_handle_input(&e.file_tree, e); return true }
	if e.outline.open    { outline_handle_input(&e.outline, active_pane(e)); return true }
	if e.find_rep.open  { find_replace_handle_input(e); return true }
	if e.mark_dlg.open  { mark_dialog_handle_input(e); return true }
	if e.goto_dlg.open   { goto_dialog_handle_input(e); return true }
	if e.def_picker.open { goto_def_picker_handle_input(e); return true }

	// Rename dialog (F2)
	if e.rename_dlg.open {
		new_name, confirmed := rename_dialog_handle_input(&e.rename_dlg)
		if confirmed { lsp_rename_confirm(e, new_name) }
		return true
	}

	// Code action dialog (Ctrl+.)
	if e.code_action_dlg.open {
		_, sel := code_action_dialog_handle_input(&e.code_action_dlg)
		if sel >= 0 { lsp_apply_code_action(e, sel) }
		return true
	}

	// Debug dialogs — high priority, before other key bindings
	if e.debug_attach.open  { debug_attach_handle_input(e, &e.debug_attach); return true }
	if e.debug_eval.open    { debug_eval_handle_input(e, &e.debug_eval); return true }
	if e.debug_panel.visible && e.debug_panel.focused { debug_panel_handle_input(e, &e.debug_panel); return true }

	return false
}

// -----------------------------------------------------
// Panels (palette, debug panel/eval openers)
// -----------------------------------------------------

handle_panels :: proc(e: ^Editor) -> bool {
	if e.palette.open {
		palette_handle_input(&e.palette, e)
		return true
	}

	if ctrl() && shift() && rl.IsKeyPressed(.P) {
		palette_open(&e.palette)
		return true
	}

	// Registered panels/shortcuts (ui_registry.odin) — topmost open panel
	// gets input before the editor.
	if ui_registry_handle_input(e) { return true }

	// Ctrl+E (with or without Shift) → open the evaluate-expression dialog
	// (modal popup, IntelliJ-style) with selected text pre-filled.
	if ctrl() && rl.IsKeyPressed(.E) {
		sel := _get_selected_text(active_pane(e))
		debug_eval_open(&e.debug_eval, sel)
		return true
	}

	// Ctrl+Shift+V → toggle Markdown preview for the active pane (no-op on
	// non-.md files; VSCode uses the same combo for "Open Preview").
	if ctrl() && shift() && rl.IsKeyPressed(.V) {
		md_preview_toggle(active_pane(e))
		return true
	}

	return false
}

// -----------------------------------------------------
// Markdown preview (read-only scroll while a .md pane is in preview mode)
// -----------------------------------------------------

handle_md_preview :: proc(e: ^Editor, p: ^Pane) -> bool {
	if !p.md_preview.visible { return false }

	line_h     := FONT_SIZE + LINE_SPACING
	max_scroll := max(f32(0), p.md_preview.content_h - p.md_preview.viewport_h)

	if key_rep(.DOWN)         { p.md_preview.scroll += line_h * 3 }
	if key_rep(.UP)           { p.md_preview.scroll -= line_h * 3 }
	if key_rep(.PAGE_DOWN)    { p.md_preview.scroll += p.md_preview.viewport_h }
	if key_rep(.PAGE_UP)      { p.md_preview.scroll -= p.md_preview.viewport_h }
	if rl.IsKeyPressed(.HOME) { p.md_preview.scroll = 0 }
	if rl.IsKeyPressed(.END)  { p.md_preview.scroll = max_scroll }

	p.md_preview.scroll = clamp(p.md_preview.scroll, 0, max_scroll)
	return true
}

// -----------------------------------------------------
// LSP shortcuts
// -----------------------------------------------------

handle_lsp_shortcuts :: proc(e: ^Editor) -> bool {
	// LSP manual completion
	if ctrl() && rl.IsKeyPressed(.SPACE) {
		lsp_trigger_completion_manual(e, active_pane(e))
		return true
	}

	// Ctrl+Shift+I → format document
	if ctrl() && shift() && rl.IsKeyPressed(.I) {
		lsp_format_document(e)
		return true
	}

	// F2 → rename symbol
	if rl.IsKeyPressed(.F2) {
		lsp_rename_open(e)
		return true
	}

	// Ctrl+. / Alt+Enter → code actions (quick fixes, e.g. "Assign statement
	// to new local variable", "Add missing import", "Add cast", ...).
	// Alt+Enter must be checked before the plain-Enter handler below —
	// otherwise it would also insert a newline.
	if (ctrl() && rl.IsKeyPressed(.PERIOD)) || (alt() && rl.IsKeyPressed(.ENTER)) {
		lsp_code_actions_request(e)
		return true
	}

	return false
}

// -----------------------------------------------------
// Navigation
// -----------------------------------------------------

handle_navigation :: proc(e: ^Editor) -> bool {
	// Alt+Z → toggle word wrap
	if alt() && rl.IsKeyPressed(.Z) {
		p := active_pane(e)
		p.word_wrap = !p.word_wrap
		e.msg = "Word wrap: on" if p.word_wrap else "Word wrap: off"
		return true
	}

	// Font size in every keymap mode (it used to live in the normal keymap only)
	if ctrl() && !alt() {
		if rl.IsKeyPressed(.EQUAL) || rl.IsKeyPressed(.KP_ADD)      { font_zoom(e, +FONT_ZOOM_STEP); return true }
		if rl.IsKeyPressed(.MINUS) || rl.IsKeyPressed(.KP_SUBTRACT) { font_zoom(e, -FONT_ZOOM_STEP); return true }
		if !shift() && (rl.IsKeyPressed(.ZERO) || rl.IsKeyPressed(.KP_0)) { font_zoom_reset(e); return true }
	}

	// Splits like Emacs's C-x 2 / C-x 3 / C-x 1, in every keymap mode
	// (Ctrl+Alt+digit stays "Repo: Switch to N")
	if ctrl() && !alt() && !shift() {
		if rl.IsKeyPressed(.TWO)   || rl.IsKeyPressed(.KP_2) { editor_split(e, .Horizontal); return true }
		if rl.IsKeyPressed(.THREE) || rl.IsKeyPressed(.KP_3) { editor_split(e, .Vertical);   return true }
		if rl.IsKeyPressed(.ONE)   || rl.IsKeyPressed(.KP_1) { editor_close_split(e);        return true }
	}

	// Close the current file tab (asks if unsaved). macOS: the physical Cmd+W —
	// Ctrl+W stays Vim's window prefix / Emacs's kill-region. Elsewhere: Ctrl+W
	// in the normal keymap only (Vim/Emacs keep theirs; use :q / "Close Tab").
	when ODIN_OS == .Darwin {
		if (rl.IsKeyDown(.LEFT_SUPER) || rl.IsKeyDown(.RIGHT_SUPER)) && !shift() && !alt() && rl.IsKeyPressed(.W) {
			editor_close_tab_request(e)
			return true
		}
	} else {
		if e.cfg.editor.keymap_mode == .Normal && ctrl() && !shift() && !alt() && rl.IsKeyPressed(.W) {
			editor_close_tab_request(e)
			return true
		}
	}

	// Ctrl+PageUp → previous tab; Ctrl+PageDown → next tab
	if ctrl() && rl.IsKeyPressed(.PAGE_UP) {
		pane_tab_prev(active_pane(e))
		lsp_on_open(e, active_pane(e))
		return true
	}
	if ctrl() && rl.IsKeyPressed(.PAGE_DOWN) {
		pane_tab_next(active_pane(e))
		lsp_on_open(e, active_pane(e))
		return true
	}

	// Suggest widget intercepts keys when visible
	if active_pane(e).suggest.visible {
		if suggest_handle_input(e, active_pane(e)) { return true }
	}

	// Go to Definition / Find References / Navigation history
	if rl.IsKeyPressed(.F12)                     { lsp_goto_definition(e, active_pane(e)); return true }
	if ctrl() && rl.IsKeyPressed(.I)             { lsp_find_references(e, active_pane(e)); return true }
	if ctrl() && rl.IsKeyPressed(.LEFT_BRACKET)  { nav_go_back(&e.nav_hist, e); return true }
	if ctrl() && rl.IsKeyPressed(.RIGHT_BRACKET) { nav_go_forward(&e.nav_hist, e); return true }

	// Ctrl+F12 → Go to Implementation ; Ctrl+Shift+F12 → Go to Type Definition
	if ctrl() && rl.IsKeyPressed(.F12) {
		if shift() { lsp_goto_type_definition(e, active_pane(e)) } else { lsp_goto_implementation(e, active_pane(e)) }
		return true
	}
	// Ctrl+Shift+O → Go to Symbol in File ; Ctrl+T → Go to Symbol in Workspace
	if ctrl() && shift() && rl.IsKeyPressed(.O) { lsp_document_symbols_open(e, active_pane(e)); return true }
	if ctrl() && rl.IsKeyPressed(.T)            { lsp_workspace_symbols_open(e); return true }
	// Ctrl+Shift+M → Problems (errors/warnings in current file)
	if ctrl() && shift() && rl.IsKeyPressed(.M) { cmd_lsp_problems(e, &e.palette); return true }

	// Ctrl+; open file tree
	if ctrl() && rl.IsKeyPressed(.SEMICOLON) {
		file_tree_open(&e.file_tree)
		return true
	}

	if ctrl() && shift() && rl.IsKeyPressed(.W) { editor_close_split(e); return true }
	if ctrl() && shift() && rl.IsKeyPressed(.F) { palette_open_search(&e.palette, e); return true }
	if ctrl() && shift() && rl.IsKeyPressed(.L) {
		e.panes[e.active].show_line_numbers = !e.panes[e.active].show_line_numbers
		return true
	}

	// Ctrl+O cycle active pane
	if ctrl() && rl.IsKeyPressed(.O) {
		if len(e.panes) > 1 { e.active = (e.active + 1) % len(e.panes) }
		return true
	}

	return false
}

// -----------------------------------------------------
// Mouse input
// -----------------------------------------------------

handle_mouse :: proc(e: ^Editor, font: rl.Font) {
	sw := f32(screen_w())
	sh := f32(screen_h()) - MSG_LINE_H
	if e.debug_panel.visible { sh -= DEBUG_PANEL_H }

	// Image panes: wheel zooms, drag pans (image_view.odin)
	{
		mp := rl.GetMousePosition()
		wheel := rl.GetMouseWheelMove()
		for i in 0 ..< len(e.panes) {
			if image_view_mouse(&e.panes[i], mp, wheel) {
				if rl.IsMouseButtonPressed(.LEFT) { e.active = i }
				return
			}
		}
	}

	// Wheel over a pane in Markdown preview scrolls the rendered preview.
	if wheel := rl.GetMouseWheelMove(); wheel != 0 {
		mp := rl.GetMousePosition()
		for i in 0 ..< len(e.panes) {
			mpv := &e.panes[i].md_preview
			if !mpv.visible { continue }
			px2, py2, pw2, ph2 := get_pane_rect(e, i, sw, sh)
			if mp.x >= px2 && mp.x < px2+pw2 && mp.y >= py2 && mp.y < py2+ph2 {
				max_scroll := max(f32(0), mpv.content_h - mpv.viewport_h)
				mpv.scroll = clamp(mpv.scroll - wheel*40, 0, max_scroll)
				break
			}
		}
	}

	// Mouse click: switch active pane / position cursor / alt+click adds extra cursor
	if rl.IsMouseButtonPressed(.LEFT) {
		mp := rl.GetMousePosition()
		clicked := -1
		for i in 0 ..< len(e.panes) {
			px2, py2, pw2, ph2 := get_pane_rect(e, i, sw, sh)
			if mp.x >= px2 && mp.x < px2+pw2 && mp.y >= py2 && mp.y < py2+ph2 { clicked = i; break }
		}
		if clicked >= 0 {
			cp := &e.panes[clicked]
			// Check tab bar click
			tab_h := TAB_BAR_H if len(cp.tabs) > 0 else f32(0)
			px2, py2, _, _ := get_pane_rect(e, clicked, sw, sh)
			tab_bar_y := py2 + PANE_TOP_PAD
			if tab_h > 0 && mp.y >= tab_bar_y && mp.y < tab_bar_y + tab_h {
				// Hit tab bar: find which tab
				e.active = clicked
				tx := px2
				for ti in 0..<len(cp.tabs) {
					lbl := path_basename(cp.tabs[ti].filename)
					dirty_mark := "* " if cp.tabs[ti].dirty else ""
					tab_label  := fmt.tprintf(" %s%s ", dirty_mark, lbl)
					tw := rl.MeasureTextEx(font, to_cstring(tab_label), FONT_SIZE - 2, CHAR_SPACING).x + 8
					if mp.x >= tx && mp.x < tx + tw {
						if ti != cp.cur_tab {
							_pane_save_tab_state(cp)
							cp.cur_tab = ti
							_pane_load_tab(cp, ti)
							lsp_on_open(e, cp)
						}
						break
					}
					tx += tw + 1
				}
			} else if alt() && clicked == e.active {
				// Alt+click: add extra cursor, keep primary
				mc_add(active_pane(e), mouse_to_cursor(active_pane(e), font, mp, px2, py2))
			} else {
				e.active = clicked
				ap       := active_pane(e)
				mc_clear(ap)
				px2b, py2b, _, _ := get_pane_rect(e, e.active, sw, sh)
				pos        := mouse_to_cursor(ap, font, mp, px2b, py2b)
				ap.cursor   = pos
				ap.sel_anchor = pos
			}
		}
	}
	if rl.IsMouseButtonDown(.LEFT) && !rl.IsMouseButtonPressed(.LEFT) {
		p            := active_pane(e)
		px, py, _, _ := get_pane_rect(e, e.active, sw, sh)
		p.cursor      = mouse_to_cursor(p, font, rl.GetMousePosition(), px, py)
	}
}

// -----------------------------------------------------
// Edit shortcuts (multi-cursor, clipboard, splits, zoom)
// -----------------------------------------------------

handle_edit_shortcuts :: proc(e: ^Editor, p: ^Pane) -> bool {
	// Alt combos — multi-cursor add, word jump, line move
	// Alt+Down/Up:       add cursor (plain Alt only; Ctrl+Alt does nothing)
	// Alt+Right/Left:    word jump/select on all cursors
	// Shift+Alt+Down/Up: move lines
	if alt() {
		s := shift()
		if !s {
			// Only plain Alt adds cursors; Ctrl+Alt is consumed so it won't fall through.
			if key_rep(.DOWN)  { if !ctrl() { mc_add_below(p) };                          return true }
			if key_rep(.UP)    { if !ctrl() { mc_add_above(p) };                          return true }
			if key_rep(.RIGHT) { if mc_has_extras(p) { mc_word_right_all(p, false) } else { move_word_right(p, false) }; return true }
			if key_rep(.LEFT)  { if mc_has_extras(p) { mc_word_left_all(p,  false) } else { move_word_left(p,  false) }; return true }
		} else if !ctrl() {
			// Shift+Alt: move lines / word-select
			if key_rep(.DOWN)  { do_move_lines_down(p); lsp_on_text_changed(e, p); return true }
			if key_rep(.UP)    { do_move_lines_up(p);   lsp_on_text_changed(e, p); return true }
			if key_rep(.RIGHT) { if mc_has_extras(p) { mc_word_right_all(p, true) } else { move_word_right(p, true) }; return true }
			if key_rep(.LEFT)  { if mc_has_extras(p) { mc_word_left_all(p,  true) } else { move_word_left(p,  true) }; return true }
		}
	}

	// Escape collapses multi-cursor to primary
	if rl.IsKeyPressed(.ESCAPE) && mc_has_extras(p) { mc_clear(p); return true }

	if ctrl() {
		if rl.IsKeyPressed(.S) { editor_save(e); lsp_on_save(e, active_pane(e)); return true }
		if rl.IsKeyPressed(.Z) { pane_undo(p); lsp_on_text_changed(e, p); return true }
		if rl.IsKeyPressed(.Y) { pane_redo(p); lsp_on_text_changed(e, p); return true }
		if rl.IsKeyPressed(.D) { do_kill_line(p); lsp_on_text_changed(e, p); return true }
		if rl.IsKeyPressed(.A) { mc_clear(p); sel_all(p); return true }
		if rl.IsKeyPressed(.C) { copy_sel(p);              return true }
		if rl.IsKeyPressed(.W) { editor_split(e, .Vertical); return true }
		if rl.IsKeyPressed(.X) { cut_sel(p); lsp_on_text_changed(e, p); return true }
		if rl.IsKeyPressed(.V) { paste(p); lsp_on_text_changed(e, p); return true }
		if rl.IsKeyPressed(.F) { find_replace_open(e); return true }
		if rl.IsKeyPressed(.G) { goto_dialog_open(e); return true }
		if rl.IsKeyPressed(.N) { cmd_new_file(e, &e.palette); return true }
		if rl.IsKeyPressed(.P) { palette_open_files(&e.palette, e); return true }
		if rl.IsKeyPressed(.TAB) { recents_open(&e.recents); return true }
		if rl.IsKeyPressed(.Q)   { e.should_quit = true; return true }
		if rl.IsKeyPressed(.SLASH) { do_comment_toggle(p); lsp_on_text_changed(e, p); return true }
		if key_rep(.LEFT)      { mc_clear(p); move_word_left(p,  shift()); return true }
		if key_rep(.RIGHT)     { mc_clear(p); move_word_right(p, shift()); return true }
		if rl.IsKeyPressed(.HOME) { mc_clear(p); move_doc_start(p, shift()); return true }
		if rl.IsKeyPressed(.END)  { mc_clear(p); move_doc_end(p,   shift()); return true }
	}

	return false
}

// -----------------------------------------------------
// Cursor movement
// -----------------------------------------------------

handle_cursor_movement :: proc(p: ^Pane) {
	if key_rep(.LEFT)      { if mc_has_extras(p) { mc_move_all_left(p,  shift()) } else { move_left(p,  shift()) } }
	if key_rep(.RIGHT)     { if mc_has_extras(p) { mc_move_all_right(p, shift()) } else { move_right(p, shift()) } }
	if key_rep(.UP) {
		if ctrl() { for _ in 0..<10 { move_up(p, shift()) } } else if mc_has_extras(p) { mc_move_all_up(p, shift()) } else { move_up(p, shift()) }
	}
	if key_rep(.DOWN) {
		if ctrl() { for _ in 0..<10 { move_down(p, shift()) } } else if mc_has_extras(p) { mc_move_all_down(p, shift()) } else { move_down(p, shift()) }
	}
	if key_rep(.HOME)      { mc_clear(p); move_bol(p,   shift()) }
	if key_rep(.END)       { mc_clear(p); move_eol(p,   shift()) }
	if key_rep(.PAGE_UP)   { mc_clear(p); move_page(p, -1, shift()) }
	if key_rep(.PAGE_DOWN) { mc_clear(p); move_page(p,  1, shift()) }
}

// -----------------------------------------------------
// Text editing (backspace, delete, enter, tab/indent)
// -----------------------------------------------------

handle_text_editing :: proc(p: ^Pane) -> bool {
	text_changed := false

	if key_rep(.BACKSPACE) {
		if mc_has_extras(p) { mc_backspace(p) } else { do_backspace(p) }
		text_changed = true
	}
	if key_rep(.DELETE) {
		if mc_has_extras(p) { mc_delete_fwd(p) } else { do_delete(p) }
		text_changed = true
	}

	if rl.IsKeyPressed(.ENTER) {
		if mc_has_extras(p) {
			mc_insert_bytes(p, []u8{'\n'})
		} else {
			undo_delete_sel(p)
			_auto_indent_enter(p)
			undo_break(p)
		}
		text_changed = true
	}

	if rl.IsKeyPressed(.TAB) {
		if mc_has_extras(p) {
			if shift() { mc_backspace(p) } else { mc_insert_bytes(p, []u8{' ',' ',' ',' '}) }
			text_changed = true
		} else if has_selection(p) {
			if shift() { do_dedent_sel(p) } else { do_indent_sel(p) }
			text_changed = true
		} else if shift() {
			do_dedent_line(p)
			text_changed = true
		} else {
			spaces := []u8{' ', ' ', ' ', ' '}
			undo_push_insert(p, p.cursor, spaces, false)
			undo_break(p)
			for _ in 0 ..< 4 {
				buffer_insert_byte(&p.buf, p.cursor, ' ')
				p.cursor += 1
			}
			p.sel_anchor = p.cursor
			p.dirty      = true
			text_changed = true
		}
	}

	return text_changed
}

// -----------------------------------------------------
// Character insertion
// -----------------------------------------------------

handle_character_input :: proc(p: ^Pane) -> bool {
	text_changed := false

	for {
		ch := rl.GetCharPressed()
		if ch == 0 { break }
		if ch < 32 { continue }

		utf_buf: [4]u8
		n := rune_encode(ch, &utf_buf)

		if mc_has_extras(p) {
			mc_insert_bytes(p, utf_buf[:n])
			text_changed = true
			continue
		}

		if n == 1 {
			b    := utf_buf[0]
			blen := buffer_len(&p.buf)
			next : u8 = 0
			if p.cursor < blen { next = buffer_get_byte(&p.buf, p.cursor) }

			// Skip over existing closing bracket/quote when typing it
			is_close := b == ')' || b == ']' || b == '}'
			is_quote  := b == '"' || b == '\'' || b == '`'
			if (is_close || is_quote) && next == b && !has_selection(p) {
				p.cursor += 1
				p.sel_anchor = p.cursor
				text_changed = true
				continue
			}

			undo_delete_sel(p)
			undo_push_insert(p, p.cursor, utf_buf[:1], true)
			buffer_insert_byte(&p.buf, p.cursor, b)
			p.cursor     += 1
			p.sel_anchor  = p.cursor
			p.dirty       = true

			// Auto-close: insert matching char after cursor
			blen2 := buffer_len(&p.buf)
			next2 : u8 = 0
			if p.cursor < blen2 { next2 = buffer_get_byte(&p.buf, p.cursor) }
			can_close := p.cursor >= blen2 || next2 == '\n' || next2 == ' ' || next2 == '\t' ||
			             next2 == ')' || next2 == ']' || next2 == '}' ||
			             next2 == '"' || next2 == '\'' || next2 == '`'

			close: u8 = 0
			if !has_selection(p) {
				switch b {
				case '(': close = ')'
				case '[': close = ']'
				case '{': close = '}'
				case '"':  if can_close && next2 != '"'  { close = '"'  }
				case '\'': if can_close && next2 != '\'' { close = '\'' }
				case '`':  if can_close && next2 != '`'  { close = '`'  }
				}
			}
			if close != 0 && can_close && (close == ')' || close == ']' || close == '}' || next2 != close) {
				buffer_insert_byte(&p.buf, p.cursor, close)
				p.dirty = true
			}
		} else {
			// Multi-byte UTF-8: no auto-pair
			undo_delete_sel(p)
			undo_push_insert(p, p.cursor, utf_buf[:n], true)
			for i in 0..<n { buffer_insert_byte(&p.buf, p.cursor+i, utf_buf[i]) }
			p.cursor     += n
			p.sel_anchor  = p.cursor
			p.dirty       = true
		}
		text_changed = true
	}

	return text_changed
}

// --- Delete confirm ---

delete_confirm_handle_input :: proc(e: ^Editor) {
	if rl.IsKeyPressed(.ESCAPE) || rl.IsKeyPressed(.N) { e.delete_confirm = false; return }
	if rl.IsKeyPressed(.Y)                              { delete_file_confirm(e); return }
}

// --- Save dialog ---

save_dialog_handle_input :: proc(e: ^Editor) {
	dlg := &e.save_dlg
	if rl.IsKeyPressed(.ESCAPE) { save_dialog_close(e); return }
	if rl.IsKeyPressed(.ENTER)  { save_dialog_confirm(e); return }
	text_input_handle(&dlg.input, &dlg.sel_all)
}

mark_dialog_handle_input :: proc(e: ^Editor) {
	dlg := &e.mark_dlg
	if rl.IsKeyPressed(.ESCAPE) { mark_dialog_close(e); return }
	if rl.IsKeyPressed(.ENTER)  { mark_dialog_confirm(e); return }
	text_input_handle(&dlg.input, &dlg.sel_all)
}

goto_dialog_handle_input :: proc(e: ^Editor) {
	dlg := &e.goto_dlg
	if rl.IsKeyPressed(.ESCAPE) { goto_dialog_close(e); return }
	if rl.IsKeyPressed(.ENTER)  { goto_dialog_confirm(e); return }
	text_input_handle(&dlg.input, &dlg.sel_all, accept_digit)
}

// --- Cursor movement (all take ^Pane) ---

move_left :: proc(p: ^Pane, selecting: bool) {
	if !selecting && has_selection(p) {
		v := sel_lo(p); p.cursor = v; p.sel_anchor = v
		return
	}
	if p.cursor > 0 {
		p.cursor -= 1
		for p.cursor > 0 && (buffer_get_byte(&p.buf, p.cursor) & 0xC0) == 0x80 {
			p.cursor -= 1
		}
	}
	if !selecting do p.sel_anchor = p.cursor
}

move_right :: proc(p: ^Pane, selecting: bool) {
	if !selecting && has_selection(p) {
		v := sel_hi(p); p.cursor = v; p.sel_anchor = v
		return
	}
	n := buffer_len(&p.buf)
	if p.cursor < n {
		p.cursor += 1
		for p.cursor < n && (buffer_get_byte(&p.buf, p.cursor) & 0xC0) == 0x80 {
			p.cursor += 1
		}
	}
	if !selecting do p.sel_anchor = p.cursor
}

move_up :: proc(p: ^Pane, selecting: bool) {
	line, col := buffer_pos_to_line_col(&p.buf, p.cursor)
	if line == 0 {
		p.cursor = 0
	} else {
		start    := buffer_line_start(&p.buf, line - 1)
		p.cursor  = start + min(col, buffer_line_length(&p.buf, line - 1))
	}
	if !selecting do p.sel_anchor = p.cursor
}

move_down :: proc(p: ^Pane, selecting: bool) {
	line, col := buffer_pos_to_line_col(&p.buf, p.cursor)
	total     := buffer_line_count(&p.buf)
	if line < total - 1 {
		start    := buffer_line_start(&p.buf, line + 1)
		p.cursor  = start + min(col, buffer_line_length(&p.buf, line + 1))
	} else {
		p.cursor = buffer_len(&p.buf)
	}
	if !selecting do p.sel_anchor = p.cursor
}

move_bol :: proc(p: ^Pane, selecting: bool) {
	line, _ := buffer_pos_to_line_col(&p.buf, p.cursor)
	p.cursor = buffer_line_start(&p.buf, line)
	if !selecting do p.sel_anchor = p.cursor
}

move_eol :: proc(p: ^Pane, selecting: bool) {
	line, _ := buffer_pos_to_line_col(&p.buf, p.cursor)
	p.cursor = buffer_line_start(&p.buf, line) + buffer_line_length(&p.buf, line)
	if !selecting do p.sel_anchor = p.cursor
}

move_doc_start :: proc(p: ^Pane, selecting: bool) {
	p.cursor = 0
	if !selecting do p.sel_anchor = 0
}

move_doc_end :: proc(p: ^Pane, selecting: bool) {
	p.cursor = buffer_len(&p.buf)
	if !selecting do p.sel_anchor = p.cursor
}

move_word_left :: proc(p: ^Pane, selecting: bool) {
	if p.cursor > 0 {
		p.cursor -= 1
		for p.cursor > 0 && !is_word(buffer_get_byte(&p.buf, p.cursor)) { p.cursor -= 1 }
		for p.cursor > 0 &&  is_word(buffer_get_byte(&p.buf, p.cursor - 1)) { p.cursor -= 1 }
	}
	if !selecting do p.sel_anchor = p.cursor
}

move_word_right :: proc(p: ^Pane, selecting: bool) {
	n := buffer_len(&p.buf)
	for p.cursor < n &&  is_word(buffer_get_byte(&p.buf, p.cursor)) { p.cursor += 1 }
	for p.cursor < n && !is_word(buffer_get_byte(&p.buf, p.cursor)) { p.cursor += 1 }
	if !selecting do p.sel_anchor = p.cursor
}

move_page :: proc(p: ^Pane, dir: int, selecting: bool) {
	for _ in 0 ..< 20 {
		if dir < 0 { move_up(p, true) } else { move_down(p, true) }
	}
	if !selecting do p.sel_anchor = p.cursor
}

sel_all :: proc(p: ^Pane) {
	p.sel_anchor = 0
	p.cursor     = buffer_len(&p.buf)
}

_auto_indent_enter :: proc(p: ^Pane) {
	line, _ := buffer_pos_to_line_col(&p.buf, p.cursor)
	ls      := buffer_line_start(&p.buf, line)
	blen    := buffer_len(&p.buf)

	// Measure current line indent
	indent := 0
	for ls+indent < blen {
		b := buffer_get_byte(&p.buf, ls+indent)
		if b != ' ' && b != '\t' { break }
		indent += 1
	}
	indent_bytes := make([]u8, indent, context.temp_allocator)
	for i in 0..<indent { indent_bytes[i] = buffer_get_byte(&p.buf, ls+i) }

	// Char before cursor (skip trailing whitespace)
	char_before: u8
	check := p.cursor - 1
	for check >= ls && (buffer_get_byte(&p.buf, check) == ' ' || buffer_get_byte(&p.buf, check) == '\t') { check -= 1 }
	if check >= ls { char_before = buffer_get_byte(&p.buf, check) }

	// Char at cursor position (skip leading whitespace)
	check2 := p.cursor
	for check2 < blen && (buffer_get_byte(&p.buf, check2) == ' ' || buffer_get_byte(&p.buf, check2) == '\t') { check2 += 1 }
	char_after: u8
	if check2 < blen && buffer_get_byte(&p.buf, check2) != '\n' { char_after = buffer_get_byte(&p.buf, check2) }

	opens  := char_before == '{' || char_before == '(' || char_before == '[' || char_before == ':'
	closes := char_after  == '}' || char_after  == ')' || char_after  == ']'

	ins: [1024]u8
	n := 0
	ins[n] = '\n'; n += 1
	copy(ins[n:], indent_bytes); n += indent

	cursor_pos: int
	if opens {
		for _ in 0..<4 { ins[n] = ' '; n += 1 }
		cursor_pos = p.cursor + n
		if closes {
			ins[n] = '\n'; n += 1
			copy(ins[n:], indent_bytes); n += indent
		}
	} else {
		cursor_pos = p.cursor + n
	}

	undo_push_insert(p, p.cursor, ins[:n], false)
	for b in ins[:n] { buffer_insert_byte(&p.buf, p.cursor, b); p.cursor += 1 }
	p.cursor     = cursor_pos
	p.sel_anchor = p.cursor
	p.dirty      = true
}

// --- Edit actions ---

do_backspace :: proc(p: ^Pane) {
	if undo_delete_sel(p) do return
	if p.cursor <= 0 do return
	// Smart backspace: delete both chars when cursor is between matched pair
	{
		blen := buffer_len(&p.buf)
		prev := buffer_get_byte(&p.buf, p.cursor - 1)
		next : u8 = 0
		if p.cursor < blen { next = buffer_get_byte(&p.buf, p.cursor) }
		pair_close: u8
		switch prev {
		case '(':  pair_close = ')'
		case '[':  pair_close = ']'
		case '{':  pair_close = '}'
		case '"':  pair_close = '"'
		case '\'': pair_close = '\''
		case '`':  pair_close = '`'
		}
		if pair_close != 0 && next == pair_close {
			buffer_delete(&p.buf, p.cursor - 1, 2)
			p.cursor    -= 1
			p.sel_anchor = p.cursor
			p.dirty      = true
			return
		}
	}
	move_left(p, false)
	// Properly handle multi-byte UTF-8
	first  := buffer_get_byte(&p.buf, p.cursor)
	nbytes := utf8_lead_len(first)
	del    := make([]u8, nbytes, context.temp_allocator)
	for i in 0 ..< nbytes { del[i] = buffer_get_byte(&p.buf, p.cursor + i) }
	undo_push_delete(p, p.cursor, del, true)
	buffer_delete(&p.buf, p.cursor, nbytes)
	p.sel_anchor = p.cursor
	p.dirty      = true
}

do_delete :: proc(p: ^Pane) {
	if undo_delete_sel(p) do return
	n := buffer_len(&p.buf)
	if p.cursor >= n do return
	first  := buffer_get_byte(&p.buf, p.cursor)
	nbytes := utf8_lead_len(first)
	del    := make([]u8, nbytes, context.temp_allocator)
	for i in 0 ..< nbytes { del[i] = buffer_get_byte(&p.buf, p.cursor + i) }
	undo_push_delete(p, p.cursor, del, false)
	buffer_delete(&p.buf, p.cursor, nbytes)
	p.dirty = true
}

copy_sel :: proc(p: ^Pane) {
	if !has_selection(p) do return
	lo  := sel_lo(p); hi := sel_hi(p)
	buf := make([]u8, hi - lo, context.temp_allocator)
	for i in 0 ..< hi - lo { buf[i] = buffer_get_byte(&p.buf, lo + i) }
	rl.SetClipboardText(to_cstring(string(buf)))
}

cut_sel :: proc(p: ^Pane) {
	if !has_selection(p) do return
	copy_sel(p)
	undo_delete_sel(p)
}

paste :: proc(p: ^Pane) {
	raw := rl.GetClipboardText()
	if raw == nil do return
	s := string(raw)
	if len(s) == 0 do return
	undo_delete_sel(p)
	undo_push_insert(p, p.cursor, transmute([]u8)s, false)
	undo_break(p)
	buffer_insert_string(&p.buf, p.cursor, s)
	p.cursor     += len(s)
	p.sel_anchor  = p.cursor
	p.dirty       = true
}

// Ctrl+D: delete entire current line (including newline)
do_kill_line :: proc(p: ^Pane) {
	line, _  := buffer_pos_to_line_col(&p.buf, p.cursor)
	ls       := buffer_line_start(&p.buf, line)
	ll       := buffer_line_length(&p.buf, line)
	total    := buffer_line_count(&p.buf)
	del_len  := ll + 1 if line < total - 1 else ll
	if del_len == 0 do return
	del := make([]u8, del_len, context.temp_allocator)
	for i in 0 ..< del_len { del[i] = buffer_get_byte(&p.buf, ls + i) }
	undo_push_delete(p, ls, del, false)
	undo_break(p)
	buffer_delete(&p.buf, ls, del_len)
	p.cursor     = ls
	p.sel_anchor = ls
	p.dirty      = true
}

// Alt+Down: move current line (or selection) one line down.
do_move_lines_down :: proc(p: ^Pane) {
	total := buffer_line_count(&p.buf)
	line, _ := buffer_pos_to_line_col(&p.buf, p.cursor)

	L1, L2 := line, line
	if has_selection(p) {
		l1, _  := buffer_pos_to_line_col(&p.buf, sel_lo(p))
		l2, c2 := buffer_pos_to_line_col(&p.buf, sel_hi(p))
		L1 = l1; L2 = l2 if c2 > 0 else max(l1, l2 - 1)
	}
	if L2 >= total - 1 { return }

	// block = lines L1..L2 including their trailing \n (L2 < total-1 guaranteed)
	block_start := buffer_line_start(&p.buf, L1)
	block_end   := buffer_line_start(&p.buf, L2 + 1) // start of L2+1 = after L2's \n

	// below = line L2+1 content (may or may not have trailing \n)
	below_start  := block_end
	below_text_len := buffer_line_length(&p.buf, L2 + 1)
	buf_len      := buffer_len(&p.buf)
	below_end    := below_start + below_text_len
	below_has_nl := below_end < buf_len && buffer_get_byte(&p.buf, below_end) == '\n'
	if below_has_nl { below_end += 1 }

	range_len  := below_end - block_start
	orig       := make([]u8, range_len, context.temp_allocator)
	for i in 0..<range_len { orig[i] = buffer_get_byte(&p.buf, block_start + i) }

	block_part := orig[:block_end - block_start] // always ends with \n
	below_part := orig[block_end - block_start:] // may or may not end with \n

	// Swap: below_part + block_part (add \n separator if below has none)
	new_len   := range_len + (0 if below_has_nl else 1)
	new_bytes := make([]u8, new_len, context.temp_allocator)
	if below_has_nl {
		copy(new_bytes,                   below_part)
		copy(new_bytes[len(below_part):], block_part)
	} else {
		copy(new_bytes,                       below_part)
		new_bytes[len(below_part)] = '\n'
		copy(new_bytes[len(below_part) + 1:], block_part)
	}

	cursor_off   := p.cursor - block_start
	below_stride := len(below_part) + (0 if below_has_nl else 1)

	undo_push_delete(p, block_start, orig, false)
	undo_break(p)
	buffer_delete(&p.buf, block_start, range_len)
	undo_push_insert(p, block_start, new_bytes, false)
	undo_break(p)
	buffer_insert_string(&p.buf, block_start, string(new_bytes))

	p.cursor     = block_start + below_stride + cursor_off
	p.sel_anchor = p.cursor
	p.dirty      = true
}

// Alt+Up: move current line (or selection) one line up.
do_move_lines_up :: proc(p: ^Pane) {
	total := buffer_line_count(&p.buf)
	line, _ := buffer_pos_to_line_col(&p.buf, p.cursor)

	L1, L2 := line, line
	if has_selection(p) {
		l1, _  := buffer_pos_to_line_col(&p.buf, sel_lo(p))
		l2, c2 := buffer_pos_to_line_col(&p.buf, sel_hi(p))
		L1 = l1; L2 = l2 if c2 > 0 else max(l1, l2 - 1)
	}
	if L1 == 0 { return }

	// above = line L1-1 including its trailing \n (L1-1 < total-1 since L1 >= 1)
	above_start := buffer_line_start(&p.buf, L1 - 1)
	block_start := buffer_line_start(&p.buf, L1)     // = above_start + len(above) + 1
	above_len   := block_start - above_start          // includes the \n

	// block = lines L1..L2 (may or may not have trailing \n)
	block_text_end := buffer_line_start(&p.buf, L2) + buffer_line_length(&p.buf, L2)
	buf_len        := buffer_len(&p.buf)
	block_end      := block_text_end
	block_has_nl   := block_end < buf_len && buffer_get_byte(&p.buf, block_end) == '\n'
	if block_has_nl { block_end += 1 }

	range_len := block_end - above_start
	orig      := make([]u8, range_len, context.temp_allocator)
	for i in 0..<range_len { orig[i] = buffer_get_byte(&p.buf, above_start + i) }

	above_part := orig[:above_len]          // ends with \n
	block_part := orig[above_len:]          // may or may not end with \n

	// Swap: block_part + above_part (add \n after block if block has none)
	new_len   := range_len + (0 if block_has_nl else 1)
	new_bytes := make([]u8, new_len, context.temp_allocator)
	if block_has_nl {
		copy(new_bytes,                   block_part)
		copy(new_bytes[len(block_part):], above_part)
	} else {
		copy(new_bytes,                       block_part)
		new_bytes[len(block_part)] = '\n'
		copy(new_bytes[len(block_part) + 1:], above_part)
	}

	cursor_off := p.cursor - block_start

	undo_push_delete(p, above_start, orig, false)
	undo_break(p)
	buffer_delete(&p.buf, above_start, range_len)
	undo_push_insert(p, above_start, new_bytes, false)
	undo_break(p)
	buffer_insert_string(&p.buf, above_start, string(new_bytes))

	p.cursor     = above_start + cursor_off
	p.sel_anchor = p.cursor
	p.dirty      = true
	_ = total
}

// Convert screen position to buffer cursor; ox/oy = pane's screen origin.
mouse_to_cursor :: proc(p: ^Pane, font: rl.Font, mp: rl.Vector2, ox, oy: f32) -> int {
	ref    := rl.MeasureTextEx(font, "M", FONT_SIZE, CHAR_SPACING)
	cw     := ref.x
	ch     := ref.y + LINE_SPACING
	digs   := digit_count(buffer_line_count(&p.buf))
	text_x := f32(digs)*cw + GUTTER_PAD*2

	local_x := mp.x - ox
	local_y := mp.y - oy - PANE_TOP_PAD

	line := int(local_y / ch) + p.scroll
	col  := int((local_x - text_x) / cw)
	if col < 0 do col = 0

	total := buffer_line_count(&p.buf)
	line   = clamp(line, 0, total - 1)

	start := buffer_line_start(&p.buf, line)
	return start + min(col, buffer_line_length(&p.buf, line))
}

// --- Helpers ---

utf8_lead_len :: proc(b: u8) -> int {
	if b & 0x80 == 0 { return 1 }
	if b & 0xE0 == 0xC0 { return 2 }
	if b & 0xF0 == 0xE0 { return 3 }
	return 4
}

is_word :: proc(ch: u8) -> bool {
	return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
	       (ch >= '0' && ch <= '9') || ch == '_'
}

rune_encode :: proc(r: rune, buf: ^[4]u8) -> int {
	switch {
	case r < 0x80:
		buf[0] = u8(r)
		return 1
	case r < 0x800:
		buf[0] = u8(0xC0 | (r >> 6))
		buf[1] = u8(0x80 | (r & 0x3F))
		return 2
	case r < 0x10000:
		buf[0] = u8(0xE0 | (r >> 12))
		buf[1] = u8(0x80 | ((r >> 6) & 0x3F))
		buf[2] = u8(0x80 | (r & 0x3F))
		return 3
	case:
		buf[0] = u8(0xF0 | (r >> 18))
		buf[1] = u8(0x80 | ((r >> 12) & 0x3F))
		buf[2] = u8(0x80 | ((r >> 6) & 0x3F))
		buf[3] = u8(0x80 | (r & 0x3F))
		return 4
	}
}

// --- Indent / dedent ---

do_indent_sel :: proc(p: ^Pane) {
	lo_line, _ := buffer_pos_to_line_col(&p.buf, sel_lo(p))
	hi         := sel_hi(p)
	hi_line, hi_col := buffer_pos_to_line_col(&p.buf, hi)
	end_line := hi_line if hi_col > 0 else (max(lo_line, hi_line - 1))

	for li := end_line; li >= lo_line; li -= 1 {
		pos := buffer_line_start(&p.buf, li)
		for i in 0 ..< 4 { buffer_insert_byte(&p.buf, pos + i, ' ') }
		if p.cursor     > pos { p.cursor     += 4 }
		if p.sel_anchor > pos { p.sel_anchor += 4 }
	}
	p.dirty = true
}

do_dedent_sel :: proc(p: ^Pane) {
	lo_line, _ := buffer_pos_to_line_col(&p.buf, sel_lo(p))
	hi         := sel_hi(p)
	hi_line, hi_col := buffer_pos_to_line_col(&p.buf, hi)
	end_line := hi_line if hi_col > 0 else (max(lo_line, hi_line - 1))

	for li := end_line; li >= lo_line; li -= 1 {
		pos := buffer_line_start(&p.buf, li)
		n   := 0
		for n < 4 && pos + n < buffer_len(&p.buf) && buffer_get_byte(&p.buf, pos + n) == ' ' {
			n += 1
		}
		if n == 0 { continue }
		buffer_delete(&p.buf, pos, n)
		if p.cursor > pos + n         { p.cursor     -= n }
		else if p.cursor > pos        { p.cursor      = pos }
		if p.sel_anchor > pos + n     { p.sel_anchor -= n }
		else if p.sel_anchor > pos    { p.sel_anchor  = pos }
	}
	p.dirty = true
}

do_dedent_line :: proc(p: ^Pane) {
	line, _ := buffer_pos_to_line_col(&p.buf, p.cursor)
	pos     := buffer_line_start(&p.buf, line)
	n := 0
	for n < 4 && pos + n < buffer_len(&p.buf) && buffer_get_byte(&p.buf, pos + n) == ' ' {
		n += 1
	}
	if n == 0 { return }
	buffer_delete(&p.buf, pos, n)
	if p.cursor > pos + n { p.cursor -= n } else if p.cursor > pos { p.cursor = pos }
	p.sel_anchor = p.cursor
	p.dirty = true
}

// --- Find / Replace ---

find_replace_open :: proc(e: ^Editor) {
	fr := &e.find_rep
	fr.open    = true
	fr.focus   = 0
	fr.current = 0
	fr.all_sel = false
	clear(&fr.replace_buf)
	clear(&fr.matches)

	p := active_pane(e)
	if has_selection(p) {
		// Pre-fill search with selected text
		lo := sel_lo(p)
		hi := sel_hi(p)
		clear(&fr.search_buf)
		for i in lo ..< hi { append(&fr.search_buf, buffer_get_byte(&p.buf, i)) }
		fr.needs_scan = true
		find_replace_scan(fr, p)
		if len(fr.matches) > 0 { find_replace_jump(fr, p) }
	} else {
		clear(&fr.search_buf)
		fr.needs_scan = false
	}
}

find_replace_close :: proc(e: ^Editor) {
	e.find_rep.open = false
}

_fr_word_char :: #force_inline proc(b: u8) -> bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') || b == '_'
}

find_replace_scan :: proc(fr: ^Find_Replace, p: ^Pane) {
	clear(&fr.matches)
	clear(&fr.match_lens)
	fr.needs_scan = false
	fr.regex_err  = false
	if len(fr.search_buf) == 0 { return }

	n    := buffer_len(&p.buf)
	qlen := len(fr.search_buf)
	q    := fr.search_buf[:]

	if fr.use_regex {
		tmp := make([]u8, n, context.temp_allocator)
		for i in 0..<n { tmp[i] = buffer_get_byte(&p.buf, i) }

		flags: re.Flags = {}
		if !fr.case_sensitive { flags |= {.Case_Insensitive} }

		it, err := re.create_iterator(string(tmp), string(q), flags,
		                              context.temp_allocator, context.temp_allocator)
		if err != nil { fr.regex_err = true; return }

		for {
			capture, _, ok := re.match_iterator(&it)
			if !ok { break }
			if len(capture.pos) == 0 { continue }
			start := capture.pos[0][0]
			end   := capture.pos[0][1]
			if fr.whole_word {
				before := tmp[start - 1] if start > 0 else u8(0)
				after  := tmp[end]       if end < n   else u8(0)
				if _fr_word_char(before) || _fr_word_char(after) { continue }
			}
			append(&fr.matches,    start)
			append(&fr.match_lens, end - start)
		}
	} else {
		for i := 0; i <= n - qlen; i += 1 {
			ok := true
			for j := 0; j < qlen; j += 1 {
				bj := buffer_get_byte(&p.buf, i + j)
				qj := q[j]
				if !fr.case_sensitive {
					if bj >= 'A' && bj <= 'Z' { bj |= 32 }
					if qj >= 'A' && qj <= 'Z' { qj |= 32 }
				}
				if bj != qj { ok = false; break }
			}
			if !ok { continue }
			if fr.whole_word {
				before := buffer_get_byte(&p.buf, i - 1)    if i > 0          else u8(0)
				after  := buffer_get_byte(&p.buf, i + qlen) if i + qlen < n   else u8(0)
				if _fr_word_char(before) || _fr_word_char(after) { continue }
			}
			append(&fr.matches,    i)
			append(&fr.match_lens, qlen)
		}
	}

	if len(fr.matches) == 0 { fr.current = 0 }
	else                     { fr.current = clamp(fr.current, 0, len(fr.matches) - 1) }
}

find_replace_jump :: proc(fr: ^Find_Replace, p: ^Pane) {
	if len(fr.matches) == 0 { return }
	pos          := fr.matches[fr.current]
	mlen         := fr.match_lens[fr.current]
	p.cursor      = pos + mlen
	p.sel_anchor  = pos
	line, _      := buffer_pos_to_line_col(&p.buf, pos)
	p.scroll      = max(0, line - 5)
	p.scroll_anim = f32(p.scroll)
	if fr.current < fr.results_scroll { fr.results_scroll = fr.current }
	if fr.current >= fr.results_scroll + 8 { fr.results_scroll = fr.current - 7 }
}

find_replace_handle_input :: proc(e: ^Editor) {
	fr := &e.find_rep
	p  := active_pane(e)

	if rl.IsKeyPressed(.ESCAPE) { find_replace_close(e); return }

	// Toggle mode (Alt+key) — work in both focus modes
	if alt() && !ctrl() {
		if rl.IsKeyPressed(.C) { fr.case_sensitive = !fr.case_sensitive; fr.needs_scan = true; return }
		if rl.IsKeyPressed(.W) { fr.whole_word     = !fr.whole_word;     fr.needs_scan = true; return }
		if rl.IsKeyPressed(.R) { fr.use_regex      = !fr.use_regex;      fr.needs_scan = true; return }
		if rl.IsKeyPressed(.L) { fr.show_results   = !fr.show_results;                         return }
	}

	if rl.IsKeyPressed(.TAB) { fr.focus = 1 - fr.focus; fr.all_sel = false; return }

	if fr.focus == 0 {
		if key_rep(.DOWN) || rl.IsKeyPressed(.ENTER) {
			if fr.needs_scan { find_replace_scan(fr, p) }
			if len(fr.matches) > 0 {
				fr.current = (fr.current + 1) % len(fr.matches)
				find_replace_jump(fr, p)
			}
			return
		}
		if key_rep(.UP) {
			if fr.needs_scan { find_replace_scan(fr, p) }
			if len(fr.matches) > 0 {
				fr.current = (fr.current - 1 + len(fr.matches)) % len(fr.matches)
				find_replace_jump(fr, p)
			}
			return
		}
	}

	if fr.focus == 1 && rl.IsKeyPressed(.ENTER) && !ctrl() {
		find_replace_do_replace(e)
		return
	}
	if ctrl() && rl.IsKeyPressed(.ENTER) {
		find_replace_replace_all(e)
		return
	}

	buf := &fr.search_buf if fr.focus == 0 else &fr.replace_buf
	if text_input_handle(buf, &fr.all_sel) && fr.focus == 0 {
		fr.needs_scan = true
	}

	if fr.needs_scan { find_replace_scan(fr, p) }
}

find_replace_do_replace :: proc(e: ^Editor) {
	fr := &e.find_rep
	p  := active_pane(e)
	if len(fr.matches) == 0 { return }

	pos   := fr.matches[fr.current]
	qlen  := fr.match_lens[fr.current]
	rtext := string(fr.replace_buf[:])

	del := make([]u8, qlen, context.temp_allocator)
	for i in 0 ..< qlen { del[i] = buffer_get_byte(&p.buf, pos + i) }
	undo_push_delete(p, pos, del, false)
	buffer_delete(&p.buf, pos, qlen)
	undo_push_insert(p, pos, transmute([]u8)rtext, false)
	undo_break(p)
	buffer_insert_string(&p.buf, pos, rtext)

	p.cursor     = pos + len(rtext)
	p.sel_anchor = p.cursor
	p.dirty      = true

	find_replace_scan(fr, p)
	if len(fr.matches) > 0 {
		fr.current = 0
		for i in 0 ..< len(fr.matches) {
			if fr.matches[i] >= pos + len(rtext) { fr.current = i; break }
		}
		find_replace_jump(fr, p)
	}
}

find_replace_replace_all :: proc(e: ^Editor) {
	fr := &e.find_rep
	p  := active_pane(e)
	find_replace_scan(fr, p)
	if len(fr.matches) == 0 { return }

	rtext := string(fr.replace_buf[:])
	count := 0

	for i := len(fr.matches) - 1; i >= 0; i -= 1 {
		pos  := fr.matches[i]
		qlen := fr.match_lens[i]
		del  := make([]u8, qlen, context.temp_allocator)
		for j in 0 ..< qlen { del[j] = buffer_get_byte(&p.buf, pos + j) }
		undo_push_delete(p, pos, del, false)
		buffer_delete(&p.buf, pos, qlen)
		undo_push_insert(p, pos, transmute([]u8)rtext, false)
		buffer_insert_string(&p.buf, pos, rtext)
		count += 1
	}
	undo_break(p)
	p.dirty = true
	find_replace_scan(fr, p)
	e.msg = fmt.tprintf("Replaced %d occurrences", count)
}

// ---------------------------------------------------------------------------
// Debug input helpers
// ---------------------------------------------------------------------------

_dbg_bp_toggle :: proc(e: ^Editor, file: string, line: int) {
	dbg.bp_toggle(&e.debug_mgr, file, line)
}

import_dbg_start_or_continue :: proc(e: ^Editor) {
	state := dbg.manager_get_state(&e.debug_mgr)
	switch state {
	case .Idle:    dbg.session_start(&e.debug_mgr)
	case .Paused:  dbg.debug_continue(&e.debug_mgr)
	case .Running, .Starting, .Stopping: // no-op
	}
}

import_dbg_stop    :: proc(e: ^Editor) { dbg.session_stop(&e.debug_mgr) }
import_dbg_next    :: proc(e: ^Editor) { dbg.debug_next(&e.debug_mgr) }
import_dbg_step_in :: proc(e: ^Editor) { dbg.debug_step_in(&e.debug_mgr) }
import_dbg_step_out :: proc(e: ^Editor) { dbg.debug_step_out(&e.debug_mgr) }
