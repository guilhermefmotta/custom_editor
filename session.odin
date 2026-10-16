package editor

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

SESSION_FILE :: "editor_session.json"

// Absolute session path, fixed at startup (session_init_path) so it does not
// follow the cwd when the active repository changes (ADR 0014).
session_file_path: string

session_init_path :: proc() {
	// (filepath.abs resolves with realpath and fails while the file is missing)
	cwd, err := os.get_working_directory(context.temp_allocator)
	if err != nil { session_file_path = strings.clone(SESSION_FILE); return }
	session_file_path, _ = filepath.join({cwd, SESSION_FILE}, context.allocator)
}

@(fini)
_session_fini :: proc "contextless" () {
	context = runtime.default_context()
	delete(session_file_path)
	session_file_path = ""
}

_session_path :: proc() -> string {
	return session_file_path if session_file_path != "" else SESSION_FILE
}

// ---------------------------------------------------------------------------
// Save
//
// {"active":0,"split":"none","split_ratio":0.5,"panes":[...],   ← scratch view (no repo)
//  "active_repo":1,
//  "repos":[{"root":"/abs","active":0,"split":"none","split_ratio":0.5,"panes":[...]}]}
// Older files (only the scratch fields) still restore.
// ---------------------------------------------------------------------------

@(private="file")
_session_json_str :: proc(sb: ^strings.Builder, s: string) {
	escaped,  _ := strings.replace_all(s, `\`, `\\`, context.temp_allocator)
	escaped2, _ := strings.replace_all(escaped, `"`, `\"`, context.temp_allocator)
	strings.write_byte(sb, '"')
	strings.write_string(sb, escaped2)
	strings.write_byte(sb, '"')
}

@(private="file")
_session_write_view :: proc(sb: ^strings.Builder, panes: []Pane, active: int, split: Split_Dir, ratio: f32, layout: Pane_Layout) {
	strings.write_string(sb, fmt.tprintf(`"active":%d,"split":"`, active))
	switch split {
	case .None:       strings.write_string(sb, "none")
	case .Vertical:   strings.write_string(sb, "vertical")
	case .Horizontal: strings.write_string(sb, "horizontal")
	}
	strings.write_string(sb, fmt.tprintf(`","split_ratio":%g,`, ratio))
	l := layout
	if len(panes) > 1 && layout_valid(&l, len(panes)) {
		strings.write_string(sb, `"layout":`)
		_session_json_str(sb, layout_encode(&l))
		strings.write_string(sb, ",")
	}
	strings.write_string(sb, `"panes":[`)
	for p, pi in panes {
		if pi > 0 { strings.write_string(sb, ",") }
		strings.write_string(sb, `{"filename":`)
		_session_json_str(sb, p.filename)
		strings.write_string(sb, fmt.tprintf(`,"cursor":%d,"scroll":%d,"cur_tab":%d,"tabs":[`, p.cursor, p.scroll, p.cur_tab))
		// Every open tab, so reopening the editor brings them all back. The
		// current tab's live cursor/scroll are in the pane, not in its tab entry.
		for t, ti in p.tabs {
			if ti > 0 { strings.write_string(sb, ",") }
			cur, scr := t.cursor, t.scroll
			if ti == p.cur_tab { cur, scr = p.cursor, p.scroll }
			strings.write_string(sb, `{"filename":`)
			_session_json_str(sb, t.filename)
			strings.write_string(sb, fmt.tprintf(`,"cursor":%d,"scroll":%d}`, cur, scr))
		}
		strings.write_string(sb, "]}")
	}
	strings.write_string(sb, "]")
}

session_build :: proc(e: ^Editor, allocator := context.temp_allocator) -> string {
	sb: strings.Builder
	strings.builder_init(&sb, allocator)
	strings.write_string(&sb, "{")
	act := repos_active(e)
	none := e.repos.none
	if act == nil || none == nil {
		_session_write_view(&sb, e.panes[:], e.active, e.split, e.split_ratio, e.layout)
	} else {
		_session_write_view(&sb, none.panes[:], none.active, none.split, none.split_ratio, none.layout)
	}
	strings.write_string(&sb, fmt.tprintf(`,"active_repo":%d,"repos":[`, e.repos.active))
	for r, i in e.repos.list {
		if i > 0 { strings.write_string(&sb, ",") }
		strings.write_string(&sb, `{"root":`)
		_session_json_str(&sb, r.root)
		strings.write_string(&sb, ",")
		if r == act {
			_session_write_view(&sb, e.panes[:], e.active, e.split, e.split_ratio, e.layout)
		} else {
			_session_write_view(&sb, r.panes[:], r.active, r.split, r.split_ratio, r.layout)
		}
		strings.write_string(&sb, "}")
	}
	// Repositories from an earlier session that weren't opened this time keep
	// their saved tabs (written back as they were loaded)
	n := len(e.repos.list)
	for root, text in e.repos.saved_views {
		if repos_index_of(&e.repos, root) >= 0 { continue }
		if n > 0 { strings.write_string(&sb, ",") }
		strings.write_string(&sb, text)
		n += 1
	}
	strings.write_string(&sb, "]}")
	return strings.to_string(sb)
}

// Reads the last session's per-repository views without opening anything
// (startup shows the welcome screen). See Repo_Set.saved_views.
session_load_views :: proc(e: ^Editor) {
	data, err := os.read_entire_file(_session_path(), context.temp_allocator)
	if err != nil { return }
	session_load_views_from(e, string(data))
}

session_load_views_from :: proc(e: ^Editor, data: string) {
	val, jerr := json.parse(transmute([]u8)data, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if jerr != nil { return }
	defer json.destroy_value(val, context.temp_allocator)
	obj, is_obj := val.(json.Object)
	if !is_obj { return }
	arr, is_arr := obj["repos"].(json.Array)
	if !is_arr { return }
	for rv in arr {
		ro, ok := rv.(json.Object)
		if !ok { continue }
		root, _ := ro["root"].(string)
		if root == "" || !os.is_dir(root) { continue } // folder gone: forget it
		text, merr := json.marshal(ro, allocator = context.temp_allocator)
		if merr != nil { continue }
		key := repos_norm_root(root, context.temp_allocator)
		if old, has := e.repos.saved_views[key]; has {
			delete(old)
			e.repos.saved_views[key] = strings.clone(string(text))
		} else {
			e.repos.saved_views[strings.clone(key)] = strings.clone(string(text))
		}
	}
}

// Gives a repository that was just opened its tabs/panes from the last
// session. The entry is consumed: from now on the live view is what's saved.
session_apply_saved_view :: proc(e: ^Editor, r: ^Repo) {
	key, text, has := _session_take_saved(e, r.root)
	if !has { return }
	defer { delete(key); delete(text) }
	val, jerr := json.parse(transmute([]u8)text, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if jerr != nil { return }
	defer json.destroy_value(val, context.temp_allocator)
	ro, ok := val.(json.Object)
	if !ok { return }
	if v := _session_read_view(ro); v.ok && !r.has_view {
		r.panes, r.active, r.split, r.split_ratio, r.layout = v.panes, v.active, v.split, v.split_ratio, v.layout
		r.has_view = true
	} else if v.ok {
		for &p in v.panes { pane_destroy(&p) }
		delete(v.panes)
	}
}

@(private="file")
_session_take_saved :: proc(e: ^Editor, root: string) -> (key, text: string, ok: bool) {
	norm := repos_norm_root(root, context.temp_allocator)
	if norm not_in e.repos.saved_views { return }
	key, text = delete_key(&e.repos.saved_views, norm)
	return key, text, true
}

session_save :: proc(e: ^Editor) {
	data := session_build(e)
	_ = os.write_entire_file(_session_path(), transmute([]u8)data)
}

// ---------------------------------------------------------------------------
// Restore
// ---------------------------------------------------------------------------

@(private="file")
_View :: struct {
	panes:       [dynamic]Pane,
	active:      int,
	split:       Split_Dir,
	split_ratio: f32,
	layout:      Pane_Layout,
	ok:          bool,
}

@(private="file")
_session_read_view :: proc(obj: json.Object) -> (v: _View) {
	v.split_ratio = 0.5
	if sv, has := obj["split"]; has {
		if ss, ok := sv.(string); ok {
			switch ss {
			case "vertical":   v.split = .Vertical
			case "horizontal": v.split = .Horizontal
			case:              v.split = .None
			}
		}
	}
	if lv, has := obj["layout"]; has {
		if ls, ok := lv.(string); ok {
			if l, lok := layout_decode(ls); lok { v.layout = l }
		}
	}
	if rv, has := obj["split_ratio"]; has {
		#partial switch x in rv {
		case json.Float:   v.split_ratio = f32(x)
		case json.Integer: v.split_ratio = f32(x)
		}
	}
	panes_v, has_panes := obj["panes"]
	if !has_panes { return }
	panes_arr, is_arr := panes_v.(json.Array)
	if !is_arr || len(panes_arr) == 0 { return }

	v.panes = make([dynamic]Pane)
	for pv in panes_arr {
		po, is_po := pv.(json.Object)
		if !is_po { continue }
		fn := ""
		if fv, has := po["filename"]; has {
			if fs, ok := fv.(string); ok { fn = fs }
		}
		p := pane_init()
		if fn != "" && pane_open(&p, fn) {
			if cv, has := po["cursor"]; has {
				if ci, ok := cv.(json.Integer); ok {
					blen     := buffer_len(&p.buf)
					p.cursor  = clamp(int(ci), 0, blen)
					p.sel_anchor = p.cursor
				}
			}
			if sv, has := po["scroll"]; has {
				if si, ok := sv.(json.Integer); ok {
					p.scroll      = int(si)
					p.scroll_anim = f32(p.scroll)
				}
			}
		}
		_session_read_tabs(&p, po)
		append(&v.panes, p)
		if len(v.panes) >= MAX_PANES { break }
	}
	if len(v.panes) == 0 { append(&v.panes, pane_init()) }
	if len(v.panes) < 2 { v.split = .None }
	if av, has := obj["active"]; has {
		if ai, ok := av.(json.Integer); ok { v.active = clamp(int(ai), 0, len(v.panes)-1) }
	}
	v.ok = true
	return
}

// Restores the pane's tab list. Without it the restored file had no tab, so
// the first file opened afterwards replaced it instead of opening beside it.
// Sessions saved before tabs were persisted get a single tab for the file.
_session_read_tabs :: proc(p: ^Pane, po: json.Object) {
	if tv, has := po["tabs"]; has {
		if arr, ok := tv.(json.Array); ok {
			for item in arr {
				to, is_obj := item.(json.Object)
				if !is_obj { continue }
				fn, _ := to["filename"].(string)
				if fn == "" || !os.exists(fn) { continue }
				tab := Pane_Tab{filename = strings.clone(fn)}
				if ci, ok := to["cursor"].(json.Integer); ok { tab.cursor = int(ci) }
				if si, ok := to["scroll"].(json.Integer); ok { tab.scroll = int(si) }
				append(&p.tabs, tab)
			}
		}
	}
	if p.filename == "" {
		// Its file is gone: keep the other tabs, open the first one
		if len(p.tabs) > 0 { p.cur_tab = 0; _pane_load_tab(p, 0) }
		return
	}
	for t, i in p.tabs {
		if t.filename == p.filename { p.cur_tab = i; return }
	}
	// The pane's file wasn't in the list (old session format): it becomes a tab
	append(&p.tabs, Pane_Tab{filename = strings.clone(p.filename), cursor = p.cursor, scroll = p.scroll})
	p.cur_tab = len(p.tabs) - 1
}

session_restore :: proc(e: ^Editor) -> bool {
	data, err := os.read_entire_file(_session_path(), context.temp_allocator)
	if err != nil { return false }
	return session_restore_from(e, string(data))
}

// Applies a session document: scratch view, then every repository (as tabs,
// each with its own panes), then activates the saved active repository.
session_restore_from :: proc(e: ^Editor, data: string) -> bool {
	val, jerr := json.parse(transmute([]u8)data, json.DEFAULT_SPECIFICATION, true, context.temp_allocator) // integers as json.Integer
	if jerr != nil { return false }
	defer json.destroy_value(val, context.temp_allocator)

	obj, is_obj := val.(json.Object)
	if !is_obj { return false }

	restored := false
	if v := _session_read_view(obj); v.ok {
		for &p in e.panes { pane_destroy(&p) }
		delete(e.panes)
		e.panes, e.active, e.split, e.split_ratio, e.layout = v.panes, v.active, v.split, v.split_ratio, v.layout
		restored = true
	}

	active_repo := -1
	if av, has := obj["active_repo"]; has {
		if ai, ok := av.(json.Integer); ok { active_repo = int(ai) }
	}
	repos_v, has_repos := obj["repos"]
	if !has_repos { return restored }
	arr, is_arr := repos_v.(json.Array)
	if !is_arr { return restored }

	target: ^Repo
	for rv, i in arr {
		ro, ok := rv.(json.Object)
		if !ok { continue }
		root, _ := ro["root"].(string)
		if root == "" || !os.is_dir(root) { continue } // folder gone: skip
		r, oerr := repos_open(e, root, activate = false)
		if oerr != "" || r == nil { continue }
		if v := _session_read_view(ro); v.ok && !r.has_view {
			r.panes, r.active, r.split, r.split_ratio, r.layout = v.panes, v.active, v.split, v.split_ratio, v.layout
			r.has_view = true
		} else if v.ok {
			for &p in v.panes { pane_destroy(&p) }
			delete(v.panes)
		}
		if i == active_repo { target = r }
		restored = true
	}
	if target == nil && len(e.repos.list) > 0 && active_repo >= 0 { target = e.repos.list[0] }
	if target != nil {
		for r, i in e.repos.list { if r == target { repos_switch_now(e, i); break } }
	}
	return restored
}
