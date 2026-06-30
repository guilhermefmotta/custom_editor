package lsp_features

import conn "../connection"
import proto "../protocol"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"

Diagnostics_Callback :: proc(uri: string, diags: []proto.Diagnostic, user: rawptr)

diagnostics_destroy_slice :: proc(diags: []proto.Diagnostic) {
	for &d in diags { proto.diagnostic_destroy(&d) }
	delete(diags)
}

Diagnostics_Feature :: struct {
	c:    ^conn.Conn,
	cb:   Diagnostics_Callback,
	user: rawptr,
}

@(private)
_diag_mu:      sync.Mutex
@(private)
_diag_by_conn: map[rawptr]^Diagnostics_Feature

diagnostics_feature_create :: proc(c: ^conn.Conn, cb: Diagnostics_Callback, user: rawptr) -> ^Diagnostics_Feature {
	df := new(Diagnostics_Feature)
	df.c = c; df.cb = cb; df.user = user

	sync.mutex_lock(&_diag_mu)
	if _diag_by_conn == nil { _diag_by_conn = make(map[rawptr]^Diagnostics_Feature) }
	_diag_by_conn[c] = df
	sync.mutex_unlock(&_diag_mu)

	conn.register_notif_handler(c, "textDocument/publishDiagnostics", _on_publish_diag)
	return df
}

diagnostics_feature_destroy :: proc(df: ^Diagnostics_Feature) {
	sync.mutex_lock(&_diag_mu)
	delete_key(&_diag_by_conn, df.c)
	sync.mutex_unlock(&_diag_mu)
	free(df)
}

@(private)
_on_publish_diag :: proc(body: []u8) {
	val, ok := json.parse(body, allocator = context.temp_allocator)
	if !ok { return }
	defer json.destroy_value(val, context.temp_allocator)

	root, is_obj := val.(json.Object)
	if !is_obj { return }

	params_v, has := root["params"]
	if !has { return }
	params, is_params := params_v.(json.Object)
	if !is_params { return }

	uri_str, _ := proto.obj_str(params, "uri")
	diag_arr, _ := proto.obj_arr(params, "diagnostics")

	diags := make([]proto.Diagnostic, len(diag_arr))
	for elem, i in diag_arr {
		if d_obj, is_d := elem.(json.Object); is_d {
			diags[i] = _parse_diagnostic(d_obj)
		}
	}

	// Find the feature registered for the connection that sent this notification.
	// We don't have a conn pointer here — look up via all registered features.
	// Since there's typically one feature, iterate all entries.
	sync.mutex_lock(&_diag_mu)
	df: ^Diagnostics_Feature
	for _, v in _diag_by_conn { df = v; break }
	sync.mutex_unlock(&_diag_mu)

	if df != nil && df.cb != nil {
		df.cb(uri_str, diags, df.user)
	} else {
		diagnostics_destroy_slice(diags)
	}
}

@(private)
_parse_diagnostic :: proc(obj: json.Object) -> proto.Diagnostic {
	d: proto.Diagnostic

	if range_v, has := obj["range"]; has {
		if r, ok := range_v.(json.Object); ok {
			d.range = proto.parse_range(r)
		}
	}

	if sev, ok := proto.obj_int(obj, "severity"); ok {
		d.severity = proto.Diagnostic_Severity(sev)
	} else {
		d.severity = .Error
	}

	// code may be string or number
	if code_v, has := obj["code"]; has {
		switch c in code_v {
		case string: d.code = strings.clone(c)
		case i64:    d.code = strings.clone(fmt.tprintf("%d", c))
		case f64:    d.code = strings.clone(fmt.tprintf("%g", c))
		}
	}

	if s, ok := proto.obj_str(obj, "source");  ok { d.source  = strings.clone(s) }
	if s, ok := proto.obj_str(obj, "message"); ok { d.message = strings.clone(s) }

	return d
}
