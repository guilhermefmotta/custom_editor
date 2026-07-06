package debug

// JDWP (Java Debug Wire Protocol) codec.
// Wire format is completely different from DAP: no JSON, no Content-Length
// framing. Handshake is a literal 14-byte ASCII exchange, then every packet
// is: length(u32BE) + id(u32BE) + flags(u8) + [cmdSet(u8) cmd(u8) | errorCode(u16BE)] + data.
// ID-typed fields (object/thread/referenceType/method/field/frame) have a
// wire size negotiated via VirtualMachine.IDSizes — everything else (counts,
// code indices) is fixed size per spec.

import "core:strings"
import "core:sync"

JDWP_HANDSHAKE :: "JDWP-Handshake"

// ---------------------------------------------------------------------------
// Command sets / commands used
// ---------------------------------------------------------------------------

JDWP_CS_VirtualMachine    :: 1
JDWP_CS_ReferenceType     :: 2
JDWP_CS_Method            :: 6
JDWP_CS_ObjectReference   :: 9
JDWP_CS_StringReference   :: 10
JDWP_CS_ThreadReference   :: 11
JDWP_CS_ArrayReference    :: 13
JDWP_CS_EventRequest      :: 15
JDWP_CS_StackFrame        :: 16
JDWP_CS_Event             :: 64

JDWP_VM_Version           :: 1
JDWP_VM_AllClassesWithGeneric :: 20
JDWP_VM_IDSizes           :: 7
JDWP_VM_Dispose           :: 6
JDWP_VM_Suspend           :: 8
JDWP_VM_Resume            :: 9
JDWP_VM_AllThreads        :: 4

JDWP_RT_MethodsWithGeneric :: 15
JDWP_RT_Fields             :: 4
JDWP_RT_SourceFile         :: 7

JDWP_M_LineTable          :: 1
JDWP_M_VariableTable      :: 2

JDWP_TR_Frames            :: 6
JDWP_TR_Name              :: 1

JDWP_ER_Set               :: 1
JDWP_ER_Clear             :: 2

JDWP_SF_GetValues         :: 1

JDWP_SR_Value             :: 1

JDWP_OR_ReferenceType     :: 1
JDWP_OR_GetValues         :: 2
JDWP_OR_InvokeMethod      :: 6
JDWP_INVOKE_SINGLE_THREADED :: 1

JDWP_AR_Length            :: 1
JDWP_AR_GetValues         :: 2

JDWP_CS_ClassType    :: 3
JDWP_CT_Superclass   :: 1

JDWP_EV_Composite         :: 100

// Event kinds
JDWP_EK_SINGLE_STEP   :: 1
JDWP_EK_BREAKPOINT    :: 2
JDWP_EK_CLASS_PREPARE :: 8
JDWP_EK_THREAD_START  :: 6
JDWP_EK_THREAD_DEATH  :: 7
JDWP_EK_VM_START      :: 90
JDWP_EK_VM_DEATH      :: 99

// Suspend policy
JDWP_SP_NONE  :: 0
JDWP_SP_ALL   :: 2

// Modifier kinds
JDWP_MOD_Count        :: 1
JDWP_MOD_ClassMatch   :: 5
JDWP_MOD_LocationOnly :: 7
JDWP_MOD_Step         :: 10

// Step size / depth
JDWP_STEP_LINE :: 1
JDWP_STEP_INTO :: 0
JDWP_STEP_OVER :: 1
JDWP_STEP_OUT  :: 2

JDWP_TYPETAG_CLASS :: 1
JDWP_TYPETAG_ARRAY :: 3

// ---------------------------------------------------------------------------
// ID sizes (negotiated once via VirtualMachine.IDSizes)
// ---------------------------------------------------------------------------

Id_Sizes :: struct {
	field:         int,
	method:        int,
	object:        int,
	reference_type: int,
	frame:         int,
}

id_sizes_default :: proc() -> Id_Sizes {
	return Id_Sizes{field = 8, method = 8, object = 8, reference_type = 8, frame = 8}
}

// ---------------------------------------------------------------------------
// Packet id counter (separate namespace from DAP's seq)
// ---------------------------------------------------------------------------

@(private="file")
_jdwp_id_mu:   sync.Mutex
@(private="file")
_jdwp_id_next: int = 1

jdwp_next_id :: proc() -> int {
	sync.mutex_lock(&_jdwp_id_mu)
	defer sync.mutex_unlock(&_jdwp_id_mu)
	id := _jdwp_id_next
	_jdwp_id_next += 1
	return id
}

// ---------------------------------------------------------------------------
// Low-level byte packing
// ---------------------------------------------------------------------------

_w_u8  :: proc(b: ^[dynamic]u8, v: u8)  { append(b, v) }
_w_u16 :: proc(b: ^[dynamic]u8, v: u16) { append(b, u8(v>>8), u8(v)) }
_w_u32 :: proc(b: ^[dynamic]u8, v: u32) { append(b, u8(v>>24), u8(v>>16), u8(v>>8), u8(v)) }
_w_u64 :: proc(b: ^[dynamic]u8, v: u64) {
	for i := 7; i >= 0; i -= 1 { append(b, u8(v >> uint(i*8))) }
}
_w_id :: proc(b: ^[dynamic]u8, v: u64, size: int) {
	for i := size-1; i >= 0; i -= 1 { append(b, u8(v >> uint(i*8))) }
}
_w_str :: proc(b: ^[dynamic]u8, s: string) {
	_w_u32(b, u32(len(s)))
	for c in transmute([]u8)s { append(b, c) }
}

_r_u8  :: proc(d: []u8, off: int) -> (u8, int)  { return d[off], off+1 }
_r_u16 :: proc(d: []u8, off: int) -> (u16, int) {
	v := u16(d[off])<<8 | u16(d[off+1])
	return v, off+2
}
_r_u32 :: proc(d: []u8, off: int) -> (u32, int) {
	v := u32(d[off])<<24 | u32(d[off+1])<<16 | u32(d[off+2])<<8 | u32(d[off+3])
	return v, off+4
}
_r_u64 :: proc(d: []u8, off: int) -> (u64, int) {
	v: u64
	for i := 0; i < 8; i += 1 { v = v<<8 | u64(d[off+i]) }
	return v, off+8
}
_r_id :: proc(d: []u8, off: int, size: int) -> (u64, int) {
	v: u64
	for i := 0; i < size; i += 1 { v = v<<8 | u64(d[off+i]) }
	return v, off+size
}
_r_str :: proc(d: []u8, off_: int) -> (string, int) {
	off := off_
	n: u32
	n, off = _r_u32(d, off)
	s := strings.clone(string(d[off:off+int(n)]))
	return s, off + int(n)
}

// ---------------------------------------------------------------------------
// Packet header
// ---------------------------------------------------------------------------

JDWP_Header :: struct {
	length:     int,
	id:         int,
	is_reply:   bool,
	cmd_set:    u8,
	cmd:        u8,
	error_code: int,
}

// Total frame length if a full frame is present in `data`, else -1.
jdwp_frame_len :: proc(data: []u8) -> int {
	if len(data) < 4 { return -1 }
	n, _ := _r_u32(data, 0)
	if int(n) < 11 { return -1 } // malformed, but avoid spinning forever
	return int(n)
}

jdwp_parse_header :: proc(body: []u8) -> JDWP_Header {
	h: JDWP_Header
	ln, off := _r_u32(body, 0)
	h.length = int(ln)
	id32: u32
	id32, off = _r_u32(body, off)
	h.id = int(id32)
	flags: u8
	flags, off = _r_u8(body, off)
	h.is_reply = flags & 0x80 != 0
	if h.is_reply {
		ec: u16
		ec, off = _r_u16(body, off)
		h.error_code = int(ec)
	} else {
		h.cmd_set, off = _r_u8(body, off)
		h.cmd, off     = _r_u8(body, off)
	}
	return h
}

// Data payload starts right after the 11-byte common header in both
// command and reply packets (cmdSet+cmd and errorCode are both 2 bytes).
jdwp_data :: proc(body: []u8) -> []u8 {
	if len(body) <= 11 { return body[len(body):] }
	return body[11:]
}

// ---------------------------------------------------------------------------
// Packet builders — command packets (flags = 0)
// ---------------------------------------------------------------------------

_build :: proc(cmd_set, cmd: u8, data: []u8) -> (msg: []u8, id: int) {
	id = jdwp_next_id()
	length := 11 + len(data)
	b: [dynamic]u8
	b = make([dynamic]u8, 0, length)
	_w_u32(&b, u32(length))
	_w_u32(&b, u32(id))
	_w_u8(&b, 0)
	_w_u8(&b, cmd_set)
	_w_u8(&b, cmd)
	for c in data { append(&b, c) }
	return b[:], id
}

build_handshake :: proc() -> []u8 {
	return transmute([]u8)strings.clone(JDWP_HANDSHAKE)
}

build_id_sizes :: proc() -> (msg: []u8, id: int) {
	return _build(JDWP_CS_VirtualMachine, JDWP_VM_IDSizes, nil)
}

build_all_classes_with_generic :: proc() -> (msg: []u8, id: int) {
	return _build(JDWP_CS_VirtualMachine, JDWP_VM_AllClassesWithGeneric, nil)
}

build_all_threads :: proc() -> (msg: []u8, id: int) {
	return _build(JDWP_CS_VirtualMachine, JDWP_VM_AllThreads, nil)
}

build_vm_resume :: proc() -> (msg: []u8, id: int) {
	return _build(JDWP_CS_VirtualMachine, JDWP_VM_Resume, nil)
}

build_vm_suspend :: proc() -> (msg: []u8, id: int) {
	return _build(JDWP_CS_VirtualMachine, JDWP_VM_Suspend, nil)
}

// Detach cleanly without killing the target — the right default for an
// attach session (unlike VirtualMachine.Exit, which terminates the JVM).
build_vm_dispose :: proc() -> (msg: []u8, id: int) {
	return _build(JDWP_CS_VirtualMachine, JDWP_VM_Dispose, nil)
}

build_class_prepare_request :: proc() -> (msg: []u8, id: int) {
	d: [dynamic]u8
	d = make([dynamic]u8, 0, 16, context.temp_allocator)
	_w_u8(&d, JDWP_EK_CLASS_PREPARE)
	_w_u8(&d, JDWP_SP_NONE)
	_w_u32(&d, 1) // modifier count
	_w_u8(&d, JDWP_MOD_ClassMatch)
	_w_str(&d, "*")
	return _build(JDWP_CS_EventRequest, JDWP_ER_Set, d[:])
}

build_methods_with_generic :: proc(ref_type: u64, sizes: Id_Sizes) -> (msg: []u8, id: int) {
	d: [dynamic]u8
	d = make([dynamic]u8, 0, 8, context.temp_allocator)
	_w_id(&d, ref_type, sizes.reference_type)
	return _build(JDWP_CS_ReferenceType, JDWP_RT_MethodsWithGeneric, d[:])
}

// ReferenceType.SourceFile — the plain filename a class was compiled from
// ("OrderService.java"), no directory. Used to let the call-stack panel
// jump to a frame's source; matching that name against the workspace is
// the caller's job (JDWP has no notion of project layout).
build_source_file :: proc(ref_type: u64, sizes: Id_Sizes) -> (msg: []u8, id: int) {
	d: [dynamic]u8
	d = make([dynamic]u8, 0, 8, context.temp_allocator)
	_w_id(&d, ref_type, sizes.reference_type)
	return _build(JDWP_CS_ReferenceType, JDWP_RT_SourceFile, d[:])
}

decode_source_file :: proc(data: []u8) -> string {
	s, _ := _r_str(data, 0)
	return s
}

build_line_table :: proc(ref_type, method: u64, sizes: Id_Sizes) -> (msg: []u8, id: int) {
	d: [dynamic]u8
	d = make([dynamic]u8, 0, 16, context.temp_allocator)
	_w_id(&d, ref_type, sizes.reference_type)
	_w_id(&d, method, sizes.method)
	return _build(JDWP_CS_Method, JDWP_M_LineTable, d[:])
}

build_variable_table :: proc(ref_type, method: u64, sizes: Id_Sizes) -> (msg: []u8, id: int) {
	d: [dynamic]u8
	d = make([dynamic]u8, 0, 16, context.temp_allocator)
	_w_id(&d, ref_type, sizes.reference_type)
	_w_id(&d, method, sizes.method)
	return _build(JDWP_CS_Method, JDWP_M_VariableTable, d[:])
}

build_set_breakpoint :: proc(ref_type, method, code_index: u64, sizes: Id_Sizes) -> (msg: []u8, id: int) {
	d: [dynamic]u8
	d = make([dynamic]u8, 0, 32, context.temp_allocator)
	_w_u8(&d, JDWP_EK_BREAKPOINT)
	_w_u8(&d, JDWP_SP_ALL)
	_w_u32(&d, 1) // modifier count
	_w_u8(&d, JDWP_MOD_LocationOnly)
	_w_u8(&d, JDWP_TYPETAG_CLASS)
	_w_id(&d, ref_type, sizes.reference_type)
	_w_id(&d, method, sizes.method)
	_w_u64(&d, code_index)
	return _build(JDWP_CS_EventRequest, JDWP_ER_Set, d[:])
}

build_step :: proc(thread: u64, depth: int, sizes: Id_Sizes) -> (msg: []u8, id: int) {
	d: [dynamic]u8
	d = make([dynamic]u8, 0, 32, context.temp_allocator)
	_w_u8(&d, JDWP_EK_SINGLE_STEP)
	_w_u8(&d, JDWP_SP_ALL)
	_w_u32(&d, 2) // modifier count
	_w_u8(&d, JDWP_MOD_Step)
	_w_id(&d, thread, sizes.object)
	_w_u32(&d, JDWP_STEP_LINE)
	_w_u32(&d, u32(depth))
	_w_u8(&d, JDWP_MOD_Count)
	_w_u32(&d, 1)
	return _build(JDWP_CS_EventRequest, JDWP_ER_Set, d[:])
}

build_clear_event :: proc(event_kind: u8, request_id: int) -> (msg: []u8, id: int) {
	d: [dynamic]u8
	d = make([dynamic]u8, 0, 8, context.temp_allocator)
	_w_u8(&d, event_kind)
	_w_u32(&d, u32(request_id))
	return _build(JDWP_CS_EventRequest, JDWP_ER_Clear, d[:])
}

build_thread_frames :: proc(thread: u64, start, length: int, sizes: Id_Sizes) -> (msg: []u8, id: int) {
	d: [dynamic]u8
	d = make([dynamic]u8, 0, 24, context.temp_allocator)
	_w_id(&d, thread, sizes.object)
	_w_u32(&d, u32(start))
	_w_u32(&d, u32(length))
	return _build(JDWP_CS_ThreadReference, JDWP_TR_Frames, d[:])
}

build_thread_name :: proc(thread: u64, sizes: Id_Sizes) -> (msg: []u8, id: int) {
	d: [dynamic]u8
	d = make([dynamic]u8, 0, 8, context.temp_allocator)
	_w_id(&d, thread, sizes.object)
	return _build(JDWP_CS_ThreadReference, JDWP_TR_Name, d[:])
}

Slot_Req :: struct { slot: int, tag: u8 }

build_stack_get_values :: proc(thread, frame: u64, slots: []Slot_Req, sizes: Id_Sizes) -> (msg: []u8, id: int) {
	d: [dynamic]u8
	d = make([dynamic]u8, 0, 32, context.temp_allocator)
	_w_id(&d, thread, sizes.object)
	_w_id(&d, frame, sizes.frame)
	_w_u32(&d, u32(len(slots)))
	for s in slots {
		_w_u32(&d, u32(s.slot))
		_w_u8(&d, s.tag)
	}
	return _build(JDWP_CS_StackFrame, JDWP_SF_GetValues, d[:])
}

build_string_value :: proc(object_id: u64, sizes: Id_Sizes) -> (msg: []u8, id: int) {
	d: [dynamic]u8
	d = make([dynamic]u8, 0, 8, context.temp_allocator)
	_w_id(&d, object_id, sizes.object)
	return _build(JDWP_CS_StringReference, JDWP_SR_Value, d[:])
}

// Methods aren't re-listed on subclasses — toString()/equals()/etc. are
// usually declared higher up (e.g. AbstractMap for HashMap), so resolving a
// method by name means walking up via ClassType.Superclass until found or
// the chain ends at Object (superclass 0).
build_superclass :: proc(class_id: u64, sizes: Id_Sizes) -> (msg: []u8, id: int) {
	d: [dynamic]u8
	d = make([dynamic]u8, 0, 8, context.temp_allocator)
	_w_id(&d, class_id, sizes.reference_type)
	return _build(JDWP_CS_ClassType, JDWP_CT_Superclass, d[:])
}

decode_superclass :: proc(data: []u8, sizes: Id_Sizes) -> u64 {
	v, _ := _r_id(data, 0, sizes.reference_type)
	return v
}

build_object_reference_type :: proc(object_id: u64, sizes: Id_Sizes) -> (msg: []u8, id: int) {
	d: [dynamic]u8
	d = make([dynamic]u8, 0, 8, context.temp_allocator)
	_w_id(&d, object_id, sizes.object)
	return _build(JDWP_CS_ObjectReference, JDWP_OR_ReferenceType, d[:])
}

// ReferenceType.Fields — instance + static fields declared directly on this
// class (not inherited ones; JDWP never re-lists a superclass's fields on a
// subclass). Good enough for the common POJO/DTO case; fields declared only
// on a base class won't show up in the expanded tree.
build_fields :: proc(ref_type: u64, sizes: Id_Sizes) -> (msg: []u8, id: int) {
	d: [dynamic]u8
	d = make([dynamic]u8, 0, 8, context.temp_allocator)
	_w_id(&d, ref_type, sizes.reference_type)
	return _build(JDWP_CS_ReferenceType, JDWP_RT_Fields, d[:])
}

Field_Entry :: struct {
	field_id:  u64,
	name:      string, // heap
	signature: string, // heap
	mod_bits:  int,
}

decode_fields :: proc(data: []u8, sizes: Id_Sizes) -> []Field_Entry {
	off := 0
	n: u32
	n, off = _r_u32(data, off)
	out := make([]Field_Entry, int(n))
	for i in 0..<int(n) {
		e: Field_Entry
		e.field_id, off  = _r_id(data, off, sizes.field)
		e.name, off      = _r_str(data, off)
		e.signature, off = _r_str(data, off)
		mb: u32
		mb, off = _r_u32(data, off)
		e.mod_bits = int(mb)
		out[i] = e
	}
	return out
}

build_object_get_values :: proc(object_id: u64, field_ids: []u64, sizes: Id_Sizes) -> (msg: []u8, id: int) {
	d: [dynamic]u8
	d = make([dynamic]u8, 0, 16+8*len(field_ids), context.temp_allocator)
	_w_id(&d, object_id, sizes.object)
	_w_u32(&d, u32(len(field_ids)))
	for f in field_ids { _w_id(&d, f, sizes.field) }
	return _build(JDWP_CS_ObjectReference, JDWP_OR_GetValues, d[:])
}

build_array_length :: proc(array_id: u64, sizes: Id_Sizes) -> (msg: []u8, id: int) {
	d: [dynamic]u8
	d = make([dynamic]u8, 0, 8, context.temp_allocator)
	_w_id(&d, array_id, sizes.object)
	return _build(JDWP_CS_ArrayReference, JDWP_AR_Length, d[:])
}

decode_array_length :: proc(data: []u8) -> int {
	v, _ := _r_u32(data, 0)
	return int(v)
}

build_array_get_values :: proc(array_id: u64, first, length: int, sizes: Id_Sizes) -> (msg: []u8, id: int) {
	d: [dynamic]u8
	d = make([dynamic]u8, 0, 16, context.temp_allocator)
	_w_id(&d, array_id, sizes.object)
	_w_u32(&d, u32(first))
	_w_u32(&d, u32(length))
	return _build(JDWP_CS_ArrayReference, JDWP_AR_GetValues, d[:])
}

// ArrayReference.GetValues reply is an ArrayRegion: a type tag followed by
// either packed untagged primitives (if the array's component type is
// primitive) or individually tagged values (if it's an object array).
decode_array_values :: proc(data: []u8, sizes: Id_Sizes) -> (type_tag: u8, values: []JDWP_Value) {
	off := 0
	type_tag, off = _r_u8(data, off)
	n: u32
	n, off = _r_u32(data, off)
	out := make([]JDWP_Value, int(n))
	switch type_tag {
	case 'Z', 'B':
		for i in 0..<int(n) { b: u8; b, off = _r_u8(data, off); out[i] = JDWP_Value{tag = type_tag, i_val = i64(b)} }
	case 'C', 'S':
		for i in 0..<int(n) { s: u16; s, off = _r_u16(data, off); out[i] = JDWP_Value{tag = type_tag, i_val = i64(s)} }
	case 'F', 'I':
		for i in 0..<int(n) { u: u32; u, off = _r_u32(data, off); out[i] = JDWP_Value{tag = type_tag, i_val = i64(u)} }
	case 'D', 'J':
		for i in 0..<int(n) { u: u64; u, off = _r_u64(data, off); out[i] = JDWP_Value{tag = type_tag, i_val = i64(u)} }
	case:
		for i in 0..<int(n) { out[i], off = decode_value(data, off, sizes) }
	}
	return type_tag, out
}

// Zero-arg method calls only (e.g. toString()) — good enough for a debugger
// evaluate box; general argument marshalling is out of scope.
build_invoke_method :: proc(object_id, thread_id, class_id, method_id: u64, sizes: Id_Sizes) -> (msg: []u8, id: int) {
	d: [dynamic]u8
	d = make([dynamic]u8, 0, 40, context.temp_allocator)
	_w_id(&d, object_id, sizes.object)
	_w_id(&d, thread_id, sizes.object)
	_w_id(&d, class_id, sizes.reference_type)
	_w_id(&d, method_id, sizes.method)
	_w_u32(&d, 0) // argument count
	_w_u32(&d, JDWP_INVOKE_SINGLE_THREADED) // don't resume other threads for this call
	return _build(JDWP_CS_ObjectReference, JDWP_OR_InvokeMethod, d[:])
}

// ---------------------------------------------------------------------------
// Reply / event decoders
// ---------------------------------------------------------------------------

decode_id_sizes :: proc(data: []u8) -> Id_Sizes {
	s: Id_Sizes
	off := 0
	v: u32
	v, off = _r_u32(data, off); s.field = int(v)
	v, off = _r_u32(data, off); s.method = int(v)
	v, off = _r_u32(data, off); s.object = int(v)
	v, off = _r_u32(data, off); s.reference_type = int(v)
	v, off = _r_u32(data, off); s.frame = int(v)
	return s
}

Class_Entry :: struct {
	ref_type_tag: u8,
	ref_type:     u64,
	signature:    string, // heap
	status:       int,
}

decode_all_classes_with_generic :: proc(data: []u8, sizes: Id_Sizes) -> []Class_Entry {
	off := 0
	n: u32
	n, off = _r_u32(data, off)
	out := make([]Class_Entry, int(n))
	for i in 0..<int(n) {
		e: Class_Entry
		e.ref_type_tag, off = _r_u8(data, off)
		e.ref_type, off     = _r_id(data, off, sizes.reference_type)
		e.signature, off    = _r_str(data, off)
		_, off               = _r_str(data, off) // generic signature, unused
		st: u32
		st, off = _r_u32(data, off)
		e.status = int(st)
		out[i] = e
	}
	return out
}

Method_Entry :: struct {
	method_id: u64,
	name:      string, // heap
	signature: string, // heap
}

decode_methods_with_generic :: proc(data: []u8, sizes: Id_Sizes) -> []Method_Entry {
	off := 0
	n: u32
	n, off = _r_u32(data, off)
	out := make([]Method_Entry, int(n))
	for i in 0..<int(n) {
		e: Method_Entry
		e.method_id, off = _r_id(data, off, sizes.method)
		e.name, off      = _r_str(data, off)
		e.signature, off = _r_str(data, off)
		_, off            = _r_str(data, off) // generic signature
		_, off            = _r_u32(data, off) // mod bits
		out[i] = e
	}
	return out
}

Line_Entry :: struct { code_index: u64, line: int }

decode_line_table :: proc(data: []u8) -> (start, end: u64, lines: []Line_Entry) {
	off := 0
	start, off = _r_u64(data, off)
	end, off   = _r_u64(data, off)
	n: u32
	n, off = _r_u32(data, off)
	lines = make([]Line_Entry, int(n))
	for i in 0..<int(n) {
		ci, o1 := _r_u64(data, off)
		ln, o2 := _r_u32(data, o1)
		lines[i] = Line_Entry{code_index = ci, line = int(ln)}
		off = o2
	}
	return
}

Var_Entry :: struct {
	code_index: u64,
	name:       string, // heap
	signature:  string, // heap
	length:     int,
	slot:       int,
}

decode_variable_table :: proc(data: []u8) -> (arg_cnt: int, vars: []Var_Entry) {
	off := 0
	ac: u32
	ac, off = _r_u32(data, off)
	arg_cnt = int(ac)
	n: u32
	n, off = _r_u32(data, off)
	vars = make([]Var_Entry, int(n))
	for i in 0..<int(n) {
		v: Var_Entry
		v.code_index, off = _r_u64(data, off)
		v.name, off       = _r_str(data, off)
		v.signature, off  = _r_str(data, off)
		ln: u32
		ln, off = _r_u32(data, off)
		v.length = int(ln)
		sl: u32
		sl, off = _r_u32(data, off)
		v.slot = int(sl)
		vars[i] = v
	}
	return
}

decode_set_event_reply :: proc(data: []u8) -> int {
	v, _ := _r_u32(data, 0)
	return int(v)
}

decode_all_threads :: proc(data: []u8, sizes: Id_Sizes) -> []u64 {
	off := 0
	n: u32
	n, off = _r_u32(data, off)
	out := make([]u64, int(n))
	for i in 0..<int(n) {
		out[i], off = _r_id(data, off, sizes.object)
	}
	return out
}

Frame_Entry :: struct {
	frame_id:   u64,
	type_tag:   u8,
	ref_type:   u64,
	method_id:  u64,
	code_index: u64,
}

decode_thread_frames :: proc(data: []u8, sizes: Id_Sizes) -> []Frame_Entry {
	off := 0
	n: u32
	n, off = _r_u32(data, off)
	out := make([]Frame_Entry, int(n))
	for i in 0..<int(n) {
		f: Frame_Entry
		f.frame_id, off  = _r_id(data, off, sizes.frame)
		f.type_tag, off  = _r_u8(data, off)
		f.ref_type, off  = _r_id(data, off, sizes.reference_type)
		f.method_id, off = _r_id(data, off, sizes.method)
		f.code_index, off = _r_u64(data, off)
		out[i] = f
	}
	return out
}

decode_thread_name :: proc(data: []u8) -> string {
	s, _ := _r_str(data, 0)
	return s
}

// A decoded JDWP value (tagged union flattened into one struct).
JDWP_Value :: struct {
	tag:      u8,
	i_val:    i64, // holds bool/byte/char/short/int/long/float-bits/double-bits
	obj_id:   u64, // holds object/string/thread/etc reference
}

decode_value :: proc(data: []u8, off_: int, sizes: Id_Sizes) -> (JDWP_Value, int) {
	off := off_
	v: JDWP_Value
	v.tag, off = _r_u8(data, off)
	switch v.tag {
	case 'Z', 'B':
		b: u8
		b, off = _r_u8(data, off)
		v.i_val = i64(b)
	case 'C', 'S':
		s: u16
		s, off = _r_u16(data, off)
		v.i_val = i64(s)
	case 'F', 'I':
		u: u32
		u, off = _r_u32(data, off)
		v.i_val = i64(u)
	case 'D', 'J':
		u: u64
		u, off = _r_u64(data, off)
		v.i_val = i64(u)
	case 'V':
		// no data
	case:
		// object-like: L [ s t g l c
		v.obj_id, off = _r_id(data, off, sizes.object)
	}
	return v, off
}

decode_stack_get_values :: proc(data: []u8, sizes: Id_Sizes) -> []JDWP_Value {
	off := 0
	n: u32
	n, off = _r_u32(data, off)
	out := make([]JDWP_Value, int(n))
	for i in 0..<int(n) {
		out[i], off = decode_value(data, off, sizes)
	}
	return out
}

decode_string_value :: proc(data: []u8) -> string {
	s, _ := _r_str(data, 0)
	return s
}

decode_object_reference_type :: proc(data: []u8, sizes: Id_Sizes) -> (tag: u8, ref_type: u64) {
	off := 0
	tag, off = _r_u8(data, off)
	ref_type, off = _r_id(data, off, sizes.reference_type)
	return
}

// InvokeMethod reply: returnValue (tagged value) + exception (tagged objectID).
decode_invoke_reply :: proc(data: []u8, sizes: Id_Sizes) -> (result: JDWP_Value, exception_id: u64) {
	off: int
	result, off = decode_value(data, 0, sizes)
	_, off = _r_u8(data, off) // exception object tag, always 'L'
	exception_id, off = _r_id(data, off, sizes.object)
	return
}

// ---------------------------------------------------------------------------
// Composite event
// ---------------------------------------------------------------------------

JDWP_Event :: struct {
	kind:       u8,
	request_id: int,
	thread_id:  u64,
	ref_type:   u64,   // ClassPrepare
	signature:  string, // heap, ClassPrepare
	method_id:  u64,   // Breakpoint/Step location
	code_index: u64,   // Breakpoint/Step location
}

// Returns ok=false if an unrecognized event kind was hit mid-stream (offset
// can no longer be trusted, so remaining events in this composite are lost).
decode_composite_event :: proc(data: []u8, sizes: Id_Sizes) -> (suspend_policy: u8, events: []JDWP_Event, ok: bool) {
	off := 0
	suspend_policy, off = _r_u8(data, off)
	n: u32
	n, off = _r_u32(data, off)
	out := make([dynamic]JDWP_Event, 0, int(n))
	for i in 0..<int(n) {
		ev: JDWP_Event
		ev.kind, off = _r_u8(data, off)
		switch ev.kind {
		case JDWP_EK_BREAKPOINT, JDWP_EK_SINGLE_STEP:
			rid: u32
			rid, off = _r_u32(data, off)
			ev.request_id = int(rid)
			ev.thread_id, off = _r_id(data, off, sizes.object)
			_, off = _r_u8(data, off) // location type tag
			ev.ref_type, off = _r_id(data, off, sizes.reference_type)
			ev.method_id, off = _r_id(data, off, sizes.method)
			ev.code_index, off = _r_u64(data, off)
		case JDWP_EK_CLASS_PREPARE:
			rid: u32
			rid, off = _r_u32(data, off)
			ev.request_id = int(rid)
			ev.thread_id, off = _r_id(data, off, sizes.object)
			_, off = _r_u8(data, off) // ref type tag
			ev.ref_type, off = _r_id(data, off, sizes.reference_type)
			ev.signature, off = _r_str(data, off)
			_, off = _r_u32(data, off) // status
		case JDWP_EK_THREAD_START, JDWP_EK_THREAD_DEATH:
			rid: u32
			rid, off = _r_u32(data, off)
			ev.request_id = int(rid)
			ev.thread_id, off = _r_id(data, off, sizes.object)
		case JDWP_EK_VM_START:
			rid: u32
			rid, off = _r_u32(data, off)
			ev.request_id = int(rid)
			ev.thread_id, off = _r_id(data, off, sizes.object)
		case JDWP_EK_VM_DEATH:
			rid: u32
			rid, off = _r_u32(data, off)
			ev.request_id = int(rid)
		case:
			append(&out, ev)
			return suspend_policy, out[:], false
		}
		append(&out, ev)
	}
	return suspend_policy, out[:], true
}
