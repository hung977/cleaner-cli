# 28 — Logging Strategy

> **Phase F · Depends on:** 00-constitution (Art. 8 layout, principle 8 observability, principle 10
> privacy, CC-6 swift-log), 07 (NFR-110…114 observability, NFR-062 redaction, NFR-113 rotation), 08
> (stdout/stderr contract, `--debug`), 10 (swift-log + audit sink, ADR-0006), 24 (log config),
> 27 (errors feed logs) · **Depended on by:** 29 (telemetry reuses redaction/consent), 31 (log &
> audit tests), 21 (staging reads/writes audit), every engine spec (emits logs).
>
> How the tool logs: swift-log usage and levels, the structured record format, the append-only
> **audit** trail of every filesystem mutation (schema, guarantees, tamper-evidence), debug/trace,
> path redaction, rotation & retention (Article 8), session correlation, `os.Logger`/signposts for
> perf, log destinations, and CI/quiet behavior. RFC-2119 keywords are normative. Logging MUST NOT
> pollute the stdout result contract (spec 08 §3) and MUST NOT perform network I/O (principle 10).

---

## 1. Goals & invariants

- **LOG-INV-1 — Reconstructable runs** (principle 8, NFR-110). Every session is fully explainable
  from its logs + audit trail: what was scanned, decided, staged/purged, skipped, and why.
- **LOG-INV-2 — The audit trail is sacred.** Every filesystem *mutation* is recorded as an
  append-only NDJSON event **before/at** the mutation, never after-the-fact reconstruction. It is the
  source of truth for rollback and "why did you touch this?".
- **LOG-INV-3 — Never on stdout.** All logs go to files and (interactively) stderr; **never** stdout,
  which belongs to the result (spec 08 §3.1, NFR-112). `--json` stdout stays a single clean document.
- **LOG-INV-4 — Local & private** (principle 10, NFR-061). Logs stay under `~/.cleaner`; no egress
  ever. Contents are never file *data* (NFR-062); paths are recorded (audit needs them) but redactable
  on export.
- **LOG-INV-5 — Bounded** (NFR-113). Logs and audit rotate by size and age; nothing grows unbounded.

---

## 2. Architecture (swift-log + sinks)

`swift-log` is the façade (CC-6/ADR-0006). A single `LoggingSystem.bootstrap` installs a
**multiplex** backend fanning each record to the enabled sinks. Metrics (`swift-metrics`) are wired
to a no-op backend unless telemetry is opted in (spec 29, NFR-114).

```
 code ── Logger("cleaner.scan") ──▶ swift-log façade
                                        │  multiplex handler
        ┌───────────────────────────────┼───────────────────────────────┐
        ▼                               ▼                               ▼
 ┌─────────────┐              ┌──────────────────┐            ┌───────────────────┐
 │ File sink   │              │ stderr sink       │            │ os.Logger sink    │
 │ cleaner.log │              │ (interactive/    │            │ (Console.app,     │
 │ NDJSON,     │              │  --debug only)   │            │  signposts, dev)  │
 │ rotated     │              │  human-ish       │            └───────────────────┘
 └─────────────┘              └──────────────────┘
        ▲ separate, dedicated path (NOT a log level):
 ┌────────────────────────────────────────────────────────────────────────────┐
 │ AUDIT sink — append-only NDJSON of every FS mutation → logs/audit/<date>.ndjson │
 │ fsync-durable, sequence-numbered, hash-chained (§6). Written by the engine,   │
 │ independent of log level; MUST NOT be suppressible by --quiet.                │
 └────────────────────────────────────────────────────────────────────────────┘
```

The audit sink is **not** a log level — it is a distinct, always-on, engine-driven event stream. A
user can raise/lower `logging.level` freely; the audit trail is unaffected (LOG-INV-2).

---

## 3. Log levels (swift-log) — what belongs where

swift-log's seven levels, with a strict rubric so levels are meaningful and greppable:

| Level | Use for | Examples |
|---|---|---|
| `trace` | ultra-fine flow, per-file decisions (huge volume) | "enter dir X", "skip by ignore-glob", per-file allocated size |
| `debug` | phase timings, decisions, adapter calls, retries | "scan phase 3.1s", "docker adapter exit 0 in 240ms", "retry rename attempt 2" |
| `info` | normal lifecycle milestones | "session started", "scan complete: 4.6M files", "staged 40 items 12.0 GiB", "cancelled at boundary" |
| `notice` | notable-but-normal | "cache invalidated (stale)", "cross-volume copy fallback used", "1 root skipped (permission)" |
| `warning` | recoverable problems (→ ledger, exit 3) | "plugin docker timed out, isolated", "config world-writable", "path vanished mid-run" |
| `error` | fatal to the command | "invalid config at :41", "no root readable — permission" |
| `critical` | safety stops & corruption | "safety: protected-path attempt /System", "staging journal checksum mismatch", crash |

Rules: **default file level = `info`** (config `logging.level`, spec 24); interactive stderr shows
`warning`+ only (chrome stays clean) unless `--debug` lowers it. `trace` is never on by default
(volume). `--debug` sets effective level to `debug` on the stderr sink (and file, if not already
lower). Every `warning`/`error`/`critical` includes a `CleanerError.code` (spec 27).

---

## 4. Structured record format

Every record is structured key/value; the **file sink** emits **NDJSON** (one JSON object per line)
for machine parsing; the **stderr sink** emits a compact human line. Both derive from the same
`Logger.Metadata`.

**Canonical fields (every record):**

| Field | Type | Meaning |
|---|---|---|
| `ts` | ISO-8601 UTC ms | timestamp |
| `level` | string | swift-log level |
| `session` | UUID | correlation id (§ 7) |
| `label` | string | logger label, `cleaner.<subsystem>` (`scan`,`clean`,`stage`,`plugin.docker`,`config`,`tui`) |
| `msg` | string | short message (spec 26 voice; no PII beyond paths) |
| `code` | string? | `CleanerError.code` when applicable (spec 27) |
| `phase` | string? | `scan`/`classify`/`preview`/`dispose`/`purge`/`restore` |
| `meta` | object | subsystem key/values (counts, durations, path, size…) |

**NDJSON file line:**
```json
{"ts":"2026-07-06T12:00:03.412Z","level":"info","session":"6f1c9c2e-…","label":"cleaner.scan",
 "phase":"scan","msg":"scan complete","meta":{"files":4600021,"dirs":812004,"durationMs":68120,
 "throughputPerMin":405882,"rootsSkipped":1}}
```

**stderr human line (interactive / `--debug`):**
```
12:00:03.412  INFO  scan   scan complete  files=4,600,021 dur=68.1s 405k/min rootsSkipped=1
```

Field names are ASCII and stable (a machine surface, never localized). Numbers are numbers (not
formatted strings) in NDJSON; the human sink formats locale-aware.

---

## 5. Debug & trace (`--debug`)

- `--debug` (spec 08) lowers the **stderr** sink to `debug` and emits per-phase timings, per-plugin
  counts, adapter command lines (argument vectors, **not** shell strings — spec 36), retry attempts,
  and cache decisions — all to **stderr**, never stdout (NFR-112, LOG-INV-3). `--json` stdout stays
  pristine.
- `logging.level: trace` (config) or `CLEANER_LOG_LEVEL=trace` enables per-file trace to the **file**
  sink (too voluminous for stderr; gated behind an explicit opt-in).
- Debug records carry rich `meta` (e.g. `{"adapter":"docker","argv":["/usr/local/bin/docker","system",
  "df","--format","{{json .}}"],"exitCode":0,"durationMs":240}`) — argv is logged for auditability;
  it is command metadata, not file contents.

---

## 6. The AUDIT trail (append-only NDJSON of every mutation)

The audit trail is the observability keystone (principle 8) and the substrate rollback (spec 21)
depends on. **Every** filesystem mutation the tool performs emits exactly one audit event.

**Location:** `~/.cleaner/logs/audit/<YYYY-MM-DD>.ndjson` (Article 8). One file per day; rotated by
age (`logging.audit.retentionDays`, default 90d — longer than app logs).

**What triggers an event:** `stage` (move to staging), `purge` (permanent delete), `restore`
(un-stage), `trash` (route to macOS Trash), and any `mkdir`/`journal` the engine performs on the
tool's own tree. Read-only scans emit **no** audit events (they mutate nothing).

**Event schema (one NDJSON object per mutation):**

| Field | Type | Meaning |
|---|---|---|
| `seq` | int | monotonic per-file sequence number (gap = tamper/loss signal) |
| `ts` | ISO-8601 UTC ms | when the mutation committed |
| `session` | UUID | owning session (§ 7) |
| `action` | enum | `stage`\|`purge`\|`restore`\|`trash`\|`mkdir`\|`journal` |
| `itemId` | string | `<plugin>:<n>` finding/item id (spec 08 §9.3) |
| `plugin` | string | originating plugin id |
| `srcPath` | string | canonical original path (absolute) |
| `dstPath` | string? | staging/trash destination (for `stage`/`trash`/`restore`) |
| `allocatedBytes` | int | on-disk allocation moved/freed (CC-10) |
| `risk` | enum | `safe`\|`medium`\|`dangerous` at decision time |
| `recoverability` | enum | `instant`\|`manual`\|`hard`\|`none` |
| `disposition` | enum | resolved disposition |
| `evidenceRef` | string? | pointer to the evidence recorded in the report (spec 09) |
| `outcome` | enum | `committed`\|`failed`\|`skipped` |
| `errCode` | string? | `CleanerError.code` if not committed (spec 27) |
| `prevHash` | hex | SHA-256 of the previous event's canonical bytes (hash chain, § 6.1) |
| `hash` | hex | SHA-256 of this event's canonical bytes incl. `prevHash` |

**Example audit line:**
```json
{"seq":41,"ts":"2026-07-06T12:00:07.880Z","session":"6f1c9c2e-…","action":"stage",
 "itemId":"derived-data:0","plugin":"derived-data",
 "srcPath":"/Users/me/Library/Developer/Xcode/DerivedData/App-abcdef",
 "dstPath":"/Users/me/.cleaner/staging/6f1c9c2e/derived-data-0",
 "allocatedBytes":12988882944,"risk":"safe","recoverability":"manual","disposition":"stage",
 "evidenceRef":"reports/6f1c9c2e.json#/items/0","outcome":"committed",
 "prevHash":"9a3f…","hash":"be21…"}
```

### 6.1 Guarantees & tamper-evidence

- **Append-only & durable.** The audit file is opened `O_APPEND`; each event is written then `fsync`'d
  (or `F_FULLFSYNC` for the strongest ordering) **before** the corresponding destructive commit is
  acknowledged, so a crash leaves the trail ahead-of or equal-to reality — never behind it (pairs with
  the staging journal for crash consistency, NFR-032/042).
- **Monotonic `seq`** per file; a gap indicates truncation/loss.
- **Hash chain** (`prevHash`→`hash`, § 6): each event commits to all prior events, making silent
  mid-file edits detectable. `cleaner doctor` verifies the chain (spec 08 §4.5); a mismatch is a
  `critical` log + a doctor 🔴.
- **Not a security boundary against root.** The chain is *tamper-evident*, not tamper-proof (a user
  with write access to their own `~/.cleaner` can rewrite the whole file). v1 scope: detect
  accidental corruption and prove internal consistency; cryptographic signing/notarized append is a
  v2 consideration (threat model, spec 36).
- **Never suppressible.** `--quiet`/`--ci` reduce *log* chatter but MUST NOT disable the audit sink
  (LOG-INV-2). `--dry-run` writes **no** audit events (nothing mutates) but logs an `info` that it was
  a dry run.

---

## 7. Correlation via session UUID

- Each invocation gets one **session UUID** at startup (Article 3 "Session"), stamped on every log
  record (`session`), every audit event, the report filename (`reports/<uuid>.json`), and the staging
  dir (`staging/<uuid>/`). This ties logs ↔ audit ↔ report ↔ staged bytes for a run.
- Sub-operations carry a `phase` and, where useful, a `spanId` (§ 8) for signpost correlation.
- `cleaner undo --list` surfaces the UUID so a user can `grep
  "$uuid" ~/.cleaner/logs/**` and get the whole story.

---

## 8. Performance instrumentation (`os.Logger` / signposts)

- An **`os.Logger`/`os_signpost` sink** (behind the multiplex) emits signpost intervals for hot
  phases (scan, hash, dispose) so Instruments and Console.app can profile without perturbing the file
  logs (ADR-0006). Signposts are compiled in but effectively free when not being recorded.
- Each timed phase logs a `debug` record with `durationMs` **and** brackets an `os_signpost` interval
  named `cleaner.<phase>` with the `session`/`spanId`. This satisfies the perf-observability half of
  principle 8 without adding stderr noise.
- No signpost or metric performs I/O beyond the OS tracing buffer; none egresses (principle 10).

---

## 9. Destinations & routing summary

| Sink | Destination | Default enabled | Level | Notes |
|---|---|---|---|---|
| File | `~/.cleaner/logs/cleaner.log` (NDJSON) | yes | `logging.level` (info) | rotated (§ 10) |
| Audit | `~/.cleaner/logs/audit/<date>.ndjson` | **always** | n/a (event stream) | durable, hash-chained |
| stderr | terminal | interactive only | `warning`+ (`debug` w/ `--debug`) | never stdout (LOG-INV-3) |
| os.Logger/signpost | unified logging | yes (dev value) | mirrors file | Console.app/Instruments |
| Crash | `~/.cleaner/logs/crash-<uuid>.log` | on panic | — | spec 27 §8 |

`CLEANER_HOME` relocates all of the above (Article 8). Paths are created `0700`/files `0600`.

---

## 10. Rotation & retention (Article 8, NFR-113)

- **`cleaner.log`:** size-based rotation at **10 MiB** → `cleaner.log.1..N`, keep **5** rolls; plus
  age pruning at `logging.retentionDays` (default 14d). Whichever hits first.
- **Audit NDJSON:** one file per day; pruned at `logging.audit.retentionDays` (default 90d). Audit is
  kept **longer** than app logs because it's the mutation record of truth. Rotation of audit never
  deletes an entry for a **still-staged** session — retention is intersected with live staging so you
  can always explain currently-recoverable items (coordinate with spec 21 retention).
- **Crash logs:** kept until the referenced session's retention lapses, capped at 20 files.
- Rotation runs at session end (cheap, off the hot path) and is itself audited (`action: journal`).
  A full-disk condition (`ENOSPC`) during logging degrades to stderr `warning` and never blocks the
  cleaning work (logs are best-effort; the audit fsync is the one that gates a destructive commit).

---

## 11. Redaction of sensitive paths (NFR-062)

- **In-place local logs keep real paths** — they are needed to explain and to drive rollback, and
  they never leave the machine (LOG-INV-4).
- **Export redaction:** when a report/log is exported (`report --output`, sharing a crash log) with
  `--redact-paths` (or `logging.redactPaths: true`, spec 24), user-identifying path components are
  replaced with a stable salted hash: `~/Projects/Secret/file` → `~/Projects/⟨h:3af9⟩/⟨h:1b02⟩`.
  Well-known non-identifying prefixes (`~/Library/Caches`, `/Applications`) are preserved for
  usefulness; the salt is per-machine and never exported.
- **Never logged, ever:** file *contents*, environment secrets, keychain material, `.env`/`*.key`/
  `*.pem` byte content (paths to them may appear but are deny-listed from action, Article 5).
- Redaction is applied by the export path, not the write path, so recovery always has true paths.

---

## 12. CI / quiet behavior

- **`--ci`:** file + audit sinks unchanged; stderr sink emits **milestone** `info`/`warning` lines
  only (no progress spam), suitable for CI logs; still never stdout. `doctor`/`audit` health mapped to
  exit codes (Article 7).
- **`--quiet`:** stderr sink → `error`+ only; file + **audit** unchanged (LOG-INV-2). Progress
  suppressed (spec 26 §7.1).
- **`--json`:** stderr logging allowed at `warning`+ (goes to stderr, not the stdout document);
  `--debug` diagnostics still stderr-only (NFR-112). The result document (stdout) is untouched by
  logging.
- **`--debug`** composes with all of the above: it only lowers the stderr sink's threshold; it never
  moves logs onto stdout.

Example CI stderr:
```
INFO  session   started 6f1c9c2e cmd=clean profile=conservative ci=true
INFO  scan      complete files=204,551 dur=8.1s
WARN  plugin    docker skipped: adapter timeout (isolated)  code=plugin.adapterTimeout
INFO  clean     staged 33 items 8.9 GiB · skipped 1 · failed 0
INFO  session   done exit=3 reason=partial dur=12.4s
```

---

## Open Questions

- **OQ-28.1** Audit hash chain: SHA-256 per event is cheap, but do we also periodically write a
  signed checkpoint (v2 tamper-*proofing*), or leave signing out of v1 entirely? *Leaning: chain only
  in v1; note v2 signing in spec 36.*
- **OQ-28.2** `F_FULLFSYNC` on every audit event may hurt dispose throughput (NFR-005). Batch-fsync
  per N items with a barrier before each destructive commit, or fsync-per-event? *Leaning: fsync the
  audit event before its own commit; batch only within a single atomic group.*
- **OQ-28.3** Retention intersection with live staging (§ 10) — where does the authority live, here or
  spec 21? *Leaning: spec 21 owns staging retention; this spec defers audit pruning to it for
  still-staged sessions.*
- **OQ-28.4** Should `cleaner.log` be NDJSON (machine-first) or a human format by default, with NDJSON
  behind a flag? *Leaning: NDJSON on disk (greppable+parseable), human only on the stderr sink.*
- **OQ-28.5** Redaction salt storage — a file under `~/.cleaner` (portable but discoverable) vs
  Keychain (safer, adds AppKit/Security dep on a cold path)? *Leaning: file `0600` in v1; Keychain
  optional in 1.x.*

## Dependencies

- **Consumes:** 00 (Art. 8 layout, principle 8/10, CC-6 swift-log), 07 (NFR-110…114 observability,
  NFR-062 redaction, NFR-032/042 crash consistency the audit fsync supports), 08 (stdout/stderr
  contract, `--debug`, `doctor` audit check), 10 (swift-log + audit sink + signposts, ADR-0006), 24
  (`logging.*` config keys), 27 (errors provide `code`/`context` logged here).
- **Feeds:** 21 (rollback consumes the audit trail; staging retention intersects audit pruning), 29
  (telemetry reuses redaction + no-egress guarantees; metrics no-op backend), 31 (audit-completeness,
  rotation, redaction, hash-chain, and stream-separation tests), 36 (threat model on audit
  tamper-evidence).
