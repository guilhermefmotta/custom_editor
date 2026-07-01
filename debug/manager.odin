package debug

// Debug_Manager: owns all debug state.
// The Editor holds one Debug_Manager. The UI calls public procs.
// A background goroutine (the transport) handles adapter I/O.
// debug_tick() must be called every frame to pump messages from the adapter.

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:encoding/json"

// ---------------------------------------------------------------------------
// Breakpoint
// ---------------------------------------------------------------------------

Breakpoint :: struct {
	file:      string, // heap
	line:      int,    // 1-based
	enabled:   bool,
	condition: string, // heap (empty = unconditional)
	verified:  bool,   // confirmed by adapter
	adapter_id: int,   // adapter-assigned ID (-1 if unknown)
}

bp_destroy :: proc(b: ^Breakpoint) {
	delete(b.file)
	delete(b.condition)
}

// ---------------------------------------------------------------------------
// Thread / Frame / Variable
// ---------------------------------------------------------------------------

Thread_Info :: struct {
	id:   int,
	name: string, // heap
}

Stack_Frame :: struct {
	id:     int,
	name:   string, // heap
	source: string, // heap (file path)
	line:   int,    // 1-based
	col:    int,    // 1-based
}

Scope :: struct {
	name:          string, // heap
	variables_ref: int,
}

Variable :: struct {
	name:          string, // heap
	value:         string, // heap
	type_:         string, // heap
	variables_ref: int,    // >0 = has children
}

variable_destroy :: proc(v: ^Variable) {
	delete(v.name); delete(v.value); delete(v.type_)
}

// ---------------------------------------------------------------------------
// Evaluate result
// ---------------------------------------------------------------------------

Eval_Result :: struct {
	expr:   string, // heap
	result: string, // heap (value or error message)
	type_:  string, // heap
	ok:     bool,   // false = adapter returned error
}

eval_result_destroy :: proc(r: ^Eval_Result) {
	delete(r.expr); delete(r.result); delete(r.type_)
}

// ---------------------------------------------------------------------------
// Console output
// ---------------------------------------------------------------------------

Console_Line :: struct {
	text:     string, // heap
	category: string, // "stdout" | "stderr" | "console" | "important"
}

// ---------------------------------------------------------------------------
// Debug state
// ---------------------------------------------------------------------------

Debug_State :: enum {
	Idle,       // no adapter running
	Starting,   // adapter spawned, waiting for initialized event
	Running,    // target is executing
	Paused,     // target stopped (breakpoint / step / exception)
	Stopping,   // disconnect in progress
}

// ---------------------------------------------------------------------------
// Adapter configuration (loaded from TOML or set programmatically)
// ---------------------------------------------------------------------------

Adapter_Config :: struct {
	id:       string, // heap e.g. "lldb"
	command:  []string, // heap slice of heap strings
}

adapter_config_destroy :: proc(c: ^Adapter_Config) {
	delete(c.id)
	for s in c.command { delete(s) }
	delete(c.command)
}

Launch_Config :: struct {
	name:          string, // heap
	adapter_id:    string, // heap
	program:       string, // heap
	cwd:           string, // heap
	args:          []string, // heap slice of heap strings
	stop_on_entry: bool,
}

launch_config_destroy :: proc(c: ^Launch_Config) {
	delete(c.name); delete(c.adapter_id)
	delete(c.program); delete(c.cwd)
	for s in c.args { delete(s) }
	delete(c.args)
}

// ---------------------------------------------------------------------------
// Pending request — maps seq → command, for response routing
// ---------------------------------------------------------------------------

Pending_Req :: struct {
	seq:     int,
	command: string, // heap
}

// ---------------------------------------------------------------------------
// Debug_Manager
// ---------------------------------------------------------------------------

Debug_Manager :: struct {
	// State
	state:          Debug_State,
	mu:             sync.Mutex,

	// Transport + protocol
	transport:      Transport,

	// Adapter config
	adapter:        Adapter_Config,
	launch:         Launch_Config,

	// Breakpoints: indexed by [file][line]
	breakpoints:    [dynamic]Breakpoint, // heap

	// Session state (updated on stopped events)
	threads:        [dynamic]Thread_Info,
	active_thread:  int, // thread ID
	frames:         [dynamic]Stack_Frame,
	active_frame:   int, // frame index (into frames)
	scopes:         [dynamic]Scope,
	variables:      [dynamic]Variable, // locals of active frame

	// Evaluate results (most recent)
	eval_result:    Eval_Result,
	eval_pending:   bool,

	// Console output ring buffer
	console:        [dynamic]Console_Line,

	// Pending requests (seq → command) for response routing
	pending:        [dynamic]Pending_Req,
	pending_mu:     sync.Mutex,

	// Events — set by tick, read by UI
	did_stop:       bool,
	stop_file:      string, // heap, updated on stopped
	stop_line:      int,    // 1-based

	// Capabilities from adapter's initialize response
	supports_restart:        bool,
	supports_step_back:      bool,
	supports_goto_targets:   bool,
	supports_set_variable:   bool,

	// True when the session was started via attach (TCP or PID) rather than launch
	_attach_mode:            bool,
	// PID for local process attach
	_attach_pid:             int,
}

// ---------------------------------------------------------------------------
// Init / Destroy
// ---------------------------------------------------------------------------

manager_init :: proc(m: ^Debug_Manager) {
	m.breakpoints = make([dynamic]Breakpoint)
	m.threads     = make([dynamic]Thread_Info)
	m.frames      = make([dynamic]Stack_Frame)
	m.scopes      = make([dynamic]Scope)
	m.variables   = make([dynamic]Variable)
	m.console     = make([dynamic]Console_Line)
	m.pending     = make([dynamic]Pending_Req)
}

manager_destroy :: proc(m: ^Debug_Manager) {
	if m.state != .Idle { _session_stop(m, true) }

	for &b in m.breakpoints { bp_destroy(&b) }
	delete(m.breakpoints)

	for &t in m.threads { delete(t.name) }
	delete(m.threads)

	for &f in m.frames { delete(f.name); delete(f.source) }
	delete(m.frames)

	for &s in m.scopes { delete(s.name) }
	delete(m.scopes)

	for &v in m.variables { variable_destroy(&v) }
	delete(m.variables)

	for &c in m.console { delete(c.text); delete(c.category) }
	delete(m.console)

	for &p in m.pending { delete(p.command) }
	delete(m.pending)

	eval_result_destroy(&m.eval_result)
	delete(m.stop_file)

	adapter_config_destroy(&m.adapter)
	launch_config_destroy(&m.launch)
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

manager_set_adapter :: proc(m: ^Debug_Manager, id: string, cmd: []string) {
	adapter_config_destroy(&m.adapter)
	m.adapter.id      = strings.clone(id)
	m.adapter.command = make([]string, len(cmd))
	for c, i in cmd { m.adapter.command[i] = strings.clone(c) }
}

manager_set_launch :: proc(m: ^Debug_Manager, name, program, cwd: string, args: []string, stop_on_entry: bool) {
	launch_config_destroy(&m.launch)
	m.launch.name          = strings.clone(name)
	m.launch.adapter_id   = strings.clone(m.adapter.id)
	m.launch.program      = strings.clone(program)
	m.launch.cwd          = strings.clone(cwd)
	m.launch.stop_on_entry = stop_on_entry
	m.launch.args          = make([]string, len(args))
	for a, i in args { m.launch.args[i] = strings.clone(a) }
}

// ---------------------------------------------------------------------------
// Breakpoint API
// ---------------------------------------------------------------------------

bp_toggle :: proc(m: ^Debug_Manager, file: string, line: int) {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)

	for i := 0; i < len(m.breakpoints); i += 1 {
		b := &m.breakpoints[i]
		if b.file == file && b.line == line {
			ordered_remove(&m.breakpoints, i)
			// Sync with adapter if running
			if m.state != .Idle { _sync_breakpoints_locked(m, file) }
			return
		}
	}
	// Add new breakpoint
	append(&m.breakpoints, Breakpoint{
		file       = strings.clone(file),
		line       = line,
		enabled    = true,
		adapter_id = -1,
	})
	if m.state != .Idle { _sync_breakpoints_locked(m, file) }
}

bp_has :: proc(m: ^Debug_Manager, file: string, line: int) -> bool {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	for &b in m.breakpoints {
		if b.file == file && b.line == line && b.enabled { return true }
	}
	return false
}

bp_clear_all :: proc(m: ^Debug_Manager) {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	// Collect unique files for adapter sync
	files := make([dynamic]string, context.temp_allocator)
	for &b in m.breakpoints {
		found := false
		for f in files { if f == b.file { found = true; break } }
		if !found { append(&files, b.file) }
	}
	for &b in m.breakpoints { bp_destroy(&b) }
	clear(&m.breakpoints)
	if m.state != .Idle {
		for f in files { _sync_breakpoints_locked(m, f) }
	}
}

// ---------------------------------------------------------------------------
// Session control
// ---------------------------------------------------------------------------

session_start :: proc(m: ^Debug_Manager) -> bool {
	if m.state != .Idle { return false }
	if len(m.adapter.command) == 0 { return false }

	if !transport_start(&m.transport, m.adapter.command) { return false }

	m.state = .Starting
	_clear_session_state(m)
	_push_console(m, "Starting debug session...", "console")

	// Send initialize
	msg := build_initialize(m.adapter.id)
	seq := _extract_seq(msg)
	_register_pending(m, seq, "initialize")
	transport_send(&m.transport, msg)

	return true
}

// Attach to a local process by PID using a spawned adapter.
session_attach_pid :: proc(m: ^Debug_Manager, pid: int) -> bool {
	if m.state != .Idle { return false }
	if len(m.adapter.command) == 0 { return false }

	if !transport_start(&m.transport, m.adapter.command) { return false }

	m.state        = .Starting
	m._attach_mode = true
	m._attach_pid  = pid
	_clear_session_state(m)
	_push_console(m, fmt.tprintf("Starting adapter for PID %d...", pid), "console")

	msg := build_initialize(m.adapter.id)
	seq := _extract_seq(msg)
	_register_pending(m, seq, "initialize")
	transport_send(&m.transport, msg)
	return true
}

// Connect to an adapter already listening on host:port (remote/attach workflow).
// After connection: sends initialize, then on initialized event sends attach + configurationDone.
// Returns "" on success, error message on failure.
session_attach_tcp :: proc(m: ^Debug_Manager, host: string, port: int) -> string {
	if m.state != .Idle { return "already in a debug session" }

	ok, err := transport_start_tcp(&m.transport, host, port)
	if !ok { return err }

	m.state = .Starting
	_clear_session_state(m)

	adapter_id := m.adapter.id if m.adapter.id != "" else "generic"
	_push_console(m, fmt.tprintf("Connecting to %s:%d ...", host, port), "console")

	msg := build_initialize(adapter_id)
	seq := _extract_seq(msg)
	_register_pending(m, seq, "initialize")
	transport_send(&m.transport, msg)

	// Mark that we want attach, not launch
	m._attach_mode = true

	return ""
}

session_stop :: proc(m: ^Debug_Manager) {
	_session_stop(m, true)
}

session_restart :: proc(m: ^Debug_Manager) {
	if m.state == .Idle { return }
	msg := build_restart()
	transport_send(&m.transport, msg)
}

// ---------------------------------------------------------------------------
// Execution control
// ---------------------------------------------------------------------------

debug_continue :: proc(m: ^Debug_Manager) {
	if m.state != .Paused { return }
	msg := build_continue(m.active_thread)
	seq := _extract_seq(msg)
	_register_pending(m, seq, "continue")
	transport_send(&m.transport, msg)
}

debug_pause :: proc(m: ^Debug_Manager) {
	if m.state != .Running { return }
	msg := build_pause(m.active_thread)
	transport_send(&m.transport, msg)
}

debug_next :: proc(m: ^Debug_Manager) {
	if m.state != .Paused { return }
	msg := build_next(m.active_thread)
	transport_send(&m.transport, msg)
}

debug_step_in :: proc(m: ^Debug_Manager) {
	if m.state != .Paused { return }
	msg := build_step_in(m.active_thread)
	transport_send(&m.transport, msg)
}

debug_step_out :: proc(m: ^Debug_Manager) {
	if m.state != .Paused { return }
	msg := build_step_out(m.active_thread)
	transport_send(&m.transport, msg)
}

// ---------------------------------------------------------------------------
// Evaluate
// ---------------------------------------------------------------------------

debug_evaluate :: proc(m: ^Debug_Manager, expr: string) {
	if m.state == .Idle { return }
	frame_id := 0
	if len(m.frames) > 0 && m.active_frame < len(m.frames) {
		frame_id = m.frames[m.active_frame].id
	}
	msg := build_evaluate(expr, frame_id, "repl")
	seq := _extract_seq(msg)
	_register_pending(m, seq, "evaluate")
	m.eval_pending = true
	transport_send(&m.transport, msg)
}

// ---------------------------------------------------------------------------
// Tick — call every frame from UI thread
// ---------------------------------------------------------------------------

debug_tick :: proc(m: ^Debug_Manager) {
	if m.state == .Idle { return }

	inbox: [dynamic]Inbox_Msg
	inbox = make([dynamic]Inbox_Msg, context.temp_allocator)
	transport_drain(&m.transport, &inbox)

	for &msg in inbox {
		_process_message(m, msg.body)
		delete(msg.body)
	}

	// Check if adapter process died
	if !m.transport.running && m.state != .Idle {
		m.state = .Idle
		_push_console(m, "Debug adapter terminated.", "console")
	}
}

// ---------------------------------------------------------------------------
// Accessors (called from UI — no lock needed since UI is single-threaded
// and writes happen only in debug_tick on the same thread)
// ---------------------------------------------------------------------------

manager_get_state :: proc(m: ^Debug_Manager) -> Debug_State { return m.state }
manager_get_frames :: proc(m: ^Debug_Manager) -> []Stack_Frame { return m.frames[:] }
manager_get_variables :: proc(m: ^Debug_Manager) -> []Variable { return m.variables[:] }
manager_get_threads :: proc(m: ^Debug_Manager) -> []Thread_Info { return m.threads[:] }
manager_get_console :: proc(m: ^Debug_Manager) -> []Console_Line { return m.console[:] }

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

_session_stop :: proc(m: ^Debug_Manager, terminate: bool) {
	if m.state == .Idle { return }
	if m.transport.running {
		msg := build_disconnect(terminate)
		transport_send(&m.transport, msg)
	}
	m.state = .Stopping
	transport_stop(&m.transport)
	m.state = .Idle
	_clear_session_state(m)
	_push_console(m, "Debug session ended.", "console")
}

_clear_session_state :: proc(m: ^Debug_Manager) {
	for &t in m.threads { delete(t.name) }; clear(&m.threads)
	for &f in m.frames  { delete(f.name); delete(f.source) }; clear(&m.frames)
	for &s in m.scopes  { delete(s.name) }; clear(&m.scopes)
	for &v in m.variables { variable_destroy(&v) }; clear(&m.variables)
	m.active_thread = 0
	m.active_frame  = 0
	m.did_stop      = false
	delete(m.stop_file); m.stop_file = ""
	m.stop_line = 0
}

_push_console :: proc(m: ^Debug_Manager, text, category: string) {
	if len(m.console) > 2000 {
		delete(m.console[0].text)
		delete(m.console[0].category)
		ordered_remove(&m.console, 0)
	}
	append(&m.console, Console_Line{
		text     = strings.clone(text),
		category = strings.clone(category),
	})
}

_register_pending :: proc(m: ^Debug_Manager, seq: int, command: string) {
	sync.mutex_lock(&m.pending_mu)
	append(&m.pending, Pending_Req{seq = seq, command = strings.clone(command)})
	sync.mutex_unlock(&m.pending_mu)
}

_pop_pending :: proc(m: ^Debug_Manager, request_seq: int) -> (string, bool) {
	sync.mutex_lock(&m.pending_mu)
	defer sync.mutex_unlock(&m.pending_mu)
	for i := 0; i < len(m.pending); i += 1 {
		if m.pending[i].seq == request_seq {
			cmd := m.pending[i].command
			ordered_remove(&m.pending, i)
			return cmd, true
		}
	}
	return "", false
}

// Extract seq number from a message string (simple scan — already set by build_request)
_extract_seq :: proc(msg: string) -> int {
	needle := `"seq":`
	idx := strings.index(msg, needle)
	if idx < 0 { return 0 }
	start := idx + len(needle)
	n := 0
	for start < len(msg) && msg[start] >= '0' && msg[start] <= '9' {
		n = n*10 + int(msg[start]-'0')
		start += 1
	}
	return n
}

// Send setBreakpoints for a given file (called while m.mu is held)
_sync_breakpoints_locked :: proc(m: ^Debug_Manager, file: string) {
	lines: [dynamic]int
	lines = make([dynamic]int, context.temp_allocator)
	for &b in m.breakpoints {
		if b.file == file && b.enabled { append(&lines, b.line) }
	}
	msg := build_set_breakpoints(file, lines[:])
	transport_send(&m.transport, msg)
}

// Send setBreakpoints for all unique files
_sync_all_breakpoints :: proc(m: ^Debug_Manager) {
	files := make([dynamic]string, context.temp_allocator)
	for &b in m.breakpoints {
		found := false
		for f in files { if f == b.file { found = true; break } }
		if !found { append(&files, b.file) }
	}
	for f in files { _sync_breakpoints_locked(m, f) }
}

// ---------------------------------------------------------------------------
// Message processing (runs on UI thread via debug_tick)
// ---------------------------------------------------------------------------

_process_message :: proc(m: ^Debug_Manager, body: []u8) {
	env, ok := parse_envelope(body)
	if !ok { return }

	switch env.type_ {
	case .Event:   _handle_event(m, &env, body)
	case .Response: _handle_response(m, &env, body)
	case .Request, .Unknown: // ignore
	}
}

_handle_event :: proc(m: ^Debug_Manager, env: ^DAP_Envelope, body: []u8) {
	switch env.event_name {
	case "initialized":
		// Sync breakpoints first, then configurationDone, then launch/attach
		_sync_all_breakpoints(m)
		msg_cd := build_configuration_done()
		transport_send(&m.transport, msg_cd)

		if m._attach_mode {
			// Attach to PID if set, otherwise adapter may already be running target
			if m._attach_pid > 0 {
				msg_a := build_attach(m._attach_pid)
				seq   := _extract_seq(msg_a)
				_register_pending(m, seq, "attach")
				transport_send(&m.transport, msg_a)
				_push_console(m, fmt.tprintf("Attaching to PID %d...", m._attach_pid), "console")
			} else {
				// Remote adapter (TCP): it controls the target; we just tell it we're ready
				msg_a := build_attach(0)
				seq   := _extract_seq(msg_a)
				_register_pending(m, seq, "attach")
				transport_send(&m.transport, msg_a)
				_push_console(m, "Attached to remote adapter.", "console")
			}
		} else {
			msg_l := build_launch(m.launch.program, m.launch.cwd, m.launch.args, m.launch.stop_on_entry)
			seq   := _extract_seq(msg_l)
			_register_pending(m, seq, "launch")
			transport_send(&m.transport, msg_l)
			_push_console(m, "Adapter initialized. Launching...", "console")
		}
		m.state = .Running

	case "stopped":
		val, err := json.parse(body, allocator = context.temp_allocator)
		if err != nil { return }
		defer json.destroy_value(val, context.temp_allocator)
		obj, _ := val.(json.Object)
		body_obj, _ := _json_path_obj(obj, "body")
		reason, _  := _json_str(body_obj, "reason")
		thread_id, _ := _json_int(body_obj, "threadId")

		m.state         = .Paused
		m.active_thread = thread_id
		m.did_stop      = true

		_push_console(m, fmt.tprintf("Stopped: %s (thread %d)", reason, thread_id), "console")

		// Fetch stack trace
		msg := build_stack_trace(thread_id, 0, 20)
		seq := _extract_seq(msg)
		_register_pending(m, seq, "stackTrace")
		transport_send(&m.transport, msg)

	case "continued":
		m.state    = .Running
		m.did_stop = false

	case "output":
		val, err := json.parse(body, allocator = context.temp_allocator)
		if err != nil { return }
		defer json.destroy_value(val, context.temp_allocator)
		obj, _ := val.(json.Object)
		body_obj, _ := _json_path_obj(obj, "body")
		text, _     := _json_str(body_obj, "output")
		category, _ := _json_str(body_obj, "category")
		if text != "" {
			_push_console(m, strings.trim_right(text, "\r\n"), category if category != "" else "stdout")
		}

	case "thread":
		// Re-fetch thread list
		msg := build_threads()
		seq := _extract_seq(msg)
		_register_pending(m, seq, "threads")
		transport_send(&m.transport, msg)

	case "exited", "terminated":
		m.state = .Idle
		_clear_session_state(m)
		_push_console(m, "Program exited.", "console")
		transport_stop(&m.transport)

	case "breakpoint":
		// Update verified state on a breakpoint
		val, err := json.parse(body, allocator = context.temp_allocator)
		if err != nil { return }
		defer json.destroy_value(val, context.temp_allocator)
		obj, _ := val.(json.Object)
		body_obj, _ := _json_path_obj(obj, "body")
		bp_obj, _ := _json_path_obj(body_obj, "breakpoint")
		bp_id, _      := _json_int(bp_obj, "id")
		verified, _   := _json_bool(bp_obj, "verified")
		src_obj, _    := _json_path_obj(bp_obj, "source")
		src_path, _   := _json_str(src_obj, "path")
		bp_line, _    := _json_int(bp_obj, "line")
		for &b in m.breakpoints {
			if b.adapter_id == bp_id || (b.file == src_path && b.line == bp_line) {
				b.verified    = verified
				b.adapter_id  = bp_id
			}
		}
	}
}

_handle_response :: proc(m: ^Debug_Manager, env: ^DAP_Envelope, body: []u8) {
	cmd, found := _pop_pending(m, env.request_seq)
	if found { defer delete(cmd) }

	if !env.success {
		msg := fmt.tprintf("DAP error [%s]: %s", cmd, env.raw_error)
		_push_console(m, msg, "important")
		if cmd == "evaluate" {
			eval_result_destroy(&m.eval_result)
			m.eval_result = Eval_Result{
				expr   = strings.clone(m.eval_result.expr), // keep expression
				result = strings.clone(msg),
				ok     = false,
			}
			m.eval_pending = false
		}
		return
	}

	switch cmd {
	case "initialize":
		// Parse capabilities
		val, err := json.parse(body, allocator = context.temp_allocator)
		if err != nil { return }
		defer json.destroy_value(val, context.temp_allocator)
		obj, _ := val.(json.Object)
		body_obj, _ := _json_path_obj(obj, "body")
		m.supports_restart,     _ = _json_bool(body_obj, "supportsRestartRequest")
		m.supports_step_back,   _ = _json_bool(body_obj, "supportsStepBack")
		m.supports_goto_targets,_ = _json_bool(body_obj, "supportsGotoTargetsRequest")
		m.supports_set_variable,_ = _json_bool(body_obj, "supportsSetVariable")

	case "launch", "attach":
		m.state = .Running
		_push_console(m, "Running.", "console")

	case "stackTrace":
		val, err := json.parse(body, allocator = context.temp_allocator)
		if err != nil { return }
		defer json.destroy_value(val, context.temp_allocator)
		obj, _ := val.(json.Object)
		body_obj, _ := _json_path_obj(obj, "body")
		frames_arr, _ := _json_arr(body_obj, "stackFrames")

		for &f in m.frames { delete(f.name); delete(f.source) }
		clear(&m.frames)

		for frame_v in frames_arr {
			fobj, is_o := frame_v.(json.Object)
			if !is_o { continue }
			id, _   := _json_int(fobj, "id")
			name, _ := _json_str(fobj, "name")
			line, _ := _json_int(fobj, "line")
			col, _  := _json_int(fobj, "column")
			src := ""
			if src_obj, ok := _json_path_obj(fobj, "source"); ok {
				src, _ = _json_str(src_obj, "path")
			}
			append(&m.frames, Stack_Frame{
				id     = id,
				name   = strings.clone(name),
				source = strings.clone(src),
				line   = line,
				col    = col,
			})
		}

		// Update stop_file/stop_line from top frame
		if len(m.frames) > 0 {
			delete(m.stop_file)
			m.stop_file = strings.clone(m.frames[0].source)
			m.stop_line = m.frames[0].line
		}

		// Fetch scopes for active frame
		if len(m.frames) > 0 {
			frame_id := m.frames[m.active_frame].id
			msg := build_scopes(frame_id)
			seq := _extract_seq(msg)
			_register_pending(m, seq, "scopes")
			transport_send(&m.transport, msg)
		}

	case "scopes":
		val, err := json.parse(body, allocator = context.temp_allocator)
		if err != nil { return }
		defer json.destroy_value(val, context.temp_allocator)
		obj, _ := val.(json.Object)
		body_obj, _ := _json_path_obj(obj, "body")
		scopes_arr, _ := _json_arr(body_obj, "scopes")

		for &s in m.scopes { delete(s.name) }
		clear(&m.scopes)
		for &v in m.variables { variable_destroy(&v) }
		clear(&m.variables)

		for scope_v in scopes_arr {
			sobj, is_o := scope_v.(json.Object)
			if !is_o { continue }
			name, _  := _json_str(sobj, "name")
			vref, _  := _json_int(sobj, "variablesReference")
			append(&m.scopes, Scope{name = strings.clone(name), variables_ref = vref})
		}

		// Fetch variables for first scope (locals)
		if len(m.scopes) > 0 && m.scopes[0].variables_ref > 0 {
			msg := build_variables(m.scopes[0].variables_ref, 0, 100)
			seq := _extract_seq(msg)
			_register_pending(m, seq, "variables")
			transport_send(&m.transport, msg)
		}

	case "variables":
		val, err := json.parse(body, allocator = context.temp_allocator)
		if err != nil { return }
		defer json.destroy_value(val, context.temp_allocator)
		obj, _ := val.(json.Object)
		body_obj, _ := _json_path_obj(obj, "body")
		vars_arr, _ := _json_arr(body_obj, "variables")

		for &v in m.variables { variable_destroy(&v) }
		clear(&m.variables)

		for var_v in vars_arr {
			vobj, is_o := var_v.(json.Object)
			if !is_o { continue }
			name, _  := _json_str(vobj, "name")
			value, _ := _json_str(vobj, "value")
			type_, _ := _json_str(vobj, "type")
			vref, _  := _json_int(vobj, "variablesReference")
			append(&m.variables, Variable{
				name          = strings.clone(name),
				value         = strings.clone(value),
				type_         = strings.clone(type_),
				variables_ref = vref,
			})
		}

	case "threads":
		val, err := json.parse(body, allocator = context.temp_allocator)
		if err != nil { return }
		defer json.destroy_value(val, context.temp_allocator)
		obj, _ := val.(json.Object)
		body_obj, _ := _json_path_obj(obj, "body")
		threads_arr, _ := _json_arr(body_obj, "threads")

		for &t in m.threads { delete(t.name) }
		clear(&m.threads)
		for t_v in threads_arr {
			tobj, is_o := t_v.(json.Object)
			if !is_o { continue }
			id, _   := _json_int(tobj, "id")
			name, _ := _json_str(tobj, "name")
			append(&m.threads, Thread_Info{id = id, name = strings.clone(name)})
		}

	case "evaluate":
		val, err := json.parse(body, allocator = context.temp_allocator)
		if err != nil { return }
		defer json.destroy_value(val, context.temp_allocator)
		obj, _ := val.(json.Object)
		body_obj, _ := _json_path_obj(obj, "body")
		result, _ := _json_str(body_obj, "result")
		type_, _  := _json_str(body_obj, "type")

		eval_result_destroy(&m.eval_result)
		m.eval_result = Eval_Result{
			expr   = strings.clone(m.eval_result.expr),
			result = strings.clone(result),
			type_  = strings.clone(type_),
			ok     = true,
		}
		m.eval_pending = false
	}
}

// ---------------------------------------------------------------------------
// Private JSON helpers (redundant with protocol.odin but scoped here)
// ---------------------------------------------------------------------------

_json_path_obj :: proc(obj: json.Object, key: string) -> (json.Object, bool) {
	v, ok := obj[key]
	if !ok { return nil, false }
	o, is_o := v.(json.Object)
	return o, is_o
}

_json_arr :: proc(obj: json.Object, key: string) -> (json.Array, bool) {
	v, ok := obj[key]
	if !ok { return nil, false }
	a, is_a := v.(json.Array)
	return a, is_a
}
