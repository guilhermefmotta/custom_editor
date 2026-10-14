package editor

// ===========================================================================
// Welcome screen (no repository open) + Clone / Init dialog (ticket #13,
// ADR 0014). Reference: Git Crab WelcomeScreen.tsx / CloneDialog.tsx.
//
//   welcome         — overlay shown while no repository is open and no file
//                     is being edited: recent repositories, Open Folder(s),
//                     Clone, Init. Esc dismisses it ("Repo: Welcome" reopens).
//   repo_dialog     — Clone (URL + destination) or Init (folder). Runs on the
//                     repo-less queue e.repos.ops (git/repo_ops.odin), shows
//                     progress, and opens the new repository as a tab.
// ===========================================================================

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import git "./git"
import rl "vendor:raylib"

WELCOME_ID     :: "welcome"
REPO_DIALOG_ID :: "repo_dialog"

@(private="file")
_Welcome :: struct {
	nav:        Ui_List_Nav,
	dismissed:  bool,
	last_count: int,
}
@(private="file") _wl: _Welcome

Repo_Dialog_Mode :: enum u8 { Clone, Init }

@(private="file")
_Repo_Dialog :: struct {
	mode:      Repo_Dialog_Mode,
	url:       [dynamic]u8,
	dest:      [dynamic]u8,
	focus:     int, // 0 url, 1 dest (Init: only dest)
	sel_all:   bool,
	dest_edited: bool,
	job:       git.Job_Id,
	job_mode:  Repo_Dialog_Mode,
	prog:      ^git.Clone_Progress,
	started:   f64,
	err:       string, // heap
}
@(private="file") _rd: _Repo_Dialog

@(init)
_welcome_register :: proc "contextless" () {
	ui_register_panel(Ui_Panel{
		id = WELCOME_ID, title = "Welcome", priority = 40, layer = .Overlay,
		draw = _wl_draw, input = _wl_input, update = _wl_update, on_open = _wl_on_open,
		command = "Repo: Welcome", command_desc = "Show the welcome screen (recent repositories, open, clone, init)",
	})
	ui_register_panel(Ui_Panel{
		id = REPO_DIALOG_ID, title = "Clone / Init Repository", priority = 93, layer = .Overlay,
		draw = _rd_draw, input = _rd_input, update = _rd_update,
	})
	ui_register_command(Command{"Repo: Clone...", "Clone a repository by URL and open it", _cmd_repo_clone, nil})
	ui_register_command(Command{"Repo: Init...", "Create a new git repository in a folder and open it", _cmd_repo_init, nil})
}

@(fini)
_welcome_fini :: proc "contextless" () {
	context = runtime.default_context()
	delete(_rd.url); delete(_rd.dest); delete(_rd.err)
	if _rd.prog != nil { git.clone_progress_destroy(_rd.prog) }
	_rd = {}
}

@(private="file")
_cmd_repo_clone :: proc(e: ^Editor, p: ^Palette) { palette_close(p); repo_dialog_open(e, .Clone) }
@(private="file")
_cmd_repo_init :: proc(e: ^Editor, p: ^Palette) { palette_close(p); repo_dialog_open(e, .Init) }

// ---------------------------------------------------------------------------
// Welcome
// ---------------------------------------------------------------------------

@(private="file")
_wl_update :: proc(e: ^Editor, dt: f32) {
	if e.git_mgr == nil { return }
	n := len(e.repos.list)
	prev := _wl.last_count
	_wl.last_count = n
	if n == 0 {
		if prev > 0 { _wl.dismissed = false } // last repo closed → welcome again
		// Shown while nothing is open; a file opened in the scratch view hides it.
		want := !_wl.dismissed && !e.repos.pending && !repos_view_has_files(e)
		if want != ui_panel_is_open(WELCOME_ID) {
			if want { ui_panel_open(e, WELCOME_ID) } else { ui_panel_close(e, WELCOME_ID) }
		}
	} else if prev == 0 && ui_panel_is_open(WELCOME_ID) {
		ui_panel_close(e, WELCOME_ID) // first repo just opened
	}
}

@(private="file")
_wl_on_open :: proc(e: ^Editor) { _wl.dismissed = false }

@(private="file")
_wl_open_recent :: proc(e: ^Editor, i: int) {
	if i < 0 || i >= len(e.recent_repos.paths) { return }
	path := strings.clone(e.recent_repos.paths[i], context.temp_allocator)
	if _, err := repos_open(e, path); err != "" {
		ui_banner_show(err, .Error, 6)
		if !os.exists(path) {
			recent_repos_remove(&e.recent_repos, path) // stale entry
			if e.repos.live { recent_repos_save(&e.recent_repos) }
		}
	}
}

@(private="file")
_wl_input :: proc(e: ^Editor) -> bool {
	if ui_panel_is_open(REPO_DIALOG_ID) || e.workspace_dlg.open { return false }
	n := len(e.recent_repos.paths)
	switch {
	case rl.IsKeyPressed(.ESCAPE):
		_wl.dismissed = true
		ui_panel_close(e, WELCOME_ID)
	case rl.IsKeyPressed(.O) && !ctrl():
		workspace_dialog_open(&e.workspace_dlg)
	case rl.IsKeyPressed(.C) && !ctrl():
		repo_dialog_open(e, .Clone)
	case rl.IsKeyPressed(.I) && !ctrl():
		repo_dialog_open(e, .Init)
	case rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER):
		_wl_open_recent(e, _wl.nav.selected)
	case rl.IsKeyPressed(.DELETE) && n > 0:
		recent_repos_remove(&e.recent_repos, e.recent_repos.paths[clamp(_wl.nav.selected, 0, n - 1)])
		if e.repos.live { recent_repos_save(&e.recent_repos) }
	case:
		ui_list_handle_nav(&_wl.nav, n, 12)
	}
	// Modal-ish: swallow keys/clicks so the scratch buffer underneath is untouched.
	return !ctrl() || rl.IsMouseButtonPressed(.LEFT)
}

@(private="file")
_wl_draw :: proc(e: ^Editor, font: rl.Font, sw, sh: f32) {
	rl.DrawRectangle(0, 0, i32(sw), i32(sh), BG)
	W  := min(f32(620), sw - 40)
	n  := len(e.recent_repos.paths)
	vis := min(n, 12)
	H  := f32(150) + f32(3) * 46 + (f32(vis) * 38 + 40 if n > 0 else 0)
	x  := (sw - W) * 0.5
	y  := max(f32(20), (sh - H) * 0.35)
	mp := rl.GetMousePosition()
	click := rl.IsMouseButtonPressed(.LEFT) && !ui_panel_is_open(REPO_DIALOG_ID) && !e.workspace_dlg.open

	ui_text(font, "editor", x, y, 40, FONT_SIZE + 10, ACCENT_COL, x + W)
	ui_text(font, "Open several repositories side by side - one tab each.", x, y + 42, 24, FONT_SIZE - 2, LINENUM, x + W)
	y += 90

	Action :: struct { label, hint, key: string, mode: int }
	actions := [3]Action{
		{"Open Folder(s)...", "Pick one or more folders (or drop them on the window)", "O", 0},
		{"Clone Repository...", "Clone a remote repository by URL", "C", 1},
		{"Init Repository...", "Create a new git repository in a folder", "I", 2},
	}
	for a in actions {
		r := rl.Rectangle{x, y, W, 40}
		hover := ui_point_in(mp, r)
		rl.DrawRectangleRec(r, ui_with_alpha(SEL_BG, 200) if hover else STATUS_BG)
		rl.DrawRectangleLinesEx(r, 1, DIVIDER_COL)
		ui_text(font, a.key, x + 12, y, 40, FONT_SIZE, ACCENT_COL, x + 40)
		ui_text(font, a.label, x + 40, y, 22, FONT_SIZE - 1, TEXT, x + W)
		ui_text(font, a.hint, x + 40, y + 18, 22, FONT_SIZE - 4, LINENUM, x + W)
		if hover && click {
			switch a.mode {
			case 0: workspace_dialog_open(&e.workspace_dlg)
			case 1: repo_dialog_open(e, .Clone)
			case 2: repo_dialog_open(e, .Init)
			}
		}
		y += 46
	}

	if n > 0 {
		y += 10
		ui_text(font, "RECENT", x, y, 24, FONT_SIZE - 4, LINENUM, x + W)
		y += 26
		ui_list_clamp(&_wl.nav, n, 12)
		for vi in 0 ..< vis {
			i := _wl.nav.scroll + vi
			if i >= n { break }
			r := rl.Rectangle{x, y, W, 36}
			if i == _wl.nav.selected {
				rl.DrawRectangleRec(r, SEL_BG)
				rl.DrawRectangleRec({x, y, 3, 36}, ACCENT_COL)
			} else if ui_point_in(mp, r) {
				rl.DrawRectangleRec(r, ui_with_alpha(SEL_BG, 110))
			}
			path := e.recent_repos.paths[i]
			ui_text(font, filepath.base(path), x + 12, y, 20, FONT_SIZE - 1, TEXT, x + W)
			ui_text(font, path, x + 12, y + 17, 18, FONT_SIZE - 5, LINENUM, x + W)
			if click && ui_point_in(mp, r) {
				_wl.nav.selected = i
				_wl_open_recent(e, i)
				return
			}
			y += 38
		}
	}
	ui_text(font, "Enter open recent   Del forget   O/C/I actions   Esc dismiss   Ctrl+Shift+P commands",
		x, max(y + 14, sh - 40), 20, FONT_SIZE - 5, LINENUM, x + W)
}

// ---------------------------------------------------------------------------
// Clone / Init dialog
// ---------------------------------------------------------------------------

// Folder new repositories go to by default: the parent of the active repo,
// else the parent of the most recent one, else the home directory.
@(private="file")
_rd_default_parent :: proc(e: ^Editor) -> string {
	if r := repos_active(e); r != nil { return filepath.dir(r.root) }
	if len(e.recent_repos.paths) > 0 { return filepath.dir(e.recent_repos.paths[0]) }
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" { home = os.get_env("USERPROFILE", context.temp_allocator) }
	return home if home != "" else "."
}

@(private="file")
_rd_set :: proc(buf: ^[dynamic]u8, s: string) {
	clear(buf)
	append(buf, s)
}

repo_dialog_open :: proc(e: ^Editor, mode: Repo_Dialog_Mode) {
	if _rd.job != 0 {
		ui_panel_open(e, REPO_DIALOG_ID) // show the running job
		return
	}
	_rd.mode, _rd.sel_all, _rd.dest_edited = mode, false, false
	delete(_rd.err); _rd.err = ""
	parent := _rd_default_parent(e)
	clear(&_rd.url)
	if mode == .Clone {
		_rd.focus = 0
		_rd_set(&_rd.dest, fmt.tprintf("%s/", parent))
	} else {
		_rd.focus = 1
		_rd_set(&_rd.dest, fmt.tprintf("%s/new-repo", parent))
		_rd.sel_all = false
	}
	ui_panel_open(e, REPO_DIALOG_ID)
}

@(private="file")
_rd_start :: proc(e: ^Editor) {
	dest := strings.trim_space(string(_rd.dest[:]))
	delete(_rd.err); _rd.err = ""
	switch _rd.mode {
	case .Clone:
		url := strings.trim_space(string(_rd.url[:]))
		if url == "" { _rd.err = strings.clone("Enter the repository URL"); return }
		if dest == "" || strings.has_suffix(dest, "/") {
			dest = fmt.tprintf("%s%s%s", dest, "" if dest == "" || strings.has_suffix(dest, "/") else "/", git.clone_repo_name(url))
		}
		if _rd.prog != nil { git.clone_progress_destroy(_rd.prog) }
		_rd.prog = new(git.Clone_Progress)
		_rd.prog.percent = -1
		_rd.job = git.git_request_clone(&e.repos.ops, url, dest, _rd.prog)
	case .Init:
		if dest == "" { _rd.err = strings.clone("Enter a folder"); return }
		_rd.job = git.git_request_init(&e.repos.ops, dest)
	}
	_rd.job_mode = _rd.mode
	_rd.started  = rl.GetTime()
}

// Polls the running clone/init (every frame, open or not).
@(private="file")
_rd_update :: proc(e: ^Editor, dt: f32) {
	if _rd.job == 0 { return }
	c, st, err := git.git_poll_as(&e.repos.ops, _rd.job, git.Git_Custom)
	#partial switch st {
	case .Queued, .Running: return
	case .Done:
		res := git.git_custom_as(c^, git.Repo_Op_Result)
		if res.ok {
			path := strings.clone(res.path, context.temp_allocator)
			msg  := strings.clone(res.message, context.temp_allocator)
			_rd_job_end(e)
			ui_panel_close(e, REPO_DIALOG_ID)
			if _, oerr := repos_open(e, path); oerr != "" {
				ui_banner_show(oerr, .Error, 8)
			} else {
				ui_banner_show(msg, .Success, 4)
			}
			return
		}
		_rd.err = strings.clone(res.message)
	case:
		_rd.err = strings.clone(err if err != "" else "operation failed")
	}
	ui_banner_show(_rd.err, .Error, 8)
	_rd_job_end(e)
	ui_panel_open(e, REPO_DIALOG_ID) // show the error next to the inputs
}

@(private="file")
_rd_job_end :: proc(e: ^Editor) {
	git.git_release(&e.repos.ops, _rd.job)
	_rd.job = 0
	if _rd.prog != nil { git.clone_progress_destroy(_rd.prog); _rd.prog = nil }
}

@(private="file")
_rd_input :: proc(e: ^Editor) -> bool {
	if rl.IsKeyPressed(.ESCAPE) { ui_panel_close(e, REPO_DIALOG_ID); return true } // a running job continues
	if _rd.job != 0 { return true }
	if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) { _rd_start(e); return true }
	if rl.IsKeyPressed(.TAB) && _rd.mode == .Clone { _rd.focus = 1 - _rd.focus; _rd.sel_all = false; return true }
	if _rd.mode == .Clone && _rd.focus == 0 {
		if text_input_handle(&_rd.url, &_rd.sel_all) && !_rd.dest_edited {
			// Follow the URL: <parent>/<name>
			parent := _rd_default_parent(e)
			name := git.clone_repo_name(string(_rd.url[:]))
			_rd_set(&_rd.dest, fmt.tprintf("%s/%s", parent, name))
		}
	} else {
		if text_input_handle(&_rd.dest, &_rd.sel_all) { _rd.dest_edited = true }
	}
	return true
}

@(private="file")
_rd_field :: proc(font: rl.Font, r: rl.Rectangle, label, text: string, focused, sel_all: bool) {
	ui_text(font, label, r.x, r.y - 22, 20, FONT_SIZE - 3, LINENUM, r.x + r.width)
	rl.DrawRectangleRec(r, STATUS_BG)
	rl.DrawRectangleLinesEx(r, 1, ACCENT_COL if focused else DIVIDER_COL)
	size := FONT_SIZE - 1
	shown := text
	for len(shown) > 0 && ui_text_w(font, shown, size) > r.width - 20 { shown = shown[1:] }
	ty := r.y + (r.height - size) * 0.5
	if focused && sel_all { rl.DrawRectangleRec({r.x + 6, ty - 2, ui_text_w(font, shown, size) + 4, size + 4}, ui_with_alpha(ACCENT_COL, 60)) }
	dlg_text(font, shown, r.x + 8, ty, size, CHAR_SPACING, TEXT, r.x + r.width, 8)
	if focused { rl.DrawRectangleV({r.x + 8 + ui_text_w(font, shown, size), ty}, {2, size}, ACCENT_COL) }
}

@(private="file")
_rd_draw :: proc(e: ^Editor, font: rl.Font, sw, sh: f32) {
	W := min(f32(640), sw - 40)
	clone := _rd.mode == .Clone
	H := f32(clone ? 250 : 190)
	px := (sw - W) * 0.5
	py := sh * 0.16
	rl.DrawRectangle(0, 0, i32(sw), i32(sh), {0, 0, 0, 150})
	px, py = dlg_begin(px, py, W, H, BG, DIVIDER_COL)
	defer dlg_end()
	ui_text(font, "Clone Repository" if clone else "Init Repository", px + 14, py + 4, 30, FONT_SIZE, ACCENT_COL, px + W)
	y := py + 62
	if clone {
		_rd_field(font, {px + 14, y, W - 28, 30}, "Repository URL (https://... or git@host:owner/repo)", string(_rd.url[:]), _rd.focus == 0 && _rd.job == 0, _rd.sel_all)
		y += 62
	}
	_rd_field(font, {px + 14, y, W - 28, 30}, "Destination folder" if clone else "Folder (created if missing)", string(_rd.dest[:]), _rd.focus == 1 && _rd.job == 0, _rd.sel_all)
	y += 42

	status := ""
	col := LINENUM
	if _rd.job != 0 {
		el := rl.GetTime() - _rd.started
		dots := strings.repeat(".", int(el * 3) % 4, context.temp_allocator)
		if _rd.job_mode == .Clone {
			buf: [48]u8
			phase, pct := git.clone_progress_read(_rd.prog, buf[:])
			if phase != "" && pct >= 0 {
				status = fmt.tprintf("%s: %d%%   (%.0fs)", phase, pct, el)
				bar := rl.Rectangle{px + 14, y + 26, W - 28, 4}
				rl.DrawRectangleRec(bar, STATUS_BG)
				rl.DrawRectangleRec({bar.x, bar.y, bar.width * f32(pct) / 100, bar.height}, ACCENT_COL)
			} else {
				status = fmt.tprintf("Cloning%s   (%.0fs)", dots, el)
			}
		} else {
			status = fmt.tprintf("Initializing%s", dots)
		}
		col = ACCENT_COL
	} else if _rd.err != "" {
		status, col = _rd.err, GITD_RED
	}
	ui_text(font, status, px + 14, y, 22, FONT_SIZE - 3, col, px + W - 14)

	hint := "Enter start   Tab next field   Esc cancel" if _rd.job == 0 else "Esc hide (keeps running in the background)"
	ui_text(font, hint, px + 14, py + H - 30, 24, FONT_SIZE - 5, LINENUM, px + W)
}
