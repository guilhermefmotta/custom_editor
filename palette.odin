package editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import rl "vendor:raylib"

// ---- Command pattern ----

Command :: struct {
	name:    string,
	desc:    string,
	execute: proc(e: ^Editor, p: ^Palette),
}

// ---- Palette state ----

Palette_Mode :: enum { Commands, Files, Search, Marks }

Palette :: struct {
	open:         bool,
	mode:         Palette_Mode,
	query:        [dynamic]u8,
	sel_all:      bool,
	selected:     int,
	scroll:       int,
	cmds:         [dynamic]Command,
	files:        [dynamic]string,
	cwd:          string,
	search:       Search_State,
	search_timer: f32,
	marks:        ^[dynamic]Mark, // pointer into Editor.marks
}

// ---- Lifecycle ----

palette_init :: proc() -> Palette {
	p: Palette
	p.query  = make([dynamic]u8)
	p.files  = make([dynamic]string)
	p.cmds   = make([dynamic]Command)
	p.search = search_state_init()

	append(&p.cmds,
		Command{"Open Workspace",            "Open a folder and set it as the workspace root",    cmd_open_workspace},
		Command{"Find File in Workspace",   "Open any file in current directory by name",        cmd_find_file},
		Command{"Search in Workspace",      "Search text across all files (case-insensitive)",   cmd_search_workspace},
		Command{"Mark Line",                "Bookmark the current line with a description",       cmd_mark_line},
		Command{"List Marks",               "Browse and jump to all bookmarked lines",            cmd_list_marks},
		Command{"Outline",                  "Browse symbols in current file",                    cmd_outline},
		Command{"Go to Line",               "Jump to a specific line number",                    cmd_goto_line},
		Command{"New File",                 "Create an empty buffer",                            cmd_new_file},
		Command{"New Directory",            "Create a new directory in the workspace",           cmd_new_directory},
		Command{"Save File",                "Save current file to disk",                        cmd_save_file},
		Command{"Close File",               "Close current file and clear buffer",              cmd_close_file},
		Command{"Rename File",              "Rename the current file on disk",                  cmd_rename_file},
		Command{"Delete File",              "Delete the current file from disk",                cmd_delete_file},
		Command{"Split Vertical",           "Split editor into two side-by-side panes",         cmd_split_vertical},
		Command{"Split Horizontal",         "Split editor into two stacked panes",              cmd_split_horizontal},
		Command{"Close Split",              "Close active pane, return to single pane",         cmd_close_split},
		Command{"Exit",                     "Quit the editor",                                  cmd_exit},
		Command{"LSP Control",              "Open LSP server control panel",                    cmd_lsp_control},
		Command{"Git",                      "Open Git panel (stage, commit, diff)",             cmd_git_panel},
	)

	cwd, err := os.get_working_directory(context.allocator)
	if err == nil { p.cwd = cwd }
	return p
}

palette_destroy :: proc(p: ^Palette) {
	search_state_destroy(&p.search)
	delete(p.query)
	delete(p.cmds)
	for f in p.files { delete(f) }
	delete(p.files)
	if p.cwd != "" { delete(p.cwd) }
	p^ = {}
}

palette_open :: proc(p: ^Palette) {
	p.open     = true
	p.mode     = .Commands
	p.selected = 0
	p.scroll   = 0
	clear(&p.query)
}

palette_close :: proc(p: ^Palette) {
	p.open = false
}

// ---- Input ----

PALETTE_MAX_VIS :: 8

palette_handle_input :: proc(p: ^Palette, e: ^Editor) {
	// Advance search debounce timer
	if p.mode == .Search && p.search_timer > 0 {
		p.search_timer -= rl.GetFrameTime()
		if p.search_timer <= 0 {
			p.search_timer = 0
			search_start(&p.search, string(p.query[:]))
		}
	}

	if rl.IsKeyPressed(.ESCAPE) { p.sel_all = false; palette_close(p); return }

	if rl.IsKeyPressed(.BACKSPACE) {
		if p.sel_all {
			clear(&p.query)
			p.sel_all = false
			palette_reset_selection(p)
			if p.mode == .Search { p.search_timer = 0.35 }
		} else if len(p.query) > 0 {
			pop(&p.query)
			palette_reset_selection(p)
			if p.mode == .Search { p.search_timer = 0.35 }
		}
		return
	}

	// Ctrl+A: select all in query
	if ctrl() && rl.IsKeyPressed(.A) { p.sel_all = true; return }

	// Ctrl+C: copy query to clipboard
	if ctrl() && rl.IsKeyPressed(.C) {
		if len(p.query) > 0 { rl.SetClipboardText(to_cstring(string(p.query[:]))) }
		return
	}

	// Ctrl+V: paste from clipboard (replaces if sel_all)
	if ctrl() && rl.IsKeyPressed(.V) {
		raw := rl.GetClipboardText()
		if raw != nil {
			if p.sel_all { clear(&p.query); p.sel_all = false }
			for b in string(raw) {
				if b >= 32 && b < 128 { append(&p.query, u8(b)) }
			}
			palette_reset_selection(p)
			if p.mode == .Search { p.search_timer = 0.35 }
		}
		return
	}

	if rl.IsKeyPressed(.UP) {
		p.sel_all = false
		if p.selected > 0 {
			p.selected -= 1
			if p.selected < p.scroll { p.scroll = p.selected }
		}
		return
	}

	if rl.IsKeyPressed(.DOWN) {
		p.sel_all = false
		n := palette_count(p, string(p.query[:]))
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
					n := palette_count(p, q)
					if p.selected >= n && p.selected > 0 { p.selected -= 1 }
					break
				}
				vis += 1
			}
		}
		return
	}

	// Text input
	for {
		ch := rl.GetCharPressed()
		if ch == 0 do break
		if ch >= 32 && ch < 128 {
			if p.sel_all { clear(&p.query); p.sel_all = false }
			append(&p.query, u8(ch))
			palette_reset_selection(p)
			if p.mode == .Search { p.search_timer = 0.35 }
		}
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
			if vis == p.selected { cmd.execute(e, p); return }
			vis += 1
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
	}
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

palette_count :: proc(p: ^Palette, q: string) -> int {
	switch p.mode {
	case .Commands:
		n := 0
		for cmd in p.cmds { if pal_match(cmd.name, q) { n += 1 } }
		return n
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
	}
	return 0
}

// ---- Rendering ----

palette_render :: proc(p: ^Palette, font: rl.Font) {
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

	OVERLAY   :: rl.Color{0,   0,   0,   160}
	PANEL_BG  :: rl.Color{36,  36,  54,  255}
	PANEL_BOR :: rl.Color{58,  60,  78,  255}
	INPUT_BG  :: rl.Color{24,  24,  37,  255}
	SEL_BG_P  :: rl.Color{69,  71,  90,  255}
	ACCENT    :: rl.Color{137, 180, 250, 255}
	SUBDUED   :: rl.Color{108, 112, 134, 255}
	SHADOW    :: rl.Color{0,   0,   0,   80}
	MATCH_COL :: rl.Color{166, 227, 161, 255}

	q       := string(p.query[:])
	n_items := palette_count(p, q)
	vis     := min(n_items, PALETTE_MAX_VIS)
	panel_h := QUERY_H + f32(vis)*ITEM_H + FOOTER_H

	panel_x := (sw - PANEL_W) * 0.5
	panel_y := sh * 0.13

	if n_items > 0 && p.selected >= n_items { p.selected = n_items - 1 }

	rl.DrawRectangle(0, 0, i32(sw), i32(sh), OVERLAY)
	dlg_begin(panel_x, panel_y, PANEL_W, panel_h, PANEL_BG, PANEL_BOR)

	// Search box
	rl.DrawRectangleV({panel_x, panel_y}, {PANEL_W, QUERY_H}, INPUT_BG)
	rl.DrawLineV({panel_x, panel_y + QUERY_H - 1}, {panel_x + PANEL_W, panel_y + QUERY_H - 1}, PANEL_BOR)

	icon := ">" if p.mode == .Search else "?"
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
			.Commands = "Type a command...",
			.Files    = "Type filename...",
			.Search   = "Type to search... (Enter to run)",
			.Marks    = "Filter marks...",
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
