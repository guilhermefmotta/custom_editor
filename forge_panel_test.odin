package editor

// Pure helpers of forge_panel.odin (features/forge.feature). The forge
// package itself is covered by `odin test ./forge`.

import "core:testing"
import "core:strings"
import forge "./forge"

@(test)
test_forge_diff_line_kind :: proc(t: ^testing.T) {
	testing.expect_value(t, forge_diff_line_kind("diff --git a/x b/x"), 4)
	testing.expect_value(t, forge_diff_line_kind("--- a/x"), 4)
	testing.expect_value(t, forge_diff_line_kind("+++ b/x"), 4)
	testing.expect_value(t, forge_diff_line_kind("@@ -1 +1 @@ proc"), 3)
	testing.expect_value(t, forge_diff_line_kind("+added"), 1)
	testing.expect_value(t, forge_diff_line_kind("-removed"), 2)
	testing.expect_value(t, forge_diff_line_kind(" context"), 0)
}

@(test)
test_forge_wrap :: proc(t: ^testing.T) {
	out: [dynamic]string
	defer delete(out)
	forge_wrap("the quick brown fox jumps over the lazy dog", 10, &out)
	testing.expect_value(t, len(out), 5)
	testing.expect_value(t, out[0], "the quick")
	testing.expect_value(t, out[4], "dog")
	clear(&out)
	forge_wrap("ááááááááááááá", 10, &out) // no spaces: hard cut on rune boundary
	testing.expect_value(t, len(out), 2)
	testing.expect_value(t, out[0], "áááááááááá")
}

@(test)
test_forge_labels_show_status :: proc(t: ^testing.T) {
	pr := forge.Pull_Request{number = 42, title = "Add forge", author = "alice", source_branch = "f", target_branch = "main", checks = .Failure, draft = true}
	l := forge_pr_label(pr)
	defer delete(l)
	testing.expect(t, strings.has_prefix(l, "[x failed   ] #42 (draft) Add forge"), l)
	testing.expect(t, strings.contains(l, "f -> main"), l)
	j := forge_job_label(forge.Job{name = "build", stage = "ci", status = .Running, duration = 125})
	defer delete(j)
	testing.expect_value(t, j, "[* running ] ci / build  (2m05s)")
	free_all(context.temp_allocator)
}
