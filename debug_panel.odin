package editor

// Persistent bottom debug panel — replaces the old modal Evaluate dialog.
// Toggle with Ctrl+E (or it auto-opens on a breakpoint/step hit). Stepping
// shortcuts (F5/F9/F10/F11) work globally regardless of whether this panel
// has input focus, so you can keep it open while single-stepping.

import rl  "vendor:raylib"
import fmt "core:fmt"
import os  "core:os"
import str "core:strings"
import dbg "./debug"
import lsp "./lsp"

DEBUG_PANEL_H :: f32(280)

Debug_Panel :: struct {
	visible:       bool,
	focused:       bool, // true when the panel should eat keyboard input; false lets it stay visible while the editor keeps focus
	active_tab:    int, // 0 = Threads & Variables, 1 = Console
	frame_scroll:  int,
	var_scroll:    int,
	console_scroll: int,

	expr_buf:     [dynamic]u8,
	expr_sel_all: bool,
	result_shown: bool,

	// LSP-backed autocomplete (Ctrl+Space): the paused frame's real source
	// file is briefly told (via didChange) that it contains the typed
	// expression as an extra line, purely so the language server resolves
	// member completions with real project context. The actual Pane/buffer
	// is never touched.
	suggest_open:     bool,
	lsp_path:         string, // heap
	lsp_true_content: string, // heap — real content to restore on revert

	_was_paused: bool, // edge-detect Paused transitions, for auto-open
}

debug_panel_init :: proc(d: ^Debug_Panel) {
	d.expr_buf = make([dynamic]u8)
}

debug_panel_destroy :: proc(d: ^Debug_Panel) {
	delete(d.expr_buf)
	delete(d.lsp_path)
	delete(d.lsp_true_content)
}

debug_panel_open :: proc(d: ^Debug_Panel, initial_expr: string) {
	d.visible      = true
	d.focused      = true
	d.active_tab   = 0
	d.result_shown = false
	d.expr_sel_all = false
	clear(&d.expr_buf)
	for b in transmute([]u8)initial_expr {
		append(&d.expr_buf, b)
	}
}

debug_panel_close :: proc(e: ^Editor, d: ^Debug_Panel) {
	_eval_lsp_revert(e, d)
	d.visible = false
	d.focused = false
}

// Call once per frame (before input handling) — auto-opens the panel the
// moment the debugger pauses, so a breakpoint/step hit surfaces the frame
// and variables without the user having to remember to open it.
debug_panel_update :: proc(e: ^Editor, d: ^Debug_Panel) {
	paused := dbg.manager_get_state(&e.debug_mgr) == .Paused
	if paused && !d._was_paused && !d.visible {
		debug_panel_open(d, "")
	}
	d._was_paused = paused
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

debug_panel_handle_input :: proc(e: ^Editor, d: ^Debug_Panel) {
	if !d.visible { return }

	suggest_client := _eval_suggest_client(e, d)

	if rl.IsKeyPressed(.ESCAPE) {
		if d.suggest_open { _eval_lsp_revert(e, d); return }
		debug_panel_close(e, d)
		return
	}

	if rl.IsKeyPressed(.TAB) && !d.suggest_open {
		d.active_tab = 1 - d.active_tab
		return
	}

	if d.active_tab == 1 {
		// Console tab: just scroll
		if rl.IsKeyPressed(.PAGE_DOWN) { d.console_scroll += 5; return }
		if rl.IsKeyPressed(.PAGE_UP)   { d.console_scroll = max(0, d.console_scroll-5); return }
		if rl.IsKeyPressed(.DOWN)     { d.console_scroll += 1; return }
		if rl.IsKeyPressed(.UP)       { d.console_scroll = max(0, d.console_scroll-1); return }
		return
	}

	// Threads & Variables tab
	if d.suggest_open && suggest_client != nil {
		if rl.IsKeyPressed(.DOWN) { lsp.completion_select_next(suggest_client); return }
		if rl.IsKeyPressed(.UP)   { lsp.completion_select_prev(suggest_client); return }
		if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.TAB) {
			_eval_accept_suggestion(e, d, suggest_client)
			return
		}
	}

	if ctrl() && rl.IsKeyPressed(.SPACE) {
		_eval_trigger_completion(e, d)
		return
	}

	if ctrl() && rl.IsKeyPressed(.ENTER) || (rl.IsKeyPressed(.ENTER) && !d.suggest_open) {
		_eval_lsp_revert(e, d)
		expr := string(d.expr_buf[:])
		if expr != "" {
			e.debug_mgr.eval_result.expr = str.clone(expr)
			dbg.debug_evaluate(&e.debug_mgr, expr)
			d.result_shown = true
		}
		return
	}

	if rl.IsKeyPressed(.PAGE_DOWN) { d.frame_scroll += 5; return }
	if rl.IsKeyPressed(.PAGE_UP)   { if d.frame_scroll > 5 { d.frame_scroll -= 5 } else { d.frame_scroll = 0 }; return }

	// Up/Down (no suggestion popup open) move the selected stack frame
	if rl.IsKeyPressed(.DOWN) {
		frames := dbg.manager_get_frames(&e.debug_mgr)
		if len(frames) > 0 { dbg.manager_set_active_frame(&e.debug_mgr, min(e.debug_mgr.active_frame+1, len(frames)-1)) }
		return
	}
	if rl.IsKeyPressed(.UP) {
		frames := dbg.manager_get_frames(&e.debug_mgr)
		if len(frames) > 0 { dbg.manager_set_active_frame(&e.debug_mgr, max(e.debug_mgr.active_frame-1, 0)) }
		return
	}

	changed := text_input_handle(&d.expr_buf, &d.expr_sel_all)
	if changed && d.suggest_open && suggest_client != nil {
		lsp.completion_update_prefix(suggest_client, _eval_prefix(d))
	}
}

// ---------------------------------------------------------------------------
// LSP-backed autocomplete helpers (operate on Debug_Panel)
// ---------------------------------------------------------------------------

_eval_suggest_client :: proc(e: ^Editor, d: ^Debug_Panel) -> ^lsp.Language_Client {
	if d.lsp_path == "" { return nil }
	return lsp.lsp_manager_find_client_for_path(&e.lsp_mgr, d.lsp_path)
}

_eval_prefix :: proc(d: ^Debug_Panel) -> string {
	end := len(d.expr_buf)
	start := end
	for start > 0 && _is_ident_char(rune(d.expr_buf[start-1])) { start -= 1 }
	return string(d.expr_buf[start:end])
}

_strip_ext :: proc(name: string) -> string {
	dot := str.last_index(name, ".")
	return dot >= 0 ? name[:dot] : name
}

// Resolves a stack frame's `source` to an openable path. DAP sessions already
// put a real (absolute or workspace-relative) path there. JDWP sessions only
// know the bare filename the class was compiled from ("OrderService.java",
// no directory — JDWP has no notion of project layout) — first check panes
// already open for that name, then fall back to a first-match search of the
// workspace tree (reusing goto_def's directory-skip list).
_debug_resolve_frame_file :: proc(e: ^Editor, source: string) -> (string, bool) {
	if source == "" { return "", false }
	if os.exists(source) { return source, true }

	for &p in e.panes {
		if path_basename(p.filename) == source { return p.filename, true }
	}

	w: os.Walker
	os.walker_init(&w, ".")
	defer os.walker_destroy(&w)
	for {
		info, ok := os.walker_walk(&w)
		if !ok { break }
		if info.type == .Directory {
			skip := len(info.name) > 0 && info.name[0] == '.'
			if !skip { for d in _DEF_SKIP { if info.name == d { skip = true; break } } }
			if skip { os.walker_skip_dir(&w) }
			continue
		}
		if info.name == source { return str.clone(info.fullpath), true }
	}
	return "", false
}

// Click-to-navigate on a call-stack frame: opens its source file (if
// resolvable) and moves the cursor to the frame's line, mirroring
// goto_def's jump behavior.
_debug_panel_jump_to_frame :: proc(e: ^Editor, f: dbg.Stack_Frame) {
	path, ok := _debug_resolve_frame_file(e, f.source)
	if !ok {
		e.msg = "No source available for this frame"
		return
	}
	p := active_pane(e)
	if path != p.filename {
		if !editor_open(e, path) { e.msg = "Cannot open file"; return }
		p = active_pane(e)
	}
	target := max(0, min(f.line-1, buffer_line_count(&p.buf)-1))
	ls := buffer_line_start(&p.buf, target)
	p.cursor      = ls
	p.sel_anchor  = ls
	p.scroll      = max(0, target-5)
	p.scroll_anim = f32(p.scroll)
	mc_clear(p)
}

_eval_find_pane :: proc(e: ^Editor, path: string) -> ^Pane {
	for &p in e.panes {
		if p.filename == path { return &p }
	}
	return nil
}

_eval_trigger_completion :: proc(e: ^Editor, d: ^Debug_Panel) {
	frames := dbg.manager_get_frames(&e.debug_mgr)
	if len(frames) == 0 || e.debug_mgr.active_frame >= len(frames) { return }
	fr := frames[e.debug_mgr.active_frame]
	if fr.source == "" || fr.line <= 0 { return }

	if lsp.lsp_manager_find_client_for_path(&e.lsp_mgr, fr.source) == nil { return }

	if d.lsp_path != "" && d.lsp_path != fr.source {
		_eval_lsp_revert(e, d)
	}

	real_content: string
	pane := _eval_find_pane(e, fr.source)
	if pane != nil {
		real_content = buffer_to_string(&pane.buf, context.temp_allocator)
	} else {
		data, err := os.read_entire_file(fr.source, context.temp_allocator)
		if err != nil { return }
		real_content = string(data)
	}

	if d.lsp_path == "" {
		d.lsp_path         = str.clone(fr.source)
		d.lsp_true_content = str.clone(real_content)
	}

	spliced, line0, char0 := _eval_splice_content(real_content, fr.line, string(d.expr_buf[:]))
	lsp.manager_did_change_full(&e.lsp_mgr, fr.source, spliced)
	lsp.manager_completion(&e.lsp_mgr, fr.source, line0, char0, .Invoked, 0, _eval_prefix(d))
	d.suggest_open = true
}

_eval_splice_content :: proc(real_content: string, frame_line_1based: int, typed: string) -> (spliced: string, line0, char0: int) {
	lines := str.split(real_content, "\n", context.temp_allocator)
	idx := frame_line_1based - 1
	if idx < 0 || idx >= len(lines) { return str.clone(real_content, context.temp_allocator), 0, 0 }

	paused := lines[idx]
	indent_len := 0
	for indent_len < len(paused) && (paused[indent_len] == ' ' || paused[indent_len] == '\t') { indent_len += 1 }
	new_line := str.concatenate({paused[:indent_len], typed}, context.temp_allocator)

	out := make([dynamic]string, 0, len(lines)+1, context.temp_allocator)
	for l, i in lines {
		append(&out, l)
		if i == idx { append(&out, new_line) }
	}
	spliced = str.join(out[:], "\n", context.temp_allocator)
	line0 = idx + 1
	char0 = len(new_line)
	return
}

_eval_accept_suggestion :: proc(e: ^Editor, d: ^Debug_Panel, c: ^lsp.Language_Client) {
	item := lsp.completion_selected_item(c)
	if item == nil { _eval_lsp_revert(e, d); return }
	insert_text := item.insert_text != "" ? item.insert_text : item.label

	prefix_len := len(_eval_prefix(d))
	for i in 0..<prefix_len { pop(&d.expr_buf) }
	for b in transmute([]u8)insert_text { append(&d.expr_buf, b) }

	_eval_lsp_revert(e, d)
}

_eval_lsp_revert :: proc(e: ^Editor, d: ^Debug_Panel) {
	if d.lsp_path == "" { return }
	if c := lsp.lsp_manager_find_client_for_path(&e.lsp_mgr, d.lsp_path); c != nil {
		lsp.completion_cancel(c)
		lsp.manager_did_change_full(&e.lsp_mgr, d.lsp_path, d.lsp_true_content)
	}
	delete(d.lsp_path);         d.lsp_path = ""
	delete(d.lsp_true_content); d.lsp_true_content = ""
	d.suggest_open = false
}

// ---------------------------------------------------------------------------
// Draw
// ---------------------------------------------------------------------------

DBGP_BG      := rl.Color{30,  30,  46,  255}
DBGP_HDR_BG  := rl.Color{24,  24,  37,  255}
DBGP_BORDER  := rl.Color{58,  60,  78,  255}
DBGP_SEL     := rl.Color{69,  71,  90,  255}
DBGP_TEXT    := rl.Color{205, 214, 244, 255}
DBGP_SUBDUED := rl.Color{108, 112, 134, 255}
DBGP_GREEN   := rl.Color{166, 227, 161, 255}
DBGP_RED     := rl.Color{243, 139, 168, 255}
DBGP_YELLOW  := rl.Color{249, 226, 175, 255}
DBGP_BLUE    := rl.Color{137, 180, 250, 255}

Tool_Btn :: struct { label: string, rect: rl.Rectangle, enabled: bool }

debug_panel_draw :: proc(e: ^Editor, d: ^Debug_Panel, font: rl.Font, sw, sh, msg_line_h: f32) {
	if !d.visible { return }

	py := sh - msg_line_h - DEBUG_PANEL_H
	rl.DrawRectangleV({0, py}, {sw, DEBUG_PANEL_H}, DBGP_BG)
	rl.DrawLineV({0, py}, {sw, py}, DBGP_BORDER)

	ref := rl.MeasureTextEx(font, "M", FONT_SIZE, CHAR_SPACING)
	m := &e.debug_mgr
	state := dbg.manager_get_state(m)

	mouse := rl.GetMousePosition()
	clicked := rl.IsMouseButtonPressed(.LEFT)

	// ── Header: title + toolbar ──────────────────────────────────
	HEADER_H :: f32(30)
	rl.DrawRectangleV({0, py}, {sw, HEADER_H}, DBGP_HDR_BG)
	rl.DrawLineV({0, py + HEADER_H - 1}, {sw, py + HEADER_H - 1}, DBGP_BORDER)
	rl.DrawTextEx(font, "Debug", {10, py + (HEADER_H-ref.y)*0.5}, FONT_SIZE, CHAR_SPACING, DBGP_BLUE)

	btns := []Tool_Btn{
		{"Restart",    {}, state != .Idle},
		{"Stop",       {}, state != .Idle},
		{"Continue",   {}, state == .Paused},
		{"Pause",      {}, state == .Running},
		{"Step Over",  {}, state == .Paused},
		{"Step Into",  {}, state == .Paused},
		{"Step Out",   {}, state == .Paused},
	}
	bx := f32(90)
	for &b, i in btns {
		bw := rl.MeasureTextEx(font, to_cstring(b.label), FONT_SIZE-2, CHAR_SPACING).x + 16
		b.rect = {bx, py + 4, bw, HEADER_H - 8}
		col := (b.enabled ? DBGP_TEXT : DBGP_SUBDUED)
		hovered := rl.CheckCollisionPointRec(mouse, b.rect)
		if hovered && b.enabled { rl.DrawRectangleRec(b.rect, DBGP_SEL) }
		rl.DrawTextEx(font, to_cstring(b.label), {b.rect.x+8, py + (HEADER_H-ref.y)*0.5}, FONT_SIZE-2, CHAR_SPACING, col)
		if hovered && b.enabled && clicked {
			switch i {
			case 0: dbg.session_restart(m)
			case 1: dbg.session_stop(m)
			case 2: dbg.debug_continue(m)
			case 3: dbg.debug_pause(m)
			case 4: dbg.debug_next(m)
			case 5: dbg.debug_step_in(m)
			case 6: dbg.debug_step_out(m)
			}
		}
		bx += bw + 6
	}

	status_s := state == .Idle ? "not connected" : (state == .Running ? "running" : (state == .Paused ? "paused" : "..."))
	status_col := state == .Paused ? DBGP_BLUE : (state == .Running ? DBGP_GREEN : DBGP_SUBDUED)
	sw_s := rl.MeasureTextEx(font, to_cstring(status_s), FONT_SIZE-3, CHAR_SPACING).x
	rl.DrawTextEx(font, to_cstring(status_s), {sw - sw_s - 10, py + (HEADER_H-ref.y+2)*0.5}, FONT_SIZE-3, CHAR_SPACING, status_col)

	cy := py + HEADER_H

	// ── Tabs ──────────────────────────────────────────────────────
	TAB_H :: f32(26)
	tabs := []string{"Threads & Variables", "Console"}
	tx := f32(10)
	for label, i in tabs {
		tw := rl.MeasureTextEx(font, to_cstring(label), FONT_SIZE-1, CHAR_SPACING).x + 16
		rect := rl.Rectangle{tx, cy, tw, TAB_H}
		is_active := i == d.active_tab
		if is_active { rl.DrawLineV({tx+8, cy+TAB_H-2}, {tx+tw-8, cy+TAB_H-2}, DBGP_BLUE) }
		col := is_active ? DBGP_BLUE : DBGP_SUBDUED
		rl.DrawTextEx(font, to_cstring(label), {tx+8, cy + (TAB_H-ref.y)*0.5}, FONT_SIZE-1, CHAR_SPACING, col)
		if clicked && rl.CheckCollisionPointRec(mouse, rect) { d.active_tab = i }
		tx += tw + 4
	}
	rl.DrawLineV({0, cy + TAB_H - 1}, {sw, cy + TAB_H - 1}, DBGP_BORDER)
	cy += TAB_H

	if d.active_tab == 1 {
		_debug_panel_draw_console(d, m, font, ref, 0, cy, sw, py + DEBUG_PANEL_H - cy)
	} else {
		_debug_panel_draw_vars(e, d, m, font, ref, 0, cy, sw, py + DEBUG_PANEL_H - cy, mouse, clicked)
	}
}

_debug_panel_draw_console :: proc(d: ^Debug_Panel, m: ^dbg.Debug_Manager, font: rl.Font, ref: rl.Vector2, ox, oy, ow, oh: f32) {
	lines := dbg.manager_get_console(m)
	LINE_H :: f32(18)
	n_vis := int(oh / LINE_H)
	if d.console_scroll > max(0, len(lines)-n_vis) { d.console_scroll = max(0, len(lines)-n_vis) }
	for vi in 0..<n_vis {
		li := d.console_scroll + vi
		if li >= len(lines) { break }
		l := lines[li]
		col := DBGP_TEXT
		switch l.category {
		case "stderr", "important": col = DBGP_RED
		case "console": col = DBGP_SUBDUED
		}
		ly := oy + f32(vi)*LINE_H
		dlg_text(font, l.text, ox+8, ly, FONT_SIZE-2, CHAR_SPACING, col, ox+ow-8, 4)
	}
	if len(lines) == 0 {
		rl.DrawTextEx(font, "(no output yet)", {ox+8, oy+4}, FONT_SIZE-2, CHAR_SPACING, DBGP_SUBDUED)
	}
}

_debug_panel_draw_vars :: proc(e: ^Editor, d: ^Debug_Panel, m: ^dbg.Debug_Manager, font: rl.Font, ref: rl.Vector2, ox, oy, ow, oh: f32, mouse: rl.Vector2, clicked: bool) {
	STACK_W :: f32(280)

	// ── Evaluate input (top strip) ───────────────────────────────
	INPUT_H :: f32(30)
	rl.DrawRectangleV({ox, oy}, {ow, INPUT_H}, DBGP_HDR_BG)
	rl.DrawLineV({ox, oy+INPUT_H-1}, {ox+ow, oy+INPUT_H-1}, DBGP_BORDER)
	lbl := to_cstring("Evaluate: ")
	lbl_w := rl.MeasureTextEx(font, lbl, FONT_SIZE-1, CHAR_SPACING).x
	rl.DrawTextEx(font, lbl, {ox+8, oy + (INPUT_H-ref.y)*0.5}, FONT_SIZE-1, CHAR_SPACING, DBGP_BLUE)
	expr_s := string(d.expr_buf[:])
	text_x := ox + 8 + lbl_w
	dlg_text(font, expr_s if expr_s != "" else "type expression, Ctrl+Space to complete",
		text_x, oy + (INPUT_H-ref.y)*0.5, FONT_SIZE-1, CHAR_SPACING,
		expr_s != "" ? DBGP_TEXT : DBGP_SUBDUED, ox+ow-8, 4)
	if expr_s != "" {
		ew := rl.MeasureTextEx(font, to_cstring(expr_s), FONT_SIZE-1, CHAR_SPACING).x
		rl.DrawRectangleV({text_x + ew, oy + (INPUT_H-ref.y)*0.5}, {2, ref.y}, DBGP_BLUE)
	}

	// Result, right-aligned on the same strip if evaluated
	if d.result_shown {
		res := m.eval_result
		if m.eval_pending {
			rl.DrawTextEx(font, "evaluating...", {ox+ow-120, oy + (INPUT_H-ref.y)*0.5}, FONT_SIZE-2, CHAR_SPACING, DBGP_SUBDUED)
		} else {
			res_col := res.ok ? DBGP_GREEN : DBGP_RED
			res_w := rl.MeasureTextEx(font, to_cstring(res.result), FONT_SIZE-2, CHAR_SPACING).x
			rl.DrawTextEx(font, to_cstring(res.result), {ox+ow-res_w-10, oy + (INPUT_H-ref.y)*0.5}, FONT_SIZE-2, CHAR_SPACING, res_col)
		}
	}

	body_top := oy + INPUT_H

	// ── Call stack (left) ─────────────────────────────────────────
	rl.DrawLineV({ox+STACK_W, body_top}, {ox+STACK_W, oy+oh}, DBGP_BORDER)
	FRAME_H :: f32(20)
	frames := dbg.manager_get_frames(m)
	n_vis := int((oy+oh-body_top) / FRAME_H)
	if len(frames) == 0 {
		msg := dbg.manager_get_state(m) == .Idle ? "not connected" : "running..."
		rl.DrawTextEx(font, to_cstring(msg), {ox+8, body_top+4}, FONT_SIZE-2, CHAR_SPACING, DBGP_SUBDUED)
	} else {
		if d.frame_scroll >= len(frames) { d.frame_scroll = max(0, len(frames)-1) }
		for vi in 0..<n_vis {
			fi := d.frame_scroll + vi
			if fi >= len(frames) { break }
			f := frames[fi]
			fy := body_top + f32(vi)*FRAME_H
			rect := rl.Rectangle{ox, fy, STACK_W, FRAME_H}
			is_active := fi == m.active_frame
			if is_active {
				rl.DrawRectangleV({ox, fy}, {STACK_W, FRAME_H}, DBGP_SEL)
				rl.DrawRectangleV({ox, fy}, {3, FRAME_H}, DBGP_YELLOW)
			}
			ty := fy + (FRAME_H-ref.y)*0.5
			num_s := fmt.tprintf("#%d", fi)
			rl.DrawTextEx(font, to_cstring(num_s), {ox+6, ty}, FONT_SIZE-3, CHAR_SPACING, DBGP_SUBDUED)
			num_w := rl.MeasureTextEx(font, to_cstring(num_s), FONT_SIZE-3, CHAR_SPACING).x
			name_col := is_active ? DBGP_BLUE : DBGP_TEXT
			has_src := f.source != "" && f.line > 0
			label := has_src ? fmt.tprintf("%s:%d, %s", f.name, f.line, _strip_ext(path_basename(f.source))) : f.name
			dlg_text(font, label, ox+6+num_w+6, ty, FONT_SIZE-2, CHAR_SPACING, name_col, ox+STACK_W-6, 2)
			hovered := rl.CheckCollisionPointRec(mouse, rect)
			if hovered && has_src { rl.DrawRectangleLinesEx(rect, 1, DBGP_BORDER) }
			if clicked && hovered {
				dbg.manager_set_active_frame(m, fi)
				_debug_panel_jump_to_frame(e, f)
			}
		}
	}

	// ── Variables (right) ──────────────────────────────────────────
	vx := ox + STACK_W + 10
	vars := dbg.manager_get_variables(m)
	VAR_H :: f32(20)
	n_var_vis := int((oy+oh-body_top) / VAR_H)
	if len(vars) == 0 {
		msg := dbg.manager_get_state(m) == .Paused ? "no locals in scope" : "not paused"
		rl.DrawTextEx(font, to_cstring(msg), {vx, body_top+4}, FONT_SIZE-2, CHAR_SPACING, DBGP_SUBDUED)
	} else {
		if d.var_scroll > max(0, len(vars)-n_var_vis) { d.var_scroll = max(0, len(vars)-n_var_vis) }
		for vi in 0..<n_var_vis {
			vidx := d.var_scroll + vi
			if vidx >= len(vars) { break }
			v := vars[vidx]
			vy := body_top + f32(vi)*VAR_H
			ty := vy + (VAR_H-ref.y)*0.5
			name_w := rl.MeasureTextEx(font, to_cstring(v.name), FONT_SIZE-2, CHAR_SPACING).x
			rl.DrawTextEx(font, to_cstring(v.name), {vx, ty}, FONT_SIZE-2, CHAR_SPACING, DBGP_BLUE)
			rl.DrawTextEx(font, "=", {vx+name_w+6, ty}, FONT_SIZE-2, CHAR_SPACING, DBGP_SUBDUED)
			dlg_text(font, v.value, vx+name_w+20, ty, FONT_SIZE-2, CHAR_SPACING, DBGP_TEXT, ox+ow-8, 2)
		}
	}

	// ── Suggestion popup ────────────────────────────────────────────
	if d.suggest_open {
		if c := _eval_suggest_client(e, d); c != nil {
			_eval_draw_suggest_popup(c, font, ox, body_top, ow)
		}
	}
}

_eval_draw_suggest_popup :: proc(c: ^lsp.Language_Client, font: rl.Font, px, top_y, panel_w: f32) {
	items, filtered := lsp.completion_filtered_items(c)
	if len(filtered) == 0 { return }

	sel := c.completion.session.selected
	n_visible := min(MAX_VISIBLE_ITEMS, len(filtered))
	scroll := 0
	if sel >= n_visible { scroll = sel - n_visible + 1 }

	popup_w := min(panel_w - 20, WIDGET_W)
	popup_h := f32(n_visible) * ITEM_H + 4
	rl.DrawRectangleV({px+10, top_y}, {popup_w, popup_h}, SUGGEST_BG)
	rl.DrawRectangleLinesEx({px+10, top_y, popup_w, popup_h}, 1, SUGGEST_BORDER)

	for i := 0; i < n_visible; i += 1 {
		idx := scroll + i
		if idx >= len(filtered) { break }
		item_i := filtered[idx]
		if item_i >= len(items) { break }
		item := &items[item_i]
		item_y := top_y + 2 + f32(i) * ITEM_H
		is_sel := idx == sel

		if is_sel {
			rl.DrawRectangleV({px+11, item_y}, {popup_w - 2, ITEM_H}, SUGGEST_SEL)
			rl.DrawLineV({px+11, item_y}, {px+11, item_y + ITEM_H}, SUGGEST_SEL_BDR)
		}

		_draw_kind_badge(font, item.kind, px+14, item_y + 3)

		detail: string
		detail_w: f32 = 0
		if item.detail != "" {
			detail = _truncate_str(item.detail, font, 140, context.temp_allocator)
			detail_w = rl.MeasureTextEx(font, to_cstring(detail), FONT_SIZE - 2, 0).x
		}

		label_col := SUGGEST_TEXT
		if item.deprecated { label_col = SUGGEST_DETAIL }
		label_x := px + 14 + KIND_ICON_W + 8
		detail_gap := detail_w + 14 if detail_w > 0 else 0
		max_label_w := popup_w - KIND_ICON_W - 12 - detail_gap
		label := _truncate_str(item.label, font, max_label_w, context.temp_allocator)
		rl.DrawTextEx(font, to_cstring(label), {label_x, item_y + 3}, FONT_SIZE, 0, label_col)

		if detail != "" {
			rl.DrawTextEx(font, to_cstring(detail), {px + 10 + popup_w - detail_w - 6, item_y + 4}, FONT_SIZE - 2, 0, SUGGEST_DETAIL)
		}
	}
}
