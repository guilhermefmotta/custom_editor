package editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"
import conf "./config"

@(private="file")
_tc_files :: proc(tag: string, names: []string) -> (dir: string, paths: [dynamic]string) {
	base := os.get_env("TMPDIR", context.temp_allocator)
	if base == "" { base = "." }
	dir, _ = filepath.join({base, fmt.tprintf("editor_tabclose_%s_%d", tag, os.get_pid())}, context.temp_allocator)
	_ = os.make_directory(dir)
	paths = make([dynamic]string, context.temp_allocator)
	for n in names {
		p, _ := filepath.join({dir, n}, context.temp_allocator)
		_ = os.write_entire_file(p, transmute([]u8)fmt.tprintf("%s\n", n))
		append(&paths, p)
	}
	return
}

@(private="file")
_tc_editor :: proc() -> Editor {
	e: Editor
	e.panes = make([dynamic]Pane)
	append(&e.panes, pane_init())
	e.cfg = conf.config_defaults()
	return e
}

@(private="file")
_tc_editor_destroy :: proc(e: ^Editor) {
	for &p in e.panes { pane_destroy(&p) }
	delete(e.panes)
	conf.config_destroy(&e.cfg)
	recents_destroy(&e.recents)
}

// A clean tab closes right away; the next tab becomes current.
@(test)
test_tab_close_clean_tab :: proc(t: ^testing.T) {
	dir, f := _tc_files("clean", {"a.txt", "b.txt"})
	defer os.remove_all(dir)
	e := _tc_editor(); defer _tc_editor_destroy(&e)
	editor_open(&e, f[0]); editor_open(&e, f[1])
	editor_close_tab_request(&e)
	p := active_pane(&e)
	testing.expect_value(t, len(p.tabs), 1)
	testing.expect_value(t, p.filename, f[0])
}

// Unsaved changes: nothing closes until the user answers the confirmation.
@(test)
test_tab_close_dirty_asks_first :: proc(t: ^testing.T) {
	dir, f := _tc_files("dirty", {"a.txt", "b.txt"})
	defer os.remove_all(dir)
	e := _tc_editor(); defer _tc_editor_destroy(&e)
	editor_open(&e, f[0]); editor_open(&e, f[1])
	active_pane(&e).dirty = true
	editor_close_tab_request(&e)
	testing.expect_value(t, len(active_pane(&e).tabs), 2)
	testing.expect(t, ui_panel_is_open(TAB_CLOSE_ID), "confirmation shown")
	editor_close_tab_dismiss(&e)
	testing.expect_value(t, len(active_pane(&e).tabs), 2) // cancel keeps the tab
}

// Vim :q on the last tab leaves an empty pane and keeps the editor running.
@(test)
test_tab_close_vim_q_last_tab_keeps_editor :: proc(t: ^testing.T) {
	dir, f := _tc_files("vimq", {"only.txt"})
	defer os.remove_all(dir)
	e := _tc_editor(); defer _tc_editor_destroy(&e)
	editor_open(&e, f[0])
	p := active_pane(&e)
	vim_exec_command(&e, p, "q")
	testing.expect(t, !e.should_quit, "editor keeps running")
	testing.expect_value(t, len(p.tabs), 0)
	testing.expect_value(t, p.filename, "")
	vim_exec_command(&e, p, "qa")
	testing.expect(t, e.should_quit, ":qa still quits")
}
