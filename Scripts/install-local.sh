#!/usr/bin/env bash
# Build a release binary and install it locally, RE-SIGNING after the copy.
#
# On Apple Silicon every executable must carry a valid code signature. `swift build` ad-hoc
# signs the binary at the build path, but `cp`-ing it elsewhere invalidates that signature, so
# the OS (AMFI) kills the copy on launch with "Killed: 9" (exit 137). Re-signing ad-hoc at the
# destination fixes it. (Release builds are properly Developer-ID signed + notarized — spec 32.)
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="${1:-/opt/homebrew/bin/cleaner}"
echo "› building release…"
swift build -c release >/dev/null
BIN="$(swift build -c release --show-bin-path)/cleaner"

cp "$BIN" "$DEST"
codesign --force -s - "$DEST"        # ← the crucial step
echo "✓ installed → $DEST  ($("$DEST" --version))"
