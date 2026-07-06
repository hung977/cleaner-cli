# 08 — Command Reference

> **Phase B · Depends on:** 00-constitution, 06-functional-requirements, 07-nonfunctional-requirements ·
> **Depended on by:** 09 (IA), 11–13, 24 (config), 25 (TUI), 26 (CLI UX), 27 (errors), 31 (tests).
>
> The complete, normative surface of the `cleaner` binary as shipped in **v0.6**. Command tree,
> per-command synopsis, flags, examples, exit codes (Constitution Article 7 — reused, not
> re-invented), the **stdout/stderr contract**, and **versioned JSON schemas** (`schemaVersion`).
> Built on swift-argument-parser (CC-2): usage errors ⇒ exit `2`; `--help` on every node;
> completions (bash/zsh/fish). RFC-2119 keywords are normative.

## 1. Command tree

```
cleaner                          # DEFAULT: scan all enabled plugins → grouped summary → prompt → clean
├── undo            [session]     # restore the last (or a specific) clean from staging   (FR-088)
├── find                          # read-only detectors — list only, never delete
│   ├── large       [paths…]      # rank the largest files under paths                    (FR-003)
│   └── dupes       [paths…]      # find duplicate files under paths                       (FR-004)
│
│  # advanced — hidden from `cleaner --help` (shouldDisplay:false) but fully runnable:
├── docker          [--prune]     # safe Docker prunes only (never volumes/system)         (FR-060)
├── brew            [--run]       # Homebrew cleanup / cache prune                          (FR-061)
├── doctor          [--ci]        # environment health checks                              (FR-072)
└── profile
    └── list                      # list available profiles                                (FR-095)
```

**Dispatch rules.** `cleaner` with **no subcommand** runs the default scan-and-clean flow (§4).
Unknown subcommand ⇒ exit `2`. Every node supports `-h/--help`. The four advanced nodes (`docker`,
`brew`, `doctor`, `profile`) are marked `shouldDisplay:false` — they do not appear in the top-level
`cleaner --help` listing but are documented here and respond to `--help` when named directly.

**Removed since earlier drafts (do not use).** `analyze` → `cleaner --dry-run`; `clean` → the
default `cleaner`; `optimize` → the **NEXT STEPS** block printed under `--dry-run`; `report` →
`--json` / `--md`; `staging` → `undo`. Removed flags: `--all`, `--include medium`. There are **no
risk levels** (no 🟢🟡🔴, no Safe/Medium/Dangerous) anywhere in the surface.

---

## 2. Global flags

Available on the default command and inherited by subcommands where meaningful. Precedence:
CLI flag > env var > config file > built-in default.

| Flag | Type | Default | Meaning |
|---|---|---|---|
| `--dry-run` | bool | false | Compute and show the full plan plus a **NEXT STEPS** block; clean nothing. Exit `0`. (FR-082) |
| `--yes` | bool | false | Clean everything found with **no prompt** (automation/CI). (FR-083) |
| `--json` | bool | false | Emit one versioned machine document on **stdout**; suppress chrome. (FR-084) |
| `--md` | bool | false | Emit a Markdown report (`\| Source \| Reclaimable \|`) on **stdout**. |
| `-v, --verbose` | bool | false | Expand each grouped source to show its underlying items. (FR-086) |
| `--no-color` | bool | false | Disable color/SGR (also honors `NO_COLOR`). (NFR-071) |
| `--include <ids>` | list | — | Restrict the run to these plugin ids (comma-separated). (FR-094) |
| `--exclude <ids>` | list | — | Drop these plugin ids from the run (comma-separated). (FR-094) |
| `--profile <name>` | string | — | Apply a saved profile's plugin selection. (FR-095) |
| `-h, --help` | bool | — | Show help for the node. |

**Selector grammar** (`--include` / `--exclude`): a comma-separated list of **plugin ids**
(e.g. `derived-data,swiftpm,docker`). There is no category/risk/path grammar. **Precedence:**
`--exclude` wins over `--include`; deny-list / protected paths (Article 5) always win over
everything.

**Environment variables:** `CLEANER_HOME` (overrides `~/.cleaner`), `NO_COLOR`, `CLEANER_PROFILE`,
`CLEANER_LOG_LEVEL`. CLI flags override env.

**Conflicts.** `--json` and `--md` are mutually exclusive output modes and both imply
non-interactive (no prompt). `--dry-run` cleans nothing, so `--yes` is a no-op under it (legal but
inert). `--yes` and `--dry-run` together preview only.

---

## 3. stdout / stderr contract (normative, all commands)

1. **stdout carries the result.** In `--json` mode, stdout contains **exactly one** JSON document
   (§9 schema) and nothing else — no logs, no progress, no color. In `--md` mode, stdout carries
   exactly the Markdown report. Human mode: stdout carries the human-readable summary/report.
2. **stderr carries chrome.** Progress lines, the confirm prompt, `--verbose` detail is on stdout
   as part of the report, but interactive prompts and warnings go to **stderr**. This keeps
   `cleaner --json | jq` clean (NFR-112).
3. **Exit code is the contract for scripts** (Article 7). `--json` output additionally carries a
   machine field mirroring the exit reason.
4. **TTY detection:** the confirm prompt renders only when stdin is a TTY and neither `--yes`,
   `--json`, nor `--md` is set; otherwise output is linear plain text and the run either cleans
   (`--yes`) or previews (default without a TTY behaves as `--dry-run`, exit `0`).
5. **Idempotent output:** given identical inputs, human, Markdown, and JSON output are byte-stable
   modulo an explicitly-labeled timestamp/duration block (NFR-031).

---

## 4. The default command — `cleaner`

**Synopsis:** `cleaner [--dry-run] [--yes] [--json] [--md] [-v] [--no-color]
[--include <ids>] [--exclude <ids>] [--profile <name>]`

**Description.** With no subcommand, `cleaner` scans **all enabled plugins** (narrowed by
`--include` / `--exclude` / `--profile`), then prints a **grouped summary by source** — one line per
source, **name left, size right**, no risk colours or levels, no emoji, largest first. It then
prompts:

```
Clean all <size>? [Y = all · s = select each · n = cancel]
```

- **`Y` / Enter** → clean everything found.
- **`s`** → walk each source in turn, asking `clean? [y/N]` per source.
- **`n`** → cancel (exit `5`).

Cleaned items are **moved to staging** (`~/.cleaner/staging/<uuid>`), recoverable via
`cleaner undo` (FR-087/088). The run is idempotent (FR-112): a second immediate run finds nothing
and exits `0`.

**Output modes (non-interactive, no prompt):**
- **`--dry-run`** — print the grouped summary plus a **NEXT STEPS** block (what to run to actually
  reclaim, and how to undo), change nothing, exit `0`.
- **`--yes`** — clean everything found without prompting (automation/CI).
- **`--json`** — emit the machine document (§9), no prompt.
- **`--md`** — emit a Markdown report with columns `| Source | Reclaimable |` (no Risk column), no
  prompt.
- **`-v/--verbose`** — expand each grouped source to list its underlying items (human and Markdown).

**Examples:**
```bash
cleaner                                  # scan, summarize, prompt to clean all / select / cancel
cleaner --dry-run                        # preview + NEXT STEPS block; cleans nothing
cleaner --yes                            # clean everything, no prompt (CI/automation)
cleaner --include derived-data,swiftpm   # only these plugins
cleaner --exclude docker --profile dev   # profile selection minus docker
cleaner --md > cleanup.md                # Markdown report to a file
cleaner --json | jq '.result.totalReclaimBytes'
```

**Exit codes:** `0` ok (incl. nothing to do / `--dry-run`) · `3` partial (some items failed/skipped)
· `4` permission · `5` cancelled (`n` at the prompt) · `6` config · `7` plugin · `8` safety
(invariant abort) · `10` precondition · `11` entitlement (required entitlement missing).

---

## 5. `undo` — restore a clean from staging (FR-088)

**Synopsis:** `cleaner undo [session-id] [--list] [--json]`

**Description.** Restores staged items to their original locations. With **no argument**, undoes the
**most recent** clean session; with a `session-id`, undoes that specific session. `--list` shows the
available staged sessions (id, date, item count, total staged bytes) instead of restoring; `--json`
renders either the restore result or the list as machine output.

**Examples:**
```bash
cleaner undo                     # restore the last clean
cleaner undo 6f1c9c2e            # restore a specific session
cleaner undo --list              # show restorable sessions
cleaner undo --list --json
```

**Exit codes:** `0` ok · `2` unknown session-id / usage · `3` partial (some items couldn't be
restored) · `4` permission · `8` safety.

---

## 6. `find` — read-only detectors (list only)

Both subcommands are strictly read-only: they **list** and never delete or stage anything.

### 6.1 `find large`

**Synopsis:** `cleaner find large [--min <size>] [--top <n>] [paths…]`

Ranks the largest files under the given roots (default `$HOME`). `--min` sets the size threshold
(default `100MB`); `--top` caps the ranked list (default `20`).

```bash
cleaner find large                          # top 20 files ≥ 100MB under $HOME
cleaner find large --min 500MB --top 50 ~/Developer
cleaner find large --json | jq '.result.largeFiles'
```

### 6.2 `find dupes`

**Synopsis:** `cleaner find dupes [--min <size>] [paths…]`

Finds duplicate files under the given roots (default `$HOME`). `--min` sets the minimum file size to
consider (default `1MB`).

```bash
cleaner find dupes                          # duplicates ≥ 1MB under $HOME
cleaner find dupes --min 10MB ~/Downloads
cleaner find dupes --json | jq '.result.duplicates'
```

**Exit codes (both):** `0` ok · `3` partial (roots skipped) · `4` permission.

---

## 7. Advanced commands (hidden from `--help`)

These four nodes are `shouldDisplay:false`: absent from the top-level help listing, fully runnable,
and responsive to `--help` when named directly.

### 7.1 `docker` — safe Docker prunes (FR-060)

**Synopsis:** `cleaner docker [--prune] [--yes]`

Reports and, with `--prune`, runs **safe** Docker reclamation only — build cache and dangling
images. It **never** touches volumes or runs `system prune`. `--yes` skips the confirmation.

```bash
cleaner docker                   # report reclaimable Docker space
cleaner docker --prune           # prune safe artifacts (confirm first)
cleaner docker --prune --yes     # prune without prompting
```

**Exit codes:** `0` ok · `3` partial · `5` cancelled · `7` plugin · `10` precondition (docker not
installed/running).

### 7.2 `brew` — Homebrew cleanup (FR-061)

**Synopsis:** `cleaner brew [--run] [--yes]`

Reports reclaimable Homebrew cache/cleanup and, with `--run`, performs it. `--yes` skips the
confirmation.

```bash
cleaner brew                     # report reclaimable brew space
cleaner brew --run               # run brew cleanup (confirm first)
cleaner brew --run --yes
```

**Exit codes:** `0` ok · `3` partial · `5` cancelled · `7` plugin · `10` precondition (brew not
installed).

### 7.3 `doctor` — environment health (FR-072)

**Synopsis:** `cleaner doctor [--ci]`

Checks and reports the environment: OS version/support, disk access, config validity, plugin load
status, staging integrity, adapter tool availability (docker/brew). `--ci` maps health to CI exit
codes.

```bash
cleaner doctor
cleaner doctor --json
cleaner doctor --ci              # 0 healthy / 3 warnings / 1 critical
```

**Exit codes (interactive):** `0` all healthy · `3` warnings present · `1` critical present ·
`6` config invalid.
**Exit codes (`--ci`):** `0` healthy · `3` warnings · `1` critical (Article 7 mapping).

### 7.4 `profile list` (FR-095)

**Synopsis:** `cleaner profile list [--json]`

Lists available profiles (names + descriptions). A profile is applied to the default run via
`--profile <name>`.

```bash
cleaner profile list
cleaner --profile conservative --yes
```

**Exit codes:** `0` ok · `6` invalid profile file.

---

## 8. Distribution & version

**Install (Homebrew tap, build-from-source):**
```bash
brew tap hung977/tap
brew trust hung977/tap
brew install cleaner
```

**Version.** `cleaner --version` prints the semantic version, git hash, build date, Swift version,
min-OS, and arch slices.

```bash
cleaner --version
```

Exit: `0`.

---

## 9. JSON output schemas (versioned)

All `--json` output is a single UTF-8 JSON document on stdout, top-level field **`schemaVersion`**
(semver string, v0.6 = `"1.0.0"`). Consumers MUST ignore unknown fields (forward-compat) and MUST
branch on `schemaVersion` major. Byte sizes are integers (bytes); sizes also carry a `humanSize`
string. Every result echoes `exitCode` and `exitReason`.

### 9.1 Envelope (common to all commands)
```json
{
  "schemaVersion": "1.0.0",
  "command": "clean",
  "sessionId": "6f1c9c2e-…",
  "startedAt": "2026-07-06T12:00:00Z",
  "durationMs": 1843,
  "exitCode": 0,
  "exitReason": "ok",
  "dryRun": false,
  "warnings": [],
  "result": { }
}
```

### 9.2 Default `cleaner` result (also the shape `--dry-run` returns)
```json
"result": {
  "stagingPath": "/Users/me/.cleaner/staging/6f1c…",
  "totalReclaimBytes": 12884901888,
  "humanSize": "12.0 GiB",
  "sources": [
    { "id": "derived-data", "name": "Xcode DerivedData",
      "reclaimBytes": 5368709120, "humanSize": "5.0 GiB", "itemCount": 12 }
  ],
  "items": [
    { "id": "derived-data:0", "plugin": "derived-data",
      "path": "…/DerivedData/App-abc", "allocatedBytes": 5368709120,
      "risk": "safe", "recoverability": "manual", "status": "staged",
      "evidence": { "regenerable": true, "lastAccess": "…" } }
  ],
  "skipped": [ { "path": "…", "reason": "locked" } ],
  "counts": { "planned": 42, "succeeded": 40, "skipped": 2, "failed": 0 }
}
```

> **Note.** The `risk` string on `items` is **vestigial metadata only** — it is retained for
> forward-compatibility but gates no behaviour and has no human-surface counterpart (no icons, no
> tiers, no auto-selection rules). Consumers SHOULD NOT branch on it.

### 9.3 `find large` / `find dupes` result
```json
"result": {
  "roots": ["/Users/me"],
  "largeFiles": [ { "path": "…", "allocatedBytes": 2147483648, "mtime": "…", "kind": "Disk Image" } ],
  "duplicates": [ { "hash": "sha256:…", "count": 3, "reclaimBytes": 1288490188,
                    "keep": "…", "paths": ["…","…","…"] } ]
}
```
`find large` populates `largeFiles`; `find dupes` populates `duplicates`.

### 9.4 `undo --list` result
```json
"result": {
  "sessions": [
    { "sessionId": "6f1c…", "cleanedAt": "…", "itemCount": 40,
      "stagedBytes": 12884901888, "humanSize": "12.0 GiB" }
  ]
}
```

### 9.5 `doctor` result
```json
"result": {
  "overall": "warning",
  "checks": [
    { "id": "diskAccess", "status": "warning",
      "message": "Some caches unreadable without additional access",
      "remedy": "Grant access in System Settings › Privacy & Security" }
  ]
}
```

**Schema governance.** JSON schemas are versioned independently per command family under
`schemaVersion`; a breaking field change bumps the major. The canonical schema files live with the
Reporting module and are snapshot-tested (spec 31).

---

## 10. Exit-code summary (reuse of Article 7)

| Code | Name | Where it appears |
|---|---|---|
| 0 | ok | any command success / nothing to do / `--dry-run` |
| 1 | general / critical | unclassified error; `--ci` doctor "critical" |
| 2 | usage | bad args/flags, unknown id, unknown session-id |
| 3 | partial / warnings | some items skipped/failed; `--ci` doctor "warnings" |
| 4 | permission | required disk access / admin not granted |
| 5 | cancelled | `n` at the prompt / Ctrl-C |
| 6 | config | invalid config or profile file |
| 7 | plugin | plugin failed to load / violated contract |
| 8 | safety | aborted by a safety invariant (protected-path attempt) |
| 10 | precondition | unsupported OS / adapter tool (docker/brew) unavailable |
| 11 | entitlement | a required macOS entitlement is missing |
| 130 | sigint | POSIX signal interruption (reserved) |

---

## Open Questions

- **OQ-08.1** Should `undo` gain a `--purge`/retention flag to permanently drop old staged sessions,
  or is retention entirely config-driven (spec 24)? *Leaning: config-driven, revisit if requested.*
- **OQ-08.2** Should `find` gain an `--old <days>` detector alongside `large`/`dupes`?
  *Leaning: defer; keep `find` to the two shipped detectors.*
- **OQ-08.3** Should any of the hidden advanced commands (`docker`/`brew`) be promoted into the main
  `--help` listing once documented? *Leaning: keep hidden; surface via docs + `doctor`.*
- **OQ-08.4** JSON: emit NDJSON streaming for very large result sets (NFR-013) as an alternative to
  one document? *Leaning: add `--json-stream` in a 1.x, single-doc for now.*

## Dependencies

- **Consumes:** 00 (exit codes, staging/undo, directory layout), 06 (the FRs each command realizes),
  07 (stdout/stderr + responsiveness NFRs), 10 (swift-argument-parser).
- **Feeds:** 09 (IA maps this surface to navigation), 11–13 (command→engine wiring, plugin metadata),
  24 (config keys), 25 (TUI for the interactive prompt), 26 (CLI UX detail), 27 (error→exit-code
  mapping), 31 (CLI + JSON-schema snapshot tests).
