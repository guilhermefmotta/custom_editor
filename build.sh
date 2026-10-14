#!/usr/bin/env bash
set -e

OUT="${1:-editor}"

# Embedded terminal: vendored libvterm as a static lib (ADR 0004).
bash "$(dirname "$0")/terminal/libvterm/build.sh"

odin build . -out:"$OUT"

# Copy font alongside the binary so the relative path font/ttf/FiraCode-Regular.ttf resolves
DEST_DIR="$(dirname "$OUT")"
if [ "$DEST_DIR" != "." ] && [ -n "$DEST_DIR" ]; then
    mkdir -p "$DEST_DIR/font/ttf"
    cp font/ttf/FiraCode-Regular.ttf "$DEST_DIR/font/ttf/FiraCode-Regular.ttf"
else
    # binary in same dir — font already present if running from project root
    mkdir -p font/ttf
fi

echo "Built: $OUT"
