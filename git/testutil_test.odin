package git

// Helpers for tests that drive a real, temporary git repository.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// Fresh empty repo (branch "main", local identity, no signing) in a unique
// temp dir. Caller: defer _trepo_destroy(dir).
_trepo_new :: proc(t: ^testing.T, name: string) -> string {
	base: string
	when ODIN_OS == .Windows {
		base = os.get_env("TEMP", context.temp_allocator)
	} else {
		base = os.get_env("TMPDIR", context.temp_allocator)
		if base == "" { base = "/tmp" }
	}
	base = strings.trim_right(base, "/\\")
	dir := fmt.aprintf("%s/editor-gitq-%s-%d", base, name, os.get_pid())
	_ = os.remove_all(dir)
	_ = os.make_directory(dir)
	_tgit(t, dir, "init", "-q", "-b", "main")
	_tgit(t, dir, "config", "user.email", "tester@example.com")
	_tgit(t, dir, "config", "user.name", "Tester")
	_tgit(t, dir, "config", "commit.gpgsign", "false")
	_tgit(t, dir, "config", "tag.gpgsign", "false")
	_tgit(t, dir, "config", "core.autocrlf", "false")
	return dir
}

_trepo_destroy :: proc(dir: string) {
	_ = os.remove_all(dir)
	delete(dir)
}

// Runs git in dir; fails the test on non-zero exit.
_tgit :: proc(t: ^testing.T, dir: string, args: ..string, loc := #caller_location) {
	out, ok := git_run(dir, args)
	delete(out)
	testing.expectf(t, ok, "git %v failed", args, loc = loc)
}

// Runs git and returns (exit ok) without failing the test.
_tgit_try :: proc(dir: string, args: ..string) -> bool {
	out, ok := git_run(dir, args)
	delete(out)
	return ok
}

// Trimmed stdout of a git command (temp-allocated).
_tgit_out :: proc(dir: string, args: ..string) -> string {
	out, ok := git_run(dir, args, context.temp_allocator)
	if !ok { return "" }
	return strings.trim_space(out)
}

_twrite :: proc(dir, rel, content: string) {
	_ = os.write_entire_file(fmt.tprintf("%s/%s", dir, rel), transmute([]u8)content)
}

// Writes a file, stages everything and commits; returns the new HEAD hash
// (temp-allocated).
_tcommit :: proc(t: ^testing.T, dir, rel, content, msg: string, loc := #caller_location) -> string {
	if rel != "" { _twrite(dir, rel, content) }
	_tgit(t, dir, "add", "-A", loc = loc)
	_tgit(t, dir, "commit", "-q", "--allow-empty", "-m", msg, loc = loc)
	return _tgit_out(dir, "rev-parse", "HEAD")
}

// Blocks (test only!) until the job finishes; 20 s timeout.
_twait :: proc(t: ^testing.T, q: ^Git_Queue, id: Job_Id, loc := #caller_location) -> Job_Status {
	deadline := time.tick_now()
	for {
		_, st := git_poll(q, id)
		if st == .Done || st == .Failed || st == .Unknown { return st }
		if time.tick_since(deadline) > 20 * time.Second {
			testing.fail_now(t, "timeout waiting for git job", loc)
		}
		time.sleep(time.Millisecond)
	}
}

// Waits for `id` and returns its payload as ^T (nil + test failure otherwise).
_tget :: proc(t: ^testing.T, q: ^Git_Queue, id: Job_Id, $T: typeid, loc := #caller_location) -> ^T {
	_twait(t, q, id, loc)
	v, st, err := git_poll_as(q, id, T)
	testing.expectf(t, st == .Done, "job %v: status %v err %q", id, st, err, loc = loc)
	return v
}
