package editor

import "core:fmt"
import "core:os"
import "core:sort"
import "core:strings"
import "core:sync"
import rl   "vendor:raylib"
import conf "./config"

// ---- Command pattern ----

Command :: struct {
	name:    string,
	desc:    string,
	execute: proc(e: ^Editor, p: ^Palette),
	// Optional capability gate — nil means "always show". Used for LSP
	// commands (Find References, Go to Implementation, ...) so the palette
	// only lists what the active file's language server actually supports,
	// per Language_Client.caps, instead of hardcoding a fixed feature set.
	available: proc(e: ^Editor) -> bool,
}

// ---- Location list — shared result UI for LSP navigation commands ----
//
// References, Go to Implementation, Go to Type Definition, Go to
// Declaration, and Document Symbols all resolve to "a list of places in the
// workspace" — same shape, same UI. One result opens the file directly
// (see _open_locations_or_navigate in lsp_integration.odin); multiple
// results list here for the user to pick.

Location_Item :: struct {
	label:  string, // heap — display name (symbol name / reference line)
	detail: string, // heap — secondary text (kind, container, file)
	file:   string, // heap — absolute path
	line:   int,    // 1-based
	col:    int,    // 1-based
}

location_item_destroy :: proc(li: ^Location_Item) {
	delete(li.label)
	delete(li.detail)
	delete(li.file)
}

// ---- Palette state ----

Palette_Mode :: enum { Commands, Files, Search, Marks, Themes, Locations, Workspace_Symbols, Keymap_Modes }

// Fixed 3-item list (unlike Themes' registry-driven set) — deliberately a
// static array rather than a p.themes-style [dynamic]string.
keymap_choices := [3]string{"Normal", "Vim", "Emacs"}

_keymap_choice_mode :: proc(name: string) -> conf.Keymap_Mode {
	switch name {
	case "Vim":   return .Vim
	case "Emacs": return .Emacs
	}
	return .Normal
}

Palette :: struct {
	open:         bool,
	mode:         Palette_Mode,
	query:        [dynamic]u8,
	sel_all:      bool,
	selected:     int,
	scroll:       int,
	cmds:         [dynamic]Command,
	files:        [dynamic]string,
	themes:       [dynamic]string, // theme names for .Themes mode
	cwd:          string,
	search:       Search_State,
	search_timer: f32,
	marks:        ^[dynamic]Mark, // pointer into Editor.marks
	locations:    [dynamic]Location_Item, // .Locations and .Workspace_Symbols results
	loc_title:    string,                 // heap — e.g. "12 references"
}

// ---- Lifecycle ----

palette_init :: proc() -> Palette {
	p: Palette
	p.query  = make([dynamic]u8)
	p.files  = make([dynamic]string)
	p.themes = make([dynamic]string)
	p.cmds      = make([dynamic]Command)
	p.locations = make([dynamic]Location_Item)
	p.search    = search_state_init()

	append(&p.cmds,
		Command{"Open Workspace",            "Open a folder and set it as the workspace root",    cmd_open_workspace, nil},
		Command{"Find File in Workspace",   "Open any file in current directory by name",        cmd_find_file, nil},
		Command{"Search in Workspace",      "Search text across all files (case-insensitive)",   cmd_search_workspace, nil},
		Command{"Mark Line",                "Bookmark the current line with a description",       cmd_mark_line, nil},
		Command{"List Marks",               "Browse and jump to all bookmarked lines",            cmd_list_marks, nil},
		Command{"Outline",                  "Browse symbols in current file",                    cmd_outline, nil},
		Command{"Go to Line",               "Jump to a specific line number",                    cmd_goto_line, nil},
		Command{"New File",                 "Create an empty buffer",                            cmd_new_file, nil},
		Command{"New Directory",            "Create a new directory in the workspace",           cmd_new_directory, nil},
		Command{"Save File",                "Save current file to disk",                        cmd_save_file, nil},
		Command{"Close File",               "Close current file and clear buffer",              cmd_close_file, nil},
		Command{"Rename File",              "Rename the current file on disk",                  cmd_rename_file, nil},
		Command{"Delete File",              "Delete the current file from disk",                cmd_delete_file, nil},
		Command{"Split Vertical",           "Split editor into two side-by-side panes",         cmd_split_vertical, nil},
		Command{"Split Horizontal",         "Split editor into two stacked panes",              cmd_split_horizontal, nil},
		Command{"Close Split",              "Close active pane, return to single pane",         cmd_close_split, nil},
		Command{"Exit",                     "Quit the editor",                                  cmd_exit, nil},
		Command{"LSP Control",              "Open LSP server control panel",                    cmd_lsp_control, nil},
		Command{"Go to Definition",         "Jump to where the symbol under cursor is defined", cmd_lsp_goto_definition,     _avail_definition},
		Command{"Find References",         "List all usages of the symbol under cursor",       cmd_lsp_references,          _avail_references},
		Command{"Go to Implementation",    "Jump to the implementation of an interface/method",cmd_lsp_goto_implementation, _avail_implementation},
		Command{"Go to Type Definition",   "Jump to the type of the symbol under cursor",      cmd_lsp_goto_type_definition,_avail_type_definition},
		Command{"Go to Declaration",       "Jump to the declaration of the symbol under cursor",cmd_lsp_goto_declaration,   _avail_declaration},
		Command{"Go to Symbol in File",    "Jump to a function/class/variable in this file",   cmd_lsp_document_symbols,    _avail_document_symbol},
		Command{"Go to Symbol in Workspace","Jump to a symbol anywhere in the workspace",       cmd_lsp_workspace_symbols,   _avail_workspace_symbol},
		Command{"Rename Symbol",           "Rename the symbol under cursor across the project",cmd_lsp_rename,              _avail_rename},
		Command{"Format Document",         "Reformat the current file via its language server",cmd_lsp_format,              _avail_format},
		Command{"Code Actions",            "Show quick fixes / refactorings at the cursor",    cmd_lsp_code_actions,        _avail_code_actions},
		Command{"Problems",                "List errors/warnings in the current file",         cmd_lsp_problems,            _avail_problems},
		Command{"Git",                      "Open Git panel (stage, commit, diff)",             cmd_git_panel, nil},
		Command{"Git Blame: Toggle",        "Show/hide date + author gutter for the active file", cmd_git_blame_toggle, nil},
		Command{"Switch Theme",             "Browse and apply editor color themes",             cmd_switch_theme, nil},
		Command{"Set Keymap Mode",          "Switch between Normal, Vim, and Emacs keybindings", cmd_set_keymap_mode, nil},
		Command{"Toggle Line Numbers",      "Show or hide line numbers in the active pane",     cmd_toggle_line_numbers, nil},
	)
	register_debug_commands(&p)

	cwd, err := os.get_working_directory(context.allocator)
	if err == nil { p.cwd = cwd }
	return p
}

palette_destroy :: proc(p: ^Palette) {
	search_state_destroy(&p.search)
	delete(p.query)
	delete(p.cmds)
	for f in p.files  { delete(f) }; delete(p.files)
	for t in p.themes { delete(t) }; delete(p.themes)
	for &li in p.locations { location_item_destroy(&li) }; delete(p.locations)
	if p.loc_title != "" { delete(p.loc_title) }
	if p.cwd != "" { delete(p.cwd) }
	p^ = {}
}

// Open the shared location-list mode with a fresh result set (takes
// ownership of items — caller must not use or free it afterward).
palette_open_locations :: proc(p: ^Palette, title: string, items: [dynamic]Location_Item) {
	for &li in p.locations { location_item_destroy(&li) }
	delete(p.locations)
	p.locations = items
	if p.loc_title != "" { delete(p.loc_title) }
	p.loc_title = strings.clone(title)
	p.open     = true
	p.mode     = .Locations
	p.selected = 0
	p.scroll   = 0
	p.sel_all  = false
	clear(&p.query)
}

// Open live workspace-symbol search — results arrive asynchronously via
// palette_set_workspace_symbol_results as the user types (debounced).
palette_open_workspace_symbols :: proc(p: ^Palette) {
	for &li in p.locations { location_item_destroy(&li) }
	clear(&p.locations)
	p.open         = true
	p.mode         = .Workspace_Symbols
	p.selected     = 0
	p.scroll       = 0
	p.sel_all      = false
	p.search_timer = 0
	clear(&p.query)
}

// Called by the workspace/symbol response handler. Ignored if the user has
// since closed the palette or switched modes (response arrived too late).
palette_set_workspace_symbol_results :: proc(p: ^Palette, items: [dynamic]Location_Item) {
	if p.mode != .Workspace_Symbols {
		for &li in items { location_item_destroy(&li) }
		delete(items)
		return
	}
	for &li in p.locations { location_item_destroy(&li) }
	delete(p.locations)
	p.locations = items
}

palette_open :: proc(p: ^Palette) {
	p.open     = true
	p.mode     = .Commands
	p.selected = 0
	p.scroll   = 0
	p.sel_all  = false
	clear(&p.query)
}

palette_close :: proc(p: ^Palette) {
	p.open    = false
	p.sel_all = false
}

palette_open_files :: proc(p: ^Palette, e: ^Editor) {
	p.open = true
	cmd_find_file(e, p)
}

palette_open_search :: proc(p: ^Palette, e: ^Editor) {
	p.open = true
	cmd_search_workspace(e, p)
}

palette_open_themes :: proc(p: ^Palette, reg: ^conf.Registry) {
	for t in p.themes { delete(t) }
	clear(&p.themes)
	for name in reg.theme.themes {
		append(&p.themes, strings.clone(name))
	}
	sort.quick_sort(p.themes[:])
	p.open     = true
	p.mode     = .Themes
	p.selected = 0
	p.scroll   = 0
	p.sel_all  = false
	clear(&p.query)
}

palette_open_keymap_modes :: proc(p: ^Palette, e: ^Editor) {
	p.open     = true
	p.mode     = .Keymap_Modes
	for name, i in keymap_choices {
		if _keymap_choice_mode(name) == e.cfg.editor.keymap_mode { p.selected = i }
	}
	p.scroll  = 0
	p.sel_all = false
	clear(&p.query)
}

// ---- Input ----

PALETTE_MAX_VIS :: 8

palette_handle_input :: proc(p: ^Palette, e: ^Editor) {
	// Advance search / workspace-symbol debounce timer
	if (p.mode == .Search || p.mode == .Workspace_Symbols) && p.search_timer > 0 {
		p.search_timer -= rl.GetFrameTime()
		if p.search_timer <= 0 {
			p.search_timer = 0
			if p.mode == .Search {
				search_start(&p.search, string(p.query[:]))
			} else {
				_lsp_workspace_symbol_query(e, string(p.query[:]))
			}
		}
	}

	if rl.IsKeyPressed(.ESCAPE) { p.sel_all = false; palette_close(p); return }

	if key_rep(.UP) {
		p.sel_all = false
		if p.selected > 0 {
			p.selected -= 1
			if p.selected < p.scroll { p.scroll = p.selected }
		}
		return
	}

	if key_rep(.DOWN) {
		p.sel_all = false
		n := palette_count(p, e, string(p.query[:]))
		if p.selected < n - 1 {
			p.selected += 1
			if p.selected >= p.scroll + PALETTE_MAX_VIS {
				p.scroll = p.selected - PALETTE_MAX_VIS + 1
			}
		}
		return
	}

	if rl.IsKeyPressed(.ENTER) {
		p.sel_all = false
		palette_execute(p, e)
		return
	}

	// Delete key in Marks mode removes the selected mark
	if p.mode == .Marks && rl.IsKeyPressed(.DELETE) {
		if p.marks != nil {
			q   := string(p.query[:])
			vis := 0
			for i in 0..<len(p.marks^) {
				if !_mark_match(p.marks^[i], q) { continue }
				if vis == p.selected {
					delete(p.marks^[i].filename)
					delete(p.marks^[i].desc)
					ordered_remove(p.marks, i)
					n := palette_count(p, e, q)
					if p.selected >= n && p.selected > 0 { p.selected -= 1 }
					break
				}
				vis += 1
			}
		}
		return
	}

	if text_input_handle(&p.query, &p.sel_all) {
		palette_reset_selection(p)
		if p.mode == .Search || p.mode == .Workspace_Symbols { p.search_timer = 0.35 }
	}
}

palette_reset_selection :: proc(p: ^Palette) {
	p.selected = 0
	p.scroll   = 0
}

// ---- Execute ----

palette_execute :: proc(p: ^Palette, e: ^Editor) {
	q := string(p.query[:])
	switch p.mode {
	case .Commands:
		vis := 0
		for &cmd in p.cmds {
			if !pal_match(cmd.name, q) { continue }
			if cmd.available != nil && !cmd.available(e) { continue }
			if vis == p.selected { cmd.execute(e, p); return }
			vis += 1
		}

	case .Locations:
		vis := 0
		for li in p.locations {
			if !pal_match(li.label, q) { continue }
			if vis == p.selected {
				location_jump(e, li)
				// Full label (untruncated by the list's fixed row width) plus
				// detail — e.g. for Problems this is the complete diagnostic
				// message, not just what fit on one line.
				e.msg = fmt.tprintf("%s  \xc2\xb7  %s", li.label, li.detail) if li.detail != "" else li.label
				palette_close(p)
				return
			}
			vis += 1
		}

	case .Workspace_Symbols:
		if p.selected >= 0 && p.selected < len(p.locations) {
			li := p.locations[p.selected]
			location_jump(e, li)
			e.msg = fmt.tprintf("%s  \xc2\xb7  %s", li.label, li.detail) if li.detail != "" else li.label
			palette_close(p)
		}

	case .Files:
		vis := 0
		for f in p.files {
			if !pal_match(f, q) { continue }
			if vis == p.selected {
				editor_open(e, f)
				palette_close(p)
				return
			}
			vis += 1
		}

	case .Search:
		// Enter with no query: start search
		// Enter with results: jump to selected
		sync.mutex_lock(&p.search.mu)
		n := len(p.search.results)
		sync.mutex_unlock(&p.search.mu)

		if n == 0 {
			p.search_timer = 0
			search_start(&p.search, q)
			return
		}
		// Jump to selected result
		sync.mutex_lock(&p.search.mu)
		sel := p.selected
		if sel < 0 { sel = 0 }
		if sel >= len(p.search.results) { sel = len(p.search.results) - 1 }
		r := p.search.results[sel]
		sync.mutex_unlock(&p.search.mu)

		search_jump(e, &r)
		palette_close(p)

	case .Marks:
		if p.marks == nil { return }
		q   := string(p.query[:])
		vis := 0
		for i in 0..<len(p.marks^) {
			if !_mark_match(p.marks^[i], q) { continue }
			if vis == p.selected {
				m := p.marks^[i]
				if m.filename != "" { editor_open(e, m.filename) }
				ap    := active_pane(e)
				total := buffer_line_count(&ap.buf)
				target := min(max(0, m.line - 1), total - 1)
				ls := buffer_line_start(&ap.buf, target)
				ap.cursor     = ls
				ap.sel_anchor = ls
				ap.scroll     = max(0, target - 10)
				ap.scroll_anim = f32(ap.scroll)
				palette_close(p)
				return
			}
			vis += 1
		}

	case .Themes:
		vis := 0
		for name in p.themes {
			if !pal_match(name, q) { continue }
			if vis == p.selected {
				conf.registry_set_theme(&e.registry, name)
				e.cfg.theme_name = name
				palette_close(p)
				return
			}
			vis += 1
		}

	case .Keymap_Modes:
		vis := 0
		for name in keymap_choices {
			if !pal_match(name, q) { continue }
			if vis == p.selected {
				e.cfg.editor.keymap_mode = _keymap_choice_mode(name)
				keymap_switch_reset(e)
				if !conf.config_persist_keymap_mode(conf.default_config_paths().workspace, e.cfg.editor.keymap_mode) {
					e.msg = "Keymap mode set (not saved to editor.toml)"
				} else {
					e.msg = fmt.tprintf("Keymap mode: %s", name)
				}
				palette_close(p)
				return
			}
			vis += 1
		}
	}
}

location_jump :: proc(e: ^Editor, li: Location_Item) {
	nav_push(&e.nav_hist, e)
	p := active_pane(e)
	if p.filename != li.file {
		editor_open(e, li.file)
		p = active_pane(e)
	}
	target := max(0, li.line - 1)
	total  := buffer_line_count(&p.buf)
	if target >= total { target = total - 1 }
	ls := buffer_line_start(&p.buf, target)
	ll := buffer_line_length(&p.buf, target)
	p.cursor      = ls + min(max(0, li.col - 1), ll)
	p.sel_anchor  = p.cursor
	p.scroll      = max(0, target - 10)
	p.scroll_anim = f32(p.scroll)
}

search_jump :: proc(e: ^Editor, r: ^Search_Result) {
	p := active_pane(e)
	if p.filename != r.file {
		editor_open(e, r.file)
		p = active_pane(e)
	}
	target := max(0, r.line - 1)
	total  := buffer_line_count(&p.buf)
	if target >= total { target = total - 1 }
	ls := buffer_line_start(&p.buf, target)
	ll := buffer_line_length(&p.buf, target)
	p.cursor     = ls + min(max(0, r.col - 1), ll)
	p.sel_anchor = p.cursor
	// Center scroll on result
	p.scroll      = max(0, target - 10)
	p.scroll_anim = f32(p.scroll)
}

// ---- File scanner ----

palette_scan_files :: proc(p: ^Palette) {
	for f in p.files { delete(f) }
	clear(&p.files)

	SKIP :: [?]string{".git", "node_modules", "target", "__pycache__",
	                  ".cache", "build", "dist", ".next", "vendor"}

	w: os.Walker
	os.walker_init(&w, ".")
	defer os.walker_destroy(&w)

	for {
		info, ok := os.walker_walk(&w)
		if !ok { break }

		if info.type == .Directory {
			skip := len(info.name) > 0 && info.name[0] == '.'
			if !skip {
				for s in SKIP { if info.name == s { skip = true; break } }
			}
			if skip { os.walker_skip_dir(&w) }
		} else {
			append(&p.files, strings.clone(info.fullpath))
		}
	}
}

// ---- Count filtered items ----

palette_count :: proc(p: ^Palette, e: ^Editor, q: string) -> int {
	switch p.mode {
	case .Commands:
		n := 0
		for cmd in p.cmds {
			if !pal_match(cmd.name, q) { continue }
			if cmd.available != nil && !cmd.available(e) { continue }
			n += 1
		}
		return n
	case .Locations:
		n := 0
		for li in p.locations { if pal_match(li.label, q) { n += 1 } }
		return n
	case .Workspace_Symbols:
		return len(p.locations) // already server-filtered by query
	case .Files:
		n := 0
		for f in p.files { if pal_match(f, q) { n += 1 } }
		return n
	case .Search:
		sync.mutex_lock(&p.search.mu)
		n := len(p.search.results)
		sync.mutex_unlock(&p.search.mu)
		return n
	case .Marks:
		if p.marks == nil { return 0 }
		n := 0
		for m in p.marks^ { if _mark_match(m, q) { n += 1 } }
		return n
	case .Themes:
		n := 0
		for t in p.themes { if pal_match(t, q) { n += 1 } }
		return n
	case .Keymap_Modes:
		n := 0
		for name in keymap_choices { if pal_match(name, q) { n += 1 } }
		return n
	}
	return 0
}

// ---- Rendering ----

palette_render :: proc(p: ^Palette, e: ^Editor, font: rl.Font) {
	if !p.open { return }

	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())

	ref := rl.MeasureTextEx(font, "M", FONT_SIZE, CHAR_SPACING)
	cw  := ref.x
	ch  := ref.y + LINE_SPACING

	PANEL_W  :: f32(640)
	ITEM_H   :: f32(50)
	QUERY_H  :: f32(48)
	FOOTER_H :: f32(30)

	OVERLAY :: rl.Color{0, 0, 0, 160}
	SHADOW  :: rl.Color{0, 0, 0, 80}

	// Pulled from active theme
	th := conf.registry_active_theme(&e.registry)
	_pc :: proc(c: conf.Color) -> rl.Color { return {c[0], c[1], c[2], c[3]} }
	PANEL_BG  := BG
	PANEL_BOR := DIVIDER_COL
	INPUT_BG  := STATUS_BG
	SEL_BG_P  := SEL_BG
	ACCENT    := ACCENT_COL
	SUBDUED   := LINENUM
	MATCH_COL := rl.Color{166, 227, 161, 255}
	if th != nil {
		MATCH_COL = _pc(th.syntax.string_)
	}

	q       := string(p.query[:])
	n_items := palette_count(p, e, q)
	vis     := min(n_items, PALETTE_MAX_VIS)
	panel_h := QUERY_H + f32(vis)*ITEM_H + FOOTER_H

	panel_x := (sw - PANEL_W) * 0.5
	panel_y := sh * 0.13

	if n_items > 0 && p.selected >= n_items { p.selected = n_items - 1 }

	rl.DrawRectangle(0, 0, i32(sw), i32(sh), OVERLAY)
	panel_x, panel_y = dlg_begin(panel_x, panel_y, PANEL_W, panel_h, PANEL_BG, PANEL_BOR)

	// Search box
	rl.DrawRectangleV({panel_x, panel_y}, {PANEL_W, QUERY_H}, INPUT_BG)
	rl.DrawLineV({panel_x, panel_y + QUERY_H - 1}, {panel_x + PANEL_W, panel_y + QUERY_H - 1}, PANEL_BOR)

	icon := ">" if p.mode == .Search else ("*" if p.mode == .Themes else "?")
	rl.DrawTextEx(font, to_cstring(icon), {panel_x + 14, panel_y + 14}, FONT_SIZE, CHAR_SPACING, ACCENT)

	if len(q) > 0 {
		tx  := panel_x + 14 + cw + 10
		tw  := rl.MeasureTextEx(font, to_cstring(q), FONT_SIZE, CHAR_SPACING).x
		if p.sel_all {
			rl.DrawRectangleV({tx - 2, panel_y + 10}, {tw + 4, ch + 4}, rl.Color{137, 180, 250, 60})
			rl.DrawRectangleLinesEx({tx - 2, panel_y + 10, tw + 4, ch + 4}, 1, rl.Color{137, 180, 250, 180})
		}
		rl.DrawTextEx(font, to_cstring(q), {tx, panel_y + 14}, FONT_SIZE, CHAR_SPACING, TEXT)
		if !p.sel_all {
			rl.DrawRectangleV({tx + tw, panel_y + 12}, {2, ch}, ACCENT)
		}
	} else {
		ph_map := #partial [Palette_Mode]string{
			.Commands          = "Type a command...",
			.Files             = "Type filename...",
			.Search            = "Type to search... (Enter to run)",
			.Marks             = "Filter marks...",
			.Themes            = "Filter themes...",
			.Locations         = "Filter results...",
			.Workspace_Symbols = "Type a symbol name...",
			.Keymap_Modes      = "Filter keymap modes...",
		}
		placeholder := ph_map[p.mode]
		rl.DrawTextEx(font, to_cstring(placeholder), {panel_x + 14 + cw + 10, panel_y + 14}, FONT_SIZE, CHAR_SPACING, SUBDUED)
	}
	rl.DrawTextEx(font, to_cstring("Esc"), {panel_x + PANEL_W - 36, panel_y + 14}, FONT_SIZE, CHAR_SPACING, SUBDUED)

	// Items — panel scissor (set by dlg_begin) clips all text to panel bounds
	item_y  := panel_y + QUERY_H
	draw_i  := 0
	data_i  := 0
	txt_max := panel_x + PANEL_W - 32 // right edge minus ">" icon + padding

	switch p.mode {
	case .Commands:
		for cmd in p.cmds {
			if !pal_match(cmd.name, q) { continue }
			if cmd.available != nil && !cmd.available(e) { continue }
			if data_i < p.scroll { data_i += 1; continue }
			if draw_i >= PALETTE_MAX_VIS { break }
			iy := item_y + f32(draw_i) * ITEM_H
			if data_i == p.selected {
				rl.DrawRectangleV({panel_x, iy}, {PANEL_W, ITEM_H}, SEL_BG_P)
				rl.DrawRectangleV({panel_x, iy}, {3, ITEM_H}, ACCENT)
			}
			dlg_text(font, cmd.name, panel_x + 16, iy + 7,      FONT_SIZE,     CHAR_SPACING, TEXT,    txt_max, 0)
			dlg_text(font, cmd.desc, panel_x + 16, iy + 7 + ch, FONT_SIZE - 2, CHAR_SPACING, SUBDUED, txt_max, 0)
			rl.DrawTextEx(font, to_cstring(">"), {panel_x + PANEL_W - 22, iy + 7}, FONT_SIZE, CHAR_SPACING, SUBDUED)
			draw_i += 1; data_i += 1
		}

	case .Locations, .Workspace_Symbols:
		for data_i < len(p.locations) {
			li := p.locations[data_i]
			if p.mode == .Locations && !pal_match(li.label, q) { data_i += 1; continue }
			if data_i < p.scroll { data_i += 1; continue }
			if draw_i >= PALETTE_MAX_VIS { break }

			iy := item_y + f32(draw_i) * ITEM_H
			if data_i == p.selected {
				rl.DrawRectangleV({panel_x, iy}, {PANEL_W, ITEM_H}, SEL_BG_P)
				rl.DrawRectangleV({panel_x, iy}, {3, ITEM_H}, ACCENT)
			}

			bname   := path_basename(li.file)
			rel     := path_rel(li.file, p.cwd)
			loc_str := fmt.tprintf(":%d:%d", li.line, li.col)
			top_str := fmt.tprintf("%s  %s%s", li.label, bname, loc_str)
			dlg_text(font, top_str, panel_x + 16, iy + 5, FONT_SIZE - 2, CHAR_SPACING, MATCH_COL, txt_max, 0)

			bottom := li.detail if li.detail != "" else rel
			dlg_text(font, bottom, panel_x + 16, iy + 5 + ch - 2, FONT_SIZE - 2, CHAR_SPACING, SUBDUED, txt_max, 0)

			draw_i += 1; data_i += 1
		}

	case .Files:
		for f in p.files {
			if !pal_match(f, q) { continue }
			if data_i < p.scroll { data_i += 1; continue }
			if draw_i >= PALETTE_MAX_VIS { break }
			iy    := item_y + f32(draw_i) * ITEM_H
			bname := path_basename(f)
			rel   := path_rel(f, p.cwd)
			if data_i == p.selected {
				rl.DrawRectangleV({panel_x, iy}, {PANEL_W, ITEM_H}, SEL_BG_P)
				rl.DrawRectangleV({panel_x, iy}, {3, ITEM_H}, ACCENT)
			}
			dlg_text(font, bname, panel_x + 16, iy + 7,      FONT_SIZE,     CHAR_SPACING, TEXT,    txt_max, 0)
			dlg_text(font, rel,   panel_x + 16, iy + 7 + ch, FONT_SIZE - 2, CHAR_SPACING, SUBDUED, txt_max, 0)
			rl.DrawTextEx(font, to_cstring(">"), {panel_x + PANEL_W - 22, iy + 7}, FONT_SIZE, CHAR_SPACING, SUBDUED)
			draw_i += 1; data_i += 1
		}

	case .Search:
		sync.mutex_lock(&p.search.mu)
		for data_i < len(p.search.results) {
			if data_i < p.scroll { data_i += 1; continue }
			if draw_i >= PALETTE_MAX_VIS { break }

			r  := p.search.results[data_i]
			iy := item_y + f32(draw_i) * ITEM_H

			if data_i == p.selected {
				rl.DrawRectangleV({panel_x, iy}, {PANEL_W, ITEM_H}, SEL_BG_P)
				rl.DrawRectangleV({panel_x, iy}, {3, ITEM_H}, ACCENT)
			}

			// Top row: filename + line:col
			bname   := path_basename(r.file)
			rel     := path_rel(r.file, p.cwd)
			loc_str := fmt.tprintf(":%d:%d", r.line, r.col)
			top_str := fmt.tprintf("%s  %s%s", bname, rel, loc_str)
			dlg_text(font, top_str, panel_x + 16, iy + 5, FONT_SIZE - 2, CHAR_SPACING, MATCH_COL, txt_max, 0)

			// Bottom row: context
			dlg_text(font, r.ctx, panel_x + 16, iy + 5 + ch - 2, FONT_SIZE - 2, CHAR_SPACING, SUBDUED, txt_max, 0)

			draw_i += 1; data_i += 1
		}
		sync.mutex_unlock(&p.search.mu)

	case .Marks:
		if p.marks != nil {
			q := string(p.query[:])
			for m in p.marks^ {
				if !_mark_match(m, q) { continue }
				if data_i < p.scroll { data_i += 1; continue }
				if draw_i >= PALETTE_MAX_VIS { break }

				iy := item_y + f32(draw_i) * ITEM_H
				if data_i == p.selected {
					rl.DrawRectangleV({panel_x, iy}, {PANEL_W, ITEM_H}, SEL_BG_P)
					rl.DrawRectangleV({panel_x, iy}, {3, ITEM_H}, ACCENT)
				}

				bname   := path_basename(m.filename) if m.filename != "" else "untitled"
				loc_str := fmt.tprintf("%s:%d", bname, m.line)
				dlg_text(font, loc_str, panel_x + 16, iy + 7,      FONT_SIZE,     CHAR_SPACING, MATCH_COL, txt_max, 0)
				dlg_text(font, m.desc,  panel_x + 16, iy + 7 + ch, FONT_SIZE - 2, CHAR_SPACING, SUBDUED,   txt_max, 0)

				draw_i += 1; data_i += 1
			}
		}

	case .Themes:
		active_name := ""
		if at := conf.registry_active_theme(&e.registry); at != nil { active_name = at.name }
		q := string(p.query[:])
		for name in p.themes {
			if !pal_match(name, q) { continue }
			if data_i < p.scroll { data_i += 1; continue }
			if draw_i >= PALETTE_MAX_VIS { break }

			iy := item_y + f32(draw_i) * ITEM_H
			if data_i == p.selected {
				rl.DrawRectangleV({panel_x, iy}, {PANEL_W, ITEM_H}, SEL_BG_P)
				rl.DrawRectangleV({panel_x, iy}, {3, ITEM_H}, ACCENT)
			}

			// Color swatches — 6 squares from this theme's colors
			if th, ok := e.registry.theme.themes[name]; ok {
				swatch_colors := [6]conf.Color{
					th.ui.background, th.ui.foreground, th.ui.accent,
					th.syntax.keyword, th.syntax.string_, th.syntax.comment,
				}
				sw_x := panel_x + PANEL_W - f32(len(swatch_colors))*16 - 14
				for sc, si in swatch_colors {
					rl.DrawRectangleV(
						{sw_x + f32(si)*16, iy + (ITEM_H-12)*0.5},
						{13, 12},
						rl.Color{sc[0], sc[1], sc[2], 255},
					)
				}
			}

			is_active := name == active_name
			name_col  := TEXT if !is_active else ACCENT
			dlg_text(font, name, panel_x + 16, iy + (ITEM_H-ch)*0.5, FONT_SIZE, CHAR_SPACING, name_col, txt_max - 110, 0)
			if is_active {
				rl.DrawTextEx(font, "active", {panel_x + 16 + rl.MeasureTextEx(font, to_cstring(name), FONT_SIZE, CHAR_SPACING).x + 10, iy + (ITEM_H-ch)*0.5 + 2}, FONT_SIZE-3, CHAR_SPACING, ACCENT)
			}

			draw_i += 1; data_i += 1
		}

	case .Keymap_Modes:
		active := e.cfg.editor.keymap_mode
		for name in keymap_choices {
			if !pal_match(name, q) { continue }
			if data_i < p.scroll { data_i += 1; continue }
			if draw_i >= PALETTE_MAX_VIS { break }

			iy := item_y + f32(draw_i) * ITEM_H
			if data_i == p.selected {
				rl.DrawRectangleV({panel_x, iy}, {PANEL_W, ITEM_H}, SEL_BG_P)
				rl.DrawRectangleV({panel_x, iy}, {3, ITEM_H}, ACCENT)
			}

			is_active := _keymap_choice_mode(name) == active
			name_col  := TEXT if !is_active else ACCENT
			dlg_text(font, name, panel_x + 16, iy + (ITEM_H-ch)*0.5, FONT_SIZE, CHAR_SPACING, name_col, txt_max - 110, 0)
			if is_active {
				rl.DrawTextEx(font, "active", {panel_x + 16 + rl.MeasureTextEx(font, to_cstring(name), FONT_SIZE, CHAR_SPACING).x + 10, iy + (ITEM_H-ch)*0.5 + 2}, FONT_SIZE-3, CHAR_SPACING, ACCENT)
			}

			draw_i += 1; data_i += 1
		}
	}

	// Footer
	fy := panel_y + QUERY_H + f32(vis)*ITEM_H
	rl.DrawRectangleV({panel_x, fy}, {PANEL_W, FOOTER_H}, INPUT_BG)
	rl.DrawRectangleLinesEx({panel_x, fy, PANEL_W, FOOTER_H}, 1, PANEL_BOR)

	footer_text: string
	switch p.mode {
	case .Commands, .Files:
		footer_text = "up/down navigate    enter select    Esc close"
	case .Search:
		sync.mutex_lock(&p.search.mu)
		phase   := p.search.phase
		n_res   := len(p.search.results)
		n_files := p.search.n_files
		sync.mutex_unlock(&p.search.mu)

		switch phase {
		case .Idle:    footer_text = "Type query and press Enter to search"
		case .Running: footer_text = fmt.tprintf("Searching... %d files  |  %d results so far", n_files, n_res)
		case .Done:    footer_text = fmt.tprintf("%d results in %d files  |  Enter to jump  |  Esc to close", n_res, n_files)
		}
	case .Marks:
		n_m := 0
		if p.marks != nil { n_m = len(p.marks^) }
		footer_text = fmt.tprintf("%d marks  |  Enter jump  |  Del remove  |  Esc close", n_m)
	case .Themes:
		footer_text = fmt.tprintf("%d themes  |  Enter apply  |  Esc close", len(p.themes))
	case .Keymap_Modes:
		footer_text = "3 modes  |  Enter apply  |  Esc close"
	case .Locations:
		title := p.loc_title if p.loc_title != "" else "results"
		footer_text = fmt.tprintf("%s  |  Enter jump  |  Esc close", title)
	case .Workspace_Symbols:
		footer_text = fmt.tprintf("%d symbols  |  Enter jump  |  Esc close", len(p.locations))
	}
	rl.DrawTextEx(font, to_cstring(footer_text), {panel_x + 12, fy + 8}, FONT_SIZE - 2, CHAR_SPACING, SUBDUED)
	dlg_end()
}

// ---- Command implementations ----

cmd_open_workspace :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	workspace_dialog_open(&e.workspace_dlg)
}

_prefill_from_selection :: proc(p: ^Palette, e: ^Editor) {
	ap := active_pane(e)
	lo := min(ap.cursor, ap.sel_anchor)
	hi := max(ap.cursor, ap.sel_anchor)
	if hi <= lo { return }
	// single line only; stop at newline
	for i in lo..<hi {
		b := buffer_get_byte(&ap.buf, i)
		if b == '\n' { break }
		if b >= 32   { append(&p.query, b) }
	}
}

cmd_find_file :: proc(e: ^Editor, p: ^Palette) {
	p.mode     = .Files
	p.selected = 0
	p.scroll   = 0
	p.sel_all  = false
	clear(&p.query)
	_prefill_from_selection(p, e)
	palette_scan_files(p)
}

cmd_search_workspace :: proc(e: ^Editor, p: ^Palette) {
	p.mode         = .Search
	p.selected     = 0
	p.scroll       = 0
	p.search_timer = 0
	p.sel_all      = false
	clear(&p.query)
	_prefill_from_selection(p, e)
	q := string(p.query[:])
	if len(q) > 0 {
		search_start(&p.search, q) // start immediately with pre-filled text
	} else {
		search_start(&p.search, "") // cancels any running worker + safely resets results
	}
}

cmd_mark_line :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	mark_dialog_open(e)
}

cmd_list_marks :: proc(e: ^Editor, p: ^Palette) {
	p.mode     = .Marks
	p.selected = 0
	p.scroll   = 0
	clear(&p.query)
}

cmd_goto_line :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	goto_dialog_open(e)
}

cmd_new_directory :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	// Open file tree in Make_Dir mode so user can pick parent and type name
	file_tree_open(&e.file_tree)
	e.file_tree.mode = .Make_Dir
	clear(&e.file_tree.input_buf)
}

cmd_new_file :: proc(e: ^Editor, p: ^Palette) {
	ap := active_pane(e)
	buffer_destroy(&ap.buf)
	ap.buf        = buffer_init()
	ap.cursor     = 0
	ap.sel_anchor = 0
	ap.scroll     = 0
	if ap.filename != "" { delete(ap.filename); ap.filename = "" }
	ap.lang  = .None
	ap.dirty = false
	e.msg    = "New file"
	palette_close(p)
}

cmd_save_file :: proc(e: ^Editor, p: ^Palette) {
	editor_save(e)
	palette_close(p)
}

cmd_close_file :: proc(e: ^Editor, p: ^Palette) {
	ap := active_pane(e)
	buffer_destroy(&ap.buf)
	ap.buf        = buffer_init()
	ap.cursor     = 0
	ap.sel_anchor = 0
	ap.scroll     = 0
	if ap.filename != "" { delete(ap.filename); ap.filename = "" }
	ap.lang  = .None
	ap.dirty = false
	palette_close(p)
}

cmd_outline :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	outline_open(&e.outline, active_pane(e))
}

cmd_rename_file :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	rename_file_open(e)
}

cmd_delete_file :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	delete_file_open(e)
}

cmd_split_vertical :: proc(e: ^Editor, p: ^Palette) {
	editor_split(e, .Vertical)
	palette_close(p)
}

cmd_split_horizontal :: proc(e: ^Editor, p: ^Palette) {
	editor_split(e, .Horizontal)
	palette_close(p)
}

cmd_close_split :: proc(e: ^Editor, p: ^Palette) {
	editor_close_split(e)
	palette_close(p)
}

cmd_exit :: proc(e: ^Editor, p: ^Palette) {
	e.should_quit = true
	palette_close(p)
}

cmd_lsp_control :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	lsp_dialog_open(&e.lsp_dialog)
}

cmd_switch_theme :: proc(e: ^Editor, p: ^Palette) {
	palette_open_themes(p, &e.registry)
}

cmd_set_keymap_mode :: proc(e: ^Editor, p: ^Palette) {
	palette_open_keymap_modes(p, e)
}

cmd_toggle_line_numbers :: proc(e: ^Editor, p: ^Palette) {
	e.panes[e.active].show_line_numbers = !e.panes[e.active].show_line_numbers
	palette_close(p)
}

// ---- Helpers ----

pal_match :: proc(s, sub: string) -> bool {
	if len(sub) == 0 { return true }
	if len(sub) > len(s) { return false }
	outer: for i in 0..=len(s) - len(sub) {
		for j in 0..<len(sub) {
			sc := s[i+j]; qc := sub[j]
			if sc >= 'A' && sc <= 'Z' { sc |= 32 }
			if qc >= 'A' && qc <= 'Z' { qc |= 32 }
			if sc != qc { continue outer }
		}
		return true
	}
	return false
}

_mark_match :: proc(m: Mark, q: string) -> bool {
	if len(q) == 0 { return true }
	if pal_match(m.desc, q) { return true }
	bname := path_basename(m.filename)
	return pal_match(bname, q)
}

path_basename :: proc(path: string) -> string {
	i := len(path) - 1
	for i >= 0 && path[i] != '/' && path[i] != '\\' { i -= 1 }
	return path[i + 1:]
}

path_rel :: proc(path, base: string) -> string {
	if len(base) == 0 { return path }
	if strings.has_prefix(path, base) {
		r := path[len(base):]
		if len(r) > 0 && (r[0] == '/' || r[0] == '\\') { return r[1:] }
		return r
	}
	return path
}
