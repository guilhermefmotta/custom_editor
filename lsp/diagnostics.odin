package lsp

import "core:encoding/json"
import "core:strings"

// ---------------------------------------------------------------------------
// Diagnostic store — per-URI lists updated by publishDiagnostics
// ---------------------------------------------------------------------------

Diag_List :: struct {
	version: int,
	items:   []Diagnostic, // heap-owned
}

Diagnostic_Store :: struct {
	by_uri: map[string]Diag_List, // key = uri (heap clone)
	// Observers — called after update (max 4 callbacks for simplicity)
	on_update: proc(uri: string, diags: []Diagnostic, user: rawptr),
	on_update_user: rawptr,
}

diag_store_init :: proc(s: ^Diagnostic_Store) {
	s.by_uri = make(map[string]Diag_List)
}

diag_store_destroy :: proc(s: ^Diagnostic_Store) {
	for _, &dl in s.by_uri { _diag_list_free(&dl) }
	delete(s.by_uri)
}

_diag_list_free :: proc(dl: ^Diag_List) {
	for &d in dl.items { diagnostic_destroy(&d) }
	delete(dl.items)
}

// Get diagnostics for a path (nil if none).
diag_store_get :: proc(s: ^Diagnostic_Store, path: string) -> []Diagnostic {
	uri := path_to_uri(path)
	if dl, ok := s.by_uri[uri]; ok { return dl.items }
	return nil
}

diag_store_get_uri :: proc(s: ^Diagnostic_Store, uri: string) -> []Diagnostic {
	if dl, ok := s.by_uri[uri]; ok { return dl.items }
	return nil
}

// ---------------------------------------------------------------------------
// Handle textDocument/publishDiagnostics notification
// ---------------------------------------------------------------------------

diag_store_on_publish :: proc(s: ^Diagnostic_Store, body: []u8) {
	val, ok := parse_json(body)
	if !ok { return }
	defer json.destroy_value(val)

	top, is_obj := val.(json.Object)
	if !is_obj { return }

	params_v, has_params := top["params"]
	if !has_params { return }
	params, is_params := params_v.(json.Object)
	if !is_params { return }

	uri_str, has_uri := json_obj_str(params, "uri")
	if !has_uri { return }
	uri := strings.clone(uri_str)

	version, _ := json_obj_int(params, "version")

	// Free old diagnostics for this URI
	if old, exists := s.by_uri[uri]; exists {
		_diag_list_free(&old)
	}

	// Parse new diagnostics
	new_items: [dynamic]Diagnostic
	new_items = make([dynamic]Diagnostic)

	if diags_arr, ok2 := json_obj_arr(params, "diagnostics"); ok2 {
		for d_val in diags_arr {
			if d_obj, is_d := d_val.(json.Object); is_d {
				d := parse_diagnostic(d_obj)
				append(&new_items, d)
			}
		}
	}

	dl := Diag_List{
		version = version,
		items   = new_items[:],
	}
	s.by_uri[uri] = dl

	// Notify observer
	if s.on_update != nil {
		s.on_update(uri, dl.items, s.on_update_user)
	}
}

// ---------------------------------------------------------------------------
// Count diagnostics by severity for a path
// ---------------------------------------------------------------------------

diag_count_errors   :: proc(s: ^Diagnostic_Store, path: string) -> int {
	n := 0
	for d in diag_store_get(s, path) { if d.severity == .Error   { n += 1 } }
	return n
}

diag_count_warnings :: proc(s: ^Diagnostic_Store, path: string) -> int {
	n := 0
	for d in diag_store_get(s, path) { if d.severity == .Warning { n += 1 } }
	return n
}

// Find diagnostic covering a given line (0-based).
diag_at_line :: proc(s: ^Diagnostic_Store, path: string, line: int) -> (Diagnostic, bool) {
	for d in diag_store_get(s, path) {
		if d.range.start.line <= line && line <= d.range.end.line {
			return d, true
		}
	}
	return {}, false
}
