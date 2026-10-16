package editor

// Markdown preview — subset renderer (headings, bold/italic/inline code,
// fenced code blocks, bullet/ordered/task lists, blockquotes, links, HR,
// tables, images).
// No word-processor-grade CommonMark compliance; covers the common cases.
// Parse is triggered only on toggle-open and on edits while visible (not
// per frame), so cost is the same class as syntax highlighting: draw calls
// scoped to the visible pane area, no cost at all when closed.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import rl "vendor:raylib"

Md_Style :: enum { Plain, Bold, Italic, Code, Link }

Md_Span :: struct {
	text:  string, // slice into Md_Preview.src — valid while src is alive
	style: Md_Style,
}

Md_Block_Kind :: enum { Blank, Heading, Paragraph, Code_Block, List_Item, Blockquote, HR, Table, Image }

Md_Task :: enum u8 { None, Open, Done } // List_Item: "- [ ]" / "- [x]"
Md_Align :: enum u8 { Left, Center, Right }

// One image reference: ![alt](url) or <img src=... alt=...>.
Md_Image :: struct {
	alt, url: string, // slices into Md_Preview.src
}

Md_Row :: [dynamic][dynamic]Md_Span // table row: one span list per cell

Md_Block :: struct {
	kind:      Md_Block_Kind,
	level:     int,  // Heading: 1-6; List_Item: nesting depth (0 = top)
	ordered:   bool, // List_Item: ordered vs bullet
	order_num: int,  // List_Item: displayed number when ordered
	task:      Md_Task,
	spans:     [dynamic]Md_Span, // Heading / Paragraph / List_Item / Blockquote
	code:      [dynamic]string,  // Code_Block: raw lines, unwrapped
	rows:      [dynamic]Md_Row,  // Table: rows[0] = header
	aligns:    [dynamic]Md_Align,// Table: per column
	images:    [dynamic]Md_Image,// Image: a line made only of images
}

Md_Preview :: struct {
	visible:    bool,
	src:        string, // owned clone of buffer text at last parse
	blocks:     [dynamic]Md_Block,
	scroll:     f32,
	content_h:  f32, // total rendered height, updated each draw — used to clamp scroll
	viewport_h: f32,
	auto_done:  bool, // "Open Markdown as preview" already applied to this file
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
		for &row in b.rows {
			for cell in row { delete(cell) }
			delete(row)
		}
		delete(b.rows)
		delete(b.aligns)
		delete(b.images)
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

	for li := 0; li < len(lines); li += 1 {
		line    := strings.trim_right(lines[li], "\r")
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

		// Table: a "| a | b |" line followed by a "|---|:--:|" separator
		if strings.has_prefix(trimmed, "|") && li + 1 < len(lines) {
			if aligns, ok := _md_table_separator(strings.trim_space(strings.trim_right(lines[li + 1], "\r"))); ok {
				b := Md_Block{kind = .Table, aligns = aligns}
				append(&b.rows, _md_table_row(trimmed))
				li += 2
				for li < len(lines) {
					t := strings.trim_space(strings.trim_right(lines[li], "\r"))
					if !strings.has_prefix(t, "|") { break }
					append(&b.rows, _md_table_row(t))
					li += 1
				}
				li -= 1 // the loop's li += 1 moves past the last row
				append(&blocks, b)
				continue
			}
		}

		if imgs, ok := md_line_images(trimmed); ok {
			append(&blocks, Md_Block{kind = .Image, images = imgs})
			continue
		}

		if trimmed == ">" || strings.has_prefix(trimmed, "> ") {
			rest := trimmed[2:] if len(trimmed) > 1 else ""
			append(&blocks, Md_Block{kind = .Blockquote, spans = md_parse_inline(rest)})
			continue
		}

		depth := _md_indent_depth(line)
		if strings.has_prefix(trimmed, "- ") || strings.has_prefix(trimmed, "* ") || strings.has_prefix(trimmed, "+ ") {
			task, rest := _md_task_prefix(trimmed[2:])
			append(&blocks, Md_Block{kind = .List_Item, level = depth, task = task, spans = md_parse_inline(rest)})
			continue
		}

		if num, rest, ok := _md_ordered_prefix(trimmed); ok {
			task, rest2 := _md_task_prefix(rest)
			append(&blocks, Md_Block{kind = .List_Item, level = depth, ordered = true, order_num = num, task = task, spans = md_parse_inline(rest2)})
			continue
		}

		append(&blocks, Md_Block{kind = .Paragraph, spans = md_parse_inline(trimmed)})
	}

	if in_code && len(code_lines) > 0 {
		append(&blocks, Md_Block{kind = .Code_Block, code = code_lines})
	}

	return blocks
}

// Nesting depth of a list line: 2 spaces (or a tab) per level.
_md_indent_depth :: proc(line: string) -> int {
	n := 0
	for c in line {
		switch c {
		case ' ':  n += 1
		case '\t': n += 2
		case:      return min(n / 2, 6)
		}
	}
	return 0
}

// "[ ] rest" / "[x] rest" at the start of a list item.
_md_task_prefix :: proc(s: string) -> (Md_Task, string) {
	if len(s) >= 4 && s[0] == '[' && s[2] == ']' && s[3] == ' ' {
		switch s[1] {
		case ' ':      return .Open, s[4:]
		case 'x', 'X': return .Done, s[4:]
		}
	}
	return .None, s
}

// Cells of "| a | b |" (outer pipes optional, "\|" stays in the cell).
_md_table_cells :: proc(line: string, allocator := context.temp_allocator) -> [dynamic]string {
	cells := make([dynamic]string, allocator)
	s := strings.trim_space(line)
	s = strings.trim_prefix(s, "|")
	if strings.has_suffix(s, "|") && !strings.has_suffix(s, "\\|") { s = s[:len(s) - 1] }
	start := 0
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\\' { i += 1; continue }
		if s[i] == '|' {
			append(&cells, strings.trim_space(s[start:i]))
			start = i + 1
		}
	}
	append(&cells, strings.trim_space(s[start:]))
	return cells
}

_md_table_row :: proc(line: string) -> Md_Row {
	row := make(Md_Row)
	for c in _md_table_cells(line) { append(&row, md_parse_inline(c)) }
	return row
}

// "|---|:--:|--:|" → column alignments; ok = false if it is not a separator.
_md_table_separator :: proc(line: string) -> (aligns: [dynamic]Md_Align, ok: bool) {
	if !strings.contains(line, "-") { return }
	cells := _md_table_cells(line)
	for c in cells {
		t := strings.trim_space(c)
		if len(t) == 0 { return }
		for ch in t { if ch != '-' && ch != ':' { return } }
		if !strings.contains(t, "-") { return }
		left, right := t[0] == ':', t[len(t) - 1] == ':'
		append(&aligns, Md_Align.Center if left && right else (Md_Align.Right if right else Md_Align.Left))
	}
	return aligns, true
}

// A line made only of images (README badge rows, screenshots):
//   ![alt](url)   [![alt](url)](link)   <img src="url" alt="...">
// ok = false when anything else is on the line.
md_line_images :: proc(line: string) -> (imgs: [dynamic]Md_Image, ok: bool) {
	s := strings.trim_space(line)
	if s == "" { return }
	for len(s) > 0 {
		img: Md_Image
		rest: string
		found: bool
		switch {
		case strings.has_prefix(s, "!["):
			img, rest, found = _md_image_ref(s)
		case strings.has_prefix(s, "[!["):
			// linked image: [![alt](url)](link)
			if img, rest, found = _md_image_ref(s[1:]); found {
				found = strings.has_prefix(rest, "](")
				if found {
					close := strings.index_byte(rest, ')')
					found = close >= 0
					if found { rest = rest[close + 1:] }
				}
			}
		case strings.has_prefix(strings.to_lower(s[:min(4, len(s))], context.temp_allocator), "<img"):
			img, rest, found = _md_html_img(s)
		}
		if !found { delete(imgs); return nil, false }
		append(&imgs, img)
		s = strings.trim_space(rest)
	}
	return imgs, true
}

// ![alt](url "title") at the start of s.
@(private="file")
_md_image_ref :: proc(s: string) -> (img: Md_Image, rest: string, ok: bool) {
	if !strings.has_prefix(s, "![") { return }
	bclose := _md_find_byte(s, 2, ']')
	if bclose < 0 || bclose + 1 >= len(s) || s[bclose + 1] != '(' { return }
	pclose := _md_find_byte(s, bclose + 2, ')')
	if pclose < 0 { return }
	target := strings.trim_space(s[bclose + 2:pclose])
	if sp := strings.index_byte(target, ' '); sp >= 0 { target = target[:sp] } // drop "title"
	return Md_Image{alt = s[2:bclose], url = strings.trim(target, "<>")}, s[pclose + 1:], true
}

// <img src="url" alt="..." ...> at the start of s.
@(private="file")
_md_html_img :: proc(s: string) -> (img: Md_Image, rest: string, ok: bool) {
	end := strings.index_byte(s, '>')
	if end < 0 { return }
	tag := s[:end]
	img.url = _md_attr(tag, "src")
	img.alt = _md_attr(tag, "alt")
	if img.url == "" { return }
	return img, s[end + 1:], true
}

@(private="file")
_md_attr :: proc(tag, name: string) -> string {
	low := strings.to_lower(tag, context.temp_allocator)
	key := fmt.tprintf("%s=", name)
	i := strings.index(low, key)
	for i > 0 && low[i - 1] != ' ' && low[i - 1] != '\t' {
		j := strings.index(low[i + 1:], key)
		if j < 0 { return "" }
		i += 1 + j
	}
	if i < 0 { return "" }
	v := tag[i + len(key):]
	if len(v) > 0 && (v[0] == '"' || v[0] == '\'') {
		q := v[0]
		close := strings.index_byte(v[1:], q)
		if close < 0 { return "" }
		return v[1:1 + close]
	}
	sp := strings.index_any(v, " \t/>")
	return v if sp < 0 else v[:sp]
}

// Image path from a markdown file: relative to the .md, %20 decoded, no
// query/fragment. "" for remote images (http/https/data:), not fetched.
md_image_path :: proc(md_file, url: string) -> string {
	u := url
	low := strings.to_lower(u, context.temp_allocator)
	if strings.has_prefix(low, "http://") || strings.has_prefix(low, "https://") || strings.has_prefix(low, "data:") || strings.has_prefix(low, "//") {
		return ""
	}
	if i := strings.index_any(u, "?#"); i >= 0 { u = u[:i] }
	u, _ = strings.replace_all(u, "%20", " ", context.temp_allocator)
	if u == "" { return "" }
	dir := filepath.dir(md_file)
	if filepath.is_abs(u) {
		if os.exists(u) { return u }
		u = strings.trim_left(u, "/") // "/docs/x.png" in a README: repo relative
	}
	full, _ := filepath.join({dir, u}, context.temp_allocator)
	return full
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
					// inline image ![alt](url): its alt shows like a link
					plain_end := i - 1 if i > seg_start && line[i-1] == '!' else i
					_md_append_plain(&spans, line[seg_start:plain_end])
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
			lx := x0 + f32(b.level) * 20
			visible := y+line_h >= oy && y <= oy+oh
			bw: f32
			if b.task != .None {
				// checkbox drawn as shapes (no ☐/☑ glyph needed)
				box := FONT_SIZE - 2
				bx, by := lx, y + (FONT_SIZE - box) * 0.5 + 1
				if visible {
					if b.task == .Done {
						rl.DrawRectangleRounded({bx, by, box, box}, 0.25, 4, ACCENT_COL)
						rl.DrawLineEx({bx + box*0.22, by + box*0.52}, {bx + box*0.42, by + box*0.72}, 2, BG)
						rl.DrawLineEx({bx + box*0.42, by + box*0.72}, {bx + box*0.78, by + box*0.30}, 2, BG)
					} else {
						rl.DrawRectangleRoundedLinesEx({bx, by, box, box}, 0.25, 4, 1.5, LINENUM)
					}
				}
				bw = box + 8
			} else {
				bullet := fmt.tprintf("%d.", b.order_num) if b.ordered else ("•" if b.level % 2 == 0 else "-")
				bw = rl.MeasureTextEx(font, to_cstring(bullet), FONT_SIZE, CHAR_SPACING).x + 8
				if visible {
					draw_text(font, to_cstring(bullet), {lx, y}, FONT_SIZE, CHAR_SPACING, TEXT)
				}
			}
			col := LINENUM if b.task == .Done else TEXT
			y = _md_draw_wrapped(font, b.spans[:], lx+bw, y, max_w-bw-(lx-x0), FONT_SIZE, oy, oh, col)

		case .Table:
			y = _md_draw_table(font, &b, x0, y, max_w, oy, oh)
			y += line_h * 0.3

		case .Image:
			y = _md_draw_images(p, font, &b, x0, y, max_w, oy, oh)

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

// Width of a span list on one line (no wrapping).
@(private="file")
_md_spans_w :: proc(font: rl.Font, spans: []Md_Span, size: f32) -> f32 {
	w: f32
	for sp in spans { w += rl.MeasureTextEx(font, to_cstring(sp.text), size, CHAR_SPACING).x }
	return w
}

// Table: columns sized to their widest cell, shrunk proportionally (cells
// clipped) when the table is wider than the preview. Header row shaded.
@(private="file")
_md_draw_table :: proc(font: rl.Font, b: ^Md_Block, x0, y0, max_w, oy, oh: f32) -> f32 {
	PADX  :: f32(10)
	size  := FONT_SIZE
	row_h := size + LINE_SPACING + 8
	ncols := 0
	for row in b.rows { ncols = max(ncols, len(row)) }
	if ncols == 0 { return y0 }

	widths := make([]f32, ncols, context.temp_allocator)
	for row in b.rows {
		for cell, c in row { widths[c] = max(widths[c], _md_spans_w(font, cell[:], size) + PADX*2) }
	}
	total: f32
	for w in widths { total += w }
	if total > max_w {
		k := max_w / total
		total = 0
		for &w in widths { w = max(w * k, PADX*2 + 16); total += w }
	}

	y := y0
	for row, ri in b.rows {
		if y + row_h >= oy && y <= oy + oh {
			if ri == 0 { rl.DrawRectangleV({x0, y}, {total, row_h}, STATUS_BG) }
			else if ri % 2 == 0 { rl.DrawRectangleV({x0, y}, {total, row_h}, CUR_LINE_BG) }
			x := x0
			for c in 0 ..< ncols {
				if c < len(row) {
					cell := row[c][:]
					cw := _md_spans_w(font, cell, size)
					avail := widths[c] - PADX*2
					tx := x + PADX
					if cw < avail {
						#partial switch (b.aligns[c] if c < len(b.aligns) else .Left) {
						case .Center: tx += (avail - cw) * 0.5
						case .Right:  tx += avail - cw
						}
					}
					right := x + widths[c] - PADX*0.5
					for sp in cell {
						if tx >= right { break }
						col := TEXT if ri == 0 else _md_span_color(sp.style, TEXT)
						dlg_text(font, sp.text, tx, y + 4, size, CHAR_SPACING, col, right, 0)
						tx += rl.MeasureTextEx(font, to_cstring(sp.text), size, CHAR_SPACING).x
					}
				}
				x += widths[c]
				if c < ncols - 1 { rl.DrawLineEx({x, y}, {x, y + row_h}, 1, DIVIDER_COL) }
			}
			rl.DrawRectangleLinesEx({x0, y, total, row_h}, 1, DIVIDER_COL)
		}
		y += row_h
	}
	return y
}

// Image line: local images drawn at their size (shrunk to the width and
// the viewport height); remote/missing ones as a placeholder with the alt.
@(private="file")
_md_draw_images :: proc(p: ^Pane, font: rl.Font, b: ^Md_Block, x0, y0, max_w, oy, oh: f32) -> f32 {
	y := y0
	line_h := FONT_SIZE + LINE_SPACING
	x := x0
	row_h: f32
	for img in b.images {
		path := md_image_path(p.filename, img.url)
		ent := img_get(path) if path != "" else nil
		if ent == nil || !ent.ok {
			label := fmt.tprintf("[image: %s]", img.alt if img.alt != "" else img.url)
			if path == "" { label = fmt.tprintf("[%s]", img.alt if img.alt != "" else "remote image") }
			lw := rl.MeasureTextEx(font, to_cstring(label), FONT_SIZE - 2, CHAR_SPACING).x
			if x > x0 && x + lw > x0 + max_w { x = x0; y += row_h + 4; row_h = 0 }
			if y + line_h >= oy && y <= oy + oh {
				draw_text(font, to_cstring(label), {x, y}, FONT_SIZE - 2, CHAR_SPACING, LINENUM if path != "" else ACCENT_COL)
			}
			x += lw + 10
			row_h = max(row_h, line_h)
			continue
		}
		w, h := f32(ent.tex.width), f32(ent.tex.height)
		k := min(1, max_w / w, (oh * 0.9) / h)
		w, h = w * k, h * k
		if x > x0 && x + w > x0 + max_w { x = x0; y += row_h + 4; row_h = 0 }
		if y + h >= oy && y <= oy + oh {
			rl.DrawTexturePro(ent.tex, {0, 0, f32(ent.tex.width), f32(ent.tex.height)}, {x, y, w, h}, {}, 0, rl.WHITE)
		}
		x += w + 8
		row_h = max(row_h, h)
	}
	return y + row_h + line_h * 0.5
}

@(private="file")
_md_span_color :: proc(style: Md_Style, default_col: rl.Color) -> rl.Color {
	switch style {
	case .Bold:   return TEXT
	case .Italic: return LINENUM
	case .Code:   return FUNC_COL
	case .Link:   return ACCENT_COL
	case .Plain:  return default_col
	}
	return default_col
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
