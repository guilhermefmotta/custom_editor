package editor

// ripgrep shipped inside the editor binary (ADR 0017). The release build
// downloads a pinned ripgrep for its target into bundled/ (see
// scripts/fetch-ripgrep.sh and .github/workflows/release.yml) and #load
// embeds it; on the first text search it is written once to the user cache
// folder, under a name carrying its hash, and run from there. A build
// without bundled/rg (local dev) embeds nothing and search_fast.odin falls
// back to an installed rg, then to the built-in engine.
//
// ripgrep is MIT / Unlicense; its license ships with the release archive.

import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"

when ODIN_OS == .Windows {
	when #exists("bundled/rg.exe") { RG_EMBEDDED :: #load("bundled/rg.exe") } else { RG_EMBEDDED :: []u8{} }
	@(private="file") RG_FILE_EXT :: ".exe"
} else {
	when #exists("bundled/rg") { RG_EMBEDDED :: #load("bundled/rg") } else { RG_EMBEDDED :: []u8{} }
	@(private="file") RG_FILE_EXT :: ""
}

// Path of the embedded ripgrep, written to the cache folder if needed.
// Heap string, "" when this build embeds none or it cannot be written.
ripgrep_extract_embedded :: proc() -> string {
	if len(RG_EMBEDDED) == 0 { return "" }
	cache, err := os.user_cache_dir(context.temp_allocator)
	if err != nil || cache == "" { return "" }
	dir, _ := filepath.join({cache, "custom_editor"}, context.temp_allocator)
	name := fmt.tprintf("rg-%x%s", hash.fnv64a(RG_EMBEDDED), RG_FILE_EXT)
	path, _ := filepath.join({dir, name}, context.allocator)

	if fi, serr := os.stat(path, context.temp_allocator); serr == nil && fi.size == i64(len(RG_EMBEDDED)) {
		return path // extracted by an earlier run (the name pins the content)
	}
	if os.make_directory_all(dir) != nil { delete(path); return "" }
	// Write next to it and rename: a concurrent editor never runs half a file
	tmp := fmt.tprintf("%s.%d.tmp", path, os.get_pid())
	if os.write_entire_file(tmp, RG_EMBEDDED) != nil { delete(path); return "" }
	when ODIN_OS != .Windows {
		_ = os.chmod(tmp, {.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other})
	}
	if os.rename(tmp, path) != nil {
		_ = os.remove(tmp)
		if !os.exists(path) { delete(path); return "" }
	}
	return path
}
