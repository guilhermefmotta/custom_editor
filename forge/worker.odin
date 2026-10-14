package forge

// Worker thread + queues. The UI thread only calls client_submit /
// client_poll (non-blocking, mutex-protected); every subprocess (git, gh,
// glab, curl, security, secret-tool) runs on the worker. One worker per
// client, tasks run in FIFO order.
//
//   c: forge.Client
//   forge.client_start(&c, start_dir)            // spawns the thread
//   forge.client_submit(&c, .List_PRs)
//   // every frame:
//   results: [dynamic]forge.Result
//   forge.client_poll(&c, &results)              // takes ownership
//   for &r in results { ...; forge.result_destroy(&r) }
//   forge.client_stop(&c)                        // joins + frees

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:thread"
import "../wake"

Op :: enum u8 {
	Detect,           // find repo root + remote, resolve auth, current branch
	List_PRs,
	PR_Diff,          // number = PR
	List_Comments,    // number = PR
	Post_Comment,     // number = PR, text = body
	List_Pipelines,
	List_Jobs,        // number = pipeline id
	Trigger_Pipeline, // on the current branch
	Retry_Job,        // number = job id
	Save_Token,       // text = token (for the detected host)
}

@(private)
Task :: struct {
	op:     Op,
	seq:    u64,
	number: i64,
	text:   string, // heap-owned
}

// Everything heap-owned; free with result_destroy.
Result :: struct {
	op:     Op,
	seq:    u64,
	number: i64,
	err:    string, // "" = success
	// Detect (also refreshed in every result after a detect)
	remote:      Remote,
	auth_source: string, // static
	branch:      string,
	// payloads
	prs:       []Pull_Request,
	pipelines: []Pipeline,
	jobs:      []Job,
	comments:  []Comment,
	text:      string, // PR diff, or a success message
}

result_destroy :: proc(r: ^Result) {
	delete(r.err)
	remote_destroy(&r.remote)
	delete(r.branch)
	if r.prs != nil       { prs_destroy(r.prs) }
	if r.pipelines != nil { pipelines_destroy(r.pipelines) }
	if r.jobs != nil      { jobs_destroy(r.jobs) }
	if r.comments != nil  { comments_destroy(r.comments) }
	delete(r.text)
	r^ = {}
}

Client :: struct {
	exec:      Exec_Proc,
	start_dir: string, // heap-owned
	// worker-only state
	session:  Session,
	root:     string,
	branch:   string,
	detected: bool,
	// shared, under mutex
	mutex:   sync.Mutex,
	cond:    sync.Cond,
	tasks:   [dynamic]Task,
	results: [dynamic]Result,
	pending: int,
	quit:    bool,
	seq:     u64,
	thread:  ^thread.Thread,
}

client_start :: proc(c: ^Client, start_dir: string, exec: Exec_Proc = exec_process) {
	c.exec = exec
	c.session.exec = exec
	c.start_dir = strings.clone(start_dir)
	c.thread = thread.create(_worker)
	c.thread.data = c
	c.thread.init_context = context
	thread.start(c.thread)
}

client_running :: proc(c: ^Client) -> bool { return c.thread != nil }

client_stop :: proc(c: ^Client) {
	if c.thread == nil { return }
	sync.mutex_lock(&c.mutex)
	c.quit = true
	sync.cond_broadcast(&c.cond)
	sync.mutex_unlock(&c.mutex)
	thread.join(c.thread)
	thread.destroy(c.thread)
	for t in c.tasks { delete(t.text) }
	delete(c.tasks)
	for &r in c.results { result_destroy(&r) }
	delete(c.results)
	remote_destroy(&c.session.remote)
	auth_destroy(&c.session.auth)
	delete(c.root)
	delete(c.branch)
	delete(c.start_dir)
	c^ = {}
}

// Queues an op; returns its sequence number. `text` is copied.
client_submit :: proc(c: ^Client, op: Op, number: i64 = 0, text := "") -> u64 {
	sync.mutex_lock(&c.mutex)
	defer sync.mutex_unlock(&c.mutex)
	c.seq += 1
	append(&c.tasks, Task{op = op, seq = c.seq, number = number, text = strings.clone(text)})
	c.pending += 1
	sync.cond_signal(&c.cond)
	return c.seq
}

// Moves finished results into `out` (caller destroys each). Non-blocking.
client_poll :: proc(c: ^Client, out: ^[dynamic]Result) {
	if c.thread == nil { return }
	if !sync.mutex_try_lock(&c.mutex) { return }
	defer sync.mutex_unlock(&c.mutex)
	append(out, ..c.results[:])
	clear(&c.results)
}

client_pending :: proc(c: ^Client) -> int {
	sync.mutex_lock(&c.mutex)
	defer sync.mutex_unlock(&c.mutex)
	return c.pending
}

@(private)
_worker :: proc(t: ^thread.Thread) {
	c := (^Client)(t.data)
	// Own temp arena: never share the UI thread's (or the test runner's).
	context.temp_allocator = runtime.Allocator{runtime.default_temp_allocator_proc, &runtime.global_default_temp_allocator_data}
	defer runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
	for {
		sync.mutex_lock(&c.mutex)
		for len(c.tasks) == 0 && !c.quit { sync.cond_wait(&c.cond, &c.mutex) }
		if c.quit { sync.mutex_unlock(&c.mutex); return }
		task := c.tasks[0]
		ordered_remove(&c.tasks, 0)
		sync.mutex_unlock(&c.mutex)

		res := _run(c, task)
		delete(task.text)
		free_all(context.temp_allocator)

		sync.mutex_lock(&c.mutex)
		append(&c.results, res)
		c.pending -= 1
		sync.mutex_unlock(&c.mutex)
		wake.request() // ADR 0016: result ready → wake the UI loop
	}
}

@(private)
_git :: proc(c: ^Client, dir: string, args: ..string) -> (out: string, ok: bool) {
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, "git")
	append(&argv, ..args)
	res := c.exec(argv[:], "", dir)
	defer exec_result_destroy(&res)
	if !res.started || res.exit_code != 0 { return "", false }
	return strings.clone(strings.trim_space(res.stdout), context.temp_allocator), true
}

@(private)
_detect :: proc(c: ^Client) -> (err: string) {
	remote_destroy(&c.session.remote)
	auth_destroy(&c.session.auth)
	delete(c.root); c.root = ""
	delete(c.branch); c.branch = ""
	c.detected = false

	root, ok := _git(c, c.start_dir, "rev-parse", "--show-toplevel")
	if !ok { return strings.clone("not inside a git repository") }
	c.root = strings.clone(root)
	url: string
	url, ok = _git(c, c.root, "remote", "get-url", "origin")
	if !ok {
		// No "origin": use the first remote.
		names, ok2 := _git(c, c.root, "remote")
		first := names
		if nl := strings.index_byte(names, '\n'); nl >= 0 { first = names[:nl] }
		if !ok2 || first == "" { return strings.clone("repository has no remote") }
		url, ok = _git(c, c.root, "remote", "get-url", first)
		if !ok { return strings.clone("could not read the remote URL") }
	}
	r, pok := parse_remote_url(url)
	if !pok { return strings.concatenate({"unrecognized remote URL: ", url}) }
	c.session.remote = r
	if branch, bok := _git(c, c.root, "rev-parse", "--abbrev-ref", "HEAD"); bok { c.branch = strings.clone(branch) }
	if r.kind == .Unknown {
		return strings.concatenate({"remote host ", r.host, " is not GitHub or GitLab"})
	}
	c.session.auth = resolve_auth(c.exec, r)
	c.detected = true
	return ""
}

@(private)
_run :: proc(c: ^Client, t: Task) -> (res: Result) {
	res.op = t.op
	res.seq = t.seq
	res.number = t.number

	if t.op == .Detect || !c.detected {
		res.err = _detect(c)
	}
	if res.err == "" {
		s := &c.session
		switch t.op {
		case .Detect:
			if s.auth.transport == .None { res.err = not_authenticated_message(s.remote) }
		case .List_PRs:         res.prs, res.err = list_prs(s)
		case .PR_Diff:          res.text, res.err = pr_diff(s, t.number)
		case .List_Comments:    res.comments, res.err = list_comments(s, t.number)
		case .Post_Comment:     res.err = post_comment(s, t.number, t.text)
		case .List_Pipelines:   res.pipelines, res.err = list_pipelines(s)
		case .List_Jobs:        res.jobs, res.err = list_jobs(s, t.number)
		case .Trigger_Pipeline: res.text, res.err = trigger_pipeline(s, c.branch)
		case .Retry_Job:        res.err = retry_job(s, t.number)
		case .Save_Token:
			res.err = token_save(c.exec, s.remote.host, t.text)
			if res.err == "" {
				// Re-resolve so the new token is used (unless a CLI login wins).
				auth_destroy(&s.auth)
				s.auth = resolve_auth(c.exec, s.remote)
				res.text = strings.concatenate({"token saved for ", s.remote.host})
			}
		}
	}
	res.remote = remote_clone(c.session.remote)
	res.auth_source = c.session.auth.source
	res.branch = strings.clone(c.branch)
	return
}
