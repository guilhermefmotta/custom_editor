package editor

import "core:testing"

@(test)
test_snap_y_lands_on_physical_pixels :: proc(t: ^testing.T) {
	old := _frame_px_scale
	defer _frame_px_scale = old

	_frame_px_scale = 1
	testing.expect_value(t, _snap_y(10.5), f32(11))
	testing.expect_value(t, _snap_y(10.4), f32(10))

	_frame_px_scale = 2 // Retina: half layout units are whole pixels
	testing.expect_value(t, _snap_y(10.5), f32(10.5))

	_frame_px_scale = 1.25 // Windows 125%: 1.5 -> 1.875 px -> 2 px -> 1.6
	testing.expect_value(t, _snap_y(1.5), f32(1.6))
}
