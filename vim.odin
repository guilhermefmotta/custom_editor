package editor

import "core:strings"
import rl "vendor:raylib"

// ---------------------------------------------------------------------------
// Vim keymap mode — state + full Normal/Insert/Visual/Replace dispatch.
//
// INVARIANT: every Vim keystroke must funnel through vim_dispatch_normal_char
// or vim_dispatch_visual_char (both call _vim_pre_dispatch first) so
// dot-repeat (`.`) and macro recording (q/@) can capture it via
// recording_keys/macros. A key handled anywhere else silently breaks both
// features for that key. vim_handle_insert/vim_handle_replace record their
// own keys directly for the same reason (they don't go through those two
// dispatch points, since Insert/Replace aren't "commands").
//
// No auto-pair-bracket insertion in Vim Insert/Replace mode — deliberate:
// real Vim doesn't auto-pair by default either, and it lets Insert-mode
// typing be recorded/replayed as plain runes without the extra state a
// shared handle_character_input call would require untangling from Raylib's
// destructive GetCharPressed() queue.
// ---------------------------------------------------------------------------

Vim_Mode :: enum { Normal, Insert, Visual, Visual_Line, Replace }

// 3-way classifier for w/b/e word motions (foo.bar() -> foo | . | bar | ( | )).
// W/B/E use a separate blank-vs-non-blank 2-way split (_vim_class_big in
// vim_motions.odin).
Vim_Char_Class :: enum { Space, Punct, Word }

Vim_Register :: struct {
	data:     [dynamic]u8,
	linewise: bool,
}

// A single recorded keystroke — enough to replay it via vim_dispatch_normal_char
// (rune_val) or vim_replay_insert_key/vim_replay_replace_key (key for
// Escape/Backspace/Enter, which aren't runes).
Vim_Key_Event :: struct {
	key:      rl.KeyboardKey,
	rune_val: rune,
}

Vim_Insert_Pos :: enum { Before, After, Line_Start, Line_End }

Vim_State :: struct {
	mode:          Vim_Mode,
	pending_count: int,
	pending_op:    rune,   // 0, or 'd'/'c'/'y'/'>'/'<' awaiting a motion/text-object
	op_count:      int,    // count typed before the operator (the "2" in 2dw)
	register_sel:  u8,     // 0 = unnamed register, else a-z after a leading "
	registers:     map[u8]Vim_Register,
	last_find:     struct { ch: rune, kind: u8, valid: bool }, // f/F/t/T target, for ;/,

	awaiting_register:  bool,
	awaiting_replace:   bool,
	awaiting_find:      u8,   // 0, or 'f'/'F'/'t'/'T'
	awaiting_g:         bool, // saw a leading 'g'
	awaiting_obj_kind:  u8,   // 0, or 'i'/'a' — pending_op set, waiting for the object char
	awaiting_macro_reg: bool, // saw 'q', waiting for the register to record into
	awaiting_at:        bool, // saw '@', waiting for the register to play (or '@' for last)

	dot_keys:       [dynamic]Vim_Key_Event, // last completed change, replayed by `.`
	recording_keys: [dynamic]Vim_Key_Event, // rolling buffer for the change currently being built
	replaying:      bool,                   // true while replaying `.`/`@` — suppresses re-recording

	macros:          map[u8][dynamic]Vim_Key_Event,
	macro_recording: bool,
	macro_reg:       u8,
	macro_last:      u8,
	macro_depth:     int, // guards against a macro invoking itself into a runaway loop
}

vim_init :: proc() -> Vim_State {
	vs: Vim_State
	vs.registers      = make(map[u8]Vim_Register)
	vs.dot_keys       = make([dynamic]Vim_Key_Event)
	vs.recording_keys = make([dynamic]Vim_Key_Event)
	vs.macros         = make(map[u8][dynamic]Vim_Key_Event)
	return vs
}

vim_destroy :: proc(vs: ^Vim_State) {
	for _, r in vs.registers { delete(r.data) }
	delete(vs.registers)
	delete(vs.dot_keys)
	delete(vs.recording_keys)
	for _, m in vs.macros { delete(m) }
	delete(vs.macros)
}

// vim_reset: called by keymap_switch_reset when leaving Vim mode (or
// switching into it fresh) so no half-finished operator/macro/recording
// state survives a mode switch.
vim_reset :: proc(vs: ^Vim_State) {
	vs.mode = .Normal
	_vim_clear_pending(vs)
	vs.awaiting_macro_reg = false
	vs.awaiting_at        = false
	clear(&vs.recording_keys)
	vs.macro_recording = false
}

_vim_clear_pending :: proc(vs: ^Vim_State) {
	vs.pending_count      = 0
	vs.pending_op         = 0
	vs.op_count           = 0
	vs.register_sel       = 0
	vs.awaiting_g         = false
	vs.awaiting_find      = 0
	vs.awaiting_obj_kind  = 0
	vs.awaiting_register  = false
	vs.awaiting_replace   = false
}

_vim_mid_sequence :: proc(vs: ^Vim_State) -> bool {
	return vs.pending_op != 0 || vs.awaiting_g || vs.awaiting_find != 0 ||
		vs.awaiting_register || vs.awaiting_replace || vs.awaiting_obj_kind != 0 ||
		vs.awaiting_macro_reg || vs.awaiting_at || vs.pending_count != 0
}

_vim_is_reg_letter :: proc(ch: rune) -> bool {
	return ch >= 'a' && ch <= 'z'
}

_vim_take_count :: proc(vs: ^Vim_State) -> (count: int, had: bool) {
	had = vs.pending_count != 0
	count = had ? vs.pending_count : 1
	vs.pending_count = 0
	return
}

// _vim_finalize_change: called when a mutating command (or an Insert/Replace
// session) completes — snapshots recording_keys into dot_keys for `.` to
// replay later. Never called for pure motions or for commands that only
// enter Insert/Replace (those call _vim_clear_pending instead and keep
// recording_keys alive through the insert session).
_vim_finalize_change :: proc(vs: ^Vim_State) {
	_vim_clear_pending(vs)
	if vs.replaying { return }
	old := vs.dot_keys
	vs.dot_keys = make([dynamic]Vim_Key_Event, len(vs.recording_keys))
	copy(vs.dot_keys[:], vs.recording_keys[:])
	delete(old)
}

_vim_pre_dispatch :: proc(vs: ^Vim_State, ch: rune, mid_sequence: bool) {
	if vs.replaying { return }
	if !mid_sequence { clear(&vs.recording_keys) }
	append(&vs.recording_keys, Vim_Key_Event{rune_val = ch})
	if vs.macro_recording { _vim_macro_append(vs, Vim_Key_Event{rune_val = ch}) }
}

_vim_macro_append :: proc(vs: ^Vim_State, k: Vim_Key_Event) {
	buf := vs.macros[vs.macro_reg]
	append(&buf, k)
	vs.macros[vs.macro_reg] = buf
}

// ---------------------------------------------------------------------------
// Top-level dispatch
// ---------------------------------------------------------------------------

vim_handle_input :: proc(e: ^Editor, p: ^Pane) {
	vs := &e.vim
	switch vs.mode {
	case .Insert:              vim_handle_insert(e, p)
	case .Replace:              vim_handle_replace(e, p)
	case .Normal:               vim_handle_normal(e, p)
	case .Visual, .Visual_Line: vim_handle_visual(e, p)
	}
}

vim_handle_normal :: proc(e: ^Editor, p: ^Pane) {
	vs := &e.vim
	if rl.IsKeyPressed(.ESCAPE) {
		_vim_clear_pending(vs)
		mc_clear(p)
		return
	}
	if ctrl() && rl.IsKeyPressed(.R) { pane_redo(p); return }

	if key_rep(.LEFT)  { p.cursor = max(0, p.cursor-1); p.sel_anchor = p.cursor }
	if key_rep(.RIGHT) { p.cursor = min(buffer_len(&p.buf), p.cursor+1); p.sel_anchor = p.cursor }
	if key_rep(.DOWN)  { move_down(p, false) }
	if key_rep(.UP)    { move_up(p, false) }

	// hjkl are the primary vim navigation keys and get held down constantly —
	// drive them from the editor's tuned key_rep timing (same as every other
	// held-key repeat in the app) instead of raw OS text-repeat, which is
	// slower to start and inconsistent across platforms. They still go
	// through the full grammar (counts, pending operators, ...) via the same
	// vim_dispatch_normal_char the character queue below uses — only the
	// trigger changes, so 'dj'/'3h'/etc are unaffected. The char-queue loop
	// below skips these four so a held key never double-fires.
	if key_rep(.H) { vim_dispatch_normal_char(e, p, 'h') }
	if key_rep(.J) { vim_dispatch_normal_char(e, p, 'j') }
	if key_rep(.K) { vim_dispatch_normal_char(e, p, 'k') }
	if key_rep(.L) { vim_dispatch_normal_char(e, p, 'l') }

	ch := rl.GetCharPressed()
	for ch != 0 {
		if ch != 'h' && ch != 'j' && ch != 'k' && ch != 'l' {
			vim_dispatch_normal_char(e, p, ch)
		}
		ch = rl.GetCharPressed()
	}
}

// ---------------------------------------------------------------------------
// Normal mode — the full counts/operators/motions/text-objects/registers
// grammar, plus macro record/play and dot-repeat entry points.
// ---------------------------------------------------------------------------

vim_dispatch_normal_char :: proc(e: ^Editor, p: ^Pane, ch: rune) {
	vs := &e.vim
	mid := _vim_mid_sequence(vs)

	if vs.macro_recording && !mid && ch == 'q' {
		vs.macro_recording = false
		return
	}
	_vim_pre_dispatch(vs, ch, mid)

	if vs.awaiting_macro_reg {
		vs.awaiting_macro_reg = false
		if _vim_is_reg_letter(ch) {
			vs.macro_recording = true
			vs.macro_reg = u8(ch)
			buf, ok := vs.macros[u8(ch)]
			if ok { clear(&buf) } else { buf = make([dynamic]Vim_Key_Event) }
			vs.macros[u8(ch)] = buf
		}
		return
	}
	if vs.awaiting_at {
		vs.awaiting_at = false
		count, _ := _vim_take_count(vs)
		reg := u8(ch)
		if ch == '@' { reg = vs.macro_last }
		if reg != 0 && _vim_is_reg_letter(rune(reg)) {
			vs.macro_last = reg
			vim_play_macro(e, p, vs, reg, count)
		}
		return
	}
	if vs.awaiting_register {
		vs.awaiting_register = false
		if _vim_is_reg_letter(ch) { vs.register_sel = u8(ch) }
		return
	}
	if vs.awaiting_replace {
		vs.awaiting_replace = false
		count, _ := _vim_take_count(vs)
		vim_replace_char(p, ch, count)
		_vim_finalize_change(vs)
		return
	}
	if vs.awaiting_find != 0 {
		kind := vs.awaiting_find
		vs.awaiting_find = 0
		count, _ := _vim_take_count(vs)
		vs.last_find = {ch, kind, true}
		_vim_do_find(e, p, vs, ch, kind, count)
		return
	}
	if vs.awaiting_g {
		vs.awaiting_g = false
		if ch == 'g' {
			count, had := _vim_take_count(vs)
			target_line := had ? count-1 : 0
			_vim_finish_motion(e, p, vs, vim_goto_line(p, target_line), false, true)
		} else {
			_vim_clear_pending(vs)
		}
		return
	}

	if vs.pending_op != 0 {
		if vs.awaiting_obj_kind != 0 {
			kind := vs.awaiting_obj_kind
			vs.awaiting_obj_kind = 0
			lo, hi, ok := vim_text_object(p, kind, ch)
			if ok { vim_do_operator(e, p, vs, lo, hi, false) } else { _vim_clear_pending(vs) }
			return
		}
		if ch == 'i' || ch == 'a' {
			vs.awaiting_obj_kind = u8(ch)
			return
		}
		if ch == vs.pending_op {
			count, _ := _vim_take_count(vs)
			total := max(1, vs.op_count) * count
			line, _ := buffer_pos_to_line_col(&p.buf, p.cursor)
			tl := min(line+total-1, buffer_line_count(&p.buf)-1)
			target := buffer_line_start(&p.buf, tl)
			lo, hi := _vim_op_range(p, p.cursor, target, false, true)
			vim_do_operator(e, p, vs, lo, hi, true)
			return
		}
		if !_vim_dispatch_motion(e, p, vs, ch) {
			_vim_clear_pending(vs)
		}
		return
	}

	vim_dispatch_command(e, p, vs, ch)
}

vim_dispatch_command :: proc(e: ^Editor, p: ^Pane, vs: ^Vim_State, ch: rune) {
	if ch >= '1' && ch <= '9' || (ch == '0' && vs.pending_count > 0) {
		vs.pending_count = vs.pending_count*10 + int(ch-'0')
		return
	}
	if ch == '"' { vs.awaiting_register = true; return }
	if ch == '.' { vim_repeat_last(e, p, vs); return }
	if ch == '@' { vs.awaiting_at = true; return }
	if ch == 'q' { vs.awaiting_macro_reg = true; return }
	if ch == 'r' { vs.awaiting_replace = true; return }

	had := vs.pending_count != 0
	count := had ? vs.pending_count : 1

	switch ch {
	case 'd', 'c', 'y', '>', '<':
		vs.op_count      = count
		vs.pending_count = 0
		vs.pending_op    = ch
		return

	case 'i': vs.pending_count = 0; vim_enter_insert(p, .Before);      vs.mode = .Insert; _vim_clear_pending(vs)
	case 'a': vs.pending_count = 0; vim_enter_insert(p, .After);       vs.mode = .Insert; _vim_clear_pending(vs)
	case 'I': vs.pending_count = 0; vim_enter_insert(p, .Line_Start);  vs.mode = .Insert; _vim_clear_pending(vs)
	case 'A': vs.pending_count = 0; vim_enter_insert(p, .Line_End);    vs.mode = .Insert; _vim_clear_pending(vs)
	case 'o': vs.pending_count = 0; vim_open_line(p, true);            vs.mode = .Insert; _vim_clear_pending(vs)
	case 'O': vs.pending_count = 0; vim_open_line(p, false);           vs.mode = .Insert; _vim_clear_pending(vs)
	case 'R': vs.pending_count = 0; vs.mode = .Replace; _vim_clear_pending(vs)

	case 'v': vs.pending_count = 0; vs.mode = .Visual;      p.sel_anchor = p.cursor; _vim_clear_pending(vs)
	case 'V': vs.pending_count = 0; vs.mode = .Visual_Line; p.sel_anchor = p.cursor; _vim_clear_pending(vs)

	case 'x': vs.pending_count = 0; vim_delete_chars(p, vs, count, true);  _vim_finalize_change(vs)
	case 'X': vs.pending_count = 0; vim_delete_chars(p, vs, count, false); _vim_finalize_change(vs)

	case 'D':
		vs.pending_count = 0
		line, _ := buffer_pos_to_line_col(&p.buf, p.cursor)
		hi := buffer_line_start(&p.buf, line) + buffer_line_length(&p.buf, line)
		if hi > p.cursor {
			vim_yank_range(p, vs, p.cursor, hi, false)
			_vim_delete_range(p, p.cursor, hi)
			p.sel_anchor = p.cursor
		}
		_vim_finalize_change(vs)

	case 'C':
		vs.pending_count = 0
		line, _ := buffer_pos_to_line_col(&p.buf, p.cursor)
		hi := buffer_line_start(&p.buf, line) + buffer_line_length(&p.buf, line)
		if hi > p.cursor {
			vim_yank_range(p, vs, p.cursor, hi, false)
			_vim_delete_range(p, p.cursor, hi)
			p.sel_anchor = p.cursor
		}
		vs.mode = .Insert
		_vim_clear_pending(vs)

	case 'Y':
		vs.pending_count = 0
		line, _ := buffer_pos_to_line_col(&p.buf, p.cursor)
		tl := min(line+count-1, buffer_line_count(&p.buf)-1)
		target := buffer_line_start(&p.buf, tl)
		lo, hi := _vim_op_range(p, p.cursor, target, false, true)
		vim_yank_range(p, vs, lo, hi, true)
		_vim_clear_pending(vs)

	case 'p': vs.pending_count = 0; vim_paste(p, vs, true);  _vim_finalize_change(vs)
	case 'P': vs.pending_count = 0; vim_paste(p, vs, false); _vim_finalize_change(vs)

	case '~': vs.pending_count = 0; vim_toggle_case(p, count); _vim_finalize_change(vs)
	case 'u': vs.pending_count = 0; pane_undo(p); _vim_clear_pending(vs)
	case 'J': vs.pending_count = 0; vim_join_lines(p, count); _vim_finalize_change(vs)

	case:
		if !_vim_dispatch_motion(e, p, vs, ch) {
			vs.pending_count = 0
		}
	}
}

// ---------------------------------------------------------------------------
// Motion dispatch — shared between plain Normal-mode movement (pending_op==0)
// and operator targets (pending_op!=0), via _vim_finish_motion.
// ---------------------------------------------------------------------------

_vim_dispatch_motion :: proc(e: ^Editor, p: ^Pane, vs: ^Vim_State, ch: rune) -> bool {
	had := vs.pending_count != 0
	count := had ? vs.pending_count : 1
	vs.pending_count = 0

	switch ch {
	case 'h': _vim_finish_motion(e, p, vs, max(0, p.cursor-count), false, false)
	case 'l':
		n := buffer_len(&p.buf)
		_vim_finish_motion(e, p, vs, min(n, p.cursor+count), false, false)
	case 'j':
		line, col := buffer_pos_to_line_col(&p.buf, p.cursor)
		tl := min(line+count, buffer_line_count(&p.buf)-1)
		_vim_finish_motion(e, p, vs, buffer_line_start(&p.buf, tl)+min(col, buffer_line_length(&p.buf, tl)), false, true)
	case 'k':
		line, col := buffer_pos_to_line_col(&p.buf, p.cursor)
		tl := max(line-count, 0)
		_vim_finish_motion(e, p, vs, buffer_line_start(&p.buf, tl)+min(col, buffer_line_length(&p.buf, tl)), false, true)
	case 'w': _vim_finish_motion(e, p, vs, vim_repeat_word_fwd(p, p.cursor, false, count), false, false)
	case 'W': _vim_finish_motion(e, p, vs, vim_repeat_word_fwd(p, p.cursor, true, count), false, false)
	case 'b': _vim_finish_motion(e, p, vs, vim_repeat_word_back(p, p.cursor, false, count), false, false)
	case 'B': _vim_finish_motion(e, p, vs, vim_repeat_word_back(p, p.cursor, true, count), false, false)
	case 'e': _vim_finish_motion(e, p, vs, vim_repeat_word_end(p, p.cursor, false, count), true, false)
	case 'E': _vim_finish_motion(e, p, vs, vim_repeat_word_end(p, p.cursor, true, count), true, false)
	case '0':
		line, _ := buffer_pos_to_line_col(&p.buf, p.cursor)
		_vim_finish_motion(e, p, vs, buffer_line_start(&p.buf, line), false, false)
	case '^':
		line, _ := buffer_pos_to_line_col(&p.buf, p.cursor)
		_vim_finish_motion(e, p, vs, vim_line_first_nonblank(p, line), false, false)
	case '$':
		line, _ := buffer_pos_to_line_col(&p.buf, p.cursor)
		tl := min(line+count-1, buffer_line_count(&p.buf)-1)
		_vim_finish_motion(e, p, vs, buffer_line_start(&p.buf, tl)+buffer_line_length(&p.buf, tl), true, false)
	case 'G':
		target_line := had ? count-1 : buffer_line_count(&p.buf)-1
		_vim_finish_motion(e, p, vs, vim_goto_line(p, target_line), false, true)
	case 'g':
		vs.pending_count = had ? count : 0
		vs.awaiting_g = true
	case 'f', 'F', 't', 'T':
		vs.pending_count = had ? count : 0
		vs.awaiting_find = u8(ch)
	case '%':
		pos, ok := vim_matching_bracket(p, p.cursor)
		if ok { _vim_finish_motion(e, p, vs, pos, true, false) } else { _vim_clear_pending(vs) }
	case ';':
		if vs.last_find.valid { _vim_do_find(e, p, vs, vs.last_find.ch, vs.last_find.kind, count) } else { _vim_clear_pending(vs) }
	case ',':
		if vs.last_find.valid {
			_vim_do_find(e, p, vs, vs.last_find.ch, _vim_invert_find_kind(vs.last_find.kind), count)
		} else { _vim_clear_pending(vs) }
	case:
		vs.pending_count = had ? count : 0
		return false
	}
	return true
}

_vim_finish_motion :: proc(e: ^Editor, p: ^Pane, vs: ^Vim_State, target: int, inclusive: bool, linewise: bool) {
	if vs.pending_op != 0 {
		lo, hi := _vim_op_range(p, p.cursor, target, inclusive, linewise)
		vim_do_operator(e, p, vs, lo, hi, linewise)
	} else {
		p.cursor = target
		p.sel_anchor = p.cursor
		_vim_clear_pending(vs)
	}
}

_vim_op_range :: proc(p: ^Pane, orig, target: int, inclusive, linewise: bool) -> (lo, hi: int) {
	if linewise {
		l1, _ := buffer_pos_to_line_col(&p.buf, min(orig, target))
		l2, _ := buffer_pos_to_line_col(&p.buf, max(orig, target))
		lo = buffer_line_start(&p.buf, l1)
		total := buffer_line_count(&p.buf)
		if l2 < total-1 {
			hi = buffer_line_start(&p.buf, l2+1)
		} else {
			hi = buffer_len(&p.buf)
			if lo > 0 { lo -= 1 }
		}
		return
	}
	lo = min(orig, target)
	hi = max(orig, target)
	if inclusive { hi = min(hi+1, buffer_len(&p.buf)) }
	return
}

_vim_do_find :: proc(e: ^Editor, p: ^Pane, vs: ^Vim_State, ch: rune, kind: u8, count: int) {
	forward := kind == 'f' || kind == 't'
	till    := kind == 't' || kind == 'T'
	pos := p.cursor
	found := false
	for _ in 0..<count {
		np, ok := vim_find_char(p, pos, u8(ch), forward, till)
		if !ok { found = false; break }
		pos = np
		found = true
	}
	if found { _vim_finish_motion(e, p, vs, pos, true, false) } else { _vim_clear_pending(vs) }
}

_vim_invert_find_kind :: proc(kind: u8) -> u8 {
	switch kind {
	case 'f': return 'F'
	case 'F': return 'f'
	case 't': return 'T'
	case 'T': return 't'
	}
	return kind
}

_vim_line_of :: proc(p: ^Pane, pos: int) -> int {
	line, _ := buffer_pos_to_line_col(&p.buf, pos)
	return line
}

// ---------------------------------------------------------------------------
// Operators — d/c/y/>/< applied to an already-resolved [lo,hi) byte range
// (from a motion, a doubled-operator line count, or a text object).
// ---------------------------------------------------------------------------

vim_do_operator :: proc(e: ^Editor, p: ^Pane, vs: ^Vim_State, lo_in, hi_in: int, linewise_in: bool) {
	op := vs.pending_op
	lo, hi := lo_in, hi_in
	linewise := linewise_in || op == '>' || op == '<'
	if op == '>' || op == '<' {
		l1 := _vim_line_of(p, lo)
		l2 := _vim_line_of(p, max(lo, hi-1))
		lo = buffer_line_start(&p.buf, l1)
		total := buffer_line_count(&p.buf)
		hi = l2 < total-1 ? buffer_line_start(&p.buf, l2+1) : buffer_len(&p.buf)
	}
	if hi <= lo { _vim_clear_pending(vs); return }

	switch op {
	case 'y':
		vim_yank_range(p, vs, lo, hi, linewise)
		p.cursor = linewise ? vim_line_first_nonblank(p, _vim_line_of(p, lo)) : lo
		p.sel_anchor = p.cursor
		_vim_finalize_change(vs)
	case 'd':
		vim_yank_range(p, vs, lo, hi, linewise)
		_vim_delete_range(p, lo, hi)
		p.cursor = min(lo, max(0, buffer_len(&p.buf)-1))
		if linewise { p.cursor = vim_line_first_nonblank(p, _vim_line_of(p, p.cursor)) }
		p.sel_anchor = p.cursor
		_vim_finalize_change(vs)
	case 'c':
		vim_yank_range(p, vs, lo, hi, linewise)
		_vim_delete_range(p, lo, hi)
		p.cursor = min(lo, buffer_len(&p.buf))
		p.sel_anchor = p.cursor
		vs.mode = .Insert
		_vim_clear_pending(vs)
	case '>':
		p.sel_anchor = lo; p.cursor = hi
		do_indent_sel(p)
		p.cursor = vim_line_first_nonblank(p, _vim_line_of(p, lo))
		p.sel_anchor = p.cursor
		_vim_finalize_change(vs)
	case '<':
		p.sel_anchor = lo; p.cursor = hi
		do_dedent_sel(p)
		p.cursor = vim_line_first_nonblank(p, _vim_line_of(p, lo))
		p.sel_anchor = p.cursor
		_vim_finalize_change(vs)
	}
}

_vim_delete_range :: proc(p: ^Pane, lo, hi: int) {
	del := make([]u8, hi-lo, context.temp_allocator)
	for i in 0..<hi-lo { del[i] = buffer_get_byte(&p.buf, lo+i) }
	undo_push_delete(p, lo, del, false)
	undo_break(p)
	buffer_delete(&p.buf, lo, hi-lo)
	p.dirty = true
}

// ---------------------------------------------------------------------------
// Registers
// ---------------------------------------------------------------------------

vim_reg_set :: proc(vs: ^Vim_State, reg: u8, data: []u8, linewise: bool) {
	if old, ok := vs.registers[reg]; ok { delete(old.data) }
	d := make([dynamic]u8, len(data))
	copy(d[:], data)
	vs.registers[reg] = Vim_Register{data = d, linewise = linewise}
}

vim_yank_range :: proc(p: ^Pane, vs: ^Vim_State, lo, hi: int, linewise: bool) {
	data := make([]u8, hi-lo, context.temp_allocator)
	for i in 0..<hi-lo { data[i] = buffer_get_byte(&p.buf, lo+i) }
	vim_reg_set(vs, vs.register_sel, data, linewise)
}

vim_paste :: proc(p: ^Pane, vs: ^Vim_State, after: bool) {
	reg, ok := vs.registers[vs.register_sel]
	if !ok || len(reg.data) == 0 { return }
	if reg.linewise {
		line, _ := buffer_pos_to_line_col(&p.buf, p.cursor)
		total := buffer_line_count(&p.buf)
		payload := string(reg.data[:])
		if !strings.has_suffix(payload, "\n") {
			payload = strings.concatenate({payload, "\n"}, context.temp_allocator)
		}
		insert_pos: int
		content_pos: int
		if after {
			if line < total-1 {
				insert_pos = buffer_line_start(&p.buf, line+1)
				content_pos = insert_pos
			} else {
				insert_pos = buffer_len(&p.buf)
				payload = strings.concatenate({"\n", strings.trim_suffix(payload, "\n")}, context.temp_allocator)
				content_pos = insert_pos + 1
			}
		} else {
			insert_pos = buffer_line_start(&p.buf, line)
			content_pos = insert_pos
		}
		undo_push_insert(p, insert_pos, transmute([]u8)payload, false)
		undo_break(p)
		buffer_insert_string(&p.buf, insert_pos, payload)
		ln := _vim_line_of(p, content_pos)
		p.cursor = vim_line_first_nonblank(p, ln)
		p.sel_anchor = p.cursor
		p.dirty = true
	} else {
		pos := after ? min(p.cursor+1, buffer_len(&p.buf)) : p.cursor
		text := string(reg.data[:])
		undo_push_insert(p, pos, transmute([]u8)text, false)
		undo_break(p)
		buffer_insert_string(&p.buf, pos, text)
		p.cursor = max(pos, pos+len(text)-1)
		p.sel_anchor = p.cursor
		p.dirty = true
	}
}

// ---------------------------------------------------------------------------
// Single-key edits
// ---------------------------------------------------------------------------

vim_delete_chars :: proc(p: ^Pane, vs: ^Vim_State, count: int, forward: bool) {
	if forward {
		line, _ := buffer_pos_to_line_col(&p.buf, p.cursor)
		avail := buffer_line_start(&p.buf, line) + buffer_line_length(&p.buf, line) - p.cursor
		c := min(count, avail)
		if c <= 0 { return }
		del := make([]u8, c, context.temp_allocator)
		for i in 0..<c { del[i] = buffer_get_byte(&p.buf, p.cursor+i) }
		vim_reg_set(vs, vs.register_sel, del, false)
		undo_push_delete(p, p.cursor, del, false)
		undo_break(p)
		buffer_delete(&p.buf, p.cursor, c)
		p.sel_anchor = p.cursor
		p.dirty = true
	} else {
		c := min(count, p.cursor)
		if c <= 0 { return }
		start := p.cursor - c
		del := make([]u8, c, context.temp_allocator)
		for i in 0..<c { del[i] = buffer_get_byte(&p.buf, start+i) }
		vim_reg_set(vs, vs.register_sel, del, false)
		undo_push_delete(p, start, del, true)
		undo_break(p)
		buffer_delete(&p.buf, start, c)
		p.cursor = start
		p.sel_anchor = p.cursor
		p.dirty = true
	}
}

vim_toggle_case :: proc(p: ^Pane, count: int) {
	line, _ := buffer_pos_to_line_col(&p.buf, p.cursor)
	avail := buffer_line_start(&p.buf, line) + buffer_line_length(&p.buf, line) - p.cursor
	c := min(count, avail)
	if c <= 0 { return }
	old := make([]u8, c, context.temp_allocator)
	new_b := make([]u8, c, context.temp_allocator)
	for i in 0..<c {
		b := buffer_get_byte(&p.buf, p.cursor+i)
		old[i] = b
		switch {
		case b >= 'a' && b <= 'z': new_b[i] = b - 32
		case b >= 'A' && b <= 'Z': new_b[i] = b + 32
		case: new_b[i] = b
		}
	}
	undo_push_delete(p, p.cursor, old, false)
	buffer_delete(&p.buf, p.cursor, c)
	undo_push_insert(p, p.cursor, new_b, false)
	buffer_insert_string(&p.buf, p.cursor, string(new_b))
	p.cursor += c
	p.sel_anchor = p.cursor
	p.dirty = true
	undo_break(p)
}

vim_replace_char :: proc(p: ^Pane, ch: rune, count: int) {
	line, _ := buffer_pos_to_line_col(&p.buf, p.cursor)
	avail := buffer_line_start(&p.buf, line) + buffer_line_length(&p.buf, line) - p.cursor
	c := min(count, avail)
	if c <= 0 { return }
	start := p.cursor
	old := make([]u8, c, context.temp_allocator)
	for i in 0..<c { old[i] = buffer_get_byte(&p.buf, start+i) }
	undo_push_delete(p, start, old, false)
	buffer_delete(&p.buf, start, c)

	buf: [4]u8
	elen := rune_encode(ch, &buf)
	new_bytes := make([dynamic]u8, 0, elen*c, context.temp_allocator)
	for _ in 0..<c { for i in 0..<elen { append(&new_bytes, buf[i]) } }
	undo_push_insert(p, start, new_bytes[:], false)
	buffer_insert_string(&p.buf, start, string(new_bytes[:]))
	p.cursor = start + elen*(c-1)
	p.sel_anchor = p.cursor
	p.dirty = true
	undo_break(p)
}

vim_join_lines :: proc(p: ^Pane, times: int) {
	for _ in 0..<max(1, times) {
		line, _ := buffer_pos_to_line_col(&p.buf, p.cursor)
		total := buffer_line_count(&p.buf)
		if line >= total-1 { break }
		eol := buffer_line_start(&p.buf, line) + buffer_line_length(&p.buf, line)
		next_start := buffer_line_start(&p.buf, line+1)
		nlen := buffer_line_length(&p.buf, line+1)
		ws := 0
		for ws < nlen {
			b := buffer_get_byte(&p.buf, next_start+ws)
			if b != ' ' && b != '\t' { break }
			ws += 1
		}
		del_len := (next_start - eol) + ws
		if del_len <= 0 { continue }
		del := make([]u8, del_len, context.temp_allocator)
		for i in 0..<del_len { del[i] = buffer_get_byte(&p.buf, eol+i) }
		undo_push_delete(p, eol, del, false)
		buffer_delete(&p.buf, eol, del_len)

		blen := buffer_len(&p.buf)
		need_space := eol > 0 && eol < blen
		if need_space && buffer_get_byte(&p.buf, eol) == ')' { need_space = false }
		if need_space && buffer_get_byte(&p.buf, eol-1) == ' ' { need_space = false }
		if need_space {
			undo_push_insert(p, eol, []u8{' '}, false)
			buffer_insert_string(&p.buf, eol, " ")
		}
		undo_break(p)
		p.cursor = eol
		p.sel_anchor = p.cursor
	}
	p.dirty = true
}

vim_enter_insert :: proc(p: ^Pane, pos: Vim_Insert_Pos) {
	switch pos {
	case .Before:
		// cursor already at the insertion point
	case .After:
		n := buffer_len(&p.buf)
		if p.cursor < n && buffer_get_byte(&p.buf, p.cursor) != '\n' { p.cursor += 1 }
	case .Line_Start:
		line, _ := buffer_pos_to_line_col(&p.buf, p.cursor)
		p.cursor = vim_line_first_nonblank(p, line)
	case .Line_End:
		line, _ := buffer_pos_to_line_col(&p.buf, p.cursor)
		p.cursor = buffer_line_start(&p.buf, line) + buffer_line_length(&p.buf, line)
	}
	p.sel_anchor = p.cursor
}

vim_open_line :: proc(p: ^Pane, below: bool) {
	if below {
		line, _ := buffer_pos_to_line_col(&p.buf, p.cursor)
		p.cursor = buffer_line_start(&p.buf, line) + buffer_line_length(&p.buf, line)
		p.sel_anchor = p.cursor
		_auto_indent_enter(p)
		return
	}
	line, _ := buffer_pos_to_line_col(&p.buf, p.cursor)
	ls := buffer_line_start(&p.buf, line)
	blen := buffer_len(&p.buf)
	indent := 0
	for ls+indent < blen {
		b := buffer_get_byte(&p.buf, ls+indent)
		if b != ' ' && b != '\t' { break }
		indent += 1
	}
	text := make([dynamic]u8, 0, indent+1, context.temp_allocator)
	for i in 0..<indent { append(&text, buffer_get_byte(&p.buf, ls+i)) }
	append(&text, u8('\n'))
	undo_push_insert(p, ls, text[:], false)
	buffer_insert_string(&p.buf, ls, string(text[:]))
	p.cursor = ls + indent
	p.sel_anchor = p.cursor
	p.dirty = true
	undo_break(p)
}

// ---------------------------------------------------------------------------
// Insert / Replace mode — live, frame-by-frame; each records its own keys
// (see the file-level invariant comment).
// ---------------------------------------------------------------------------

vim_handle_insert :: proc(e: ^Editor, p: ^Pane) {
	vs := &e.vim
	if rl.IsKeyPressed(.ESCAPE) {
		append(&vs.recording_keys, Vim_Key_Event{key = .ESCAPE})
		_vim_finalize_change(vs)
		vs.mode = .Normal
		_, col := buffer_pos_to_line_col(&p.buf, p.cursor)
		if col > 0 { move_left(p, false) }
		undo_break(p)
		return
	}

	cursor_before := p.cursor
	text_changed := false

	if rl.IsKeyPressed(.BACKSPACE) || key_rep(.BACKSPACE) {
		append(&vs.recording_keys, Vim_Key_Event{key = .BACKSPACE})
		do_backspace(p)
		text_changed = true
	}
	if key_rep(.DELETE) {
		do_delete(p)
		text_changed = true
	}
	if rl.IsKeyPressed(.ENTER) || key_rep(.ENTER) || rl.IsKeyPressed(.KP_ENTER) {
		append(&vs.recording_keys, Vim_Key_Event{key = .ENTER})
		if has_selection(p) { undo_delete_sel(p) }
		_auto_indent_enter(p)
		undo_break(p)
		text_changed = true
	}
	if rl.IsKeyPressed(.TAB) {
		append(&vs.recording_keys, Vim_Key_Event{rune_val = '\t'})
		spaces := []u8{' ', ' ', ' ', ' '}
		undo_push_insert(p, p.cursor, spaces, false)
		buffer_insert_string(&p.buf, p.cursor, "    ")
		p.cursor += 4
		p.sel_anchor = p.cursor
		undo_break(p)
		text_changed = true
	}
	handle_cursor_movement(p)

	ch := rl.GetCharPressed()
	for ch != 0 {
		if ch >= 32 {
			append(&vs.recording_keys, Vim_Key_Event{rune_val = ch})
			buf: [4]u8
			n := rune_encode(ch, &buf)
			undo_push_insert(p, p.cursor, buf[:n], true)
			buffer_insert_string(&p.buf, p.cursor, string(buf[:n]))
			p.cursor += n
			p.sel_anchor = p.cursor
			p.dirty = true
			text_changed = true
		}
		ch = rl.GetCharPressed()
	}

	if p.cursor != cursor_before { lsp_on_cursor_moved(e, p) }
	if text_changed { lsp_on_text_changed(e, p) }
}

vim_handle_replace :: proc(e: ^Editor, p: ^Pane) {
	vs := &e.vim
	if rl.IsKeyPressed(.ESCAPE) {
		append(&vs.recording_keys, Vim_Key_Event{key = .ESCAPE})
		_vim_finalize_change(vs)
		vs.mode = .Normal
		undo_break(p)
		return
	}
	if rl.IsKeyPressed(.BACKSPACE) {
		append(&vs.recording_keys, Vim_Key_Event{key = .BACKSPACE})
		move_left(p, false) // simplification: doesn't restore the overwritten char
	}
	handle_cursor_movement(p)
	ch := rl.GetCharPressed()
	for ch != 0 {
		if ch >= 32 {
			append(&vs.recording_keys, Vim_Key_Event{rune_val = ch})
			_vim_replace_insert_one(p, ch)
		}
		ch = rl.GetCharPressed()
	}
}

_vim_replace_insert_one :: proc(p: ^Pane, ch: rune) {
	buf: [4]u8
	n := rune_encode(ch, &buf)
	blen := buffer_len(&p.buf)
	if p.cursor < blen && buffer_get_byte(&p.buf, p.cursor) != '\n' {
		old := make([]u8, 1, context.temp_allocator)
		old[0] = buffer_get_byte(&p.buf, p.cursor)
		undo_push_delete(p, p.cursor, old, false)
		buffer_delete(&p.buf, p.cursor, 1)
	}
	undo_push_insert(p, p.cursor, buf[:n], false)
	buffer_insert_string(&p.buf, p.cursor, string(buf[:n]))
	p.cursor += n
	p.sel_anchor = p.cursor
	p.dirty = true
	undo_break(p)
}

// ---------------------------------------------------------------------------
// Visual / Visual_Line mode
// ---------------------------------------------------------------------------

vim_handle_visual :: proc(e: ^Editor, p: ^Pane) {
	vs := &e.vim
	if rl.IsKeyPressed(.ESCAPE) {
		vs.mode = .Normal
		p.sel_anchor = p.cursor
		_vim_clear_pending(vs)
		return
	}
	if key_rep(.LEFT)  { move_left(p, true) }
	if key_rep(.RIGHT) { move_right(p, true) }
	if key_rep(.UP)    { move_up(p, true) }
	if key_rep(.DOWN)  { move_down(p, true) }

	// See the matching comment in vim_handle_normal — hjkl repeat via the
	// tuned key_rep timing, not raw OS text-repeat, so extending a selection
	// by holding the key feels as snappy as arrow-key selection.
	if key_rep(.H) { vim_dispatch_visual_char(e, p, vs, 'h') }
	if key_rep(.J) { vim_dispatch_visual_char(e, p, vs, 'j') }
	if key_rep(.K) { vim_dispatch_visual_char(e, p, vs, 'k') }
	if key_rep(.L) { vim_dispatch_visual_char(e, p, vs, 'l') }

	ch := rl.GetCharPressed()
	for ch != 0 {
		if ch != 'h' && ch != 'j' && ch != 'k' && ch != 'l' {
			vim_dispatch_visual_char(e, p, vs, ch)
		}
		ch = rl.GetCharPressed()
	}
}

vim_dispatch_visual_char :: proc(e: ^Editor, p: ^Pane, vs: ^Vim_State, ch: rune) {
	mid := vs.awaiting_g || vs.awaiting_find != 0 || vs.awaiting_register || vs.awaiting_obj_kind != 0 || vs.pending_count != 0
	_vim_pre_dispatch(vs, ch, mid)

	if vs.awaiting_register {
		vs.awaiting_register = false
		if _vim_is_reg_letter(ch) { vs.register_sel = u8(ch) }
		return
	}
	if !mid && ch == '"' { vs.awaiting_register = true; return }

	if vs.awaiting_obj_kind != 0 {
		kind := vs.awaiting_obj_kind
		vs.awaiting_obj_kind = 0
		lo, hi, ok := vim_text_object(p, kind, ch)
		if ok { p.sel_anchor = lo; p.cursor = hi }
		return
	}
	if !mid && (ch == 'i' || ch == 'a') { vs.awaiting_obj_kind = u8(ch); return }

	if vs.awaiting_find != 0 {
		kind := vs.awaiting_find
		vs.awaiting_find = 0
		count, _ := _vim_take_count(vs)
		vs.last_find = {ch, kind, true}
		forward := kind == 'f' || kind == 't'
		till    := kind == 't' || kind == 'T'
		pos := p.cursor
		ok := false
		for _ in 0..<count {
			np, k := vim_find_char(p, pos, u8(ch), forward, till)
			if !k { ok = false; break }
			pos = np; ok = true
		}
		if ok { p.cursor = pos }
		return
	}
	if vs.awaiting_g {
		vs.awaiting_g = false
		if ch == 'g' { p.cursor = vim_goto_line(p, 0) }
		return
	}

	if ch >= '1' && ch <= '9' || (ch == '0' && vs.pending_count > 0) {
		vs.pending_count = vs.pending_count*10 + int(ch-'0')
		return
	}
	had := vs.pending_count != 0
	count := had ? vs.pending_count : 1
	vs.pending_count = 0

	switch ch {
	case 'v':
		if vs.mode == .Visual { vs.mode = .Normal; p.sel_anchor = p.cursor } else { vs.mode = .Visual }
	case 'V':
		if vs.mode == .Visual_Line { vs.mode = .Normal; p.sel_anchor = p.cursor } else { vs.mode = .Visual_Line }
	case 'h': for _ in 0..<count { move_left(p, true) }
	case 'l': for _ in 0..<count { move_right(p, true) }
	case 'j': for _ in 0..<count { move_down(p, true) }
	case 'k': for _ in 0..<count { move_up(p, true) }
	case 'w': p.cursor = vim_repeat_word_fwd(p, p.cursor, false, count)
	case 'W': p.cursor = vim_repeat_word_fwd(p, p.cursor, true, count)
	case 'b': p.cursor = vim_repeat_word_back(p, p.cursor, false, count)
	case 'B': p.cursor = vim_repeat_word_back(p, p.cursor, true, count)
	case 'e': p.cursor = vim_repeat_word_end(p, p.cursor, false, count)
	case 'E': p.cursor = vim_repeat_word_end(p, p.cursor, true, count)
	case '0':
		line, _ := buffer_pos_to_line_col(&p.buf, p.cursor)
		p.cursor = buffer_line_start(&p.buf, line)
	case '^':
		line, _ := buffer_pos_to_line_col(&p.buf, p.cursor)
		p.cursor = vim_line_first_nonblank(p, line)
	case '$':
		line, _ := buffer_pos_to_line_col(&p.buf, p.cursor)
		tl := min(line+count-1, buffer_line_count(&p.buf)-1)
		p.cursor = buffer_line_start(&p.buf, tl) + buffer_line_length(&p.buf, tl)
	case 'g':
		vs.awaiting_g = true
	case 'G':
		target_line := had ? count-1 : buffer_line_count(&p.buf)-1
		p.cursor = vim_goto_line(p, target_line)
	case 'f', 'F', 't', 'T':
		vs.pending_count = had ? count : 0
		vs.awaiting_find = u8(ch)
	case '%':
		pos, ok := vim_matching_bracket(p, p.cursor)
		if ok { p.cursor = pos }

	case 'd', 'x': vim_visual_operator(e, p, vs, 'd')
	case 'c':      vim_visual_operator(e, p, vs, 'c')
	case 'y':      vim_visual_operator(e, p, vs, 'y')
	case '>':      vim_visual_operator(e, p, vs, '>')
	case '<':      vim_visual_operator(e, p, vs, '<')
	case '~':
		lo, hi := sel_lo(p), sel_hi(p)
		if vs.mode != .Visual_Line { hi = min(hi+1, buffer_len(&p.buf)) }
		if hi > lo {
			p.cursor = lo
			vim_toggle_case(p, hi-lo)
		}
		vs.mode = .Normal
		p.sel_anchor = p.cursor
		_vim_finalize_change(vs)
	case 'u':
		pane_undo(p)
		vs.mode = .Normal
		p.sel_anchor = p.cursor
		_vim_clear_pending(vs)
	}
}

vim_visual_operator :: proc(e: ^Editor, p: ^Pane, vs: ^Vim_State, op: rune) {
	lw := vs.mode == .Visual_Line
	lo := sel_lo(p)
	hi := sel_hi(p)
	if !lw { hi = min(hi+1, buffer_len(&p.buf)) }
	vs.pending_op = op
	vs.mode = .Normal
	vim_do_operator(e, p, vs, lo, hi, lw)
}

// ---------------------------------------------------------------------------
// Dot-repeat (`.`) and macros (q/@) — both replay a []Vim_Key_Event through
// the same dispatch used for live input, with vs.replaying=true so neither
// re-records itself.
// ---------------------------------------------------------------------------

vim_repeat_last :: proc(e: ^Editor, p: ^Pane, vs: ^Vim_State) {
	if len(vs.dot_keys) == 0 { return }
	keys := make([]Vim_Key_Event, len(vs.dot_keys), context.temp_allocator)
	copy(keys, vs.dot_keys[:])
	vim_replay_keys(e, p, keys)
}

vim_play_macro :: proc(e: ^Editor, p: ^Pane, vs: ^Vim_State, reg: u8, count: int) {
	seq, ok := vs.macros[reg]
	if !ok || len(seq) == 0 { return }
	keys := make([]Vim_Key_Event, len(seq), context.temp_allocator)
	copy(keys, seq[:])
	for _ in 0..<max(1, count) {
		vim_replay_keys(e, p, keys)
	}
}

vim_replay_keys :: proc(e: ^Editor, p: ^Pane, keys: []Vim_Key_Event) {
	vs := &e.vim
	if vs.macro_depth > 4 { return }
	vs.macro_depth += 1
	vs.replaying = true
	for k in keys {
		switch vs.mode {
		case .Insert:  vim_replay_insert_key(p, k)
		case .Replace: vim_replay_replace_key(p, k)
		case .Normal, .Visual, .Visual_Line:
			if k.rune_val != 0 { vim_dispatch_normal_char(e, p, k.rune_val) }
		}
	}
	if vs.mode == .Insert || vs.mode == .Replace {
		vs.mode = .Normal
		_, col := buffer_pos_to_line_col(&p.buf, p.cursor)
		if col > 0 { move_left(p, false) }
		undo_break(p)
	}
	vs.replaying = false
	vs.macro_depth -= 1
}

vim_replay_insert_key :: proc(p: ^Pane, k: Vim_Key_Event) {
	if k.key == .ESCAPE { return } // loop-end handled by vim_replay_keys
	if k.key == .BACKSPACE { do_backspace(p); return }
	if k.key == .ENTER { _auto_indent_enter(p); undo_break(p); return }
	if k.rune_val >= 32 {
		buf: [4]u8
		n := rune_encode(k.rune_val, &buf)
		undo_push_insert(p, p.cursor, buf[:n], true)
		buffer_insert_string(&p.buf, p.cursor, string(buf[:n]))
		p.cursor += n
		p.sel_anchor = p.cursor
		p.dirty = true
	}
}

vim_replay_replace_key :: proc(p: ^Pane, k: Vim_Key_Event) {
	if k.key == .ESCAPE { return }
	if k.key == .BACKSPACE { move_left(p, false); return }
	if k.rune_val >= 32 { _vim_replace_insert_one(p, k.rune_val) }
}
