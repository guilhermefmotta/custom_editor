package lsp_server

import ws      "../workspace"
import trans   "../transport"
import connpkg "../connection"
import clpkg   "../client"
import "core:strings"
import "core:sync"

Server_State :: enum u8 { Stopped, Starting, Running, Stopping }

Server_Instance :: struct {
	config:    ^Server_Config,
	transport: ^trans.Transport,
	conn:      ^connpkg.Conn,
	client:    ^clpkg.LSP_Client,
	state:     Server_State,
	root_uri:  string,
}

server_instance_destroy :: proc(si: ^Server_Instance) {
	clpkg.client_destroy(si.client)
	delete(si.root_uri)
	free(si)
}

Server_Manager :: struct {
	mu:      sync.Mutex,
	servers: map[ws.Language_ID]^Server_Instance,
	configs: map[ws.Language_ID]^Server_Config,
}

server_manager_create :: proc() -> ^Server_Manager {
	sm         := new(Server_Manager)
	sm.servers  = make(map[ws.Language_ID]^Server_Instance)
	sm.configs  = make(map[ws.Language_ID]^Server_Config)
	return sm
}

server_manager_destroy :: proc(sm: ^Server_Manager) {
	sync.mutex_lock(&sm.mu)
	for _, si  in sm.servers { server_instance_destroy(si) }
	delete(sm.servers)
	for _, cfg in sm.configs { server_config_destroy(cfg) }
	delete(sm.configs)
	sync.mutex_unlock(&sm.mu)
	free(sm)
}

server_manager_register :: proc(sm: ^Server_Manager, lang: ws.Language_ID, cfg: ^Server_Config) {
	sync.mutex_lock(&sm.mu)
	if old, ok := sm.configs[lang]; ok { server_config_destroy(old) }
	sm.configs[lang] = cfg
	sync.mutex_unlock(&sm.mu)
}

server_manager_get_or_start :: proc(sm: ^Server_Manager, lang: ws.Language_ID, root_uri, caps_json: string) -> (^Server_Instance, bool) {
	sync.mutex_lock(&sm.mu)
	if si, ok := sm.servers[lang]; ok && si.state == .Running {
		sync.mutex_unlock(&sm.mu)
		return si, true
	}
	cfg, has_cfg := sm.configs[lang]
	if !has_cfg {
		cfg = server_config_for_language(lang)
		if cfg == nil { sync.mutex_unlock(&sm.mu); return nil, false }
		sm.configs[lang] = cfg
	}
	sync.mutex_unlock(&sm.mu)

	transport, ok := trans.stdio_transport_create(cfg.command)
	if !ok { return nil, false }

	c  := connpkg.conn_create(transport)
	connpkg.conn_start(c)

	lc := clpkg.client_create(c)
	clpkg.client_initialize(lc, root_uri, caps_json)

	si           := new(Server_Instance)
	si.config     = cfg
	si.transport  = transport
	si.conn       = c
	si.client     = lc
	si.state      = .Starting
	si.root_uri   = strings.clone(root_uri)

	sync.mutex_lock(&sm.mu)
	sm.servers[lang] = si
	sync.mutex_unlock(&sm.mu)

	return si, true
}

server_manager_stop :: proc(sm: ^Server_Manager, lang: ws.Language_ID) {
	sync.mutex_lock(&sm.mu)
	si, ok := sm.servers[lang]
	if !ok { sync.mutex_unlock(&sm.mu); return }
	delete_key(&sm.servers, lang)
	sync.mutex_unlock(&sm.mu)
	server_instance_destroy(si)
}

server_manager_get :: proc(sm: ^Server_Manager, lang: ws.Language_ID) -> (^Server_Instance, bool) {
	sync.mutex_lock(&sm.mu)
	si, ok := sm.servers[lang]
	sync.mutex_unlock(&sm.mu)
	return si, ok
}

server_manager_drain :: proc(sm: ^Server_Manager) {
	sync.mutex_lock(&sm.mu)
	instances := make([dynamic]^Server_Instance, context.temp_allocator)
	for _, si in sm.servers { append(&instances, si) }
	sync.mutex_unlock(&sm.mu)
	for si in instances {
		clpkg.client_drain(si.client)
		if si.state == .Starting && clpkg.client_is_running(si.client) {
			si.state = .Running
		}
	}
}
