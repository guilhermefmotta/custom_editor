package lsp_features

import proto "../protocol"
import conn  "../connection"
import "core:encoding/json"
import "core:fmt"
import "core:strings"

Semantic_Tokens_Callback :: proc(tokens: []proto.Semantic_Token, user: rawptr)

Semantic_Tokens_Feature :: struct {
	c:           ^conn.Conn,
	pending_id:  int,
	token_types: []string,
	token_mods:  []string,
}

semantic_tokens_feature_create :: proc(c: ^conn.Conn) -> ^Semantic_Tokens_Feature {
	sf := new(Semantic_Tokens_Feature)
	sf.c          = c
	sf.pending_id = -1
	return sf
}

semantic_tokens_feature_destroy :: proc(sf: ^Semantic_Tokens_Feature) {
	for &s in sf.token_types { delete(s) }
	delete(sf.token_types)
	for &s in sf.token_mods { delete(s) }
	delete(sf.token_mods)
	free(sf)
}

semantic_tokens_on_initialized :: proc(sf: ^Semantic_Tokens_Feature, server_caps_json: string) {
	val, ok := proto.parse_json(transmute([]u8)server_caps_json, context.temp_allocator)
	if !ok { return }
	defer json.destroy_value(val, context.temp_allocator)

	caps_obj, is_obj := val.(json.Object)
	if !is_obj { return }

	provider, has_p := proto.obj_obj(caps_obj, "semanticTokensProvider")
	if !has_p { return }
	legend, has_l := proto.obj_obj(provider, "legend")
	if !has_l { return }

	if types_arr, ok2 := proto.obj_arr(legend, "tokenTypes"); ok2 {
		sf.token_types = make([]string, len(types_arr))
		for v, i in types_arr {
			if s, is_s := v.(string); is_s { sf.token_types[i] = strings.clone(s) }
		}
	}
	if mods_arr, ok2 := proto.obj_arr(legend, "tokenModifiers"); ok2 {
		sf.token_mods = make([]string, len(mods_arr))
		for v, i in mods_arr {
			if s, is_s := v.(string); is_s { sf.token_mods[i] = strings.clone(s) }
		}
	}
}

semantic_tokens_cancel :: proc(sf: ^Semantic_Tokens_Feature) {
	if sf.pending_id >= 0 {
		conn.cancel_request(sf.c, sf.pending_id)
		sf.pending_id = -1
	}
}

_ST_CB_Data :: struct {
	cb:          Semantic_Tokens_Callback,
	user:        rawptr,
	token_types: []string, // not owned — points into feature
	token_mods:  []string,
}

_on_st_response :: proc(result: json.Value, error: json.Value, user: rawptr) {
	cb_data := cast(^_ST_CB_Data)user
	defer free(cb_data)
	defer json.destroy_value(result)
	defer json.destroy_value(error)

	if error != nil || result == nil { cb_data.cb(nil, cb_data.user); return }
	obj, is_obj := result.(json.Object)
	if !is_obj { cb_data.cb(nil, cb_data.user); return }
	data_arr, has_data := proto.obj_arr(obj, "data")
	if !has_data { cb_data.cb(nil, cb_data.user); return }

	n := len(data_arr) / 5
	tokens := make([]proto.Semantic_Token, n)
	prev_line, prev_col := 0, 0
	for i := 0; i < n; i += 1 {
		base := i * 5
		delta_line  := _arr_int(data_arr, base+0)
		delta_col   := _arr_int(data_arr, base+1)
		length      := _arr_int(data_arr, base+2)
		type_idx    := _arr_int(data_arr, base+3)
		mod_mask    := _arr_int(data_arr, base+4)

		if delta_line == 0 {
			prev_col += delta_col
		} else {
			prev_line += delta_line
			prev_col   = delta_col
		}

		tok_type := proto.Token_Type.Variable
		if cb_data.token_types != nil && type_idx < len(cb_data.token_types) {
			tok_type = _token_type_from_str(cb_data.token_types[type_idx])
		}

		mod_set: proto.Token_Modifier_Set
		if cb_data.token_mods != nil {
			for j := 0; j < len(cb_data.token_mods); j += 1 {
				if mod_mask & (1 << uint(j)) != 0 {
					if m, ok := _token_mod_from_str(cb_data.token_mods[j]); ok {
						mod_set += {m}
					}
				}
			}
		}

		tokens[i] = proto.Semantic_Token{
			line      = prev_line,
			col       = prev_col,
			length    = length,
			type      = tok_type,
			modifiers = mod_set,
		}
	}
	cb_data.cb(tokens, cb_data.user)
}

semantic_tokens_request :: proc(sf: ^Semantic_Tokens_Feature, uri: string,
                                cb: Semantic_Tokens_Callback, user: rawptr) {
	semantic_tokens_cancel(sf)
	params := fmt.tprintf(`{"textDocument":{"uri":%s}}`, proto.json_str(uri))
	cb_data := new(_ST_CB_Data)
	cb_data.cb          = cb
	cb_data.user        = user
	cb_data.token_types = sf.token_types
	cb_data.token_mods  = sf.token_mods
	sf.pending_id = conn.send_request(sf.c, "textDocument/semanticTokens/full", params,
		proto.Response_Callback{proc_ = _on_st_response, user = cb_data})
}

_arr_int :: proc(arr: json.Array, idx: int) -> int {
	if idx >= len(arr) { return 0 }
	switch v in arr[idx] {
	case i64: return int(v)
	case f64: return int(v)
	}
	return 0
}

_token_type_from_str :: proc(s: string) -> proto.Token_Type {
	switch s {
	case "namespace":     return .Namespace
	case "type":          return .Type
	case "class":         return .Class
	case "enum":          return .Enum
	case "interface":     return .Interface
	case "struct":        return .Struct
	case "typeParameter": return .Type_Parameter
	case "parameter":     return .Parameter
	case "variable":      return .Variable
	case "property":      return .Property
	case "enumMember":    return .Enum_Member
	case "event":         return .Event
	case "function":      return .Function
	case "method":        return .Method
	case "macro":         return .Macro
	case "keyword":       return .Keyword
	case "modifier":      return .Modifier
	case "comment":       return .Comment
	case "string":        return .String
	case "number":        return .Number
	case "regexp":        return .Regexp
	case "operator":      return .Operator
	case "decorator":     return .Decorator
	}
	return .Variable
}

_token_mod_from_str :: proc(s: string) -> (proto.Token_Modifier, bool) {
	switch s {
	case "declaration":    return .Declaration, true
	case "definition":     return .Definition, true
	case "readonly":       return .Readonly, true
	case "static":         return .Static, true
	case "deprecated":     return .Deprecated, true
	case "abstract":       return .Abstract, true
	case "async":          return .Async, true
	case "modification":   return .Modification, true
	case "documentation":  return .Documentation, true
	case "defaultLibrary": return .Default_Library, true
	}
	return .Declaration, false
}
