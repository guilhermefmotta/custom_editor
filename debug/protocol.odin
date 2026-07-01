package debug

// DAP protocol message building and parsing.
// DAP uses Content-Length framing (same as LSP) but a different JSON schema:
//   {"seq":N,"type":"request|response|event","command|event":...,"arguments|body":...}

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"

// ---------------------------------------------------------------------------
// Raw inbox message body
// ---------------------------------------------------------------------------

Inbox_Msg :: struct {
	body: []u8, // heap; consumer must delete
}

// ---------------------------------------------------------------------------
// Sequence counter
// ---------------------------------------------------------------------------

@(private="file")
_seq_mu:   sync.Mutex
@(private="file")
_seq_next: int = 1

next_seq :: proc() -> int {
	sync.mutex_lock(&_seq_mu)
	defer sync.mutex_unlock(&_seq_mu)
	s := _seq_next
	_seq_next += 1
	return s
}

// ---------------------------------------------------------------------------
// Envelope types
// ---------------------------------------------------------------------------

DAP_Msg_Type :: enum { Request, Response, Event, Unknown }

DAP_Envelope :: struct {
	seq:         int,
	type_:       DAP_Msg_Type,
	command:     string, // for requests
	event_name:  string, // for events
	request_seq: int,    // for responses
	success:     bool,   // for responses
	raw_args:    string, // raw JSON of "arguments" or "body"
	raw_result:  string, // raw JSON of "body" (response only)
	raw_error:   string, // raw JSON of "message" on failure
}

// Parse a raw DAP message body into an envelope.
// Returns false if body is not valid JSON or missing "type".
parse_envelope :: proc(body: []u8) -> (env: DAP_Envelope, ok: bool) {
	val, err := json.parse(body, allocator = context.temp_allocator)
	if err != nil { return {}, false }
	defer json.destroy_value(val, context.temp_allocator)

	obj, is_obj := val.(json.Object)
	if !is_obj { return {}, false }

	if seq_v, has := obj["seq"]; has {
		#partial switch v in seq_v {
		case i64: env.seq = int(v)
		case f64: env.seq = int(v)
		}
	}

	type_s, _ := _json_str(obj, "type")
	switch type_s {
	case "request":  env.type_ = .Request
	case "response": env.type_ = .Response
	case "event":    env.type_ = .Event
	case:            env.type_ = .Unknown
	}

	env.command,    _ = _json_str(obj, "command")
	env.event_name, _ = _json_str(obj, "event")

	if rseq, has := obj["request_seq"]; has {
		#partial switch v in rseq {
		case i64: env.request_seq = int(v)
		case f64: env.request_seq = int(v)
		}
	}

	if succ, has := obj["success"]; has {
		if b, is_b := succ.(bool); is_b { env.success = b }
	}

	// We don't sub-parse args/body here — callers do that themselves.
	// Just mark the positions by re-parsing with strings (temp alloc).
	env.raw_args   = _extract_raw(body, "arguments")
	env.raw_result = _extract_raw(body, "body")
	env.raw_error  = _extract_raw(body, "message")

	return env, true
}

// ---------------------------------------------------------------------------
// Request builders — all return temp-allocated JSON strings
// ---------------------------------------------------------------------------

build_request :: proc(command: string, args: string) -> string {
	seq := next_seq()
	if args == "" || args == "null" {
		return fmt.tprintf(`{"seq":%d,"type":"request","command":"%s"}`, seq, command)
	}
	return fmt.tprintf(`{"seq":%d,"type":"request","command":"%s","arguments":%s}`, seq, command, args)
}

// initialize — must be first request sent
build_initialize :: proc(adapter_id: string) -> string {
	args := fmt.tprintf(
		`{"clientID":"custom_editor","clientName":"Custom Editor","adapterID":"%s",`+
		`"locale":"en-US","linesStartAt1":true,"columnsStartAt1":true,"pathFormat":"path",`+
		`"supportsVariableType":true,"supportsVariablePaging":false,`+
		`"supportsRunInTerminalRequest":false,"supportsMemoryReferences":false}`,
		adapter_id)
	return build_request("initialize", args)
}

// configurationDone — sent after initialize + all setBreakpoints
build_configuration_done :: proc() -> string {
	return build_request("configurationDone", "")
}

// launch
build_launch :: proc(program, cwd: string, args: []string, stop_on_entry: bool) -> string {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	strings.write_string(&b, `{"program":`)
	strings.write_string(&b, _json_str_lit(program))
	strings.write_string(&b, `,"cwd":`)
	strings.write_string(&b, _json_str_lit(cwd))
	fmt.sbprintf(&b, `,"stopOnEntry":%v`, stop_on_entry)
	strings.write_string(&b, `,"args":[`)
	for a, i in args {
		if i > 0 { strings.write_string(&b, ",") }
		strings.write_string(&b, _json_str_lit(a))
	}
	strings.write_string(&b, `],"noDebug":false}`)
	return build_request("launch", strings.to_string(b))
}

// attach
build_attach :: proc(pid: int) -> string {
	return build_request("attach", fmt.tprintf(`{"pid":%d}`, pid))
}

// disconnect
build_disconnect :: proc(terminate: bool) -> string {
	return build_request("disconnect", fmt.tprintf(`{"terminateDebuggee":%v}`, terminate))
}

// continue
build_continue :: proc(thread_id: int) -> string {
	return build_request("continue", fmt.tprintf(`{"threadId":%d}`, thread_id))
}

// pause
build_pause :: proc(thread_id: int) -> string {
	return build_request("pause", fmt.tprintf(`{"threadId":%d}`, thread_id))
}

// next (step over)
build_next :: proc(thread_id: int) -> string {
	return build_request("next", fmt.tprintf(`{"threadId":%d}`, thread_id))
}

// stepIn
build_step_in :: proc(thread_id: int) -> string {
	return build_request("stepIn", fmt.tprintf(`{"threadId":%d}`, thread_id))
}

// stepOut
build_step_out :: proc(thread_id: int) -> string {
	return build_request("stepOut", fmt.tprintf(`{"threadId":%d}`, thread_id))
}

// restart
build_restart :: proc() -> string {
	return build_request("restart", "{}")
}

// threads
build_threads :: proc() -> string {
	return build_request("threads", "")
}

// stackTrace
build_stack_trace :: proc(thread_id, start, levels: int) -> string {
	return build_request("stackTrace",
		fmt.tprintf(`{"threadId":%d,"startFrame":%d,"levels":%d}`, thread_id, start, levels))
}

// scopes
build_scopes :: proc(frame_id: int) -> string {
	return build_request("scopes", fmt.tprintf(`{"frameId":%d}`, frame_id))
}

// variables
build_variables :: proc(variables_ref, start, count: int) -> string {
	return build_request("variables",
		fmt.tprintf(`{"variablesReference":%d,"start":%d,"count":%d}`, variables_ref, start, count))
}

// setBreakpoints
build_set_breakpoints :: proc(source_path: string, lines: []int) -> string {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	fmt.sbprintf(&b, `{"source":{"path":%s},"breakpoints":[`, _json_str_lit(source_path))
	for l, i in lines {
		if i > 0 { strings.write_string(&b, ",") }
		fmt.sbprintf(&b, `{"line":%d}`, l)
	}
	strings.write_string(&b, "]}")
	return build_request("setBreakpoints", strings.to_string(b))
}

// setExceptionBreakpoints
build_set_exception_breakpoints :: proc(filters: []string) -> string {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	strings.write_string(&b, `{"filters":[`)
	for f, i in filters {
		if i > 0 { strings.write_string(&b, ",") }
		strings.write_string(&b, _json_str_lit(f))
	}
	strings.write_string(&b, "]}")
	return build_request("setExceptionBreakpoints", strings.to_string(b))
}

// evaluate
build_evaluate :: proc(expr: string, frame_id: int, context_: string) -> string {
	ctx := context_ if context_ != "" else "repl"
	return build_request("evaluate",
		fmt.tprintf(`{"expression":%s,"frameId":%d,"context":"%s"}`, _json_str_lit(expr), frame_id, ctx))
}

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

// Simple JSON string literal builder (temp alloc, handles common escapes)
_json_str_lit :: proc(s: string) -> string {
	b: strings.Builder
	strings.builder_init_len_cap(&b, 0, len(s)+4, context.temp_allocator)
	strings.write_byte(&b, '"')
	for i := 0; i < len(s); i += 1 {
		ch := s[i]
		switch ch {
		case '"':  strings.write_string(&b, `\"`)
		case '\\': strings.write_string(&b, `\\`)
		case '\n': strings.write_string(&b, `\n`)
		case '\r': strings.write_string(&b, `\r`)
		case '\t': strings.write_string(&b, `\t`)
		case: strings.write_byte(&b, ch)
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

_json_str :: proc(obj: json.Object, key: string) -> (string, bool) {
	v, ok := obj[key]
	if !ok { return "", false }
	s, is_s := v.(string)
	return s, is_s
}

_json_int :: proc(obj: json.Object, key: string) -> (int, bool) {
	v, ok := obj[key]
	if !ok { return 0, false }
	#partial switch n in v {
	case i64: return int(n), true
	case f64: return int(n), true
	}
	return 0, false
}

_json_bool :: proc(obj: json.Object, key: string) -> (bool, bool) {
	v, ok := obj[key]
	if !ok { return false, false }
	b, is_b := v.(bool)
	return b, is_b
}

// Extract raw JSON value for a key by simple string search (temp alloc).
// Not fully robust for nested structures, but sufficient for known field names.
_extract_raw :: proc(body: []u8, key: string) -> string {
	s := string(body)
	needle := fmt.tprintf(`"%s":`, key)
	idx := strings.index(s, needle)
	if idx < 0 { return "" }
	start := idx + len(needle)
	// Skip whitespace
	for start < len(s) && (s[start] == ' ' || s[start] == '\t') { start += 1 }
	if start >= len(s) { return "" }

	ch := s[start]
	end := start + 1
	if ch == '{' || ch == '[' {
		depth := 1
		in_str := false
		for end < len(s) && depth > 0 {
			c := s[end]
			if !in_str {
				if c == '{' || c == '[' { depth += 1 }
				else if c == '}' || c == ']' { depth -= 1 }
				else if c == '"' { in_str = true }
			} else {
				if c == '\\' { end += 1 } // skip escaped char
				else if c == '"' { in_str = false }
			}
			end += 1
		}
		return s[start:end]
	} else if ch == '"' {
		for end < len(s) {
			c := s[end]
			if c == '\\' { end += 2; continue }
			if c == '"'  { end += 1; break }
			end += 1
		}
		return s[start:end]
	} else {
		// number, bool, null
		for end < len(s) && s[end] != ',' && s[end] != '}' && s[end] != ']' { end += 1 }
		return strings.trim_right_space(s[start:end])
	}
}
