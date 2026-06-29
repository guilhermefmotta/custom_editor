package lsp

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

// ---------------------------------------------------------------------------
// Completion trigger reason
// ---------------------------------------------------------------------------

Trigger_Kind :: enum {
	Invoked,           // Ctrl+Space or auto after typing identifier char
	Trigger_Char,      // typed a trigger character like . or (
	Re_Invoke,         // re-triggered after filter changed
}

// ---------------------------------------------------------------------------
// Completion session — one per active completion in a pane
// ---------------------------------------------------------------------------

Completion_Session :: struct {
	active:         bool,
	request_id:     int,      // pending LSP request id; -1 if none
	trigger_kind:   Trigger_Kind,
	trigger_char:   rune,
	line:           int,      // cursor position when triggered
	character:      int,
	prefix:         string,   // heap — text typed since trigger (used for filtering)
	items:          []Completion_Item, // heap-owned, full list from server
	filtered:       []int,    // indices into items, sorted by score
	selected:       int,      // index into filtered
	needs_filter:   bool,     // prefix changed — re-filter next update
}

session_init :: proc(s: ^Completion_Session) {
	s^ = {}
	s.request_id = -1
}

session_destroy :: proc(s: ^Completion_Session) {
	delete(s.prefix)
	_items_free(s.items)
	delete(s.filtered)
	s^ = {}
	s.request_id = -1
}

_items_free :: proc(items: []Completion_Item) {
	for &item in items { completion_item_destroy(&item) }
	delete(items)
}

// ---------------------------------------------------------------------------
// Ranked completion item for display
// ---------------------------------------------------------------------------

Ranked_Item :: struct {
	item:  ^Completion_Item,
	score: int,
	index: int, // original index in session.items
}

// ---------------------------------------------------------------------------
// Completion manager — one per Language_Client
// ---------------------------------------------------------------------------

Completion_Manager :: struct {
	session: Completion_Session,
}

completion_manager_init :: proc(m: ^Completion_Manager) {
	session_init(&m.session)
}

completion_manager_destroy :: proc(m: ^Completion_Manager) {
	session_destroy(&m.session)
}

// ---------------------------------------------------------------------------
// Request completion at position
// ---------------------------------------------------------------------------

completion_request :: proc(
	c:            ^Language_Client,
	path:         string,
	line, char:   int,
	trigger:      Trigger_Kind,
	trigger_char: rune,
	prefix:       string,
) {
	if c.state != .Running || !c.caps.has_completion { return }

	m := &c.completion

	// Cancel old request if pending
	if m.session.active && m.session.request_id >= 0 {
		client_cancel_request(c, m.session.request_id)
	}

	// Reset session
	session_destroy(&m.session)
	m.session.active       = true
	m.session.line         = line
	m.session.character    = char
	m.session.trigger_kind = trigger
	m.session.trigger_char = trigger_char
	m.session.prefix       = strings.clone(prefix)
	m.session.request_id   = -1
	m.session.selected     = 0

	// Build params
	trigger_kind_num := 1
	switch trigger {
	case .Trigger_Char: trigger_kind_num = 2
	case .Re_Invoke:    trigger_kind_num = 3
	case .Invoked:      trigger_kind_num = 1
	}

	params: string
	if trigger == .Trigger_Char && trigger_char != 0 {
		char_str := fmt.tprintf("%r", trigger_char)
		params = fmt.tprintf(
			`{"textDocument":{"uri":%s},"position":{"line":%d,"character":%d},"context":{"triggerKind":%d,"triggerCharacter":%s}}`,
			json_str(path_to_uri(path)), line, char, trigger_kind_num, json_str(char_str),
		)
	} else {
		params = fmt.tprintf(
			`{"textDocument":{"uri":%s},"position":{"line":%d,"character":%d},"context":{"triggerKind":%d}}`,
			json_str(path_to_uri(path)), line, char, trigger_kind_num,
		)
	}

	m.session.request_id = client_send_request(c, "textDocument/completion", params, Response_Callback{
		proc_ = _on_completion_response,
	})
}

// Cancel active completion.
completion_cancel :: proc(c: ^Language_Client) {
	m := &c.completion
	if !m.session.active { return }
	if m.session.request_id >= 0 {
		client_cancel_request(c, m.session.request_id)
	}
	session_destroy(&m.session)
}

// Update prefix (user kept typing). Re-filters without new request if prefix
// still matches items.
completion_update_prefix :: proc(c: ^Language_Client, prefix: string) {
	m := &c.completion
	if !m.session.active { return }

	delete(m.session.prefix)
	m.session.prefix      = strings.clone(prefix)
	m.session.needs_filter = true
	m.session.selected    = 0
}

// Called each frame after client_update. Applies pending filter.
completion_manager_update :: proc(c: ^Language_Client) {
	m := &c.completion
	if !m.session.active { return }
	if m.session.needs_filter {
		_refilter_session(&m.session)
		m.session.needs_filter = false
	}
}

_refilter_session :: proc(s: ^Completion_Session) {
	delete(s.filtered)
	if len(s.items) == 0 { s.filtered = nil; return }

	scored := make([dynamic]Ranked_Item, context.temp_allocator)
	for &item, i in s.items {
		score := fuzzy_score(item.filter_text, s.prefix)
		if score < 0 { continue } // no match
		append(&scored, Ranked_Item{item = &item, score = score, index = i})
	}

	// Sort by score descending, then sort_text ascending for ties
	slice.sort_by(scored[:], proc(a, b: Ranked_Item) -> bool {
		if a.score != b.score { return a.score > b.score }
		return a.item.sort_text < b.item.sort_text
	})

	out := make([]int, len(scored))
	for r, i in scored { out[i] = r.index }
	s.filtered = out
}

// Navigate selection
completion_select_next :: proc(c: ^Language_Client) {
	s := &c.completion.session
	if !s.active || len(s.filtered) == 0 { return }
	s.selected = (s.selected + 1) % len(s.filtered)
}

completion_select_prev :: proc(c: ^Language_Client) {
	s := &c.completion.session
	if !s.active || len(s.filtered) == 0 { return }
	s.selected = (s.selected - 1 + len(s.filtered)) % len(s.filtered)
}

// Get the currently selected item (nil if none).
completion_selected_item :: proc(c: ^Language_Client) -> ^Completion_Item {
	s := &c.completion.session
	if !s.active || len(s.filtered) == 0 { return nil }
	if s.selected >= len(s.filtered) { return nil }
	return &s.items[s.filtered[s.selected]]
}

// Is completion active and has results?
completion_is_visible :: proc(c: ^Language_Client) -> bool {
	s := &c.completion.session
	return s.active && len(s.filtered) > 0
}

// Get filtered items (indices) — caller uses to render.
completion_filtered_items :: proc(c: ^Language_Client) -> ([]Completion_Item, []int) {
	s := &c.completion.session
	return s.items, s.filtered
}

// ---------------------------------------------------------------------------
// Response handler
// ---------------------------------------------------------------------------

_on_completion_response :: proc(c: ^Language_Client, result: json.Value, error: json.Value, user: rawptr) {
	defer json.destroy_value(result)
	defer json.destroy_value(error)

	m := &c.completion
	if !m.session.active { return }
	m.session.request_id = -1

	if error != nil { session_destroy(&m.session); return }
	if result == nil { return }

	// Result can be CompletionList or CompletionItem[]
	new_items: [dynamic]Completion_Item
	new_items = make([dynamic]Completion_Item)

	#partial switch v in result {
	case json.Array:
		// CompletionItem[]
		for item_v in v {
			if item_obj, ok := item_v.(json.Object); ok {
				append(&new_items, parse_completion_item(item_obj))
			}
		}
	case json.Object:
		// CompletionList { isIncomplete, items }
		if items_arr, ok := json_obj_arr(v, "items"); ok {
			for item_v in items_arr {
				if item_obj, ok2 := item_v.(json.Object); ok2 {
					append(&new_items, parse_completion_item(item_obj))
				}
			}
		}
	}

	_items_free(m.session.items)
	m.session.items = new_items[:]
	m.session.needs_filter = true
}

// ---------------------------------------------------------------------------
// Fuzzy scorer
//
// Score algorithm (similar to VS Code's FuzzyScorer):
// - Exact match:   high score
// - Prefix match:  high score
// - camelCase match: medium-high
// - Subsequence:   positive score proportional to density
// - No match:      -1
//
// Time: O(n*m), Space: O(m) for prefix length m, item length n
// ---------------------------------------------------------------------------

fuzzy_score :: proc(text: string, pattern: string) -> int {
	if len(pattern) == 0 { return 1000 } // empty prefix matches everything
	if len(text) == 0    { return -1    }

	t := strings.to_lower(text,    context.temp_allocator)
	p := strings.to_lower(pattern, context.temp_allocator)

	// Exact match
	if t == p { return 10000 }

	// Prefix match
	if strings.has_prefix(t, p) {
		return 9000 + (100 - min(len(t) - len(p), 100))
	}

	// Subsequence match with density bonus
	pi := 0
	ti := 0
	first_match := -1
	last_match  := -1
	gaps        := 0

	tb := transmute([]u8)t
	pb := transmute([]u8)p

	for pi < len(pb) && ti < len(tb) {
		if pb[pi] == tb[ti] {
			if first_match < 0 { first_match = ti }
			last_match = ti
			pi += 1
		} else if first_match >= 0 {
			gaps += 1
		}
		ti += 1
	}

	if pi < len(pb) { return -1 } // not a subsequence

	// Score based on match density and position
	span    := last_match - first_match + 1
	density := len(pb) * 1000 / max(span, 1)
	start_bonus := max(0, 500 - first_match * 10)
	gap_penalty := gaps * 20

	return density + start_bonus - gap_penalty
}

// Check if pattern is a subsequence of text (case-insensitive).
is_subsequence :: proc(text: string, pattern: string) -> bool {
	if len(pattern) == 0 { return true }
	pi := 0
	for ti := 0; ti < len(text) && pi < len(pattern); ti += 1 {
		tc := text[ti]
		pc := pattern[pi]
		if tc >= 'A' && tc <= 'Z' { tc += 32 }
		if pc >= 'A' && pc <= 'Z' { pc += 32 }
		if tc == pc { pi += 1 }
	}
	return pi == len(pattern)
}

// ---------------------------------------------------------------------------
// Completion resolve — fetch full documentation for selected item
// ---------------------------------------------------------------------------

completion_resolve :: proc(c: ^Language_Client, item_index: int, cb: Response_Callback) {
	s := &c.completion.session
	if item_index < 0 || item_index >= len(s.items) { return }
	if c.state != .Running { return }

	item := &s.items[item_index]
	// Build minimal resolve request using item's data field
	params := fmt.tprintf(
		`{"label":%s,"kind":%d,"data":%s}`,
		json_str(item.label),
		int(item.kind),
		item.data == "" ? "null" : item.data,
	)
	client_send_request(c, "completionItem/resolve", params, cb)
}
