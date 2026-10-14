package editor

import "core:fmt"
import "core:os"
import "core:strings"
import git "./git"
import rl "vendor:raylib"

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

Git_Dialog_Mode  :: enum { Status, Diff, Merge }
Git_Dialog_Focus :: enum { Files, Commit }

Conflict_Resolution :: enum { Unresolved, Ours, Theirs, Both }

Conflict_Block :: struct {
	ours_label:   string,   // heap
	theirs_label: string,   // heap
	ours_lines:   []string, // heap (slice of heap strings)
	theirs_lines: []string, // heap
	start_byte:   int,
	end_byte:     int,
	resolution:   Conflict_Resolution,
}

Merge_State :: struct {
	blocks:    [dynamic]Conflict_Block,
	selected:  int,
	ours_scroll:   int,
	theirs_scroll: int,
	file_path: string, // heap (abs)
	content:   []u8,   // heap — original file bytes
}

Git_Dialog :: struct {
	visible:    bool,
	mode:       Git_Dialog_Mode,
	focus:      Git_Dialog_Focus,
	selected:   int,
	scroll:     int,
	diff_scroll: int,
	diff:        git.File_Diff, // whole-file side-by-side diff (Diff mode)
	diff_path:   string,        // heap, repo-relative path shown in Diff mode
	diff_change: int,           // index into diff.changed of the focused change
	commit_buf: [dynamic]u8,
	commit_sel_all: bool,
	msg:        string, // heap
	msg_ok:     bool,
	merge:      Merge_State,
	// Branch picker overlay
	bp_open:     bool,
	bp_branches: [dynamic]string, // heap
	bp_selected: int,
	bp_scroll:   int,
	bp_filter:   [dynamic]u8,
	bp_filter_sel_all: bool,
}

// Layout
GITD_BP_W   :: f32(460) // branch picker width
GITD_BP_MAX :: 14       // max visible branches
GITD_W         :: f32(720)
GITD_HEADER_H  :: f32(34)
GITD_ENTRY_H   :: f32(20)
GITD_SECTION_H :: f32(18)
GITD_COMMIT_H  :: f32(26)
GITD_FOOTER_H  :: f32(26)
GITD_LIST_MAX  :: 16
GITD_DIFF_LEAD :: 3  // rows of context kept above a change when jumping to it
GITD_DIFF_GUTTER_CH :: 5 // line-number gutter width, in characters

// Rows visible in the last drawn diff (for PageUp/PageDown)
_gitd_diff_page_rows := 20

GITD_DIFF_ADD_BG   := rl.Color{40, 70, 50, 255}
GITD_DIFF_DEL_BG   := rl.Color{80, 40, 48, 255}
GITD_DIFF_EMPTY_BG := rl.Color{30, 30, 44, 255}
GITD_DIFF_MARK_ADD := rl.Color{166, 227, 161, 255}
GITD_DIFF_MARK_DEL := rl.Color{243, 139, 168, 255}

GITD_MERGE_W   :: f32(840) // wider for merge view
GITD_HALF_W    :: (GITD_MERGE_W - 4) / 2
GITD_ROW_MAX   :: 10 // max lines shown per side in merge view

// Colors
GITD_BG       := rl.Color{24,  24,  37,  255}
GITD_BORDER   := rl.Color{58,  60,  78,  255}
GITD_SEL      := rl.Color{45,  50,  70,  255}
GITD_HEADER   := rl.Color{30,  30,  46,  255}
GITD_SECTION  := rl.Color{49,  50,  68,  255}
GITD_GREEN    := rl.Color{166, 227, 161, 255}
GITD_GREEN_BG := rl.Color{30,  50,  35,  255}
GITD_RED      := rl.Color{243, 139, 168, 255}
GITD_RED_BG   := rl.Color{50,  30,  35,  255}
GITD_BLUE     := rl.Color{137, 180, 250, 255}
GITD_ORANGE      :: rl.Color{250, 179, 135, 255}
GITD_YELLOW      :: rl.Color{249, 226, 175, 255}
GITD_SUBDUED     :: rl.Color{108, 112, 134, 255}
GITD_TEXT        :: rl.Color{205, 214, 244, 255}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

git_dialog_init :: proc(d: ^Git_Dialog) {
	d.commit_buf = make([dynamic]u8)
	d.merge.blocks = make([dynamic]Conflict_Block)
	d.bp_branches = make([dynamic]string)
	d.bp_filter   = make([dynamic]u8)
}

git_dialog_destroy :: proc(d: ^Git_Dialog) {
	delete(d.commit_buf)
	if d.msg != "" { delete(d.msg) }
	_merge_destroy(&d.merge)
	_gitd_diff_free(d)
	_bp_free_branches(d)
	delete(d.bp_branches)
	delete(d.bp_filter)
	d^ = {}
}

git_dialog_open :: proc(d: ^Git_Dialog) {
	d.visible     = true
	d.mode        = .Status
	d.focus       = .Files
	d.selected    = 0
	d.scroll      = 0
	d.diff_scroll   = 0
	d.commit_sel_all = false
	_rep_key = .KEY_NULL
}

git_dialog_close :: proc(d: ^Git_Dialog) {
	d.visible = false
	_merge_destroy(&d.merge)
	_gitd_diff_free(d)
}

_gitd_diff_free :: proc(d: ^Git_Dialog) {
	git.file_diff_destroy(&d.diff)
	if d.diff_path != "" { delete(d.diff_path); d.diff_path = "" }
}

// Opens the whole-file diff of rel_path, scrolled to its first change.
_gitd_open_diff :: proc(d: ^Git_Dialog, m: ^git.Git_Manager, rel_path: string) {
	_gitd_diff_free(d)
	d.diff        = git.git_diff_file_full(m, rel_path)
	d.diff_path   = strings.clone(rel_path)
	d.diff_change = 0
	d.diff_scroll = 0
	if len(d.diff.changed) > 0 { d.diff_scroll = max(0, d.diff.changed[0] - GITD_DIFF_LEAD) }
	d.mode = .Diff
}

// Scrolls so change i sits a few rows below the top
_gitd_diff_goto :: proc(d: ^Git_Dialog, i: int) {
	n := len(d.diff.changed)
	if n == 0 { return }
	d.diff_change = (i % n + n) % n // wrap around both ways
	d.diff_scroll = max(0, d.diff.changed[d.diff_change] - GITD_DIFF_LEAD)
}

// ---------------------------------------------------------------------------
// Branch picker helpers
// ---------------------------------------------------------------------------

_bp_free_branches :: proc(d: ^Git_Dialog) {
	for s in d.bp_branches { delete(s) }
	clear(&d.bp_branches)
}

_bp_open :: proc(d: ^Git_Dialog, m: ^git.Git_Manager) {
	_bp_free_branches(d)
	new_list := git.git_list_branches(m)
	for s in new_list { append(&d.bp_branches, s) }
	delete(new_list)
	d.bp_selected = 0
	d.bp_scroll   = 0
	clear(&d.bp_filter)
	d.bp_filter_sel_all = false
	d.bp_open     = true
}

_bp_close :: proc(d: ^Git_Dialog) {
	d.bp_open = false
}

// Returns temp-allocated list of indices into bp_branches matching filter.
_bp_filtered :: proc(d: ^Git_Dialog) -> []int {
	out    := make([dynamic]int, context.temp_allocator)
	filter := string(d.bp_filter[:])
	for b, i in d.bp_branches {
		if filter == "" || strings.contains(b, filter) { append(&out, i) }
	}
	return out[:]
}

// ---------------------------------------------------------------------------

_gitd_set_msg :: proc(d: ^Git_Dialog, ok: bool, msg: string) {
	if d.msg != "" { delete(d.msg) }
	d.msg = strings.clone(msg)
	d.msg_ok = ok
}

// ---------------------------------------------------------------------------
// Merge helpers
// ---------------------------------------------------------------------------

_merge_destroy :: proc(m: ^Merge_State) {
	for &b in m.blocks {
		delete(b.ours_label); delete(b.theirs_label)
		for s in b.ours_lines   { delete(s) }
		for s in b.theirs_lines { delete(s) }
		delete(b.ours_lines)
		delete(b.theirs_lines)
	}
	delete(m.blocks)
	if m.file_path != "" { delete(m.file_path) }
	if m.content != nil  { delete(m.content) }
	m^ = {blocks = make([dynamic]Conflict_Block)}
}

// Parse conflict markers in `content`. Returns owned blocks.
_parse_conflicts :: proc(content: string) -> [dynamic]Conflict_Block {
	blocks := make([dynamic]Conflict_Block)

	Pstate :: enum { None, Ours, Theirs }
	state := Pstate.None

	cur_ours:   [dynamic]string
	cur_theirs: [dynamic]string
	ours_label:  string
	block_start: int

	s          := content
	byte_pos   := 0

	cur_ours   = make([dynamic]string, context.temp_allocator)
	cur_theirs = make([dynamic]string, context.temp_allocator)

	for len(s) > 0 {
		nl := strings.index_byte(s, '\n')
		line_bytes: string
		line_len:   int
		if nl < 0 {
			line_bytes = s
			line_len   = len(s)
		} else {
			line_bytes = s[:nl]
			line_len   = nl + 1
		}
		// Strip trailing \r
		line := line_bytes
		if len(line) > 0 && line[len(line)-1] == '\r' { line = line[:len(line)-1] }

		if strings.has_prefix(line, "<<<<<<<") && state == .None {
			state       = .Ours
			ours_label  = strings.trim_space(line[7:])
			block_start = byte_pos
			clear(&cur_ours)
			clear(&cur_theirs)
		} else if strings.has_prefix(line, "=======") && state == .Ours {
			state = .Theirs
		} else if strings.has_prefix(line, ">>>>>>>") && state == .Theirs {
			theirs_label := strings.trim_space(line[7:])

			b: Conflict_Block
			b.start_byte  = block_start
			b.end_byte    = byte_pos + line_len
			b.ours_label   = strings.clone(ours_label)
			b.theirs_label = strings.clone(theirs_label)
			b.ours_lines   = make([]string, len(cur_ours))
			for l, i in cur_ours   { b.ours_lines[i]   = strings.clone(l) }
			b.theirs_lines = make([]string, len(cur_theirs))
			for l, i in cur_theirs { b.theirs_lines[i] = strings.clone(l) }
			append(&blocks, b)
			state = .None
		} else if state == .Ours {
			append(&cur_ours, line)
		} else if state == .Theirs {
			append(&cur_theirs, line)
		}

		byte_pos += line_len
		if nl < 0 { break }
		s = s[line_len:]
	}
	return blocks
}

// Open merge view for a conflicted file.
_gitd_open_merge :: proc(d: ^Git_Dialog, m: ^git.Git_Manager, abs_path: string) {
	data, err := os.read_entire_file(abs_path, context.allocator)
	if err != nil { _gitd_set_msg(d, false, "can't read file"); return }
	content := string(data)
	blocks := _parse_conflicts(content)
	if len(blocks) == 0 {
		delete(data)
		_gitd_set_msg(d, false, "no conflict markers found")
		return
	}
	_merge_destroy(&d.merge)
	d.merge.blocks    = blocks
	d.merge.selected  = 0
	d.merge.file_path = strings.clone(abs_path)
	d.merge.content   = data
	d.mode = .Merge
}

// Write resolved file back to disk and stage it.
_gitd_write_and_stage :: proc(d: ^Git_Dialog, m: ^git.Git_Manager) {
	ms := &d.merge
	// Check all resolved
	unresolved := 0
	for b in ms.blocks { if b.resolution == .Unresolved { unresolved += 1 } }
	if unresolved > 0 {
		_gitd_set_msg(d, false, fmt.tprintf("%d conflict(s) not resolved", unresolved))
		return
	}

	// Rebuild file content
	b := strings.builder_make()
	content := string(ms.content)
	pos := 0
	for &blk in ms.blocks {
		strings.write_string(&b, content[pos:blk.start_byte])
		switch blk.resolution {
		case .Ours:
			for line in blk.ours_lines   { strings.write_string(&b, line); strings.write_byte(&b, '\n') }
		case .Theirs:
			for line in blk.theirs_lines { strings.write_string(&b, line); strings.write_byte(&b, '\n') }
		case .Both:
			for line in blk.ours_lines   { strings.write_string(&b, line); strings.write_byte(&b, '\n') }
			for line in blk.theirs_lines { strings.write_string(&b, line); strings.write_byte(&b, '\n') }
		case .Unresolved: // unreachable
		}
		pos = blk.end_byte
	}
	strings.write_string(&b, content[pos:])

	write_err := os.write_entire_file(ms.file_path, b.buf[:])
	strings.builder_destroy(&b)
	if write_err != nil { _gitd_set_msg(d, false, "write failed"); return }

	// Stage
	rel := ms.file_path
	if len(m.root) > 0 && len(ms.file_path) > len(m.root)+1 {
		rel = ms.file_path[len(m.root)+1:]
	}
	git.git_stage(m, rel)
	git.git_manager_refresh_now(m)

	_merge_destroy(&d.merge)
	d.mode = .Status
	_gitd_set_msg(d, true, "conflicts resolved and staged")
}

// ---------------------------------------------------------------------------
// Visibility helpers
// ---------------------------------------------------------------------------

_gitd_build_vis :: proc(entries: [dynamic]git.Status_Entry) -> (staged: []int, changes: []int, untracked: []int) {
	s := make([dynamic]int, context.temp_allocator)
	c := make([dynamic]int, context.temp_allocator)
	u := make([dynamic]int, context.temp_allocator)
	for e, i in entries {
		if e.index == '?' && e.worktree == '?' { append(&u, i); continue }
		if e.index != ' '  { append(&s, i) }
		if e.worktree != ' ' && e.worktree != '?' && e.index == ' ' { append(&c, i) }
	}
	return s[:], c[:], u[:]
}

_gitd_vis_total :: proc(staged, changes, untracked: []int) -> int {
	return len(staged) + len(changes) + len(untracked)
}

_gitd_entry_at :: proc(staged, changes, untracked: []int, sel: int) -> int {
	if sel < len(staged)           { return staged[sel] }
	s2 := sel - len(staged)
	if s2 < len(changes)           { return changes[s2] }
	s3 := s2 - len(changes)
	if s3 < len(untracked)         { return untracked[s3] }
	return -1
}

_is_conflicted :: proc(e: git.Status_Entry) -> bool {
	return e.index == 'U' || e.worktree == 'U' ||
	       (e.index == 'A' && e.worktree == 'A') ||
	       (e.index == 'D' && e.worktree == 'D')
}

// ---------------------------------------------------------------------------
// Input handler
// ---------------------------------------------------------------------------

git_dialog_handle_input :: proc(d: ^Git_Dialog, e: ^Editor) {
	if !d.visible { return }
	m := &e.git_mgr

	// Branch picker takes full priority
	if d.bp_open { _git_bp_input(d, m); return }

	// --- Merge mode ---
	if d.mode == .Merge {
		_git_merge_input(d, m)
		return
	}

	// --- Diff mode ---
	if d.mode == .Diff {
		if rl.IsKeyPressed(.ESCAPE) || rl.IsKeyPressed(.B) {
			_gitd_diff_free(d)
			d.mode = .Status; return
		}
		page := max(1, _gitd_diff_page_rows - 2)
		if key_rep(.DOWN) || key_rep(.J) { d.diff_scroll += 1 }
		if key_rep(.UP)   || key_rep(.K) { d.diff_scroll = max(0, d.diff_scroll - 1) }
		if key_rep(.PAGE_DOWN) || (ctrl() && key_rep(.D)) { d.diff_scroll += page }
		if key_rep(.PAGE_UP)   || (ctrl() && key_rep(.U)) { d.diff_scroll = max(0, d.diff_scroll - page) }
		if rl.IsKeyPressed(.HOME) { d.diff_scroll = 0 }
		if rl.IsKeyPressed(.END)  { d.diff_scroll = len(d.diff.rows) }
		// Jump between changes: n / p (Shift+N also goes back)
		if rl.IsKeyPressed(.N) { _gitd_diff_goto(d, d.diff_change + (-1 if shift() else 1)) }
		if rl.IsKeyPressed(.P) { _gitd_diff_goto(d, d.diff_change - 1) }
		wheel := rl.GetMouseWheelMove()
		if wheel != 0 { d.diff_scroll = max(0, d.diff_scroll - int(wheel)*3) }
		return
	}

	// --- Status mode ---
	if d.focus == .Commit {
		if rl.IsKeyPressed(.ESCAPE) || rl.IsKeyPressed(.TAB) { d.focus = .Files; return }
		if rl.IsKeyPressed(.ENTER) {
			if len(d.commit_buf) == 0 { _gitd_set_msg(d, false, "commit message empty"); return }
			err := git.git_commit(m, string(d.commit_buf[:]))
			if err == "" {
				clear(&d.commit_buf)
				_gitd_set_msg(d, true, "committed")
				git.git_manager_refresh_now(m)
			} else { _gitd_set_msg(d, false, err); delete(err) }
			return
		}
		text_input_handle(&d.commit_buf, &d.commit_sel_all)
		return
	}

	staged, changes, untracked := _gitd_build_vis(m.current.entries)
	total := _gitd_vis_total(staged, changes, untracked)

	if rl.IsKeyPressed(.ESCAPE)   { git_dialog_close(d); return }
	if key_rep(.DOWN) && total > 0 { d.selected = min(d.selected+1, total-1) }
	if key_rep(.UP)                { d.selected = max(0, d.selected-1) }
	wheel := rl.GetMouseWheelMove()
	if wheel != 0 { d.selected = clamp(d.selected - int(wheel)*3, 0, max(0, total-1)) }
	if rl.IsKeyPressed(.TAB) { d.focus = .Commit; return }
	if rl.IsKeyPressed(.R)   { git.git_manager_refresh_now(m); _gitd_set_msg(d, true, "refreshing..."); return }

	// Branch picker (merge a branch)
	if rl.IsKeyPressed(.B) { _bp_open(d, m); return }

	// Merge-in-progress actions
	if git.git_merge_in_progress(m) {
		if rl.IsKeyPressed(.F) {
			err := git.git_merge_continue(m)
			if err == "" { _gitd_set_msg(d, true, "merge finalized!") } else { _gitd_set_msg(d, false, err); delete(err) }
			git.git_manager_refresh_now(m); return
		}
		if rl.IsKeyPressed(.Z) {
			ok := git.git_merge_abort(m)
			if ok { _gitd_set_msg(d, true, "merge aborted") } else { _gitd_set_msg(d, false, "abort failed") }
			git.git_manager_refresh_now(m); return
		}
	}

	ei := _gitd_entry_at(staged, changes, untracked, d.selected)
	if ei < 0 { return }
	entry := &m.current.entries[ei]

	if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.M) {
		if _is_conflicted(entry^) {
			abs := fmt.tprintf("%s/%s", m.root, entry.path)
			_gitd_open_merge(d, m, abs)
		}
		return
	}

	if rl.IsKeyPressed(.S) {
		ok: bool
		if entry.index != ' ' {
			ok = git.git_unstage(m, entry.path)
			if ok { _gitd_set_msg(d, true, "unstaged") } else { _gitd_set_msg(d, false, "unstage failed") }
		} else {
			ok = git.git_stage(m, entry.path)
			if ok { _gitd_set_msg(d, true, "staged") } else { _gitd_set_msg(d, false, "stage failed") }
		}
		if ok { git.git_manager_refresh_now(m) }
		return
	}

	if rl.IsKeyPressed(.D) {
		_gitd_open_diff(d, m, entry.path)
		return
	}

	if rl.IsKeyPressed(.X) {
		ok := git.git_checkout(m, entry.path)
		if ok { _gitd_set_msg(d, true, "discarded"); git.git_manager_refresh_now(m) } else { _gitd_set_msg(d, false, "discard failed") }
		return
	}
}

_git_merge_input :: proc(d: ^Git_Dialog, m: ^git.Git_Manager) {
	ms := &d.merge
	n  := len(ms.blocks)

	if rl.IsKeyPressed(.ESCAPE) { d.mode = .Status; return }

	// Navigate conflicts
	if (key_rep(.J) || key_rep(.DOWN) || key_rep(.RIGHT)) && ms.selected < n-1 {
		ms.selected += 1; ms.ours_scroll = 0; ms.theirs_scroll = 0
	}
	if (key_rep(.K) || key_rep(.UP) || key_rep(.LEFT)) && ms.selected > 0 {
		ms.selected -= 1; ms.ours_scroll = 0; ms.theirs_scroll = 0
	}

	// Scroll ours/theirs sections
	wheel := rl.GetMouseWheelMove()
	if wheel != 0 {
		if rl.IsKeyDown(.LEFT_SHIFT) {
			ms.theirs_scroll = max(0, ms.theirs_scroll - int(wheel)*2)
		} else {
			ms.ours_scroll = max(0, ms.ours_scroll - int(wheel)*2)
		}
	}

	if n == 0 { return }
	blk := &ms.blocks[ms.selected]

	if rl.IsKeyPressed(.A) { blk.resolution = .Ours }
	if rl.IsKeyPressed(.B) { blk.resolution = .Theirs }
	if rl.IsKeyPressed(.O) { blk.resolution = .Both }
	if rl.IsKeyPressed(.U) { blk.resolution = .Unresolved } // undo

	if rl.IsKeyPressed(.W) { _gitd_write_and_stage(d, m) }
}

_git_bp_input :: proc(d: ^Git_Dialog, m: ^git.Git_Manager) {
	if rl.IsKeyPressed(.ESCAPE) { _bp_close(d); return }

	filtered := _bp_filtered(d)
	n := len(filtered)

	if key_rep(.DOWN) && d.bp_selected < n-1 {
		d.bp_selected += 1
		if d.bp_selected >= d.bp_scroll + GITD_BP_MAX { d.bp_scroll = d.bp_selected - GITD_BP_MAX + 1 }
	}
	if key_rep(.UP) && d.bp_selected > 0 {
		d.bp_selected -= 1
		if d.bp_selected < d.bp_scroll { d.bp_scroll = d.bp_selected }
	}

	if text_input_handle(&d.bp_filter, &d.bp_filter_sel_all) {
		d.bp_selected = 0; d.bp_scroll = 0
	}

	if rl.IsKeyPressed(.ENTER) && n > 0 {
		branch_idx := filtered[d.bp_selected]
		branch := d.bp_branches[branch_idx]
		conflicts, err := git.git_merge(m, branch)
		_bp_close(d)
		if err != "" {
			_gitd_set_msg(d, false, err); delete(err)
		} else if conflicts {
			_gitd_set_msg(d, true, "merge conflict — select conflicted file then Enter/M to resolve")
		} else {
			_gitd_set_msg(d, true, fmt.tprintf("merged %s", branch))
		}
		git.git_manager_refresh_now(m)
	}
}

// ---------------------------------------------------------------------------
// Draw
// ---------------------------------------------------------------------------

git_dialog_draw :: proc(d: ^Git_Dialog, e: ^Editor, font: rl.Font) {
	if !d.visible { return }
	m := &e.git_mgr

	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())

	switch d.mode {
	case .Merge: _gitd_draw_merge(d, m, font, sw, sh)
	case .Diff:  _gitd_draw_diff(d, m, font, sw, sh)
	case .Status: _gitd_draw_status(d, m, font, sw, sh)
	}
	if d.bp_open { _gitd_draw_branch_picker(d, m, font, sw, sh) }
}

// ---------------------------------------------------------------------------
// Status view
// ---------------------------------------------------------------------------

_gitd_draw_status :: proc(d: ^Git_Dialog, m: ^git.Git_Manager, font: rl.Font, sw, sh: f32) {
	ref := rl.MeasureTextEx(font, "M", FONT_SIZE, CHAR_SPACING)

	staged, changes, untracked := _gitd_build_vis(m.current.entries)
	n_staged := len(staged); n_changes := len(changes); n_untracked := len(untracked)
	total := n_staged + n_changes + n_untracked

	n_sections := 0
	if n_staged > 0    { n_sections += 1 }
	if n_changes > 0   { n_sections += 1 }
	if n_untracked > 0 { n_sections += 1 }

	vis_entries := min(total, GITD_LIST_MAX)
	panel_h := GITD_HEADER_H + f32(n_sections)*GITD_SECTION_H + f32(vis_entries)*GITD_ENTRY_H + GITD_COMMIT_H + GITD_FOOTER_H + 12
	panel_h  = min(panel_h, sh - 60)

	px := (sw - GITD_W) * 0.5
	py := (sh - panel_h) * 0.5

	px, py = dlg_begin(px, py, GITD_W, panel_h, GITD_BG, GITD_BORDER)

	// Header
	merging := git.git_merge_in_progress(m)
	rl.DrawRectangleV({px, py}, {GITD_W, GITD_HEADER_H}, GITD_HEADER)
	branch_str := fmt.tprintf(" Git  %s%s",
		m.current.branch if m.current.branch != "" else "(no branch)",
		"  [MERGING]" if merging else "")
	header_col := GITD_ORANGE if merging else GITD_BLUE
	rl.DrawTextEx(font, to_cstring(branch_str), {px+10, py + (GITD_HEADER_H-ref.y)*0.5}, FONT_SIZE, CHAR_SPACING, header_col)
	if m.refreshing {
		ind_w := rl.MeasureTextEx(font, "refreshing...", FONT_SIZE-2, CHAR_SPACING).x
		rl.DrawTextEx(font, "refreshing...", {px + GITD_W - ind_w - 10, py + (GITD_HEADER_H-ref.y)*0.5}, FONT_SIZE-2, CHAR_SPACING, GITD_SUBDUED)
	}

	// File list
	list_top := py + GITD_HEADER_H
	list_bot := py + panel_h - GITD_COMMIT_H - GITD_FOOTER_H - 14

	cy     := list_top
	vis_idx := 0

	d.scroll = clamp(d.scroll, 0, max(0, total - GITD_LIST_MAX))
	if d.selected - d.scroll >= GITD_LIST_MAX { d.scroll = d.selected - GITD_LIST_MAX + 1 }
	if d.selected < d.scroll                  { d.scroll = d.selected }

	draw_section :: proc(label: string, entries_slice: []int, entries: [dynamic]git.Status_Entry, d: ^Git_Dialog, font: rl.Font, px, cy: f32, vis_idx: ^int, ref: rl.Vector2) -> f32 {
		y := cy
		rl.DrawRectangleV({px, y}, {GITD_W, GITD_SECTION_H}, GITD_SECTION)
		rl.DrawTextEx(font, to_cstring(label), {px+10, y + (GITD_SECTION_H-ref.y+2)*0.5}, FONT_SIZE-2, CHAR_SPACING, GITD_SUBDUED)
		y += GITD_SECTION_H
		for idx in entries_slice {
			vdx := vis_idx^; vis_idx^ += 1
			if vdx < d.scroll || vdx >= d.scroll + GITD_LIST_MAX { y += GITD_ENTRY_H; continue }
			entry := entries[idx]
			is_sel := vdx == d.selected
			if is_sel { rl.DrawRectangleV({px, y}, {GITD_W, GITD_ENTRY_H}, GITD_SEL) }
			// Conflict indicator
			is_conflict := entry.index == 'U' || entry.worktree == 'U' ||
			               (entry.index == 'A' && entry.worktree == 'A') ||
			               (entry.index == 'D' && entry.worktree == 'D')
			xy_col := GITD_RED if is_conflict else (GITD_GREEN if entry.index != ' ' && entry.index != '?' else GITD_ORANGE)
			xy_str := fmt.tprintf("%c%c", rune(entry.index), rune(entry.worktree))
			rl.DrawTextEx(font, to_cstring(xy_str), {px+8,  y + (GITD_ENTRY_H-ref.y)*0.5}, FONT_SIZE-1, CHAR_SPACING, xy_col)
			suffix      := " [!] conflict" if is_conflict else ""
			suffix_w    := rl.MeasureTextEx(font, to_cstring(suffix), FONT_SIZE-2, CHAR_SPACING).x if is_conflict else f32(0)
			right_edge  := px + GITD_W - suffix_w - 8
			ty_entry    := y + (GITD_ENTRY_H-ref.y)*0.5
			dlg_text(font, entry.path, px+36, ty_entry, FONT_SIZE-1, CHAR_SPACING, GITD_TEXT, right_edge, 0)
			if is_conflict {
				path_w := rl.MeasureTextEx(font, to_cstring(text_clip(font, entry.path, right_edge-(px+36), FONT_SIZE-1, CHAR_SPACING)), FONT_SIZE-1, CHAR_SPACING).x
				rl.DrawTextEx(font, " [!] conflict", {px+36+path_w, ty_entry}, FONT_SIZE-2, CHAR_SPACING, GITD_RED)
			}
			y += GITD_ENTRY_H
		}
		return y
	}

	if n_staged > 0    { cy = draw_section("Staged Changes", staged,    m.current.entries, d, font, px, cy, &vis_idx, ref) }
	if n_changes > 0   { cy = draw_section("Changes",       changes,   m.current.entries, d, font, px, cy, &vis_idx, ref) }
	if n_untracked > 0 { cy = draw_section("Untracked",     untracked, m.current.entries, d, font, px, cy, &vis_idx, ref) }

	if total == 0 {
		empty: cstring = "No changes — working tree clean"
		ew := rl.MeasureTextEx(font, empty, FONT_SIZE-1, CHAR_SPACING).x
		rl.DrawTextEx(font, empty, {px + (GITD_W-ew)*0.5, list_top + 14}, FONT_SIZE-1, CHAR_SPACING, GITD_SUBDUED)
	}

	// Separator
	sep_y := list_bot + 4
	rl.DrawLineV({px, sep_y}, {px+GITD_W, sep_y}, GITD_BORDER)

	// Commit input
	commit_y := sep_y + 4
	commit_border := GITD_BLUE if d.focus == .Commit else GITD_BORDER
	rl.DrawRectangleLinesEx({px+8, commit_y, GITD_W-16, GITD_COMMIT_H}, 1, commit_border)
	commit_str  := string(d.commit_buf[:]) if len(d.commit_buf) > 0 else ""
	commit_cstr := to_cstring(commit_str)  if commit_str != "" else cstring("Commit message... (Tab to focus, Enter to commit)")
	commit_col  := GITD_TEXT if len(d.commit_buf) > 0 else GITD_SUBDUED
	rl.DrawTextEx(font, commit_cstr, {px+14, commit_y + (GITD_COMMIT_H-ref.y)*0.5}, FONT_SIZE-1, CHAR_SPACING, commit_col)
	if d.focus == .Commit {
		cx := px + 14 + rl.MeasureTextEx(font, commit_cstr, FONT_SIZE-1, CHAR_SPACING).x
		rl.DrawLineV({cx+1, commit_y+4}, {cx+1, commit_y+GITD_COMMIT_H-4}, GITD_BLUE)
	}

	// Status msg
	msg_y := commit_y + GITD_COMMIT_H + 2
	if d.msg != "" {
		mc := GITD_GREEN if d.msg_ok else GITD_RED
		rl.DrawTextEx(font, to_cstring(d.msg), {px+14, msg_y}, FONT_SIZE-2, CHAR_SPACING, mc)
	}

	// Footer
	footer_y := py + panel_h - GITD_FOOTER_H
	rl.DrawLineV({px, footer_y}, {px+GITD_W, footer_y}, GITD_BORDER)
	hint_str := "S stage/unstage  D diff  M conflict  X discard  B merge branch  R refresh  Tab commit  Esc close"
	if merging { hint_str = "M conflict  B merge branch  F finalize merge  Z abort merge  S stage  D diff  Esc close" }
	rl.DrawTextEx(font, to_cstring(hint_str), {px+10, footer_y + (GITD_FOOTER_H-ref.y)*0.5}, FONT_SIZE-2, CHAR_SPACING, GITD_SUBDUED)
	dlg_end()
}

// ---------------------------------------------------------------------------
// Diff view
// ---------------------------------------------------------------------------

_gitd_draw_diff :: proc(d: ^Git_Dialog, m: ^git.Git_Manager, font: rl.Font, sw, sh: f32) {
	ref := rl.MeasureTextEx(font, "M", FONT_SIZE, CHAR_SPACING)
	fs  := FONT_SIZE - 1
	dy  := ref.y + 2
	cw  := rl.MeasureTextEx(font, "0", fs, CHAR_SPACING).x

	// Nearly full window: the whole file is shown, so use the space
	pw := sw - 40
	ph := sh - 40
	px, py := dlg_begin((sw - pw) * 0.5, (sh - ph) * 0.5, pw, ph, GITD_BG, GITD_BORDER)

	rows := d.diff.rows[:]
	n_changes := len(d.diff.changed)

	// Header: path, change counter, keys
	rl.DrawRectangleV({px, py}, {pw, GITD_HEADER_H}, GITD_HEADER)
	pos := fmt.tprintf("change %d/%d", d.diff_change + 1, n_changes) if n_changes > 0 else "no changes"
	title := fmt.tprintf(" %s   %s   (n/p next/prev change, ↑↓ PgUp/PgDn scroll, Esc back)", d.diff_path, pos)
	dlg_text(font, title, px + 10, py + (GITD_HEADER_H - ref.y) * 0.5, fs, CHAR_SPACING, GITD_BLUE, px + pw, 10)

	footer_y    := py + ph - GITD_FOOTER_H
	content_top := py + GITD_HEADER_H
	content_h   := footer_y - content_top

	vis := max(1, int(content_h / dy))
	_gitd_diff_page_rows = vis
	d.diff_scroll = clamp(d.diff_scroll, 0, max(0, len(rows) - vis))

	if d.diff.binary || len(rows) == 0 {
		msg := "Binary file — no text diff" if d.diff.binary else "No changes"
		rl.DrawTextEx(font, to_cstring(msg), {px + 16, content_top + 12}, fs, CHAR_SPACING, GITD_SUBDUED)
		dlg_end()
		return
	}

	// Two columns: [gutter | text] old  ‖  [gutter | text] new
	half   := (pw - 3) * 0.5
	gutter := cw * f32(GITD_DIFF_GUTTER_CH) + 10
	col_x  := [2]f32{px, px + half + 3}
	rl.DrawRectangleV({px + half + 1, content_top}, {1, content_h}, GITD_BORDER)

	cy := content_top
	for i := d.diff_scroll; i < len(rows) && i < d.diff_scroll + vis; i += 1 {
		row := rows[i]
		sides := [2]git.Diff_Side{row.left, row.right}
		for side, c in sides {
			x := col_x[c]
			bg: rl.Color
			mark: rl.Color
			switch side.kind {
			case .Context: bg = GITD_BG
			case .Add:     bg = GITD_DIFF_ADD_BG;   mark = GITD_DIFF_MARK_ADD
			case .Delete:  bg = GITD_DIFF_DEL_BG;   mark = GITD_DIFF_MARK_DEL
			case .Empty:   bg = GITD_DIFF_EMPTY_BG
			}
			if side.kind != .Context { rl.DrawRectangleV({x, cy}, {half, dy}, bg) }
			if mark.a != 0 { rl.DrawRectangleV({x, cy}, {3, dy}, mark) }
			if side.line > 0 {
				num := fmt.tprintf("%d", side.line)
				nw  := rl.MeasureTextEx(font, to_cstring(num), fs, CHAR_SPACING).x
				rl.DrawTextEx(font, to_cstring(num), {x + gutter - 8 - nw, cy + 1}, fs, CHAR_SPACING, GITD_SUBDUED)
			}
			if side.text != "" {
				dlg_text(font, _gitd_expand_tabs(side.text), x + gutter, cy + 1, fs, CHAR_SPACING,
				         GITD_TEXT, x + half, 6)
			}
		}
		cy += dy
	}

	// Scrollbar with change markers, so changes are visible across the file
	track_x := px + pw - 6
	rl.DrawRectangleV({track_x, content_top}, {5, content_h}, GITD_HEADER)
	total := f32(len(rows))
	for start in d.diff.changed {
		r := rows[start]
		col := GITD_DIFF_MARK_DEL if r.right.kind == .Empty else GITD_DIFF_MARK_ADD
		if r.left.kind == .Delete && r.right.kind == .Add { col = GITD_YELLOW }
		rl.DrawRectangleV({track_x, content_top + content_h * f32(start) / total}, {5, 2}, col)
	}
	bar_h := max(16, content_h * f32(vis) / total)
	bar_y := content_top + content_h * f32(d.diff_scroll) / total
	rl.DrawRectangleLinesEx({track_x - 1, bar_y, 7, bar_h}, 1, GITD_SUBDUED)

	// Footer
	rl.DrawLineV({px, footer_y}, {px + pw, footer_y}, GITD_BORDER)
	info := fmt.tprintf("line %d/%d", d.diff_scroll + 1, len(rows))
	iw := rl.MeasureTextEx(font, to_cstring(info), FONT_SIZE - 2, CHAR_SPACING).x
	rl.DrawTextEx(font, to_cstring(info), {px + pw - iw - 14, footer_y + (GITD_FOOTER_H - ref.y) * 0.5}, FONT_SIZE - 2, CHAR_SPACING, GITD_SUBDUED)
	dlg_end()
}

// Tabs as spaces for display (raylib draws \t as a missing glyph)
_gitd_expand_tabs :: proc(s: string) -> string {
	if strings.index_byte(s, '\t') < 0 { return s }
	b := strings.builder_make(context.temp_allocator)
	col := 0
	for r in s {
		if r == '\t' {
			for _ in 0..<(4 - col % 4) { strings.write_byte(&b, ' '); col += 1 }
		} else {
			strings.write_rune(&b, r); col += 1
		}
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// Merge view
// ---------------------------------------------------------------------------

_gitd_draw_merge :: proc(d: ^Git_Dialog, m: ^git.Git_Manager, font: rl.Font, sw, sh: f32) {
	ms  := &d.merge
	ref := rl.MeasureTextEx(font, "M", FONT_SIZE, CHAR_SPACING)
	lh  := ref.y + 3

	n   := len(ms.blocks)
	if n == 0 { d.mode = .Status; return }
	blk := &ms.blocks[ms.selected]

	// Count resolved
	resolved := 0
	for b in ms.blocks { if b.resolution != .Unresolved { resolved += 1 } }

	// Panel sizing: header + two side-by-side panels (each GITD_ROW_MAX rows) + action bar + footer
	side_h    := GITD_SECTION_H + f32(GITD_ROW_MAX)*lh + 6
	panel_h   := GITD_HEADER_H + side_h + f32(32) + GITD_FOOTER_H
	panel_h    = min(panel_h, sh - 40)

	px := (sw - GITD_MERGE_W) * 0.5
	py := (sh - panel_h) * 0.5

	px, py = dlg_begin(px, py, GITD_MERGE_W, panel_h, GITD_BG, GITD_BORDER)

	// Header
	rl.DrawRectangleV({px, py}, {GITD_MERGE_W, GITD_HEADER_H}, GITD_HEADER)
	header_str := fmt.tprintf(" Merge Conflicts  %d/%d  —  conflict %d of %d",
		resolved, n, ms.selected+1, n)
	rl.DrawTextEx(font, to_cstring(header_str), {px+10, py + (GITD_HEADER_H-ref.y)*0.5}, FONT_SIZE, CHAR_SPACING, GITD_BLUE)

	// Resolution status: show "2/5" count
	status_str := fmt.tprintf("%d/%d resolved", resolved, n)
	status_w := rl.MeasureTextEx(font, to_cstring(status_str), FONT_SIZE-2, CHAR_SPACING).x
	rl.DrawTextEx(font, to_cstring(status_str), {px + GITD_MERGE_W - status_w - 12, py + (GITD_HEADER_H-ref.y)*0.5}, FONT_SIZE-2, CHAR_SPACING, GITD_SUBDUED)

	cy := py + GITD_HEADER_H

	// Two side-by-side panels
	left_x  := px + 2
	right_x := px + GITD_HALF_W + 4

	_draw_side :: proc(title, label: string, lines_arr: []string, bg_col, label_col: rl.Color,
	                   x, y, w, h: f32, scroll: ^int, font: rl.Font, ref: rl.Vector2, lh: f32) {
		rl.DrawRectangleV({x, y}, {w, GITD_SECTION_H}, GITD_SECTION)
		head := fmt.tprintf(" %s  %s", title, label)
		rl.DrawTextEx(font, to_cstring(head), {x+6, y + (GITD_SECTION_H-ref.y)*0.5}, FONT_SIZE-2, CHAR_SPACING, label_col)
		sy := y + GITD_SECTION_H

		n_lines := len(lines_arr)
		scroll_max := max(0, n_lines - GITD_ROW_MAX)
		scroll^ = clamp(scroll^, 0, scroll_max)

		clip_h := h - GITD_SECTION_H
		rl.BeginScissorMode(i32(x)+1, i32(sy), i32(w)-2, i32(clip_h))
		for i := 0; i < GITD_ROW_MAX && scroll^+i < n_lines; i += 1 {
			ly := sy + f32(i)*lh
			rl.DrawRectangleV({x+1, ly}, {w-2, lh}, bg_col)
			rl.DrawTextEx(font, to_cstring(lines_arr[scroll^+i]), {x+6, ly+1}, FONT_SIZE-1, CHAR_SPACING, GITD_TEXT)
		}
		if n_lines == 0 {
			rl.DrawTextEx(font, "(empty)", {x+8, sy+4}, FONT_SIZE-2, CHAR_SPACING, GITD_SUBDUED)
		}
		rl.EndScissorMode()
	}

	// Left: OURS (HEAD)  |  Right: THEIRS (incoming)
	_draw_side("CURRENT",  blk.ours_label,   blk.ours_lines,   GITD_GREEN_BG, GITD_GREEN,
	           left_x,  cy, GITD_HALF_W, side_h, &ms.ours_scroll,   font, ref, lh)
	dlg_restore() // re-enable panel scissor after _draw_side's EndScissorMode
	_draw_side("INCOMING", blk.theirs_label, blk.theirs_lines, GITD_RED_BG,   GITD_RED,
	           right_x, cy, GITD_HALF_W, side_h, &ms.theirs_scroll, font, ref, lh)
	dlg_restore() // re-enable panel scissor after _draw_side's EndScissorMode

	// Vertical divider between the two panels
	rl.DrawLineV({px + GITD_HALF_W + 2, cy}, {px + GITD_HALF_W + 2, cy + side_h}, GITD_BORDER)

	cy += side_h

	// Resolution buttons / current status
	rl.DrawLineV({px, cy}, {px+GITD_MERGE_W, cy}, GITD_BORDER)
	cy += 6

	res_str: string
	res_col: rl.Color
	switch blk.resolution {
	case .Ours:       res_str = "[v] Accept Current";  res_col = GITD_GREEN
	case .Theirs:     res_str = "[v] Accept Incoming"; res_col = GITD_RED
	case .Both:       res_str = "[v] Accept Both";     res_col = GITD_YELLOW
	case .Unresolved: res_str = "    Unresolved";      res_col = GITD_SUBDUED
	}
	rl.DrawTextEx(font, to_cstring(res_str), {px+10, cy + (ref.y)*0.5 - 2}, FONT_SIZE-1, CHAR_SPACING, res_col)

	// Action key hints on right
	act_hints: cstring = "[A] Current  [B] Incoming  [O] Both  [U] Undo"
	act_w := rl.MeasureTextEx(font, act_hints, FONT_SIZE-2, CHAR_SPACING).x
	rl.DrawTextEx(font, act_hints, {px+GITD_MERGE_W-act_w-10, cy + (ref.y)*0.5 - 2}, FONT_SIZE-2, CHAR_SPACING, GITD_SUBDUED)
	cy += f32(32)

	// Footer
	footer_y := py + panel_h - GITD_FOOTER_H
	rl.DrawLineV({px, footer_y}, {px+GITD_MERGE_W, footer_y}, GITD_BORDER)
	nav_hint: cstring = "J/K navigate conflicts  W write & stage  Esc back  Shift+Scroll = scroll incoming"
	rl.DrawTextEx(font, nav_hint, {px+10, footer_y + (GITD_FOOTER_H-ref.y)*0.5}, FONT_SIZE-2, CHAR_SPACING, GITD_SUBDUED)
	dlg_end()
}

// ---------------------------------------------------------------------------
// Branch picker overlay
// ---------------------------------------------------------------------------

_gitd_draw_branch_picker :: proc(d: ^Git_Dialog, m: ^git.Git_Manager, font: rl.Font, sw, sh: f32) {
	ref := rl.MeasureTextEx(font, "M", FONT_SIZE, CHAR_SPACING)

	BP_ENTRY_H  :: f32(22)
	BP_INPUT_H  :: f32(30)
	BP_FOOTER_H :: f32(24)

	filtered := _bp_filtered(d)
	n_vis    := min(len(filtered), GITD_BP_MAX)
	panel_h  := GITD_HEADER_H + BP_INPUT_H + f32(n_vis)*BP_ENTRY_H + BP_FOOTER_H + 8
	if n_vis == 0 { panel_h += BP_ENTRY_H } // space for "no match" text

	px := (sw - GITD_BP_W) * 0.5
	py := (sh - panel_h)   * 0.5

	// Dim everything behind
	rl.DrawRectangleV({0, 0}, {sw, sh}, rl.Color{0, 0, 0, 120})

	px, py = dlg_begin(px, py, GITD_BP_W, panel_h, GITD_BG, GITD_BORDER)

	// Header
	rl.DrawRectangleV({px, py}, {GITD_BP_W, GITD_HEADER_H}, GITD_HEADER)
	h_str := fmt.tprintf(" Merge Branch into %s", m.current.branch)
	rl.DrawTextEx(font, to_cstring(h_str), {px+10, py + (GITD_HEADER_H-ref.y)*0.5}, FONT_SIZE, CHAR_SPACING, GITD_BLUE)

	cy := py + GITD_HEADER_H

	// Filter input box
	rl.DrawRectangleLinesEx({px+8, cy+4, GITD_BP_W-16, BP_INPUT_H-8}, 1, GITD_BLUE)
	filter_str  := string(d.bp_filter[:])
	filter_cstr := to_cstring(filter_str) if filter_str != "" else cstring("Filter branches...")
	filter_col  := GITD_TEXT if filter_str != "" else GITD_SUBDUED
	text_x      := px + 14
	text_y      := cy + 4 + (BP_INPUT_H-8-ref.y)*0.5
	rl.DrawTextEx(font, filter_cstr, {text_x, text_y}, FONT_SIZE-1, CHAR_SPACING, filter_col)
	// Blinking cursor at end of typed text
	cur_x := text_x + rl.MeasureTextEx(font, to_cstring(filter_str), FONT_SIZE-1, CHAR_SPACING).x
	rl.DrawLineV({cur_x+1, cy+8}, {cur_x+1, cy+BP_INPUT_H-8}, GITD_BLUE)
	cy += BP_INPUT_H

	// Branch list
	list_h := f32(max(n_vis, 1)) * BP_ENTRY_H
	if len(filtered) == 0 {
		no_match: cstring = "no branches match"
		rl.DrawTextEx(font, no_match, {px+14, cy+4}, FONT_SIZE-2, CHAR_SPACING, GITD_SUBDUED)
	} else {
		for i := 0; i < n_vis; i += 1 {
			fi := d.bp_scroll + i
			if fi >= len(filtered) { break }
			bi  := filtered[fi]
			b   := d.bp_branches[bi]
			is_sel     := fi == d.bp_selected
			is_current := b == m.current.branch
			ey  := cy + f32(i)*BP_ENTRY_H
			if is_sel { rl.DrawRectangleV({px, ey}, {GITD_BP_W, BP_ENTRY_H}, GITD_SEL) }
			// Current branch marker
			mark: cstring = "* " if is_current else "  "
			mark_col := GITD_GREEN
			rl.DrawTextEx(font, mark, {px+10, ey + (BP_ENTRY_H-ref.y)*0.5}, FONT_SIZE-1, CHAR_SPACING, mark_col)
			name_col := GITD_YELLOW if is_sel else GITD_TEXT
			dlg_text(font, b, px+28, ey + (BP_ENTRY_H-ref.y)*0.5, FONT_SIZE-1, CHAR_SPACING, name_col, px+GITD_BP_W, 8)
		}
	}
	cy += list_h

	// Footer
	rl.DrawLineV({px, cy}, {px+GITD_BP_W, cy}, GITD_BORDER)
	fp_hint: cstring = "Enter merge  J/K or Up/Down navigate  type to filter  Esc cancel"
	rl.DrawTextEx(font, fp_hint, {px+10, cy + (BP_FOOTER_H-ref.y)*0.5}, FONT_SIZE-2, CHAR_SPACING, GITD_SUBDUED)
	dlg_end()
}
