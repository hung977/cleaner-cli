#!/usr/bin/env bash
# Build a universal (arm64 + x86_64) release binary, tar it, and print the sha256 for the
# Homebrew formula. Upload the tarball as a GitHub Release asset for the current tag.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(git describe --tags --abbrev=0 | sed 's/^v//')}"
echo "› building universal binary for v$VERSION…"
swift build -c release --arch arm64 --arch x86_64 >/dev/null
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/cleaner"
file "$BIN"

OUT="dist"
mkdir -p "$OUT"
STAGE="$(mktemp -d)"
cp "$BIN" "$STAGE/cleaner"
TARBALL="$OUT/cleaner-$VERSION-universal.tar.gz"
tar -czf "$TARBALL" -C "$STAGE" cleaner
rm -rf "$STAGE"

SHA=$(shasum -a 256 "$TARBALL" | awk '{print $1}')
echo ""
echo "✓ $TARBALL"
echo "  sha256: $SHA"
echo ""
echo "Next:"
echo "  1. gh release create v$VERSION $TARBALL   (or upload via GitHub web UI)"
echo "  2. put $SHA into homebrew-tap/Formula/cleaner.rb"
