// Package lsp_bridge — public API for the editor.
//
// Wires together: workspace manager, server manager, and all feature
// modules into a single facade the editor calls each frame.
//
// Architecture:
//
//   Editor (lsp_integration.odin)
//       └── Bridge  (this package)
//               ├── Server_Manager   (lsp/server)
//               │       └── per language: Transport → Conn → LSP_Client
//               ├── Doc_Manager      (lsp/workspace)
//               └── per-server Feature set (lsp/features)
//                       ├── Doc_Sync
//                       ├── Completion_Feature
//                       ├── Hover_Feature
//                       ├── Diagnostics_Feature
//                       ├── Definition_Feature
//                       ├── References_Feature
//                       ├── Sig_Help_Feature
//                       ├── Semantic_Tokens_Feature
//                       ├── Code_Actions_Feature
//                       ├── Formatting_Feature
//                       ├── Rename_Feature
//                       └── Inlay_Hints_Feature
//
// Thread model: all public procs called from main thread.
// Background threads live inside Conn (reader) and Transport (writer).
// bridge_drain() must be called each frame to dispatch inbound messages.
package lsp_bridge

import srv "../server"
import ws  "../workspace"
import ft  "../features"
import cl  "../client"
import proto "../protocol"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"

// ---------------------------------------------------------------------------
// Per-server feature bundle
// ---------------------------------------------------------------------------

Server_Features :: struct {
    lang:           ws.Language_ID,
    doc_sync:       ^ft.Doc_Sync,
    completion:     ^ft.Completion_Feature,
    hover:          ^ft.Hover_Feature,
    diagnostics:    ^ft.Diagnostics_Feature,
    definition:     ^ft.Definition_Feature,
    references:     ^ft.References_Feature,
    sig_help:       ^ft.Sig_Help_Feature,
    sem_tokens:     ^ft.Semantic_Tokens_Feature,
    code_actions:   ^ft.Code_Actions_Feature,
    formatting:     ^ft.Formatting_Feature,
    rename_:        ^ft.Rename_Feature,
    inlay_hints:    ^ft.Inlay_Hints_Feature,
}

@(private)
_server_features_destroy :: proc(sf: ^Server_Features) {
    if sf.doc_sync    != nil { ft.doc_sync_destroy(sf.doc_sync) }
    if sf.completion  != nil { ft.completion_feature_destroy(sf.completion) }
    if sf.hover       != nil { ft.hover_feature_destroy(sf.hover) }
    if sf.diagnostics != nil { ft.diagnostics_feature_destroy(sf.diagnostics) }
    if sf.definition  != nil { ft.definition_feature_destroy(sf.definition) }
    if sf.references  != nil { ft.references_feature_destroy(sf.references) }
    if sf.sig_help    != nil { ft.sig_help_feature_destroy(sf.sig_help) }
    if sf.sem_tokens  != nil { ft.semantic_tokens_feature_destroy(sf.sem_tokens) }
    if sf.code_actions != nil { ft.code_actions_feature_destroy(sf.code_actions) }
    if sf.formatting  != nil { ft.formatting_feature_destroy(sf.formatting) }
    if sf.rename_     != nil { ft.rename_feature_destroy(sf.rename_) }
    if sf.inlay_hints != nil { ft.inlay_hints_feature_destroy(sf.inlay_hints) }
    free(sf)
}

// ---------------------------------------------------------------------------
// Bridge
// ---------------------------------------------------------------------------

Bridge :: struct {
    servers:   ^srv.Server_Manager,
    docs:      ^ws.Doc_Manager,

    mu:        sync.Mutex,
    features:  map[ws.Language_ID]^Server_Features,

    // Diagnostics callback: forwarded from each Diagnostics_Feature.
    on_diagnostics: Diagnostics_Handler,
    diag_user:      rawptr,
}

// Diagnostics_Handler receives per-file diagnostics from any server.
// uri is temp-lifetime (clone if you need to store it).
// diags is heap — caller must destroy with ft.diagnostics_destroy_slice.
Diagnostics_Handler :: proc(uri: string, diags: []proto.Diagnostic, user: rawptr)

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

bridge_create :: proc() -> ^Bridge {
    b := new(Bridge)
    b.servers  = srv.server_manager_create()
    b.docs     = ws.doc_manager_create()
    b.features = make(map[ws.Language_ID]^Server_Features)
    return b
}

bridge_destroy :: proc(b: ^Bridge) {
    sync.mutex_lock(&b.mu)
    for _, sf in b.features { _server_features_destroy(sf) }
    delete(b.features)
    sync.mutex_unlock(&b.mu)

    srv.server_manager_destroy(b.servers)
    ws.doc_manager_destroy(b.docs)
    free(b)
}

// bridge_set_diagnostics_handler sets the callback for publishDiagnostics events.
// Must be called before any document is opened.
bridge_set_diagnostics_handler :: proc(b: ^Bridge, h: Diagnostics_Handler, user: rawptr) {
    b.on_diagnostics = h
    b.diag_user      = user
}

// bridge_register_server registers a server config for a language.
// Bridge takes ownership of cfg.
bridge_register_server :: proc(b: ^Bridge, lang: ws.Language_ID, cfg: ^srv.Server_Config) {
    srv.server_manager_register(b.servers, lang, cfg)
}

// ---------------------------------------------------------------------------
// Document lifecycle
// ---------------------------------------------------------------------------

// bridge_open_document: open a document in the appropriate server.
// abs_path must be an absolute filesystem path.
// content: current file content.
bridge_open_document :: proc(b: ^Bridge, abs_path, content: string) {
    doc, is_new := ws.doc_manager_get_or_create(b.docs, abs_path)
    if doc == nil { return }

    sf := _get_or_start_features(b, doc.language_id, abs_path)
    if sf == nil { return }

    if is_new || !doc.open {
        doc.open = true
        ft.doc_sync_did_open(sf.doc_sync, doc.uri, ws.language_id_string(doc.language_id), content)
    }
}

// bridge_change_document: notify the server of a content change.
bridge_change_document :: proc(b: ^Bridge, abs_path, full_content: string) {
    doc, ok := ws.doc_manager_get_by_path(b.docs, abs_path)
    if !ok || !doc.open { return }

    sf := _get_features(b, doc.language_id)
    if sf == nil { return }

    ft.doc_sync_did_change(sf.doc_sync, doc.uri, full_content)
}

// bridge_close_document: close a document.
bridge_close_document :: proc(b: ^Bridge, abs_path: string) {
    doc, ok := ws.doc_manager_get_by_path(b.docs, abs_path)
    if !ok { return }

    sf := _get_features(b, doc.language_id)
    if sf != nil && doc.open {
        ft.doc_sync_did_close(sf.doc_sync, doc.uri)
        doc.open = false
    }
    ws.doc_manager_remove(b.docs, doc.uri)
}

// bridge_save_document: notify the server that a document was saved.
bridge_save_document :: proc(b: ^Bridge, abs_path: string) {
    doc, ok := ws.doc_manager_get_by_path(b.docs, abs_path)
    if !ok || !doc.open { return }

    sf := _get_features(b, doc.language_id)
    if sf == nil { return }

    ft.doc_sync_did_save(sf.doc_sync, doc.uri)
}

// ---------------------------------------------------------------------------
// Feature requests
// ---------------------------------------------------------------------------

bridge_request_completion :: proc(b: ^Bridge, abs_path: string, pos: proto.Position,
                                   trigger_char: string, cb: ft.Completion_Callback, user: rawptr) {
    doc, sf, ok := _doc_and_features(b, abs_path)
    if !ok { return }
    ft.completion_request(sf.completion, doc.uri, pos, trigger_char, cb, user)
}

bridge_cancel_completion :: proc(b: ^Bridge, abs_path: string) {
    _, sf, ok := _doc_and_features(b, abs_path)
    if ok { ft.completion_cancel(sf.completion) }
}

bridge_request_hover :: proc(b: ^Bridge, abs_path: string, pos: proto.Position,
                              cb: ft.Hover_Callback, user: rawptr) {
    doc, sf, ok := _doc_and_features(b, abs_path)
    if !ok { return }
    ft.hover_request(sf.hover, doc.uri, pos, cb, user)
}

bridge_cancel_hover :: proc(b: ^Bridge, abs_path: string) {
    _, sf, ok := _doc_and_features(b, abs_path)
    if ok { ft.hover_cancel(sf.hover) }
}

bridge_request_definition :: proc(b: ^Bridge, abs_path: string, pos: proto.Position,
                                   cb: ft.Location_Callback, user: rawptr) {
    doc, sf, ok := _doc_and_features(b, abs_path)
    if !ok { return }
    ft.definition_request(sf.definition, doc.uri, pos, cb, user)
}

bridge_request_references :: proc(b: ^Bridge, abs_path: string, pos: proto.Position,
                                   include_decl: bool, cb: ft.Location_Callback, user: rawptr) {
    doc, sf, ok := _doc_and_features(b, abs_path)
    if !ok { return }
    ft.references_request(sf.references, doc.uri, pos, include_decl, cb, user)
}

bridge_request_sig_help :: proc(b: ^Bridge, abs_path: string, pos: proto.Position,
                                 trigger_char: string, retrigger: bool,
                                 cb: ft.Sig_Help_Callback, user: rawptr) {
    doc, sf, ok := _doc_and_features(b, abs_path)
    if !ok { return }
    ft.sig_help_request(sf.sig_help, doc.uri, pos, trigger_char, retrigger, cb, user)
}

bridge_request_semantic_tokens :: proc(b: ^Bridge, abs_path: string,
                                        cb: ft.Semantic_Tokens_Callback, user: rawptr) {
    doc, sf, ok := _doc_and_features(b, abs_path)
    if !ok { return }
    ft.semantic_tokens_request(sf.sem_tokens, doc.uri, cb, user)
}

bridge_request_code_actions :: proc(b: ^Bridge, abs_path: string, r: proto.Range,
                                     diags: []proto.Diagnostic,
                                     cb: ft.Code_Actions_Callback, user: rawptr) {
    doc, sf, ok := _doc_and_features(b, abs_path)
    if !ok { return }
    ft.code_actions_request(sf.code_actions, doc.uri, r, diags, cb, user)
}

bridge_request_formatting :: proc(b: ^Bridge, abs_path: string,
                                   cb: ft.Text_Edits_Callback, user: rawptr) {
    doc, sf, ok := _doc_and_features(b, abs_path)
    if !ok { return }
    ft.formatting_request(sf.formatting, doc.uri, cb, user)
}

bridge_request_rename :: proc(b: ^Bridge, abs_path: string, pos: proto.Position,
                               new_name: string, cb: ft.Workspace_Edit_Callback, user: rawptr) {
    doc, sf, ok := _doc_and_features(b, abs_path)
    if !ok { return }
    ft.rename_request(sf.rename_, doc.uri, pos, new_name, cb, user)
}

bridge_request_inlay_hints :: proc(b: ^Bridge, abs_path: string, r: proto.Range,
                                    cb: ft.Inlay_Hints_Callback, user: rawptr) {
    doc, sf, ok := _doc_and_features(b, abs_path)
    if !ok { return }
    ft.inlay_hints_request(sf.inlay_hints, doc.uri, r, cb, user)
}

// ---------------------------------------------------------------------------
// Frame update — call each frame from main thread
// ---------------------------------------------------------------------------

bridge_drain :: proc(b: ^Bridge) {
    srv.server_manager_drain(b.servers)
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

// _doc_and_features: common lookup for request procs.
_doc_and_features :: proc(b: ^Bridge, abs_path: string) -> (doc: ^ws.Document, sf: ^Server_Features, ok: bool) {
    doc, exists := ws.doc_manager_get_by_path(b.docs, abs_path)
    if !exists || !doc.open { return nil, nil, false }
    sf = _get_features(b, doc.language_id)
    return doc, sf, sf != nil
}

// _get_features: non-starting lookup.
_get_features :: proc(b: ^Bridge, lang: ws.Language_ID) -> ^Server_Features {
    sync.mutex_lock(&b.mu)
    sf := b.features[lang]
    sync.mutex_unlock(&b.mu)
    return sf
}

// _get_or_start_features: starts the server for lang if not running, creates feature bundle.
_get_or_start_features :: proc(b: ^Bridge, lang: ws.Language_ID, abs_path: string) -> ^Server_Features {
    sync.mutex_lock(&b.mu)
    if sf, ok := b.features[lang]; ok {
        sync.mutex_unlock(&b.mu)
        return sf
    }
    sync.mutex_unlock(&b.mu)

    // Find root URI for this file
    root_uri := _find_root_uri(abs_path)

    caps_json := cl.build_client_capabilities()
    si, ok := srv.server_manager_get_or_start(b.servers, lang, root_uri, caps_json)
    if !ok { return nil }

    c := si.conn
    sf := new(Server_Features)
    sf.lang        = lang
    sf.doc_sync    = ft.doc_sync_create(c)
    sf.completion  = ft.completion_feature_create(c)
    sf.hover       = ft.hover_feature_create(c)
    sf.definition  = ft.definition_feature_create(c)
    sf.references  = ft.references_feature_create(c)
    sf.sig_help    = ft.sig_help_feature_create(c)
    sf.sem_tokens  = ft.semantic_tokens_feature_create(c)
    sf.code_actions = ft.code_actions_feature_create(c)
    sf.formatting  = ft.formatting_feature_create(c)
    sf.rename_     = ft.rename_feature_create(c)
    sf.inlay_hints = ft.inlay_hints_feature_create(c)

    // Diagnostics routes through the bridge callback
    diag_data := new(_Diag_Bridge_Data)
    diag_data.bridge = b
    sf.diagnostics = ft.diagnostics_feature_create(c, _on_diag, diag_data)

    sync.mutex_lock(&b.mu)
    b.features[lang] = sf
    sync.mutex_unlock(&b.mu)

    return sf
}

// _Diag_Bridge_Data carries bridge ptr for the diagnostics callback shim.
_Diag_Bridge_Data :: struct {
    bridge: ^Bridge,
}

_on_diag :: proc(uri: string, diags: []proto.Diagnostic, user: rawptr) {
    d := cast(^_Diag_Bridge_Data)user
    if d.bridge.on_diagnostics != nil {
        d.bridge.on_diagnostics(uri, diags, d.bridge.diag_user)
    } else {
        ft.diagnostics_destroy_slice(diags)
    }
}

// _find_root_uri walks parent directories for project markers.
// Returns file:// URI of root.
_find_root_uri :: proc(abs_path: string) -> string {
    markers := [?]string{"ols.json","Cargo.toml","go.mod","pom.xml",".git","package.json"}
    dir := _path_dirname(abs_path)
    for dir != "" && dir != "/" {
        for m in markers {
            check := fmt.tprintf("%s/%s", dir, m)
            if _file_exists(check) {
                return proto.path_to_uri(dir)
            }
        }
        parent := _path_dirname(dir)
        if parent == dir { break }
        dir = parent
    }
    return proto.path_to_uri(dir if dir != "" else "/")
}

_path_dirname :: proc(p: string) -> string {
    for i := len(p) - 1; i >= 0; i -= 1 {
        if p[i] == '/' && i > 0 { return p[:i] }
    }
    return "/"
}

_file_exists :: proc(path: string) -> bool {
    import "core:os"
    _, err := os.stat(path)
    return err == nil
}
