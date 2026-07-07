package editor

import conf "./config"
import rl   "vendor:raylib"

// keymap_switch_reset: called once whenever the palette's "Set Keymap Mode"
// command changes e.cfg.editor.keymap_mode at runtime, so switching mid
// Vim-Insert or mid Emacs-prefix-chord never leaves the editor in a broken
// hybrid state (a stray pending operator, an armed macro recording, a
// half-typed C-x chord, ...).
keymap_switch_reset :: proc(e: ^Editor) {
	vim_reset(&e.vim)
	emacs_reset(&e.emacs)
	p := active_pane(e)
	if e.cfg.editor.keymap_mode == .Vim {
		// Vim's Normal mode has no ambient selection outside Visual mode.
		p.sel_anchor = p.cursor
	}
	_rep_key = .KEY_NULL
	mc_clear(p)
}

keymap_mode_name :: proc(m: conf.Keymap_Mode) -> string {
	switch m {
	case .Normal: return "Normal"
	case .Vim:    return "Vim"
	case .Emacs:  return "Emacs"
	}
	return "Normal"
}

VIM_MODE_COL_NORMAL  := rl.Color{166, 227, 161, 255} // green
VIM_MODE_COL_INSERT  := rl.Color{249, 226, 175, 255} // yellow
VIM_MODE_COL_VISUAL  := rl.Color{203, 166, 247, 255} // mauve
VIM_MODE_COL_REPLACE := rl.Color{243, 139, 168, 255} // red
EMACS_MODE_COL       := rl.Color{137, 180, 250, 255} // blue

// _keymap_badge: status-bar mode indicator (like vim-airline's mode block).
// Empty text = no badge (Normal keymap doesn't need one, it's modeless).
_keymap_badge :: proc(e: ^Editor) -> (text: string, col: rl.Color) {
	switch e.cfg.editor.keymap_mode {
	case .Normal:
		return "", BG
	case .Vim:
		switch e.vim.mode {
		case .Normal:      return " NORMAL ", VIM_MODE_COL_NORMAL
		case .Insert:      return " INSERT ", VIM_MODE_COL_INSERT
		case .Visual:      return " VISUAL ", VIM_MODE_COL_VISUAL
		case .Visual_Line: return " V-LINE ", VIM_MODE_COL_VISUAL
		case .Replace:     return " REPLACE ", VIM_MODE_COL_REPLACE
		}
	case .Emacs:
		if e.emacs.isearch.active { return " I-SEARCH ", VIM_MODE_COL_INSERT }
		if e.emacs.mark_active    { return " MARK ", VIM_MODE_COL_VISUAL }
		return " EMACS ", EMACS_MODE_COL
	}
	return "", BG
}

// Block cursor in every Vim mode except Insert (which keeps the thin beam) —
// matches real Vim's modal cursor convention.
_vim_cursor_is_block :: proc(e: ^Editor) -> bool {
	if e.cfg.editor.keymap_mode != .Vim { return false }
	return e.vim.mode != .Insert
}
