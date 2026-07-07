package editor

// ---------------------------------------------------------------------------
// Vim text objects — iw/aw, i"/a", i(/a(, etc. Always charwise (no ip/ap
// paragraph objects — out of scope).
// ---------------------------------------------------------------------------

vim_text_object :: proc(p: ^Pane, kind: u8, obj: rune) -> (lo, hi: int, ok: bool) {
	around := kind == 'a'
	switch obj {
	case 'w': return vim_textobj_word(p, around, false)
	case 'W': return vim_textobj_word(p, around, true)
	case '"':  return vim_textobj_quote(p, around, '"')
	case '\'': return vim_textobj_quote(p, around, '\'')
	case '`':  return vim_textobj_quote(p, around, '`')
	case '(', ')', 'b': return vim_textobj_bracket(p, around, '(', ')')
	case '{', '}', 'B': return vim_textobj_bracket(p, around, '{', '}')
	case '[', ']': return vim_textobj_bracket(p, around, '[', ']')
	case '<', '>': return vim_textobj_bracket(p, around, '<', '>')
	}
	return 0, 0, false
}

vim_textobj_word :: proc(p: ^Pane, around: bool, big: bool) -> (lo, hi: int, ok: bool) {
	n := buffer_len(&p.buf)
	if n == 0 { return 0, 0, false }
	c := clamp(p.cursor, 0, n-1)
	cl := big ? _vim_class_big(buffer_get_byte(&p.buf, c)) : _vim_class(buffer_get_byte(&p.buf, c))
	lo = c
	for lo > 0 {
		pcl := big ? _vim_class_big(buffer_get_byte(&p.buf, lo-1)) : _vim_class(buffer_get_byte(&p.buf, lo-1))
		if pcl != cl { break }
		lo -= 1
	}
	hi = c
	for hi+1 < n {
		ncl := big ? _vim_class_big(buffer_get_byte(&p.buf, hi+1)) : _vim_class(buffer_get_byte(&p.buf, hi+1))
		if ncl != cl { break }
		hi += 1
	}
	hi += 1
	if around {
		orig_hi := hi
		for hi < n {
			c2 := big ? _vim_class_big(buffer_get_byte(&p.buf, hi)) : _vim_class(buffer_get_byte(&p.buf, hi))
			if c2 != .Space { break }
			hi += 1
		}
		if hi == orig_hi {
			for lo > 0 {
				c2 := big ? _vim_class_big(buffer_get_byte(&p.buf, lo-1)) : _vim_class(buffer_get_byte(&p.buf, lo-1))
				if c2 != .Space { break }
				lo -= 1
			}
		}
	}
	return lo, hi, true
}

// Quote objects scan the current line only — real Vim doesn't cross newlines
// for these.
vim_textobj_quote :: proc(p: ^Pane, around: bool, q: u8) -> (lo, hi: int, ok: bool) {
	line, _ := buffer_pos_to_line_col(&p.buf, p.cursor)
	ls := buffer_line_start(&p.buf, line)
	ll := buffer_line_length(&p.buf, line)

	positions := make([dynamic]int, 0, 8, context.temp_allocator)
	for i in 0..<ll {
		if buffer_get_byte(&p.buf, ls+i) == q { append(&positions, ls+i) }
	}
	i := 0
	for i+1 < len(positions) {
		a, b := positions[i], positions[i+1]
		if p.cursor <= b {
			if around {
				blen := buffer_len(&p.buf)
				if b+1 < blen && buffer_get_byte(&p.buf, b+1) == ' ' { return a, b+2, true }
				if a > 0 && buffer_get_byte(&p.buf, a-1) == ' ' { return a-1, b+1, true }
				return a, b+1, true
			}
			return a+1, b, true
		}
		i += 2
	}
	return 0, 0, false
}

// Balanced-depth walk outward from the cursor — can cross lines, unlike quotes.
vim_textobj_bracket :: proc(p: ^Pane, around: bool, open_ch, close_ch: u8) -> (lo, hi: int, ok: bool) {
	n := buffer_len(&p.buf)
	if n == 0 { return 0, 0, false }
	c := clamp(p.cursor, 0, n-1)

	open_pos  := -1
	close_pos := -1
	cur := buffer_get_byte(&p.buf, c)
	if cur == open_ch {
		open_pos = c
	} else if cur == close_ch {
		close_pos = c
	}

	if open_pos < 0 {
		depth := 0
		i := c - 1
		for i >= 0 {
			b := buffer_get_byte(&p.buf, i)
			if b == close_ch {
				depth += 1
			} else if b == open_ch {
				if depth == 0 { open_pos = i; break }
				depth -= 1
			}
			i -= 1
		}
	}
	if open_pos < 0 { return 0, 0, false }

	if close_pos < 0 {
		depth := 0
		for j := open_pos; j < n; j += 1 {
			b := buffer_get_byte(&p.buf, j)
			if b == open_ch {
				depth += 1
			} else if b == close_ch {
				depth -= 1
				if depth == 0 { close_pos = j; break }
			}
		}
	}
	if close_pos < 0 { return 0, 0, false }

	if around { return open_pos, close_pos+1, true }
	return open_pos+1, close_pos, true
}
