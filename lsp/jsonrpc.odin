package lsp

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"

// ---------------------------------------------------------------------------
// Request ID — monotonically increasing, protected by mutex
// ---------------------------------------------------------------------------

_id_mu:   sync.Mutex
_next_id: int = 1

next_request_id :: proc() -> int {
	sync.mutex_lock(&_id_mu)
	defer sync.mutex_unlock(&_id_mu)
	id := _next_id
	_next_id += 1
	return id
}

// ---------------------------------------------------------------------------
// Inbox message — raw body bytes owned by consumer
// ---------------------------------------------------------------------------

Inbox_Message :: struct {
	body: []u8, // heap-allocated full JSON body; consumer must delete
}

// ---------------------------------------------------------------------------
// Content-Length framing
// ---------------------------------------------------------------------------

// Returns (content_length, header_end_offset) or (-1, 0) if incomplete/invalid.
parse_header :: proc(data: []u8) -> (content_len: int, end: int) {
	i := 0
	n := len(data)
	for i + 3 < n {
		if data[i] == '\r' && data[i+1] == '\n' && data[i+2] == '\r' && data[i+3] == '\n' {
			header_str := string(data[:i])
			cl_prefix  := "Content-Length: "
			idx        := strings.index(header_str, cl_prefix)
			if idx < 0 { return -1, 0 }
			num_start  := idx + len(cl_prefix)
			num_end    := num_start
			for num_end < len(header_str) && header_str[num_end] >= '0' && header_str[num_end] <= '9' {
				num_end += 1
			}
			cl, ok := strconv.parse_int(header_str[num_start:num_end])
			if !ok { return -1, 0 }
			return cl, i + 4
		}
		i += 1
	}
	return -1, 0 // incomplete header
}

// Build framed message: Content-Length header + \r\n\r\n + body.
// Returned slice is heap-allocated; caller owns it.
frame_message :: proc(body: string) -> []u8 {
	header := fmt.tprintf("Content-Length: %d\r\n\r\n", len(body))
	buf := make([]u8, len(header) + len(body))
	copy(buf[:len(header)], transmute([]u8)header)
	copy(buf[len(header):], transmute([]u8)body)
	return buf
}

// ---------------------------------------------------------------------------
// JSON construction helpers (generates JSON strings, no reflection)
// ---------------------------------------------------------------------------

// Escape s for use inside a JSON string literal.
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
			if ch < 0x20 {
				fmt.sbprintf(b, `\u%04x`, int(ch))
			} else {
				strings.write_byte(b, ch)
			}
		}
	}
}

// Return JSON-quoted, escaped string. Uses temp allocator.
json_str :: proc(s: string) -> string {
	b: strings.Builder
	strings.builder_init_len_cap(&b, 0, len(s) + 4, context.temp_allocator)
	strings.write_byte(&b, '"')
	json_escape(s, &b)
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

// Build a JSON-RPC 2.0 request string (temp-allocated).
build_request :: proc(id: int, method: string, params: string) -> string {
	if params == "" {
		return fmt.tprintf(`{"jsonrpc":"2.0","id":%d,"method":"%s"}`, id, method)
	}
	return fmt.tprintf(`{"jsonrpc":"2.0","id":%d,"method":"%s","params":%s}`, id, method, params)
}

// Build a JSON-RPC 2.0 notification string (temp-allocated).
build_notification :: proc(method: string, params: string) -> string {
	if params == "" {
		return fmt.tprintf(`{"jsonrpc":"2.0","method":"%s"}`, method)
	}
	return fmt.tprintf(`{"jsonrpc":"2.0","method":"%s","params":%s}`, method, params)
}

// ---------------------------------------------------------------------------
// JSON extraction helpers — parse a raw body and extract routing fields.
// Allocates into temp_allocator; caller owns the returned strings until
// the next mem.free_all(context.temp_allocator).
// ---------------------------------------------------------------------------

Routed_Message :: struct {
	id:          int,   // -1 if absent
	method:      string, // empty for responses
	is_response: bool,
	raw_params:  string, // sub-slice of body string pointing at "params" value
	raw_result:  string, // sub-slice of body string pointing at "result" value
	raw_error:   string, // sub-slice of body string pointing at "error" value
}

// Route a raw body. Does a full parse via json.parse (temp alloc).
// Returns false on parse failure.
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
		if s, is_s := m_v.(string); is_s {
			msg.method = s
		}
		msg.is_response = false
	} else {
		msg.is_response = true
	}

	// For params/result/error we would need to re-extract from body.
	// Callers that need them re-parse body themselves.
	return msg, true
}

// ---------------------------------------------------------------------------
// JSON value accessors — used by feature modules
// ---------------------------------------------------------------------------

json_obj_get :: proc(obj: json.Object, key: string) -> (json.Value, bool) {
	v, ok := obj[key]
	return v, ok
}

json_obj_str :: proc(obj: json.Object, key: string) -> (string, bool) {
	v, ok := obj[key]
	if !ok { return "", false }
	s, is_s := v.(string)
	return s, is_s
}

json_obj_int :: proc(obj: json.Object, key: string) -> (int, bool) {
	v, ok := obj[key]
	if !ok { return 0, false }
	#partial switch n in v {
	case i64: return int(n), true
	case f64: return int(n), true
	}
	return 0, false
}

json_obj_bool :: proc(obj: json.Object, key: string) -> (bool, bool) {
	v, ok := obj[key]
	if !ok { return false, false }
	b, is_b := v.(bool)
	return b, is_b
}

json_obj_obj :: proc(obj: json.Object, key: string) -> (json.Object, bool) {
	v, ok := obj[key]
	if !ok { return nil, false }
	o, is_o := v.(json.Object)
	return o, is_o
}

json_obj_arr :: proc(obj: json.Object, key: string) -> (json.Array, bool) {
	v, ok := obj[key]
	if !ok { return nil, false }
	a, is_a := v.(json.Array)
	return a, is_a
}

// Parse a json.Value from raw bytes.  Allocates into provided allocator.
parse_json :: proc(data: []u8, allocator := context.allocator) -> (json.Value, bool) {
	val, err := json.parse(data, allocator = allocator)
	return val, err == nil
}

json_path_obj :: proc(obj: json.Object, keys: ..string) -> (json.Object, bool) {
	cur := obj
	for key, i in keys {
		v, ok := cur[key]
		if !ok { return nil, false }
		if i == len(keys) - 1 {
			o, is_o := v.(json.Object)
			return o, is_o
		}
		next, is_o := v.(json.Object)
		if !is_o { return nil, false }
		cur = next
	}
	return cur, true
}
