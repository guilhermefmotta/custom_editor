package lsp_features

import conn "../connection"
import proto "../protocol"
import "core:encoding/json"
import "core:strings"

Location_Callback :: proc(locations: []proto.Location, user: rawptr)

locations_destroy :: proc(locs: []proto.Location) {
	for &l in locs { delete(l.uri) }
	delete(locs)
}

Definition_Feature :: struct {
	c:          ^conn.Conn,
	pending_id: int,
}

definition_feature_create :: proc(c: ^conn.Conn) -> ^Definition_Feature {
	df := new(Definition_Feature)
	df.c = c
	df.pending_id = -1
	return df
}

definition_feature_destroy :: proc(df: ^Definition_Feature) {
	free(df)
}

definition_request :: proc(df: ^Definition_Feature, uri: string, pos: proto.Position, cb: Location_Callback, user: rawptr) {
	_loc_request(df, "textDocument/definition", uri, pos, cb, user)
}

declaration_request :: proc(df: ^Definition_Feature, uri: string, pos: proto.Position, cb: Location_Callback, user: rawptr) {
	_loc_request(df, "textDocument/declaration", uri, pos, cb, user)
}

implementation_request :: proc(df: ^Definition_Feature, uri: string, pos: proto.Position, cb: Location_Callback, user: rawptr) {
	_loc_request(df, "textDocument/implementation", uri, pos, cb, user)
}

type_definition_request :: proc(df: ^Definition_Feature, uri: string, pos: proto.Position, cb: Location_Callback, user: rawptr) {
	_loc_request(df, "textDocument/typeDefinition", uri, pos, cb, user)
}

definition_cancel :: proc(df: ^Definition_Feature) {
	if df.pending_id >= 0 {
		conn.cancel_request(df.c, df.pending_id)
		df.pending_id = -1
	}
}

@(private)
_loc_request :: proc(
	df: ^Definition_Feature,
	method: string,
	uri: string,
	pos: proto.Position,
	cb: Location_Callback,
	user: rawptr,
) {
	if df.pending_id >= 0 {
		conn.cancel_request(df.c, df.pending_id)
		df.pending_id = -1
	}

	params := proto.td_pos_params(uri, pos)

	State :: struct { df: ^Definition_Feature; cb: Location_Callback; user: rawptr }
	s := new(State)
	s.df = df; s.cb = cb; s.user = user

	callback := proto.Response_Callback{
		proc_ = proc(result: json.Value, error: json.Value, user: rawptr) {
			s := cast(^State)user
			defer free(s)
			defer json.destroy_value(error)
			defer json.destroy_value(result)
			s.df.pending_id = -1
			if result == nil { s.cb(nil, s.user); return }
			if _, is_null := result.(json.Null); is_null { s.cb(nil, s.user); return }
			locs := _parse_locations(result)
			s.cb(locs, s.user)
		},
		user = s,
	}

	df.pending_id = conn.send_request(df.c, method, params, callback)
}

@(private)
_parse_location :: proc(obj: json.Object) -> proto.Location {
	loc: proto.Location
	if s, ok := proto.obj_str(obj, "uri"); ok { loc.uri = strings.clone(s) }
	if r, ok := proto.obj_obj(obj, "range"); ok { loc.range = proto.parse_range(r) }
	return loc
}

@(private)
_parse_locations :: proc(val: json.Value) -> []proto.Location {
	switch v in val {
	case json.Object:
		locs := make([]proto.Location, 1)
		locs[0] = _parse_location(v)
		return locs
	case json.Array:
		locs := make([]proto.Location, len(v))
		for elem, i in v {
			if obj, ok := elem.(json.Object); ok {
				locs[i] = _parse_location(obj)
			}
		}
		return locs
	}
	return nil
}
