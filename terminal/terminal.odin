package term

// Per-session markers a running Claude Code puts in its environment. When the
// editor itself was started from inside a Claude Code session they would leak
// into every terminal it spawns, and a `claude` started there treats itself as
// a child session (e.g. "Transcript saving is off ... inherited
// CLAUDE_CODE_CHILD_SESSION marker"). Only these markers are dropped; the
// user's own CLAUDE_* / ANTHROPIC_* configuration still passes through.
SESSION_ENV_STRIP :: [?]string{
	"CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID",
	"CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
	"CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_EXECPATH", "CLAUDE_CODE_SESSION_ATTENDED",
	"CLAUDE_PID", "CLAUDE_EFFORT",
}

// "KEY=VALUE" whose key is a session marker to drop.
env_is_session_marker :: proc(kv: string) -> bool {
	for k in SESSION_ENV_STRIP {
		if len(kv) > len(k) && kv[len(k)] == '=' && kv[:len(k)] == k { return true }
	}
	return false
}

// Terminal model: one libvterm instance + a PTY + two I/O threads.
//
// Threads
//   reader  — pty_read → vterm_input_write (under `mu`) → sets `dirty`.
//   writer  — waits on `write_sema`, swaps `out` (bytes produced by libvterm
//             for keys/paste/replies) out under `mu`, writes to the PTY
//             without holding the lock (a child that stops reading can't
//             wedge the UI or the reader).
//   UI      — keys/paste/resize take `mu` briefly; drawing never touches
//             libvterm: `snapshot` copies the ready grid only when `dirty`
//             (or the view changed). `dirty` is also what a future
//             event-driven render loop can poll to decide to wake up.
//
// All libvterm calls happen under `mu`; libvterm callbacks therefore run
// with `mu` held.

import "base:runtime"
import "core:c"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "../wake"

SCROLLBACK_MAX :: 5000
READ_BUF_SIZE  :: 64 * 1024

Attr :: enum u8 { Bold, Italic, Underline, Blink, Reverse, Conceal, Strike, Default_Fg, Default_Bg }
Attrs :: bit_set[Attr; u16]

// One screen cell, colors already resolved to RGB. When .Default_Fg /
// .Default_Bg is set the renderer should use its theme colors instead.
Cell :: struct {
	ch:     rune, // 0 = empty
	fg, bg: [3]u8,
	attrs:  Attrs,
	width:  u8, // 1, 2 (wide glyph), 0 (right half of a wide glyph)
}

Terminal :: struct {
	mu:     sync.Mutex,
	vt:     ^VTerm,
	screen: ^VTermScreen,
	state:  ^VTermState,
	rows, cols: int,

	// --- guarded by mu ---
	out:        [dynamic]u8,       // pending bytes for the PTY
	sb:         [][]Cell,          // scrollback ring (lazily allocated)
	sb_head:    int,
	sb_len:     int,
	cursor_visible: bool,
	altscreen:  bool,
	title:      [dynamic]u8,
	bytes_in:   int,               // total bytes fed to libvterm
	bell:       bool,

	// --- atomics ---
	dirty:  bool,
	exited: bool,
	quit:   bool,

	pty:        Pty,
	has_pty:    bool,
	reader:     ^thread.Thread,
	writer:     ^thread.Thread,
	write_sema: sync.Sema,
	allocator:  runtime.Allocator,
	ctx:        runtime.Context, // for libvterm callbacks
}

// A copy of what to draw. Reused across frames (call snapshot_destroy).
Snapshot :: struct {
	rows, cols:     int,
	cells:          [dynamic]Cell, // rows*cols, row-major
	cursor_row:     int,
	cursor_col:     int,
	cursor_visible: bool, // false while scrolled back
	altscreen:      bool,
	sb_len:         int,  // scrollback lines available
	scroll:         int,  // lines scrolled back actually applied (clamped)
	title:          [dynamic]u8,
	exited:         bool,
}

@(private) _atomic_load  :: proc "contextless" (p: ^bool) -> bool { return sync.atomic_load(p) }
@(private) _atomic_store :: proc "contextless" (p: ^bool, v: bool) { sync.atomic_store(p, v) }
@(private) _sleep_ms     :: proc(ms: int) { time.sleep(time.Duration(ms) * time.Millisecond) }

// ---------------------------------------------------------------------------
// Lifetime
// ---------------------------------------------------------------------------

// Creates the emulator only (no process). Use `start` to attach a PTY.
create :: proc(rows, cols: int, allocator := context.allocator) -> ^Terminal {
	t := new(Terminal, allocator)
	t.allocator = allocator
	t.ctx = context
	t.ctx.allocator = allocator
	t.rows = max(rows, 1)
	t.cols = max(cols, 1)
	t.out.allocator = allocator
	t.title.allocator = allocator
	t.cursor_visible = true

	t.vt = vterm_new(c.int(t.rows), c.int(t.cols))
	vterm_set_utf8(t.vt, 1)
	vterm_output_set_callback(t.vt, _on_output, t)
	t.state = vterm_obtain_state(t.vt)
	t.screen = vterm_obtain_screen(t.vt)
	vterm_screen_set_callbacks(t.screen, &_screen_callbacks, t)
	vterm_screen_enable_altscreen(t.screen, 1)
	vterm_screen_set_damage_merge(t.screen, .SCROLL)
	vterm_screen_reset(t.screen, 1)
	return t
}

Spawn_Options :: struct {
	argv: []string, // empty = default_shell()
	cwd:  string,   // "" = inherit
	env:  []string, // "KEY=VALUE" overrides, added to TERM/COLORTERM
}

// Spawns the process on a PTY and starts the I/O threads.
start :: proc(t: ^Terminal, opts: Spawn_Options) -> bool {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	argv := opts.argv
	if len(argv) == 0 { argv = default_shell(context.temp_allocator) }
	env := make([dynamic]string, context.temp_allocator)
	append(&env, "TERM=xterm-256color", "COLORTERM=truecolor", "TERM_PROGRAM=custom_editor")
	append(&env, ..opts.env)
	if !pty_spawn(&t.pty, argv, opts.cwd, env[:], t.rows, t.cols) { return false }
	t.has_pty = true
	t.reader = thread.create_and_start_with_poly_data(t, _reader_proc, t.ctx)
	t.writer = thread.create_and_start_with_poly_data(t, _writer_proc, t.ctx)
	return true
}

destroy :: proc(t: ^Terminal) {
	if t == nil { return }
	if t.has_pty {
		pty_kill(&t.pty)
		_atomic_store(&t.quit, true)
		sync.sema_post(&t.write_sema)
		thread.join(t.reader); thread.destroy(t.reader)
		thread.join(t.writer); thread.destroy(t.writer)
		pty_close(&t.pty)
	}
	vterm_free(t.vt)
	for i in 0 ..< len(t.sb) { delete(t.sb[i], t.allocator) }
	delete(t.sb, t.allocator)
	delete(t.out)
	delete(t.title)
	free(t, t.allocator)
}

// ---------------------------------------------------------------------------
// I/O threads
// ---------------------------------------------------------------------------

// Reader poll timeout: only bounds how long `quit` can go unnoticed when the
// child survives SIGHUP (destroy kills it first, which normally ends the read
// at once). Was 50 ms; 8 idle shells then cost 160 wake-ups/s (ADR 0016).
READ_POLL_MS :: 500

@(private)
_reader_proc :: proc(t: ^Terminal) {
	buf := make([]u8, READ_BUF_SIZE, t.allocator)
	defer delete(buf, t.allocator)
	for !_atomic_load(&t.quit) {
		n, eof := pty_read(&t.pty, buf, READ_POLL_MS)
		if n > 0 { feed(t, buf[:n]) }
		if eof { break }
	}
	_atomic_store(&t.exited, true)
	_atomic_store(&t.dirty, true)
	wake.request() // ADR 0016: the UI loop may be asleep
}

@(private)
_writer_proc :: proc(t: ^Terminal) {
	local := make([dynamic]u8, t.allocator)
	defer delete(local)
	for {
		sync.sema_wait(&t.write_sema)
		if _atomic_load(&t.quit) { break }
		sync.mutex_lock(&t.mu)
		local, t.out = t.out, local // swap buffers, no copy
		sync.mutex_unlock(&t.mu)
		if len(local) > 0 {
			pty_write(&t.pty, local[:], &t.quit)
			clear(&local)
		}
	}
}

@(private)
_kick_writer :: proc(t: ^Terminal) {
	if t.has_pty { sync.sema_post(&t.write_sema) }
}

// ---------------------------------------------------------------------------
// Feeding output / sending input
// ---------------------------------------------------------------------------

// Feeds program output to the emulator (the reader thread does this; tests
// call it directly).
feed :: proc(t: ^Terminal, data: []u8) {
	sync.mutex_lock(&t.mu)
	vterm_input_write(t.vt, raw_data(data), c.size_t(len(data)))
	vterm_screen_flush_damage(t.screen)
	t.bytes_in += len(data)
	has_out := len(t.out) > 0
	sync.mutex_unlock(&t.mu)
	_atomic_store(&t.dirty, true)
	wake.request() // ADR 0016: new output → wake the sleeping UI loop
	if has_out { _kick_writer(t) } // replies to queries (DA, DSR...)
}

Mods :: bit_set[enum u8 { Shift, Alt, Ctrl }; u8]

@(private)
_vmod :: proc(m: Mods) -> VTermModifier {
	r := VTERM_MOD_NONE
	if .Shift in m { r |= VTERM_MOD_SHIFT }
	if .Alt   in m { r |= VTERM_MOD_ALT }
	if .Ctrl  in m { r |= VTERM_MOD_CTRL }
	return r
}

Key :: enum u8 {
	Enter, Tab, Backspace, Escape, Up, Down, Left, Right,
	Insert, Delete, Home, End, Page_Up, Page_Down,
	F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12,
}

// Sends a special key (encoded by libvterm per the current modes, e.g.
// application cursor keys).
send_key :: proc(t: ^Terminal, k: Key, mods: Mods = {}) {
	vk: VTermKey
	switch k {
	case .Enter:     vk = .ENTER
	case .Tab:       vk = .TAB
	case .Backspace: vk = .BACKSPACE
	case .Escape:    vk = .ESCAPE
	case .Up:        vk = .UP
	case .Down:      vk = .DOWN
	case .Left:      vk = .LEFT
	case .Right:     vk = .RIGHT
	case .Insert:    vk = .INS
	case .Delete:    vk = .DEL
	case .Home:      vk = .HOME
	case .End:       vk = .END
	case .Page_Up:   vk = .PAGEUP
	case .Page_Down: vk = .PAGEDOWN
	case .F1 ..= .F12: vk = VTermKey(int(VTermKey.FUNCTION_0) + 1 + int(k) - int(Key.F1))
	}
	sync.mutex_lock(&t.mu)
	vterm_keyboard_key(t.vt, vk, _vmod(mods))
	sync.mutex_unlock(&t.mu)
	_kick_writer(t)
}

// Sends a character; Ctrl+letter becomes the control code (Ctrl+C = 0x03),
// Alt prefixes ESC.
send_char :: proc(t: ^Terminal, r: rune, mods: Mods = {}) {
	sync.mutex_lock(&t.mu)
	vterm_keyboard_unichar(t.vt, u32(r), _vmod(mods))
	sync.mutex_unlock(&t.mu)
	_kick_writer(t)
}

// Sends raw bytes to the program, bypassing key encoding.
send_bytes :: proc(t: ^Terminal, data: []u8) {
	sync.mutex_lock(&t.mu)
	append(&t.out, ..data)
	sync.mutex_unlock(&t.mu)
	_kick_writer(t)
}

// Pastes text: bracketed (ESC[200~ … ESC[201~) when the program enabled it;
// newlines become CR like a real terminal. Large text goes straight to the
// output buffer (no per-char encoding).
paste :: proc(t: ^Terminal, text: string) {
	sync.mutex_lock(&t.mu)
	vterm_keyboard_start_paste(t.vt)
	reserve(&t.out, len(t.out) + len(text))
	for i := 0; i < len(text); i += 1 {
		ch := text[i]
		if ch == '\r' && i + 1 < len(text) && text[i + 1] == '\n' { continue }
		if ch == '\n' { ch = '\r' }
		if ch == 0x1b { continue } // never let pasted ESC end the bracket early
		append(&t.out, ch)
	}
	vterm_keyboard_end_paste(t.vt)
	sync.mutex_unlock(&t.mu)
	_kick_writer(t)
}

// Takes (and clears) the bytes pending for the PTY. Only meaningful without
// a PTY (tests) — with one the writer thread consumes them.
take_output :: proc(t: ^Terminal, allocator := context.allocator) -> []u8 {
	sync.mutex_lock(&t.mu)
	defer sync.mutex_unlock(&t.mu)
	out := make([]u8, len(t.out), allocator)
	copy(out, t.out[:])
	clear(&t.out)
	return out
}

resize :: proc(t: ^Terminal, rows, cols: int) {
	rows, cols := max(rows, 1), max(cols, 1)
	if rows == t.rows && cols == t.cols { return }
	sync.mutex_lock(&t.mu)
	t.rows, t.cols = rows, cols
	vterm_set_size(t.vt, c.int(rows), c.int(cols))
	vterm_screen_flush_damage(t.screen)
	sync.mutex_unlock(&t.mu)
	if t.has_pty { pty_resize(&t.pty, rows, cols) }
	_atomic_store(&t.dirty, true)
}

// ---------------------------------------------------------------------------
// Reading the grid
// ---------------------------------------------------------------------------

is_dirty  :: proc(t: ^Terminal) -> bool { return _atomic_load(&t.dirty) }
has_exited :: proc(t: ^Terminal) -> bool { return _atomic_load(&t.exited) }

bytes_received :: proc(t: ^Terminal) -> int {
	sync.mutex_lock(&t.mu)
	defer sync.mutex_unlock(&t.mu)
	return t.bytes_in
}

scrollback_len :: proc(t: ^Terminal) -> int {
	sync.mutex_lock(&t.mu)
	defer sync.mutex_unlock(&t.mu)
	return t.sb_len
}

@(private)
_cell_from_vterm :: proc(t: ^Terminal, vc: ^VTermScreenCell) -> Cell {
	cell := Cell{ch = rune(vc.chars[0]), width = u8(vc.width)}
	a := vc.attrs
	if a & (1 << ATTR_BOLD_BIT)      != 0 { cell.attrs += {.Bold} }
	if a & (3 << ATTR_UNDERLINE_BIT) != 0 { cell.attrs += {.Underline} }
	if a & (1 << ATTR_ITALIC_BIT)    != 0 { cell.attrs += {.Italic} }
	if a & (1 << ATTR_BLINK_BIT)     != 0 { cell.attrs += {.Blink} }
	if a & (1 << ATTR_REVERSE_BIT)   != 0 { cell.attrs += {.Reverse} }
	if a & (1 << ATTR_CONCEAL_BIT)   != 0 { cell.attrs += {.Conceal} }
	if a & (1 << ATTR_STRIKE_BIT)    != 0 { cell.attrs += {.Strike} }
	if vc.fg.type & VTERM_COLOR_DEFAULT_FG != 0 { cell.attrs += {.Default_Fg} }
	if vc.bg.type & VTERM_COLOR_DEFAULT_BG != 0 { cell.attrs += {.Default_Bg} }
	fg, bg := vc.fg, vc.bg
	vterm_screen_convert_color_to_rgb(t.screen, &fg)
	vterm_screen_convert_color_to_rgb(t.screen, &bg)
	cell.fg = {fg.red, fg.green, fg.blue}
	cell.bg = {bg.red, bg.green, bg.blue}
	return cell
}

// Must hold mu.
@(private)
_screen_cell :: proc(t: ^Terminal, row, col: int) -> Cell {
	vc: VTermScreenCell
	vterm_screen_get_cell(t.screen, {c.int(row), c.int(col)}, &vc)
	return _cell_from_vterm(t, &vc)
}

// Copies the visible grid into `s`, `scroll` lines back into the scrollback
// (0 = live screen). Clears `dirty`.
snapshot :: proc(t: ^Terminal, s: ^Snapshot, scroll := 0) {
	_atomic_store(&t.dirty, false)
	sync.mutex_lock(&t.mu)
	defer sync.mutex_unlock(&t.mu)

	rows, cols := t.rows, t.cols
	s.rows, s.cols = rows, cols
	resize_dynamic_array(&s.cells, rows * cols)
	s.sb_len = t.sb_len
	s.scroll = clamp(scroll, 0, t.sb_len)
	s.altscreen = t.altscreen
	s.exited = _atomic_load(&t.exited)

	for r in 0 ..< rows {
		line := r - s.scroll // < 0 → scrollback
		dst := s.cells[r * cols:][:cols]
		if line >= 0 {
			for col in 0 ..< cols { dst[col] = _screen_cell(t, line, col) }
		} else {
			src := t.sb[(t.sb_head + t.sb_len + line) % len(t.sb)]
			n := min(len(src), cols)
			copy(dst[:n], src[:n])
			for col in n ..< cols { dst[col] = Cell{width = 1, attrs = {.Default_Fg, .Default_Bg}} }
		}
	}

	pos: VTermPos
	vterm_state_get_cursorpos(t.state, &pos)
	s.cursor_row = int(pos.row) + s.scroll
	s.cursor_col = int(pos.col)
	s.cursor_visible = t.cursor_visible && s.cursor_row < rows && !s.exited

	clear(&s.title)
	append(&s.title, ..t.title[:])
}

snapshot_destroy :: proc(s: ^Snapshot) {
	delete(s.cells)
	delete(s.title)
	s^ = {}
}

snapshot_cell :: proc(s: ^Snapshot, row, col: int) -> Cell {
	return s.cells[row * s.cols + col]
}

// Text of one snapshot row (trailing blanks trimmed).
snapshot_row_text :: proc(s: ^Snapshot, row: int, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for col in 0 ..< s.cols {
		cell := snapshot_cell(s, row, col)
		if cell.width == 0 { continue }
		strings.write_rune(&b, cell.ch if cell.ch != 0 else ' ')
	}
	return strings.trim_right_space(strings.to_string(b))
}

// Text of a rectangular-ish selection of the snapshot, rows joined by "\n".
snapshot_text :: proc(s: ^Snapshot, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	last := -1
	for r in 0 ..< s.rows {
		line := snapshot_row_text(s, r, context.temp_allocator)
		if line != "" { last = r }
	}
	for r in 0 ..= last {
		if r > 0 { strings.write_byte(&b, '\n') }
		strings.write_string(&b, snapshot_row_text(s, r, context.temp_allocator))
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// libvterm callbacks (run with mu held, on whichever thread called libvterm)
// ---------------------------------------------------------------------------

@(private)
_on_output :: proc "c" (s: [^]u8, n: c.size_t, user: rawptr) {
	t := (^Terminal)(user)
	context = t.ctx
	append(&t.out, ..s[:n])
}

@(private)
_screen_callbacks := VTermScreenCallbacks{
	settermprop = _on_settermprop,
	bell        = _on_bell,
	sb_pushline = _on_sb_pushline,
	sb_popline  = _on_sb_popline,
	sb_clear    = _on_sb_clear,
}

@(private)
_on_settermprop :: proc "c" (prop: VTermProp, val: ^VTermValue, user: rawptr) -> c.int {
	t := (^Terminal)(user)
	context = t.ctx
	#partial switch prop {
	case .CURSORVISIBLE: t.cursor_visible = val.boolean != 0
	case .ALTSCREEN:     t.altscreen = val.boolean != 0
	case .TITLE:
		f := val.string
		when ODIN_OS == .Windows {
			// MSVC: `size_t len:30` then a separate unit for the bools.
			n := int(f.bits & 0x3FFFFFFF)
			flags := (cast([^]u8)val)[16]
			initial := flags & 1 != 0
		} else {
			n := int(f.bits & 0x3FFFFFFF)
			initial := (f.bits >> 30) & 1 != 0
		}
		if initial { clear(&t.title) }
		if f.str != nil && n > 0 && len(t.title) < 256 {
			append(&t.title, ..(cast([^]u8)f.str)[:min(n, 256 - len(t.title))])
		}
	}
	return 1
}

@(private)
_on_bell :: proc "c" (user: rawptr) -> c.int {
	(^Terminal)(user).bell = true
	return 1
}

@(private)
_on_sb_pushline :: proc "c" (cols: c.int, cells: [^]VTermScreenCell, user: rawptr) -> c.int {
	t := (^Terminal)(user)
	context = t.ctx
	if t.sb == nil { t.sb = make([][]Cell, SCROLLBACK_MAX, t.allocator) }
	idx: int
	if t.sb_len < len(t.sb) {
		idx = (t.sb_head + t.sb_len) % len(t.sb)
		t.sb_len += 1
	} else {
		idx = t.sb_head
		t.sb_head = (t.sb_head + 1) % len(t.sb)
	}
	n := int(cols)
	// Trim trailing blanks so short lines cost little.
	for n > 0 && cells[n - 1].chars[0] == 0 && cells[n - 1].bg.type & VTERM_COLOR_DEFAULT_BG != 0 { n -= 1 }
	line := t.sb[idx]
	if len(line) != n {
		delete(line, t.allocator)
		line = make([]Cell, n, t.allocator)
		t.sb[idx] = line
	}
	for i in 0 ..< n { line[i] = _cell_from_vterm(t, &cells[i]) }
	return 1
}

@(private)
_on_sb_popline :: proc "c" (cols: c.int, cells: [^]VTermScreenCell, user: rawptr) -> c.int {
	t := (^Terminal)(user)
	context = t.ctx
	if t.sb_len == 0 { return 0 }
	t.sb_len -= 1
	line := t.sb[(t.sb_head + t.sb_len) % len(t.sb)]
	for i in 0 ..< int(cols) {
		vc := &cells[i]
		vc^ = {}
		vc.width = 1
		vc.fg.type = VTERM_COLOR_DEFAULT_FG
		vc.bg.type = VTERM_COLOR_DEFAULT_BG
		if i < len(line) {
			cl := line[i]
			vc.chars[0] = u32(cl.ch)
			vc.width = c.char(cl.width)
			if .Default_Fg not_in cl.attrs { vc.fg = {0, cl.fg[0], cl.fg[1], cl.fg[2]} }
			if .Default_Bg not_in cl.attrs { vc.bg = {0, cl.bg[0], cl.bg[1], cl.bg[2]} }
			if .Bold in cl.attrs      { vc.attrs |= 1 << ATTR_BOLD_BIT }
			if .Underline in cl.attrs { vc.attrs |= 1 << ATTR_UNDERLINE_BIT }
			if .Italic in cl.attrs    { vc.attrs |= 1 << ATTR_ITALIC_BIT }
			if .Reverse in cl.attrs   { vc.attrs |= 1 << ATTR_REVERSE_BIT }
			if .Strike in cl.attrs    { vc.attrs |= 1 << ATTR_STRIKE_BIT }
		}
	}
	return 1
}

@(private)
_on_sb_clear :: proc "c" (user: rawptr) -> c.int {
	t := (^Terminal)(user)
	t.sb_len = 0
	t.sb_head = 0
	return 1
}


// Nearest ancestor of `dir` (inclusive) containing `.git` (dir or file, so
// worktrees count); `dir` itself when there is none. Allocated.
find_repo_root :: proc(dir: string, allocator := context.allocator) -> string {
	cur := strings.trim_right(dir, "/\\")
	if cur == "" { cur = dir }
	for {
		probe := strings.concatenate({cur, "/.git"}, context.temp_allocator)
		if os.exists(probe) { return strings.clone(cur, allocator) }
		i := strings.last_index_any(cur, "/\\")
		if i < 0 { break }
		parent := cur[:i]
		if parent == "" || parent == cur { break }
		if len(parent) == 2 && parent[1] == ':' { break } // C:
		cur = parent
	}
	return strings.clone(dir, allocator)
}
