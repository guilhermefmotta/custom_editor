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

// Fade-in tracking. Only one modal dialog is ever open at a time in this
// editor, so a single "was any panel drawn last frame" flag is enough to
// detect a fresh open (gap since the last dlg_begin call) without every
// call site needing to pass an identity/timestamp of its own.
@(private="file")
_dlg_drawn_last_frame, _dlg_drawn_this_frame: bool
@(private="file")
_dlg_open_t0: f64

FADE_DUR :: f32(0.10) // seconds

// dlg_frame_tick: call once per frame, before any dialog rendering.
dlg_frame_tick :: proc() {
    _dlg_drawn_last_frame = _dlg_drawn_this_frame
    _dlg_drawn_this_frame = false
}

// dlg_fade_alpha: 0..1 ease-out ramp, 1 once a panel has been open longer
// than FADE_DUR. Also marks a panel as drawn this frame.
dlg_fade_alpha :: proc() -> f32 {
    now := f64(rl.GetTime())
    if !_dlg_drawn_last_frame { _dlg_open_t0 = now }
    _dlg_drawn_this_frame = true
    t := f32(now - _dlg_open_t0)
    if t >= FADE_DUR { return 1 }
    k := t / FADE_DUR
    return 1 - (1 - k) * (1 - k) // ease-out quad
}

@(private="file")
_fade :: proc(c: rl.Color, a: f32) -> rl.Color {
    return rl.Color{c.r, c.g, c.b, u8(f32(c.a) * a)}
}

// ---------------------------------------------------------------------------
// Drag-to-move (hold Ctrl + drag with the left mouse button anywhere on a
// panel). Only one modal dialog is ever open at a time in this editor (see
// the fade-tracking note below), so a single global drag offset is enough —
// it's reset whenever a dialog freshly opens so a previous drag never leaks
// into the next dialog shown.
// ---------------------------------------------------------------------------

@(private="file")
_dlg_off: rl.Vector2
@(private="file")
_dlg_dragging: bool
@(private="file")
_dlg_drag_mouse0: rl.Vector2
@(private="file")
_dlg_drag_off0: rl.Vector2

// _dlg_handle_drag takes the panel's normally-computed (un-offset) position
// and returns where it should actually be drawn this frame, updating the
// drag offset in response to Ctrl+drag.
@(private="file")
_dlg_handle_drag :: proc(px, py, w, h: f32) -> (f32, f32) {
    cx := px + _dlg_off.x
    cy := py + _dlg_off.y
    mp := rl.GetMousePosition()

    if _dlg_dragging {
        if rl.IsMouseButtonDown(.LEFT) {
            _dlg_off = _dlg_drag_off0 + (mp - _dlg_drag_mouse0)
            cx = px + _dlg_off.x
            cy = py + _dlg_off.y
        } else {
            _dlg_dragging = false
        }
    } else if ctrl() && rl.IsMouseButtonPressed(.LEFT) {
        if mp.x >= cx && mp.x < cx+w && mp.y >= cy && mp.y < cy+h {
            _dlg_dragging    = true
            _dlg_drag_mouse0 = mp
            _dlg_drag_off0   = _dlg_off
        }
    }
    return cx, cy
}

// dlg_begin: draw a soft layered shadow + background + border + a subtle
// top highlight hairline (simulates light catching the panel's top edge),
// then activate a panel-level scissor that clips ALL subsequent draws to
// the panel interior.
// The overlay (full-screen dim) must be drawn BEFORE calling this.
// Returns the panel's actual (px, py) for this frame — offset by any active
// Ctrl+drag — which callers must use for all their own subsequent drawing
// (reassign into the same px, py locals) so dragged content stays aligned
// with the panel background.
// Call dlg_end() when all dialog content is drawn.
dlg_begin :: proc(px, py, w, h: f32, bg, border: rl.Color) -> (f32, f32) {
    if !_dlg_drawn_last_frame {
        _dlg_off      = {0, 0}
        _dlg_dragging = false
    }

    px, py := _dlg_handle_drag(px, py, w, h)

    _dlg_px = px; _dlg_py = py; _dlg_w = w; _dlg_h = h; _dlg_active = true

    a := dlg_fade_alpha() // 0..1 pop-in ramp over FADE_DUR on fresh open

    // Soft layered shadow — a few widening, thinning rects reads as a cheap
    // blur without needing a real blur pass.
    rl.DrawRectangleV({px + 8, py + 10}, {w, h}, _fade({0, 0, 0, 35}, a))
    rl.DrawRectangleV({px + 5, py + 7},  {w, h}, _fade({0, 0, 0, 55}, a))
    rl.DrawRectangleV({px + 2, py + 3},  {w, h}, _fade({0, 0, 0, 90}, a))

    rl.DrawRectangleV({px, py}, {w, h}, _fade(bg, a))
    rl.DrawRectangleLinesEx({px, py, w, h}, 1, _fade(border, a))

    // Top highlight hairline: a faint lighter line just inside the border,
    // like light grazing the panel's top edge — cheap way to add depth
    // without touching the (risky-to-round) scissor geometry.
    rl.DrawLineV({px + 1, py + 1}, {px + w - 1, py + 1}, _fade({255, 255, 255, 18}, a))

    rl.BeginScissorMode(i32(px + 1), i32(py + 1), i32(w - 2), i32(h - 2))

    return px, py
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
