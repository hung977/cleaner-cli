#!/usr/bin/env bash
# Integration smoke test: drives the built `cleaner` binary through the v0.1 user journeys
# (analyze → dry-run → clean → restore) against a synthesized home, asserting exit codes and
# behavior. No real user data is touched (CLEANER_TEST_HOME sandbox). Wired into CI.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "› building…"
swift build >/dev/null
BIN="$(swift build --show-bin-path)/cleaner"

H="$(mktemp -d)/home"
mkdir -p "$H/Library/Developer/Xcode/DerivedData/MyApp-abc/Build" \
         "$H/.npm/_cacache/aa" "$H/.Trash/junk" "$H/Documents"
mkfile() { mkdir -p "$(dirname "$1")"; dd if=/dev/zero of="$1" bs=1024 count="$2" 2>/dev/null; }
mkfile "$H/Library/Developer/Xcode/DerivedData/MyApp-abc/Build/x.o" 2000
mkfile "$H/.npm/_cacache/aa/d" 1000
mkfile "$H/.Trash/junk/big.bin" 3000
mkfile "$H/Documents/DO-NOT-DELETE.txt" 10   # protected — must always survive

export CLEANER_TEST_HOME="$H" CLEANER_HOME="$H/.cleaner"
fail() { echo "✗ $1"; exit 1; }
assert_exists() { [ -e "$1" ] || fail "expected to exist: $1"; }
assert_absent() { [ -e "$1" ] && fail "expected gone: $1" || true; }

echo "› analyze (expect exit 0)"
"$BIN" analyze >/dev/null; [ $? -eq 0 ] || fail "analyze exit"

echo "› analyze --json is valid JSON"
"$BIN" analyze --json | python3 -c 'import json,sys; json.load(sys.stdin)' || fail "analyze json"

echo "› dry-run mutates nothing"
"$BIN" clean --dry-run >/dev/null
assert_exists "$H/Library/Developer/Xcode/DerivedData/MyApp-abc"
assert_exists "$H/.npm/_cacache"

echo "› clean --yes stages Safe only (Trash 🟡 survives)"
"$BIN" clean --yes >/dev/null
assert_absent "$H/Library/Developer/Xcode/DerivedData/MyApp-abc"
assert_absent "$H/.npm/_cacache"
assert_exists "$H/.Trash/junk"                 # 🟡 not auto-cleaned under --yes
assert_exists "$H/Documents/DO-NOT-DELETE.txt" # protected, never touched

echo "› restore brings staged items back"
SID="$("$BIN" staging list --json | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["session"])')"
"$BIN" staging restore "$SID" >/dev/null
assert_exists "$H/Library/Developer/Xcode/DerivedData/MyApp-abc/Build/x.o"

echo "› protected file still present after full journey"
assert_exists "$H/Documents/DO-NOT-DELETE.txt"

echo "› doctor --ci is healthy (exit 0)"
"$BIN" doctor --ci >/dev/null || fail "doctor --ci should exit 0 in a sane sandbox"

echo "› report --md produces a Markdown report"
"$BIN" report --format md | grep -q "# cleaner — Storage Report" || fail "report --md header"

echo "› config ignore hides matching findings"
mkfile "$H/Library/Developer/Xcode/DerivedData/Keep-me/z" 500
printf 'version: 1\nignore:\n  - "*Keep*"\n' > "$H/.cleaner/config.yml"
"$BIN" analyze | grep -q "Keep-me" && fail "ignored item should be hidden" || true

echo "› invalid config exits 6"
printf 'version: 99\n' > "$H/.cleaner/config.yml"
set +e; "$BIN" analyze >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -eq 6 ] || fail "invalid config should exit 6 (got $rc)"
rm -f "$H/.cleaner/config.yml"

echo "› large-files detects a big file"
mkdir -p "$H/Downloads"; mkfile "$H/Downloads/huge.bin" 200000   # ~195 MB
"$BIN" large-files --min 100MB "$H/Downloads" | grep -q "huge.bin" || fail "large-files should list huge.bin"

echo "› duplicates detects identical copies (and never deletes)"
mkfile "$H/Downloads/dupe-a.bin" 2000; cp "$H/Downloads/dupe-a.bin" "$H/Downloads/dupe-b.bin"
"$BIN" duplicates --min 1MB "$H/Downloads" | grep -qi "reclaimable" || fail "duplicates should report reclaimable"
assert_exists "$H/Downloads/dupe-a.bin"; assert_exists "$H/Downloads/dupe-b.bin"  # read-only

rm -rf "$(dirname "$H")"
echo "✓ integration smoke test passed"
