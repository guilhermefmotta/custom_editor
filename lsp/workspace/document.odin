package lsp_workspace

import proto "../protocol"
import "core:strings"

Language_ID :: enum u8 {
	Unknown,
	Odin,
	C,
	Cpp,
	Go,
	Rust,
	Python,
	JavaScript,
	TypeScript,
	JSON,
	TOML,
	Markdown,
}

Document :: struct {
	uri:         string,
	path:        string,
	language_id: Language_ID,
	version:     int,
	open:        bool,
}

language_id_string :: proc(id: Language_ID) -> string {
	switch id {
	case .Odin:       return "odin"
	case .C:          return "c"
	case .Cpp:        return "cpp"
	case .Go:         return "go"
	case .Rust:       return "rust"
	case .Python:     return "python"
	case .JavaScript: return "javascript"
	case .TypeScript: return "typescript"
	case .JSON:       return "json"
	case .TOML:       return "toml"
	case .Markdown:   return "markdown"
	case .Unknown:    return "plaintext"
	}
	return "plaintext"
}

detect_language :: proc(ext: string) -> Language_ID {
	switch ext {
	case "odin":                                    return .Odin
	case "c", "h":                                  return .C
	case "cc", "cpp", "cxx", "hh", "hpp", "hxx":   return .Cpp
	case "go":                                      return .Go
	case "rs":                                      return .Rust
	case "py":                                      return .Python
	case "js", "mjs":                               return .JavaScript
	case "ts", "tsx":                               return .TypeScript
	case "json":                                    return .JSON
	case "toml":                                    return .TOML
	case "md", "markdown":                          return .Markdown
	}
	return .Unknown
}

document_create :: proc(abs_path: string, lang: Language_ID) -> ^Document {
	d             := new(Document)
	d.path         = strings.clone(abs_path)
	uri_temp      := proto.path_to_uri(abs_path)
	d.uri          = strings.clone(uri_temp)
	d.language_id  = lang
	d.version      = 0
	d.open         = false
	return d
}

document_destroy :: proc(d: ^Document) {
	delete(d.uri)
	delete(d.path)
	free(d)
}

document_increment_version :: proc(d: ^Document) -> int {
	d.version += 1
	return d.version
}
