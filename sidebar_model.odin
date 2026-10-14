package editor

// Pure (raylib-free) model of the refs sidebar (ticket #6): row building
// with sections, remote grouping and per-section filters, context-menu
// actions per row, ahead/behind label. Drawing/input live in sidebar.odin.

import "core:fmt"
import "core:strings"
import "git"

Sidebar_Section :: enum u8 { Local, Remote, Tags, Stashes, Submodules, Reflog }

SIDEBAR_SECTION_TITLES := [Sidebar_Section]string{
	.Local      = "LOCAL BRANCHES",
	.Remote     = "REMOTE BRANCHES",
	.Tags       = "TAGS",
	.Stashes    = "STASHES",
	.Submodules = "SUBMODULES",
	.Reflog     = "REFLOG",
}

Sidebar_Row_Kind :: enum u8 {
	Section,       // section header (index unused)
	Remote_Group,  // "origin" under REMOTE BRANCHES (index into remotes or -1)
	Local_Branch,  // index into snap.branches
	Remote_Branch, // index into snap.branches
	Tag,           // index into snap.tags
	Stash,         // index into snap.stashes
	Submodule,     // index into snap.submodules
	Reflog,        // index into snap.reflog
	Empty,         // "(none)" / "(no matches)" placeholder
}

Sidebar_Row :: struct {
	kind:    Sidebar_Row_Kind,
	section: Sidebar_Section,
	index:   int,
	depth:   int,
	group:   string, // remote name for Remote_Group / Remote_Branch (borrowed)
}

Sidebar_View :: struct {
	collapsed: [Sidebar_Section]bool,
	filters:   [Sidebar_Section][dynamic]u8,
}

sidebar_view_destroy :: proc(v: ^Sidebar_View) {
	for &f in v.filters { delete(f) }
	v^ = {}
}

sidebar_filter :: proc(v: ^Sidebar_View, s: Sidebar_Section) -> string { return string(v.filters[s][:]) }

// Display name used for filtering and drawing (borrowed or temp).
sidebar_row_name :: proc(snap: ^git.Refs_Snapshot, r: Sidebar_Row) -> string {
	switch r.kind {
	case .Section:      return SIDEBAR_SECTION_TITLES[r.section]
	case .Remote_Group: return r.group
	case .Local_Branch: return snap.branches[r.index].name
	case .Remote_Branch:
		n := snap.branches[r.index].name
		return n[len(r.group) + 1:] if strings.has_prefix(n, r.group) && len(n) > len(r.group) else n
	case .Tag:          return snap.tags[r.index].name
	case .Stash:
		s := snap.stashes[r.index]
		return fmt.tprintf("%s  %s", s.ref, s.message)
	case .Submodule:    return snap.submodules[r.index].path
	case .Reflog:
		e := snap.reflog[r.index]
		short := e.hash[:min(7, len(e.hash))]
		if e.message == "" { return fmt.tprintf("%s  %s", short, e.action) }
		return fmt.tprintf("%s  %s: %s", short, e.action, e.message)
	case .Empty:        return ""
	}
	return ""
}

// Text the per-section filter matches against.
@(private="file")
_sb_filter_text :: proc(snap: ^git.Refs_Snapshot, r: Sidebar_Row) -> string {
	if r.kind == .Remote_Branch { return snap.branches[r.index].name } // "origin/feat"
	return sidebar_row_name(snap, r)
}

// Rebuilds `rows` from the snapshot. A nil snapshot gives no rows.
sidebar_build_rows :: proc(snap: ^git.Refs_Snapshot, v: ^Sidebar_View, rows: ^[dynamic]Sidebar_Row) {
	clear(rows)
	if snap == nil { return }
	for sec in Sidebar_Section {
		append(rows, Sidebar_Row{kind = .Section, section = sec, index = -1})
		if v.collapsed[sec] { continue }
		q := sidebar_filter(v, sec)
		start := len(rows)
		add :: proc(rows: ^[dynamic]Sidebar_Row, snap: ^git.Refs_Snapshot, q: string, r: Sidebar_Row) -> bool {
			if q != "" && !pal_match(_sb_filter_text(snap, r), q) { return false }
			append(rows, r)
			return true
		}
		switch sec {
		case .Local:
			for b, i in snap.branches {
				if !b.is_remote { add(rows, snap, q, {kind = .Local_Branch, section = sec, index = i, depth = 1}) }
			}
		case .Remote:
			// Group by remote, in the order remotes first appear
			groups := make([dynamic]string, context.temp_allocator)
			for b in snap.branches {
				if !b.is_remote { continue }
				seen := false
				for g in groups { if g == b.remote { seen = true; break } }
				if !seen { append(&groups, b.remote) }
			}
			for g in groups {
				hdr := len(rows)
				append(rows, Sidebar_Row{kind = .Remote_Group, section = sec, index = -1, depth = 1, group = g})
				n := 0
				for b, i in snap.branches {
					if b.is_remote && b.remote == g {
						if add(rows, snap, q, {kind = .Remote_Branch, section = sec, index = i, depth = 2, group = g}) { n += 1 }
					}
				}
				if n == 0 { resize(rows, hdr) } // group with no match: hide its header
			}
		case .Tags:
			for _, i in snap.tags { add(rows, snap, q, {kind = .Tag, section = sec, index = i, depth = 1}) }
		case .Stashes:
			for _, i in snap.stashes { add(rows, snap, q, {kind = .Stash, section = sec, index = i, depth = 1}) }
		case .Submodules:
			for _, i in snap.submodules { add(rows, snap, q, {kind = .Submodule, section = sec, index = i, depth = 1}) }
		case .Reflog:
			for _, i in snap.reflog { add(rows, snap, q, {kind = .Reflog, section = sec, index = i, depth = 1}) }
		}
		if len(rows) == start { append(rows, Sidebar_Row{kind = .Empty, section = sec, index = -1, depth = 1}) }
	}
}

// Number of items in a section (unfiltered), for the header.
sidebar_section_count :: proc(snap: ^git.Refs_Snapshot, sec: Sidebar_Section) -> int {
	if snap == nil { return 0 }
	switch sec {
	case .Local, .Remote:
		n := 0
		for b in snap.branches { if b.is_remote == (sec == .Remote) { n += 1 } }
		return n
	case .Tags:       return len(snap.tags)
	case .Stashes:    return len(snap.stashes)
	case .Submodules: return len(snap.submodules)
	case .Reflog:     return len(snap.reflog)
	}
	return 0
}

// "↑2 ↓1" (font has U+2191/U+2193), "gone" for a deleted upstream, "" in sync / no upstream.
sidebar_ahead_behind :: proc(b: git.Branch, allocator := context.temp_allocator) -> string {
	if b.upstream_gone { return "gone" }
	switch {
	case b.ahead > 0 && b.behind > 0: return fmt.aprintf("↑%d ↓%d", b.ahead, b.behind, allocator = allocator)
	case b.ahead > 0:                 return fmt.aprintf("↑%d", b.ahead, allocator = allocator)
	case b.behind > 0:                return fmt.aprintf("↓%d", b.behind, allocator = allocator)
	}
	return ""
}

// ---------------------------------------------------------------------------
// Context-menu actions
// ---------------------------------------------------------------------------

Sidebar_Action :: enum u8 {
	Checkout,
	Show_In_Graph,
	New_Branch,
	New_Tag,
	Rename,
	Delete_Branch,
	Delete_Remote_Branch,
	Merge,
	Rebase,
	Push,
	Delete_Tag,
	Stash_Apply,
	Stash_Pop,
	Stash_Drop,
	Stash_Push,
	Copy_Hash,
	Refresh,
}

SIDEBAR_ACTION_LABELS := [Sidebar_Action]string{
	.Checkout             = "Checkout",
	.Show_In_Graph        = "Show in commit graph",
	.New_Branch           = "New branch from here...",
	.New_Tag              = "New tag here...",
	.Rename               = "Rename...",
	.Delete_Branch        = "Delete...",
	.Delete_Remote_Branch = "Delete remote branch...",
	.Merge                = "Merge into current",
	.Rebase               = "Rebase current onto this",
	.Push                 = "Push",
	.Delete_Tag           = "Delete tag...",
	.Stash_Apply          = "Apply",
	.Stash_Pop            = "Pop",
	.Stash_Drop           = "Drop...",
	.Stash_Push           = "Stash local changes",
	.Copy_Hash            = "Copy hash",
	.Refresh              = "Refresh",
}

SIDEBAR_MAX_ACTIONS :: 12

// Actions offered for `r`, written into buf. Header rows get section-level
// actions (new branch at HEAD, new tag at HEAD, stash changes).
sidebar_menu_actions :: proc(snap: ^git.Refs_Snapshot, r: Sidebar_Row, buf: ^[SIDEBAR_MAX_ACTIONS]Sidebar_Action) -> []Sidebar_Action {
	n := 0
	put :: proc(buf: ^[SIDEBAR_MAX_ACTIONS]Sidebar_Action, n: ^int, a: Sidebar_Action) { buf[n^] = a; n^ += 1 }
	switch r.kind {
	case .Local_Branch:
		b := snap.branches[r.index]
		if !b.is_head { put(buf, &n, .Checkout) }
		put(buf, &n, .Show_In_Graph)
		put(buf, &n, .New_Branch)
		put(buf, &n, .New_Tag)
		put(buf, &n, .Rename)
		if !b.is_head {
			put(buf, &n, .Delete_Branch)
			put(buf, &n, .Merge)
			put(buf, &n, .Rebase)
		}
		put(buf, &n, .Push)
		put(buf, &n, .Copy_Hash)
	case .Remote_Branch:
		put(buf, &n, .Checkout)
		put(buf, &n, .Show_In_Graph)
		put(buf, &n, .New_Branch)
		put(buf, &n, .Merge)
		put(buf, &n, .Rebase)
		put(buf, &n, .Delete_Remote_Branch)
		put(buf, &n, .Copy_Hash)
	case .Tag:
		put(buf, &n, .Show_In_Graph)
		put(buf, &n, .New_Branch)
		put(buf, &n, .Delete_Tag)
		put(buf, &n, .Copy_Hash)
	case .Stash:
		put(buf, &n, .Stash_Apply)
		put(buf, &n, .Stash_Pop)
		put(buf, &n, .Stash_Drop)
	case .Reflog:
		put(buf, &n, .New_Branch)
		put(buf, &n, .Copy_Hash)
	case .Submodule:
		put(buf, &n, .Copy_Hash)
	case .Section, .Remote_Group, .Empty:
		#partial switch r.section {
		case .Local: put(buf, &n, .New_Branch)
		case .Tags:  put(buf, &n, .New_Tag)
		case .Stashes: put(buf, &n, .Stash_Push)
		}
		put(buf, &n, .Refresh)
	}
	return buf[:n]
}

// Commit-ish a row points at ("" = HEAD / not applicable).
sidebar_row_rev :: proc(snap: ^git.Refs_Snapshot, r: Sidebar_Row) -> string {
	#partial switch r.kind {
	case .Local_Branch, .Remote_Branch: return snap.branches[r.index].name
	case .Tag:       return snap.tags[r.index].name
	case .Stash:     return snap.stashes[r.index].hash
	case .Reflog:    return snap.reflog[r.index].hash
	case .Submodule: return snap.submodules[r.index].hash
	}
	return ""
}

sidebar_row_hash :: proc(snap: ^git.Refs_Snapshot, r: Sidebar_Row) -> string {
	#partial switch r.kind {
	case .Local_Branch, .Remote_Branch: return snap.branches[r.index].hash
	case .Tag: return snap.tags[r.index].hash
	}
	return sidebar_row_rev(snap, r)
}

// Branch name a row refers to for "filter the graph" ("" = not a branch/tag).
sidebar_row_branch :: proc(snap: ^git.Refs_Snapshot, r: Sidebar_Row) -> string {
	#partial switch r.kind {
	case .Local_Branch, .Remote_Branch: return snap.branches[r.index].name
	case .Tag: return snap.tags[r.index].name
	}
	return ""
}
