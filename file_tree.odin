package editor

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import git "./git"
import rl "vendor:raylib"

File_Tree_Mode :: enum { Browse, Rename, Confirm_Delete, Make_Dir, Make_File }

File_Tree_Node :: struct {
	name:     string, // display name (heap) — may be a compacted chain like "java/com/example/demo"
	path:     string, // full relative path to the real dir/file this row represents (heap)
	is_dir:   bool,
	depth:    int,
	expanded: bool,
	ghost:    bool, // deleted in git: not on disk, injected from the status (#11)
}

File_Tree :: struct {
	open:       bool,
	nodes:      [dynamic]File_Tree_Node,
	selected:   int,
	scroll:     int,
	mode:       File_Tree_Mode,
	input_buf:  [dynamic]u8,
	input_sel_all: bool,
	status_msg: string,

	filter:  [dynamic]u8,          // recursive fuzzy-filter text
	filter_sel_all: bool,
	results: [dynamic]File_Tree_Node, // flat recursive matches; populated when len(filter) > 0

	search_active:  bool,
	search_needle:  string,          // heap
	search_snap:    ^Ws_Snapshot,    // workspace index being filtered (retained)
	search_pos:     int,             // next file of search_snap to test
	search_dirs:    map[string]bool, // folders already listed (keys slice search_snap)
	search_ignored: bool,            // [editor] search_ignored_files, set by the input handler

	// Git badges (#11). Index rebuilt from e.git_mgr.current by file_tree_git_sync.
	git_idx:       Tree_Git_Index,
	git_hash:      u64,  // content hash of the indexed status
	git_has_index: bool, // false → rebuild on next sync (e.g. tree reopened)
	git_stale:     bool, // status changed while rows could not be rebuilt
	git_mgr:       ^git.Git_Manager, // manager/generation last indexed
	git_gen:       int,
	changed_only:  bool, // "only changed" filter: rows built from the status, all folders expanded
	collapsed:     map[string]bool, // folders collapsed by hand in changed_only (keys heap)
}

// ---- Icons ----
// Small rounded glyphs instead of hard-edged rects — reads less like a
// terminal file listing.

_ft_draw_folder_icon :: proc(x, y_mid, size: f32, color: rl.Color) {
	body_h := size - 3
	rl.DrawRectangleRounded({x, y_mid + 3, size, body_h}, 0.28, 4, color)
	rl.DrawRectangleRounded({x, y_mid, size * 0.5, 4}, 0.5, 4, color)
}

_ft_draw_file_icon :: proc(x, y_mid, size: f32, color: rl.Color) {
	w := size - 3
	rl.DrawRectangleRounded({x, y_mid, w, size}, 0.22, 4, color)
	// Folded top-right corner — small triangle notch in the panel bg tone.
	rl.DrawTriangle({x + w - 4, y_mid}, {x + w, y_mid}, {x + w, y_mid + 4}, BG)
}

file_tree_init :: proc() -> File_Tree {
	ft: File_Tree
	ft.nodes     = make([dynamic]File_Tree_Node)
	ft.input_buf = make([dynamic]u8)
	ft.filter    = make([dynamic]u8)
	ft.results   = make([dynamic]File_Tree_Node)
	return ft
}

file_tree_destroy :: proc(ft: ^File_Tree) {
	for n in ft.nodes { delete(n.name); delete(n.path) }
	delete(ft.nodes)
	delete(ft.input_buf)
	delete(ft.filter)
	for r in ft.results { delete(r.name); delete(r.path) }
	delete(ft.results)
	_ft_search_stop(ft)
	delete(ft.search_dirs)
	delete(ft.search_needle)
	tree_git_index_destroy(&ft.git_idx)
	_ft_clear_collapsed(ft)
	delete(ft.collapsed)
	ft^ = {}
}

file_tree_open :: proc(ft: ^File_Tree) {
	ft.open           = true
	ft.selected       = 0
	ft.scroll         = 0
	ft.mode           = .Browse
	ft.status_msg     = ""
	ft.filter_sel_all = false
	ft.input_sel_all  = false
	clear(&ft.filter)
	for r in ft.results { delete(r.name); delete(r.path) }
	clear(&ft.results)
	_ft_search_stop(ft)
	ft.search_active = false
	delete(ft.search_needle)
	ft.search_needle = ""
	ft.git_has_index = false // re-index next frame (cwd may have changed)
	_ft_reload_rows(ft)
}

_ft_clear_nodes :: proc(ft: ^File_Tree) {
	for n in ft.nodes { delete(n.name); delete(n.path) }
	clear(&ft.nodes)
}

_ft_clear_collapsed :: proc(ft: ^File_Tree) {
	for k in ft.collapsed { delete(k) }
	clear(&ft.collapsed)
}

// Rebuilds ft.nodes from scratch: the disk tree, or the changed-only view.
_ft_reload_rows :: proc(ft: ^File_Tree) {
	_ft_clear_nodes(ft)
	if ft.changed_only {
		_ft_build_changed(ft)
	} else {
		_ft_load_children(ft, ".", 0, 0)
	}
}

file_tree_close :: proc(ft: ^File_Tree) {
	ft.open       = false
	ft.mode       = .Browse
	ft.status_msg = ""
}

FT_MAX_CHILDREN :: 500  // max entries per directory expansion

// True when `name` should be hidden from both the tree and the recursive search.
_ft_is_skipped :: proc(name: string) -> bool {
	return ws_is_skipped_dir(name)
}

// If `path` contains exactly one visible entry and that entry is itself a
// directory, return its name. Used to collapse single-child folder chains
// into one display row (e.g. "src/main/java/com/example/demo").
_ft_single_subdir :: proc(path: string) -> (child_name: string, ok: bool) {
	entries := make([dynamic]Dir_Entry, context.temp_allocator)
	if !fast_list_dir(path, &entries, context.temp_allocator) { return "", false }
	count: int
	name: string
	only_dir := true
	for en in entries {
		if _ft_is_skipped(en.name) { continue }
		count += 1
		if count > 1 { return "", false }
		if !en.is_dir { only_dir = false }
		name = en.name
	}
	if count == 1 && only_dir { return name, true }
	return "", false
}

_ft_load_children :: proc(ft: ^File_Tree, dir_path: string, depth: int, insert_idx: int) -> int {
	dirs  := make([dynamic]File_Tree_Node, context.temp_allocator)
	files := make([dynamic]File_Tree_Node, context.temp_allocator)

	// A folder that only holds deleted files does not exist on disk any more
	// (the listing then fails and only the git ghosts below are shown).
	listing := make([dynamic]Dir_Entry, context.temp_allocator)
	_ = fast_list_dir(dir_path, &listing, context.temp_allocator)

	for en in listing {
		name   := en.name
		is_dir := en.is_dir
		if _ft_is_skipped(name) { continue }

		full, _ := filepath.join({dir_path, name}, context.temp_allocator)

		if is_dir {
			// Collapse a chain of single-child directories into one row.
			disp_name := name
			real_path := full
			for {
				// A folder with deleted files has hidden children: keep it its own row.
				if del_f, del_d := tree_git_deleted_children(&ft.git_idx, real_path); len(del_f) + len(del_d) > 0 { break }
				child, chain_ok := _ft_single_subdir(real_path)
				if !chain_ok { break }
				disp_name = strings.concatenate({disp_name, "/", child}, context.temp_allocator)
				real_path, _ = filepath.join({real_path, child}, context.temp_allocator)
			}
			node := File_Tree_Node{
				name   = strings.clone(disp_name),
				path   = strings.clone(real_path),
				is_dir = true,
				depth  = depth,
			}
			append(&dirs, node)
		} else {
			node := File_Tree_Node{
				name   = strings.clone(name),
				path   = strings.clone(full),
				is_dir = false,
				depth  = depth,
			}
			append(&files, node)
		}
		if len(dirs) + len(files) >= FT_MAX_CHILDREN { ft.status_msg = "Showing first 500 entries"; break }
	}

	// Deleted files are gone from disk: inject them (and folders that only
	// hold deleted files) from the git status.
	_ft_inject_deleted(ft, dir_path, depth, &dirs, &files)

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
	if ft.changed_only && !_ft_in_untracked_dir(ft, n.path) { _ft_toggle_changed_dir(ft, idx); return }

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

// ---- Recursive fuzzy filter ----
//
// Matches file and folder names over the workspace index (ws_index.odin,
// built on a worker thread). The UI thread only compares strings, under a
// time budget per frame, so even a monorepo-sized list never blocks a frame.

FT_SEARCH_MAX_RESULTS :: 300
FT_SEARCH_BUDGET      :: 4 * time.Millisecond

_ft_search_step :: proc(ft: ^File_Tree) {
	if !ft.search_active { return }
	if ft.search_snap == nil {
		ws_index_refresh(ft.search_ignored)
		ft.search_snap, _ = ws_index_get()
		if ft.search_snap == nil { return } // first index still building
	}
	files := ft.search_snap.files
	t0 := time.tick_now()
	for ft.search_pos < len(files) {
		if len(ft.results) >= FT_SEARCH_MAX_RESULTS { break }
		if ft.search_pos & 1023 == 0 && time.tick_since(t0) > FT_SEARCH_BUDGET { return }
		f := files[ft.search_pos]
		ft.search_pos += 1
		_ft_match_index_path(ft, f)
	}
	_ft_search_finish(ft)
}

// Adds `path` (a file of the index) and the folders on its way whose name
// contains the needle. Each folder is listed once.
@(private="file")
_ft_match_index_path :: proc(ft: ^File_Tree, path: string) {
	start := 0
	for i in 0 ..< len(path) {
		if path[i] != '/' { continue }
		dir := path[:i]
		if pal_match(path[start:i], ft.search_needle) && !(dir in ft.search_dirs) {
			ft.search_dirs[dir] = true
			append(&ft.results, File_Tree_Node{name = strings.clone(path[start:i]), path = strings.clone(dir), is_dir = true})
		}
		start = i + 1
	}
	name := path[start:]
	if !pal_match(name, ft.search_needle) { return }
	append(&ft.results, File_Tree_Node{name = strings.clone(name), path = strings.clone(path)})
}

// Ends the filter pass and lets go of the index snapshot.
_ft_search_stop :: proc(ft: ^File_Tree) {
	ws_snapshot_release(ft.search_snap)
	ft.search_snap = nil
	ft.search_pos  = 0
	clear(&ft.search_dirs)
}

@(private="file")
_ft_search_finish :: proc(ft: ^File_Tree) {
	ft.search_active = false
	_ft_search_stop(ft)
	_ft_sort_results(ft)
}

_ft_sort_results :: proc(ft: ^File_Tree) {
	slice.sort_by(ft.results[:], proc(a, b: File_Tree_Node) -> bool { return a.path < b.path })
}

_ft_rebuild_search :: proc(ft: ^File_Tree) {
	for r in ft.results { delete(r.name); delete(r.path) }
	clear(&ft.results)
	ft.selected = 0
	ft.scroll   = 0
	_ft_search_stop(ft)
	ft.search_active = false
	delete(ft.search_needle)
	ft.search_needle = ""
	if len(ft.filter) == 0 { return }

	ft.search_needle = strings.clone(string(ft.filter[:]))
	ft.search_active = true
}

// ---- Input ----

FILE_TREE_MAX_VIS :: 24

file_tree_handle_input :: proc(ft: ^File_Tree, e: ^Editor) {
	ft.search_ignored = e.cfg.editor.search_ignored_files
	switch ft.mode {
	case .Browse:          file_tree_browse_input(ft, e)
	case .Rename:          file_tree_text_input(ft, e, .Rename)
	case .Make_Dir:        file_tree_text_input(ft, e, .Make_Dir)
	case .Make_File:       file_tree_text_input(ft, e, .Make_File)
	case .Confirm_Delete:  file_tree_delete_input(ft, e)
	}
}

file_tree_browse_input :: proc(ft: ^File_Tree, e: ^Editor) {
	if rl.IsKeyPressed(.ESCAPE) {
		if len(ft.filter) > 0 {
			clear(&ft.filter)
			_ft_rebuild_search(ft)
			return
		}
		file_tree_close(ft)
		return
	}

	searching := len(ft.filter) > 0
	n := len(ft.results) if searching else len(ft.nodes)

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

	if searching {
		if rl.IsKeyPressed(.ENTER) {
			if ft.selected < len(ft.results) {
				r := ft.results[ft.selected]
				if !r.is_dir { _ft_open_node(ft, e, r) }
			}
			return
		}
	} else {
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
				nd := ft.nodes[ft.selected]
				if nd.is_dir {
					_ft_toggle_dir(ft, ft.selected)
				} else {
					_ft_open_node(ft, e, nd)
				}
			}
			return
		}

		// Ctrl+G: "only changed" filter — changed files with folders expanded.
		if ctrl() && rl.IsKeyPressed(.G) {
			file_tree_toggle_changed_only(ft)
			ft.status_msg = "Only changed files" if ft.changed_only else ""
			return
		}

		// Ctrl+H: history of the selected file (ticket #10).
		if ctrl() && rl.IsKeyPressed(.H) {
			if ft.selected < len(ft.nodes) && !ft.nodes[ft.selected].is_dir {
				// Node paths are cwd-relative; the history panel wants an absolute path
				path := ft.nodes[ft.selected].path
				if !filepath.is_abs(path) {
					if cwd, err := os.get_working_directory(context.temp_allocator); err == nil {
						path, _ = filepath.join({cwd, path}, context.temp_allocator)
					}
				}
				file_tree_close(ft)
				file_history_open(e, path)
			}
			return
		}

		// Deleted (ghost) rows are not on disk: nothing to rename or delete.
		if ctrl() && (rl.IsKeyPressed(.R) || rl.IsKeyPressed(.D)) && ft.selected < len(ft.nodes) && ft.nodes[ft.selected].ghost {
			ft.status_msg = "Deleted in git — not on disk"
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

		// Ctrl+N new file, Ctrl+Shift+N new folder (in the selected folder,
		// or next to the selected file)
		if ctrl() && rl.IsKeyPressed(.N) {
			clear(&ft.input_buf)
			ft.mode       = .Make_Dir if shift() else .Make_File
			ft.status_msg = ""
			return
		}
	}

	// Recursive filter typing (active in both browse and search views)
	if text_input_handle(&ft.filter, &ft.filter_sel_all) { _ft_rebuild_search(ft) }
}

file_tree_text_input :: proc(ft: ^File_Tree, e: ^Editor, mode: File_Tree_Mode) {
	if rl.IsKeyPressed(.ESCAPE) { ft.mode = .Browse; return }
	text_input_handle(&ft.input_buf, &ft.input_sel_all)

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
				ws_index_invalidate()
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
		case .Make_File:
			parent := "."
			if ft.selected < len(ft.nodes) {
				nd := &ft.nodes[ft.selected]
				parent = nd.path if nd.is_dir else filepath.dir(nd.path)
			}
			newp, _ := filepath.join({parent, name}, context.temp_allocator)
			if new_path_is_dir(name) { newp = strings.concatenate({newp, "/"}, context.temp_allocator) }
			switch create_new_path(newp) {
			case .Created_File, .Exists:
				file_tree_close(ft)
				editor_open(e, newp)
				return
			case .Created_Dir:
				ft.status_msg = "Directory created"
				file_tree_open(ft)
				return
			case .Invalid: ft.status_msg = "Not a valid new file name"
			case .Failed:  ft.status_msg = "Failed to create file"
			}
		case .Browse, .Confirm_Delete:
		}
		ft.mode = .Browse
		return
	}
}

file_tree_delete_input :: proc(ft: ^File_Tree, e: ^Editor) {
	if rl.IsKeyPressed(.ESCAPE) || rl.IsKeyPressed(.N) { ft.mode = .Browse; return }
	if rl.IsKeyPressed(.Y) {
		if ft.selected < len(ft.nodes) {
			nd  := &ft.nodes[ft.selected]
			err : os.Error
			if nd.is_dir { err = os.remove_all(nd.path) } else { err = os.remove(nd.path) }
			ws_index_invalidate()
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

	_ft_search_step(ft)

	sw := f32(screen_w())
	sh := f32(screen_h())

	ref := rl.MeasureTextEx(font, "M", FONT_SIZE, CHAR_SPACING)
	cw  := ref.x
	ch  := ref.y + LINE_SPACING

	// Half the window, so long paths and the footer fit (was a fixed 360)
	PANEL_W  := clamp(sw * 0.5, min(f32(440), sw - 40), f32(860))
	HEADER_H :: f32(36)
	INPUT_H  :: f32(30)
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

	searching    := len(ft.filter) > 0
	has_filt_row := ft.mode == .Browse
	total        := len(ft.results) if searching else len(ft.nodes)
	vis_count    := min(total, FILE_TREE_MAX_VIS)
	filt_h       := INPUT_H if has_filt_row else f32(0)
	panel_h      := HEADER_H + filt_h + f32(max(vis_count, (1 if searching && vis_count == 0 else 0)))*ITEM_H + FOOTER_H

	panel_x := (sw - PANEL_W) * 0.5  // centered
	panel_y := sh * 0.05

	rl.DrawRectangle(0, 0, i32(sw), i32(sh), OVERLAY)
	panel_x, panel_y = dlg_begin(panel_x, panel_y, PANEL_W, panel_h, PANEL_BG, PANEL_BOR)

	// Header
	rl.DrawRectangleV({panel_x, panel_y}, {PANEL_W, HEADER_H}, INPUT_BG)
	rl.DrawLineV({panel_x, panel_y + HEADER_H - 1}, {panel_x + PANEL_W, panel_y + HEADER_H - 1}, PANEL_BOR)

	title: string
	switch ft.mode {
	case .Browse:         title = "File Tree — only changed" if ft.changed_only else "File Tree"
	case .Rename:         title = fmt.tprintf("Rename: %s", string(ft.input_buf[:]))
	case .Make_Dir:       title = fmt.tprintf("New Dir: %s", string(ft.input_buf[:]))
	case .Make_File:      title = fmt.tprintf("New File: %s", string(ft.input_buf[:]))
	case .Confirm_Delete:
		if ft.selected < len(ft.nodes) {
			title = fmt.tprintf("Delete %s? [Y/N]", ft.nodes[ft.selected].name)
		} else { title = "Delete? [Y/N]" }
	}
	dlg_text(font, title, panel_x + 10, panel_y + 9, FONT_SIZE, CHAR_SPACING, ACCENT, panel_x + PANEL_W, 10)

	if ft.mode == .Rename || ft.mode == .Make_Dir || ft.mode == .Make_File {
		tx := panel_x + 10 + rl.MeasureTextEx(font, to_cstring(title), FONT_SIZE, CHAR_SPACING).x
		rl.DrawRectangleV({tx, panel_y + 9}, {2, ref.y}, ACCENT)
	}

	// Filter input row (recursive fuzzy filter)
	list_y := panel_y + HEADER_H
	if has_filt_row {
		iy := list_y
		rl.DrawRectangleV({panel_x, iy}, {PANEL_W, INPUT_H}, INPUT_BG)
		rl.DrawLineV({panel_x, iy + INPUT_H - 1}, {panel_x + PANEL_W, iy + INPUT_H - 1}, PANEL_BOR)
		filter_str  := string(ft.filter[:])
		placeholder := len(filter_str) == 0
		display     := filter_str if !placeholder else "type to filter (recursive)..."
		dcol        := TEXT if !placeholder else SUBDUED
		if !placeholder && ft.filter_sel_all {
			fw := rl.MeasureTextEx(font, to_cstring(filter_str), FONT_SIZE - 2, CHAR_SPACING).x
			rl.DrawRectangleV({panel_x + 8, iy + 4}, {fw + 4, ref.y + 4}, rl.Color{ACCENT_COL.r, ACCENT_COL.g, ACCENT_COL.b, 60})
			rl.DrawRectangleLinesEx({panel_x + 8, iy + 4, fw + 4, ref.y + 4}, 1, rl.Color{ACCENT_COL.r, ACCENT_COL.g, ACCENT_COL.b, 180})
		}
		draw_text(font, to_cstring(display), {panel_x + 10, iy + 6}, FONT_SIZE - 2, CHAR_SPACING, dcol)
		if !placeholder && !ft.filter_sel_all {
			fw := rl.MeasureTextEx(font, to_cstring(filter_str), FONT_SIZE - 2, CHAR_SPACING).x
			rl.DrawRectangleV({panel_x + 10 + fw, iy + 6}, {2, ref.y}, ACCENT)
		}
		list_y += INPUT_H
	}

	// Clamp scroll
	max_scroll := max(0, total - FILE_TREE_MAX_VIS)
	if ft.scroll > max_scroll { ft.scroll = max_scroll }

	if searching {
		if total == 0 {
			msg := "  searching..." if ft.search_active else "  no matches"
			draw_text(font, to_cstring(msg), {panel_x + 10, list_y + 4}, FONT_SIZE, CHAR_SPACING, SUBDUED)
		}
		for vi in 0..<vis_count {
			ri := ft.scroll + vi
			if ri >= len(ft.results) { break }
			r  := &ft.results[ri]
			iy := list_y + f32(vi) * ITEM_H

			if ri == ft.selected {
				rl.DrawRectangleV({panel_x, iy}, {PANEL_W, ITEM_H}, SEL_BG_C)
				rl.DrawRectangleV({panel_x, iy}, {3, ITEM_H}, ACCENT)
			}

			ix     := panel_x + 10
			icon_h := f32(12)
			iy_mid := iy + (ITEM_H - icon_h) * 0.5
			badge_w := f32(26)
			if r.is_dir {
				gk := tree_git_dir_kind(&ft.git_idx, r.path)
				_ft_draw_folder_icon(ix, iy_mid, icon_h, rl.Color{148, 226, 213, 255})
				dlg_text(font, r.path, ix + icon_h + 8, iy + 3, FONT_SIZE - 2, CHAR_SPACING, DIR_COL, panel_x + PANEL_W - badge_w, 6)
				_ft_draw_git_badge(font, gk, true, panel_x + PANEL_W, iy, ITEM_H)
			} else {
				gk := tree_git_file_kind(&ft.git_idx, r.path)
				tc := TEXT if gk == .None else tree_git_color(gk)
				_ft_draw_file_icon(ix, iy_mid, icon_h, LINENUM)
				dlg_text(font, r.path, ix + icon_h + 5, iy + 3, FONT_SIZE - 2, CHAR_SPACING, tc, panel_x + PANEL_W - badge_w, 6)
				_ft_draw_git_badge(font, gk, false, panel_x + PANEL_W, iy, ITEM_H)
			}
		}
	} else {
		for vi in 0..<vis_count {
			ni := ft.scroll + vi
			if ni >= len(ft.nodes) { break }
			nd := &ft.nodes[ni]
			iy := list_y + f32(vi) * ITEM_H

			if ni == ft.selected {
				rl.DrawRectangleV({panel_x, iy}, {PANEL_W, ITEM_H}, SEL_BG_C)
				rl.DrawRectangleV({panel_x, iy}, {3, ITEM_H}, ACCENT)
			}

			ix     := panel_x + 10 + f32(nd.depth) * 16
			icon_h := f32(12)
			iy_mid := iy + (ITEM_H - icon_h) * 0.5
			_ = ch
			badge_w := f32(26)
			if nd.is_dir {
				gk := tree_git_dir_kind(&ft.git_idx, nd.path)
				fc := DIR_COL if nd.expanded else rl.Color{148, 226, 213, 255}
				_ft_draw_folder_icon(ix, iy_mid, icon_h, fc)
				// +/- expand indicator
				arr := "-" if nd.expanded else "+"
				draw_text(font, to_cstring(arr), {ix + icon_h + 2, iy + 3}, FONT_SIZE - 4, CHAR_SPACING, SUBDUED)
				dlg_text(font, nd.name, ix + icon_h + 12, iy + 3, FONT_SIZE - 2, CHAR_SPACING, DIR_COL, panel_x + PANEL_W - badge_w, 6)
				// Folder with changes below: dot in the most important change's color.
				_ft_draw_git_badge(font, gk, true, panel_x + PANEL_W, iy, ITEM_H)
			} else {
				gk := tree_git_file_kind(&ft.git_idx, nd.path)
				if nd.ghost { gk = .Deleted }
				tc := TEXT if gk == .None else tree_git_color(gk)
				_ft_draw_file_icon(ix, iy_mid, icon_h, LINENUM)
				dlg_text(font, nd.name, ix + icon_h + 5, iy + 3, FONT_SIZE - 2, CHAR_SPACING, tc, panel_x + PANEL_W - badge_w, 6)
				if gk == .Deleted { _ft_draw_strike(font, nd.name, ix + icon_h + 5, iy, ITEM_H, tc) }
				_ft_draw_git_badge(font, gk, false, panel_x + PANEL_W, iy, ITEM_H)
			}
		}
	}

	// Footer
	fy := list_y + f32(vis_count) * ITEM_H
	if searching && vis_count == 0 { fy += ITEM_H }
	rl.DrawRectangleV({panel_x, fy}, {PANEL_W, FOOTER_H}, INPUT_BG)
	rl.DrawRectangleLinesEx({panel_x, fy, PANEL_W, FOOTER_H}, 1, PANEL_BOR)

	footer: string
	col := SUBDUED
	switch ft.mode {
	case .Browse:
		if ft.status_msg != "" {
			footer = ft.status_msg
		} else if searching {
			footer = fmt.tprintf("Searching... %d found", total) if ft.search_active else "↑↓ navigate  Enter open  Esc clear filter"
		} else {
			footer = "Enter open  ←→ expand  Ctrl+G changed  Ctrl+H history  Ctrl+R ren  Ctrl+D del  Ctrl+N file  Ctrl+Shift+N dir"
		}
	case .Rename:   footer = "Type new name · Enter confirm · Esc cancel"
	case .Make_Dir: footer = "Type directory name · Enter confirm · Esc cancel"
	case .Make_File: footer = "Type file name (end with / for a folder) · Enter confirm · Esc cancel"
	case .Confirm_Delete:
		footer = ft.status_msg if ft.status_msg != "" else "Press Y to confirm delete, N or Esc to cancel"
		col = WARN_COL
	}
	_ = ch
	dlg_text(font, footer, panel_x + 10, fy + 7, FONT_SIZE - 3, CHAR_SPACING, col, panel_x + PANEL_W, 10)
	dlg_end()
}

// ===========================================================================
// Git badges, deleted files and "only changed" filter (#11)
// ===========================================================================

// Appends deleted children of `dir_path` that are not already listed.
_ft_inject_deleted :: proc(ft: ^File_Tree, dir_path: string, depth: int, dirs, files: ^[dynamic]File_Tree_Node) {
	del_files, del_dirs := tree_git_deleted_children(&ft.git_idx, dir_path)
	if len(del_files) + len(del_dirs) == 0 { return }
	base := tree_git_key(dir_path)
	_join :: proc(base, name: string) -> string {
		return name if base == "." else strings.concatenate({base, "/", name}, context.temp_allocator)
	}
	outer_d: for name in del_dirs {
		p := _join(base, name)
		for d in dirs { if tree_git_key(d.path) == p { continue outer_d } }
		append(dirs, File_Tree_Node{name = strings.clone(name), path = strings.clone(p), is_dir = true, depth = depth, ghost = true})
	}
	outer_f: for name in del_files {
		p := _join(base, name)
		for f in files { if tree_git_key(f.path) == p { continue outer_f } }
		append(files, File_Tree_Node{name = strings.clone(name), path = strings.clone(p), depth = depth, ghost = true})
	}
}

// Rows of the "only changed" view: every changed path (deleted included),
// folders expanded unless in `collapsed`. Dirs first, then files, each
// sorted by name — same order as the disk tree. An untracked folder ("?? d/")
// is a folder row whose content is read from disk on demand. Strings are
// allocated with `allocator`.
tree_git_changed_rows :: proc(paths: []string, untracked_dirs: []string, collapsed: map[string]bool, allocator := context.allocator) -> [dynamic]File_Tree_Node {
	rows := make([dynamic]File_Tree_Node, allocator)
	sorted := slice.clone(paths, context.temp_allocator)
	slice.sort(sorted)
	_emit :: proc(rows: ^[dynamic]File_Tree_Node, items: []string, prefix: string, depth: int,
	              udirs: []string, collapsed: map[string]bool, allocator: runtime.Allocator) {
		// items: paths relative to `prefix`, sorted; same first component → contiguous
		Group :: struct { name: string, sub: []string }
		dirs  := make([dynamic]Group, context.temp_allocator)
		files := make([dynamic]string, context.temp_allocator)
		i := 0
		for i < len(items) {
			it := items[i]
			slash := strings.index_byte(it, '/')
			if slash < 0 {
				full := it if prefix == "" else strings.concatenate({prefix, "/", it}, context.temp_allocator)
				if slice.contains(udirs, full) {
					append(&dirs, Group{name = it})
				} else {
					append(&files, it)
				}
				i += 1
				continue
			}
			comp := it[:slash]
			j := i
			sub := make([dynamic]string, context.temp_allocator)
			for j < len(items) && strings.has_prefix(items[j], comp) && len(items[j]) > len(comp) && items[j][len(comp)] == '/' {
				append(&sub, items[j][len(comp)+1:])
				j += 1
			}
			// merge with a same-named untracked/earlier group
			merged := false
			for &g in dirs {
				if g.name == comp {
					both := make([dynamic]string, context.temp_allocator)
					append(&both, ..g.sub); append(&both, ..sub[:])
					slice.sort(both[:])
					g.sub = both[:]; merged = true; break
				}
			}
			if !merged { append(&dirs, Group{name = comp, sub = sub[:]}) }
			i = j
		}
		slice.sort_by(dirs[:], proc(a, b: Group) -> bool { return a.name < b.name })
		slice.sort(files[:])
		for g in dirs {
			full := g.name if prefix == "" else strings.concatenate({prefix, "/", g.name}, context.temp_allocator)
			is_udir := slice.contains(udirs, full)
			open := len(g.sub) > 0 && !(full in collapsed)
			append(rows, File_Tree_Node{
				name = strings.clone(g.name, allocator), path = strings.clone(full, allocator),
				is_dir = true, depth = depth, expanded = open && !is_udir,
			})
			if open && !is_udir { _emit(rows, g.sub, full, depth + 1, udirs, collapsed, allocator) }
		}
		for name in files {
			full := name if prefix == "" else strings.concatenate({prefix, "/", name}, context.temp_allocator)
			append(rows, File_Tree_Node{name = strings.clone(name, allocator), path = strings.clone(full, allocator), depth = depth})
		}
	}
	_emit(&rows, sorted, "", 0, untracked_dirs, collapsed, allocator)
	return rows
}

_ft_build_changed :: proc(ft: ^File_Tree) {
	paths := make([dynamic]string, context.temp_allocator)
	for k in ft.git_idx.files { append(&paths, k) }
	rows := tree_git_changed_rows(paths[:], ft.git_idx.untracked_dirs[:], ft.collapsed, context.temp_allocator)
	for r in rows {
		n := r
		n.name = strings.clone(r.name)
		n.path = strings.clone(r.path)
		n.ghost = !n.is_dir && ft.git_idx.files[r.path] == .Deleted
		append(&ft.nodes, n)
	}
}

// True when `path` is (inside) an untracked folder — its rows come from disk.
_ft_in_untracked_dir :: proc(ft: ^File_Tree, path: string) -> bool {
	k := tree_git_key(path)
	for u in ft.git_idx.untracked_dirs {
		if k == u || (strings.has_prefix(k, u) && len(k) > len(u) && k[len(u)] == '/') { return true }
	}
	return false
}

// Changed-only view: collapse/expand by remembering the folder and rebuilding.
_ft_toggle_changed_dir :: proc(ft: ^File_Tree, idx: int) {
	p := ft.nodes[idx].path
	if p in ft.collapsed {
		key := p
		for k in ft.collapsed { if k == p { key = k; break } }
		delete_key(&ft.collapsed, p)
		delete(key)
	} else {
		ft.collapsed[strings.clone(p)] = true
	}
	_ft_refresh_rows_keep(ft)
}

// Toggles the "only changed" filter (rows built from the git status).
file_tree_toggle_changed_only :: proc(ft: ^File_Tree) {
	ft.changed_only = !ft.changed_only
	_ft_clear_collapsed(ft)
	ft.selected = 0
	ft.scroll   = 0
	_ft_reload_rows(ft)
}

// Rebuilds the rows (status changed) keeping expanded folders and selection.
_ft_refresh_rows_keep :: proc(ft: ^File_Tree) {
	sel_path := ""
	if ft.selected < len(ft.nodes) { sel_path = strings.clone(ft.nodes[ft.selected].path, context.temp_allocator) }
	expanded := make(map[string]bool, allocator = context.temp_allocator)
	for n in ft.nodes { if n.is_dir && n.expanded { expanded[strings.clone(n.path, context.temp_allocator)] = true } }

	_ft_reload_rows(ft)
	if !ft.changed_only {
		for i := 0; i < len(ft.nodes); i += 1 {
			n := ft.nodes[i]
			if n.is_dir && !n.expanded && n.path in expanded { _ft_toggle_dir(ft, i) }
		}
	}
	ft.selected = min(ft.selected, max(0, len(ft.nodes) - 1))
	for n, i in ft.nodes { if n.path == sel_path { ft.selected = i; break } }
	if ft.selected < ft.scroll { ft.scroll = ft.selected }
	if ft.selected >= ft.scroll + FILE_TREE_MAX_VIS { ft.scroll = ft.selected - FILE_TREE_MAX_VIS + 1 }
}

// Called every frame (tree_head_view panel's update hook). Re-indexes the
// manager's status when it changed and refreshes the visible rows, so the
// badges follow the manager's own refresh — no extra git process.
file_tree_git_sync :: proc(e: ^Editor) {
	ft := &e.file_tree
	if e.git_mgr.root == "" {
		if len(ft.git_idx.files) > 0 { tree_git_index_clear(&ft.git_idx) }
		return
	}
	// The status only changes when the manager swaps in a new one: hash it
	// then, not every frame (a monorepo can have thousands of entries)
	if !ft.git_has_index || ft.git_mgr != e.git_mgr || ft.git_gen != e.git_mgr.status_gen {
		ft.git_mgr, ft.git_gen = e.git_mgr, e.git_mgr.status_gen
		entries := e.git_mgr.current.entries[:]
		h := tree_git_status_hash(entries)
		if !ft.git_has_index || h != ft.git_hash {
			cwd, err := os.get_working_directory(context.temp_allocator)
			if err != nil { cwd = "." }
			tree_git_index_build(&ft.git_idx, entries, e.git_mgr.root, cwd)
			ft.git_hash      = h
			ft.git_has_index = true
			ft.git_stale     = true
		}
	}
	// Rebuild rows only while browsing (never under a rename/delete prompt
	// or the recursive filter, whose rows come from the disk walker).
	if ft.git_stale && ft.open && ft.mode == .Browse && len(ft.filter) == 0 {
		ft.git_stale = false
		_ft_refresh_rows_keep(ft)
	} else if !ft.open {
		ft.git_stale = false // file_tree_open loads fresh rows
	}
}

// Opens a selected file row: deleted ones show the HEAD version read-only.
_ft_open_node :: proc(ft: ^File_Tree, e: ^Editor, nd: File_Tree_Node) {
	if nd.ghost || (!os.exists(nd.path) && tree_git_file_kind(&ft.git_idx, nd.path) == .Deleted) {
		repo_path, ok := ft.git_idx.repo_rel[tree_git_key(nd.path)]
		if !ok { ft.status_msg = "Deleted file not in git status"; return }
		file_tree_close(ft)
		tree_head_view_open(e, repo_path)
		return
	}
	if nd.is_dir { return }
	editor_open(e, nd.path)
	file_tree_close(ft)
}

// Draws the change letter at the right edge of a row and returns the color
// the name should use (TEXT when clean). Deleted rows get a strike-through.
_ft_draw_git_badge :: proc(font: rl.Font, kind: Tree_Git_Kind, is_dir: bool, right, iy, item_h: f32) {
	if kind == .None { return }
	col := tree_git_color(kind)
	if is_dir {
		rl.DrawCircleV({right - 14, iy + item_h * 0.5}, 3.5, col)
		return
	}
	letter := tree_git_letter(kind)
	lw := rl.MeasureTextEx(font, to_cstring(letter), FONT_SIZE - 3, CHAR_SPACING).x
	draw_text(font, to_cstring(letter), {right - 10 - lw, iy + 4}, FONT_SIZE - 3, CHAR_SPACING, col)
}

_ft_draw_strike :: proc(font: rl.Font, text: string, x, iy, item_h: f32, col: rl.Color) {
	w := rl.MeasureTextEx(font, to_cstring(text), FONT_SIZE - 2, CHAR_SPACING).x
	rl.DrawLineEx({x, iy + item_h * 0.5}, {x + w, iy + item_h * 0.5}, 1, col)
}

// ---------------------------------------------------------------------------
// Read-only HEAD view of a deleted file
// ---------------------------------------------------------------------------

TREE_HEAD_VIEW_ID :: "tree_head_view"

@(private="file")
_Tree_Head_View :: struct {
	path:   string,           // repo-relative (heap)
	job:    git.Job_Id,
	lines:  [dynamic]string,  // heap (each line cloned)
	msg:    string,           // heap; loading/error text
	scroll: int,
}

@(private="file") _thv: _Tree_Head_View

@(init)
_tree_head_view_register :: proc "contextless" () {
	ui_register_panel(Ui_Panel{
		id       = TREE_HEAD_VIEW_ID,
		title    = "HEAD (read-only)",
		priority = 60,
		layer    = .Overlay,
		draw     = _thv_draw,
		input    = _thv_input,
		update   = _thv_update, // also keeps the file tree's git badges in sync
		on_close = _thv_on_close,
	})
	// The tree only had its Ctrl/Cmd+; key (input.odin); list it in the palette too
	ui_register_command(Command{"File Tree: Toggle", "Show the folder hierarchy of the active project (Ctrl/Cmd+;)", _cmd_file_tree_toggle, nil})
	ui_register_command(Command{"File Tree: Show Changed Files", "File tree with only the files changed in git", _cmd_file_tree_changed, nil})
}

@(private="file")
_cmd_file_tree_toggle :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	if e.file_tree.open { file_tree_close(&e.file_tree) } else { file_tree_open(&e.file_tree) }
}

@(private="file")
_cmd_file_tree_changed :: proc(e: ^Editor, p: ^Palette) {
	palette_close(p)
	if !e.file_tree.open { file_tree_open(&e.file_tree) }
	if !e.file_tree.changed_only { file_tree_toggle_changed_only(&e.file_tree) }
}

@(fini)
_tree_head_view_fini :: proc "contextless" () {
	context = runtime.default_context()
	_thv_reset()
}

@(private="file")
_thv_reset :: proc() {
	for l in _thv.lines { delete(l) }
	delete(_thv.lines)
	delete(_thv.path)
	delete(_thv.msg)
	_thv = {}
}

// Shows `repo_path` as of HEAD in a read-only overlay (deleted files).
tree_head_view_open :: proc(e: ^Editor, repo_path: string) {
	if _thv.job != 0 { git.git_release(&e.git_mgr.queue, _thv.job) }
	_thv_reset()
	_thv.path = strings.clone(repo_path)
	_thv.msg  = strings.clone("loading...")
	_thv.job  = git.git_request_file_at(&e.git_mgr.queue, "HEAD", repo_path)
	ui_panel_open(e, TREE_HEAD_VIEW_ID)
}

@(private="file")
_thv_on_close :: proc(e: ^Editor) {
	if e != nil && _thv.job != 0 { git.git_release(&e.git_mgr.queue, _thv.job) }
	_thv_reset()
}

@(private="file")
_thv_update :: proc(e: ^Editor, dt: f32) {
	file_tree_git_sync(e)
	if _thv.job == 0 { return }
	blob, st, err := git.git_poll_as(&e.git_mgr.queue, _thv.job, git.File_Blob)
	switch st {
	case .Queued, .Running:
		return
	case .Done:
		delete(_thv.msg); _thv.msg = ""
		if !blob.present {
			_thv.msg = strings.clone("file does not exist in HEAD")
		} else if blob.binary {
			_thv.msg = strings.clone("binary file")
		} else {
			text, _ := strings.replace_all(blob.text, "\t", "    ", context.temp_allocator)
			for l in strings.split_lines(text, context.temp_allocator) { append(&_thv.lines, strings.clone(strings.trim_right(l, "\r"))) }
		}
	case .Failed, .Unknown:
		delete(_thv.msg)
		_thv.msg = strings.clone(err if err != "" else "failed to read HEAD version")
	}
	git.git_release(&e.git_mgr.queue, _thv.job)
	_thv.job = 0
}

@(private="file")
_thv_vis_rows :: proc() -> int {
	sh := f32(screen_h())
	ref_h := FONT_SIZE + LINE_SPACING
	return max(1, int((sh * 0.86 - 70) / ref_h))
}

@(private="file")
_thv_input :: proc(e: ^Editor) -> bool {
	if rl.IsKeyPressed(.ESCAPE) || rl.IsKeyPressed(.Q) { ui_panel_close(e, TREE_HEAD_VIEW_ID); return true }
	vis := _thv_vis_rows()
	max_scroll := max(0, len(_thv.lines) - vis)
	if key_rep(.DOWN) || key_rep(.J) { _thv.scroll += 1 }
	if key_rep(.UP)   || key_rep(.K) { _thv.scroll -= 1 }
	if key_rep(.PAGE_DOWN) { _thv.scroll += vis }
	if key_rep(.PAGE_UP)   { _thv.scroll -= vis }
	if rl.IsKeyPressed(.HOME) { _thv.scroll = 0 }
	if rl.IsKeyPressed(.END)  { _thv.scroll = max_scroll }
	wheel := rl.GetMouseWheelMove()
	if wheel != 0 { _thv.scroll -= int(wheel * 3) }
	_thv.scroll = clamp(_thv.scroll, 0, max_scroll)
	return true // modal: the buffer underneath must not receive edits
}

@(private="file")
_thv_draw :: proc(e: ^Editor, font: rl.Font, sw, sh: f32) {
	HEADER_H :: f32(34)
	FOOTER_H :: f32(26)
	w := min(sw - 40, 1000)
	h := sh * 0.86
	x := (sw - w) * 0.5
	y := sh * 0.07
	rl.DrawRectangle(0, 0, i32(sw), i32(sh), rl.Color{0, 0, 0, 150})
	x, y = dlg_begin(x, y, w, h, GITD_BG, GITD_BORDER)

	rl.DrawRectangleV({x, y}, {w, HEADER_H}, GITD_HEADER)
	title := fmt.tprintf("%s  @ HEAD  (read-only, deleted)", _thv.path)
	dlg_text(font, title, x + 10, y + 8, FONT_SIZE, CHAR_SPACING, GITD_RED, x + w, 10)

	row_h := FONT_SIZE + LINE_SPACING
	ly := y + HEADER_H + 6
	if _thv.msg != "" {
		draw_text(font, to_cstring(_thv.msg), {x + 12, ly}, FONT_SIZE - 2, CHAR_SPACING, GITD_SUBDUED)
	} else {
		vis := _thv_vis_rows()
		gut := rl.MeasureTextEx(font, "00000", FONT_SIZE - 2, CHAR_SPACING).x
		for vi in 0..<vis {
			li := _thv.scroll + vi
			if li >= len(_thv.lines) { break }
			ry := ly + f32(vi) * row_h
			if ry + row_h > y + h - FOOTER_H { break }
			num := fmt.tprintf("%5d", li + 1)
			draw_text(font, to_cstring(num), {x + 6, ry}, FONT_SIZE - 2, CHAR_SPACING, GITD_SUBDUED)
			dlg_text(font, _thv.lines[li], x + 16 + gut, ry, FONT_SIZE - 2, CHAR_SPACING, GITD_TEXT, x + w, 8)
		}
	}

	fy := y + h - FOOTER_H
	rl.DrawRectangleV({x, fy}, {w, FOOTER_H}, GITD_HEADER)
	foot := fmt.tprintf("%d lines  ↑↓ PgUp PgDn Home End scroll  Esc close", len(_thv.lines))
	draw_text(font, to_cstring(foot), {x + 10, fy + 5}, FONT_SIZE - 3, CHAR_SPACING, GITD_SUBDUED)
	dlg_end()
}
