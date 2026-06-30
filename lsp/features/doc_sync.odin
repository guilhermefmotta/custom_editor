package lsp_features

import conn "../connection"
import proto "../protocol"
import "core:fmt"
import "core:strings"
import "core:sync"

Doc_Sync :: struct {
	c:          ^conn.Conn,
	version_mu: sync.Mutex,
	version_map: map[string]int,
}

doc_sync_create :: proc(c: ^conn.Conn) -> ^Doc_Sync {
	ds := new(Doc_Sync)
	ds.c = c
	ds.version_map = make(map[string]int)
	return ds
}

doc_sync_destroy :: proc(ds: ^Doc_Sync) {
	for k in ds.version_map { delete(k) }
	delete(ds.version_map)
	free(ds)
}

doc_sync_did_open :: proc(ds: ^Doc_Sync, uri, language_id, text: string) {
	sync.mutex_lock(&ds.version_mu)
	if _, exists := ds.version_map[uri]; !exists {
		ds.version_map[strings.clone(uri)] = 1
	}
	sync.mutex_unlock(&ds.version_mu)

	params := fmt.tprintf(
		`{"textDocument":{"uri":%s,"languageId":%s,"version":1,"text":%s}}`,
		proto.json_str(uri), proto.json_str(language_id), proto.json_str(text),
	)
	conn.send_notification(ds.c, "textDocument/didOpen", params)
}

doc_sync_did_change :: proc(ds: ^Doc_Sync, uri, full_text: string) {
	sync.mutex_lock(&ds.version_mu)
	ver := ds.version_map[uri] + 1
	ds.version_map[uri] = ver
	sync.mutex_unlock(&ds.version_mu)

	params := fmt.tprintf(
		`{"textDocument":{"uri":%s,"version":%d},"contentChanges":[{"text":%s}]}`,
		proto.json_str(uri), ver, proto.json_str(full_text),
	)
	conn.send_notification(ds.c, "textDocument/didChange", params)
}

doc_sync_did_close :: proc(ds: ^Doc_Sync, uri: string) {
	sync.mutex_lock(&ds.version_mu)
	for k in ds.version_map {
		if k == uri {
			delete(k)
			break
		}
	}
	delete_key(&ds.version_map, uri)
	sync.mutex_unlock(&ds.version_mu)

	params := fmt.tprintf(`{"textDocument":{"uri":%s}}`, proto.json_str(uri))
	conn.send_notification(ds.c, "textDocument/didClose", params)
}

doc_sync_did_save :: proc(ds: ^Doc_Sync, uri: string) {
	params := fmt.tprintf(`{"textDocument":{"uri":%s}}`, proto.json_str(uri))
	conn.send_notification(ds.c, "textDocument/didSave", params)
}
