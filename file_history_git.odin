package editor

// ===========================================================================
// File history + blame — git side (ticket #10, ADR 0004).
//
// Everything here runs on the git queue worker (Git_Work_Proc enqueued with
// git.git_request_custom); the UI thread only polls the results. Inside a work
// proc context.allocator is the job arena, so nothing is freed piece by piece.
//
//   fh_request_history(q, rel_path)        (Fh_History)  `git log --follow`
//   fh_request_blame(q, rel_path, content) (Fh_Blame)    blame of the buffer
//
// Pure helpers (no raylib, tested in file_history_test.odin):
//   fh_parse_history, fh_parse_blame, fh_relative_time, fh_blame_color_slots
// ===========================================================================

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import git "./git"

FH_ZERO_HASH :: "0000000000000000000000000000000000000000"

// One commit that touched the file. `path` is the file's name in that commit
// (history follows renames); `old_path` is set when the commit renamed/copied
// it — pass both to git_request_commit_file_diff.
Fh_Commit :: struct {
	hash:       string,
	short_hash: string,
	author:     string,
	email:      string,
	time:       i64, // author time, unix seconds
	subject:    string,
	path:       string,
	old_path:   string,
	status:     u8, // 'M', 'A', 'D', 'R', 'C', ... (0 = not reported, e.g. merges)
}

Fh_History :: struct {
	commits: []Fh_Commit, // newest first
}

// One line of the blamed buffer. committed=false: the line is not in any
// commit (edited/new in the buffer, or the file is untracked) — no author.
Fh_Blame_Line :: struct {
	committed:  bool,
	hash:       string,
	short_hash: string,
	author:     string,
	time:       i64,
	summary:    string, // commit subject (tooltip)
	text:       string, // line content
}

Fh_Blame :: struct {
	lines:   []Fh_Blame_Line,
	tracked: bool, // false: git doesn't know the file (all lines uncommitted)
}

// ---------------------------------------------------------------------------
// Requests (UI thread)
// ---------------------------------------------------------------------------

fh_request_history :: proc(q: ^git.Git_Queue, rel_path: string) -> git.Job_Id {
	return git.git_request_custom(q, fh_history_work, {rel_path})
}

// content: the buffer text to blame (lines not in HEAD come back uncommitted).
// has_content=false blames the file on disk instead.
fh_request_blame :: proc(q: ^git.Git_Queue, rel_path, content: string, has_content: bool) -> git.Job_Id {
	return git.git_request_custom(q, fh_blame_work, {rel_path, content, "1" if has_content else "0"})
}

// ---------------------------------------------------------------------------
// Work procs (worker thread)
// ---------------------------------------------------------------------------

@(private="file")
FH_LOG_FORMAT :: "--format=%x1e%H%x1f%h%x1f%an%x1f%ae%x1f%at%x1f%s"

// args = {rel_path}
fh_history_work :: proc(root: string, args: []string, user: rawptr) -> (git.Git_Payload, string) {
	if len(args) < 1 { return nil, "missing path" }
	h, c := git.git_custom_new(Fh_History)
	// HEAD unborn → git log fails: no history, not an error
	out, ok := git.git_run(root, {"log", "--follow", "-z", "-M", "--name-status", FH_LOG_FORMAT, "HEAD", "--", args[0]})
	if ok { h.commits = fh_parse_history(out, args[0]) }
	return c, ""
}

// args = {rel_path, content, "1" | "0"}
fh_blame_work :: proc(root: string, args: []string, user: rawptr) -> (git.Git_Payload, string) {
	if len(args) < 3 { return nil, "missing arguments" }
	rel, content := args[0], args[1]
	has_content := args[2] == "1"

	if !has_content {
		data, err := os.read_entire_file(fmt.tprintf("%s/%s", root, rel), context.allocator)
		if err != nil { return nil, "cannot read file" }
		content = string(data)
	}

	// `git blame --contents -` would need stdin, which git_run (popen "r")
	// can't feed: the buffer goes through a temp file instead (ADR 0004).
	tmp_path := ""
	if has_content {
		f, ferr := os.create_temp_file("", "editor-blame-*.tmp")
		if ferr == nil {
			tmp_path = strings.clone(os.name(f))
			_, werr := os.write(f, transmute([]u8)content)
			os.close(f)
			if werr != nil { _ = os.remove(tmp_path); tmp_path = "" }
		}
	}
	defer if tmp_path != "" { _ = os.remove(tmp_path) }

	out: string
	ok: bool
	if tmp_path != "" {
		out, ok = git.git_run(root, {"blame", "--porcelain", "--contents", tmp_path, "--", rel})
	} else {
		out, ok = git.git_run(root, {"blame", "--porcelain", "--", rel})
	}

	b, c := git.git_custom_new(Fh_Blame)
	b.tracked = ok
	b.lines = fh_parse_blame(out if ok else "", content)
	return c, ""
}

// ---------------------------------------------------------------------------
// Parsing (pure)
// ---------------------------------------------------------------------------

// Parses `git log --follow -z --name-status FH_LOG_FORMAT -- path`: records
// start with \x1e; the header fields are \x1f-separated and end at a NUL,
// followed by "\n<status>\0<path>\0[<new path>\0]". Walking newest → oldest,
// a rename switches the tracked name to the old one for older commits.
fh_parse_history :: proc(out: string, path: string, allocator := context.allocator) -> []Fh_Commit {
	context.allocator = allocator
	list := make([dynamic]Fh_Commit)
	cur := path
	recs := strings.split(out, "\x1e", context.temp_allocator)
	for rec in recs {
		if strings.trim_space(rec) == "" { continue }
		header := rec
		rest := ""
		if z := strings.index_byte(rec, 0); z >= 0 { header = rec[:z]; rest = rec[z+1:] }
		f := strings.split(header, "\x1f", context.temp_allocator)
		if len(f) < 6 { continue }
		c := Fh_Commit{
			hash = f[0], short_hash = f[1], author = f[2], email = f[3], subject = f[5],
		}
		c.time, _ = strconv.parse_i64(f[4])

		rest = strings.trim_left(rest, "\n")
		fields := strings.split(rest, "\x00", context.temp_allocator)
		if len(fields) >= 2 && fields[0] != "" {
			c.status = fields[0][0]
			if (c.status == 'R' || c.status == 'C') && len(fields) >= 3 {
				c.old_path = fields[1]
				c.path = fields[2]
				cur = fields[1] // older commits know the file by its old name
			} else {
				c.path = fields[1]
				cur = fields[1]
			}
		} else {
			c.path = cur
		}
		append(&list, c)
	}
	return list[:]
}

// Splits text into lines ("a\nb\n" → 2 lines, "" → 0 lines, CR stripped).
fh_split_lines :: proc(text: string, allocator := context.allocator) -> []string {
	if text == "" { return make([]string, 0, allocator) }
	t := strings.trim_suffix(text, "\n")
	lines := strings.split(t, "\n", allocator)
	for &l in lines { l = strings.trim_suffix(l, "\r") }
	return lines
}

// Applies `git blame --porcelain` output to the lines of `content`. Lines the
// output doesn't cover, and lines blamed on the zero hash (not committed),
// come back with committed=false and no author.
fh_parse_blame :: proc(out: string, content: string, allocator := context.allocator) -> []Fh_Blame_Line {
	context.allocator = allocator
	texts := fh_split_lines(content)
	lines := make([]Fh_Blame_Line, len(texts))
	for t, i in texts { lines[i].text = t }

	Info :: struct { author: string, time: i64, summary: string }
	cache := make(map[string]Info, context.temp_allocator)

	s := out
	for len(s) > 0 {
		header: string
		if nl := strings.index_byte(s, '\n'); nl >= 0 { header = s[:nl]; s = s[nl+1:] } else { header = s; s = "" }
		parts := strings.fields(header, context.temp_allocator)
		if len(parts) < 3 || len(parts[0]) != 40 { continue }
		hash := parts[0]
		final_line, fok := strconv.parse_int(parts[2])
		if !fok { continue }

		info := cache[hash]
		for len(s) > 0 {
			line: string
			if nl := strings.index_byte(s, '\n'); nl >= 0 { line = s[:nl]; s = s[nl+1:] } else { line = s; s = "" }
			if len(line) > 0 && line[0] == '\t' { break } // content line ends the block
			switch {
			case strings.has_prefix(line, "author "):      info.author = line[len("author "):]
			case strings.has_prefix(line, "author-time "): info.time, _ = strconv.parse_i64(line[len("author-time "):])
			case strings.has_prefix(line, "summary "):     info.summary = line[len("summary "):]
			}
		}
		cache[hash] = info

		i := final_line - 1
		if i < 0 || i >= len(lines) { continue }
		if hash == FH_ZERO_HASH { continue }
		l := &lines[i]
		l.committed  = true
		l.hash       = hash
		l.short_hash = hash[:8]
		l.author     = info.author
		l.time       = info.time
		l.summary    = info.summary
	}
	return lines
}

// "just now", "5 minutes ago", "3 days ago", "2 years ago" (temp-allocated).
fh_relative_time :: proc(now, t: i64) -> string {
	d := now - t
	if d < 0 { d = 0 }
	unit :: proc(n: i64, name: string) -> string {
		return fmt.tprintf("%d %s%s ago", n, name, "" if n == 1 else "s")
	}
	switch {
	case d < 60:           return "just now"
	case d < 3600:         return unit(d / 60, "minute")
	case d < 86400:        return unit(d / 3600, "hour")
	case d < 30 * 86400:   return unit(d / 86400, "day")
	case d < 365 * 86400:  return unit(d / (30 * 86400), "month")
	}
	return unit(d / (365 * 86400), "year")
}

FH_BLAME_COLORS :: 8

// Color slot per line: commits get slots in order of first appearance
// (cycling through FH_BLAME_COLORS); uncommitted lines get -1.
fh_blame_color_slots :: proc(lines: []Fh_Blame_Line, allocator := context.allocator) -> []int {
	slots := make([]int, len(lines), allocator)
	seen := make(map[string]int, context.temp_allocator)
	next := 0
	for l, i in lines {
		if !l.committed { slots[i] = -1; continue }
		s, ok := seen[l.hash]
		if !ok { s = next % FH_BLAME_COLORS; seen[l.hash] = s; next += 1 }
		slots[i] = s
	}
	return slots
}
