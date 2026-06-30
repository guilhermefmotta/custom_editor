package lsp_workspace

import proto "../protocol"
import "core:strings"
import "core:sync"

Doc_Manager :: struct {
	mu:   sync.Mutex,
	docs: map[string]^Document,
}

doc_manager_create :: proc() -> ^Doc_Manager {
	dm      := new(Doc_Manager)
	dm.docs  = make(map[string]^Document)
	return dm
}

doc_manager_destroy :: proc(dm: ^Doc_Manager) {
	sync.mutex_lock(&dm.mu)
	for key, doc in dm.docs {
		document_destroy(doc)
		delete(key)
	}
	delete(dm.docs)
	sync.mutex_unlock(&dm.mu)
	free(dm)
}

doc_manager_get_or_create :: proc(dm: ^Doc_Manager, abs_path: string) -> (doc: ^Document, is_new: bool) {
	uri_temp := proto.path_to_uri(abs_path)
	uri      := strings.clone(uri_temp)
	defer delete(uri)

	sync.mutex_lock(&dm.mu)
	if d, ok := dm.docs[uri]; ok {
		sync.mutex_unlock(&dm.mu)
		return d, false
	}
	ext  := proto.path_ext(abs_path)
	lang := detect_language(ext)
	d    := document_create(abs_path, lang)
	dm.docs[strings.clone(d.uri)] = d
	sync.mutex_unlock(&dm.mu)
	return d, true
}

doc_manager_get :: proc(dm: ^Doc_Manager, uri: string) -> (^Document, bool) {
	sync.mutex_lock(&dm.mu)
	d, ok := dm.docs[uri]
	sync.mutex_unlock(&dm.mu)
	return d, ok
}

doc_manager_get_by_path :: proc(dm: ^Doc_Manager, abs_path: string) -> (^Document, bool) {
	uri_temp := proto.path_to_uri(abs_path)
	uri      := strings.clone(uri_temp, context.temp_allocator)
	return doc_manager_get(dm, uri)
}

doc_manager_remove :: proc(dm: ^Doc_Manager, uri: string) {
	sync.mutex_lock(&dm.mu)
	if d, ok := dm.docs[uri]; ok {
		document_destroy(d)
		key := uri
		delete_key(&dm.docs, uri)
		delete(key)
	}
	sync.mutex_unlock(&dm.mu)
}

doc_manager_all_uris :: proc(dm: ^Doc_Manager, allocator := context.allocator) -> []string {
	sync.mutex_lock(&dm.mu)
	result := make([]string, len(dm.docs), allocator)
	i := 0
	for uri in dm.docs {
		result[i] = strings.clone(uri, allocator)
		i += 1
	}
	sync.mutex_unlock(&dm.mu)
	return result
}
