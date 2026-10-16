package editor

import "core:testing"

@(private="file")
_vim_test_pane :: proc(text: string) -> (e: Editor) {
	e.panes = make([dynamic]Pane)
	append(&e.panes, pane_init())
	buffer_insert_string(&e.panes[0].buf, 0, text)
	return
}

@(private="file")
_vim_test_destroy :: proc(e: ^Editor) {
	for &p in e.panes { pane_destroy(&p) }
	delete(e.panes)
	vim_destroy(&e.vim)
}

@(private="file")
_keys :: proc(e: ^Editor, s: string) {
	for ch in s { vim_dispatch_normal_char(e, &e.panes[0], ch) }
}

@(test)
test_vim_dollar_lands_on_last_char :: proc(t: ^testing.T) {
	e := _vim_test_pane("func main() {\n\tx := 1\n\n}")
	defer _vim_test_destroy(&e)
	p := &e.panes[0]

	_keys(&e, "$")
	testing.expect_value(t, p.cursor, 12) // on '{', not after it
	_keys(&e, "l")
	testing.expect_value(t, p.cursor, 12) // l stops at the last char
	_keys(&e, "j")
	testing.expect_value(t, p.cursor, 14 + 6) // shorter line: its last char

	p.cursor = 0
	_keys(&e, "d$")
	testing.expect_value(t, string(buffer_to_string(&p.buf, context.temp_allocator)), "\n\tx := 1\n\n}")
}

@(test)
test_vim_dollar_empty_line_and_utf8 :: proc(t: ^testing.T) {
	e := _vim_test_pane("ação\n\nb")
	defer _vim_test_destroy(&e)
	p := &e.panes[0]

	_keys(&e, "$")
	testing.expect_value(t, p.cursor, 5) // the "o" (ç and ã are 2 bytes each)
	p.cursor = 7                         // the empty line
	_keys(&e, "$")
	testing.expect_value(t, p.cursor, 7)
	_keys(&e, "d$")
	testing.expect_value(t, string(buffer_to_string(&p.buf, context.temp_allocator)), "ação\n\nb")
}
