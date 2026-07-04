package lsp

import "core:encoding/json"
import "core:fmt"
import "core:strings"

// ---------------------------------------------------------------------------
// Core LSP Types
// ---------------------------------------------------------------------------

Position :: struct {
	line:      int, // 0-based
	character: int, // 0-based UTF-16 code unit offset
}

Range :: struct {
	start: Position,
	end:   Position,
}

Location :: struct {
	uri:   string,
	range: Range,
}

TextDocumentIdentifier :: struct {
	uri: string,
}

VersionedTextDocument :: struct {
	uri:     string,
	version: int,
}

TextEdit :: struct {
	range:   Range,
	new_text: string,
}

// ---------------------------------------------------------------------------
// Diagnostic
// ---------------------------------------------------------------------------

Diagnostic_Severity :: enum {
	Error       = 1,
	Warning     = 2,
	Information = 3,
	Hint        = 4,
}

Diagnostic :: struct {
	range:    Range,
	severity: Diagnostic_Severity,
	code:     string,
	source:   string,
	message:  string,
}

// ---------------------------------------------------------------------------
// Completion
// ---------------------------------------------------------------------------

Completion_Trigger_Kind :: enum {
	Invoked          = 1,
	Trigger_Character = 2,
	Trigger_Re_Invoke = 3,
}

Completion_Item_Kind :: enum {
	Text          = 1,
	Method        = 2,
	Function      = 3,
	Constructor   = 4,
	Field         = 5,
	Variable      = 6,
	Class         = 7,
	Interface     = 8,
	Module        = 9,
	Property      = 10,
	Unit          = 11,
	Value         = 12,
	Enum          = 13,
	Keyword       = 14,
	Snippet       = 15,
	Color         = 16,
	File          = 17,
	Reference     = 18,
	Folder        = 19,
	Enum_Member   = 20,
	Constant      = 21,
	Struct        = 22,
	Event         = 23,
	Operator      = 24,
	Type_Parameter = 25,
}

Completion_Item :: struct {
	label:               string,
	kind:                Completion_Item_Kind,
	detail:              string,
	documentation:       string,
	sort_text:           string,
	filter_text:         string,
	insert_text:         string,
	deprecated:          bool,
	preselect:           bool,
	additional_edits:    []TextEdit,
	commit_characters:   []string,
	data:                string, // opaque for resolve
}

completion_item_destroy :: proc(item: ^Completion_Item) {
	delete(item.label)
	delete(item.detail)
	delete(item.documentation)
	delete(item.sort_text)
	delete(item.filter_text)
	delete(item.insert_text)
	delete(item.data)
	for &e in item.additional_edits { delete(e.new_text) }
	delete(item.additional_edits)
	for &s in item.commit_characters { delete(s) }
	delete(item.commit_characters)
}

// ---------------------------------------------------------------------------
// Hover
// ---------------------------------------------------------------------------

Hover_Result :: struct {
	contents: string, // Markdown or plaintext
	range:    Range,
	has_range: bool,
}

hover_result_destroy :: proc(h: ^Hover_Result) {
	if h.contents != "" { delete(h.contents); h.contents = "" }
}

// ---------------------------------------------------------------------------
// Signature Help
// ---------------------------------------------------------------------------

Parameter_Info :: struct {
	label:         string,
	documentation: string,
}

Signature_Info :: struct {
	label:           string,
	documentation:   string,
	parameters:      []Parameter_Info,
	active_parameter: int,
}

Signature_Help :: struct {
	signatures:       []Signature_Info,
	active_signature: int,
	active_parameter: int,
}

signature_help_destroy :: proc(sh: ^Signature_Help) {
	for &sig in sh.signatures {
		delete(sig.label)
		delete(sig.documentation)
		for &p in sig.parameters {
			delete(p.label)
			delete(p.documentation)
		}
		delete(sig.parameters)
	}
	delete(sh.signatures)
	sh^ = {}
}

// ---------------------------------------------------------------------------
// Semantic Tokens
// ---------------------------------------------------------------------------

Token_Type :: enum {
	Namespace,
	Type,
	Class,
	Enum,
	Interface,
	Struct,
	Type_Parameter,
	Parameter,
	Variable,
	Property,
	Enum_Member,
	Event,
	Function,
	Method,
	Macro,
	Keyword,
	Modifier,
	Comment,
	String,
	Number,
	Regexp,
	Operator,
	Decorator,
}

Token_Modifier :: enum {
	Declaration,
	Definition,
	Readonly,
	Static,
	Deprecated,
	Abstract,
	Async,
	Modification,
	Documentation,
	Default_Library,
}

Token_Modifier_Set :: bit_set[Token_Modifier]

Semantic_Token :: struct {
	line:      int,
	col:       int,
	length:    int,
	type:      Token_Type,
	modifiers: Token_Modifier_Set,
}

// ---------------------------------------------------------------------------
// URI helpers
// ---------------------------------------------------------------------------

// Convert filesystem path → file:// URI. Temp-allocated.
path_to_uri :: proc(path: string) -> string {
	if len(path) == 0 { return "file://" }
	if path[0] == '/' {
		return fmt.tprintf("file://%s", path)
	}
	return fmt.tprintf("file:///%s", path)
}

// Convert file:// URI → filesystem path. Temp-allocated.
uri_to_path :: proc(uri: string) -> string {
	if strings.has_prefix(uri, "file://") {
		rest := uri[7:]
		if len(rest) > 0 && rest[0] != '/' {
			return rest[1:] // Windows: strip extra /
		}
		return rest
	}
	return uri
}

// ---------------------------------------------------------------------------
// Position/range JSON builders
// ---------------------------------------------------------------------------

position_json :: proc(pos: Position) -> string {
	return strings.concatenate({
		`{"line":`, fmt.tprintf("%d", pos.line), `,"character":`, fmt.tprintf("%d", pos.character), `}`,
	}, context.temp_allocator)
}

range_json :: proc(r: Range) -> string {
	return strings.concatenate({
		`{"start":{"line":`, fmt.tprintf("%d", r.start.line),
		`,"character":`, fmt.tprintf("%d", r.start.character),
		`},"end":{"line":`, fmt.tprintf("%d", r.end.line),
		`,"character":`, fmt.tprintf("%d", r.end.character), `}}`,
	}, context.temp_allocator)
}

text_document_json :: proc(uri: string) -> string {
	return strings.concatenate({`{"uri":`, json_str(uri), `}`}, context.temp_allocator)
}

// Build textDocumentPositionParams JSON (temp-allocated).
td_pos_params :: proc(uri: string, pos: Position) -> string {
	return strings.concatenate({
		`{"textDocument":{"uri":`, json_str(uri),
		`},"position":{"line":`, fmt.tprintf("%d", pos.line),
		`,"character":`, fmt.tprintf("%d", pos.character), `}}`,
	}, context.temp_allocator)
}

// ---------------------------------------------------------------------------
// Parse helpers — extract LSP types from json.Object
// ---------------------------------------------------------------------------

parse_position :: proc(obj: json.Object) -> Position {
	line, _ := json_obj_int(obj, "line")
	char, _ := json_obj_int(obj, "character")
	return {line, char}
}

parse_range :: proc(obj: json.Object) -> Range {
	start_obj, _ := json_obj_obj(obj, "start")
	end_obj, _   := json_obj_obj(obj, "end")
	return {parse_position(start_obj), parse_position(end_obj)}
}

parse_diagnostic :: proc(obj: json.Object) -> Diagnostic {
	d: Diagnostic
	if r, ok := json_obj_obj(obj, "range"); ok { d.range = parse_range(r) }
	if sev, ok := json_obj_int(obj, "severity"); ok {
		d.severity = Diagnostic_Severity(sev)
	} else {
		d.severity = .Error
	}
	d.message, _ = json_obj_str(obj, "message")
	d.message = strings.clone(d.message)
	if c, ok := json_obj_str(obj, "code");   ok { d.code   = strings.clone(c) }
	if s, ok := json_obj_str(obj, "source"); ok { d.source = strings.clone(s) }
	return d
}

diagnostic_destroy :: proc(d: ^Diagnostic) {
	delete(d.message)
	delete(d.code)
	delete(d.source)
}

parse_completion_item :: proc(obj: json.Object) -> Completion_Item {
	item: Completion_Item
	if s, ok := json_obj_str(obj, "label");      ok { item.label       = strings.clone(s) }
	if s, ok := json_obj_str(obj, "detail");     ok { item.detail      = strings.clone(s) }
	if s, ok := json_obj_str(obj, "sortText");   ok { item.sort_text   = strings.clone(s) }
	if s, ok := json_obj_str(obj, "filterText"); ok { item.filter_text = strings.clone(s) }
	if s, ok := json_obj_str(obj, "insertText"); ok { item.insert_text = strings.clone(s) }
	if k, ok := json_obj_int(obj, "kind");       ok { item.kind        = Completion_Item_Kind(k) }
	if b, ok := json_obj_bool(obj, "deprecated");ok { item.deprecated  = b }
	if b, ok := json_obj_bool(obj, "preselect"); ok { item.preselect   = b }

	if doc_v, has := obj["documentation"]; has {
		#partial switch v in doc_v {
		case string:
			item.documentation = strings.clone(v)
		case json.Object:
			if s, ok2 := json_obj_str(v, "value"); ok2 {
				item.documentation = strings.clone(s)
			}
		case: // Null, i64, f64, bool, Array — ignore
		}
	}

	if item.filter_text == "" && item.label != "" {
		item.filter_text = strings.clone(item.label)
	}
	if item.sort_text == "" && item.label != "" {
		item.sort_text = strings.clone(item.label)
	}

	// additionalTextEdits — e.g. jdtls's auto-import: inserting an unimported
	// type adds the missing `import` line here alongside the primary insertText.
	if arr, ok := json_obj_arr(obj, "additionalTextEdits"); ok {
		edits := make([dynamic]TextEdit)
		for edit_v in arr {
			edit_obj, is_obj := edit_v.(json.Object)
			if !is_obj { continue }
			r, has_r := json_obj_obj(edit_obj, "range")
			if !has_r { continue }
			new_text, _ := json_obj_str(edit_obj, "newText")
			append(&edits, TextEdit{range = parse_range(r), new_text = strings.clone(new_text)})
		}
		item.additional_edits = edits[:]
	}

	return item
}
