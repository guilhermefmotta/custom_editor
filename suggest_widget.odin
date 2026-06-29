package editor

import "core:fmt"
import "core:strings"
import lsp "./lsp"
import rl "vendor:raylib"

// ---------------------------------------------------------------------------
// Colors — Catppuccin Mocha
// ---------------------------------------------------------------------------

SUGGEST_BG      :: rl.Color{30,  30,  46,  245}
SUGGEST_BORDER  :: rl.Color{69,  71,  90,  255}
SUGGEST_SEL     :: rl.Color{49,  50,  68,  255}
SUGGEST_SEL_BDR :: rl.Color{137, 180, 250, 255}
SUGGEST_TEXT    :: rl.Color{205, 214, 244, 255}
SUGGEST_DETAIL  :: rl.Color{108, 112, 134, 255}
SUGGEST_KIND_FN :: rl.Color{137, 180, 250, 255} // blue  — function/method
SUGGEST_KIND_KW :: rl.Color{203, 166, 247, 255} // mauve — keyword
SUGGEST_KIND_TY :: rl.Color{137, 220, 235, 255} // sky   — type/class
SUGGEST_KIND_VA :: rl.Color{205, 214, 244, 255} // text  — variable/field
SUGGEST_KIND_SN :: rl.Color{250, 179, 135, 255} // peach — snippet
SUGGEST_KIND_MO :: rl.Color{148, 226, 213, 255} // teal  — module/namespace

// Hover popup
HOVER_BG     :: rl.Color{24, 24, 37, 240}
HOVER_BORDER :: rl.Color{69, 71, 90, 255}

// Sig help bar
SIGH_BG      :: rl.Color{30, 30, 46, 230}
SIGH_ACTIVE  :: rl.Color{250, 179, 135, 255} // peach — active parameter
SIGH_NORMAL  :: rl.Color{205, 214, 244, 255}
SIGH_BORDER  :: rl.Color{69, 71, 90, 255}

// ---------------------------------------------------------------------------
// Suggest widget state — embedded in Pane
// ---------------------------------------------------------------------------

Suggest_Widget :: struct {
	visible:  bool,
	items:    []lsp.Completion_Item, // borrowed from completion session
	filtered: []int,                 // borrowed indices
	selected: int,
	scroll:   int,  // first visible index in filtered
}

MAX_VISIBLE_ITEMS :: 10
ITEM_H            :: f32(22)
WIDGET_W          :: f32(380)
DETAIL_W          :: f32(200) // detail popup width
KIND_ICON_W       :: f32(18)

// ---------------------------------------------------------------------------
// Input handling — call from handle_input when completion is visible
// ---------------------------------------------------------------------------

suggest_handle_input :: proc(e: ^Editor, p: ^Pane) -> (consumed: bool) {
	if !p.suggest.visible { return false }

	c := _get_client(e, p)
	if c == nil { p.suggest.visible = false; return false }

	if key_rep(.DOWN) {
		lsp.completion_select_next(c)
		p.suggest.selected = c.completion.session.selected
		_clamp_scroll(&p.suggest)
		return true
	}
	if key_rep(.UP) {
		lsp.completion_select_prev(c)
		p.suggest.selected = c.completion.session.selected
		_clamp_scroll(&p.suggest)
		return true
	}
	if rl.IsKeyPressed(.TAB) || rl.IsKeyPressed(.ENTER) {
		lsp_completion_accept(e, p)
		return true
	}
	if rl.IsKeyPressed(.ESCAPE) {
		lsp.completion_cancel(c)
		p.suggest.visible = false
		return true
	}

	// Page up/down
	if rl.IsKeyPressed(.PAGE_DOWN) {
		for i := 0; i < MAX_VISIBLE_ITEMS; i += 1 { lsp.completion_select_next(c) }
		p.suggest.selected = c.completion.session.selected
		_clamp_scroll(&p.suggest)
		return true
	}
	if rl.IsKeyPressed(.PAGE_UP) {
		for i := 0; i < MAX_VISIBLE_ITEMS; i += 1 { lsp.completion_select_prev(c) }
		p.suggest.selected = c.completion.session.selected
		_clamp_scroll(&p.suggest)
		return true
	}

	return false
}

_clamp_scroll :: proc(w: ^Suggest_Widget) {
	sel := w.selected
	if sel < w.scroll { w.scroll = sel }
	if sel >= w.scroll + MAX_VISIBLE_ITEMS { w.scroll = sel - MAX_VISIBLE_ITEMS + 1 }
	if w.scroll < 0 { w.scroll = 0 }
}

// ---------------------------------------------------------------------------
// Render — call from render_pane after drawing text
// ---------------------------------------------------------------------------

render_suggest_widget :: proc(
	p:    ^Pane,
	font: rl.Font,
	ox, oy, ow, oh: f32,
	cursor_x, cursor_y: f32,
) {
	if !p.suggest.visible || len(p.suggest.filtered) == 0 { return }

	n_visible := min(MAX_VISIBLE_ITEMS, len(p.suggest.filtered) - p.suggest.scroll)
	if n_visible <= 0 { return }

	widget_h := f32(n_visible) * ITEM_H + 4

	// Position: below cursor, clamped to pane bounds
	wx := cursor_x
	wy := cursor_y + FONT_SIZE + LINE_SPACING + 4
	if wx + WIDGET_W > ox + ow { wx = ox + ow - WIDGET_W }
	if wy + widget_h > oy + oh { wy = cursor_y - widget_h - 4 }

	// Background + border
	rl.DrawRectangleV({wx, wy}, {WIDGET_W, widget_h}, SUGGEST_BG)
	_draw_border(wx, wy, WIDGET_W, widget_h, SUGGEST_BORDER)

	// Items
	for i := 0; i < n_visible; i += 1 {
		idx     := p.suggest.scroll + i
		item_i  := p.suggest.filtered[idx]
		if item_i >= len(p.suggest.items) { break }
		item    := &p.suggest.items[item_i]
		item_y  := wy + 2 + f32(i) * ITEM_H
		is_sel  := idx == p.suggest.selected

		if is_sel {
			rl.DrawRectangleV({wx + 1, item_y}, {WIDGET_W - 2, ITEM_H}, SUGGEST_SEL)
			rl.DrawLineV({wx + 1, item_y}, {wx + 1, item_y + ITEM_H}, SUGGEST_SEL_BDR)
		}

		// Kind icon (colored square)
		kind_col := _kind_color(item.kind)
		icon_str := _kind_icon(item.kind)
		rl.DrawTextEx(font, to_cstring(icon_str), {wx + 4, item_y + 3}, FONT_SIZE - 2, 0, kind_col)

		// Label
		label_col := SUGGEST_TEXT
		if item.deprecated { label_col = SUGGEST_DETAIL }
		label_x := wx + KIND_ICON_W + 4
		max_label_w := WIDGET_W - KIND_ICON_W - 8
		label := _truncate_str(item.label, font, max_label_w, context.temp_allocator)
		rl.DrawTextEx(font, to_cstring(label), {label_x, item_y + 3}, FONT_SIZE, 0, label_col)

		// Detail (right-aligned, dimmed)
		if item.detail != "" {
			detail := _truncate_str(item.detail, font, 120, context.temp_allocator)
			dw := rl.MeasureTextEx(font, to_cstring(detail), FONT_SIZE - 2, 0).x
			rl.DrawTextEx(font, to_cstring(detail), {wx + WIDGET_W - dw - 6, item_y + 4}, FONT_SIZE - 2, 0, SUGGEST_DETAIL)
		}
	}

	// Scrollbar
	if len(p.suggest.filtered) > MAX_VISIBLE_ITEMS {
		_draw_scrollbar(wx + WIDGET_W - 4, wy + 2, 3, widget_h - 4,
			p.suggest.scroll, len(p.suggest.filtered), MAX_VISIBLE_ITEMS)
	}
}

// ---------------------------------------------------------------------------
// Hover popup
// ---------------------------------------------------------------------------

render_hover_popup :: proc(
	c:    ^lsp.Language_Client,
	font: rl.Font,
	ox, oy, ow, oh: f32,
	cursor_x, cursor_y: f32,
) {
	if c == nil { return }
	hr, ok := lsp.hover_get_result(c)
	if !ok || hr.contents == "" { return }

	lines := strings.split_lines(hr.contents, context.temp_allocator)
	if len(lines) == 0 { return }

	// Measure popup size
	max_w: f32 = 0
	for line in lines {
		w := rl.MeasureTextEx(font, to_cstring(line), FONT_SIZE - 1, 0).x
		if w > max_w { max_w = w }
	}
	max_w = min(max_w + 16, ow * 0.6)
	n_lines := min(len(lines), 20)
	popup_h := f32(n_lines) * (FONT_SIZE + 2) + 8

	// Position above cursor
	px := cursor_x
	py := cursor_y - popup_h - 6
	if py < oy { py = cursor_y + FONT_SIZE + 6 }
	if px + max_w > ox + ow { px = ox + ow - max_w }

	rl.DrawRectangleV({px, py}, {max_w, popup_h}, HOVER_BG)
	_draw_border(px, py, max_w, popup_h, HOVER_BORDER)

	for i in 0..<n_lines {
		line := lines[i]
		rl.DrawTextEx(font, to_cstring(line), {px + 8, py + 4 + f32(i) * (FONT_SIZE + 2)}, FONT_SIZE - 1, 0, SUGGEST_TEXT)
	}
}

// ---------------------------------------------------------------------------
// Signature help bar — rendered at top of pane text area
// ---------------------------------------------------------------------------

render_sig_help :: proc(
	c:    ^lsp.Language_Client,
	font: rl.Font,
	ox, oy, ow: f32,
	cursor_y: f32,
) {
	if c == nil { return }
	sh, ok := lsp.sig_help_get(c)
	if !ok || len(sh.signatures) == 0 { return }

	sig_idx := sh.active_signature
	if sig_idx >= len(sh.signatures) { sig_idx = 0 }
	sig := &sh.signatures[sig_idx]

	// Build display string with active parameter highlighted
	py := cursor_y - FONT_SIZE - LINE_SPACING - 8
	if py < oy { py = oy + FONT_SIZE + 2 }

	bar_h := FONT_SIZE + 10
	rl.DrawRectangleV({ox, py}, {ow, bar_h}, SIGH_BG)
	rl.DrawLineV({ox, py + bar_h - 1}, {ox + ow, py + bar_h - 1}, SIGH_BORDER)

	x := ox + 8.0
	y := py + 4.0

	// Draw label with active parameter highlighted
	label := sig.label
	active_param := sig.active_parameter
	if sh.active_parameter >= 0 { active_param = sh.active_parameter }

	if active_param >= 0 && active_param < len(sig.parameters) {
		// Find the parameter in the label and highlight it
		param_label := sig.parameters[active_param].label
		before, match, after := strings.partition(label, param_label)
		if match != "" {
			_draw_text_at(font, before, &x, y, SIGH_NORMAL)
			_draw_text_at(font, match, &x, y, SIGH_ACTIVE)
			_draw_text_at(font, after, &x, y, SIGH_NORMAL)
		} else {
			_draw_text_at(font, label, &x, y, SIGH_NORMAL)
		}
	} else {
		_draw_text_at(font, label, &x, y, SIGH_NORMAL)
	}

	// Overload counter
	if len(sh.signatures) > 1 {
		counter := fmt.tprintf(" %d/%d", sig_idx + 1, len(sh.signatures))
		_draw_text_at(font, counter, &x, y, SIGH_ACTIVE)
	}
}

// ---------------------------------------------------------------------------
// Diagnostic squiggles + gutter indicators
// ---------------------------------------------------------------------------

render_diagnostics :: proc(
	diags: []lsp.Diagnostic,
	font:  rl.Font,
	buf:   ^Gap_Buffer,
	ox, oy: f32,
	scroll: int,
	cw, ch: f32,
	text_x: f32,
	vis_lines: int,
) {
	if len(diags) == 0 { return }

	for &d in diags {
		line := d.range.start.line
		if line < scroll || line >= scroll + vis_lines { continue }

		row_y := oy + PANE_TOP_PAD + f32(line - scroll) * ch

		// Squiggle color
		sq_col: rl.Color
		switch d.severity {
		case .Error:       sq_col = {243, 139, 168, 200} // red
		case .Warning:     sq_col = {249, 226, 175, 200} // yellow
		case .Information: sq_col = {137, 220, 235, 200} // sky
		case .Hint:        sq_col = {166, 227, 161, 160} // green
		}

		// Measure position of squiggle start
		ls := buffer_line_start(buf, line)
		ll := buffer_line_length(buf, line)
		line_bytes := make([]u8, ll, context.temp_allocator)
		for i in 0..<ll { line_bytes[i] = buffer_get_byte(buf, ls + i) }

		start_x := text_x
		end_x   := text_x + f32(ll) * cw // approximation; monospace

		// Draw squiggle on bottom of text line
		sq_y := row_y + FONT_SIZE - 1
		_draw_squiggle(start_x, sq_y, end_x - start_x, sq_col)

		// Gutter dot
		dot_x := ox + 2
		rl.DrawCircleV({dot_x, row_y + FONT_SIZE * 0.5}, 3, sq_col)
	}
}

// Inline diagnostic message at end of line.
render_diagnostic_inline :: proc(
	diags: []lsp.Diagnostic,
	font:  rl.Font,
	buf:   ^Gap_Buffer,
	line:  int,
	x, y: f32,
) {
	for &d in diags {
		if d.range.start.line != line { continue }
		msg := d.message
		if len(msg) > 60 { msg = fmt.tprintf("%s…", msg[:57]) }
		label := fmt.tprintf("  %s", msg)
		msg_col: rl.Color
		#partial switch d.severity {
		case .Error:   msg_col = {243, 139, 168, 160}
		case .Warning: msg_col = {249, 226, 175, 140}
		case:          msg_col = {108, 112, 134, 140}
		}
		rl.DrawTextEx(font, to_cstring(label), {x, y}, FONT_SIZE - 2, 0, msg_col)
		break // one per line
	}
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

_draw_border :: proc(x, y, w, h: f32, col: rl.Color) {
	rl.DrawRectangleLinesEx({x, y, w, h}, 1, col)
}

_draw_squiggle :: proc(x, y, width: f32, col: rl.Color) {
	amp: f32 = 2
	step: f32 = 4
	cx := x
	up := true
	for cx + step <= x + width {
		ny := y - amp if up else y + amp
		rl.DrawLineV({cx, y}, {cx + step * 0.5, ny}, col)
		rl.DrawLineV({cx + step * 0.5, ny}, {cx + step, y}, col)
		cx += step
		up = !up
	}
}

_draw_scrollbar :: proc(x, y, w, h: f32, scroll, total, visible: int) {
	if total <= visible { return }
	ratio    := f32(visible) / f32(total)
	bar_h    := max(h * ratio, 8)
	bar_y    := y + h * f32(scroll) / f32(total)
	rl.DrawRectangleV({x, bar_y}, {w, bar_h}, SUGGEST_BORDER)
}

_draw_text_at :: proc(font: rl.Font, text: string, x: ^f32, y: f32, col: rl.Color) {
	if text == "" { return }
	cs := to_cstring(text)
	rl.DrawTextEx(font, cs, {x^, y}, FONT_SIZE, 0, col)
	x^ += rl.MeasureTextEx(font, cs, FONT_SIZE, 0).x
}

_truncate_str :: proc(s: string, font: rl.Font, max_w: f32, allocator := context.allocator) -> string {
	if rl.MeasureTextEx(font, to_cstring(s), FONT_SIZE, 0).x <= max_w { return s }
	// Binary search for fitting length
	lo, hi := 0, len(s)
	for lo + 1 < hi {
		mid := (lo + hi) / 2
		candidate := fmt.tprintf("%s…", s[:mid])
		if rl.MeasureTextEx(font, to_cstring(candidate), FONT_SIZE, 0).x <= max_w {
			lo = mid
		} else {
			hi = mid
		}
	}
	return fmt.aprintf("%s…", s[:lo], allocator = allocator)
}

_kind_color :: proc(kind: lsp.Completion_Item_Kind) -> rl.Color {
	#partial switch kind {
	case .Function, .Method, .Constructor: return SUGGEST_KIND_FN
	case .Keyword:                         return SUGGEST_KIND_KW
	case .Class, .Interface, .Struct,
	     .Enum, .Type_Parameter:          return SUGGEST_KIND_TY
	case .Snippet:                         return SUGGEST_KIND_SN
	case .Module, .Folder:                 return SUGGEST_KIND_MO
	case:                                  return SUGGEST_KIND_VA
	}
}

_kind_icon :: proc(kind: lsp.Completion_Item_Kind) -> string {
	switch kind {
	case .Function:       return "fn"
	case .Method:         return "me"
	case .Constructor:    return "co"
	case .Field:          return "fi"
	case .Variable:       return "va"
	case .Class:          return "cl"
	case .Interface:      return "in"
	case .Module:         return "mo"
	case .Property:       return "pr"
	case .Unit:           return "un"
	case .Value:          return "vl"
	case .Enum:           return "en"
	case .Keyword:        return "kw"
	case .Snippet:        return "sn"
	case .Color:          return "co"
	case .File:           return "fi"
	case .Reference:      return "re"
	case .Folder:         return "fo"
	case .Enum_Member:    return "em"
	case .Constant:       return "cn"
	case .Struct:         return "st"
	case .Event:          return "ev"
	case .Operator:       return "op"
	case .Type_Parameter: return "tp"
	case .Text:           return "tx"
	}
	return "  "
}
