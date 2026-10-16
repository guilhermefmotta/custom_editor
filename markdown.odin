package editor

// Markdown preview — subset renderer (headings, bold/italic/inline code,
// fenced code blocks, bullet/ordered lists, blockquotes, links, HR).
// No word-processor-grade CommonMark compliance; covers the common cases.
// Parse is triggered only on toggle-open and on edits while visible (not
// per frame), so cost is the same class as syntax highlighting: draw calls
// scoped to the visible pane area, no cost at all when closed.

import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

Md_Style :: enum { Plain, Bold, Italic, Code, Link }

Md_Span :: struct {
	text:  string, // slice into Md_Preview.src — valid while src is alive
	style: Md_Style,
}

Md_Block_Kind :: enum { Blank, Heading, Paragraph, Code_Block, List_Item, Blockquote, HR }

Md_Block :: struct {
	kind:      Md_Block_Kind,
	level:     int,  // Heading: 1-6
	ordered:   bool, // List_Item: ordered vs bullet
	order_num: int,  // List_Item: displayed number when ordered
	spans:     [dynamic]Md_Span, // Heading / Paragraph / List_Item / Blockquote
	code:      [dynamic]string,  // Code_Block: raw lines, unwrapped
}

Md_Preview :: struct {
	visible:    bool,
	src:        string, // owned clone of buffer text at last parse
	blocks:     [dynamic]Md_Block,
	scroll:     f32,
	content_h:  f32, // total rendered height, updated each draw — used to clamp scroll
	viewport_h: f32,
}

is_markdown_file :: proc(filename: string) -> bool {
	return strings.has_suffix(filename, ".md") || strings.has_suffix(filename, ".markdown")
}

md_preview_destroy :: proc(mp: ^Md_Preview) {
	_md_blocks_destroy(&mp.blocks)
	if mp.src != "" { delete(mp.src) }
	mp^ = {}
}

_md_blocks_destroy :: proc(blocks: ^[dynamic]Md_Block) {
	for &b in blocks {
		delete(b.spans)
		delete(b.code)
	}
	delete(blocks^)
	blocks^ = nil
}

// md_preview_toggle: no-op on non-.md files — Ctrl+Shift+V / palette command
// call this unconditionally, so the gate lives here rather than at call sites.
md_preview_toggle :: proc(p: ^Pane) {
	if !is_markdown_file(p.filename) { return }
	p.md_preview.visible = !p.md_preview.visible
	if p.md_preview.visible {
		md_preview_reparse(p)
	}
}

md_preview_reparse :: proc(p: ^Pane) {
	_md_blocks_destroy(&p.md_preview.blocks)
	if p.md_preview.src != "" { delete(p.md_preview.src) }
	p.md_preview.src    = buffer_to_string(&p.buf)
	p.md_preview.blocks = md_parse(p.md_preview.src)
	p.md_preview.scroll = 0
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

md_parse :: proc(src: string) -> [dynamic]Md_Block {
	blocks := make([dynamic]Md_Block)
	lines  := strings.split(src, "\n", context.temp_allocator)

	in_code:    bool
	code_lines: [dynamic]string

	for raw_line in lines {
		line    := strings.trim_right(raw_line, "\r")
		trimmed := strings.trim_space(line)

		if in_code {
			if strings.has_prefix(trimmed, "```") {
				in_code = false
				append(&blocks, Md_Block{kind = .Code_Block, code = code_lines})
				code_lines = nil
				continue
			}
			append(&code_lines, line)
			continue
		}

		if strings.has_prefix(trimmed, "```") {
			in_code    = true
			code_lines = make([dynamic]string)
			continue
		}

		if trimmed == "" {
			append(&blocks, Md_Block{kind = .Blank})
			continue
		}

		if _md_is_hr(trimmed) {
			append(&blocks, Md_Block{kind = .HR})
			continue
		}

		if strings.has_prefix(trimmed, "#") {
			level := 0
			for level < len(trimmed) && level < 6 && trimmed[level] == '#' { level += 1 }
			if level < len(trimmed) && trimmed[level] == ' ' {
				text := strings.trim_space(trimmed[level:])
				append(&blocks, Md_Block{kind = .Heading, level = level, spans = md_parse_inline(text)})
				continue
			}
		}

		if trimmed == ">" || strings.has_prefix(trimmed, "> ") {
			rest := trimmed[2:] if len(trimmed) > 1 else ""
			append(&blocks, Md_Block{kind = .Blockquote, spans = md_parse_inline(rest)})
			continue
		}

		if strings.has_prefix(trimmed, "- ") || strings.has_prefix(trimmed, "* ") || strings.has_prefix(trimmed, "+ ") {
			append(&blocks, Md_Block{kind = .List_Item, ordered = false, spans = md_parse_inline(trimmed[2:])})
			continue
		}

		if num, rest, ok := _md_ordered_prefix(trimmed); ok {
			append(&blocks, Md_Block{kind = .List_Item, ordered = true, order_num = num, spans = md_parse_inline(rest)})
			continue
		}

		append(&blocks, Md_Block{kind = .Paragraph, spans = md_parse_inline(trimmed)})
	}

	if in_code && len(code_lines) > 0 {
		append(&blocks, Md_Block{kind = .Code_Block, code = code_lines})
	}

	return blocks
}

_md_is_hr :: proc(s: string) -> bool {
	if len(s) < 3 { return false }
	c := s[0]
	if c != '-' && c != '*' && c != '_' { return false }
	for i := 0; i < len(s); i += 1 {
		if s[i] != c { return false }
	}
	return true
}

_md_ordered_prefix :: proc(s: string) -> (num: int, rest: string, ok: bool) {
	i := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' { i += 1 }
	if i == 0 || i >= len(s) { return }
	if s[i] != '.' && s[i] != ')' { return }
	if i+1 >= len(s) || s[i+1] != ' ' { return }
	n := 0
	for j := 0; j < i; j += 1 { n = n*10 + int(s[j]-'0') }
	return n, s[i+2:], true
}

// md_parse_inline: greedy single-pass scan for **bold**, *italic*/_italic_,
// `code`, and [text](url) (url dropped — only the label renders). Anything
// not matched falls through as Plain text.
md_parse_inline :: proc(line: string) -> [dynamic]Md_Span {
	spans := make([dynamic]Md_Span)
	i         := 0
	n         := len(line)
	seg_start := 0

	for i < n {
		c := line[i]
		if c == '*' && i+1 < n && line[i+1] == '*' {
			if close := _md_find(line, i+2, "**"); close >= 0 {
				_md_append_plain(&spans, line[seg_start:i])
				append(&spans, Md_Span{text = line[i+2:close], style = .Bold})
				i = close + 2
				seg_start = i
				continue
			}
		} else if c == '*' || c == '_' {
			if close := _md_find_byte(line, i+1, c); close >= 0 && close > i+1 {
				_md_append_plain(&spans, line[seg_start:i])
				append(&spans, Md_Span{text = line[i+1:close], style = .Italic})
				i = close + 1
				seg_start = i
				continue
			}
		} else if c == '`' {
			if close := _md_find_byte(line, i+1, '`'); close >= 0 {
				_md_append_plain(&spans, line[seg_start:i])
				append(&spans, Md_Span{text = line[i+1:close], style = .Code})
				i = close + 1
				seg_start = i
				continue
			}
		} else if c == '[' {
			if bclose := _md_find_byte(line, i+1, ']'); bclose >= 0 && bclose+1 < n && line[bclose+1] == '(' {
				if pclose := _md_find_byte(line, bclose+2, ')'); pclose >= 0 {
					_md_append_plain(&spans, line[seg_start:i])
					append(&spans, Md_Span{text = line[i+1:bclose], style = .Link})
					i = pclose + 1
					seg_start = i
					continue
				}
			}
		}
		i += 1
	}
	_md_append_plain(&spans, line[seg_start:])
	return spans
}

_md_append_plain :: proc(spans: ^[dynamic]Md_Span, text: string) {
	if len(text) > 0 {
		append(spans, Md_Span{text = text, style = .Plain})
	}
}

_md_find :: proc(s: string, from: int, needle: string) -> int {
	if from > len(s) { return -1 }
	idx := strings.index(s[from:], needle)
	if idx < 0 { return -1 }
	return from + idx
}

_md_find_byte :: proc(s: string, from: int, b: u8) -> int {
	for j := from; j < len(s); j += 1 {
		if s[j] == b { return j }
	}
	return -1
}

// ---------------------------------------------------------------------------
// Draw
// ---------------------------------------------------------------------------

_md_heading_size :: proc(level: int, base: f32) -> f32 {
	switch level {
	case 1:  return base + 12
	case 2:  return base + 8
	case 3:  return base + 5
	case 4:  return base + 3
	case 5:  return base + 1
	case:    return base
	}
}

md_preview_draw :: proc(p: ^Pane, font: rl.Font, ox, oy, ow, oh: f32) {
	mp   := &p.md_preview
	pad  :: f32(16)
	max_w := ow - pad*2
	line_h := FONT_SIZE + LINE_SPACING

	ui_scissor_begin(i32(ox), i32(oy), i32(ow), i32(oh))
	defer rl.EndScissorMode()
	rl.DrawRectangleV({ox, oy}, {ow, oh}, BG)

	x0 := ox + pad
	y  := oy + pad - mp.scroll

	for &b in mp.blocks {
		switch b.kind {
		case .Blank:
			y += line_h * 0.5

		case .HR:
			if y+line_h >= oy && y <= oy+oh {
				ly := y + line_h*0.5
				rl.DrawLineEx({x0, ly}, {ox+ow-pad, ly}, 1, DIVIDER_COL)
			}
			y += line_h

		case .Heading:
			sz := _md_heading_size(b.level, FONT_SIZE)
			y = _md_draw_wrapped(font, b.spans[:], x0, y, max_w, sz, oy, oh, TEXT)
			y += line_h * 0.3

		case .Paragraph:
			y = _md_draw_wrapped(font, b.spans[:], x0, y, max_w, FONT_SIZE, oy, oh, TEXT)

		case .Blockquote:
			start_y := y
			y = _md_draw_wrapped(font, b.spans[:], x0+12, y, max_w-12, FONT_SIZE, oy, oh, LINENUM)
			bar_h := y - start_y
			if start_y < oy+oh && start_y+bar_h >= oy {
				rl.DrawRectangleV({x0, start_y}, {3, bar_h}, DIVIDER_COL)
			}

		case .List_Item:
			bullet := fmt.tprintf("%d.", b.order_num) if b.ordered else "•"
			bw := rl.MeasureTextEx(font, to_cstring(bullet), FONT_SIZE, CHAR_SPACING).x + 8
			if y+line_h >= oy && y <= oy+oh {
				draw_text(font, to_cstring(bullet), {x0, y}, FONT_SIZE, CHAR_SPACING, TEXT)
			}
			y = _md_draw_wrapped(font, b.spans[:], x0+bw, y, max_w-bw, FONT_SIZE, oy, oh, TEXT)

		case .Code_Block:
			block_h := f32(max(1, len(b.code))) * line_h + 8
			if y+block_h >= oy && y <= oy+oh {
				rl.DrawRectangleV({ox+pad*0.5, y}, {ow-pad, block_h}, CUR_LINE_BG)
			}
			cy := y + 4
			for cline in b.code {
				if cy+line_h >= oy && cy <= oy+oh {
					draw_text(font, to_cstring(cline), {x0, cy}, FONT_SIZE, CHAR_SPACING, FUNC_COL)
				}
				cy += line_h
			}
			y += block_h
		}
	}

	mp.content_h  = (y + mp.scroll) - oy + pad
	mp.viewport_h = oh
}

// _md_draw_wrapped: greedy word-wrap of styled spans within max_w, culling
// draw calls outside [oy, oy+oh] but still advancing y so scroll math stays
// correct. Returns the y position just past the wrapped block.
_md_draw_wrapped :: proc(font: rl.Font, spans: []Md_Span, x0, y0, max_w, size: f32, oy, oh: f32, default_col: rl.Color) -> f32 {
	line_h  := size + LINE_SPACING
	x, y    := x0, y0
	space_w := rl.MeasureTextEx(font, to_cstring(" "), size, CHAR_SPACING).x

	if len(spans) == 0 { return y + line_h }

	for sp in spans {
		col := default_col
		switch sp.style {
		case .Bold:   col = TEXT
		case .Italic: col = LINENUM
		case .Code:   col = FUNC_COL
		case .Link:   col = ACCENT_COL
		case .Plain:  col = default_col
		}
		words := strings.split(sp.text, " ", context.temp_allocator)
		for w in words {
			if w == "" {
				x += space_w
				continue
			}
			wc := to_cstring(w)
			ww := rl.MeasureTextEx(font, wc, size, CHAR_SPACING).x
			if x+ww > x0+max_w && x > x0 {
				x = x0
				y += line_h
			}
			visible := y+size >= oy && y <= oy+oh
			if sp.style == .Code && visible {
				rl.DrawRectangleV({x-2, y}, {ww+4, line_h-2}, CUR_LINE_BG)
			}
			if visible {
				draw_text(font, wc, {x, y}, size, CHAR_SPACING, col)
			}
			x += ww + space_w
		}
	}
	return y + line_h
}
