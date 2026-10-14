package config

import "core:strings"

// ---------------------------------------------------------------------------
// Primitive helpers
// ---------------------------------------------------------------------------

// RGBA color stored as 4 bytes.
Color :: [4]u8

color_from_hex :: proc(hex: string) -> Color {
	s := hex
	if len(s) > 0 && s[0] == '#' { s = s[1:] }
	if len(s) == 6 {
		r, _ := _hex2(s[0:2])
		g, _ := _hex2(s[2:4])
		b, _ := _hex2(s[4:6])
		return {r, g, b, 255}
	}
	if len(s) == 8 {
		r, _ := _hex2(s[0:2])
		g, _ := _hex2(s[2:4])
		b, _ := _hex2(s[4:6])
		a, _ := _hex2(s[6:8])
		return {r, g, b, a}
	}
	return {0, 0, 0, 255}
}

@(private)
_hex2 :: proc(s: string) -> (u8, bool) {
	if len(s) < 2 { return 0, false }
	hi := _hexn(s[0]); lo := _hexn(s[1])
	return u8(hi << 4 | lo), true
}
@(private)
_hexn :: proc(ch: u8) -> u8 {
	switch {
	case ch >= '0' && ch <= '9': return ch - '0'
	case ch >= 'a' && ch <= 'f': return ch - 'a' + 10
	case ch >= 'A' && ch <= 'F': return ch - 'A' + 10
	}
	return 0
}

// ---------------------------------------------------------------------------
// Editor
// ---------------------------------------------------------------------------

Editor_Config :: struct {
	tab_size:          int,
	use_spaces:        bool,
	line_numbers:      bool,
	relative_numbers:  bool,
	word_wrap:         bool,
	auto_save:         bool,
	auto_save_delay:   f32,   // seconds
	format_on_save:    bool,
	trim_trailing_ws:  bool,
	insert_final_nl:   bool,
	bracket_matching:  bool,
	show_status_bar:        bool,
	show_minimap:           bool,
	status_bar_position:    string, // "top" | "bottom"
	rulers:            []int, // vertical rulers at these columns
	keymap_mode:       Keymap_Mode,
}

// Which keybinding scheme the main text-editing input pipeline uses.
// Persisted; switched at runtime via the command palette ("Set Keymap Mode").
Keymap_Mode :: enum { Normal, Vim, Emacs }

// ---------------------------------------------------------------------------
// Window
// ---------------------------------------------------------------------------

Window_Config :: struct {
	width:       int,
	height:      int,
	fullscreen:  bool,
	fps_target:  int,
	// ADR 0016: sleep until an event when nothing is moving (false = render
	// every frame at fps_target, the pre-0016 behavior).
	event_driven: bool,
	title:       string,
}

// ---------------------------------------------------------------------------
// Font
// ---------------------------------------------------------------------------

Font_Config :: struct {
	family:       string, // font file or name
	size:         int,
	line_height:  f32,
	char_spacing: f32,
	fallbacks:    []string, // tried in order if family not found
}

// ---------------------------------------------------------------------------
// Theme (UI + syntax)
// ---------------------------------------------------------------------------

Syntax_Colors :: struct {
	keyword:    Color,
	string_:    Color,
	comment:    Color,
	number:     Color,
	type_:      Color,
	function_:  Color,
	variable:   Color,
	operator:   Color,
	preproc:    Color,
	builtin:    Color,
	constant:   Color,
	label:      Color,
	escape:     Color,
	punctuation:Color,
}

UI_Colors :: struct {
	background:       Color,
	foreground:       Color,
	cursor:           Color,
	cursor_inactive:  Color,
	selection:        Color,
	line_highlight:   Color,
	line_number:      Color,
	line_number_cur:  Color,
	status_bar_bg:    Color,
	status_bar_fg:    Color,
	status_bar_sel_bg:Color,
	tab_bar_bg:       Color,
	tab_active_bg:    Color,
	tab_active_fg:    Color,
	tab_inactive_bg:  Color,
	tab_inactive_fg:  Color,
	sidebar_bg:       Color,
	sidebar_fg:       Color,
	sidebar_sel_bg:   Color,
	panel_bg:         Color,
	border:           Color,
	scrollbar:        Color,
	scrollbar_thumb:  Color,
	// Diagnostic
	diag_error:       Color,
	diag_warn:        Color,
	diag_info:        Color,
	diag_hint:        Color,
	// LSP status
	lsp_off:          Color,
	lsp_loading:      Color,
	lsp_ready:        Color,
	lsp_error:        Color,
	// Accent
	accent:           Color,
	accent_fg:        Color,
}

Theme_Config :: struct {
	name:   string,
	ui:     UI_Colors,
	syntax: Syntax_Colors,
}

// ---------------------------------------------------------------------------
// Cursor
// ---------------------------------------------------------------------------

Cursor_Style :: enum { Block, Line, Underline }

Cursor_Config :: struct {
	style:           Cursor_Style,
	blink:           bool,
	blink_rate:      f32, // Hz
}

// ---------------------------------------------------------------------------
// Scrolling
// ---------------------------------------------------------------------------

Scroll_Config :: struct {
	smooth:           bool,
	speed:            f32,
	sensitivity:      f32,
	padding_lines:    int, // lines of context above/below cursor
}

// ---------------------------------------------------------------------------
// Completion
// ---------------------------------------------------------------------------

Completion_Config :: struct {
	enable:           bool,
	trigger_delay:    f32,
	max_results:      int,
	fuzzy:            bool,
	snippets:         bool,
	auto_import:      bool,
	doc_delay:        f32,
}

// ---------------------------------------------------------------------------
// Diagnostics
// ---------------------------------------------------------------------------

Diag_Underline :: enum { None, Underline, Squiggly, Dotted }

Diagnostics_Config :: struct {
	enable:          bool,
	inline_messages: bool,
	gutter_icons:    bool,
	update_on_type:  bool,
	update_delay:    f32,
	underline:       Diag_Underline,
	min_severity:    int, // 1=error 2=warn 3=info 4=hint
}

// ---------------------------------------------------------------------------
// Language
// ---------------------------------------------------------------------------

Auto_Pair :: struct { open, close: string }

Language_Config :: struct {
	id:               string,   // e.g. "cpp", "odin", "python"
	name:             string,   // display name
	extensions:       []string, // e.g. [".cpp", ".hpp"]
	filenames:        []string, // exact filenames e.g. ["Makefile"]
	shebangs:         []string, // e.g. ["python3", "python"]
	comment_line:     string,   // e.g. "//"
	comment_block:    [2]string,// e.g. ["/*","*/"]
	tab_size:         int,      // 0 = inherit from editor
	use_spaces:       bool,
	word_separators:  string,
	auto_pairs:       []Auto_Pair,
	formatter:        string,   // formatter id
	lsp:              string,   // lsp server id
	dap:              string,   // dap adapter id
	snippets_file:    string,
}

// ---------------------------------------------------------------------------
// LSP
// ---------------------------------------------------------------------------

LSP_Server_Config :: struct {
	id:           string,
	name:         string,
	command:      string,
	args:         []string,
	languages:    []string, // language IDs this server handles
	env:          map[string]string,
	init_options: string,   // JSON string
	enabled:      bool,
	priority:     int,      // higher = preferred when multiple servers match
	install_url:  string,   // optional — overrides the built-in download URL
	                        // for servers whose auto-install fetches a release
	                        // asset (jdtls, lua-language-server, zls, lemminx,
	                        // rust-analyzer). Empty = use the built-in default
	                        // for the current OS/arch.
}

LSP_Config :: struct {
	servers: [dynamic]LSP_Server_Config,
}

// ---------------------------------------------------------------------------
// DAP
// ---------------------------------------------------------------------------

DAP_Adapter_Config :: struct {
	id:        string,
	name:      string,
	command:   string,
	args:      []string,
	languages: []string,
	env:       map[string]string,
	enabled:   bool,
}

DAP_Config :: struct {
	adapters: [dynamic]DAP_Adapter_Config,
}

// ---------------------------------------------------------------------------
// Formatter
// ---------------------------------------------------------------------------

Formatter_Config :: struct {
	id:              string,
	name:            string,
	command:         string,
	args:            []string,
	languages:       []string,
	stdin_pipe:      bool,   // pass file via stdin
	enabled:         bool,
}

// ---------------------------------------------------------------------------
// Keybinding
// ---------------------------------------------------------------------------

Keybinding :: struct {
	command: string,
	keys:    string,
	context_expr: string,  // context expression e.g. "editorFocus"
	args:    string,  // JSON args for the command
}

// ---------------------------------------------------------------------------
// Build
// ---------------------------------------------------------------------------

Build_Config :: struct {
	name:    string,
	command: string,
	args:    []string,
	cwd:     string,
	env:     map[string]string,
}

// ---------------------------------------------------------------------------
// Workspace
// ---------------------------------------------------------------------------

Workspace_Config :: struct {
	trusted:       bool,
	file_exclude:  []string, // glob patterns
	search_exclude:[]string,
}

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

Log_Level :: enum { Off, Error, Warn, Info, Debug, Trace }

Log_Config :: struct {
	level:   Log_Level,
	file:    string,   // "" = stderr
	lsp:     bool,     // log LSP messages
}

// ---------------------------------------------------------------------------
// Performance
// ---------------------------------------------------------------------------

Perf_Config :: struct {
	lazy_highlight:      bool,
	max_highlight_lines: int,
	max_file_size_kb:    int,
}

// ---------------------------------------------------------------------------
// Top-level Config
// ---------------------------------------------------------------------------

Config :: struct {
	version:     int,
	editor:      Editor_Config,
	window:      Window_Config,
	font:        Font_Config,
	theme_name:  string,       // name of active theme
	cursor:      Cursor_Config,
	scrolling:   Scroll_Config,
	completion:  Completion_Config,
	diagnostics: Diagnostics_Config,
	lsp:         LSP_Config,
	dap:         DAP_Config,
	formatters:  [dynamic]Formatter_Config,
	keybindings: [dynamic]Keybinding,
	build:       [dynamic]Build_Config,
	workspace:   Workspace_Config,
	logging:     Log_Config,
	performance: Perf_Config,
}

config_destroy :: proc(c: ^Config) {
	delete(c.font.family)
	for s in c.font.fallbacks { delete(s) }
	delete(c.font.fallbacks)
	delete(c.theme_name)
	delete(c.window.title)
	for r in c.editor.rulers { _ = r }
	delete(c.editor.rulers)
	delete(c.editor.status_bar_position)
	_lsp_config_destroy(&c.lsp)
	_dap_config_destroy(&c.dap)
	for &f in c.formatters { _fmt_config_destroy(&f) }
	delete(c.formatters)
	for &kb in c.keybindings { _kb_destroy(&kb) }
	delete(c.keybindings)
	for &b in c.build { _build_destroy(&b) }
	delete(c.build)
	delete(c.logging.file)
	for s in c.workspace.file_exclude   { delete(s) }
	for s in c.workspace.search_exclude { delete(s) }
	delete(c.workspace.file_exclude)
	delete(c.workspace.search_exclude)
}

@(private)
_lsp_config_destroy :: proc(c: ^LSP_Config) {
	for &s in c.servers {
		delete(s.id); delete(s.name); delete(s.command); delete(s.init_options); delete(s.install_url)
		for a in s.args     { delete(a) }; delete(s.args)
		for l in s.languages { delete(l) }; delete(s.languages)
		for k, v in s.env    { delete(k); delete(v) }; delete(s.env)
	}
	delete(c.servers)
}

@(private)
_dap_config_destroy :: proc(c: ^DAP_Config) {
	for &a in c.adapters {
		delete(a.id); delete(a.name); delete(a.command)
		for arg in a.args      { delete(arg) }; delete(a.args)
		for l   in a.languages { delete(l)   }; delete(a.languages)
		for k, v in a.env      { delete(k); delete(v) }; delete(a.env)
	}
	delete(c.adapters)
}

@(private)
_fmt_config_destroy :: proc(f: ^Formatter_Config) {
	delete(f.id); delete(f.name); delete(f.command)
	for a in f.args      { delete(a) }; delete(f.args)
	for l in f.languages { delete(l) }; delete(f.languages)
}

@(private)
_kb_destroy :: proc(kb: ^Keybinding) {
	delete(kb.command); delete(kb.keys); delete(kb.context_expr); delete(kb.args)
}

@(private)
_build_destroy :: proc(b: ^Build_Config) {
	delete(b.name); delete(b.command); delete(b.cwd)
	for a in b.args   { delete(a) }; delete(b.args)
	for k, v in b.env { delete(k); delete(v) }; delete(b.env)
}

// ---------------------------------------------------------------------------
// Defaults
// ---------------------------------------------------------------------------

config_defaults :: proc() -> Config {
	c: Config
	c.version = 1

	c.editor = {
		tab_size         = 4,
		use_spaces       = false,
		line_numbers     = true,
		relative_numbers = false,
		word_wrap        = false,
		auto_save        = false,
		auto_save_delay  = 1.0,
		format_on_save   = false,
		trim_trailing_ws = false,
		insert_final_nl  = true,
		bracket_matching = true,
		show_status_bar       = true,
		show_minimap          = false,
		status_bar_position   = strings.clone("top"),
		keymap_mode           = .Normal,
	}

	c.window = {
		width      = 1280,
		height     = 720,
		fps_target = 60,
		event_driven = true,
		title      = strings.clone("Editor"),
	}

	c.font = {
		family       = strings.clone("font/ttf/FiraCode-Regular.ttf"),
		size         = 14,
		line_height  = 1.0,
		char_spacing = 0.0,
		fallbacks    = {},
	}

	c.theme_name = strings.clone("dark")

	c.cursor = {
		style      = .Block,
		blink      = false,
		blink_rate = 1.0,
	}

	c.scrolling = {
		smooth        = true,
		speed         = 5.0,
		sensitivity   = 1.0,
		padding_lines = 5,
	}

	c.completion = {
		enable        = true,
		trigger_delay = 0.05,
		max_results   = 50,
		fuzzy         = true,
		snippets      = true,
		auto_import   = false,
		doc_delay     = 0.5,
	}

	c.diagnostics = {
		enable          = true,
		inline_messages = false,
		gutter_icons    = true,
		update_on_type  = true,
		update_delay    = 0.3,
		underline       = .Squiggly,
		min_severity    = 4,
	}

	c.performance = {
		lazy_highlight      = true,
		max_highlight_lines = 5000,
		max_file_size_kb    = 5120,
	}

	c.logging = {level = .Warn}

	return c
}

// ---------------------------------------------------------------------------
// Default built-in dark theme (Catppuccin Mocha palette)
// ---------------------------------------------------------------------------

default_dark_theme :: proc() -> Theme_Config {
	t: Theme_Config
	t.name = strings.clone("dark")
	t.ui = {
		background        = {30,  30,  46,  255},
		foreground        = {205, 214, 244, 255},
		cursor            = {243, 139, 168, 255},
		cursor_inactive   = {88,  91,  112, 255},
		selection         = {69,  71,  90,  255},
		line_highlight    = {40,  40,  58,  255},
		line_number       = {88,  91,  112, 255},
		line_number_cur   = {249, 226, 175, 255},
		status_bar_bg     = {24,  24,  37,  255},
		status_bar_fg     = {205, 214, 244, 255},
		status_bar_sel_bg = {137, 180, 250, 255},
		tab_bar_bg        = {24,  24,  37,  255},
		tab_active_bg     = {30,  30,  46,  255},
		tab_active_fg     = {205, 214, 244, 255},
		tab_inactive_bg   = {24,  24,  37,  255},
		tab_inactive_fg   = {108, 112, 134, 255},
		sidebar_bg        = {24,  24,  37,  255},
		sidebar_fg        = {205, 214, 244, 255},
		sidebar_sel_bg    = {49,  50,  68,  255},
		panel_bg          = {24,  24,  37,  255},
		border            = {49,  50,  68,  255},
		scrollbar         = {49,  50,  68,  255},
		scrollbar_thumb   = {88,  91,  112, 255},
		diag_error        = {243, 139, 168, 255},
		diag_warn         = {249, 226, 175, 255},
		diag_info         = {137, 180, 250, 255},
		diag_hint         = {166, 227, 161, 255},
		lsp_off           = {88,  91,  112, 255},
		lsp_loading       = {249, 226, 175, 255},
		lsp_ready         = {166, 227, 161, 255},
		lsp_error         = {243, 139, 168, 255},
		accent            = {137, 180, 250, 255},
		accent_fg         = {30,  30,  46,  255},
	}
	t.syntax = {
		keyword     = {203, 166, 247, 255}, // mauve
		string_     = {166, 227, 161, 255}, // green
		comment     = {88,  91,  112, 255}, // overlay0
		number      = {250, 179, 135, 255}, // peach
		type_       = {249, 226, 175, 255}, // yellow
		function_   = {137, 180, 250, 255}, // blue
		variable    = {205, 214, 244, 255}, // text
		operator    = {137, 220, 235, 255}, // sky
		preproc     = {243, 139, 168, 255}, // red
		builtin     = {116, 199, 236, 255}, // sapphire
		constant    = {250, 179, 135, 255}, // peach
		label       = {166, 227, 161, 255}, // green
		escape      = {245, 194, 231, 255}, // pink
		punctuation = {147, 153, 178, 255}, // overlay2
	}
	return t
}
