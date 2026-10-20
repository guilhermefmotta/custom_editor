package editor

// Settings screen (ticket #15, features/settings-panel.feature, ADR 0003).
// Registers itself via @(init) (ADR 0001): palette "Settings: Open",
// Ctrl/Cmd+, . Edits theme, font family/size, keymap mode, tab size, word
// wrap and auto save; every change is validated, applied immediately and
// written to the USER editor.toml (conf.default_config_paths().user) with
// the line-patching writer in config/writer.odin.
//
// Keys: Up/Down select, Left/Right cycle or step the value, Enter cycles
// or opens the text field (Enter = apply, Esc = cancel), Esc closes.
//
// Also owns the runtime side of settings that had no consumer yet:
//   - startup: FONT_SIZE / font family / word wrap from the loaded config;
//   - auto save (settings_panel_update): dirty panes with a file are saved
//     after `auto_save_delay` seconds without edits.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import conf "./config"
import "./git"
import rl "vendor:raylib"

SETTINGS_PANEL_ID :: "settings"

// Font file requested by the settings (owned); main.odin tries it before
// FONT_PATHS and rebuilds the atlas whenever settings_font_gen changes.
settings_font_path: string
settings_font_gen:  int

@(init)
_settings_register :: proc "contextless" () {
	ui_register_panel(Ui_Panel{
		id       = SETTINGS_PANEL_ID,
		title    = "Settings",
		priority = 90,
		layer    = .Overlay,
		draw     = _settings_draw,
		input    = _settings_input,
		update   = settings_panel_update,
		on_open  = _settings_on_open,
		on_close = _settings_on_close,
		command  = "Settings: Open",
		command_desc = "Theme, font, UI scale, smooth text, keymap mode, tab size, word wrap, auto save",
		shortcut = {key = .COMMA, mods = {.Ctrl}},
	})
}

@(fini)
_settings_fini :: proc "contextless" () {
	context = runtime.default_context()
	_settings_on_close(nil)
	delete(settings_font_path)
	settings_font_path = ""
}

SETTINGS_ROWS := [conf.Setting]string{
	.Theme           = "Theme",
	.Font_Family     = "Font family",
	.Font_Size       = "Font size",
	.Keymap_Mode     = "Keymap mode",
	.Tab_Size        = "Tab size",
	.Word_Wrap       = "Word wrap",
	.Auto_Save       = "Auto save",
	.Auto_Save_Delay = "Auto save delay (s)",
	.UI_Scale        = "UI scale",
	.Smooth_Text     = "Smooth text",
	.Markdown_Preview = "Open Markdown as preview",
	.Format_On_Save   = "Format on save",
	.Search_Ignored   = "Search git-ignored files",
}

// Values Left/Right step through for "UI scale" (percent, 0 = auto).
SETTINGS_UI_SCALES :: [?]int{0, 80, 90, 100, 110, 125, 150, 175, 200}

@(private="file")
_Settings_State :: struct {
	sel:        conf.Setting,
	editing:    bool,
	edit_buf:   [dynamic]u8,
	sel_all:    bool,
	err:        [conf.Setting]string, // owned; per-row validation error
	status:     string,               // owned; footer (save result)
	status_err: bool,
	overridden: [conf.Setting]bool,   // workspace editor.toml also sets it
	// runtime
	started:    bool,
	n_panes:    int,
	autosave:   [MAX_PANES]_Autosave_Slot,
}

@(private="file")
_Autosave_Slot :: struct {
	len, cursor, undo: int,
	idle:              f32,
}

@(private="file") _st: _Settings_State

// Path written by the screen. Tests point it elsewhere.
settings_user_path :: proc() -> string {
	if _settings_path_override != "" { return _settings_path_override }
	return conf.default_config_paths().user
}
_settings_path_override: string

// ---------------------------------------------------------------------------
// Apply (pure-ish logic, covered by settings_panel_test.odin)
// ---------------------------------------------------------------------------

// Sorted theme names from the registry (temp allocator).
settings_theme_names :: proc(e: ^Editor) -> []string {
	names := make([dynamic]string, 0, len(e.registry.theme.themes), context.temp_allocator)
	for name in e.registry.theme.themes { append(&names, name) }
	slice.sort(names[:])
	return names[:]
}

// Validate `raw`, apply it to the running editor and persist it to `path`.
// err != "": invalid value, nothing changed (config, editor, file).
// save_err != "": applied in memory but the file was not written.
settings_apply :: proc(e: ^Editor, s: conf.Setting, raw: string, path: string) -> (err: string, save_err: string) {
	v, perr := conf.config_setting_parse(s, raw, settings_theme_names(e))
	if perr != "" { return perr, "" }

	switch s {
	case .Theme:
		conf.registry_set_theme(&e.registry, v.str)
		// e.cfg.theme_name may be aliased by the palette's theme picker, so
		// it is replaced without freeing the previous string.
		e.cfg.theme_name = strings.clone(v.str)
		v.str = e.cfg.theme_name
	case .Font_Family:
		conf.config_setting_set(&e.cfg, s, v)
		v.str = e.cfg.font.family
		_settings_set_font_path(v.str)
	case .Font_Size:
		conf.config_setting_set(&e.cfg, s, v)
		FONT_SIZE = f32(v.num) // main.odin rebuilds the atlas
	case .Keymap_Mode:
		changed := e.cfg.editor.keymap_mode != v.mode
		conf.config_setting_set(&e.cfg, s, v)
		if changed { keymap_switch_reset(e) }
	case .Word_Wrap:
		conf.config_setting_set(&e.cfg, s, v)
		for &p in e.panes { p.word_wrap = v.b }
	case .Tab_Size, .Auto_Save, .Auto_Save_Delay, .Markdown_Preview, .Format_On_Save, .Search_Ignored:
		conf.config_setting_set(&e.cfg, s, v) // read live from e.cfg
	case .UI_Scale:
		conf.config_setting_set(&e.cfg, s, v)
		UI_ZOOM = ui_zoom_from_percent(v.num) // main.odin rebuilds the atlas
	case .Smooth_Text:
		conf.config_setting_set(&e.cfg, s, v)
		FONT_SMOOTH = v.b
	}

	if ok, werr := conf.config_write_setting(path, s, v); !ok { return "", werr }
	return "", ""
}

// Current value as text (temp allocator).
settings_value_text :: proc(e: ^Editor, s: conf.Setting) -> string {
	return conf.config_setting_display(s, conf.config_setting_get(&e.cfg, s))
}

// Next/previous value for Left/Right ("" = row has no stepping).
settings_cycle_value :: proc(e: ^Editor, s: conf.Setting, dir: int) -> string {
	v := conf.config_setting_get(&e.cfg, s)
	switch s {
	case .Theme:
		names := settings_theme_names(e)
		if len(names) == 0 { return "" }
		i, _ := slice.linear_search(names, v.str)
		return names[(i + dir + len(names)) % len(names)]
	case .Keymap_Mode:
		n := len(conf.Keymap_Mode)
		return conf.keymap_mode_id(conf.Keymap_Mode((int(v.mode) + dir + n) % n))
	case .Word_Wrap, .Auto_Save, .Smooth_Text, .Markdown_Preview, .Format_On_Save, .Search_Ignored:
		return "off" if v.b else "on"
	case .UI_Scale:
		steps := SETTINGS_UI_SCALES
		i := 0
		for st, k in steps { if st <= v.num { i = k } } // custom values snap to the step below
		i = (i + dir + len(steps)) % len(steps)
		return "auto" if steps[i] == 0 else fmt.tprintf("%d", steps[i])
	case .Font_Size:
		return fmt.tprintf("%d", clamp(v.num + dir, conf.FONT_SIZE_MIN, conf.FONT_SIZE_MAX))
	case .Tab_Size:
		return fmt.tprintf("%d", clamp(v.num + dir, conf.TAB_SIZE_MIN, conf.TAB_SIZE_MAX))
	case .Auto_Save_Delay:
		step := 0.5 if v.f >= 1 else 0.1
		return conf.toml_float_literal(clamp(v.f + f64(dir) * step, conf.AUTO_SAVE_DELAY_MIN, conf.AUTO_SAVE_DELAY_MAX))
	case .Font_Family:
		return ""
	}
	return ""
}

@(private="file")
_settings_set_font_path :: proc(path: string) {
	if path == settings_font_path { return }
	delete(settings_font_path)
	settings_font_path = strings.clone(path)
	settings_font_gen += 1
}

@(private="file")
_set_owned :: proc(dst: ^string, s: string) {
	delete(dst^)
	dst^ = strings.clone(s) if s != "" else ""
}

// Run one change from the UI and record its outcome for display.
@(private="file")
_settings_commit :: proc(e: ^Editor, s: conf.Setting, raw: string) -> bool {
	err, save_err := settings_apply(e, s, raw, settings_user_path())
	_set_owned(&_st.err[s], err)
	if err != "" { return false }
	if save_err != "" {
		_set_owned(&_st.status, fmt.tprintf("Applied, but not saved: %s", save_err))
		_st.status_err = true
	} else {
		_set_owned(&_st.status, fmt.tprintf("%s = %s  (saved to %s)", SETTINGS_ROWS[s], settings_value_text(e, s), settings_user_path()))
		_st.status_err = false
	}
	return true
}

// ---------------------------------------------------------------------------
// Runtime: startup apply + auto save (every frame, open or not)
// ---------------------------------------------------------------------------

settings_panel_update :: proc(e: ^Editor, dt: f32) {
	if !_st.started {
		_st.started = true
		c := &e.cfg
		if c.font.size >= conf.FONT_SIZE_MIN && c.font.size <= conf.FONT_SIZE_MAX { FONT_SIZE = f32(c.font.size) }
		if c.font.family != "" && os.exists(c.font.family) { _settings_set_font_path(c.font.family) }
		if c.window.ui_scale >= conf.UI_SCALE_MIN && c.window.ui_scale <= conf.UI_SCALE_MAX {
			UI_ZOOM = ui_zoom_from_percent(c.window.ui_scale)
		}
		FONT_SMOOTH = c.font.smooth
	}
	// New panes (splits) pick up the configured word wrap.
	if len(e.panes) != _st.n_panes {
		for i in _st.n_panes ..< len(e.panes) { e.panes[i].word_wrap = e.cfg.editor.word_wrap }
		_st.n_panes = len(e.panes)
	}
	_settings_autosave(e, dt)
	_settings_md_auto_preview(e)
}

// "Open Markdown as preview": a .md just opened in a pane (pane_open resets
// md_preview) starts in the rendered view; toggling back to text sticks.
@(private="file")
_settings_md_auto_preview :: proc(e: ^Editor) {
	if !e.cfg.editor.markdown_preview { return }
	for &p in e.panes {
		if p.md_preview.auto_done || !is_markdown_file(p.filename) { continue }
		p.md_preview.auto_done = true
		if !p.md_preview.visible { md_preview_toggle(&p) }
	}
}

@(private="file")
_settings_autosave :: proc(e: ^Editor, dt: f32) {
	if !e.cfg.editor.auto_save { return }
	delay := max(e.cfg.editor.auto_save_delay, f32(conf.AUTO_SAVE_DELAY_MIN))
	for &p, i in e.panes {
		if i >= MAX_PANES { break }
		slot := &_st.autosave[i]
		l, c, u := buffer_len(&p.buf), p.cursor, len(p.undo)
		if l != slot.len || c != slot.cursor || u != slot.undo {
			slot.len, slot.cursor, slot.undo = l, c, u
			slot.idle = 0
			continue
		}
		if !p.dirty || p.filename == "" { slot.idle = 0; continue }
		slot.idle += dt
		if slot.idle < delay {
			frame_request_in(f64(delay - slot.idle)) // ADR 0016: save even if idle
			continue
		}
		slot.idle = 0
		if ok, _ := pane_save(&p); ok {
			git.git_blame_invalidate(e.git_mgr, p.filename)
			e.msg = "Auto saved"
		} else {
			e.msg = "Auto save failed"
		}
	}
}

// ---------------------------------------------------------------------------
// Panel
// ---------------------------------------------------------------------------

@(private="file")
_settings_on_open :: proc(e: ^Editor) {
	_st.editing = false
	for &s in _st.err { _set_owned(&s, "") }
	_set_owned(&_st.status, "")
	_st.overridden = {}
	ws := conf.default_config_paths().workspace
	if tbl, ok := conf.toml_load_file(ws); ok {
		defer conf.toml_destroy_table(tbl)
		for s in conf.Setting {
			loc := conf.SETTING_LOCATION[s]
			t := tbl
			if loc.section != "" {
				sub, sok := conf.toml_table(tbl, loc.section)
				if !sok { continue }
				t = sub
			}
			_, has := t^[loc.key]
			_st.overridden[s] = has
		}
	}
}

@(private="file")
_settings_on_close :: proc(e: ^Editor) {
	_st.editing = false
	delete(_st.edit_buf); _st.edit_buf = nil
	for &s in _st.err { _set_owned(&s, "") }
	_set_owned(&_st.status, "")
}

@(private="file")
_settings_begin_edit :: proc(e: ^Editor) {
	clear(&_st.edit_buf)
	append(&_st.edit_buf, ..transmute([]u8)settings_value_text(e, _st.sel))
	_st.sel_all = true
	_st.editing = true
	for { if rl.GetCharPressed() == 0 { break } } // drop the char of the opening key
}

@(private="file")
_settings_activate :: proc(e: ^Editor) {
	switch _st.sel {
	case .Theme, .Keymap_Mode, .Word_Wrap, .Auto_Save, .UI_Scale, .Smooth_Text, .Markdown_Preview, .Format_On_Save, .Search_Ignored:
		_settings_commit(e, _st.sel, settings_cycle_value(e, _st.sel, 1))
	case .Font_Family, .Font_Size, .Tab_Size, .Auto_Save_Delay:
		_settings_begin_edit(e)
	}
}

@(private="file")
_settings_input :: proc(e: ^Editor) -> bool {
	if _st.editing {
		switch {
		case rl.IsKeyPressed(.ESCAPE):
			_st.editing = false
			_set_owned(&_st.err[_st.sel], "")
		case rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER):
			if _settings_commit(e, _st.sel, string(_st.edit_buf[:])) { _st.editing = false }
		case:
			if text_input_handle(&_st.edit_buf, &_st.sel_all) { _set_owned(&_st.err[_st.sel], "") }
		}
		return true
	}

	n := len(conf.Setting)
	switch {
	case rl.IsKeyPressed(.ESCAPE):
		ui_panel_close(e, SETTINGS_PANEL_ID)
	case key_rep(.DOWN):
		_st.sel = conf.Setting((int(_st.sel) + 1) % n)
	case key_rep(.UP):
		_st.sel = conf.Setting((int(_st.sel) + n - 1) % n)
	case key_rep(.RIGHT):
		if v := settings_cycle_value(e, _st.sel, 1); v != "" { _settings_commit(e, _st.sel, v) }
	case key_rep(.LEFT):
		if v := settings_cycle_value(e, _st.sel, -1); v != "" { _settings_commit(e, _st.sel, v) }
	case rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) || rl.IsKeyPressed(.SPACE):
		_settings_activate(e)
	}
	for { if rl.GetCharPressed() == 0 { break } } // modal: typed chars never reach the buffer
	return true
}

@(private="file")
_settings_draw :: proc(e: ^Editor, font: rl.Font, sw, sh: f32) {
	W   :: f32(720)
	HDR :: f32(36)
	FTR :: f32(48)
	ROW := max(UI_ROW_H + 6, FONT_SIZE + 12)
	ERR_H := FONT_SIZE + 4
	n_err := 0
	for s in _st.err { if s != "" { n_err += 1 } }
	H := HDR + 10 + f32(len(conf.Setting)) * ROW + f32(n_err) * ERR_H + FTR + 10

	rl.DrawRectangle(0, 0, i32(sw), i32(sh), {0, 0, 0, 150})
	px, py := dlg_begin((sw - W) * 0.5, max(20, (sh - H) * 0.3), W, H, BG, DIVIDER_COL)

	rl.DrawRectangleRec({px, py, W, HDR}, STATUS_BG)
	ui_text(font, "Settings", px + 12, py, HDR, FONT_SIZE, ACCENT_COL, px + W)
	ui_text(font, "applied now, saved to your user editor.toml", px + 110, py, HDR, FONT_SIZE - 3, LINENUM, px + W - 10)

	mp := rl.GetMousePosition()
	LABEL_W :: f32(210)
	y := py + HDR + 10
	for s in conf.Setting {
		r := rl.Rectangle{px + 8, y, W - 16, ROW}
		sel := s == _st.sel
		if sel { rl.DrawRectangleRec(r, SEL_BG) }
		if ui_point_in(mp, r) && rl.IsMouseButtonPressed(.LEFT) && !_st.editing {
			if sel { _settings_activate(e) } else { _st.sel = s }
		}
		label := SETTINGS_ROWS[s]
		if _st.overridden[s] { label = fmt.tprintf("%s *", label) }
		ui_text(font, label, r.x + 10, y, ROW, FONT_SIZE - 1, sel ? TEXT : LINENUM, r.x + LABEL_W)

		vx := r.x + LABEL_W
		if sel && _st.editing {
			box := rl.Rectangle{vx - 4, y + 3, r.x + r.width - vx - 4, ROW - 6}
			rl.DrawRectangleRec(box, BG)
			rl.DrawRectangleLinesEx(box, 1, _st.err[s] != "" ? MSG_COL : ACCENT_COL)
			txt := string(_st.edit_buf[:])
			if _st.sel_all && txt != "" {
				rl.DrawRectangleRec({vx, y + 6, ui_text_w(font, txt, FONT_SIZE - 1), ROW - 12}, SEL_BG)
			}
			ui_text(font, txt, vx, y, ROW, FONT_SIZE - 1, TEXT, box.x + box.width)
			cx := vx + ui_text_w(font, txt, FONT_SIZE - 1) + 1
			rl.DrawRectangleRec({cx, y + 7, 2, ROW - 14}, CURSOR_COL)
		} else {
			val := settings_value_text(e, s)
			#partial switch s {
			case .Theme, .Keymap_Mode, .Word_Wrap, .Auto_Save, .Font_Size, .Tab_Size, .Auto_Save_Delay:
				val = fmt.tprintf("< %s >", val) if sel else val
			}
			ui_text(font, val, vx, y, ROW, FONT_SIZE - 1, sel ? ACCENT_COL : TEXT, r.x + r.width - 6)
		}
		y += ROW
		if _st.err[s] != "" {
			ui_text(font, _st.err[s], vx, y, ERR_H, FONT_SIZE - 3, MSG_COL, px + W - 10)
			y += ERR_H
		}
	}

	fy := py + H - FTR
	rl.DrawRectangleRec({px, fy, W, FTR}, STATUS_BG)
	if _st.status != "" {
		ui_text(font, _st.status, px + 10, fy + 2, FTR * 0.5, FONT_SIZE - 3, _st.status_err ? MSG_COL : DIAG_HINT_COL, px + W - 10)
	}
	hint := "Up/Dn select   Left/Right change   Enter edit/apply   Esc close/cancel"
	if _st.editing { hint = "Type a value   Enter apply   Esc cancel" }
	for o in _st.overridden { if o { hint = fmt.tprintf("%s   * also set in workspace editor.toml (wins at startup)", hint); break } }
	ui_text(font, hint, px + 10, fy + FTR * 0.5 - 2, FTR * 0.5, FONT_SIZE - 4, LINENUM, px + W - 10)
	dlg_end()
}
