package editor

import rl "vendor:raylib"

Lang :: enum {
	None,
	Odin,
	C,
	Python,
	JavaScript,
	Go,
	Rust,
	Java,
	Kotlin,
	YAML,
	Properties,
}

Token_Kind :: enum {
	Default,
	Keyword,
	Type,
	String_Lit,
	Number,
	Comment,
	Operator,
	Builtin,
	Macro,
	Attribute,
}

TOKEN_COLORS: [Token_Kind]rl.Color = {
	.Default    = {205, 214, 244, 255},
	.Keyword    = {203, 166, 247, 255}, // mauve
	.Type       = {137, 220, 235, 255}, // sky
	.String_Lit = {166, 227, 161, 255}, // green
	.Number     = {250, 179, 135, 255}, // peach
	.Comment    = {88,  91,  112, 255}, // surface2 (gray)
	.Operator   = {137, 180, 250, 255}, // blue
	.Builtin    = {243, 139, 168, 255}, // red
	.Macro      = {250, 179, 135, 255}, // peach
	.Attribute  = {148, 226, 213, 255}, // teal
}

Span :: struct {
	start: int,
	len:   int,
	kind:  Token_Kind,
}

detect_lang :: proc(path: string) -> Lang {
	dot := -1
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '.' { dot = i; break }
		if path[i] == '/' || path[i] == '\\' { break }
	}
	if dot < 0 do return .None
	switch path[dot + 1:] {
	case "odin":                        return .Odin
	case "c", "h", "cpp", "cc", "hpp": return .C
	case "py":                          return .Python
	case "js", "ts", "jsx", "tsx":     return .JavaScript
	case "go":                          return .Go
	case "rs":                          return .Rust
	case "java":                        return .Java
	case "kt", "kts":                   return .Kotlin
	case "yml", "yaml":                 return .YAML
	case "properties", "gradle":        return .Properties
	}
	return .None
}

tokenize_line :: proc(line: string, lang: Lang) -> []Span {
	if lang == .None || len(line) == 0 do return nil
	spans := make([dynamic]Span, context.temp_allocator)
	i, n  := 0, len(line)

	for i < n {
		ch := line[i]

		// Whitespace — no span, default color
		if ch == ' ' || ch == '\t' { i += 1; continue }

		// Block comment  /* ... */
		if ch == '/' && i+1 < n && line[i+1] == '*' && lang != .Python {
			start := i; i += 2
			for i+1 < n && !(line[i] == '*' && line[i+1] == '/') { i += 1 }
			if i+1 < n { i += 2 } else { i = n }
			append(&spans, Span{start, i - start, .Comment})
			continue
		}

		// Line comments
		if ch == '/' && i+1 < n && line[i+1] == '/' && lang != .Python {
			append(&spans, Span{i, n - i, .Comment}); break
		}
		if ch == '#' && (lang == .Python || lang == .YAML || lang == .Properties) {
			append(&spans, Span{i, n - i, .Comment}); break
		}
		if ch == '!' && lang == .Properties {
			append(&spans, Span{i, n - i, .Comment}); break
		}

		// Preprocessor/directive  #word  (C, Odin)
		if ch == '#' && (lang == .C || lang == .Odin) {
			start := i; i += 1
			for i < n && (is_alpha(line[i]) || is_digit(line[i]) || line[i] == '_') { i += 1 }
			append(&spans, Span{start, i - start, .Macro})
			continue
		}

		// Odin attribute  @tag or @(...)
		if ch == '@' && lang == .Odin {
			start := i; i += 1
			if i < n && line[i] == '(' {
				for i < n && line[i] != ')' { i += 1 }
				if i < n { i += 1 }
			} else {
				for i < n && (is_alpha(line[i]) || line[i] == '_') { i += 1 }
			}
			append(&spans, Span{start, i - start, .Attribute})
			continue
		}

		// String: "..." or `...`
		if ch == '"' || ch == '`' {
			quote := ch; start := i; i += 1
			for i < n {
				if line[i] == '\\' && quote != '`' { i += 2; continue }
				if line[i] == quote                { i += 1; break }
				i += 1
			}
			append(&spans, Span{start, i - start, .String_Lit})
			continue
		}

		// String / char: '...'
		if ch == '\'' {
			start := i; i += 1
			for i < n {
				if line[i] == '\\' { i += 2; continue }
				if line[i] == '\'' { i += 1; break }
				i += 1
			}
			append(&spans, Span{start, i - start, .String_Lit})
			continue
		}

		// Number (decimal, 0x, 0b, 0o)
		if is_digit(ch) || (ch == '.' && i+1 < n && is_digit(line[i+1])) {
			start := i
			if ch == '0' && i+1 < n {
				switch line[i+1] {
				case 'x', 'X':
					i += 2
					for i < n && is_hex(line[i]) { i += 1 }
					append(&spans, Span{start, i - start, .Number}); continue
				case 'b', 'B':
					i += 2
					for i < n && (line[i] == '0' || line[i] == '1' || line[i] == '_') { i += 1 }
					append(&spans, Span{start, i - start, .Number}); continue
				case 'o', 'O':
					i += 2
					for i < n && line[i] >= '0' && line[i] <= '7' { i += 1 }
					append(&spans, Span{start, i - start, .Number}); continue
				}
			}
			i += 1
			for i < n && (is_digit(line[i]) || line[i] == '.' || line[i] == '_' ||
			              line[i] == 'e'    || line[i] == 'E') { i += 1 }
			for i < n && is_alpha(line[i]) { i += 1 } // numeric suffix
			append(&spans, Span{start, i - start, .Number})
			continue
		}

		// Identifier / keyword
		if is_alpha(ch) || ch == '_' {
			start := i; i += 1
			for i < n && (is_alpha(line[i]) || is_digit(line[i]) || line[i] == '_' ||
			              (lang == .YAML && line[i] == '-')) { i += 1 }
			// YAML key: word immediately followed by ':'
			if lang == .YAML && i < n && line[i] == ':' &&
			   (i+1 == n || line[i+1] == ' ' || line[i+1] == '\t') {
				append(&spans, Span{start, i - start, .Keyword})
				continue
			}
			// Properties key: word before '=' or ':'
			if lang == .Properties && i < n && (line[i] == '=' || line[i] == ':') {
				append(&spans, Span{start, i - start, .Keyword})
				continue
			}
			kind := classify_word(line[start:i], lang)
			append(&spans, Span{start, i - start, kind})
			continue
		}

		// Operator (multi-char handled greedily)
		if is_op(ch) {
			start := i; i += 1
			if i < n && is_op(line[i]) {
				switch line[start:i+1] {
				case "->", "::", "=>", "!=", "==", "<=", ">=", "&&", "||",
				     "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", ":=",
				     "..", "**", "<<", ">>":
					i += 1
				}
			}
			append(&spans, Span{start, i - start, .Operator})
			continue
		}

		// Punctuation / brackets — skip (default color)
		i += 1
	}

	return spans[:]
}

classify_word :: proc(word: string, lang: Lang) -> Token_Kind {
	switch lang {
	case .Odin:
		switch word {
		case "package", "import", "proc", "struct", "enum", "union", "map",
		     "bit_set", "if", "else", "when", "for", "in", "not_in", "return",
		     "defer", "switch", "case", "do", "break", "continue", "fallthrough",
		     "using", "distinct", "dynamic", "auto_cast", "cast", "transmute",
		     "nil", "true", "false", "or_return", "or_else", "where", "context":
			return .Keyword
		case "int", "uint", "i8", "i16", "i32", "i64", "i128",
		     "u8", "u16", "u32", "u64", "u128", "f16", "f32", "f64",
		     "bool", "b8", "b16", "b32", "b64", "string", "cstring",
		     "rune", "byte", "uintptr", "rawptr", "typeid", "any",
		     "i16le", "i32le", "i64le", "u16le", "u32le", "u64le",
		     "i16be", "i32be", "i64be", "u16be", "u32be", "u64be":
			return .Type
		case "len", "cap", "make", "new", "free", "delete", "append", "pop",
		     "copy", "clear", "reserve", "resize", "min", "max", "abs", "clamp",
		     "assert", "panic", "size_of", "align_of", "offset_of", "type_of",
		     "print", "println", "printf", "unimplemented", "unreachable",
		     "inject_at", "ordered_remove", "unordered_remove":
			return .Builtin
		}
	case .C:
		switch word {
		case "auto", "break", "case", "const", "continue", "default", "do",
		     "else", "enum", "extern", "for", "goto", "if", "inline", "register",
		     "restrict", "return", "sizeof", "static", "struct", "switch",
		     "typedef", "union", "volatile", "while", "NULL", "true", "false":
			return .Keyword
		case "void", "char", "short", "int", "long", "float", "double",
		     "signed", "unsigned", "bool", "_Bool",
		     "int8_t", "int16_t", "int32_t", "int64_t",
		     "uint8_t", "uint16_t", "uint32_t", "uint64_t",
		     "size_t", "ptrdiff_t", "intptr_t", "uintptr_t":
			return .Type
		case "printf", "scanf", "malloc", "free", "calloc", "realloc",
		     "memcpy", "memset", "memmove", "strlen", "strcpy", "strcmp",
		     "fprintf", "sprintf", "snprintf", "fopen", "fclose":
			return .Builtin
		}
	case .Python:
		switch word {
		case "and", "as", "assert", "async", "await", "break", "class",
		     "continue", "def", "del", "elif", "else", "except", "finally",
		     "for", "from", "global", "if", "import", "in", "is", "lambda",
		     "nonlocal", "not", "or", "pass", "raise", "return", "try",
		     "while", "with", "yield", "True", "False", "None":
			return .Keyword
		case "int", "float", "str", "bool", "list", "dict", "set", "tuple",
		     "bytes", "bytearray", "type", "object", "complex", "frozenset":
			return .Type
		case "print", "len", "range", "enumerate", "zip", "map", "filter",
		     "sorted", "reversed", "isinstance", "issubclass", "hasattr",
		     "getattr", "setattr", "super", "property", "open", "input",
		     "repr", "id", "hash", "abs", "min", "max", "sum", "all", "any",
		     "chr", "ord", "hex", "bin", "oct", "round":
			return .Builtin
		}
	case .JavaScript:
		switch word {
		case "break", "case", "catch", "class", "const", "continue", "debugger",
		     "default", "delete", "do", "else", "export", "extends", "finally",
		     "for", "function", "if", "import", "in", "instanceof", "let",
		     "new", "of", "return", "static", "super", "switch", "this", "throw",
		     "try", "typeof", "var", "void", "while", "with", "yield",
		     "async", "await", "from", "as", "true", "false", "null", "undefined":
			return .Keyword
		case "string", "number", "boolean", "object", "any", "never",
		     "unknown", "interface", "type", "enum", "namespace", "declare",
		     "readonly", "abstract", "implements", "override":
			return .Type
		case "console", "Math", "JSON", "Object", "Array", "String",
		     "Number", "Boolean", "Promise", "Symbol", "Error", "Map", "Set",
		     "parseInt", "parseFloat", "isNaN", "isFinite", "fetch":
			return .Builtin
		}
	case .Go:
		switch word {
		case "break", "case", "chan", "const", "continue", "default", "defer",
		     "else", "fallthrough", "for", "func", "go", "goto", "if", "import",
		     "interface", "map", "package", "range", "return", "select",
		     "struct", "switch", "type", "var", "true", "false", "nil":
			return .Keyword
		case "bool", "byte", "complex64", "complex128", "error", "float32",
		     "float64", "int", "int8", "int16", "int32", "int64", "rune",
		     "string", "uint", "uint8", "uint16", "uint32", "uint64", "uintptr":
			return .Type
		case "append", "cap", "close", "complex", "copy", "delete", "imag",
		     "len", "make", "new", "panic", "print", "println", "real", "recover":
			return .Builtin
		}
	case .Rust:
		switch word {
		case "as", "break", "const", "continue", "crate", "dyn", "else", "enum",
		     "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop",
		     "match", "mod", "move", "mut", "pub", "ref", "return", "self",
		     "Self", "static", "struct", "super", "trait", "true", "type",
		     "unsafe", "use", "where", "while", "async", "await":
			return .Keyword
		case "bool", "char", "f32", "f64", "i8", "i16", "i32", "i64", "i128",
		     "isize", "str", "u8", "u16", "u32", "u64", "u128", "usize",
		     "String", "Vec", "Option", "Result", "Box", "Rc", "Arc",
		     "HashMap", "HashSet", "BTreeMap", "BTreeSet":
			return .Type
		case "println", "print", "eprintln", "eprint", "panic", "assert",
		     "assert_eq", "assert_ne", "todo", "unimplemented", "unreachable",
		     "Some", "None", "Ok", "Err", "vec", "format", "write", "writeln":
			return .Builtin
		}
	case .Java:
		switch word {
		case "abstract", "assert", "break", "case", "catch", "class", "const",
		     "continue", "default", "do", "else", "enum", "extends", "final",
		     "finally", "for", "goto", "if", "implements", "import", "instanceof",
		     "interface", "native", "new", "null", "package", "private", "protected",
		     "public", "return", "static", "strictfp", "super", "switch",
		     "synchronized", "this", "throw", "throws", "transient", "true", "false",
		     "try", "var", "void", "volatile", "while", "record", "sealed", "permits",
		     "yield":
			return .Keyword
		case "boolean", "byte", "char", "double", "float", "int", "long", "short",
		     "String", "Object", "Number", "Integer", "Long", "Double", "Float",
		     "Boolean", "Character", "Byte", "Short", "StringBuilder", "StringBuffer",
		     "List", "ArrayList", "LinkedList", "Map", "HashMap", "Set", "HashSet",
		     "Iterator", "Iterable", "Comparable", "Runnable", "Thread":
			return .Type
		case "System", "Math", "Arrays", "Collections", "Optional", "Stream",
		     "println", "print", "printf", "format", "length", "size", "get", "put",
		     "add", "remove", "contains", "equals", "hashCode", "toString",
		     "valueOf", "parseInt", "parseLong", "parseDouble":
			return .Builtin
		}
	case .Kotlin:
		switch word {
		case "abstract", "actual", "annotation", "as", "break", "by", "catch", "class",
		     "companion", "const", "constructor", "continue", "crossinline", "data",
		     "delegate", "do", "dynamic", "else", "enum", "expect", "external", "false",
		     "field", "file", "final", "finally", "for", "fun", "get", "if", "import",
		     "in", "infix", "init", "inline", "inner", "interface", "internal", "is",
		     "it", "lateinit", "noinline", "null", "object", "open", "operator", "out",
		     "override", "package", "param", "private", "protected", "public", "receiver",
		     "reified", "return", "sealed", "set", "setparam", "super", "suspend",
		     "tailrec", "this", "throw", "true", "try", "typealias", "typeof", "val",
		     "value", "var", "vararg", "when", "where", "while":
			return .Keyword
		case "Boolean", "Byte", "Char", "Double", "Float", "Int", "Long", "Short",
		     "String", "Unit", "Any", "Nothing", "Array", "List", "MutableList",
		     "Map", "MutableMap", "Set", "MutableSet", "Pair", "Triple",
		     "Collection", "Sequence", "Flow", "StateFlow", "SharedFlow":
			return .Type
		case "println", "print", "readLine", "TODO", "error", "check", "require",
		     "also", "apply", "let", "run", "with", "repeat", "forEach", "map",
		     "filter", "fold", "reduce", "firstOrNull", "lastOrNull", "takeIf",
		     "takeUnless", "listOf", "mutableListOf", "mapOf", "mutableMapOf",
		     "setOf", "mutableSetOf", "emptyList", "emptyMap", "emptySet":
			return .Builtin
		}
	case .YAML:
		switch word {
		case "true", "false", "null", "yes", "no", "on", "off":
			return .Keyword
		}
	case .Properties:
		switch word {
		case "true", "false":
			return .Keyword
		}
	case .None:
	}
	return .Default
}

// Draw line with syntax-colored spans. Gaps between spans use TEXT color.
// Tracks x with MeasureTextEx so UTF-8 stays aligned.
draw_highlighted_line :: proc(font: rl.Font, line: []u8, x, y: f32, lang: Lang) {
	if len(line) == 0 do return
 
	if lang == .None {
		rl.DrawTextEx(font, to_cstring(string(line)), {x, y}, FONT_SIZE, CHAR_SPACING, TEXT)
		return
	}

	spans := tokenize_line(string(line), lang)
	cur_x := x
	prev  := 0

	draw_seg :: proc(font: rl.Font, s: string, x, y: f32, col: rl.Color) -> f32 {
		if len(s) == 0 do return 0
		cs := to_cstring(s)
		rl.DrawTextEx(font, cs, {x, y}, FONT_SIZE, CHAR_SPACING, col)
		return rl.MeasureTextEx(font, cs, FONT_SIZE, CHAR_SPACING).x
	}

	for span in spans {
		if span.start > prev {
			cur_x += draw_seg(font, string(line[prev:span.start]), cur_x, y, TEXT)
		}
		cur_x += draw_seg(font, string(line[span.start:span.start + span.len]),
		                  cur_x, y, TOKEN_COLORS[span.kind])
		prev = span.start + span.len
	}
	if prev < len(line) {
		draw_seg(font, string(line[prev:]), cur_x, y, TEXT)
	}
}

// --- Char class helpers ---

is_alpha :: proc(ch: u8) -> bool {
	return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
}
is_digit :: proc(ch: u8) -> bool { return ch >= '0' && ch <= '9' }
is_hex   :: proc(ch: u8) -> bool {
	return is_digit(ch) || (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F') || ch == '_'
}
is_op :: proc(ch: u8) -> bool {
	switch ch {
	case '+', '-', '*', '/', '%', '&', '|', '^', '~', '!', '=', '<', '>', '?', ':':
		return true
	}
	return false
}
