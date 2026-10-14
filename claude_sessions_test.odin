package editor

// Feature: features/claude-sessions.feature (ticket #17). Never runs the real
// `claude`: sessions use a fake script that fires the hooks through the
// command written in the generated settings file. Nothing under ~/.claude
// (nor ~/.config/editor) is touched: every test uses its own temp dir.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import term "terminal"

@(private="file")
_cst_tmp :: proc(name: string) -> string {
	base: string
	when ODIN_OS == .Windows {
		base = os.get_env("TEMP", context.temp_allocator)
	} else {
		base = os.get_env("TMPDIR", context.temp_allocator)
		if base == "" { base = "/tmp" }
	}
	base = strings.trim_right(base, "/\\")
	dir := fmt.aprintf("%s/editor-claude-%s-%d", base, name, os.get_pid())
	_ = os.remove_all(dir)
	_ = os.make_directory_all(dir)
	return dir
}

@(private="file")
_cst_free_dir :: proc(dir: string) { _ = os.remove_all(dir); delete(dir) }

// # teste: test_cs_parse_hook_payload
@(test)
test_cs_parse_hook_payload :: proc(t: ^testing.T) {
	n := `{"session_id":"s-1","transcript_path":"/x.jsonl","cwd":"/repo","hook_event_name":"Notification",` +
	     `"notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}`
	p, ok := claude_parse_hook_payload(n)
	testing.expect(t, ok)
	testing.expect_value(t, p.hook_event_name, "Notification")
	testing.expect_value(t, p.session_id, "s-1")
	testing.expect_value(t, p.cwd, "/repo")
	testing.expect_value(t, p.notification_type, "permission_prompt")
	testing.expect_value(t, p.message, "Claude needs your permission to use Bash")
	st, sok := claude_event_status(p)
	testing.expect(t, sok)
	testing.expect_value(t, st, Claude_Status.Waiting)
	claude_hook_payload_destroy(&p)

	// Nested objects / arrays / numbers we don't model are skipped.
	pre := `{"session_id":"s-1","hook_event_name":"PreToolUse","tool_name":"Bash",` +
	       `"tool_input":{"command":"ls","timeout":120000,"run_in_background":false},"extra":[1,2,{"a":null}]}` + "\n"
	p, ok = claude_parse_hook_payload(pre)
	testing.expect(t, ok)
	testing.expect_value(t, p.tool_name, "Bash")
	st, sok = claude_event_status(p)
	testing.expect(t, sok && st == .Working)
	claude_hook_payload_destroy(&p)

	cases := []struct { js: string, ok: bool, st: Claude_Status }{
		{`{"hook_event_name":"UserPromptSubmit","prompt":"hi"}`, true, .Working},
		{`{"hook_event_name":"PostToolUse","tool_name":"Edit"}`, true, .Working},
		{`{"hook_event_name":"Stop","stop_hook_active":false}`, true, .Stopped},
		{`{"hook_event_name":"SessionEnd","reason":"prompt_input_exit"}`, true, .Stopped},
		{`{"hook_event_name":"SessionStart","source":"startup"}`, true, .Stopped},
		{`{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"waiting"}`, true, .Waiting},
		{`{"hook_event_name":"Notification","notification_type":"auth_success"}`, false, .Stopped},
		{`{"hook_event_name":"SubagentStop"}`, false, .Stopped},
	}
	for c in cases {
		pp, pok := claude_parse_hook_payload(c.js)
		testing.expectf(t, pok, "parse %s", c.js)
		s2, k := claude_event_status(pp)
		testing.expectf(t, k == c.ok && (!k || s2 == c.st), "%s → %v %v", c.js, s2, k)
		claude_hook_payload_destroy(&pp)
	}

	_, bad := claude_parse_hook_payload("not json")
	testing.expect(t, !bad)
	_, empty := claude_parse_hook_payload("  ")
	testing.expect(t, !empty)
	_, noev := claude_parse_hook_payload(`{"session_id":"x"}`)
	testing.expect(t, !noev)
}

// # teste: test_cs_status_machine
@(test)
test_cs_status_machine :: proc(t: ^testing.T) {
	s: Claude_Session
	defer { delete(s.message); delete(s.claude_id) }
	ev :: proc(s: ^Claude_Session, js: string) -> bool {
		p, _ := claude_parse_hook_payload(js, context.temp_allocator)
		return claude_session_apply(s, p)
	}
	testing.expect_value(t, s.status, Claude_Status.Stopped)
	testing.expect(t, !ev(&s, `{"session_id":"c1","hook_event_name":"UserPromptSubmit"}`))
	testing.expect_value(t, s.status, Claude_Status.Working)
	testing.expect_value(t, s.claude_id, "c1")
	// working → waiting: notify once
	testing.expect(t, ev(&s, `{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"Allow Bash?"}`))
	testing.expect_value(t, s.status, Claude_Status.Waiting)
	testing.expect_value(t, s.message, "Allow Bash?")
	testing.expect(t, !ev(&s, `{"hook_event_name":"Notification","notification_type":"idle_prompt"}`))
	// informational notification changes nothing
	testing.expect(t, !ev(&s, `{"hook_event_name":"Notification","notification_type":"auth_success"}`))
	testing.expect_value(t, s.status, Claude_Status.Waiting)
	// waiting → working (permission granted, tool ran) → stopped
	testing.expect(t, !ev(&s, `{"hook_event_name":"PostToolUse","tool_name":"Bash"}`))
	testing.expect_value(t, s.status, Claude_Status.Working)
	testing.expect(t, !ev(&s, `{"hook_event_name":"Stop"}`))
	testing.expect_value(t, s.status, Claude_Status.Stopped)
	// stopped → waiting (idle reminder) notifies again
	testing.expect(t, ev(&s, `{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"Claude is waiting for your input"}`))
	// process exit → stopped for good
	claude_session_mark_exited(&s)
	testing.expect(t, s.exited)
	testing.expect_value(t, s.status, Claude_Status.Stopped)

	_, changed, notify := claude_status_step(.Waiting, .Waiting)
	testing.expect(t, !changed && !notify)
	_, changed, notify = claude_status_step(.Stopped, .Waiting)
	testing.expect(t, changed && notify)
}

// # teste: test_cs_settings_only_editor_hooks
@(test)
test_cs_settings_only_editor_hooks :: proc(t: ^testing.T) {
	dir := _cst_tmp("settings")
	defer _cst_free_dir(dir)
	cs: Claude_Sessions
	claude_sessions_init(&cs, dir)
	defer claude_sessions_destroy(&cs)
	testing.expect(t, claude_sessions_prepare(&cs))

	data, err := os.read_entire_file(claude_settings_path(dir, context.temp_allocator), context.temp_allocator)
	testing.expect(t, err == nil)
	v, jerr := json.parse(data, allocator = context.temp_allocator)
	testing.expect(t, jerr == nil)
	root, is_obj := v.(json.Object)
	testing.expect(t, is_obj)
	testing.expect_value(t, len(root), 1) // only "hooks": nothing else of the user's config is overridden
	hooks, hok := root["hooks"].(json.Object)
	testing.expect(t, hok)

	want_cmd := claude_hook_command(dir, context.temp_allocator)
	events := CLAUDE_HOOK_EVENTS
	testing.expect_value(t, len(hooks), len(events))
	for ev in events {
		groups, gok := hooks[ev].(json.Array)
		testing.expectf(t, gok && len(groups) == 1, "event %s", ev)
		if !gok || len(groups) != 1 { continue }
		hs := groups[0].(json.Object)["hooks"].(json.Array)
		testing.expect_value(t, len(hs), 1)
		h := hs[0].(json.Object)
		testing.expect_value(t, h["type"].(json.String), "command")
		testing.expect_value(t, h["command"].(json.String), want_cmd)
	}
	testing.expect(t, "SubagentStop" not_in hooks) // the user's own hooks stay in the user's settings
	// The command points at the generated script, which exists.
	script := fmt.tprintf("%s/%s", dir, CLAUDE_HOOK_SCRIPT_PS if ODIN_OS == .Windows else CLAUDE_HOOK_SCRIPT_SH)
	testing.expect(t, strings.contains(want_cmd, script))
	testing.expect(t, os.exists(script))
	when ODIN_OS != .Windows {
		testing.expect_value(t, want_cmd, fmt.tprintf("sh '%s'", script))
		// launch argv: login shell → exec claude --settings '<file>'
		argv := claude_launch_argv(claude_settings_path(dir, context.temp_allocator), context.temp_allocator)
		testing.expect_value(t, len(argv), 4)
		testing.expect(t, strings.has_suffix(argv[3], fmt.tprintf("--settings '%s/%s'", dir, CLAUDE_SETTINGS_FILE)))
	}
}

// # teste: test_cs_notify_command
@(test)
test_cs_notify_command :: proc(t: ^testing.T) {
	argv := claude_notify_command(`Claude: api`, `Allow "rm"?` + "\nnow", context.temp_allocator)
	when ODIN_OS == .Darwin {
		testing.expect_value(t, len(argv), 3)
		testing.expect_value(t, argv[0], "osascript")
		testing.expect_value(t, argv[2], `display notification "Allow \"rm\"? now" with title "Claude: api"`)
	} else when ODIN_OS == .Linux {
		testing.expect_value(t, argv[0], "notify-send")
		testing.expect_value(t, argv[len(argv) - 2], "Claude: api")
	} else when ODIN_OS == .Windows {
		testing.expect_value(t, argv[0], "powershell")
	}
}

when ODIN_OS != .Windows {

// # teste: test_cs_start_one_session_per_repo
@(test)
test_cs_start_one_session_per_repo :: proc(t: ^testing.T) {
	dir := _cst_tmp("one")
	defer _cst_free_dir(dir)
	a := fmt.tprintf("%s/api", dir)
	w := fmt.tprintf("%s/web", dir)
	_ = os.make_directory_all(a)
	_ = os.make_directory_all(w)
	cs: Claude_Sessions
	claude_sessions_init(&cs, fmt.tprintf("%s/state-dir", dir))
	defer claude_sessions_destroy(&cs)

	fake := []string{"/bin/sh", "-c", "pwd; echo \"$" + CLAUDE_STATUS_ENV + "\"; sleep 30"}
	s1, c1, e1 := claude_sessions_get_or_start(&cs, a, fake)
	testing.expectf(t, s1 != nil && c1, "start: %s", e1)
	s1b, c1b, _ := claude_sessions_get_or_start(&cs, a, fake)
	testing.expect(t, s1b == s1 && !c1b) // reused
	s2, c2, _ := claude_sessions_get_or_start(&cs, w, fake)
	testing.expect(t, s2 != nil && c2 && s2 != s1)
	testing.expect_value(t, len(cs.list), 2)
	testing.expect(t, claude_sessions_find(&cs, a) == s1)
	testing.expect_value(t, s2.name, "web")
	testing.expect(t, s1.status_file != s2.status_file)

	// The process runs in the repo root with the status-file variable set.
	snap: term.Snapshot
	defer term.snapshot_destroy(&snap)
	deadline := time.tick_now()
	text := ""
	for time.duration_seconds(time.tick_since(deadline)) < 5 {
		term.snapshot(s1.t, &snap)
		text, _ = strings.replace_all(term.snapshot_text(&snap, context.temp_allocator), "\n", "", context.temp_allocator)
		if strings.contains(text, s1.status_file) { break }
		time.sleep(20 * time.Millisecond)
	}
	testing.expectf(t, strings.contains(text, "/api") && strings.contains(text, s1.status_file), "screen: %q", text)

	_, _, err := claude_sessions_get_or_start(&cs, "", fake)
	testing.expect(t, err != "")

	claude_sessions_remove(&cs, s1)
	testing.expect_value(t, len(cs.list), 1)
	testing.expect(t, claude_sessions_find(&cs, a) == nil)
}

// A fake `claude`: reads the hook command out of the generated settings file
// and fires hooks through it, one per line the test types into the PTY.
@(private="file")
FAKE_CLAUDE :: `#!/bin/sh
[ "$1" = "--settings" ] || { echo "no --settings"; exit 2; }
cmd=$(grep '"command": ' "$2" | head -n 1 | sed 's/^ *"command": "//; s/"}]}],*$//')
hook() { printf '%s' "$1" | eval "$cmd"; }
echo "fake claude ready"
read x; hook '{"session_id":"fake-1","hook_event_name":"UserPromptSubmit","prompt":"hi"}'
read x; hook '{"session_id":"fake-1","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
read x; hook '{"session_id":"fake-1","hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}'
read x; hook '{"session_id":"fake-1","hook_event_name":"PostToolUse","tool_name":"Bash"}'
read x; hook '{"session_id":"fake-1","hook_event_name":"Stop"}'
read x; exit 0
`

// # teste: test_cs_fake_claude_drives_status
@(test)
test_cs_fake_claude_drives_status :: proc(t: ^testing.T) {
	dir := _cst_tmp("fake")
	defer _cst_free_dir(dir)
	repo := fmt.tprintf("%s/repo", dir)
	_ = os.make_directory_all(repo)
	fake_path := fmt.tprintf("%s/fake-claude.sh", dir)
	_ = os.write_entire_file(fake_path, transmute([]u8)string(FAKE_CLAUDE))

	cs: Claude_Sessions
	claude_sessions_init(&cs, fmt.tprintf("%s/state-dir", dir))
	defer claude_sessions_destroy(&cs)
	testing.expect(t, claude_sessions_prepare(&cs))
	argv := []string{"/bin/sh", fake_path, "--settings", claude_settings_path(cs.dir, context.temp_allocator)}
	s, created, err := claude_sessions_get_or_start(&cs, repo, argv)
	testing.expectf(t, s != nil && created, "start: %s", err)
	if s == nil { return }

	wait_status :: proc(s: ^Claude_Session, want: Claude_Status, exited := false) -> (notified: bool, ok: bool) {
		start := time.tick_now()
		for time.duration_seconds(time.tick_since(start)) < 5 {
			_, n := claude_session_poll(s)
			notified ||= n
			if s.status == want && s.exited == exited { return notified, true }
			time.sleep(10 * time.Millisecond)
		}
		return notified, false
	}
	wait_text :: proc(s: ^Claude_Session, needle: string) -> bool {
		snap: term.Snapshot
		defer term.snapshot_destroy(&snap)
		start := time.tick_now()
		for time.duration_seconds(time.tick_since(start)) < 5 {
			term.snapshot(s.t, &snap)
			if strings.contains(term.snapshot_text(&snap, context.temp_allocator), needle) { return true }
			time.sleep(10 * time.Millisecond)
		}
		return false
	}
	testing.expect(t, wait_text(s, "fake claude ready"))

	steps := []struct { st: Claude_Status, notify: bool }{
		{.Working, false}, // UserPromptSubmit
		{.Working, false}, // PreToolUse
		{.Waiting, true},  // Notification (permission)
		{.Working, false}, // PostToolUse
		{.Stopped, false}, // Stop
	}
	for step, i in steps {
		before, before_t := s.file_size, s.file_mtime
		term.send_bytes(s.t, {'\r'})
		// Wait for the hook to rewrite the status file, then for the status.
		notified := false
		start := time.tick_now()
		for time.duration_seconds(time.tick_since(start)) < 5 {
			_, n := claude_session_poll(s)
			notified ||= n
			if s.file_size != before || s.file_mtime != before_t { break }
			time.sleep(10 * time.Millisecond)
		}
		n, ok := wait_status(s, step.st)
		notified ||= n
		if !ok {
			snap: term.Snapshot
			term.snapshot(s.t, &snap)
			testing.expectf(t, ok, "step %d: status %v, want %v; screen %q", i, s.status, step.st, term.snapshot_text(&snap, context.temp_allocator))
			term.snapshot_destroy(&snap)
			return
		}
		testing.expectf(t, notified == step.notify, "step %d: notify %v", i, notified)
		if i == 2 {
			testing.expect_value(t, s.message, "Claude needs your permission to use Bash")
		}
	}
	testing.expect_value(t, s.claude_id, "fake-1")
	// Fake exits → stopped + exited.
	term.send_bytes(s.t, {'\r'})
	_, ok := wait_status(s, .Stopped, exited = true)
	testing.expect(t, ok)

	// The status file lives in the editor's dir, never in the repo.
	entries, _ := os.read_all_directory_by_path(repo, context.temp_allocator)
	testing.expect_value(t, len(entries), 0)
}

} // ODIN_OS != .Windows
