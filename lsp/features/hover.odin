package lsp_features

import conn "../connection"
import proto "../protocol"
import "core:encoding/json"
import "core:strings"

Hover_Callback :: proc(result: ^proto.Hover_Result, user: rawptr)

Hover_Feature :: struct {
	c:          ^conn.Conn,
	pending_id: int,
}

hover_feature_create :: proc(c: ^conn.Conn) -> ^Hover_Feature {
	hf := new(Hover_Feature)
	hf.c = c
	hf.pending_id = -1
	return hf
}

hover_feature_destroy :: proc(hf: ^Hover_Feature) {
	free(hf)
}

hover_request :: proc(hf: ^Hover_Feature, uri: string, pos: proto.Position, cb: Hover_Callback, user: rawptr) {
	if hf.pending_id >= 0 {
		conn.cancel_request(hf.c, hf.pending_id)
		hf.pending_id = -1
	}

	params := proto.td_pos_params(uri, pos)

	State :: struct { hf: ^Hover_Feature; cb: Hover_Callback; user: rawptr }
	s := new(State)
	s.hf = hf; s.cb = cb; s.user = user

	callback := proto.Response_Callback{
		proc_ = proc(result: json.Value, error: json.Value, user: rawptr) {
			s := cast(^State)user
			defer free(s)
			defer json.destroy_value(error)
			defer json.destroy_value(result)
			s.hf.pending_id = -1
			if result == nil { s.cb(nil, s.user); return }
			if _, is_null := result.(json.Null); is_null { s.cb(nil, s.user); return }
			obj, is_obj := result.(json.Object)
			if !is_obj { s.cb(nil, s.user); return }
			r := _parse_hover_result(obj)
			s.cb(r, s.user)
		},
		user = s,
	}

	hf.pending_id = conn.send_request(hf.c, "textDocument/hover", params, callback)
}

hover_cancel :: proc(hf: ^Hover_Feature) {
	if hf.pending_id >= 0 {
		conn.cancel_request(hf.c, hf.pending_id)
		hf.pending_id = -1
	}
}

_parse_hover_result :: proc(obj: json.Object) -> ^proto.Hover_Result {
	r := new(proto.Hover_Result)

	if contents_v, has := obj["contents"]; has {
		switch c in contents_v {
		case string:
			r.contents = strings.clone(c)
		case json.Object:
			if s, ok := proto.obj_str(c, "value"); ok {
				r.contents = strings.clone(s)
			}
		case json.Array:
			if len(c) > 0 {
				switch elem in c[0] {
				case string:
					r.contents = strings.clone(elem)
				case json.Object:
					if s, ok := proto.obj_str(elem, "value"); ok {
						r.contents = strings.clone(s)
					}
				}
			}
		}
	}

	if range_v, has := obj["range"]; has {
		if range_obj, ok := range_v.(json.Object); ok {
			r.range = proto.parse_range(range_obj)
			r.has_range = true
		}
	}

	return r
}
