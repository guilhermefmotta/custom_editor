#!/usr/bin/env bash
# Downloads a pinned ripgrep release into bundled/ so the editor build embeds
# it (ripgrep_bundled.odin). The checksum published with the release is
# verified before anything is kept.
#
#   scripts/fetch-ripgrep.sh <target>
#   targets: x86_64-unknown-linux-musl  aarch64-apple-darwin
#            x86_64-apple-darwin        x86_64-pc-windows-msvc
set -euo pipefail

RG_VERSION=14.1.1
target=${1:?target triple required}
case "$target" in
  *windows*) ext=zip;    exe=rg.exe ;;
  *)         ext=tar.gz; exe=rg ;;
esac
name="ripgrep-${RG_VERSION}-${target}"
url="https://github.com/BurntSushi/ripgrep/releases/download/${RG_VERSION}/${name}.${ext}"

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

curl -fsSL "$url" -o "$tmp/$name.$ext"
curl -fsSL "$url.sha256" -o "$tmp/sum"
expected=$(awk '{print $1}' "$tmp/sum")
if command -v sha256sum >/dev/null; then
  actual=$(sha256sum "$tmp/$name.$ext" | awk '{print $1}')
else
  actual=$(shasum -a 256 "$tmp/$name.$ext" | awk '{print $1}')
fi
if [ "$expected" != "$actual" ]; then
  echo "ripgrep checksum mismatch: expected $expected, got $actual" >&2
  exit 1
fi

if [ "$ext" = zip ]; then
  if command -v unzip >/dev/null; then
    unzip -q "$tmp/$name.$ext" -d "$tmp"
  else # Git Bash on Windows runners
    powershell -NoProfile -Command "Expand-Archive -Path '$(cygpath -w "$tmp/$name.$ext")' -DestinationPath '$(cygpath -w "$tmp")'"
  fi
else
  tar -xzf "$tmp/$name.$ext" -C "$tmp"
fi

mkdir -p "$root/bundled"
cp "$tmp/$name/$exe" "$root/bundled/$exe"
chmod +x "$root/bundled/$exe"
cp "$tmp/$name/LICENSE-MIT" "$root/bundled/ripgrep-LICENSE-MIT"
cp "$tmp/$name/UNLICENSE" "$root/bundled/ripgrep-UNLICENSE"
echo "ripgrep $RG_VERSION ($target) -> bundled/$exe"
