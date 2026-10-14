#+build windows
package git

// Windows: no live progress (the output arrives at the end); the chunk
// callback still sees the whole output once.
@(private)
_repo_exec_stream :: proc(root: string, args: []string, env: [][2]string, on_chunk: proc(user: rawptr, chunk: []u8), user: rawptr, allocator := context.allocator) -> (output: string, exit_code: int) {
	out, code := _remote_exec(root, args, env, allocator)
	if on_chunk != nil && len(out) > 0 { on_chunk(user, transmute([]u8)out) }
	return out, code
}
