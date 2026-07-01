package lsp

import "core:sync"

// ---------------------------------------------------------------------------
// Write queue — mutex + condvar for efficient blocking write thread
// ---------------------------------------------------------------------------

Write_Queue :: struct {
	items: [dynamic][]u8, // owned slices
	mu:    sync.Mutex,
	cond:  sync.Cond,
	done:  bool,
}

wq_init :: proc(q: ^Write_Queue) {
	q.items = make([dynamic][]u8)
}

wq_destroy :: proc(q: ^Write_Queue) {
	for item in q.items { delete(item) }
	delete(q.items)
}

wq_push :: proc(q: ^Write_Queue, data: []u8) {
	sync.mutex_lock(&q.mu)
	append(&q.items, data)
	sync.mutex_unlock(&q.mu)
	sync.cond_signal(&q.cond)
}

wq_stop :: proc(q: ^Write_Queue) {
	sync.mutex_lock(&q.mu)
	q.done = true
	sync.mutex_unlock(&q.mu)
	sync.cond_signal(&q.cond)
}

// ---------------------------------------------------------------------------
// Read queue — inbox messages from server
// ---------------------------------------------------------------------------

Read_Queue :: struct {
	items: [dynamic]Inbox_Message,
	mu:    sync.Mutex,
}

rq_init :: proc(q: ^Read_Queue) {
	q.items = make([dynamic]Inbox_Message)
}

rq_destroy :: proc(q: ^Read_Queue) {
	for &m in q.items { delete(m.body) }
	delete(q.items)
}

rq_push :: proc(q: ^Read_Queue, msg: Inbox_Message) {
	sync.mutex_lock(&q.mu)
	append(&q.items, msg)
	sync.mutex_unlock(&q.mu)
}

// Drain all pending items into out. Caller owns the returned bodies.
rq_drain :: proc(q: ^Read_Queue, out: ^[dynamic]Inbox_Message) {
	sync.mutex_lock(&q.mu)
	for &m in q.items { append(out, m) }
	clear(&q.items)
	sync.mutex_unlock(&q.mu)
}
