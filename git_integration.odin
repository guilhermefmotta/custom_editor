package editor

import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import git "./git"
import rl "vendor:raylib"

// ---------------------------------------------------------------------------
// Git gutter mark colors (defined here, shared with renderer)
// ---------------------------------------------------------------------------

GIT_ADDED    :: rl.Color{166, 227, 161, 255} // Catppuccin green
GIT_MODIFIED :: rl.Color{250, 179, 135, 255} // Catppuccin peach
GIT_DELETED  :: rl.Color{243, 139, 168, 255} // Catppuccin red

// ---------------------------------------------------------------------------
// Init — open the startup repository (ADR 0014)
// ---------------------------------------------------------------------------

// Called once at startup after the session/args were applied. When nothing
// opened a repository, the folder of the active file (or the cwd) is opened
// as one if it lives inside a git repository — the pre-multi-repo behavior of
// launching the editor from a project directory. Otherwise the welcome
// screen shows.
editor_git_init :: proc(e: ^Editor) {
	if len(e.repos.list) > 0 { return }
	root := _git_find_root(e)
	if root == "" { return }
	if _, err := repos_open(e, root); err != "" { ui_banner_show(err, .Error, 8) }
}

_git_find_root :: proc(e: ^Editor) -> string {
	cwd, cwd_err := os.get_working_directory(context.temp_allocator)
	if cwd_err != nil { cwd = "." }
	p := active_pane(e)
	start := cwd
	if p.filename != "" { start = _path_dirname(p.filename) }
	dir := start
	for dir != "" && dir != "/" {
		if _file_exists(fmt.tprintf("%s/.git", dir)) { return dir }
		parent := _path_dirname(dir)
		if parent == dir || parent == "" { break }
		dir = parent
	}
	// Also check cwd
	if _file_exists(fmt.tprintf("%s/.git", cwd)) { return cwd }
	return ""
}

// ---------------------------------------------------------------------------
// git_update — call once per frame from main thread
// ---------------------------------------------------------------------------

// Active repo: full update (status + queue callbacks). Background repos:
// status only (repos_git_update). Also drives a pending repo switch.
git_update :: proc(e: ^Editor, dt: f32) {
	git.git_manager_update(e.git_mgr, dt) // no-op without a repository
	repos_git_update(e, dt)
}

// ---------------------------------------------------------------------------
// Draw gutter mark for one line (called from renderer)
// ---------------------------------------------------------------------------

git_draw_line_mark :: proc(e: ^Editor, filename: string, line_1based: int, ox: f32, y: f32, ch: f32) {
	if e.git_mgr.root == "" { return }
	hunks, has := e.git_mgr.current.hunks[filename]
	if !has { return }
	for h in hunks {
		switch h.kind {
		case .Added, .Modified:
			if line_1based >= h.new_start && line_1based < h.new_start + h.new_count {
				col := GIT_ADDED if h.kind == .Added else GIT_MODIFIED
				rl.DrawRectangleV({ox, y}, {3, ch}, col)
				return
			}
		case .Deleted:
			// Show deletion mark as thin bar at bottom of the line just before deletion
			if line_1based == h.new_start || (h.new_start == 0 && line_1based == 1) {
				rl.DrawRectangleV({ox, y + ch - 3}, {3, 3}, GIT_DELETED)
				return
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Palette command handler
// ---------------------------------------------------------------------------

cmd_git_panel :: proc(e: ^Editor, p: ^Palette) {
	if e.git_mgr.root == "" {
		e.msg = "No git repository found"
		return
	}
	palette_close(p)
	git_dialog_open(&e.git_dialog)
}

cmd_git_blame_toggle :: proc(e: ^Editor, p: ^Palette) {
	if e.git_mgr.root == "" {
		e.msg = "No git repository found"
		return
	}
	e.blame_enabled = !e.blame_enabled
	palette_close(p)
	e.msg = "Git Blame: on" if e.blame_enabled else "Git Blame: off"
}

// ---------------------------------------------------------------------------
// Blame gutter (date + author, left of line numbers, toggled via palette)
// ---------------------------------------------------------------------------

BLAME_GUTTER_CHARS :: 22 // "23/08/2017 " (11) + author name (up to 11)
BLAME_ZERO_HASH     :: "0000000000000000000000000000000000000000"

// git_blame_gutter_width returns the extra gutter width (0 when disabled)
// that render_pane must add before the line-number column.
git_blame_gutter_width :: proc(e: ^Editor, cw: f32) -> f32 {
	if !e.blame_enabled { return 0 }
	return f32(BLAME_GUTTER_CHARS)*cw + GUTTER_PAD*2
}

// git_draw_blame_gutter draws date + author for line li (0-based) at the
// left edge of the gutter (ox), but only on the first line of a run of
// consecutive lines that share the same commit — repeats render blank so
// the annotation reads as one block per commit, not noise per line.
git_draw_blame_gutter :: proc(e: ^Editor, filename: string, li: int, ox: f32, y: f32, ch: f32, font: rl.Font) {
	if !e.blame_enabled || filename == "" { return }
	lines := git.git_blame_get(e.git_mgr, filename)
	if li < 0 || li >= len(lines) { return }
	bl := lines[li]
	if bl.author == "" { return } // no blame info for this line (e.g. binary/empty file)

	is_new_block := li == 0 || lines[li-1].hash != bl.hash
	if !is_new_block { return }

	uncommitted := bl.hash == BLAME_ZERO_HASH
	label: string
	col: rl.Color
	if uncommitted {
		label = "uncommitted"
		col = rl.Color{250, 179, 135, 200} // Catppuccin peach
	} else {
		name := bl.author
		if len(name) > 11 { name = name[:11] }
		label = fmt.tprintf("%s %s", bl.date, name)
		col = rl.Color{147, 153, 178, 255} // Catppuccin subtext0
	}
	ref := rl.MeasureTextEx(font, "M", FONT_SIZE, CHAR_SPACING)
	rl.DrawTextEx(font, to_cstring(label), {ox + GUTTER_PAD, y + (ch - ref.y)*0.5}, FONT_SIZE, CHAR_SPACING, col)
}

// ---------------------------------------------------------------------------
// File tree git badges (#11) — pure classification + status index
// ---------------------------------------------------------------------------
//
// The file tree shows, per file, the kind of change git reports for it and,
// per folder, a dot with the most important change found below it. The
// status comes from git.Git_Manager (e.git_mgr.current.entries, refreshed by
// the manager's own background thread) — no extra git process is spawned.

// Ordered by importance: a folder dot shows the max() of its descendants.
// Priority (Git Crab FileExplorer.tsx): conflicted > deleted > modified >
// renamed > added > untracked.
Tree_Git_Kind :: enum u8 {
	None,
	Untracked,
	Added,
	Renamed,
	Modified,
	Deleted,
	Conflicted,
}

TREE_GIT_PURPLE :: rl.Color{203, 166, 247, 255} // Catppuccin mauve (Git Crab purple-400)

// Classifies one `git status --porcelain=v1` XY pair. Same rules as Git
// Crab's change_kind (repo.rs): conflict first, then deleted, added,
// untracked, renamed, modified.
tree_git_classify :: proc(x, y: u8) -> Tree_Git_Kind {
	if x == '!' && y == '!' { return .None }
	if x == '?' && y == '?' { return .Untracked }
	// Unmerged: DD AU UD UA DU AA UU
	if x == 'U' || y == 'U' || (x == 'A' && y == 'A') || (x == 'D' && y == 'D') { return .Conflicted }
	if x == 'D' || y == 'D' { return .Deleted }
	if x == 'A' || x == 'C' { return .Added }
	if x == 'R' || y == 'R' { return .Renamed }
	if x == 'M' || y == 'M' || x == 'T' || y == 'T' { return .Modified }
	return .None
}

tree_git_letter :: proc(k: Tree_Git_Kind) -> string {
	switch k {
	case .None:       return ""
	case .Untracked:  return "U"
	case .Added:      return "A"
	case .Renamed:    return "R"
	case .Modified:   return "M"
	case .Deleted:    return "D"
	case .Conflicted: return "!"
	}
	return ""
}

// Colors follow Git Crab (yellow/green/red/sky/purple) in the editor palette.
tree_git_color :: proc(k: Tree_Git_Kind) -> rl.Color {
	switch k {
	case .None:                return TEXT
	case .Untracked, .Added:   return GITD_GREEN
	case .Renamed:             return GITD_BLUE
	case .Modified:            return GITD_YELLOW
	case .Deleted:             return GITD_RED
	case .Conflicted:          return TREE_GIT_PURPLE
	}
	return TEXT
}

// Status of the repository indexed by path relative to the editor's cwd
// (the file tree's root), so tree nodes can be looked up directly.
Tree_Git_Index :: struct {
	files:          map[string]Tree_Git_Kind, // cwd-relative path → kind (keys heap-owned)
	dirs:           map[string]Tree_Git_Kind, // every ancestor dir → most important kind (keys heap-owned)
	untracked_dirs: [dynamic]string,          // "?? dir/" entries, no trailing slash (aliases `files` keys)
	deleted:        [dynamic]string,          // deleted files — not on disk (aliases `files` keys)
	repo_rel:       map[string]string,        // cwd-relative → repo-relative (keys alias `files`, values heap)
}

tree_git_index_clear :: proc(idx: ^Tree_Git_Index) {
	for k, v in idx.repo_rel { delete(v); _ = k }
	clear(&idx.repo_rel)
	for k in idx.files { delete(k) }
	clear(&idx.files)
	for k in idx.dirs { delete(k) }
	clear(&idx.dirs)
	clear(&idx.untracked_dirs)
	clear(&idx.deleted)
}

tree_git_index_destroy :: proc(idx: ^Tree_Git_Index) {
	tree_git_index_clear(idx)
	delete(idx.files)
	delete(idx.dirs)
	delete(idx.untracked_dirs)
	delete(idx.deleted)
	delete(idx.repo_rel)
	idx^ = {}
}

// Rebuilds the index from porcelain entries. `root` is the repository root
// and `cwd` the tree root (both absolute, or both the same relative base);
// entries outside cwd are dropped.
tree_git_index_build :: proc(idx: ^Tree_Git_Index, entries: []git.Status_Entry, root, cwd: string) {
	tree_git_index_clear(idx)
	for en in entries {
		kind := tree_git_classify(en.index, en.worktree)
		if kind == .None { continue }
		is_udir := strings.has_suffix(en.path, "/")
		repo_path := strings.trim_right(en.path, "/")
		rel := tree_git_cwd_rel(root, cwd, repo_path, context.temp_allocator)
		if rel == "" { continue }
		if _, dup := idx.files[rel]; dup {
			// Same path listed twice (e.g. "D " + "??"): keep the more important.
			if kind > idx.files[rel] { idx.files[rel] = kind }
			continue
		}
		key := strings.clone(rel)
		idx.files[key] = kind
		idx.repo_rel[key] = strings.clone(repo_path)
		if is_udir { append(&idx.untracked_dirs, key) }
		if kind == .Deleted { append(&idx.deleted, key) }
		// Folder dots: every ancestor (and an untracked dir itself).
		d := key if is_udir else _tree_git_parent(key)
		for d != "" {
			if cur, ok := idx.dirs[d]; ok {
				if kind > cur { idx.dirs[d] = kind }
			} else {
				idx.dirs[strings.clone(d)] = kind
			}
			d = _tree_git_parent(d)
		}
	}
}

// Path of `repo_path` (relative to root) relative to cwd; "" when outside.
tree_git_cwd_rel :: proc(root, cwd, repo_path: string, allocator := context.allocator) -> string {
	if root == cwd { return strings.clone(tree_git_key(repo_path), allocator) }
	abs, _ := filepath.join({root, repo_path}, context.temp_allocator)
	rel, err := filepath.rel(cwd, abs, context.temp_allocator)
	if err != .None || rel == "." || rel == ".." || strings.has_prefix(rel, "../") || strings.has_prefix(rel, "..\\") { return "" }
	return strings.clone(tree_git_key(rel), allocator)
}

// "a/b/c" → "a/b"; "a" → "".
_tree_git_parent :: proc(p: string) -> string {
	i := strings.last_index_any(p, "/\\")
	if i < 0 { return "" }
	return p[:i]
}

// Normalizes a tree path ("./a/b", "a//b") to the index key form ("a/b").
tree_git_key :: proc(path: string) -> string {
	c, _ := filepath.clean(path, context.temp_allocator)
	when ODIN_OS == .Windows {
		c, _ = strings.replace_all(c, "\\", "/", context.temp_allocator)
	}
	return c
}

// Kind of a file node (untracked folders count for everything below them).
tree_git_file_kind :: proc(idx: ^Tree_Git_Index, path: string) -> Tree_Git_Kind {
	k := tree_git_key(path)
	if v, ok := idx.files[k]; ok { return v }
	for u in idx.untracked_dirs {
		if strings.has_prefix(k, u) && len(k) > len(u) && k[len(u)] == '/' { return .Untracked }
	}
	return .None
}

// Most important change below a folder node (.None = clean).
tree_git_dir_kind :: proc(idx: ^Tree_Git_Index, path: string) -> Tree_Git_Kind {
	k := tree_git_key(path)
	if v, ok := idx.dirs[k]; ok { return v }
	return tree_git_file_kind(idx, k) // inside an untracked folder
}

// Deleted entries that are direct children of `dir` ("." = tree root):
// deleted file names and names of sub-folders that hold deleted files.
// Sorted, unique, temp-allocated. Used to inject them into the tree, since
// they no longer exist on disk.
tree_git_deleted_children :: proc(idx: ^Tree_Git_Index, dir: string) -> (files: []string, dirs: []string) {
	d := tree_git_key(dir)
	fs := make([dynamic]string, context.temp_allocator)
	ds := make([dynamic]string, context.temp_allocator)
	for p in idx.deleted {
		rest: string
		if d == "." {
			rest = p
		} else if strings.has_prefix(p, d) && len(p) > len(d) && p[len(d)] == '/' {
			rest = p[len(d)+1:]
		} else {
			continue
		}
		if s := strings.index_byte(rest, '/'); s >= 0 {
			name := rest[:s]
			if !slice.contains(ds[:], name) { append(&ds, name) }
		} else {
			append(&fs, rest)
		}
	}
	slice.sort(fs[:])
	slice.sort(ds[:])
	return fs[:], ds[:]
}

// Content hash of a status list — the manager swaps in a new array every
// refresh, so the tree only rebuilds when the status actually changed.
tree_git_status_hash :: proc(entries: []git.Status_Entry) -> u64 {
	h: u64 = 14695981039346656037
	for en in entries {
		xy := [2]u8{en.index, en.worktree}
		h = hash.fnv64a(xy[:], h)
		h = hash.fnv64a(transmute([]u8)en.path, h)
		h = hash.fnv64a(transmute([]u8)en.old_path, h)
		h = hash.fnv64a({0}, h)
	}
	return h
}
