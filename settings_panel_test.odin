package editor

// Tests for the settings screen logic (features/settings-panel.feature).
// Run from the repo root: odin test .   (uses themes/ and font/ from the repo)

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import conf "./config"

@(private="file")
_test_editor :: proc() -> Editor {
	e: Editor
	e.panes = make([dynamic]Pane)
	append(&e.panes, pane_init())
	append(&e.panes, pane_init())
	e.cfg = conf.config_defaults()
	e.registry = conf.registry_build(&e.cfg, "languages", "themes")
	return e
}

@(private="file")
_test_editor_destroy :: proc(e: ^Editor) {
	for &p in e.panes { pane_destroy(&p) }
	delete(e.panes)
	conf.registry_destroy(&e.registry)
	conf.config_destroy(&e.cfg)
	delete(settings_font_path)
	settings_font_path = ""
}

@(private="file")
_test_path :: proc(name: string) -> string {
	base := os.get_env("TMPDIR", context.temp_allocator)
	if base == "" { base = os.get_env("TEMP", context.temp_allocator) }
	if base == "" { base = "." }
	p, _ := filepath.join({base, fmt.tprintf("editor_settings_%s_%d.toml", name, os.get_pid())}, context.temp_allocator)
	return p
}

@(test)
test_settings_rows_cover_required_keys :: proc(t: ^testing.T) {
	for s in conf.Setting { testing.expect(t, SETTINGS_ROWS[s] != "", fmt.tprint(s)) }
	need := []conf.Setting{.Theme, .Font_Family, .Font_Size, .Keymap_Mode, .Tab_Size, .Word_Wrap, .Auto_Save}
	for s in need {
		loc := conf.SETTING_LOCATION[s]
		testing.expect(t, loc.key != "", fmt.tprint(s))
	}
}

@(test)
test_settings_cycle_values :: proc(t: ^testing.T) {
	// _test_editor_destroy resets settings_font_path: same lock as the others
	sync.mutex_lock(&_settings_globals_mu)
	defer sync.mutex_unlock(&_settings_globals_mu)
	e := _test_editor()
	defer _test_editor_destroy(&e)
	names := settings_theme_names(&e)
	testing.expect(t, len(names) >= 2)

	e.cfg.editor.keymap_mode = .Normal
	testing.expect_value(t, settings_cycle_value(&e, .Keymap_Mode, 1), "vim")
	testing.expect_value(t, settings_cycle_value(&e, .Keymap_Mode, -1), "emacs")
	testing.expect_value(t, settings_cycle_value(&e, .Word_Wrap, 1), "on")
	e.cfg.editor.tab_size = 1
	testing.expect_value(t, settings_cycle_value(&e, .Tab_Size, -1), "1") // clamped
	e.cfg.font.size = 72
	testing.expect_value(t, settings_cycle_value(&e, .Font_Size, 1), "72")
	testing.expect_value(t, settings_cycle_value(&e, .Font_Family, 1), "") // text only
	testing.expect(t, settings_cycle_value(&e, .Theme, 1) != e.cfg.theme_name)

	e.cfg.window.ui_scale = 0
	testing.expect_value(t, settings_cycle_value(&e, .UI_Scale, 1), "80")
	testing.expect_value(t, settings_cycle_value(&e, .UI_Scale, -1), "200")
	e.cfg.window.ui_scale = 125
	testing.expect_value(t, settings_cycle_value(&e, .UI_Scale, 1), "150")
	e.cfg.window.ui_scale = 130 // hand-written value: steps from the one below
	testing.expect_value(t, settings_cycle_value(&e, .UI_Scale, 1), "150")
	e.cfg.font.smooth = true
	testing.expect_value(t, settings_cycle_value(&e, .Smooth_Text, 1), "off")
}

// Tests that change globals (FONT_SIZE, theme, keymap) run one at a time: the
// test runner is multi-threaded and they would race on that shared state.
_settings_globals_mu: sync.Mutex

@(test)
test_settings_apply_updates_config :: proc(t: ^testing.T) {
	sync.mutex_lock(&_settings_globals_mu)
	defer sync.mutex_unlock(&_settings_globals_mu)
	e := _test_editor()
	defer _test_editor_destroy(&e)
	path := _test_path("apply")
	defer os.remove(path)
	old_font := FONT_SIZE
	defer FONT_SIZE = old_font

	old_theme := e.cfg.theme_name
	err, serr := settings_apply(&e, .Theme, "gruvbox", path)
	delete(old_theme)
	testing.expect_value(t, err, ""); testing.expect_value(t, serr, "")
	testing.expect_value(t, conf.registry_active_theme(&e.registry).name, "gruvbox")
	testing.expect_value(t, e.cfg.theme_name, "gruvbox")

	err, serr = settings_apply(&e, .Font_Size, "20", path)
	testing.expect_value(t, err, "")
	testing.expect_value(t, FONT_SIZE, f32(20))

	gen := settings_font_gen
	err, serr = settings_apply(&e, .Font_Family, "font/ttf/FiraCode-Bold.ttf", path)
	testing.expect_value(t, err, "")
	testing.expect_value(t, settings_font_path, "font/ttf/FiraCode-Bold.ttf")
	testing.expect_value(t, settings_font_gen, gen + 1)

	err, serr = settings_apply(&e, .Keymap_Mode, "emacs", path)
	testing.expect_value(t, e.cfg.editor.keymap_mode, conf.Keymap_Mode.Emacs)
	err, serr = settings_apply(&e, .Tab_Size, "2", path)
	testing.expect_value(t, e.cfg.editor.tab_size, 2)
	err, serr = settings_apply(&e, .Word_Wrap, "on", path)
	for p in e.panes { testing.expect(t, p.word_wrap) }
	err, serr = settings_apply(&e, .Auto_Save, "on", path)
	err, serr = settings_apply(&e, .Auto_Save_Delay, "2.5", path)
	testing.expect_value(t, e.cfg.editor.auto_save, true)
	testing.expect_value(t, e.cfg.editor.auto_save_delay, f32(2.5))

	old_zoom, old_smooth := UI_ZOOM, FONT_SMOOTH
	defer { UI_ZOOM = old_zoom; FONT_SMOOTH = old_smooth }
	err, serr = settings_apply(&e, .UI_Scale, "150", path)
	testing.expect_value(t, err, "")
	testing.expect_value(t, UI_ZOOM, f32(1.5))
	err, serr = settings_apply(&e, .Smooth_Text, "off", path)
	testing.expect_value(t, FONT_SMOOTH, false)

	// everything landed in the user file
	cfg := conf.load_config({user = path})
	defer conf.config_destroy(&cfg)
	testing.expect_value(t, cfg.theme_name, "gruvbox")
	testing.expect_value(t, cfg.font.size, 20)
	testing.expect_value(t, cfg.font.family, "font/ttf/FiraCode-Bold.ttf")
	testing.expect_value(t, cfg.editor.keymap_mode, conf.Keymap_Mode.Emacs)
	testing.expect_value(t, cfg.editor.tab_size, 2)
	testing.expect_value(t, cfg.editor.word_wrap, true)
	testing.expect_value(t, cfg.editor.auto_save, true)
	testing.expect_value(t, cfg.editor.auto_save_delay, f32(2.5))
	testing.expect_value(t, cfg.window.ui_scale, 150)
	testing.expect_value(t, cfg.font.smooth, false)
}

@(test)
test_settings_invalid_value_keeps_file :: proc(t: ^testing.T) {
	sync.mutex_lock(&_settings_globals_mu)
	defer sync.mutex_unlock(&_settings_globals_mu)
	e := _test_editor()
	defer _test_editor_destroy(&e)
	path := _test_path("invalid")
	defer os.remove(path)
	ORIG :: "# mine\n[editor]\ntab_size = 4 # keep\n"
	testing.expect(t, os.write_entire_file(path, transmute([]byte)string(ORIG)) == nil)
	old_font := FONT_SIZE
	theme_before := strings.clone(e.cfg.theme_name, context.temp_allocator)

	cases := []struct{ s: conf.Setting, raw: string }{
		{.Tab_Size, "0"}, {.Font_Size, "-3"}, {.Theme, "inexistente"},
		{.Font_Family, "/nao/existe.ttf"}, {.Auto_Save_Delay, "abc"},
	}
	for c in cases {
		err, _ := settings_apply(&e, c.s, c.raw, path)
		testing.expectf(t, err != "", "%v %q accepted", c.s, c.raw)
	}
	testing.expect_value(t, e.cfg.editor.tab_size, 4)
	testing.expect_value(t, FONT_SIZE, old_font)
	testing.expect_value(t, e.cfg.theme_name, theme_before)
	testing.expect_value(t, settings_font_path, "")
	data, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, string(data), ORIG)
}
