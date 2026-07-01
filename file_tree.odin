package editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import rl "vendor:raylib"

File_Tree_Mode :: enum { Browse, Rename, Confirm_Delete, Make_Dir }

File_Tree_Node :: struct {
	name:     string, // display name (heap)
	path:     string, // full relative path (heap)
	is_dir:   bool,
	depth:    int,
	expanded: bool,
}

File_Tree :: struct {
	open:       bool,
	nodes:      [dynamic]File_Tree_Node,
	selected:   int,
	scroll:     int,
	mode:       File_Tree_Mode,
	input_buf:  [dynamic]u8,
	status_msg: string,
}

file_tree_init :: proc() -> File_Tree {
	ft: File_Tree
	ft.nodes     = make([dynamic]File_Tree_Node)
	ft.input_buf = make([dynamic]u8)
	return ft
}

file_tree_destroy :: proc(ft: ^File_Tree) {
	for n in ft.nodes { delete(n.name); delete(n.path) }
	delete(ft.nodes)
	delete(ft.input_buf)
	ft^ = {}
}

file_tree_open :: proc(ft: ^File_Tree) {
	ft.open       = true
	ft.selected   = 0
	ft.scroll     = 0
	ft.mode       = .Browse
	ft.status_msg = ""
	for n in ft.nodes { delete(n.name); delete(n.path) }
	clear(&ft.nodes)
	_ft_load_children(ft, ".", 0, 0)
}

file_tree_close :: proc(ft: ^File_Tree) {
	ft.open       = false
	ft.mode       = .Browse
	ft.status_msg = ""
}

_ft_load_children :: proc(ft: ^File_Tree, dir_path: string, depth: int, insert_idx: int) -> int {
	SKIP :: [?]string{".git", "node_modules", "target", "__pycache__",
	                  ".cache", "build", "dist", ".next", "vendor"}

	f, ferr := os.open(dir_path)
	if ferr != nil { return 0 }
	defer os.close(f)

	it := os.read_directory_iterator_create(f)
	defer os.read_directory_iterator_destroy(&it)

	dirs  := make([dynamic]File_Tree_Node, context.temp_allocator)
	files := make([dynamic]File_Tree_Node, context.temp_allocator)

	for {
		fi, _, ok := os.read_directory_iterator(&it)
		if !ok { break }
		// NOTE: on Linux the iterator owns fi memory — it auto-frees prev fi on
		// next call and on destroy. Do NOT call file_info_delete manually.
		// Clone the data we need immediately before the next iteration.

		name   := fi.name
		is_dir := fi.type == .Directory

		skip := len(name) > 0 && name[0] == '.'
		if !skip { for s in SKIP { if name == s { skip = true; break } } }
		if skip { continue }

		full, _ := filepath.join({dir_path, name}, context.allocator)
		node := File_Tree_Node{
			name   = strings.clone(name),
			path   = full,
			is_dir = is_dir,
			depth  = depth,
		}
		if is_dir { append(&dirs, node) } else { append(&files, node) }
	}

	_ft_sort_nodes :: proc(arr: ^[dynamic]File_Tree_Node) {
		for i in 1..<len(arr) {
			key := arr[i]; j := i - 1
			for j >= 0 && arr[j].name > key.name { arr[j+1] = arr[j]; j -= 1 }
			arr[j+1] = key
		}
	}
	_ft_sort_nodes(&dirs)
	_ft_sort_nodes(&files)

	pos := insert_idx
	for n in dirs  { inject_at(&ft.nodes, pos, n); pos += 1 }
	for n in files { inject_at(&ft.nodes, pos, n); pos += 1 }
	return pos - insert_idx
}

_ft_toggle_dir :: proc(ft: ^File_Tree, idx: int) {
	n := &ft.nodes[idx]
	if !n.is_dir { return }

	if n.expanded {
		child_depth := n.depth + 1
		end := idx + 1
		for end < len(ft.nodes) && ft.nodes[end].depth >= child_depth { end += 1 }
		for i := end - 1; i > idx; i -= 1 {
			delete(ft.nodes[i].name)
			delete(ft.nodes[i].path)
			ordered_remove(&ft.nodes, i)
		}
		n.expanded = false
	} else {
		_ft_load_children(ft, n.path, n.depth + 1, idx + 1)
		// Re-fetch pointer after dynamic array resize
		ft.nodes[idx].expanded = true
	}
}

// ---- Input ----

FILE_TREE_MAX_VIS :: 24

file_tree_handle_input :: proc(ft: ^File_Tree, e: ^Editor) {
	switch ft.mode {
	case .Browse:          file_tree_browse_input(ft, e)
	case .Rename:          file_tree_text_input(ft, e, .Rename)
	case .Make_Dir:        file_tree_text_input(ft, e, .Make_Dir)
	case .Confirm_Delete:  file_tree_delete_input(ft, e)
	}
}

file_tree_browse_input :: proc(ft: ^File_Tree, e: ^Editor) {
	if rl.IsKeyPressed(.ESCAPE) { file_tree_close(ft); return }

	n := len(ft.nodes)

	if key_rep(.UP) {
		if ft.selected > 0 {
			ft.selected -= 1
			if ft.selected < ft.scroll { ft.scroll = ft.selected }
		}
		return
	}
	if key_rep(.DOWN) {
		if ft.selected < n - 1 {
			ft.selected += 1
			if ft.selected >= ft.scroll + FILE_TREE_MAX_VIS {
				ft.scroll = ft.selected - FILE_TREE_MAX_VIS + 1
			}
		}
		return
	}
	if rl.IsKeyPressed(.LEFT) {
		if ft.selected < len(ft.nodes) {
			nd := &ft.nodes[ft.selected]
			if nd.is_dir && nd.expanded {
				_ft_toggle_dir(ft, ft.selected)
			} else {
				d := nd.depth - 1
				for i := ft.selected - 1; i >= 0; i -= 1 {
					if ft.nodes[i].depth == d { ft.selected = i; break }
				}
			}
		}
		return
	}
	if rl.IsKeyPressed(.RIGHT) {
		if ft.selected < len(ft.nodes) {
			nd := &ft.nodes[ft.selected]
			if nd.is_dir && !nd.expanded { _ft_toggle_dir(ft, ft.selected) }
		}
		return
	}
	if rl.IsKeyPressed(.ENTER) {
		if ft.selected < len(ft.nodes) {
			nd := &ft.nodes[ft.selected]
			if nd.is_dir {
				_ft_toggle_dir(ft, ft.selected)
			} else {
				editor_open(e, nd.path)
				file_tree_close(ft)
			}
		}
		return
	}

	if ctrl() && rl.IsKeyPressed(.R) {
		if ft.selected < len(ft.nodes) {
			clear(&ft.input_buf)
			name := ft.nodes[ft.selected].name
			for i in 0..<len(name) { append(&ft.input_buf, name[i]) }
			ft.mode       = .Rename
			ft.status_msg = ""
		}
		return
	}

	if ctrl() && rl.IsKeyPressed(.D) {
		if ft.selected < len(ft.nodes) {
			ft.mode       = .Confirm_Delete
			ft.status_msg = ""
		}
		return
	}

	if ctrl() && rl.IsKeyPressed(.N) {
		clear(&ft.input_buf)
		ft.mode       = .Make_Dir
		ft.status_msg = ""
		return
	}
}

file_tree_text_input :: proc(ft: ^File_Tree, e: ^Editor, mode: File_Tree_Mode) {
	if rl.IsKeyPressed(.ESCAPE) { ft.mode = .Browse; return }
	if key_rep(.BACKSPACE) && len(ft.input_buf) > 0 { pop(&ft.input_buf) }

	if rl.IsKeyPressed(.ENTER) {
		name := string(ft.input_buf[:])
		if len(name) == 0 { ft.mode = .Browse; return }

		switch mode {
		case .Rename:
			if ft.selected < len(ft.nodes) {
				nd    := &ft.nodes[ft.selected]
				dir   := filepath.dir(nd.path)
				newp, _ := filepath.join({dir, name}, context.temp_allocator)
				err   := os.rename(nd.path, newp)
				if err == nil {
					delete(nd.name); nd.name = strings.clone(name)
					delete(nd.path); nd.path = strings.clone(newp)
					ft.status_msg = "Renamed"
				} else {
					ft.status_msg = "Rename failed"
				}
			}
		case .Make_Dir:
			parent := "."
			if ft.selected < len(ft.nodes) {
				nd := &ft.nodes[ft.selected]
				parent = nd.path if nd.is_dir else filepath.dir(nd.path)
			}
			newp, _ := filepath.join({parent, name}, context.temp_allocator)
			err  := os.make_directory(newp)
			if err == nil {
				ft.status_msg = "Directory created"
				file_tree_open(ft)
				return
			} else {
				ft.status_msg = "Failed to create directory"
			}
		case .Browse, .Confirm_Delete:
		}
		ft.mode = .Browse
		return
	}

	for {
		ch := rl.GetCharPressed()
		if ch == 0 { break }
		if ch >= 32 && ch < 128 { append(&ft.input_buf, u8(ch)) }
	}
}

file_tree_delete_input :: proc(ft: ^File_Tree, e: ^Editor) {
	if rl.IsKeyPressed(.ESCAPE) || rl.IsKeyPressed(.N) { ft.mode = .Browse; return }
	if rl.IsKeyPressed(.Y) {
		if ft.selected < len(ft.nodes) {
			nd  := &ft.nodes[ft.selected]
			err : os.Error
			if nd.is_dir { err = os.remove_all(nd.path) } else { err = os.remove(nd.path) }
			if err == nil {
				delete(nd.name); delete(nd.path)
				ordered_remove(&ft.nodes, ft.selected)
				if ft.selected >= len(ft.nodes) && ft.selected > 0 { ft.selected -= 1 }
				ft.status_msg = "Deleted"
			} else {
				ft.status_msg = "Delete failed"
			}
		}
		ft.mode = .Browse
	}
}

// ---- Rendering ----

render_file_tree :: proc(ft: ^File_Tree, font: rl.Font) {
	if !ft.open { return }

	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())

	ref := rl.MeasureTextEx(font, "M", FONT_SIZE, CHAR_SPACING)
	cw  := ref.x
	ch  := ref.y + LINE_SPACING

	PANEL_W  :: f32(360)
	HEADER_H :: f32(36)
	ITEM_H   :: f32(24)
	FOOTER_H :: f32(30)

	OVERLAY  :: rl.Color{0, 0, 0, 150}
	PANEL_BG := BG
	PANEL_BOR:= DIVIDER_COL
	SEL_BG_C := SEL_BG
	ACCENT   := ACCENT_COL
	SUBDUED  := LINENUM
	DIR_COL  := DIAG_HINT_COL
	INPUT_BG := STATUS_BG
	WARN_COL := MSG_COL

	vis_count := min(len(ft.nodes), FILE_TREE_MAX_VIS)
	panel_h   := HEADER_H + f32(vis_count)*ITEM_H + FOOTER_H

	panel_x := (sw - PANEL_W) * 0.5  // centered
	panel_y := sh * 0.05

	rl.DrawRectangle(0, 0, i32(sw), i32(sh), OVERLAY)
	dlg_begin(panel_x, panel_y, PANEL_W, panel_h, PANEL_BG, PANEL_BOR)

	// Header
	rl.DrawRectangleV({panel_x, panel_y}, {PANEL_W, HEADER_H}, INPUT_BG)
	rl.DrawLineV({panel_x, panel_y + HEADER_H - 1}, {panel_x + PANEL_W, panel_y + HEADER_H - 1}, PANEL_BOR)

	title: string
	switch ft.mode {
	case .Browse:         title = "File Tree"
	case .Rename:         title = fmt.tprintf("Rename: %s", string(ft.input_buf[:]))
	case .Make_Dir:       title = fmt.tprintf("New Dir: %s", string(ft.input_buf[:]))
	case .Confirm_Delete:
		if ft.selected < len(ft.nodes) {
			title = fmt.tprintf("Delete %s? [Y/N]", ft.nodes[ft.selected].name)
		} else { title = "Delete? [Y/N]" }
	}
	dlg_text(font, title, panel_x + 10, panel_y + 9, FONT_SIZE, CHAR_SPACING, ACCENT, panel_x + PANEL_W, 10)

	if ft.mode == .Rename || ft.mode == .Make_Dir {
		tx := panel_x + 10 + rl.MeasureTextEx(font, to_cstring(title), FONT_SIZE, CHAR_SPACING).x
		rl.DrawRectangleV({tx, panel_y + 9}, {2, ref.y}, ACCENT)
	}

	// Clamp scroll
	max_scroll := max(0, len(ft.nodes) - FILE_TREE_MAX_VIS)
	if ft.scroll > max_scroll { ft.scroll = max_scroll }

	// Nodes
	for vi in 0..<vis_count {
		ni := ft.scroll + vi
		if ni >= len(ft.nodes) { break }
		nd := &ft.nodes[ni]
		iy := panel_y + HEADER_H + f32(vi) * ITEM_H

		if ni == ft.selected {
			rl.DrawRectangleV({panel_x, iy}, {PANEL_W, ITEM_H}, SEL_BG_C)
			rl.DrawRectangleV({panel_x, iy}, {3, ITEM_H}, ACCENT)
		}

		ix     := panel_x + 10 + f32(nd.depth) * 16
		icon_h := f32(12)
		iy_mid := iy + (ITEM_H - icon_h) * 0.5
		_ = ch
		if nd.is_dir {
			// Folder icon: tab nub + body
			fc := DIR_COL if nd.expanded else rl.Color{148, 226, 213, 255}
			rl.DrawRectangleV({ix,     iy_mid + 3}, {icon_h,     icon_h - 3}, fc)
			rl.DrawRectangleV({ix,     iy_mid},     {5,          3},           fc)
			// +/- expand indicator
			arr := "-" if nd.expanded else "+"
			rl.DrawTextEx(font, to_cstring(arr), {ix + icon_h + 2, iy + 3}, FONT_SIZE - 4, CHAR_SPACING, SUBDUED)
			dlg_text(font, nd.name, ix + icon_h + 12, iy + 3, FONT_SIZE - 2, CHAR_SPACING, DIR_COL, panel_x + PANEL_W, 6)
		} else {
			// File icon: rect with folded top-right corner
			rl.DrawRectangleV({ix,            iy_mid},          {icon_h - 3, icon_h},     LINENUM)
			rl.DrawRectangleV({ix + icon_h - 3, iy_mid + 3},   {3,          icon_h - 3}, LINENUM)
			dlg_text(font, nd.name, ix + icon_h + 5, iy + 3, FONT_SIZE - 2, CHAR_SPACING, TEXT, panel_x + PANEL_W, 6)
		}
	}

	// Footer
	fy := panel_y + HEADER_H + f32(vis_count) * ITEM_H
	rl.DrawRectangleV({panel_x, fy}, {PANEL_W, FOOTER_H}, INPUT_BG)
	rl.DrawRectangleLinesEx({panel_x, fy, PANEL_W, FOOTER_H}, 1, PANEL_BOR)

	footer: string
	col := SUBDUED
	switch ft.mode {
	case .Browse:
		footer = ft.status_msg if ft.status_msg != "" else "Enter open  ←→ expand  Ctrl+R rename  Ctrl+D del  Ctrl+N dir  Esc"
	case .Rename:   footer = "Type new name · Enter confirm · Esc cancel"
	case .Make_Dir: footer = "Type directory name · Enter confirm · Esc cancel"
	case .Confirm_Delete:
		footer = ft.status_msg if ft.status_msg != "" else "Press Y to confirm delete, N or Esc to cancel"
		col = WARN_COL
	}
	_ = ch
	rl.DrawTextEx(font, to_cstring(footer), {panel_x + 10, fy + 7}, FONT_SIZE - 3, CHAR_SPACING, col)
	dlg_end()
}
