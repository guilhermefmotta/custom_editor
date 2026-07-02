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
_install_cmd_for_id :: proc(id: string) -> (cmd: []string, label: string) {
	_s :: proc(strs: []string) -> []string {
		out := make([]string, len(strs))
		for s, i in strs { out[i] = strings.clone(s) }
		return out
	}
	switch id {
	case "pylsp":
		when ODIN_OS == .Windows {
			return _s({"powershell", "-NoProfile", "-Command", "pip install python-lsp-server"}),
			       strings.clone("Installing pylsp...")
		} else {
			return _s({"sh", "-c",
			           `set -e; ` +
			           `if command -v pipx >/dev/null 2>&1; then ` +
			           `  pipx install python-lsp-server 2>&1; ` +
			           `else ` +
			           `  pip3 install --break-system-packages python-lsp-server 2>&1 || ` +
			           `  pip3 install --user python-lsp-server 2>&1; ` +
			           `fi; echo "Done."`}),
			       strings.clone("Installing pylsp...")
		}
	case "gopls":
		return _s({"go", "install", "golang.org/x/tools/gopls@latest"}),
		       strings.clone("Installing gopls via go install...")
	case "rust-analyzer":
		return _s({"rustup", "component", "add", "rust-analyzer"}),
		       strings.clone("Installing rust-analyzer via rustup...")
	case "typescript-language-server":
		when ODIN_OS == .Windows {
			return _s({"powershell", "-NoProfile", "-Command",
			           "npm install -g typescript-language-server typescript"}),
			       strings.clone("Installing typescript-language-server via npm...")
		} else {
			return _s({"sh", "-c", "npm install -g typescript-language-server typescript 2>&1"}),
			       strings.clone("Installing typescript-language-server via npm...")
		}
	case "jdtls":
		when ODIN_OS == .Windows {
			return _s({"powershell", "-NoProfile", "-Command",
			           `winget install --silent EclipseAdoptium.Temurin.21.JDK; ` +
			           `$url="https://www.eclipse.org/downloads/download.php?file=/jdtls/milestones/1.9.0/jdt-language-server-1.9.0-202203031534.tar.gz"; ` +
			           `$dir="$env:LOCALAPPDATA\jdtls"; New-Item -ItemType Directory -Force -Path $dir | Out-Null; ` +
			           `Invoke-WebRequest -Uri $url -OutFile "$dir\jdtls.tar.gz"`}),
			       strings.clone("Installing jdtls (requires Java 17+)...")
		} else {
			// Try brew (linuxbrew/macOS), then apt, then snap.
			// set -e exits non-zero if ALL methods fail.
			return _s({"sh", "-c",
			           `set -e; ` +
			           `if command -v brew >/dev/null 2>&1; then ` +
			           `  brew install jdtls 2>&1; ` +
			           `elif command -v apt-get >/dev/null 2>&1; then ` +
			           `  sudo apt-get install -y jdtls 2>&1; ` +
			           `elif command -v snap >/dev/null 2>&1; then ` +
			           `  sudo snap install jdtls 2>&1; ` +
			           `else ` +
			           `  echo "ERROR: no supported package manager found (brew/apt/snap)"; exit 1; ` +
			           `fi; ` +
			           `echo "Done. Java 17+ must be on PATH for jdtls to start."`}),
			       strings.clone("Installing jdtls via brew (requires Java 17+)...")
		}
	case "lua-language-server":
		when ODIN_OS == .Windows {
			return _s({"powershell", "-NoProfile", "-Command",
			           `$dir="$env:LOCALAPPDATA\editor"; New-Item -ItemType Directory -Force -Path $dir | Out-Null; ` +
			           `Invoke-WebRequest -Uri "https://github.com/LuaLS/lua-language-server/releases/latest/download/lua-language-server-win32-x64.zip" -OutFile "$dir\luals.zip"; ` +
			           `Expand-Archive -Force "$dir\luals.zip" "$dir\lua-language-server"; ` +
			           `[Environment]::SetEnvironmentVariable("PATH","$dir\lua-language-server\bin;$env:PATH","User")`}),
			       strings.clone("Downloading lua-language-server...")
		} else {
			return _s({"sh", "-c",
			           `set -e; DEST="$HOME/.local/bin"; mkdir -p "$DEST"; ` +
			           `OS=$(uname -s); ARCH=$(uname -m); ` +
			           `if [ "$OS" = "Darwin" ]; then PLAT=darwin; else PLAT=linux; fi; ` +
			           `if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then ARCH=arm64; else ARCH=x64; fi; ` +
			           `URL="https://github.com/LuaLS/lua-language-server/releases/latest/download/lua-language-server-$PLAT-$ARCH.tar.gz"; ` +
			           `TMP=$(mktemp -d); curl -fsSL "$URL" | tar -xz -C "$TMP"; ` +
			           `cp "$TMP/bin/lua-language-server" "$DEST/lua-language-server"; ` +
			           `chmod +x "$DEST/lua-language-server"; rm -rf "$TMP"; echo "Installed"`}),
			       strings.clone("Downloading lua-language-server...")
		}
	case "zls":
		when ODIN_OS == .Windows {
			return _s({"powershell", "-NoProfile", "-Command",
			           `$dir="$env:LOCALAPPDATA\editor"; New-Item -ItemType Directory -Force -Path $dir | Out-Null; ` +
			           `Invoke-WebRequest -Uri "https://github.com/zigtools/zls/releases/latest/download/zls-x86_64-windows.zip" -OutFile "$dir\zls.zip"; ` +
			           `Expand-Archive -Force "$dir\zls.zip" "$dir\zls"; ` +
			           `[Environment]::SetEnvironmentVariable("PATH","$dir\zls;$env:PATH","User")`}),
			       strings.clone("Downloading zls (Zig Language Server)...")
		} else {
			return _s({"sh", "-c",
			           `set -e; DEST="$HOME/.local/bin"; mkdir -p "$DEST"; ` +
			           `ARCH=$(uname -m); OS=$(uname -s | tr A-Z a-z); ` +
			           `if [ "$OS" = "darwin" ]; then OS=macos; fi; ` +
			           `URL="https://github.com/zigtools/zls/releases/latest/download/zls-$ARCH-$OS.tar.xz"; ` +
			           `curl -fsSL "$URL" | tar -xJ -C "$DEST" zls; ` +
			           `chmod +x "$DEST/zls"; echo "Installed: $DEST/zls"`}),
			       strings.clone("Downloading zls (Zig Language Server)...")
		}
	case "lemminx":
		when ODIN_OS == .Windows {
			return _s({"powershell", "-NoProfile", "-Command",
			           `$dir="$env:LOCALAPPDATA\editor"; New-Item -ItemType Directory -Force -Path $dir | Out-Null; ` +
			           `Invoke-WebRequest -Uri "https://github.com/eclipse/lemminx/releases/latest/download/lemminx-win32.exe" -OutFile "$dir\lemminx.exe"; ` +
			           `[Environment]::SetEnvironmentVariable("PATH","$dir;$env:PATH","User")`}),
			       strings.clone("Downloading LemMinX (XML Language Server)...")
		} else {
			return _s({"sh", "-c",
			           `set -e; DEST="$HOME/.local/bin"; mkdir -p "$DEST"; ` +
			           `OS=$(uname -s); if [ "$OS" = "Darwin" ]; then SUFFIX=osx; else SUFFIX=linux; fi; ` +
			           `URL="https://github.com/eclipse/lemminx/releases/latest/download/lemminx-$SUFFIX"; ` +
			           `curl -fsSL "$URL" -o "$DEST/lemminx" || wget -qO "$DEST/lemminx" "$URL"; ` +
			           `chmod +x "$DEST/lemminx"; echo "Installed: $DEST/lemminx"`}),
			       strings.clone("Downloading LemMinX (XML Language Server)...")
		}
	case "csharp-ls":
		return _s({"dotnet", "tool", "install", "-g", "csharp-ls"}),
		       strings.clone("Installing csharp-ls via dotnet tool...")
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
	for dir != "" && dir != "/" {
		for marker in markers {
			if _file_exists(fmt.tprintf("%s/%s", dir, marker)) { return dir }
		}
		parent := _path_dirname(dir)
		if parent == dir || parent == "" { break } // guard against infinite loop
		dir = parent
	}
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
_apply_text_edit_obj :: proc(p: ^Pane, obj: json.Object) {
	range_obj, has_r := lsp.json_obj_obj(obj, "range")
	if !has_r { return }
	r := lsp.parse_range(range_obj)
	new_text, _ := lsp.json_obj_str(obj, "newText")

	start_off := _lsp_pos_to_offset(p, r.start.line, r.start.character)
	end_off   := _lsp_pos_to_offset(p, r.end.line,   r.end.character)
	if end_off < start_off { end_off = start_off }
	end_off = min(end_off, buffer_len(&p.buf))

	if end_off > start_off { buffer_delete(&p.buf, start_off, end_off - start_off) }
	if len(new_text) > 0   { buffer_insert_string(&p.buf, start_off, new_text) }
	p.dirty = true
}

// Apply TextEdit[] (json.Array) to a pane, in reverse order to preserve offsets.
apply_text_edits_to_pane :: proc(p: ^Pane, edits: json.Array) {
	// Apply in reverse so earlier edits don't shift later positions
	for i := len(edits) - 1; i >= 0; i -= 1 {
		obj, is_obj := edits[i].(json.Object)
		if !is_obj { continue }
		_apply_text_edit_obj(p, obj)
	}
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

	e.msg = fmt.tprintf("Applied: %s", a.title)
}

_on_execute_command :: proc(c: ^lsp.Language_Client, result: json.Value, error: json.Value, user: rawptr) {
	defer json.destroy_value(result)
	defer json.destroy_value(error)
}
