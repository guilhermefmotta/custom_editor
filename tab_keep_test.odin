package editor

// Switching tabs keeps unsaved edits; :wa writes them.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import conf "./config"

@(test)
test_tab_switch_keeps_unsaved_and_save_all :: proc(t: ^testing.T) {
	base := os.get_env("TMPDIR", context.temp_allocator)
	if base == "" { base = "/tmp" }
	dir := fmt.tprintf("%s/editor-tabs-%d", strings.trim_right(base, "/\\"), os.get_pid())
	_ = os.remove_all(dir)
	_ = os.make_directory(dir)
	defer os.remove_all(dir)
	a := fmt.tprintf("%s/a.txt", dir)
	b := fmt.tprintf("%s/b.txt", dir)
	_ = os.write_entire_file(a, transmute([]u8)string("aaa"))
	_ = os.write_entire_file(b, transmute([]u8)string("bbb"))

	e: Editor
	e.panes = make([dynamic]Pane)
	append(&e.panes, pane_init())
	e.cfg = conf.config_defaults()
	defer {
		for &q in e.panes { pane_destroy(&q) }
		delete(e.panes)
		conf.config_destroy(&e.cfg)
	}
	p := &e.panes[0]
	testing.expect(t, pane_open(p, a))
	append(&p.tabs, Pane_Tab{filename = strings.clone(p.filename)})
	testing.expect(t, pane_open_tab(p, b))

	// Edit b, go to a, come back: the edit is still there
	buffer_insert_string(&p.buf, 0, "X")
	p.dirty = true
	pane_tab_prev(p)
	testing.expect_value(t, buffer_to_string(&p.buf, context.temp_allocator), "aaa")
	testing.expect(t, !p.dirty)
	pane_tab_next(p)
	testing.expect_value(t, buffer_to_string(&p.buf, context.temp_allocator), "Xbbb")
	testing.expect(t, p.dirty)

	// Edit a too, leave b unsaved in its tab, then :wa saves both
	pane_tab_prev(p)
	buffer_insert_string(&p.buf, 0, "Y")
	p.dirty = true
	testing.expect(t, editor_any_dirty(&e))
	editor_save_all(&e)
	da, _ := os.read_entire_file(a, context.temp_allocator)
	db, _ := os.read_entire_file(b, context.temp_allocator)
	testing.expect_value(t, string(da), "Yaaa")
	testing.expect_value(t, string(db), "Xbbb")
	testing.expect(t, !editor_any_dirty(&e))
}
