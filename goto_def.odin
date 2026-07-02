package editor

import "core:fmt"
import "core:os"
import "core:strings"
import rl "vendor:raylib"

// ---- Navigation History --------------------------------------------------

NAV_MAX :: 100

Nav_Entry :: struct {
	filename: string, // heap-owned
	cursor:   int,
	scroll:   int,
}

Nav_History :: struct {
	back:    [dynamic]Nav_Entry,
	forward: [dynamic]Nav_Entry,
}

nav_history_init :: proc() -> Nav_History {
	h: Nav_History
	h.back    = make([dynamic]Nav_Entry)
	h.forward = make([dynamic]Nav_Entry)
	return h
}

nav_history_destroy :: proc(h: ^Nav_History) {
	for &e in h.back    { delete(e.filename) }
	for &e in h.forward { delete(e.filename) }
	delete(h.back)
	delete(h.forward)
	h^ = {}
}

_nav_cur :: proc(e: ^Editor) -> Nav_Entry {
	ap := active_pane(e)
	return Nav_Entry{
		filename = strings.clone(ap.filename),
		cursor   = ap.cursor,
		scroll   = ap.scroll,
	}
}

_nav_apply :: proc(e: ^Editor, entry: Nav_Entry) {
	ap := active_pane(e)
	if entry.filename != "" && ap.filename != entry.filename {
		editor_open(e, entry.filename)
		ap = active_pane(e)
	}
	blen         := buffer_len(&ap.buf)
	ap.cursor     = clamp(entry.cursor, 0, blen)
	ap.sel_anchor = ap.cursor
	ap.scroll     = entry.scroll
	ap.scroll_anim = f32(ap.scroll)
	mc_clear(ap)
}

// Push current location before a jump (clears forward history).
nav_push :: proc(h: ^Nav_History, e: ^Editor) {
	for &fe in h.forward { delete(fe.filename) }
	clear(&h.forward)

	cur := _nav_cur(e)
	append(&h.back, cur)
	if len(h.back) > NAV_MAX {
		delete(h.back[0].filename)
		ordered_remove(&h.back, 0)
	}
}

nav_go_back :: proc(h: ^Nav_History, e: ^Editor) {
	if len(h.back) == 0 { e.msg = "No previous location"; return }
	append(&h.forward, _nav_cur(e))
	entry := pop(&h.back)
	_nav_apply(e, entry)
	delete(entry.filename)
}

nav_go_forward :: proc(h: ^Nav_History, e: ^Editor) {
	if len(h.forward) == 0 { e.msg = "No next location"; return }
	append(&h.back, _nav_cur(e))
	entry := pop(&h.forward)
	_nav_apply(e, entry)
	delete(entry.filename)
}

// ---- Definition Picker ---------------------------------------------------

Goto_Def_Result :: struct {
	file:    string, // heap-owned
	line:    int,    // 0-based
	preview: string, // heap-owned
}

Picker_Mode :: enum { Def, Refs }

Goto_Def_Picker :: struct {
	open:       bool,
	mode:       Picker_Mode,
	word:       string, // heap-owned
	results:    [dynamic]Goto_Def_Result,
	sel:        int,
	scroll:     int,
	filter:     [256]u8,
	filter_len: int,
}

DEF_MAX_VIS :: 12

goto_def_picker_init :: proc() -> Goto_Def_Picker {
	p: Goto_Def_Picker
	p.results = make([dynamic]Goto_Def_Result)
	return p
}

goto_def_picker_destroy :: proc(p: ^Goto_Def_Picker) {
	delete(p.word)
	for &r in p.results { delete(r.file); delete(r.preview) }
	delete(p.results)
	p^ = {}
}

_def_picker_clear :: proc(p: ^Goto_Def_Picker) {
	delete(p.word); p.word = ""
	for &r in p.results { delete(r.file); delete(r.preview) }
	clear(&p.results)
	p.sel        = 0
	p.scroll     = 0
	p.filter_len = 0
}

// ---- Symbol Extraction ---------------------------------------------------

// Extract the symbol name DEFINED on this line for the given language.
// Returns "" if this line has no top-level definition.
_def_line_symbol :: proc(line: []u8, lang: Lang) -> string {
	if len(line) == 0 { return "" }
	s := string(line)

	// Measure indent
	indent := 0
	for indent < len(line) && (line[indent] == ' ' || line[indent] == '\t') { indent += 1 }
	trimmed := line[indent:]
	ts := string(trimmed)

	switch lang {
	case .Odin:
		// Top-level only: IDENT :: ... or IDENT : ...
		if indent != 0 { return "" }
		i := 0
		if i >= len(line) || !_ol_is_word(line[i]) { return "" }
		j := i
		for j < len(line) && _ol_is_word(line[j]) { j += 1 }
		name := string(line[i:j])
		k := j
		for k < len(line) && line[k] == ' ' { k += 1 }
		if k >= len(line) || line[k] != ':' { return "" }
		return name

	case .Go:
		if indent != 0 { return "" }
		if strings.has_prefix(s, "func ") {
			rest := s[5:]
			if len(rest) > 0 && rest[0] == '(' {
				close := strings.index(rest, ")")
				if close >= 0 {
					after := strings.trim_left(rest[close+1:], " ")
					return _ol_ident(transmute([]u8)after, 0)
				}
			} else {
				return _ol_ident(transmute([]u8)rest, 0)
			}
		}
		if strings.has_prefix(s, "type ")  { return _ol_ident(transmute([]u8)s, 5) }
		if strings.has_prefix(s, "var ")   { return _ol_ident(transmute([]u8)s, 4) }
		if strings.has_prefix(s, "const ") { return _ol_ident(transmute([]u8)s, 6) }

	case .C:
		if indent != 0 { return "" }
		if strings.has_prefix(s, "//") || strings.has_prefix(s, "/*") || strings.has_prefix(s, "#") { return "" }
		if strings.has_prefix(s, "struct ")    { return _ol_ident(transmute([]u8)s, 7) }
		if strings.has_prefix(s, "enum ")      { return _ol_ident(transmute([]u8)s, 5) }
		if strings.has_prefix(s, "union ")     { return _ol_ident(transmute([]u8)s, 6) }
		if strings.has_prefix(s, "class ")     { return _ol_ident(transmute([]u8)s, 6) }
		if strings.has_prefix(s, "typedef ")   { return "" } // skip typedefs to avoid noise
		// Function definition: return_type name( ... without = before (
		pi := strings.index(s, "(")
		ei := strings.index(s, "=")
		si := strings.index(s, ";")
		if pi > 0 && (ei < 0 || ei > pi) && (si < 0 || si > pi) {
			nm := _ol_last_ident(s[:pi])
			KW :: [?]string{"if", "for", "while", "switch", "return", "sizeof", "alignof"}
			bad := false
			for kw in KW { if nm == kw { bad = true; break } }
			if nm != "" && !bad { return nm }
		}

	case .Rust:
		if indent != 0 { return "" }
		st := ts
		if strings.has_prefix(st, "pub(crate) ") { st = st[11:] }
		else if strings.has_prefix(st, "pub(super) ") { st = st[11:] }
		else if strings.has_prefix(st, "pub ") { st = st[4:] }
		if strings.has_prefix(st, "fn ")        { return _ol_ident(transmute([]u8)st, 3) }
		if strings.has_prefix(st, "async fn ")  { return _ol_ident(transmute([]u8)st, 9) }
		if strings.has_prefix(st, "struct ")    { return _ol_ident(transmute([]u8)st, 7) }
		if strings.has_prefix(st, "enum ")      { return _ol_ident(transmute([]u8)st, 5) }
		if strings.has_prefix(st, "trait ")     { return _ol_ident(transmute([]u8)st, 6) }
		if strings.has_prefix(st, "impl ")      { return _ol_ident(transmute([]u8)st, 5) }
		if strings.has_prefix(st, "type ")      { return _ol_ident(transmute([]u8)st, 5) }
		if strings.has_prefix(st, "const ")     { return _ol_ident(transmute([]u8)st, 6) }
		if strings.has_prefix(st, "static ")    { return _ol_ident(transmute([]u8)st, 7) }
		if strings.has_prefix(st, "mod ")       { return _ol_ident(transmute([]u8)st, 4) }

	case .Python:
		if strings.has_prefix(ts, "async def ") { return _ol_ident(transmute([]u8)trimmed, 10) }
		if strings.has_prefix(ts, "def ")        { return _ol_ident(transmute([]u8)trimmed, 4) }
		if strings.has_prefix(ts, "class ")      { return _ol_ident(transmute([]u8)trimmed, 6) }

	case .JavaScript:
		ts2 := ts
		if strings.has_prefix(ts2, "export ")  { ts2 = ts2[7:] }
		if strings.has_prefix(ts2, "default ") { ts2 = ts2[8:] }
		if strings.has_prefix(ts2, "async function ") { return _ol_ident(transmute([]u8)ts2, 15) }
		if strings.has_prefix(ts2, "function ")       { return _ol_ident(transmute([]u8)ts2, 9) }
		if strings.has_prefix(ts2, "class ")          { return _ol_ident(transmute([]u8)ts2, 6) }
		if strings.has_prefix(ts2, "interface ")      { return _ol_ident(transmute([]u8)ts2, 10) }
		skip := 0
		if strings.has_prefix(ts2, "const ")     { skip = 6 }
		else if strings.has_prefix(ts2, "let ")  { skip = 4 }
		else if strings.has_prefix(ts2, "var ")  { skip = 4 }
		if skip > 0 {
			nm := _ol_ident(transmute([]u8)ts2, skip)
			lstr := string(line)
			if nm != "" && (strings.contains(lstr, "=>") || strings.contains(lstr, "function") || strings.contains(lstr, "class")) {
				return nm
			}
		}

	case .Java:
		java_mods := []string{"public ", "private ", "protected ", "static ",
		                      "final ", "abstract ", "synchronized ", "native "}
		ts3 := ts
		for { prev := ts3; for m in java_mods { if strings.has_prefix(ts3, m) { ts3 = ts3[len(m):] } }; if ts3 == prev { break } }
		if strings.has_prefix(ts3, "class ")     { return _ol_ident(transmute([]u8)ts3, 6) }
		if strings.has_prefix(ts3, "interface ") { return _ol_ident(transmute([]u8)ts3, 10) }
		if strings.has_prefix(ts3, "enum ")      { return _ol_ident(transmute([]u8)ts3, 5) }
		if strings.contains(ts3, "(") {
			pi := strings.index(ts3, "(")
			if pi > 0 {
				nm := _ol_last_ident(ts3[:pi])
				if nm != "" { return nm }
			}
		}

	case .Xml, .None:
	}
	return ""
}

// ---- Scanning ------------------------------------------------------------

// Scan gap buffer of active pane for definitions matching target.
_def_scan_pane :: proc(p: ^Pane, target: string, results: ^[dynamic]Goto_Def_Result) {
	total := buffer_line_count(&p.buf)
	for li in 0..<total {
		ls := buffer_line_start(&p.buf, li)
		ll := buffer_line_length(&p.buf, li)
		if ll == 0 { continue }

		line := make([]u8, ll, context.temp_allocator)
		for i in 0..<ll { line[i] = buffer_get_byte(&p.buf, ls + i) }

		if _def_line_symbol(line, p.lang) == target {
			prev := strings.trim_space(string(line))
			if len(prev) > 80 { prev = prev[:80] }
			append(results, Goto_Def_Result{
				file    = strings.clone(p.filename),
				line    = li,
				preview = strings.clone(prev),
			})
		}
	}
}

_DEF_SKIP :: [?]string{".git", "node_modules", "target", "__pycache__",
                        ".cache", "build", "dist", ".next", "vendor"}

// Scan raw bytes (file contents) for definitions matching target.
_def_scan_bytes :: proc(data: []u8, lang: Lang, target, file: string, results: ^[dynamic]Goto_Def_Result) {
	i, lnum, n := 0, 0, len(data)
	for i < n {
		ls := i
		for i < n && data[i] != '\n' { i += 1 }
		line := data[ls:i]
		if i < n { i += 1 }

		if _def_line_symbol(line, lang) == target {
			prev := strings.trim_space(string(line))
			if len(prev) > 80 { prev = prev[:80] }
			append(results, Goto_Def_Result{
				file    = strings.clone(file),
				line    = lnum,
				preview = strings.clone(prev),
			})
		}
		lnum += 1
	}
}

// Walk workspace looking for definitions; skip current_file (already scanned).
_def_scan_workspace :: proc(target, current_file: string, results: ^[dynamic]Goto_Def_Result) {
	w: os.Walker
	os.walker_init(&w, ".")
	defer os.walker_destroy(&w)

	for {
		info, ok := os.walker_walk(&w)
		if !ok || len(results^) >= 50 { break }

		if info.type == .Directory {
			skip := len(info.name) > 0 && info.name[0] == '.'
			if !skip { for d in _DEF_SKIP { if info.name == d { skip = true; break } } }
			if skip { os.walker_skip_dir(&w) }
			continue
		}

		lang := detect_lang(info.name)
		if lang == .None { continue }
		if info.fullpath == current_file { continue }

		data, err := os.read_entire_file_from_path(info.fullpath, context.allocator)
		if err != nil { continue }
		_def_scan_bytes(data, lang, target, info.fullpath, results)
		delete(data)
	}
}

// ---- Reference Scanning (all occurrences, whole-word) --------------------

_refs_line :: proc(line: []u8, target: string, tlen: int) -> bool {
	llen := len(line)
	if llen < tlen { return false }
	for j in 0..=llen-tlen {
		match := true
		for k in 0..<tlen {
			if line[j+k] != target[k] { match = false; break }
		}
		if match {
			left_ok  := j == 0          || !_ol_is_word(line[j-1])
			right_ok := j+tlen >= llen  || !_ol_is_word(line[j+tlen])
			if left_ok && right_ok { return true }
		}
	}
	return false
}

_refs_scan_pane :: proc(p: ^Pane, target: string, results: ^[dynamic]Goto_Def_Result) {
	tlen  := len(target)
	total := buffer_line_count(&p.buf)
	for li in 0..<total {
		ls := buffer_line_start(&p.buf, li)
		ll := buffer_line_length(&p.buf, li)
		if ll < tlen { continue }

		line := make([]u8, ll, context.temp_allocator)
		for i in 0..<ll { line[i] = buffer_get_byte(&p.buf, ls+i) }

		if _refs_line(line, target, tlen) {
			prev := strings.trim_space(string(line))
			if len(prev) > 80 { prev = prev[:80] }
			append(results, Goto_Def_Result{
				file    = strings.clone(p.filename),
				line    = li,
				preview = strings.clone(prev),
			})
		}
	}
}

_refs_scan_bytes :: proc(data: []u8, target, file: string, results: ^[dynamic]Goto_Def_Result) {
	tlen       := len(target)
	i, lnum, n := 0, 0, len(data)

	// Binary detection: bail on null byte in first 8 KB
	check := min(8192, n)
	for k in 0..<check { if data[k] == 0 { return } }

	for i < n {
		ls := i
		for i < n && data[i] != '\n' { i += 1 }
		line := data[ls:i]
		if i < n { i += 1 }

		if _refs_line(line, target, tlen) {
			prev := strings.trim_space(string(line))
			if len(prev) > 80 { prev = prev[:80] }
			append(results, Goto_Def_Result{
				file    = strings.clone(file),
				line    = lnum,
				preview = strings.clone(prev),
			})
		}
		lnum += 1
	}
}

_refs_scan_workspace :: proc(target, current_file: string, results: ^[dynamic]Goto_Def_Result) {
	w: os.Walker
	os.walker_init(&w, ".")
	defer os.walker_destroy(&w)

	for {
		info, ok := os.walker_walk(&w)
		if !ok || len(results^) >= 300 { break }

		if info.type == .Directory {
			skip := len(info.name) > 0 && info.name[0] == '.'
			if !skip { for d in _DEF_SKIP { if info.name == d { skip = true; break } } }
			if skip { os.walker_skip_dir(&w) }
			continue
		}

		if info.fullpath == current_file { continue }

		data, err := os.read_entire_file_from_path(info.fullpath, context.allocator)
		if err != nil { continue }
		_refs_scan_bytes(data, target, info.fullpath, results)
		delete(data)
	}
}

goto_refs_do :: proc(e: ^Editor) {
	p    := active_pane(e)
	word := _def_word_at_cursor(p)
	if word == "" { e.msg = "No symbol under cursor"; return }

	dp := &e.def_picker
	_def_picker_clear(dp)
	dp.word = strings.clone(word)
	dp.mode = .Refs

	// Current file first (preserves order: current file refs appear at top)
	_refs_scan_pane(p, word, &dp.results)
	// Then workspace
	_refs_scan_workspace(word, p.filename, &dp.results)

	n := len(dp.results)
	if n == 0 {
		e.msg = fmt.tprintf("No references to '%s' found", word)
		return
	}

	nav_push(&e.nav_hist, e)

	if n == 1 {
		_goto_def_jump(e, dp.results[0])
	} else {
		dp.open = true
		e.msg   = fmt.tprintf("%d references to '%s'", n, word)
	}
}

// Extract identifier under or just left of cursor.
_def_word_at_cursor :: proc(p: ^Pane) -> string {
	pos  := p.cursor
	blen := buffer_len(&p.buf)

	cur_b: u8
	if pos < blen { cur_b = buffer_get_byte(&p.buf, pos) }

	if !_ol_is_word(cur_b) {
		if pos > 0 && _ol_is_word(buffer_get_byte(&p.buf, pos-1)) { pos -= 1 } else { return "" }
	}

	lo := pos
	for lo > 0 && _ol_is_word(buffer_get_byte(&p.buf, lo-1)) { lo -= 1 }
	hi := pos + 1
	for hi < blen && _ol_is_word(buffer_get_byte(&p.buf, hi)) { hi += 1 }

	result := make([]u8, hi-lo, context.temp_allocator)
	for i in 0..<(hi-lo) { result[i] = buffer_get_byte(&p.buf, lo+i) }
	return string(result)
}

// ---- Main Entry ----------------------------------------------------------

goto_def_do :: proc(e: ^Editor) {
	p    := active_pane(e)
	word := _def_word_at_cursor(p)
	if word == "" { e.msg = "No symbol under cursor"; return }

	dp := &e.def_picker
	_def_picker_clear(dp)
	dp.word = strings.clone(word)
	dp.mode = .Def

	// 1. Current file
	_def_scan_pane(p, word, &dp.results)

	// 2. Workspace (synchronous; fine for typical project sizes)
	if len(dp.results) == 0 {
		_def_scan_workspace(word, p.filename, &dp.results)
	}

	n := len(dp.results)
	if n == 0 {
		e.msg = fmt.tprintf("Definition of '%s' not found", word)
		return
	}

	nav_push(&e.nav_hist, e)

	if n == 1 {
		_goto_def_jump(e, dp.results[0])
	} else {
		dp.open = true
		e.msg   = fmt.tprintf("%d definitions of '%s'  —  F12 again or pick", n, word)
	}
}

_goto_def_jump :: proc(e: ^Editor, r: Goto_Def_Result) {
	p := active_pane(e)
	if r.file != "" && r.file != p.filename {
		if !editor_open(e, r.file) { e.msg = "Cannot open file"; return }
		p = active_pane(e)
	}
	target := min(r.line, buffer_line_count(&p.buf) - 1)
	ls     := buffer_line_start(&p.buf, target)
	p.cursor      = ls
	p.sel_anchor  = ls
	p.scroll      = max(0, target - 5)
	p.scroll_anim = f32(p.scroll)
	mc_clear(p)
	e.msg = fmt.tprintf("→ %s:%d", path_basename(r.file if r.file != "" else p.filename), target + 1)
}

// ---- Picker Input --------------------------------------------------------

// Build filtered index list from dp.results based on dp.filter. Uses temp allocator.
_def_filtered :: proc(dp: ^Goto_Def_Picker) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	if dp.filter_len == 0 {
		for i in 0..<len(dp.results) { append(&out, i) }
		return out[:]
	}
	q := string(dp.filter[:dp.filter_len])
	for i in 0..<len(dp.results) {
		r := dp.results[i]
		if strings.contains(r.preview, q) || strings.contains(r.file, q) {
			append(&out, i)
		}
	}
	return out[:]
}

goto_def_picker_handle_input :: proc(e: ^Editor) {
	dp := &e.def_picker
	if !dp.open { return }

	if rl.IsKeyPressed(.ESCAPE) { dp.open = false; return }

	filtered := _def_filtered(dp)
	nf := len(filtered)

	if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.F12) {
		if dp.sel < nf {
			_goto_def_jump(e, dp.results[filtered[dp.sel]])
			dp.open = false
		}
		return
	}

	// Backspace deletes filter char
	if key_rep(.BACKSPACE) && dp.filter_len > 0 {
		dp.filter_len -= 1
		dp.sel = 0; dp.scroll = 0
		return
	}

	if key_rep(.UP) {
		if dp.sel > 0 {
			dp.sel -= 1
			if dp.sel < dp.scroll { dp.scroll = dp.sel }
		}
		return
	}
	if key_rep(.DOWN) {
		if dp.sel < nf - 1 {
			dp.sel += 1
			if dp.sel >= dp.scroll + DEF_MAX_VIS { dp.scroll = dp.sel - DEF_MAX_VIS + 1 }
		}
		return
	}

	// Printable chars go to filter
	for {
		ch := rl.GetCharPressed()
		if ch == 0 { break }
		if ch < 32 { continue }
		enc: [4]u8
		n := rune_encode(ch, &enc)
		if dp.filter_len + n <= len(dp.filter) {
			for k in 0..<n { dp.filter[dp.filter_len + k] = enc[k] }
			dp.filter_len += n
			dp.sel = 0; dp.scroll = 0
		}
	}
}

// ---- Picker Render -------------------------------------------------------

render_def_picker :: proc(dp: ^Goto_Def_Picker, font: rl.Font, sw, sh: f32) {
	if !dp.open { return }

	ref := rl.MeasureTextEx(font, "M", FONT_SIZE, CHAR_SPACING)
	ch  := ref.y + LINE_SPACING

	PANEL_W  :: f32(600)
	HDR_H    :: f32(36)
	FILTER_H :: f32(32)
	ITEM_H   :: f32(48)
	FOOTER_H :: f32(26)

	OVERLAY  :: rl.Color{0, 0, 0, 160}
	PANEL_BG := BG
	BORDER   := DIVIDER_COL
	SEL_BG   := SEL_BG
	ACCENT   := ACCENT_COL
	SUBDUED  := LINENUM
	HDR_BG   := STATUS_BG
	PREV_COL := rl.Color{TEXT.r, TEXT.g, TEXT.b, 180}

	filtered := _def_filtered(dp)
	nf  := len(filtered)
	vis := min(nf, DEF_MAX_VIS)
	panel_h := HDR_H + FILTER_H + f32(vis)*ITEM_H + FOOTER_H

	px := (sw - PANEL_W) * 0.5
	py := sh * 0.15

	rl.DrawRectangle(0, 0, i32(sw), i32(sh), OVERLAY)
	dlg_begin(px, py, PANEL_W, panel_h, PANEL_BG, BORDER)

	// Header
	rl.DrawRectangleV({px, py}, {PANEL_W, HDR_H}, HDR_BG)
	rl.DrawLineV({px, py + HDR_H - 1}, {px + PANEL_W, py + HDR_H - 1}, BORDER)
	label := "Go to Definition" if dp.mode == .Def else "Find References"
	title := fmt.tprintf("%s  —  '%s'  (%d / %d)", label, dp.word, nf, len(dp.results))
	dlg_text(font, title, px + 10, py + 9, FONT_SIZE, CHAR_SPACING, ACCENT, px + PANEL_W, 10)

	// Filter input row
	fy_in := py + HDR_H
	rl.DrawRectangleV({px, fy_in}, {PANEL_W, FILTER_H}, PANEL_BG)
	rl.DrawLineV({px, fy_in + FILTER_H - 1}, {px + PANEL_W, fy_in + FILTER_H - 1}, BORDER)
	filter_str := string(dp.filter[:dp.filter_len])
	placeholder := dp.filter_len == 0
	filter_disp := filter_str if !placeholder else "filter..."
	filter_col  := TEXT if !placeholder else SUBDUED
	dlg_text(font, filter_disp, px + 10, fy_in + 7, FONT_SIZE - 2, CHAR_SPACING, filter_col, px + PANEL_W, 10)

	// Items
	item_y := fy_in + FILTER_H
	max_s  := max(0, nf - DEF_MAX_VIS)
	if dp.scroll > max_s { dp.scroll = max_s }

	for vi in 0..<vis {
		fi    := dp.scroll + vi
		if fi >= nf { break }
		ri    := filtered[fi]
		r     := dp.results[ri]
		row_y := item_y + f32(vi)*ITEM_H

		if fi == dp.sel {
			rl.DrawRectangleV({px, row_y}, {PANEL_W, ITEM_H}, SEL_BG)
			rl.DrawRectangleV({px, row_y}, {3, ITEM_H}, ACCENT)
		}

		bname := path_basename(r.file) if r.file != "" else "current file"
		loc   := fmt.tprintf("%s  :  line %d", bname, r.line + 1)
		dlg_text(font, loc,        px + 14, row_y + 5,      FONT_SIZE,     CHAR_SPACING, ACCENT,   px + PANEL_W, 10)
		dlg_text(font, r.preview,  px + 14, row_y + 5 + ch, FONT_SIZE - 2, CHAR_SPACING, PREV_COL, px + PANEL_W, 10)
	}

	// Footer
	footer_y := item_y + f32(vis)*ITEM_H
	rl.DrawRectangleV({px, footer_y}, {PANEL_W, FOOTER_H}, HDR_BG)
	rl.DrawRectangleLinesEx({px, footer_y, PANEL_W, FOOTER_H}, 1, BORDER)
	hint := "type to filter  ·  ↑↓ navigate  ·  Enter jump  ·  Esc close"
	hw   := rl.MeasureTextEx(font, to_cstring(hint), FONT_SIZE - 3, CHAR_SPACING).x
	rl.DrawTextEx(font, to_cstring(hint), {px + PANEL_W - hw - 10, footer_y + 5}, FONT_SIZE - 3, CHAR_SPACING, SUBDUED)
	dlg_end()
}
