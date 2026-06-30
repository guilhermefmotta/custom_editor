package lsp_server

import trans "../transport"

spawn_server_process :: proc(command: []string) -> (^trans.Transport, bool) {
	return trans.stdio_transport_create(command)
}

kill_server_process :: proc(t: ^trans.Transport) {
	trans.transport_destroy(t)
	free(t)
}
