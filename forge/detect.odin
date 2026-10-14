package forge

import "core:fmt"
import "core:strings"

// Parses a git remote URL into a Remote. Accepted forms:
//   https://[user[:pass]@]host[:port]/path[.git][/]
//   ssh://[user@]host[:port]/path[.git]
//   git://host/path
//   [user@]host:path[.git]          (scp-like, e.g. git@github.com:o/r.git)
// The kind comes from the host name: "github.com" or any host containing
// "github" (GitHub Enterprise) is GitHub; any host containing "gitlab" is
// GitLab (gitlab.com and self-hosted). Anything else parses with
// kind = .Unknown. For http(s) URLs a non-default port stays in `host` (it is
// the web/API port); for ssh the port is dropped (it is only the ssh port).
// ok = false when the URL has no host or no "owner/name" path.
parse_remote_url :: proc(url: string, allocator := context.allocator) -> (r: Remote, ok: bool) {
	u := strings.trim_space(url)
	host, path: string
	keep_port := false

	if i := strings.index(u, "://"); i >= 0 {
		scheme := strings.to_lower(u[:i], context.temp_allocator)
		keep_port = scheme == "http" || scheme == "https"
		rest := u[i + 3:]
		slash := strings.index_byte(rest, '/')
		if slash < 0 { return {}, false }
		host = rest[:slash]
		path = rest[slash + 1:]
	} else {
		// scp-like: [user@]host:path
		colon := strings.index_byte(u, ':')
		if colon < 0 { return {}, false }
		host = u[:colon]
		path = u[colon + 1:]
	}

	// Strip credentials.
	if at := strings.last_index_byte(host, '@'); at >= 0 { host = host[at + 1:] }
	// Strip port (unless it is the http port we must keep).
	if !keep_port {
		if c := strings.index_byte(host, ':'); c >= 0 { host = host[:c] }
	}

	path = strings.trim(path, "/")
	path = strings.trim_suffix(path, ".git")
	path = strings.trim_right(path, "/")
	if host == "" || path == "" || strings.index_byte(path, '/') < 0 { return {}, false }

	lower := strings.to_lower(host, context.temp_allocator)
	kind := Kind.Unknown
	if strings.contains(lower, "github") {
		kind = .GitHub
	} else if strings.contains(lower, "gitlab") {
		kind = .GitLab
	}

	last := strings.last_index_byte(path, '/')
	r = {
		kind    = kind,
		host    = strings.clone(lower, allocator),
		project = strings.clone(path, allocator),
		owner   = strings.clone(path[:last], allocator),
		name    = strings.clone(path[last + 1:], allocator),
	}
	return r, true
}

// REST API root (no trailing slash).
api_base :: proc(r: Remote, allocator := context.temp_allocator) -> string {
	switch r.kind {
	case .GitHub:
		if r.host == "github.com" { return strings.clone("https://api.github.com", allocator) }
		return fmt.aprintf("https://%s/api/v3", r.host, allocator = allocator)
	case .GitLab:
		return fmt.aprintf("https://%s/api/v4", r.host, allocator = allocator)
	case .Unknown:
	}
	return ""
}

graphql_url :: proc(r: Remote, allocator := context.temp_allocator) -> string {
	if r.kind == .GitHub && r.host == "github.com" { return strings.clone("https://api.github.com/graphql", allocator) }
	return fmt.aprintf("https://%s/api/graphql", r.host, allocator = allocator)
}

// GitLab project id in REST paths: the full path, URL-encoded.
gitlab_project_id :: proc(r: Remote, allocator := context.temp_allocator) -> string {
	s, _ := strings.replace_all(r.project, "/", "%2F", allocator)
	return s
}
