package git

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
_has_ref :: proc(c: Commit, name: string, kind: Ref_Kind) -> (Ref_Label, bool) {
	for r in c.refs { if r.name == name && r.kind == kind { return r, true } }
	return {}, false
}

// History: root ─ feat(f1,f2) ─┐
//              └─ m1 ──────── merge ─ 20 linear commits (HEAD = main)
@(test)
test_log_paginated_with_parents_and_refs :: proc(t: ^testing.T) {
	dir := _trepo_new(t, "log")
	defer _trepo_destroy(dir)
	root_hash := _tcommit(t, dir, "f.txt", "base\n", "root commit")
	_tgit(t, dir, "tag", "lw")
	_tgit(t, dir, "update-ref", "refs/remotes/origin/main", root_hash)
	_tgit(t, dir, "checkout", "-q", "-b", "feat")
	_tcommit(t, dir, "feat.txt", "1\n", "feat one")
	_tcommit(t, dir, "feat.txt", "2\n", "feat two")
	_tgit(t, dir, "checkout", "-q", "main")
	_tcommit(t, dir, "main.txt", "m\n", "main one")
	_tgit(t, dir, "merge", "-q", "--no-ff", "--no-edit", "feat")
	merge_hash := strings.clone(_tgit_out(dir, "rev-parse", "HEAD"))
	defer delete(merge_hash)
	_tgit(t, dir, "tag", "-a", "v1", "-m", "release one")
	for i in 0..<20 { _tcommit(t, dir, "n.txt", fmt.tprintf("%d\n", i), fmt.tprintf("linear %d", i)) }
	head := strings.clone(_tgit_out(dir, "rev-parse", "HEAD"))
	defer delete(head)

	q: Git_Queue
	git_queue_init(&q, dir)
	defer git_queue_destroy(&q)

	// Page through 25 commits, 10 at a time
	seen := make(map[string]int) // hash → global position
	defer delete(seen)
	all := make([dynamic]Commit)
	defer delete(all)
	ids: [dynamic]Job_Id
	defer delete(ids)
	more := true
	for skip := 0; more; skip += 10 {
		id := git_request_log(&q, {skip = skip, limit = 10})
		append(&ids, id)
		page := _tget(t, &q, id, Log_Page)
		if page == nil { return }
		testing.expect_value(t, page.skip, skip)
		testing.expect_value(t, page.head, head)
		for c in page.commits { seen[c.hash] = len(all); append(&all, c) }
		more = page.has_more
		testing.expect(t, len(page.commits) == 10 || !more)
	}
	defer for id in ids { git_release(&q, id) } // `all` points into the results
	testing.expect_value(t, len(all), 25)
	testing.expect_value(t, len(seen), 25)

	// Graph order: every parent appears after its child
	for c, i in all {
		for p in c.parents {
			pos, ok := seen[p]
			testing.expectf(t, ok && pos > i, "parent %s of %s out of order", p, c.subject)
		}
	}

	// Fields and refs
	first := all[0]
	testing.expect_value(t, first.hash, head)
	testing.expect_value(t, first.subject, "linear 19")
	testing.expect_value(t, first.author_name, "Tester")
	testing.expect_value(t, first.author_email, "tester@example.com")
	testing.expect(t, first.author_time > 0 && first.commit_time > 0)
	testing.expect(t, strings.has_prefix(first.hash, first.short_hash) && len(first.short_hash) >= 7)
	main_ref, has_main := _has_ref(first, "main", .Branch)
	testing.expect(t, has_main && main_ref.is_head)

	merge := all[seen[merge_hash]]
	testing.expect_value(t, len(merge.parents), 2)
	_, has_v1 := _has_ref(merge, "v1", .Tag) // annotated tag peeled to the commit
	testing.expect(t, has_v1)

	rootc := all[seen[root_hash]]
	testing.expect_value(t, len(rootc.parents), 0)
	_, has_lw := _has_ref(rootc, "lw", .Tag)
	_, has_origin := _has_ref(rootc, "origin/main", .Remote_Branch)
	testing.expect(t, has_lw && has_origin)
	feat_tip := all[seen[merge.parents[1]]]
	feat_ref, has_feat := _has_ref(feat_tip, "feat", .Branch)
	testing.expect(t, has_feat && !feat_ref.is_head)

	// Detached HEAD gets its own label
	_tgit(t, dir, "checkout", "-q", "--detach", merge_hash)
	did := git_request_log(&q, {limit = 50})
	defer git_release(&q, did)
	if dpage := _tget(t, &q, did, Log_Page); dpage != nil {
		testing.expect_value(t, dpage.head, merge_hash)
		for c in dpage.commits {
			if c.hash != merge_hash { continue }
			hl, has_head := _has_ref(c, "HEAD", .Head)
			testing.expect(t, has_head && hl.is_head)
		}
	}
}

// Filters used by branch search and file history screens.
@(test)
test_log_search_and_file_history :: proc(t: ^testing.T) {
	dir := _trepo_new(t, "logsearch")
	defer _trepo_destroy(dir)
	_tcommit(t, dir, "a.txt", "1\n", "Add A")
	_tcommit(t, dir, "b.txt", "1\n", "add B")
	_tgit(t, dir, "checkout", "-q", "-b", "feat")
	_tcommit(t, dir, "a.txt", "2\n", "change a on FEAT")
	_tgit(t, dir, "checkout", "-q", "main")
	_tcommit(t, dir, "b.txt", "2\n", "change b")

	q: Git_Queue
	git_queue_init(&q, dir)
	defer git_queue_destroy(&q)

	subjects :: proc(p: ^Log_Page) -> string {
		sb := strings.builder_make(context.temp_allocator)
		for c, i in p.commits {
			if i > 0 { strings.write_string(&sb, "|") }
			strings.write_string(&sb, c.subject)
		}
		return strings.to_string(sb)
	}

	// Message search over all refs, case-insensitive
	id1 := git_request_log(&q, {grep = "feat"})
	defer git_release(&q, id1)
	if p := _tget(t, &q, id1, Log_Page); p != nil {
		testing.expect_value(t, subjects(p), "change a on FEAT")
	}
	// File history (across all branches)
	id2 := git_request_log(&q, {path = "a.txt"})
	defer git_release(&q, id2)
	if p := _tget(t, &q, id2, Log_Page); p != nil {
		testing.expect_value(t, subjects(p), "change a on FEAT|Add A")
	}
	// Single branch, with search
	id3 := git_request_log(&q, {rev = "main", grep = "add"})
	defer git_release(&q, id3)
	if p := _tget(t, &q, id3, Log_Page); p != nil {
		testing.expect_value(t, subjects(p), "add B|Add A")
		testing.expect(t, !p.has_more)
	}
	// Unknown revision fails
	id4 := git_request_log(&q, {rev = "nope"})
	defer git_release(&q, id4)
	testing.expect_value(t, _twait(t, &q, id4), Job_Status.Failed)

	// Unborn repository → empty page, not an error
	empty := _trepo_new(t, "logempty")
	defer _trepo_destroy(empty)
	eq: Git_Queue
	git_queue_init(&eq, empty)
	defer git_queue_destroy(&eq)
	id5 := git_request_log(&eq, {})
	defer git_release(&eq, id5)
	if p := _tget(t, &eq, id5, Log_Page); p != nil {
		testing.expect_value(t, len(p.commits), 0)
		testing.expect_value(t, p.head, "")
	}
}

@(test)
test_commit_detail_and_file_diff :: proc(t: ^testing.T) {
	dir := _trepo_new(t, "detail")
	defer _trepo_destroy(dir)
	_twrite(dir, "a.txt", "1\n2\n3\n")
	_twrite(dir, "b.txt", "bye\n")
	_twrite(dir, "old.txt", "keep\nthis\nfile\nmostly\nthe\nsame\n")
	root_hash := strings.clone(_tcommit(t, dir, "", "", "root"))
	defer delete(root_hash)

	_twrite(dir, "a.txt", "1\ntwo\n3\n")
	_twrite(dir, "c.txt", "new\n")
	_tgit(t, dir, "rm", "-q", "b.txt")
	_tgit(t, dir, "mv", "old.txt", "new.txt")
	_twrite(dir, "new.txt", "keep\nthis\nfile\nmostly\nthe\nSAME\n")
	second := strings.clone(_tcommit(t, dir, "", "", "second\n\nbody line"))
	defer delete(second)

	_tgit(t, dir, "checkout", "-q", "-b", "side", root_hash)
	_tcommit(t, dir, "side.txt", "s\n", "side")
	_tgit(t, dir, "checkout", "-q", "main")
	_tgit(t, dir, "merge", "-q", "--no-ff", "--no-edit", "side")
	merge_hash := strings.clone(_tgit_out(dir, "rev-parse", "HEAD"))
	defer delete(merge_hash)

	q: Git_Queue
	git_queue_init(&q, dir)
	defer git_queue_destroy(&q)

	find :: proc(files: []Commit_File, path: string) -> (Commit_File, bool) {
		for f in files { if f.path == path { return f, true } }
		return {}, false
	}

	// Second commit: M, A, D, R vs. first parent
	id := git_request_commit_detail(&q, second)
	defer git_release(&q, id)
	if d := _tget(t, &q, id, Commit_Detail); d != nil {
		testing.expect_value(t, d.commit.hash, second)
		testing.expect_value(t, d.commit.subject, "second")
		testing.expect_value(t, d.message, "second\n\nbody line")
		testing.expect_value(t, len(d.files), 4)
		fa, _ := find(d.files, "a.txt");   testing.expect_value(t, fa.change, File_Change.Modified)
		fb, _ := find(d.files, "b.txt");   testing.expect_value(t, fb.change, File_Change.Deleted)
		fc, _ := find(d.files, "c.txt");   testing.expect_value(t, fc.change, File_Change.Added)
		fr, _ := find(d.files, "new.txt"); testing.expect_value(t, fr.change, File_Change.Renamed)
		testing.expect_value(t, fr.old_path, "old.txt")
	}

	// Root commit: everything added
	rid := git_request_commit_detail(&q, root_hash)
	defer git_release(&q, rid)
	if d := _tget(t, &q, rid, Commit_Detail); d != nil {
		testing.expect_value(t, len(d.commit.parents), 0)
		testing.expect_value(t, len(d.files), 3)
		for f in d.files { testing.expect_value(t, f.change, File_Change.Added) }
	}

	// Merge commit: vs. first parent → only side.txt
	mid := git_request_commit_detail(&q, merge_hash)
	defer git_release(&q, mid)
	if d := _tget(t, &q, mid, Commit_Detail); d != nil {
		testing.expect_value(t, len(d.files), 1)
		if len(d.files) == 1 { testing.expect_value(t, d.files[0].path, "side.txt") }
	}

	// Whole-file diff of a.txt in the second commit
	did := git_request_commit_file_diff(&q, second, "a.txt")
	defer git_release(&q, did)
	if fd := _tget(t, &q, did, File_Diff); fd != nil {
		testing.expect_value(t, len(fd.rows), 3)
		testing.expect_value(t, fd.rows[0].left.kind, Diff_Kind.Context)
		testing.expect_value(t, fd.rows[1].left.text, "2")
		testing.expect_value(t, fd.rows[1].right.text, "two")
		testing.expect_value(t, len(fd.changed), 1)
	}
	// Same file in the root commit: all added
	rdid := git_request_commit_file_diff(&q, root_hash, "a.txt")
	defer git_release(&q, rdid)
	if fd := _tget(t, &q, rdid, File_Diff); fd != nil {
		testing.expect_value(t, len(fd.rows), 3)
		for r in fd.rows { testing.expect_value(t, r.right.kind, Diff_Kind.Add) }
	}
	// Renamed file, paired with its old version
	nid := git_request_commit_file_diff(&q, second, "new.txt", "old.txt")
	defer git_release(&q, nid)
	if fd := _tget(t, &q, nid, File_Diff); fd != nil {
		testing.expect_value(t, len(fd.rows), 6)
		testing.expect_value(t, fd.rows[5].left.text, "same")
		testing.expect_value(t, fd.rows[5].right.text, "SAME")
	}
	// Deleted file: all deleted
	bid := git_request_commit_file_diff(&q, second, "b.txt")
	defer git_release(&q, bid)
	if fd := _tget(t, &q, bid, File_Diff); fd != nil {
		testing.expect_value(t, len(fd.rows), 1)
		if len(fd.rows) == 1 { testing.expect_value(t, fd.rows[0].left.kind, Diff_Kind.Delete) }
	}
}

@(test)
test_branches_with_upstream_ahead_behind :: proc(t: ^testing.T) {
	dir := _trepo_new(t, "branches")
	defer _trepo_destroy(dir)
	remote := fmt.aprintf("%s-remote.git", dir)
	defer { _ = os.remove_all(remote); delete(remote) }
	_tcommit(t, dir, "a.txt", "1\n", "c1")
	_tgit(t, dir, "clone", "-q", "--bare", dir, remote)
	_tgit(t, dir, "remote", "add", "origin", remote)
	_tgit(t, dir, "fetch", "-q", "origin")
	_tgit(t, dir, "branch", "-q", "--set-upstream-to=origin/main", "main")
	_tcommit(t, dir, "a.txt", "2\n", "c2")
	_tgit(t, dir, "push", "-q", "origin", "main")
	_tgit(t, dir, "reset", "-q", "--hard", "HEAD~1")
	_tcommit(t, dir, "b.txt", "x\n", "c3") // ahead 1, behind 1
	_tgit(t, dir, "branch", "feat")
	_tgit(t, dir, "branch", "tmp")
	_tgit(t, dir, "push", "-q", "-u", "origin", "tmp")
	_tgit(t, dir, "push", "-q", "origin", "--delete", "tmp") // upstream gone

	q: Git_Queue
	git_queue_init(&q, dir)
	defer git_queue_destroy(&q)
	id := git_request_branches(&q)
	defer git_release(&q, id)
	bs := _tget(t, &q, id, []Branch)
	if bs == nil { return }

	get :: proc(bs: []Branch, name: string, remote: bool) -> (Branch, bool) {
		for b in bs { if b.name == name && b.is_remote == remote { return b, true } }
		return {}, false
	}
	main, ok1 := get(bs^, "main", false)
	testing.expect(t, ok1)
	testing.expect(t, main.is_head)
	testing.expect_value(t, main.ref, "refs/heads/main")
	testing.expect_value(t, main.upstream, "origin/main")
	testing.expect_value(t, main.ahead, 1)
	testing.expect_value(t, main.behind, 1)
	testing.expect_value(t, main.subject, "c3")
	testing.expect(t, len(main.hash) >= 40 && main.commit_time > 0)

	feat, ok2 := get(bs^, "feat", false)
	testing.expect(t, ok2 && !feat.is_head && feat.upstream == "" && feat.ahead == 0)

	tmp, ok3 := get(bs^, "tmp", false)
	testing.expect(t, ok3 && tmp.upstream_gone)

	om, ok4 := get(bs^, "origin/main", true)
	testing.expect(t, ok4)
	testing.expect_value(t, om.remote, "origin")
	testing.expect_value(t, om.subject, "c2")
	for b in bs^ { testing.expect(t, !strings.has_suffix(b.name, "/HEAD")) }
}

@(test)
test_remotes_tags_stashes :: proc(t: ^testing.T) {
	dir := _trepo_new(t, "rts")
	defer _trepo_destroy(dir)
	first := strings.clone(_tcommit(t, dir, "a.txt", "1\n", "c1"))
	defer delete(first)
	_tgit(t, dir, "tag", "lw")
	second := strings.clone(_tcommit(t, dir, "a.txt", "2\n", "c2"))
	defer delete(second)
	_tgit(t, dir, "tag", "-a", "v1", "-m", "release one")
	_tgit(t, dir, "remote", "add", "origin", "https://example.com/a.git")
	_tgit(t, dir, "remote", "set-url", "--push", "origin", "git@example.com:a.git")
	_tgit(t, dir, "remote", "add", "up.stream", "https://example.com/b.git")
	_twrite(dir, "a.txt", "dirty 1\n")
	_tgit(t, dir, "stash", "push", "-q", "-m", "first")
	_twrite(dir, "a.txt", "dirty 2\n")
	_tgit(t, dir, "stash", "push", "-q", "-m", "second")

	q: Git_Queue
	git_queue_init(&q, dir)
	defer git_queue_destroy(&q)
	rid := git_request_remotes(&q)
	tid := git_request_tags(&q)
	sid := git_request_stashes(&q)
	defer { git_release(&q, rid); git_release(&q, tid); git_release(&q, sid) }

	if rs := _tget(t, &q, rid, []Remote); rs != nil {
		testing.expect_value(t, len(rs^), 2)
		if len(rs^) == 2 {
			testing.expect_value(t, rs[0].name, "origin")
			testing.expect_value(t, rs[0].url, "https://example.com/a.git")
			testing.expect_value(t, rs[0].push_url, "git@example.com:a.git")
			testing.expect_value(t, rs[1].name, "up.stream")
			testing.expect_value(t, rs[1].push_url, "")
		}
	}
	if ts := _tget(t, &q, tid, []Tag); ts != nil {
		testing.expect_value(t, len(ts^), 2)
		if len(ts^) == 2 {
			testing.expect_value(t, ts[0].name, "lw")
			testing.expect(t, !ts[0].annotated)
			testing.expect_value(t, ts[0].hash, first)
			testing.expect_value(t, ts[1].name, "v1")
			testing.expect(t, ts[1].annotated)
			testing.expect_value(t, ts[1].hash, second)
			testing.expect(t, ts[1].object != "" && ts[1].object != second)
			testing.expect_value(t, ts[1].message, "release one")
			testing.expect(t, ts[1].time > 0)
		}
	}
	if ss := _tget(t, &q, sid, []Stash); ss != nil {
		testing.expect_value(t, len(ss^), 2)
		if len(ss^) == 2 {
			testing.expect_value(t, ss[0].index, 0)
			testing.expect_value(t, ss[0].ref, "stash@{0}")
			testing.expect_value(t, ss[0].message, "On main: second")
			testing.expect_value(t, ss[1].index, 1)
			testing.expect_value(t, ss[1].message, "On main: first")
			testing.expect(t, len(ss[1].hash) >= 40 && ss[1].time > 0)
		}
	}

	// Repo without remotes/stashes/submodules: empty lists, not errors
	empty := _trepo_new(t, "rtsempty")
	defer _trepo_destroy(empty)
	_tcommit(t, empty, "a.txt", "1\n", "c1")
	eq: Git_Queue
	git_queue_init(&eq, empty)
	defer git_queue_destroy(&eq)
	e1 := git_request_remotes(&eq)
	e2 := git_request_stashes(&eq)
	e3 := git_request_submodules(&eq)
	e4 := git_request_tags(&eq)
	defer { git_release(&eq, e1); git_release(&eq, e2); git_release(&eq, e3); git_release(&eq, e4) }
	if v := _tget(t, &eq, e1, []Remote); v != nil { testing.expect_value(t, len(v^), 0) }
	if v := _tget(t, &eq, e2, []Stash); v != nil { testing.expect_value(t, len(v^), 0) }
	if v := _tget(t, &eq, e3, []Submodule); v != nil { testing.expect_value(t, len(v^), 0) }
	if v := _tget(t, &eq, e4, []Tag); v != nil { testing.expect_value(t, len(v^), 0) }
}

@(test)
test_reflog_paginated :: proc(t: ^testing.T) {
	dir := _trepo_new(t, "reflog")
	defer _trepo_destroy(dir)
	_tcommit(t, dir, "a.txt", "1\n", "one")
	_tcommit(t, dir, "a.txt", "2\n", "two")
	_tgit(t, dir, "checkout", "-q", "-b", "feat")
	_tgit(t, dir, "checkout", "-q", "main")
	head := strings.clone(_tgit_out(dir, "rev-parse", "HEAD"))
	defer delete(head)

	q: Git_Queue
	git_queue_init(&q, dir)
	defer git_queue_destroy(&q)
	p1 := git_request_reflog(&q, "", 0, 2)
	p2 := git_request_reflog(&q, "", 2, 10)
	br := git_request_reflog(&q, "main")
	defer { git_release(&q, p1); git_release(&q, p2); git_release(&q, br) }

	if es := _tget(t, &q, p1, []Reflog_Entry); es != nil {
		testing.expect_value(t, len(es^), 2)
		if len(es^) == 2 {
			testing.expect_value(t, es[0].index, 0)
			testing.expect_value(t, es[0].selector, "HEAD@{0}")
			testing.expect_value(t, es[0].hash, head)
			testing.expect_value(t, es[0].action, "checkout")
			testing.expect_value(t, es[0].message, "moving from feat to main")
			testing.expect(t, es[0].time > 1_000_000_000)
			testing.expect_value(t, es[1].message, "moving from main to feat")
		}
	}
	if es := _tget(t, &q, p2, []Reflog_Entry); es != nil {
		testing.expect_value(t, len(es^), 2)
		if len(es^) == 2 {
			testing.expect_value(t, es[0].index, 2)
			testing.expect_value(t, es[0].selector, "HEAD@{2}")
			testing.expect_value(t, es[0].action, "commit")
			testing.expect_value(t, es[0].message, "two")
			testing.expect_value(t, es[1].action, "commit (initial)")
		}
	}
	if es := _tget(t, &q, br, []Reflog_Entry); es != nil {
		testing.expect_value(t, len(es^), 2)
		if len(es^) == 2 { testing.expect_value(t, es[0].selector, "main@{0}") }
	}
}

@(test)
test_submodules :: proc(t: ^testing.T) {
	sub := _trepo_new(t, "subsrc")
	defer _trepo_destroy(sub)
	sub_hash := strings.clone(_tcommit(t, sub, "lib.txt", "lib\n", "lib"))
	defer delete(sub_hash)

	dir := _trepo_new(t, "subhost")
	defer _trepo_destroy(dir)
	_tcommit(t, dir, "a.txt", "1\n", "c1")
	_tgit(t, dir, "-c", "protocol.file.allow=always", "submodule", "add", "-q", sub, "libs/sub")
	_tcommit(t, dir, "", "", "add submodule")

	q: Git_Queue
	git_queue_init(&q, dir)
	defer git_queue_destroy(&q)
	id1 := git_request_submodules(&q)
	defer git_release(&q, id1)
	if ss := _tget(t, &q, id1, []Submodule); ss != nil {
		testing.expect_value(t, len(ss^), 1)
		if len(ss^) == 1 {
			testing.expect_value(t, ss[0].name, "libs/sub")
			testing.expect_value(t, ss[0].path, "libs/sub")
			testing.expect_value(t, ss[0].url, sub)
			testing.expect_value(t, ss[0].hash, sub_hash)
			testing.expect_value(t, ss[0].state, Submodule_State.Up_To_Date)
		}
	}

	// New commit inside the submodule → checked out ≠ recorded
	subdir := fmt.tprintf("%s/libs/sub", dir)
	_tgit(t, subdir, "config", "user.email", "tester@example.com")
	_tgit(t, subdir, "config", "user.name", "Tester")
	_tgit(t, subdir, "config", "commit.gpgsign", "false")
	_tcommit(t, subdir, "", "", "moved")
	id2 := git_request_submodules(&q)
	defer git_release(&q, id2)
	if ss := _tget(t, &q, id2, []Submodule); ss != nil && len(ss^) == 1 {
		testing.expect_value(t, ss[0].state, Submodule_State.Modified)
		testing.expect(t, ss[0].hash != sub_hash)
	}
}

@(test)
test_file_at_revision :: proc(t: ^testing.T) {
	dir := _trepo_new(t, "fileat")
	defer _trepo_destroy(dir)
	_tcommit(t, dir, "a.txt", "v1\n", "c1")
	_tgit(t, dir, "branch", "old")
	c2 := strings.clone(_tcommit(t, dir, "a.txt", "v2\n", "c2"))
	defer delete(c2)
	_tcommit(t, dir, "a.txt", "v3\n", "c3")
	_twrite(dir, "a.txt", "dirty\n") // working tree must not leak in

	q: Git_Queue
	git_queue_init(&q, dir)
	defer git_queue_destroy(&q)
	h  := git_request_file_at(&q, "HEAD", "a.txt")
	b  := git_request_file_at(&q, "old", "a.txt")
	x  := git_request_file_at(&q, c2, "a.txt")
	m  := git_request_file_at(&q, "HEAD", "missing.txt")
	bad := git_request_file_at(&q, "nope", "a.txt")
	defer { git_release(&q, h); git_release(&q, b); git_release(&q, x); git_release(&q, m); git_release(&q, bad) }

	if v := _tget(t, &q, h, File_Blob); v != nil { testing.expect(t, v.present && !v.binary); testing.expect_value(t, v.text, "v3\n") }
	if v := _tget(t, &q, b, File_Blob); v != nil { testing.expect_value(t, v.text, "v1\n") }
	if v := _tget(t, &q, x, File_Blob); v != nil { testing.expect_value(t, v.text, "v2\n") }
	if v := _tget(t, &q, m, File_Blob); v != nil { testing.expect(t, !v.present) }
	testing.expect_value(t, _twait(t, &q, bad), Job_Status.Failed)
}

// Builds main/feat that both change line 2 of f.txt and add new.txt.
@(private = "file")
_conflict_repo :: proc(t: ^testing.T, name: string) -> string {
	dir := _trepo_new(t, name)
	_tcommit(t, dir, "f.txt", "a\nb\nc\n", "base")
	_tgit(t, dir, "checkout", "-q", "-b", "feat")
	_twrite(dir, "new.txt", "feat side\n")
	_tcommit(t, dir, "f.txt", "a\nFEAT\nc\n", "feat change")
	_tgit(t, dir, "checkout", "-q", "main")
	_twrite(dir, "new.txt", "main side\n")
	_tcommit(t, dir, "f.txt", "a\nMAIN\nc\n", "main change")
	return dir
}

@(test)
test_conflict_stages_in_merge :: proc(t: ^testing.T) {
	dir := _conflict_repo(t, "conflict")
	defer _trepo_destroy(dir)
	testing.expect(t, !_tgit_try(dir, "merge", "--no-edit", "feat")) // stops on conflict

	q: Git_Queue
	git_queue_init(&q, dir)
	defer git_queue_destroy(&q)
	sid := git_request_repo_state(&q)
	fid := git_request_conflict(&q, "f.txt")
	nid := git_request_conflict(&q, "new.txt")
	cid := git_request_conflict(&q, "not-conflicted.txt")
	defer { git_release(&q, sid); git_release(&q, fid); git_release(&q, nid); git_release(&q, cid) }

	if s := _tget(t, &q, sid, Repo_State); s != nil {
		testing.expect_value(t, s.operation, Repo_Operation.Merging)
		testing.expect_value(t, len(s.conflicts), 2)
		if len(s.conflicts) == 2 {
			testing.expect_value(t, s.conflicts[0], "f.txt")
			testing.expect_value(t, s.conflicts[1], "new.txt")
		}
	}
	if c := _tget(t, &q, fid, Conflict_Stages); c != nil {
		testing.expect_value(t, c.path, "f.txt")
		testing.expect_value(t, c.base.text, "a\nb\nc\n")
		testing.expect_value(t, c.ours.text, "a\nMAIN\nc\n")
		testing.expect_value(t, c.theirs.text, "a\nFEAT\nc\n")
		testing.expect_value(t, c.ours_label, "main")
		testing.expect_value(t, c.theirs_label, "feat")
		testing.expect_value(t, c.operation, Repo_Operation.Merging)
		testing.expect(t, !c.binary)
	}
	if c := _tget(t, &q, nid, Conflict_Stages); c != nil { // add/add: no base
		testing.expect(t, !c.base.present)
		testing.expect_value(t, c.ours.text, "main side\n")
		testing.expect_value(t, c.theirs.text, "feat side\n")
	}
	testing.expect_value(t, _twait(t, &q, cid), Job_Status.Failed)
}

@(test)
test_repo_state_operations :: proc(t: ^testing.T) {
	// Stable names for the UI / logs (never compare these to decide: use the enum)
	testing.expect_value(t, repo_operation_name(.Clean), "clean")
	testing.expect_value(t, repo_operation_name(.Merging), "merging")
	testing.expect_value(t, repo_operation_name(.Rebasing), "rebasing")
	testing.expect_value(t, repo_operation_name(.Cherry_Picking), "cherry-picking")
	testing.expect_value(t, repo_operation_name(.Reverting), "reverting")
	testing.expect_value(t, repo_operation_name(.Bisecting), "bisecting")
	testing.expect_value(t, repo_operation_name(.Conflicted), "conflicted")

	dir := _conflict_repo(t, "state")
	defer _trepo_destroy(dir)
	q: Git_Queue
	git_queue_init(&q, dir)
	defer git_queue_destroy(&q)

	// Copy of the state that outlives the job (conflicts → count only)
	state :: proc(t: ^testing.T, q: ^Git_Queue, loc := #caller_location) -> (s: Repo_State, conflicts: int) {
		id := git_request_repo_state(q)
		if v := _tget(t, q, id, Repo_State, loc); v != nil {
			s = v^
			s.conflicts = nil
			conflicts = len(v.conflicts)
			s.head_branch = strings.clone(v.head_branch, context.temp_allocator)
			s.head_hash = strings.clone(v.head_hash, context.temp_allocator)
			s.git_dir = ""
			s.operation_head = strings.clone(v.operation_head, context.temp_allocator)
		}
		git_release(q, id)
		return
	}

	head := strings.clone(_tgit_out(dir, "rev-parse", "HEAD"))
	defer delete(head)
	feat := strings.clone(_tgit_out(dir, "rev-parse", "feat"))
	defer delete(feat)

	s, nconf := state(t, &q)
	testing.expect_value(t, s.operation, Repo_Operation.Clean)
	testing.expect_value(t, s.head_branch, "main")
	testing.expect_value(t, s.head_hash, head)
	testing.expect(t, !s.detached && !s.unborn)

	_twrite(dir, "u.txt", "untracked\n")
	_twrite(dir, "f.txt", "edited\n")
	{
		id := git_request_repo_state(&q)
		if v := _tget(t, &q, id, Repo_State); v != nil {
			testing.expect_value(t, v.unstaged, 1)
			testing.expect_value(t, v.untracked, 1)
			testing.expect_value(t, v.operation, Repo_Operation.Clean)
		}
		git_release(&q, id)
	}
	_tgit(t, dir, "checkout", "-q", "--", "f.txt")
	_ = remove_file(dir, "u.txt")

	// Merge
	testing.expect(t, !_tgit_try(dir, "merge", "--no-edit", "feat"))
	s, nconf = state(t, &q)
	testing.expect_value(t, s.operation, Repo_Operation.Merging)
	testing.expect_value(t, nconf, 2)
	testing.expect_value(t, s.operation_head, feat)
	_tgit(t, dir, "merge", "--abort")

	// Rebase
	testing.expect(t, !_tgit_try(dir, "rebase", "feat"))
	s, nconf = state(t, &q)
	testing.expect_value(t, s.operation, Repo_Operation.Rebasing)
	testing.expect(t, nconf > 0)
	testing.expect(t, s.detached)
	_tgit(t, dir, "rebase", "--abort")

	// Cherry-pick
	testing.expect(t, !_tgit_try(dir, "cherry-pick", "feat"))
	s, nconf = state(t, &q)
	testing.expect_value(t, s.operation, Repo_Operation.Cherry_Picking)
	testing.expect_value(t, s.operation_head, feat)
	testing.expect(t, nconf > 0)
	_tgit(t, dir, "cherry-pick", "--abort")

	// Revert: undo a change that a later commit built upon
	_tcommit(t, dir, "r.txt", "1\n", "r1")
	mid := strings.clone(_tcommit(t, dir, "r.txt", "2\n", "r2"))
	defer delete(mid)
	_tcommit(t, dir, "r.txt", "3\n", "r3")
	testing.expect(t, !_tgit_try(dir, "revert", "--no-edit", mid))
	s, nconf = state(t, &q)
	testing.expect_value(t, s.operation, Repo_Operation.Reverting)
	testing.expect_value(t, s.operation_head, mid)
	testing.expect_value(t, nconf, 1)
	_tgit(t, dir, "revert", "--abort")

	s, nconf = state(t, &q)
	testing.expect_value(t, s.operation, Repo_Operation.Clean)
	testing.expect_value(t, nconf, 0)

	// Unborn repo
	empty := _trepo_new(t, "stateempty")
	defer _trepo_destroy(empty)
	eq: Git_Queue
	git_queue_init(&eq, empty)
	defer git_queue_destroy(&eq)
	es, _ := state(t, &eq)
	testing.expect(t, es.unborn)
	testing.expect_value(t, es.head_hash, "")
	testing.expect_value(t, es.operation, Repo_Operation.Clean)
}

@(private = "file")
remove_file :: proc(dir, rel: string) -> bool {
	return _tgit_try(dir, "clean", "-q", "-f", "--", rel)
}
