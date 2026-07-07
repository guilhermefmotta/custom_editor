package editor

// ---------------------------------------------------------------------------
// Vim motions — pure functions of a `from` position (never read/write
// p.cursor directly) so the same motion can drive plain cursor movement,
// an operator's target range, or Visual-mode selection extension.
// ---------------------------------------------------------------------------

_vim_class :: proc(ch: u8) -> Vim_Char_Class {
	switch {
	case ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r':
		return .Space
	case is_word(ch):
		return .Word
	case:
		return .Punct
	}
}

// W/B/E use blank-vs-non-blank only, no punctuation split.
_vim_class_big :: proc(ch: u8) -> Vim_Char_Class {
	if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' { return .Space }
	return .Word
}

vim_word_fwd :: proc(p: ^Pane, from: int, big: bool) -> int {
	n := buffer_len(&p.buf)
	pos := from
	if pos >= n { return pos }
	start_class := big ? _vim_class_big(buffer_get_byte(&p.buf, pos)) : _vim_class(buffer_get_byte(&p.buf, pos))
	if start_class != .Space {
		for pos < n {
			cl := big ? _vim_class_big(buffer_get_byte(&p.buf, pos)) : _vim_class(buffer_get_byte(&p.buf, pos))
			if cl != start_class { break }
			pos += 1
		}
	}
	for pos < n {
		cl := big ? _vim_class_big(buffer_get_byte(&p.buf, pos)) : _vim_class(buffer_get_byte(&p.buf, pos))
		if cl != .Space { break }
		pos += 1
	}
	return pos
}

vim_word_back :: proc(p: ^Pane, from: int, big: bool) -> int {
	pos := from
	if pos <= 0 { return 0 }
	pos -= 1
	for pos > 0 {
		cl := big ? _vim_class_big(buffer_get_byte(&p.buf, pos)) : _vim_class(buffer_get_byte(&p.buf, pos))
		if cl != .Space { break }
		pos -= 1
	}
	if pos == 0 { return 0 }
	cl := big ? _vim_class_big(buffer_get_byte(&p.buf, pos)) : _vim_class(buffer_get_byte(&p.buf, pos))
	for pos > 0 {
		pcl := big ? _vim_class_big(buffer_get_byte(&p.buf, pos-1)) : _vim_class(buffer_get_byte(&p.buf, pos-1))
		if pcl != cl { break }
		pos -= 1
	}
	return pos
}

// Inclusive motion — lands ON the last char of the word.
vim_word_end :: proc(p: ^Pane, from: int, big: bool) -> int {
	n := buffer_len(&p.buf)
	if n == 0 { return 0 }
	pos := from
	if pos >= n-1 { return n-1 }
	pos += 1
	for pos < n {
		cl := big ? _vim_class_big(buffer_get_byte(&p.buf, pos)) : _vim_class(buffer_get_byte(&p.buf, pos))
		if cl != .Space { break }
		pos += 1
	}
	if pos >= n { return n-1 }
	cl := big ? _vim_class_big(buffer_get_byte(&p.buf, pos)) : _vim_class(buffer_get_byte(&p.buf, pos))
	for pos+1 < n {
		ncl := big ? _vim_class_big(buffer_get_byte(&p.buf, pos+1)) : _vim_class(buffer_get_byte(&p.buf, pos+1))
		if ncl != cl { break }
		pos += 1
	}
	return pos
}

vim_repeat_word_fwd  :: proc(p: ^Pane, from: int, big: bool, count: int) -> int { pos := from; for _ in 0..<max(1,count) { pos = vim_word_fwd(p, pos, big) };  return pos }
vim_repeat_word_back :: proc(p: ^Pane, from: int, big: bool, count: int) -> int { pos := from; for _ in 0..<max(1,count) { pos = vim_word_back(p, pos, big) }; return pos }
vim_repeat_word_end  :: proc(p: ^Pane, from: int, big: bool, count: int) -> int { pos := from; for _ in 0..<max(1,count) { pos = vim_word_end(p, pos, big) };  return pos }

vim_line_first_nonblank :: proc(p: ^Pane, line: int) -> int {
	ls := buffer_line_start(&p.buf, line)
	ll := buffer_line_length(&p.buf, line)
	i := 0
	for i < ll {
		b := buffer_get_byte(&p.buf, ls+i)
		if b != ' ' && b != '\t' { break }
		i += 1
	}
	return ls + i
}

vim_goto_line :: proc(p: ^Pane, line: int) -> int {
	total := buffer_line_count(&p.buf)
	l := clamp(line, 0, total-1)
	return vim_line_first_nonblank(p, l)
}

// f/F/t/T. forward=true for f/t, false for F/T; till=true for t/T (lands one
// char short of the target instead of on it).
vim_find_char :: proc(p: ^Pane, from: int, ch: u8, forward: bool, till: bool) -> (pos: int, ok: bool) {
	n := buffer_len(&p.buf)
	if forward {
		i := from + 1
		for i < n {
			if buffer_get_byte(&p.buf, i) == ch { return (till ? i-1 : i), true }
			i += 1
		}
	} else {
		i := from - 1
		for i >= 0 {
			if buffer_get_byte(&p.buf, i) == ch { return (till ? i+1 : i), true }
			i -= 1
		}
	}
	return from, false
}

// %  — jump to the bracket matching the first paren/bracket/brace at or
// after the cursor on the current line.
vim_matching_bracket :: proc(p: ^Pane, from: int) -> (pos: int, ok: bool) {
	n := buffer_len(&p.buf)
	pairs := [3][2]u8{{'(', ')'}, {'[', ']'}, {'{', '}'}}
	i := from
	open_ch, close_ch: u8
	forward := true
	found := false
	for i < n {
		b := buffer_get_byte(&p.buf, i)
		if b == '\n' { break }
		for pr in pairs {
			if b == pr[0] { open_ch, close_ch = pr[0], pr[1]; forward = true;  found = true; break }
			if b == pr[1] { open_ch, close_ch = pr[0], pr[1]; forward = false; found = true; break }
		}
		if found { break }
		i += 1
	}
	if !found { return from, false }
	depth := 0
	if forward {
		for j := i; j < n; j += 1 {
			b := buffer_get_byte(&p.buf, j)
			if b == open_ch { depth += 1 } else if b == close_ch { depth -= 1; if depth == 0 { return j, true } }
		}
	} else {
		for j := i; j >= 0; j -= 1 {
			b := buffer_get_byte(&p.buf, j)
			if b == close_ch { depth += 1 } else if b == open_ch { depth -= 1; if depth == 0 { return j, true } }
		}
	}
	return from, false
}
