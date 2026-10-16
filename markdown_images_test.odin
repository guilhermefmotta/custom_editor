package editor

import "core:os"
import "core:path/filepath"
import "core:testing"

@(private="file")
_span_text :: proc(spans: [dynamic]Md_Span) -> string {
	if len(spans) == 0 { return "" }
	return spans[0].text
}

@(test)
test_md_table_parses_rows_and_alignment :: proc(t: ^testing.T) {
	src := "| Name | Qty | Note |\n|:-----|----:|:----:|\n| a | 1 | **x** |\n| b | 22 | y |\nafter"
	blocks := md_parse(src)
	defer _md_blocks_destroy(&blocks)
	testing.expect_value(t, blocks[0].kind, Md_Block_Kind.Table)
	tb := blocks[0]
	testing.expect_value(t, len(tb.rows), 3)
	testing.expect_value(t, len(tb.aligns), 3)
	testing.expect_value(t, tb.aligns[0], Md_Align.Left)
	testing.expect_value(t, tb.aligns[1], Md_Align.Right)
	testing.expect_value(t, tb.aligns[2], Md_Align.Center)
	testing.expect_value(t, _span_text(tb.rows[0][1]), "Qty")
	testing.expect_value(t, tb.rows[1][2][0].style, Md_Style.Bold)
	testing.expect_value(t, _span_text(tb.rows[2][1]), "22")
	testing.expect_value(t, blocks[1].kind, Md_Block_Kind.Paragraph) // "after" is not a row
}

@(test)
test_md_pipe_line_without_separator_is_text :: proc(t: ^testing.T) {
	blocks := md_parse("| not a table |\nplain")
	defer _md_blocks_destroy(&blocks)
	testing.expect_value(t, blocks[0].kind, Md_Block_Kind.Paragraph)
}

@(test)
test_md_task_list_and_nesting :: proc(t: ^testing.T) {
	blocks := md_parse("- [ ] todo\n- [x] done\n  - child\n1. [X] numbered")
	defer _md_blocks_destroy(&blocks)
	testing.expect_value(t, blocks[0].task, Md_Task.Open)
	testing.expect_value(t, _span_text(blocks[0].spans), "todo")
	testing.expect_value(t, blocks[1].task, Md_Task.Done)
	testing.expect_value(t, blocks[2].task, Md_Task.None)
	testing.expect_value(t, blocks[2].level, 1)
	testing.expect_value(t, blocks[3].ordered, true)
	testing.expect_value(t, blocks[3].task, Md_Task.Done)
}

@(test)
test_md_image_lines :: proc(t: ^testing.T) {
	imgs, ok := md_line_images(`![shot](docs/a b.png "title")`)
	testing.expect(t, ok)
	testing.expect_value(t, len(imgs), 1)
	testing.expect_value(t, imgs[0].alt, "shot")
	testing.expect_value(t, imgs[0].url, "docs/a")
	delete(imgs)

	imgs, ok = md_line_images(`[![CI](https://x/badge.svg)](https://x) ![two](b.png)`)
	testing.expect(t, ok)
	testing.expect_value(t, len(imgs), 2)
	testing.expect_value(t, imgs[0].url, "https://x/badge.svg")
	testing.expect_value(t, imgs[1].url, "b.png")
	delete(imgs)

	imgs, ok = md_line_images(`<img src="layout.png" width="600" alt="Layout">`)
	testing.expect(t, ok)
	testing.expect_value(t, imgs[0].url, "layout.png")
	testing.expect_value(t, imgs[0].alt, "Layout")
	delete(imgs)

	_, ok = md_line_images("text ![x](y.png)")
	testing.expect(t, !ok)

	blocks := md_parse("see ![logo](l.png) here")
	defer _md_blocks_destroy(&blocks)
	testing.expect_value(t, blocks[0].kind, Md_Block_Kind.Paragraph)
	testing.expect_value(t, blocks[0].spans[0].text, "see ") // no stray "!"
	testing.expect_value(t, blocks[0].spans[1].style, Md_Style.Link)
}

@(test)
test_md_image_path :: proc(t: ^testing.T) {
	md := filepath.join({"/repo", "docs", "README.md"}, context.temp_allocator) or_else ""
	testing.expect_value(t, md_image_path(md, "https://x/y.png"), "")
	testing.expect_value(t, md_image_path(md, "img/a%20b.png?raw=true"), "/repo/docs/img/a b.png")
	testing.expect_value(t, md_image_path(md, "./shot.png"), "/repo/docs/shot.png")
}

@(test)
test_image_file_opens_read_only :: proc(t: ^testing.T) {
	base := os.get_env("TMPDIR", context.temp_allocator)
	if base == "" { base = "." }
	path, _ := filepath.join({base, "editor_img_test.png"}, context.temp_allocator)
	DATA :: "\x89PNG fake bytes"
	testing.expect(t, os.write_entire_file(path, transmute([]byte)string(DATA)) == nil)
	defer os.remove(path)

	p := pane_init()
	defer pane_destroy(&p)
	testing.expect(t, pane_open(&p, path))
	testing.expect(t, p.image.active)
	testing.expect_value(t, buffer_len(&p.buf), 0)
	ok, _ := pane_save(&p)
	testing.expect(t, !ok)
	data, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, string(data), DATA) // never overwritten

	testing.expect(t, is_image_file("a/B.JPG"))
	testing.expect(t, !is_image_file("a.svg"))
}

@(test)
test_image_zoom_math :: proc(t: ^testing.T) {
	testing.expect_value(t, image_fit_zoom(4000, 1000, 2000, 1000), f32(0.5))
	testing.expect_value(t, image_fit_zoom(100, 100, 2000, 1000), f32(1)) // small: not enlarged
	// zooming 2x around the image point under the anchor keeps it there
	off := image_zoom_offset({0, 0}, {100, 0}, 1, 2)
	testing.expect_value(t, off, [2]f32{-100, 0})
}
