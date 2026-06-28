package editor

INITIAL_CAP  :: 4096
MIN_GAP_SIZE :: 64

Gap_Buffer :: struct {
	data:       []u8,
	gap_start:  int,
	gap_end:    int,
	line_index: [dynamic]int, // line_index[i] = logical byte offset of line i start
}

// ---- Init / Destroy ----

buffer_init :: proc() -> Gap_Buffer {
	gb: Gap_Buffer
	gb.data       = make([]u8, INITIAL_CAP)
	gb.gap_start  = 0
	gb.gap_end    = INITIAL_CAP
	gb.line_index = make([dynamic]int, 0, 1024)
	append(&gb.line_index, 0)
	return gb
}

buffer_destroy :: proc(gb: ^Gap_Buffer) {
	delete(gb.data)
	delete(gb.line_index)
	gb^ = {}
}

// ---- Core metrics ----

buffer_len :: proc(gb: ^Gap_Buffer) -> int {
	return len(gb.data) - (gb.gap_end - gb.gap_start)
}

buffer_gap_size :: proc(gb: ^Gap_Buffer) -> int {
	return gb.gap_end - gb.gap_start
}

// ---- Gap manipulation ----

buffer_move_gap :: proc(gb: ^Gap_Buffer, pos: int) {
	if pos == gb.gap_start do return
	gap_size := buffer_gap_size(gb)
	if pos < gb.gap_start {
		n := gb.gap_start - pos
		copy(gb.data[gb.gap_end - n : gb.gap_end], gb.data[pos : gb.gap_start])
		gb.gap_start = pos
		gb.gap_end  -= n
	} else {
		n := pos - gb.gap_start
		copy(gb.data[gb.gap_start:], gb.data[gb.gap_end : gb.gap_end + n])
		gb.gap_start  = pos
		gb.gap_end   += n
	}
	_ = gap_size
}

buffer_grow :: proc(gb: ^Gap_Buffer, needed: int) {
	new_cap := len(gb.data) * 2
	for new_cap - buffer_len(gb) < needed { new_cap *= 2 }
	new_data     := make([]u8, new_cap)
	post_gap_len := len(gb.data) - gb.gap_end
	new_gap_end  := new_cap - post_gap_len
	copy(new_data, gb.data[:gb.gap_start])
	copy(new_data[new_gap_end:], gb.data[gb.gap_end:])
	delete(gb.data)
	gb.data    = new_data
	gb.gap_end = new_gap_end
}

// ---- Byte access ----

buffer_get_byte :: proc(gb: ^Gap_Buffer, pos: int) -> u8 {
	if pos < gb.gap_start do return gb.data[pos]
	phys := pos + (gb.gap_end - gb.gap_start)
	if phys >= len(gb.data) do return 0
	return gb.data[phys]
}

// ---- Insert / Delete (updates line_index) ----

buffer_insert_byte :: proc(gb: ^Gap_Buffer, pos: int, ch: u8) {
	if buffer_gap_size(gb) < 1 do buffer_grow(gb, MIN_GAP_SIZE)
	buffer_move_gap(gb, pos)
	gb.data[gb.gap_start] = ch
	gb.gap_start += 1
	li_on_insert(gb, pos, ch)
}

buffer_insert_string :: proc(gb: ^Gap_Buffer, pos: int, s: string) {
	if len(s) == 0 do return
	if buffer_gap_size(gb) < len(s) do buffer_grow(gb, len(s) + MIN_GAP_SIZE)
	buffer_move_gap(gb, pos)
	copy(gb.data[gb.gap_start:], s)
	gb.gap_start += len(s)
	// Rebuild is correct for arbitrary multi-char inserts
	li_build(gb)
}

buffer_delete :: proc(gb: ^Gap_Buffer, pos, n: int) {
	if n <= 0 do return
	buffer_move_gap(gb, pos)
	actual := min(n, len(gb.data) - gb.gap_end)
	gb.gap_end += actual
	li_on_delete(gb, pos, actual)
}

// ---- String / line helpers ----

buffer_to_string :: proc(gb: ^Gap_Buffer, allocator := context.allocator) -> string {
	n   := buffer_len(gb)
	out := make([]u8, n, allocator)
	copy(out, gb.data[:gb.gap_start])
	copy(out[gb.gap_start:], gb.data[gb.gap_end:])
	return string(out)
}

// O(1) — uses line_index
buffer_line_count :: proc(gb: ^Gap_Buffer) -> int {
	return max(1, len(gb.line_index))
}

// O(1) — uses line_index
buffer_line_start :: proc(gb: ^Gap_Buffer, line: int) -> int {
	if line <= 0 || len(gb.line_index) == 0 do return 0
	if line >= len(gb.line_index) do return buffer_len(gb)
	return gb.line_index[line]
}

// O(1) — uses line_index
buffer_line_length :: proc(gb: ^Gap_Buffer, line: int) -> int {
	if line < 0 || line >= len(gb.line_index) do return 0
	start := gb.line_index[line]
	if line + 1 < len(gb.line_index) {
		return gb.line_index[line + 1] - start - 1 // subtract the '\n'
	}
	return buffer_len(gb) - start
}

// O(log n) — binary search on line_index
buffer_pos_to_line_col :: proc(gb: ^Gap_Buffer, pos: int) -> (line, col: int) {
	line = li_find_line(gb, pos)
	col  = pos - gb.line_index[line]
	return
}

// Returns bytes for line (no newline). Uses temp allocator.
buffer_get_line_bytes :: proc(gb: ^Gap_Buffer, line: int) -> []u8 {
	if line < 0 || line >= len(gb.line_index) do return nil
	start  := gb.line_index[line]
	length := buffer_line_length(gb, line)
	result := make([]u8, length, context.temp_allocator)
	for i in 0 ..< length {
		result[i] = buffer_get_byte(gb, start + i)
	}
	return result
}

// ---- Line index internals ----

// Full rebuild — O(n bytes). Call after bulk insert or file load.
li_build :: proc(gb: ^Gap_Buffer) {
	clear(&gb.line_index)
	append(&gb.line_index, 0)
	logical := 0
	// Pre-gap
	for i in 0 ..< gb.gap_start {
		if gb.data[i] == '\n' do append(&gb.line_index, logical + 1)
		logical += 1
	}
	// Post-gap
	for i in gb.gap_end ..< len(gb.data) {
		if gb.data[i] == '\n' do append(&gb.line_index, logical + 1)
		logical += 1
	}
}

// Incremental update after single-byte insert at pos — O(n lines).
li_on_insert :: proc(gb: ^Gap_Buffer, pos: int, ch: u8) {
	l := li_find_line(gb, pos)
	// Shift all entries after the line containing pos
	for i in l + 1 ..< len(gb.line_index) {
		gb.line_index[i] += 1
	}
	if ch == '\n' {
		inject_at(&gb.line_index, l + 1, pos + 1)
	}
}

// Incremental update after deleting `n` bytes at pos — O(n lines).
li_on_delete :: proc(gb: ^Gap_Buffer, pos, n: int) {
	write := 0
	for i in 0 ..< len(gb.line_index) {
		e := gb.line_index[i]
		if e > pos && e <= pos + n {
			continue // entry fell inside deleted region — remove it
		}
		if e > pos {
			gb.line_index[write] = e - n
		} else {
			gb.line_index[write] = e
		}
		write += 1
	}
	resize(&gb.line_index, write)
}

// Binary search: largest l where line_index[l] <= pos — O(log n).
li_find_line :: proc(gb: ^Gap_Buffer, pos: int) -> int {
	if len(gb.line_index) == 0 do return 0
	lo, hi := 0, len(gb.line_index) - 1
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if gb.line_index[mid] <= pos {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	return lo
}
