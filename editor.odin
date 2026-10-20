package editor

import "core:fmt"
import "core:os"
import "core:strings"
import lsp  "./lsp"
import conf "./config"
import git  "./git"
import dbg  "./debug"

Split_Dir :: enum { None, Vertical, Horizontal }

DIVIDER_W :: f32(1)

Save_Dialog :: struct {
	open:    bool,
	rename:  bool,
	new_file: bool, // New File prompt: create the path, then open it
	input:   [dynamic]u8,
	sel_all: bool,
}

Mark :: struct {
	filename: string, // heap
	line:     int,    // 1-based
	desc:     string, // heap
}

Mark_Dialog :: struct {
	open:    bool,
	input:   [dynamic]u8,
	sel_all: bool,
}

Goto_Dialog :: struct {
	open:    bool,
	input:   [dynamic]u8,
	sel_all: bool,
}

Find_Replace :: struct {
	open:           bool,
	search_buf:     [dynamic]u8,
	replace_buf:    [dynamic]u8,
	focus:          int,            // 0=search  1=replace
	matches:        [dynamic]int,   // sorted buffer start positions
	match_lens:     [dynamic]int,   // parallel; per-match lengths (regex can vary)
	current:        int,
	needs_scan:     bool,
	all_sel:        bool,           // Ctrl+A: next char replaces entire focused input
	case_sensitive: bool,           // Aa toggle
	whole_word:     bool,           // ab toggle
	use_regex:      bool,           // .* toggle
	show_results:   bool,           // ≡ toggle
	results_scroll: int,
	regex_err:      bool,
}

Editor :: struct {
	panes:           [dynamic]Pane,
	active:          int,
	split:           Split_Dir, // legacy single split (old sessions); layout is the truth
	split_ratio:     f32,
	layout:          Pane_Layout, // pane_layout.odin
	msg:             string,
	palette:         Palette,
	save_dlg:        Save_Dialog,
	file_tree:       File_Tree,
	marks:           [dynamic]Mark,
	mark_dlg:        Mark_Dialog,
	goto_dlg:        Goto_Dialog,
	find_rep:        Find_Replace,
	outline:         Outline_Dialog,
	recents:         Recents_Dialog,
	workspace_dlg:   Workspace_Dialog,
	lsp_dialog:      LSP_Dialog,
	// Git of the ACTIVE repository (ADR 0014): points into repos.list[active]
	// (or repos.none — root "" — when no repo is open). Never nil after
	// editor_init/repos_init. Screens keep using e.git_mgr.root/.queue/.current.
	git_mgr:         ^git.Git_Manager,
	repos:           Repo_Set,     // open repositories (tabs), see repos.odin
	recent_repos:    Recent_Repos, // recently opened repository folders
	git_dialog:      Git_Dialog,
	nav_hist:        Nav_History,
	def_picker:      Goto_Def_Picker,
	rename_dlg:      Rename_Dialog,
	code_action_dlg: Code_Action_Dialog,
	delete_confirm:  bool,
	should_quit:     bool,
	lsp_mgr:         lsp.LSP_Manager,
	cfg:             conf.Config,
	registry:        conf.Registry,
	debug_mgr:       dbg.Debug_Manager,
	debug_panel:     Debug_Panel,
	debug_eval:      Debug_Eval_Dialog,
	debug_attach:    Debug_Attach_Dialog,
	blame_enabled:   bool, // Git Blame gutter toggle (palette command)
	vim:             Vim_State,   // runtime-only; live only while cfg.editor.keymap_mode == .Vim
	emacs:           Emacs_State, // runtime-only; live only while cfg.editor.keymap_mode == .Emacs
}

editor_init :: proc() -> Editor {
	e: Editor
	e.panes           = make([dynamic]Pane)
	e.split_ratio     = 0.5
	e.layout          = layout_single()
	e.marks           = make([dynamic]Mark)
	e.palette         = palette_init()
	e.save_dlg.input  = make([dynamic]u8)
	e.mark_dlg.input    = make([dynamic]u8)
	e.goto_dlg.input    = make([dynamic]u8)
	e.find_rep.search_buf  = make([dynamic]u8)
	e.find_rep.replace_buf = make([dynamic]u8)
	e.find_rep.matches     = make([dynamic]int)
	e.find_rep.match_lens  = make([dynamic]int)
	e.file_tree       = file_tree_init()
	e.outline         = outline_init()
	e.recents         = recents_init()
	repos_init(&e)
	workspace_dialog_init(&e.workspace_dlg)
	git_dialog_init(&e.git_dialog)
	e.nav_hist       = nav_history_init()
	e.def_picker     = goto_def_picker_init()
	e.rename_dlg     = rename_dialog_init()
	e.code_action_dlg = code_action_dialog_init()
	append(&e.panes, pane_init())
	e.cfg      = conf.load_config(conf.default_config_paths())
	e.registry = conf.registry_build(&e.cfg, "languages", "themes")
	dbg.manager_init(&e.debug_mgr)
	debug_panel_init(&e.debug_panel)
	debug_eval_init(&e.debug_eval)
	debug_attach_init(&e.debug_attach)
	e.vim   = vim_init()
	e.emacs = emacs_init()
	return e
}

// Called after editor_init + arg parsing so root path is known.
editor_lsp_init :: proc(e: ^Editor) {
	lsp_init(e)
}

editor_lsp_destroy :: proc(e: ^Editor) {
	lsp_destroy(e)
}

editor_destroy :: proc(e: ^Editor) {
	for &p in e.panes { pane_destroy(&p) }
	delete(e.panes)
	palette_destroy(&e.palette)
	file_tree_destroy(&e.file_tree)
	for &m in e.marks { delete(m.filename); delete(m.desc) }
	delete(e.marks)
	delete(e.save_dlg.input)
	delete(e.mark_dlg.input)
	delete(e.goto_dlg.input)
	delete(e.find_rep.search_buf)
	delete(e.find_rep.replace_buf)
	delete(e.find_rep.matches)
	delete(e.find_rep.match_lens)
	outline_destroy(&e.outline)
	recents_destroy(&e.recents)
	workspace_dialog_destroy(&e.workspace_dlg)
	lsp_dialog_destroy(&e.lsp_dialog)
	git_dialog_destroy(&e.git_dialog)
	repos_destroy(e) // every repo's git manager (incl. the active one) + stashed views
	recent_repos_destroy(&e.recent_repos)
	nav_history_destroy(&e.nav_hist)
	goto_def_picker_destroy(&e.def_picker)
	rename_dialog_destroy(&e.rename_dlg)
	code_action_dialog_destroy(&e.code_action_dlg)
	editor_lsp_destroy(e)
	dbg.manager_destroy(&e.debug_mgr)
	debug_panel_destroy(&e.debug_panel)
	debug_eval_destroy(&e.debug_eval)
	debug_attach_destroy(&e.debug_attach)
	vim_destroy(&e.vim)
	emacs_destroy(&e.emacs)
	conf.registry_destroy(&e.registry)
	conf.config_destroy(&e.cfg)
	e^ = {}
}

active_pane :: proc(e: ^Editor) -> ^Pane {
	return &e.panes[e.active]
}

editor_open :: proc(e: ^Editor, path: string) -> bool {
	fi, fi_err := os.stat(path, context.temp_allocator)
	if fi_err == nil {
		limit_bytes := i64(e.cfg.performance.max_file_size_kb) * 1024
		if fi.size > limit_bytes {
			e.msg = fmt.tprintf("File too large (%d MB) — limit %d MB. Raise max_file_size_kb in editor.toml.",
				fi.size / (1024*1024), limit_bytes / (1024*1024))
			return false
		}
	}
	p := active_pane(e)
	// A file shown without a tab entry (opened outside editor_open) becomes a
	// tab first, so the new file opens beside it instead of replacing it.
	if len(p.tabs) == 0 && p.filename != "" {
		append(&p.tabs, Pane_Tab{filename = strings.clone(p.filename), cursor = p.cursor, scroll = p.scroll})
		p.cur_tab = 0
	}
	if len(p.tabs) == 0 {
		// First file ever: open normally and register as tab 0
		if !pane_open(p, path) { return false }
		if len(p.tabs) == 0 {
			append(&p.tabs, Pane_Tab{filename = strings.clone(p.filename)})
			p.cur_tab = 0
		}
	} else {
		if !pane_open_tab(p, path) { return false }
	}
	recents_push(&e.recents, path)
	lsp_on_open(e, active_pane(e))
	return true
}

editor_save :: proc(e: ^Editor) -> bool {
	p := active_pane(e)
	if p.filename == "" {
		save_dialog_open(e)
		return false
	}
	return editor_save_pane(e, p)
}

// :wa / "Save All": every pane and every tab with unsaved changes. Buffers
// without a file name are skipped (they need Save As).
editor_save_all :: proc(e: ^Editor) {
	saved, failed, unnamed := 0, 0, 0
	for &p in e.panes {
		s, f := pane_save_kept_tabs(&p)
		saved += s; failed += f
		if !p.dirty || p.image.active { continue }
		if p.filename == "" { unnamed += 1; continue }
		if editor_save_pane(e, &p) { saved += 1 } else { failed += 1 }
	}
	switch {
	case failed > 0:  e.msg = fmt.tprintf("Saved %d, %d failed", saved, failed)
	case unnamed > 0: e.msg = fmt.tprintf("Saved %d, %d without a name (use Save As)", saved, unnamed)
	case saved == 0:  e.msg = "Nothing to save"
	case:             e.msg = fmt.tprintf("Saved %d file%s", saved, "" if saved == 1 else "s")
	}
}

// Unsaved changes left in any pane or kept tab?
editor_any_dirty :: proc(e: ^Editor) -> bool {
	for &p in e.panes {
		if p.dirty && !p.image.active { return true }
		for t, i in p.tabs { if i != p.cur_tab && t.kept && t.dirty { return true } }
	}
	return false
}

editor_save_pane :: proc(e: ^Editor, p: ^Pane) -> bool {
	ok, msg := pane_save(p)
	e.msg = msg
	if ok {
		git.git_blame_invalidate(e.git_mgr, p.filename)
		git.git_manager_refresh_now(e.git_mgr) // gutter marks / badges follow the save
		lsp_on_save(e, p)
		lsp_format_on_save(e, p) // saves again when the reply arrives
	}
	return ok
}

MAX_PANES :: 8

// Splits the active pane (Emacs-style: splits nest). The new, empty pane
// takes the right/bottom half and becomes active.
editor_split :: proc(e: ^Editor, dir: Split_Dir) {
	if len(e.panes) >= MAX_PANES { e.msg = fmt.tprintf("Max %d panes", MAX_PANES); return }
	editor_layout_fix(e)
	np := pane_init()
	np.word_wrap = e.panes[e.active].word_wrap
	append(&e.panes, np)
	if !layout_split(&e.layout, e.active, len(e.panes) - 1, dir) {
		pane_destroy(&e.panes[len(e.panes) - 1])
		pop(&e.panes)
		return
	}
	e.active = len(e.panes) - 1
}

// Closes the active pane; its space goes to its neighbor.
editor_close_split :: proc(e: ^Editor) {
	if len(e.panes) <= 1 { e.msg = "Single pane"; return }
	editor_layout_fix(e)
	closed := e.active
	pane_destroy(&e.panes[closed])
	ordered_remove(&e.panes, closed)
	layout_remove(&e.layout, closed)
	if e.active >= len(e.panes) { e.active = len(e.panes) - 1 }
}

// Keeps only the active pane (Emacs C-x 1).
editor_close_other_panes :: proc(e: ^Editor) {
	if len(e.panes) <= 1 { e.msg = "Single pane"; return }
	keep := e.panes[e.active]
	for &p, i in e.panes { if i != e.active { pane_destroy(&p) } }
	clear(&e.panes)
	append(&e.panes, keep)
	e.active = 0
	e.layout = layout_single()
}

// Repairs a layout that doesn't match the pane list (old sessions, views
// restored with a different number of panes).
editor_layout_fix :: proc(e: ^Editor) {
	if !layout_valid(&e.layout, len(e.panes)) {
		e.layout = layout_from_legacy(len(e.panes), e.split, e.split_ratio)
	}
	e.active = clamp(e.active, 0, max(0, len(e.panes) - 1))
}

// ---- Save As dialog ----

save_dialog_open :: proc(e: ^Editor) {
	e.save_dlg.open    = true
	e.save_dlg.rename  = false
	e.save_dlg.sel_all = false
	clear(&e.save_dlg.input)
	s := "untitled.txt"
	for i in 0 ..< len(s) { append(&e.save_dlg.input, s[i]) }
}

// Ctrl/Cmd+N: asks for the new file's path (prefilled with the current
// file's folder) and creates it on Enter.
new_file_dialog_open :: proc(e: ^Editor) {
	e.save_dlg.open     = true
	e.save_dlg.rename   = false
	e.save_dlg.new_file = true
	e.save_dlg.sel_all  = false
	clear(&e.save_dlg.input)
	cwd, _ := os.get_working_directory(context.temp_allocator)
	s := new_file_prefill(active_pane(e).filename, cwd)
	for i in 0 ..< len(s) { append(&e.save_dlg.input, s[i]) }
}

save_dialog_close :: proc(e: ^Editor) {
	e.save_dlg.open    = false
	e.save_dlg.rename  = false
	e.save_dlg.new_file = false
	e.save_dlg.sel_all = false
	clear(&e.save_dlg.input)
}

save_dialog_confirm :: proc(e: ^Editor) {
	name := string(e.save_dlg.input[:])
	if len(name) == 0 { save_dialog_close(e); return }
	ws_index_invalidate() // new / renamed file
	p := active_pane(e)
	if e.save_dlg.new_file {
		path := strings.trim_space(name)
		r := create_new_path(path)
		switch r {
		case .Created_Dir:  e.msg = fmt.tprintf("Folder %s created", strings.trim_right(path, "/\\"))
		case .Invalid:      e.msg = "Not a valid new file name"
		case .Failed:       e.msg = fmt.tprintf("Could not create %s", path)
		case .Created_File, .Exists:
			save_dialog_close(e)
			if editor_open(e, path) {
				e.msg = fmt.tprintf("%s already exists — opened", path) if r == .Exists else fmt.tprintf("Created %s", path)
			}
			return
		}
		save_dialog_close(e)
		return
	}
	if e.save_dlg.rename {
		old := p.filename
		err := os.rename(old, name)
		if err != nil { e.msg = "Rename failed"; save_dialog_close(e); return }
		recents_remove(&e.recents, old)
		delete(p.filename)
		p.filename = _pane_abs(name)
		p.lang     = detect_lang(name)
		recents_push(&e.recents, p.filename)
		e.msg = fmt.tprintf("Renamed to %s", path_basename(name))
	} else {
		if p.filename != "" { delete(p.filename) }
		p.filename = _pane_abs(name)
		p.lang     = detect_lang(name)
		ok, msg   := pane_save(p)
		e.msg      = msg
		if ok { recents_push(&e.recents, name) }
	}
	save_dialog_close(e)
}

rename_file_open :: proc(e: ^Editor) {
	p := active_pane(e)
	if p.filename == "" { e.msg = "No filename - Save As first"; return }
	clear(&e.save_dlg.input)
	for i in 0..<len(p.filename) { append(&e.save_dlg.input, p.filename[i]) }
	e.save_dlg.rename  = true
	e.save_dlg.open    = true
	e.save_dlg.sel_all = false
}

delete_file_open :: proc(e: ^Editor) {
	p := active_pane(e)
	if p.filename == "" { e.msg = "No file to delete"; return }
	e.delete_confirm = true
}

delete_file_confirm :: proc(e: ^Editor) {
	p := active_pane(e)
	if p.filename == "" { e.delete_confirm = false; return }
	err := os.remove(p.filename)
	if err != nil {
		e.msg = "Delete failed"
		e.delete_confirm = false
		return
	}
	e.msg = fmt.tprintf("Deleted %s", path_basename(p.filename))
	recents_remove(&e.recents, p.filename)
	delete(p.filename)
	p.filename = ""
	buffer_destroy(&p.buf)
	p.buf         = buffer_init()
	p.cursor      = 0
	p.sel_anchor  = 0
	p.scroll      = 0
	p.scroll_anim = 0
	for &op in p.undo { delete(op.data) }
	clear(&p.undo)
	for &op in p.redo { delete(op.data) }
	clear(&p.redo)
	p.u_merge = 0
	p.dirty   = false
	mc_clear(p)
	e.delete_confirm = false
}

// ---- Mark dialog ----

mark_dialog_open :: proc(e: ^Editor) {
	ap := active_pane(e)
	line, _ := buffer_pos_to_line_col(&ap.buf, ap.cursor)
	ls := buffer_line_start(&ap.buf, line)
	ll := buffer_line_length(&ap.buf, line)

	clear(&e.mark_dlg.input)
	// Pre-fill with current line content (strip leading whitespace)
	start := ls
	for start < ls + ll {
		b := buffer_get_byte(&ap.buf, start)
		if b != ' ' && b != '\t' { break }
		start += 1
	}
	for i in start ..< ls + ll { append(&e.mark_dlg.input, buffer_get_byte(&ap.buf, i)) }
	e.mark_dlg.open    = true
	e.mark_dlg.sel_all = false
}

mark_dialog_close :: proc(e: ^Editor) {
	e.mark_dlg.open    = false
	e.mark_dlg.sel_all = false
	clear(&e.mark_dlg.input)
}

mark_dialog_confirm :: proc(e: ^Editor) {
	desc := strings.clone(string(e.mark_dlg.input[:]))
	ap   := active_pane(e)
	line, _ := buffer_pos_to_line_col(&ap.buf, ap.cursor)
	m := Mark{
		filename = strings.clone(ap.filename),
		line     = line + 1,
		desc     = desc,
	}
	append(&e.marks, m)
	e.msg = fmt.tprintf("Marked line %d", m.line)
	mark_dialog_close(e)
}

// ---- Goto Line dialog ----

goto_dialog_open :: proc(e: ^Editor) {
	clear(&e.goto_dlg.input)
	e.goto_dlg.open    = true
	e.goto_dlg.sel_all = false
}

goto_dialog_close :: proc(e: ^Editor) {
	e.goto_dlg.open    = false
	e.goto_dlg.sel_all = false
	clear(&e.goto_dlg.input)
}

goto_dialog_confirm :: proc(e: ^Editor) {
	n := 0
	for b in e.goto_dlg.input { if b >= '0' && b <= '9' { n = n*10 + int(b - '0') } }
	if n < 1 { goto_dialog_close(e); return }

	ap    := active_pane(e)
	total := buffer_line_count(&ap.buf)
	target := min(n - 1, total - 1)
	ls := buffer_line_start(&ap.buf, target)
	ap.cursor     = ls
	ap.sel_anchor = ls
	ap.scroll     = max(0, target - 10)
	ap.scroll_anim = f32(ap.scroll)
	e.msg = fmt.tprintf("Line %d", target + 1)
	goto_dialog_close(e)
}

// ---- Pane rect ----

// The repo tab strip (repos.odin) takes the top REPO_BAR_H when a repo is open.
get_pane_rect :: proc(e: ^Editor, idx: int, sw, sh: f32) -> (x, y, w, h: f32) {
	top := repos_bar_h(e)
	x, y, w, h = _get_pane_rect(e, idx, sw, sh - top)
	return x, y + top, w, h
}

@(private="file")
_get_pane_rect :: proc(e: ^Editor, idx: int, sw, sh: f32) -> (x, y, w, h: f32) {
	n := len(e.panes)
	if n <= 1 { return 0, 0, sw, sh }
	editor_layout_fix(e)
	if rx, ry, rw, rh, ok := layout_rect(&e.layout, idx, 0, 0, sw, sh, DIVIDER_W); ok { return rx, ry, rw, rh }
	return 0, 0, sw, sh
}
