package forge

// Per-host token storage in the OS secret store (ADR 0008):
//   macOS   Keychain        `security` (generic password, service SERVICE, account = host);
//                            written through `security -i` stdin so the token never hits argv
//   Linux   Secret Service   `secret-tool` (attributes service=SERVICE host=<host>), token on stdin;
//                            if secret-tool is missing: file fallback (below)
//   Windows Credential Manager (CredWriteW/CredReadW, target "SERVICE:<host>"), token_windows.odin
//   other   file fallback: <user config dir>/custom_editor/forge_tokens, mode 0600,
//            one "host token" per line
// Tokens are only needed when gh/glab is not logged in for the host.

import "core:os"
import "core:strings"

SERVICE :: "custom_editor.forge"

when ODIN_OS == .Darwin {
	TOKEN_STORE_NAME :: "keychain"
} else when ODIN_OS == .Linux {
	TOKEN_STORE_NAME :: "secret-service"
} else when ODIN_OS == .Windows {
	TOKEN_STORE_NAME :: "credential-manager"
} else {
	TOKEN_STORE_NAME :: "token-file"
}

// Tokens are opaque ASCII ([A-Za-z0-9._:~+/=-]); anything else is rejected,
// which also makes quoting for `security -i` safe.
token_valid :: proc(tok: string) -> bool {
	if len(tok) == 0 || len(tok) > 512 { return false }
	for c in transmute([]u8)tok {
		switch c {
		case 'a'..='z', 'A'..='Z', '0'..='9', '.', '_', ':', '~', '+', '/', '=', '-':
		case: return false
		}
	}
	return true
}

// Heap-owned token for host.
token_load :: proc(exec: Exec_Proc, host: string) -> (tok: string, ok: bool) {
	when ODIN_OS == .Darwin {
		res := exec([]string{"security", "find-generic-password", "-s", SERVICE, "-a", host, "-w"}, "", "")
		defer exec_result_destroy(&res)
		return _token_from_output(res)
	} else when ODIN_OS == .Linux {
		res := exec([]string{"secret-tool", "lookup", "service", SERVICE, "host", host}, "", "")
		defer exec_result_destroy(&res)
		if !res.started { return _file_load(host) }
		return _token_from_output(res)
	} else when ODIN_OS == .Windows {
		return _wincred_load(host)
	} else {
		return _file_load(host)
	}
}

// Saves (replaces) the token for host. err is heap-owned.
token_save :: proc(exec: Exec_Proc, host, tok: string) -> (err: string) {
	if !token_valid(tok) { return strings.clone("invalid token (unexpected characters)") }
	when ODIN_OS == .Darwin {
		cmd := strings.concatenate({`add-generic-password -U -s "`, SERVICE, `" -a "`, host, `" -l "`, SERVICE, " ", host, `" -w "`, tok, "\"\n"}, context.temp_allocator)
		res := exec([]string{"security", "-i"}, cmd, "")
		defer exec_result_destroy(&res)
		if !res.started { return strings.clone("`security` not found") }
		// `security -i` exits 0 even when a command fails: verify.
		if back, ok := token_load(exec, host); ok {
			same := back == tok
			delete(back)
			if same { return "" }
		}
		msg := strings.trim_space(res.stderr)
		return strings.clone(msg if msg != "" else "could not save token in the Keychain")
	} else when ODIN_OS == .Linux {
		label := strings.concatenate({SERVICE, " ", host}, context.temp_allocator)
		res := exec([]string{"secret-tool", "store", "--label", label, "service", SERVICE, "host", host}, tok, "")
		defer exec_result_destroy(&res)
		if !res.started { return _file_save(host, tok) }
		if res.exit_code != 0 {
			msg := strings.trim_space(res.stderr)
			return strings.clone(msg if msg != "" else "secret-tool store failed")
		}
		return ""
	} else when ODIN_OS == .Windows {
		return _wincred_save(host, tok)
	} else {
		return _file_save(host, tok)
	}
}

@(private)
_token_from_output :: proc(res: Exec_Result) -> (tok: string, ok: bool) {
	if !res.started || res.exit_code != 0 { return "", false }
	t := strings.trim_space(res.stdout)
	if t == "" { return "", false }
	return strings.clone(t), true
}

@(private)
_getenv :: proc(name: string) -> string {
	return os.get_env(name, context.allocator)
}

// ---------------------------------------------------------------------------
// File fallback (no secret store available)
// ---------------------------------------------------------------------------

@(private)
_token_file_path :: proc(allocator := context.temp_allocator) -> string {
	dir, err := os.user_config_dir(context.temp_allocator)
	if err != nil || dir == "" { return "" }
	return strings.concatenate({dir, "/custom_editor/forge_tokens"}, allocator)
}

@(private)
_file_load :: proc(host: string) -> (tok: string, ok: bool) {
	path := _token_file_path()
	if path == "" { return "", false }
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return "", false }
	return token_file_lookup(string(data), host)
}

// Pure: finds host's token in the file content. Heap-owned.
token_file_lookup :: proc(content, host: string) -> (tok: string, ok: bool) {
	it := content
	for line in strings.split_lines_iterator(&it) {
		l := strings.trim_space(line)
		sp := strings.index_byte(l, ' ')
		if sp < 0 { continue }
		if l[:sp] == host { return strings.clone(strings.trim_space(l[sp + 1:])), true }
	}
	return "", false
}

// Pure: content with host's token replaced/added. Allocated with allocator.
token_file_update :: proc(content, host, tok: string, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	it := content
	for line in strings.split_lines_iterator(&it) {
		l := strings.trim_space(line)
		if l == "" { continue }
		sp := strings.index_byte(l, ' ')
		if sp >= 0 && l[:sp] == host { continue }
		strings.write_string(&sb, l)
		strings.write_byte(&sb, '\n')
	}
	strings.write_string(&sb, host)
	strings.write_byte(&sb, ' ')
	strings.write_string(&sb, tok)
	strings.write_byte(&sb, '\n')
	return strings.to_string(sb)
}

@(private)
_file_save :: proc(host, tok: string) -> (err: string) {
	path := _token_file_path()
	if path == "" { return strings.clone("no user config directory for the token file") }
	dir := path[:strings.last_index_byte(path, '/')]
	_ = os.make_directory_all(dir)
	old, _ := os.read_entire_file(path, context.temp_allocator)
	content := token_file_update(string(old), host, tok)
	if e := os.write_entire_file(path, content, {.Read_User, .Write_User}); e != nil {
		return strings.clone("could not write the token file")
	}
	_ = os.chmod(path, {.Read_User, .Write_User}) // also tighten a pre-existing file
	return ""
}
