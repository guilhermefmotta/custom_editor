// Package lsp_protocol — JSON-RPC framing and JSON encoding helpers.
//
// Responsibilities:
//   - Content-Length header framing (parse + emit)
//   - JSON string escaping for building outbound params without reflection
//   - Routing (classify incoming raw bytes as request / response / notification)
//   - Typed JSON accessor helpers used by all feature modules
//
// All encoding functions produce temp-allocated strings unless noted.
// frame_message is the only function that allocates on the heap (for the
// write queue), because the framed bytes must outlive the current frame.
package lsp_protocol

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"

// ---------------------------------------------------------------------------
// Monotonic request ID
// ---------------------------------------------------------------------------

_id_mu:   sync.Mutex
_next_id: int = 1

next_id :: proc() -> int {
	sync.mutex_lock(&_id_mu)
	defer sync.mutex_unlock(&_id_mu)
	id := _next_id
	_next_id += 1
	return id
}

// ---------------------------------------------------------------------------
// Content-Length framing
// ---------------------------------------------------------------------------

// parse_header finds the first \r\n\r\n in data and extracts Content-Length.
// Returns (content_len, header_end_offset) or (-1, 0) if incomplete/invalid.
parse_header :: proc(data: []u8) -> (content_len, end: int) {
	n := len(data)
	for i := 0; i + 3 < n; i += 1 {
		if data[i] == '\r' && data[i+1] == '\n' && data[i+2] == '\r' && data[i+3] == '\n' {
			hdr := string(data[:i])
			prefix := "Content-Length: "
			idx := strings.index(hdr, prefix)
			if idx < 0 { return -1, 0 }
			num := hdr[idx + len(prefix):]
			cl, ok := strconv.parse_int(num)
			if !ok { return -1, 0 }
			return cl, i + 4
		}
	}
	return -1, 0
}

// frame_message builds a complete "Content-Length: N\r\n\r\n<body>" byte
// slice.  HEAP-allocated — the write thread deletes it after sending.
frame_message :: proc(body: string) -> []u8 {
	hdr := fmt.tprintf("Content-Length: %d\r\n\r\n", len(body))
	buf := make([]u8, len(hdr) + len(body))
	copy(buf[:len(hdr)], transmute([]u8)hdr)
	copy(buf[len(hdr):], transmute([]u8)body)
	return buf
}

// ---------------------------------------------------------------------------
// JSON-RPC message building (temp-allocated)
// ---------------------------------------------------------------------------

build_request :: proc(id: int, method, params: string) -> string {
	if params == "" || params == "null" {
		return fmt.tprintf(`{"jsonrpc":"2.0","id":%d,"method":"%s","params":{}}`, id, method)
	}
	return fmt.tprintf(`{"jsonrpc":"2.0","id":%d,"method":"%s","params":%s}`, id, method, params)
}

build_notification :: proc(method, params: string) -> string {
	if params == "" || params == "null" {
		return fmt.tprintf(`{"jsonrpc":"2.0","method":"%s","params":{}}`, method)
	}
	return fmt.tprintf(`{"jsonrpc":"2.0","method":"%s","params":%s}`, method, params)
}

build_response :: proc(id: int, result: string) -> string {
	return fmt.tprintf(`{"jsonrpc":"2.0","id":%d,"result":%s}`, id, result)
}

build_error_response :: proc(id: int, code: int, message: string) -> string {
	return fmt.tprintf(`{"jsonrpc":"2.0","id":%d,"error":{"code":%d,"message":"%s"}}`,
		id, code, message)
}

// ---------------------------------------------------------------------------
// Routing — classify an incoming raw message
// ---------------------------------------------------------------------------

// route_message peeks into the JSON to determine kind and extract id/method.
// Uses temp allocator — strings in the returned Routed_Message are valid
// until the next mem.free_all(context.temp_allocator).
// The caller must store body separately for longer lifetime.
route_message :: proc(body: []u8) -> (msg: Routed_Message, ok: bool) {
	val, err := json.parse(body, allocator = context.temp_allocator)
	if err != nil { return {}, false }
	defer json.destroy_value(val, context.temp_allocator)

	obj, is_obj := val.(json.Object)
	if !is_obj { return {}, false }

	msg.id = -1

	if id_v, has := obj["id"]; has {
		#partial switch v in id_v {
		case i64: msg.id = int(v)
		case f64: msg.id = int(v)
		}
	}

	if m_v, has := obj["method"]; has {
		if s, is_s := m_v.(string); is_s { msg.method = s }
		msg.kind = .Request if msg.id >= 0 else .Notification
	} else {
		msg.kind = .Response
	}

	return msg, true
}

// ---------------------------------------------------------------------------
// JSON string encoding (temp-allocated)
// ---------------------------------------------------------------------------

// json_str returns a JSON-quoted, escaped string literal.
json_str :: proc(s: string) -> string {
	b: strings.Builder
	strings.builder_init_len_cap(&b, 0, len(s) + 4, context.temp_allocator)
	strings.write_byte(&b, '"')
	json_escape(s, &b)
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

json_escape :: proc(s: string, b: ^strings.Builder) {
	for i := 0; i < len(s); i += 1 {
		ch := s[i]
		switch ch {
		case '"':  strings.write_string(b, `\"`)
		case '\\': strings.write_string(b, `\\`)
		case '\n': strings.write_string(b, `\n`)
		case '\r': strings.write_string(b, `\r`)
		case '\t': strings.write_string(b, `\t`)
		case:
			if ch < 0x20 { fmt.sbprintf(b, `\u%04x`, int(ch)) } else { strings.write_byte(b, ch) }
		}
	}
}

// ---------------------------------------------------------------------------
// JSON accessor helpers — extract typed values from a json.Object
// ---------------------------------------------------------------------------

obj_str :: proc(obj: json.Object, key: string) -> (string, bool) {
	v, ok := obj[key]; if !ok { return "", false }
	s, is_s := v.(string); return s, is_s
}

obj_int :: proc(obj: json.Object, key: string) -> (int, bool) {
	v, ok := obj[key]; if !ok { return 0, false }
	#partial switch n in v { case i64: return int(n), true; case f64: return int(n), true }
	return 0, false
}

obj_bool :: proc(obj: json.Object, key: string) -> (bool, bool) {
	v, ok := obj[key]; if !ok { return false, false }
	b, is_b := v.(bool); return b, is_b
}

obj_obj :: proc(obj: json.Object, key: string) -> (json.Object, bool) {
	v, ok := obj[key]; if !ok { return nil, false }
	o, is_o := v.(json.Object); return o, is_o
}

obj_arr :: proc(obj: json.Object, key: string) -> (json.Array, bool) {
	v, ok := obj[key]; if !ok { return nil, false }
	a, is_a := v.(json.Array); return a, is_a
}

// parse_json: convenience wrapper — allocator defaults to heap.
parse_json :: proc(data: []u8, allocator := context.allocator) -> (json.Value, bool) {
	val, err := json.parse(data, allocator = allocator)
	return val, err == nil
}

// ---------------------------------------------------------------------------
// URI helpers
// ---------------------------------------------------------------------------

path_to_uri :: proc(path: string) -> string {
	if len(path) == 0 { return "file://" }
	if path[0] == '/' { return fmt.tprintf("file://%s", path) }
	return fmt.tprintf("file:///%s", path)
}

uri_to_path :: proc(uri: string) -> string {
	if strings.has_prefix(uri, "file://") {
		rest := uri[7:]
		if len(rest) > 0 && rest[0] != '/' { return rest[1:] }
		return rest
	}
	return uri
}

// ---------------------------------------------------------------------------
// Deep-clone a json.Value to the heap (for callback ownership)
// ---------------------------------------------------------------------------

clone_json_value :: proc(v: json.Value) -> json.Value {
	switch val in v {
	case json.Null:   return json.Null{}
	case bool:        return val
	case i64:         return val
	case f64:         return val
	case string:      return strings.clone(val)
	case json.Array:
		arr := make(json.Array, len(val))
		for item, i in val { arr[i] = clone_json_value(item) }
		return arr
	case json.Object:
		obj := make(json.Object)
		for k, item in val { obj[strings.clone(k)] = clone_json_value(item) }
		return obj
	}
	return nil
}

// ---------------------------------------------------------------------------
// Position / Range helpers
// ---------------------------------------------------------------------------

position_to_json :: proc(p: Position) -> string {
	return fmt.tprintf(`{"line":%d,"character":%d}`, p.line, p.character)
}

range_to_json :: proc(r: Range) -> string {
	return fmt.tprintf(
		`{"start":{"line":%d,"character":%d},"end":{"line":%d,"character":%d}}`,
		r.start.line, r.start.character, r.end.line, r.end.character)
}

td_pos_params :: proc(uri: string, pos: Position) -> string {
	return fmt.tprintf(
		`{"textDocument":{"uri":%s},"position":{"line":%d,"character":%d}}`,
		json_str(uri), pos.line, pos.character)
}

parse_position :: proc(obj: json.Object) -> Position {
	line, _ := obj_int(obj, "line")
	char, _ := obj_int(obj, "character")
	return {line, char}
}

parse_range :: proc(obj: json.Object) -> Range {
	s, _ := obj_obj(obj, "start")
	e, _ := obj_obj(obj, "end")
	return {parse_position(s), parse_position(e)}
}

// path_ext — file extension without dot.
path_ext :: proc(path: string) -> string {
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '.' { return path[i+1:] }
		if path[i] == '/' || path[i] == '\\' { break }
	}
	return ""
}
