package lsp

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"

// ---------------------------------------------------------------------------
// Client state machine
// ---------------------------------------------------------------------------

Client_State :: enum {
	Created,
	Starting,
	Initializing,
	Running,
	Shutting_Down,
	Stopped,
}

// ---------------------------------------------------------------------------
// Log entries — collected from window/logMessage and stderr
// ---------------------------------------------------------------------------

LSP_Log_Level :: enum { Error = 1, Warning = 2, Info = 3, Log = 4 }

LSP_Log_Entry :: struct {
	level:   LSP_Log_Level,
	message: string, // heap-owned
}

LSP_LOG_MAX :: 500 // rolling cap to avoid unbounded growth

// ---------------------------------------------------------------------------
// Callback types
// ---------------------------------------------------------------------------

// Called when a response arrives for a pending request.
// result is nil on error, error is nil on success.
// Both are heap-allocated json.Values; callback must call json.destroy_value on them.
Response_Callback :: struct {
	proc_: proc(client: ^Language_Client, result: json.Value, error: json.Value, user: rawptr),
	user:  rawptr,
}

// Called when a notification arrives.
Notification_Handler :: proc(client: ^Language_Client, method: string, params_body: []u8)

// ---------------------------------------------------------------------------
// Pending request
// ---------------------------------------------------------------------------

Pending_Request :: struct {
	method:   string, // heap clone
	callback: Response_Callback,
}

// ---------------------------------------------------------------------------
// Server capabilities (subset we care about)
// ---------------------------------------------------------------------------

Server_Caps :: struct {
	has_completion:        bool,
	has_hover:             bool,
	has_signature_help:    bool,
	has_definition:        bool,
	has_references:        bool,
	has_rename:            bool,
	has_formatting:        bool,
	has_range_formatting:  bool,
	has_code_actions:      bool,
	has_semantic_tokens:   bool,
	has_inlay_hints:       bool,
	has_code_lens:         bool,
	has_workspace_symbols: bool,
	completion_triggers:   []string, // heap-owned
	sig_help_triggers:     []string, // heap-owned
	text_sync_kind:        int,      // 1 = full, 2 = incremental
}

server_caps_destroy :: proc(c: ^Server_Caps) {
	for s in c.completion_triggers { delete(s) }
	delete(c.completion_triggers)
	for s in c.sig_help_triggers { delete(s) }
	delete(c.sig_help_triggers)
}

// ---------------------------------------------------------------------------
// Language client
// ---------------------------------------------------------------------------

Language_Client :: struct {
	state:          Client_State,
	transport:      Transport,
	pending:        map[int]Pending_Request,
	notif_handlers: map[string]Notification_Handler,
	caps:           Server_Caps,
	root_uri:       string, // heap
	// Feature modules attached at init
	docs:           Document_Sync,
	diags:          Diagnostic_Store,
	completion:     Completion_Manager,
	hover:          Hover_Manager,
	sig_help:       Sig_Help_Manager,
	sem_tokens:     Sem_Token_Store,
	// Diagnostics / logging
	logs:           [dynamic]LSP_Log_Entry, // heap-owned entries
	error_msg:      string,                 // heap; set on unexpected exit or init failure
	// Deferred didOpen flush: OLS drops messages that arrive simultaneously with initialized.
	// Set true after _cb_initialized; flushed 200ms later in client_update.
	flush_pending:      bool,
	flush_pending_tick: time.Tick,
}

// ---------------------------------------------------------------------------
// Create / destroy
// ---------------------------------------------------------------------------

client_create :: proc(root_path: string) -> ^Language_Client {
	c := new(Language_Client)
	c.state          = .Created
	c.root_uri       = strings.clone(path_to_uri(root_path))
	c.pending        = make(map[int]Pending_Request)
	c.notif_handlers = make(map[string]Notification_Handler)
	c.logs           = make([dynamic]LSP_Log_Entry)

	doc_sync_init(&c.docs)
	diag_store_init(&c.diags)
	completion_manager_init(&c.completion)
	hover_manager_init(&c.hover)
	sig_help_manager_init(&c.sig_help)
	sem_token_store_init(&c.sem_tokens)

	// Register built-in notification handlers
	c.notif_handlers["textDocument/publishDiagnostics"] = _on_publish_diagnostics
	c.notif_handlers["window/logMessage"]               = _on_window_log_message
	c.notif_handlers["window/showMessage"]              = _on_window_log_message

	return c
}

client_destroy :: proc(c: ^Language_Client) {
	if c.state == .Running { client_shutdown(c) }

	transport_stop(&c.transport)

	for _, &p in c.pending { delete(p.method) }
	delete(c.pending)
	delete(c.notif_handlers)
	server_caps_destroy(&c.caps)
	delete(c.root_uri)

	doc_sync_destroy(&c.docs)
	diag_store_destroy(&c.diags)
	completion_manager_destroy(&c.completion)
	hover_manager_destroy(&c.hover)
	sig_help_manager_destroy(&c.sig_help)
	sem_token_store_destroy(&c.sem_tokens)

	for &e in c.logs { delete(e.message) }
	delete(c.logs)
	if c.error_msg != "" { delete(c.error_msg) }

	free(c)
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

client_start :: proc(c: ^Language_Client, cmd: []string) -> bool {
	if c.state != .Created { return false }
	cmd_str := strings.join(cmd, " ", context.temp_allocator)
	_client_log(c, .Info, fmt.tprintf("spawning: %s", cmd_str))
	if !transport_start(&c.transport, cmd) {
		_client_log(c, .Error, fmt.tprintf("transport_start failed for: %s", cmd_str))
		return false
	}
	_client_log(c, .Info, fmt.tprintf("transport started, root=%s", c.root_uri))
	c.state = .Initializing
	_send_initialize(c)
	return true
}

client_shutdown :: proc(c: ^Language_Client) {
	if c.state != .Running { return }
	c.state = .Shutting_Down
	client_send_request(c, "shutdown", "null", {})
}

// ---------------------------------------------------------------------------
// Send helpers
// ---------------------------------------------------------------------------

client_send_request :: proc(c: ^Language_Client, method: string, params: string, cb: Response_Callback) -> int {
	if c.state == .Stopped { return -1 }
	id   := next_request_id()
	body := build_request(id, method, params)
	transport_send(&c.transport, body)

	c.pending[id] = Pending_Request{
		method   = strings.clone(method),
		callback = cb,
	}
	return id
}

client_send_notification :: proc(c: ^Language_Client, method: string, params: string) {
	if c.state == .Stopped { return }
	body := build_notification(method, params)
	transport_send(&c.transport, body)
}

// Cancel a pending request by sending $/cancelRequest notification.
client_cancel_request :: proc(c: ^Language_Client, id: int) {
	if id < 0 { return }
	params := strings.concatenate({`{"id":`, fmt.tprintf("%d", id), `}`}, context.temp_allocator)
	client_send_notification(c, "$/cancelRequest", params)
	if p, ok := &c.pending[id]; ok {
		delete(p.method)
		delete_key(&c.pending, id)
	}
}

// ---------------------------------------------------------------------------
// Main update — call each frame from UI thread
// ---------------------------------------------------------------------------

client_update :: proc(c: ^Language_Client) {
	if c.state == .Created || c.state == .Stopped { return }

	// Detect unexpected process exit (e.g. OLS binary not found → exits immediately).
	if c.transport.process.running {
		exited, exit_code := process_poll(&c.transport.process)
		if exited {
			_client_log(c, .Error, fmt.tprintf("server process exited unexpectedly (exit code %d) — check binary is in PATH and executable", exit_code))
			if c.error_msg != "" { delete(c.error_msg) }
			c.error_msg = strings.clone(fmt.tprintf("server exited (code %d)", exit_code))
			c.state = .Stopped
			return
		}
	}

	msgs: [dynamic]Inbox_Message
	msgs = make([dynamic]Inbox_Message, context.temp_allocator)
	transport_drain(&c.transport, &msgs)

	for &msg in msgs {
		_dispatch(c, &msg)
		delete(msg.body)
	}

	if c.flush_pending && time.tick_since(c.flush_pending_tick) >= 200 * time.Millisecond {
		c.flush_pending = false
		doc_sync_flush_pending(c)
	}
}

_client_log :: proc(c: ^Language_Client, level: LSP_Log_Level, msg: string) {
	// Rolling cap — drop oldest when full
	if len(c.logs) >= LSP_LOG_MAX {
		delete(c.logs[0].message)
		ordered_remove(&c.logs, 0)
	}
	append(&c.logs, LSP_Log_Entry{level = level, message = strings.clone(msg)})

	level_str := "LOG"
	switch level {
	case .Error:   level_str = "ERR"
	case .Warning: level_str = "WRN"
	case .Info:    level_str = "INF"
	case .Log:     level_str = "LOG"
	}
	log_writef(level_str, msg)
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

_dispatch :: proc(c: ^Language_Client, msg: ^Inbox_Message) {
	routed, ok := route_message(msg.body)
	if !ok {
		preview := string(msg.body[:min(120, len(msg.body))])
		_client_log(c, .Error, fmt.tprintf("route_message failed (json parse error), body prefix: %s", preview))
		return
	}

	if routed.is_response {
		_client_log(c, .Log, fmt.tprintf("← response id=%d", routed.id))
		_handle_response(c, routed.id, msg.body)
	} else {
		_handle_notification_or_request(c, routed.method, msg.body)
	}
}

_handle_response :: proc(c: ^Language_Client, id: int, body: []u8) {
	if id < 0 { return }

	p, found := c.pending[id]
	if !found { return }
	delete_key(&c.pending, id)

	// Parse result/error from body
	val, parse_ok := parse_json(body)
	if !parse_ok {
		if p.callback.proc_ != nil {
			p.callback.proc_(c, nil, nil, p.callback.user)
		}
		delete(p.method)
		return
	}

	obj, is_obj := val.(json.Object)
	if !is_obj {
		json.destroy_value(val)
		delete(p.method)
		return
	}

	result := obj["result"]
	error  := obj["error"]

	// Move result/error out of obj before destroying
	// We pass ownership to the callback
	result_copy: json.Value
	error_copy:  json.Value

	if _, has_result := obj["result"]; has_result {
		result_copy = _deep_clone_value(result)
	}
	if _, has_err := obj["error"]; has_err {
		error_copy = _deep_clone_value(error)
	}

	json.destroy_value(val)

	if p.callback.proc_ != nil {
		p.callback.proc_(c, result_copy, error_copy, p.callback.user)
	} else {
		json.destroy_value(result_copy)
		json.destroy_value(error_copy)
	}

	// Special: initialized response
	if p.method == "initialize" && c.state == .Initializing {
		_on_initialize_response(c, result_copy)
	}

	delete(p.method)
}

_handle_notification_or_request :: proc(c: ^Language_Client, method: string, body: []u8) {
	if h, ok := c.notif_handlers[method]; ok {
		h(c, method, body)
	}
}

// ---------------------------------------------------------------------------
// Initialize handshake
// ---------------------------------------------------------------------------

_send_initialize :: proc(c: ^Language_Client) {
	pid     := int(os.get_pid())
	pid_str := fmt.tprintf("%d", pid)
	root    := json_str(c.root_uri)
	_client_log(c, .Info, fmt.tprintf("sending initialize pid=%d root=%s", pid, c.root_uri))

	// Build params by concatenation — avoids fmt treating { as a format directive.
	static_caps := `{"textDocument":{"synchronization":{"dynamicRegistration":true,"willSave":false,"didSave":true,"willSaveWaitUntil":false},"completion":{"dynamicRegistration":true,"completionItem":{"snippetSupport":false,"documentationFormat":["plaintext","markdown"],"deprecatedSupport":true,"preselectSupport":true},"completionItemKind":{"valueSet":[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25]}},"hover":{"dynamicRegistration":true,"contentFormat":["plaintext","markdown"]},"signatureHelp":{"dynamicRegistration":true,"signatureInformation":{"documentationFormat":["plaintext","markdown"],"parameterInformation":{"labelOffsetSupport":true}}},"definition":{"dynamicRegistration":true},"references":{"dynamicRegistration":true},"documentHighlight":{"dynamicRegistration":true},"documentSymbol":{"dynamicRegistration":true},"codeAction":{"dynamicRegistration":true},"codeLens":{"dynamicRegistration":true},"formatting":{"dynamicRegistration":true},"rename":{"dynamicRegistration":true},"publishDiagnostics":{"relatedInformation":true,"tagSupport":{"valueSet":[1,2]},"versionSupport":true},"semanticTokens":{"dynamicRegistration":true,"requests":{"full":true,"range":false},"tokenTypes":["namespace","type","class","enum","interface","struct","typeParameter","parameter","variable","property","enumMember","event","function","method","macro","keyword","modifier","comment","string","number","regexp","operator","decorator"],"tokenModifiers":["declaration","definition","readonly","static","deprecated","abstract","async","modification","documentation","defaultLibrary"],"formats":["relative"],"overlappingTokenSupport":false,"multilineTokenSupport":false},"inlayHint":{"dynamicRegistration":true},"diagnostics":{"dynamicRegistration":true}},"workspace":{"applyEdit":true,"symbol":{"dynamicRegistration":true},"workspaceFolders":true,"fileOperations":{"didCreate":false,"willCreate":false,"didRename":false,"willRename":false,"didDelete":false,"willDelete":false}}}`

	params := strings.concatenate({
		`{"processId":`, pid_str,
		`,"rootUri":`, root,
		`,"capabilities":`, static_caps,
		`,"initializationOptions":{}`,
		`,"workspaceFolders":[{"uri":`, root, `,"name":"workspace"}]}`,
	}, context.temp_allocator)

	preview_len := min(200, len(params))
	_client_log(c, .Log, fmt.tprintf("params[0:%d]: %s", preview_len, params[:preview_len]))

	client_send_request(c, "initialize", params, Response_Callback{
		proc_ = _cb_initialized,
	})
}

_cb_initialized :: proc(c: ^Language_Client, result: json.Value, error: json.Value, user: rawptr) {
	defer json.destroy_value(result)
	defer json.destroy_value(error)

	if error != nil {
		_client_log(c, .Error, "initialize request returned an error — server not running")
		if c.error_msg != "" { delete(c.error_msg) }
		c.error_msg = strings.clone("initialize returned error")
		c.state = .Stopped
		return
	}

	obj, is_obj := result.(json.Object)
	if !is_obj {
		_client_log(c, .Error, fmt.tprintf("initialize response: result is not an object (type=%T) — server did not respond correctly", result))
		c.state = .Stopped
		return
	}

	// Parse server capabilities
	if caps_obj, ok := json_obj_obj(obj, "capabilities"); ok {
		_parse_server_caps(c, caps_obj)
	}

	c.state = .Running
	_client_log(c, .Info, fmt.tprintf(
		"initialized: completion=%v hover=%v sighelp=%v def=%v semtok=%v sync=%d",
		c.caps.has_completion, c.caps.has_hover, c.caps.has_signature_help,
		c.caps.has_definition, c.caps.has_semantic_tokens, c.caps.text_sync_kind,
	))

	// Send initialized notification
	client_send_notification(c, "initialized", "{}")

	// Defer didOpen until next update cycle. OLS drops messages that arrive in the
	// same pipe read as initialized — schedule the flush 200ms later.
	c.flush_pending      = true
	c.flush_pending_tick = time.tick_now()
}

_on_initialize_response :: proc(c: ^Language_Client, result: json.Value) {
	// Already handled by _cb_initialized above
}

_parse_server_caps :: proc(c: ^Language_Client, caps: json.Object) {
	server_caps_destroy(&c.caps)
	c.caps = {}

	// Text sync
	if ts_v, has := caps["textDocumentSync"]; has {
		#partial switch v in ts_v {
		case i64:         c.caps.text_sync_kind = int(v)
		case json.Object: if k, ok := json_obj_int(v, "change"); ok { c.caps.text_sync_kind = k }
		case:
		}
	}

	_, has_comp := caps["completionProvider"]
	c.caps.has_completion = has_comp
	if has_comp {
		if cp_obj, ok := json_obj_obj(caps, "completionProvider"); ok {
			if triggers, ok2 := json_obj_arr(cp_obj, "triggerCharacters"); ok2 {
				trig := make([dynamic]string)
				for t in triggers {
					if s, is_s := t.(string); is_s { append(&trig, strings.clone(s)) }
				}
				c.caps.completion_triggers = trig[:]
			}
		}
	}

	_, has_hover := caps["hoverProvider"]
	c.caps.has_hover = has_hover

	if _, has := caps["signatureHelpProvider"]; has {
		c.caps.has_signature_help = true
		if sh_obj, ok := json_obj_obj(caps, "signatureHelpProvider"); ok {
			if triggers, ok2 := json_obj_arr(sh_obj, "triggerCharacters"); ok2 {
				trig := make([dynamic]string)
				for t in triggers {
					if s, is_s := t.(string); is_s { append(&trig, strings.clone(s)) }
				}
				c.caps.sig_help_triggers = trig[:]
			}
		}
	}

	_, has_def := caps["definitionProvider"]
	c.caps.has_definition = has_def

	_, has_ref := caps["referencesProvider"]
	c.caps.has_references = has_ref

	_, has_rename := caps["renameProvider"]
	c.caps.has_rename = has_rename

	_, has_fmt := caps["documentFormattingProvider"]
	c.caps.has_formatting = has_fmt

	_, has_ca := caps["codeActionProvider"]
	c.caps.has_code_actions = has_ca

	_, has_st := caps["semanticTokensProvider"]
	c.caps.has_semantic_tokens = has_st

	_, has_ih := caps["inlayHintProvider"]
	c.caps.has_inlay_hints = has_ih

	_, has_cl := caps["codeLensProvider"]
	c.caps.has_code_lens = has_cl

	_, has_ws := caps["workspaceSymbolProvider"]
	c.caps.has_workspace_symbols = has_ws
}

// ---------------------------------------------------------------------------
// Notification handler wrappers
// ---------------------------------------------------------------------------

_on_publish_diagnostics :: proc(c: ^Language_Client, method: string, body: []u8) {
	diag_store_on_publish(&c.diags, body)
}

_on_window_log_message :: proc(c: ^Language_Client, method: string, body: []u8) {
	val, ok := parse_json(body, context.temp_allocator)
	if !ok { return }
	defer json.destroy_value(val, context.temp_allocator)

	outer, is_obj := val.(json.Object)
	if !is_obj { return }
	params_v, has_p := outer["params"]
	if !has_p { return }
	params, is_pobj := params_v.(json.Object)
	if !is_pobj { return }

	level := 4
	if lv, ok2 := json_obj_int(params, "type"); ok2 { level = lv }
	msg, has_msg := json_obj_str(params, "message")
	if !has_msg { return }

	_client_log(c, LSP_Log_Level(level), msg)
}

// ---------------------------------------------------------------------------
// Deep clone a json.Value (heap allocator)
// ---------------------------------------------------------------------------

_deep_clone_value :: proc(v: json.Value) -> json.Value {
	switch val in v {
	case json.Null:   return json.Null{}
	case bool:        return val
	case i64:         return val
	case f64:         return val
	case string:      return strings.clone(val)
	case json.Array:
		arr := make(json.Array, len(val))
		for item, i in val { arr[i] = _deep_clone_value(item) }
		return arr
	case json.Object:
		obj := make(json.Object)
		for k, item in val { obj[strings.clone(k)] = _deep_clone_value(item) }
		return obj
	}
	return nil
}
