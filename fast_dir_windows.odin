#+build windows
package editor

import "core:strings"
import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

@(private="file") FIND_EX_INFO_BASIC         :: 1
@(private="file") FIND_EX_SEARCH_NAME_MATCH  :: 0
@(private="file") FIND_FIRST_EX_LARGE_FETCH  :: 2
@(private="file") FILE_ATTRIBUTE_REPARSE_POINT_ :: 0x400

@(private="file", default_calling_convention = "system")
foreign kernel32 {
	FindFirstFileExW :: proc(lpFileName: win.LPCWSTR, fInfoLevelId: i32, lpFindFileData: rawptr,
	                         fSearchOp: i32, lpSearchFilter: rawptr, dwAdditionalFlags: win.DWORD) -> win.HANDLE ---
}

// Lists `path` (no "." / ".."). A reparse point (symlink, junction) to a
// folder is reported as a folder with `link` set, so walks skip it.
fast_list_dir :: proc(path: string, out: ^[dynamic]Dir_Entry, allocator := context.allocator) -> bool {
	pattern := win.utf8_to_wstring(strings.concatenate({path, "\\*"}, context.temp_allocator), context.temp_allocator)
	fd: win.WIN32_FIND_DATAW
	h := FindFirstFileExW(pattern, FIND_EX_INFO_BASIC, &fd, FIND_EX_SEARCH_NAME_MATCH, nil, FIND_FIRST_EX_LARGE_FETCH)
	if h == win.INVALID_HANDLE_VALUE { return false }
	defer win.FindClose(h)
	for {
		n := 0
		for n < len(fd.cFileName) && fd.cFileName[n] != 0 { n += 1 }
		name, _ := win.utf16_to_utf8(fd.cFileName[:n], context.temp_allocator)
		if name != "." && name != ".." {
			attrs := fd.dwFileAttributes
			is_dir := attrs & win.FILE_ATTRIBUTE_DIRECTORY != 0
			link   := attrs & FILE_ATTRIBUTE_REPARSE_POINT_ != 0
			append(out, Dir_Entry{name = strings.clone(name, allocator), is_dir = is_dir, link = link})
		}
		if !win.FindNextFileW(h, &fd) { break }
	}
	return true
}
