# 27 — Error Handling Strategy

> **Phase F · Depends on:** 00-constitution (Art. 6 `CleanerError`, Art. 7 exit codes, Art. 1
> principles), 07 (NFR-035 graceful degradation, NFR-040…043 cancellation, NFR-043 terminal restore),
> 08 (exit-code mapping, stdout/stderr contract, JSON envelope), 09 (error presentation in screens),
> 25 (TUI error/toast rendering, terminal restore on panic), 26 (error UX: what/why/next) ·
> **Depended on by:** 24/28/29 (their error codes), 31 (error-path tests), every engine spec.
>
> The single strategy for representing, surfacing, aggregating, and recovering from failure. Defines
> the `CleanerError` protocol, the taxonomy→exit-code map, how errors render across TUI/JSON/logs,
> partial-failure aggregation (exit `3`), the user-facing message style, panic/crash handling, retry
> policy, and cancellation as a non-error path. RFC-2119 keywords are normative. Exit codes are
> **reused** from Article 7, never re-invented.

---

## 1. Principles

- **EH-1 — Fail closed on safety, open on everything else.** A safety-invariant violation aborts hard
  (exit `8`); a *recoverable* per-item failure is isolated, reported, and the run continues
  (NFR-035). Never trade safety for completion; never abort a whole session for one bad item.
- **EH-2 — Every error carries its exit code.** Errors don't decide exit codes ad hoc at the top
  level; each conforms to `CleanerError` and *is* its exit code (Article 6/7). The process exit is a
  deterministic function of the errors seen (§ 5).
- **EH-3 — Three-part messages.** Every user-facing error says **what went wrong · why · what to do
  next** (spec 26 §6). No bare codes, no stack traces by default.
- **EH-4 — One representation, three renderings.** The same `CleanerError` value renders to TUI,
  `--json`, and logs without re-authoring (§ 4).
- **EH-5 — Cancellation is not an error.** User cancel / timeout is an expected outcome with its own
  path and exit `5`, not an exception dumped as a failure (§ 9).
- **EH-6 — Truthful partial results** (principle 3). A run that did *some* work reports exactly what
  succeeded, skipped, and failed, and exits `3` — never `0` if anything was left undone, never `1` if
  the outcome is a clean partial.

---

## 2. The `CleanerError` protocol

Every error type in the codebase conforms to `CleanerError` (Article 6). It is `Sendable` and
`Error`, carries a stable machine identity, its exit code, and human remediation.

```swift
public protocol CleanerError: Error, Sendable, CustomStringConvertible {
    /// Stable, ASCII, machine identity, e.g. "permission.fullDiskAccess", "config.badType".
    /// Never localized; forms the `errorCode` in --json and logs. Grouped by domain (§3).
    var code: String { get }

    /// The exit code this error maps to (Article 7). MUST be one of the fixed set.
    var exitCode: ExitCode { get }

    /// One-sentence WHAT went wrong, localized (spec 26 voice). No trailing period rules per style.
    var message: String { get }

    /// WHY it happened, localized, optional. Context a user needs to understand the failure.
    var reason: String? { get }

    /// WHAT to do next: an actionable remediation (a command, a Settings path). Localized.
    var remediation: String? { get }

    /// The wrapped lower-level cause (errno, POSIXError, Yams error, plugin error) for logs/--debug.
    var underlyingCause: Error? { get }

    /// TRUE if the run can continue past this (per-item/plugin isolation → aggregate, §5).
    /// FALSE aborts the command with `exitCode`.
    var isRecoverable: Bool { get }

    /// Structured, NON-SENSITIVE key/values for logs and --json (path, plugin, size, phase…).
    /// Paths are recorded (audit needs them) but honor --redact-paths on export (NFR-062).
    var context: [String: String] { get }
}
```

- **`code`** is a dotted `domain.detail` string (§ 3), stable across releases (a released code is
  never repurposed). It is the join key between message catalog, docs, and JSON.
- **`exitCode`** is drawn only from Article 7's fixed set (`ExitCode` is an enum over them).
- **`isRecoverable`** drives aggregation (§ 5): recoverable errors accumulate into a partial result
  (exit `3`); non-recoverable ones abort with their `exitCode`.
- **`context`** never contains file *contents* (NFR-062); paths are allowed (audit) but redactable on
  export.

### 2.1 Convenience layer

A base `struct CleanerErr: CleanerError` covers common cases via factory helpers
(`.permission(path:)`, `.config(code:at:snippet:)`, `.pathVanished(path:)`, `.pluginFailed(id:cause:)`,
`.safetyViolation(path:)`) so call sites are terse and consistent. Domain modules may define richer
concrete types (e.g. `ConfigError` with a source location) that still conform.

---

## 3. Taxonomy → exit-code map

Errors group by **domain**; each domain's default exit code follows Article 7. `isRecoverable` is a
per-instance property (a permission error on one root is recoverable; on the *only* root it's fatal).

| Domain (`code` prefix) | Meaning | Default `exitCode` | Typically recoverable? |
|---|---|---|---|
| `usage.*` | bad args/flags, unknown id/key/shell, prompt-required-non-interactive | `2` usage | no (pre-run) |
| `config.*` | invalid config/profile (parse/type/range/rule/migration) | `6` config | no |
| `permission.*` | Full Disk Access / admin / read-denied | `4` permission | per-root: yes → aggregate |
| `plugin.*` | plugin load failure / contract violation / adapter error | `7` plugin | per-plugin: yes → isolate |
| `safety.*` | protected-path attempt, symlink-escape, invariant breach | `8` safety | **no** (fail closed, EH-1) |
| `fs.*` | path vanished, locked/in-use, I/O error, cross-volume, ENOSPC | `3` partial | per-item: yes |
| `precondition.*` | unsupported OS, no TTY where required, missing adapter tool | `10` precondition | no (pre-run) |
| `cancelled.*` | user cancel / timeout (NOT an error path, § 9) | `5` cancelled | n/a |
| `internal.*` | unexpected/invariant-broken (bug) → panic path (§ 8) | `1` general | no |

**Aggregation rule (EH-6):** when a run finishes with a mix, the process exit is the **highest-
severity** applicable code by this precedence: `8 > 6 > 7 > 4 > 2 > 3 > 1 > 5 > 0` — i.e. a safety
abort or config error outranks a partial; a clean run with only skipped items is `3`; a fully clean
run is `0`; a pure cancel with no failures is `5`. (See § 5 for the exact resolver.)

---

## 4. One error, three renderings

### 4.1 TUI / human (stderr)

Three-part, located, colored by `error`/`warning` token (spec 25 §6), icon `✖`/`⚠`, never a stack
trace unless `--debug`.

```
✖ Can't read ~/Library/Mail
  why:  macOS restricts this folder to apps with Full Disk Access
  fix:  System Settings › Privacy & Security › Full Disk Access → enable "cleaner", then re-run
  (skipping this folder — partial results follow)
```

In the interactive TUI a recoverable error becomes a **toast** (spec 25 §3) and a per-item `skipped`
row; a fatal error tears down the alt-screen (restoring the terminal, NFR-043) and prints the block
above to stderr.

### 4.2 `--json` (stderr for the error object; stdout still gets the result envelope)

Errors surface inside the spec-08 §9 envelope. Recoverable errors go in `warnings[]` / `result.
skipped[]`; a fatal error sets `exitCode`/`exitReason` and adds an `error` object. The single stdout
document remains valid JSON (spec 08 §3.1); human error prose goes to stderr only.

```json
{
  "schemaVersion": "1.0.0", "command": "clean", "sessionId": "6f1c…",
  "exitCode": 3, "exitReason": "partial", "dryRun": false,
  "warnings": [
    { "code": "permission.fullDiskAccess", "message": "Can't read ~/Library/Mail",
      "reason": "Full Disk Access required", "remediation": "Enable in System Settings › Privacy…",
      "context": { "path": "~/Library/Mail", "phase": "scan" } }
  ],
  "result": { "counts": { "planned": 42, "succeeded": 40, "skipped": 2, "failed": 0 },
              "skipped": [ { "path": "~/.npm", "reason": "locked", "code": "fs.locked" } ] }
}
```

A **fatal** error (non-recoverable) instead yields `"result": null` (or best-effort partial) plus a
top-level `"error": { code, message, reason, remediation, context }` and the matching `exitCode`.

### 4.3 Logs / audit (files)

Every error — recoverable or fatal — is logged as a structured `swift-log` record (spec 28) with
`code`, `exitCode`, `context`, `underlyingCause` (full, incl. errno), and the session UUID.
Filesystem mutations that failed mid-flight are additionally recorded in the **audit** NDJSON
(spec 28) so the report and `staging` reflect reality (NFR-042). `--debug` mirrors the full cause
chain to stderr (never stdout, NFR-112).

---

## 5. Partial-failure aggregation (exit `3`)

The engine collects outcomes into a **`RunLedger`** actor as work streams. Each item/plugin yields
`succeeded | skipped(CleanerError) | failed(CleanerError)`; recoverable errors never propagate up —
they land in the ledger and the run continues (NFR-035, EH-1).

```
                 ┌──────────────── RunLedger (actor) ────────────────┐
 per-item  ────▶ │  succeeded[]   skipped[](err)   failed[](err)     │
 per-plugin ───▶ │  fatal?: CleanerError?   cancelled?: Bool         │
                 └──────────────────────┬────────────────────────────┘
                                        ▼  at session end
                       resolveExitCode(ledger) → ExitCode
```

**`resolveExitCode`** (deterministic, EH-2):

1. If `ledger.fatal != nil` → that error's `exitCode` (safety `8` / config `6` / plugin `7` /
   permission `4` if *all* roots failed / precondition `10` / internal `1`). Highest severity wins if
   several (precedence in § 3).
2. Else if `ledger.cancelled` and no failures → `5`.
3. Else if `failed[]`.isEmpty is false **or** `skipped[]` is non-empty **or** a *subset* of roots hit
   permission → `3` (partial). The report lists every skipped/failed item with its `code` + reason.
4. Else → `0`.

The **Summary (S7)** and the JSON `counts`/`skipped`/`failed` are the human/machine face of the
ledger; totals are truthful (principle 3) — "40 staged · 2 skipped · 0 failed", exit `3`.

---

## 6. User-facing message style (the three parts)

Realized from spec 26 §11 voice. **Message** = what (one sentence, no blame, name the object).
**Reason** = why (the mechanism, optional but preferred). **Remediation** = the next command or
setting. Examples for the common cases:

**Permission denied (recoverable per-root):**
```
✖ Can't read ~/Library/Mail
  why:  Full Disk Access is required for this folder
  fix:  System Settings › Privacy & Security › Full Disk Access → enable "cleaner", then re-run
```
`code: permission.fullDiskAccess` · exit `4` if it was the only root, else contributes to `3`.

**Config invalid (fatal):**
```
✖ Invalid configuration: scan.minLargeFileSize is not a valid size (~/.cleaner/config.yml:41)
  why:  "1 Gigabyte" isn't a recognized unit
  fix:  use 1GiB (binary) or 1GB (decimal); run `cleaner config validate` to check
```
`code: config.badType` (`CFG-021`, spec 24 §5) · exit `6`.

**Plugin failed (recoverable — isolate & continue):**
```
⚠ Skipped plugin "docker": the docker CLI didn't respond within 10s
  why:  the adapter shelled out to `docker system df` and timed out
  fix:  ensure Docker Desktop is running, or exclude it: --exclude plugin:docker
  (continuing with the other 11 plugins)
```
`code: plugin.adapterTimeout` · isolated → run continues → contributes to exit `3`/`7`.

**Path vanished mid-clean (recoverable — the good case):**
```
ⓘ ~/Library/Developer/…/DerivedData/X was removed by another process before we staged it
  no action needed — it's already gone; counted as skipped, not failed
```
`code: fs.pathVanished` · benign, idempotent (principle 5) · counted `skipped`, exit `3` only if it
was the sole planned item; otherwise silent success for the rest.

**Safety violation (fatal, fail closed):**
```
✖ Refused: /System/Library is a protected path and will never be modified
  why:  a plugin or rule targeted a path on the non-overridable deny-list (Article 5)
  fix:  this is a safety stop; report it — a plugin/rule is misbehaving
```
`code: safety.protectedPath` · exit `8` · logged at `critical` + audit event.

---

## 7. Retry policy

Retries are **narrow, bounded, and only for transient I/O** — never for logic, permission, safety, or
config errors.

| Failure | Retry? | Policy |
|---|---|---|
| Transient FS I/O (`EAGAIN`, `EINTR`, `EBUSY` on rename) | yes | up to **3** attempts, backoff 50→200→800 ms (jittered) |
| Adapter shell-out (docker/brew/xcrun) transient exit | conditional | 1 retry only if the adapter declares idempotent+retryable; else fail-isolate |
| Permission (`EACCES`, FDA) | no | surface remediation; never loop on a permission wall |
| `ENOSPC` (disk full during staging copy) | no | fail the item, surface, suggest `--trash`/purge older staging |
| Safety / config / usage / precondition | no | deterministic; retry would be dishonest |
| Cross-volume move → copy fallback | not a retry | it's a planned degradation (NFR-005), reported |

Retries are logged at `debug` with attempt count; an item that exhausts retries becomes `failed` in
the ledger (contributes to exit `3`). No retry ever repeats a *destructive* step that partially
succeeded — staging uses atomic `rename` + journal so a retry is safe or a no-op (NFR-032).

---

## 8. Panics & unexpected errors (bugs)

An `internal.*` error means an invariant we *thought* impossible broke — a bug, not a user condition.

- **No force-unwraps** without a `// SAFETY:` note (Article 6); a broken invariant throws
  `internal.invariant` rather than trapping where feasible.
- **Top-level guard.** The `main` entrypoint wraps the command run in a boundary that catches any
  escaped `Error`, **restores the terminal** (exit alt-screen, show cursor, cooked mode — NFR-043,
  runs even on `fatalError`/signal via the terminal-restore guard, spec 25 §9.1), flushes logs, and
  prints a crash block to stderr with exit `1`.
- **Crash report.** On an unexpected error the tool writes `~/.cleaner/logs/crash-<session>.log`
  containing: version/build, OS/arch, the command line (flags only, **no path values** unless
  `--debug`), the error `code` + cause chain, a Swift backtrace (when available), and the last N log
  lines. It prints where the report is and how to file it — but **performs no network I/O**
  (principle 10); reporting is a manual, user-initiated paste.

```
✖ cleaner hit an unexpected error and stopped safely.
  Nothing was deleted after the last successful step (staging is journaled).
  code:   internal.invariant · "accumulator underflow in ScanAccumulator"
  report: ~/.cleaner/logs/crash-6f1c9c2e.log  (no file paths included)
  please file it: https://github.com/…/issues  (attach the report; review it first)
exit: 1
```

The message is calm and reassuring about **safety** (crash-consistency guarantee, NFR-032): the
half-done disposal is either fully staged or untouched.

---

## 9. Cancellation as a non-error path

Cancellation (Ctrl-C, `q`, timeout) is a **first-class expected outcome**, not an exception (EH-5).

- Structured concurrency propagates `CancellationError` cooperatively (spec 10 §5); the engine checks
  `Task.checkCancellation()` at directory/item boundaries and stops < 200 ms (NFR-040).
- Cancellation **is not** logged as an error; it's an `info` event. Any work already done is
  journaled and reported truthfully (NFR-042): the Summary and `staging` reflect exactly what moved.
- Exit is **`5`** (`cancelled`) for `q`/timeout; a raw `SIGINT` that bypasses cooperative shutdown is
  `130` (POSIX, Article 7). Either way the terminal is restored (NFR-043) and no resource leaks
  (open FDs, temp files) remain.
- If cancellation happens with a *partial* success already banked, the report shows it, and the exit
  is `5` (the user's intent dominates), with the partial results still persisted for `report`/
  `staging`.

```
^C
Cancelling… stopped at a safe boundary.
Reclaimed so far: 9.8 GiB (staged) · 22 of 42 items · 0 failed
Undo:  cleaner undo 6f1c9c2e     Resume later:  cleaner
exit: 5 (cancelled)
```

---

## 10. Interaction with logging & audit

- Every fatal error → `error`/`critical` log record; every recoverable → `warning`/`notice`
  (spec 28 levels). Safety violations → `critical` **and** an audit event.
- The `code`, `exitCode`, cause chain, and `context` are logged verbatim; the audit NDJSON records
  any attempted/partial mutation (spec 28 schema) so "why did it stop here?" is always answerable
  (principle 8, NFR-110).
- Redaction: on `--redact-paths` export, `context.path` and message paths are hashed (NFR-062); the
  in-place local log keeps real paths (needed for recovery).

---

## Open Questions

- **OQ-27.1** Should `permission.*` on a subset of roots ever escalate past `3` to `4` (e.g. > 50 % of
  requested roots unreadable)? *Leaning: stay `3` if any root succeeded; `4` only when nothing could
  be read — matches spec 08 `analyze`.*
- **OQ-27.2** Do we expose a machine-stable `errorCode` catalog file (like rustc's index) for
  scripts/docs, versioned alongside JSON schemas? *Leaning: yes, generate from the `CleanerError`
  conformers in CI.*
- **OQ-27.3** Crash report contents: include a Swift backtrace by default (needs symbolication) or
  only under `--debug`? *Leaning: unsymbolicated backtrace always, symbolication only on request.*
- **OQ-27.4** Adapter retryability — declared per-adapter in spec 13, or a conservative global "no
  retry for shell-outs"? *Leaning: per-adapter opt-in, default no.*
- **OQ-27.5** Should `--resume` (§ 9) be a v1 commitment or ride NFR-041's SHOULD? Coordinate with
  spec 17. *Leaning: mirror spec 17 — SHOULD, may slip; the cancel/report path is MUST regardless.*

## Dependencies

- **Consumes:** 00 (Art. 6 `CleanerError`, Art. 7 exit codes, principles 1/3/8), 07 (NFR-035
  degradation, NFR-040…043 cancellation/restore, NFR-032 crash consistency, NFR-062 redaction), 08
  (exit-code + JSON envelope + stream contract), 09 (screen-level error placement), 25 (TUI/toast
  rendering, terminal restore on panic), 26 (three-part message UX & voice).
- **Feeds:** 24/28/29 (their `CFG-*`/log/telemetry errors conform here), 17/20/21 (engine error
  emission, cancellation, crash-consistency), 23 (safety `8` on protected-path/policy failure), 31
  (error-path, cancellation, and partial-aggregation tests; crash-report snapshot).
