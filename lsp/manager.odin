package lsp

import "core:fmt"
import "core:os"
import "core:strings"

// ---------------------------------------------------------------------------
// Language server configuration
// ---------------------------------------------------------------------------

Server_Config :: struct {
	// Command + args to launch the server
	command: []string, // heap strings

	// File extensions this server handles (without dot)
	extensions: []string, // heap strings

	// Optional: extra initialization options sent as JSON string
	// Empty string → no initializationOptions override
	init_options: string, // heap

	// Name for display / logging
	name: string, // heap
}

server_config_destroy :: proc(c: ^Server_Config) {
	for s in c.command    { delete(s) }
	for s in c.extensions { delete(s) }
	delete(c.command)
	delete(c.extensions)
	delete(c.init_options)
	delete(c.name)
}

// ---------------------------------------------------------------------------
// LSP Manager — owns one client per server config, lazily started
// ---------------------------------------------------------------------------

Client_Entry :: struct {
	config: Server_Config,
	client: ^Language_Client, // nil until first file of matching type opened
}

LSP_Manager :: struct {
	entries:   [dynamic]Client_Entry,
	root_path: string, // heap; workspace root
}

lsp_manager_init :: proc(m: ^LSP_Manager, root_path: string) {
	m.entries   = make([dynamic]Client_Entry)
	m.root_path = strings.clone(root_path)
	lsp_log_open("lsp.log")
	log_writef("INF", fmt.tprintf("lsp_manager_init root=%s", root_path))
}

lsp_manager_destroy :: proc(m: ^LSP_Manager) {
	for &e in m.entries {
		if e.client != nil { client_destroy(e.client) }
		server_config_destroy(&e.config)
	}
	delete(m.entries)
	delete(m.root_path)
	lsp_log_close()
}

// ---------------------------------------------------------------------------
// Register a server config
// ---------------------------------------------------------------------------

lsp_manager_register :: proc(m: ^LSP_Manager, cfg: Server_Config) {
	append(&m.entries, Client_Entry{config = cfg})
}

// ---------------------------------------------------------------------------
// Default server configurations — edit commands to match your system
// ---------------------------------------------------------------------------

_clone_strs :: proc(strs: []string) -> []string {
	out := make([]string, len(strs))
	for s, i in strs { out[i] = strings.clone(s) }
	return out
}

_register_defaults :: proc(m: ^LSP_Manager) {
	// ---- Odin (ols) ----
	lsp_manager_register(m, Server_Config{
		name       = strings.clone("ols"),
		command    = _clone_strs({"ols"}),
		extensions = _clone_strs({"odin"}),
	})

	// ---- C / C++ (clangd) ----
	lsp_manager_register(m, Server_Config{
		name       = strings.clone("clangd"),
		command    = _clone_strs({"clangd", "--background-index", "--clang-tidy"}),
		extensions = _clone_strs({"c", "h", "cpp", "cc", "cxx", "hpp", "hxx"}),
	})

	// ---- Python (pylsp) ----
	lsp_manager_register(m, Server_Config{
		name       = strings.clone("pylsp"),
		command    = _clone_strs({"pylsp"}),
		extensions = _clone_strs({"py"}),
	})

	// ---- Go (gopls) ----
	lsp_manager_register(m, Server_Config{
		name       = strings.clone("gopls"),
		command    = _clone_strs({"gopls", "serve"}),
		extensions = _clone_strs({"go"}),
	})

	// ---- Rust (rust-analyzer) ----
	lsp_manager_register(m, Server_Config{
		name       = strings.clone("rust-analyzer"),
		command    = _clone_strs({"rust-analyzer"}),
		extensions = _clone_strs({"rs"}),
	})

	// ---- JavaScript / TypeScript (typescript-language-server) ----
	lsp_manager_register(m, Server_Config{
		name       = strings.clone("typescript-language-server"),
		command    = _clone_strs({"typescript-language-server", "--stdio"}),
		extensions = _clone_strs({"js", "ts", "jsx", "tsx", "mjs", "cjs"}),
	})

	// ---- Java (jdtls — Eclipse JDT Language Server) ----
	//
	// jdtls needs a per-workspace data directory.
	// We use ~/.cache/jdtls/workspace/<root_hash> so different projects
	// don't share state.  The jdtls wrapper script (from AUR, brew, etc.)
	// accepts -data <dir>; if you use the raw jar, replace command with the
	// full java invocation shown in the comment below.
	//
	// Raw jar alternative (set JDTLS_HOME env):
	//   java \
	//     -Declipse.application=org.eclipse.jdt.ls.core.id1 \
	//     -Dosgi.bundles.defaultStartLevel=4 \
	//     -Declipse.product=org.eclipse.jdt.ls.core.product \
	//     -Dlog.level=ALL \
	//     -noverify \
	//     -Xmx1G \
	//     --add-modules=ALL-SYSTEM \
	//     --add-opens java.base/java.util=ALL-UNNAMED \
	//     --add-opens java.base/java.lang=ALL-UNNAMED \
	//     -jar $JDTLS_HOME/plugins/org.eclipse.equinox.launcher_*.jar \
	//     -configuration $JDTLS_HOME/config_linux \
	//     -data ~/.cache/jdtls/workspace/default
	lsp_manager_register(m, _make_jdtls_config(m.root_path))

	// ---- Lua (lua-language-server) ----
	lsp_manager_register(m, Server_Config{
		name       = strings.clone("lua-language-server"),
		command    = _clone_strs({"lua-language-server"}),
		extensions = _clone_strs({"lua"}),
	})

	// ---- Zig (zls) ----
	lsp_manager_register(m, Server_Config{
		name       = strings.clone("zls"),
		command    = _clone_strs({"zls"}),
		extensions = _clone_strs({"zig"}),
	})

	// ---- C# (omnisharp) ----
	lsp_manager_register(m, Server_Config{
		name       = strings.clone("omnisharp"),
		command    = _clone_strs({"omnisharp", "--languageserver", "--hostPID", "0"}),
		extensions = _clone_strs({"cs"}),
	})
}

// ---------------------------------------------------------------------------
// Java (jdtls) — full configuration
// ---------------------------------------------------------------------------

_make_jdtls_config :: proc(root_path: string) -> Server_Config {
	// Workspace data dir: ~/.cache/jdtls/workspace/<simple hash of root>
	hash := _simple_hash(root_path)
	home := os.get_env("HOME", context.temp_allocator)
	data_dir := fmt.tprintf("%s/.cache/jdtls/workspace/%x", home, hash)

	// jdtls initialization options (standard set; expand as needed)
	init_opts := `{
  "settings": {
    "java": {
      "autobuild": { "enabled": true },
      "maxConcurrentBuilds": 1,
      "completion": {
        "enabled":          true,
        "importOrder":      ["java", "javax", "com", "org"],
        "filteredTypes":    ["com.sun.*", "sun.*", "jdk.*"],
        "guessMethodArguments": true,
        "overwrite":        true,
        "postfix":          { "enabled": true }
      },
      "signatureHelp": { "enabled": true, "description": { "enabled": true } },
      "format": {
        "enabled":         true,
        "onType":          { "enabled": true },
        "comments":        { "enabled": true },
        "insertSpaces":    true,
        "tabSize":         4
      },
      "saveActions": { "organizeImports": false },
      "import": {
        "gradle": { "enabled": true, "offline": { "enabled": false }, "wrapper": { "enabled": true } },
        "maven":  { "enabled": true },
        "exclusions": [
          "**/node_modules/**",
          "**/.metadata/**",
          "**/archetype-resources/**",
          "**/META-INF/maven/**"
        ]
      },
      "referencesCodeLens": { "enabled": true },
      "implementationsCodeLens": { "enabled": true },
      "inlayHints": {
        "parameterNames": { "enabled": "all", "exclusions": [] }
      },
      "references": { "includeDecompiledSources": true },
      "sources": { "organizeImports": { "starThreshold": 99, "staticStarThreshold": 99 } },
      "codeGeneration": {
        "toString":    { "template": "${object.className}{${member.name()}=${member.value}, }" },
        "hashCodeEquals": { "useJava7Objects": false, "useInstanceof": false },
        "useBlocks":   false
      },
      "configuration": {
        "updateBuildConfiguration": "interactive",
        "runtimes": []
      },
      "errors": { "incompleteClasspath": { "severity": "warning" } },
      "trace": { "server": "off" }
    }
  },
  "extendedClientCapabilities": {
    "classFileContentsSupport":      true,
    "overrideMethodsPromptSupport":  true,
    "hashCodeEqualsPromptSupport":   true,
    "advancedOrganizeImportsSupport": true,
    "generateToStringPromptSupport": true,
    "advancedGenerateAccessorsSupport": true,
    "generateConstructorsPromptSupport": true,
    "generateDelegateMethodsPromptSupport": true,
    "advancedExtractRefactoringSupport": true,
    "inferSelectionSupport": ["extractMethod", "extractVariable", "extractField"],
    "moveRefactoringSupport":  true,
    "clientHoverProvider":     true,
    "clientDocumentSymbolProvider": true,
    "gradleChecksumWrapperPromptSupport": true,
    "resolveAdditionalTextEditsSupport":  true,
    "progressReportProvider":  false,
    "executeClientCommandSupport": true,
    "shouldLanguageServerExitOnShutdown": true
  }
}`

	cmd := []string{
		"jdtls",
		"-data", data_dir,
	}

	return Server_Config{
		name         = strings.clone("jdtls"),
		command      = _clone_strs(cmd),
		extensions   = _clone_strs({"java"}),
		init_options = strings.clone(init_opts),
	}
}

// Simple djb2-style hash for workspace directory name.
_simple_hash :: proc(s: string) -> u32 {
	h: u32 = 5381
	for c in s { h = h * 33 ~ u32(c) }
	return h
}

// ---------------------------------------------------------------------------
// Look up client for a file extension — start if not running
// ---------------------------------------------------------------------------

lsp_manager_get_client :: proc(m: ^LSP_Manager, ext: string) -> ^Language_Client {
	for &e in m.entries {
		for ex in e.config.extensions {
			if ex == ext {
				if e.client == nil { _start_client(&e, m.root_path) }
				return e.client
			}
		}
	}
	return nil
}

lsp_manager_get_client_for_path :: proc(m: ^LSP_Manager, path: string) -> ^Language_Client {
	ext := path_ext(path)
	return lsp_manager_get_client(m, ext)
}

// Read-only lookup — never starts a server. Safe to call from render path.
lsp_manager_find_client_for_path :: proc(m: ^LSP_Manager, path: string) -> ^Language_Client {
	ext := path_ext(path)
	for &e in m.entries {
		for ex in e.config.extensions {
			if ex == ext { return e.client }
		}
	}
	return nil
}

_start_client :: proc(e: ^Client_Entry, root_path: string) {
	c := client_create(root_path)
	if !client_start(c, e.config.command) {
		client_destroy(c)
		return
	}
	e.client = c
}

// ---------------------------------------------------------------------------
// High-level file events — called from editor integration
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// High-level file events — use find (read-only); server must be started
// explicitly via lsp_manager_start_for_ext.
// ---------------------------------------------------------------------------

manager_did_open :: proc(m: ^LSP_Manager, path: string, content: string) {
	c := lsp_manager_find_client_for_path(m, path)
	if c == nil { return }
	doc_sync_did_open(c, path, content) // handles Initializing → deferred; Running → immediate
	if c.state == .Running && c.caps.has_semantic_tokens { sem_tokens_request_full(c, path) }
}

manager_did_close :: proc(m: ^LSP_Manager, path: string) {
	c := lsp_manager_find_client_for_path(m, path)
	if c == nil { return }
	doc_sync_did_close(c, path)
}

manager_did_change_full :: proc(m: ^LSP_Manager, path: string, content: string) {
	c := lsp_manager_find_client_for_path(m, path)
	if c == nil { return }
	doc_sync_did_change_full(c, path, content)
}

manager_did_save :: proc(m: ^LSP_Manager, path: string, content: string) {
	c := lsp_manager_find_client_for_path(m, path)
	if c == nil { return }
	doc_sync_did_save(c, path, content, true)
	if c.caps.has_semantic_tokens { sem_tokens_request_full(c, path) }
}

manager_completion :: proc(m: ^LSP_Manager, path: string, line, char: int,
                           trigger: Trigger_Kind, trigger_char: rune, prefix: string) {
	c := lsp_manager_find_client_for_path(m, path)
	if c == nil { return }
	completion_request(c, path, line, char, trigger, trigger_char, prefix)
}

manager_hover :: proc(m: ^LSP_Manager, path: string, line, char: int) {
	c := lsp_manager_find_client_for_path(m, path)
	if c == nil { return }
	hover_request(c, path, line, char)
}

manager_sig_help :: proc(m: ^LSP_Manager, path: string, line, char: int) {
	c := lsp_manager_find_client_for_path(m, path)
	if c == nil { return }
	sig_help_request(c, path, line, char, false)
}

// ---------------------------------------------------------------------------
// Update all active clients — call each frame from UI thread
// ---------------------------------------------------------------------------

lsp_manager_update :: proc(m: ^LSP_Manager) {
	for &e in m.entries {
		if e.client == nil { continue }
		c := e.client
		client_update(c)
		completion_manager_update(c)
	}
}

// Get diagnostics for a path from the appropriate client.
manager_get_diags :: proc(m: ^LSP_Manager, path: string) -> []Diagnostic {
	c := lsp_manager_find_client_for_path(m, path)
	if c == nil { return nil }
	return diag_store_get(&c.diags, path)
}

// Get completion state for a path's client.
manager_get_completion :: proc(m: ^LSP_Manager, path: string) -> ^Completion_Manager {
	c := lsp_manager_find_client_for_path(m, path)
	if c == nil { return nil }
	return &c.completion
}

manager_get_hover :: proc(m: ^LSP_Manager, path: string) -> ^Hover_Manager {
	c := lsp_manager_find_client_for_path(m, path)
	if c == nil { return nil }
	return &c.hover
}

manager_get_sig_help :: proc(m: ^LSP_Manager, path: string) -> ^Sig_Help_Manager {
	c := lsp_manager_find_client_for_path(m, path)
	if c == nil { return nil }
	return &c.sig_help
}

manager_get_sem_tokens :: proc(m: ^LSP_Manager, path: string) -> ^Sem_Token_Store {
	c := lsp_manager_find_client_for_path(m, path)
	if c == nil { return nil }
	return &c.sem_tokens
}

// Cancel active completion for a path's client.
manager_completion_cancel :: proc(m: ^LSP_Manager, path: string) {
	c := lsp_manager_find_client_for_path(m, path)
	if c == nil { return }
	completion_cancel(c)
}

// Go To Definition — returns Location or empty on failure.
// Callback-based: result delivered on next client_update.
manager_definition :: proc(m: ^LSP_Manager, path: string, line, char: int, cb: Response_Callback) {
	c := lsp_manager_find_client_for_path(m, path)
	if c == nil || !c.caps.has_definition { return }
	params := td_pos_params(path_to_uri(path), {line, char})
	client_send_request(c, "textDocument/definition", params, cb)
}

manager_references :: proc(m: ^LSP_Manager, path: string, line, char: int, cb: Response_Callback) {
	c := lsp_manager_find_client_for_path(m, path)
	if c == nil || !c.caps.has_references { return }
	params := strings.concatenate({
		`{"textDocument":{"uri":`, json_str(path_to_uri(path)),
		`},"position":{"line":`, fmt.tprintf("%d", line),
		`,"character":`, fmt.tprintf("%d", char),
		`},"context":{"includeDeclaration":true}}`,
	}, context.temp_allocator)
	client_send_request(c, "textDocument/references", params, cb)
}

manager_rename :: proc(m: ^LSP_Manager, path: string, line, char: int, new_name: string, cb: Response_Callback) {
	c := lsp_manager_find_client_for_path(m, path)
	if c == nil || !c.caps.has_rename { return }
	params := strings.concatenate({
		`{"textDocument":{"uri":`, json_str(path_to_uri(path)),
		`},"position":{"line":`, fmt.tprintf("%d", line),
		`,"character":`, fmt.tprintf("%d", char),
		`},"newName":`, json_str(new_name), `}`,
	}, context.temp_allocator)
	client_send_request(c, "textDocument/rename", params, cb)
}

manager_format :: proc(m: ^LSP_Manager, path: string, tab_size: int, use_spaces: bool, cb: Response_Callback) {
	c := lsp_manager_find_client_for_path(m, path)
	if c == nil || !c.caps.has_formatting { return }
	spaces_s := use_spaces ? "true" : "false"
	params := strings.concatenate({
		`{"textDocument":{"uri":`, json_str(path_to_uri(path)),
		`},"options":{"tabSize":`, fmt.tprintf("%d", tab_size),
		`,"insertSpaces":`, spaces_s, `}}`,
	}, context.temp_allocator)
	client_send_request(c, "textDocument/formatting", params, cb)
}

// ---------------------------------------------------------------------------
// Explicit server control — called from LSP dialog only
// ---------------------------------------------------------------------------

// Returns the server config name for the given file extension, or "".
lsp_manager_server_name_for_path :: proc(m: ^LSP_Manager, path: string) -> string {
	ext := path_ext(path)
	for &e in m.entries {
		for ex in e.config.extensions {
			if ex == ext { return e.config.name }
		}
	}
	return ""
}

// Start the server for the given file extension.
// Returns (true, "") on success or if already running.
// Returns (false, reason) on failure.
lsp_manager_start_for_ext :: proc(m: ^LSP_Manager, ext: string) -> (ok: bool, err: string) {
	for &e in m.entries {
		for ex in e.config.extensions {
			if ex != ext { continue }
			if e.client != nil {
				switch e.client.state {
				case .Running:
					return false, "already running — use Restart"
				case .Initializing, .Starting:
					return false, "already starting"
				case .Created, .Shutting_Down, .Stopped:
					client_destroy(e.client)
					e.client = nil
				}
			}
			c := client_create(m.root_path)
			if !client_start(c, e.config.command) {
				client_destroy(c)
				return false, fmt.tprintf("failed to spawn '%s' — check it is in PATH", e.config.command[0])
			}
			e.client = c
			return true, ""
		}
	}
	return false, fmt.tprintf("no server registered for '.%s' files", ext)
}

// Stop the server for the given file extension.
lsp_manager_stop_for_ext :: proc(m: ^LSP_Manager, ext: string) -> (ok: bool, err: string) {
	for &e in m.entries {
		for ex in e.config.extensions {
			if ex != ext { continue }
			if e.client == nil { return false, "server not running" }
			client_destroy(e.client)
			e.client = nil
			return true, ""
		}
	}
	return false, fmt.tprintf("no server registered for '.%s' files", ext)
}

// Restart (stop then start) the server for the given file extension.
lsp_manager_restart_for_ext :: proc(m: ^LSP_Manager, ext: string) -> (ok: bool, err: string) {
	// Stop — ignore error if not running (clean start is fine)
	lsp_manager_stop_for_ext(m, ext)
	return lsp_manager_start_for_ext(m, ext)
}
