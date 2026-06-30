package lsp_client

import conn "../connection"
import proto "../protocol"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"

Client_State :: enum u8 {
	Uninitialized,
	Initializing,
	Running,
	Stopping,
	Stopped,
}

LSP_Client :: struct {
	conn:           ^conn.Conn,
	state:          Client_State,
	state_mu:       sync.Mutex,
	root_uri:       string,
	server_caps:    json.Value,
	flush_pending:  bool,
	flush_tick:     time.Tick,
	flush_delay:    time.Duration,
	on_initialized: proc(lc: ^LSP_Client, user: rawptr),
	on_stopped:     proc(lc: ^LSP_Client, user: rawptr),
	user:           rawptr,
}

client_create :: proc(c: ^conn.Conn) -> ^LSP_Client {
	lc := new(LSP_Client)
	lc.conn        = c
	lc.state       = .Uninitialized
	lc.flush_delay = 200 * time.Millisecond
	conn.register_req_handler(c, "client/registerCapability",   _stub_req_handler)
	conn.register_req_handler(c, "client/unregisterCapability", _stub_req_handler)
	return lc
}

client_destroy :: proc(lc: ^LSP_Client) {
	if lc.state == .Running { client_shutdown(lc) }
	json.destroy_value(lc.server_caps)
	delete(lc.root_uri)
	free(lc)
}

client_initialize :: proc(lc: ^LSP_Client, root_uri, capabilities_json: string) {
	sync.mutex_lock(&lc.state_mu)
	if lc.state != .Uninitialized { sync.mutex_unlock(&lc.state_mu); return }
	lc.state    = .Initializing
	lc.root_uri = strings.clone(root_uri)
	sync.mutex_unlock(&lc.state_mu)

	params := fmt.tprintf(
		`{"processId":null,"rootUri":%s,"capabilities":%s,"clientInfo":{"name":"custom_editor","version":"1.0"}}`,
		proto.json_str(root_uri), capabilities_json)

	cb := proto.Response_Callback{proc_ = _on_initialize_response, user = lc}
	conn.send_request(lc.conn, "initialize", params, cb)
}

client_shutdown :: proc(lc: ^LSP_Client) {
	sync.mutex_lock(&lc.state_mu)
	if lc.state != .Running { sync.mutex_unlock(&lc.state_mu); return }
	lc.state = .Stopping
	sync.mutex_unlock(&lc.state_mu)

	cb := proto.Response_Callback{proc_ = _on_shutdown_response, user = lc}
	conn.send_request(lc.conn, "shutdown", "", cb)
}

client_drain :: proc(lc: ^LSP_Client) {
	conn.conn_drain(lc.conn)
}

client_flush_ready :: proc(lc: ^LSP_Client) -> bool {
	if !lc.flush_pending { return false }
	if time.tick_since(lc.flush_tick) < lc.flush_delay { return false }
	lc.flush_pending = false
	return true
}

client_is_running :: proc(lc: ^LSP_Client) -> bool {
	return lc.state == .Running
}

client_state :: proc(lc: ^LSP_Client) -> Client_State {
	return lc.state
}

// ---------------------------------------------------------------------------
// Private
// ---------------------------------------------------------------------------

_stub_req_handler :: proc(id: int, _: []u8) -> (string, bool) {
	return "null", true
}

_on_initialize_response :: proc(result: json.Value, error: json.Value, user: rawptr) {
	lc := cast(^LSP_Client)user

	defer json.destroy_value(result)
	defer json.destroy_value(error)

	if obj, ok := result.(json.Object); ok {
		if caps, has := obj["result"]; has {
			if caps_obj, is_caps := caps.(json.Object); is_caps {
				if server_caps, has2 := caps_obj["capabilities"]; has2 {
					lc.server_caps = proto.clone_json_value(server_caps)
				}
			}
		} else if caps, has2 := obj["capabilities"]; has2 {
			lc.server_caps = proto.clone_json_value(caps)
		}
	}

	conn.send_notification(lc.conn, "initialized", "{}")

	sync.mutex_lock(&lc.state_mu)
	lc.state         = .Running
	lc.flush_pending = true
	lc.flush_tick    = time.tick_now()
	sync.mutex_unlock(&lc.state_mu)

	if lc.on_initialized != nil { lc.on_initialized(lc, lc.user) }
}

_on_shutdown_response :: proc(result: json.Value, error: json.Value, user: rawptr) {
	lc := cast(^LSP_Client)user

	json.destroy_value(result)
	json.destroy_value(error)

	conn.send_notification(lc.conn, "exit", "")
	conn.conn_stop(lc.conn)

	sync.mutex_lock(&lc.state_mu)
	lc.state = .Stopped
	sync.mutex_unlock(&lc.state_mu)

	if lc.on_stopped != nil { lc.on_stopped(lc, lc.user) }
}
