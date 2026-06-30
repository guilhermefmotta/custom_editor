// Package lsp_protocol — generic JSON-RPC 2.0 types.
// Nothing in this package is LSP-specific. Any JSON-RPC-based protocol
// (LSP, DAP, etc.) can use these types and the codec module.
package lsp_protocol

import "core:encoding/json"
import "core:strings"

// ---------------------------------------------------------------------------
// JSON-RPC 2.0 message classification
// ---------------------------------------------------------------------------

Message_Kind :: enum u8 {
	Request,      // has id + method + params
	Response,     // has id + (result | error)
	Notification, // has method + params, no id
}

// Routing envelope: everything needed to dispatch a message without
// parsing the full body. The full body slice is kept alive until dispatch
// completes, so handlers can re-parse as needed.
Routed_Message :: struct {
	kind:   Message_Kind,
	id:     int,    // -1 for notifications
	method: string, // empty for responses; points into body (temp lifetime)
	body:   []u8,   // heap-owned; consumer must delete after dispatch
}

// ---------------------------------------------------------------------------
// Pending request tracking
// ---------------------------------------------------------------------------

// Proc type for request response callbacks. Ownership: result/error are
// heap-allocated json.Value (via json.parse with heap allocator).
// Callback MUST call json.destroy_value on both (even if nil).
Response_Callback :: struct {
	proc_: proc(result: json.Value, error: json.Value, user: rawptr),
	user:  rawptr,
}

Pending_Request :: struct {
	method:   string,            // heap clone; for logging
	callback: Response_Callback,
	canceled: bool,              // set by cancel_request
}

// ---------------------------------------------------------------------------
// LSP basic protocol types (used across all features)
// ---------------------------------------------------------------------------

Position :: struct {
	line:      int, // 0-based
	character: int, // 0-based UTF-16 code units
}

Range :: struct {
	start, end: Position,
}

Location :: struct {
	uri:   string,
	range: Range,
}

Location_Link :: struct {
	origin_selection_range: Range,
	target_uri:             string,
	target_range:           Range,
	target_selection_range: Range,
}

Text_Edit :: struct {
	range:    Range,
	new_text: string,
}

Diagnostic_Severity :: enum u8 {
	Error   = 1,
	Warning = 2,
	Info    = 3,
	Hint    = 4,
}

Diagnostic :: struct {
	range:    Range,
	severity: Diagnostic_Severity,
	code:     string,
	source:   string,
	message:  string,
}

diagnostic_destroy :: proc(d: ^Diagnostic) {
	delete(d.code)
	delete(d.source)
	delete(d.message)
}

// ---------------------------------------------------------------------------
// Completion types
// ---------------------------------------------------------------------------

Completion_Item_Kind :: enum u8 {
	Text = 1, Method, Function, Constructor, Field, Variable, Class,
	Interface, Module, Property, Unit, Value, Enum, Keyword, Snippet,
	Color, File, Reference, Folder, Enum_Member, Constant, Struct,
	Event, Operator, Type_Parameter,
}

Trigger_Kind :: enum u8 {
	Invoked   = 1,
	Trigger   = 2,
	ReInvoke  = 3,
}

Insert_Text_Format :: enum u8 {
	Plain_Text = 1,
	Snippet    = 2,
}

Completion_Item :: struct {
	label:              string,
	kind:               Completion_Item_Kind,
	detail:             string,
	documentation:      string,
	sort_text:          string,
	filter_text:        string,
	insert_text:        string,
	insert_text_format: Insert_Text_Format,
	deprecated:         bool,
	preselect:          bool,
	additional_edits:   []Text_Edit,
	commit_characters:  []string,
	data:               json.Value, // opaque for resolve
}

completion_item_destroy :: proc(item: ^Completion_Item) {
	delete(item.label)
	delete(item.detail)
	delete(item.documentation)
	delete(item.sort_text)
	delete(item.filter_text)
	delete(item.insert_text)
	for &e in item.additional_edits { delete(e.new_text) }
	delete(item.additional_edits)
	for &s in item.commit_characters { delete(s) }
	delete(item.commit_characters)
	json.destroy_value(item.data)
}

// ---------------------------------------------------------------------------
// Hover types
// ---------------------------------------------------------------------------

Hover_Result :: struct {
	contents:  string, // Markdown or plaintext
	range:     Range,
	has_range: bool,
}

hover_result_destroy :: proc(h: ^Hover_Result) {
	delete(h.contents)
}

// ---------------------------------------------------------------------------
// Signature help types
// ---------------------------------------------------------------------------

Parameter_Info :: struct {
	label:         string,
	documentation: string,
}

Signature_Info :: struct {
	label:            string,
	documentation:    string,
	parameters:       []Parameter_Info,
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
		for &p in sig.parameters { delete(p.label); delete(p.documentation) }
		delete(sig.parameters)
	}
	delete(sh.signatures)
}

// ---------------------------------------------------------------------------
// Semantic token types
// ---------------------------------------------------------------------------

Token_Type :: enum u8 {
	Namespace, Type, Class, Enum, Interface, Struct, Type_Parameter,
	Parameter, Variable, Property, Enum_Member, Event, Function, Method,
	Macro, Keyword, Modifier, Comment, String, Number, Regexp, Operator, Decorator,
}

Token_Modifier :: enum u8 {
	Declaration, Definition, Readonly, Static, Deprecated, Abstract,
	Async, Modification, Documentation, Default_Library,
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
// Code action types
// ---------------------------------------------------------------------------

Code_Action_Kind :: enum u8 {
	Empty, Quick_Fix, Refactor, Refactor_Extract, Refactor_Inline,
	Refactor_Rewrite, Source, Source_Organize_Imports, Source_Fix_All,
}

Code_Action :: struct {
	title:       string,
	kind:        Code_Action_Kind,
	diagnostics: []Diagnostic,
	is_preferred: bool,
	edit_json:   json.Value, // raw WorkspaceEdit — applied via editor
}

code_action_destroy :: proc(a: ^Code_Action) {
	delete(a.title)
	for &d in a.diagnostics { diagnostic_destroy(&d) }
	delete(a.diagnostics)
	json.destroy_value(a.edit_json)
}

// ---------------------------------------------------------------------------
// Inlay hint
// ---------------------------------------------------------------------------

Inlay_Hint_Kind :: enum u8 { Type = 1, Parameter = 2 }

Inlay_Hint :: struct {
	position: Position,
	label:    string,
	kind:     Inlay_Hint_Kind,
	padding_left:  bool,
	padding_right: bool,
}

inlay_hint_destroy :: proc(h: ^Inlay_Hint) { delete(h.label) }
