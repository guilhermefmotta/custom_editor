package debug

import "core:net"
import "core:sync"

// ---------------------------------------------------------------------------
// Transport modes
// ---------------------------------------------------------------------------

Transport_Mode :: enum { Process, TCP }

// DAP: JSON-over-Content-Length. JDWP: raw binary length-prefixed packets
// (Java Debug Wire Protocol, spoken directly by a JVM's -agentlib:jdwp socket).
Protocol_Kind :: enum { DAP, JDWP }

// ---------------------------------------------------------------------------
// Write queue
// ---------------------------------------------------------------------------

Write_Queue :: struct {
	items: [dynamic][]u8,
	mu:    sync.Mutex,
	cond:  sync.Cond,
	done:  bool,
}

wq_init    :: proc(q: ^Write_Queue) { q.items = make([dynamic][]u8) }
wq_destroy :: proc(q: ^Write_Queue) { for item in q.items { delete(item) }; delete(q.items) }

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
// Read queue
// ---------------------------------------------------------------------------

Read_Queue :: struct {
	items: [dynamic]Inbox_Msg,
	mu:    sync.Mutex,
}

rq_init    :: proc(q: ^Read_Queue) { q.items = make([dynamic]Inbox_Msg) }
rq_destroy :: proc(q: ^Read_Queue) { for &m in q.items { delete(m.body) }; delete(q.items) }

rq_push :: proc(q: ^Read_Queue, msg: Inbox_Msg) {
	sync.mutex_lock(&q.mu)
	append(&q.items, msg)
	sync.mutex_unlock(&q.mu)
}

rq_drain :: proc(q: ^Read_Queue, out: ^[dynamic]Inbox_Msg) {
	sync.mutex_lock(&q.mu)
	for &m in q.items { append(out, m) }
	clear(&q.items)
	sync.mutex_unlock(&q.mu)
}

// ---------------------------------------------------------------------------
// JDWP handshake — literal 14-byte ASCII exchange before any framed packets
// ---------------------------------------------------------------------------

_jdwp_handshake :: proc(sock: net.TCP_Socket) -> (ok: bool, err: string) {
	hs := transmute([]u8)string(JDWP_HANDSHAKE)
	sent := 0
	for sent < len(hs) {
		n, e := net.send_tcp(sock, hs[sent:])
		if e != nil || n <= 0 { return false, "JDWP handshake send failed" }
		sent += n
	}
	buf: [14]u8
	got := 0
	for got < 14 {
		n, e := net.recv_tcp(sock, buf[got:])
		if e != nil || n <= 0 { return false, "JDWP handshake recv failed (target closed connection)" }
		got += n
	}
	if string(buf[:]) != JDWP_HANDSHAKE { return false, "handshake mismatch: not a JDWP endpoint" }
	return true, ""
}

// ---------------------------------------------------------------------------
// Content-Length header parser
// ---------------------------------------------------------------------------

_parse_header :: proc(data: []u8) -> (content_len: int, end: int) {
	i, n := 0, len(data)
	for i + 3 < n {
		if data[i]=='\r' && data[i+1]=='\n' && data[i+2]=='\r' && data[i+3]=='\n' {
			hdr := string(data[:i])
			pfx := "Content-Length: "
			idx := 0; found := false
			for j := 0; j + len(pfx) <= len(hdr); j += 1 {
				if hdr[j:j+len(pfx)] == pfx { idx = j + len(pfx); found = true; break }
			}
			if !found { return -1, 0 }
			cl := 0
			for idx < len(hdr) && hdr[idx] >= '0' && hdr[idx] <= '9' {
				cl = cl*10 + int(hdr[idx]-'0'); idx += 1
			}
			return cl, i + 4
		}
		i += 1
	}
	return -1, 0
}
