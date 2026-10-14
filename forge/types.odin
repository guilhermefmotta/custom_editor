package forge

// Forge integration (ticket #14 / ADR 0008): GitHub and GitLab pull requests,
// pipelines/jobs and comments. Everything that touches the network runs on
// the worker thread in worker.odin; the UI (forge_panel.odin in the root
// package) only enqueues jobs and polls results.
//
// Ownership: every string inside the result structs is heap-owned by the
// struct and freed by the matching *_destroy proc.

import "core:strings"

Kind :: enum u8 { Unknown, GitHub, GitLab }

// Normalized status for PR checks, pipelines and jobs.
Status :: enum u8 { None, Pending, Running, Success, Failure, Canceled, Skipped, Manual }

// Where the repository lives, derived from the remote URL.
Remote :: struct {
	kind:    Kind,
	host:    string, // e.g. "github.com", "gitlab.example.com" (no port)
	project: string, // "owner/repo" or "group/sub/project"
	owner:   string, // everything before the last '/' of project
	name:    string, // last path segment of project
}

Pull_Request :: struct {
	number:        i64,
	title:         string,
	author:        string,
	url:           string,
	created_at:    string,
	source_branch: string,
	target_branch: string,
	draft:         bool,
	checks:        Status,
}

Pipeline :: struct {
	id:         i64,
	name:       string,
	branch:     string,
	url:        string,
	created_at: string,
	status:     Status,
}

Job :: struct {
	id:       i64,
	name:     string,
	stage:    string,
	url:      string,
	status:   Status,
	duration: f64, // seconds, 0 = unknown
}

Comment :: struct {
	id:         i64,
	author:     string,
	body:       string,
	created_at: string,
}

remote_destroy :: proc(r: ^Remote) {
	delete(r.host); delete(r.project); delete(r.owner); delete(r.name)
	r^ = {}
}

remote_clone :: proc(r: Remote, allocator := context.allocator) -> Remote {
	return {
		kind    = r.kind,
		host    = strings.clone(r.host, allocator),
		project = strings.clone(r.project, allocator),
		owner   = strings.clone(r.owner, allocator),
		name    = strings.clone(r.name, allocator),
	}
}

prs_destroy :: proc(prs: []Pull_Request) {
	for p in prs {
		delete(p.title); delete(p.author); delete(p.url); delete(p.created_at)
		delete(p.source_branch); delete(p.target_branch)
	}
	delete(prs)
}

pipelines_destroy :: proc(ps: []Pipeline) {
	for p in ps { delete(p.name); delete(p.branch); delete(p.url); delete(p.created_at) }
	delete(ps)
}

jobs_destroy :: proc(js: []Job) {
	for j in js { delete(j.name); delete(j.stage); delete(j.url) }
	delete(js)
}

comments_destroy :: proc(cs: []Comment) {
	for c in cs { delete(c.author); delete(c.body); delete(c.created_at) }
	delete(cs)
}

kind_label :: proc(k: Kind) -> string {
	switch k {
	case .GitHub:  return "GitHub"
	case .GitLab:  return "GitLab"
	case .Unknown: return "Unknown"
	}
	return "Unknown"
}

// Short glyph for lists (ASCII only so every font renders it).
status_glyph :: proc(s: Status) -> string {
	switch s {
	case .None:     return " "
	case .Pending:  return "o"
	case .Running:  return "*"
	case .Success:  return "+"
	case .Failure:  return "x"
	case .Canceled: return "-"
	case .Skipped:  return "/"
	case .Manual:   return ">"
	}
	return " "
}

status_label :: proc(s: Status) -> string {
	switch s {
	case .None:     return "no checks"
	case .Pending:  return "pending"
	case .Running:  return "running"
	case .Success:  return "success"
	case .Failure:  return "failed"
	case .Canceled: return "canceled"
	case .Skipped:  return "skipped"
	case .Manual:   return "manual"
	}
	return ""
}
