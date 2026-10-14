package git

// Operations of the commit graph screen (ticket #4, ADR 0001: screen ops live
// in git/<tela>_ops*.odin and run on the queue worker).

import "core:slice"
import "core:strings"

// Result of git_request_commit_search (payload Git_Custom → ^Commit_Search).
Commit_Search :: struct {
	commits:   []Commit, // newest first, unique, refs filled
	truncated: bool,     // more matches than `limit` exist
	head:      string,
}

COMMIT_SEARCH_LIMIT :: 500

// Commits whose message or author matches `query` (case-insensitive,
// literal text) or whose hash starts with it. rev = "" searches every ref
// (like the graph), otherwise only history reachable from rev.
git_request_commit_search :: proc(q: ^Git_Queue, query: string, rev := "", limit := COMMIT_SEARCH_LIMIT) -> Job_Id {
	buf: [16]u8
	return git_request_custom(q, _commit_search_work, {query, rev, _itoa(buf[:], limit)})
}

@(private="file")
_itoa :: proc(buf: []u8, n: int) -> string {
	n := max(n, 0)
	i := len(buf)
	if n == 0 { i -= 1; buf[i] = '0' }
	for n > 0 && i > 0 { i -= 1; buf[i] = u8('0' + n % 10); n /= 10 }
	return string(buf[i:])
}

// Worker-side search (also callable directly from tests / other jobs).
git_query_commit_search :: proc(root, query, rev: string, limit := COMMIT_SEARCH_LIMIT, allocator := context.allocator) -> (res: Commit_Search, err: string) {
	context.allocator = allocator
	query := strings.trim_space(query)
	if query == "" { return res, "" }
	limit := limit if limit > 0 else COMMIT_SEARCH_LIMIT

	found := make([dynamic]Commit)
	seen  := make(map[string]bool, 64, context.temp_allocator)
	add :: proc(found: ^[dynamic]Commit, seen: ^map[string]bool, page: Log_Page) {
		for c in page.commits {
			if c.hash in seen { continue }
			seen[c.hash] = true
			append(found, c)
		}
	}

	// Hash prefix
	if _is_hex(query) && len(query) >= 4 {
		if h, ok := _rev_parse(root, strings.concatenate({query, "^{commit}"}, context.temp_allocator)); ok {
			if page, perr := git_query_log(root, {rev = h, limit = 1}); perr == "" {
				add(&found, &seen, page)
				res.head = page.head
			}
		}
	}

	pattern := _bre_escape(query)
	by_msg, merr := git_query_log(root, {rev = rev, grep = pattern, limit = limit})
	if merr != "" { return res, merr }
	by_author, aerr := git_query_log(root, {rev = rev, author = _bre_escape(query, fold_case = true), limit = limit})
	if aerr != "" { return res, aerr }
	add(&found, &seen, by_msg)
	add(&found, &seen, by_author)
	if res.head == "" { res.head = by_msg.head }

	slice.stable_sort_by(found[:], proc(a, b: Commit) -> bool { return a.commit_time > b.commit_time })
	res.truncated = by_msg.has_more || by_author.has_more || len(found) > limit
	if len(found) > limit { resize(&found, limit) }
	res.commits = found[:]
	return res, ""
}

@(private="file")
_commit_search_work :: proc(root: string, args: []string, user: rawptr) -> (Git_Payload, string) {
	limit := 0
	for c in transmute([]u8)args[2] { limit = limit * 10 + int(c - '0') }
	p, payload := git_custom_new(Commit_Search)
	r, err := git_query_commit_search(root, args[0], args[1], limit)
	if err != "" { return nil, err }
	p^ = r
	return payload, ""
}

@(private="file")
_is_hex :: proc(s: string) -> bool {
	for c in transmute([]u8)s {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) { return false }
	}
	return len(s) > 0
}

// Escapes basic-regex metacharacters so the query matches literally.
// fold_case turns letters into [xX] (--author has no case-insensitive flag of
// its own; -i is only added by git_query_log together with --grep).
@(private="file")
_bre_escape :: proc(s: string, fold_case := false) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in transmute([]u8)s {
		if fold_case && ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) {
			lo := c | 0x20
			strings.write_byte(&b, '[')
			strings.write_byte(&b, lo)
			strings.write_byte(&b, lo - 32)
			strings.write_byte(&b, ']')
			continue
		}
		switch c {
		case '\\', '.', '[', ']', '*', '^', '$':
			strings.write_byte(&b, '\\')
		}
		strings.write_byte(&b, c)
	}
	return strings.to_string(b)
}
