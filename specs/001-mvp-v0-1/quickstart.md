# Quickstart: cleaner-cli v0.1

**Feature**: `001-mvp-v0-1` | **Date**: 2026-07-06

How a developer builds, runs, and tests the v0.1 safety spine. Requires **macOS 13+** and a
**Swift 6** toolchain (Xcode 16 / Swift 6.0). No network access is needed at runtime.

> **Safety note**: `cleaner clean` moves files to `~/.cleaner/staging/` (reversible) by default —
> it does not permanently delete. You can always `cleaner staging restore` afterward. Try it
> against a throwaway directory first if you like.

---

## 1. Build

```bash
swift build                 # debug build of the `cleaner` executable + all libraries
swift build -c release      # optimized build (used for perf sanity checks)
```

Expected: a clean build producing `.build/debug/cleaner`. First build resolves pinned
dependencies (swift-argument-parser, swift-log, swift-system, swift-collections, Yams).

---

## 2. Analyze (read-only — US1)

Scan your home directory and print a human summary. This never mutates anything.

```bash
swift run cleaner analyze
```

Expected output (stderr shows a progress line while scanning; stdout shows the table):

```text
Analyzing /Users/me …  (scanning: 41,204 files, 12.3 GiB)         # progress → stderr

STORAGE
  Capacity  1.0 TiB     Used  812.4 GiB     Free  211.6 GiB     Reclaimable  18.7 GiB

RECLAIMABLE BY CATEGORY
  Category           Plugin              Items   On-disk    Risk
  developer-cache    dev.cleaner.xcode      14    12.1 GiB   🟢 safe
  developer-cache    dev.cleaner.npm         1     4.3 GiB   🟢 safe
  trash              dev.cleaner.trash      37     2.3 GiB   🟡 medium

  Total reclaimable (staged, reversible): 18.7 GiB across 52 items
Exit: 0 (ok)
```

Machine-readable form — stdout is exactly one JSON document, so it pipes cleanly:

```bash
swift run cleaner analyze --json | jq '.result.byCategory'
```

```json
[
  { "category": "developer-cache", "allocatedBytes": 17643245568, "logicalBytes": 17700000000,
    "itemCount": 15, "plugins": ["dev.cleaner.xcode", "dev.cleaner.npm"] },
  { "category": "trash", "allocatedBytes": 2469606195, "logicalBytes": 2469606195,
    "itemCount": 37, "plugins": ["dev.cleaner.trash"] }
]
```

The full envelope carries `schemaVersion: "1.0.0"`, `command`, `sessionId`, `durationMs`,
`exitCode: 0`, `exitReason: "ok"`. Restrict to one plugin with
`swift run cleaner analyze --include plugin:dev.cleaner.xcode`.

---

## 3. Preview a clean (dry-run — US2)

Compute and show the full plan and projected reclaim, disposing of nothing (exit 0). Uses the
**same** measurement code as a real run.

```bash
swift run cleaner clean --plugins dev.cleaner.xcode,dev.cleaner.npm --dry-run
```

```text
PLAN (dry-run — nothing will be disposed)
  Disposition: stage → /Users/me/.cleaner/staging/<new-session>
  🟢 dev.cleaner.xcode   ~/Library/Developer/Xcode/DerivedData/App-abc     5.0 GiB   stage
  🟢 dev.cleaner.xcode   ~/Library/Developer/Xcode/DerivedData/Lib-def     7.1 GiB   stage
  🟢 dev.cleaner.npm     ~/.npm/_cacache                                   4.3 GiB   stage
  Projected reclaim (on-disk): 16.4 GiB   (shared/clone bytes excluded: 0)
Exit: 0 (ok)
```

JSON preview: `swift run cleaner clean … --dry-run --json` returns the same `result` shape a real
`clean` returns, with every item `"disposition":"stage"` and no `"status":"staged"` mutations.

---

## 4. Clean for real (stage — US2)

```bash
swift run cleaner clean --plugins dev.cleaner.xcode,dev.cleaner.npm
```

Interactive: you see the preview above, then a prompt on stderr:

```text
Stage 3 items (16.4 GiB) to ~/.cleaner/staging? [y/N] y
Staging …  ▸ App-abc  ▸ Lib-def  ▸ _cacache                     # progress → stderr
Staged 3 items · 16.4 GiB reclaimed · session 6f1c9c2e-…
Exit: 0 (ok)
```

Non-interactive auto-confirm for 🟢 (🟡 Trash is skipped unless `--include medium`):

```bash
swift run cleaner clean --include risk:safe --yes
```

Run it again immediately — idempotent, nothing new to do:

```bash
swift run cleaner clean --include risk:safe --yes
# → "Nothing to do." · Exit: 0 (ok)
```

Every staged item appended an audit event; inspect it:

```bash
tail -n 3 ~/.cleaner/logs/audit/$(date +%F).ndjson
# {"schemaVersion":1,"event":"item.staged","plugin":"dev.cleaner.xcode","disposition":"stage", …}
```

---

## 5. List and restore staged items (rollback — US3)

```bash
swift run cleaner staging list
```

```text
STAGED SESSIONS
  Session                               Date              Items   Staged     Expires
  6f1c9c2e-…                            2026-07-06 12:00      3    16.4 GiB   2026-07-20
    ~/Library/Developer/Xcode/DerivedData/App-abc
    ~/Library/Developer/Xcode/DerivedData/Lib-def
    ~/.npm/_cacache
Exit: 0 (ok)
```

Restore the whole session byte-for-byte to the original locations:

```bash
swift run cleaner staging restore 6f1c9c2e-…
```

```text
Restoring session 6f1c9c2e-… …
  ✓ App-abc      → ~/Library/Developer/Xcode/DerivedData/App-abc   (checksum verified)
  ✓ Lib-def      → ~/Library/Developer/Xcode/DerivedData/Lib-def   (checksum verified)
  ✓ _cacache     → ~/.npm/_cacache                                 (checksum verified)
Restored 3/3 items · recorded in audit trail
Exit: 0 (ok)
```

If a destination is now occupied, that item is skipped (exit `3`) unless you pass `--force`:

```bash
swift run cleaner staging restore 6f1c9c2e-… --force
```

`staging list --json` and `staging restore … ` both emit the versioned envelope; an unknown
session id exits `2`.

---

## 6. Run the tests

```bash
swift test                                        # full suite
swift test --filter CleanerEngineTests            # one target
swift test --filter Safety                         # the 100%-gate safety suite (.tags(.safety))
swift test --filter CleanerIntegrationTests        # full analyze/clean/rollback + exit-code contract
```

Expected: all tests pass. The safety suite (deny-list × disposition matrix, TOCTOU, symlink
escape, round-trip restore) must be **100% green** — it blocks merge. The round-trip test cleans a
synthesized tree and asserts `staging restore` returns it byte-for-byte identical (content +
metadata) across same-volume and cross-volume staging.

---

## 7. Exit codes (Constitution Article 7)

| Code | Meaning | When you'll see it in v0.1 |
|---|---|---|
| `0` | ok / nothing to do | successful analyze/clean/restore |
| `2` | usage | bad flags, unknown session id, `clean` with no TTY and no `--yes` |
| `3` | partial | some roots skipped (permission) or some items failed/collided |
| `4` | permission | a needed root is inaccessible (Full Disk Access) |
| `5` | cancelled | Ctrl-C / `q` |
| `6` | config | invalid config file |
| `7` | plugin | a plugin failed to load or violated its contract |
| `8` | safety | a protected-path / escaping-symlink attempt was aborted |
| `10` | precondition | unsupported OS (< macOS 13) |

Check it in a script:

```bash
swift run cleaner analyze --json > /tmp/report.json; echo "exit=$?"
```

---

## 8. Where things live

```text
~/.cleaner/                              # overridable via CLEANER_HOME
├── staging/<session-uuid>/              # quarantined items (reversible)
│   ├── manifest.ndjson                  # per-item restore records
│   └── files/…                          # payload mirroring original paths
└── logs/
    ├── cleaner.log                      # structured swift-log output
    └── audit/<date>.ndjson              # append-only audit of every mutation
```

Set `CLEANER_HOME=/tmp/cleaner-sandbox swift run cleaner …` to keep experiments out of your real
`~/.cleaner`.
