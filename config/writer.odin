package config

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

// ===========================================================================
// Config writer (ADR 0003 — gravação do editor.toml)
//
// There is no round-trip TOML serializer: settings are written by patching
// ONE line of the file (`key = value`), so comments, blank lines, key order
// and formatting of everything else survive byte-for-byte. A value's
// trailing `# comment` is kept too.
//
// Safety rules of config_write_value:
//   - the current file must pass toml_validate, otherwise nothing is written
//     (the lenient loader skips bad lines; rewriting would make that silent
//     data loss permanent) and the caller shows "fix it by hand";
//   - the patched text is validated again and the value is read back before
//     anything touches the disk;
//   - the new content goes to `<path>.tmp` and is renamed over the original
//     (atomic replace on POSIX; MoveFileEx REPLACE_EXISTING on Windows), so a
//     crash mid-write never leaves a truncated editor.toml.
//
// Settings editable from the settings screen are described by `Setting`:
// config_setting_parse validates user input, config_setting_literal turns a
// value into TOML, config_setting_get/config_setting_set read/apply it on a
// Config.
// ===========================================================================

Setting :: enum u8 {
	Theme,
	Font_Family,
	Font_Size,
	Keymap_Mode,
	Tab_Size,
	Word_Wrap,
	Auto_Save,
	Auto_Save_Delay,
}

// Location of each setting in editor.toml ("" section = top level).
Setting_Location :: struct { section, key: string }

SETTING_LOCATION := [Setting]Setting_Location{
	.Theme           = {"",       "theme"},
	.Font_Family     = {"font",   "family"},
	.Font_Size       = {"font",   "size"},
	.Keymap_Mode     = {"editor", "keymap_mode"},
	.Tab_Size        = {"editor", "tab_size"},
	.Word_Wrap       = {"editor", "word_wrap"},
	.Auto_Save       = {"editor", "auto_save"},
	.Auto_Save_Delay = {"editor", "auto_save_delay"},
}

FONT_SIZE_MIN       :: 8   // same clamp as Ctrl+= / Ctrl+-
FONT_SIZE_MAX       :: 72
TAB_SIZE_MIN        :: 1
TAB_SIZE_MAX        :: 16
AUTO_SAVE_DELAY_MIN :: 0.1
AUTO_SAVE_DELAY_MAX :: 600.0

// Parsed value of a Setting; only the field matching the setting is used.
Setting_Value :: struct {
	str:  string, // Theme, Font_Family — aliases the input/Config, not owned
	num:  int,    // Font_Size, Tab_Size
	f:    f64,    // Auto_Save_Delay
	b:    bool,   // Word_Wrap, Auto_Save
	mode: Keymap_Mode,
}

keymap_mode_id :: proc(m: Keymap_Mode) -> string {
	switch m {
	case .Normal: return "normal"
	case .Vim:    return "vim"
	case .Emacs:  return "emacs"
	}
	return "normal"
}

// Validate user input for a setting. `themes` = names known to the theme
// registry. err is "" on success (otherwise a static or temp string).
config_setting_parse :: proc(s: Setting, raw: string, themes: []string) -> (v: Setting_Value, err: string) {
	in_ := strings.trim_space(raw)
	switch s {
	case .Theme:
		for t in themes { if t == in_ { v.str = in_; return v, "" } }
		if in_ == "" { return v, "theme name is empty" }
		return v, fmt.tprintf("unknown theme %q", in_)

	case .Font_Family:
		if in_ == "" { return v, "font path is empty" }
		ext := strings.to_lower(filepath.ext(in_), context.temp_allocator)
		if ext != ".ttf" && ext != ".otf" && ext != ".ttc" {
			return v, "font must be a .ttf, .otf or .ttc file"
		}
		if !os.exists(in_) { return v, fmt.tprintf("font file not found: %s", in_) }
		v.str = in_
		return v, ""

	case .Font_Size:
		n, ok := strconv.parse_int(in_, 10)
		if !ok { return v, "font size must be a whole number" }
		if n < FONT_SIZE_MIN || n > FONT_SIZE_MAX {
			return v, fmt.tprintf("font size must be between %d and %d", FONT_SIZE_MIN, FONT_SIZE_MAX)
		}
		v.num = n
		return v, ""

	case .Tab_Size:
		n, ok := strconv.parse_int(in_, 10)
		if !ok { return v, "tab size must be a whole number" }
		if n < TAB_SIZE_MIN || n > TAB_SIZE_MAX {
			return v, fmt.tprintf("tab size must be between %d and %d", TAB_SIZE_MIN, TAB_SIZE_MAX)
		}
		v.num = n
		return v, ""

	case .Keymap_Mode:
		switch strings.to_lower(in_, context.temp_allocator) {
		case "normal": v.mode = .Normal
		case "vim":    v.mode = .Vim
		case "emacs":  v.mode = .Emacs
		case:          return v, "keymap mode must be normal, vim or emacs"
		}
		return v, ""

	case .Word_Wrap, .Auto_Save:
		switch strings.to_lower(in_, context.temp_allocator) {
		case "true", "on", "yes", "1":  v.b = true
		case "false", "off", "no", "0": v.b = false
		case: return v, "expected on/off"
		}
		return v, ""

	case .Auto_Save_Delay:
		f, ok := strconv.parse_f64(in_)
		if !ok || f != f { return v, "auto save delay must be a number of seconds" }
		if f < AUTO_SAVE_DELAY_MIN || f > AUTO_SAVE_DELAY_MAX {
			return v, fmt.tprintf("auto save delay must be between %.1f and %.0f seconds", AUTO_SAVE_DELAY_MIN, AUTO_SAVE_DELAY_MAX)
		}
		v.f = f
		return v, ""
	}
	return v, "unknown setting"
}

// TOML literal for a value (e.g. `"gruvbox"`, `14`, `true`, `1.5`).
config_setting_literal :: proc(s: Setting, v: Setting_Value, allocator := context.temp_allocator) -> string {
	switch s {
	case .Theme, .Font_Family: return toml_quote(v.str, allocator)
	case .Keymap_Mode:         return toml_quote(keymap_mode_id(v.mode), allocator)
	case .Font_Size, .Tab_Size: return fmt.aprintf("%d", v.num, allocator = allocator)
	case .Word_Wrap, .Auto_Save: return strings.clone("true" if v.b else "false", allocator)
	case .Auto_Save_Delay:     return toml_float_literal(v.f, allocator)
	}
	return ""
}

// Human-readable value (UI).
config_setting_display :: proc(s: Setting, v: Setting_Value, allocator := context.temp_allocator) -> string {
	switch s {
	case .Theme, .Font_Family:   return strings.clone(v.str, allocator)
	case .Keymap_Mode:           return strings.clone(keymap_mode_id(v.mode), allocator)
	case .Font_Size, .Tab_Size:  return fmt.aprintf("%d", v.num, allocator = allocator)
	case .Word_Wrap, .Auto_Save: return strings.clone("on" if v.b else "off", allocator)
	case .Auto_Save_Delay:       return toml_float_literal(v.f, allocator)
	}
	return ""
}

config_setting_get :: proc(c: ^Config, s: Setting) -> (v: Setting_Value) {
	switch s {
	case .Theme:           v.str  = c.theme_name
	case .Font_Family:     v.str  = c.font.family
	case .Font_Size:       v.num  = c.font.size
	case .Keymap_Mode:     v.mode = c.editor.keymap_mode
	case .Tab_Size:        v.num  = c.editor.tab_size
	case .Word_Wrap:       v.b    = c.editor.word_wrap
	case .Auto_Save:       v.b    = c.editor.auto_save
	case .Auto_Save_Delay: v.f    = f64(c.editor.auto_save_delay)
	}
	return
}

// Store a (validated) value in the Config; strings are cloned (Config owns them).
config_setting_set :: proc(c: ^Config, s: Setting, v: Setting_Value) {
	switch s {
	case .Theme:           _replace_str(&c.theme_name, v.str)
	case .Font_Family:     _replace_str(&c.font.family, v.str)
	case .Font_Size:       c.font.size              = v.num
	case .Keymap_Mode:     c.editor.keymap_mode     = v.mode
	case .Tab_Size:        c.editor.tab_size        = v.num
	case .Word_Wrap:       c.editor.word_wrap       = v.b
	case .Auto_Save:       c.editor.auto_save       = v.b
	case .Auto_Save_Delay: c.editor.auto_save_delay = f32(v.f)
	}
}

// Persist one setting into the TOML file at `path` (see safety rules above).
config_write_setting :: proc(path: string, s: Setting, v: Setting_Value) -> (ok: bool, err: string) {
	loc := SETTING_LOCATION[s]
	return config_write_value(path, loc.section, loc.key, config_setting_literal(s, v))
}

// Basic TOML string with escapes (Windows paths keep their backslashes).
toml_quote :: proc(s: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '"')
	for ch in s {
		switch ch {
		case '"':  strings.write_string(&b, `\"`)
		case '\\': strings.write_string(&b, `\\`)
		case '\n': strings.write_string(&b, `\n`)
		case '\t': strings.write_string(&b, `\t`)
		case '\r': strings.write_string(&b, `\r`)
		case:
			if ch < 0x20 { fmt.sbprintf(&b, `\u%04x`, int(ch)) } else { strings.write_rune(&b, ch) }
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

// Shortest-ish float literal that is still a TOML float (always has a '.').
toml_float_literal :: proc(f: f64, allocator := context.temp_allocator) -> string {
	s := fmt.tprintf("%.3f", f)
	s = strings.trim_right(s, "0")
	if strings.has_suffix(s, ".") { s = fmt.tprintf("%s0", s) }
	return strings.clone(s, allocator)
}

// ---------------------------------------------------------------------------
// Line patcher (pure)
// ---------------------------------------------------------------------------

// Return `src` with `key = literal` set inside [section] ("" = top level).
//   - existing key: only the value part of that line changes; indentation,
//     spacing around '=', the trailing comment and the line ending stay;
//   - missing key: a line is inserted after the section's last key/value
//     (so separator comments that belong to the next header stay with it);
//   - missing section: `[section]` + the key are appended at the end.
// Everything else is byte-for-byte identical.
toml_patch_value :: proc(src, section, key, literal: string, allocator := context.allocator) -> string {
	context.allocator = context.temp_allocator
	lines := strings.split(src, "\n")
	// A file ending in "\n" splits into a trailing "" — not a real line.
	// CRLF files keep their "\r" at the end of each line.
	had_final_nl := strings.has_suffix(src, "\n")
	if had_final_nl || src == "" { lines = lines[:len(lines)-1] }
	crlf := len(lines) > 0 && strings.has_suffix(lines[0], "\r")

	cur_section := ""         // "" = top level; "\x00" = array-of-tables / unmatchable
	in_target   := section == ""
	section_found := section == ""
	header_idx  := -1         // header line of the target section
	last_kv     := -1         // last line of the last key/value in the target section
	first_header := -1
	depth       := 0          // open [ ] across lines (multi-line arrays)
	in_ml       := ""         // inside a multi-line string: its delimiter
	key_line    := -1

	for line, i in lines {
		if in_ml != "" {
			if strings.count(line, in_ml) % 2 == 1 { in_ml = "" }
			if in_target { last_kv = i }
			continue
		}
		if depth > 0 {
			depth += _bracket_delta(line)
			if depth < 0 { depth = 0 }
			if in_target { last_kv = i }
			continue
		}
		trimmed := strings.trim_space(line)
		if trimmed == "" || trimmed[0] == '#' { continue }
		if trimmed[0] == '[' {
			if first_header < 0 { first_header = i }
			cur_section = _header_name(trimmed)
			in_target = cur_section == section && section != ""
			if in_target && !section_found { section_found = true; header_idx = i }
			else if in_target { in_target = false } // duplicate header: invalid TOML, ignore
			continue
		}
		// key/value line
		if in_target {
			last_kv = i
			if key_line < 0 && _line_key_is(trimmed, key) { key_line = i }
		}
		depth = _bracket_delta(line)
		if depth < 0 { depth = 0 }
		if c := _open_ml_delim(line); c != "" { in_ml = c }
	}

	out := make([dynamic]string, 0, len(lines) + 4)
	cr     := "\r" if crlf else ""
	new_kv := fmt.tprintf("%s = %s%s", key, literal, cr)

	switch {
	case key_line >= 0:
		for l, i in lines {
			if i == key_line { append(&out, _replace_line_value(l, literal)) } else { append(&out, l) }
		}
	case section_found:
		at := last_kv
		if at < 0 {
			if section == "" && first_header >= 0 {
				// no top-level key yet: before the first header, above the
				// comment block glued to it
				at = first_header
				for at > 0 && strings.has_prefix(strings.trim_space(lines[at-1]), "#") { at -= 1 }
				at -= 1 // insert after index `at` (-1 = top of file)
			} else if section == "" {
				at = len(lines) - 1
			} else {
				at = header_idx
			}
		}
		for l in lines[:at+1] { append(&out, l) }
		append(&out, new_kv)
		if section == "" && last_kv < 0 && at + 1 < len(lines) && strings.trim_space(lines[at+1]) != "" {
			append(&out, cr)
		}
		for l in lines[at+1:] { append(&out, l) }
	case:
		for l in lines { append(&out, l) }
		if len(out) > 0 && strings.trim_space(out[len(out)-1]) != "" { append(&out, cr) }
		append(&out, fmt.tprintf("[%s]%s", section, cr))
		append(&out, new_kv)
	}

	joined := strings.join(out[:], "\n")
	// keep a missing final newline missing, unless lines were added
	if had_final_nl || key_line < 0 { joined = strings.concatenate({joined, "\n"}) }
	return strings.clone(joined, allocator)
}

// Patch + validate + atomic write. Creates the file (and its directory) when
// missing. err is a human-readable reason when ok=false.
config_write_value :: proc(path, section, key, literal: string) -> (ok: bool, err: string) {
	src := ""
	if data, rerr := os.read_entire_file(path, context.temp_allocator); rerr == nil {
		src = string(data)
		if valid, line := toml_validate(src); !valid {
			return false, fmt.tprintf("%s has a syntax error near line %d - fix it by hand (not saved)", path, line)
		}
	} else if os.exists(path) {
		return false, fmt.tprintf("cannot read %s", path)
	}

	patched := toml_patch_value(src, section, key, literal, context.temp_allocator)
	if valid, line := toml_validate(patched); !valid {
		return false, fmt.tprintf("refusing to write: result would be invalid near line %d", line)
	}
	if !_readback_matches(patched, section, key, literal) {
		return false, "refusing to write: value did not round-trip"
	}

	dir := filepath.dir(path)
	if dir != "" && dir != "." && !os.exists(dir) {
		if os.make_directory_all(dir) != nil { return false, fmt.tprintf("cannot create %s", dir) }
	}
	tmp := fmt.tprintf("%s.tmp", path)
	if os.write_entire_file(tmp, transmute([]byte)patched) != nil {
		os.remove(tmp)
		return false, fmt.tprintf("cannot write %s", tmp)
	}
	if os.rename(tmp, path) != nil {
		os.remove(tmp)
		return false, fmt.tprintf("cannot replace %s", path)
	}
	return true, ""
}

// config_persist_keymap_mode: kept for the palette's "Set Keymap Mode".
// Same line patch as the settings screen (comment on the line preserved,
// atomic write, never rewrites an invalid file).
config_persist_keymap_mode :: proc(path: string, mode: Keymap_Mode) -> bool {
	ok, _ := config_write_setting(path, .Keymap_Mode, Setting_Value{mode = mode})
	return ok
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// Parse `literal` and the patched document; the key must hold the same value.
@(private)
_readback_matches :: proc(doc, section, key, literal: string) -> bool {
	want_root, _ := toml_parse(fmt.tprintf("v = %s\n", literal))
	defer toml_destroy_table(want_root)
	got_root, _ := toml_parse(doc)
	defer toml_destroy_table(got_root)
	tbl := got_root
	if section != "" {
		t, ok := toml_table(got_root, section)
		if !ok { return false }
		tbl = t
	}
	want, ok1 := want_root^["v"]
	got,  ok2 := tbl^[key]
	if !ok1 || !ok2 || want.kind != got.kind { return false }
	#partial switch want.kind {
	case .Str:   return want.str == got.str
	case .Int:   return want.i == got.i
	case .Float: return want.f == got.f
	case .Bool:  return want.b == got.b
	}
	return false
}

// "[editor]  # c" -> "editor"; "[[build]]" -> "\x00" (never a target).
@(private)
_header_name :: proc(trimmed: string) -> string {
	if strings.has_prefix(trimmed, "[[") { return "\x00" }
	end := strings.index_byte(trimmed, ']')
	if end < 0 { return "\x00" }
	return strings.trim_space(trimmed[1:end])
}

@(private)
_line_key_is :: proc(trimmed, key: string) -> bool {
	rest: string
	switch {
	case strings.has_prefix(trimmed, key):
		rest = trimmed[len(key):]
	case len(trimmed) > len(key) + 1 && (trimmed[0] == '"' || trimmed[0] == '\'') &&
	     strings.has_prefix(trimmed[1:], key) && trimmed[len(key)+1] == trimmed[0]:
		rest = trimmed[len(key)+2:]
	case:
		return false
	}
	rest = strings.trim_left(rest, " \t")
	return strings.has_prefix(rest, "=")
}

// Index where a `# comment` starts outside of strings (-1 = none).
@(private)
_comment_start :: proc(line: string) -> int {
	q: u8 = 0
	for i := 0; i < len(line); i += 1 {
		ch := line[i]
		switch {
		case q == '"' && ch == '\\': i += 1
		case q != 0 && ch == q:      q = 0
		case q == 0 && (ch == '"' || ch == '\''): q = ch
		case q == 0 && ch == '#':    return i
		}
	}
	return -1
}

// Net '[' minus ']' outside strings and comments.
@(private)
_bracket_delta :: proc(line: string) -> int {
	end := _comment_start(line)
	if end < 0 { end = len(line) }
	q: u8 = 0
	d := 0
	for i := 0; i < end; i += 1 {
		ch := line[i]
		switch {
		case q == '"' && ch == '\\': i += 1
		case q != 0 && ch == q:      q = 0
		case q == 0 && (ch == '"' || ch == '\''): q = ch
		case q == 0 && ch == '[':    d += 1
		case q == 0 && ch == ']':    d -= 1
		}
	}
	return d
}

// Multi-line string opened (and not closed) on this line: its delimiter.
@(private)
_open_ml_delim :: proc(line: string) -> string {
	for d in ([]string{`"""`, `'''`}) {
		if strings.count(line, d) % 2 == 1 { return d }
	}
	return ""
}

// Swap the value of a `key = value  # comment` line, keeping the rest.
@(private)
_replace_line_value :: proc(line, literal: string) -> string {
	eq := strings.index_byte(line, '=')
	if eq < 0 { return line }
	cr := strings.has_suffix(line, "\r")
	body := line[:len(line)-1] if cr else line
	vstart := eq + 1
	for vstart < len(body) && (body[vstart] == ' ' || body[vstart] == '\t') { vstart += 1 }
	tail := ""
	if c := _comment_start(body[vstart:]); c >= 0 {
		cstart := vstart + c
		ws := cstart
		for ws > vstart && (body[ws-1] == ' ' || body[ws-1] == '\t') { ws -= 1 }
		tail = body[ws:]
	}
	sep := body[eq+1:vstart]
	if sep == "" { sep = " " }
	return fmt.tprintf("%s%s%s%s%s", body[:eq+1], sep, literal, tail, "\r" if cr else "")
}
