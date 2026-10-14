package config

// Tests for the editor.toml writer + setting validation
// (features/settings-panel.feature). Run: odin test ./config

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(private="file")
SAMPLE :: `# Editor configuration
# Priority: defaults < system < user < workspace

version = 1
theme = "4coder"   # active theme

# ---------------------------------------------------------------------------
[editor]
# ---------------------------------------------------------------------------

tab_size          = 4
word_wrap         = false
auto_save_delay   = 1.0     # seconds after last keystroke
keymap_mode          = "vim" # normal | vim | emacs

# ---------------------------------------------------------------------------
[font]
# ---------------------------------------------------------------------------

family       = "font/ttf/FiraCode-Regular.ttf"
size         = 14
fallbacks = [
  "JetBrainsMono.ttf",
  "/usr/share/fonts/x.ttf",
]

[[build]]
name = "debug"
size = 99
`

@(private="file")
_lines_diff :: proc(a, b: string) -> (changed: [dynamic]string) {
	al := strings.split(a, "\n", context.temp_allocator)
	bl := strings.split(b, "\n", context.temp_allocator)
	changed = make([dynamic]string, context.temp_allocator)
	if len(al) != len(bl) { append(&changed, fmt.tprintf("line count %d != %d", len(al), len(bl))); return }
	for l, i in al { if l != bl[i] { append(&changed, bl[i]) } }
	return
}

@(test)
test_patch_replaces_value_preserving_comments :: proc(t: ^testing.T) {
	out := toml_patch_value(SAMPLE, "editor", "tab_size", "2", context.temp_allocator)
	d := _lines_diff(SAMPLE, out)
	testing.expect_value(t, len(d), 1)
	if len(d) == 1 { testing.expect_value(t, d[0], "tab_size          = 2") }

	// trailing comment and spacing kept
	out = toml_patch_value(SAMPLE, "editor", "keymap_mode", `"emacs"`, context.temp_allocator)
	d = _lines_diff(SAMPLE, out)
	testing.expect_value(t, len(d), 1)
	if len(d) == 1 { testing.expect_value(t, d[0], `keymap_mode          = "emacs" # normal | vim | emacs`) }

	// top-level key
	out = toml_patch_value(SAMPLE, "", "theme", `"gruvbox"`, context.temp_allocator)
	d = _lines_diff(SAMPLE, out)
	testing.expect_value(t, len(d), 1)
	if len(d) == 1 { testing.expect_value(t, d[0], `theme = "gruvbox"   # active theme`) }

	// [font].size changes, [[build]].size does not
	out = toml_patch_value(SAMPLE, "font", "size", "20", context.temp_allocator)
	d = _lines_diff(SAMPLE, out)
	testing.expect_value(t, len(d), 1)
	if len(d) == 1 { testing.expect_value(t, d[0], "size         = 20") }

	// string with a '#' inside isn't mistaken for a comment
	out = toml_patch_value(SAMPLE, "font", "family", `"C:\\Fonts\\a#b.ttf"`, context.temp_allocator)
	testing.expect(t, strings.contains(out, `family       = "C:\\Fonts\\a#b.ttf"` + "\n"))

	// CRLF and missing final newline are preserved
	crlf := "[editor]\r\ntab_size = 4 # c\r\nword_wrap = true"
	out = toml_patch_value(crlf, "editor", "tab_size", "8", context.temp_allocator)
	testing.expect_value(t, out, "[editor]\r\ntab_size = 8 # c\r\nword_wrap = true")
}

@(test)
test_patch_inserts_missing_key_and_section :: proc(t: ^testing.T) {
	// missing key: inserted after the last key of the section, before the
	// separator comments of the next header (and not inside the array)
	out := toml_patch_value(SAMPLE, "editor", "auto_save", "true", context.temp_allocator)
	testing.expect(t, strings.contains(out,
		"keymap_mode          = \"vim\" # normal | vim | emacs\nauto_save = true\n\n# ----"))
	out = toml_patch_value(SAMPLE, "font", "line_height", "1.2", context.temp_allocator)
	testing.expect(t, strings.contains(out, "  \"/usr/share/fonts/x.ttf\",\n]\nline_height = 1.2\n\n[[build]]"))

	// missing section: appended at the end
	out = toml_patch_value("[editor]\ntab_size = 4\n", "font", "size", "16", context.temp_allocator)
	testing.expect_value(t, out, "[editor]\ntab_size = 4\n\n[font]\nsize = 16\n")

	// empty file
	out = toml_patch_value("", "", "theme", `"dark"`, context.temp_allocator)
	testing.expect_value(t, out, "theme = \"dark\"\n")
	out = toml_patch_value("", "editor", "tab_size", "3", context.temp_allocator)
	testing.expect_value(t, out, "[editor]\ntab_size = 3\n")

	// top-level key with no top-level keys yet: above the header's comments
	out = toml_patch_value("# c\n[editor]\ntab_size = 4\n", "", "theme", `"dark"`, context.temp_allocator)
	testing.expect_value(t, out, "theme = \"dark\"\n\n# c\n[editor]\ntab_size = 4\n")
}

@(private="file")
_tmp_dir :: proc(name: string) -> string {
	base := os.get_env("TMPDIR", context.temp_allocator)
	if base == "" { base = os.get_env("TEMP", context.temp_allocator) }
	if base == "" { base = "." }
	p, _ := filepath.join({base, fmt.tprintf("editor_cfg_test_%s_%d", name, os.get_pid())}, context.temp_allocator)
	return p
}

@(private="file")
_rm_tree :: proc(dir, file: string) {
	os.remove(file)
	os.remove(fmt.tprintf("%s.tmp", file))
	os.remove(dir)
}

@(test)
test_write_setting_round_trip :: proc(t: ^testing.T) {
	dir := _tmp_dir("roundtrip")
	os.make_directory_all(dir)
	path, _ := filepath.join({dir, "editor.toml"}, context.temp_allocator)
	defer _rm_tree(dir, path)
	testing.expect(t, os.write_entire_file(path, transmute([]byte)string(SAMPLE)) == nil)

	ok, err := config_write_setting(path, .Tab_Size, Setting_Value{num = 2})
	testing.expect(t, ok, err)
	ok, err = config_write_setting(path, .Auto_Save, Setting_Value{b = true})
	testing.expect(t, ok, err)
	ok, err = config_write_setting(path, .Auto_Save_Delay, Setting_Value{f = 2.5})
	testing.expect(t, ok, err)
	ok, err = config_write_setting(path, .Theme, Setting_Value{str = "gruvbox"})
	testing.expect(t, ok, err)
	ok, err = config_write_setting(path, .Keymap_Mode, Setting_Value{mode = .Emacs})
	testing.expect(t, ok, err)
	testing.expect(t, !os.exists(fmt.tprintf("%s.tmp", path)))

	data, _ := os.read_entire_file(path, context.temp_allocator)
	d := _lines_diff(SAMPLE, string(data))
	// 4 lines rewritten + 1 inserted (auto_save) -> line count differs by 1
	testing.expect(t, strings.count(string(data), "\n") == strings.count(SAMPLE, "\n") + 1)
	_ = d
	for l in ([]string{"# Editor configuration", "# ---------------------------------------------------------------------------",
	                   "fallbacks = [", "[[build]]", `name = "debug"`, "size = 99", "version = 1"}) {
		testing.expect(t, strings.contains(string(data), l), l)
	}

	cfg := load_config({user = path})
	defer config_destroy(&cfg)
	testing.expect_value(t, cfg.editor.tab_size, 2)
	testing.expect_value(t, cfg.editor.auto_save, true)
	testing.expect_value(t, cfg.editor.auto_save_delay, f32(2.5))
	testing.expect_value(t, cfg.theme_name, "gruvbox")
	testing.expect_value(t, cfg.editor.keymap_mode, Keymap_Mode.Emacs)
	testing.expect_value(t, cfg.font.size, 14)
}

@(test)
test_write_setting_creates_user_file :: proc(t: ^testing.T) {
	dir := _tmp_dir("create")
	path, _ := filepath.join({dir, "editor.toml"}, context.temp_allocator)
	defer _rm_tree(dir, path)
	testing.expect(t, !os.exists(path))

	ok, err := config_write_setting(path, .Font_Size, Setting_Value{num = 20})
	testing.expect(t, ok, err)
	data, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, string(data), "[font]\nsize = 20\n")

	// Windows-style path survives the quoting round trip
	ok, err = config_write_setting(path, .Font_Family, Setting_Value{str = `C:\Fonts\x "y".ttf`})
	testing.expect(t, ok, err)
	cfg := load_config({user = path})
	defer config_destroy(&cfg)
	testing.expect_value(t, cfg.font.family, `C:\Fonts\x "y".ttf`)
	testing.expect_value(t, cfg.font.size, 20)
}

@(test)
test_write_setting_refuses_invalid_toml :: proc(t: ^testing.T) {
	dir := _tmp_dir("invalid")
	os.make_directory_all(dir)
	path, _ := filepath.join({dir, "editor.toml"}, context.temp_allocator)
	defer _rm_tree(dir, path)
	BROKEN :: "[editor\ntab_size = 4\nword_wrap = = true\n"
	testing.expect(t, os.write_entire_file(path, transmute([]byte)string(BROKEN)) == nil)

	ok, err := config_write_setting(path, .Tab_Size, Setting_Value{num = 2})
	testing.expect(t, !ok)
	testing.expect(t, strings.contains(err, "fix it by hand"), err)
	data, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, string(data), BROKEN)
}

@(test)
test_validate_rejects_invalid_values :: proc(t: ^testing.T) {
	themes := []string{"dark", "gruvbox", "4coder"}
	bad := []struct{ s: Setting, raw: string }{
		{.Tab_Size, "0"}, {.Tab_Size, "17"}, {.Tab_Size, "abc"}, {.Tab_Size, ""},
		{.Font_Size, "-3"}, {.Font_Size, "0"}, {.Font_Size, "200"}, {.Font_Size, "12.5"},
		{.Theme, "inexistente"}, {.Theme, ""},
		{.Font_Family, "/nao/existe.ttf"}, {.Font_Family, "editor.toml"}, {.Font_Family, ""},
		{.Keymap_Mode, "nano"},
		{.Word_Wrap, "maybe"},
		{.Auto_Save_Delay, "abc"}, {.Auto_Save_Delay, "0"}, {.Auto_Save_Delay, "-1"}, {.Auto_Save_Delay, "nan"},
	}
	for b in bad {
		_, err := config_setting_parse(b.s, b.raw, themes)
		testing.expectf(t, err != "", "%v %q should be rejected", b.s, b.raw)
	}

	v, err := config_setting_parse(.Tab_Size, " 2 ", themes)
	testing.expect_value(t, err, "")
	testing.expect_value(t, v.num, 2)
	v, err = config_setting_parse(.Font_Size, "20", themes)
	testing.expect_value(t, v.num, 20)
	v, err = config_setting_parse(.Theme, "gruvbox", themes)
	testing.expect_value(t, v.str, "gruvbox")
	v, err = config_setting_parse(.Keymap_Mode, "Emacs", themes)
	testing.expect_value(t, v.mode, Keymap_Mode.Emacs)
	v, err = config_setting_parse(.Auto_Save_Delay, "1.5", themes)
	testing.expect_value(t, v.f, 1.5)
	v, err = config_setting_parse(.Word_Wrap, "on", themes)
	testing.expect_value(t, v.b, true)
}

@(test)
test_setting_get_set_literal :: proc(t: ^testing.T) {
	cfg := config_defaults()
	defer config_destroy(&cfg)
	config_setting_set(&cfg, .Theme, {str = "gruvbox"})
	config_setting_set(&cfg, .Font_Family, {str = "a.ttf"})
	config_setting_set(&cfg, .Tab_Size, {num = 3})
	testing.expect_value(t, config_setting_get(&cfg, .Theme).str, "gruvbox")
	testing.expect_value(t, config_setting_get(&cfg, .Font_Family).str, "a.ttf")
	testing.expect_value(t, config_setting_get(&cfg, .Tab_Size).num, 3)
	testing.expect_value(t, config_setting_literal(.Auto_Save_Delay, {f = 1}), "1.0")
	testing.expect_value(t, config_setting_literal(.Auto_Save_Delay, {f = 0.25}), "0.25")
	testing.expect_value(t, config_setting_literal(.Keymap_Mode, {mode = .Vim}), `"vim"`)
	testing.expect_value(t, config_setting_literal(.Font_Family, {str = `a\b`}), `"a\\b"`)
}

@(test)
test_toml_numbers_and_validate :: proc(t: ^testing.T) {
	root, _ := toml_parse("a = 14\nb = -3\nc = 1.5\nk2fa = 7\n")
	defer toml_destroy_table(root)
	n, ok := toml_int(root, "a");  testing.expect(t, ok && n == 14)
	n, ok  = toml_int(root, "b");  testing.expect(t, ok && n == -3)
	n, ok  = toml_int(root, "k2fa"); testing.expect(t, ok && n == 7)
	f, okf := toml_float(root, "c"); testing.expect(t, okf && f == 1.5)

	testing.expect(t, !_valid("a = \n"))
	testing.expect(t, !_valid("[x\n"))
	testing.expect(t, !_valid("a = \"open\n"))
	testing.expect(t, !_valid("a = 1 2\n"))
	testing.expect(t, _valid(SAMPLE))
	// the repo's own config files must stay valid (writer refuses invalid ones)
	data, err := os.read_entire_file("editor.toml", context.temp_allocator)
	if err == nil { testing.expect(t, _valid(string(data)), "editor.toml") }
}

@(private="file")
_valid :: proc(s: string) -> bool { ok, _ := toml_validate(s); return ok }
