package git

// git_run_raw returns heap-owned stdout AND exit code regardless of success.
// Caller must always delete(output).
git_run_raw :: proc(root: string, args: []string, allocator := context.allocator) -> (output: string, exit_code: int) {
	return _exec(root, args, allocator)
}

// git_run executes `git -C root <args>` and returns heap-owned stdout.
// ok=false on non-zero exit. Caller must delete(output) when ok=true.
git_run :: proc(root: string, args: []string, allocator := context.allocator) -> (output: string, ok: bool) {
	out, code := _exec(root, args, allocator)
	if code != 0 { delete(out, allocator); return "", false }
	return out, true
}
