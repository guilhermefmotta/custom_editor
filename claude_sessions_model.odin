package editor

// ===========================================================================
// Claude Code sessions — model (ticket #17, ADR 0015). No raylib here: the
// panel/shortcut/notification side is claude_sessions.odin.
//
// One session per repository root: a terminal (package `term`) running
//   claude --settings <dir>/claude-hooks.json
// in the repo root. That settings file holds ONLY the editor's status hooks
// (Claude Code merges `--settings` with the user's own settings and hook
// lists merge across levels, so the user's plugins/hooks keep working; the
// user's ~/.claude is never touched). Every hook runs the generated
// <dir>/status-hook.sh (.ps1 on Windows), which copies the hook's JSON
// payload (stdin) into the file named by $CUSTOM_EDITOR_CLAUDE_STATUS —
// set only in the environment of terminals this editor starts, so the hook
// is a no-op anywhere else. The editor polls that file (mtime/size) and
// feeds the payload to the status machine:
//
//   UserPromptSubmit / PreToolUse / PostToolUse  → Working
//   Notification (permission / idle / input)     → Waiting   (OS notification)
//   Stop / SessionEnd / process exited           → Stopped
//   SessionStart                                 → Stopped (idle at the prompt)
// ===========================================================================

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import git "./git"
import term "terminal"

CLAUDE_STATUS_ENV     :: "CUSTOM_EDITOR_CLAUDE_STATUS"
CLAUDE_CMD_ENV        :: "CUSTOM_EDITOR_CLAUDE_CMD" // override the `claude` command (e.g. a wrapper)
CLAUDE_SETTINGS_FILE  :: "claude-hooks.json"
CLAUDE_HOOK_SCRIPT_SH :: "status-hook.sh"
CLAUDE_HOOK_SCRIPT_PS :: "status-hook.ps1"
// Events the editor's settings file hooks (and nothing else).
CLAUDE_HOOK_EVENTS :: [?]string{"SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop", "SessionEnd"}

Claude_Status :: enum u8 {
	Stopped, // idle at the prompt / finished the turn / process gone
	Working,
	Waiting, // needs you: permission prompt, question, idle reminder
}

CLAUDE_STATUS_LABEL := [Claude_Status]string{
	.Stopped = "stopped",
	.Working = "working",
	.Waiting = "waiting for you",
}

// Fields of a hook payload we care about (stdin JSON of every hook).
Claude_Hook_Payload :: struct {
	session_id:        string,
	cwd:               string,
	hook_event_name:   string,
	notification_type: string,
	message:           string,
	tool_name:         string,
}

Claude_Session :: struct {
	id:          string, // "<editor pid>-<n>", owned
	root:        string, // repository root (cwd of claude), owned
	name:        string, // basename of root, owned
	t:           ^term.Terminal,
	status:      Claude_Status,
	exited:      bool,
	since:       time.Time, // last status change
	message:     string,    // last Notification message, owned
	claude_id:   string,    // Claude Code session_id (from the hooks), owned
	status_file: string,    // owned
	file_mtime:  time.Time,
	file_size:   i64,

	// Review mode (review_mode*.odin)
	base_rev:    string, // HEAD when the session started ("" = unknown yet), owned
	base_job:    git.Job_Id, // pending rev-parse on the repo's queue
	reviewed:    map[string]bool, // path (owned key) → reviewed
}

Claude_Sessions :: struct {
	list:     [dynamic]^Claude_Session,
	dir:      string, // where settings/script/state live, owned
	next:     int,
	prepared: bool,
}

// ---------------------------------------------------------------------------
// Hook payload → status
// ---------------------------------------------------------------------------

// Parses a hook payload. Strings are allocated with `allocator`.
claude_parse_hook_payload :: proc(data: string, allocator := context.allocator) -> (p: Claude_Hook_Payload, ok: bool) {
	trimmed := strings.trim_space(data)
	if trimmed == "" { return {}, false }
	if err := json.unmarshal_string(trimmed, &p, allocator = allocator); err != nil || p.hook_event_name == "" {
		claude_hook_payload_destroy(&p, allocator)
		return {}, false
	}
	return p, true
}

claude_hook_payload_destroy :: proc(p: ^Claude_Hook_Payload, allocator := context.allocator) {
	delete(p.session_id, allocator)
	delete(p.cwd, allocator)
	delete(p.hook_event_name, allocator)
	delete(p.notification_type, allocator)
	delete(p.message, allocator)
	delete(p.tool_name, allocator)
	p^ = {}
}

// Status an event leads to; ok = false when the event doesn't change it
// (unknown events, informational notifications like auth_success).
claude_event_status :: proc(p: Claude_Hook_Payload) -> (s: Claude_Status, ok: bool) {
	switch p.hook_event_name {
	case "UserPromptSubmit", "PreToolUse", "PostToolUse", "SubagentStart":
		return .Working, true
	case "Notification":
		switch p.notification_type {
		case "", "permission_prompt", "idle_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
			return .Waiting, true
		}
		return .Stopped, false
	case "Stop", "SessionEnd", "SessionStart":
		return .Stopped, true
	}
	return .Stopped, false
}

// Status machine step. notify = the session just started waiting for you.
claude_status_step :: proc(cur, next: Claude_Status) -> (new: Claude_Status, changed, notify: bool) {
	return next, next != cur, next == .Waiting && cur != .Waiting
}

// Applies a parsed payload to the session. Returns whether a notification
// should be shown.
claude_session_apply :: proc(s: ^Claude_Session, p: Claude_Hook_Payload) -> (notify: bool) {
	if p.session_id != "" && p.session_id != s.claude_id {
		delete(s.claude_id)
		s.claude_id = strings.clone(p.session_id)
	}
	next, ok := claude_event_status(p)
	if !ok { return false }
	if next == .Waiting && p.message != "" {
		delete(s.message)
		s.message = strings.clone(p.message)
	}
	new, changed, n := claude_status_step(s.status, next)
	if changed { s.status = new; s.since = time.now() }
	return n
}

// Marks the session's process as gone (status Stopped, no notification).
claude_session_mark_exited :: proc(s: ^Claude_Session) {
	if s.exited { return }
	s.exited = true
	if s.status != .Stopped { s.status = .Stopped; s.since = time.now() }
}

// Reads the session's status file when it changed since the last poll and
// applies it. Also notices the process exiting. notify = start waiting.
claude_session_poll :: proc(s: ^Claude_Session) -> (changed, notify: bool) {
	before := s.status
	if !s.exited && s.t != nil && term.has_exited(s.t) { claude_session_mark_exited(s) }
	fi, err := os.stat(s.status_file, context.temp_allocator)
	if err == nil && (fi.modification_time != s.file_mtime || fi.size != s.file_size) {
		s.file_mtime, s.file_size = fi.modification_time, fi.size
		if data, rerr := os.read_entire_file(s.status_file, context.temp_allocator); rerr == nil {
			if p, ok := claude_parse_hook_payload(string(data), context.temp_allocator); ok {
				// A late hook after exit can't revive a dead session.
				if !s.exited { notify = claude_session_apply(s, p) }
			}
		}
	}
	return s.status != before, notify
}

// ---------------------------------------------------------------------------
// Generated files (settings + hook script)
// ---------------------------------------------------------------------------

// ~/.config/editor/claude (USERPROFILE on Windows); temp-allocated, "" if no home.
claude_sessions_default_dir :: proc() -> string {
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" { home = os.get_env("USERPROFILE", context.temp_allocator) }
	if home == "" { return "" }
	return fmt.tprintf("%s/.config/editor/claude", home)
}

@(private="file")
_json_escape :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for ch in s {
		switch ch {
		case '"':  strings.write_string(b, `\"`)
		case '\\': strings.write_string(b, `\\`)
		case '\n': strings.write_string(b, `\n`)
		case '\r': strings.write_string(b, `\r`)
		case '\t': strings.write_string(b, `\t`)
		case:
			if ch < 0x20 { fmt.sbprintf(b, `\u%04x`, int(ch)) } else { strings.write_rune(b, ch) }
		}
	}
	strings.write_byte(b, '"')
}

// POSIX single-quoting.
claude_sh_quote :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '\'')
	for i in 0 ..< len(s) {
		if s[i] == '\'' { strings.write_string(&b, `'\''`) } else { strings.write_byte(&b, s[i]) }
	}
	strings.write_byte(&b, '\'')
	return strings.to_string(b)
}

// Command each hook runs (points at the generated script in `dir`).
claude_hook_command :: proc(dir: string, allocator := context.allocator) -> string {
	when ODIN_OS == .Windows {
		return fmt.aprintf(`powershell -NoProfile -ExecutionPolicy Bypass -File "%s/%s"`, dir, CLAUDE_HOOK_SCRIPT_PS, allocator = allocator)
	} else {
		script := fmt.tprintf("%s/%s", dir, CLAUDE_HOOK_SCRIPT_SH)
		return fmt.aprintf("sh %s", claude_sh_quote(script, context.temp_allocator), allocator = allocator)
	}
}

// The settings JSON passed with --settings: only the editor's hooks, one
// "command" per line (the fake-claude test greps it).
claude_settings_json :: proc(hook_cmd: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\n  \"hooks\": {\n")
	events := CLAUDE_HOOK_EVENTS
	for ev, i in events {
		matcher := `"matcher": "*", ` if ev == "PreToolUse" || ev == "PostToolUse" else ""
		// (no fmt here: Odin's fmt treats '{' as a format directive)
		strings.write_string(&b, "    \"")
		strings.write_string(&b, ev)
		strings.write_string(&b, "\": [{")
		strings.write_string(&b, matcher)
		strings.write_string(&b, "\"hooks\": [{\"type\": \"command\", \"timeout\": 10,\n      \"command\": ")
		_json_escape(&b, hook_cmd)
		strings.write_string(&b, "}]}]")
		strings.write_string(&b, ",\n" if i < len(events) - 1 else "\n")
	}
	strings.write_string(&b, "  }\n}\n")
	return strings.to_string(b)
}

// The hook script: copies the payload (stdin) atomically into
// $CUSTOM_EDITOR_CLAUDE_STATUS. Prints nothing (UserPromptSubmit stdout
// would be added to Claude's context) and always exits 0.
CLAUDE_HOOK_SCRIPT_SH_TEXT :: `#!/bin/sh
# Generated by custom_editor (Claude sessions, ADR 0015). Do not edit.
# Copies the Claude Code hook payload (stdin) into the session status file
# named by $` + CLAUDE_STATUS_ENV + `; a no-op outside editor-started sessions.
f="${` + CLAUDE_STATUS_ENV + `:-}"
if [ -z "$f" ]; then cat >/dev/null 2>&1; exit 0; fi
tmp="$f.$$.tmp"
if cat > "$tmp" 2>/dev/null; then mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp"; fi
exit 0
`

CLAUDE_HOOK_SCRIPT_PS_TEXT :: `# Generated by custom_editor (Claude sessions, ADR 0015). Do not edit.
$f = $env:` + CLAUDE_STATUS_ENV + `
$in = [Console]::In.ReadToEnd()
if ($f) {
  $tmp = "$f.$PID.tmp"
  try { [IO.File]::WriteAllText($tmp, $in); Move-Item -Force $tmp $f } catch {}
}
exit 0
`

claude_settings_path :: proc(dir: string, allocator := context.allocator) -> string {
	return fmt.aprintf("%s/%s", dir, CLAUDE_SETTINGS_FILE, allocator = allocator)
}

// Writes the settings file and hook script into cs.dir (overwritten every
// run so they always match this build). Returns false if it can't.
claude_sessions_prepare :: proc(cs: ^Claude_Sessions) -> bool {
	if cs.dir == "" { return false }
	if cs.prepared { return true }
	_ = os.make_directory_all(fmt.tprintf("%s/state", cs.dir))
	script := CLAUDE_HOOK_SCRIPT_PS_TEXT if ODIN_OS == .Windows else CLAUDE_HOOK_SCRIPT_SH_TEXT
	name := CLAUDE_HOOK_SCRIPT_PS if ODIN_OS == .Windows else CLAUDE_HOOK_SCRIPT_SH
	if os.write_entire_file(fmt.tprintf("%s/%s", cs.dir, name), transmute([]u8)string(script)) != nil { return false }
	cmd := claude_hook_command(cs.dir, context.temp_allocator)
	js := claude_settings_json(cmd, context.temp_allocator)
	if os.write_entire_file(claude_settings_path(cs.dir, context.temp_allocator), transmute([]u8)js) != nil { return false }
	cs.prepared = true
	return true
}

// argv that starts Claude Code with the editor's settings file. On Unix it
// goes through the user's login shell so `claude` is found on the PATH the
// user's profile sets up (a GUI app's PATH usually lacks ~/.local/bin).
claude_launch_argv :: proc(settings_path: string, allocator := context.allocator) -> []string {
	cmd := os.get_env(CLAUDE_CMD_ENV, context.temp_allocator)
	if cmd == "" { cmd = "claude" }
	when ODIN_OS == .Windows {
		// Separate arguments: the spawner quotes each one as needed. One
		// pre-quoted string got its inner quotes escaped as \" (which cmd.exe
		// doesn't understand), so claude received the path with literal quotes.
		out := make([]string, 5, allocator)
		out[0] = strings.clone("cmd.exe", allocator)
		out[1] = strings.clone("/c", allocator)
		out[2] = strings.clone(cmd, allocator)
		out[3] = strings.clone("--settings", allocator)
		out[4] = strings.clone(settings_path, allocator)
	} else {
		sh := os.get_env("SHELL", context.temp_allocator)
		if sh == "" { sh = "/bin/sh" }
		out := make([]string, 4, allocator)
		out[0] = strings.clone(sh, allocator)
		out[1] = strings.clone("-l", allocator)
		out[2] = strings.clone("-c", allocator)
		out[3] = fmt.aprintf("exec %s --settings %s", cmd, claude_sh_quote(settings_path, context.temp_allocator), allocator = allocator)
	}
	return out
}

// ---------------------------------------------------------------------------
// Registry: one session per repository root
// ---------------------------------------------------------------------------

claude_sessions_init :: proc(cs: ^Claude_Sessions, dir: string) {
	cs.dir = strings.clone(dir)
	cs.list = make([dynamic]^Claude_Session)
}

claude_sessions_destroy :: proc(cs: ^Claude_Sessions) {
	for s in cs.list { _claude_session_free(s) }
	delete(cs.list)
	delete(cs.dir)
	cs^ = {}
}

@(private="file")
_claude_session_free :: proc(s: ^Claude_Session) {
	if s.t != nil { term.destroy(s.t) }
	_ = os.remove(s.status_file)
	delete(s.id); delete(s.root); delete(s.name); delete(s.message)
	delete(s.claude_id); delete(s.status_file); delete(s.base_rev)
	for k in s.reviewed { delete(k) }
	delete(s.reviewed)
	free(s)
}

claude_sessions_find :: proc(cs: ^Claude_Sessions, root: string) -> ^Claude_Session {
	for s in cs.list { if s.root == root { return s } }
	return nil
}

// Session of `root`, started if there is none (or the old one exited).
// argv = nil → claude_launch_argv. created = a new process was started.
claude_sessions_get_or_start :: proc(cs: ^Claude_Sessions, root: string, argv: []string = nil, rows := 24, cols := 80) -> (s: ^Claude_Session, created: bool, err: string) {
	if root == "" { return nil, false, "No repository" }
	if old := claude_sessions_find(cs, root); old != nil {
		if !old.exited && !(old.t != nil && term.has_exited(old.t)) { return old, false, "" }
		claude_sessions_remove(cs, old)
	}
	if !claude_sessions_prepare(cs) { return nil, false, "Could not write the Claude hook files" }

	s = new(Claude_Session)
	s.id = fmt.aprintf("%d-%d", os.get_pid(), cs.next)
	cs.next += 1
	s.root = strings.clone(root)
	name := strings.trim_right(root, "/\\")
	if i := strings.last_index_any(name, "/\\"); i >= 0 { name = name[i + 1:] }
	s.name = strings.clone(name)
	s.status_file = fmt.aprintf("%s/state/%s.status", cs.dir, s.id)
	_ = os.remove(s.status_file)
	s.since = time.now()
	s.reviewed = make(map[string]bool)

	args := argv
	if args == nil { args = claude_launch_argv(claude_settings_path(cs.dir, context.temp_allocator), context.temp_allocator) }
	s.t = term.create(rows, cols)
	env := []string{fmt.tprintf("%s=%s", CLAUDE_STATUS_ENV, s.status_file)}
	if !term.start(s.t, {argv = args, cwd = root, env = env}) {
		_claude_session_free(s)
		return nil, false, "Could not start Claude Code"
	}
	append(&cs.list, s)
	return s, true, ""
}

// Kills (if running) and forgets the session.
claude_sessions_remove :: proc(cs: ^Claude_Sessions, s: ^Claude_Session) {
	for x, i in cs.list {
		if x == s { ordered_remove(&cs.list, i); break }
	}
	_claude_session_free(s)
}

// Number of sessions in each status (for the panel header).
claude_sessions_counts :: proc(cs: ^Claude_Sessions) -> (counts: [Claude_Status]int) {
	for s in cs.list { counts[s.status] += 1 }
	return
}

// ---------------------------------------------------------------------------
// OS notification command (run detached by claude_sessions.odin)
// ---------------------------------------------------------------------------

@(private="file")
_escape_quoted :: proc(s: string, q: byte, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for i in 0 ..< len(s) {
		ch := s[i]
		switch {
		case ch == '\n' || ch == '\r': strings.write_byte(&b, ' ')
		case q == '"' && (ch == '"' || ch == '\\'): strings.write_byte(&b, '\\'); strings.write_byte(&b, ch)
		case q == '\'' && ch == '\'': strings.write_string(&b, "''") // PowerShell
		case: strings.write_byte(&b, ch)
		}
	}
	return strings.to_string(b)
}

// argv of the desktop notification for this OS (no shell involved).
claude_notify_command :: proc(title, body: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	when ODIN_OS == .Darwin {
		script := fmt.tprintf(`display notification "%s" with title "%s"`,
			_escape_quoted(body, '"', context.temp_allocator), _escape_quoted(title, '"', context.temp_allocator))
		append(&out, strings.clone("osascript", allocator), strings.clone("-e", allocator), strings.clone(script, allocator))
	} else when ODIN_OS == .Windows {
		APP :: `{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe`
		ps := fmt.tprintf(
			`[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null; ` +
			`$t = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02); ` +
			`$x = $t.GetElementsByTagName('text'); $x.Item(0).AppendChild($t.CreateTextNode('%s')) > $null; ` +
			`$x.Item(1).AppendChild($t.CreateTextNode('%s')) > $null; ` +
			`[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('%s').Show([Windows.UI.Notifications.ToastNotification]::new($t))`,
			_escape_quoted(title, '\'', context.temp_allocator), _escape_quoted(body, '\'', context.temp_allocator), APP)
		append(&out, strings.clone("powershell", allocator), strings.clone("-NoProfile", allocator),
		       strings.clone("-WindowStyle", allocator), strings.clone("Hidden", allocator),
		       strings.clone("-Command", allocator), strings.clone(ps, allocator))
	} else {
		append(&out, strings.clone("notify-send", allocator), strings.clone("-a", allocator), strings.clone("custom_editor", allocator),
		       strings.clone(title, allocator), strings.clone(body, allocator))
	}
	return out[:]
}
