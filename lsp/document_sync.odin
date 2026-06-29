package lsp

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

// ---------------------------------------------------------------------------
// Document Sync — tracks open documents and their versions
// ---------------------------------------------------------------------------

Doc_State :: struct {
	uri:            string, // heap
	path:           string, // heap; filesystem path for deferred didOpen
	version:        int,
	lang_id:        string, // heap; LSP languageId e.g. "odin", "c", "python"
	did_open_sent:  bool,
}

Document_Sync :: struct {
	open_docs: map[string]Doc_State, // key = uri (heap)
}

doc_sync_init :: proc(ds: ^Document_Sync) {
	ds.open_docs = make(map[string]Doc_State)
}

doc_sync_destroy :: proc(ds: ^Document_Sync) {
	for _, &s in ds.open_docs {
		delete(s.uri)
		delete(s.path)
		delete(s.lang_id)
	}
	delete(ds.open_docs)
}

// Map our Lang enum to LSP languageId strings.
lang_id_for :: proc(ext: string) -> string {
	switch ext {
	case "odin":                        return "odin"
	case "c", "h":                      return "c"
	case "cpp", "cc", "cxx", "hpp":    return "cpp"
	case "py":                          return "python"
	case "js":                          return "javascript"
	case "ts":                          return "typescript"
	case "jsx":                         return "javascriptreact"
	case "tsx":                         return "typescriptreact"
	case "go":                          return "go"
	case "rs":                          return "rust"
	case "java":                        return "java"
	case "json":                        return "json"
	case "md":                          return "markdown"
	case "sh":                          return "shellscript"
	case "lua":                         return "lua"
	case "zig":                         return "zig"
	case "cs":                          return "csharp"
	case "rb":                          return "ruby"
	case "php":                         return "php"
	case "kt":                          return "kotlin"
	case "swift":                       return "swift"
	}
	return "plaintext"
}

// Extract extension from path (without dot).
path_ext :: proc(path: string) -> string {
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '.' { return path[i+1:] }
		if path[i] == '/' || path[i] == '\\' { break }
	}
	return ""
}

// ---------------------------------------------------------------------------
// didOpen — notify server that a document was opened
// ---------------------------------------------------------------------------

doc_sync_did_open :: proc(c: ^Language_Client, path: string, content: string) {
	uri   := path_to_uri(path)
	uri_h := strings.clone(uri)
	ext   := path_ext(path)
	lang  := lang_id_for(ext)

	// Free old state if re-opening same uri
	if old, exists := c.docs.open_docs[uri_h]; exists {
		delete(old.uri)
		delete(old.path)
		delete(old.lang_id)
	}

	state := Doc_State{
		uri     = uri_h,
		path    = strings.clone(path),
		version = 1,
		lang_id = strings.clone(lang),
	}

	if c.state == .Running {
		state.did_open_sent = true
		c.docs.open_docs[uri_h] = state
		params := fmt.tprintf(
			`{"textDocument":{"uri":%s,"languageId":"%s","version":1,"text":%s}}`,
			json_str(uri), lang, json_str(content),
		)
		client_send_notification(c, "textDocument/didOpen", params)
	} else {
		// Record for deferred send once server is Running
		c.docs.open_docs[uri_h] = state
	}
}

// Send didOpen for any docs recorded before server was Running.
doc_sync_flush_pending :: proc(c: ^Language_Client) {
	for uri_h, &state in c.docs.open_docs {
		if state.did_open_sent { continue }
		data, err := os.read_entire_file_from_path(state.path, context.temp_allocator)
		if err != nil { continue }
		content := string(data)
		params := fmt.tprintf(
			`{"textDocument":{"uri":%s,"languageId":"%s","version":1,"text":%s}}`,
			json_str(uri_h), state.lang_id, json_str(content),
		)
		client_send_notification(c, "textDocument/didOpen", params)
		state.did_open_sent = true
	}
}

// ---------------------------------------------------------------------------
// didClose
// ---------------------------------------------------------------------------

doc_sync_did_close :: proc(c: ^Language_Client, path: string) {
	if c.state != .Running { return }

	uri := path_to_uri(path)
	if state, ok := c.docs.open_docs[uri]; ok {
		delete(state.uri)
		delete(state.lang_id)
		delete_key(&c.docs.open_docs, uri)
	}

	params := fmt.tprintf(`{"textDocument":{"uri":%s}}`, json_str(uri))
	client_send_notification(c, "textDocument/didClose", params)
}

// ---------------------------------------------------------------------------
// didChange — full or incremental
// ---------------------------------------------------------------------------

doc_sync_did_change_full :: proc(c: ^Language_Client, path: string, content: string) {
	if c.state != .Running { return }

	uri := path_to_uri(path)
	state, ok := &c.docs.open_docs[uri]
	if !ok { doc_sync_did_open(c, path, content); return }
	state.version += 1

	params := fmt.tprintf(
		`{"textDocument":{"uri":%s,"version":%d},"contentChanges":[{"text":%s}]}`,
		json_str(uri), state.version, json_str(content),
	)
	client_send_notification(c, "textDocument/didChange", params)
}

// Incremental change: a single range was replaced with new_text.
doc_sync_did_change_range :: proc(
	c: ^Language_Client,
	path: string,
	start_line, start_char: int,
	end_line,   end_char:   int,
	new_text: string,
) {
	if c.state != .Running { return }

	uri := path_to_uri(path)
	state, ok := &c.docs.open_docs[uri]
	if !ok { return }
	state.version += 1

	params := fmt.tprintf(
		`{"textDocument":{"uri":%s,"version":%d},"contentChanges":[{"range":{"start":{"line":%d,"character":%d},"end":{"line":%d,"character":%d}},"text":%s}]}`,
		json_str(uri), state.version,
		start_line, start_char, end_line, end_char,
		json_str(new_text),
	)
	client_send_notification(c, "textDocument/didChange", params)
}

// ---------------------------------------------------------------------------
// didSave
// ---------------------------------------------------------------------------

doc_sync_did_save :: proc(c: ^Language_Client, path: string, content: string, include_text: bool) {
	if c.state != .Running { return }

	uri := path_to_uri(path)
	if include_text {
		params := fmt.tprintf(
			`{"textDocument":{"uri":%s},"text":%s}`,
			json_str(uri), json_str(content),
		)
		client_send_notification(c, "textDocument/didSave", params)
	} else {
		params := fmt.tprintf(`{"textDocument":{"uri":%s}}`, json_str(uri))
		client_send_notification(c, "textDocument/didSave", params)
	}
}

// ---------------------------------------------------------------------------
// Check if a document is open in this client
// ---------------------------------------------------------------------------

doc_is_open :: proc(c: ^Language_Client, path: string) -> bool {
	uri := path_to_uri(path)
	_, ok := c.docs.open_docs[uri]
	return ok
}

doc_uri :: proc(c: ^Language_Client, path: string) -> string {
	return path_to_uri(path)
}
