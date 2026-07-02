package lsp

import "core:fmt"
import "core:os"
import "core:path/filepath"
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

	// Auto-install: command to run when binary is not found on PATH.
	// Empty slice = no auto-install available.
	install_cmd:   []string, // heap
	install_label: string,   // heap — shown in UI: "Installing pylsp via pip..."
}

server_config_destroy :: proc(c: ^Server_Config) {
	for s in c.command      { delete(s) }
	for s in c.extensions   { delete(s) }
	for s in c.install_cmd  { delete(s) }
	delete(c.command)
	delete(c.extensions)
	delete(c.install_cmd)
	delete(c.init_options)
	delete(c.install_label)
	delete(c.name)
}

// ---------------------------------------------------------------------------
// LSP Manager — one client per (server_config × project_root)
// ---------------------------------------------------------------------------

// One running client for a specific project root.
Rooted_Client :: struct {
	root:   string,             // heap-cloned; absolute project root path
	client: ^Language_Client,
}

Install_State :: enum { None, Running, Done, Failed }

Client_Entry :: struct {
	config:         Server_Config,
	clients:        [dynamic]Rooted_Client, // one per project root, lazily started
	install_state:  Install_State,
	install_job:    Install_Job,
	install_output: [dynamic]u8, // captured stdout+stderr of install process
}

LSP_Manager :: struct {
	entries:   [dynamic]Client_Entry,
	root_path: string, // heap; fallback workspace root
}

lsp_manager_init :: proc(m: ^LSP_Manager, root_path: string) {
	m.entries   = make([dynamic]Client_Entry)
	m.root_path = strings.clone(root_path)
	lsp_log_open("lsp.log")
	log_writef("INF", fmt.tprintf("lsp_manager_init root=%s", root_path))
}

lsp_manager_destroy :: proc(m: ^LSP_Manager) {
	for &e in m.entries {
		for &rc in e.clients {
			client_destroy(rc.client)
			delete(rc.root)
		}
		delete(e.clients)
		server_config_destroy(&e.config)
		if e.install_job.active { install_job_kill(&e.install_job) }
		delete(e.install_output)
	}
	delete(m.entries)
	delete(m.root_path)
	lsp_log_close()
}

// ---------------------------------------------------------------------------
// Register a server config
// ---------------------------------------------------------------------------

lsp_manager_register :: proc(m: ^LSP_Manager, cfg: Server_Config) {
	append(&m.entries, Client_Entry{
		config         = cfg,
		clients        = make([dynamic]Rooted_Client),
		install_output = make([dynamic]u8),
	})
}

// ---------------------------------------------------------------------------
// Project root detection — walk up from file looking for build markers
// ---------------------------------------------------------------------------

_PROJ_MARKERS :: [?]string{
	"pom.xml", "build.gradle", "build.gradle.kts",
	"go.mod", "Cargo.toml", "ols.json", "package.json",
	"pyproject.toml", "setup.py", ".git",
}

_lsp_file_exists :: proc(path: string) -> bool {
	fi, err := os.stat(path, context.temp_allocator)
	return err == nil && fi.size >= 0
}

_project_root_for_file :: proc(file_path: string) -> string {
	dir := filepath.dir(file_path)
	for dir != "" && dir != "/" {
		for m in _PROJ_MARKERS {
			probe := strings.concatenate({dir, "/", m}, context.temp_allocator)
			if _lsp_file_exists(probe) { return dir }
		}
		parent := filepath.dir(dir)
		if parent == dir || parent == "" { break }
		dir = parent
	}
	return filepath.dir(file_path)
}

// ---------------------------------------------------------------------------
// Find or start a rooted client within an entry
// ---------------------------------------------------------------------------

_find_rooted_client :: proc(e: ^Client_Entry, file_path: string) -> ^Language_Client {
	best_len := -1
	best: ^Language_Client
	for &rc in e.clients {
		if strings.has_prefix(file_path, rc.root) && len(rc.root) > best_len {
			best_len = len(rc.root)
			best     = rc.client
		}
	}
	return best
}

_start_rooted_client :: proc(e: ^Client_Entry, root: string) -> ^Language_Client {
	// Check if already running for this root
	for &rc in e.clients {
		if rc.root == root {
			return rc.client
		}
	}

	// Check if install is in progress; retry start after done
	if e.install_state == .Running { return nil }
	if e.install_state == .Failed  { return nil }

	// Check binary exists on PATH; auto-install if missing
	if len(e.config.command) > 0 {
		exists, _ := server_binary_exists(e.config.command[0])
		if !exists {
			if e.install_state == .None && len(e.config.install_cmd) > 0 {
				label := e.config.install_label if e.config.install_label != "" else fmt.tprintf("Installing %s...", e.config.name)
				log_writef("INF", fmt.tprintf("%s (binary '%s' not found)", label, e.config.command[0]))
				clear(&e.install_output)
				append(&e.install_output, ..transmute([]u8)label)
				append(&e.install_output, '\n')
				job, ok := install_job_start(e.config.install_cmd)
				if ok {
					e.install_job   = job
					e.install_state = .Running
				} else {
					e.install_state = .Failed
					append(&e.install_output, ..transmute([]u8)string("Failed to start installer\n"))
				}
			} else if e.install_state == .None {
				log_writef("WRN", fmt.tprintf("'%s' not on PATH and no auto-install available", e.config.command[0]))
			}
			return nil
		}
	}

	// Build command — for jdtls, inject a unique -data dir per root
	cmd := e.config.command
	jdtls_extra: []string
	if e.config.name == "jdtls" {
		hash := _simple_hash(root)
		home := os.get_env("HOME", context.temp_allocator)
		if home == "" { home = os.get_env("USERPROFILE", context.temp_allocator) }
		ddir := fmt.tprintf("%s/.cache/jdtls/workspace/%x", home, hash)
		jdtls_extra = make([]string, len(cmd) + 2, context.temp_allocator)
		for s, i in cmd { jdtls_extra[i] = s }
		jdtls_extra[len(cmd)]   = "-data"
		jdtls_extra[len(cmd)+1] = ddir
		cmd = jdtls_extra
	}
	c := client_create(root)
	if !client_start(c, cmd) { client_destroy(c); return nil }
	append(&e.clients, Rooted_Client{root = strings.clone(root), client = c})
	log_writef("INF", fmt.tprintf("started '%s' for root=%s", e.config.name, root))
	return c
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
		name          = strings.clone("pylsp"),
		command       = _clone_strs({"pylsp"}),
		extensions    = _clone_strs({"py"}),
		install_cmd   = _clone_strs({"pip3", "install", "python-lsp-server"}),
		install_label = strings.clone("Installing pylsp via pip3..."),
	})

	// ---- Go (gopls) ----
	lsp_manager_register(m, Server_Config{
		name          = strings.clone("gopls"),
		command       = _clone_strs({"gopls", "serve"}),
		extensions    = _clone_strs({"go"}),
		install_cmd   = _clone_strs({"go", "install", "golang.org/x/tools/gopls@latest"}),
		install_label = strings.clone("Installing gopls via go install..."),
	})

	// ---- Rust (rust-analyzer) ----
	lsp_manager_register(m, Server_Config{
		name          = strings.clone("rust-analyzer"),
		command       = _clone_strs({"rust-analyzer"}),
		extensions    = _clone_strs({"rs"}),
		install_cmd   = _clone_strs({"rustup", "component", "add", "rust-analyzer"}),
		install_label = strings.clone("Installing rust-analyzer via rustup..."),
	})

	// ---- JavaScript / TypeScript (typescript-language-server) ----
	lsp_manager_register(m, Server_Config{
		name          = strings.clone("typescript-language-server"),
		command       = _clone_strs({"typescript-language-server", "--stdio"}),
		extensions    = _clone_strs({"js", "ts", "jsx", "tsx", "mjs", "cjs"}),
		install_cmd   = _clone_strs({"npm", "install", "-g", "typescript-language-server", "typescript"}),
		install_label = strings.clone("Installing typescript-language-server via npm..."),
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
	{
		when ODIN_OS == .Windows {
			lua_install := _clone_strs({"powershell", "-NoProfile", "-Command",
				`$dir="$env:LOCALAPPDATA\editor"; New-Item -ItemType Directory -Force -Path $dir | Out-Null; ` +
				`$url="https://github.com/LuaLS/lua-language-server/releases/latest/download/lua-language-server-win32-x64.zip"; ` +
				`Invoke-WebRequest -Uri $url -OutFile "$dir\luals.zip"; ` +
				`Expand-Archive -Force "$dir\luals.zip" "$dir\lua-language-server"; ` +
				`$bin="$dir\lua-language-server\bin"; ` +
				`[Environment]::SetEnvironmentVariable("PATH","$bin;$env:PATH","User")`})
		} else {
			lua_install := _clone_strs({"sh", "-c",
				`set -e; DEST="$HOME/.local/bin"; mkdir -p "$DEST"; ` +
				`OS=$(uname -s); ARCH=$(uname -m); ` +
				`if [ "$OS" = "Darwin" ]; then PLAT=darwin; else PLAT=linux; fi; ` +
				`if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then ARCH=arm64; else ARCH=x64; fi; ` +
				`URL="https://github.com/LuaLS/lua-language-server/releases/latest/download/lua-language-server-$PLAT-$ARCH.tar.gz"; ` +
				`TMP=$(mktemp -d); curl -fsSL "$URL" | tar -xz -C "$TMP"; ` +
				`cp "$TMP/bin/lua-language-server" "$DEST/lua-language-server"; ` +
				`chmod +x "$DEST/lua-language-server"; rm -rf "$TMP"; ` +
				`echo "Installed: $DEST/lua-language-server"`})
		}
		lsp_manager_register(m, Server_Config{
			name          = strings.clone("lua-language-server"),
			command       = _clone_strs({"lua-language-server"}),
			extensions    = _clone_strs({"lua"}),
			install_cmd   = lua_install,
			install_label = strings.clone("Downloading lua-language-server..."),
		})
	}

	// ---- Zig (zls) ----
	{
		when ODIN_OS == .Windows {
			zls_install := _clone_strs({"powershell", "-NoProfile", "-Command",
				`$dir="$env:LOCALAPPDATA\editor"; New-Item -ItemType Directory -Force -Path $dir | Out-Null; ` +
				`$url="https://github.com/zigtools/zls/releases/latest/download/zls-x86_64-windows.zip"; ` +
				`Invoke-WebRequest -Uri $url -OutFile "$dir\zls.zip"; ` +
				`Expand-Archive -Force "$dir\zls.zip" "$dir\zls"; ` +
				`[Environment]::SetEnvironmentVariable("PATH","$dir\zls;$env:PATH","User")`})
		} else {
			zls_install := _clone_strs({"sh", "-c",
				`set -e; DEST="$HOME/.local/bin"; mkdir -p "$DEST"; ` +
				`ARCH=$(uname -m); OS=$(uname -s | tr A-Z a-z); ` +
				`if [ "$OS" = "darwin" ]; then OS=macos; fi; ` +
				`URL="https://github.com/zigtools/zls/releases/latest/download/zls-$ARCH-$OS.tar.xz"; ` +
				`curl -fsSL "$URL" | tar -xJ -C "$DEST" zls; ` +
				`chmod +x "$DEST/zls"; echo "Installed: $DEST/zls"`})
		}
		lsp_manager_register(m, Server_Config{
			name          = strings.clone("zls"),
			command       = _clone_strs({"zls"}),
			extensions    = _clone_strs({"zig"}),
			install_cmd   = zls_install,
			install_label = strings.clone("Downloading zls (Zig Language Server)..."),
		})
	}

	// ---- C# (csharp-ls via dotnet) ----
	lsp_manager_register(m, Server_Config{
		name          = strings.clone("csharp-ls"),
		command       = _clone_strs({"csharp-ls"}),
		extensions    = _clone_strs({"cs"}),
		install_cmd   = _clone_strs({"dotnet", "tool", "install", "-g", "csharp-ls"}),
		install_label = strings.clone("Installing csharp-ls via dotnet tool..."),
	})

	// ---- XML / HTML (LemMinX) ----
	{
		when ODIN_OS == .Windows {
			lemminx_install := _clone_strs({"powershell", "-NoProfile", "-Command",
				`$dir="$env:LOCALAPPDATA\editor"; ` +
				`New-Item -ItemType Directory -Force -Path $dir | Out-Null; ` +
				`$url="https://github.com/eclipse/lemminx/releases/latest/download/lemminx-win32.exe"; ` +
				`Invoke-WebRequest -Uri $url -OutFile "$dir\lemminx.exe"; ` +
				`$old=$env:PATH; ` +
				`[Environment]::SetEnvironmentVariable("PATH","$dir;$old","User")`})
		} else {
			lemminx_install := _clone_strs({"sh", "-c",
				`set -e; ` +
				`DEST="$HOME/.local/bin"; mkdir -p "$DEST"; ` +
				`OS=$(uname -s); ` +
				`if [ "$OS" = "Darwin" ]; then SUFFIX=osx; else SUFFIX=linux; fi; ` +
				`URL="https://github.com/eclipse/lemminx/releases/latest/download/lemminx-$SUFFIX"; ` +
				`curl -fsSL "$URL" -o "$DEST/lemminx" || wget -qO "$DEST/lemminx" "$URL"; ` +
				`chmod +x "$DEST/lemminx"; ` +
				`echo "Installed: $DEST/lemminx"`})
		}
		lsp_manager_register(m, Server_Config{
			name          = strings.clone("lemminx"),
			command       = _clone_strs({"lemminx"}),
			extensions    = _clone_strs({"xml", "pom", "xsd", "xsl", "xslt", "svg", "html", "htm"}),
			install_cmd   = lemminx_install,
			install_label = strings.clone("Downloading LemMinX (XML Language Server)..."),
		})
	}
}

// ---------------------------------------------------------------------------
// Java (jdtls) — full configuration
// ---------------------------------------------------------------------------

_make_jdtls_config :: proc(root_path: string) -> Server_Config {
	// Workspace data dir: ~/.cache/jdtls/workspace/<simple hash of root>
	hash := _simple_hash(root_path)
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" { home = os.get_env("USERPROFILE", context.temp_allocator) }
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

	// Auto-install: `pip3 install jdtls` installs a Python wrapper that
	// bundles the Eclipse JDT LS jar. Requires Java 17+ already on PATH.
	when ODIN_OS == .Windows {
		install := _clone_strs({"powershell", "-NoProfile", "-Command",
			`pip3 install jdtls; ` +
			`if ($LASTEXITCODE -ne 0) { pip install jdtls }`})
	} else {
		install := _clone_strs({"sh", "-c",
			`pip3 install jdtls 2>&1 || pip install jdtls 2>&1; ` +
			`echo "Note: Java 17+ must be on PATH for jdtls to start."`})
	}

	return Server_Config{
		name          = strings.clone("jdtls"),
		command       = _clone_strs(cmd),
		extensions    = _clone_strs({"java"}),
		init_options  = strings.clone(init_opts),
		install_cmd   = install,
		install_label = strings.clone("Installing jdtls via pip3 (requires Java 17+)..."),
	}
}

// Simple djb2-style hash for workspace directory name.
_simple_hash :: proc(s: string) -> u32 {
	h: u32 = 5381
	for c in s { h = h * 33 ~ u32(c) }
	return h
}

// ---------------------------------------------------------------------------
// Poll running install jobs — call once per frame from editor update loop
// ---------------------------------------------------------------------------

// Returns true if any server just finished installing (caller may want to retry open).
lsp_manager_update_installs :: proc(m: ^LSP_Manager) -> (any_finished: bool) {
	for &e in m.entries {
		if e.install_state != .Running { continue }
		exited, success := install_job_poll(&e.install_job, &e.install_output)
		if exited {
			if success {
				e.install_state = .Done
				log_writef("INF", fmt.tprintf("installed '%s' successfully", e.config.name))
				append(&e.install_output, ..transmute([]u8)string("\n✓ Done. Restart server via LSP Control (Ctrl+Shift+L).\n"))
			} else {
				e.install_state = .Failed
				log_writef("ERR", fmt.tprintf("install of '%s' failed — check LSP dialog for output", e.config.name))
				append(&e.install_output, ..transmute([]u8)string("\n✗ Install failed. Check output above.\n"))
			}
			any_finished = true
		}
	}
	return
}

// ---- Install info struct (returned to UI) ----------------------------------

Install_Info :: struct {
	state:       Install_State,
	output:      string, // points into entry's install_output — valid until next update
	label:       string, // install label text
	has_install: bool,   // install_cmd is defined
	server_name: string, // name of the server
}

// Get install info for a file's extension (for UI display).
lsp_manager_install_info_for_path :: proc(m: ^LSP_Manager, path: string) -> Install_Info {
	ext := path_ext(path)
	for &e in m.entries {
		for ex in e.config.extensions {
			if ex != ext { continue }
			return Install_Info{
				state       = e.install_state,
				output      = string(e.install_output[:]),
				label       = e.config.install_label,
				has_install = len(e.config.install_cmd) > 0,
				server_name = e.config.name,
			}
		}
	}
	return {}
}

// Get install status for a server name (for UI display).
lsp_manager_install_state :: proc(m: ^LSP_Manager, server_name: string) -> (state: Install_State, output: string) {
	for &e in m.entries {
		if e.config.name == server_name {
			return e.install_state, string(e.install_output[:])
		}
	}
	return .None, ""
}

// Trigger install for a server by name. Returns false if no install command defined.
lsp_manager_trigger_install :: proc(m: ^LSP_Manager, server_name: string) -> bool {
	for &e in m.entries {
		if e.config.name != server_name { continue }
		if len(e.config.install_cmd) == 0 { return false }
		if e.install_state == .Running { return true } // already running
		if e.install_job.active { install_job_kill(&e.install_job) }
		clear(&e.install_output)
		label := e.config.install_label if e.config.install_label != "" else fmt.tprintf("Installing %s...", e.config.name)
		append(&e.install_output, ..transmute([]u8)label)
		append(&e.install_output, '\n')
		job, ok := install_job_start(e.config.install_cmd)
		if ok {
			e.install_job   = job
			e.install_state = .Running
			return true
		}
		e.install_state = .Failed
		append(&e.install_output, ..transmute([]u8)string("Failed to spawn installer process\n"))
		return false
	}
	return false
}

// ---------------------------------------------------------------------------
// Look up client for a file extension — start if not running
// ---------------------------------------------------------------------------

// Find or start a client for the given file path; detects project root automatically.
lsp_manager_get_client_for_path :: proc(m: ^LSP_Manager, path: string) -> ^Language_Client {
	ext  := path_ext(path)
	root := _project_root_for_file(path)
	for &e in m.entries {
		for ex in e.config.extensions {
			if ex == ext { return _start_rooted_client(&e, root) }
		}
	}
	return nil
}

// Read-only lookup — never starts a server. Safe to call from render path.
lsp_manager_find_client_for_path :: proc(m: ^LSP_Manager, path: string) -> ^Language_Client {
	ext := path_ext(path)
	for &e in m.entries {
		for ex in e.config.extensions {
			if ex == ext { return _find_rooted_client(&e, path) }
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// High-level file events — called from editor integration
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// High-level file events — use find (read-only); server must be started
// explicitly via lsp_manager_start_for_path.
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
		for &rc in e.clients {
			client_update(rc.client)
			completion_manager_update(rc.client)
		}
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

manager_code_actions :: proc(m: ^LSP_Manager, path: string, line, char: int, cb: Response_Callback) {
	c := lsp_manager_find_client_for_path(m, path)
	if c == nil || !c.caps.has_code_actions { return }
	uri := path_to_uri(path)
	params := strings.concatenate({
		`{"textDocument":{"uri":`, json_str(uri),
		`},"range":{"start":{"line":`, fmt.tprintf("%d", line),
		`,"character":`, fmt.tprintf("%d", char),
		`},"end":{"line":`, fmt.tprintf("%d", line),
		`,"character":`, fmt.tprintf("%d", char),
		`}},"context":{"diagnostics":[]}}`,
	}, context.temp_allocator)
	client_send_request(c, "textDocument/codeAction", params, cb)
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

// Start LSP for the given file — detects project root automatically.
lsp_manager_start_for_path :: proc(m: ^LSP_Manager, path: string) -> (ok: bool, err: string) {
	ext  := path_ext(path)
	root := _project_root_for_file(path)
	for &e in m.entries {
		for ex in e.config.extensions {
			if ex != ext { continue }
			// Check if already running for this root
			for &rc in e.clients {
				if rc.root == root {
					switch rc.client.state {
					case .Running:              return false, "already running — use Restart"
					case .Initializing, .Starting: return false, "already starting"
					case .Created, .Shutting_Down, .Stopped:
						client_destroy(rc.client)
						rc.client = nil
						// Remove and restart below
					}
					// Remove the dead entry
					ordered_remove(&e.clients, (int)(uintptr(rawptr(&rc)) - uintptr(rawptr(&e.clients[0]))) / size_of(Rooted_Client))
					break
				}
			}
			c := _start_rooted_client(&e, root)
			if c == nil {
				switch e.install_state {
				case .Running:
					return false, fmt.tprintf("installing '%s'... open LSP Control to watch progress", e.config.name)
				case .Done:
					return false, fmt.tprintf("'%s' installed — starting server...", e.config.name)
				case .Failed:
					return false, fmt.tprintf("auto-install of '%s' failed — see LSP Control for output", e.config.name)
				case .None:
					return false, fmt.tprintf("'%s' not found on PATH — LSP Control (Ctrl+Shift+L) → Install", e.config.name)
				}
			}
			return true, ""
		}
	}
	return false, fmt.tprintf("no server for '.%s' files", ext)
}

// Stop LSP client for the given file's project root.
lsp_manager_stop_for_path :: proc(m: ^LSP_Manager, path: string) -> (ok: bool, err: string) {
	ext  := path_ext(path)
	root := _project_root_for_file(path)
	for &e in m.entries {
		for ex in e.config.extensions {
			if ex != ext { continue }
			for i in 0 ..< len(e.clients) {
				rc := &e.clients[i]
				if rc.root == root {
					client_destroy(rc.client)
					delete(rc.root)
					ordered_remove(&e.clients, i)
					return true, ""
				}
			}
			return false, "server not running for this project"
		}
	}
	return false, fmt.tprintf("no server for '.%s' files", ext)
}

// Restart LSP for the given file's project root.
lsp_manager_restart_for_path :: proc(m: ^LSP_Manager, path: string) -> (ok: bool, err: string) {
	lsp_manager_stop_for_path(m, path)
	return lsp_manager_start_for_path(m, path)
}
