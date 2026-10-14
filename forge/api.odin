package forge

// High-level operations (one per UI action). Blocking — call only from the
// worker thread (worker.odin) or tests. Endpoints follow Git Crab's
// src-tauri/src/commands/forge.rs, except PR listing, which uses GraphQL to
// get the check status of every PR in a single request.

import "core:fmt"
import "core:strings"

Session :: struct {
	exec:   Exec_Proc,
	remote: Remote,
	auth:   Auth,
}

@(private)
_unknown :: proc() -> string { return strings.clone("remote is neither GitHub nor GitLab") }

@(private)
_gh_repo :: proc(s: ^Session) -> string {
	return fmt.tprintf("repos/%s/%s", s.remote.owner, s.remote.name)
}

@(private)
_gl_proj :: proc(s: ^Session) -> string {
	return fmt.tprintf("projects/%s", gitlab_project_id(s.remote))
}

// Percent-encodes a query parameter value.
url_query_escape :: proc(v: string, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	for c in transmute([]u8)v {
		switch c {
		case 'a'..='z', 'A'..='Z', '0'..='9', '-', '_', '.', '~':
			strings.write_byte(&sb, c)
		case:
			fmt.sbprintf(&sb, "%%%02X", c)
		}
	}
	return strings.to_string(sb)
}

// Request builders — pure, tested in forge_test.odin.

req_list_prs :: proc(r: Remote) -> Request {
	fields := make([]Field, 3 if r.kind == .GitHub else 2, context.temp_allocator)
	if r.kind == .GitHub {
		fields[0] = {"query", GITHUB_PRS_QUERY}
		fields[1] = {"owner", r.owner}
		fields[2] = {"name", r.name}
	} else {
		fields[0] = {"query", GITLAB_MRS_QUERY}
		fields[1] = {"fullPath", r.project}
	}
	return {method = "POST", path = "graphql", fields = fields}
}

req_pr_diff :: proc(r: Remote, n: i64) -> Request {
	if r.kind == .GitHub {
		return {method = "GET", path = fmt.tprintf("repos/%s/%s/pulls/%d", r.owner, r.name, n), accept = "application/vnd.github.diff"}
	}
	return {method = "GET", path = fmt.tprintf("projects/%s/merge_requests/%d/diffs?per_page=100", gitlab_project_id(r), n)}
}

req_list_comments :: proc(r: Remote, n: i64) -> Request {
	if r.kind == .GitHub {
		return {method = "GET", path = fmt.tprintf("repos/%s/%s/issues/%d/comments?per_page=100", r.owner, r.name, n)}
	}
	return {method = "GET", path = fmt.tprintf("projects/%s/merge_requests/%d/notes?per_page=100&sort=desc", gitlab_project_id(r), n)}
}

req_post_comment :: proc(r: Remote, n: i64, body: string) -> Request {
	fields := make([]Field, 1, context.temp_allocator)
	fields[0] = {"body", body}
	if r.kind == .GitHub {
		return {method = "POST", path = fmt.tprintf("repos/%s/%s/issues/%d/comments", r.owner, r.name, n), fields = fields}
	}
	return {method = "POST", path = fmt.tprintf("projects/%s/merge_requests/%d/notes", gitlab_project_id(r), n), fields = fields}
}

req_list_pipelines :: proc(r: Remote) -> Request {
	if r.kind == .GitHub {
		return {method = "GET", path = fmt.tprintf("repos/%s/%s/actions/runs?per_page=30", r.owner, r.name)}
	}
	return {method = "GET", path = fmt.tprintf("projects/%s/pipelines?per_page=30", gitlab_project_id(r))}
}

req_list_jobs :: proc(r: Remote, pipeline: i64) -> Request {
	if r.kind == .GitHub {
		return {method = "GET", path = fmt.tprintf("repos/%s/%s/actions/runs/%d/jobs?per_page=100", r.owner, r.name, pipeline)}
	}
	return {method = "GET", path = fmt.tprintf("projects/%s/pipelines/%d/jobs?per_page=100", gitlab_project_id(r), pipeline)}
}

req_retry_job :: proc(r: Remote, job: i64) -> Request {
	if r.kind == .GitHub {
		return {method = "POST", path = fmt.tprintf("repos/%s/%s/actions/jobs/%d/rerun", r.owner, r.name, job)}
	}
	return {method = "POST", path = fmt.tprintf("projects/%s/jobs/%d/retry", gitlab_project_id(r), job)}
}

// GitLab: create a pipeline on ref. GitHub has no generic "run CI on a
// branch" call: we re-run the latest workflow run of the branch
// (req_latest_run + req_rerun_run), like Git Crab.
req_trigger_gitlab :: proc(r: Remote, ref: string) -> Request {
	fields := make([]Field, 1, context.temp_allocator)
	fields[0] = {"ref", ref}
	return {method = "POST", path = fmt.tprintf("projects/%s/pipeline", gitlab_project_id(r)), fields = fields}
}

req_latest_run :: proc(r: Remote, branch: string) -> Request {
	return {method = "GET", path = fmt.tprintf("repos/%s/%s/actions/runs?branch=%s&per_page=1", r.owner, r.name, url_query_escape(branch))}
}

req_rerun_run :: proc(r: Remote, run: i64) -> Request {
	return {method = "POST", path = fmt.tprintf("repos/%s/%s/actions/runs/%d/rerun", r.owner, r.name, run)}
}

// ---------------------------------------------------------------------------
// Operations
// ---------------------------------------------------------------------------

list_prs :: proc(s: ^Session) -> (prs: []Pull_Request, err: string) {
	if s.remote.kind == .Unknown { return nil, _unknown() }
	body: string
	body, err = do_request(s.exec, s.remote, s.auth, req_list_prs(s.remote))
	if err != "" { return }
	defer delete(body)
	if s.remote.kind == .GitHub { return parse_github_prs(body) }
	return parse_gitlab_mrs(body)
}

pr_diff :: proc(s: ^Session, n: i64) -> (diff: string, err: string) {
	if s.remote.kind == .Unknown { return "", _unknown() }
	body: string
	body, err = do_request(s.exec, s.remote, s.auth, req_pr_diff(s.remote, n))
	if err != "" { return }
	if s.remote.kind == .GitHub { return body, "" }
	defer delete(body)
	return parse_gitlab_mr_diffs(body)
}

list_comments :: proc(s: ^Session, n: i64) -> (cs: []Comment, err: string) {
	if s.remote.kind == .Unknown { return nil, _unknown() }
	body: string
	body, err = do_request(s.exec, s.remote, s.auth, req_list_comments(s.remote, n))
	if err != "" { return }
	defer delete(body)
	if s.remote.kind == .GitHub { return parse_github_comments(body) }
	return parse_gitlab_notes(body)
}

post_comment :: proc(s: ^Session, n: i64, text: string) -> (err: string) {
	if s.remote.kind == .Unknown { return _unknown() }
	if strings.trim_space(text) == "" { return strings.clone("empty comment") }
	body: string
	body, err = do_request(s.exec, s.remote, s.auth, req_post_comment(s.remote, n, text))
	delete(body)
	return
}

list_pipelines :: proc(s: ^Session) -> (ps: []Pipeline, err: string) {
	if s.remote.kind == .Unknown { return nil, _unknown() }
	body: string
	body, err = do_request(s.exec, s.remote, s.auth, req_list_pipelines(s.remote))
	if err != "" { return }
	defer delete(body)
	if s.remote.kind == .GitHub { return parse_github_runs(body) }
	return parse_gitlab_pipelines(body)
}

list_jobs :: proc(s: ^Session, pipeline: i64) -> (js: []Job, err: string) {
	if s.remote.kind == .Unknown { return nil, _unknown() }
	body: string
	body, err = do_request(s.exec, s.remote, s.auth, req_list_jobs(s.remote, pipeline))
	if err != "" { return }
	defer delete(body)
	if s.remote.kind == .GitHub { return parse_github_jobs(body) }
	return parse_gitlab_jobs(body)
}

retry_job :: proc(s: ^Session, job: i64) -> (err: string) {
	if s.remote.kind == .Unknown { return _unknown() }
	body: string
	body, err = do_request(s.exec, s.remote, s.auth, req_retry_job(s.remote, job))
	delete(body)
	return
}

// Returns a heap-owned human message on success.
trigger_pipeline :: proc(s: ^Session, branch: string) -> (msg: string, err: string) {
	if branch == "" || branch == "HEAD" { return "", strings.clone("no current branch (detached HEAD)") }
	switch s.remote.kind {
	case .Unknown:
		return "", _unknown()
	case .GitLab:
		body: string
		body, err = do_request(s.exec, s.remote, s.auth, req_trigger_gitlab(s.remote, branch))
		delete(body)
		if err != "" { return }
		return fmt.aprintf("pipeline created on %s", branch), ""
	case .GitHub:
		body: string
		body, err = do_request(s.exec, s.remote, s.auth, req_latest_run(s.remote, branch))
		if err != "" { return }
		run := parse_github_first_run_id(body)
		delete(body)
		if run == 0 { return "", fmt.aprintf("no workflow runs found for branch %s", branch) }
		body, err = do_request(s.exec, s.remote, s.auth, req_rerun_run(s.remote, run))
		delete(body)
		if err != "" { return }
		return fmt.aprintf("re-running workflow run %d on %s", run, branch), ""
	}
	return
}
