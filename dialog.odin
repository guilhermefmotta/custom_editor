package editor

import rl "vendor:raylib"
import "core:strings"

// ---------------------------------------------------------------------------
// Shared dialog utilities
// ---------------------------------------------------------------------------

// Package-level panel state — set by dlg_begin, used by dlg_restore.
@(private="file")
_dlg_px, _dlg_py, _dlg_w, _dlg_h: f32
@(private="file")
_dlg_active: bool

// dlg_begin: draw shadow + background + border, then activate a panel-level
// scissor that clips ALL subsequent draws to the panel interior.
// The overlay (full-screen dim) must be drawn BEFORE calling this.
// Call dlg_end() when all dialog content is drawn.
dlg_begin :: proc(px, py, w, h: f32, bg, border: rl.Color) {
    _dlg_px = px; _dlg_py = py; _dlg_w = w; _dlg_h = h; _dlg_active = true
    rl.DrawRectangleV({px + 4, py + 4}, {w, h}, rl.Color{0, 0, 0, 80}) // shadow
    rl.DrawRectangleV({px, py}, {w, h}, bg)
    rl.DrawRectangleLinesEx({px, py, w, h}, 1, border)
    rl.BeginScissorMode(i32(px + 1), i32(py + 1), i32(w - 2), i32(h - 2))
}

// dlg_end: deactivate the panel scissor.
dlg_end :: proc() {
    rl.EndScissorMode()
    _dlg_active = false
}

// dlg_restore: re-enable the panel-level scissor after an inner scissor section
// (BeginScissorMode/EndScissorMode pair used for sub-regions within the dialog).
// In Raylib, inner EndScissorMode disables ALL scissoring, so call this
// immediately after any inner EndScissorMode to restore panel clipping.
dlg_restore :: proc() {
    if !_dlg_active { return }
    rl.BeginScissorMode(i32(_dlg_px + 1), i32(_dlg_py + 1), i32(_dlg_w - 2), i32(_dlg_h - 2))
}

// text_clip returns a string that fits within max_w pixels at the given font
// size. Appends "..." when truncated. Returns the original slice if it fits
// (no allocation). Otherwise uses context.temp_allocator.
text_clip :: proc(font: rl.Font, text: string, max_w, size, spacing: f32) -> string {
    if text == "" || max_w <= 0 { return "" }
    if rl.MeasureTextEx(font, to_cstring(text), size, spacing).x <= max_w { return text }

    ellipsis :: "..."
    ew := rl.MeasureTextEx(font, ellipsis, size, spacing).x
    if ew >= max_w { return "." }

    avail := max_w - ew
    end   := len(text)
    for end > 0 {
        end -= 1
        for end > 0 && (text[end] & 0xC0) == 0x80 { end -= 1 }
        sub := text[:end]
        if rl.MeasureTextEx(font, to_cstring(sub), size, spacing).x <= avail {
            return strings.concatenate({sub, ellipsis}, context.temp_allocator)
        }
    }
    return ellipsis
}

// dlg_text draws text clipped to fit between tx and (right_edge - pad).
dlg_text :: proc(font: rl.Font, text: string, tx, ty, size, spacing: f32, color: rl.Color, right_edge, pad: f32) {
    max_w := right_edge - tx - pad
    s := text_clip(font, text, max_w, size, spacing)
    if s == "" { return }
    rl.DrawTextEx(font, to_cstring(s), {tx, ty}, size, spacing, color)
}
