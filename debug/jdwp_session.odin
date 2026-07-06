package debug

// JDWP session orchestration: attach handshake follow-up, breakpoint
// resolution (file:line -> referenceTypeID/methodID/codeIndex), composite
// event handling (breakpoint/step/classPrepare hits), and execution control.
// This is the JDWP analog of the DAP _handle_event/_handle_response pair in
// manager.odin — kept in its own file since the two protocols share almost
// nothing beyond the Debug_Manager struct they both update.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"

// ---------------------------------------------------------------------------
// Pending request bookkeeping (separate id-space from DAP's seq)
// ---------------------------------------------------------------------------

_jdwp_register :: proc(m: ^Debug_Manager, id: int, p: JDWP_Pending) {
	pp := p
	pp.id   = id
	pp.kind = strings.clone(p.kind)
	sync.mutex_lock(&m.pending_mu)
	append(&m.jdwp_pending, pp)
	sync.mutex_unlock(&m.pending_mu)
}

_jdwp_pop :: proc(m: ^Debug_Manager, id: int) -> (JDWP_Pending, bool) {
	sync.mutex_lock(&m.pending_mu)
	defer sync.mutex_unlock(&m.pending_mu)
	for i := 0; i < len(m.jdwp_pending); i += 1 {
		if m.jdwp_pending[i].id == id {
			p := m.jdwp_pending[i]
			ordered_remove(&m.jdwp_pending, i)
			return p, true
		}
	}
	return {}, false
}

_jdwp_send :: proc(m: ^Debug_Manager, msg: []u8) {
	transport_send(&m.transport, string(msg))
	delete(msg)
}

// ---------------------------------------------------------------------------
// Small string helpers (file paths, class names — no cross-package access
// to the editor's path_basename, so these are local)
// ---------------------------------------------------------------------------

_basename :: proc(path: string) -> string {
	slash := strings.last_index_any(path, "/\\")
	return path[slash+1:] if slash >= 0 else path
}

_basename_no_ext :: proc(path: string) -> string {
	b := _basename(path)
	dot := strings.last_index(b, ".")
	if dot >= 0 { return b[:dot] }
	return b
}

// Derive a dotted fully-qualified class name ("com.example.demo.DemoApplication")
// from a .java source file by reading its `package` declaration. Only matches
// the outer (public) class — breakpoints inside inner/lambda classes in the
// same file won't resolve. Caller owns the returned string.
_jdwp_class_name_for_file :: proc(file: string) -> (string, bool) {
	data, err := os.read_entire_file(file, context.temp_allocator)
	if err != nil { return "", false }
	text := string(data)
	pkg := ""
	idx := strings.index(text, "package ")
	if idx >= 0 {
		rest := text[idx+8:]
		semi := strings.index(rest, ";")
		if semi >= 0 { pkg = strings.trim_space(rest[:semi]) }
	}
	base := _basename_no_ext(file)
	if pkg == "" { return strings.clone(base), true }
	return fmt.aprintf("%s.%s", pkg, base), true
}

// ---------------------------------------------------------------------------
// Breakpoint resolution: file:line -> EventRequest.Set(Breakpoint)
// ---------------------------------------------------------------------------

// Try to resolve one breakpoint against classes already known to us. If the
// owning class hasn't loaded yet, this is a no-op — the global ClassPrepare
// watch (armed at attach) will retry every unresolved breakpoint as classes
// come in.
//
// A .java file can define more than one class (a public outer class plus
// nested/inner/lambda/anonymous classes, e.g. a `static class` or
// `@RestController` colocated in the same file). Those all get binary names
// of the form "Outer$Inner" / "Outer$1", so any class whose signature is
// exactly the outer class or starts with "Outer$" is a candidate — every
// candidate is tried in turn (via class_queue) until one has a method whose
// line table contains the target line.
_jdwp_try_resolve_bp :: proc(m: ^Debug_Manager, idx: int) {
	if idx < 0 || idx >= len(m.breakpoints) { return }
	b := m.breakpoints[idx]
	if b.adapter_id != -1 { return }

	class_name, ok := _jdwp_class_name_for_file(b.file)
	if !ok { return }
	defer delete(class_name)

	slashed, _    := strings.replace_all(class_name, ".", "/", context.temp_allocator)
	expected_sig  := fmt.tprintf("L%s;", slashed)
	nested_prefix := fmt.tprintf("L%s$", slashed)

	candidates := make([dynamic]u64, 0, 4, context.temp_allocator)
	for c in m.jdwp_classes {
		if c.signature == expected_sig || strings.has_prefix(c.signature, nested_prefix) {
			append(&candidates, c.ref_type)
		}
	}
	if len(candidates) == 0 { return } // not loaded yet — retried on the next ClassPrepare

	_jdwp_start_class_probe(m, candidates[:], b.file, b.line)
}

// Kick off (or continue) resolution against candidates[0]; candidates[1:]
// becomes the class_queue fallback if candidates[0] has no matching line.
_jdwp_start_class_probe :: proc(m: ^Debug_Manager, candidates: []u64, file: string, line: int) {
	if len(candidates) == 0 {
		_push_console(m, fmt.tprintf("Could not resolve breakpoint %s:%d (no matching line found in any class from this file)", _basename(file), line), "important")
		return
	}
	class_queue_copy := make([]u64, len(candidates)-1)
	copy(class_queue_copy, candidates[1:])

	msg, id := build_methods_with_generic(candidates[0], m.id_sizes)
	_jdwp_register(m, id, JDWP_Pending{
		kind = "methods", ref_type = candidates[0],
		file = strings.clone(file), line = line,
		class_queue = class_queue_copy,
	})
	_jdwp_send(m, msg)
}

// Fetch the line table for methods_queue[0]; on failure (no matching line),
// try the next method, then the next candidate class. Copies `remaining`
// since the caller's backing array may be freed (jdwp_pending_destroy)
// before this chain completes.
_jdwp_probe_next_method :: proc(m: ^Debug_Manager, ref_type: u64, file: string, line: int, remaining: []u64, class_queue: []u64) {
	if len(remaining) == 0 {
		_jdwp_start_class_probe(m, class_queue, file, line)
		return
	}
	queue_copy := make([]u64, len(remaining))
	copy(queue_copy, remaining)
	class_queue_copy := make([]u64, len(class_queue))
	copy(class_queue_copy, class_queue)
	msg, id := build_line_table(ref_type, queue_copy[0], m.id_sizes)
	_jdwp_register(m, id, JDWP_Pending{
		kind = "linetable", ref_type = ref_type,
		file = strings.clone(file), line = line,
		methods_queue = queue_copy,
		class_queue = class_queue_copy,
	})
	_jdwp_send(m, msg)
}

// Requests names, source line, and source filename for every frame of the
// current call stack (not just the top frame, previously the only one that
// got resolved) — a stack commonly spans several classes (app code,
// reflection internals, framework proxies):
//   - Methods_WithGeneric once per distinct ref_type -> method names
//     ("frame_methods" reply patches every frame sharing that ref_type)
//   - Method.LineTable once per frame (its code_index is frame-specific
//     even when the ref_type/method is shared) -> frames[i].line
//   - ReferenceType.SourceFile once per distinct ref_type -> frames[i].source,
//     the bare filename JDWP knows the class was compiled from; matching
//     that against the actual workspace layout is left to the caller
//     (jump-to-frame), since JDWP has no notion of project structure.
_jdwp_fetch_frame_details :: proc(m: ^Debug_Manager) {
	seen_names, seen_src: map[u64]bool
	seen_names = make(map[u64]bool, 0, context.temp_allocator)
	seen_src   = make(map[u64]bool, 0, context.temp_allocator)

	for fe, i in m.jdwp_frame_ext {
		if !seen_names[fe.ref_type] {
			seen_names[fe.ref_type] = true
			msg, id := build_methods_with_generic(fe.ref_type, m.id_sizes)
			_jdwp_register(m, id, JDWP_Pending{kind = "frame_methods", ref_type = fe.ref_type})
			_jdwp_send(m, msg)
		}

		lmsg, lid := build_line_table(fe.ref_type, fe.method_id, m.id_sizes)
		_jdwp_register(m, lid, JDWP_Pending{kind = "frame_linetable", code_index = fe.code_index, line = i})
		_jdwp_send(m, lmsg)

		if !seen_src[fe.ref_type] {
			seen_src[fe.ref_type] = true
			smsg, sid := build_source_file(fe.ref_type, m.id_sizes)
			_jdwp_register(m, sid, JDWP_Pending{kind = "frame_sourcefile", ref_type = fe.ref_type})
			_jdwp_send(m, smsg)
		}
	}
}

_jdwp_bp_lookup :: proc(m: ^Debug_Manager, request_id: int) -> (string, int) {
	for b in m.breakpoints {
		if b.adapter_id == request_id { return b.file, b.line }
	}
	return "", 0
}

// ---------------------------------------------------------------------------
// Execution control
// ---------------------------------------------------------------------------

_jdwp_continue :: proc(m: ^Debug_Manager) {
	msg, _ := build_vm_resume()
	_jdwp_send(m, msg)
	m.state = .Running
	_push_console(m, "Continuing.", "console")
}

_jdwp_pause :: proc(m: ^Debug_Manager) {
	msg, id := build_vm_suspend()
	_jdwp_register(m, id, JDWP_Pending{kind = "suspend_ack"})
	_jdwp_send(m, msg)
}

_jdwp_step :: proc(m: ^Debug_Manager, depth: int) {
	msg, id := build_step(u64(m.active_thread), depth, m.id_sizes)
	_jdwp_register(m, id, JDWP_Pending{kind = "step_armed"})
	_jdwp_send(m, msg)
}

// Fetch and populate m.variables with the active frame's in-scope locals.
// Called after any stop (breakpoint/step/pause) and whenever the UI switches
// the active frame. Async: VariableTable (which locals + their slots) then
// StackFrame.GetValues (their current values), with a further round trip per
// String local to resolve its actual text.
_jdwp_fetch_locals :: proc(m: ^Debug_Manager) {
	if m.active_frame < 0 || m.active_frame >= len(m.jdwp_frame_ext) { return }
	fr := m.jdwp_frame_ext[m.active_frame]
	msg, id := build_variable_table(fr.ref_type, fr.method_id, m.id_sizes)
	_jdwp_register(m, id, JDWP_Pending{
		kind = "locals_vartable", thread_id = fr.thread_id, frame_id = fr.frame_id, code_index = fr.code_index,
	})
	_jdwp_send(m, msg)
}

// ---------------------------------------------------------------------------
// Evaluate — local-variable lookup, plus zero-arg method calls on a local
// (e.g. "response.toString()") via real ObjectReference.InvokeMethod. JDWP
// has no expression evaluator and no argument marshalling here — this covers
// the single most useful case (seeing an object's actual contents instead of
// its raw reference) without building a general expression engine.
//
// JDWP_Pending field reuse through this chain (fields otherwise unused by
// these kinds): `file` carries the receiver identifier, then "string"/"other"
// for the eval_getvalue string-fetch flag; `reason` carries the method name
// once a call is requested; `code_index` carries an objectID once resolved.
// ---------------------------------------------------------------------------

_jdwp_evaluate :: proc(m: ^Debug_Manager, expr: string) {
	eval_result_destroy(&m.eval_result)
	m.eval_result = Eval_Result{expr = strings.clone(expr)}

	if m.state != .Paused || len(m.jdwp_frame_ext) == 0 || m.active_frame >= len(m.jdwp_frame_ext) {
		m.eval_result.result = strings.clone("not stopped")
		m.eval_result.ok = false
		return
	}

	recv, method, is_call := _jdwp_parse_method_call(expr)
	name := is_call ? recv : strings.trim_space(expr)

	fr := m.jdwp_frame_ext[m.active_frame]
	m.eval_pending = true
	msg, id := build_variable_table(fr.ref_type, fr.method_id, m.id_sizes)
	_jdwp_register(m, id, JDWP_Pending{
		kind = "eval_vartable", thread_id = fr.thread_id, frame_id = fr.frame_id,
		file = strings.clone(name), reason = is_call ? strings.clone(method) : "",
	})
	_jdwp_send(m, msg)
}

// Recognizes "recv.method()" — a bare identifier, a dot, another bare
// identifier, and an empty argument list. Anything more (arguments, chained
// calls, operators) falls through to plain-identifier lookup and reports
// "not found", same as before.
_jdwp_parse_method_call :: proc(expr: string) -> (recv, method: string, ok: bool) {
	e := strings.trim_space(expr)
	if !strings.has_suffix(e, "()") { return "", "", false }
	body := strings.trim_space(e[:len(e)-2])
	dot := strings.last_index(body, ".")
	if dot < 0 { return "", "", false }
	recv = strings.trim_space(body[:dot])
	method = strings.trim_space(body[dot+1:])
	if recv == "" || method == "" { return "", "", false }
	for c in recv   { if !_jdwp_is_ident_char(rune(c)) { return "", "", false } }
	for c in method { if !_jdwp_is_ident_char(rune(c)) { return "", "", false } }
	return recv, method, true
}

_jdwp_is_ident_char :: proc(r: rune) -> bool {
	return r == '_' || (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9')
}

// A successful (or even exception-throwing) ObjectReference.InvokeMethod
// call temporarily resumes the invoking thread to run the method, which
// invalidates every FrameID previously obtained for it — re-fetch frames
// (and thus locals) so the panel and any further evaluate calls stay valid.
_jdwp_refresh_frames_after_invoke :: proc(m: ^Debug_Manager, thread_id: u64) {
	msg, id := build_thread_frames(thread_id, 0, -1, m.id_sizes)
	_jdwp_register(m, id, JDWP_Pending{kind = "eval_refresh_frames", thread_id = thread_id})
	_jdwp_send(m, msg)
}

// ---------------------------------------------------------------------------
// Expandable variable tree — ObjectReference.ReferenceType picks class vs.
// array, then either ReferenceType.Fields + ObjectReference.GetValues, or
// ArrayReference.Length + ArrayReference.GetValues. `code_index` carries the
// objectID/arrayID through the whole chain (unused by these kinds otherwise).
// ---------------------------------------------------------------------------

MAX_EXPAND_ARRAY_ELEMS :: 100

_jdwp_expand_variable :: proc(m: ^Debug_Manager, object_id: u64) {
	msg, id := build_object_reference_type(object_id, m.id_sizes)
	_jdwp_register(m, id, JDWP_Pending{kind = "expand_reftype", code_index = object_id})
	_jdwp_send(m, msg)
}

// Converts a JVM type descriptor ("Ljava/lang/String;", "[I", "I", ...) into
// a short display name ("String", "int[]", "int"). Uses the field's declared
// type, not the value's runtime type (that would need another round trip per
// field) — so a field declared as an interface (e.g. `List`) shows that
// declared name even when the live object is some concrete impl class.
_jdwp_pretty_sig :: proc(sig: string) -> string {
	if len(sig) == 0 { return strings.clone("") }
	switch sig[0] {
	case 'Z': return strings.clone("boolean")
	case 'B': return strings.clone("byte")
	case 'C': return strings.clone("char")
	case 'S': return strings.clone("short")
	case 'I': return strings.clone("int")
	case 'J': return strings.clone("long")
	case 'F': return strings.clone("float")
	case 'D': return strings.clone("double")
	case 'V': return strings.clone("void")
	case '[':
		inner := _jdwp_pretty_sig(sig[1:])
		defer delete(inner)
		return fmt.aprintf("%s[]", inner)
	case 'L':
		body := len(sig) >= 2 ? sig[1:len(sig)-1] : sig
		slash := strings.last_index(body, "/")
		return strings.clone(slash >= 0 ? body[slash+1:] : body)
	case:
		return strings.clone(sig)
	}
}

_jdwp_format_value :: proc(v: JDWP_Value) -> string {
	switch v.tag {
	case 'Z': return strings.clone(v.i_val != 0 ? "true" : "false")
	case 'B', 'S', 'I', 'J': return fmt.aprintf("%d", v.i_val)
	case 'C': return fmt.aprintf("%c", rune(v.i_val))
	case 'F':
		f := transmute(f32)u32(v.i_val)
		return fmt.aprintf("%f", f)
	case 'D':
		d := transmute(f64)u64(v.i_val)
		return fmt.aprintf("%f", d)
	case 'V': return strings.clone("void")
	case: return fmt.aprintf("<object 0x%x>", v.obj_id)
	}
}

// ---------------------------------------------------------------------------
// Top-level dispatch — called from debug_tick for every drained packet
// ---------------------------------------------------------------------------

_jdwp_process_message :: proc(m: ^Debug_Manager, body: []u8) {
	hdr  := jdwp_parse_header(body)
	data := jdwp_data(body)
	if hdr.is_reply {
		_jdwp_handle_reply(m, hdr, data)
	} else if hdr.cmd_set == JDWP_CS_Event && hdr.cmd == JDWP_EV_Composite {
		_jdwp_handle_composite(m, data)
	}
}

_jdwp_handle_composite :: proc(m: ^Debug_Manager, data: []u8) {
	_, events, ok := decode_composite_event(data, m.id_sizes)
	defer delete(events)

	for ev in events {
		switch ev.kind {
		case JDWP_EK_CLASS_PREPARE:
			append(&m.jdwp_classes, JDWP_Class{ref_type = ev.ref_type, signature = ev.signature})
			for i := 0; i < len(m.breakpoints); i += 1 {
				if m.breakpoints[i].adapter_id == -1 { _jdwp_try_resolve_bp(m, i) }
			}

		case JDWP_EK_BREAKPOINT:
			m.state = .Paused
			m.active_thread = int(ev.thread_id)
			file, line := _jdwp_bp_lookup(m, ev.request_id)
			msg, id := build_thread_frames(ev.thread_id, 0, -1, m.id_sizes)
			_jdwp_register(m, id, JDWP_Pending{
				kind = "frames", thread_id = ev.thread_id,
				reason = strings.clone("breakpoint"), file = strings.clone(file), line = line,
			})
			_jdwp_send(m, msg)

		case JDWP_EK_SINGLE_STEP:
			m.state = .Paused
			m.active_thread = int(ev.thread_id)
			msg, id := build_thread_frames(ev.thread_id, 0, -1, m.id_sizes)
			_jdwp_register(m, id, JDWP_Pending{
				kind = "frames", thread_id = ev.thread_id, reason = strings.clone("step"),
			})
			_jdwp_send(m, msg)

		case JDWP_EK_VM_DEATH:
			m.state = .Idle
			_clear_session_state(m)
			_push_console(m, "Target JVM exited.", "console")
			transport_stop(&m.transport)
		}
	}

	if !ok {
		_push_console(m, "JDWP: unrecognized event kind in composite (rest of batch dropped)", "console")
	}
}

_jdwp_handle_reply :: proc(m: ^Debug_Manager, hdr: JDWP_Header, data: []u8) {
	p, found := _jdwp_pop(m, hdr.id)
	if !found { return }
	defer jdwp_pending_destroy(&p)

	if hdr.error_code != 0 {
		_push_console(m, fmt.tprintf("JDWP error [%s]: code %d", p.kind, hdr.error_code), "important")
		if strings.has_prefix(p.kind, "eval_") {
			m.eval_result.result = strings.clone(fmt.tprintf("JDWP error code %d", hdr.error_code))
			m.eval_result.ok     = false
			m.eval_pending       = false
		}
		return
	}

	switch p.kind {
	case "idsizes":
		m.id_sizes = decode_id_sizes(data)
		msg, id := build_all_classes_with_generic()
		_jdwp_register(m, id, JDWP_Pending{kind = "allclasses_init"})
		_jdwp_send(m, msg)

	case "allclasses_init":
		entries := decode_all_classes_with_generic(data, m.id_sizes)
		for e in entries {
			append(&m.jdwp_classes, JDWP_Class{ref_type = e.ref_type, signature = e.signature})
		}
		delete(entries)

		msg, id := build_class_prepare_request()
		_jdwp_register(m, id, JDWP_Pending{kind = "classprepare_setup"})
		_jdwp_send(m, msg)

		m.state = .Running
		_push_console(m, "Attached (JDWP).", "console")
		for i := 0; i < len(m.breakpoints); i += 1 {
			if m.breakpoints[i].adapter_id == -1 { _jdwp_try_resolve_bp(m, i) }
		}

	case "classprepare_setup":
		// event request armed, nothing further to do

	case "setbp":
		req_id := decode_set_event_reply(data)
		for &b in m.breakpoints {
			if b.file == p.file && b.line == p.line {
				b.adapter_id = req_id
				b.verified   = true
				break
			}
		}
		_push_console(m, fmt.tprintf("Breakpoint set at %s:%d", _basename(p.file), p.line), "console")

	case "methods":
		methods := decode_methods_with_generic(data, m.id_sizes)
		ids := make([dynamic]u64, 0, len(methods))
		for me in methods {
			append(&ids, me.method_id)
			delete(me.name); delete(me.signature)
		}
		delete(methods)
		_jdwp_probe_next_method(m, p.ref_type, p.file, p.line, ids[:], p.class_queue)
		delete(ids)

	case "linetable":
		_, _, lines := decode_line_table(data)
		found := false
		found_ci: u64
		for le in lines {
			if le.line == p.line { found_ci = le.code_index; found = true; break }
		}
		if !found {
			best_line := -1
			for le in lines {
				if le.line >= p.line && (best_line == -1 || le.line < best_line) {
					best_line = le.line; found_ci = le.code_index; found = true
				}
			}
		}
		delete(lines)
		if found {
			msg, id := build_set_breakpoint(p.ref_type, p.methods_queue[0], found_ci, m.id_sizes)
			_jdwp_register(m, id, JDWP_Pending{kind = "setbp", file = strings.clone(p.file), line = p.line})
			_jdwp_send(m, msg)
		} else {
			_jdwp_probe_next_method(m, p.ref_type, p.file, p.line, p.methods_queue[1:], p.class_queue)
		}

	case "frames":
		entries := decode_thread_frames(data, m.id_sizes)
		_var_children_clear(m)
		for &f in m.frames { delete(f.name); delete(f.source) }
		clear(&m.frames)
		clear(&m.jdwp_frame_ext)
		for fe in entries {
			append(&m.jdwp_frame_ext, JDWP_Frame_Ext{
				thread_id = p.thread_id, frame_id = fe.frame_id, ref_type = fe.ref_type,
				method_id = fe.method_id, code_index = fe.code_index,
			})
			append(&m.frames, Stack_Frame{
				// heap-allocated: Stack_Frame.name is freed with delete() elsewhere
				// (frame_methods reply, _clear_session_state) — tprintf's temp
				// allocation would corrupt the heap allocator when that runs.
				id = len(m.frames), name = fmt.aprintf("0x%x", fe.method_id), source = "",
			})
		}
		delete(entries)
		m.active_frame = 0
		m.did_stop     = true
		_jdwp_fetch_locals(m)

		if p.reason == "breakpoint" {
			delete(m.stop_file)
			m.stop_file = strings.clone(p.file)
			m.stop_line = p.line
			if len(m.frames) > 0 { m.frames[0].line = p.line }
			_push_console(m, fmt.tprintf("Stopped: breakpoint at %s:%d", _basename(p.file), p.line), "console")
		} else if len(m.jdwp_frame_ext) > 0 {
			top := m.jdwp_frame_ext[0]
			msg, id := build_line_table(top.ref_type, top.method_id, m.id_sizes)
			_jdwp_register(m, id, JDWP_Pending{kind = "stop_linetable", code_index = top.code_index, reason = strings.clone(p.reason)})
			_jdwp_send(m, msg)
		} else {
			_push_console(m, fmt.tprintf("Stopped: %s", p.reason), "console")
		}

		_jdwp_fetch_frame_details(m)

	case "stop_linetable":
		_, _, lines := decode_line_table(data)
		best_line := 0
		best_ci: u64
		first := true
		for le in lines {
			if le.code_index <= p.code_index && (first || le.code_index >= best_ci) {
				best_ci = le.code_index; best_line = le.line; first = false
			}
		}
		delete(lines)
		m.stop_line = best_line
		if len(m.frames) > 0 { m.frames[0].line = best_line }
		_push_console(m, fmt.tprintf("Stopped: %s at %s:%d", p.reason, _basename(m.stop_file), best_line), "console")

	case "frame_methods":
		methods := decode_methods_with_generic(data, m.id_sizes)
		for i := 0; i < len(m.jdwp_frame_ext); i += 1 {
			if m.jdwp_frame_ext[i].ref_type != p.ref_type { continue }
			for me in methods {
				if me.method_id == m.jdwp_frame_ext[i].method_id && i < len(m.frames) {
					delete(m.frames[i].name)
					m.frames[i].name = strings.clone(me.name)
					break
				}
			}
		}
		for me in methods { delete(me.name); delete(me.signature) }
		delete(methods)

	case "frame_linetable":
		// `code_index` = this frame's PC, `line` = which m.frames[] slot to patch
		// (repurposed — see JDWP_Pending field-reuse note near the eval section).
		_, _, lines := decode_line_table(data)
		best_line := 0
		best_ci: u64
		first := true
		for le in lines {
			if le.code_index <= p.code_index && (first || le.code_index >= best_ci) {
				best_ci = le.code_index; best_line = le.line; first = false
			}
		}
		delete(lines)
		if p.line >= 0 && p.line < len(m.frames) { m.frames[p.line].line = best_line }

	case "frame_sourcefile":
		name := decode_source_file(data)
		for i := 0; i < len(m.jdwp_frame_ext); i += 1 {
			if m.jdwp_frame_ext[i].ref_type != p.ref_type || i >= len(m.frames) { continue }
			delete(m.frames[i].source)
			m.frames[i].source = strings.clone(name)
		}
		delete(name)

	case "locals_vartable":
		_, vars := decode_variable_table(data)
		for &lm in m.jdwp_locals_meta { delete(lm.name); delete(lm.signature) }
		clear(&m.jdwp_locals_meta)

		slots := make([dynamic]Slot_Req, 0, len(vars), context.temp_allocator)
		for v in vars {
			in_scope := v.code_index <= p.code_index && p.code_index < v.code_index + u64(v.length)
			if !in_scope || len(v.signature) == 0 {
				delete(v.name); delete(v.signature)
				continue
			}
			append(&m.jdwp_locals_meta, JDWP_Local_Meta{name = v.name, signature = v.signature, slot = v.slot})
			append(&slots, Slot_Req{slot = v.slot, tag = u8(v.signature[0])})
		}
		delete(vars)

		for &vv in m.variables { variable_destroy(&vv) }
		clear(&m.variables)
		if len(slots) > 0 {
			msg, id := build_stack_get_values(p.thread_id, p.frame_id, slots[:], m.id_sizes)
			_jdwp_register(m, id, JDWP_Pending{kind = "locals_getvalues", thread_id = p.thread_id, frame_id = p.frame_id})
			_jdwp_send(m, msg)
		}

	case "locals_getvalues":
		values := decode_stack_get_values(data, m.id_sizes)
		for &vv in m.variables { variable_destroy(&vv) }
		clear(&m.variables)
		for i := 0; i < len(values) && i < len(m.jdwp_locals_meta); i += 1 {
			meta := m.jdwp_locals_meta[i]
			val  := values[i]
			is_string := meta.signature == "Ljava/lang/String;"
			val_str: string
			if is_string && val.tag != 'V' {
				val_str = strings.clone("…")
			} else if val.tag == 'L' || val.tag == '[' {
				val_str = val.obj_id == 0 ? strings.clone("null") : fmt.aprintf("{{%s@%d}}", _jdwp_pretty_sig(meta.signature), val.obj_id)
			} else {
				val_str = _jdwp_format_value(val)
			}
			is_obj := !is_string && (val.tag == 'L' || val.tag == '[') && val.obj_id != 0
			append(&m.variables, Variable{
				name = strings.clone(meta.name), value = val_str, type_ = _jdwp_pretty_sig(meta.signature),
				variables_ref = is_obj ? int(val.obj_id) : 0,
			})
			if is_string && val.tag != 'V' {
				msg, id := build_string_value(val.obj_id, m.id_sizes)
				// `line` repurposed here to carry the variables[] index to patch on reply.
				_jdwp_register(m, id, JDWP_Pending{kind = "locals_stringvalue", line = len(m.variables) - 1})
				_jdwp_send(m, msg)
			}
		}
		delete(values)

	case "locals_stringvalue":
		if p.line >= 0 && p.line < len(m.variables) {
			delete(m.variables[p.line].value)
			m.variables[p.line].value = decode_string_value(data)
		}

	case "suspend_ack":
		msg, id := build_all_threads()
		_jdwp_register(m, id, JDWP_Pending{kind = "pause_threads"})
		_jdwp_send(m, msg)

	case "pause_threads":
		ids := decode_all_threads(data, m.id_sizes)
		if len(ids) > 0 {
			tid := ids[0]
			m.state = .Paused
			m.active_thread = int(tid)
			msg, id := build_thread_frames(tid, 0, -1, m.id_sizes)
			_jdwp_register(m, id, JDWP_Pending{kind = "frames", thread_id = tid, reason = strings.clone("pause")})
			_jdwp_send(m, msg)
		}
		delete(ids)

	case "step_armed":
		msg, _ := build_vm_resume()
		_jdwp_send(m, msg)
		m.state = .Running

	case "eval_vartable":
		_, vars := decode_variable_table(data)
		target := p.file
		match_idx := -1
		for i := 0; i < len(vars); i += 1 {
			if vars[i].name == target { match_idx = i; break }
		}
		if match_idx == -1 {
			m.eval_result.result = strings.clone("not found (JDWP evaluate supports local variable names only)")
			m.eval_result.ok     = false
			m.eval_pending       = false
		} else {
			sig  := vars[match_idx].signature
			tag  := u8(sig[0])
			slot := vars[match_idx].slot
			is_string := sig == "Ljava/lang/String;"
			msg, id := build_stack_get_values(p.thread_id, p.frame_id, []Slot_Req{{slot = slot, tag = tag}}, m.id_sizes)
			_jdwp_register(m, id, JDWP_Pending{
				kind = "eval_getvalue", thread_id = p.thread_id,
				file = strings.clone(p.reason != "" ? "call" : (is_string ? "string" : "other")),
				reason = strings.clone(p.reason),
				sig  = strings.clone(sig),
			})
			_jdwp_send(m, msg)
		}
		for v in vars { delete(v.name); delete(v.signature) }
		delete(vars)

	case "eval_getvalue":
		values := decode_stack_get_values(data, m.id_sizes)
		if len(values) == 0 {
			m.eval_result.result = strings.clone("<no value>")
			m.eval_result.ok     = true
			m.eval_pending       = false
		} else if p.file == "call" {
			v := values[0]
			if v.tag != 'L' && v.tag != 's' && v.tag != '[' {
				m.eval_result.result = strings.clone("cannot call a method on a primitive value")
				m.eval_result.ok     = false
				m.eval_pending       = false
			} else {
				msg, id := build_object_reference_type(v.obj_id, m.id_sizes)
				_jdwp_register(m, id, JDWP_Pending{
					kind = "eval_objtype", thread_id = p.thread_id, code_index = v.obj_id,
					reason = strings.clone(p.reason),
				})
				_jdwp_send(m, msg)
			}
		} else if p.file == "string" && values[0].tag != 'V' {
			msg, id := build_string_value(values[0].obj_id, m.id_sizes)
			_jdwp_register(m, id, JDWP_Pending{kind = "eval_stringvalue"})
			_jdwp_send(m, msg)
		} else {
			v := values[0]
			if (v.tag == 'L' || v.tag == '[') && v.obj_id != 0 {
				m.eval_result.result = fmt.aprintf("{{%s@%d}}", _jdwp_pretty_sig(p.sig), v.obj_id)
			} else {
				m.eval_result.result = _jdwp_format_value(v)
			}
			m.eval_result.ok     = true
			m.eval_pending       = false
			if (v.tag == 'L' || v.tag == '[') && v.obj_id != 0 { m.eval_result.variables_ref = int(v.obj_id) }
		}
		delete(values)

	case "eval_objtype":
		_, ref_type := decode_object_reference_type(data, m.id_sizes)
		msg, id := build_methods_with_generic(ref_type, m.id_sizes)
		_jdwp_register(m, id, JDWP_Pending{
			kind = "eval_methods", ref_type = ref_type, thread_id = p.thread_id,
			code_index = p.code_index, reason = strings.clone(p.reason),
		})
		_jdwp_send(m, msg)

	case "eval_methods":
		methods := decode_methods_with_generic(data, m.id_sizes)
		found_id: u64
		found := false
		for me in methods {
			if me.name == p.reason && strings.has_prefix(me.signature, "()") {
				found_id = me.method_id
				found = true
			}
		}
		for me in methods { delete(me.name); delete(me.signature) }
		delete(methods)
		if !found {
			// Not declared on this class — walk up to its superclass (e.g.
			// HashMap doesn't declare toString(), AbstractMap does).
			msg, id := build_superclass(p.ref_type, m.id_sizes)
			_jdwp_register(m, id, JDWP_Pending{
				kind = "eval_superclass", thread_id = p.thread_id,
				code_index = p.code_index, reason = strings.clone(p.reason),
			})
			_jdwp_send(m, msg)
		} else {
			msg, id := build_invoke_method(p.code_index, p.thread_id, p.ref_type, found_id, m.id_sizes)
			_jdwp_register(m, id, JDWP_Pending{kind = "eval_invoke", thread_id = p.thread_id})
			_jdwp_send(m, msg)
		}

	case "eval_superclass":
		super_ref := decode_superclass(data, m.id_sizes)
		if super_ref == 0 {
			m.eval_result.result = strings.clone(fmt.tprintf("method %s() not found", p.reason))
			m.eval_result.ok     = false
			m.eval_pending       = false
		} else {
			msg, id := build_methods_with_generic(super_ref, m.id_sizes)
			_jdwp_register(m, id, JDWP_Pending{
				kind = "eval_methods", ref_type = super_ref, thread_id = p.thread_id,
				code_index = p.code_index, reason = strings.clone(p.reason),
			})
			_jdwp_send(m, msg)
		}

	case "eval_invoke":
		result, exception_id := decode_invoke_reply(data, m.id_sizes)
		if exception_id != 0 {
			m.eval_result.result = strings.clone("exception thrown while calling method")
			m.eval_result.ok     = false
			m.eval_pending       = false
			_jdwp_refresh_frames_after_invoke(m, p.thread_id)
		} else if result.tag == 's' {
			msg, id := build_string_value(result.obj_id, m.id_sizes)
			// file="invoked" marks this so eval_stringvalue knows a frame
			// refresh is owed — a plain string-variable fetch doesn't need one.
			_jdwp_register(m, id, JDWP_Pending{kind = "eval_stringvalue", thread_id = p.thread_id, file = strings.clone("invoked")})
			_jdwp_send(m, msg)
		} else {
			m.eval_result.result = _jdwp_format_value(result)
			m.eval_result.ok     = true
			m.eval_pending       = false
			_jdwp_refresh_frames_after_invoke(m, p.thread_id)
		}

	case "eval_stringvalue":
		m.eval_result.result = decode_string_value(data)
		m.eval_result.ok     = true
		m.eval_pending       = false
		if p.file == "invoked" { _jdwp_refresh_frames_after_invoke(m, p.thread_id) }

	case "eval_refresh_frames":
		entries := decode_thread_frames(data, m.id_sizes)
		for &f in m.frames { delete(f.name); delete(f.source) }
		clear(&m.frames)
		clear(&m.jdwp_frame_ext)
		for fe in entries {
			append(&m.jdwp_frame_ext, JDWP_Frame_Ext{
				thread_id = p.thread_id, frame_id = fe.frame_id, ref_type = fe.ref_type,
				method_id = fe.method_id, code_index = fe.code_index,
			})
			append(&m.frames, Stack_Frame{id = len(m.frames), name = fmt.aprintf("0x%x", fe.method_id), source = ""})
		}
		delete(entries)
		if m.active_frame >= len(m.frames) { m.active_frame = 0 }
		_jdwp_fetch_frame_details(m)
		_jdwp_fetch_locals(m)

	case "expand_reftype":
		tag, ref_type := decode_object_reference_type(data, m.id_sizes)
		obj_id := p.code_index
		if tag == JDWP_TYPETAG_ARRAY {
			msg, id := build_array_length(obj_id, m.id_sizes)
			_jdwp_register(m, id, JDWP_Pending{kind = "expand_arrlen", code_index = obj_id})
			_jdwp_send(m, msg)
		} else {
			msg, id := build_fields(ref_type, m.id_sizes)
			_jdwp_register(m, id, JDWP_Pending{kind = "expand_fields", code_index = obj_id})
			_jdwp_send(m, msg)
		}

	case "expand_fields":
		obj_id := p.code_index
		fields := decode_fields(data, m.id_sizes)

		ids   := make([dynamic]u64, 0, len(fields), context.temp_allocator)
		metas := make([dynamic]JDWP_Field_Meta, 0, len(fields))
		for f in fields {
			is_static := f.mod_bits & 0x0008 != 0
			if is_static {
				delete(f.name); delete(f.signature)
				continue
			}
			append(&ids, f.field_id)
			append(&metas, JDWP_Field_Meta{name = f.name, signature = f.signature})
		}
		delete(fields)

		if len(ids) == 0 {
			m.var_children[int(obj_id)] = {}
			m.expanding_ref = 0
			for me in metas { delete(me.name); delete(me.signature) }
			delete(metas)
		} else {
			m.jdwp_expand_field_meta[int(obj_id)] = metas[:]
			msg, id := build_object_get_values(obj_id, ids[:], m.id_sizes)
			_jdwp_register(m, id, JDWP_Pending{kind = "expand_getvalues", code_index = obj_id})
			_jdwp_send(m, msg)
		}

	case "expand_getvalues":
		obj_id := p.code_index
		metas, has_metas := m.jdwp_expand_field_meta[int(obj_id)]
		values := decode_stack_get_values(data, m.id_sizes)

		n := has_metas ? min(len(values), len(metas)) : 0
		out := make([]Variable, n)
		for i in 0..<n {
			v    := values[i]
			meta := metas[i]
			is_obj := (v.tag == 'L' || v.tag == '[') && v.obj_id != 0
			val_str: string
			if (v.tag == 'L' || v.tag == '[') {
				val_str = v.obj_id == 0 ? strings.clone("null") : fmt.aprintf("{{%s@%d}}", _jdwp_pretty_sig(meta.signature), v.obj_id)
			} else {
				val_str = _jdwp_format_value(v)
			}
			out[i] = Variable{
				name = strings.clone(meta.name), value = val_str, type_ = _jdwp_pretty_sig(meta.signature),
				variables_ref = is_obj ? int(v.obj_id) : 0,
			}
		}
		delete(values)
		if has_metas {
			for me in metas { delete(me.name); delete(me.signature) }
			delete(metas)
			delete_key(&m.jdwp_expand_field_meta, int(obj_id))
		}
		m.var_children[int(obj_id)] = out
		m.expanding_ref = 0

	case "expand_arrlen":
		obj_id := p.code_index
		n := decode_array_length(data)
		if n == 0 {
			m.var_children[int(obj_id)] = {}
			m.expanding_ref = 0
		} else {
			msg, id := build_array_get_values(obj_id, 0, min(n, MAX_EXPAND_ARRAY_ELEMS), m.id_sizes)
			_jdwp_register(m, id, JDWP_Pending{kind = "expand_arrvalues", code_index = obj_id})
			_jdwp_send(m, msg)
		}

	case "expand_arrvalues":
		obj_id := p.code_index
		type_tag, values := decode_array_values(data, m.id_sizes)
		is_obj_tag := type_tag == 'L' || type_tag == '[' || type_tag == 's'
		out := make([]Variable, len(values))
		for i in 0..<len(values) {
			v := values[i]
			val_str: string
			ref: int
			if is_obj_tag {
				val_str = v.obj_id == 0 ? strings.clone("null") : fmt.aprintf("{{@%d}}", v.obj_id)
				ref = v.obj_id != 0 ? int(v.obj_id) : 0
			} else {
				val_str = _jdwp_format_value(v)
			}
			out[i] = Variable{name = fmt.aprintf("[%d]", i), value = val_str, type_ = strings.clone(""), variables_ref = ref}
		}
		delete(values)
		m.var_children[int(obj_id)] = out
		m.expanding_ref = 0
	}
}
