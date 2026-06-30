// Package lsp_conn — generic JSON-RPC 2.0 connection.
//
// Responsibilities:
//   - Owns a Transport and two background threads (reader, writer)
//   - Frames outbound messages (Content-Length) and enqueues them
//   - Accumulates inbound bytes into a ring buffer, parses frames
//   - Routes incoming messages to registered handlers
//   - Tracks pending outbound requests (id → callback + cancel flag)
//   - Exposes send_request / send_notification / cancel_request
//   - Exposes register_handler / register_notif_handler for inbound
//
// Thread model:
//   • Reader thread: calls transport.read() in a tight loop, accumulates
//     bytes, parses frames, pushes complete Inbox_Items to inbox queue.
//   • Writer thread: sleeps on a cond var, wakes when outbox has items,
//     calls transport.write() for each framed message.
//   • Main thread: calls conn_drain() each frame — locks inbox briefly,
//     steals all items, unlocks, then dispatches callbacks without holding
//     any lock.  This means feature callbacks run on the main thread and
//     can safely touch editor state.
//
// No callback ever runs with a lock held, preventing deadlocks.
package lsp_conn

import proto "../protocol"
import trans "../transport"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"

// ---------------------------------------------------------------------------
// Inbox / Outbox queues
// ---------------------------------------------------------------------------

Inbox_Item :: struct {
	body: []u8, // heap-owned; consumer deletes
}

Write_Item :: struct {
	data: []u8, // heap-owned; write thread deletes
}

// ---------------------------------------------------------------------------
// Handler types
// ---------------------------------------------------------------------------

// Request_Handler: called when the SERVER sends a request to the CLIENT.
// Must return a JSON result string (temp or heap OK — we clone it).
// Return ("", false) to send a method-not-found error.
Request_Handler :: proc(id: int, params_body: []u8) -> (result: string, ok: bool)

// Notification_Handler: called for server→client notifications.
Notification_Handler :: proc(params_body: []u8)

// ---------------------------------------------------------------------------
// Connection
// ---------------------------------------------------------------------------

Conn :: struct {
	transport:     ^trans.Transport,

	// Pending outbound requests — id → entry
	pending_mu:    sync.Mutex,
	pending:       map[int]proto.Pending_Request,

	// Inbound message queue (reader → main thread)
	inbox_mu:      sync.Mutex,
	inbox:         [dynamic]Inbox_Item,

	// Outbound message queue (main/feat threads → writer)
	outbox_mu:     sync.Mutex,
	outbox_cond:   sync.Cond,
	outbox:        [dynamic]Write_Item,
	outbox_done:   bool,

	// Handler registrations
	handler_mu:    sync.Mutex,
	req_handlers:  map[string]Request_Handler,
	notif_handlers: map[string]Notification_Handler,

	// Background threads
	reader:        ^thread.Thread,
	writer:        ^thread.Thread,
	reader_data:   ^_Reader_Data,
	writer_data:   ^_Writer_Data,

	running:       bool,
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

conn_create :: proc(transport: ^trans.Transport) -> ^Conn {
	c := new(Conn)
	c.transport     = transport
	c.pending       = make(map[int]proto.Pending_Request)
	c.inbox         = make([dynamic]Inbox_Item)
	c.outbox        = make([dynamic]Write_Item)
	c.req_handlers  = make(map[string]Request_Handler)
	c.notif_handlers = make(map[string]Notification_Handler)
	return c
}

// conn_start spawns reader and writer background threads.
// Must be called before any send_ calls.
conn_start :: proc(c: ^Conn) {
	rd := new(_Reader_Data); rd.conn = c
	c.reader_data = rd
	c.reader = thread.create(_reader_proc)
	c.reader.data = rd
	thread.start(c.reader)

	wd := new(_Writer_Data); wd.conn = c
	c.writer_data = wd
	c.writer = thread.create(_writer_proc)
	c.writer.data = wd
	thread.start(c.writer)

	c.running = true
}

// conn_stop signals writer to finish, closes transport, joins threads.
conn_stop :: proc(c: ^Conn) {
	if !c.running { return }
	c.running = false

	// Signal writer to exit
	sync.mutex_lock(&c.outbox_mu)
	c.outbox_done = true
	sync.mutex_unlock(&c.outbox_mu)
	sync.cond_signal(&c.outbox_cond)

	// Unblock reader by closing transport
	trans.transport_close(c.transport)

	thread.join(c.reader)
	thread.join(c.writer)
	thread.destroy(c.reader)
	thread.destroy(c.writer)
	free(c.reader_data)
	free(c.writer_data)

	trans.transport_destroy(c.transport)
}

conn_destroy :: proc(c: ^Conn) {
	conn_stop(c)

	// Cancel all pending requests
	sync.mutex_lock(&c.pending_mu)
	for _, &p in c.pending {
		if p.callback.proc_ != nil { p.callback.proc_(nil, nil, p.callback.user) }
		delete(p.method)
	}
	delete(c.pending)
	sync.mutex_unlock(&c.pending_mu)

	for item in c.inbox { delete(item.body) }
	delete(c.inbox)
	for item in c.outbox { delete(item.data) }
	delete(c.outbox)
	delete(c.req_handlers)
	delete(c.notif_handlers)
	free(c)
}

// ---------------------------------------------------------------------------
// Handler registration
// ---------------------------------------------------------------------------

// register_req_handler registers a handler for a server→client request method.
register_req_handler :: proc(c: ^Conn, method: string, h: Request_Handler) {
	sync.mutex_lock(&c.handler_mu)
	c.req_handlers[method] = h
	sync.mutex_unlock(&c.handler_mu)
}

// register_notif_handler registers a handler for a server→client notification.
register_notif_handler :: proc(c: ^Conn, method: string, h: Notification_Handler) {
	sync.mutex_lock(&c.handler_mu)
	c.notif_handlers[method] = h
	sync.mutex_unlock(&c.handler_mu)
}

// ---------------------------------------------------------------------------
// Outbound API — called from main thread (or feature threads)
// ---------------------------------------------------------------------------

// send_request enqueues an outbound JSON-RPC request.
// Returns the request id (for cancellation).
// params must be a valid JSON value string (or "").
send_request :: proc(c: ^Conn, method, params: string, cb: proto.Response_Callback) -> int {
	if !c.running { return -1 }
	id := proto.next_id()
	body := proto.build_request(id, method, params)
	framed := proto.frame_message(body) // heap

	sync.mutex_lock(&c.pending_mu)
	c.pending[id] = proto.Pending_Request{
		method   = strings.clone(method),
		callback = cb,
	}
	sync.mutex_unlock(&c.pending_mu)

	_enqueue_write(c, framed)
	return id
}

// send_notification enqueues an outbound JSON-RPC notification (no response).
send_notification :: proc(c: ^Conn, method, params: string) {
	if !c.running { return }
	body   := proto.build_notification(method, params)
	framed := proto.frame_message(body)
	_enqueue_write(c, framed)
}

// cancel_request marks the pending request as cancelled and sends
// the standard $/cancelRequest notification.
cancel_request :: proc(c: ^Conn, id: int) {
	if id < 0 { return }
	sync.mutex_lock(&c.pending_mu)
	if p, ok := &c.pending[id]; ok { p.canceled = true }
	sync.mutex_unlock(&c.pending_mu)
	params := fmt.tprintf(`{"id":%d}`, id)
	send_notification(c, "$/cancelRequest", params)
}

// ---------------------------------------------------------------------------
// Main-thread drain — call each frame
// ---------------------------------------------------------------------------

// conn_drain steals all pending inbox items and dispatches them.
// No lock is held during dispatch — callbacks can safely touch editor state.
conn_drain :: proc(c: ^Conn) {
	// Steal inbox
	sync.mutex_lock(&c.inbox_mu)
	if len(c.inbox) == 0 { sync.mutex_unlock(&c.inbox_mu); return }
	items := make([dynamic]Inbox_Item, context.temp_allocator)
	for item in c.inbox { append(&items, item) }
	clear(&c.inbox)
	sync.mutex_unlock(&c.inbox_mu)

	// Dispatch each message
	for &item in items {
		_dispatch(c, item.body)
		delete(item.body)
	}
}

// ---------------------------------------------------------------------------
// Dispatch (runs on main thread, no locks held)
// ---------------------------------------------------------------------------

_dispatch :: proc(c: ^Conn, body: []u8) {
	msg, ok := proto.route_message(body)
	if !ok { return } // malformed — drop

	switch msg.kind {
	case .Response:     _dispatch_response(c, msg.id, body)
	case .Request:      _dispatch_server_request(c, msg.id, msg.method, body)
	case .Notification: _dispatch_notification(c, msg.method, body)
	}
}

_dispatch_response :: proc(c: ^Conn, id: int, body: []u8) {
	if id < 0 { return }

	sync.mutex_lock(&c.pending_mu)
	p, found := c.pending[id]
	if !found { sync.mutex_unlock(&c.pending_mu); return }
	delete_key(&c.pending, id)
	sync.mutex_unlock(&c.pending_mu)

	defer delete(p.method)
	if p.canceled {
		if p.callback.proc_ != nil { p.callback.proc_(nil, nil, p.callback.user) }
		return
	}

	// Parse full body on heap for callback ownership
	val, parse_ok := proto.parse_json(body)
	if !parse_ok {
		if p.callback.proc_ != nil { p.callback.proc_(nil, nil, p.callback.user) }
		return
	}

	obj, is_obj := val.(json.Object)
	if !is_obj { json.destroy_value(val); if p.callback.proc_ != nil { p.callback.proc_(nil, nil, p.callback.user) }; return }

	var result_copy, error_copy: json.Value
	if _, has := obj["result"]; has { result_copy = proto.clone_json_value(obj["result"]) }
	if _, has := obj["error"];  has { error_copy  = proto.clone_json_value(obj["error"])  }
	json.destroy_value(val)

	if p.callback.proc_ != nil { p.callback.proc_(result_copy, error_copy, p.callback.user) }
}

_dispatch_server_request :: proc(c: ^Conn, id: int, method: string, body: []u8) {
	sync.mutex_lock(&c.handler_mu)
	h, has := c.req_handlers[method]
	sync.mutex_unlock(&c.handler_mu)

	if !has {
		resp := proto.build_error_response(id, -32601, "Method not found")
		framed := proto.frame_message(resp)
		_enqueue_write(c, framed)
		return
	}
	result, ok := h(id, body)
	var resp: string
	if ok { resp = proto.build_response(id, result if result != "" else "null") } else {
		resp = proto.build_error_response(id, -32603, "Internal error")
	}
	framed := proto.frame_message(resp)
	_enqueue_write(c, framed)
}

_dispatch_notification :: proc(c: ^Conn, method: string, body: []u8) {
	sync.mutex_lock(&c.handler_mu)
	h, has := c.notif_handlers[method]
	sync.mutex_unlock(&c.handler_mu)
	if has { h(body) }
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

_enqueue_write :: proc(c: ^Conn, framed: []u8) {
	sync.mutex_lock(&c.outbox_mu)
	append(&c.outbox, Write_Item{data = framed})
	sync.mutex_unlock(&c.outbox_mu)
	sync.cond_signal(&c.outbox_cond)
}

// ---------------------------------------------------------------------------
// Reader background thread
// ---------------------------------------------------------------------------

_Reader_Data :: struct { conn: ^Conn }

_reader_proc :: proc(t: ^thread.Thread) {
	d := cast(^_Reader_Data)t.data
	c := d.conn

	buf_cap := 1 << 16 // 64 KiB
	buf     := make([]u8, buf_cap)
	defer delete(buf)
	filled := 0

	for {
		if filled == len(buf) {
			new_buf := make([]u8, len(buf) * 2)
			copy(new_buf, buf)
			delete(buf)
			buf = new_buf
		}

		n := trans.transport_read(c.transport, buf[filled:])
		if n <= 0 { break }
		filled += n

		for {
			cl, end := proto.parse_header(buf[:filled])
			if cl < 0 { break }
			total := end + cl
			if filled < total { break }

			body := make([]u8, cl)
			copy(body, buf[end:total])

			sync.mutex_lock(&c.inbox_mu)
			append(&c.inbox, Inbox_Item{body = body})
			sync.mutex_unlock(&c.inbox_mu)

			copy(buf, buf[total:filled])
			filled -= total
		}
	}
}

// ---------------------------------------------------------------------------
// Writer background thread
// ---------------------------------------------------------------------------

_Writer_Data :: struct { conn: ^Conn }

_writer_proc :: proc(t: ^thread.Thread) {
	d := cast(^_Writer_Data)t.data
	c := d.conn

	for {
		sync.mutex_lock(&c.outbox_mu)
		for len(c.outbox) == 0 && !c.outbox_done {
			sync.cond_wait(&c.outbox_cond, &c.outbox_mu)
		}
		if c.outbox_done && len(c.outbox) == 0 {
			sync.mutex_unlock(&c.outbox_mu)
			break
		}
		pending := make([dynamic]Write_Item, context.temp_allocator)
		for item in c.outbox { append(&pending, item) }
		clear(&c.outbox)
		sync.mutex_unlock(&c.outbox_mu)

		pipe_ok := true
		for item in pending {
			if pipe_ok { pipe_ok = trans.transport_write(c.transport, item.data) }
			delete(item.data)
		}
		if !pipe_ok { break }
	}
}
