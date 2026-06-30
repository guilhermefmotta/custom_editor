package config

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

// ---------------------------------------------------------------------------
// TOML value tree  (all strings are heap-owned; call toml_destroy to free)
//
// TOML_Value is a plain struct (not a union) to avoid Odin's restriction on
// recursive union types.  kind+rawptr breaks the type-system cycle while
// keeping map[string]TOML_Value (a struct value) assignable without issue.
// ---------------------------------------------------------------------------

TOML_Kind :: enum u8 { Null, Str, Int, Float, Bool, Array, Table }

TOML_Value :: struct {
	kind: TOML_Kind,
	str:  string,  // valid when kind == .Str
	i:    i64,     // valid when kind == .Int
	f:    f64,     // valid when kind == .Float
	b:    bool,    // valid when kind == .Bool
	ptr:  rawptr,  // ^TOML_Array when .Array, ^TOML_Table when .Table
}

TOML_Array :: [dynamic]TOML_Value
TOML_Table :: map[string]TOML_Value

// Typed constructors
@(private) _tv_str   :: proc(s: string) -> TOML_Value          { return {kind=.Str,   str=s} }
@(private) _tv_int   :: proc(n: i64)    -> TOML_Value          { return {kind=.Int,   i=n}   }
@(private) _tv_float :: proc(f: f64)    -> TOML_Value          { return {kind=.Float, f=f}   }
@(private) _tv_bool  :: proc(b: bool)   -> TOML_Value          { return {kind=.Bool,  b=b}   }
@(private) _tv_arr   :: proc(a: ^TOML_Array) -> TOML_Value     { return {kind=.Array, ptr=a} }
@(private) _tv_tbl   :: proc(t: ^TOML_Table) -> TOML_Value     { return {kind=.Table, ptr=t} }

// Internal destroy helpers
@(private)
_destroy_arr :: proc(a: ^TOML_Array) {
	for item in a^ { toml_destroy(item) }
	delete(a^); free(a)
}

@(private)
_destroy_tbl :: proc(t: ^TOML_Table) {
	for k, v in t^ { delete(k); toml_destroy(v) }
	delete(t^); free(t)
}

toml_destroy :: proc(v: TOML_Value) {
	#partial switch v.kind {
	case .Str:   delete(v.str)
	case .Array: _destroy_arr(cast(^TOML_Array)v.ptr)
	case .Table: _destroy_tbl(cast(^TOML_Table)v.ptr)
	}
}

// Destroy the root table returned by toml_parse / toml_load_file.
toml_destroy_table :: proc(t: ^TOML_Table) {
	if t == nil { return }
	for k, v in t^ { delete(k); toml_destroy(v) }
	delete(t^); free(t)
}

// ---------------------------------------------------------------------------
// Typed accessors — all take ^TOML_Table
// ---------------------------------------------------------------------------

toml_str :: proc(t: ^TOML_Table, key: string) -> (string, bool) {
	v, ok := t^[key]; if !ok || v.kind != .Str { return "", false }
	return v.str, true
}
toml_int :: proc(t: ^TOML_Table, key: string) -> (i64, bool) {
	v, ok := t^[key]; if !ok || v.kind != .Int { return 0, false }
	return v.i, true
}
toml_uint :: proc(t: ^TOML_Table, key: string) -> (u64, bool) {
	n, ok := toml_int(t, key); return u64(n), ok
}
toml_float :: proc(t: ^TOML_Table, key: string) -> (f64, bool) {
	v, ok := t^[key]; if !ok { return 0, false }
	if v.kind == .Float { return v.f, true }
	if v.kind == .Int   { return f64(v.i), true }
	return 0, false
}
toml_bool :: proc(t: ^TOML_Table, key: string) -> (bool, bool) {
	v, ok := t^[key]; if !ok || v.kind != .Bool { return false, false }
	return v.b, true
}
toml_table :: proc(t: ^TOML_Table, key: string) -> (^TOML_Table, bool) {
	v, ok := t^[key]; if !ok || v.kind != .Table { return nil, false }
	return cast(^TOML_Table)v.ptr, true
}
toml_array :: proc(t: ^TOML_Table, key: string) -> (^TOML_Array, bool) {
	v, ok := t^[key]; if !ok || v.kind != .Array { return nil, false }
	return cast(^TOML_Array)v.ptr, true
}

// ---------------------------------------------------------------------------
// Lexer
// ---------------------------------------------------------------------------

_TK :: enum u8 {
	EOF, NL,
	Eq, Dot, Comma, LBrack, RBrack, LBrace, RBrace,
	DblLBrack, DblRBrack,
	Key,   // bare key  (slice into source, NOT heap-owned)
	Str,   // string    (heap-owned)
	Int,   // integer   (heap-owned decimal string)
	Float, // float     (heap-owned decimal string)
	Bool,  // true/false (slice into source)
}

_Tok :: struct { kind: _TK, val: string, line: int }
_Lex :: struct { src: string, pos, line: int }

@(private)
_la :: proc(l: ^_Lex, off: int = 0) -> u8 {
	i := l.pos + off
	if i >= len(l.src) { return 0 }
	return l.src[i]
}

@(private)
_adv :: proc(l: ^_Lex) -> u8 {
	if l.pos >= len(l.src) { return 0 }
	ch := l.src[l.pos]; l.pos += 1
	if ch == '\n' { l.line += 1 }
	return ch
}

@(private)
_skip_ws :: proc(l: ^_Lex) {
	for l.pos < len(l.src) {
		ch := l.src[l.pos]
		if ch == ' ' || ch == '\t' || ch == '\r' {
			l.pos += 1
		} else if ch == '#' {
			for l.pos < len(l.src) && l.src[l.pos] != '\n' { l.pos += 1 }
		} else {
			break
		}
	}
}

@(private)
_read_basic :: proc(l: ^_Lex) -> (string, bool) {
	b: strings.Builder; strings.builder_init(&b)
	for l.pos < len(l.src) {
		ch := l.src[l.pos]
		if ch == '"' { l.pos += 1; return strings.to_string(b), true }
		if ch == '\\' {
			l.pos += 1
			if l.pos >= len(l.src) { break }
			esc := l.src[l.pos]; l.pos += 1
			switch esc {
			case 'n':  strings.write_byte(&b, '\n')
			case 't':  strings.write_byte(&b, '\t')
			case 'r':  strings.write_byte(&b, '\r')
			case '"':  strings.write_byte(&b, '"')
			case '\\': strings.write_byte(&b, '\\')
			case 'u', 'U':
				n := 4; if esc == 'U' { n = 8 }
				if l.pos+n <= len(l.src) {
					code, _ := strconv.parse_int(l.src[l.pos:l.pos+n], 16)
					bytes, sz := utf8.encode_rune(rune(code))
					strings.write_bytes(&b, bytes[:sz])
					l.pos += n
				}
			}
		} else {
			if ch == '\n' { l.line += 1 }
			l.pos += 1
			strings.write_byte(&b, ch)
		}
	}
	strings.builder_destroy(&b); return "", false
}

@(private)
_read_ml_basic :: proc(l: ^_Lex) -> (string, bool) {
	if _la(l) == '\n' { l.pos += 1; l.line += 1 }
	b: strings.Builder; strings.builder_init(&b)
	for l.pos < len(l.src) {
		if l.src[l.pos] == '"' && _la(l,1) == '"' && _la(l,2) == '"' {
			l.pos += 3; return strings.to_string(b), true
		}
		ch := l.src[l.pos]; l.pos += 1
		if ch == '\n' { l.line += 1 }
		strings.write_byte(&b, ch)
	}
	strings.builder_destroy(&b); return "", false
}

@(private)
_read_literal :: proc(l: ^_Lex) -> (string, bool) {
	start := l.pos
	for l.pos < len(l.src) && l.src[l.pos] != '\'' { l.pos += 1 }
	if l.pos >= len(l.src) { return "", false }
	s := strings.clone(l.src[start:l.pos]); l.pos += 1
	return s, true
}

@(private)
_read_ml_literal :: proc(l: ^_Lex) -> (string, bool) {
	if _la(l) == '\n' { l.pos += 1; l.line += 1 }
	start := l.pos
	for l.pos < len(l.src) {
		if l.src[l.pos] == '\'' && _la(l,1) == '\'' && _la(l,2) == '\'' {
			s := strings.clone(l.src[start:l.pos]); l.pos += 3
			return s, true
		}
		if l.src[l.pos] == '\n' { l.line += 1 }
		l.pos += 1
	}
	return "", false
}

@(private)
_is_bare :: proc(ch: u8) -> bool {
	return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
	       (ch >= '0' && ch <= '9') || ch == '_' || ch == '-'
}

@(private)
_lex_next :: proc(l: ^_Lex) -> _Tok {
	_skip_ws(l)
	ln := l.line
	if l.pos >= len(l.src) { return {.EOF, "", ln} }
	ch := l.src[l.pos]

	switch ch {
	case '\n': l.pos += 1; l.line += 1; return {.NL, "", ln}
	case '=':  l.pos += 1; return {.Eq,    "", ln}
	case '.':  l.pos += 1; return {.Dot,   "", ln}
	case ',':  l.pos += 1; return {.Comma, "", ln}
	case '{':  l.pos += 1; return {.LBrace,"", ln}
	case '}':  l.pos += 1; return {.RBrace,"", ln}
	case '[':
		if _la(l, 1) == '[' { l.pos += 2; return {.DblLBrack, "", ln} }
		l.pos += 1; return {.LBrack, "", ln}
	case ']':
		if _la(l, 1) == ']' { l.pos += 2; return {.DblRBrack, "", ln} }
		l.pos += 1; return {.RBrack, "", ln}
	case '"':
		l.pos += 1
		if _la(l, 0) == '"' && _la(l, 1) == '"' {
			l.pos += 2
			s, ok := _read_ml_basic(l); if !ok { return {.EOF, "", ln} }
			return {.Str, s, ln}
		}
		s, ok := _read_basic(l); if !ok { return {.EOF, "", ln} }
		return {.Str, s, ln}
	case '\'':
		l.pos += 1
		if _la(l, 0) == '\'' && _la(l, 1) == '\'' {
			l.pos += 2
			s, ok := _read_ml_literal(l); if !ok { return {.EOF, "", ln} }
			return {.Str, s, ln}
		}
		s, ok := _read_literal(l); if !ok { return {.EOF, "", ln} }
		return {.Str, s, ln}
	}

	if _is_bare(ch) {
		start := l.pos
		for l.pos < len(l.src) && _is_bare(l.src[l.pos]) { l.pos += 1 }
		word := l.src[start:l.pos]
		if word == "true" || word == "false" { return {.Bool, word, ln} }
		if word == "inf"  || word == "nan"  || word == "+inf" || word == "-inf" ||
		   word == "+nan" || word == "-nan" { return {.Float, strings.clone(word), ln} }
		return {.Key, word, ln}
	}

	if ch == '-' || ch == '+' || (ch >= '0' && ch <= '9') {
		start := l.pos; is_f := false
		if ch == '-' || ch == '+' { l.pos += 1 }
		if _la(l) == '0' && (l.pos+1 < len(l.src)) {
			next := _la(l, 1)
			if next == 'x' || next == 'o' || next == 'b' {
				l.pos += 2
				for l.pos < len(l.src) && _is_bare(l.src[l.pos]) { l.pos += 1 }
				n, _ := strconv.parse_i64(l.src[start:l.pos])
				return {.Int, fmt.aprintf("%d", n), ln}
			}
		}
		for l.pos < len(l.src) {
			c2 := l.src[l.pos]
			if c2 >= '0' && c2 <= '9' || c2 == '_' { l.pos += 1 } else
			if c2 == '.' || c2 == 'e' || c2 == 'E' { is_f = true; l.pos += 1 } else
			if (c2 == '+' || c2 == '-') && l.pos > start+1 { l.pos += 1 } else { break }
		}
		raw := l.src[start:l.pos]
		clean, _ := strings.replace_all(raw, "_", "", context.temp_allocator)
		if is_f { return {.Float, strings.clone(clean), ln} }
		return {.Int, strings.clone(clean), ln}
	}

	l.pos += 1
	return _lex_next(l)
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

_Par :: struct {
	l:    _Lex,
	cur:  _Tok,
	peek: _Tok,
}

_par_init :: proc(p: ^_Par, src: string) {
	p.l    = _Lex{src=src, line=1}
	p.cur  = _lex_next(&p.l)
	p.peek = _lex_next(&p.l)
}

_par_adv :: proc(p: ^_Par) -> _Tok {
	t := p.cur; p.cur = p.peek; p.peek = _lex_next(&p.l); return t
}

_par_skip_nl :: proc(p: ^_Par) {
	for p.cur.kind == .NL { _par_adv(p) }
}

_par_expect :: proc(p: ^_Par, k: _TK) -> bool {
	if p.cur.kind != k { return false }
	_par_adv(p); return true
}

_par_key_seg :: proc(p: ^_Par) -> (string, bool) {
	t := p.cur
	#partial switch t.kind {
	case .Key:  _par_adv(p); return strings.clone(t.val), true
	case .Str:  _par_adv(p); return t.val, true
	case .Int:  _par_adv(p); return t.val, true
	case .Bool: _par_adv(p); return strings.clone(t.val), true
	case:       return "", false
	}
}

_par_key :: proc(p: ^_Par) -> ([]string, bool) {
	parts: [dynamic]string
	seg, ok := _par_key_seg(p)
	if !ok { return nil, false }
	append(&parts, seg)
	for p.cur.kind == .Dot {
		_par_adv(p)
		seg2, ok2 := _par_key_seg(p)
		if !ok2 { for k in parts { delete(k) }; delete(parts); return nil, false }
		append(&parts, seg2)
	}
	return parts[:], true
}

@(private)
_tbl_set :: proc(tbl: ^TOML_Table, keys: []string, val: TOML_Value) {
	if len(keys) == 0 { return }
	k := keys[0]
	if len(keys) == 1 {
		if old, exists := tbl^[k]; exists {
			toml_destroy(old)
			tbl^[k] = val
		} else {
			tbl^[strings.clone(k)] = val
		}
		return
	}
	if v, exists := tbl^[k]; exists {
		if v.kind == .Table { _tbl_set(cast(^TOML_Table)v.ptr, keys[1:], val); return }
		return
	}
	sub := new(TOML_Table); sub^ = make(TOML_Table)
	tbl^[strings.clone(k)] = _tv_tbl(sub)
	_tbl_set(sub, keys[1:], val)
}

@(private)
_get_or_create :: proc(root: ^TOML_Table, keys: []string) -> ^TOML_Table {
	cur := root
	for k in keys {
		v, exists := cur^[k]
		if !exists {
			sub := new(TOML_Table); sub^ = make(TOML_Table)
			cur^[strings.clone(k)] = _tv_tbl(sub)
			cur = sub; continue
		}
		if v.kind == .Array {
			arr := cast(^TOML_Array)v.ptr
			if len(arr^) > 0 {
				last := arr^[len(arr^)-1]
				if last.kind == .Table { cur = cast(^TOML_Table)last.ptr; continue }
			}
		}
		if v.kind == .Table { cur = cast(^TOML_Table)v.ptr; continue }
		break
	}
	return cur
}

_par_val :: proc(p: ^_Par) -> (TOML_Value, bool) {
	t := p.cur
	#partial switch t.kind {
	case .Str:
		_par_adv(p); return _tv_str(t.val), true
	case .Bool:
		_par_adv(p); return _tv_bool(t.val == "true"), true
	case .Int:
		_par_adv(p); n, _ := strconv.parse_i64(t.val); delete(t.val)
		return _tv_int(n), true
	case .Float:
		_par_adv(p); f, _ := strconv.parse_f64(t.val); delete(t.val)
		return _tv_float(f), true
	case .LBrack: return _par_array(p)
	case .LBrace: return _par_inline_tbl(p)
	case:         return {}, false
	}
}

_par_array :: proc(p: ^_Par) -> (TOML_Value, bool) {
	if !_par_expect(p, .LBrack) { return {}, false }
	arr := new(TOML_Array); arr^ = make(TOML_Array)
	_par_skip_nl(p)
	for p.cur.kind != .RBrack && p.cur.kind != .EOF {
		v, ok := _par_val(p)
		if !ok { _destroy_arr(arr); return {}, false }
		append(arr, v)
		_par_skip_nl(p)
		if p.cur.kind == .Comma { _par_adv(p); _par_skip_nl(p) } else { break }
	}
	_par_skip_nl(p)
	if !_par_expect(p, .RBrack) { _destroy_arr(arr); return {}, false }
	return _tv_arr(arr), true
}

_par_inline_tbl :: proc(p: ^_Par) -> (TOML_Value, bool) {
	if !_par_expect(p, .LBrace) { return {}, false }
	tbl := new(TOML_Table); tbl^ = make(TOML_Table)
	for p.cur.kind != .RBrace && p.cur.kind != .EOF {
		keys, ok := _par_key(p)
		if !ok { break }
		if !_par_expect(p, .Eq) { for k in keys { delete(k) }; delete(keys); break }
		val, ok2 := _par_val(p)
		if ok2 { _tbl_set(tbl, keys, val) }
		for k in keys { delete(k) }; delete(keys)
		if p.cur.kind == .Comma { _par_adv(p) } else { break }
	}
	_par_expect(p, .RBrace)
	return _tv_tbl(tbl), true
}

// ---------------------------------------------------------------------------
// Parse a complete TOML document
// ---------------------------------------------------------------------------

toml_parse :: proc(src: string) -> (root: ^TOML_Table, ok: bool) {
	p: _Par
	_par_init(&p, src)
	root = new(TOML_Table); root^ = make(TOML_Table)
	cur_tbl := root

	_par_skip_nl(&p)

	for p.cur.kind != .EOF {
		if p.cur.kind == .DblLBrack {
			_par_adv(&p)
			keys, kok := _par_key(&p)
			if !kok || !_par_expect(&p, .DblRBrack) {
				if kok { for k in keys { delete(k) }; delete(keys) }
				_par_skip_nl(&p); continue
			}
			parent := _get_or_create(root, keys[:len(keys)-1])
			last_key := keys[len(keys)-1]

			if v, exists := parent^[last_key]; exists {
				if v.kind == .Array {
					arr := cast(^TOML_Array)v.ptr
					new_tbl := new(TOML_Table); new_tbl^ = make(TOML_Table)
					append(arr, _tv_tbl(new_tbl))
					cur_tbl = new_tbl
				}
			} else {
				arr := new(TOML_Array); arr^ = make(TOML_Array)
				new_tbl := new(TOML_Table); new_tbl^ = make(TOML_Table)
				append(arr, _tv_tbl(new_tbl))
				parent^[strings.clone(last_key)] = _tv_arr(arr)
				cur_tbl = new_tbl
			}
			for k in keys { delete(k) }; delete(keys)
			_par_skip_nl(&p); continue
		}

		if p.cur.kind == .LBrack {
			_par_adv(&p)
			keys, kok := _par_key(&p)
			if !kok || !_par_expect(&p, .RBrack) {
				if kok { for k in keys { delete(k) }; delete(keys) }
				_par_skip_nl(&p); continue
			}
			cur_tbl = _get_or_create(root, keys)
			for k in keys { delete(k) }; delete(keys)
			_par_skip_nl(&p); continue
		}

		if p.cur.kind == .Key || p.cur.kind == .Str ||
		   p.cur.kind == .Int || p.cur.kind == .Bool {
			keys, kok := _par_key(&p)
			if !kok { _par_skip_nl(&p); continue }
			if !_par_expect(&p, .Eq) {
				for k in keys { delete(k) }; delete(keys)
				_par_skip_nl(&p); continue
			}
			val, vok := _par_val(&p)
			if vok { _tbl_set(cur_tbl, keys, val) }
			for k in keys { delete(k) }; delete(keys)
			_par_skip_nl(&p); continue
		}

		_par_adv(&p)
		_par_skip_nl(&p)
	}

	return root, true
}

toml_load_file :: proc(path: string) -> (^TOML_Table, bool) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil { return nil, false }
	defer delete(data)
	return toml_parse(string(data))
}
