package editor

// ===========================================================================
// UI registry — palette commands, panels and shortcuts registered from the
// screen's own file (ADR 0001). palette.odin / input.odin / renderer.odin
// only iterate this registry; a new screen never edits them.
//
// HOW A NEW SCREEN REGISTERS ITSELF
// ---------------------------------
//   // my_screen.odin
//   package editor
//
//   @(init)
//   _my_screen_register :: proc "contextless" () {   // @(init) must be contextless
//       ui_register_panel(Ui_Panel{
//           id       = "my_screen",                     // unique key
//           title    = "My Screen",
//           priority = 50,                              // higher = gets input first / drawn on top
//           layer    = .Overlay,                        // .Dock (under dialogs) or .Overlay (above)
//           draw     = _my_screen_draw,                 // proc(e: ^Editor, font: rl.Font, sw, sh: f32)
//           input    = _my_screen_input,                // proc(e: ^Editor) -> bool  (true = consumed)
//           update   = nil,                             // optional proc(e: ^Editor, dt: f32), every frame
//           on_open  = nil, on_close = nil,             // optional proc(e: ^Editor)
//           command  = "My Screen: Toggle",             // optional palette entry that toggles it
//           command_desc = "Show/hide My Screen",       // optional (defaults to title)
//           shortcut = {key = .G, mods = {.Ctrl, .Shift}}, // optional global toggle shortcut
//       })
//       ui_register_command(Command{"My Screen: Do Thing", "Description", _my_cmd, nil},
//                           shortcut = {key = .J, mods = {.Ctrl, .Alt}})
//   }
//
// Rules
// - @(init) runs before main, in no guaranteed order across files. Nothing
//   here depends on order: commands are listed sorted by name, panels by
//   (priority desc, id asc). Registering an id/name twice replaces it.
// - ui_register_* are "contextless" so they can be called from @(init);
//   they allocate with the default heap allocator (freed at @(fini)).
// - Strings passed in (id, title, names) must outlive the program — use
//   literals.
// - Input order each frame (input.odin → handle_panels): built-in modal
//   dialogs → palette → Ctrl+Shift+P → registered shortcuts → open
//   registered panels by priority (first `input` returning true stops the
//   chain) → rest of the editor. A modal panel just always returns true.
//   Panels read keyboard/mouse straight from raylib; return true when the
//   mouse is over you so the editor doesn't also handle the click.
// - Drawing (renderer.odin): `.Dock` panels after the editor panes,
//   `.Overlay` panels (then the banner) after built-in dialogs, right
//   before the palette. Within a layer, ascending priority (highest on top).
// - Per-panel state lives in the screen's own file (package-level vars).
// - Open/close from code: ui_panel_open / ui_panel_close / ui_panel_toggle /
//   ui_panel_is_open(id).
// - Components to build screens with: ui_list.odin (list + filter),
//   ui_tabs.odin, ui_split.odin (resizable divider), ui_confirm.odin,
//   ui_menu.odin (context menu), ui_banner.odin. See ui_demo.odin for a
//   living example using all of them.
// ===========================================================================

import "base:runtime"
import "core:slice"
import rl "vendor:raylib"

Ui_Mod :: enum u8 { Ctrl, Shift, Alt }
Ui_Mods :: bit_set[Ui_Mod]

// key == .KEY_NULL means "no shortcut". Ctrl also matches Cmd on macOS
// (see ctrl() in input.odin).
Ui_Shortcut :: struct {
	key:  rl.KeyboardKey,
	mods: Ui_Mods,
}

Ui_Layer :: enum u8 { Dock, Overlay }

Ui_Panel :: struct {
	id:       string,
	title:    string,
	priority: int,
	layer:    Ui_Layer,
	open:     bool, // initial state; afterwards owned by the registry
	draw:     proc(e: ^Editor, font: rl.Font, sw, sh: f32),
	input:    proc(e: ^Editor) -> bool,
	update:   proc(e: ^Editor, dt: f32),
	on_open:  proc(e: ^Editor),
	on_close: proc(e: ^Editor),
	command:  string,      // palette entry name that toggles the panel ("" = none)
	command_desc: string,  // palette description for `command` ("" = title)
	shortcut: Ui_Shortcut, // global toggle shortcut (key = .KEY_NULL = none)
}

Ui_Registered_Command :: struct {
	cmd:      Command,
	shortcut: Ui_Shortcut,
	panel_id: string, // set for auto-generated panel toggle commands
}

@(private="file") _ui_panels:   [dynamic]Ui_Panel
@(private="file") _ui_commands: [dynamic]Ui_Registered_Command
@(private="file") _ui_panels_sorted: bool

// Name of the command currently being executed by the palette — lets the
// generic panel-toggle command find its panel (Command.execute has no user
// data). Set by palette_execute.
ui_command_running: string

// ---------------------------------------------------------------------------
// Registration (callable from @(init))
// ---------------------------------------------------------------------------

ui_register_command :: proc "contextless" (cmd: Command, shortcut := Ui_Shortcut{}) {
	context = runtime.default_context()
	_ui_add_command({cmd = cmd, shortcut = shortcut})
}

ui_register_panel :: proc "contextless" (panel: Ui_Panel) {
	context = runtime.default_context()
	for &p in _ui_panels {
		if p.id == panel.id { p = panel; _ui_panels_sorted = false; _ui_panel_cmd(panel); return }
	}
	append(&_ui_panels, panel)
	_ui_panels_sorted = false
	_ui_panel_cmd(panel)
}

@(private="file")
_ui_panel_cmd :: proc(panel: Ui_Panel) {
	if panel.command == "" { return }
	_ui_add_command({
		cmd      = Command{panel.command, panel.command_desc if panel.command_desc != "" else panel.title, _ui_panel_toggle_cmd, nil},
		panel_id = panel.id,
	})
}

@(private="file")
_ui_add_command :: proc(rc: Ui_Registered_Command) {
	for &c in _ui_commands {
		if c.cmd.name == rc.cmd.name { c = rc; return }
	}
	append(&_ui_commands, rc)
}

@(fini)
_ui_registry_fini :: proc "contextless" () {
	context = runtime.default_context()
	delete(_ui_panels)
	delete(_ui_commands)
}

// ---------------------------------------------------------------------------
// Queries
// ---------------------------------------------------------------------------

// Registered palette commands, sorted by name. Caller owns the slice
// (allocated with `allocator`).
ui_registered_commands :: proc(allocator := context.temp_allocator) -> []Command {
	out := make([]Command, len(_ui_commands), allocator)
	for c, i in _ui_commands { out[i] = c.cmd }
	slice.sort_by(out, proc(a, b: Command) -> bool { return a.name < b.name })
	return out
}

// Panels sorted by (priority desc, id asc). The slice aliases the registry —
// do not keep it across registrations.
ui_panels :: proc() -> []Ui_Panel {
	if !_ui_panels_sorted {
		slice.sort_by(_ui_panels[:], _ui_panel_less)
		_ui_panels_sorted = true
	}
	return _ui_panels[:]
}

_ui_panel_less :: proc(a, b: Ui_Panel) -> bool {
	if a.priority != b.priority { return a.priority > b.priority }
	return a.id < b.id
}

ui_panel_find :: proc(id: string) -> ^Ui_Panel {
	for &p in _ui_panels { if p.id == id { return &p } }
	return nil
}

ui_panel_is_open :: proc(id: string) -> bool {
	p := ui_panel_find(id)
	return p != nil && p.open
}

ui_panel_open :: proc(e: ^Editor, id: string) {
	p := ui_panel_find(id)
	if p == nil || p.open { return }
	p.open = true
	if p.on_open != nil { p.on_open(e) }
}

ui_panel_close :: proc(e: ^Editor, id: string) {
	p := ui_panel_find(id)
	if p == nil || !p.open { return }
	p.open = false
	if p.on_close != nil { p.on_close(e) }
}

ui_panel_toggle :: proc(e: ^Editor, id: string) {
	if ui_panel_is_open(id) { ui_panel_close(e, id) } else { ui_panel_open(e, id) }
}

@(private="file")
_ui_panel_toggle_cmd :: proc(e: ^Editor, p: ^Palette) {
	for c in _ui_commands {
		if c.cmd.name == ui_command_running && c.panel_id != "" {
			palette_close(p)
			ui_panel_toggle(e, c.panel_id)
			return
		}
	}
}

// ---------------------------------------------------------------------------
// Shortcuts
// ---------------------------------------------------------------------------

// Pure matcher: does `s` fire given the pressed key and held modifiers?
// Modifiers must match exactly (Ctrl+G does not fire on Ctrl+Shift+G).
ui_shortcut_matches :: proc(s: Ui_Shortcut, pressed: rl.KeyboardKey, held: Ui_Mods) -> bool {
	return s.key != .KEY_NULL && s.key == pressed && s.mods == held
}

@(private="file")
_ui_held_mods :: proc() -> Ui_Mods {
	m: Ui_Mods
	if ctrl()  { m += {.Ctrl} }
	if shift() { m += {.Shift} }
	if alt()   { m += {.Alt} }
	return m
}

@(private="file")
_ui_shortcut_pressed :: proc(s: Ui_Shortcut, held: Ui_Mods) -> bool {
	if s.key == .KEY_NULL || !rl.IsKeyPressed(s.key) { return false }
	return ui_shortcut_matches(s, s.key, held)
}

// ---------------------------------------------------------------------------
// Frame hooks — called by input.odin / renderer.odin only
// ---------------------------------------------------------------------------

// Shortcuts, then open panels by priority. Returns true if input consumed.
ui_registry_handle_input :: proc(e: ^Editor) -> bool {
	if ui_banner_handle_input(&ui_banner) { return true }
	held := _ui_held_mods()
	for p in ui_panels() {
		if _ui_shortcut_pressed(p.shortcut, held) { ui_panel_toggle(e, p.id); return true }
	}
	for c in _ui_commands {
		if c.panel_id != "" { continue }
		if !_ui_shortcut_pressed(c.shortcut, held) { continue }
		if c.cmd.available != nil && !c.cmd.available(e) { continue }
		ui_command_running = c.cmd.name
		c.cmd.execute(e, &e.palette)
		ui_command_running = ""
		return true
	}
	for p in ui_panels() {
		if p.open && p.input != nil && p.input(e) { return true }
	}
	return false
}

// Every-frame update hooks (open or not — the panel decides).
ui_registry_update :: proc(e: ^Editor, dt: f32) {
	for p in ui_panels() { if p.update != nil { p.update(e, dt) } }
	now := f64(rl.GetTime())
	ui_banner_update(&ui_banner, now)
	// ADR 0016: wake up to hide an expiring banner even when idle
	if ui_banner.visible && ui_banner.until > 0 { frame_request_in(ui_banner.until - now) }
}

// Draw open panels of `layer`, lowest priority first so the highest ends on top.
ui_registry_draw :: proc(e: ^Editor, font: rl.Font, layer: Ui_Layer, sw, sh: f32) {
	ps := ui_panels()
	#reverse for p in ps {
		if p.open && p.layer == layer && p.draw != nil { p.draw(e, font, sw, sh) }
	}
	if layer == .Overlay {
		ui_banner_draw(&ui_banner, font, sw)
		ui_cursor_flush()
	}
}
