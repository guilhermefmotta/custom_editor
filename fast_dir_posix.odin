#+build linux, darwin, freebsd, openbsd, netbsd
package editor

import "core:strings"
import "core:sys/posix"

// Lists `path` (no "." / ".."). Entries whose type the file system does not
// report (DT_UNKNOWN) or symlinks fall back to one stat each.
fast_list_dir :: proc(path: string, out: ^[dynamic]Dir_Entry, allocator := context.allocator) -> bool {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	d := posix.opendir(cpath)
	if d == nil { return false }
	defer posix.closedir(d)
	for {
		ent := posix.readdir(d)
		if ent == nil { break }
		name := string(cstring(raw_data(ent.d_name[:])))
		if name == "." || name == ".." { continue }
		is_dir, link: bool
		#partial switch ent.d_type {
		case .DIR: is_dir = true
		case .REG: is_dir = false
		case:
			link = ent.d_type == .LNK
			st: posix.stat_t
			if posix.fstatat(posix.dirfd(d), cstring(raw_data(ent.d_name[:])), &st, {}) == .OK {
				is_dir = posix.S_ISDIR(st.st_mode)
			}
		}
		append(out, Dir_Entry{name = strings.clone(name, allocator), is_dir = is_dir, link = link})
	}
	return true
}
