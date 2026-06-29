package lsp

import "core:encoding/json"
import "core:fmt"
import "core:strings"

// ---------------------------------------------------------------------------
// Semantic token store — full document token list
// ---------------------------------------------------------------------------

Sem_Token_Store :: struct {
	tokens:      []Semantic_Token, // heap-owned, sorted by line then col
	result_id:   string,          // for delta requests; heap
	pending_id:  int,             // request id; -1 if none
	dirty:       bool,            // need re-request
	// Legend from server — maps token type index → Token_Type
	type_legend: []Token_Type,   // heap
	mod_legend:  []Token_Modifier, // heap
}

sem_token_store_init :: proc(s: ^Sem_Token_Store) {
	s^ = {}
	s.pending_id = -1
}

sem_token_store_destroy :: proc(s: ^Sem_Token_Store) {
	delete(s.tokens)
	delete(s.result_id)
	delete(s.type_legend)
	delete(s.mod_legend)
}

// Set legends from server capabilities.
sem_tokens_set_legend :: proc(s: ^Sem_Token_Store, type_names: []string, mod_names: []string) {
	delete(s.type_legend)
	delete(s.mod_legend)

	types := make([dynamic]Token_Type)
	for name in type_names {
		append(&types, _token_type_from_str(name))
	}
	s.type_legend = types[:]

	mods := make([dynamic]Token_Modifier)
	for name in mod_names {
		append(&mods, _token_mod_from_str(name))
	}
	s.mod_legend = mods[:]
}

// Request full semantic tokens for document.
sem_tokens_request_full :: proc(c: ^Language_Client, path: string) {
	if c.state != .Running || !c.caps.has_semantic_tokens { return }
	s := &c.sem_tokens

	if s.pending_id >= 0 { client_cancel_request(c, s.pending_id) }

	params := fmt.tprintf(`{"textDocument":{"uri":%s}}`, json_str(path_to_uri(path)))
	s.pending_id = client_send_request(c, "textDocument/semanticTokens/full", params, Response_Callback{
		proc_ = _on_sem_tokens_full,
	})
}

// Get semantic token at a line/col (nil if none).
sem_tokens_at :: proc(s: ^Sem_Token_Store, line, col: int) -> ^Semantic_Token {
	for &t in s.tokens {
		if t.line == line && col >= t.col && col < t.col + t.length {
			return &t
		}
		if t.line > line { break }
	}
	return nil
}

// Get all tokens on a line.
sem_tokens_for_line :: proc(s: ^Sem_Token_Store, line: int) -> []Semantic_Token {
	start := -1
	end   := len(s.tokens)
	for t, i in s.tokens {
		if t.line == line && start < 0 { start = i }
		if t.line > line { end = i; break }
	}
	if start < 0 { return nil }
	return s.tokens[start:end]
}

// ---------------------------------------------------------------------------
// Response: textDocument/semanticTokens/full
// ---------------------------------------------------------------------------

_on_sem_tokens_full :: proc(c: ^Language_Client, result: json.Value, error: json.Value, user: rawptr) {
	defer json.destroy_value(result)
	defer json.destroy_value(error)

	s := &c.sem_tokens
	s.pending_id = -1

	if error != nil || result == nil { return }
	if _, is_null := result.(json.Null); is_null { return }

	obj, is_obj := result.(json.Object)
	if !is_obj { return }

	// Decode result_id for delta
	if rid, ok := json_obj_str(obj, "resultId"); ok {
		delete(s.result_id)
		s.result_id = strings.clone(rid)
	}

	// Decode data array: [deltaLine, deltaStartChar, length, tokenType, tokenModifiers, ...]
	data_arr, ok := json_obj_arr(obj, "data")
	if !ok || len(data_arr) % 5 != 0 { return }

	delete(s.tokens)
	tokens := make([dynamic]Semantic_Token)
	cur_line := 0
	cur_col  := 0

	for i := 0; i + 4 < len(data_arr); i += 5 {
		delta_line, _  := data_arr[i].(i64)
		delta_col, _   := data_arr[i+1].(i64)
		length, _      := data_arr[i+2].(i64)
		type_idx, _    := data_arr[i+3].(i64)
		mod_bits, _    := data_arr[i+4].(i64)

		cur_line += int(delta_line)
		if delta_line > 0 { cur_col = 0 }
		cur_col += int(delta_col)

		tok_type := _legend_type(s, int(type_idx))
		tok_mods := _decode_modifiers(s, int(mod_bits))

		append(&tokens, Semantic_Token{
			line      = cur_line,
			col       = cur_col,
			length    = int(length),
			type      = tok_type,
			modifiers = tok_mods,
		})
	}

	s.tokens = tokens[:]
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

_legend_type :: proc(s: ^Sem_Token_Store, idx: int) -> Token_Type {
	if idx >= 0 && idx < len(s.type_legend) { return s.type_legend[idx] }
	return .Variable
}

_decode_modifiers :: proc(s: ^Sem_Token_Store, bits: int) -> Token_Modifier_Set {
	result: Token_Modifier_Set
	for i := 0; i < len(s.mod_legend); i += 1 {
		if bits & (1 << uint(i)) != 0 {
			result += {s.mod_legend[i]}
		}
	}
	return result
}

_token_type_from_str :: proc(name: string) -> Token_Type {
	switch name {
	case "namespace":      return .Namespace
	case "type":           return .Type
	case "class":          return .Class
	case "enum":           return .Enum
	case "interface":      return .Interface
	case "struct":         return .Struct
	case "typeParameter":  return .Type_Parameter
	case "parameter":      return .Parameter
	case "variable":       return .Variable
	case "property":       return .Property
	case "enumMember":     return .Enum_Member
	case "event":          return .Event
	case "function":       return .Function
	case "method":         return .Method
	case "macro":          return .Macro
	case "keyword":        return .Keyword
	case "modifier":       return .Modifier
	case "comment":        return .Comment
	case "string":         return .String
	case "number":         return .Number
	case "regexp":         return .Regexp
	case "operator":       return .Operator
	case "decorator":      return .Decorator
	}
	return .Variable
}

_token_mod_from_str :: proc(name: string) -> Token_Modifier {
	switch name {
	case "declaration":    return .Declaration
	case "definition":     return .Definition
	case "readonly":       return .Readonly
	case "static":         return .Static
	case "deprecated":     return .Deprecated
	case "abstract":       return .Abstract
	case "async":          return .Async
	case "modification":   return .Modification
	case "documentation":  return .Documentation
	case "defaultLibrary": return .Default_Library
	}
	return .Declaration
}
