package editor

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import lsp  "./lsp"
import conf "./config"

// ---------------------------------------------------------------------------
// Per-pane LSP state
// ---------------------------------------------------------------------------

Pane_LSP :: struct {
	change_timer:    f32,
	change_pending:  bool,
	hover_timer:     f32,
	hover_pending:   bool,
	last_hover_line: int,
	last_hover_char: int,
	show_hover:      bool,
	show_sig_help:   bool,
}

CHANGE_DEBOUNCE :: f32(0.30)
HOVER_DEBOUNCE  :: f32(0.50)

pane_lsp_destroy :: proc(pl: ^Pane_LSP) {
	pl^ = {}
}

// ---------------------------------------------------------------------------
// Init / destroy
// ---------------------------------------------------------------------------

lsp_init :: proc(e: ^Editor) {
	root := _lsp_find_root(e)
	lsp.lsp_manager_init(&e.lsp_mgr, root)
	_register_lsp_from_config(e)
}

_register_lsp_from_config :: proc(e: ^Editor) {
	for &srv in e.cfg.lsp.servers {
		if !srv.enabled { continue }
		if srv.command == "" { continue }

		// Map language IDs → file extensions (without leading dot)
		exts: [dynamic]string
		for lang_id in srv.languages {
			lc := conf.registry_lang_by_id(&e.registry, lang_id)
			if lc != nil {
				for ext in lc.extensions {
					bare := ext
					if len(bare) > 0 && bare[0] == '.' { bare = bare[1:] }
					append(&exts, strings.clone(bare))
				}
			} else {
				// No language config — treat lang ID itself as extension
				append(&exts, strings.clone(lang_id))
			}
		}
		if len(exts) == 0 { delete(exts); continue }

		// Build command + args slice (heap-owned)
		cmd := make([]string, 1 + len(srv.args))
		cmd[0] = strings.clone(srv.command)
		for a, i in srv.args { cmd[i+1] = strings.clone(a) }

		// Look up auto-install command for known server IDs
		inst_cmd, inst_label := _install_cmd_for_id(srv.id)

		// Transfer ownership of cmd and exts backing arrays to lsp manager
		lsp.lsp_manager_register(&e.lsp_mgr, lsp.Server_Config{
			name          = strings.clone(srv.name),
			command       = cmd,
			extensions    = exts[:],
			init_options  = strings.clone(srv.init_options),
			install_cmd   = inst_cmd,
			install_label = inst_label,
		})
		// exts header goes out of scope; backing array now owned by Server_Config
	}
}

// Map well-known server IDs to install commands (cross-platform).
//
// Every server is downloaded/built directly into its own editor-owned
// directory (lsp.lsp_home_dir(id) — ~/.config/editor/lsp/<id>/ on
// Linux/macOS, %LOCALAPPDATA%\editor\lsp\<id>\ on Windows) and never
// touches the user's global PATH, pip/npm/dotnet-tool/rustup install
// locations, or a system package manager. lsp.manager resolves the
// produced binary by absolute path (see server_binary_exists), so no
// PATH mutation is ever required.
_install_cmd_for_id :: proc(id: string) -> (cmd: []string, label: string) {
	_s :: proc(strs: []string) -> []string {
		out := make([]string, len(strs))
		for s, i in strs { out[i] = strings.clone(s) }
		return out
	}
	// NOTE: install scripts are built with strings.concatenate, not fmt.tprintf —
	// fmt.tprintf treats bare '{' as the start of a Python-style format spec
	// (see core:fmt/doc.odin), which corrupts any script needing literal braces
	// (e.g. jdtls's `{ ...; } > file` shell grouping). concatenate does no
	// verb/brace parsing at all, so it's the only safe way to splice `dest` in.
	switch id {
	case "pylsp":
		dest := lsp.lsp_home_dir("pylsp")
		when ODIN_OS == .Windows {
			cmd_str := strings.concatenate({
				`$DEST="`, dest, `"; New-Item -ItemType Directory -Force -Path $DEST | Out-Null; ` +
				`python -m venv "$DEST\venv"; ` +
				`& "$DEST\venv\Scripts\pip.exe" install python-lsp-server; ` +
				`Copy-Item "$DEST\venv\Scripts\pylsp.exe" "$DEST\pylsp.exe" -Force`,
			})
			return _s({"powershell", "-NoProfile", "-Command", cmd_str}),
			       strings.clone("Installing pylsp into editor-local venv...")
		} else {
			cmd_str := strings.concatenate({
				`set -e; DEST="`, dest, `"; mkdir -p "$DEST"; ` +
				`PY=python3; command -v python3 >/dev/null 2>&1 || PY=python; ` +
				`"$PY" -m venv "$DEST/venv"; ` +
				`"$DEST/venv/bin/pip" install --upgrade pip >/dev/null 2>&1 || true; ` +
				`"$DEST/venv/bin/pip" install python-lsp-server; ` +
				`ln -sf "$DEST/venv/bin/pylsp" "$DEST/pylsp"; ` +
				`echo "Installed: $DEST/pylsp"`,
			})
			return _s({"sh", "-c", cmd_str}),
			       strings.clone("Installing pylsp into editor-local venv...")
		}
	case "gopls":
		dest := lsp.lsp_home_dir("gopls")
		when ODIN_OS == .Windows {
			cmd_str := strings.concatenate({
				`$DEST="`, dest, `"; New-Item -ItemType Directory -Force -Path $DEST | Out-Null; ` +
				`$env:GOBIN=$DEST; go install golang.org/x/tools/gopls@latest`,
			})
			return _s({"powershell", "-NoProfile", "-Command", cmd_str}),
			       strings.clone("Installing gopls into editor-local dir...")
		} else {
			cmd_str := strings.concatenate({
				`set -e; DEST="`, dest, `"; mkdir -p "$DEST"; ` +
				`GOBIN="$DEST" go install golang.org/x/tools/gopls@latest; ` +
				`echo "Installed: $DEST/gopls"`,
			})
			return _s({"sh", "-c", cmd_str}),
			       strings.clone("Installing gopls into editor-local dir...")
		}
	case "rust-analyzer":
		dest := lsp.lsp_home_dir("rust-analyzer")
		when ODIN_OS == .Windows {
			cmd_str := strings.concatenate({
				`$DEST="`, dest, `"; New-Item -ItemType Directory -Force -Path $DEST | Out-Null; ` +
				`$url="https://github.com/rust-lang/rust-analyzer/releases/latest/download/rust-analyzer-x86_64-pc-windows-msvc.gz"; ` +
				`Invoke-WebRequest -Uri $url -OutFile "$DEST\ra.gz"; ` +
				`$in=New-Object System.IO.FileStream("$DEST\ra.gz",[IO.FileMode]::Open); ` +
				`$out=New-Object System.IO.FileStream("$DEST\rust-analyzer.exe",[IO.FileMode]::Create); ` +
				`$gz=New-Object System.IO.Compression.GZipStream($in,[IO.Compression.CompressionMode]::Decompress); ` +
				`$gz.CopyTo($out); $gz.Close(); $out.Close(); $in.Close(); Remove-Item "$DEST\ra.gz"`,
			})
			return _s({"powershell", "-NoProfile", "-Command", cmd_str}),
			       strings.clone("Downloading rust-analyzer into editor-local dir...")
		} else {
			cmd_str := strings.concatenate({
				`set -e; DEST="`, dest, `"; mkdir -p "$DEST"; ` +
				`OS=$(uname -s); ARCH=$(uname -m); ` +
				`if [ "$OS" = "Darwin" ]; then ` +
				`  if [ "$ARCH" = "arm64" ]; then TARGET=aarch64-apple-darwin; else TARGET=x86_64-apple-darwin; fi; ` +
				`else ` +
				`  if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then TARGET=aarch64-unknown-linux-gnu; else TARGET=x86_64-unknown-linux-gnu; fi; ` +
				`fi; ` +
				`URL="https://github.com/rust-lang/rust-analyzer/releases/latest/download/rust-analyzer-$TARGET.gz"; ` +
				`curl -fsSL "$URL" | gunzip -c > "$DEST/rust-analyzer"; ` +
				`chmod +x "$DEST/rust-analyzer"; echo "Installed: $DEST/rust-analyzer"`,
			})
			return _s({"sh", "-c", cmd_str}),
			       strings.clone("Downloading rust-analyzer into editor-local dir...")
		}
	case "typescript-language-server":
		dest := lsp.lsp_home_dir("typescript-language-server")
		when ODIN_OS == .Windows {
			cmd_str := strings.concatenate({
				`$DEST="`, dest, `"; New-Item -ItemType Directory -Force -Path $DEST | Out-Null; ` +
				`npm install --prefix "$DEST" typescript-language-server typescript; ` +
				`Copy-Item "$DEST\node_modules\.bin\typescript-language-server.cmd" "$DEST\typescript-language-server.cmd" -Force`,
			})
			return _s({"powershell", "-NoProfile", "-Command", cmd_str}),
			       strings.clone("Installing typescript-language-server into editor-local dir...")
		} else {
			cmd_str := strings.concatenate({
				`set -e; DEST="`, dest, `"; mkdir -p "$DEST"; ` +
				`npm install --prefix "$DEST" typescript-language-server typescript; ` +
				`ln -sf "$DEST/node_modules/.bin/typescript-language-server" "$DEST/typescript-language-server"; ` +
				`echo "Installed: $DEST/typescript-language-server"`,
			})
			return _s({"sh", "-c", cmd_str}),
			       strings.clone("Installing typescript-language-server into editor-local dir...")
		}
	case "jdtls":
		dest := lsp.lsp_home_dir("jdtls")
		when ODIN_OS == .Windows {
			cmd_str := strings.concatenate({
				`winget install --silent EclipseAdoptium.Temurin.21.JDK; ` +
				`$DEST="`, dest, `"; New-Item -ItemType Directory -Force -Path $DEST | Out-Null; ` +
				`$url="https://download.eclipse.org/jdtls/snapshots/jdt-language-server-latest.tar.gz"; ` +
				`Invoke-WebRequest -Uri $url -OutFile "$DEST\jdtls.tar.gz"; ` +
				`tar -xzf "$DEST\jdtls.tar.gz" -C "$DEST"; Remove-Item "$DEST\jdtls.tar.gz"; ` +
				`$jar=(Get-ChildItem "$DEST\plugins\org.eclipse.equinox.launcher_*.jar" | Select-Object -First 1).FullName; ` +
				`$launcher = 'java -Declipse.application=org.eclipse.jdt.ls.core.id1 -Dosgi.bundles.defaultStartLevel=4 -Declipse.product=org.eclipse.jdt.ls.core.product -Dlog.level=ALL -noverify -Xmx1G --add-modules=ALL-SYSTEM --add-opens java.base/java.util=ALL-UNNAMED --add-opens java.base/java.lang=ALL-UNNAMED -jar "{0}" -configuration "{1}\config_win" %*' -f $jar, $DEST; ` +
				`Set-Content -Path "$DEST\jdtls.cmd" -Value $launcher`,
			})
			return _s({"powershell", "-NoProfile", "-Command", cmd_str}),
			       strings.clone("Installing jdtls into editor-local dir (requires Java 17+)...")
		} else {
			cmd_str := strings.concatenate({
				`set -e; DEST="`, dest, `"; mkdir -p "$DEST"; ` +
				`URL="https://download.eclipse.org/jdtls/snapshots/jdt-language-server-latest.tar.gz"; ` +
				`curl -fsSL "$URL" -o "$DEST/jdtls.tar.gz"; ` +
				`tar -xzf "$DEST/jdtls.tar.gz" -C "$DEST"; rm -f "$DEST/jdtls.tar.gz"; ` +
				`CONF=config_linux; [ "$(uname -s)" = "Darwin" ] && CONF=config_mac; ` +
				`JAR=$(ls "$DEST"/plugins/org.eclipse.equinox.launcher_*.jar | head -1); ` +
				`{ echo '#!/bin/sh'; ` +
				`  echo "exec java -Declipse.application=org.eclipse.jdt.ls.core.id1 -Dosgi.bundles.defaultStartLevel=4 -Declipse.product=org.eclipse.jdt.ls.core.product -Dlog.level=ALL -noverify -Xmx1G --add-modules=ALL-SYSTEM --add-opens java.base/java.util=ALL-UNNAMED --add-opens java.base/java.lang=ALL-UNNAMED -jar \"$JAR\" -configuration \"$DEST/$CONF\" \"\$@\""; ` +
				`} > "$DEST/jdtls"; ` +
				`chmod +x "$DEST/jdtls"; echo "Installed: $DEST/jdtls"`,
			})
			return _s({"sh", "-c", cmd_str}),
			       strings.clone("Installing jdtls into editor-local dir (requires Java 17+)...")
		}
	case "lua-language-server":
		dest := lsp.lsp_home_dir("lua-language-server")
		when ODIN_OS == .Windows {
			cmd_str := strings.concatenate({
				`$DEST="`, dest, `"; New-Item -ItemType Directory -Force -Path $DEST | Out-Null; ` +
				`$url="https://github.com/LuaLS/lua-language-server/releases/latest/download/lua-language-server-win32-x64.zip"; ` +
				`Invoke-WebRequest -Uri $url -OutFile "$DEST\luals.zip"; ` +
				`Expand-Archive -Force "$DEST\luals.zip" "$DEST\extracted"; ` +
				`Copy-Item "$DEST\extracted\bin\lua-language-server.exe" "$DEST\lua-language-server.exe" -Force`,
			})
			return _s({"powershell", "-NoProfile", "-Command", cmd_str}),
			       strings.clone("Downloading lua-language-server into editor-local dir...")
		} else {
			cmd_str := strings.concatenate({
				`set -e; DEST="`, dest, `"; mkdir -p "$DEST"; ` +
				`OS=$(uname -s); ARCH=$(uname -m); ` +
				`if [ "$OS" = "Darwin" ]; then PLAT=darwin; else PLAT=linux; fi; ` +
				`if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then ARCH=arm64; else ARCH=x64; fi; ` +
				`URL="https://github.com/LuaLS/lua-language-server/releases/latest/download/lua-language-server-$PLAT-$ARCH.tar.gz"; ` +
				`TMP=$(mktemp -d); curl -fsSL "$URL" | tar -xz -C "$TMP"; ` +
				`cp "$TMP/bin/lua-language-server" "$DEST/lua-language-server"; ` +
				`chmod +x "$DEST/lua-language-server"; rm -rf "$TMP"; echo "Installed: $DEST/lua-language-server"`,
			})
			return _s({"sh", "-c", cmd_str}),
			       strings.clone("Downloading lua-language-server into editor-local dir...")
		}
	case "zls":
		dest := lsp.lsp_home_dir("zls")
		when ODIN_OS == .Windows {
			cmd_str := strings.concatenate({
				`$DEST="`, dest, `"; New-Item -ItemType Directory -Force -Path $DEST | Out-Null; ` +
				`$url="https://github.com/zigtools/zls/releases/latest/download/zls-x86_64-windows.zip"; ` +
				`Invoke-WebRequest -Uri $url -OutFile "$DEST\zls.zip"; ` +
				`Expand-Archive -Force "$DEST\zls.zip" "$DEST\extracted"; ` +
				`Copy-Item "$DEST\extracted\zls.exe" "$DEST\zls.exe" -Force`,
			})
			return _s({"powershell", "-NoProfile", "-Command", cmd_str}),
			       strings.clone("Downloading zls into editor-local dir...")
		} else {
			cmd_str := strings.concatenate({
				`set -e; DEST="`, dest, `"; mkdir -p "$DEST"; ` +
				`ARCH=$(uname -m); OS=$(uname -s | tr A-Z a-z); ` +
				`if [ "$OS" = "darwin" ]; then OS=macos; fi; ` +
				`URL="https://github.com/zigtools/zls/releases/latest/download/zls-$ARCH-$OS.tar.xz"; ` +
				`curl -fsSL "$URL" | tar -xJ -C "$DEST" zls; ` +
				`chmod +x "$DEST/zls"; echo "Installed: $DEST/zls"`,
			})
			return _s({"sh", "-c", cmd_str}),
			       strings.clone("Downloading zls into editor-local dir...")
		}
	case "lemminx":
		dest := lsp.lsp_home_dir("lemminx")
		when ODIN_OS == .Windows {
			cmd_str := strings.concatenate({
				`$DEST="`, dest, `"; New-Item -ItemType Directory -Force -Path $DEST | Out-Null; ` +
				`$url="https://github.com/eclipse/lemminx/releases/latest/download/lemminx-win32.exe"; ` +
				`Invoke-WebRequest -Uri $url -OutFile "$DEST\lemminx.exe"`,
			})
			return _s({"powershell", "-NoProfile", "-Command", cmd_str}),
			       strings.clone("Downloading LemMinX into editor-local dir...")
		} else {
			cmd_str := strings.concatenate({
				`set -e; DEST="`, dest, `"; mkdir -p "$DEST"; ` +
				`OS=$(uname -s); if [ "$OS" = "Darwin" ]; then SUFFIX=osx; else SUFFIX=linux; fi; ` +
				`URL="https://github.com/eclipse/lemminx/releases/latest/download/lemminx-$SUFFIX"; ` +
				`curl -fsSL "$URL" -o "$DEST/lemminx" || wget -qO "$DEST/lemminx" "$URL"; ` +
				`chmod +x "$DEST/lemminx"; echo "Installed: $DEST/lemminx"`,
			})
			return _s({"sh", "-c", cmd_str}),
			       strings.clone("Downloading LemMinX into editor-local dir...")
		}
	case "csharp-ls":
		dest := lsp.lsp_home_dir("csharp-ls")
		when ODIN_OS == .Windows {
			cmd_str := strings.concatenate({
				`$DEST="`, dest, `"; New-Item -ItemType Directory -Force -Path $DEST | Out-Null; ` +
				`dotnet tool install --tool-path "$DEST" csharp-ls`,
			})
			return _s({"powershell", "-NoProfile", "-Command", cmd_str}),
			       strings.clone("Installing csharp-ls into editor-local dir...")
		} else {
			cmd_str := strings.concatenate({
				`set -e; DEST="`, dest, `"; mkdir -p "$DEST"; ` +
				`dotnet tool install --tool-path "$DEST" csharp-ls; ` +
				`echo "Installed: $DEST/csharp-ls"`,
			})
			return _s({"sh", "-c", cmd_str}),
			       strings.clone("Installing csharp-ls into editor-local dir...")
		}
	}
	return nil, ""
}

lsp_destroy :: proc(e: ^Editor) {
	lsp.lsp_manager_destroy(&e.lsp_mgr)
	for &p in e.panes { pane_lsp_destroy(&p.lsp) }
}

_lsp_find_root :: proc(e: ^Editor) -> string {
	// Always start from the CWD so we have an absolute reference.
	cwd, cwd_err := os.get_working_directory(context.temp_allocator)
	if cwd_err != nil || len(cwd) == 0 { cwd = "." }

	p := active_pane(e)
	search := cwd // directory to start searching from
	if p.filename != "" {
		// p.filename is absolute (guaranteed by pane_open → _pane_abs).
		search = _path_dirname(p.filename)
	}

	markers := [?]string{"ols.json","Cargo.toml","go.mod","pom.xml","build.gradle",".git","package.json"}
	dir := search
	best := ""
	// Keep climbing past the first marker match, all the way up to (but not
	// above) the opened workspace root, remembering the OUTERMOST directory
	// that has one — a multi-module Maven/Gradle project has a pom.xml in
	// every submodule, and stopping at the first (innermost) one picks the
	// submodule instead of the true reactor root the LSP needs to resolve
	// inter-module dependencies. len(dir) >= len(cwd) bounds the climb to
	// stay within the workspace the user actually opened.
	for dir != "" && dir != "/" && len(dir) >= len(cwd) {
		for marker in markers {
			if _file_exists(fmt.tprintf("%s/%s", dir, marker)) { best = dir; break }
		}
		parent := _path_dirname(dir)
		if parent == dir || parent == "" { break } // guard against infinite loop
		dir = parent
	}
	if best != "" { return best }
	return search // file's dir (or CWD) if no marker found
}

// ---------------------------------------------------------------------------
// Per-frame update
// ---------------------------------------------------------------------------

lsp_update :: proc(e: ^Editor, dt: f32) {
	lsp.lsp_manager_update(&e.lsp_mgr)
	if lsp.lsp_manager_update_installs(&e.lsp_mgr) {
		// A server just finished installing — try to start it for any open pane
		for i in 0..<len(e.panes) {
			p := &e.panes[i]
			if p.filename != "" { lsp_on_open(e, p) }
		}
	}

	for i in 0..<len(e.panes) {
		p := &e.panes[i]
		if p.filename == "" { continue }
		_pane_lsp_update(e, p, dt)
	}
}

_pane_lsp_update :: proc(e: ^Editor, p: ^Pane, dt: f32) {
	if p.lsp.change_pending {
		p.lsp.change_timer += dt
		if p.lsp.change_timer >= CHANGE_DEBOUNCE {
			p.lsp.change_pending = false
			p.lsp.change_timer   = 0
			_flush_change(e, p)
		}
	}

	if p.lsp.hover_pending {
		p.lsp.hover_timer += dt
		if p.lsp.hover_timer >= HOVER_DEBOUNCE {
			p.lsp.hover_pending = false
			p.lsp.hover_timer   = 0
			_flush_hover(e, p)
		}
	}

	// Sync suggest widget and hover state every frame
	c := _get_client(e, p)
	if c != nil {
		_sync_suggest_widget(p, c)
		_, hover_ready := lsp.hover_get_result(c)
		p.lsp.show_hover = hover_ready
	}
}

_flush_change :: proc(e: ^Editor, p: ^Pane) {
	content := buffer_to_string(&p.buf)
	defer delete(content)
	lsp.manager_did_change_full(&e.lsp_mgr, p.filename, content)
}

_flush_hover :: proc(e: ^Editor, p: ^Pane) {
	lsp.manager_hover(&e.lsp_mgr, p.filename, p.lsp.last_hover_line, p.lsp.last_hover_char)
}

// ---------------------------------------------------------------------------
// Editor event hooks
// ---------------------------------------------------------------------------

lsp_on_open :: proc(e: ^Editor, p: ^Pane) {
	if p.filename == "" { return }
	content := buffer_to_string(&p.buf)
	defer delete(content)
	lsp.manager_did_open(&e.lsp_mgr, p.filename, content)
}

lsp_on_close :: proc(e: ^Editor, p: ^Pane) {
	if p.filename == "" { return }
	lsp.manager_did_close(&e.lsp_mgr, p.filename)
}

lsp_on_text_changed :: proc(e: ^Editor, p: ^Pane) {
	if p.filename == "" { return }
	p.lsp.change_pending = true
	p.lsp.change_timer   = 0

	c  := _get_client(e, p)
	ch := _char_before_cursor(p)

	if _is_ident_char(ch) {
		// Starting a new completion session: flush immediately so server sees current doc.
		if c != nil && !c.completion.session.active {
			_flush_change(e, p)
			p.lsp.change_pending = false
		}
		_maybe_trigger_completion(e, p, ch, false)
	} else if c != nil && _is_trigger_char(e, p, ch) {
		// Trigger char always starts a new session.
		_flush_change(e, p)
		p.lsp.change_pending = false
		_maybe_trigger_completion(e, p, ch, true)
	} else {
		if c != nil { lsp.completion_cancel(c) }
		p.suggest.visible = false
	}

	// Signature help on ( or ,
	if ch == '(' || ch == ',' {
		if c != nil {
			_flush_change(e, p)
			p.lsp.change_pending = false
		}
		line, char := _cursor_lsp_pos(p)
		lsp.manager_sig_help(&e.lsp_mgr, p.filename, line, char)
		p.lsp.show_sig_help = true
	} else if ch == ')' {
		if c != nil { lsp.sig_help_clear(c) }
		p.lsp.show_sig_help = false
	}
}

lsp_on_cursor_moved :: proc(e: ^Editor, p: ^Pane) {
	if p.filename == "" { return }
	c := _get_client(e, p)
	if c != nil { lsp.hover_clear(c) } // discard stale result for old position
	line, char := _cursor_lsp_pos(p)
	p.lsp.last_hover_line = line
	p.lsp.last_hover_char = char
	p.lsp.hover_pending   = true
	p.lsp.hover_timer     = 0
	p.lsp.show_hover      = false
}

lsp_on_save :: proc(e: ^Editor, p: ^Pane) {
	if p.filename == "" { return }
	content := buffer_to_string(&p.buf)
	defer delete(content)
	lsp.manager_did_save(&e.lsp_mgr, p.filename, content)
}

// Re-register all currently open panes with a freshly started server.
// Called after dialog Start/Restart so the server receives didOpen for every file.
lsp_reopen_all_panes :: proc(e: ^Editor) {
	for i in 0..<len(e.panes) {
		p := &e.panes[i]
		if p.filename == "" { continue }
		content := buffer_to_string(&p.buf)
		defer delete(content)
		lsp.manager_did_open(&e.lsp_mgr, p.filename, content)
	}
}

lsp_trigger_completion_manual :: proc(e: ^Editor, p: ^Pane) {
	if p.filename == "" { return }
	prefix := _word_before_cursor(p)
	line, char := _cursor_lsp_pos(p)
	lsp.manager_completion(&e.lsp_mgr, p.filename, line, char, .Invoked, 0, prefix)
}

// Apply selected completion item.
lsp_completion_accept :: proc(e: ^Editor, p: ^Pane) -> bool {
	c := _get_client(e, p)
	if c == nil { return false }
	item := lsp.completion_selected_item(c)
	if item == nil { return false }

	insert_text := item.insert_text
	if insert_text == "" { insert_text = item.label }
	if insert_text == "" { return false }

	// additionalTextEdits (e.g. auto-import) target positions elsewhere in the
	// document — apply them before the primary insertText so cursor-relative
	// offsets below are computed against the post-import buffer state.
	if len(item.additional_edits) > 0 {
		_apply_additional_edits(p, item.additional_edits)
	}

	prefix := _word_before_cursor(p)
	if len(prefix) > 0 { pane_delete_backward(p, len(prefix)) }
	pane_insert_str(p, insert_text)

	lsp.completion_cancel(c)
	p.suggest.visible    = false
	// Buffer was modified — notify LSP on next debounce tick
	p.lsp.change_pending = true
	p.lsp.change_timer   = 0
	return true
}

// Apply additionalTextEdits from a completion item (e.g. jdtls's auto-import,
// which adds the missing `import` line). These edits target lines elsewhere
// in the document (typically the import section, above the cursor), so after
// applying them we shift the cursor by their net byte delta to keep it at
// the same logical spot the user was typing at.
_apply_additional_edits :: proc(p: ^Pane, edits: []lsp.TextEdit) {
	first := true
	// Reverse order: keeps earlier edits' line/col positions valid, since
	// applying a later (higher-offset) edit first can't shift anything before it.
	for i := len(edits) - 1; i >= 0; i -= 1 {
		ed := edits[i]
		start_off := _lsp_pos_to_offset(p, ed.range.start.line, ed.range.start.character)
		end_off   := _lsp_pos_to_offset(p, ed.range.end.line, ed.range.end.character)
		if end_off < start_off { end_off = start_off }
		end_off = min(end_off, buffer_len(&p.buf))

		old_len := end_off - start_off
		new_len := len(ed.new_text)

		if end_off > start_off {
			del := make([]u8, old_len, context.temp_allocator)
			for i2 in 0..<old_len { del[i2] = buffer_get_byte(&p.buf, start_off + i2) }
			undo_push_mc(p, false, start_off, del, first)
			first = false
			buffer_delete(&p.buf, start_off, old_len)
		}
		if new_len > 0 {
			undo_push_mc(p, true, start_off, transmute([]u8)ed.new_text, first)
			first = false
			buffer_insert_string(&p.buf, start_off, ed.new_text)
		}

		if start_off <= p.cursor {
			p.cursor    += new_len - old_len
			p.sel_anchor = p.cursor
		}
	}
	undo_break(p)
	p.dirty = true
}

// LSP-aware Go To Definition. Falls back to local search if no server.
lsp_goto_definition :: proc(e: ^Editor, p: ^Pane) {
	if p.filename == "" { goto_def_do(e); return }
	c := _get_client(e, p)
	if c == nil || !c.caps.has_definition { goto_def_do(e); return }

	line, char := _cursor_lsp_pos(p)
	lsp.manager_definition(&e.lsp_mgr, p.filename, line, char, lsp.Response_Callback{
		proc_ = _on_definition_response,
		user  = e,
	})
}

_on_definition_response :: proc(c: ^lsp.Language_Client, result: json.Value, error: json.Value, user: rawptr) {
	defer json.destroy_value(result)
	defer json.destroy_value(error)
	if error != nil { return }
	e := cast(^Editor)user
	_navigate_to_lsp_location(e, result)
}

_navigate_to_lsp_location :: proc(e: ^Editor, result: json.Value) {
	#partial switch v in result {
	case json.Array:
		if len(v) == 0 { return }
		_navigate_to_lsp_location(e, v[0])
	case json.Object:
		uri_str, has_uri := lsp.json_obj_str(v, "uri")
		if !has_uri { uri_str, has_uri = lsp.json_obj_str(v, "targetUri") }
		if !has_uri { return }

		path := lsp.uri_to_path(uri_str)
		line := 0

		if r_obj, has_r := lsp.json_obj_obj(v, "range"); has_r {
			r := lsp.parse_range(r_obj)
			line = r.start.line
		} else if r_obj, has_r := lsp.json_obj_obj(v, "targetSelectionRange"); has_r {
			r := lsp.parse_range(r_obj)
			line = r.start.line
		}

		nav_push(&e.nav_hist, e)
		if !editor_open(e, path) { return }
		ap := active_pane(e)
		ls := buffer_line_start(&ap.buf, line)
		ap.cursor     = ls
		ap.sel_anchor = ls
		ap.scroll     = max(0, line - 10)
		ap.scroll_anim = f32(ap.scroll)
	case:
	}
}

// ---------------------------------------------------------------------------
// Find References / Go to Implementation / Go to Type Definition /
// Go to Declaration / Document Symbols / Workspace Symbols
//
// These all resolve to "a list of places" (Location | Location[] |
// LocationLink[] | SymbolInformation[] | DocumentSymbol[]), so they share
// one result path: _open_locations_or_navigate jumps straight to the file
// when there's exactly one hit (same UX as Go to Definition), or opens the
// palette's .Locations list when there's more than one.
// ---------------------------------------------------------------------------

// Prefers the language server's real references (accounts for scope, shadowing,
// cross-file usage) — falls back to the local text-scan picker (goto_refs_do)
// when no server is running, same pattern lsp_goto_definition already uses.
lsp_find_references :: proc(e: ^Editor, p: ^Pane) {
	c := _get_client(e, p)
	if c == nil || !c.caps.has_references || p.filename == "" { goto_refs_do(e); return }
	line, char := _cursor_lsp_pos(p)
	lsp.manager_references(&e.lsp_mgr, p.filename, line, char, lsp.Response_Callback{
		proc_ = _on_references_response, user = e,
	})
}

_on_references_response :: proc(c: ^lsp.Language_Client, result: json.Value, error: json.Value, user: rawptr) {
	defer json.destroy_value(result)
	defer json.destroy_value(error)
	if error != nil { return }
	e := cast(^Editor)user
	items := _parse_locations(result, "reference")
	_open_locations_or_navigate(e, items, fmt.tprintf("%d references", len(items)))
}

lsp_goto_implementation :: proc(e: ^Editor, p: ^Pane) {
	c := _get_client(e, p)
	if c == nil || !c.caps.has_implementation || p.filename == "" { return }
	line, char := _cursor_lsp_pos(p)
	lsp.manager_implementation(&e.lsp_mgr, p.filename, line, char, lsp.Response_Callback{
		proc_ = _on_implementation_response, user = e,
	})
}

_on_implementation_response :: proc(c: ^lsp.Language_Client, result: json.Value, error: json.Value, user: rawptr) {
	defer json.destroy_value(result)
	defer json.destroy_value(error)
	if error != nil { return }
	e := cast(^Editor)user
	items := _parse_locations(result, "implementation")
	_open_locations_or_navigate(e, items, fmt.tprintf("%d implementations", len(items)))
}

lsp_goto_type_definition :: proc(e: ^Editor, p: ^Pane) {
	c := _get_client(e, p)
	if c == nil || !c.caps.has_type_definition || p.filename == "" { return }
	line, char := _cursor_lsp_pos(p)
	lsp.manager_type_definition(&e.lsp_mgr, p.filename, line, char, lsp.Response_Callback{
		proc_ = _on_type_definition_response, user = e,
	})
}

_on_type_definition_response :: proc(c: ^lsp.Language_Client, result: json.Value, error: json.Value, user: rawptr) {
	defer json.destroy_value(result)
	defer json.destroy_value(error)
	if error != nil { return }
	e := cast(^Editor)user
	items := _parse_locations(result, "type definition")
	_open_locations_or_navigate(e, items, fmt.tprintf("%d type definitions", len(items)))
}

lsp_goto_declaration :: proc(e: ^Editor, p: ^Pane) {
	c := _get_client(e, p)
	if c == nil || !c.caps.has_declaration || p.filename == "" { return }
	line, char := _cursor_lsp_pos(p)
	lsp.manager_declaration(&e.lsp_mgr, p.filename, line, char, lsp.Response_Callback{
		proc_ = _on_declaration_response, user = e,
	})
}

_on_declaration_response :: proc(c: ^lsp.Language_Client, result: json.Value, error: json.Value, user: rawptr) {
	defer json.destroy_value(result)
	defer json.destroy_value(error)
	if error != nil { return }
	e := cast(^Editor)user
	items := _parse_locations(result, "declaration")
	_open_locations_or_navigate(e, items, fmt.tprintf("%d declarations", len(items)))
}

lsp_document_symbols_open :: proc(e: ^Editor, p: ^Pane) {
	c := _get_client(e, p)
	if c == nil || !c.caps.has_document_symbol || p.filename == "" { return }
	lsp.manager_document_symbol(&e.lsp_mgr, p.filename, lsp.Response_Callback{
		proc_ = _on_document_symbol_response, user = e,
	})
}

_on_document_symbol_response :: proc(c: ^lsp.Language_Client, result: json.Value, error: json.Value, user: rawptr) {
	defer json.destroy_value(result)
	defer json.destroy_value(error)
	if error != nil { return }
	e := cast(^Editor)user
	arr, is_arr := result.(json.Array)
	if !is_arr { return }
	ap := active_pane(e)
	if ap.filename == "" { return }

	items := make([dynamic]Location_Item)
	_walk_doc_symbols(&items, arr, ap.filename, "")
	_open_locations_or_navigate(e, items, fmt.tprintf("%d symbols", len(items)))
}

// DocumentSymbol[] is a tree (nested "children"); SymbolInformation[] (older
// servers) is flat with a "location" object instead of "range". Handle both.
_walk_doc_symbols :: proc(items: ^[dynamic]Location_Item, arr: json.Array, file: string, prefix: string) {
	for item_v in arr {
		obj, ok := item_v.(json.Object)
		if !ok { continue }
		name, _   := lsp.json_obj_str(obj, "name")
		kind_n, _ := lsp.json_obj_int(obj, "kind")

		range_obj, has_r := lsp.json_obj_obj(obj, "selectionRange")
		if !has_r { range_obj, has_r = lsp.json_obj_obj(obj, "range") }
		line, col := 1, 1
		if has_r {
			r := lsp.parse_range(range_obj)
			line = r.start.line + 1
			col  = r.start.character + 1
		} else if loc_obj, has_loc := lsp.json_obj_obj(obj, "location"); has_loc {
			if rr_obj, has_rr := lsp.json_obj_obj(loc_obj, "range"); has_rr {
				r := lsp.parse_range(rr_obj)
				line = r.start.line + 1
				col  = r.start.character + 1
			}
		}

		label := fmt.tprintf("%s.%s", prefix, name) if prefix != "" else name
		append(items, Location_Item{
			label  = strings.clone(label),
			detail = strings.clone(_symbol_kind_name(kind_n)),
			file   = strings.clone(file),
			line   = line,
			col    = col,
		})

		if children, has_c := lsp.json_obj_arr(obj, "children"); has_c {
			_walk_doc_symbols(items, children, file, name)
		}
	}
}

lsp_workspace_symbols_open :: proc(e: ^Editor) {
	palette_open_workspace_symbols(&e.palette)
}

_lsp_workspace_symbol_query :: proc(e: ^Editor, query: string) {
	if query == "" { return }
	ap := active_pane(e)
	if ap.filename == "" { return }
	lsp.manager_workspace_symbol(&e.lsp_mgr, ap.filename, query, lsp.Response_Callback{
		proc_ = _on_workspace_symbol_response, user = e,
	})
}

_on_workspace_symbol_response :: proc(c: ^lsp.Language_Client, result: json.Value, error: json.Value, user: rawptr) {
	defer json.destroy_value(result)
	defer json.destroy_value(error)
	if error != nil { return }
	e := cast(^Editor)user
	arr, is_arr := result.(json.Array)
	if !is_arr { return }

	items := make([dynamic]Location_Item)
	for item_v in arr {
		obj, ok := item_v.(json.Object)
		if !ok { continue }
		name, _      := lsp.json_obj_str(obj, "name")
		kind_n, _    := lsp.json_obj_int(obj, "kind")
		container, _ := lsp.json_obj_str(obj, "containerName")
		loc_obj, has_loc := lsp.json_obj_obj(obj, "location")
		if !has_loc { continue }
		uri_str, has_uri := lsp.json_obj_str(loc_obj, "uri")
		if !has_uri { continue }

		line, col := 1, 1
		if r_obj, has_r := lsp.json_obj_obj(loc_obj, "range"); has_r {
			r := lsp.parse_range(r_obj)
			line = r.start.line + 1
			col  = r.start.character + 1
		}

		detail := _symbol_kind_name(kind_n)
		if container != "" { detail = fmt.tprintf("%s  \xc2\xb7  %s", detail, container) }

		append(&items, Location_Item{
			label  = strings.clone(name),
			detail = strings.clone(detail),
			file   = strings.clone(lsp.uri_to_path(uri_str)),
			line   = line,
			col    = col,
		})
	}

	palette_set_workspace_symbol_results(&e.palette, items)
}

// Parse a Location | Location[] | LocationLink[] result (LocationLink uses
// targetUri/targetRange instead of uri/range) into display-ready items.
_parse_locations :: proc(result: json.Value, label: string) -> [dynamic]Location_Item {
	items := make([dynamic]Location_Item)

	add_one :: proc(items: ^[dynamic]Location_Item, obj: json.Object, label: string) {
		uri_str, has_uri := lsp.json_obj_str(obj, "uri")
		if !has_uri { uri_str, has_uri = lsp.json_obj_str(obj, "targetUri") }
		if !has_uri { return }

		range_obj, has_r := lsp.json_obj_obj(obj, "range")
		if !has_r { range_obj, has_r = lsp.json_obj_obj(obj, "targetSelectionRange") }
		if !has_r { range_obj, has_r = lsp.json_obj_obj(obj, "targetRange") }

		line, col := 1, 1
		if has_r {
			r := lsp.parse_range(range_obj)
			line = r.start.line + 1
			col  = r.start.character + 1
		}

		path := lsp.uri_to_path(uri_str)
		append(items, Location_Item{
			label  = strings.clone(label),
			detail = strings.clone(path_basename(path)),
			file   = strings.clone(path),
			line   = line,
			col    = col,
		})
	}

	#partial switch v in result {
	case json.Array:
		for item_v in v {
			if obj, ok := item_v.(json.Object); ok { add_one(&items, obj, label) }
		}
	case json.Object:
		add_one(&items, v, label)
	}
	return items
}

// One result: jump straight there (same UX as Go to Definition). More than
// one: hand off to the palette's shared .Locations list.
_open_locations_or_navigate :: proc(e: ^Editor, items: [dynamic]Location_Item, title: string) {
	if len(items) == 0 {
		e.msg = fmt.tprintf("%s: no results", title)
		delete(items)
		return
	}
	if len(items) == 1 {
		li := items[0]
		location_jump(e, li)
		for &it in items { location_item_destroy(&it) }
		delete(items)
		return
	}
	palette_open_locations(&e.palette, title, items)
}

// LSP SymbolKind (1-indexed) → short display label.
_symbol_kind_name :: proc(kind: int) -> string {
	switch kind {
	case 1:  return "File"
	case 2:  return "Module"
	case 3:  return "Namespace"
	case 4:  return "Package"
	case 5:  return "Class"
	case 6:  return "Method"
	case 7:  return "Property"
	case 8:  return "Field"
	case 9:  return "Constructor"
	case 10: return "Enum"
	case 11: return "Interface"
	case 12: return "Function"
	case 13: return "Variable"
	case 14: return "Constant"
	case 20: return "Key"
	case 22: return "Struct"
	case 23: return "Event"
	case 24: return "Operator"
	case 25: return "TypeParameter"
	}
	return ""
}

// ---------------------------------------------------------------------------
// Command palette wiring — one cmd_* + availability gate per LSP feature.
// The gate reads Language_Client.caps for the active pane's server, so a
// command only appears when that specific server actually advertises
// support for it (e.g. pylsp has no Go to Implementation, jdtls does).
// ---------------------------------------------------------------------------

cmd_lsp_goto_definition :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	lsp_goto_definition(e, active_pane(e))
}
_avail_definition :: proc(e: ^Editor) -> bool {
	c := _get_client(e, active_pane(e)); return c != nil && c.caps.has_definition
}

cmd_lsp_references :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	lsp_find_references(e, active_pane(e))
}
_avail_references :: proc(e: ^Editor) -> bool {
	c := _get_client(e, active_pane(e)); return c != nil && c.caps.has_references
}

cmd_lsp_goto_implementation :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	lsp_goto_implementation(e, active_pane(e))
}
_avail_implementation :: proc(e: ^Editor) -> bool {
	c := _get_client(e, active_pane(e)); return c != nil && c.caps.has_implementation
}

cmd_lsp_goto_type_definition :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	lsp_goto_type_definition(e, active_pane(e))
}
_avail_type_definition :: proc(e: ^Editor) -> bool {
	c := _get_client(e, active_pane(e)); return c != nil && c.caps.has_type_definition
}

cmd_lsp_goto_declaration :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	lsp_goto_declaration(e, active_pane(e))
}
_avail_declaration :: proc(e: ^Editor) -> bool {
	c := _get_client(e, active_pane(e)); return c != nil && c.caps.has_declaration
}

cmd_lsp_document_symbols :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	lsp_document_symbols_open(e, active_pane(e))
}
_avail_document_symbol :: proc(e: ^Editor) -> bool {
	c := _get_client(e, active_pane(e)); return c != nil && c.caps.has_document_symbol
}

// Doesn't close the palette — switches it into live-query mode instead,
// same pattern cmd_switch_theme already uses for .Themes.
cmd_lsp_workspace_symbols :: proc(e: ^Editor, p: ^Palette) {
	lsp_workspace_symbols_open(e)
}
_avail_workspace_symbol :: proc(e: ^Editor) -> bool {
	c := _get_client(e, active_pane(e)); return c != nil && c.caps.has_workspace_symbols
}

cmd_lsp_rename :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	lsp_rename_open(e)
}
_avail_rename :: proc(e: ^Editor) -> bool {
	c := _get_client(e, active_pane(e)); return c != nil && c.caps.has_rename
}

cmd_lsp_format :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	lsp_format_document(e)
}
_avail_format :: proc(e: ^Editor) -> bool {
	c := _get_client(e, active_pane(e)); return c != nil && c.caps.has_formatting
}

cmd_lsp_code_actions :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	lsp_code_actions_request(e)
}
_avail_code_actions :: proc(e: ^Editor) -> bool {
	c := _get_client(e, active_pane(e)); return c != nil && c.caps.has_code_actions
}

// "Problems" — lists this file's diagnostics (errors/warnings/info/hints,
// already pushed by the server via textDocument/publishDiagnostics and
// stored per-client) through the same .Locations list used by References
// etc. Doesn't need a capability check: diagnostics are server-pushed, not
// request-gated, so it's available whenever a file with an LSP client is open.
cmd_lsp_problems :: proc(e: ^Editor, p: ^Palette) {
	ap := active_pane(e)
	if ap.filename == "" { palette_close(p); return }

	diags := lsp.manager_get_diags(&e.lsp_mgr, ap.filename)
	if len(diags) == 0 {
		palette_close(p)
		e.msg = "No problems in this file"
		return
	}

	items := make([dynamic]Location_Item)
	for d in diags {
		label  := fmt.tprintf("[%s] %s", _severity_label(d.severity), d.message)
		detail := d.source
		if d.code != "" { detail = fmt.tprintf("%s %s", detail, d.code) if detail != "" else d.code }
		append(&items, Location_Item{
			label  = strings.clone(label),
			detail = strings.clone(detail),
			file   = strings.clone(ap.filename),
			line   = d.range.start.line + 1,
			col    = d.range.start.character + 1,
		})
	}
	palette_open_locations(p, fmt.tprintf("%d problems", len(items)), items)
}
_avail_problems :: proc(e: ^Editor) -> bool {
	return active_pane(e).filename != ""
}

_severity_label :: proc(s: lsp.Diagnostic_Severity) -> string {
	switch s {
	case .Error:       return "Error"
	case .Warning:     return "Warning"
	case .Information: return "Info"
	case .Hint:        return "Hint"
	}
	return "?"
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

_get_client :: proc(e: ^Editor, p: ^Pane) -> ^lsp.Language_Client {
	if p.filename == "" { return nil }
	return lsp.lsp_manager_find_client_for_path(&e.lsp_mgr, p.filename)
}

_cursor_lsp_pos :: proc(p: ^Pane) -> (line, char: int) {
	return buffer_pos_to_line_col(&p.buf, p.cursor)
}

_char_before_cursor :: proc(p: ^Pane) -> rune {
	if p.cursor == 0 { return 0 }
	return rune(buffer_get_byte(&p.buf, p.cursor - 1))
}

_is_ident_char :: proc(ch: rune) -> bool {
	return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
	       (ch >= '0' && ch <= '9') || ch == '_'
}

_is_trigger_char :: proc(e: ^Editor, p: ^Pane, ch: rune) -> bool {
	c := _get_client(e, p)
	if c == nil { return false }
	s := fmt.tprintf("%r", ch)
	for t in c.caps.completion_triggers { if t == s { return true } }
	return false
}

_word_before_cursor :: proc(p: ^Pane) -> string {
	end   := p.cursor
	start := end
	for start > 0 {
		b := buffer_get_byte(&p.buf, start - 1)
		if !_is_ident_char(rune(b)) { break }
		start -= 1
	}
	if start == end { return "" }
	n   := end - start
	tmp := make([]u8, n, context.temp_allocator)
	for i in 0..<n { tmp[i] = buffer_get_byte(&p.buf, start + i) }
	return string(tmp)
}

_maybe_trigger_completion :: proc(e: ^Editor, p: ^Pane, ch: rune, is_trigger: bool) {
	c := _get_client(e, p)
	if c == nil { return }

	prefix := _word_before_cursor(p)
	line, char := _cursor_lsp_pos(p)

	if c.completion.session.active && !is_trigger {
		lsp.completion_update_prefix(c, prefix)
		return
	}

	trigger := lsp.Trigger_Kind.Invoked
	if is_trigger { trigger = .Trigger_Char }
	lsp.manager_completion(&e.lsp_mgr, p.filename, line, char, trigger, ch, prefix)
}

_sync_suggest_widget :: proc(p: ^Pane, c: ^lsp.Language_Client) {
	if !lsp.completion_is_visible(c) {
		p.suggest.visible = false
		return
	}
	p.suggest.visible  = true
	items, filtered   := lsp.completion_filtered_items(c)
	p.suggest.items    = items
	p.suggest.filtered = filtered
	p.suggest.selected = c.completion.session.selected
}

// Pane text operations with undo support.
pane_delete_backward :: proc(p: ^Pane, n: int) {
	if n <= 0 || p.cursor < n { return }
	pos := p.cursor - n
	del := make([]u8, n, context.temp_allocator)
	for i in 0..<n { del[i] = buffer_get_byte(&p.buf, pos + i) }
	undo_push_delete(p, pos, del, true)
	undo_break(p)
	buffer_delete(&p.buf, pos, n)
	p.cursor     = pos
	p.sel_anchor = pos
	p.dirty      = true
}

pane_insert_str :: proc(p: ^Pane, text: string) {
	data := transmute([]u8)text
	undo_push_insert(p, p.cursor, data, false)
	undo_break(p)
	for b, i in data {
		buffer_insert_byte(&p.buf, p.cursor + i, b)
	}
	p.cursor    += len(data)
	p.sel_anchor = p.cursor
	p.dirty      = true
}

_path_dirname :: proc(path: string) -> string {
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' { return path[:i] }
	}
	return "."
}

_file_exists :: proc(path: string) -> bool {
	return os.exists(path)
}

// ---------------------------------------------------------------------------
// TextEdit / WorkspaceEdit application
// ---------------------------------------------------------------------------

// Convert LSP {line, char} to byte offset in pane. Treats char as byte offset (ASCII-safe).
_lsp_pos_to_offset :: proc(p: ^Pane, line, char: int) -> int {
	ls := buffer_line_start(&p.buf, line)
	ll := buffer_line_length(&p.buf, line)
	return ls + clamp(char, 0, ll)
}

// Apply a single TextEdit JSON object to a pane.
// `first` threads the undo compound-group flag across every delete/insert in
// this edit — and across every edit in the same apply_text_edits_to_pane
// call — so one Ctrl+Z undoes the whole rename/format/code-action/workspace
// edit, not one fragment of it (see undo_push_mc in undo.odin: the group
// unwinds LIFO until it hits the entry pushed with first=true).
_apply_text_edit_obj :: proc(p: ^Pane, obj: json.Object, first: ^bool) {
	range_obj, has_r := lsp.json_obj_obj(obj, "range")
	if !has_r { return }
	r := lsp.parse_range(range_obj)
	new_text, _ := lsp.json_obj_str(obj, "newText")

	start_off := _lsp_pos_to_offset(p, r.start.line, r.start.character)
	end_off   := _lsp_pos_to_offset(p, r.end.line,   r.end.character)
	if end_off < start_off { end_off = start_off }
	end_off = min(end_off, buffer_len(&p.buf))

	if end_off > start_off {
		n := end_off - start_off
		del := make([]u8, n, context.temp_allocator)
		for i in 0..<n { del[i] = buffer_get_byte(&p.buf, start_off + i) }
		undo_push_mc(p, false, start_off, del, first^)
		first^ = false
		buffer_delete(&p.buf, start_off, n)
	}
	if len(new_text) > 0 {
		undo_push_mc(p, true, start_off, transmute([]u8)new_text, first^)
		first^ = false
		buffer_insert_string(&p.buf, start_off, new_text)
	}
	p.dirty = true
}

// Apply TextEdit[] (json.Array) to a pane, in reverse order to preserve offsets.
apply_text_edits_to_pane :: proc(p: ^Pane, edits: json.Array) {
	first := true
	// Apply in reverse so earlier edits don't shift later positions
	for i := len(edits) - 1; i >= 0; i -= 1 {
		obj, is_obj := edits[i].(json.Object)
		if !is_obj { continue }
		_apply_text_edit_obj(p, obj, &first)
	}
	undo_break(p)
	blen := buffer_len(&p.buf)
	p.cursor     = clamp(p.cursor, 0, blen)
	p.sel_anchor = p.cursor
}

// Apply a WorkspaceEdit JSON object — handles both `changes` and `documentChanges`.
apply_workspace_edit :: proc(e: ^Editor, val: json.Value) {
	obj, is_obj := val.(json.Object)
	if !is_obj { return }

	// `changes`: { uri: TextEdit[] }
	if changes_v, has := obj["changes"]; has {
		if changes_obj, ok := changes_v.(json.Object); ok {
			for uri_str, edits_v in changes_obj {
				edits_arr, is_arr := edits_v.(json.Array)
				if !is_arr { continue }
				path := lsp.uri_to_path(uri_str)
				_apply_edits_to_file(e, path, edits_arr)
			}
		}
	}

	// `documentChanges`: [{textDocument:{uri}, edits:[...]}]
	if dc_v, has := obj["documentChanges"]; has {
		if dc_arr, ok := dc_v.(json.Array); ok {
			for item_v in dc_arr {
				item, is_obj2 := item_v.(json.Object)
				if !is_obj2 { continue }
				td_obj, has_td := lsp.json_obj_obj(item, "textDocument")
				if !has_td { continue }
				uri_str, has_uri := lsp.json_obj_str(td_obj, "uri")
				if !has_uri { continue }
				edits_arr, has_edits := lsp.json_obj_arr(item, "edits")
				if !has_edits { continue }
				path := lsp.uri_to_path(uri_str)
				_apply_edits_to_file(e, path, edits_arr)
			}
		}
	}
}

_apply_edits_to_file :: proc(e: ^Editor, path: string, edits: json.Array) {
	if len(edits) == 0 { return }
	// Apply to open pane if file is already loaded
	for &p in e.panes {
		if p.filename == path {
			apply_text_edits_to_pane(&p, edits)
			return
		}
	}
	// File not open: load it, apply, save
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil { return }
	defer delete(data)
	tmp := pane_init()
	defer pane_destroy(&tmp)
	clean, _ := strings.replace_all(string(data), "\r", "", context.allocator)
	defer delete(clean)
	buffer_insert_string(&tmp.buf, 0, clean)
	tmp.filename = strings.clone(path)
	tmp.lang     = detect_lang(path)
	apply_text_edits_to_pane(&tmp, edits)
	text := buffer_to_string(&tmp.buf)
	defer delete(text)
	_ = os.write_entire_file(path, transmute([]u8)text)
}

// ---------------------------------------------------------------------------
// Format document  (Ctrl+Shift+I)
// ---------------------------------------------------------------------------

lsp_format_document :: proc(e: ^Editor) {
	p := active_pane(e)
	c := _get_client(e, p)
	if c == nil || !c.caps.has_formatting { e.msg = "LSP: format not supported"; return }
	lsp.manager_format(&e.lsp_mgr, p.filename, 4, true, lsp.Response_Callback{
		proc_ = _on_format_response, user = e,
	})
}

_on_format_response :: proc(c: ^lsp.Language_Client, result: json.Value, error: json.Value, user: rawptr) {
	defer json.destroy_value(result)
	defer json.destroy_value(error)
	if error != nil { return }
	e := cast(^Editor)user
	arr, is_arr := result.(json.Array)
	if !is_arr { return }
	p := active_pane(e)
	apply_text_edits_to_pane(p, arr)
	e.msg = "Formatted"
}

// ---------------------------------------------------------------------------
// Rename symbol  (F2)
// ---------------------------------------------------------------------------

lsp_rename_open :: proc(e: ^Editor) {
	p    := active_pane(e)
	word := _def_word_at_cursor(p)
	if word == "" { e.msg = "No symbol under cursor"; return }
	rename_dialog_open(&e.rename_dlg, word)
}

lsp_rename_confirm :: proc(e: ^Editor, new_name: string) {
	p := active_pane(e)
	if p.filename == "" { return }
	c := _get_client(e, p)
	if c == nil || !c.caps.has_rename { e.msg = "LSP: rename not supported"; return }
	line, char := _cursor_lsp_pos(p)
	lsp.manager_rename(&e.lsp_mgr, p.filename, line, char, new_name, lsp.Response_Callback{
		proc_ = _on_rename_response, user = e,
	})
}

_on_rename_response :: proc(c: ^lsp.Language_Client, result: json.Value, error: json.Value, user: rawptr) {
	defer json.destroy_value(result)
	defer json.destroy_value(error)
	e := cast(^Editor)user
	if error != nil { e.msg = "Rename failed"; return }
	if _, is_null := result.(json.Null); is_null { e.msg = "Rename: no edits"; return }
	apply_workspace_edit(e, result)
	e.msg = "Renamed"
}

// ---------------------------------------------------------------------------
// Code actions  (Ctrl+.)
// ---------------------------------------------------------------------------

lsp_code_actions_request :: proc(e: ^Editor) {
	p := active_pane(e)
	c := _get_client(e, p)
	if c == nil || !c.caps.has_code_actions { e.msg = "LSP: code actions not supported"; return }
	line, char := _cursor_lsp_pos(p)
	lsp.manager_code_actions(&e.lsp_mgr, p.filename, line, char, lsp.Response_Callback{
		proc_ = _on_code_actions_response, user = e,
	})
}

_on_code_actions_response :: proc(c: ^lsp.Language_Client, result: json.Value, error: json.Value, user: rawptr) {
	defer json.destroy_value(result)
	defer json.destroy_value(error)
	e := cast(^Editor)user
	if error != nil { return }
	arr, is_arr := result.(json.Array)
	if !is_arr || len(arr) == 0 { e.msg = "No code actions available"; return }

	d := &e.code_action_dlg
	code_action_dialog_clear(d)

	for item_v in arr {
		obj, is_obj := item_v.(json.Object)
		if !is_obj { continue }
		a: Code_Action
		title, _ := lsp.json_obj_str(obj, "title")
		a.title = strings.clone(title)
		kind, has_kind := lsp.json_obj_str(obj, "kind")
		if has_kind { a.kind = strings.clone(kind) } else { a.kind = strings.clone("") }
		is_pref, _ := lsp.json_obj_bool(obj, "isPreferred")
		a.is_preferred = is_pref

		// Edit
		if edit_v, has_e := obj["edit"]; has_e {
			if _, not_null := edit_v.(json.Null); !not_null {
				a.has_edit  = true
				a.edit_json = strings.clone(fmt.tprintf("%v", edit_v))
				// Store the raw edit value — we deep-clone it for later application
				_store_action_edit(e, len(d.actions), lsp.Deep_Clone_Value(edit_v))
			}
		}

		// Command
		if cmd_v, has_c := obj["command"]; has_c {
			#partial switch cv in cmd_v {
			case json.Object:
				cmd_id, _ := lsp.json_obj_str(cv, "command")
				a.cmd_id    = strings.clone(cmd_id)
				a.has_cmd   = true
			case string:
				a.cmd_id  = strings.clone(cv)
				a.has_cmd = true
			}
		}

		// Neither edit nor command present — server (e.g. jdtls, once
		// codeActionLiteralSupport.resolveSupport is declared) expects
		// codeAction/resolve on selection. Keep the original object to
		// send back verbatim.
		if !a.has_edit && !a.has_cmd {
			a.raw_json = lsp.Deep_Clone_Value(item_v)
		}

		append(&d.actions, a)
	}

	if len(d.actions) == 1 {
		// Only one action: apply immediately
		lsp_apply_code_action(e, 0)
	} else if len(d.actions) > 0 {
		code_action_dialog_open(d)
	}
}

// Temporary store for deep-cloned edit JSON values (indexed by action index).
// We keep them as a parallel map keyed by dialog open epoch.
@(private="file")
_pending_edits: map[int]json.Value

_store_action_edit :: proc(e: ^Editor, idx: int, v: json.Value) {
	if _pending_edits == nil { _pending_edits = make(map[int]json.Value) }
	if old, has := _pending_edits[idx]; has { json.destroy_value(old) }
	_pending_edits[idx] = lsp._deep_clone_value(v)
}

lsp_apply_code_action :: proc(e: ^Editor, idx: int) {
	d := &e.code_action_dlg
	if idx < 0 || idx >= len(d.actions) { return }
	a := d.actions[idx]

	if a.has_edit {
		if edit_v, has := _pending_edits[idx]; has {
			apply_workspace_edit(e, edit_v)
			json.destroy_value(edit_v)
			delete_key(&_pending_edits, idx)
		}
	}
	// Clean up remaining pending edits when dialog closes
	for k, v in _pending_edits { json.destroy_value(v) }
	clear(&_pending_edits)

	if a.has_cmd && a.cmd_id != "" {
		p := active_pane(e)
		c := _get_client(e, p)
		if c != nil {
			params := fmt.tprintf(`{"command":%s,"arguments":[]}`, lsp.json_str(a.cmd_id))
			lsp.client_send_request(c, "workspace/executeCommand", params, lsp.Response_Callback{
				proc_ = _on_execute_command,
			})
		}
	}

	if !a.has_edit && !a.has_cmd && a.raw_json != nil {
		p := active_pane(e)
		c := _get_client(e, p)
		if c != nil && c.caps.has_code_action_resolve {
			params, merr := json.marshal(a.raw_json, allocator = context.temp_allocator)
			if merr == nil {
				e.msg = fmt.tprintf("Resolving: %s...", a.title)
				lsp.client_send_request(c, "codeAction/resolve", string(params), lsp.Response_Callback{
					proc_ = _on_code_action_resolve_response, user = e,
				})
				return
			}
		}
		e.msg = fmt.tprintf("%s: nothing to apply (no edit/command)", a.title)
		return
	}

	e.msg = fmt.tprintf("Applied: %s", a.title)
}

_on_execute_command :: proc(c: ^lsp.Language_Client, result: json.Value, error: json.Value, user: rawptr) {
	defer json.destroy_value(result)
	defer json.destroy_value(error)
}

// Response to codeAction/resolve — same object we sent, now with edit
// and/or command populated. Apply exactly like the direct (non-deferred) path.
_on_code_action_resolve_response :: proc(c: ^lsp.Language_Client, result: json.Value, error: json.Value, user: rawptr) {
	defer json.destroy_value(result)
	defer json.destroy_value(error)
	e := cast(^Editor)user
	if error != nil { e.msg = "Code action resolve failed"; return }

	obj, is_obj := result.(json.Object)
	if !is_obj { return }

	title, _ := lsp.json_obj_str(obj, "title")

	if edit_v, has_e := obj["edit"]; has_e {
		if _, is_null := edit_v.(json.Null); !is_null {
			apply_workspace_edit(e, edit_v)
		}
	}

	if cmd_v, has_c := obj["command"]; has_c {
		cmd_id := ""
		#partial switch cv in cmd_v {
		case json.Object: cmd_id, _ = lsp.json_obj_str(cv, "command")
		case string:      cmd_id = cv
		}
		if cmd_id != "" {
			p := active_pane(e)
			cl := _get_client(e, p)
			if cl != nil {
				params := fmt.tprintf(`{"command":%s,"arguments":[]}`, lsp.json_str(cmd_id))
				lsp.client_send_request(cl, "workspace/executeCommand", params, lsp.Response_Callback{
					proc_ = _on_execute_command,
				})
			}
		}
	}

	e.msg = fmt.tprintf("Applied: %s", title)
}
