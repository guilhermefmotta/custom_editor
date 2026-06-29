package lsp

import "core:encoding/json"
import "core:fmt"
import "core:strings"

// ---------------------------------------------------------------------------
// Hover manager
// ---------------------------------------------------------------------------

Hover_State :: enum { Idle, Pending, Ready }

Hover_Manager :: struct {
	state:      Hover_State,
	request_id: int,
	result:     Hover_Result,
	// Position that was hovered when request was sent
	req_line:   int,
	req_char:   int,
}

hover_manager_init :: proc(m: ^Hover_Manager) {
	m^ = {}
	m.request_id = -1
}

hover_manager_destroy :: proc(m: ^Hover_Manager) {
	hover_result_destroy(&m.result)
}

// Send hover request for position.
hover_request :: proc(c: ^Language_Client, path: string, line, char: int) {
	if c.state != .Running || !c.caps.has_hover { return }
	m := &c.hover

	// Cancel old pending request
	if m.state == .Pending && m.request_id >= 0 {
		client_cancel_request(c, m.request_id)
	}

	hover_result_destroy(&m.result)
	m.state      = .Pending
	m.req_line   = line
	m.req_char   = char

	params := td_pos_params(path_to_uri(path), {line, char})
	m.request_id = client_send_request(c, "textDocument/hover", params, Response_Callback{
		proc_ = _on_hover_response,
	})
}

hover_clear :: proc(c: ^Language_Client) {
	m := &c.hover
	if m.state == .Pending && m.request_id >= 0 {
		client_cancel_request(c, m.request_id)
	}
	hover_result_destroy(&m.result)
	m.state      = .Idle
	m.request_id = -1
}

hover_get_result :: proc(c: ^Language_Client) -> (^Hover_Result, bool) {
	m := &c.hover
	if m.state == .Ready { return &m.result, true }
	return nil, false
}

_on_hover_response :: proc(c: ^Language_Client, result: json.Value, error: json.Value, user: rawptr) {
	defer json.destroy_value(result)
	defer json.destroy_value(error)

	m := &c.hover
	m.request_id = -1

	if error != nil || result == nil {
		m.state = .Idle
		return
	}

	// result is null → no hover at position
	if _, is_null := result.(json.Null); is_null {
		m.state = .Idle
		return
	}

	obj, is_obj := result.(json.Object)
	if !is_obj { m.state = .Idle; return }

	hover_result_destroy(&m.result)
	m.result = {}

	if contents_v, has := obj["contents"]; has {
		#partial switch v in contents_v {
		case string:
			m.result.contents = strings.clone(v)
		case json.Object:
			if val_str, ok := json_obj_str(v, "value"); ok {
				m.result.contents = strings.clone(val_str)
			}
		case json.Array:
			b: strings.Builder
			strings.builder_init(&b)
			for item_v, i in v {
				if i > 0 { strings.write_string(&b, "\n\n") }
				#partial switch iv in item_v {
				case string:
					strings.write_string(&b, iv)
				case json.Object:
					if val_str, ok2 := json_obj_str(iv, "value"); ok2 {
						strings.write_string(&b, val_str)
					}
				case: // ignore other types
				}
			}
			m.result.contents = strings.to_string(b)
		case: // Null, i64, f64, bool — ignore
		}
	}

	if range_obj, ok := json_obj_obj(obj, "range"); ok {
		m.result.range     = parse_range(range_obj)
		m.result.has_range = true
	}

	m.state = .Ready
}
