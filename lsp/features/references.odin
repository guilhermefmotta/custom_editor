package lsp_features

import proto "../protocol"
import conn  "../connection"
import "core:encoding/json"
import "core:fmt"
import "core:strings"

Location_Callback :: proc(locations: []proto.Location, user: rawptr)

locations_destroy :: proc(locs: []proto.Location) {
	for &l in locs { delete(l.uri) }
	delete(locs)
}

References_Feature :: struct {
	c:          ^conn.Conn,
	pending_id: int,
}

references_feature_create :: proc(c: ^conn.Conn) -> ^References_Feature {
	rf := new(References_Feature)
	rf.c          = c
	rf.pending_id = -1
	return rf
}

references_feature_destroy :: proc(rf: ^References_Feature) {
	free(rf)
}

references_cancel :: proc(rf: ^References_Feature) {
	if rf.pending_id >= 0 {
		conn.cancel_request(rf.c, rf.pending_id)
		rf.pending_id = -1
	}
}

_Ref_CB_Data :: struct {
	cb:   Location_Callback,
	user: rawptr,
	uri:  string, // heap clone — used for highlights to repeat the uri
}

_on_loc_response :: proc(result: json.Value, error: json.Value, user: rawptr) {
	cb_data := cast(^_Ref_CB_Data)user
	defer free(cb_data)
	defer json.destroy_value(result)
	defer json.destroy_value(error)
	if error != nil || result == nil { cb_data.cb(nil, cb_data.user); delete(cb_data.uri); return }

	locs := _parse_locations(result, cb_data.uri)
	delete(cb_data.uri)
	cb_data.cb(locs, cb_data.user)
}

references_request :: proc(rf: ^References_Feature, uri: string, pos: proto.Position,
                            include_declaration: bool, cb: Location_Callback, user: rawptr) {
	references_cancel(rf)
	decl := "true" if include_declaration else "false"
	params := fmt.tprintf(
		`{"textDocument":{"uri":%s},"position":{"line":%d,"character":%d},"context":{"includeDeclaration":%s}}`,
		proto.json_str(uri), pos.line, pos.character, decl)
	cb_data := new(_Ref_CB_Data)
	cb_data.cb   = cb
	cb_data.user = user
	cb_data.uri  = strings.clone(uri)
	rf.pending_id = conn.send_request(rf.c, "textDocument/references", params,
		proto.Response_Callback{proc_ = _on_loc_response, user = cb_data})
}

_on_highlight_response :: proc(result: json.Value, error: json.Value, user: rawptr) {
	cb_data := cast(^_Ref_CB_Data)user
	defer free(cb_data)
	defer json.destroy_value(result)
	defer json.destroy_value(error)
	if error != nil || result == nil { cb_data.cb(nil, cb_data.user); delete(cb_data.uri); return }

	arr, is_arr := result.(json.Array)
	if !is_arr { cb_data.cb(nil, cb_data.user); delete(cb_data.uri); return }

	locs := make([]proto.Location, len(arr))
	for item, i in arr {
		obj, ok := item.(json.Object)
		if !ok { continue }
		rng_obj, _ := proto.obj_obj(obj, "range")
		locs[i] = proto.Location{
			uri   = strings.clone(cb_data.uri),
			range = proto.parse_range(rng_obj),
		}
	}
	delete(cb_data.uri)
	cb_data.cb(locs, cb_data.user)
}

document_highlights_request :: proc(rf: ^References_Feature, uri: string, pos: proto.Position,
                                    cb: Location_Callback, user: rawptr) {
	references_cancel(rf)
	params := fmt.tprintf(
		`{"textDocument":{"uri":%s},"position":{"line":%d,"character":%d}}`,
		proto.json_str(uri), pos.line, pos.character)
	cb_data := new(_Ref_CB_Data)
	cb_data.cb   = cb
	cb_data.user = user
	cb_data.uri  = strings.clone(uri)
	rf.pending_id = conn.send_request(rf.c, "textDocument/documentHighlight", params,
		proto.Response_Callback{proc_ = _on_highlight_response, user = cb_data})
}

_parse_locations :: proc(result: json.Value, fallback_uri: string) -> []proto.Location {
	switch v in result {
	case json.Array:
		locs := make([]proto.Location, len(v))
		for item, i in v {
			obj, ok := item.(json.Object)
			if !ok { continue }
			uri_s, _ := proto.obj_str(obj, "uri")
			rng_obj, _ := proto.obj_obj(obj, "range")
			locs[i] = proto.Location{
				uri   = strings.clone(uri_s),
				range = proto.parse_range(rng_obj),
			}
		}
		return locs
	case json.Object:
		uri_s, _ := proto.obj_str(v, "uri")
		rng_obj, _ := proto.obj_obj(v, "range")
		locs := make([]proto.Location, 1)
		locs[0] = proto.Location{
			uri   = strings.clone(uri_s),
			range = proto.parse_range(rng_obj),
		}
		return locs
	}
	return nil
}
