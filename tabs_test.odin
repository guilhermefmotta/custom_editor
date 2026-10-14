package editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"
import conf "./config"

@(private="file")
_tabs_tmp_files :: proc(tag: string, names: []string) -> (dir: string, paths: [dynamic]string) {
	base := os.get_env("TMPDIR", context.temp_allocator)
	if base == "" { base = "." }
	dir, _ = filepath.join({base, fmt.tprintf("editor_tabs_%s_%d", tag, os.get_pid())}, context.temp_allocator)
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
_tabs_editor :: proc() -> Editor {
	e: Editor
	e.panes = make([dynamic]Pane)
	e.cfg = conf.config_defaults()
	return e
}

@(private="file")
_tabs_editor_destroy :: proc(e: ^Editor) {
	for &p in e.panes { pane_destroy(&p) }
	delete(e.panes)
	conf.config_destroy(&e.cfg)
	recents_destroy(&e.recents)
}

// A file restored by the session (opened without a tab) must stay open as a
// tab when other files are opened — it used to be replaced by the first one.
@(test)
test_tabs_restored_file_stays_as_tab :: proc(t: ^testing.T) {
	dir, f := _tabs_tmp_files("restored", {"restored.txt", "a.txt", "b.txt"})
	defer os.remove_all(dir)
	e := _tabs_editor()
	defer _tabs_editor_destroy(&e)
	p := pane_init()
	testing.expect(t, pane_open(&p, f[0]))
	append(&e.panes, p)

	editor_open(&e, f[1])
	editor_open(&e, f[2])

	ap := active_pane(&e)
	testing.expect_value(t, len(ap.tabs), 3)
	if len(ap.tabs) == 3 {
		testing.expect_value(t, ap.tabs[0].filename, f[0])
		testing.expect_value(t, ap.tabs[2].filename, f[2])
	}
	testing.expect_value(t, ap.filename, f[2])
}

// Every tab survives a session save + restore, with the same current tab.
@(test)
test_tabs_session_round_trip :: proc(t: ^testing.T) {
	dir, f := _tabs_tmp_files("roundtrip", {"one.txt", "two.txt", "three.txt"})
	defer os.remove_all(dir)
	e := _tabs_editor()
	defer _tabs_editor_destroy(&e)
	append(&e.panes, pane_init())
	for path in f { editor_open(&e, path) }
	// make "two" current
	ap := active_pane(&e)
	_pane_save_tab_state(ap)
	ap.cur_tab = 1
	_pane_load_tab(ap, 1)

	data := session_build(&e)

	r := _tabs_editor()
	defer _tabs_editor_destroy(&r)
	testing.expect(t, session_restore_from(&r, data))
	rp := active_pane(&r)
	testing.expect_value(t, len(rp.tabs), 3)
	testing.expect_value(t, rp.cur_tab, 1)
	testing.expect_value(t, rp.filename, f[1])
}
