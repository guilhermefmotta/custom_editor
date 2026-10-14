package git

// ===========================================================================
// Async git queue — ADR 0001 ("camada git assíncrona")
//
// Every new git query/operation goes through a Git_Queue: the UI thread only
// enqueues requests and reads finished results; git itself runs on one worker
// thread per queue (started lazily on the first request). Jobs run strictly in
// FIFO order, so a screen may enqueue "operation, then re-query" and get them
// in that order.
//
// Each Git_Manager owns a queue (`m.queue`, bound to `m.root`). It is pumped by
// git_manager_update (already called every frame), which runs callbacks.
//
// Lifecycle of a request (all procs below are main-thread procs):
//
//     id := git_request_log(&m.queue, {skip = 0, limit = 500})   // returns at once
//     ...
//     // every frame:
//     page, st, err := git_poll_as(&m.queue, id, Log_Page)
//     switch st {
//     case .Queued, .Running: // draw a spinner
//     case .Done:   use(page^)      // ^Log_Page valid until released
//     case .Failed: show(err)
//     case .Unknown: // id never existed or already released
//     }
//     ...
//     git_release(&m.queue, id)   // frees EVERYTHING in the result at once
//
// git_release also cancels: a queued job is dropped, a running one is
// discarded when it finishes. Re-requesting (e.g. next log page, refresh) is
// just a new id; release the old one when you no longer draw it.
//
// Callback style (instead of polling):
//
//     id := git_request_branches(&m.queue)
//     git_on_done(&m.queue, id, proc(r: ^Git_Result, user: rawptr) {
//         branches := r.payload.([]Branch)  // copy what you keep!
//     }, my_screen)
//
//   The callback runs on the main thread inside git_queue_update and the
//   result is released right after it returns.
//
// Memory: each job owns a mem.Dynamic_Arena (backed by the queue allocator).
// Everything in a result (strings, slices, File_Diff rows...) lives in it and
// is freed by git_release / after the callback. Never free pieces of a result
// (file_diff_destroy etc. on a result is unnecessary — and a no-op).
//
// Request procs (payload type in parentheses — use it with git_poll_as):
//   git_request_log(q, Log_Options)                      (Log_Page)
//   git_request_commit_detail(q, rev)                    (Commit_Detail)
//   git_request_commit_file_diff(q, rev, path, old_path) (File_Diff)
//   git_request_branches(q)                              ([]Branch)
//   git_request_remotes(q)                               ([]Remote)
//   git_request_tags(q)                                  ([]Tag)
//   git_request_stashes(q)                               ([]Stash)
//   git_request_reflog(q, ref, skip, limit)              ([]Reflog_Entry)
//   git_request_submodules(q)                            ([]Submodule)
//   git_request_file_at(q, rev, path)                    (File_Blob)
//   git_request_conflict(q, path)                        (Conflict_Stages)
//   git_request_repo_state(q)                            (Repo_State)
//   git_request_command(q, args)                         (Command_Output)  raw `git <args>`
//   git_request_custom(q, work, args, user)              (whatever `work` returns)
//
// Screen-specific operations (ADR: `git/<tela>_ops*.odin`) should be written
// as a Git_Work_Proc and enqueued with git_request_custom (or wrapped in their
// own `git_request_<op>` proc that calls it). Inside a work proc,
// context.allocator is the job arena; git_run / git_query_* may be called
// freely there — they are worker-side, synchronous procs and must NOT be
// called from the UI thread.
// ===========================================================================

import "core:mem"
import "core:sync"
import "core:thread"

Job_Id :: distinct u64 // 0 = no job

Job_Status :: enum u8 {
	Unknown, // never existed or already released
	Queued,
	Running,
	Done,
	Failed,
}

// Payload a screen-specific work proc returns: a pointer to its own struct
// allocated in the job arena (context.allocator inside the work proc).
Git_Custom :: struct {
	data: rawptr,
	type: typeid,
}

// Raw output of git_request_command.
Command_Output :: struct {
	output:    string, // stdout (stderr is discarded by git_run)
	exit_code: int,
}

Git_Payload :: union {
	Log_Page,
	Commit_Detail,
	File_Diff,
	[]Branch,
	[]Remote,
	[]Tag,
	[]Stash,
	[]Reflog_Entry,
	[]Submodule,
	File_Blob,
	Conflict_Stages,
	Repo_State,
	Command_Output,
	Git_Custom,
}

Git_Result :: struct {
	id:      Job_Id,
	status:  Job_Status,
	payload: Git_Payload,
	err:     string, // non-empty when status == .Failed
}

// Runs on the worker thread with context.allocator = job arena. Return
// err != "" to fail the job.
Git_Work_Proc :: #type proc(root: string, args: []string, user: rawptr) -> (payload: Git_Payload, err: string)

// Main-thread completion callback (see git_on_done).
Git_Callback :: #type proc(result: ^Git_Result, user: rawptr)

Request_Kind :: enum u8 {
	Log,
	Commit_Detail,
	Commit_File_Diff,
	Branches,
	Remotes,
	Tags,
	Stashes,
	Reflog,
	Submodules,
	File_At,
	Conflict,
	Repo_State,
	Command,
	Custom,
}

@(private)
Git_Request :: struct {
	kind:     Request_Kind,
	log:      Log_Options,
	rev:      string,
	path:     string,
	old_path: string,
	skip:     int,
	limit:    int,
	args:     []string,
	work:     Git_Work_Proc,
	user:     rawptr,
}

@(private)
Git_Job :: struct {
	using result: Git_Result,
	req:          Git_Request,
	arena:        mem.Dynamic_Arena,
	discard:      bool, // released while running
	callback:     Git_Callback,
	cb_user:      rawptr,
}

Git_Queue :: struct {
	root:      string, // owned
	allocator: mem.Allocator,

	mu:      sync.Mutex,
	cond:    sync.Cond,
	pending: [dynamic]^Git_Job, // FIFO, front = next
	jobs:    map[Job_Id]^Git_Job, // every live job (queued/running/finished)
	next_id: Job_Id,
	quit:    bool,
	worker:  ^thread.Thread,
	inited:  bool,
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

git_queue_init :: proc(q: ^Git_Queue, root: string, allocator := context.allocator) {
	q.allocator = allocator
	q.root      = clone_str(root, allocator)
	q.pending   = make([dynamic]^Git_Job, allocator)
	q.jobs      = make(map[Job_Id]^Git_Job, allocator)
	q.next_id   = 1
	q.inited    = true
}

// Stops the worker (waits for the running git command to finish) and frees
// every job, released or not. Safe on a zero / never-initialised queue.
git_queue_destroy :: proc(q: ^Git_Queue) {
	if !q.inited { return }
	sync.mutex_lock(&q.mu)
	q.quit = true
	sync.cond_broadcast(&q.cond)
	sync.mutex_unlock(&q.mu)
	if q.worker != nil {
		thread.join(q.worker)
		thread.destroy(q.worker)
		q.worker = nil
	}
	for _, job in q.jobs { _job_free(q, job) }
	delete(q.jobs)
	delete(q.pending)
	delete(q.root, q.allocator)
	q^ = {}
}

// Call once per frame on the main thread: runs git_on_done callbacks of
// finished jobs (and releases those jobs).
git_queue_update :: proc(q: ^Git_Queue) {
	if !q.inited { return }
	ready := make([dynamic]^Git_Job, context.temp_allocator)
	sync.mutex_lock(&q.mu)
	for _, job in q.jobs {
		if job.callback != nil && (job.status == .Done || job.status == .Failed) {
			append(&ready, job)
		}
	}
	for job in ready { delete_key(&q.jobs, job.id) }
	sync.mutex_unlock(&q.mu)

	// stable order: completion order == FIFO == id order
	for i in 1..<len(ready) {
		for j := i; j > 0 && ready[j-1].id > ready[j].id; j -= 1 {
			ready[j-1], ready[j] = ready[j], ready[j-1]
		}
	}
	for job in ready {
		job.callback(&job.result, job.cb_user)
		_job_free(q, job)
	}
}

// Number of jobs waiting or running (handy for a "git busy" indicator).
git_queue_busy :: proc(q: ^Git_Queue) -> int {
	if !q.inited { return 0 }
	sync.mutex_guard(&q.mu)
	n := 0
	for _, job in q.jobs {
		if job.status == .Queued || job.status == .Running { n += 1 }
	}
	return n
}

// ---------------------------------------------------------------------------
// Reading results
// ---------------------------------------------------------------------------

// Current status of `id`. When .Done/.Failed the returned pointer is valid
// (and immutable) until git_release(q, id).
git_poll :: proc(q: ^Git_Queue, id: Job_Id) -> (result: ^Git_Result, status: Job_Status) {
	if !q.inited || id == 0 { return nil, .Unknown }
	sync.mutex_guard(&q.mu)
	job, ok := q.jobs[id]
	if !ok || job.discard { return nil, .Unknown }
	if job.status == .Done || job.status == .Failed { return &job.result, job.status }
	return nil, job.status
}

// Typed poll: value != nil only when status == .Done and the payload is a T.
git_poll_as :: proc(q: ^Git_Queue, id: Job_Id, $T: typeid) -> (value: ^T, status: Job_Status, err: string) {
	r, st := git_poll(q, id)
	if r == nil { return nil, st, "" }
	if st == .Failed { return nil, st, r.err }
	v, ok := &r.payload.(T)
	if !ok { return nil, .Failed, "unexpected payload type" }
	return v, st, ""
}

// Frees the result of `id` (or cancels it if still queued/running).
git_release :: proc(q: ^Git_Queue, id: Job_Id) {
	if !q.inited || id == 0 { return }
	sync.mutex_lock(&q.mu)
	job, ok := q.jobs[id]
	if !ok { sync.mutex_unlock(&q.mu); return }
	switch job.status {
	case .Running:
		job.discard = true // worker frees it when done
		sync.mutex_unlock(&q.mu)
		return
	case .Queued:
		for p, i in q.pending {
			if p == job { ordered_remove(&q.pending, i); break }
		}
	case .Done, .Failed, .Unknown:
	}
	delete_key(&q.jobs, id)
	sync.mutex_unlock(&q.mu)
	_job_free(q, job)
}

// Registers a main-thread callback for `id`; it fires from git_queue_update
// (also if the job already finished) and the job is released afterwards.
git_on_done :: proc(q: ^Git_Queue, id: Job_Id, cb: Git_Callback, user: rawptr = nil) {
	if !q.inited || id == 0 { return }
	sync.mutex_guard(&q.mu)
	if job, ok := q.jobs[id]; ok {
		job.callback = cb
		job.cb_user  = user
	}
}

// ---------------------------------------------------------------------------
// Requests
// ---------------------------------------------------------------------------

git_request_log :: proc(q: ^Git_Queue, opts: Log_Options) -> Job_Id {
	return _enqueue(q, Git_Request{kind = .Log, log = opts})
}

// Full message + changed files of `rev` (vs. its first parent).
git_request_commit_detail :: proc(q: ^Git_Queue, rev: string) -> Job_Id {
	return _enqueue(q, Git_Request{kind = .Commit_Detail, rev = rev})
}

// Whole-file side-by-side diff of `path` in commit `rev` vs. its first parent
// (root commit: everything added). Pass old_path for renames.
git_request_commit_file_diff :: proc(q: ^Git_Queue, rev, path: string, old_path := "") -> Job_Id {
	return _enqueue(q, Git_Request{kind = .Commit_File_Diff, rev = rev, path = path, old_path = old_path})
}

git_request_branches :: proc(q: ^Git_Queue) -> Job_Id {
	return _enqueue(q, Git_Request{kind = .Branches})
}

git_request_remotes :: proc(q: ^Git_Queue) -> Job_Id {
	return _enqueue(q, Git_Request{kind = .Remotes})
}

git_request_tags :: proc(q: ^Git_Queue) -> Job_Id {
	return _enqueue(q, Git_Request{kind = .Tags})
}

git_request_stashes :: proc(q: ^Git_Queue) -> Job_Id {
	return _enqueue(q, Git_Request{kind = .Stashes})
}

// Reflog of `ref` ("" = HEAD), newest first. limit <= 0 → 200.
git_request_reflog :: proc(q: ^Git_Queue, ref := "", skip := 0, limit := 0) -> Job_Id {
	return _enqueue(q, Git_Request{kind = .Reflog, rev = ref, skip = skip, limit = limit})
}

git_request_submodules :: proc(q: ^Git_Queue) -> Job_Id {
	return _enqueue(q, Git_Request{kind = .Submodules})
}

// Content of `path` (relative to repo root) at `rev` ("HEAD", branch, hash...).
git_request_file_at :: proc(q: ^Git_Queue, rev, path: string) -> Job_Id {
	return _enqueue(q, Git_Request{kind = .File_At, rev = rev, path = path})
}

// Base/ours/theirs index stages of a conflicted `path`.
git_request_conflict :: proc(q: ^Git_Queue, path: string) -> Job_Id {
	return _enqueue(q, Git_Request{kind = .Conflict, path = path})
}

git_request_repo_state :: proc(q: ^Git_Queue) -> Job_Id {
	return _enqueue(q, Git_Request{kind = .Repo_State})
}

// Runs `git <args>` in the repo. Never fails at queue level: inspect
// Command_Output.exit_code.
git_request_command :: proc(q: ^Git_Queue, args: []string) -> Job_Id {
	return _enqueue(q, Git_Request{kind = .Command, args = args})
}

// Runs `work(root, args, user)` on the worker. `args` are copied; `user` is
// passed as-is and must stay valid until the job finishes (or is released).
git_request_custom :: proc(q: ^Git_Queue, work: Git_Work_Proc, args: []string = nil, user: rawptr = nil) -> Job_Id {
	return _enqueue(q, Git_Request{kind = .Custom, work = work, args = args, user = user})
}

// Helper for work procs: allocate a T in the job arena and wrap it.
git_custom_new :: proc($T: typeid) -> (^T, Git_Custom) {
	p := new(T)
	return p, Git_Custom{data = p, type = T}
}

// Helper for consumers: the custom payload as ^T (nil if another type).
git_custom_as :: proc(c: Git_Custom, $T: typeid) -> ^T {
	if c.type != T { return nil }
	return (^T)(c.data)
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

@(private)
_enqueue :: proc(q: ^Git_Queue, req: Git_Request) -> Job_Id {
	if !q.inited { return 0 }
	job := new(Git_Job, q.allocator)
	mem.dynamic_arena_init(&job.arena, q.allocator, q.allocator)
	a := mem.dynamic_arena_allocator(&job.arena)

	// Deep-copy the request into the job arena so the caller's strings may die
	r := req
	r.rev      = clone_str(req.rev, a)
	r.path     = clone_str(req.path, a)
	r.old_path = clone_str(req.old_path, a)
	r.log.rev    = clone_str(req.log.rev, a)
	r.log.path   = clone_str(req.log.path, a)
	r.log.grep   = clone_str(req.log.grep, a)
	r.log.author = clone_str(req.log.author, a)
	if req.args != nil {
		args := make([]string, len(req.args), a)
		for s, i in req.args { args[i] = clone_str(s, a) }
		r.args = args
	}
	job.req    = r
	job.status = .Queued

	sync.mutex_lock(&q.mu)
	job.id = q.next_id
	q.next_id += 1
	q.jobs[job.id] = job
	append(&q.pending, job)
	if q.worker == nil {
		t := thread.create(_worker_proc)
		t.data = q // no init_context: the thread keeps its own temp allocator
		q.worker = t
		thread.start(t)
	}
	sync.cond_signal(&q.cond)
	id := job.id
	sync.mutex_unlock(&q.mu)
	return id
}

@(private)
_job_free :: proc(q: ^Git_Queue, job: ^Git_Job) {
	mem.dynamic_arena_destroy(&job.arena)
	free(job, q.allocator)
}

@(private)
_worker_proc :: proc(t: ^thread.Thread) {
	q := (^Git_Queue)(t.data)
	context.allocator = q.allocator
	for {
		sync.mutex_lock(&q.mu)
		for len(q.pending) == 0 && !q.quit {
			sync.cond_wait(&q.cond, &q.mu)
		}
		if q.quit { sync.mutex_unlock(&q.mu); break }
		job := q.pending[0]
		ordered_remove(&q.pending, 0)
		job.status = .Running
		sync.mutex_unlock(&q.mu)

		payload: Git_Payload
		err: string
		{
			context.allocator = mem.dynamic_arena_allocator(&job.arena)
			payload, err = _execute(q.root, &job.req)
		}
		free_all(context.temp_allocator)

		sync.mutex_lock(&q.mu)
		if job.discard {
			delete_key(&q.jobs, job.id)
			sync.mutex_unlock(&q.mu)
			_job_free(q, job)
			continue
		}
		job.payload = payload
		job.err     = err
		job.status  = .Failed if err != "" else .Done
		sync.mutex_unlock(&q.mu)
	}
}

// Runs on the worker; context.allocator is the job arena.
@(private)
_execute :: proc(root: string, r: ^Git_Request) -> (Git_Payload, string) {
	switch r.kind {
	case .Log:
		v, err := git_query_log(root, r.log)
		return v, err
	case .Commit_Detail:
		v, err := git_query_commit_detail(root, r.rev)
		return v, err
	case .Commit_File_Diff:
		v, ok := git_diff_commit_file(root, r.rev, r.path, r.old_path)
		if !ok { return nil, "git diff failed" }
		return v, ""
	case .Branches:
		v, err := git_query_branches(root)
		return v, err
	case .Remotes:
		v, err := git_query_remotes(root)
		return v, err
	case .Tags:
		v, err := git_query_tags(root)
		return v, err
	case .Stashes:
		v, err := git_query_stashes(root)
		return v, err
	case .Reflog:
		v, err := git_query_reflog(root, r.rev, r.skip, r.limit)
		return v, err
	case .Submodules:
		v, err := git_query_submodules(root)
		return v, err
	case .File_At:
		v, err := git_query_file_at(root, r.rev, r.path)
		return v, err
	case .Conflict:
		v, err := git_query_conflict(root, r.path)
		return v, err
	case .Repo_State:
		v, err := git_query_repo_state(root)
		return v, err
	case .Command:
		out, code := git_run_raw(root, r.args)
		return Command_Output{output = out, exit_code = code}, ""
	case .Custom:
		if r.work == nil { return nil, "no work proc" }
		return r.work(root, r.args, r.user)
	}
	return nil, "unknown request"
}

@(private)
clone_str :: proc(s: string, allocator: mem.Allocator) -> string {
	if s == "" { return "" }
	b := make([]u8, len(s), allocator)
	copy(b, s)
	return string(b)
}
