package config

import "core:os"
import "core:path/filepath"
import "core:strings"

// ---------------------------------------------------------------------------
// Registry
//
// Central lookup tables built from the loaded config.
// The editor core interacts with these registries instead of raw Config,
// keeping all language/tool-specific logic out of the core.
//
// Ownership: all Registry values are non-owning views into Config slices.
// The Config must outlive the Registry.  Call registry_destroy to free the
// map structures (not the pointed-to data).
// ---------------------------------------------------------------------------

// Language_Registry: maps
//   - file extension (e.g. "odin") → ^Language_Config
//   - filename        (e.g. "Makefile") → ^Language_Config
//   - shebang word    (e.g. "python3")  → ^Language_Config
Language_Registry :: struct {
	by_ext:     map[string]^Language_Config, // key is bare ext without dot
	by_filename:map[string]^Language_Config,
	by_shebang: map[string]^Language_Config,
	configs:    [dynamic]Language_Config,    // owns all language data
}

// LSP_Registry: maps language id → ordered list of server configs
LSP_Registry :: struct {
	by_lang: map[string][dynamic]^LSP_Server_Config, // non-owning
	servers: []^LSP_Server_Config,                   // non-owning views into Config
}

// DAP_Registry: maps language id → adapter config
DAP_Registry :: struct {
	by_lang: map[string]^DAP_Adapter_Config,
}

// Formatter_Registry: maps language id → formatter config
Formatter_Registry :: struct {
	by_lang: map[string]^Formatter_Config,
}

// Theme_Registry: maps name → theme
Theme_Registry :: struct {
	themes: map[string]Theme_Config, // owns theme data
}

// ---------------------------------------------------------------------------
// Master registry — single object passed around the editor
// ---------------------------------------------------------------------------

Registry :: struct {
	lang:      Language_Registry,
	lsp:       LSP_Registry,
	dap:       DAP_Registry,
	formatter: Formatter_Registry,
	theme:     Theme_Registry,
	active_theme: ^Theme_Config, // points into theme.themes
}

// ---------------------------------------------------------------------------
// Build registries from a loaded Config
// ---------------------------------------------------------------------------

registry_build :: proc(cfg: ^Config, lang_dir: string, theme_dir: string) -> Registry {
	r: Registry

	// ---- Language registry ----
	r.lang.by_ext      = make(map[string]^Language_Config)
	r.lang.by_filename = make(map[string]^Language_Config)
	r.lang.by_shebang  = make(map[string]^Language_Config)

	// Load language files from languages/ directory
	_load_languages_dir(&r.lang, lang_dir)

	// ---- LSP registry ----
	r.lsp.by_lang = make(map[string][dynamic]^LSP_Server_Config)
	for &srv in cfg.lsp.servers {
		if !srv.enabled { continue }
		for lang in srv.languages {
			if _, exists := r.lsp.by_lang[lang]; !exists {
				r.lsp.by_lang[strings.clone(lang)] = make([dynamic]^LSP_Server_Config)
			}
			append(&r.lsp.by_lang[lang], &srv)
		}
	}
	// Sort by priority (higher priority = preferred)
	for _, &list in r.lsp.by_lang {
		_sort_lsp_by_priority(list[:])
	}

	// ---- DAP registry ----
	r.dap.by_lang = make(map[string]^DAP_Adapter_Config)
	for &adp in cfg.dap.adapters {
		if !adp.enabled { continue }
		for lang in adp.languages {
			if _, exists := r.dap.by_lang[lang]; !exists {
				r.dap.by_lang[strings.clone(lang)] = &adp
			}
		}
	}

	// ---- Formatter registry ----
	r.formatter.by_lang = make(map[string]^Formatter_Config)
	for &fmt in cfg.formatters {
		if !fmt.enabled { continue }
		for lang in fmt.languages {
			if _, exists := r.formatter.by_lang[lang]; !exists {
				r.formatter.by_lang[strings.clone(lang)] = &fmt
			}
		}
	}

	// ---- Theme registry ----
	r.theme.themes = make(map[string]Theme_Config)
	// Built-in default themes
	dark := default_dark_theme()
	r.theme.themes[strings.clone(dark.name)] = dark
	// Load from directory
	_load_themes_dir(&r.theme, theme_dir)
	// Set active theme
	_set_active_theme(&r, cfg.theme_name)

	return r
}

registry_destroy :: proc(r: ^Registry) {
	// Language registry
	for k in r.lang.by_ext      { delete(k) }; delete(r.lang.by_ext)
	for k in r.lang.by_filename { delete(k) }; delete(r.lang.by_filename)
	for k in r.lang.by_shebang  { delete(k) }; delete(r.lang.by_shebang)
	for &lc in r.lang.configs   { language_config_destroy(&lc) }
	delete(r.lang.configs)

	// LSP registry
	for k, &list in r.lsp.by_lang { delete(k); delete(list) }
	delete(r.lsp.by_lang)

	// DAP registry
	for k in r.dap.by_lang { delete(k) }; delete(r.dap.by_lang)

	// Formatter registry
	for k in r.formatter.by_lang { delete(k) }; delete(r.formatter.by_lang)

	// Theme registry
	for k, &th in r.theme.themes { delete(k); _theme_destroy(&th) }
	delete(r.theme.themes)
}

// ---------------------------------------------------------------------------
// Lookup APIs (language-agnostic — no hardcoded language IDs anywhere)
// ---------------------------------------------------------------------------

// Find language config by file extension (without leading dot).
registry_lang_by_ext :: proc(r: ^Registry, ext: string) -> ^Language_Config {
	return r.lang.by_ext[ext]
}

// Find language config by exact filename.
registry_lang_by_filename :: proc(r: ^Registry, name: string) -> ^Language_Config {
	return r.lang.by_filename[name]
}

// Find language config by language ID.
registry_lang_by_id :: proc(r: ^Registry, id: string) -> ^Language_Config {
	for &lc in r.lang.configs {
		if lc.id == id { return &lc }
	}
	return nil
}

// Find the highest-priority LSP server for a language ID.
registry_lsp_primary :: proc(r: ^Registry, lang_id: string) -> ^LSP_Server_Config {
	list, ok := r.lsp.by_lang[lang_id]
	if !ok || len(list) == 0 { return nil }
	return list[0]
}

// Get ALL servers for a language (ordered by priority, first = best).
registry_lsp_all :: proc(r: ^Registry, lang_id: string) -> []^LSP_Server_Config {
	list, ok := r.lsp.by_lang[lang_id]
	if !ok { return nil }
	return list[:]
}

// Find the LSP server for a given file path (uses extension → language → server).
registry_lsp_for_path :: proc(r: ^Registry, path: string) -> ^LSP_Server_Config {
	ext := _path_ext(path)
	lc  := registry_lang_by_ext(r, ext)
	if lc == nil { return nil }
	if lc.lsp == "" { return registry_lsp_primary(r, lc.id) }
	// Language specifies a preferred server
	return registry_lsp_by_id(r, lc.lsp)
}

// Find LSP server by its id.
registry_lsp_by_id :: proc(r: ^Registry, id: string) -> ^LSP_Server_Config {
	for lang_id, list in r.lsp.by_lang {
		_ = lang_id
		for srv in list {
			if srv.id == id { return srv }
		}
	}
	return nil
}

// Find the DAP adapter for a language ID.
registry_dap_for_lang :: proc(r: ^Registry, lang_id: string) -> ^DAP_Adapter_Config {
	return r.dap.by_lang[lang_id]
}

// Find the formatter for a language ID.
registry_formatter_for_lang :: proc(r: ^Registry, lang_id: string) -> ^Formatter_Config {
	return r.formatter.by_lang[lang_id]
}

// Get the active theme.
registry_active_theme :: proc(r: ^Registry) -> ^Theme_Config {
	if r.active_theme != nil { return r.active_theme }
	// Fallback: first theme
	for _, &t in r.theme.themes { return &t }
	return nil
}

// Switch active theme by name.
registry_set_theme :: proc(r: ^Registry, name: string) {
	_set_active_theme(r, name)
}

// ---------------------------------------------------------------------------
// LSP command builder — returns command slice ready for exec
// Always heap-allocates; caller must delete each string and the slice.
// ---------------------------------------------------------------------------

registry_lsp_command :: proc(r: ^Registry, lang_id: string) -> ([]string, bool) {
	srv := registry_lsp_primary(r, lang_id)
	if srv == nil || srv.command == "" { return nil, false }
	cmd := make([]string, 1 + len(srv.args))
	cmd[0] = strings.clone(srv.command)
	for a, i in srv.args { cmd[i+1] = strings.clone(a) }
	return cmd, true
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

@(private)
_load_languages_dir :: proc(lr: ^Language_Registry, dir: string) {
	f, err := os.open(dir)
	if err != nil { return }
	defer os.close(f)
	entries, read_err := os.read_dir(f, -1, context.temp_allocator)
	if read_err != nil { return }
	defer os.file_info_slice_delete(entries, context.temp_allocator)
	for info in entries {
		if !strings.has_suffix(info.name, ".toml") { continue }
		path, _ := filepath.join({dir, info.name}, context.temp_allocator)
		lc, ok := load_language_config(path)
		if !ok || lc.id == "" { continue }
		append(&lr.configs, lc)
		ptr := &lr.configs[len(lr.configs)-1]
		for ext in lc.extensions {
			bare := ext
			if len(bare) > 0 && bare[0] == '.' { bare = bare[1:] }
			lr.by_ext[strings.clone(bare)] = ptr
		}
		for name in lc.filenames {
			lr.by_filename[strings.clone(name)] = ptr
		}
		for shebang in lc.shebangs {
			lr.by_shebang[strings.clone(shebang)] = ptr
		}
	}
}

@(private)
_load_themes_dir :: proc(tr: ^Theme_Registry, dir: string) {
	f, err := os.open(dir)
	if err != nil { return }
	defer os.close(f)
	entries, read_err := os.read_dir(f, -1, context.temp_allocator)
	if read_err != nil { return }
	defer os.file_info_slice_delete(entries, context.temp_allocator)
	for info in entries {
		if !strings.has_suffix(info.name, ".toml") { continue }
		path, _ := filepath.join({dir, info.name}, context.temp_allocator)
		theme, ok := load_theme(path)
		if !ok { continue }
		if old, exists := tr.themes[theme.name]; exists {
			// same name (e.g. themes/dark.toml vs the built-in): the map
			// keeps its existing key, so don't clone a new one (it leaked)
			_theme_destroy(&old)
			tr.themes[theme.name] = theme
			continue
		}
		tr.themes[strings.clone(theme.name)] = theme
	}
}

@(private)
_set_active_theme :: proc(r: ^Registry, name: string) {
	for th_name, &t in r.theme.themes {
		if th_name == name { r.active_theme = &t; return }
	}
}

@(private)
_sort_lsp_by_priority :: proc(list: []^LSP_Server_Config) {
	// Insertion sort — list is typically tiny (1-3 servers per language)
	for i in 1..<len(list) {
		key := list[i]
		j   := i - 1
		for j >= 0 && list[j].priority < key.priority {
			list[j+1] = list[j]
			j -= 1
		}
		list[j+1] = key
	}
}

@(private)
_path_ext :: proc(path: string) -> string {
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '.' { return path[i+1:] }
		if path[i] == '/' { break }
	}
	return ""
}

@(private)
_theme_destroy :: proc(t: ^Theme_Config) {
	delete(t.name)
}
