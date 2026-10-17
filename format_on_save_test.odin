package editor

// Tests for format on save: the server's reply is applied and saved only
// when the buffer is still what was sent.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import conf "./config"

@(private="file")
_fmt_reply :: proc() -> json.Value {
	// Replace line 0, chars 0..5 ("a  =1") with "a = 1"
	v, _ := json.parse_string(`[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}},"newText":"a = 1"}]`)
	return v
}

@(test)
test_format_on_save_reply :: proc(t: ^testing.T) {
	e: Editor
	e.panes = make([dynamic]Pane)
	append(&e.panes, pane_init())
	e.cfg = conf.config_defaults()
	defer {
		for &q in e.panes { pane_destroy(&q) }
		delete(e.panes)
		conf.config_destroy(&e.cfg)
	}
	base := os.get_env("TMPDIR", context.temp_allocator)
	if base == "" { base = "/tmp" }
	path := fmt.tprintf("%s/editor-fmt-%d.go", strings.trim_right(base, "/\\"), os.get_pid())
	_ = os.write_entire_file(path, transmute([]u8)string("a  =1\n"))
	defer os.remove(path)
	ep := &e
	p := active_pane(ep)
	testing.expect(t, pane_open(p, path))

	req := new(Format_Req)
	req^ = Format_Req{e = ep, path = strings.clone(p.filename), hash = _buf_hash(p), save = true}
	_on_format_response(nil, _fmt_reply(), nil, req)
	data, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, string(data), "a = 1\n")
	testing.expect(t, !p.dirty)

	// Buffer changed after the request: the reply is dropped
	req = new(Format_Req)
	req^ = Format_Req{e = ep, path = strings.clone(p.filename), hash = 12345, save = true}
	_on_format_response(nil, _fmt_reply(), nil, req)
	data, _ = os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, string(data), "a = 1\n")
}
