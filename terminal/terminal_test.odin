package term

// Scenarios: features/embedded-terminal.feature

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
_wait :: proc(t: ^Terminal, cond: proc(t: ^Terminal) -> bool, timeout := 5 * time.Second) -> bool {
	start := time.now()
	for time.since(start) < timeout {
		if cond(t) { return true }
		time.sleep(5 * time.Millisecond)
	}
	return cond(t)
}

@(private = "file")
_row :: proc(t: ^Terminal, row: int) -> string {
	s: Snapshot
	defer snapshot_destroy(&s)
	snapshot(t, &s)
	return snapshot_row_text(&s, row, context.temp_allocator)
}

@(private = "file")
_screen_contains :: proc(t: ^Terminal, needle: string) -> bool {
	s: Snapshot
	defer snapshot_destroy(&s)
	snapshot(t, &s)
	return strings.contains(snapshot_text(&s, context.temp_allocator), needle)
}

// # teste: test_spawn_printf_reaches_grid
@(test)
test_spawn_printf_reaches_grid :: proc(tt: ^testing.T) {
	when ODIN_OS == .Windows { return }
	t := create(24, 80)
	defer destroy(t)
	testing.expect(tt, start(t, {argv = {"/bin/sh", "-c", "printf 'abc\\n'"}}))
	testing.expect(tt, _wait(t, has_exited))
	testing.expect_value(tt, _row(t, 0), "abc")
}

// # teste: test_ansi_colors_become_cell_attrs
@(test)
test_ansi_colors_become_cell_attrs :: proc(tt: ^testing.T) {
	t := create(5, 20)
	defer destroy(t)
	feed(t, transmute([]u8)string("\e[1;31mR\e[0m\e[38;5;208mO\e[38;2;1;2;3;48;2;4;5;6mT\e[0m\e[7mV\e[0m\e[3;4mI"))
	s: Snapshot
	defer snapshot_destroy(&s)
	snapshot(t, &s)

	r := snapshot_cell(&s, 0, 0)
	testing.expect_value(tt, r.ch, 'R')
	testing.expect(tt, .Bold in r.attrs)
	testing.expect(tt, .Default_Fg not_in r.attrs)
	testing.expect(tt, r.fg[0] > 100 && r.fg[1] < 100 && r.fg[2] < 100, "R should be red")

	o := snapshot_cell(&s, 0, 1)
	testing.expect_value(tt, o.ch, 'O')
	testing.expect_value(tt, o.fg, [3]u8{0xff, 0x66, 0x00}) // 208 in libvterm's 6x6x6 cube
	testing.expect(tt, .Bold not_in o.attrs)

	tc := snapshot_cell(&s, 0, 2)
	testing.expect_value(tt, tc.fg, [3]u8{1, 2, 3})
	testing.expect_value(tt, tc.bg, [3]u8{4, 5, 6})
	testing.expect(tt, .Default_Bg not_in tc.attrs)

	v := snapshot_cell(&s, 0, 3)
	testing.expect(tt, .Reverse in v.attrs)
	testing.expect(tt, .Default_Fg in v.attrs && .Default_Bg in v.attrs)

	i := snapshot_cell(&s, 0, 4)
	testing.expect(tt, .Italic in i.attrs && .Underline in i.attrs)
}

// # teste: test_cursor_and_scrollback
@(test)
test_cursor_and_scrollback :: proc(tt: ^testing.T) {
	t := create(5, 20)
	defer destroy(t)
	for i in 1 ..= 20 { feed(t, transmute([]u8)fmt.tprintf("line %d\r\n", i)) }

	s: Snapshot
	defer snapshot_destroy(&s)
	snapshot(t, &s)
	testing.expect_value(tt, snapshot_row_text(&s, 3, context.temp_allocator), "line 20")
	testing.expect_value(tt, s.cursor_row, 4)
	testing.expect_value(tt, s.cursor_col, 0)
	testing.expect_value(tt, s.sb_len, 16)

	snapshot(t, &s, scroll = 16)
	testing.expect_value(tt, snapshot_row_text(&s, 0, context.temp_allocator), "line 1")
	testing.expect_value(tt, snapshot_row_text(&s, 4, context.temp_allocator), "line 5")
	testing.expect(tt, !s.cursor_visible)

	// Clamped past the top.
	snapshot(t, &s, scroll = 999)
	testing.expect_value(tt, s.scroll, 16)

	// Growing the screen pulls lines back from the scrollback.
	resize(t, 10, 20)
	snapshot(t, &s)
	testing.expect_value(tt, s.rows, 10)
	testing.expect_value(tt, scrollback_len(t), 11)
	testing.expect_value(tt, snapshot_row_text(&s, 0, context.temp_allocator), "line 12")
}

// # teste: test_resize_reaches_pty
@(test)
test_resize_reaches_pty :: proc(tt: ^testing.T) {
	when ODIN_OS == .Windows { return }
	t := create(24, 80)
	defer destroy(t)
	testing.expect(tt, start(t, {argv = {"/bin/sh", "-c", "sleep 0.3; stty size"}}))
	resize(t, 30, 100)
	testing.expect(tt, _wait(t, has_exited))
	s: Snapshot
	defer snapshot_destroy(&s)
	snapshot(t, &s)
	testing.expect_value(tt, s.rows, 30)
	testing.expect_value(tt, s.cols, 100)
	testing.expect_value(tt, snapshot_row_text(&s, 0, context.temp_allocator), "30 100")
}

// # teste: test_large_output_no_data_loss
@(test)
test_large_output_no_data_loss :: proc(tt: ^testing.T) {
	when ODIN_OS == .Windows { return }
	N :: 100000
	expected := 0
	for i in 1 ..= N { expected += len(fmt.tprint(i)) + 2 } // ONLCR: "\n" → "\r\n"

	t := create(24, 80)
	defer destroy(t)
	testing.expect(tt, start(t, {argv = {"/bin/sh", "-c", "seq 1 100000"}}))
	testing.expect(tt, _wait(t, has_exited, 20 * time.Second))
	// macOS' tty may emit an extra CR in ONLCR when its queue fills, so
	// the byte count is a lower bound; the content check below is exact.
	testing.expect(tt, bytes_received(t) >= expected, "bytes lost")
	testing.expect_value(tt, scrollback_len(t), SCROLLBACK_MAX)

	// Every line kept (scrollback + screen) is the exact consecutive sequence.
	s: Snapshot
	defer snapshot_destroy(&s)
	first := N - SCROLLBACK_MAX - 22 // screen holds 23 numbers + the empty prompt row
	bad := 0
	for sc := SCROLLBACK_MAX; sc > -24; sc -= 24 {
		snapshot(t, &s, max(sc, 0))
		base := SCROLLBACK_MAX - s.scroll // absolute line index of row 0
		for r in 0 ..< 24 {
			line := base + r
			if line >= SCROLLBACK_MAX + 23 { break }
			want := fmt.tprint(first + line)
			if got := snapshot_row_text(&s, r, context.temp_allocator); got != want { bad += 1 }
		}
	}
	testing.expect_value(tt, bad, 0)
	testing.expect_value(tt, _row(t, 22), "100000")
}

// # teste: test_keys_encode_to_pty_bytes
@(test)
test_keys_encode_to_pty_bytes :: proc(tt: ^testing.T) {
	t := create(5, 20)
	defer destroy(t)
	check :: proc(tt: ^testing.T, t: ^Terminal, want: string, loc := #caller_location) {
		got := take_output(t, context.temp_allocator)
		testing.expect_value(tt, string(got), want, loc = loc)
	}
	send_char(t, 'c', {.Ctrl});      check(tt, t, "\x03")
	send_key(t, .Escape);            check(tt, t, "\e")
	send_bytes(t, {0x1b, '\r'});     check(tt, t, "\e\r") // Shift+Enter (Meta+Enter)
	send_key(t, .Enter);             check(tt, t, "\r")
	send_char(t, 'x', {.Alt});       check(tt, t, "\ex")
	send_char(t, 'ç');               check(tt, t, "ç")
	send_key(t, .Up);                check(tt, t, "\e[A")
	feed(t, transmute([]u8)string("\e[?1h")) // application cursor keys
	send_key(t, .Up);                check(tt, t, "\eOA")
}

// # teste: test_paste_bracketed
@(test)
test_paste_bracketed :: proc(tt: ^testing.T) {
	t := create(5, 20)
	defer destroy(t)
	paste(t, "a\nb\r\nc")
	testing.expect_value(tt, string(take_output(t, context.temp_allocator)), "a\rb\rc")
	feed(t, transmute([]u8)string("\e[?2004h"))
	paste(t, "x\ny")
	testing.expect_value(tt, string(take_output(t, context.temp_allocator)), "\e[200~x\ry\e[201~")

	big := strings.repeat("0123456789\n", 20000, context.temp_allocator)
	paste(t, big)
	testing.expect_value(tt, len(take_output(t, context.temp_allocator)), len(big) + 12)
}

// # teste: test_many_instances
@(test)
test_many_instances :: proc(tt: ^testing.T) {
	when ODIN_OS == .Windows { return }
	ts: [8]^Terminal
	for &t in ts {
		t = create(24, 80)
		testing.expect(tt, start(t, {argv = {"/bin/sh"}}))
	}
	for t in ts { send_bytes(t, transmute([]u8)string("echo hi-$((40+2))\r")) }
	for t in ts {
		testing.expect(tt, _wait(t, proc(t: ^Terminal) -> bool { return _screen_contains(t, "hi-42") }))
	}
	for t in ts { destroy(t) }
}

// Interactive input reaches the program through the writer thread.
@(test)
test_typing_roundtrip :: proc(tt: ^testing.T) {
	when ODIN_OS == .Windows { return }
	t := create(24, 80)
	defer destroy(t)
	testing.expect(tt, start(t, {argv = {"/bin/cat"}}))
	for r in "ping" { send_char(t, r) }
	send_key(t, .Enter)
	testing.expect(tt, _wait(t, proc(t: ^Terminal) -> bool { return _row(t, 1) == "ping" }))
	send_char(t, 'c', {.Ctrl}) // ^C kills cat
	testing.expect(tt, _wait(t, has_exited))
}

// # teste: test_repo_root_finds_git_dir
@(test)
test_repo_root_finds_git_dir :: proc(tt: ^testing.T) {
	base := fmt.tprintf("%s/term_root_test_%d", os.temp_directory(context.temp_allocator) or_else "/tmp", time.now()._nsec)
	nested := fmt.tprintf("%s/a/b", base)
	testing.expect(tt, os.make_directory_all(nested) == nil)
	testing.expect(tt, os.make_directory(fmt.tprintf("%s/.git", base)) == nil)
	defer os.remove_all(base)

	root := find_repo_root(nested)
	defer delete(root)
	testing.expect_value(tt, root, base)

	none := find_repo_root("/")
	defer delete(none)
	testing.expect_value(tt, none, "/")
}
