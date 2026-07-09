package config

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// ---------------------------------------------------------------------------
// Config loader
//
// Loading pipeline:
//   1. Start with config_defaults()
//   2. Load system config   (/etc/editor/editor.toml)
//   3. Load user config     (~/.config/editor/editor.toml)
//   4. Load workspace config  (./.editor.toml or ./editor.toml)
//   5. Each level merges on top of the previous (later = higher priority)
//   6. Load all language configs from languages/ dir
//   7. Load all LSP configs from lsp/ dir
// ---------------------------------------------------------------------------

Config_Paths :: struct {
	system:    string, // /etc/editor/editor.toml
	user:      string, // ~/.config/editor/editor.toml
	workspace: string, // ./.editor.toml
	languages: string, // languages/ dir
	lsp:       string, // lsp/ dir
	dap:       string, // dap/ dir
	themes:    string, // themes/ dir
}

default_config_paths :: proc() -> Config_Paths {
	home := os.get_env("HOME", context.temp_allocator)
	return {
		system    = "/etc/editor/editor.toml",
		user      = fmt.tprintf("%s/.config/editor/editor.toml", home),
		workspace = "editor.toml",
		languages = "languages",
		lsp       = "lsp",
		dap       = "dap",
		themes    = "themes",
	}
}

// ---------------------------------------------------------------------------
// Load & merge full config
// ---------------------------------------------------------------------------

load_config :: proc(paths: Config_Paths) -> Config {
	cfg := config_defaults()

	// System → user → workspace (each overrides previous)
	_load_and_apply(&cfg, paths.system)
	_load_and_apply(&cfg, paths.user)
	_load_and_apply(&cfg, paths.workspace)

	// Load per-language, lsp, dap from directories
	_load_lsp_dir(&cfg, paths.lsp)
	_load_dap_dir(&cfg, paths.dap)

	return cfg
}

@(private)
_load_and_apply :: proc(cfg: ^Config, path: string) {
	tbl, ok := toml_load_file(path)
	if !ok { return }
	defer toml_destroy_table(tbl)
	_apply_table(cfg, tbl)
}

// ---------------------------------------------------------------------------
// Apply a parsed TOML table onto a Config struct
// ---------------------------------------------------------------------------

@(private)
_apply_table :: proc(cfg: ^Config, tbl: ^TOML_Table) {
	if sec, ok := toml_table(tbl, "editor");      ok { _apply_editor(cfg, sec)      }
	if sec, ok := toml_table(tbl, "window");      ok { _apply_window(cfg, sec)      }
	if sec, ok := toml_table(tbl, "font");        ok { _apply_font(cfg, sec)        }
	if sec, ok := toml_table(tbl, "cursor");      ok { _apply_cursor(cfg, sec)      }
	if sec, ok := toml_table(tbl, "scrolling");   ok { _apply_scroll(cfg, sec)      }
	if sec, ok := toml_table(tbl, "completion");  ok { _apply_completion(cfg, sec)  }
	if sec, ok := toml_table(tbl, "diagnostics"); ok { _apply_diagnostics(cfg, sec) }
	if sec, ok := toml_table(tbl, "workspace");   ok { _apply_workspace(cfg, sec)   }
	if sec, ok := toml_table(tbl, "logging");     ok { _apply_logging(cfg, sec)     }
	if sec, ok := toml_table(tbl, "performance"); ok { _apply_perf(cfg, sec)        }

	// Theme name
	if s, ok := toml_str(tbl, "theme"); ok { _replace_str(&cfg.theme_name, s) }

	// LSP servers
	if lsp_sec, ok := toml_table(tbl, "lsp"); ok {
		if arr, ok2 := toml_array(lsp_sec, "servers"); ok2 {
			_apply_lsp_servers(cfg, arr)
		}
	}

	// DAP adapters
	if dap_sec, ok := toml_table(tbl, "dap"); ok {
		if arr, ok2 := toml_array(dap_sec, "adapters"); ok2 {
			_apply_dap_adapters(cfg, arr)
		}
	}

	// Formatters
	if arr, ok := toml_array(tbl, "formatters"); ok {
		_apply_formatters(cfg, arr)
	}

	// Keybindings
	if arr, ok := toml_array(tbl, "keybindings"); ok {
		_apply_keybindings(cfg, arr)
	}

	// Build profiles
	if arr, ok := toml_array(tbl, "build"); ok {
		_apply_build(cfg, arr)
	}
}

// ---------------------------------------------------------------------------
// Section appliers
// ---------------------------------------------------------------------------

@(private)
_apply_editor :: proc(cfg: ^Config, t: ^TOML_Table) {
	e := &cfg.editor
	if n, ok := toml_int(t, "tab_size");         ok { e.tab_size         = int(n) }
	if b, ok := toml_bool(t, "use_spaces");       ok { e.use_spaces       = b }
	if b, ok := toml_bool(t, "line_numbers");     ok { e.line_numbers     = b }
	if b, ok := toml_bool(t, "relative_numbers"); ok { e.relative_numbers = b }
	if b, ok := toml_bool(t, "word_wrap");        ok { e.word_wrap        = b }
	if b, ok := toml_bool(t, "auto_save");        ok { e.auto_save        = b }
	if f, ok := toml_float(t, "auto_save_delay"); ok { e.auto_save_delay  = f32(f) }
	if b, ok := toml_bool(t, "format_on_save");   ok { e.format_on_save   = b }
	if b, ok := toml_bool(t, "trim_trailing_ws"); ok { e.trim_trailing_ws = b }
	if b, ok := toml_bool(t, "insert_final_nl");  ok { e.insert_final_nl  = b }
	if b, ok := toml_bool(t, "bracket_matching"); ok { e.bracket_matching = b }
	if b, ok := toml_bool(t, "show_status_bar");  ok { e.show_status_bar  = b }
	if b, ok := toml_bool(t, "show_minimap");     ok { e.show_minimap     = b }
	if s, ok := toml_str(t, "status_bar_position"); ok {
		if s == "top" || s == "bottom" { _replace_str(&e.status_bar_position, s) }
	}
	if s, ok := toml_str(t, "keymap_mode"); ok {
		switch s {
		case "normal": e.keymap_mode = .Normal
		case "vim":    e.keymap_mode = .Vim
		case "emacs":  e.keymap_mode = .Emacs
		}
	}
}

@(private)
_apply_window :: proc(cfg: ^Config, t: ^TOML_Table) {
	w := &cfg.window
	if n, ok := toml_int(t, "width");      ok { w.width      = int(n) }
	if n, ok := toml_int(t, "height");     ok { w.height     = int(n) }
	if b, ok := toml_bool(t, "fullscreen");ok { w.fullscreen = b }
	if n, ok := toml_int(t, "fps_target"); ok { w.fps_target = int(n) }
	if s, ok := toml_str(t, "title");      ok { _replace_str(&w.title, s) }
}

@(private)
_apply_font :: proc(cfg: ^Config, t: ^TOML_Table) {
	f := &cfg.font
	if s, ok := toml_str(t, "family");        ok { _replace_str(&f.family, s) }
	if n, ok := toml_int(t, "size");          ok { f.size         = int(n) }
	if v, ok := toml_float(t, "line_height"); ok { f.line_height  = f32(v) }
	if v, ok := toml_float(t, "char_spacing");ok { f.char_spacing = f32(v) }
	if arr, ok := toml_array(t, "fallbacks"); ok {
		for s in f.fallbacks { delete(s) }
		delete(f.fallbacks)
		f.fallbacks = _arr_strings(arr)
	}
}

@(private)
_apply_cursor :: proc(cfg: ^Config, t: ^TOML_Table) {
	c := &cfg.cursor
	if s, ok := toml_str(t, "style"); ok {
		switch s {
		case "block":     c.style = .Block
		case "line":      c.style = .Line
		case "underline": c.style = .Underline
		}
	}
	if b, ok := toml_bool(t, "blink");       ok { c.blink      = b }
	if f, ok := toml_float(t, "blink_rate"); ok { c.blink_rate = f32(f) }
}

@(private)
_apply_scroll :: proc(cfg: ^Config, t: ^TOML_Table) {
	s := &cfg.scrolling
	if b, ok := toml_bool(t, "smooth");          ok { s.smooth        = b }
	if f, ok := toml_float(t, "speed");           ok { s.speed         = f32(f) }
	if f, ok := toml_float(t, "sensitivity");     ok { s.sensitivity   = f32(f) }
	if n, ok := toml_int(t, "padding_lines");     ok { s.padding_lines = int(n) }
}

@(private)
_apply_completion :: proc(cfg: ^Config, t: ^TOML_Table) {
	c := &cfg.completion
	if b, ok := toml_bool(t, "enable");          ok { c.enable        = b }
	if f, ok := toml_float(t, "trigger_delay");  ok { c.trigger_delay = f32(f) }
	if n, ok := toml_int(t, "max_results");      ok { c.max_results   = int(n) }
	if b, ok := toml_bool(t, "fuzzy");           ok { c.fuzzy         = b }
	if b, ok := toml_bool(t, "snippets");        ok { c.snippets      = b }
	if b, ok := toml_bool(t, "auto_import");     ok { c.auto_import   = b }
	if f, ok := toml_float(t, "doc_delay");      ok { c.doc_delay     = f32(f) }
}

@(private)
_apply_diagnostics :: proc(cfg: ^Config, t: ^TOML_Table) {
	d := &cfg.diagnostics
	if b, ok := toml_bool(t, "enable");           ok { d.enable          = b }
	if b, ok := toml_bool(t, "inline_messages");  ok { d.inline_messages = b }
	if b, ok := toml_bool(t, "gutter_icons");     ok { d.gutter_icons    = b }
	if b, ok := toml_bool(t, "update_on_type");   ok { d.update_on_type  = b }
	if f, ok := toml_float(t, "update_delay");    ok { d.update_delay    = f32(f) }
	if n, ok := toml_int(t, "min_severity");      ok { d.min_severity    = int(n) }
	if s, ok := toml_str(t, "underline"); ok {
		switch s {
		case "none":      d.underline = .None
		case "underline": d.underline = .Underline
		case "squiggly":  d.underline = .Squiggly
		case "dotted":    d.underline = .Dotted
		}
	}
}

@(private)
_apply_workspace :: proc(cfg: ^Config, t: ^TOML_Table) {
	w := &cfg.workspace
	if b, ok := toml_bool(t, "trusted"); ok { w.trusted = b }
	if arr, ok := toml_array(t, "file_exclude"); ok {
		for s in w.file_exclude { delete(s) }; delete(w.file_exclude)
		w.file_exclude = _arr_strings(arr)
	}
	if arr, ok := toml_array(t, "search_exclude"); ok {
		for s in w.search_exclude { delete(s) }; delete(w.search_exclude)
		w.search_exclude = _arr_strings(arr)
	}
}

@(private)
_apply_logging :: proc(cfg: ^Config, t: ^TOML_Table) {
	l := &cfg.logging
	if s, ok := toml_str(t, "level"); ok {
		switch s {
		case "off":   l.level = .Off
		case "error": l.level = .Error
		case "warn":  l.level = .Warn
		case "info":  l.level = .Info
		case "debug": l.level = .Debug
		case "trace": l.level = .Trace
		}
	}
	if s, ok := toml_str(t, "file"); ok { _replace_str(&l.file, s) }
	if b, ok := toml_bool(t, "lsp"); ok { l.lsp = b }
}

@(private)
_apply_perf :: proc(cfg: ^Config, t: ^TOML_Table) {
	p := &cfg.performance
	if b, ok := toml_bool(t, "lazy_highlight");       ok { p.lazy_highlight      = b }
	if n, ok := toml_int(t, "max_highlight_lines");   ok { p.max_highlight_lines = int(n) }
	if n, ok := toml_int(t, "max_file_size_kb");      ok { p.max_file_size_kb    = int(n) }
}

// ---------------------------------------------------------------------------
// LSP / DAP / Formatter parsers
// ---------------------------------------------------------------------------

@(private)
_apply_lsp_servers :: proc(cfg: ^Config, arr: ^TOML_Array) {
	for item in arr^ {
		if item.kind != .Table { continue }
		tbl := cast(^TOML_Table)item.ptr
		srv := _parse_lsp_server(tbl)
		found := false
		for &e in cfg.lsp.servers {
			if e.id == srv.id { _lsp_server_destroy(&e); e = srv; found = true; break }
		}
		if !found { append(&cfg.lsp.servers, srv) }
	}
}

@(private)
_parse_lsp_server :: proc(t: ^TOML_Table) -> LSP_Server_Config {
	s: LSP_Server_Config
	s.enabled  = true
	s.priority = 0
	if v, ok := toml_str(t, "id");           ok { s.id           = strings.clone(v) }
	if v, ok := toml_str(t, "name");         ok { s.name         = strings.clone(v) }
	if v, ok := toml_str(t, "command");      ok { s.command      = strings.clone(v) }
	if v, ok := toml_str(t, "init_options"); ok { s.init_options = strings.clone(v) }
	if v, ok := toml_str(t, "install_url");  ok { s.install_url  = strings.clone(v) }
	if v, ok := toml_bool(t, "enabled");     ok { s.enabled      = v }
	if v, ok := toml_int(t, "priority");     ok { s.priority     = int(v) }
	if arr, ok := toml_array(t, "args");      ok { s.args      = _arr_strings(arr) }
	if arr, ok := toml_array(t, "languages"); ok { s.languages = _arr_strings(arr) }
	if env, ok := toml_table(t, "env");       ok { s.env       = _table_strings(env) }
	return s
}

@(private)
_apply_dap_adapters :: proc(cfg: ^Config, arr: ^TOML_Array) {
	for item in arr^ {
		if item.kind != .Table { continue }
		tbl := cast(^TOML_Table)item.ptr
		adp := _parse_dap_adapter(tbl)
		found := false
		for &e in cfg.dap.adapters {
			if e.id == adp.id { _dap_adapter_destroy(&e); e = adp; found = true; break }
		}
		if !found { append(&cfg.dap.adapters, adp) }
	}
}

@(private)
_parse_dap_adapter :: proc(t: ^TOML_Table) -> DAP_Adapter_Config {
	a: DAP_Adapter_Config
	a.enabled = true
	if v, ok := toml_str(t, "id");      ok { a.id      = strings.clone(v) }
	if v, ok := toml_str(t, "name");    ok { a.name    = strings.clone(v) }
	if v, ok := toml_str(t, "command"); ok { a.command = strings.clone(v) }
	if v, ok := toml_bool(t, "enabled");ok { a.enabled = v }
	if arr, ok := toml_array(t, "args");      ok { a.args      = _arr_strings(arr) }
	if arr, ok := toml_array(t, "languages"); ok { a.languages = _arr_strings(arr) }
	if env, ok := toml_table(t, "env");       ok { a.env       = _table_strings(env) }
	return a
}

@(private)
_apply_formatters :: proc(cfg: ^Config, arr: ^TOML_Array) {
	for item in arr^ {
		if item.kind != .Table { continue }
		tbl := cast(^TOML_Table)item.ptr
		f := _parse_formatter(tbl)
		found := false
		for &e in cfg.formatters {
			if e.id == f.id { _fmt_config_destroy(&e); e = f; found = true; break }
		}
		if !found { append(&cfg.formatters, f) }
	}
}

@(private)
_parse_formatter :: proc(t: ^TOML_Table) -> Formatter_Config {
	f: Formatter_Config
	f.enabled = true
	if v, ok := toml_str(t, "id");          ok { f.id         = strings.clone(v) }
	if v, ok := toml_str(t, "name");        ok { f.name       = strings.clone(v) }
	if v, ok := toml_str(t, "command");     ok { f.command    = strings.clone(v) }
	if v, ok := toml_bool(t, "enabled");    ok { f.enabled    = v }
	if v, ok := toml_bool(t, "stdin_pipe"); ok { f.stdin_pipe = v }
	if arr, ok := toml_array(t, "args");      ok { f.args      = _arr_strings(arr) }
	if arr, ok := toml_array(t, "languages"); ok { f.languages = _arr_strings(arr) }
	return f
}

@(private)
_apply_keybindings :: proc(cfg: ^Config, arr: ^TOML_Array) {
	for item in arr^ {
		if item.kind != .Table { continue }
		tbl := cast(^TOML_Table)item.ptr
		kb: Keybinding
		if v, ok2 := toml_str(tbl, "command"); ok2 { kb.command      = strings.clone(v) }
		if v, ok2 := toml_str(tbl, "keys");    ok2 { kb.keys         = strings.clone(v) }
		if v, ok2 := toml_str(tbl, "when");    ok2 { kb.context_expr = strings.clone(v) }
		if v, ok2 := toml_str(tbl, "args");    ok2 { kb.args         = strings.clone(v) }
		if kb.command == "" || kb.keys == "" { _kb_destroy(&kb); continue }
		found := false
		for &e in cfg.keybindings {
			if e.command == kb.command && e.context_expr == kb.context_expr {
				_kb_destroy(&e); e = kb; found = true; break
			}
		}
		if !found { append(&cfg.keybindings, kb) }
	}
}

@(private)
_apply_build :: proc(cfg: ^Config, arr: ^TOML_Array) {
	for item in arr^ {
		if item.kind != .Table { continue }
		tbl := cast(^TOML_Table)item.ptr
		b: Build_Config
		if v, ok2 := toml_str(tbl, "name");    ok2 { b.name    = strings.clone(v) }
		if v, ok2 := toml_str(tbl, "command"); ok2 { b.command = strings.clone(v) }
		if v, ok2 := toml_str(tbl, "cwd");     ok2 { b.cwd     = strings.clone(v) }
		if arr2, ok2 := toml_array(tbl, "args"); ok2 { b.args = _arr_strings(arr2) }
		if env, ok2  := toml_table(tbl, "env");  ok2 { b.env  = _table_strings(env) }
		append(&cfg.build, b)
	}
}

// ---------------------------------------------------------------------------
// Directory loaders
// ---------------------------------------------------------------------------

@(private)
_load_lsp_dir :: proc(cfg: ^Config, dir: string) {
	f, err := os.open(dir)
	if err != nil { return }
	defer os.close(f)
	entries, read_err := os.read_dir(f, -1, context.temp_allocator)
	if read_err != nil { return }
	defer os.file_info_slice_delete(entries, context.temp_allocator)
	for info in entries {
		if !strings.has_suffix(info.name, ".toml") { continue }
		path, _ := filepath.join({dir, info.name}, context.temp_allocator)
		tbl, ok := toml_load_file(path)
		if !ok { continue }
		defer toml_destroy_table(tbl)
		if arr, ok2 := toml_array(tbl, "servers"); ok2 {
			_apply_lsp_servers(cfg, arr)
		} else {
			srv := _parse_lsp_server(tbl)
			if srv.id != "" {
				found := false
				for &e in cfg.lsp.servers {
					if e.id == srv.id { _lsp_server_destroy(&e); e = srv; found = true; break }
				}
				if !found { append(&cfg.lsp.servers, srv) }
			}
		}
	}
}

@(private)
_load_dap_dir :: proc(cfg: ^Config, dir: string) {
	f, err := os.open(dir)
	if err != nil { return }
	defer os.close(f)
	entries, read_err := os.read_dir(f, -1, context.temp_allocator)
	if read_err != nil { return }
	defer os.file_info_slice_delete(entries, context.temp_allocator)
	for info in entries {
		if !strings.has_suffix(info.name, ".toml") { continue }
		path, _ := filepath.join({dir, info.name}, context.temp_allocator)
		tbl, ok := toml_load_file(path)
		if !ok { continue }
		defer toml_destroy_table(tbl)
		if arr, ok2 := toml_array(tbl, "adapters"); ok2 {
			_apply_dap_adapters(cfg, arr)
		} else {
			adp := _parse_dap_adapter(tbl)
			if adp.id != "" {
				found := false
				for &e in cfg.dap.adapters {
					if e.id == adp.id { _dap_adapter_destroy(&e); e = adp; found = true; break }
				}
				if !found { append(&cfg.dap.adapters, adp) }
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Language config loader
// ---------------------------------------------------------------------------

load_language_config :: proc(path: string) -> (Language_Config, bool) {
	tbl, ok := toml_load_file(path)
	if !ok { return {}, false }
	defer toml_destroy_table(tbl)
	lc := _parse_language(tbl)
	return lc, lc.id != ""
}

@(private)
_parse_language :: proc(t: ^TOML_Table) -> Language_Config {
	lc: Language_Config
	if v, ok := toml_str(t, "id");            ok { lc.id            = strings.clone(v) }
	if v, ok := toml_str(t, "name");          ok { lc.name          = strings.clone(v) }
	if v, ok := toml_str(t, "comment_line");  ok { lc.comment_line  = strings.clone(v) }
	if v, ok := toml_str(t, "formatter");     ok { lc.formatter     = strings.clone(v) }
	if v, ok := toml_str(t, "lsp");           ok { lc.lsp           = strings.clone(v) }
	if v, ok := toml_str(t, "dap");           ok { lc.dap           = strings.clone(v) }
	if v, ok := toml_str(t, "snippets_file"); ok { lc.snippets_file = strings.clone(v) }
	if v, ok := toml_str(t, "word_separators"); ok { lc.word_separators = strings.clone(v) }
	if n, ok := toml_int(t, "tab_size");      ok { lc.tab_size  = int(n) }
	if b, ok := toml_bool(t, "use_spaces");   ok { lc.use_spaces = b }
	if arr, ok := toml_array(t, "extensions"); ok { lc.extensions = _arr_strings(arr) }
	if arr, ok := toml_array(t, "filenames");  ok { lc.filenames  = _arr_strings(arr) }
	if arr, ok := toml_array(t, "shebangs");   ok { lc.shebangs   = _arr_strings(arr) }
	if cb, ok := toml_array(t, "comment_block"); ok && len(cb^) >= 2 {
		if cb^[0].kind == .Str && cb^[1].kind == .Str {
			lc.comment_block[0] = strings.clone(cb^[0].str)
			lc.comment_block[1] = strings.clone(cb^[1].str)
		}
	}
	return lc
}

language_config_destroy :: proc(lc: ^Language_Config) {
	delete(lc.id); delete(lc.name); delete(lc.comment_line)
	delete(lc.formatter); delete(lc.lsp); delete(lc.dap)
	delete(lc.snippets_file); delete(lc.word_separators)
	delete(lc.comment_block[0]); delete(lc.comment_block[1])
	for s in lc.extensions  { delete(s) }; delete(lc.extensions)
	for s in lc.filenames   { delete(s) }; delete(lc.filenames)
	for s in lc.shebangs    { delete(s) }; delete(lc.shebangs)
	for &p in lc.auto_pairs { delete(p.open); delete(p.close) }
	delete(lc.auto_pairs)
}

// ---------------------------------------------------------------------------
// Theme loader
// ---------------------------------------------------------------------------

load_theme :: proc(path: string) -> (Theme_Config, bool) {
	tbl, ok := toml_load_file(path)
	if !ok { return {}, false }
	defer toml_destroy_table(tbl)

	theme := default_dark_theme()
	if s, ok2 := toml_str(tbl, "name"); ok2 { _replace_str(&theme.name, s) }

	if ui, ok2 := toml_table(tbl, "ui"); ok2 {
		_apply_ui_colors(&theme.ui, ui)
	}
	if syn, ok2 := toml_table(tbl, "syntax"); ok2 {
		_apply_syntax_colors(&theme.syntax, syn)
	}
	return theme, true
}

@(private)
_apply_ui_colors :: proc(ui: ^UI_Colors, t: ^TOML_Table) {
	_color_field(t, "background",        &ui.background)
	_color_field(t, "foreground",        &ui.foreground)
	_color_field(t, "cursor",            &ui.cursor)
	_color_field(t, "cursor_inactive",   &ui.cursor_inactive)
	_color_field(t, "selection",         &ui.selection)
	_color_field(t, "line_highlight",    &ui.line_highlight)
	_color_field(t, "line_number",       &ui.line_number)
	_color_field(t, "line_number_cur",   &ui.line_number_cur)
	_color_field(t, "status_bar_bg",     &ui.status_bar_bg)
	_color_field(t, "status_bar_fg",     &ui.status_bar_fg)
	_color_field(t, "status_bar_sel_bg", &ui.status_bar_sel_bg)
	_color_field(t, "tab_bar_bg",        &ui.tab_bar_bg)
	_color_field(t, "tab_active_bg",     &ui.tab_active_bg)
	_color_field(t, "tab_active_fg",     &ui.tab_active_fg)
	_color_field(t, "tab_inactive_bg",   &ui.tab_inactive_bg)
	_color_field(t, "tab_inactive_fg",   &ui.tab_inactive_fg)
	_color_field(t, "sidebar_bg",        &ui.sidebar_bg)
	_color_field(t, "sidebar_fg",        &ui.sidebar_fg)
	_color_field(t, "sidebar_sel_bg",    &ui.sidebar_sel_bg)
	_color_field(t, "panel_bg",          &ui.panel_bg)
	_color_field(t, "border",            &ui.border)
	_color_field(t, "scrollbar",         &ui.scrollbar)
	_color_field(t, "scrollbar_thumb",   &ui.scrollbar_thumb)
	_color_field(t, "diag_error",        &ui.diag_error)
	_color_field(t, "diag_warn",         &ui.diag_warn)
	_color_field(t, "diag_info",         &ui.diag_info)
	_color_field(t, "diag_hint",         &ui.diag_hint)
	_color_field(t, "lsp_off",           &ui.lsp_off)
	_color_field(t, "lsp_loading",       &ui.lsp_loading)
	_color_field(t, "lsp_ready",         &ui.lsp_ready)
	_color_field(t, "lsp_error",         &ui.lsp_error)
	_color_field(t, "accent",            &ui.accent)
	_color_field(t, "accent_fg",         &ui.accent_fg)
}

@(private)
_apply_syntax_colors :: proc(syn: ^Syntax_Colors, t: ^TOML_Table) {
	_color_field(t, "keyword",     &syn.keyword)
	_color_field(t, "string",      &syn.string_)
	_color_field(t, "comment",     &syn.comment)
	_color_field(t, "number",      &syn.number)
	_color_field(t, "type",        &syn.type_)
	_color_field(t, "function",    &syn.function_)
	_color_field(t, "variable",    &syn.variable)
	_color_field(t, "operator",    &syn.operator)
	_color_field(t, "preproc",     &syn.preproc)
	_color_field(t, "builtin",     &syn.builtin)
	_color_field(t, "constant",    &syn.constant)
	_color_field(t, "label",       &syn.label)
	_color_field(t, "escape",      &syn.escape)
	_color_field(t, "punctuation", &syn.punctuation)
}

@(private)
_color_field :: proc(t: ^TOML_Table, key: string, out: ^Color) {
	if s, ok := toml_str(t, key); ok { out^ = color_from_hex(s) }
}

// ---------------------------------------------------------------------------
// Utility helpers
// ---------------------------------------------------------------------------

@(private)
_replace_str :: proc(dst: ^string, src: string) {
	delete(dst^)
	dst^ = strings.clone(src)
}

@(private)
_arr_strings :: proc(arr: ^TOML_Array) -> []string {
	out := make([]string, len(arr^))
	for v, i in arr^ {
		if v.kind == .Str { out[i] = strings.clone(v.str) }
	}
	return out
}

@(private)
_table_strings :: proc(t: ^TOML_Table) -> map[string]string {
	out := make(map[string]string)
	for k, v in t^ {
		if v.kind == .Str { out[strings.clone(k)] = strings.clone(v.str) }
	}
	return out
}

@(private)
_lsp_server_destroy :: proc(s: ^LSP_Server_Config) {
	delete(s.id); delete(s.name); delete(s.command); delete(s.init_options); delete(s.install_url)
	for a in s.args      { delete(a) }; delete(s.args)
	for l in s.languages { delete(l) }; delete(s.languages)
	for k, v in s.env    { delete(k); delete(v) }; delete(s.env)
}

@(private)
_dap_adapter_destroy :: proc(a: ^DAP_Adapter_Config) {
	delete(a.id); delete(a.name); delete(a.command)
	for arg in a.args      { delete(arg) }; delete(a.args)
	for l   in a.languages { delete(l)   }; delete(a.languages)
	for k, v in a.env      { delete(k); delete(v) }; delete(a.env)
}
