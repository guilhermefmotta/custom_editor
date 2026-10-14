package git

// ===========================================================================
// Read-only git queries (log/graph, refs, remotes, stash, tags, reflog,
// submodules, blobs, conflict stages, repository state).
//
// These are the SYNCHRONOUS, worker-side implementations behind the
// git_request_* procs in queue.odin. Never call them from the UI thread
// (ADR 0001) — use the queue. They are also the building blocks for
// screen-specific work procs in `git/<tela>_ops*.odin`.
//
// Allocation: every git_query_* allocates its result (and the raw git output
// its strings point into) from `allocator`, which is expected to be an arena
// (the job arena when run through the queue). Results are not meant to be
// freed piece by piece.
//
// Parsing relies only on stable machine formats: `--format` with \x1f / NUL
// separators and `-z`, `for-each-ref --format`, `status --porcelain=v2 -z`,
// `config -z`. Errors are static strings ("" = success).
// ===========================================================================

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

Log_Options :: struct {
	rev:          string, // "" = every local branch, remote branch, tag and HEAD
	path:         string, // only commits touching this path (file history)
	grep:         string, // case-insensitive search in the commit message
	author:       string, // author name/e-mail pattern
	skip:         int,    // commits to skip (page offset)
	limit:        int,    // page size; <= 0 → 500
	first_parent: bool,
}

Ref_Kind :: enum u8 {
	Branch,        // refs/heads/*        name "main"
	Remote_Branch, // refs/remotes/*      name "origin/main"
	Tag,           // refs/tags/*         name "v1.0"
	Head,          // detached HEAD       name "HEAD"
}

Ref_Label :: struct {
	name:    string,
	kind:    Ref_Kind,
	is_head: bool, // the branch HEAD points to (or the detached HEAD label)
}

Commit :: struct {
	hash:         string,
	short_hash:   string,
	parents:      []string, // first parent first; empty for root commits
	author_name:  string,
	author_email: string,
	author_time:  i64, // unix seconds
	commit_time:  i64, // unix seconds
	subject:      string,
	refs:         []Ref_Label,
}

// One page of history in graph order (`--date-order`: parents always after
// their children). Feed pages in sequence to a lane assigner to draw the graph.
Log_Page :: struct {
	commits:  []Commit,
	skip:     int,  // offset this page starts at
	has_more: bool, // another page exists after this one
	head:     string, // HEAD hash ("" when unborn)
}

File_Change :: enum u8 {
	Modified,
	Added,
	Deleted,
	Renamed,
	Copied,
	Type_Changed,
	Unmerged,
	Unknown,
}

Commit_File :: struct {
	path:     string,
	old_path: string, // renames/copies; "" otherwise
	change:   File_Change,
}

Commit_Detail :: struct {
	commit:  Commit, // refs left empty
	message: string, // full message (subject + body)
	files:   []Commit_File, // vs. first parent; root commit: all added
}

Branch :: struct {
	name:          string, // short: "main", "origin/main"
	ref:           string, // full: "refs/heads/main"
	hash:          string,
	is_remote:     bool,
	is_head:       bool,
	remote:        string, // remote name for remote branches ("origin")
	upstream:      string, // short upstream of a local branch ("origin/main"), "" if none
	upstream_gone: bool,   // upstream configured but the ref no longer exists
	ahead:         int,    // commits in branch not in upstream
	behind:        int,    // commits in upstream not in branch
	subject:       string, // tip commit subject
	commit_time:   i64,
}

Remote :: struct {
	name:     string,
	url:      string,
	push_url: string, // "" when not set (pushes go to url)
}

Tag :: struct {
	name:      string,
	hash:      string, // commit (or object) the tag points to, peeled
	object:    string, // tag object hash for annotated tags, "" otherwise
	annotated: bool,
	message:   string, // annotation subject (annotated only)
	time:      i64,    // tagger date (annotated) or commit date
}

Stash :: struct {
	index:   int,
	ref:     string, // "stash@{0}"
	hash:    string,
	message: string, // "WIP on main: abc123 subject" / "On main: msg"
	time:    i64,
}

Reflog_Entry :: struct {
	index:    int,
	selector: string, // "HEAD@{3}"
	hash:     string,
	action:   string, // "commit", "checkout", "reset", "merge feat", ...
	message:  string, // text after "action: "
	time:     i64,
}

Submodule_State :: enum u8 {
	Up_To_Date,    // checked out at the recorded commit
	Uninitialized, // not checked out
	Modified,      // checked out at a different commit than recorded
	Conflict,      // merge conflict on the gitlink
}

Submodule :: struct {
	name:   string,
	path:   string,
	url:    string,
	branch: string,
	hash:   string, // checked-out commit (recorded commit when uninitialized)
	state:  Submodule_State,
}

File_Blob :: struct {
	present: bool, // false: path does not exist at that revision / stage
	binary:  bool,
	text:    string,
}

// Repository operation in progress. Compare the ENUM, never strings; when a
// string is needed (logs, config, tests) use repo_operation_name, whose values
// are stable lowercase identifiers.
Repo_Operation :: enum u8 {
	Clean,
	Merging,
	Rebasing,
	Cherry_Picking,
	Reverting,
	Bisecting,
	Conflicted, // unmerged index entries without an operation (e.g. stash pop)
}

repo_operation_name :: proc(op: Repo_Operation) -> string {
	switch op {
	case .Clean:          return "clean"
	case .Merging:        return "merging"
	case .Rebasing:       return "rebasing"
	case .Cherry_Picking: return "cherry-picking"
	case .Reverting:      return "reverting"
	case .Bisecting:      return "bisecting"
	case .Conflicted:     return "conflicted"
	}
	return "clean"
}

Repo_State :: struct {
	operation:      Repo_Operation,
	head_branch:    string, // "" when detached or unborn without a name
	head_hash:      string, // "" when unborn
	detached:       bool,
	unborn:         bool,   // no commits yet
	operation_head: string, // MERGE_HEAD / CHERRY_PICK_HEAD / REVERT_HEAD / REBASE_HEAD hash
	conflicts:      []string, // unmerged paths, relative to the repo root
	staged:         int,
	unstaged:       int,
	untracked:      int,
	git_dir:        string,
}

Conflict_Stages :: struct {
	path:         string,
	base:         File_Blob, // stage 1 (absent for add/add)
	ours:         File_Blob, // stage 2 (absent when deleted on our side)
	theirs:       File_Blob, // stage 3 (absent when deleted on their side)
	ours_label:   string,    // HEAD branch name or short hash
	theirs_label: string,    // incoming branch name or short hash
	operation:    Repo_Operation,
	binary:       bool,
}

// ---------------------------------------------------------------------------
// Log / commits
// ---------------------------------------------------------------------------

LOG_DEFAULT_LIMIT :: 500

@(private)
COMMIT_FORMAT :: "--format=%H%x1f%h%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%ct%x1f%s"

git_query_log :: proc(root: string, opts: Log_Options, allocator := context.allocator) -> (page: Log_Page, err: string) {
	context.allocator = allocator
	limit := opts.limit if opts.limit > 0 else LOG_DEFAULT_LIMIT
	skip  := max(opts.skip, 0)
	page.skip = skip

	head, head_ok := _rev_parse(root, "HEAD")
	if head_ok { page.head = head }
	if !head_ok && opts.rev == "" {
		// Unborn HEAD: still list other refs if any exist
		probe, _ := git_run(root, {"for-each-ref", "--count=1", "--format=%(refname)", "refs/heads", "refs/remotes", "refs/tags"})
		if strings.trim_space(probe) == "" { return page, "" }
	}

	args := make([dynamic]string, context.temp_allocator)
	append(&args, "log", "-z", "--date-order", COMMIT_FORMAT,
		fmt.tprintf("--skip=%d", skip), fmt.tprintf("--max-count=%d", limit + 1))
	if opts.first_parent { append(&args, "--first-parent") }
	if opts.grep != ""   { append(&args, "-i", fmt.tprintf("--grep=%s", opts.grep)) }
	if opts.author != "" { append(&args, fmt.tprintf("--author=%s", opts.author)) }
	if opts.rev != "" {
		append(&args, opts.rev)
	} else {
		append(&args, "--branches", "--remotes", "--tags")
		if head_ok { append(&args, "HEAD") }
	}
	append(&args, "--")
	if opts.path != "" { append(&args, opts.path) }

	out, ok := git_run(root, args[:])
	if !ok { return page, "git log failed" }

	refs := _ref_map(root, head if head_ok else "")

	commits := make([dynamic]Commit, 0, limit + 1)
	rest := out
	for rec in _next_field(&rest, 0) {
		r := strings.trim_left(rec, "\n")
		if r == "" { continue }
		c, cok := _parse_commit(r)
		if !cok { continue }
		if labels, has := refs[c.hash]; has { c.refs = labels[:] }
		append(&commits, c)
	}
	if len(commits) > limit {
		page.has_more = true
		resize(&commits, limit)
	}
	page.commits = commits[:]
	return page, ""
}

git_query_commit_detail :: proc(root, rev: string, allocator := context.allocator) -> (d: Commit_Detail, err: string) {
	context.allocator = allocator
	out, ok := git_run(root, {"log", "-1", "-z", COMMIT_FORMAT + "%x1f%B", rev, "--"})
	if !ok { return d, "unknown revision" }
	r := strings.trim_left(strings.trim_right(out, "\x00"), "\n")
	// The body is the 9th field: split it off before parsing the rest
	n := 0
	cut := -1
	for i in 0..<len(r) {
		if r[i] == 0x1f { n += 1; if n == 8 { cut = i; break } }
	}
	if cut < 0 { return d, "unexpected git log output" }
	c, cok := _parse_commit(r[:cut])
	if !cok { return d, "unexpected git log output" }
	d.commit  = c
	d.message = strings.trim_right(r[cut+1:], "\n")

	files, ferr := git_query_commit_files(root, c.hash, c.parents[0] if len(c.parents) > 0 else "")
	if ferr != "" { return d, ferr }
	d.files = files
	return d, ""
}

// Files changed in `hash` relative to `parent` ("" = root commit, all added).
git_query_commit_files :: proc(root, hash, parent: string, allocator := context.allocator) -> (files: []Commit_File, err: string) {
	context.allocator = allocator
	out: string
	ok: bool
	if parent != "" {
		out, ok = git_run(root, {"diff-tree", "-r", "-z", "-M", "--name-status", "--no-commit-id", parent, hash})
	} else {
		out, ok = git_run(root, {"diff-tree", "-r", "-z", "-M", "--name-status", "--no-commit-id", "--root", hash})
	}
	if !ok { return nil, "git diff-tree failed" }

	list := make([dynamic]Commit_File)
	rest := out
	for {
		status, more := _next_field(&rest, 0)
		if !more { break }
		if status == "" { continue }
		f: Commit_File
		switch status[0] {
		case 'M': f.change = .Modified
		case 'A': f.change = .Added
		case 'D': f.change = .Deleted
		case 'R': f.change = .Renamed
		case 'C': f.change = .Copied
		case 'T': f.change = .Type_Changed
		case 'U': f.change = .Unmerged
		case:     f.change = .Unknown
		}
		p1, _ := _next_field(&rest, 0)
		if f.change == .Renamed || f.change == .Copied {
			p2, _ := _next_field(&rest, 0)
			f.old_path = p1
			f.path     = p2
		} else {
			f.path = p1
		}
		append(&list, f)
	}
	return list[:], ""
}

// ---------------------------------------------------------------------------
// Branches / remotes / tags / stashes / reflog / submodules
// ---------------------------------------------------------------------------

git_query_branches :: proc(root: string, allocator := context.allocator) -> (branches: []Branch, err: string) {
	context.allocator = allocator
	out, ok := git_run(root, {
		"for-each-ref",
		"--format=%(refname)%00%(objectname)%00%(upstream)%00%(upstream:short)%00%(HEAD)%00%(committerdate:unix)%00%(contents:subject)",
		"refs/heads", "refs/remotes",
	})
	if !ok { return nil, "git for-each-ref failed" }

	list := make([dynamic]Branch)
	rest := out
	for line in _next_field(&rest, '\n') {
		f := strings.split(line, "\x00", context.temp_allocator)
		if len(f) < 7 { continue }
		b: Branch
		b.ref         = f[0]
		b.hash        = f[1]
		b.is_head     = f[4] == "*"
		b.commit_time = _parse_i64(f[5])
		b.subject     = f[6]
		if strings.has_prefix(b.ref, "refs/heads/") {
			b.name     = b.ref[len("refs/heads/"):]
			b.upstream = f[3]
			if f[2] != "" {
				counts, cok := git_run(root, {"rev-list", "--left-right", "--count", fmt.tprintf("%s...%s", b.ref, f[2]), "--"}, context.temp_allocator)
				if cok {
					cf := strings.fields(counts, context.temp_allocator)
					if len(cf) == 2 {
						b.ahead  = int(_parse_i64(cf[0]))
						b.behind = int(_parse_i64(cf[1]))
					}
				} else {
					b.upstream_gone = true
				}
			}
		} else {
			b.name      = b.ref[len("refs/remotes/"):]
			b.is_remote = true
			if strings.has_suffix(b.name, "/HEAD") { continue } // symbolic origin/HEAD
			if slash := strings.index_byte(b.name, '/'); slash > 0 { b.remote = b.name[:slash] }
		}
		append(&list, b)
	}
	return list[:], ""
}

git_query_remotes :: proc(root: string, allocator := context.allocator) -> (remotes: []Remote, err: string) {
	context.allocator = allocator
	out, code := git_run_raw(root, {"config", "-z", "--get-regexp", "^remote[.]"})
	if code == 1 { return nil, "" } // no remotes configured
	if code != 0 { return nil, "git config failed" }

	list := make([dynamic]Remote)
	rest := out
	for rec in _next_field(&rest, 0) {
		nl := strings.index_byte(rec, '\n')
		if nl < 0 { continue }
		key, value := rec[:nl], rec[nl+1:]
		dot := strings.last_index_byte(key, '.')
		if dot <= len("remote.") { continue }
		name, field := key[len("remote."):dot], key[dot+1:]
		if field != "url" && field != "pushurl" { continue }
		idx := -1
		for r, i in list { if r.name == name { idx = i; break } }
		if idx < 0 { append(&list, Remote{name = name}); idx = len(list) - 1 }
		if field == "url" { list[idx].url = value } else { list[idx].push_url = value }
	}
	return list[:], ""
}

git_query_tags :: proc(root: string, allocator := context.allocator) -> (tags: []Tag, err: string) {
	context.allocator = allocator
	out, ok := git_run(root, {
		"for-each-ref",
		"--format=%(refname:lstrip=2)%00%(objecttype)%00%(objectname)%00%(*objectname)%00%(creatordate:unix)%00%(contents:subject)",
		"refs/tags",
	})
	if !ok { return nil, "git for-each-ref failed" }

	list := make([dynamic]Tag)
	rest := out
	for line in _next_field(&rest, '\n') {
		f := strings.split(line, "\x00", context.temp_allocator)
		if len(f) < 6 { continue }
		t := Tag{name = f[0], time = _parse_i64(f[4])}
		if f[1] == "tag" {
			t.annotated = true
			t.object    = f[2]
			t.hash      = f[3] if f[3] != "" else f[2]
			t.message   = f[5]
		} else {
			t.hash = f[2]
		}
		append(&list, t)
	}
	return list[:], ""
}

git_query_stashes :: proc(root: string, allocator := context.allocator) -> (stashes: []Stash, err: string) {
	context.allocator = allocator
	out, ok := git_run(root, {"stash", "list", "-z", "--format=%gd%x1f%H%x1f%ct%x1f%gs"})
	if !ok { return nil, "git stash list failed" }

	list := make([dynamic]Stash)
	rest := out
	for rec in _next_field(&rest, 0) {
		r := strings.trim_left(rec, "\n")
		f := strings.split(r, "\x1f", context.temp_allocator)
		if len(f) < 4 { continue }
		s := Stash{ref = f[0], hash = f[1], time = _parse_i64(f[2]), message = f[3]}
		if o := strings.index_byte(s.ref, '{'); o >= 0 {
			s.index = int(_parse_i64(strings.trim_right(s.ref[o+1:], "}")))
		}
		append(&list, s)
	}
	return list[:], ""
}

REFLOG_DEFAULT_LIMIT :: 200

// Reflog of `ref` ("" = HEAD), newest first, starting at entry `skip`.
git_query_reflog :: proc(root: string, ref := "", skip := 0, limit := 0, allocator := context.allocator) -> (entries: []Reflog_Entry, err: string) {
	context.allocator = allocator
	ref := ref if ref != "" else "HEAD"
	limit := limit if limit > 0 else REFLOG_DEFAULT_LIMIT
	skip := skip if skip > 0 else 0
	// --date=unix turns %gd into "HEAD@{<unix time>}": the entry's own time
	out, code := git_run_raw(root, {"reflog", "show", "-z", "--date=unix", "--format=%H%x1f%gd%x1f%gs",
		fmt.tprintf("--skip=%d", skip), fmt.tprintf("--max-count=%d", limit), ref, "--"})
	// A ref without reflog (or unborn HEAD) is an empty list, not an error
	if code != 0 { return nil, "" }

	list := make([dynamic]Reflog_Entry)
	rest := out
	for rec in _next_field(&rest, 0) {
		r := strings.trim_left(rec, "\n")
		f := strings.split(r, "\x1f", context.temp_allocator)
		if len(f) < 3 { continue }
		e: Reflog_Entry
		e.index    = skip + len(list)
		e.hash     = f[0]
		e.selector = fmt.aprintf("%s@{{%d}}", ref, e.index)
		if o := strings.index_byte(f[1], '{'); o >= 0 {
			e.time = _parse_i64(strings.trim_right(f[1][o+1:], "}"))
		}
		if c := strings.index(f[2], ": "); c >= 0 {
			e.action  = f[2][:c]
			e.message = f[2][c+2:]
		} else {
			e.action = f[2]
		}
		append(&list, e)
	}
	return list[:], ""
}

git_query_submodules :: proc(root: string, allocator := context.allocator) -> (subs: []Submodule, err: string) {
	context.allocator = allocator
	cfg, code := git_run_raw(root, {"config", "-z", "-f", ".gitmodules", "--get-regexp", "^submodule[.]"})
	if code != 0 { return nil, "" } // no .gitmodules → no submodules

	list := make([dynamic]Submodule)
	rest := cfg
	for rec in _next_field(&rest, 0) {
		nl := strings.index_byte(rec, '\n')
		if nl < 0 { continue }
		key, value := rec[:nl], rec[nl+1:]
		dot := strings.last_index_byte(key, '.')
		if dot <= len("submodule.") { continue }
		name, field := key[len("submodule."):dot], key[dot+1:]
		idx := -1
		for s, i in list { if s.name == name { idx = i; break } }
		if idx < 0 { append(&list, Submodule{name = name, state = .Uninitialized}); idx = len(list) - 1 }
		switch field {
		case "path":   list[idx].path = value
		case "url":    list[idx].url = value
		case "branch": list[idx].branch = value
		}
	}

	if st, ok := git_run(root, {"submodule", "status"}); ok {
		srest := st
		for line in _next_field(&srest, '\n') {
			if len(line) < 3 { continue }
			flag := line[0]
			body := line[1:]
			sp := strings.index_byte(body, ' ')
			if sp < 0 { continue }
			hash, path := body[:sp], body[sp+1:]
			for &s in list {
				if s.path == "" { continue }
				if path != s.path && !strings.has_prefix(path, strings.concatenate({s.path, " ("}, context.temp_allocator)) { continue }
				s.hash = hash
				switch flag {
				case '-': s.state = .Uninitialized
				case '+': s.state = .Modified
				case 'U': s.state = .Conflict
				case:     s.state = .Up_To_Date
				}
			}
		}
	}
	return list[:], ""
}

// ---------------------------------------------------------------------------
// Blobs and conflicts
// ---------------------------------------------------------------------------

// Content of `path` (relative to the repo root) at `rev`. present=false when
// the revision exists but the path doesn't; err when the revision is unknown.
git_query_file_at :: proc(root, rev, path: string, allocator := context.allocator) -> (blob: File_Blob, err: string) {
	context.allocator = allocator
	blob = _read_blob(root, fmt.tprintf("%s:%s", rev, path))
	if !blob.present {
		if _, ok := _rev_parse(root, strings.concatenate({rev, "^{commit}"}, context.temp_allocator)); !ok {
			return blob, "unknown revision"
		}
	}
	return blob, ""
}

git_query_conflict :: proc(root, path: string, allocator := context.allocator) -> (c: Conflict_Stages, err: string) {
	context.allocator = allocator
	c.path   = strings.clone(path)
	c.base   = _read_blob(root, fmt.tprintf(":1:%s", path))
	c.ours   = _read_blob(root, fmt.tprintf(":2:%s", path))
	c.theirs = _read_blob(root, fmt.tprintf(":3:%s", path))
	if !c.base.present && !c.ours.present && !c.theirs.present {
		return c, "path is not in conflict"
	}
	c.binary = c.base.binary || c.ours.binary || c.theirs.binary

	st, serr := git_query_repo_state(root)
	if serr == "" {
		c.operation = st.operation
		if st.head_branch != "" {
			c.ours_label = st.head_branch
		} else {
			c.ours_label = _short(st.head_hash)
		}
		if st.operation_head != "" {
			c.theirs_label = _short(st.operation_head)
			if name, ok := git_run(root, {"name-rev", "--name-only", "--no-undefined",
				"--refs=refs/heads/*", "--refs=refs/remotes/*", st.operation_head}); ok {
				if n := strings.trim_space(name); n != "" { c.theirs_label = n }
			}
		}
	}
	if c.ours_label == ""   { c.ours_label = "ours" }
	if c.theirs_label == "" { c.theirs_label = "theirs" }
	return c, ""
}

// ---------------------------------------------------------------------------
// Repository state
// ---------------------------------------------------------------------------

git_query_repo_state :: proc(root: string, allocator := context.allocator) -> (s: Repo_State, err: string) {
	context.allocator = allocator
	gd, gok := git_run(root, {"rev-parse", "--absolute-git-dir"})
	if !gok { return s, "not a git repository" }
	s.git_dir = strings.trim_space(gd)

	out, ok := git_run(root, {"status", "--porcelain=v2", "-z", "--branch"})
	if !ok { return s, "git status failed" }

	conflicts := make([dynamic]string)
	rest := out
	for {
		rec, more := _next_field(&rest, 0)
		if !more { break }
		if len(rec) < 2 { continue }
		switch rec[0] {
		case '#':
			if strings.has_prefix(rec, "# branch.oid ") {
				v := rec[len("# branch.oid "):]
				if v == "(initial)" { s.unborn = true } else { s.head_hash = v }
			} else if strings.has_prefix(rec, "# branch.head ") {
				v := rec[len("# branch.head "):]
				if v == "(detached)" { s.detached = true } else { s.head_branch = v }
			}
		case '1', '2':
			if len(rec) > 3 {
				if rec[2] != '.' { s.staged += 1 }
				if rec[3] != '.' { s.unstaged += 1 }
			}
			if rec[0] == '2' { _next_field(&rest, 0) } // original path
		case 'u':
			if p, pok := _field_after(rec, 10); pok { append(&conflicts, p) }
		case '?':
			s.untracked += 1
		}
	}
	s.conflicts = conflicts[:]

	exists :: proc(dir, name: string) -> bool {
		return os.exists(strings.concatenate({dir, "/", name}, context.temp_allocator))
	}
	head_file :: proc(dir, name: string) -> string {
		data, rerr := os.read_entire_file(strings.concatenate({dir, "/", name}, context.temp_allocator), context.allocator)
		if rerr != nil { return "" }
		text := strings.trim_space(string(data))
		if nl := strings.index_byte(text, '\n'); nl >= 0 { text = strings.trim_space(text[:nl]) }
		return text
	}

	switch {
	case exists(s.git_dir, "rebase-merge") || exists(s.git_dir, "rebase-apply"):
		s.operation      = .Rebasing
		s.operation_head = head_file(s.git_dir, "REBASE_HEAD")
	case exists(s.git_dir, "MERGE_HEAD"):
		s.operation      = .Merging
		s.operation_head = head_file(s.git_dir, "MERGE_HEAD")
	case exists(s.git_dir, "CHERRY_PICK_HEAD"):
		s.operation      = .Cherry_Picking
		s.operation_head = head_file(s.git_dir, "CHERRY_PICK_HEAD")
	case exists(s.git_dir, "REVERT_HEAD"):
		s.operation      = .Reverting
		s.operation_head = head_file(s.git_dir, "REVERT_HEAD")
	case exists(s.git_dir, "BISECT_LOG"):
		s.operation = .Bisecting
	case len(s.conflicts) > 0:
		s.operation = .Conflicted
	case:
		s.operation = .Clean
	}
	return s, ""
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

// Iterator over `s` split by `sep`, consuming it; skips nothing, but a
// trailing separator does not yield an empty last field.
@(private)
_next_field :: proc(s: ^string, sep: byte) -> (field: string, ok: bool) {
	if len(s^) == 0 { return "", false }
	i := strings.index_byte(s^, sep)
	if i < 0 {
		field = s^
		s^ = ""
	} else {
		field = s[:i]
		s^ = s[i+1:]
	}
	return field, true
}

// The text after the n-th space of `rec` (paths may contain spaces).
@(private)
_field_after :: proc(rec: string, n: int) -> (string, bool) {
	count := 0
	for i in 0..<len(rec) {
		if rec[i] == ' ' {
			count += 1
			if count == n { return rec[i+1:], true }
		}
	}
	return "", false
}

@(private)
_parse_commit :: proc(rec: string) -> (c: Commit, ok: bool) {
	f := strings.split(rec, "\x1f", context.temp_allocator)
	if len(f) < 8 { return c, false }
	c.hash         = f[0]
	c.short_hash   = f[1]
	c.parents      = strings.fields(f[2]) if f[2] != "" else nil
	c.author_name  = f[3]
	c.author_email = f[4]
	c.author_time  = _parse_i64(f[5])
	c.commit_time  = _parse_i64(f[6])
	c.subject      = f[7]
	return c, true
}

// hash → labels for every branch, remote branch and tag (tags peeled to the
// commit), plus a "HEAD" label when HEAD is detached.
@(private)
_ref_map :: proc(root, head: string) -> map[string][dynamic]Ref_Label {
	refs := make(map[string][dynamic]Ref_Label)
	out, ok := git_run(root, {"for-each-ref", "--format=%(objectname)%00%(*objectname)%00%(refname)%00%(HEAD)",
		"refs/heads", "refs/remotes", "refs/tags"})
	if !ok { return refs }
	head_on_branch := false
	rest := out
	for line in _next_field(&rest, '\n') {
		f := strings.split(line, "\x00", context.temp_allocator)
		if len(f) < 4 { continue }
		hash := f[1] if f[1] != "" else f[0]
		l: Ref_Label
		switch {
		case strings.has_prefix(f[2], "refs/heads/"):
			l = {name = f[2][len("refs/heads/"):], kind = .Branch, is_head = f[3] == "*"}
			if l.is_head { head_on_branch = true }
		case strings.has_prefix(f[2], "refs/remotes/"):
			l = {name = f[2][len("refs/remotes/"):], kind = .Remote_Branch}
			if strings.has_suffix(l.name, "/HEAD") { continue }
		case strings.has_prefix(f[2], "refs/tags/"):
			l = {name = f[2][len("refs/tags/"):], kind = .Tag}
		case:
			continue
		}
		_add_label(&refs, hash, l)
	}
	if head != "" && !head_on_branch {
		_add_label(&refs, head, Ref_Label{name = "HEAD", kind = .Head, is_head = true})
	}
	return refs
}

@(private)
_add_label :: proc(refs: ^map[string][dynamic]Ref_Label, hash: string, l: Ref_Label) {
	if hash not_in refs { refs[hash] = make([dynamic]Ref_Label, 0, 2) }
	append(&refs[hash], l)
}

@(private)
_rev_parse :: proc(root, rev: string) -> (hash: string, ok: bool) {
	out, rok := git_run(root, {"rev-parse", "-q", "--verify", rev})
	if !rok { return "", false }
	return strings.trim_space(out), true
}

@(private)
_read_blob :: proc(root, spec: string) -> File_Blob {
	out, ok := git_run(root, {"cat-file", "blob", spec})
	if !ok { return {} }
	return File_Blob{present = true, binary = _looks_binary(out), text = out}
}

@(private)
_short :: proc(hash: string) -> string {
	return hash[:min(len(hash), 7)]
}

@(private)
_parse_i64 :: proc(s: string) -> i64 {
	v, _ := strconv.parse_i64(strings.trim_space(s))
	return v
}
