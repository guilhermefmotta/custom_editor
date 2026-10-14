package term

// Minimal libvterm 0.3.3 bindings (only what the terminal model uses).
// Linking (ADR 0004): the vendored source in libvterm/ is compiled to a
// static lib by libvterm/build.sh (build.bat on Windows); when it hasn't been
// built yet, macOS/Linux fall back to a system libvterm (Homebrew /
// libvterm-dev) so a plain `odin build .` still works on a dev machine.

import "core:c"

when ODIN_OS == .Windows {
	foreign import vterm "libvterm/lib/vterm.lib"
} else when #exists("libvterm/lib/libvterm.a") {
	foreign import vterm "libvterm/lib/libvterm.a"
} else {
	foreign import vterm "system:vterm"
}

VTerm        :: struct {}
VTermScreen  :: struct {}
VTermState   :: struct {}

VTermPos :: struct {
	row, col: c.int,
}

VTermRect :: struct {
	start_row, end_row, start_col, end_col: c.int,
}

VTERM_COLOR_INDEXED      :: 0x01
VTERM_COLOR_TYPE_MASK    :: 0x01
VTERM_COLOR_DEFAULT_FG   :: 0x02
VTERM_COLOR_DEFAULT_BG   :: 0x04

// Tagged union: type, then r,g,b (RGB) or idx (indexed). 4 bytes.
VTermColor :: struct {
	type:  u8,
	red:   u8, // idx when indexed
	green: u8,
	blue:  u8,
}

VTermStringFragment :: struct {
	str:  cstring,
	bits: c.size_t, // len:30, initial:1, final:1
}

VTermValue :: struct #raw_union {
	boolean: c.int,
	number:  c.int,
	string:  VTermStringFragment,
	color:   VTermColor,
}

VTermProp :: enum c.int {
	NONE = 0,
	CURSORVISIBLE = 1,
	CURSORBLINK,
	ALTSCREEN,
	TITLE,
	ICONNAME,
	REVERSE,
	CURSORSHAPE,
	MOUSE,
	FOCUSREPORT,
}

VTERM_MAX_CHARS_PER_CELL :: 6

// VTermScreenCellAttrs is a 32-bit bitfield (LSB first on every supported
// ABI): bold:1 underline:2 italic:1 blink:1 reverse:1 conceal:1 strike:1 ...
ATTR_BOLD_BIT      :: 0
ATTR_UNDERLINE_BIT :: 1 // 2 bits
ATTR_ITALIC_BIT    :: 3
ATTR_BLINK_BIT     :: 4
ATTR_REVERSE_BIT   :: 5
ATTR_CONCEAL_BIT   :: 6
ATTR_STRIKE_BIT    :: 7

VTermScreenCell :: struct {
	chars: [VTERM_MAX_CHARS_PER_CELL]u32,
	width: c.char,
	attrs: u32,
	fg, bg: VTermColor,
}
#assert(size_of(VTermScreenCell) == 40)
#assert(offset_of(VTermScreenCell, attrs) == 28)

VTermScreenCallbacks :: struct {
	damage:      proc "c" (rect: VTermRect, user: rawptr) -> c.int,
	moverect:    proc "c" (dest, src: VTermRect, user: rawptr) -> c.int,
	movecursor:  proc "c" (pos, oldpos: VTermPos, visible: c.int, user: rawptr) -> c.int,
	settermprop: proc "c" (prop: VTermProp, val: ^VTermValue, user: rawptr) -> c.int,
	bell:        proc "c" (user: rawptr) -> c.int,
	resize:      proc "c" (rows, cols: c.int, user: rawptr) -> c.int,
	sb_pushline: proc "c" (cols: c.int, cells: [^]VTermScreenCell, user: rawptr) -> c.int,
	sb_popline:  proc "c" (cols: c.int, cells: [^]VTermScreenCell, user: rawptr) -> c.int,
	sb_clear:    proc "c" (user: rawptr) -> c.int,
}

VTermDamageSize :: enum c.int { CELL, ROW, SCREEN, SCROLL }

VTermModifier :: distinct c.int
VTERM_MOD_NONE  :: VTermModifier(0x00)
VTERM_MOD_SHIFT :: VTermModifier(0x01)
VTERM_MOD_ALT   :: VTermModifier(0x02)
VTERM_MOD_CTRL  :: VTermModifier(0x04)

VTermKey :: enum c.int {
	NONE,
	ENTER,
	TAB,
	BACKSPACE,
	ESCAPE,
	UP,
	DOWN,
	LEFT,
	RIGHT,
	INS,
	DEL,
	HOME,
	END,
	PAGEUP,
	PAGEDOWN,
	FUNCTION_0 = 256,
}

VTermOutputCallback :: proc "c" (s: [^]u8, len: c.size_t, user: rawptr)

@(default_calling_convention = "c")
foreign vterm {
	vterm_new                 :: proc(rows, cols: c.int) -> ^VTerm ---
	vterm_free                :: proc(vt: ^VTerm) ---
	vterm_get_size            :: proc(vt: ^VTerm, rows, cols: ^c.int) ---
	vterm_set_size            :: proc(vt: ^VTerm, rows, cols: c.int) ---
	vterm_set_utf8            :: proc(vt: ^VTerm, is_utf8: c.int) ---
	vterm_input_write         :: proc(vt: ^VTerm, bytes: [^]u8, len: c.size_t) -> c.size_t ---
	vterm_output_set_callback :: proc(vt: ^VTerm, func: VTermOutputCallback, user: rawptr) ---
	vterm_keyboard_unichar    :: proc(vt: ^VTerm, ch: u32, mod: VTermModifier) ---
	vterm_keyboard_key        :: proc(vt: ^VTerm, key: VTermKey, mod: VTermModifier) ---
	vterm_keyboard_start_paste :: proc(vt: ^VTerm) ---
	vterm_keyboard_end_paste   :: proc(vt: ^VTerm) ---

	vterm_obtain_state        :: proc(vt: ^VTerm) -> ^VTermState ---
	vterm_state_get_cursorpos :: proc(state: ^VTermState, pos: ^VTermPos) ---
	vterm_state_get_palette_color :: proc(state: ^VTermState, index: c.int, col: ^VTermColor) ---

	vterm_obtain_screen          :: proc(vt: ^VTerm) -> ^VTermScreen ---
	vterm_screen_set_callbacks   :: proc(screen: ^VTermScreen, callbacks: ^VTermScreenCallbacks, user: rawptr) ---
	vterm_screen_enable_altscreen :: proc(screen: ^VTermScreen, altscreen: c.int) ---
	vterm_screen_enable_reflow   :: proc(screen: ^VTermScreen, reflow: bool) ---
	vterm_screen_set_damage_merge :: proc(screen: ^VTermScreen, size: VTermDamageSize) ---
	vterm_screen_flush_damage    :: proc(screen: ^VTermScreen) ---
	vterm_screen_reset           :: proc(screen: ^VTermScreen, hard: c.int) ---
	vterm_screen_get_cell        :: proc(screen: ^VTermScreen, pos: VTermPos, cell: ^VTermScreenCell) -> c.int ---
	vterm_screen_convert_color_to_rgb :: proc(screen: ^VTermScreen, col: ^VTermColor) ---
	vterm_screen_set_default_colors   :: proc(screen: ^VTermScreen, fg, bg: ^VTermColor) ---
}
