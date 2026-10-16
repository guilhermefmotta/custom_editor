package editor

// Images: an image file opened in a pane shows the picture instead of its
// bytes (zoom, pan, fit), and the Markdown preview draws ![alt](path).
//
// Both share a texture cache keyed by absolute path. Textures are created
// lazily from the draw code (the only place with a GL context — tests and
// pane_open never touch the GPU), with mipmaps + trilinear filtering so a
// zoomed-out picture is not aliased. The cache keeps IMG_CACHE_MAX textures
// and drops the least recently drawn one past that; a file that fails to
// load is remembered too, so it is not retried every frame.
//
// Formats are what raylib decodes: PNG, JPG, BMP, GIF (first frame), TGA,
// QOI. WEBP/SVG are not image files here (SVG still opens as text).

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import rl "vendor:raylib"

IMAGE_EXTS :: []string{".png", ".jpg", ".jpeg", ".bmp", ".gif", ".tga", ".qoi"}
IMG_CACHE_MAX :: 24
IMG_ZOOM_MIN  :: f32(0.02)
IMG_ZOOM_MAX  :: f32(32)
IMG_ZOOM_STEP :: f32(1.25)
IMG_PAN_STEP  :: f32(60)

is_image_file :: proc(path: string) -> bool {
	ext := strings.to_lower(filepath.ext(path), context.temp_allocator)
	for x in IMAGE_EXTS { if ext == x { return true } }
	return false
}

// ---------------------------------------------------------------------------
// Texture cache
// ---------------------------------------------------------------------------

Img_Entry :: struct {
	tex:   rl.Texture2D,
	ok:    bool,
	bytes: i64, // file size
	used:  u64, // frame stamp of the last img_get
}

@(private="file") _img_cache: map[string]Img_Entry // keys owned
@(private="file") _img_stamp: u64

@(fini)
_img_cache_fini :: proc "contextless" () {
	context = runtime.default_context()
	// The GL context is gone by now: only the keys are ours to free
	for k in _img_cache { delete(k) }
	delete(_img_cache)
}

// Texture for `path` (loaded on first use). Draw code only.
img_get :: proc(path: string) -> ^Img_Entry {
	_img_stamp += 1
	if ent, ok := &_img_cache[path]; ok {
		ent.used = _img_stamp
		return ent
	}
	if len(_img_cache) >= IMG_CACHE_MAX { _img_evict_oldest() }

	ent: Img_Entry
	ent.used = _img_stamp
	if fi, err := os.stat(path, context.temp_allocator); err == nil { ent.bytes = fi.size }
	img := rl.LoadImage(to_cstring(path))
	if img.data != nil {
		ent.tex = rl.LoadTextureFromImage(img)
		rl.UnloadImage(img)
		if ent.tex.id != 0 {
			rl.GenTextureMipmaps(&ent.tex)
			rl.SetTextureFilter(ent.tex, .TRILINEAR)
			ent.ok = true
		}
	}
	_img_cache[strings.clone(path)] = ent
	return &_img_cache[path]
}

// Forget a path (file changed on disk / reopened): next img_get reloads it.
img_forget :: proc(path: string) {
	if _, has := _img_cache[path]; !has { return }
	k, v := delete_key(&_img_cache, path)
	if v.ok { rl.UnloadTexture(v.tex) }
	delete(k)
}

@(private="file")
_img_evict_oldest :: proc() {
	oldest_key: string
	oldest := max(u64)
	for k, v in _img_cache {
		if v.used < oldest { oldest = v.used; oldest_key = k }
	}
	if oldest_key != "" { img_forget(oldest_key) }
}

// "245 KB" / "1.2 MB"
img_size_text :: proc(bytes: i64) -> string {
	switch {
	case bytes >= 1024 * 1024: return fmt.tprintf("%.1f MB", f64(bytes) / (1024 * 1024))
	case bytes >= 1024:        return fmt.tprintf("%d KB", bytes / 1024)
	}
	return fmt.tprintf("%d B", bytes)
}

// ---------------------------------------------------------------------------
// Image viewer (pane state)
// ---------------------------------------------------------------------------

Image_View :: struct {
	active: bool,
	fit:    bool,         // zoom follows the pane size
	zoom:   f32,          // layout units per image pixel
	off:    rl.Vector2,   // image center relative to the content center
	rect:   rl.Rectangle, // content area of the last draw (mouse)
}

// Called by pane_open for image files: nothing is read into the buffer.
image_view_open :: proc(p: ^Pane) {
	img_forget(p.filename) // pick up a file that changed since it was cached
	p.image = Image_View{active = true, fit = true}
}

// Zoom factor that shows the whole image (never enlarges small ones).
image_fit_zoom :: proc(w, h: i32, area_w, area_h: f32) -> f32 {
	if w <= 0 || h <= 0 { return 1 }
	return min(1, area_w / f32(w), area_h / f32(h))
}

// New offset that keeps the image point under `anchor` fixed while the zoom
// goes from z to nz (anchor relative to the content center).
image_zoom_offset :: proc(off, anchor: rl.Vector2, z, nz: f32) -> rl.Vector2 {
	u := (anchor - off) / z
	return anchor - u * nz
}

image_view_set_zoom :: proc(iv: ^Image_View, nz: f32, anchor: rl.Vector2) {
	nz := clamp(nz, IMG_ZOOM_MIN, IMG_ZOOM_MAX)
	if iv.zoom <= 0 { iv.zoom = 1 }
	iv.off  = image_zoom_offset(iv.off, anchor, iv.zoom, nz)
	iv.zoom = nz
	iv.fit  = false
}

image_view_draw :: proc(p: ^Pane, font: rl.Font, ox, oy, ow, oh: f32) {
	iv := &p.image
	iv.rect = {ox, oy, ow, oh}
	ui_scissor_begin(i32(ox), i32(oy), i32(ow), i32(oh))
	defer rl.EndScissorMode()
	rl.DrawRectangleV({ox, oy}, {ow, oh}, STATUS_BG)

	ent := img_get(p.filename)
	if !ent.ok {
		msg := "Could not load this image"
		w := rl.MeasureTextEx(font, to_cstring(msg), FONT_SIZE, CHAR_SPACING).x
		draw_text(font, to_cstring(msg), {ox + (ow - w) * 0.5, oy + oh * 0.4}, FONT_SIZE, CHAR_SPACING, LINENUM)
		return
	}
	PAD :: f32(16)
	if iv.fit || iv.zoom <= 0 {
		iv.zoom = image_fit_zoom(ent.tex.width, ent.tex.height, ow - PAD * 2, oh - PAD * 2)
		iv.off  = {}
	}
	w := f32(ent.tex.width) * iv.zoom
	h := f32(ent.tex.height) * iv.zoom
	cx := ox + ow * 0.5 + iv.off.x
	cy := oy + oh * 0.5 + iv.off.y
	dst := rl.Rectangle{math.round(cx - w * 0.5), math.round(cy - h * 0.5), w, h}
	_img_checker(dst) // transparent pixels read as transparent
	rl.DrawTexturePro(ent.tex, {0, 0, f32(ent.tex.width), f32(ent.tex.height)}, dst, {}, 0, rl.WHITE)
}

// Light checkerboard under the image (visible through transparent pixels).
@(private="file")
_img_checker :: proc(r: rl.Rectangle) {
	CELL :: f32(8)
	A :: rl.Color{58, 58, 64, 255}
	B :: rl.Color{78, 78, 86, 255}
	rl.DrawRectangleRec(r, A)
	vis := r
	if vis.width * vis.height > 4_000_000 { return } // huge zoom: plain background
	for y := f32(0); y < r.height; y += CELL {
		for x := f32(0); x < r.width; x += CELL {
			if (int(x / CELL) + int(y / CELL)) % 2 == 0 { continue }
			rl.DrawRectangleRec({r.x + x, r.y + y, min(CELL, r.width - x), min(CELL, r.height - y)}, B)
		}
	}
}

// Status line text for an image pane.
image_view_status :: proc(p: ^Pane) -> string {
	name := path_basename(p.filename)
	ext  := strings.to_upper(strings.trim_prefix(filepath.ext(p.filename), "."), context.temp_allocator)
	ent  := img_get(p.filename)
	if !ent.ok { return fmt.tprintf(" %s — %s", name, ext) }
	return fmt.tprintf(" %s — %dx%d %s, %s — %d%%   + - zoom  0 fit  1 actual size  drag/arrows pan",
		name, ent.tex.width, ent.tex.height, ext, img_size_text(ent.bytes), int(math.round(p.image.zoom * 100)))
}

// Keyboard (read-only view: swallows everything else, like the Markdown
// preview). Ctrl/Cmd shortcuts were already handled by the global phase.
handle_image_view :: proc(e: ^Editor, p: ^Pane) -> bool {
	iv := &p.image
	if !iv.active { return false }
	if ctrl() || alt() { return true }
	center := rl.Vector2{}
	switch {
	case rl.IsKeyPressed(.EQUAL), rl.IsKeyPressed(.KP_ADD):
		image_view_set_zoom(iv, iv.zoom * IMG_ZOOM_STEP, center)
	case rl.IsKeyPressed(.MINUS), rl.IsKeyPressed(.KP_SUBTRACT):
		image_view_set_zoom(iv, iv.zoom / IMG_ZOOM_STEP, center)
	case rl.IsKeyPressed(.ZERO), rl.IsKeyPressed(.KP_0):
		iv.fit = true
	case rl.IsKeyPressed(.ONE), rl.IsKeyPressed(.KP_1):
		image_view_set_zoom(iv, 1, center)
	case key_rep(.LEFT) || key_rep(.H):  iv.off.x += IMG_PAN_STEP; iv.fit = false
	case key_rep(.RIGHT) || key_rep(.L): iv.off.x -= IMG_PAN_STEP; iv.fit = false
	case key_rep(.UP) || key_rep(.K):    iv.off.y += IMG_PAN_STEP; iv.fit = false
	case key_rep(.DOWN) || key_rep(.J):  iv.off.y -= IMG_PAN_STEP; iv.fit = false
	}
	return true
}

// Mouse over an image pane: wheel zooms around the pointer, left drag pans.
// true = the event was used.
image_view_mouse :: proc(p: ^Pane, mp: rl.Vector2, wheel: f32) -> bool {
	iv := &p.image
	if !iv.active || !rl.CheckCollisionPointRec(mp, iv.rect) { return false }
	center := rl.Vector2{iv.rect.x + iv.rect.width * 0.5, iv.rect.y + iv.rect.height * 0.5}
	used := false
	if wheel != 0 {
		image_view_set_zoom(iv, iv.zoom * math.pow(IMG_ZOOM_STEP, wheel), mp - center)
		used = true
	}
	if rl.IsMouseButtonDown(.LEFT) {
		if d := rl.GetMouseDelta() / ui_scale(); d != {} { // delta is not mouse-scaled
			iv.off += d
			iv.fit = false
			used = true
		}
	}
	return used
}
