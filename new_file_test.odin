package editor

// Tests for New File by name (Ctrl/Cmd+N prompt and file tree Ctrl+N).

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_create_new_path :: proc(t: ^testing.T) {
	base := os.get_env("TMPDIR", context.temp_allocator)
	if base == "" { base = "/tmp" }
	dir := fmt.tprintf("%s/editor-new-file-%d", strings.trim_right(base, "/\\"), os.get_pid())
	_ = os.remove_all(dir)
	_ = os.make_directory(dir)
	defer os.remove_all(dir)

	f := fmt.tprintf("%s/a.txt", dir)
	testing.expect_value(t, create_new_path(f), New_Path_Result.Created_File)
	testing.expect(t, os.exists(f))
	testing.expect_value(t, create_new_path(f), New_Path_Result.Exists)

	nested := fmt.tprintf("%s/src/util/str.odin", dir)
	testing.expect_value(t, create_new_path(nested), New_Path_Result.Created_File)
	testing.expect(t, os.exists(nested))

	d := fmt.tprintf("%s/docs/img/", dir)
	testing.expect_value(t, create_new_path(d), New_Path_Result.Created_Dir)
	testing.expect(t, os.is_dir(fmt.tprintf("%s/docs/img", dir)))
	testing.expect_value(t, create_new_path(d), New_Path_Result.Invalid)
	testing.expect_value(t, create_new_path(fmt.tprintf("%s/src", dir)), New_Path_Result.Invalid)
	testing.expect_value(t, create_new_path("   "), New_Path_Result.Invalid)
}

@(test)
test_new_file_prefill :: proc(t: ^testing.T) {
	testing.expect_value(t, new_file_prefill("/w/src/ui/a.odin", "/w"), "src/ui/")
	testing.expect_value(t, new_file_prefill("/w/main.odin", "/w"), "")
	testing.expect_value(t, new_file_prefill("/other/x.go", "/w"), "")
	testing.expect_value(t, new_file_prefill("", "/w"), "")
}
