package forge

// HTTP through subprocesses (ADR 0008): Odin's core has no HTTPS client.
//   1. `gh api` / `glab api` when installed and logged in for the host —
//      reuses the user's CLI login, we never see or store a token;
//   2. otherwise `curl` with a token (env var or the OS secret store, see
//      token.odin). The Authorization header goes through curl's stdin
//      (`-H @-`), never argv.

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"

Transport :: enum u8 { None, CLI, Curl }

Auth :: struct {
	transport: Transport,
	token:     string, // heap-owned; only for .Curl
	source:    string, // static description: "gh", "glab", "keychain", "GH_TOKEN", ...
}

auth_destroy :: proc(a: ^Auth) {
	delete(a.token)
	a^ = {}
}

Field :: struct { key, value: string }

Request :: struct {
	method: string,  // "GET" | "POST"
	path:   string,  // REST path relative to the API root ("repos/o/r/pulls"), or "graphql"
	fields: []Field, // POST body fields / GraphQL: "query" + variables (all strings)
	accept: string,  // optional Accept header
}

USER_AGENT :: "custom_editor-forge"

cli_name :: proc(k: Kind) -> string {
	return "glab" if k == .GitLab else "gh"
}

// argv for `gh api` / `glab api`. Allocated with `allocator`.
build_cli_argv :: proc(r: Remote, req: Request, allocator := context.temp_allocator) -> []string {
	argv := make([dynamic]string, allocator)
	append(&argv, cli_name(r.kind), "api", "--hostname", r.host, "-X", req.method)
	if req.accept != "" { append(&argv, "-H", fmt.aprintf("Accept: %s", req.accept, allocator = allocator)) }
	append(&argv, req.path)
	for f in req.fields {
		append(&argv, "-f", fmt.aprintf("%s=%s", f.key, f.value, allocator = allocator))
	}
	return argv[:]
}

// Full URL for curl.
request_url :: proc(r: Remote, req: Request, allocator := context.temp_allocator) -> string {
	if req.path == "graphql" { return graphql_url(r, allocator) }
	return fmt.aprintf("%s/%s", api_base(r, context.temp_allocator), req.path, allocator = allocator)
}

// JSON body for curl ("" = none). GraphQL: {"query": q, "variables": {...}}.
build_json_body :: proc(req: Request, allocator := context.temp_allocator) -> string {
	if len(req.fields) == 0 { return "" }
	m := make(map[string]string, allocator = context.temp_allocator)
	query := ""
	for f in req.fields {
		if req.path == "graphql" && f.key == "query" { query = f.value; continue }
		m[f.key] = f.value
	}
	data: []byte
	if req.path == "graphql" {
		Body :: struct { query: string, variables: map[string]string }
		data, _ = json.marshal(Body{query, m}, allocator = allocator)
	} else {
		data, _ = json.marshal(m, allocator = allocator)
	}
	return string(data)
}

// curl argv + the stdin carrying the auth header.
build_curl :: proc(r: Remote, req: Request, token: string, allocator := context.temp_allocator) -> (argv: []string, stdin_data: string) {
	a := make([dynamic]string, allocator)
	append(&a, "curl", "-sS", "--max-time", "60", "-X", req.method)
	if token != "" { append(&a, "-H", "@-") } // auth header read from stdin
	append(&a, "-H", "User-Agent: " + USER_AGENT)
	accept := req.accept
	if accept == "" && r.kind == .GitHub { accept = "application/vnd.github+json" }
	if accept != "" { append(&a, "-H", fmt.aprintf("Accept: %s", accept, allocator = allocator)) }
	body := build_json_body(req, allocator)
	if body != "" {
		append(&a, "-H", "Content-Type: application/json", "--data-binary", body)
	} else if req.method == "POST" {
		append(&a, "--data-binary", "")
	}
	append(&a, "-w", "\n%{http_code}", request_url(r, req, allocator))

	if token == "" {
		stdin_data = ""
	} else if r.kind == .GitLab {
		stdin_data = fmt.aprintf("PRIVATE-TOKEN: %s\n", token, allocator = allocator)
	} else {
		stdin_data = fmt.aprintf("Authorization: Bearer %s\n", token, allocator = allocator)
	}
	return a[:], stdin_data
}

// Splits curl output produced with `-w "\n%{http_code}"`.
split_curl_output :: proc(out: string) -> (body: string, status: int) {
	nl := strings.last_index_byte(out, '\n')
	if nl < 0 {
		code, _ := strconv.parse_int(strings.trim_space(out))
		return "", code
	}
	code, _ := strconv.parse_int(strings.trim_space(out[nl + 1:]))
	return out[:nl], code
}

// Appends a hint when the failure looks like an auth problem. Heap-owned.
@(private)
_with_hint :: proc(r: Remote, msg: string) -> string {
	low := strings.to_lower(msg, context.temp_allocator)
	if strings.contains(low, "401") || strings.contains(low, "bad credentials") ||
	   strings.contains(low, "unauthorized") || strings.contains(low, "403") ||
	   strings.contains(low, "authentication") || strings.contains(low, "token") {
		return fmt.aprintf("%s — check the token (Forge: Set Token) or `%s auth login --hostname %s`", msg, cli_name(r.kind), r.host)
	}
	return strings.clone(msg)
}

// Builds the user-facing message for a failed request. Heap-owned.
error_message :: proc(r: Remote, t: Transport, res: Exec_Result, status: int, body: string) -> string {
	tool := cli_name(r.kind) if t == .CLI else "curl"
	if !res.started {
		return fmt.aprintf("%s not found on PATH", tool)
	}
	api_msg := api_error_message(body)
	defer delete(api_msg)
	stderr := strings.trim_space(res.stderr)
	if nl := strings.index_byte(stderr, '\n'); nl >= 0 { stderr = stderr[:nl] }
	msg: string
	switch {
	case t == .Curl && status > 0 && api_msg != "": msg = fmt.tprintf("HTTP %d: %s", status, api_msg)
	case t == .Curl && status > 0:                  msg = fmt.tprintf("HTTP %d", status)
	case stderr != "" && api_msg != "":             msg = fmt.tprintf("%s (%s)", stderr, api_msg)
	case stderr != "":                              msg = stderr
	case api_msg != "":                             msg = api_msg
	case:                                           msg = fmt.tprintf("%s exited with code %d", tool, res.exit_code)
	}
	if t == .Curl && status == 0 && stderr != "" { msg = fmt.tprintf("network error: %s", stderr) }
	return _with_hint(r, msg)
}

// Runs one request. ok: body is heap-owned (context.allocator); otherwise
// err is heap-owned. GraphQL "errors" are left to the parsers.
do_request :: proc(exec: Exec_Proc, r: Remote, auth: Auth, req: Request) -> (body: string, err: string) {
	switch auth.transport {
	case .None:
		// Anonymous access still works for reads on public projects (except
		// GitHub GraphQL, which always needs auth).
		if req.method != "GET" && !(r.kind == .GitLab && req.path == "graphql") || r.kind == .GitHub && req.path == "graphql" {
			return "", not_authenticated_message(r)
		}
		argv, _ := build_curl(r, req, "")
		res := exec(argv, "", "")
		defer exec_result_destroy(&res)
		b, status := split_curl_output(res.stdout)
		if !res.started || res.exit_code != 0 || status == 0 || status >= 400 {
			if status == 401 || status == 403 || status == 404 { return "", not_authenticated_message(r) }
			return "", error_message(r, .Curl, res, status, b)
		}
		return strings.clone(b), ""
	case .CLI:
		res := exec(build_cli_argv(r, req), "", "")
		defer exec_result_destroy(&res)
		if !res.started || res.exit_code != 0 {
			return "", error_message(r, .CLI, res, 0, res.stdout)
		}
		return strings.clone(res.stdout), ""
	case .Curl:
		argv, stdin_data := build_curl(r, req, auth.token)
		res := exec(argv, stdin_data, "")
		defer exec_result_destroy(&res)
		b, status := split_curl_output(res.stdout)
		if !res.started || res.exit_code != 0 || status == 0 || status >= 400 {
			return "", error_message(r, .Curl, res, status, b)
		}
		return strings.clone(b), ""
	}
	return "", strings.clone("unreachable")
}

not_authenticated_message :: proc(r: Remote) -> string {
	return fmt.aprintf("not authenticated for %s: run `%s auth login --hostname %s` or set a token (Forge: Set Token)",
	                   r.host, cli_name(r.kind), r.host)
}

// Picks how to talk to the host: logged-in CLI first, then a token (env var,
// then the OS secret store) over curl.
resolve_auth :: proc(exec: Exec_Proc, r: Remote) -> Auth {
	if r.kind == .Unknown { return {} }
	{
		res := exec([]string{cli_name(r.kind), "auth", "status", "--hostname", r.host}, "", "")
		defer exec_result_destroy(&res)
		if res.started && res.exit_code == 0 {
			return {transport = .CLI, source = cli_name(r.kind)}
		}
	}
	if tok, src, ok := token_from_env(r); ok {
		return {transport = .Curl, token = tok, source = src}
	}
	if tok, ok := token_load(exec, r.host); ok {
		return {transport = .Curl, token = tok, source = TOKEN_STORE_NAME}
	}
	return {}
}

// GH_TOKEN/GITHUB_TOKEN (github.com only — GH_ENTERPRISE_TOKEN for GHE),
// GITLAB_TOKEN/GL_TOKEN for GitLab. Heap-owned token.
token_from_env :: proc(r: Remote) -> (tok: string, source: string, ok: bool) {
	names: []string
	switch r.kind {
	case .GitHub:  names = _ENV_GITHUB[:] if r.host == "github.com" else _ENV_GHE[:]
	case .GitLab:  names = _ENV_GITLAB[:]
	case .Unknown: return
	}
	for n in names {
		v := _getenv(n)
		if v != "" { return v, n, true }
		delete(v)
	}
	return
}

@(private) _ENV_GITHUB := [?]string{"GH_TOKEN", "GITHUB_TOKEN"}
@(private) _ENV_GHE    := [?]string{"GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"}
@(private) _ENV_GITLAB := [?]string{"GITLAB_TOKEN", "GL_TOKEN"}
