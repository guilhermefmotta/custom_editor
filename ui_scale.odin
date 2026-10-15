package editor

// Display scaling on Windows (125%, 150%...).
//
// raylib's WINDOW_HIGHDPI is broken on Windows (it reports the window size
// already multiplied by the scale without scaling the drawing), so there the
// window runs at physical resolution (GLFW makes the process DPI-aware) and the
// editor scales itself, the way raylib does on macOS:
//   - every frame is drawn under a 2D camera zoomed by the scale;
//   - the font atlas is rasterized at FONT_SIZE x scale (font_pixel_size), so
//     text lands 1:1 on physical pixels — crisp, not stretched;
//   - the mouse is scaled back to layout coordinates (SetMouseScale);
//   - layout reads the logical size (screen_w/screen_h) and scissor rectangles
//     are converted to physical pixels (ui_scissor_begin).
// On macOS (raylib's HIGHDPI) and Linux the display part is 1.
//
// On top of that, the "UI scale" setting (UI_ZOOM, [window] ui_scale) zooms
// the whole interface the same way on every OS.

import "core:math"
import rl "vendor:raylib"

// "UI scale" setting as a factor (1 = 100%); set by settings_panel.odin.
UI_ZOOM: f32 = 1

// "Smooth text" setting: glyph atlases rasterized at FONT_OVERSAMPLE x and
// filtered down with mipmaps, so text drawn smaller than the atlas (the UI
// uses FONT_SIZE-1/-2/-4 in many places) is not jagged.
FONT_SMOOTH := true
FONT_OVERSAMPLE :: 2

// Display scale the editor applies itself (Windows only, see above).
_display_scale :: proc() -> f32 {
	when ODIN_OS == .Windows {
		s := rl.GetWindowScaleDPI().x
		return s if s > 1 else 1
	} else {
		return 1
	}
}

ui_scale :: proc() -> f32 {
	return _display_scale() * UI_ZOOM
}

// UI_ZOOM for a [window] ui_scale value (percent, 0 = automatic).
ui_zoom_from_percent :: proc(pct: int) -> f32 {
	if pct <= 0 { return 1 }
	return f32(pct) / 100
}

// Texture filter for a glyph atlas: trilinear over mipmaps when smoothing,
// plain bilinear otherwise.
font_texture_setup :: proc(f: ^rl.Font) {
	if FONT_SMOOTH {
		rl.GenTextureMipmaps(&f.texture)
		rl.SetTextureFilter(f.texture, .TRILINEAR)
	} else {
		rl.SetTextureFilter(f.texture, .BILINEAR)
	}
}

// Layout size of the window (physical size / scale).
screen_w :: proc() -> i32 { return i32(f32(rl.GetScreenWidth()) / ui_scale()) }
screen_h :: proc() -> i32 { return i32(f32(rl.GetScreenHeight()) / ui_scale()) }

// Before reading input: mouse positions in layout coordinates.
ui_frame_input :: proc() {
	s := ui_scale()
	rl.SetMouseScale(1 / s, 1 / s)
}

// After BeginDrawing / before EndDrawing: draw the frame scaled.
// BeginMode2D drops raylib's own HIGHDPI scale matrix (macOS Retina), so the
// camera carries it too there.
ui_frame_begin :: proc() {
	s := ui_scale()
	if s == 1 { return }
	when ODIN_OS == .Darwin {
		if d := rl.GetWindowScaleDPI().x; d > 1 { s *= d }
	}
	rl.BeginMode2D(rl.Camera2D{zoom = s})
}
ui_frame_end :: proc() {
	if ui_scale() != 1 { rl.EndMode2D() }
}

// BeginScissorMode with a rectangle in layout coordinates.
ui_scissor_begin :: proc(x, y, w, h: i32) {
	s := ui_scale()
	if s == 1 { rl.BeginScissorMode(x, y, w, h); return }
	x0 := i32(math.floor(f32(x) * s))
	y0 := i32(math.floor(f32(y) * s))
	rl.BeginScissorMode(x0, y0, i32(math.ceil(f32(x + w) * s)) - x0, i32(math.ceil(f32(y + h) * s)) - y0)
}
