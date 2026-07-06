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

rm -rf "$(dirname "$H")"
echo "✓ integration smoke test passed"
