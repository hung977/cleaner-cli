# plugin-logs — system & app logs, crash reports

> **Phase H · Plugin id:** `dev.cleaner.logs` · **Target release:** MVP ·
> **Depends on:** plugins/README, 13, 14, 16, 19 (age), 00 Art. 4/5.

Cleans user-level logs and diagnostic reports: `~/Library/Logs`, crash/spin reports under
`DiagnosticReports`, and rotated app logs. Old logs are 🟢 (pure diagnostics); *recent* crash
reports are 🟡 (a developer or support case may still need them). It stays in **user** log space —
it does not touch `/var/log` or the unified system log store (those need elevation and are OS
territory).

## 1. Identity

```swift
PluginManifest(
    id: "dev.cleaner.logs", name: "Logs & Diagnostics", category: .system,
    apiVersion: "1.4.0", pluginVersion: "1.0.0",
    declaredRoots: [
        RootSpec(base: .libraryLogs,               glob: "**"),                              // ~/Library/Logs
        RootSpec(base: .libraryLogs,               glob: "DiagnosticReports/**"),            // user crash/spin reports
        RootSpec(base: .home,                      glob: "Library/Application Support/CrashReporter/**"),
    ],
    defaultRisk: .safe,                          // old logs 🟢; recent crash reports 🟡
    capabilities: [.dryRun, .estimate, .rollback, .audit, .incremental],
    requiresElevation: false, trust: .firstParty)
```

Scope boundary: only the **user** log tree (`~/Library/Logs` and user `DiagnosticReports`). It
does **not** touch `/var/log`, `/Library/Logs` (system-wide), the unified logging database
(`/var/db/diagnostics`), Time Machine logs, or any log a running process holds open. No elevation
is requested (v1).

## 2. What it targets

| Sub-item | Path | Why junk | Risk |
|---|---|---|---|
| App logs (rotated/old) | `~/Library/Logs/<app>/*.log`, `*.log.N`, `*.gz` | Historical diagnostics; superseded by newer logs. | 🟢 |
| Crash reports (old) | `~/Library/Logs/DiagnosticReports/*.ips`/`*.crash` | Post-mortems for past crashes; diagnostic only. | 🟢 |
| Crash reports (recent) | same, mtime < N days | A dev/support case may still need them. | 🟡 |
| Spin/hang/jetsam reports | `*.spin`, `*.hang`, `*.jetsam` | Diagnostic only. | 🟢/🟡 |

Does **not** target: the active/current log file of a running app (open/locked), system logs
outside user space, or logs the user tagged/opened recently.

## 3. Detection signals & algorithm

**Age + activity are the safety signals; location scopes.** Per root:

1. Enumerate files; group per app subdirectory where sensible (one `Item` per log group, or per
   file for `DiagnosticReports`).
2. **Age:** `mtime`/`birthtime`/`lastUsedDate`. Files older than `staleDays` (default 30) → 🟢.
   Crash reports younger than `recentCrashDays` (default 14) → 🟡 (surfaced, not pre-selected):
   someone may be actively investigating.
3. **Active-log guard:** the current log of a running process is `isOpenOrLocked` → skip (never
   truncate a live log, spec 16 §8). Prefer clearly-rotated files (`.log.1`, `.gz`, dated names).
4. **User-authored signal:** a log with Finder tags or under a path the user obviously curates →
   down-rank (rare, but honors "user-authored content" scoring, spec 16 §5).
5. `FindingID = "logs:<app-or-report>:<canonicalPath>"` (deterministic, DM-7).

## 4. Roots / paths with justification

| RootSpec | Resolves to | Justification |
|---|---|---|
| `.libraryLogs / **` | `~/Library/Logs/**` | The user log tree; diagnostics, not user documents. |
| `.libraryLogs / DiagnosticReports/**` | `~/Library/Logs/DiagnosticReports/*.ips` | User crash reports; owned by the user, safe to clear when old. |
| `.home / Library/Application Support/CrashReporter/**` | legacy crash reporter state | Old crash-reporter artifacts. |

`.libraryLogs` is a proposed `RootBase` for `~/Library/Logs` (Open Questions). System log
locations (`/var/log`, `/Library/Logs`) are **not** declared → unreachable without elevation, which
this plugin does not request.

## 5. Risk & safety scoring

| Sub-item | Risk | Score | Notes |
|---|---|---|---|
| Old app logs (> staleDays) | 🟢 90 | diagnostic, superseded | pre-selected |
| Old crash reports | 🟢 88 | post-mortem, old | pre-selected |
| Recent crash reports (< recentCrashDays) | 🟡 65 | may be under investigation | not pre-selected |
| Active/open log | — | excluded (skip) | |

Scores lowered with evidence only (DM-2). Logs never contain irreplaceable user data (they are
diagnostics), so nothing here is 🔴 — but recent crashes stay 🟡 out of respect for active
debugging/support workflows (Principle 1: don't delete something the user needs *now*).

## 6. Recoverability & staging

- `Disposition = .stage` (Principle 2). `Recoverability = .manual` (logs regenerate as the app
  runs; crash reports are gone unless re-triggered — effectively `.hard` for a specific past
  crash, so recent crashes are 🟡 + staged, not purged).
- `RollbackHint`: "logs regenerate; a specific old crash report cannot be re-created — restore from
  staging if a support case needs it." Because staging keeps them recoverable for the retention
  window (spec 21), even the 🟡 recent-crash case is safe.

## 7. Dry-run / estimate

- `estimate`: `allocatedSize` sums (CC-10), `confidence = .exact` (logs are plain files, no
  clones). `.gz`/rotated files counted at their on-disk size.
- `--dry-run` groups by app and by (old 🟢 / recent-crash 🟡), showing the biggest log producers so
  the user sees which app is spamming logs (a useful diagnostic in itself).

## 8. Shell fallback & its safety

**N/A — fully native.** The plugin never invokes `log`/`syslog`/`tmutil`; it only reads and stages
user log files via `context.fs`. (Clearing the unified system log would require `log erase` and
elevation — explicitly out of scope for v1, see Open Questions.)

## 9. Edge cases & false-positive mitigations

| Edge case | Mitigation |
|---|---|
| Live log of a running app | `isOpenOrLocked` → skip; prefer rotated files. |
| Recent crash under active investigation | 🟡, not pre-selected, staged (recoverable). |
| System logs / `/var/log` | Not declared; unreachable (no elevation requested). |
| Unified log store `/var/db/diagnostics` | Out of scope; never touched. |
| App that stores *data* (not logs) under `~/Library/Logs` | Rare, but the age/`isOpenOrLocked` guards + staging protect it; down-rank tagged files. |
| Symlinked log dir | `O_NOFOLLOW`; not followed out of root (spec 16 §6). |
| Log currently being written (rotation race) | fd-identity check at act time (spec 16 §9); skip if it changed. |
| Sensitive data in logs (tokens) | Logs are staged (not exported) and the tool never reads their *contents* for scanning — only metadata (Principle 10). |

## 10. Test cases

- **T1 app log mtime 200d** → 🟢, pre-selected.
- **T2 crash report `.ips` mtime 3d** → 🟡, not pre-selected.
- **T3 crash report mtime 90d** → 🟢.
- **T4 live `.log` held open by a running app** → skipped (`isOpenOrLocked`).
- **T5 `/var/log/...` path** → not scanned (undeclared).
- **T6 `.log.1` rotated + live `.log`** → only rotated one pre-selected.
- **T7 estimate** → allocated sum, exact.
- **T8 recent crash cleaned then rollback** → restored from staging within retention.

## 11. Config keys

`plugins.logs`:

| Key | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | bool | `true` | Master toggle. |
| `staleDays` | int | `30` | Age above which app logs are 🟢. |
| `recentCrashDays` | int | `14` | Crash reports younger than this stay 🟡. |
| `includeCrashReports` | bool | `true` | Include `DiagnosticReports`. |
| `includeSpinHangJetsam` | bool | `true` | Include spin/hang/jetsam reports. |
| `protectApps` | list<string> | `[]` | App log subdirs to never touch (e.g. a support-critical app). |

## Open Questions

- **OQ-logs.1** Ratify `.libraryLogs` anchor in spec 13 §4. *Leaning: yes.*
- **OQ-logs.2** Offer system-log cleanup (`/var/log`, unified store via `log erase`) as an
  elevation-gated v1.0 sub-feature, or keep strictly user-space? *Leaning: user-space only for v1;
  system logs need `.elevation` + a dedicated safety review (spec 23/36).*
- **OQ-logs.3** Per-file vs per-app-directory grouping for the preview — which is clearer for large
  log trees? *Leaning: per-app group with a drill-down (spec 25).*

## Dependencies

**Consumes:** 13 (contract), 14 (types), 16 §5/§6/§8/§9 (metadata, symlink, in-use, TOCTOU), 19
(age thresholds), 00 Art. 4.1 (medium recent crashes), Art. 5 (system paths protected), 21
(staging retention makes 🟡 crashes safe). **Feeds:** 20 (stages logs), 22 (scores), 23 (future
elevation path), 25 (grouping).
