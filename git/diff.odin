package git

import "core:os"
import "core:strconv"
import "core:strings"

// ---------------------------------------------------------------------------
// Whole-file side-by-side diff
//
// The diff carries the entire file (git diff with unlimited context), laid out
// as rows of (old, new) so the view can show every line with the changed ones
// highlighted, instead of only the changed hunks.
// ---------------------------------------------------------------------------

Diff_Kind :: enum u8 {
	Context, // same line on both sides
	Add,     // only in the new file
	Delete,  // only in the old file
	Empty,   // filler opposite an Add/Delete so both columns stay aligned
}

Diff_Side :: struct {
	text: string, // slice into File_Diff.raw (not separately allocated)
	line: int,    // 1-based line number in its file; 0 for Empty
	kind: Diff_Kind,
}

Diff_Row :: struct {
	left:  Diff_Side, // old version (HEAD)
	right: Diff_Side, // new version (index + working tree)
}

File_Diff :: struct {
	rows:    [dynamic]Diff_Row,
	raw:     string, // owns the text the rows point into
	binary:  bool,
	changed: [dynamic]int, // row index where each run of changed rows starts
}

file_diff_destroy :: proc(fd: ^File_Diff) {
	delete(fd.rows)
	delete(fd.changed)
	delete(fd.raw)
	fd^ = {}
}

// Diff of rel_path against HEAD covering the whole file: staged and unstaged
// changes together, new (untracked/added) files as all-added, deleted files as
// all-deleted.
git_diff_file_full :: proc(m: ^Git_Manager, rel_path: string) -> File_Diff {
	// Practically unlimited context: git emits one hunk spanning the file
	FULL :: "-U2147483647"

	if out, ok := git_run(m.root, {"diff", FULL, "HEAD", "--", rel_path}); ok && out != "" {
		return parse_unified_diff(out)
	} else if ok {
		delete(out)
	}

	// Not in HEAD (untracked, or new repo without commits): whole file is new
	abs := strings.concatenate({m.root, "/", rel_path}, context.temp_allocator)
	if data, rerr := os.read_entire_file(abs, context.allocator); rerr == nil {
		return file_diff_all_added(string(data))
	}
	return {}
}

// Every line of `text` as an addition (file with no previous version).
file_diff_all_added :: proc(text: string) -> File_Diff {
	fd := File_Diff{raw = text}
	if _looks_binary(text) { fd.binary = true; return fd }
	rest := text
	n := 0
	for line in strings.split_lines_iterator(&rest) {
		n += 1
		append(&fd.rows, Diff_Row{
			left  = {kind = .Empty},
			right = {text = strings.trim_right(line, "\r"), line = n, kind = .Add},
		})
	}
	if n > 0 { append(&fd.changed, 0) }
	return fd
}

// Parses `git diff` unified output into side-by-side rows. Takes ownership of
// `raw`. Runs of deletions followed by additions are paired line by line
// (modified lines sit next to each other); the shorter side is padded with
// Empty rows.
parse_unified_diff :: proc(raw: string) -> File_Diff {
	fd := File_Diff{raw = raw}
	if strings.contains(raw, "\nBinary files ") || strings.has_prefix(raw, "Binary files ") {
		fd.binary = true
		return fd
	}

	old_ln, new_ln := 0, 0
	in_hunk := false
	dels := make([dynamic]Diff_Side, context.temp_allocator)
	adds := make([dynamic]Diff_Side, context.temp_allocator)

	flush :: proc(fd: ^File_Diff, dels, adds: ^[dynamic]Diff_Side) {
		n := max(len(dels), len(adds))
		if n == 0 { return }
		append(&fd.changed, len(fd.rows))
		for i in 0..<n {
			row: Diff_Row
			row.left  = dels[i] if i < len(dels) else Diff_Side{kind = .Empty}
			row.right = adds[i] if i < len(adds) else Diff_Side{kind = .Empty}
			append(&fd.rows, row)
		}
		clear(dels)
		clear(adds)
	}

	rest := raw
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_right(line, "\r")
		if strings.has_prefix(l, "@@") {
			flush(&fd, &dels, &adds)
			old_ln, new_ln = _parse_hunk_header(l)
			in_hunk = true
			continue
		}
		// File headers before the first hunk; git never emits a bare empty line
		// inside a hunk (empty context lines are " "), only the trailing one
		if !in_hunk || len(l) == 0 { continue }
		body := l[1:]
		switch l[0] {
		case ' ':
			flush(&fd, &dels, &adds)
			append(&fd.rows, Diff_Row{
				left  = {text = body, line = old_ln, kind = .Context},
				right = {text = body, line = new_ln, kind = .Context},
			})
			old_ln += 1; new_ln += 1
		case '-':
			// Additions come after deletions within a change; a new deletion
			// after additions starts a new change
			if len(adds) > 0 { flush(&fd, &dels, &adds) }
			append(&dels, Diff_Side{text = body, line = old_ln, kind = .Delete})
			old_ln += 1
		case '+':
			append(&adds, Diff_Side{text = body, line = new_ln, kind = .Add})
			new_ln += 1
		case '\\':
			// "\ No newline at end of file"
		}
	}
	flush(&fd, &dels, &adds)
	return fd
}

// "@@ -12,7 +12,12 @@ ..." → (12, 12)
@(private)
_parse_hunk_header :: proc(h: string) -> (old_start, new_start: int) {
	parts := strings.fields(h, context.temp_allocator)
	if len(parts) < 3 { return 1, 1 }
	start :: proc(s: string) -> int {
		s := s[1:] // drop '-' / '+'
		if i := strings.index_byte(s, ','); i >= 0 { s = s[:i] }
		n, _ := strconv.parse_int(s)
		return max(n, 1)
	}
	return start(parts[1]), start(parts[2])
}

@(private)
_looks_binary :: proc(text: string) -> bool {
	n := min(len(text), 8000)
	return strings.index_byte(text[:n], 0) >= 0
}
