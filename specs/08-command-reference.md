# 08 — Command Reference

> **Phase B · Depends on:** 00-constitution, 06-functional-requirements, 07-nonfunctional-requirements ·
> **Depended on by:** 09 (IA), 11–13, 24 (config), 25 (TUI), 26 (CLI UX), 27 (errors), 31 (tests).
>
> The complete, normative surface of the `cleaner` binary. Command tree, per-command synopsis,
> flags, examples, exit codes (Constitution Article 7 — reused, not re-invented), the
> **stdout/stderr contract**, and **versioned JSON schemas** (`schemaVersion`). Built on
> swift-argument-parser (CC-2): usage errors ⇒ exit `2`; `--help` on every node; completions
> (bash/zsh/fish). RFC-2119 keywords are normative.

## 1. Command tree

```
cleaner                         # interactive TUI (no subcommand + TTY) → FR-076
├── analyze        [paths…]     # read-only usage analysis + storage report   (FR-070)
├── audit          [paths…]     # detection advisories, risk-ranked           (FR-071)
├── clean          [selectors]  # preview → confirm → dispose (primary verb)  (FR-075)
├── optimize                    # curated one-shot safe maintenance           (FR-074)
├── doctor                      # environment health checks                   (FR-072)
├── report         [session]    # render a persisted session's results        (FR-073)
│
├── plugins                     # plugin management
│   ├── list
│   └── info <plugin-id>
├── config                      # configuration management
│   ├── get   <key>
│   ├── set   <key> <value>
│   ├── edit
│   └── validate [file]
├── staging                     # quarantine management (rollback surface)
│   ├── list
│   ├── restore <session|item> [--force]
│   └── purge   <session|item|--older-than>
├── profile                     # profile management
│   ├── list
│   ├── show   <name>
│   ├── save   <name>
│   └── delete <name>
├── completion  <bash|zsh|fish> # emit shell completion script
├── version                     # print version/build info      (also: --version)
└── self-update                 # v2 STUB — refuses in v1        (exit 10)
```

**Dispatch rules.** `cleaner` with **no subcommand** and a **TTY** ⇒ interactive TUI (FR-076).
No subcommand and **no TTY** ⇒ print help, exit `2`. Unknown subcommand ⇒ exit `2`. Every node
supports `-h/--help`.

---

## 2. Global flags

Available on every command (parsed by the root; subcommands inherit). Precedence:
CLI flag > env var > config file > built-in default.

| Flag | Type | Default | Meaning |
|---|---|---|---|
| `-v, --verbose` | count | 0 | Increase human-readable detail (repeatable: `-vv`). (FR-086) |
| `--debug` | bool | false | Emit diagnostic traces (timings, decisions, adapter calls) to **stderr**. (FR-086/NFR-112) |
| `--dry-run` | bool | false | Compute and show the full plan; dispose of nothing. Exit `0`. (FR-082) |
| `-y, --yes` | bool | false | Auto-confirm 🟢 (and 🟡 with `--include medium`); NEVER 🔴. (FR-083) |
| `--json` | bool | false | Emit versioned machine-readable result on **stdout**; suppress chrome. (FR-084) |
| `--ci` | bool | false | Non-interactive; implies `--no-tui --no-color`; stable exit codes; never prompts. (FR-085) |
| `--no-tui` | bool | false | Disable full-screen TUI; use linear plain output. (NFR-070) |
| `--no-color` | bool | false | Disable color/SGR (also honors `NO_COLOR`). (NFR-071) |
| `--config <path>` | path | `~/.cleaner/config.yml` | Use an alternate config file. (FR-096, spec 24) |
| `--profile <name>` | string | — | Apply a saved profile's plugin selection + options. (FR-095) |
| `--include <sel>` | list | — | Include by plugin-id / category / risk (`safe\|medium\|dangerous`) / path glob. (FR-094) |
| `--exclude <sel>` | list | — | Exclude by the same selector grammar. (FR-094) |
| `--plugins <ids>` | list | all enabled | Restrict the run to these plugin ids. (FR-041) |
| `-h, --help` | bool | — | Show help for the node. |

**Selector grammar** (`--include`/`--exclude`): comma-separated tokens, each one of
`plugin:<id>`, `category:<name>`, `risk:<safe|medium|dangerous>`, or a `path:<glob>`.
Bare tokens are matched as plugin-id then category. **Precedence:** `--exclude` wins over
`--include`; `--plugins` narrows the universe first; deny-list/protected paths (Article 5)
always win over everything.

**Environment variables:** `CLEANER_HOME` (overrides `~/.cleaner`), `NO_COLOR`,
`CLEANER_CONFIG`, `CLEANER_PROFILE`, `CLEANER_LOG_LEVEL`. CLI flags override env.

**Conflicts.** `--json`/`--ci` imply non-interactive: prompts are errors ⇒ if confirmation is
required and neither `--yes` nor a signed policy is present, exit `2` (usage) for `clean`/
`optimize`. `--dry-run` with `--yes` is legal (yes is a no-op under dry-run).

---

## 3. stdout / stderr contract (normative, all commands)

1. **stdout carries the result.** In `--json` mode, stdout contains **exactly one** JSON
   document (§9 schema) and nothing else — no logs, no progress, no color. Human mode: stdout
   carries the human-readable result/report.
2. **stderr carries chrome.** Progress bars, spinners, TUI frames, prompts, `--verbose`/
   `--debug` diagnostics, and warnings go to **stderr**. This keeps `cleaner … --json | jq`
   clean (NFR-112).
3. **Exit code is the contract for scripts** (Article 7). `--json` output additionally carries
   a machine field mirroring the exit reason.
4. **TTY detection:** progress/TUI render only when stderr is a TTY and neither `--no-tui`/
   `--ci`/`--json` is set; otherwise output is linear plain text.
5. **Idempotent output:** given identical inputs, human and JSON output are byte-stable modulo
   an explicitly-labeled timestamp/duration block (NFR-031).

---

## 4. Action commands

### 4.1 `analyze` — read-only usage analysis (FR-070)

**Synopsis:** `cleaner analyze [paths…] [--min-size <size>] [--top <n>] [--depth <n>]
[--duplicates] [--old <days>] [global flags]`

**Description.** Read-only scan (never mutates). Produces a storage report (capacity/used/
free/purgeable/reclaimable) and size-attributed breakdown by category and plugin, plus optional
large-file / duplicate / old-file findings. Always exits `0` on success; `4` if a needed root is
inaccessible (permission), `3` if some roots were skipped.

**Arguments:** `paths…` — one or more roots (default: `$HOME`; `--all-volumes` for every mounted
local volume).

**Flags:** `--min-size <size>` (large-file threshold, default 1GiB; accepts `500MB`, `2GiB`),
`--top <n>` (limit ranked lists, default 50), `--depth <n>` (tree depth for breakdown),
`--duplicates` (run duplicate pipeline, FR-004), `--old <days>` (old-file cutoff, FR-005),
`--all-volumes`, `--no-cache` (ignore incremental cache, FR-007).

**Examples:**
```bash
cleaner analyze                          # analyze $HOME, human report
cleaner analyze / --all-volumes --json   # whole machine, JSON to stdout
cleaner analyze ~/Developer --min-size 500MB --top 20
cleaner analyze --duplicates --old 365 --json | jq '.findings.duplicates'
```
**Exit codes:** `0` ok · `3` partial (roots skipped) · `4` permission · `5` cancelled ·
`10` unsupported env.

### 4.2 `audit` — detection advisories (FR-071)

**Synopsis:** `cleaner audit [paths…] [--categories <list>] [--min-savings <size>]
[--sort <size|risk|age>] [global flags]`

**Description.** Runs detection (FR-050–061): unused apps, orphan packages, obsolete SDKs, stale
DerivedData, old runtimes/archives, unnecessary localizations, temp downloads, duplicate cache,
zombie dirs. Read-only; acts on nothing. Emits a prioritized, risk-ranked opportunity list with
evidence. In `--ci`, maps to CI health codes.

**Flags:** `--categories <list>`, `--min-savings <size>` (hide opportunities below N),
`--sort <size|risk|age>` (default `size`), `--include/--exclude` (risk/category filters).

**Examples:**
```bash
cleaner audit                            # ranked advisories for $HOME
cleaner audit --sort risk --json
cleaner audit --ci                       # exit 0 healthy / 3 warnings / 1 critical
```
**Exit codes (interactive):** `0` ok · `3` partial · `4` permission.
**Exit codes (`--ci`):** `0` no significant reclaimable / healthy · `3` warnings (reclaimable
found) · `1` critical (e.g. free space below headroom).

### 4.3 `clean` — dispose selected junk (FR-075) — **primary destructive verb**

**Synopsis:** `cleaner clean [selectors] [--stage|--trash|--no-stage] [--min-size <size>]
[--older-than <days>] [-y] [--dry-run] [global flags]`

**Description.** Runs the **preview → confirm → dispose** pipeline (principle 1). Selects plugins
via `--plugins`/`--include`/`--exclude`/`--profile`; scans; classifies (🟢🟡🔴); presents a
preview (paths, sizes, risk, disposition, recoverability, projected Reclaim); then, on
confirmation, disposes. **Default disposition: `stage`** (`~/.cleaner/staging/<uuid>`, FR-087).
🟢 pre-selected; 🟡 shown but not pre-selected; 🔴 shown, never pre-selected, requires **typed**
confirmation (Article 4.1). Idempotent (FR-112).

**Disposition flags (mutually exclusive):** `--stage` (default, reversible), `--trash` (route to
macOS Trash via `NSWorkspace.recycle`, FR-090), `--no-stage` (permanent purge; requires explicit
confirmation and MUST NOT run under `--ci`/`--json` without `--yes` **and** a signed policy —
Article 4.4).

**Other flags:** `--min-size`, `--older-than <days>`, `--keep <n>` (retain most-recent N per
group, e.g. logs), `--assume-fda` (skip the Full-Disk-Access probe when already granted).

**Examples:**
```bash
cleaner clean --plugins derived-data,swiftpm            # interactive preview+confirm
cleaner clean --include risk:safe --yes                 # auto-clean all 🟢
cleaner clean --profile developer-daily --yes
cleaner clean --include category:docker --dry-run --json
cleaner clean --include risk:dangerous                  # typed confirmation required
cleaner clean --plugins trash --no-stage --yes          # empty Trash permanently
```
**Exit codes:** `0` ok (incl. nothing to do) · `3` partial (some items failed/skipped) ·
`4` permission · `5` cancelled · `6` config · `7` plugin · `8` safety (invariant abort) ·
`2` usage (e.g. `--no-stage` non-interactive without policy).

### 4.4 `optimize` — curated safe one-shot (FR-074)

**Synopsis:** `cleaner optimize [-y] [--dry-run] [global flags]`

**Description.** Convenience "make space now": a fixed curated set of mostly-🟢 categories (safe
caches, temp files, crash reports, Trash *report*, logs trim) run preview-first. **Never**
includes 🔴. `--include medium` may opt-in 🟡 (OQ-06.1). Equivalent to a built-in conservative
profile; honors `--yes`.

**Examples:**
```bash
cleaner optimize                 # preview curated safe cleanup, confirm
cleaner optimize --yes           # run it non-interactively (🟢 only)
cleaner optimize --dry-run --json
```
**Exit codes:** as `clean`.

### 4.5 `doctor` — environment health (FR-072)

**Synopsis:** `cleaner doctor [--fix] [global flags]`

**Description.** Checks and reports 🟢/🟡/🔴 per item: OS version/support, Full Disk Access,
admin availability, TTY presence, config validity, plugin load status, staging integrity,
free-space headroom, adapter tool availability (docker/brew/xcrun). `--fix` performs safe
auto-remediations only (e.g. repair a corrupt staging index, recreate `~/.cleaner` layout).

**Examples:**
```bash
cleaner doctor
cleaner doctor --json
cleaner doctor --ci              # 0 healthy / 3 warnings / 1 critical
```
**Exit codes (interactive):** `0` all healthy · `3` warnings present · `1` critical present ·
`6` config invalid.
**Exit codes (`--ci`):** `0` healthy · `3` warnings · `1` critical (Article 7 mapping).

### 4.6 `report` — render a persisted session (FR-073)

**Synopsis:** `cleaner report [session-id] [--format <human|json|markdown|html>]
[--output <path>] [--last] [global flags]`

**Description.** Renders a prior session's stored results (`~/.cleaner/reports`) without
rescanning. `--last` (default when no id) picks the most recent session; `report list` sub-form
lists available sessions.

**Examples:**
```bash
cleaner report --last --format markdown
cleaner report 6f1c… --format html --output ~/Desktop/cleanup.html
cleaner report --json
```
**Exit codes:** `0` ok · `2` unknown session-id/format · `6` corrupt report store.

---

## 5. Management: `plugins`

### `plugins list`
**Synopsis:** `cleaner plugins list [--enabled|--disabled] [global flags]`
Lists all plugins: id, category, default risk, enabled state, native/fallback status.
```bash
cleaner plugins list
cleaner plugins list --json
```
Exit: `0`.

### `plugins info <plugin-id>`
Shows a plugin's declared roots, risk defaults, recoverability, native API + shell fallback,
options, and any adapter prerequisites. Unknown id ⇒ exit `2`.
```bash
cleaner plugins info docker
```

---

## 6. Management: `config`

`config get <key>` · `config set <key> <value>` · `config edit` (opens `$EDITOR` on
`~/.cleaner/config.yml`) · `config validate [file]` (schema-check; exit `6` on invalid).

```bash
cleaner config get scan.minLargeFileSize
cleaner config set staging.retentionDays 30
cleaner config edit
cleaner config validate ./team-config.yml
```
Exit: `0` ok · `2` unknown key/usage · `6` invalid config. Keys are dotted paths into the
config schema (spec 24). `set` MUST re-validate before persisting and MUST reject writes to
deny-list-relevant keys that would weaken safety without an explicit `--force-unsafe` + ack.

---

## 7. Management: `staging` (rollback surface, FR-088/089)

### `staging list`
Lists staged sessions/items: session UUID, date, item count, total staged bytes, original
paths, expiry (retention). `--session <uuid>` drills into one.
```bash
cleaner staging list
cleaner staging list --json
```

### `staging restore <session|item> [--force]`
Restores staged items to their original locations (FR-088). Refuses if destination is occupied
unless `--force`. Records the restore in the audit trail.
```bash
cleaner staging restore 6f1c…                 # restore a whole session
cleaner staging restore 6f1c…:42 --force      # restore one item, overwrite
```
Exit: `0` ok · `3` partial (some couldn't restore) · `2` unknown id · `8` safety.

### `staging purge <session|item|--older-than <days>>`
**Permanent** deletion of staged items — the only irreversible operation (Article 3). Requires
confirmation (typed in interactive; `--yes` in scripts). `--older-than <days>` and `--all`
supported; retention-based auto-purge is driven by config (spec 24).
```bash
cleaner staging purge --older-than 30 --yes
cleaner staging purge 6f1c…
```
Exit: `0` ok · `2` unknown id/usage · `5` cancelled.

---

## 8. Management: `profile`, `completion`, `version`, `self-update`

### `profile list|show|save|delete` (FR-095)
`profile list` (names + descriptions), `profile show <name>` (plugin selection + options),
`profile save <name>` (persist current selectors/options as `~/.cleaner/profiles/<name>.yml`),
`profile delete <name>`. Built-ins `developer-daily`, `conservative`, `aggressive` ship
read-only. Apply a profile on any action command via `--profile <name>`.
```bash
cleaner profile list
cleaner clean --profile conservative --yes
cleaner profile save my-weekly
```
Exit: `0` · `2` unknown name (show/delete) · `6` invalid profile file.

### `completion <bash|zsh|fish>`
Emits the shell completion script to stdout (swift-argument-parser generated).
```bash
cleaner completion zsh > ~/.zsh/completions/_cleaner
```
Exit: `0` · `2` unknown shell.

### `version` / `--version`
Prints semantic version, git hash, build date, Swift version, min-OS, arch slices. `--json`
supported. `cleaner --version` is equivalent to `cleaner version`.
```bash
cleaner version --json
```
Exit: `0`.

### `self-update` — **v2 STUB**
Reserved for v2. In v1 it MUST print a message directing the user to Homebrew
(`brew upgrade cleaner`) / GitHub Releases and exit `10` (precondition/unsupported). It MUST NOT
perform any network I/O in v1 (principle 10).
```bash
cleaner self-update            # → "not available in v1; use brew upgrade cleaner", exit 10
```

---

## 9. JSON output schemas (versioned)

All `--json` output is a single UTF-8 JSON document on stdout, top-level field
**`schemaVersion`** (semver string, v1 = `"1.0.0"`). Consumers MUST ignore unknown fields
(forward-compat) and MUST branch on `schemaVersion` major. Byte sizes are integers (bytes);
sizes also carry a `humanSize` string. Every result echoes `exitCode` and `exitReason`.

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

### 9.2 `analyze` result
```json
"result": {
  "roots": ["/Users/me"],
  "volume": { "capacityBytes": 4000e9, "usedBytes": 3200e9, "freeBytes": 800e9,
              "purgeableBytes": 120e9, "reclaimableBytes": 45e9 },
  "byCategory": [ { "category": "developer", "allocatedBytes": 30e9, "logicalBytes": 31e9,
                    "itemCount": 12045, "plugins": ["derived-data","swiftpm"] } ],
  "findings": {
    "largeFiles": [ { "path": "…", "allocatedBytes": 2e9, "mtime": "…", "kind": "Disk Image" } ],
    "duplicates": [ { "hash": "sha256:…", "count": 3, "reclaimBytes": 1.2e9,
                      "keep": "…", "paths": ["…","…","…"] } ],
    "oldFiles": [ { "path": "…", "atime": "…", "allocatedBytes": 5e8 } ]
  }
}
```

### 9.3 `clean` / `optimize` result (also the shape `--dry-run` returns)
```json
"result": {
  "disposition": "stage",
  "stagingPath": "/Users/me/.cleaner/staging/6f1c…",
  "totalReclaimBytes": 12884901888,
  "humanSize": "12.0 GiB",
  "items": [
    { "id": "derived-data:0", "plugin": "derived-data", "category": "developer",
      "path": "…/DerivedData/App-abc", "allocatedBytes": 5368709120,
      "risk": "safe", "riskIcon": "🟢", "safetyScore": 96,
      "recoverability": "manual", "disposition": "stage", "status": "staged",
      "evidence": { "regenerable": true, "lastAccess": "…" } }
  ],
  "skipped": [ { "path": "…", "reason": "locked", "risk": "medium" } ],
  "counts": { "planned": 42, "succeeded": 40, "skipped": 2, "failed": 0 }
}
```

### 9.4 `audit` result
```json
"result": {
  "opportunities": [
    { "id": "unused-app:0", "type": "unusedApp", "risk": "dangerous", "riskIcon": "🔴",
      "reclaimBytes": 800e6, "path": "/Applications/Foo.app", "advisoryOnly": true,
      "evidence": { "lastUsed": "2023-01-…", "launchServicesSeen": false } }
  ],
  "totals": { "count": 37, "reclaimBytes": 45e9 }
}
```

### 9.5 `doctor` result
```json
"result": {
  "overall": "warning",
  "checks": [
    { "id": "fullDiskAccess", "status": "warning", "icon": "🟡",
      "message": "Full Disk Access not granted; some caches unreadable",
      "remedy": "Grant in System Settings › Privacy & Security" }
  ]
}
```

### 9.6 `staging list`, `plugins list`, `report`
Follow the same envelope; `result` is an array (`sessions` / `plugins`) or the persisted
session document (`report`). Each documented in specs 21, 13, and 28 respectively; all carry
`schemaVersion`.

**Schema governance.** JSON schemas are versioned independently per command family under
`schemaVersion`; a breaking field change bumps the major. The canonical schema files live with
the Reporting module and are snapshot-tested (spec 31).

---

## 10. Exit-code summary (reuse of Article 7)

| Code | Name | Where it appears |
|---|---|---|
| 0 | ok | any command success / nothing to do |
| 1 | general / critical | unclassified error; `--ci` doctor/audit "critical" |
| 2 | usage | bad args/flags, unknown id/key/shell, non-interactive confirm required |
| 3 | partial / warnings | some items skipped/failed; `--ci` doctor/audit "warnings" |
| 4 | permission | Full Disk Access / admin not granted |
| 5 | cancelled | Ctrl-C / `q` / timeout |
| 6 | config | invalid config or profile file |
| 7 | plugin | plugin failed to load / violated contract |
| 8 | safety | aborted by a safety invariant (protected-path attempt) |
| 10 | precondition | unsupported OS / no TTY where required / `self-update` v1 |
| 130 | sigint | POSIX signal interruption (reserved) |

---

## Open Questions

- **OQ-08.1** Should `report` expose a `report list` as a proper subcommand vs. a `--list` flag?
  *Leaning: `--list` flag on `report` for a flat surface.*
- **OQ-08.2** `--no-stage` under `--ci`: require a signed policy always, or allow with
  `--yes --force-unsafe`? Coordinate with spec 23. *Leaning: signed policy required.*
- **OQ-08.3** Do we add a top-level `--all-volumes` global flag, or keep it per-command
  (`analyze`/`audit`/`clean`)? *Leaning: per-command.*
- **OQ-08.4** JSON: emit NDJSON streaming for very large result sets (NFR-013) as an alternative
  to one document? *Leaning: add `--json-stream` in a 1.x, single-doc in v1.*
- **OQ-08.5** Should `optimize` accept `paths…` or always operate on well-known roots?
  *Leaning: well-known roots only.*

## Dependencies

- **Consumes:** 00 (exit codes, risk icons, dispositions, directory layout), 06 (the FRs each
  command realizes), 07 (stdout/stderr + responsiveness NFRs), 10 (swift-argument-parser).
- **Feeds:** 09 (IA maps this surface to navigation), 11–13 (command→engine wiring, plugin
  metadata for `plugins`), 24 (config keys for `config`), 25 (TUI for interactive `cleaner`),
  26 (CLI UX detail), 27 (error→exit-code mapping), 31 (CLI + JSON-schema snapshot tests).
