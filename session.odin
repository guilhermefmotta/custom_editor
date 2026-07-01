package editor

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

SESSION_FILE :: "editor_session.json"

session_save :: proc(e: ^Editor) {
	sb: strings.Builder
	strings.builder_init(&sb, context.temp_allocator)
	strings.write_string(&sb, `{"active":`)
	strings.write_string(&sb, fmt.tprintf("%d", e.active))
	strings.write_string(&sb, `,"split":"`)
	switch e.split {
	case .None:       strings.write_string(&sb, "none")
	case .Vertical:   strings.write_string(&sb, "vertical")
	case .Horizontal: strings.write_string(&sb, "horizontal")
	}
	strings.write_string(&sb, fmt.tprintf(`","split_ratio":%g,"panes":[`, e.split_ratio))
	for p, pi in e.panes {
		if pi > 0 { strings.write_string(&sb, ",") }
		fn := p.filename
		escaped,  _ := strings.replace_all(fn, `\`, `\\`, context.temp_allocator)
		escaped2, _ := strings.replace_all(escaped, `"`, `\"`, context.temp_allocator)
		strings.write_string(&sb, fmt.tprintf(`{"filename":"%s","cursor":%d,"scroll":%d}`,
			escaped2, p.cursor, p.scroll))
	}
	strings.write_string(&sb, "]}")
	data := transmute([]u8)strings.to_string(sb)
	_ = os.write_entire_file(SESSION_FILE, data)
}

session_restore :: proc(e: ^Editor) -> bool {
	data, err := os.read_entire_file(SESSION_FILE, context.temp_allocator)
	if err != nil { return false }

	val, jerr := json.parse(data, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
	if jerr != nil { return false }
	defer json.destroy_value(val)

	obj, is_obj := val.(json.Object)
	if !is_obj { return false }

	// Split direction
	if sv, has := obj["split"]; has {
		if ss, ok := sv.(string); ok {
			switch ss {
			case "vertical":   e.split = .Vertical
			case "horizontal": e.split = .Horizontal
			case:              e.split = .None
			}
		}
	}
	// Split ratio
	if rv, has := obj["split_ratio"]; has {
		#partial switch v in rv {
		case json.Float:   e.split_ratio = f32(v)
		case json.Integer: e.split_ratio = f32(v)
		}
	}

	// Panes
	panes_v, has_panes := obj["panes"]
	if !has_panes { return false }
	panes_arr, is_arr := panes_v.(json.Array)
	if !is_arr || len(panes_arr) == 0 { return false }

	// Destroy existing panes and reset list
	for &p in e.panes { pane_destroy(&p) }
	clear(&e.panes)

	loaded := 0
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
		append(&e.panes, p)
		loaded += 1
		if loaded >= 4 { break }
	}

	if len(e.panes) == 0 { append(&e.panes, pane_init()) }
	if len(e.panes) < 2   { e.split = .None }

	// Active pane index
	if av, has := obj["active"]; has {
		if ai, ok := av.(json.Integer); ok {
			e.active = clamp(int(ai), 0, len(e.panes)-1)
		}
	}

	return true
}
