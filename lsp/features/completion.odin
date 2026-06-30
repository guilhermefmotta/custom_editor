package lsp_features

import conn "../connection"
import proto "../protocol"
import "core:encoding/json"
import "core:fmt"
import "core:strings"

Completion_Result :: struct {
	items:      []proto.Completion_Item,
	incomplete: bool,
}

completion_result_destroy :: proc(r: ^Completion_Result) {
	for &item in r.items { proto.completion_item_destroy(&item) }
	delete(r.items)
}

Completion_Callback :: proc(result: ^Completion_Result, user: rawptr)

Completion_Feature :: struct {
	c:          ^conn.Conn,
	pending_id: int,
}

completion_feature_create :: proc(c: ^conn.Conn) -> ^Completion_Feature {
	cf := new(Completion_Feature)
	cf.c = c
	cf.pending_id = -1
	return cf
}

completion_feature_destroy :: proc(cf: ^Completion_Feature) {
	free(cf)
}

completion_request :: proc(
	cf: ^Completion_Feature,
	uri: string,
	pos: proto.Position,
	trigger_char: string,
	cb: Completion_Callback,
	user: rawptr,
) {
	if cf.pending_id >= 0 {
		conn.cancel_request(cf.c, cf.pending_id)
		cf.pending_id = -1
	}

	var params: string
	if trigger_char != "" {
		params = fmt.tprintf(
			`{"textDocument":{"uri":%s},"position":{"line":%d,"character":%d},"context":{"triggerKind":2,"triggerCharacter":%s}}`,
			proto.json_str(uri), pos.line, pos.character, proto.json_str(trigger_char),
		)
	} else {
		params = fmt.tprintf(
			`{"textDocument":{"uri":%s},"position":{"line":%d,"character":%d},"context":{"triggerKind":1}}`,
			proto.json_str(uri), pos.line, pos.character,
		)
	}

	State :: struct { cf: ^Completion_Feature; cb: Completion_Callback; user: rawptr }
	s := new(State)
	s.cf = cf; s.cb = cb; s.user = user

	callback := proto.Response_Callback{
		proc_ = proc(result: json.Value, error: json.Value, user: rawptr) {
			s := cast(^State)user
			defer free(s)
			defer json.destroy_value(error)
			defer json.destroy_value(result)
			s.cf.pending_id = -1
			if result == nil {
				s.cb(nil, s.user)
				return
			}
			r := _parse_completion_result(result)
			if r == nil {
				s.cb(nil, s.user)
				return
			}
			s.cb(r, s.user)
		},
		user = s,
	}

	cf.pending_id = conn.send_request(cf.c, "textDocument/completion", params, callback)
}

completion_cancel :: proc(cf: ^Completion_Feature) {
	if cf.pending_id >= 0 {
		conn.cancel_request(cf.c, cf.pending_id)
		cf.pending_id = -1
	}
}

_parse_completion_result :: proc(val: json.Value) -> ^Completion_Result {
	r := new(Completion_Result)

	switch v in val {
	case json.Array:
		r.items = make([]proto.Completion_Item, len(v))
		for elem, i in v {
			if obj, ok := elem.(json.Object); ok {
				r.items[i] = _parse_completion_item(obj)
			}
		}
	case json.Object:
		if incomplete, ok := v["isIncomplete"].(bool); ok { r.incomplete = incomplete }
		if items_val, has := v["items"]; has {
			if arr, ok := items_val.(json.Array); ok {
				r.items = make([]proto.Completion_Item, len(arr))
				for elem, i in arr {
					if obj, ok2 := elem.(json.Object); ok2 {
						r.items[i] = _parse_completion_item(obj)
					}
				}
			}
		}
	case:
		free(r)
		return nil
	}
	return r
}

_parse_completion_item :: proc(obj: json.Object) -> proto.Completion_Item {
	item: proto.Completion_Item

	if s, ok := proto.obj_str(obj, "label"); ok { item.label = strings.clone(s) }
	if n, ok := proto.obj_int(obj, "kind");  ok { item.kind = proto.Completion_Item_Kind(n) }
	if s, ok := proto.obj_str(obj, "detail"); ok { item.detail = strings.clone(s) }
	if s, ok := proto.obj_str(obj, "sortText");   ok { item.sort_text   = strings.clone(s) }
	if s, ok := proto.obj_str(obj, "filterText"); ok { item.filter_text = strings.clone(s) }
	if s, ok := proto.obj_str(obj, "insertText"); ok { item.insert_text = strings.clone(s) }
	if n, ok := proto.obj_int(obj, "insertTextFormat"); ok { item.insert_text_format = proto.Insert_Text_Format(n) }
	if b, ok := proto.obj_bool(obj, "deprecated");  ok { item.deprecated  = b }
	if b, ok := proto.obj_bool(obj, "preselect");   ok { item.preselect   = b }

	// documentation: string or MarkupContent
	if doc_v, has := obj["documentation"]; has {
		switch d in doc_v {
		case string: item.documentation = strings.clone(d)
		case json.Object:
			if s, ok := proto.obj_str(d, "value"); ok { item.documentation = strings.clone(s) }
		}
	}

	return item
}
