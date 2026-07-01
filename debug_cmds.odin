package editor

// Debug palette commands — registered into the main command palette (Ctrl+P).
// Type "debug" to filter all of them.

import dbg "./debug"

// Called from palette_init to register all debug commands.
register_debug_commands :: proc(p: ^Palette) {
	append(&p.cmds,
		Command{"Debug: Start",                   "Launch debug session for current file",          cmd_dbg_start},
		Command{"Debug: Stop",                    "Stop current debug session",                     cmd_dbg_stop},
		Command{"Debug: Restart",                 "Restart current debug session",                  cmd_dbg_restart},
		Command{"Debug: Continue",                "Resume execution (F5)",                          cmd_dbg_continue},
		Command{"Debug: Pause",                   "Pause running program",                          cmd_dbg_pause},
		Command{"Debug: Step Over",               "Execute next line without entering calls (F10)", cmd_dbg_step_over},
		Command{"Debug: Step Into",               "Step into function call (F11)",                  cmd_dbg_step_into},
		Command{"Debug: Step Out",                "Step out of current function (Shift+F11)",       cmd_dbg_step_out},
		Command{"Debug: Toggle Breakpoint",       "Add or remove breakpoint at current line (F9)",  cmd_dbg_toggle_bp},
		Command{"Debug: Remove All Breakpoints",  "Clear every breakpoint",                         cmd_dbg_clear_bp},
		Command{"Debug: Evaluate Expression",     "Evaluate selected text or type expression",      cmd_dbg_evaluate},
		Command{"Debug: Attach Remote...",        "Connect to a remote DAP adapter via TCP",        cmd_dbg_attach_remote},
	)
}

cmd_dbg_start :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	dbg.session_start(&e.debug_mgr)
}

cmd_dbg_stop :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	dbg.session_stop(&e.debug_mgr)
}

cmd_dbg_restart :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	dbg.session_restart(&e.debug_mgr)
}

cmd_dbg_continue :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	dbg.debug_continue(&e.debug_mgr)
}

cmd_dbg_pause :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	dbg.debug_pause(&e.debug_mgr)
}

cmd_dbg_step_over :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	dbg.debug_next(&e.debug_mgr)
}

cmd_dbg_step_into :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	dbg.debug_step_in(&e.debug_mgr)
}

cmd_dbg_step_out :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	dbg.debug_step_out(&e.debug_mgr)
}

cmd_dbg_toggle_bp :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	pn := active_pane(e)
	if pn.filename != "" {
		line, _ := buffer_pos_to_line_col(&pn.buf, pn.cursor)
		dbg.bp_toggle(&e.debug_mgr, pn.filename, line + 1)
	}
}

cmd_dbg_clear_bp :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	dbg.bp_clear_all(&e.debug_mgr)
}

cmd_dbg_evaluate :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	pn := active_pane(e)
	sel := _get_selected_text(pn)
	debug_eval_open(&e.debug_eval, sel)
}

cmd_dbg_attach_remote :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	debug_attach_open(&e.debug_attach)
}

// ---------------------------------------------------------------------------
// Helper: get selected text from active pane (gap-buffer aware)
// ---------------------------------------------------------------------------

_get_selected_text :: proc(p: ^Pane) -> string {
	if !has_selection(p) { return "" }
	lo, hi := sel_lo(p), sel_hi(p)
	if hi <= lo { return "" }
	full := buffer_to_string(&p.buf, context.temp_allocator)
	if lo >= len(full) || hi > len(full) { return "" }
	return full[lo:hi]
}
