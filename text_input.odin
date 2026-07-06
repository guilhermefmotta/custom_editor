package editor

import rl "vendor:raylib"

// Shared single-line text-field key handling used by every dialog input
// (palette query, file tree filter, rename box, commit message, ...).
// Centralizes what used to be duplicated per-dialog: held-repeat Backspace,
// Ctrl+A select-all / Ctrl+C copy / Ctrl+V paste, and UTF-8 typed-character
// insertion. Before this, each dialog hand-rolled its own subset — some
// supported multi-byte UTF-8, some didn't; none walked back over UTF-8
// continuation bytes on backspace, so deleting after a multi-byte rune left
// a corrupted trailing byte. One implementation now, so every input behaves
// the same and that class of bug can't reappear file-by-file.
//
// accept: optional predicate restricting which runes may be typed or pasted
// (e.g. digits-only for "Go to Line"). nil accepts any printable rune.
// transform: optional per-rune rewrite applied before the accept check
// (e.g. normalizing '\' to '/' for path input). nil leaves runes as-is.
//
// Returns true if `buf` changed this frame.
text_input_handle :: proc(
	buf: ^[dynamic]u8, sel_all: ^bool,
	accept: proc(r: rune) -> bool = nil,
	transform: proc(r: rune) -> rune = nil,
) -> bool {
	if ctrl() && rl.IsKeyPressed(.A) { sel_all^ = true; return false }

	if ctrl() && rl.IsKeyPressed(.C) {
		if len(buf) > 0 { rl.SetClipboardText(to_cstring(string(buf[:]))) }
		return false
	}

	if ctrl() && rl.IsKeyPressed(.V) {
		raw := rl.GetClipboardText()
		if raw == nil { return false }
		if sel_all^ { clear(buf); sel_all^ = false }
		changed := false
		for r in string(raw) {
			_text_input_put(buf, r, accept, transform, &changed)
		}
		return changed
	}

	if key_rep(.BACKSPACE) {
		if sel_all^ {
			clear(buf); sel_all^ = false
		} else if len(buf) > 0 {
			// Walk back over UTF-8 continuation bytes, then drop the lead byte.
			for len(buf) > 0 && (buf[len(buf)-1] & 0xC0) == 0x80 { pop(buf) }
			if len(buf) > 0 { pop(buf) }
		}
		return true
	}

	changed := false
	for {
		ch := rl.GetCharPressed()
		if ch == 0 { break }
		if sel_all^ { clear(buf); sel_all^ = false }
		_text_input_put(buf, ch, accept, transform, &changed)
	}
	return changed
}

@(private="file")
_text_input_put :: proc(buf: ^[dynamic]u8, r: rune, accept: proc(r: rune) -> bool, transform: proc(r: rune) -> rune, changed: ^bool) {
	rr := r
	if rr < 32 { return }
	if transform != nil { rr = transform(rr) }
	if accept != nil && !accept(rr) { return }
	enc: [4]u8
	n := rune_encode(rr, &enc)
	for i in 0..<n { append(buf, enc[i]) }
	changed^ = true
}

// accept_digit restricts text_input_handle to ASCII digits (e.g. line numbers).
accept_digit :: proc(r: rune) -> bool { return r >= '0' && r <= '9' }
