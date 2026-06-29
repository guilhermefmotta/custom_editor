package editor

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import lsp "./lsp"

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
}

lsp_destroy :: proc(e: ^Editor) {
	lsp.lsp_manager_destroy(&e.lsp_mgr)
	for &p in e.panes { pane_lsp_destroy(&p.lsp) }
}

_lsp_find_root :: proc(e: ^Editor) -> string {
	p := active_pane(e)
	if p.filename != "" {
		dir := _path_dirname(p.filename)
		markers := [?]string{"ols.json","Cargo.toml","go.mod","pom.xml","build.gradle",".git","package.json"}
		for dir != "" && dir != "/" {
			for marker in markers {
				if _file_exists(fmt.tprintf("%s/%s", dir, marker)) { return dir }
			}
			dir = _path_dirname(dir)
		}
		return _path_dirname(p.filename)
	}
	return "."
}

// ---------------------------------------------------------------------------
// Per-frame update
// ---------------------------------------------------------------------------

lsp_update :: proc(e: ^Editor, dt: f32) {
	lsp.lsp_manager_update(&e.lsp_mgr)

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

	// Sync suggest widget every frame
	c := _get_client(e, p)
	if c != nil { _sync_suggest_widget(p, c) }
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

	ch := _char_before_cursor(p)
	if _is_ident_char(ch) {
		_maybe_trigger_completion(e, p, ch, false)
	} else if _is_trigger_char(e, p, ch) {
		_maybe_trigger_completion(e, p, ch, true)
	} else {
		c := _get_client(e, p)
		if c != nil { lsp.completion_cancel(c) }
		p.suggest.visible = false
	}

	// Signature help on ( or ,
	if ch == '(' || ch == ',' {
		line, char := _cursor_lsp_pos(p)
		lsp.manager_sig_help(&e.lsp_mgr, p.filename, line, char)
		p.lsp.show_sig_help = true
	} else if ch == ')' {
		c := _get_client(e, p)
		if c != nil { lsp.sig_help_clear(c) }
		p.lsp.show_sig_help = false
	}
}

lsp_on_cursor_moved :: proc(e: ^Editor, p: ^Pane) {
	if p.filename == "" { return }
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
	p.suggest.visible = false
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
