package forge

// Parsing of GitHub/GitLab API responses (REST + GraphQL) into the forge
// structs. Pure: no I/O. Fixtures in forge/testdata, tests in forge_test.odin.
// All parse_* return heap-owned results (free with the *_destroy procs) and
// an error message (heap-owned, "" when ok).

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"

// ---------------------------------------------------------------------------
// json.Value helpers
// ---------------------------------------------------------------------------

@(private)
_get :: proc(v: json.Value, keys: ..string) -> json.Value {
	cur := v
	for k in keys {
		obj, ok := cur.(json.Object)
		if !ok { return nil }
		cur = obj[k] or_else nil
	}
	return cur
}

@(private)
_str :: proc(v: json.Value) -> string {
	#partial switch x in v {
	case json.String: return x
	}
	return ""
}

@(private)
_int :: proc(v: json.Value) -> i64 {
	#partial switch x in v {
	case json.Integer: return x
	case json.Float:   return i64(x)
	case json.String:  n, _ := strconv.parse_i64(x); return n
	}
	return 0
}

@(private)
_f64 :: proc(v: json.Value) -> f64 {
	#partial switch x in v {
	case json.Integer: return f64(x)
	case json.Float:   return x
	}
	return 0
}

@(private)
_bool :: proc(v: json.Value) -> bool {
	b, _ := v.(json.Boolean)
	return b
}

@(private)
_arr :: proc(v: json.Value) -> json.Array {
	a, _ := v.(json.Array)
	return a
}

@(private)
_clone :: proc(v: json.Value) -> string { return strings.clone(_str(v)) }

@(private)
_parse :: proc(data: string) -> (v: json.Value, err: string) {
	val, perr := json.parse_string(data, .JSON, true)
	if perr != nil {
		json.destroy_value(val)
		return nil, fmt.aprintf("invalid JSON response (%v)", perr)
	}
	return val, ""
}

// First GraphQL error message, or "".
@(private)
_graphql_error :: proc(v: json.Value) -> string {
	errs := _arr(_get(v, "errors"))
	if len(errs) == 0 { return "" }
	msg := _str(_get(errs[0], "message"))
	return fmt.aprintf("GraphQL: %s", msg if msg != "" else "error")
}

// Error message carried by an API error body ({"message": ...} on GitHub,
// {"message"|"error": ...} on GitLab; GitLab's message can be an object or
// array). "" when there is none. Heap-owned.
api_error_message :: proc(body: string) -> string {
	v, err := _parse(body)
	if err != "" { delete(err); return "" }
	defer json.destroy_value(v)
	if e := _graphql_error(v); e != "" { return e }
	for key in ([]string{"message", "error", "error_description"}) {
		m := _get(v, key)
		#partial switch x in m {
		case json.String: if x != "" { return strings.clone(x) }
		case json.Object, json.Array:
			s, merr := json.marshal(m)
			if merr == nil { return string(s) }
		}
	}
	return ""
}

// ---------------------------------------------------------------------------
// Status mapping
// ---------------------------------------------------------------------------

// GitHub GraphQL StatusState of a commit's statusCheckRollup.
github_rollup_status :: proc(state: string) -> Status {
	switch strings.to_upper(state, context.temp_allocator) {
	case "SUCCESS":             return .Success
	case "FAILURE", "ERROR":    return .Failure
	case "PENDING", "EXPECTED": return .Pending
	}
	return .None
}

// GitHub Actions run/job (status, conclusion).
github_run_status :: proc(status, conclusion: string) -> Status {
	switch status {
	case "completed":
		switch conclusion {
		case "success":                                   return .Success
		case "failure", "timed_out", "startup_failure":   return .Failure
		case "cancelled":                                 return .Canceled
		case "skipped", "neutral", "stale":               return .Skipped
		case "action_required":                           return .Manual
		}
		return .None
	case "in_progress":                                   return .Running
	case "queued", "waiting", "requested", "pending":     return .Pending
	}
	return .None
}

// GitLab pipeline/job status (REST lowercase or GraphQL uppercase).
gitlab_status :: proc(s: string) -> Status {
	switch strings.to_lower(s, context.temp_allocator) {
	case "success", "passed":   return .Success
	case "failed":              return .Failure
	case "running":             return .Running
	case "pending", "created", "waiting_for_resource", "preparing", "scheduled", "waiting_for_callback":
		return .Pending
	case "canceled", "canceling": return .Canceled
	case "skipped":             return .Skipped
	case "manual":              return .Manual
	}
	return .None
}

// ---------------------------------------------------------------------------
// Pull/merge requests (GraphQL — one request gives PRs + check status)
// ---------------------------------------------------------------------------

GITHUB_PRS_QUERY :: `query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    pullRequests(states: OPEN, first: 50, orderBy: {field: CREATED_AT, direction: DESC}) {
      nodes {
        number title url isDraft createdAt headRefName baseRefName
        author { login }
        commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
      }
    }
  }
}`

GITLAB_MRS_QUERY :: `query($fullPath: ID!) {
  project(fullPath: $fullPath) {
    mergeRequests(state: opened, first: 50, sort: CREATED_DESC) {
      nodes {
        iid title webUrl draft createdAt sourceBranch targetBranch
        author { username }
        headPipeline { status }
      }
    }
  }
}`

parse_github_prs :: proc(data: string) -> (prs: []Pull_Request, err: string) {
	v, perr := _parse(data)
	if perr != "" { return nil, perr }
	defer json.destroy_value(v)
	if e := _graphql_error(v); e != "" { return nil, e }
	repo := _get(v, "data", "repository")
	if repo == nil { return nil, strings.clone("repository not found (check access/token)") }
	nodes := _arr(_get(repo, "pullRequests", "nodes"))
	out := make([]Pull_Request, len(nodes))
	for n, i in nodes {
		commits := _arr(_get(n, "commits", "nodes"))
		checks := Status.None
		if len(commits) > 0 {
			checks = github_rollup_status(_str(_get(commits[0], "commit", "statusCheckRollup", "state")))
		}
		out[i] = {
			number        = _int(_get(n, "number")),
			title         = _clone(_get(n, "title")),
			author        = _clone(_get(n, "author", "login")),
			url           = _clone(_get(n, "url")),
			created_at    = _clone(_get(n, "createdAt")),
			source_branch = _clone(_get(n, "headRefName")),
			target_branch = _clone(_get(n, "baseRefName")),
			draft         = _bool(_get(n, "isDraft")),
			checks        = checks,
		}
	}
	return out, ""
}

parse_gitlab_mrs :: proc(data: string) -> (prs: []Pull_Request, err: string) {
	v, perr := _parse(data)
	if perr != "" { return nil, perr }
	defer json.destroy_value(v)
	if e := _graphql_error(v); e != "" { return nil, e }
	proj := _get(v, "data", "project")
	if proj == nil { return nil, strings.clone("project not found (check access/token)") }
	nodes := _arr(_get(proj, "mergeRequests", "nodes"))
	out := make([]Pull_Request, len(nodes))
	for n, i in nodes {
		out[i] = {
			number        = _int(_get(n, "iid")),
			title         = _clone(_get(n, "title")),
			author        = _clone(_get(n, "author", "username")),
			url           = _clone(_get(n, "webUrl")),
			created_at    = _clone(_get(n, "createdAt")),
			source_branch = _clone(_get(n, "sourceBranch")),
			target_branch = _clone(_get(n, "targetBranch")),
			draft         = _bool(_get(n, "draft")),
			checks        = gitlab_status(_str(_get(n, "headPipeline", "status"))),
		}
	}
	return out, ""
}

// GitLab GET merge_requests/:iid/diffs → unified diff text.
parse_gitlab_mr_diffs :: proc(data: string) -> (diff: string, err: string) {
	v, perr := _parse(data)
	if perr != "" { return "", perr }
	defer json.destroy_value(v)
	files, ok := v.(json.Array)
	if !ok { return "", strings.clone("unexpected diff response") }
	sb := strings.builder_make()
	for f in files {
		old_p := _str(_get(f, "old_path"))
		new_p := _str(_get(f, "new_path"))
		fmt.sbprintf(&sb, "diff --git a/%s b/%s\n", old_p, new_p)
		if _bool(_get(f, "new_file"))     { strings.write_string(&sb, "new file\n") }
		if _bool(_get(f, "deleted_file")) { strings.write_string(&sb, "deleted file\n") }
		if _bool(_get(f, "renamed_file")) { fmt.sbprintf(&sb, "rename from %s\nrename to %s\n", old_p, new_p) }
		fmt.sbprintf(&sb, "--- %s%s\n", "a/" if !_bool(_get(f, "new_file")) else "", old_p if !_bool(_get(f, "new_file")) else "/dev/null")
		fmt.sbprintf(&sb, "+++ %s%s\n", "b/" if !_bool(_get(f, "deleted_file")) else "", new_p if !_bool(_get(f, "deleted_file")) else "/dev/null")
		d := _str(_get(f, "diff"))
		strings.write_string(&sb, d)
		if len(d) > 0 && d[len(d) - 1] != '\n' { strings.write_byte(&sb, '\n') }
	}
	return strings.to_string(sb), ""
}

// ---------------------------------------------------------------------------
// Pipelines / jobs
// ---------------------------------------------------------------------------

parse_github_runs :: proc(data: string) -> (out: []Pipeline, err: string) {
	v, perr := _parse(data)
	if perr != "" { return nil, perr }
	defer json.destroy_value(v)
	runs := _arr(_get(v, "workflow_runs"))
	if _get(v, "workflow_runs") == nil { return nil, strings.clone("unexpected workflow runs response") }
	out = make([]Pipeline, len(runs))
	for r, i in runs {
		title := _str(_get(r, "display_title"))
		name  := _str(_get(r, "name"))
		out[i] = {
			id         = _int(_get(r, "id")),
			name       = fmt.aprintf("%s #%d: %s", name, _int(_get(r, "run_number")), title) if title != "" else strings.clone(name),
			branch     = _clone(_get(r, "head_branch")),
			url        = _clone(_get(r, "html_url")),
			created_at = _clone(_get(r, "created_at")),
			status     = github_run_status(_str(_get(r, "status")), _str(_get(r, "conclusion"))),
		}
	}
	return out, ""
}

// First run id of a runs listing (for "re-run latest on branch"), 0 if none.
parse_github_first_run_id :: proc(data: string) -> i64 {
	v, err := _parse(data)
	if err != "" { delete(err); return 0 }
	defer json.destroy_value(v)
	runs := _arr(_get(v, "workflow_runs"))
	return _int(_get(runs[0], "id")) if len(runs) > 0 else 0
}

parse_gitlab_pipelines :: proc(data: string) -> (out: []Pipeline, err: string) {
	v, perr := _parse(data)
	if perr != "" { return nil, perr }
	defer json.destroy_value(v)
	ps, ok := v.(json.Array)
	if !ok { return nil, strings.clone("unexpected pipelines response") }
	out = make([]Pipeline, len(ps))
	for p, i in ps {
		id := _int(_get(p, "id"))
		src := _str(_get(p, "source"))
		out[i] = {
			id         = id,
			name       = fmt.aprintf("Pipeline #%d (%s)", id, src) if src != "" else fmt.aprintf("Pipeline #%d", id),
			branch     = _clone(_get(p, "ref")),
			url        = _clone(_get(p, "web_url")),
			created_at = _clone(_get(p, "created_at")),
			status     = gitlab_status(_str(_get(p, "status"))),
		}
	}
	return out, ""
}

parse_github_jobs :: proc(data: string) -> (out: []Job, err: string) {
	v, perr := _parse(data)
	if perr != "" { return nil, perr }
	defer json.destroy_value(v)
	if _get(v, "jobs") == nil { return nil, strings.clone("unexpected jobs response") }
	js := _arr(_get(v, "jobs"))
	out = make([]Job, len(js))
	for j, i in js {
		out[i] = {
			id       = _int(_get(j, "id")),
			name     = _clone(_get(j, "name")),
			stage    = _clone(_get(j, "workflow_name")),
			url      = _clone(_get(j, "html_url")),
			status   = github_run_status(_str(_get(j, "status")), _str(_get(j, "conclusion"))),
			duration = _duration(_str(_get(j, "started_at")), _str(_get(j, "completed_at"))),
		}
	}
	return out, ""
}

parse_gitlab_jobs :: proc(data: string) -> (out: []Job, err: string) {
	v, perr := _parse(data)
	if perr != "" { return nil, perr }
	defer json.destroy_value(v)
	js, ok := v.(json.Array)
	if !ok { return nil, strings.clone("unexpected jobs response") }
	out = make([]Job, len(js))
	for j, i in js {
		out[i] = {
			id       = _int(_get(j, "id")),
			name     = _clone(_get(j, "name")),
			stage    = _clone(_get(j, "stage")),
			url      = _clone(_get(j, "web_url")),
			status   = gitlab_status(_str(_get(j, "status"))),
			duration = _f64(_get(j, "duration")),
		}
	}
	return out, ""
}

@(private)
_duration :: proc(start, end: string) -> f64 {
	if start == "" || end == "" { return 0 }
	a, ca := time.rfc3339_to_time_utc(start)
	b, cb := time.rfc3339_to_time_utc(end)
	if ca == 0 || cb == 0 { return 0 }
	return max(0, time.duration_seconds(time.diff(a, b)))
}

// ---------------------------------------------------------------------------
// Comments
// ---------------------------------------------------------------------------

parse_github_comments :: proc(data: string) -> (out: []Comment, err: string) {
	v, perr := _parse(data)
	if perr != "" { return nil, perr }
	defer json.destroy_value(v)
	cs, ok := v.(json.Array)
	if !ok { return nil, strings.clone("unexpected comments response") }
	out = make([]Comment, len(cs))
	for c, i in cs {
		out[i] = {
			id         = _int(_get(c, "id")),
			author     = _clone(_get(c, "user", "login")),
			body       = _clone(_get(c, "body")),
			created_at = _clone(_get(c, "created_at")),
		}
	}
	return out, ""
}

// GitLab MR notes, without system notes ("added 1 commit", ...). The API
// returns newest first; we return oldest first like GitHub.
parse_gitlab_notes :: proc(data: string) -> (out: []Comment, err: string) {
	v, perr := _parse(data)
	if perr != "" { return nil, perr }
	defer json.destroy_value(v)
	ns, ok := v.(json.Array)
	if !ok { return nil, strings.clone("unexpected notes response") }
	list := make([dynamic]Comment, 0, len(ns))
	#reverse for n in ns {
		if _bool(_get(n, "system")) { continue }
		append(&list, Comment{
			id         = _int(_get(n, "id")),
			author     = _clone(_get(n, "author", "username")),
			body       = _clone(_get(n, "body")),
			created_at = _clone(_get(n, "created_at")),
		})
	}
	return list[:], ""
}
