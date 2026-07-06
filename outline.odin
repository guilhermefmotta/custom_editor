package editor

import "core:strings"
import "core:fmt"
import rl "vendor:raylib"

// ---- Data ----------------------------------------------------------------

Outline_Symbol :: struct {
	line: int,
	kind: string, // "proc" "struct" "enum" "const" "var" "type" "func" "class" "impl" etc.
	name: string, // heap-allocated
}

Outline_Dialog :: struct {
	open:     bool,
	symbols:  [dynamic]Outline_Symbol,
	filter:   [dynamic]u8,
	sel_all:  bool,
	filtered: [dynamic]int, // indices into symbols[]
	sel:      int,          // index into filtered[]
	scroll:   int,
}

OUTLINE_MAX_VIS :: 22

outline_init :: proc() -> Outline_Dialog {
	od: Outline_Dialog
	od.symbols  = make([dynamic]Outline_Symbol)
	od.filter   = make([dynamic]u8)
	od.filtered = make([dynamic]int)
	return od
}

outline_destroy :: proc(od: ^Outline_Dialog) {
	for s in od.symbols { delete(s.name) }
	delete(od.symbols)
	delete(od.filter)
	delete(od.filtered)
	od^ = {}
}

// ---- Scan ----------------------------------------------------------------

_ol_is_word :: proc(b: u8) -> bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') ||
	       (b >= '0' && b <= '9') || b == '_'
}

_ol_indent :: proc(line: []u8) -> int {
	for i in 0..<len(line) { if line[i] != ' ' && line[i] != '\t' { return i } }
	return len(line)
}

// Extract the first identifier starting at off.
_ol_ident :: proc(line: []u8, off: int) -> string {
	i := off
	for i < len(line) && !_ol_is_word(line[i]) { i += 1 }
	j := i
	for j < len(line) && _ol_is_word(line[j]) { j += 1 }
	return string(line[i:j])
}

// Extract last identifier before a sentinel byte (used for C function names before '(').
_ol_last_ident :: proc(s: string) -> string {
	end := len(s)
	for end > 0 && !_ol_is_word(s[end-1]) { end -= 1 }
	start := end
	for start > 0 && _ol_is_word(s[start-1]) { start -= 1 }
	return s[start:end]
}

_ol_has_prefix :: proc(line: []u8, off: int, pfx: string) -> bool {
	if off + len(pfx) > len(line) { return false }
	for i in 0..<len(pfx) { if line[off+i] != pfx[i] { return false } }
	return true
}

_ol_str_pfx :: strings.has_prefix

outline_scan :: proc(od: ^Outline_Dialog, p: ^Pane) {
	for s in od.symbols { delete(s.name) }
	clear(&od.symbols)

	total := buffer_line_count(&p.buf)

	for li in 0..<total {
		ls := buffer_line_start(&p.buf, li)
		ll := buffer_line_length(&p.buf, li)
		if ll == 0 { continue }

		line := make([]u8, ll, context.temp_allocator)
		for i in 0..<ll { line[i] = buffer_get_byte(&p.buf, ls+i) }

		indent := _ol_indent(line)
		s := string(line)

		sym: Outline_Symbol
		sym.line = li
		found := false

		switch p.lang {

		// ---- Odin --------------------------------------------------------
		case .Odin:
			if indent != 0 { continue }
			// pattern:  IDENT :: ...  or  IDENT : ...
			i := 0
			if i >= len(line) || !_ol_is_word(line[i]) { continue }
			name_start := i
			for i < len(line) && _ol_is_word(line[i]) { i += 1 }
			name := string(line[name_start:i])
			for i < len(line) && line[i] == ' ' { i += 1 }
			if i >= len(line) || line[i] != ':' { continue }
			i += 1
			if i < len(line) && line[i] == ':' {
				// :: constant / proc / type
				i += 1
				for i < len(line) && line[i] == ' ' { i += 1 }
				rest := string(line[i:])
				switch {
				case _ol_str_pfx(rest, "proc"):     sym.kind = "proc"
				case _ol_str_pfx(rest, "struct"):   sym.kind = "struct"
				case _ol_str_pfx(rest, "enum"):     sym.kind = "enum"
				case _ol_str_pfx(rest, "union"):    sym.kind = "union"
				case _ol_str_pfx(rest, "bit_set"):  sym.kind = "type"
				case _ol_str_pfx(rest, "distinct"): sym.kind = "type"
				case _ol_str_pfx(rest, "map"):      sym.kind = "type"
				case: sym.kind = "const"
				}
			} else {
				sym.kind = "var"
			}
			sym.name = strings.clone(name)
			found = true

		// ---- Go ----------------------------------------------------------
		case .Go:
			if indent != 0 { continue }
			switch {
			case _ol_str_pfx(s, "func "):
				rest := s[5:]
				if len(rest) > 0 && rest[0] == '(' {
					// method: func (recv) Name(
					close := strings.index(rest, ")")
					if close >= 0 {
						after := strings.trim_left(rest[close+1:], " ")
						nm := _ol_ident(transmute([]u8)after, 0)
						if nm != "" { sym.kind = "method"; sym.name = strings.clone(nm); found = true }
					}
				} else {
					nm := _ol_ident(transmute([]u8)rest, 0)
					if nm != "" { sym.kind = "func"; sym.name = strings.clone(nm); found = true }
				}
			case _ol_str_pfx(s, "type "):
				nm := _ol_ident(transmute([]u8)s, 5)
				if nm != "" { sym.kind = "type"; sym.name = strings.clone(nm); found = true }
			case _ol_str_pfx(s, "var "):
				nm := _ol_ident(transmute([]u8)s, 4)
				if nm != "" { sym.kind = "var"; sym.name = strings.clone(nm); found = true }
			case _ol_str_pfx(s, "const "):
				nm := _ol_ident(transmute([]u8)s, 6)
				if nm != "" { sym.kind = "const"; sym.name = strings.clone(nm); found = true }
			}

		// ---- Python -------------------------------------------------------
		case .Python:
			trimmed := strings.trim_left(s, " \t")
			switch {
			case _ol_str_pfx(trimmed, "async def "):
				nm := _ol_ident(transmute([]u8)trimmed, 10)
				if nm != "" {
					sym.kind = "method" if indent > 0 else "func"
					sym.name = strings.clone(nm); found = true
				}
			case _ol_str_pfx(trimmed, "def "):
				nm := _ol_ident(transmute([]u8)trimmed, 4)
				if nm != "" {
					sym.kind = "method" if indent > 0 else "func"
					sym.name = strings.clone(nm); found = true
				}
			case _ol_str_pfx(trimmed, "class ") && indent == 0:
				nm := _ol_ident(transmute([]u8)trimmed, 6)
				if nm != "" { sym.kind = "class"; sym.name = strings.clone(nm); found = true }
			}

		// ---- C / C++ -----------------------------------------------------
		case .C:
			if indent != 0 { continue }
			if _ol_str_pfx(s, "//") || _ol_str_pfx(s, "/*") || _ol_str_pfx(s, "#") { continue }
			switch {
			case _ol_str_pfx(s, "struct "):
				nm := _ol_ident(transmute([]u8)s, 7)
				sym.kind = "struct"; sym.name = strings.clone(nm if nm != "" else "anon"); found = true
			case _ol_str_pfx(s, "typedef struct") || _ol_str_pfx(s, "typedef enum") || _ol_str_pfx(s, "typedef union"):
				sym.kind = "type"; sym.name = strings.clone(s[:min(len(s),30)]); found = true
			case _ol_str_pfx(s, "enum "):
				nm := _ol_ident(transmute([]u8)s, 5)
				sym.kind = "enum"; sym.name = strings.clone(nm if nm != "" else "anon"); found = true
			case len(s) > 0 && (_ol_is_word(s[0]) || s[0] == '*'):
				// Heuristic: has '(' without '=' before it → likely a function
				pi := strings.index(s, "(")
				ei := strings.index(s, "=")
				if pi > 0 && (ei < 0 || ei > pi) {
					nm := _ol_last_ident(s[:pi])
					if nm != "" { sym.kind = "func"; sym.name = strings.clone(nm); found = true }
				}
			}

		// ---- Rust --------------------------------------------------------
		case .Rust:
			if indent != 0 { continue }
			stripped := s
			if _ol_str_pfx(stripped, "pub(crate) ") { stripped = stripped[11:] }
			else if _ol_str_pfx(stripped, "pub(super) ") { stripped = stripped[11:] }
			else if _ol_str_pfx(stripped, "pub ") { stripped = stripped[4:] }
			switch {
			case _ol_str_pfx(stripped, "fn "):
				nm := _ol_ident(transmute([]u8)stripped, 3)
				if nm != "" { sym.kind = "func"; sym.name = strings.clone(nm); found = true }
			case _ol_str_pfx(stripped, "async fn "):
				nm := _ol_ident(transmute([]u8)stripped, 9)
				if nm != "" { sym.kind = "func"; sym.name = strings.clone(nm); found = true }
			case _ol_str_pfx(stripped, "struct "):
				nm := _ol_ident(transmute([]u8)stripped, 7)
				if nm != "" { sym.kind = "struct"; sym.name = strings.clone(nm); found = true }
			case _ol_str_pfx(stripped, "enum "):
				nm := _ol_ident(transmute([]u8)stripped, 5)
				if nm != "" { sym.kind = "enum"; sym.name = strings.clone(nm); found = true }
			case _ol_str_pfx(stripped, "trait "):
				nm := _ol_ident(transmute([]u8)stripped, 6)
				if nm != "" { sym.kind = "trait"; sym.name = strings.clone(nm); found = true }
			case _ol_str_pfx(stripped, "impl "):
				nm := _ol_ident(transmute([]u8)stripped, 5)
				if nm != "" { sym.kind = "impl"; sym.name = strings.clone(nm); found = true }
			case _ol_str_pfx(stripped, "type "):
				nm := _ol_ident(transmute([]u8)stripped, 5)
				if nm != "" { sym.kind = "type"; sym.name = strings.clone(nm); found = true }
			case _ol_str_pfx(stripped, "const "):
				nm := _ol_ident(transmute([]u8)stripped, 6)
				if nm != "" { sym.kind = "const"; sym.name = strings.clone(nm); found = true }
			case _ol_str_pfx(stripped, "static "):
				nm := _ol_ident(transmute([]u8)stripped, 7)
				if nm != "" { sym.kind = "var"; sym.name = strings.clone(nm); found = true }
			case _ol_str_pfx(stripped, "mod "):
				nm := _ol_ident(transmute([]u8)stripped, 4)
				if nm != "" { sym.kind = "mod"; sym.name = strings.clone(nm); found = true }
			}

		// ---- JavaScript / TypeScript -------------------------------------
		case .JavaScript:
			ts := strings.trim_left(s, " \t")
			exported := _ol_str_pfx(ts, "export ")
			if exported { ts = ts[7:] }
			if _ol_str_pfx(ts, "default ") { ts = ts[8:] }

			switch {
			case _ol_str_pfx(ts, "async function "):
				nm := _ol_ident(transmute([]u8)ts, 15)
				if nm != "" { sym.kind = "func"; sym.name = strings.clone(nm); found = true }
			case _ol_str_pfx(ts, "function "):
				nm := _ol_ident(transmute([]u8)ts, 9)
				if nm != "" { sym.kind = "func"; sym.name = strings.clone(nm); found = true }
			case _ol_str_pfx(ts, "class "):
				nm := _ol_ident(transmute([]u8)ts, 6)
				if nm != "" { sym.kind = "class"; sym.name = strings.clone(nm); found = true }
			case _ol_str_pfx(ts, "interface "):
				nm := _ol_ident(transmute([]u8)ts, 10)
				if nm != "" { sym.kind = "type"; sym.name = strings.clone(nm); found = true }
			case _ol_str_pfx(ts, "type "):
				nm := _ol_ident(transmute([]u8)ts, 5)
				if nm != "" { sym.kind = "type"; sym.name = strings.clone(nm); found = true }
			case _ol_str_pfx(ts, "const ") || _ol_str_pfx(ts, "let ") || _ol_str_pfx(ts, "var "):
				skip := 6 if _ol_str_pfx(ts, "const ") else 4
				nm := _ol_ident(transmute([]u8)ts, skip)
				if nm != "" {
					kind := "func" if strings.contains(ts, "=>") || strings.contains(ts, "function") else "const"
					sym.kind = kind; sym.name = strings.clone(nm); found = true
				}
			case indent == 0 && !_ol_str_pfx(ts, "//") && !_ol_str_pfx(ts, "/*"):
				// TypeScript: method shorthand at indent 0 with '('
				pi := strings.index(ts, "(")
				if pi > 0 {
					nm := _ol_last_ident(ts[:pi])
					if nm != "" { sym.kind = "method"; sym.name = strings.clone(nm); found = true }
				}
			}

		// ---- Java --------------------------------------------------------
		case .Java:
			ts := strings.trim_left(s, " \t")
			// Strip common modifiers
			java_mods := []string{"public ", "private ", "protected ", "static ",
			                      "final ", "abstract ", "synchronized ", "native "}
			for { prev := ts; for m in java_mods { if _ol_str_pfx(ts, m) { ts = ts[len(m):] } }; if ts == prev { break } }
			switch {
			case _ol_str_pfx(ts, "class "):
				nm := _ol_ident(transmute([]u8)ts, 6)
				if nm != "" { sym.kind = "class"; sym.name = strings.clone(nm); found = true }
			case _ol_str_pfx(ts, "interface "):
				nm := _ol_ident(transmute([]u8)ts, 10)
				if nm != "" { sym.kind = "type"; sym.name = strings.clone(nm); found = true }
			case _ol_str_pfx(ts, "enum "):
				nm := _ol_ident(transmute([]u8)ts, 5)
				if nm != "" { sym.kind = "enum"; sym.name = strings.clone(nm); found = true }
			case indent <= 4 && !_ol_str_pfx(ts, "//") && strings.contains(ts, "("):
				pi := strings.index(ts, "(")
				if pi > 0 {
					nm := _ol_last_ident(ts[:pi])
					if nm != "" { sym.kind = "func"; sym.name = strings.clone(nm); found = true }
				}
			}

		// ---- Unknown / plain text ----------------------------------------
		case .Xml:
			// No outline for XML files
		case .None:
			if indent != 0 { continue }
			if _ol_str_pfx(s, "//") || _ol_str_pfx(s, "#") || _ol_str_pfx(s, "/*") { continue }
			if len(line) > 0 && _ol_is_word(line[0]) {
				nm := _ol_ident(line, 0)
				if nm != "" { sym.kind = "sym"; sym.name = strings.clone(nm); found = true }
			}
		}

		if found { append(&od.symbols, sym) }
	}

	_outline_rebuild_filter(od)
}

// ---- Filter -------------------------------------------------------------

_outline_rebuild_filter :: proc(od: ^Outline_Dialog) {
	clear(&od.filtered)
	q := strings.to_lower(string(od.filter[:]), context.temp_allocator)
	for i in 0..<len(od.symbols) {
		s := od.symbols[i]
		if len(q) == 0 {
			append(&od.filtered, i)
		} else {
			name_low := strings.to_lower(s.name, context.temp_allocator)
			if strings.contains(name_low, q) { append(&od.filtered, i) }
		}
	}
	od.sel    = 0
	od.scroll = 0
}

// ---- Open / Close -------------------------------------------------------

outline_open :: proc(od: ^Outline_Dialog, p: ^Pane) {
	od.open    = true
	od.sel_all = false
	clear(&od.filter)
	outline_scan(od, p)
}

outline_close :: proc(od: ^Outline_Dialog) {
	od.open = false
}

// ---- Input --------------------------------------------------------------

outline_handle_input :: proc(od: ^Outline_Dialog, p: ^Pane) {
	if rl.IsKeyPressed(.ESCAPE) { outline_close(od); return }

	n := len(od.filtered)

	if key_rep(.UP) {
		if od.sel > 0 {
			od.sel -= 1
			if od.sel < od.scroll { od.scroll = od.sel }
		}
		return
	}
	if key_rep(.DOWN) {
		if od.sel < n - 1 {
			od.sel += 1
			if od.sel >= od.scroll + OUTLINE_MAX_VIS { od.scroll = od.sel - OUTLINE_MAX_VIS + 1 }
		}
		return
	}
	if rl.IsKeyPressed(.ENTER) {
		outline_jump(od, p)
		return
	}

	// Filter typing
	if text_input_handle(&od.filter, &od.sel_all) { _outline_rebuild_filter(od) }
}

outline_jump :: proc(od: ^Outline_Dialog, p: ^Pane) {
	if od.sel >= len(od.filtered) { outline_close(od); return }
	sym := od.symbols[od.filtered[od.sel]]
	ls  := buffer_line_start(&p.buf, sym.line)
	p.cursor     = ls
	p.sel_anchor = ls
	p.scroll     = max(0, sym.line - 5)
	p.scroll_anim = f32(p.scroll)
	mc_clear(p)
	outline_close(od)
}

// ---- Render -------------------------------------------------------------

render_outline :: proc(od: ^Outline_Dialog, p: ^Pane, font: rl.Font, sw, sh: f32) {
	if !od.open { return }

	ref := rl.MeasureTextEx(font, "M", FONT_SIZE, CHAR_SPACING)
	cw  := ref.x
	_ = cw

	PANEL_W  :: f32(420)
	HEADER_H :: f32(36)
	INPUT_H  :: f32(32)
	ITEM_H   :: f32(23)
	FOOTER_H :: f32(26)

	OVERLAY  :: rl.Color{0, 0, 0, 160}
	PANEL_BG := BG
	BORDER   := DIVIDER_COL
	SEL_BG_C := SEL_BG
	ACCENT   := ACCENT_COL
	SUBDUED  := LINENUM
	INPUT_BG := STATUS_BG
	LNUM_COL := LINENUM

	n := len(od.filtered)
	vis := min(n, OUTLINE_MAX_VIS)
	panel_h := HEADER_H + INPUT_H + f32(vis)*ITEM_H + FOOTER_H
	if vis == 0 { panel_h = HEADER_H + INPUT_H + ITEM_H + FOOTER_H }

	panel_x := (sw - PANEL_W) * 0.5
	panel_y := sh * 0.05

	rl.DrawRectangle(0, 0, i32(sw), i32(sh), OVERLAY)
	panel_x, panel_y = dlg_begin(panel_x, panel_y, PANEL_W, panel_h, PANEL_BG, BORDER)

	// Header: filename
	rl.DrawRectangleV({panel_x, panel_y}, {PANEL_W, HEADER_H}, INPUT_BG)
	rl.DrawLineV({panel_x, panel_y + HEADER_H - 1}, {panel_x + PANEL_W, panel_y + HEADER_H - 1}, BORDER)
	fname := p.filename if p.filename != "" else "untitled"
	title := fmt.tprintf("Outline  —  %s", fname)
	rl.DrawTextEx(font, to_cstring(title), {panel_x + 10, panel_y + 9}, FONT_SIZE, CHAR_SPACING, ACCENT)

	// Filter input row
	iy := panel_y + HEADER_H
	rl.DrawRectangleV({panel_x, iy}, {PANEL_W, INPUT_H}, INPUT_BG)
	rl.DrawLineV({panel_x, iy + INPUT_H - 1}, {panel_x + PANEL_W, iy + INPUT_H - 1}, BORDER)
	filter_str := string(od.filter[:])
	placeholder := len(filter_str) == 0
	display := filter_str if !placeholder else "type to filter…"
	dcol := TEXT if !placeholder else SUBDUED
	rl.DrawTextEx(font, to_cstring(display), {panel_x + 10, iy + 7}, FONT_SIZE, CHAR_SPACING, dcol)
	if !placeholder {
		fw := rl.MeasureTextEx(font, to_cstring(filter_str), FONT_SIZE, CHAR_SPACING).x
		rl.DrawRectangleV({panel_x + 10 + fw, iy + 7}, {2, ref.y}, ACCENT)
	}

	// Symbol list — panel scissor (from dlg_begin) clips all content
	list_y := iy + INPUT_H
	if n == 0 {
		rl.DrawTextEx(font, "  no symbols", {panel_x + 10, list_y + 4}, FONT_SIZE, CHAR_SPACING, SUBDUED)
	} else {
		// Clamp scroll
		max_scroll := max(0, n - OUTLINE_MAX_VIS)
		if od.scroll > max_scroll { od.scroll = max_scroll }

		for vi in 0..<vis {
			fi := od.scroll + vi
			if fi >= n { break }
			si  := od.filtered[fi]
			sym := od.symbols[si]
			row_y := list_y + f32(vi)*ITEM_H

			if fi == od.sel {
				rl.DrawRectangleV({panel_x, row_y}, {PANEL_W, ITEM_H}, SEL_BG_C)
				rl.DrawRectangleV({panel_x, row_y}, {3, ITEM_H}, ACCENT)
			}

			// Kind badge color
			kind_col := _outline_kind_color(sym.kind)
			badge := sym.kind
			if len(badge) > 6 { badge = badge[:6] }
			bw := rl.MeasureTextEx(font, to_cstring(badge), FONT_SIZE - 3, CHAR_SPACING).x
			badge_x := panel_x + 10
			rl.DrawRectangleRounded({badge_x - 2, row_y + 4, bw + 6, ITEM_H - 8}, 0.4, 4, rl.Color{kind_col.r, kind_col.g, kind_col.b, 40})
			rl.DrawTextEx(font, to_cstring(badge), {badge_x, row_y + 4}, FONT_SIZE - 3, CHAR_SPACING, kind_col)

			// Name — clipped to leave room for the line-number column
			name_x    := badge_x + bw + 12
			lnum_rsrv := f32(40) // reserved for line number on right
			dlg_text(font, sym.name, name_x, row_y + 3, FONT_SIZE, CHAR_SPACING, TEXT,
			         panel_x + PANEL_W - lnum_rsrv, 4)

			// Line number right-aligned
			lnum := fmt.tprintf("%d", sym.line + 1)
			lw   := rl.MeasureTextEx(font, to_cstring(lnum), FONT_SIZE - 2, CHAR_SPACING).x
			rl.DrawTextEx(font, to_cstring(lnum), {panel_x + PANEL_W - lw - 10, row_y + 4}, FONT_SIZE - 2, CHAR_SPACING, LNUM_COL)
		}
	}

	// Footer hint
	fy := list_y + f32(max(vis, 1))*ITEM_H
	rl.DrawRectangleV({panel_x, fy}, {PANEL_W, FOOTER_H}, INPUT_BG)
	rl.DrawRectangleLinesEx({panel_x, fy, PANEL_W, FOOTER_H}, 1, BORDER)
	cnt := fmt.tprintf("%d symbol%s", n, "s" if n != 1 else "")
	rl.DrawTextEx(font, to_cstring(cnt), {panel_x + 10, fy + 5}, FONT_SIZE - 3, CHAR_SPACING, SUBDUED)
	hint := "↑↓ navigate · Enter jump · Esc close"
	hw   := rl.MeasureTextEx(font, to_cstring(hint), FONT_SIZE - 3, CHAR_SPACING).x
	rl.DrawTextEx(font, to_cstring(hint), {panel_x + PANEL_W - hw - 10, fy + 5}, FONT_SIZE - 3, CHAR_SPACING, SUBDUED)
	dlg_end()
}

_outline_kind_color :: proc(kind: string) -> rl.Color {
	switch kind {
	case "proc", "func", "method": return rl.Color{137, 180, 250, 255} // blue
	case "struct", "class":        return rl.Color{166, 227, 161, 255} // green
	case "enum", "union":          return rl.Color{249, 226, 175, 255} // yellow
	case "type", "interface":      return rl.Color{148, 226, 213, 255} // teal
	case "const":                  return rl.Color{203, 166, 247, 255} // mauve
	case "var":                    return rl.Color{250, 179, 135, 255} // peach
	case "impl":                   return rl.Color{116, 199, 236, 255} // sapphire
	case "trait":                  return rl.Color{245, 194, 231, 255} // pink
	case "mod":                    return rl.Color{180, 190, 254, 255} // lavender
	}
	return rl.Color{108, 112, 134, 255} // subdued
}
