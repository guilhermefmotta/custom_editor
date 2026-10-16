package editor

// Embedded terminal panel (ticket #16, ADR 0010). Registers itself via
// @(init) (ADR 0001): "Terminal: Toggle" (Ctrl+`), "Terminal: New Tab"
// (Ctrl+Shift+`), "Terminal: Close Tab". Overlay on the bottom half of the
// window (Dock panels don't reserve space yet).
//
// Emulation/PTY live in terminal/ (package `term`); this file only maps
// raylib input to keys and draws the snapshot grid. The snapshot is
// refreshed only when the terminal is dirty or the view changed.
//
// Keys: everything goes to the program while the panel has focus (click
// inside to focus, outside to give focus back to the editor). Ctrl+C, Esc
// reach the program; Shift+Enter sends ESC CR (Meta+Enter, a newline in
// Claude Code). Copy/paste: Cmd+C/Cmd+V on macOS, Ctrl+Shift+C/V
// elsewhere (copies the mouse selection, or the visible screen).

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import term "terminal"
import rl "vendor:raylib"

TERMINAL_PANEL_ID :: "terminal"
TERMINAL_MAX_TABS :: 8

@(init)
_terminal_panel_register :: proc "contextless" () {
	ui_register_panel(Ui_Panel{
		id       = TERMINAL_PANEL_ID,
		title    = "Terminal",
		priority = 40,
		layer    = .Overlay,
		draw     = _tp_draw,
		input    = _tp_input,
		on_open  = _tp_on_open,
		on_close = _tp_on_close,
		command  = "Terminal: Toggle",
		command_desc = "Show/hide the embedded terminal (shell at the repository root)",
		shortcut = {key = .GRAVE, mods = {.Ctrl}},
	})
	ui_register_command(Command{"Terminal: New Tab", "Open a new terminal tab", _tp_cmd_new_tab, nil},
	                    shortcut = {key = .GRAVE, mods = {.Ctrl, .Shift}})
	ui_register_command(Command{"Terminal: Close Tab", "Close the active terminal tab", _tp_cmd_close_tab, _tp_has_tabs})
}

@(fini)
_terminal_panel_fini :: proc "contextless" () {
	context = runtime.default_context()
	for &tab in _tp.tabs { _tp_tab_destroy(&tab) }
	delete(_tp.tabs)
	// Font is not unloaded: the window (GL context) is already gone here.
}

@(private="file")
_Tp_Tab :: struct {
	t:      ^term.Terminal,
	snap:   term.Snapshot,
	scroll: int,    // lines scrolled back (0 = live)
	shell:  string, // owned, for the tab label
	fresh:  bool,   // snapshot taken at least once
	external: bool, // attached by another screen (terminal_panel_attach): never destroyed here
}

@(private="file")
_Tp :: struct {
	tabs:    [dynamic]_Tp_Tab,
	active:  int,
	focused: bool,
	// Own copy of the editor font with box-drawing/symbol glyphs (TUIs like
	// Claude Code draw with them); same file and size as the editor font.
	font:      rl.Font,
	font_px:   i32,
	font_ok:   bool,
	// System fonts for glyphs the editor font lacks (✻ ⏵ ⏺ …), tried in order
	syms:      [4]rl.Font,
	nsyms:     int,
	// Layout of the last frame (input uses it).
	area, grid: rl.Rectangle,
	cw, ch:     f32,
	// Linear mouse selection in view coordinates (row, col).
	sel_on, selecting: bool,
	sel_a, sel_b:      [2]int,
}
@(private="file") _tp: _Tp

@(private="file")
_tp_has_tabs :: proc(e: ^Editor) -> bool { return len(_tp.tabs) > 0 }

@(private="file")
_tp_tab_destroy :: proc(tab: ^_Tp_Tab) {
	if !tab.external { term.destroy(tab.t) }
	term.snapshot_destroy(&tab.snap)
	delete(tab.shell)
	tab^ = {}
}

@(private="file")
_tp_new_tab :: proc() -> bool {
	if len(_tp.tabs) >= TERMINAL_MAX_TABS {
		ui_banner_show(fmt.tprintf("At most %d terminals", TERMINAL_MAX_TABS), .Warning)
		return false
	}
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	cwd, _ := os.get_working_directory(context.temp_allocator)
	root := term.find_repo_root(cwd, context.temp_allocator)
	rows, cols := 24, 80
	if _tp.cw > 0 && _tp.ch > 0 {
		rows = max(1, int(_tp.grid.height / _tp.ch))
		cols = max(1, int(_tp.grid.width / _tp.cw))
	}
	t := term.create(rows, cols)
	argv := term.default_shell(context.temp_allocator)
	if !term.start(t, {argv = argv, cwd = root}) {
		term.destroy(t)
		ui_banner_show("Could not start the shell", .Error)
		return false
	}
	name := argv[0]
	if i := strings.last_index_any(name, "/\\"); i >= 0 { name = name[i + 1:] }
	append(&_tp.tabs, _Tp_Tab{t = t, shell = strings.clone(name)})
	_tp.active = len(_tp.tabs) - 1
	_tp.focused = true
	_tp.sel_on = false
	return true
}

@(private="file")
_tp_close_tab :: proc(e: ^Editor, i: int) {
	if i < 0 || i >= len(_tp.tabs) { return }
	_tp_tab_destroy(&_tp.tabs[i])
	ordered_remove(&_tp.tabs, i)
	_tp.active = clamp(_tp.active, 0, max(0, len(_tp.tabs) - 1))
	_tp.sel_on = false
	if len(_tp.tabs) == 0 { ui_panel_close(e, TERMINAL_PANEL_ID) }
}

@(private="file")
_tp_on_open :: proc(e: ^Editor) {
	if len(_tp.tabs) == 0 && !_tp_new_tab() { ui_panel_close(e, TERMINAL_PANEL_ID); return }
	_tp.focused = true
}

// Opens the panel with `n` shell tabs (benchmark: N idle terminals, ADR 0016).
terminal_panel_open_tabs :: proc(e: ^Editor, n: int) -> int {
	if !ui_panel_is_open(TERMINAL_PANEL_ID) { ui_panel_open(e, TERMINAL_PANEL_ID) }
	for len(_tp.tabs) < n && _tp_new_tab() {}
	return len(_tp.tabs)
}

// Shells keep running while the panel is hidden.
@(private="file")
_tp_on_close :: proc(e: ^Editor) { _tp.focused = false; _tp.selecting = false }

@(private="file")
_tp_cmd_new_tab :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	if !ui_panel_is_open(TERMINAL_PANEL_ID) {
		ui_panel_open(e, TERMINAL_PANEL_ID)
		if len(_tp.tabs) == 1 { return } // on_open already created one
	}
	_tp_new_tab()
}

@(private="file")
_tp_cmd_close_tab :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	_tp_close_tab(e, _tp.active)
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

@(private="file")
_tp_pressed :: proc(k: rl.KeyboardKey) -> bool { return rl.IsKeyPressed(k) || rl.IsKeyPressedRepeat(k) }

@(private="file")
_tp_drain_chars :: proc() { for rl.GetCharPressed() != 0 {} }

@(private="file")
_tp_cell_at :: proc(p: rl.Vector2, s: ^term.Snapshot) -> [2]int {
	r := int((p.y - _tp.grid.y) / _tp.ch)
	c := int((p.x - _tp.grid.x) / _tp.cw)
	return {clamp(r, 0, max(0, s.rows - 1)), clamp(c, 0, max(0, s.cols - 1))}
}

@(private="file")
_tp_input :: proc(e: ^Editor) -> bool {
	if len(_tp.tabs) == 0 { return false }
	tab := &_tp.tabs[_tp.active]
	t := tab.t
	mp := rl.GetMousePosition()
	inside := ui_point_in(mp, _tp.area)

	if rl.IsMouseButtonPressed(.LEFT) { _tp.focused = inside }

	// --- mouse (only inside the panel) ---
	if inside {
		if wheel := rl.GetMouseWheelMove(); wheel != 0 {
			if tab.snap.altscreen {
				// Full-screen apps without mouse reporting: wheel = arrows.
				for _ in 0 ..< 3 { term.send_key(t, .Up if wheel > 0 else .Down) }
			} else {
				tab.scroll = clamp(tab.scroll + int(wheel * 3), 0, tab.snap.sb_len)
			}
		}
		if ui_point_in(mp, _tp.grid) {
			ui_cursor_request(.IBEAM)
			if rl.IsMouseButtonPressed(.LEFT) {
				_tp.selecting = true
				_tp.sel_on = false
				_tp.sel_a = _tp_cell_at(mp, &tab.snap)
				_tp.sel_b = _tp.sel_a
			}
		}
	}
	if _tp.selecting {
		if rl.IsMouseButtonDown(.LEFT) {
			_tp.sel_b = _tp_cell_at(mp, &tab.snap)
			if _tp.sel_b != _tp.sel_a { _tp.sel_on = true }
		} else {
			_tp.selecting = false
		}
	}

	if !_tp.focused { return inside }

	// --- keyboard ---
	if ui_tabs_handle_input(&_tp.active, len(_tp.tabs)) { _tp.sel_on = false; return true }

	when ODIN_OS == .Darwin {
		cmd := rl.IsKeyDown(.LEFT_SUPER) || rl.IsKeyDown(.RIGHT_SUPER)
		copy_combo  := cmd && rl.IsKeyPressed(.C)
		paste_combo := cmd && rl.IsKeyPressed(.V)
	} else {
		cmd := false
		cs := (rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)) && shift()
		copy_combo  := cs && rl.IsKeyPressed(.C)
		paste_combo := (cs && rl.IsKeyPressed(.V)) || (shift() && rl.IsKeyPressed(.INSERT))
	}
	if copy_combo {
		_tp_drain_chars()
		text := _tp_selection_text(&tab.snap, context.temp_allocator)
		rl.SetClipboardText(strings.clone_to_cstring(text, context.temp_allocator))
		ui_banner_show("Copied" if _tp.sel_on else "Copied visible screen", .Success)
		return true
	}
	if paste_combo {
		_tp_drain_chars()
		if clip := rl.GetClipboardText(); clip != nil { term.paste(t, string(clip)) }
		tab.scroll = 0
		return true
	}
	if cmd { return false } // other Cmd combos are editor shortcuts (Cmd+P...), never the program's

	if term.has_exited(t) {
		_tp_drain_chars()
		if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) { _tp_close_tab(e, _tp.active) }
		return true
	}

	pctrl := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
	mods: term.Mods
	if shift() { mods += {.Shift} }
	if alt()   { mods += {.Alt} }
	if pctrl   { mods += {.Ctrl} }
	sent := false

	KEYS :: [?]struct { rk: rl.KeyboardKey, k: term.Key }{
		{.TAB, .Tab}, {.BACKSPACE, .Backspace}, {.ESCAPE, .Escape},
		{.UP, .Up}, {.DOWN, .Down}, {.LEFT, .Left}, {.RIGHT, .Right},
		{.INSERT, .Insert}, {.DELETE, .Delete}, {.HOME, .Home}, {.END, .End},
		{.PAGE_UP, .Page_Up}, {.PAGE_DOWN, .Page_Down},
		{.F1, .F1}, {.F2, .F2}, {.F3, .F3}, {.F4, .F4}, {.F5, .F5}, {.F6, .F6},
		{.F7, .F7}, {.F8, .F8}, {.F9, .F9}, {.F10, .F10}, {.F11, .F11}, {.F12, .F12},
	}
	for m in KEYS {
		if _tp_pressed(m.rk) { term.send_key(t, m.k, mods); sent = true }
	}
	if _tp_pressed(.ENTER) || _tp_pressed(.KP_ENTER) {
		if .Shift in mods && .Ctrl not_in mods {
			term.send_bytes(t, {0x1b, '\r'}) // Meta+Enter: newline in Claude Code
		} else {
			term.send_key(t, .Enter, mods - {.Shift})
		}
		sent = true
	}

	if pctrl || (ODIN_OS != .Darwin && alt()) {
		// Control/Alt combos don't produce char events reliably: map keys.
		_tp_drain_chars()
		for k in rl.KeyboardKey.A ..= rl.KeyboardKey.Z {
			if _tp_pressed(k) {
				ch := rune('a' + int(k) - int(rl.KeyboardKey.A))
				if .Shift in mods && .Ctrl not_in mods { ch -= 32 }
				term.send_char(t, ch, mods - {.Shift}); sent = true
			}
		}
		for k in rl.KeyboardKey.ZERO ..= rl.KeyboardKey.NINE {
			if _tp_pressed(k) && .Ctrl not_in mods { term.send_char(t, rune('0' + int(k) - int(rl.KeyboardKey.ZERO)), {.Alt}); sent = true }
		}
		PUNCT :: [?]struct { rk: rl.KeyboardKey, ch: rune }{
			{.SPACE, ' '}, {.LEFT_BRACKET, '['}, {.BACKSLASH, '\\'}, {.RIGHT_BRACKET, ']'},
			{.MINUS, '-'}, {.SLASH, '/'}, {.PERIOD, '.'}, {.COMMA, ','},
		}
		for p in PUNCT {
			if _tp_pressed(p.rk) { term.send_char(t, p.ch, mods - {.Shift}); sent = true }
		}
	} else {
		for ch := rl.GetCharPressed(); ch != 0; ch = rl.GetCharPressed() {
			term.send_char(t, ch); sent = true
		}
	}
	if sent { tab.scroll = 0; _tp.sel_on = false }
	return true
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

// Text without the characters `font` can't draw (they'd show as '?'), e.g.
// the "✳" Claude Code puts at the start of its window title.
@(private="file")
_tp_drawable :: proc(font: rl.Font, s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r in s {
		if r >= 0x80 && font.glyphs[rl.GetGlyphIndex(font, r)].value != r { continue }
		strings.write_rune(&b, r)
	}
	return strings.trim_space(strings.to_string(b))
}

// Claude Code's mode/record markers: ⏵ (U+23F5) and ⏺ (U+23FA). The fonts
// that have them place them badly in a cell, so they're drawn as shapes.
@(private="file")
_tp_draw_shape :: proc(ch: rune, r: rl.Rectangle, col: rl.Color) -> bool {
	switch ch {
	case 0x23F5: // ⏵ small right-pointing triangle
		s  := min(r.width, r.height) * 0.55
		cx := r.x + r.width * 0.5
		cy := r.y + r.height * 0.5
		rl.DrawTriangle({cx - s * 0.45, cy - s * 0.5}, {cx - s * 0.45, cy + s * 0.5}, {cx + s * 0.5, cy}, col)
		return true
	case 0x23FA: // ⏺ record (filled circle)
		rl.DrawCircleV({r.x + r.width * 0.5, r.y + r.height * 0.5}, min(r.width, r.height) * 0.3, col)
		return true
	}
	return false
}

// System fonts with broad symbol coverage, tried in order.
@(private="file")
_TP_SYMBOL_FONTS :: [?]string{
	// macOS: Arial Unicode has ✻ ✳, STIX Two Math has ⏵ ⏺
	"/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
	"/System/Library/Fonts/Supplemental/STIXTwoMath.otf",
	"/System/Library/Fonts/Apple Symbols.ttf",
	// Windows
	"C:/Windows/Fonts/seguisym.ttf",
	"C:/Windows/Fonts/seguiemj.ttf",
	// Linux
	"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
	"/usr/share/fonts/TTF/DejaVuSans.ttf",
	"/usr/share/fonts/noto/NotoSansSymbols2-Regular.ttf",
	"/usr/share/fonts/truetype/noto/NotoSansSymbols2-Regular.ttf",
}

// The editor font when it has the glyph, else the symbol font (raylib maps a
// missing glyph to '?', which is what showed up in Claude Code's UI).
@(private="file")
_tp_glyph_font :: proc(main: rl.Font, ch: rune) -> rl.Font {
	if ch < 0x80 { return main }
	if main.glyphs[rl.GetGlyphIndex(main, ch)].value == ch { return main }
	for i in 0 ..< _tp.nsyms {
		f := _tp.syms[i]
		if f.glyphs[rl.GetGlyphIndex(f, ch)].value == ch { return f }
	}
	return main
}

@(private="file")
_tp_ensure_font :: proc(fallback: rl.Font) -> rl.Font {
	px := font_pixel_size()
	if _tp.font_ok && _tp.font_px == px { return _tp.font }
	if _tp.font_ok { rl.UnloadFont(_tp.font); _tp.font_ok = false }
	for i in 0 ..< _tp.nsyms { rl.UnloadFont(_tp.syms[i]) }
	_tp.nsyms = 0
	_tp.font_px = px

	RANGES :: [?][2]rune{
		{0x20, 0x7E}, {0xA0, 0x17F}, {0x2000, 0x206F}, {0x2190, 0x21FF},
		{0x2200, 0x22FF}, {0x2300, 0x23FF}, {0x2500, 0x25FF}, {0x2600, 0x26FF},
		{0x2700, 0x27BF}, {0x2800, 0x28FF},
	}
	cps := make([dynamic]rune, context.temp_allocator)
	for r in RANGES { for c := r[0]; c <= r[1]; c += 1 { append(&cps, c) } }
	// Symbol fallbacks from the system (same ranges, skipping plain ASCII).
	// No single font covers everything Claude Code draws, so several load.
	for path in _TP_SYMBOL_FONTS {
		if _tp.nsyms == len(_tp.syms) { break }
		if !os.exists(path) { continue }
		sf := rl.LoadFontEx(to_cstring(path), px, raw_data(cps[95:]), i32(len(cps) - 95))
		if sf.glyphCount > 0 {
			rl.SetTextureFilter(sf.texture, .BILINEAR)
			_tp.syms[_tp.nsyms] = sf
			_tp.nsyms += 1
		}
	}
	for path in FONT_PATHS {
		// Relative to where the editor was launched: by now the working
		// directory follows the active repository (ADR 0014)
		f := rl.LoadFontEx(to_cstring(_launch_path(path)), px, raw_data(cps[:]), i32(len(cps)))
		if f.glyphCount > 0 {
			rl.SetTextureFilter(f.texture, .BILINEAR)
			_tp.font = f
			_tp.font_ok = true
			return f
		}
	}
	_tp.font = fallback
	_tp.font_px = -1 // retry next time the size changes; fallback isn't ours to unload
	return fallback
}

@(private="file")
_tp_rgb :: proc(c: [3]u8) -> rl.Color { return {c[0], c[1], c[2], 255} }

@(private="file")
_tp_colors :: proc(cell: term.Cell) -> (fg, bg: rl.Color, bg_default: bool) {
	fg = TEXT if .Default_Fg in cell.attrs else _tp_rgb(cell.fg)
	bg_default = .Default_Bg in cell.attrs
	bg = BG if bg_default else _tp_rgb(cell.bg)
	if .Reverse in cell.attrs { fg, bg = bg, fg; bg_default = false }
	if .Conceal in cell.attrs { fg = bg }
	return
}

@(private="file")
_tp_sel_range :: proc() -> (a, b: [2]int) {
	a, b = _tp.sel_a, _tp.sel_b
	if b[0] < a[0] || (b[0] == a[0] && b[1] < a[1]) { a, b = b, a }
	return
}

@(private="file")
_tp_in_sel :: proc(r, c: int) -> bool {
	if !_tp.sel_on { return false }
	a, b := _tp_sel_range()
	p := r * 100000 + c
	return p >= a[0] * 100000 + a[1] && p <= b[0] * 100000 + b[1]
}

@(private="file")
_tp_selection_text :: proc(s: ^term.Snapshot, allocator := context.allocator) -> string {
	if !_tp.sel_on { return term.snapshot_text(s, allocator) }
	a, b := _tp_sel_range()
	sb := strings.builder_make(allocator)
	for r in a[0] ..= min(b[0], s.rows - 1) {
		c0 := a[1] if r == a[0] else 0
		c1 := b[1] if r == b[0] else s.cols - 1
		line := strings.builder_make(context.temp_allocator)
		for c in c0 ..= min(c1, s.cols - 1) {
			cell := term.snapshot_cell(s, r, c)
			if cell.width == 0 { continue }
			strings.write_rune(&line, cell.ch if cell.ch != 0 else ' ')
		}
		if r > a[0] { strings.write_byte(&sb, '\n') }
		strings.write_string(&sb, strings.trim_right_space(strings.to_string(line)))
	}
	return strings.to_string(sb)
}

@(private="file")
_tp_draw :: proc(e: ^Editor, font: rl.Font, sw, sh: f32) {
	TAB_H :: f32(28)
	PAD   :: f32(6)
	if len(_tp.tabs) == 0 { return }
	_tp.active = clamp(_tp.active, 0, len(_tp.tabs) - 1)

	y0 := f32(int(sh * 0.5))
	_tp.area = {0, y0, sw, max(TAB_H + 20, sh - MSG_LINE_H - y0)}
	area := _tp.area
	rl.DrawRectangleRec(area, BG)
	rl.DrawRectangleRec({area.x, area.y, area.width, 2}, ACCENT_COL if _tp.focused else DIVIDER_COL)

	// Tabs + "+" button.
	labels := make([]string, len(_tp.tabs), context.temp_allocator)
	for &tab, i in _tp.tabs {
		title := _tp_drawable(font, string(tab.snap.title[:]))
		name := title if title != "" else tab.shell
		if len(name) > 28 { name = name[:28] }
		labels[i] = fmt.tprintf("%d %s%s", i + 1, name, " (exited)" if term.has_exited(tab.t) else "")
	}
	bw := f32(30)
	strip := rl.Rectangle{area.x, area.y + 2, area.width - 2 * bw, TAB_H}
	if ui_tabs(font, strip, labels, &_tp.active) { _tp.sel_on = false }
	rl.DrawRectangleRec({strip.x + strip.width, strip.y, 2 * bw, TAB_H}, STATUS_BG)
	if ui_button(font, {strip.x + strip.width, strip.y + 2, bw - 2, TAB_H - 4}, "+", false, false) {
		_tp_new_tab()
	}
	if ui_button(font, {strip.x + strip.width + bw, strip.y + 2, bw - 2, TAB_H - 4}, "x", false, false) {
		_tp_close_tab(e, _tp.active)
		if len(_tp.tabs) == 0 { return }
	}

	tab := &_tp.tabs[_tp.active]
	t := tab.t
	tfont := _tp_ensure_font(font)
	ref := rl.MeasureTextEx(tfont, "M", FONT_SIZE, CHAR_SPACING)
	_tp.cw = max(ref.x, 1)
	_tp.ch = max(ref.y + LINE_SPACING, 1)
	gy := strip.y + TAB_H + 4
	_tp.grid = {area.x + PAD, gy, area.width - 2 * PAD, area.y + area.height - gy - 4}
	rows := max(1, int(_tp.grid.height / _tp.ch))
	cols := max(1, int(_tp.grid.width / _tp.cw))
	term.resize(t, rows, cols)

	s := &tab.snap
	if !tab.fresh || term.is_dirty(t) || s.scroll != tab.scroll || s.rows != rows || s.cols != cols {
		term.snapshot(t, s, tab.scroll)
		tab.scroll = s.scroll
		tab.fresh = true
	}

	gx := _tp.grid.x
	cw, ch := _tp.cw, _tp.ch
	text_dy := (ch - FONT_SIZE) * 0.5
	for r in 0 ..< s.rows {
		y := _tp.grid.y + f32(r) * ch
		// Backgrounds, merged into runs.
		run_start, run_col := -1, rl.Color{}
		for c in 0 ..= s.cols {
			col: rl.Color
			has := false
			if c < s.cols {
				_, bg, def := _tp_colors(term.snapshot_cell(s, r, c))
				if _tp_in_sel(r, c) { bg = SEL_BG; def = false }
				col, has = bg, !def
			}
			if run_start >= 0 && (!has || col != run_col) {
				rl.DrawRectangleRec({gx + f32(run_start) * cw, y, f32(c - run_start) * cw, ch}, run_col)
				run_start = -1
			}
			if has && run_start < 0 { run_start, run_col = c, col }
		}
		// Glyphs and decorations.
		for c in 0 ..< s.cols {
			cell := term.snapshot_cell(s, r, c)
			if cell.width == 0 { continue }
			fg, _, _ := _tp_colors(cell)
			x := gx + f32(c) * cw
			if cell.ch >= 0x2500 && cell.ch <= 0x259F && _tp_draw_box(cell.ch, {x, y, cw, ch}, fg) {
				// drawn as rectangles
			} else if _tp_draw_shape(cell.ch, {x, y, cw, ch}, fg) {
				// drawn as a shape (fonts' metrics for these are off)
			} else if cell.ch > ' ' {
				gf := _tp_glyph_font(tfont, cell.ch)
				draw_codepoint(gf, cell.ch, {x, y + text_dy}, FONT_SIZE, fg)
				if .Bold in cell.attrs { draw_codepoint(gf, cell.ch, {x + 0.6, y + text_dy}, FONT_SIZE, fg) }
			}
			w := cw * f32(max(1, int(cell.width)))
			if .Underline in cell.attrs { rl.DrawRectangleRec({x, y + ch - 2, w, 1}, fg) }
			if .Strike in cell.attrs    { rl.DrawRectangleRec({x, y + ch * 0.5, w, 1}, fg) }
		}
	}

	// Cursor.
	if s.cursor_visible && s.cursor_row < s.rows && s.cursor_col < s.cols && tab.scroll == 0 {
		cr := rl.Rectangle{gx + f32(s.cursor_col) * cw, _tp.grid.y + f32(s.cursor_row) * ch, cw, ch}
		if _tp.focused {
			rl.DrawRectangleRec(cr, CURSOR_COL)
			cell := term.snapshot_cell(s, s.cursor_row, s.cursor_col)
			if cell.ch > ' ' { draw_codepoint(_tp_glyph_font(tfont, cell.ch), cell.ch, {cr.x, cr.y + text_dy}, FONT_SIZE, BG) }
		} else {
			rl.DrawRectangleLinesEx(cr, 1, CURSOR_COL)
		}
	}

	// Status hints (top-right of the grid).
	hint := ""
	if tab.scroll > 0 { hint = fmt.tprintf("scrollback -%d/%d", tab.scroll, s.sb_len) }
	if s.exited { hint = "process exited - Enter closes the tab" }
	if hint != "" {
		size := FONT_SIZE - 3
		w := ui_text_w(font, hint, size) + 16
		hr := rl.Rectangle{_tp.grid.x + _tp.grid.width - w, _tp.grid.y, w, size + 8}
		rl.DrawRectangleRec(hr, STATUS_BG)
		ui_text(font, hint, hr.x + 8, hr.y, hr.height, size, ACCENT_COL, hr.x + hr.width)
	}
}

// Active terminal (nil when there is none) — for other screens that need to
// drive it (e.g. run a command in it).
terminal_panel_active :: proc() -> ^term.Terminal {
	if len(_tp.tabs) == 0 { return nil }
	return _tp.tabs[clamp(_tp.active, 0, len(_tp.tabs) - 1)].t
}

// --- Terminals owned by other screens (ticket #17: Claude sessions) ---
// The owner creates/starts/destroys the term.Terminal (any argv/cwd/env via
// term.start); the panel only shows it as a tab. Closing that tab (x, or
// Enter after the process exits) just detaches it.

// Shows `t` as a tab (added if needed), makes it active and opens/focuses
// the panel. False when the tab limit is reached.
terminal_panel_attach :: proc(e: ^Editor, t: ^term.Terminal, label: string) -> bool {
	idx := -1
	for tab, i in _tp.tabs { if tab.t == t { idx = i } }
	if idx < 0 {
		if len(_tp.tabs) >= TERMINAL_MAX_TABS {
			ui_banner_show(fmt.tprintf("At most %d terminals", TERMINAL_MAX_TABS), .Warning)
			return false
		}
		append(&_tp.tabs, _Tp_Tab{t = t, shell = strings.clone(label), external = true})
		idx = len(_tp.tabs) - 1
	}
	_tp.active = idx
	_tp.sel_on = false
	ui_panel_open(e, TERMINAL_PANEL_ID)
	_tp.focused = true
	return true
}

// Removes the tab showing `t` (if any) without touching the process.
terminal_panel_detach :: proc(e: ^Editor, t: ^term.Terminal) {
	for tab, i in _tp.tabs {
		if tab.t == t { _tp_close_tab(e, i); return }
	}
}

// Is `t` the tab currently visible in the open panel?
terminal_panel_shows :: proc(t: ^term.Terminal) -> bool {
	return t != nil && ui_panel_is_open(TERMINAL_PANEL_ID) && terminal_panel_active() == t
}

// Box-drawing and block elements drawn as rectangles so lines connect
// across cells regardless of the font's glyph metrics and the line spacing
// (TUIs like Claude Code frame everything with them). Returns false for
// characters it doesn't handle.
@(private="file")
_tp_draw_box :: proc(ch: rune, r: rl.Rectangle, col: rl.Color) -> bool {
	L :: u8(1); R :: u8(2); U :: u8(4); D :: u8(8)
	segs: u8
	switch ch {
	case 0x2500, 0x2501, 0x2504, 0x2505, 0x2508, 0x2509, 0x254C, 0x254D, 0x2550: segs = L | R
	case 0x2502, 0x2503, 0x2506, 0x2507, 0x250A, 0x250B, 0x254E, 0x254F, 0x2551: segs = U | D
	case 0x250C ..= 0x250F, 0x2552 ..= 0x2554, 0x256D: segs = R | D
	case 0x2510 ..= 0x2513, 0x2555 ..= 0x2557, 0x256E: segs = L | D
	case 0x2514 ..= 0x2517, 0x2558 ..= 0x255A, 0x2570: segs = R | U
	case 0x2518 ..= 0x251B, 0x255B ..= 0x255D, 0x256F: segs = L | U
	case 0x251C ..= 0x2523, 0x255E ..= 0x2560: segs = U | D | R
	case 0x2524 ..= 0x252B, 0x2561 ..= 0x2563: segs = U | D | L
	case 0x252C ..= 0x2533, 0x2564 ..= 0x2566: segs = L | R | D
	case 0x2534 ..= 0x253B, 0x2567 ..= 0x2569: segs = L | R | U
	case 0x253C ..= 0x254B, 0x256A ..= 0x256C: segs = L | R | U | D
	case 0x2574, 0x2578: segs = L
	case 0x2575, 0x2579: segs = U
	case 0x2576, 0x257A: segs = R
	case 0x2577, 0x257B: segs = D
	case 0x2580: rl.DrawRectangleRec({r.x, r.y, r.width, r.height * 0.5}, col); return true
	case 0x2581 ..= 0x2588:
		h := r.height * f32(ch - 0x2580) / 8
		rl.DrawRectangleRec({r.x, r.y + r.height - h, r.width, h}, col); return true
	case 0x2589 ..= 0x258F:
		w := r.width * f32(0x2590 - ch) / 8
		rl.DrawRectangleRec({r.x, r.y, w, r.height}, col); return true
	case 0x2590: rl.DrawRectangleRec({r.x + r.width * 0.5, r.y, r.width * 0.5, r.height}, col); return true
	case 0x2591 ..= 0x2593:
		rl.DrawRectangleRec(r, ui_with_alpha(col, u8(64 * int(ch - 0x2590)))); return true
	case 0x2594: rl.DrawRectangleRec({r.x, r.y, r.width, r.height / 8}, col); return true
	case 0x2595: rl.DrawRectangleRec({r.x + r.width * 7 / 8, r.y, r.width / 8, r.height}, col); return true
	case 0x2596 ..= 0x259F:
		// Quadrants ▖▗▘▙▚▛▜▝▞▟ (Claude Code's logo is drawn with these)
		UL :: 1; UR :: 2; LL :: 4; LR :: 8
		QUADS := [10]u8{LL, LR, UL, UL | LL | LR, UL | LR, UL | UR | LL, UL | UR | LR, UR, UR | LL, UR | LL | LR}
		q := QUADS[ch - 0x2596]
		hw, hh := r.width * 0.5, r.height * 0.5
		if q & UL != 0 { rl.DrawRectangleRec({r.x,      r.y,      hw, hh}, col) }
		if q & UR != 0 { rl.DrawRectangleRec({r.x + hw, r.y,      r.width - hw, hh}, col) }
		if q & LL != 0 { rl.DrawRectangleRec({r.x,      r.y + hh, hw, r.height - hh}, col) }
		if q & LR != 0 { rl.DrawRectangleRec({r.x + hw, r.y + hh, r.width - hw, r.height - hh}, col) }
		return true
	case: return false
	}
	t := max(f32(1), f32(int(r.width / 8 + 0.5)))
	cx := f32(int(r.x + (r.width - t) * 0.5))
	cy := f32(int(r.y + (r.height - t) * 0.5))
	if segs & L != 0 { rl.DrawRectangleRec({r.x, cy, cx - r.x + t, t}, col) }
	if segs & R != 0 { rl.DrawRectangleRec({cx, cy, r.x + r.width - cx, t}, col) }
	if segs & U != 0 { rl.DrawRectangleRec({cx, r.y, t, cy - r.y + t}, col) }
	if segs & D != 0 { rl.DrawRectangleRec({cx, cy, t, r.y + r.height - cy}, col) }
	return true
}
