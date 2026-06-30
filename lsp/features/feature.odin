package lsp_features

import "core:strings"

Feature_VTable :: struct {
	fill_caps:      proc(self: rawptr, b: ^strings.Builder),
	on_initialized: proc(self: rawptr, server_caps_json: string),
	destroy:        proc(self: rawptr),
}

Feature :: struct {
	vtable: ^Feature_VTable,
	data:   rawptr,
}

feature_fill_caps :: #force_inline proc(f: ^Feature, b: ^strings.Builder) {
	if f.vtable.fill_caps != nil { f.vtable.fill_caps(f.data, b) }
}

feature_on_initialized :: #force_inline proc(f: ^Feature, caps_json: string) {
	if f.vtable.on_initialized != nil { f.vtable.on_initialized(f.data, caps_json) }
}

feature_destroy :: #force_inline proc(f: ^Feature) {
	if f.vtable.destroy != nil { f.vtable.destroy(f.data) }
}
