#!/usr/bin/env bash
# Builds the vendored libvterm (0.3.3, MIT — see LICENSE) into
# terminal/libvterm/lib/libvterm.a, which terminal/vterm.odin links
# statically. Idempotent: rebuilds only when a source is newer than the lib.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/lib/libvterm.a"
CC="${CC:-cc}"

if [ -f "$LIB" ] && [ -z "$(find "$HERE/src" "$HERE/include" -newer "$LIB" -type f | head -1)" ]; then
    exit 0
fi

OBJ="$HERE/lib/obj"
mkdir -p "$OBJ"
for f in "$HERE"/src/*.c; do
    "$CC" -c -O2 -std=c99 -fPIC -w -I"$HERE/include" "$f" -o "$OBJ/$(basename "${f%.c}").o"
done
rm -f "$LIB"
ar rcs "$LIB" "$OBJ"/*.o
rm -rf "$OBJ"
echo "Built: $LIB"
