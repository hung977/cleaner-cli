#!/usr/bin/env bash
# Integration smoke test: drives the built `cleaner` binary through the v0.5 user journeys
# against a synthesized home, asserting behavior and exit codes. No real user data is touched
# (CLEANER_TEST_HOME sandbox). Wired into CI.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "› building…"
swift build >/dev/null
BIN="$(swift build --show-bin-path)/cleaner"

H="$(mktemp -d)/home"
mkdir -p "$H/Library/Developer/Xcode/DerivedData/MyApp-abc/Build" \
         "$H/.npm/_cacache/aa" "$H/.Trash/junk" "$H/Documents" "$H/Downloads" "$H/.cleaner"
mkfile() { mkdir -p "$(dirname "$1")"; dd if=/dev/zero of="$1" bs=1024 count="$2" 2>/dev/null; }
mkfile "$H/Library/Developer/Xcode/DerivedData/MyApp-abc/Build/x.o" 2000
mkfile "$H/.npm/_cacache/aa/d" 1000
mkfile "$H/.Trash/junk/big.bin" 3000
mkfile "$H/Documents/DO-NOT-DELETE.txt" 10   # protected — must always survive

export CLEANER_TEST_HOME="$H" CLEANER_HOME="$H/.cleaner"
fail() { echo "✗ $1"; exit 1; }
assert_exists() { [ -e "$1" ] || fail "expected to exist: $1"; }
assert_absent() { [ -e "$1" ] && fail "expected gone: $1" || true; }

echo "› cleaner --dry-run previews + shows NEXT STEPS (exit 0)"
out="$("$BIN" --dry-run)"; echo "$out" | grep -q "DISK RECLAIMABLE" || fail "dry-run header"
echo "$out" | grep -q "NEXT STEPS" || fail "dry-run should suggest next steps"

echo "› --json is valid JSON"
"$BIN" --json | python3 -c 'import json,sys; json.load(sys.stdin)' || fail "json"

echo "› --md emits a Markdown report"
"$BIN" --md | grep -q "# cleaner — Storage Report" || fail "md report"

echo "› dry-run mutates nothing"
"$BIN" --dry-run >/dev/null
assert_exists "$H/Library/Developer/Xcode/DerivedData/MyApp-abc"
assert_exists "$H/.npm/_cacache"

echo "› --yes cleans everything found (all staged); protected paths untouched"
"$BIN" --yes >/dev/null
assert_absent "$H/Library/Developer/Xcode/DerivedData/MyApp-abc"
assert_absent "$H/.npm/_cacache"
assert_absent "$H/.Trash/junk"                 # Trash now staged too (recoverable)
assert_exists "$H/Documents/DO-NOT-DELETE.txt" # protected — never touched

echo "› cleaner undo restores the last clean"
"$BIN" undo >/dev/null
assert_exists "$H/Library/Developer/Xcode/DerivedData/MyApp-abc/Build/x.o"
assert_exists "$H/Documents/DO-NOT-DELETE.txt"

echo "› undo --list shows staged sessions"
"$BIN" undo --list --json | python3 -c 'import json,sys; json.load(sys.stdin)' || fail "undo --list json"

echo "› doctor --ci is healthy (exit 0)"
"$BIN" doctor --ci >/dev/null || fail "doctor --ci"

echo "› find large / find dupes (read-only)"
mkfile "$H/Downloads/huge.bin" 200000
"$BIN" find large --min 100MB "$H/Downloads" | grep -q "huge.bin" || fail "find large"
mkfile "$H/Downloads/dupe-a.bin" 2000; cp "$H/Downloads/dupe-a.bin" "$H/Downloads/dupe-b.bin"
"$BIN" find dupes --min 1MB "$H/Downloads" | grep -qi "reclaimable" || fail "find dupes"
assert_exists "$H/Downloads/dupe-a.bin"; assert_exists "$H/Downloads/dupe-b.bin"

echo "› docker degrades cleanly; brew runs if present"
set +e; "$BIN" docker >/dev/null 2>&1; rc=$?; set -e
{ [ "$rc" -eq 0 ] || [ "$rc" -eq 10 ]; } || fail "docker exit (got $rc)"
if command -v brew >/dev/null 2>&1; then "$BIN" brew >/dev/null 2>&1 || fail "brew"; fi

echo "› profiles: list + unknown profile → exit 6; invalid config → exit 6"
printf 'version: 1\nprofiles:\n  xcode-only:\n    include: [dev.cleaner.xcode.deriveddata]\n' > "$H/.cleaner/config.yml"
"$BIN" profile list | grep -q "xcode-only" || fail "profile list"
set +e; "$BIN" --dry-run --profile nope >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -eq 6 ] || fail "unknown profile → 6 (got $rc)"
printf 'version: 99\n' > "$H/.cleaner/config.yml"
set +e; "$BIN" --dry-run >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -eq 6 ] || fail "invalid config → 6 (got $rc)"
rm -f "$H/.cleaner/config.yml"

rm -rf "$(dirname "$H")"
echo "✓ integration smoke test passed"
