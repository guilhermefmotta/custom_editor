package forge

// Tests for features/forge.feature. No real processes or network: the
// fixtures in testdata/ are canned API responses and `_fake_exec` stands in
// for git/gh/glab/curl/security. Run: odin test ./forge

import "base:runtime"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

// ---------------------------------------------------------------------------
// Host detection
// ---------------------------------------------------------------------------

@(private="file")
_expect_remote :: proc(t: ^testing.T, url: string, kind: Kind, host, project, owner, name: string, loc := #caller_location) {
	r, ok := parse_remote_url(url)
	defer remote_destroy(&r)
	testing.expect(t, ok, url, loc = loc)
	testing.expect_value(t, r.kind, kind, loc)
	testing.expect_value(t, r.host, host, loc)
	testing.expect_value(t, r.project, project, loc)
	testing.expect_value(t, r.owner, owner, loc)
	testing.expect_value(t, r.name, name, loc)
}

@(test)
test_detect_github_https :: proc(t: ^testing.T) {
	_expect_remote(t, "https://github.com/odin-lang/Odin.git", .GitHub, "github.com", "odin-lang/Odin", "odin-lang", "Odin")
	_expect_remote(t, "https://github.com/odin-lang/Odin", .GitHub, "github.com", "odin-lang/Odin", "odin-lang", "Odin")
	_expect_remote(t, "https://user:secret@github.com/a/b.git/\n", .GitHub, "github.com", "a/b", "a", "b")
	_expect_remote(t, "https://github.acme.corp/team/svc.git", .GitHub, "github.acme.corp", "team/svc", "team", "svc")
}

@(test)
test_detect_github_ssh :: proc(t: ^testing.T) {
	_expect_remote(t, "git@github.com:odin-lang/Odin.git", .GitHub, "github.com", "odin-lang/Odin", "odin-lang", "Odin")
	_expect_remote(t, "ssh://git@github.com/odin-lang/Odin.git", .GitHub, "github.com", "odin-lang/Odin", "odin-lang", "Odin")
	_expect_remote(t, "git@GitHub.com:A/B", .GitHub, "github.com", "A/B", "A", "B")
}

@(test)
test_detect_gitlab_self_hosted :: proc(t: ^testing.T) {
	_expect_remote(t, "https://gitlab.com/group/proj.git", .GitLab, "gitlab.com", "group/proj", "group", "proj")
	_expect_remote(t, "ssh://git@gitlab.empresa.com.br:2222/time/app.git", .GitLab, "gitlab.empresa.com.br", "time/app", "time", "app")
	_expect_remote(t, "https://ci-user@gitlab.empresa.com.br/time/app.git", .GitLab, "gitlab.empresa.com.br", "time/app", "time", "app")
	// http(s) port is the API port: kept.
	_expect_remote(t, "https://gitlab.local:8443/time/app.git", .GitLab, "gitlab.local:8443", "time/app", "time", "app")
}

@(test)
test_detect_gitlab_subgroups_ssh_url :: proc(t: ^testing.T) {
	_expect_remote(t, "https://gitlab.com/group/sub/proj", .GitLab, "gitlab.com", "group/sub/proj", "group/sub", "proj")
	_expect_remote(t, "git@gitlab.com:group/sub/deeper/proj.git", .GitLab, "gitlab.com", "group/sub/deeper/proj", "group/sub/deeper", "proj")
}

@(test)
test_detect_unknown_host :: proc(t: ^testing.T) {
	_expect_remote(t, "https://bitbucket.org/a/b.git", .Unknown, "bitbucket.org", "a/b", "a", "b")
	for bad in ([]string{"", "not a url", "https://github.com/", "git@github.com:onlyowner", "/local/path/repo"}) {
		r, ok := parse_remote_url(bad)
		testing.expectf(t, !ok, "should not parse %q", bad)
		remote_destroy(&r)
	}
}

@(test)
test_detect_api_urls :: proc(t: ^testing.T) {
	gh, _ := parse_remote_url("git@github.com:a/b.git");          defer remote_destroy(&gh)
	ghe, _ := parse_remote_url("https://github.acme.corp/a/b");    defer remote_destroy(&ghe)
	gl, _ := parse_remote_url("git@gitlab.x.io:g/sub/p.git");      defer remote_destroy(&gl)
	testing.expect_value(t, api_base(gh), "https://api.github.com")
	testing.expect_value(t, graphql_url(gh), "https://api.github.com/graphql")
	testing.expect_value(t, api_base(ghe), "https://github.acme.corp/api/v3")
	testing.expect_value(t, graphql_url(ghe), "https://github.acme.corp/api/graphql")
	testing.expect_value(t, api_base(gl), "https://gitlab.x.io/api/v4")
	testing.expect_value(t, graphql_url(gl), "https://gitlab.x.io/api/graphql")
	testing.expect_value(t, gitlab_project_id(gl), "g%2Fsub%2Fp")
	free_all(context.temp_allocator)
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

@(test)
test_parse_github_prs_graphql :: proc(t: ^testing.T) {
	prs, err := parse_github_prs(#load("testdata/github_prs_graphql.json", string))
	defer prs_destroy(prs)
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(prs), 3)
	if len(prs) != 3 { return }
	testing.expect_value(t, prs[0].number, 42)
	testing.expect_value(t, prs[0].title, "Add forge panel")
	testing.expect_value(t, prs[0].author, "alice")
	testing.expect_value(t, prs[0].source_branch, "feature/forge")
	testing.expect_value(t, prs[0].target_branch, "main")
	testing.expect_value(t, prs[0].checks, Status.Success)
	testing.expect_value(t, prs[0].draft, false)
	testing.expect_value(t, prs[1].checks, Status.Failure)
	testing.expect_value(t, prs[1].draft, true)
	testing.expect_value(t, prs[2].checks, Status.None) // no checks
	testing.expect_value(t, prs[2].author, "")          // deleted user
}

@(test)
test_parse_gitlab_mrs_graphql :: proc(t: ^testing.T) {
	prs, err := parse_gitlab_mrs(#load("testdata/gitlab_mrs_graphql.json", string))
	defer prs_destroy(prs)
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(prs), 2)
	if len(prs) != 2 { return }
	testing.expect_value(t, prs[0].number, 7) // iid is a string in GitLab GraphQL
	testing.expect_value(t, prs[0].author, "carol")
	testing.expect_value(t, prs[0].checks, Status.Running)
	testing.expect_value(t, prs[0].url, "https://gitlab.example.com/team/app/-/merge_requests/7")
	testing.expect_value(t, prs[1].checks, Status.None)
	testing.expect_value(t, prs[1].draft, true)
}

@(test)
test_parse_graphql_error :: proc(t: ^testing.T) {
	prs, err := parse_github_prs(#load("testdata/graphql_error.json", string))
	defer delete(err)
	testing.expect(t, prs == nil)
	testing.expect(t, strings.contains(err, "Could not resolve"), err)

	prs2, err2 := parse_github_prs("<html>502 Bad Gateway</html>")
	defer delete(err2)
	testing.expect(t, prs2 == nil)
	testing.expect(t, strings.contains(err2, "invalid JSON"), err2)
}

@(test)
test_check_state_mapping :: proc(t: ^testing.T) {
	testing.expect_value(t, github_rollup_status("SUCCESS"), Status.Success)
	testing.expect_value(t, github_rollup_status("ERROR"), Status.Failure)
	testing.expect_value(t, github_rollup_status("EXPECTED"), Status.Pending)
	testing.expect_value(t, github_rollup_status(""), Status.None)
	testing.expect_value(t, github_run_status("completed", "timed_out"), Status.Failure)
	testing.expect_value(t, github_run_status("completed", "cancelled"), Status.Canceled)
	testing.expect_value(t, github_run_status("in_progress", ""), Status.Running)
	testing.expect_value(t, github_run_status("queued", ""), Status.Pending)
	testing.expect_value(t, gitlab_status("SUCCESS"), Status.Success)
	testing.expect_value(t, gitlab_status("failed"), Status.Failure)
	testing.expect_value(t, gitlab_status("waiting_for_resource"), Status.Pending)
	testing.expect_value(t, gitlab_status("manual"), Status.Manual)
	testing.expect_value(t, gitlab_status("canceled"), Status.Canceled)
	free_all(context.temp_allocator)
}

@(test)
test_parse_github_runs :: proc(t: ^testing.T) {
	ps, err := parse_github_runs(#load("testdata/github_runs.json", string))
	defer pipelines_destroy(ps)
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(ps), 2)
	if len(ps) != 2 { return }
	testing.expect_value(t, ps[0].id, 9001)
	testing.expect_value(t, ps[0].name, "CI #120: Add forge panel")
	testing.expect_value(t, ps[0].branch, "feature/forge")
	testing.expect_value(t, ps[0].status, Status.Success)
	testing.expect_value(t, ps[1].name, "CI")
	testing.expect_value(t, ps[1].status, Status.Running)
	testing.expect_value(t, parse_github_first_run_id(#load("testdata/github_runs.json", string)), 9001)
	testing.expect_value(t, parse_github_first_run_id(`{"workflow_runs":[]}`), 0)
}

@(test)
test_parse_gitlab_pipelines :: proc(t: ^testing.T) {
	ps, err := parse_gitlab_pipelines(#load("testdata/gitlab_pipelines.json", string))
	defer pipelines_destroy(ps)
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(ps), 2)
	if len(ps) != 2 { return }
	testing.expect_value(t, ps[0].id, 555)
	testing.expect_value(t, ps[0].name, "Pipeline #555 (push)")
	testing.expect_value(t, ps[0].branch, "develop")
	testing.expect_value(t, ps[0].status, Status.Failure)
	testing.expect_value(t, ps[1].name, "Pipeline #554")
	testing.expect_value(t, ps[1].status, Status.Canceled)
}

@(test)
test_parse_github_jobs :: proc(t: ^testing.T) {
	js, err := parse_github_jobs(#load("testdata/github_jobs.json", string))
	defer jobs_destroy(js)
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(js), 2)
	if len(js) != 2 { return }
	testing.expect_value(t, js[0].id, 77)
	testing.expect_value(t, js[0].name, "build (macos)")
	testing.expect_value(t, js[0].stage, "CI")
	testing.expect_value(t, js[0].status, Status.Failure)
	testing.expect_value(t, js[0].duration, 150.0)
	testing.expect_value(t, js[1].status, Status.Pending)
	testing.expect_value(t, js[1].duration, 0.0)
}

@(test)
test_parse_gitlab_jobs :: proc(t: ^testing.T) {
	js, err := parse_gitlab_jobs(#load("testdata/gitlab_jobs.json", string))
	defer jobs_destroy(js)
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(js), 2)
	if len(js) != 2 { return }
	testing.expect_value(t, js[0].stage, "build")
	testing.expect_value(t, js[0].status, Status.Success)
	testing.expect_value(t, js[0].duration, 83.5)
	testing.expect_value(t, js[1].status, Status.Manual)
}

@(test)
test_parse_github_comments :: proc(t: ^testing.T) {
	cs, err := parse_github_comments(#load("testdata/github_comments.json", string))
	defer comments_destroy(cs)
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(cs), 2)
	if len(cs) != 2 { return }
	testing.expect_value(t, cs[0].author, "bob")
	testing.expect_value(t, cs[0].body, "LGTM, one nit:\nrename `foo`")
	testing.expect_value(t, cs[1].body, "Done ✅")
}

@(test)
test_parse_gitlab_notes_skips_system :: proc(t: ^testing.T) {
	cs, err := parse_gitlab_notes(#load("testdata/gitlab_notes.json", string))
	defer comments_destroy(cs)
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(cs), 2)
	if len(cs) != 2 { return }
	testing.expect_value(t, cs[0].author, "erin") // oldest first
	testing.expect_value(t, cs[1].author, "carol")
}

@(test)
test_parse_gitlab_mr_diffs :: proc(t: ^testing.T) {
	d, err := parse_gitlab_mr_diffs(#load("testdata/gitlab_mr_diffs.json", string))
	defer delete(d)
	testing.expect_value(t, err, "")
	want := "diff --git a/src/a.odin b/src/a.odin\n--- a/src/a.odin\n+++ b/src/a.odin\n@@ -1,2 +1,2 @@\n-old line\n+new line\n context\n" +
	        "diff --git a/docs/new.md b/docs/new.md\nnew file\n--- /dev/null\n+++ b/docs/new.md\n@@ -0,0 +1 @@\n+# hello\n"
	testing.expect_value(t, d, want)
}

// ---------------------------------------------------------------------------
// Transport / requests
// ---------------------------------------------------------------------------

@(test)
test_github_diff_request_uses_diff_media_type :: proc(t: ^testing.T) {
	r, _ := parse_remote_url("git@github.com:acme/editor.git"); defer remote_destroy(&r)
	argv := build_cli_argv(r, req_pr_diff(r, 42))
	testing.expect(t, slice.contains(argv, "Accept: application/vnd.github.diff"))
	testing.expect(t, slice.contains(argv, "repos/acme/editor/pulls/42"))
	testing.expect_value(t, argv[0], "gh")
	free_all(context.temp_allocator)
}

@(test)
test_curl_token_goes_to_stdin :: proc(t: ^testing.T) {
	TOKEN :: "ghp_SECRETSECRET"
	r, _ := parse_remote_url("git@github.com:acme/editor.git"); defer remote_destroy(&r)
	argv, stdin := build_curl(r, req_post_comment(r, 42, `he said "hi"`), TOKEN)
	for a in argv { testing.expectf(t, !strings.contains(a, TOKEN), "token leaked in argv: %q", a) }
	testing.expect_value(t, stdin, "Authorization: Bearer " + TOKEN + "\n")
	testing.expect(t, slice.contains(argv, "@-"))
	testing.expect(t, slice.contains(argv, `{"body":"he said \"hi\""}`))
	testing.expect_value(t, argv[len(argv) - 1], "https://api.github.com/repos/acme/editor/issues/42/comments")

	gl, _ := parse_remote_url("https://gitlab.example.com/team/app.git"); defer remote_destroy(&gl)
	_, stdin2 := build_curl(gl, req_list_prs(gl), "glpat-x")
	testing.expect_value(t, stdin2, "PRIVATE-TOKEN: glpat-x\n")
	free_all(context.temp_allocator)
}

@(test)
test_graphql_body_and_cli_fields :: proc(t: ^testing.T) {
	gl, _ := parse_remote_url("https://gitlab.example.com/team/app.git"); defer remote_destroy(&gl)
	req := req_list_prs(gl)
	body := build_json_body(req)
	testing.expect(t, strings.has_prefix(body, `{"query":"query($fullPath: ID!)`), body)
	testing.expect(t, strings.has_suffix(body, `"variables":{"fullPath":"team/app"}}`), body)
	testing.expect_value(t, request_url(gl, req), "https://gitlab.example.com/api/graphql")
	argv := build_cli_argv(gl, req)
	testing.expect_value(t, argv[0], "glab")
	testing.expect(t, slice.contains(argv, "fullPath=team/app"))
	testing.expect(t, slice.contains(argv, "gitlab.example.com"))
	free_all(context.temp_allocator)
}

@(test)
test_trigger_and_retry_requests :: proc(t: ^testing.T) {
	gh, _ := parse_remote_url("git@github.com:acme/editor.git"); defer remote_destroy(&gh)
	gl, _ := parse_remote_url("git@gitlab.com:g/sub/app.git");   defer remote_destroy(&gl)
	r := req_retry_job(gh, 77)
	testing.expect_value(t, r.method, "POST")
	testing.expect_value(t, r.path, "repos/acme/editor/actions/jobs/77/rerun")
	r = req_retry_job(gl, 901)
	testing.expect_value(t, r.path, "projects/g%2Fsub%2Fapp/jobs/901/retry")
	r = req_trigger_gitlab(gl, "feature/x")
	testing.expect_value(t, r.path, "projects/g%2Fsub%2Fapp/pipeline")
	testing.expect_value(t, r.fields[0], Field{"ref", "feature/x"})
	testing.expect_value(t, req_latest_run(gh, "feature/x y").path, "repos/acme/editor/actions/runs?branch=feature%2Fx%20y&per_page=1")
	testing.expect_value(t, req_rerun_run(gh, 9001).path, "repos/acme/editor/actions/runs/9001/rerun")
	testing.expect_value(t, req_list_jobs(gl, 555).path, "projects/g%2Fsub%2Fapp/pipelines/555/jobs?per_page=100")
	free_all(context.temp_allocator)
}

@(test)
test_post_comment_request :: proc(t: ^testing.T) {
	gl, _ := parse_remote_url("git@gitlab.com:g/app.git"); defer remote_destroy(&gl)
	r := req_post_comment(gl, 7, "olá\nmundo")
	testing.expect_value(t, r.method, "POST")
	testing.expect_value(t, r.path, "projects/g%2Fapp/merge_requests/7/notes")
	testing.expect_value(t, build_json_body(r), `{"body":"olá\nmundo"}`)
	testing.expect_value(t, req_list_comments(gl, 7).path, "projects/g%2Fapp/merge_requests/7/notes?per_page=100&sort=desc")
	free_all(context.temp_allocator)
}

@(test)
test_curl_http_error_message :: proc(t: ^testing.T) {
	body, status := split_curl_output(string(#load("testdata/github_error_401.json", string)) + "\n401")
	testing.expect_value(t, status, 401)
	r, _ := parse_remote_url("git@github.com:acme/editor.git"); defer remote_destroy(&r)
	msg := error_message(r, .Curl, Exec_Result{started = true}, status, body)
	defer delete(msg)
	testing.expect(t, strings.has_prefix(msg, "HTTP 401: Bad credentials"), msg)
	testing.expect(t, strings.contains(msg, "Forge: Set Token"), msg)

	net := error_message(r, .Curl, Exec_Result{started = true, exit_code = 6, stderr = "curl: (6) Could not resolve host: api.github.com\n"}, 0, "")
	defer delete(net)
	testing.expect_value(t, net, "network error: curl: (6) Could not resolve host: api.github.com")

	missing := error_message(r, .CLI, Exec_Result{}, 0, "")
	defer delete(missing)
	testing.expect_value(t, missing, "gh not found on PATH")
	free_all(context.temp_allocator)
}

// ---------------------------------------------------------------------------
// Tokens
// ---------------------------------------------------------------------------

@(test)
test_token_valid_and_file_format :: proc(t: ^testing.T) {
	testing.expect(t, token_valid("ghp_abcDEF123"))
	testing.expect(t, token_valid("glpat-xx.yy"))
	testing.expect(t, !token_valid(""))
	testing.expect(t, !token_valid(`a"b`))
	testing.expect(t, !token_valid("a b"))
	testing.expect(t, !token_valid("a\nb"))

	c := token_file_update("github.com old\ngitlab.x tok2\n", "github.com", "new")
	testing.expect_value(t, c, "gitlab.x tok2\ngithub.com new\n")
	tok, ok := token_file_lookup(c, "github.com")
	defer delete(tok)
	testing.expect(t, ok)
	testing.expect_value(t, tok, "new")
	_, ok2 := token_file_lookup(c, "nope")
	testing.expect(t, !ok2)
	free_all(context.temp_allocator)
}

// Single-test recorder for the token store (no other test uses it).
@(private="file") _rec_mutex: sync.Mutex
@(private="file") _rec_argv:  [dynamic]string
@(private="file") _rec_stdin: [dynamic]string
@(private="file") _rec_saved: string

@(private="file")
_recording_exec :: proc(argv: []string, stdin_data: string, dir: string, allocator := context.allocator) -> Exec_Result {
	sync.mutex_lock(&_rec_mutex)
	defer sync.mutex_unlock(&_rec_mutex)
	append(&_rec_argv, strings.join(argv, " "))
	append(&_rec_stdin, strings.clone(stdin_data))
	switch argv[0] {
	case "security":
		if len(argv) > 1 && argv[1] == "-i" {
			// emulate the keychain: remember the -w "..." value
			if i := strings.index(stdin_data, `-w "`); i >= 0 {
				rest := stdin_data[i + 4:]
				delete(_rec_saved)
				_rec_saved = strings.clone(rest[:strings.index_byte(rest, '"')])
			}
			return {started = true}
		}
		return {started = true, stdout = strings.concatenate({_rec_saved, "\n"}, allocator)}
	case "secret-tool":
		if argv[1] == "store" { delete(_rec_saved); _rec_saved = strings.clone(stdin_data) }
		return {started = true, stdout = strings.clone(_rec_saved, allocator)}
	}
	return {}
}

@(test)
test_token_store_uses_stdin_not_argv :: proc(t: ^testing.T) {
	when ODIN_OS == .Darwin || ODIN_OS == .Linux {
		TOKEN :: "glpat-SECRET123"
		defer {
			for s in _rec_argv { delete(s) }
			for s in _rec_stdin { delete(s) }
			delete(_rec_argv); delete(_rec_stdin); delete(_rec_saved)
			_rec_argv = {}; _rec_stdin = {}; _rec_saved = ""
		}
		err := token_save(_recording_exec, "gitlab.example.com", TOKEN)
		testing.expect_value(t, err, "")
		for a in _rec_argv { testing.expectf(t, !strings.contains(a, TOKEN), "token in argv: %q", a) }
		found := false
		for s in _rec_stdin { if strings.contains(s, TOKEN) { found = true } }
		testing.expect(t, found, "token should be written through stdin")
		tok, ok := token_load(_recording_exec, "gitlab.example.com")
		defer delete(tok)
		testing.expect(t, ok)
		testing.expect_value(t, tok, TOKEN)
		bad := token_save(_recording_exec, "h", `x" -w "evil`)
		defer delete(bad)
		testing.expect(t, bad != "", "tokens with quotes are rejected")
	}
}

// ---------------------------------------------------------------------------
// Worker (end to end with a fake exec)
// ---------------------------------------------------------------------------

// Stateless fake: the start dir picks the scenario.
//   /repo/gh       GitHub via logged-in gh
//   /repo/neterr   GitLab via curl (token from the fake keychain) — network down
//   /repo/noauth   GitLab host with no CLI login and no token
//   /repo/bitbucket unknown forge
@(private="file")
_fake_exec :: proc(argv: []string, stdin_data: string, dir: string, allocator := context.allocator) -> Exec_Result {
	ok :: proc(s: string, allocator: Allocator_Type) -> Exec_Result { return {started = true, stdout = strings.clone(s, allocator)} }
	fail :: proc(code: int, msg: string, allocator: Allocator_Type) -> Exec_Result {
		return {started = true, exit_code = code, stderr = strings.clone(msg, allocator)}
	}
	time.sleep(time.Millisecond) // pretend to be slow
	switch argv[0] {
	case "git":
		switch {
		case argv[1] == "rev-parse" && argv[2] == "--show-toplevel": return ok(dir, allocator)
		case argv[1] == "rev-parse":                                 return ok("feature/forge\n", allocator)
		case argv[1] == "remote" && len(argv) > 2:
			switch dir {
			case "/repo/gh":        return ok("git@github.com:acme/editor.git\n", allocator)
			case "/repo/neterr":    return ok("https://gitlab.example.com/team/app.git\n", allocator)
			case "/repo/noauth":    return ok("https://gitlab.noauth.test/team/app.git\n", allocator)
			case "/repo/bitbucket": return ok("git@bitbucket.org:a/b.git\n", allocator)
			}
		}
		return fail(128, "fatal", allocator)
	case "gh":
		if argv[1] == "auth" { return ok("", allocator) }
		if slice.contains(argv, "graphql") { return ok(#load("testdata/github_prs_graphql.json", string), allocator) }
		return fail(1, "gh: Not Found (HTTP 404)", allocator)
	case "glab":
		return fail(1, "not logged in", allocator)
	case "security", "secret-tool":
		if slice.contains(argv, "gitlab.example.com") { return ok("glpat-test\n", allocator) }
		return fail(44, "item not found", allocator)
	case "curl":
		if strings.contains(argv[len(argv) - 1], "gitlab.example.com") {
			return fail(6, "curl: (6) Could not resolve host: gitlab.example.com", allocator)
		}
		return ok(`{"message":"401 Unauthorized"}` + "\n401", allocator)
	}
	return {}
}

@(private="file") Allocator_Type :: runtime.Allocator

@(private="file")
_run_one :: proc(t: ^testing.T, start_dir: string, op: Op, number: i64 = 0) -> Result {
	c: Client
	client_start(&c, start_dir, _fake_exec)
	defer client_stop(&c)
	seq := client_submit(&c, op, number)
	results: [dynamic]Result
	defer delete(results)
	deadline := time.tick_now()
	for len(results) == 0 {
		client_poll(&c, &results) // non-blocking, like the UI frame loop
		if time.tick_since(deadline) > 5 * time.Second { testing.fail_now(t, "worker timed out") }
		time.sleep(time.Millisecond)
	}
	testing.expect_value(t, len(results), 1)
	testing.expect_value(t, results[0].seq, seq)
	testing.expect_value(t, client_pending(&c), 0)
	return results[0]
}

@(test)
test_worker_lists_prs_off_ui_thread :: proc(t: ^testing.T) {
	r := _run_one(t, "/repo/gh", .List_PRs)
	defer result_destroy(&r)
	testing.expect_value(t, r.err, "")
	testing.expect_value(t, len(r.prs), 3)
	testing.expect_value(t, r.remote.kind, Kind.GitHub)
	testing.expect_value(t, r.auth_source, "gh")
	testing.expect_value(t, r.branch, "feature/forge")
}

@(test)
test_worker_reports_network_error :: proc(t: ^testing.T) {
	r := _run_one(t, "/repo/neterr", .List_Pipelines)
	defer result_destroy(&r)
	testing.expect(t, strings.has_prefix(r.err, "network error: curl: (6)"), r.err)
	testing.expect(t, r.pipelines == nil)
	testing.expect_value(t, r.remote.kind, Kind.GitLab)
}

@(test)
test_worker_reports_missing_auth :: proc(t: ^testing.T) {
	r := _run_one(t, "/repo/noauth", .List_PRs)
	defer result_destroy(&r)
	// Either "not authenticated ..." or, when GITLAB_TOKEN is set on this
	// machine, the 401 from the fake API — both point the user at the token.
	testing.expect(t, r.err != "", "expected an error")
	testing.expect(t, strings.contains(r.err, "token") || strings.contains(r.err, "Token"), r.err)

	u := _run_one(t, "/repo/bitbucket", .List_PRs)
	defer result_destroy(&u)
	testing.expect(t, strings.contains(u.err, "not GitHub or GitLab"), u.err)
}

@(test)
test_auth_prefers_cli_then_token :: proc(t: ^testing.T) {
	gh, _ := parse_remote_url("git@github.com:acme/editor.git"); defer remote_destroy(&gh)
	a := resolve_auth(_fake_exec, gh)
	testing.expect_value(t, a.transport, Transport.CLI)
	auth_destroy(&a)

	gl, _ := parse_remote_url("https://gitlab.example.com/team/app.git"); defer remote_destroy(&gl)
	b := resolve_auth(_fake_exec, gl)
	defer auth_destroy(&b)
	testing.expect_value(t, b.transport, Transport.Curl) // glab not logged in → token
	testing.expect(t, b.token != "")
}
