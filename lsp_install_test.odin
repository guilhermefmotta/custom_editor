package editor

import "core:encoding/base64"
import "core:strings"
import "core:testing"
import "core:unicode/utf16"

// The Windows install scripts reach PowerShell intact (quotes included) via
// -EncodedCommand instead of going through command-line quoting.
@(test)
test_ps_argv_keeps_script_quotes :: proc(t: ^testing.T) {
	script := `$DEST="C:\Users\a b\editor\lsp\gopls"; New-Item -ItemType Directory -Force -Path $DEST | Out-Null`
	argv := _ps_argv(script)
	defer { for a in argv { delete(a) }; delete(argv) }
	testing.expect_value(t, argv[0], "powershell")
	testing.expect_value(t, argv[len(argv) - 2], "-EncodedCommand")

	raw, err := base64.decode(argv[len(argv) - 1], allocator = context.temp_allocator)
	testing.expect(t, err == nil)
	u16s := make([]u16, len(raw) / 2, context.temp_allocator)
	for i in 0 ..< len(u16s) { u16s[i] = u16(raw[2 * i]) | u16(raw[2 * i + 1]) << 8 }
	buf := make([]u8, len(u16s) * 4, context.temp_allocator)
	n := utf16.decode_to_utf8(buf, u16s)
	decoded := string(buf[:n])
	testing.expect(t, strings.has_suffix(decoded, script), "script survives byte for byte")
	testing.expect(t, strings.contains(decoded, `$DEST="C:\Users\a b\`), "double quotes kept")
}
