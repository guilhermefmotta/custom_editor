package lsp_server

import ws "../workspace"
import "core:strings"

Server_Config :: struct {
	name:              string,
	command:           []string,
	languages:         []ws.Language_ID,
	init_options_json: string,
	root_markers:      []string,
	auto_start:        bool,
}

server_config_destroy :: proc(cfg: ^Server_Config) {
	delete(cfg.name)
	for &s in cfg.command { delete(s) }
	delete(cfg.command)
	delete(cfg.languages)
	delete(cfg.init_options_json)
	for &s in cfg.root_markers { delete(s) }
	delete(cfg.root_markers)
	free(cfg)
}

server_config_for_odin :: proc() -> ^Server_Config {
	cfg          := new(Server_Config)
	cfg.name      = strings.clone("OLS")
	cmd           := make([]string, 1)
	cmd[0]         = strings.clone("ols")
	cfg.command   = cmd
	langs         := make([]ws.Language_ID, 1)
	langs[0]       = .Odin
	cfg.languages = langs
	markers       := make([]string, 2)
	markers[0]     = strings.clone("ols.json")
	markers[1]     = strings.clone(".git")
	cfg.root_markers = markers
	cfg.auto_start = true
	return cfg
}

server_config_for_language :: proc(lang: ws.Language_ID) -> ^Server_Config {
	switch lang {
	case .Odin: return server_config_for_odin()
	case:       return nil
	}
}
