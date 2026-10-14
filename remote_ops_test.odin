package editor

import "core:testing"
import "git"

// teste: test_remote_ops_pull_conflict (lado da UI: abre o merge_resolver)
@(test)
test_remote_ops_outcome :: proc(t: ^testing.T) {
	conflicts := []string{"f.txt"}

	k, open := remote_ops_outcome({ok = true})
	testing.expect(t, k == .Success && !open)

	k, open = remote_ops_outcome({ok = false, kind = .Conflict, has_state = true,
		state = {operation = .Merging, conflicts = conflicts}})
	testing.expect(t, k == .Warning && open)

	k, open = remote_ops_outcome({ok = false, kind = .Conflict, has_state = true,
		state = {operation = .Rebasing, conflicts = conflicts}})
	testing.expect(t, open)

	// stash pop with conflicts leaves unmerged paths without an operation
	k, open = remote_ops_outcome({ok = false, kind = .Conflict, has_state = true,
		state = {operation = .Conflicted, conflicts = conflicts}})
	testing.expect(t, open)

	k, open = remote_ops_outcome({ok = false, kind = .Rejected})
	testing.expect(t, k == .Error && !open)
	k, open = remote_ops_outcome({ok = false, kind = .Auth})
	testing.expect(t, k == .Error && !open)
	k, open = remote_ops_outcome({ok = false, kind = .Nothing_To_Stash})
	testing.expect(t, k == .Info && !open)
	_ = git.Remote_Op.Push
}
