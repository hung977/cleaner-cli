# 15 — Data Model (on-disk & persistent)

> **Phase D · Depends on:** 00-constitution (Article 8 layout), 10-tech-stack (Codable/Yams),
> 14-domain-model (entity shapes) · **Depended on by:** 17 (scan/cache), 20 (cleanup),
> 21 (rollback), 24 (config), 28 (logging), 34 (CI/migration tests).

## 1. Purpose & scope

Defines the **persistent, on-disk data structures** the tool owns under `~/.cleaner/`
(Constitution Article 8). Where spec 14 defines the in-memory domain entities, this spec defines
how a subset of them are serialized, versioned, rotated, locked, and migrated. It covers:

1. Directory layout & ownership (§ 3)
2. `config.yml` (schema owned by spec 24 — referenced, not duplicated) (§ 4)
3. Staging manifest — NDJSON, everything needed to restore an item (§ 5)
4. Audit log — append-only NDJSON event stream (§ 6)
5. Incremental-scan cache — change detection keyed by path+inode+mtime+size (§ 7)
6. Report JSON — versioned export of `CleanReport` (§ 8)
7. Profiles — YAML (§ 9)
8. Cross-cutting: versioning/migration (§ 10), retention/rotation (§ 11), concurrency/locking
   (§ 12)

**Format principles.** Human-inspectable where users edit (YAML: config, profiles);
machine-append-friendly where the tool streams (NDJSON: staging manifest, audit, cache journal);
versioned JSON where a stable export contract matters (reports). Every format carries an explicit
version integer and every reader tolerates unknown newer fields (forward-compatible) and can
migrate older ones (§ 10).

## 2. Encoding conventions (apply to all formats)

- **Timestamps:** RFC 3339 / ISO 8601 UTC with fractional seconds, e.g.
  `2026-07-06T14:03:22.481Z`. Never local time on disk.
- **Paths:** absolute, NFC-normalized Unicode, stored as-is (not URL-encoded). A path field
  never contains a symlink component that was resolved away — canonicalization rules in spec 16.
- **Sizes:** integer bytes (`Int64`), two fields where truthful reclaim matters
  (`sizeLogical`, `sizeOnDisk`) mirroring spec 14 § 6.
- **IDs:** UUIDs as lowercased hyphenated strings; domain IDs (`FindingID`, `PluginID`) as their
  `raw` string.
- **Booleans/enums:** enums serialize to their `String` rawValue (matches spec 14 `Codable`).
- **Byte blobs (xattrs, ACLs):** base64 strings, with a `truncated` flag if elided past a cap.
- **JSON:** UTF-8, `\n`-terminated for NDJSON (one complete object per line, no pretty-printing).
- **Numbers:** never floats for bytes/counts; `Duration` serialized as integer nanoseconds or
  `{seconds, attoseconds}` per Swift `Codable` — pinned to nanoseconds `Int64` via a custom coder.

## 3. Directory layout (Constitution Article 8, expanded)

`CLEANER_HOME` defaults to `~/.cleaner` (XDG-overridable). All paths below are relative to it.

```
~/.cleaner/
├── config.yml                       # spec 24. Single user-editable config.
├── .lock                            # global advisory lock file (§ 12) — flock target
├── schema-versions.json             # map: format → current schemaVersion on this machine (§ 10)
├── profiles/
│   └── <profile-id>.yml             # one file per profile (§ 9)
├── staging/
│   └── <session-uuid>/
│       ├── manifest.ndjson          # restore records, one per staged item (§ 5)
│       ├── manifest.ndjson.lock     # per-session single-writer lock
│       └── files/                   # the quarantined payload tree (spec 21 layout)
├── logs/
│   ├── cleaner.log                  # human/structured swift-log text (rotated, spec 28)
│   └── audit/
│       └── <YYYY-MM-DD>.ndjson       # append-only audit events (§ 6), daily file
├── cache/
│   ├── scan-index.ndjson            # incremental scan cache journal (§ 7)
│   ├── scan-index.ndjson.lock
│   └── scan-index.meta.json         # cache header: version, volume UUIDs, generation
├── reports/
│   └── <session-uuid>.json          # versioned CleanReport export (§ 8)
└── policy/                          # signed automation policies (spec 23) — not defined here
```

Permissions: `~/.cleaner` is created `0700`; all files `0600` unless the OS Trash requires
otherwise. The tool refuses to run if `CLEANER_HOME` is world-writable or owned by another user
(spec 36 threat model).

## 4. Configuration — `config.yml` (schema owned by spec 24)

The full config schema, validation rules, and defaults are **spec 24**. This spec fixes only:

- **Location:** `~/.cleaner/config.yml`, YAML (Yams, CC-5).
- **Version key:** every config file MUST carry `schemaVersion: <int>` at the top level; migration
  per § 10.
- **On-disk digest:** the resolved config is hashed (SHA-256) into `Session.configSnapshot`
  (`ConfigDigest`, spec 14 § 4.15) so every report/audit records exactly which config was in force.

Illustrative skeleton (authoritative schema in spec 24):

```yaml
schemaVersion: 1
defaults:
  disposition: stage          # Disposition rawValue (spec 14 §4.5)
  includeRisk: [safe, medium] # RiskLevel rawValues
staging:
  retentionDays: 14
whitelist:                    # user additions to protected paths (Article 5)
  - ~/Projects/keep-me
targets:                      # user blacklist/target rules
  - ~/Library/Caches/com.example.app
plugins:
  dev.cleaner.xcode:
    enabled: true
    options: { keepLatestSimulators: true }
```

## 5. Staging manifest (NDJSON) — restore contract

**File:** `staging/<session-uuid>/manifest.ndjson`. One JSON object per line, appended as each
item is staged during a `clean` run. This is the **source of truth for rollback** (spec 21): it
must contain *everything* needed to restore an item byte-and-metadata identically to its original
location, without re-reading the (now-moved) original.

Each line is a `StagingManifestEntry`:

```jsonc
{
  "manifestEntryID": "b1d2…-uuid",     // matches StagedRef.manifestEntryID (spec 14 §4.14)
  "schemaVersion": 1,
  "sessionID": "…-uuid",
  "findingID": "dev.cleaner.xcode:/Users/h/Library/Developer/Xcode/DerivedData/App-abc",
  "plugin": "dev.cleaner.xcode",
  "stagedAt": "2026-07-06T14:03:22.481Z",
  "disposition": "stage",
  "original": {
    "path": "/Users/h/Library/Developer/Xcode/DerivedData/App-abc",
    "kind": "directory",                // ItemKind
    "ownerUID": 501,
    "ownerGID": 20,
    "posixPermissions": "0755",         // octal string
    "acl": "BASE64…",                   // NFSv4/POSIX ACL blob, base64; null if none
    "xattrs": [                         // preserved verbatim for restore fidelity
      { "name": "com.apple.metadata:kMDItemWhereFroms", "value": "BASE64…", "truncated": false }
    ],
    "flags": { "uchg": false, "hidden": false },  // BSD chflags to restore
    "timestamps": {
      "mtime": "2026-06-30T09:12:00Z",
      "atime": "2026-07-05T22:00:00Z",
      "birthtime": "2026-01-02T08:00:00Z"
    },
    "isSymlink": false,
    "symlinkTarget": null,              // if isSymlink, restore the link, never the resolved target
    "hardlinkCount": 1,
    "sizeLogical": 734003200,
    "sizeOnDisk": 690000000,
    "volumeUUID": "…-volume-uuid"        // must match on restore or warn (spec 21)
  },
  "staged": {
    "relativePath": "files/Library/Developer/Xcode/DerivedData/App-abc",
    "method": "rename",                 // "rename" (same-volume, fast) | "copy+unlink" (cross-volume)
    "checksum": { "algo": "sha256", "value": "…", "scope": "tree-manifest" }
  },
  "restore": {
    "collisionPolicy": "fail",          // fail | rename | overwrite — chosen at restore time, default fail
    "restored": false,                  // flipped true (via a follow-up "restored" event line) after rollback
    "restoredAt": null
  }
}
```

Notes:

- **Checksum scope.** For files: SHA-256 of contents. For directories/groups: a *tree manifest*
  hash (sorted relative-path + size + per-file hash), so integrity of the whole staged tree is
  verifiable before restore without hashing on every access. Large trees may record per-file
  checksums in a sibling `manifest-files.ndjson` referenced by `checksum.scope: "tree-manifest"`.
- **Append-only + restore records.** The manifest is never rewritten. A rollback appends a second
  line `{ "manifestEntryID": …, "event": "restored", "restoredAt": … }`; the effective state is
  the reduction of all lines for an ID (last-write-wins on `restored`). This keeps the file a
  crash-safe append log (§ 12).
- **Fidelity requirement (spec 21):** owner, group, POSIX mode, ACL, all xattrs, BSD flags, and
  the three timestamps are captured *before* the move so restore reproduces them. Symlinks are
  staged as links (never dereferenced); hardlinks record `hardlinkCount` so restore can warn if
  siblings changed.

## 6. Audit log (NDJSON) — every filesystem mutation

**File:** `logs/audit/<YYYY-MM-DD>.ndjson`, append-only, one event per line (Constitution
Principle 8; sink defined in spec 28). This is the "why did you delete this?" record. It records
*every* mutation (stage, trash, purge, restore) and safety-significant decisions
(protected-path blocks, permission denials).

`AuditEvent`:

```jsonc
{
  "schemaVersion": 1,
  "eventID": "…-uuid",
  "ts": "2026-07-06T14:03:22.481Z",
  "sessionID": "…-uuid",
  "seq": 4210,                          // monotonic per session (ordering across same-ts events)
  "actor": { "uid": 501, "tool": "cleaner", "version": "1.0.0" },
  "command": "clean",
  "type": "item.staged",               // enum below
  "plugin": "dev.cleaner.xcode",
  "findingID": "dev.cleaner.xcode:/Users/h/…/DerivedData/App-abc",
  "path": "/Users/h/…/DerivedData/App-abc",
  "disposition": "stage",
  "risk": "safe",
  "safetyScore": 92,
  "recoverability": "instant",
  "reclaim": { "sizeOnDisk": 690000000, "sizeLogical": 734003200, "sharedExcluded": 0 },
  "result": "staged",                  // ActionResult (spec 14 §4.14)
  "stagedRef": { "manifestEntryID": "b1d2…", "stagedPath": "…/files/…/App-abc" },
  "confirmed": "preselected",
  "error": null
}
```

Event `type` vocabulary (extensible; unknown types tolerated by readers):

| type | meaning |
|---|---|
| `session.start` / `session.end` | session boundary; `session.end` carries exit code. |
| `scan.finding` | a finding produced (path, risk, score) — optional, config-gated (verbose audit). |
| `item.staged` / `item.trashed` / `item.purged` | a mutation succeeded. |
| `item.restored` | rollback restored an item. |
| `item.failed` | a mutation failed (`error` populated). |
| `safety.blocked` | a protected-path / invariant abort (exit code 8). |
| `permission.denied` | needed FDA/admin not granted (exit code 4). |
| `policy.applied` | an automation policy authorized actions (spec 23). |

The audit stream is **the** immutable trail; the report (§ 8) is a per-session summary derived
from it. Audit lines are written *before* the irreversible part of an action where possible
(write-intent then confirm), and always after, so a crash mid-op is reconstructable.

## 7. Incremental-scan cache — change detection

**Files:** `cache/scan-index.ndjson` (journal) + `cache/scan-index.meta.json` (header). Purpose:
make re-scans fast and idempotent (Principles 5, 9) by skipping subtrees that provably haven't
changed since the last scan. The cache is a **performance hint only** — it MUST NEVER cause the
tool to act on stale data; on any doubt the entry is treated as a miss and the path re-examined.

### 7.1 Change key

A path is "unchanged" iff its identity tuple matches the cached tuple exactly:

```
key   = canonicalPath
stamp = (volumeUUID, inode, mtime_ns, size, allocatedSize, mode, ownerUID, generationCount?)
```

- **inode + volumeUUID** detects replacement (a new file at the same path has a new inode).
- **mtime_ns** detects content/metadata change (nanosecond precision from `getattrlistbulk`,
  spec 16).
- **size + allocatedSize** catches truncation/growth and clone/sparse changes.
- **mode + ownerUID** catches permission/ownership changes that affect safety.
- `generationCount` (APFS `st_gen`, when available) hardens against inode reuse. Optional.

For a **directory** finding, the cache also stores a `childrenDigest` (hash of the sorted list of
immediate child `(name, inode, mtime_ns, size)` tuples) so adding/removing a child invalidates the
directory entry without a full recursive re-walk.

### 7.2 Journal entry (`ScanCacheEntry`)

```jsonc
{
  "schemaVersion": 1,
  "path": "/Users/h/Library/Developer/Xcode/DerivedData/App-abc",
  "volumeUUID": "…",
  "inode": 8412345,
  "mtimeNs": 1751810000000000000,
  "size": 734003200,
  "allocatedSize": 690000000,
  "mode": "0755",
  "ownerUID": 501,
  "gen": 41,                            // st_gen, optional
  "kind": "directory",
  "childrenDigest": "sha256:…",         // directories only
  "lastScannedAt": "2026-07-06T14:00:00Z",
  "producedFindingID": "dev.cleaner.xcode:/Users/h/…/App-abc",  // if this path yielded a finding
  "sizeOnDiskCorrected": 690000000      // cached truthful reclaim (spec 14 §6)
}
```

### 7.3 Header (`scan-index.meta.json`)

```jsonc
{
  "schemaVersion": 1,
  "generation": 37,                     // bumped each full scan; entries tagged w/ generation for GC
  "toolVersion": "1.0.0",
  "volumes": [ { "uuid": "…", "fsType": "apfs", "isSSD": true } ],
  "createdAt": "2026-05-01T…",
  "compactedAt": "2026-07-01T…"
}
```

### 7.4 Semantics

- The journal is append-only during a scan (new/updated stamps appended). Compaction (§ 11)
  rewrites it into a deduplicated snapshot keyed by path, keeping the latest stamp per path.
- **Invalidation triggers a full re-examination of the subtree** (never a silent skip):
  volumeUUID mismatch, inode mismatch, any stamp field differs, `childrenDigest` differs, header
  `toolVersion` major changed, or the entry's `schemaVersion` is unmigratable. Volume unmount/
  remount or a changed volume UUID invalidates the whole volume's entries.
- A cache **miss or corruption never blocks a scan** — it degrades to a full walk. The cache file
  may be deleted at any time with no correctness impact (only speed).

## 8. Report JSON — versioned export of `CleanReport`

**File:** `reports/<session-uuid>.json`, pretty-printed JSON (single object; unlike the streaming
NDJSON logs, a report is a whole document read by humans and tools). It is the machine-readable
contract external tools consume, so it is **strictly versioned** (`schemaVersion`) and additive-
only within a major version.

```jsonc
{
  "schemaVersion": 1,                   // == CleanReport.schemaVersion (spec 14 §4.14)
  "kind": "cleaner.report",
  "session": {
    "id": "…-uuid",
    "command": "clean",
    "toolVersion": "1.0.0",
    "osVersion": "macOS 15.5",
    "profile": "developer-daily",
    "configDigest": "sha256:…",
    "startedAt": "2026-07-06T14:00:00Z",
    "finishedAt": "2026-07-06T14:02:11Z",
    "exitCode": 0
  },
  "projectedReclaim": { "sizeOnDisk": 3221225472, "sizeLogical": 3400000000, "sharedExcluded": 120000000, "confidence": "estimated" },
  "realizedReclaim":  { "sizeOnDiskFreed": 3200100000, "sizeLogicalRemoved": 3390000000 },
  "reclaimDelta":     { "sizeOnDisk": -21125472, "note": "actual < projected by 0.7% (clone overlap)" },
  "byCategory": [
    { "category": "developer-cache", "findingCount": 12, "sizeOnDiskFreed": 2900000000 }
  ],
  "byRisk": { "safe": 10, "medium": 2, "dangerous": 0 },
  "outcomes": [
    {
      "action": "…-uuid",
      "findingID": "dev.cleaner.xcode:/Users/h/…/App-abc",
      "disposition": "stage",
      "result": "staged",
      "reclaimed": { "sizeOnDiskFreed": 690000000, "sizeLogicalRemoved": 734003200 },
      "stagedRef": { "manifestEntryID": "b1d2…", "stagedPath": "…/files/…/App-abc" },
      "error": null
    }
  ],
  "skipped": [ { "path": "/private/var/…", "reason": "permissionDenied" } ],
  "staging": { "sessionPath": "~/.cleaner/staging/…-uuid", "retentionExpiresAt": "2026-07-20T…" }
}
```

Compatibility contract: within a major `schemaVersion`, only *additive* changes (new optional
fields). A breaking change increments `schemaVersion` and ships a documented migration note.
Consumers MUST ignore unknown fields.

## 9. Profiles (YAML)

**File:** `profiles/<profile-id>.yml`. One file per `Profile` (spec 14 § 4.16). YAML for
hand-editability (same rationale as config, CC-5).

```yaml
schemaVersion: 1
id: developer-daily
displayName: "Developer — daily"
enabledPlugins:
  - dev.cleaner.xcode
  - dev.cleaner.npm
  - dev.cleaner.docker
includeRisk: [safe, medium]           # RiskLevel rawValues
defaultDisposition: stage             # Disposition rawValue
pluginOptions:
  dev.cleaner.xcode:
    keepLatestSimulators: true
    keepDerivedDataDays: 7
extraTargets:
  - ~/Library/Caches/com.example.tool
extraProtected:
  - ~/Projects/thesis
createdAt: 2026-05-01T09:00:00Z
updatedAt: 2026-07-01T11:30:00Z
```

`pluginOptions` values map to `PluginOptionMap`/`OptionValue` (spec 14 § 4.16); each plugin
validates its own bag and rejects unknown keys with exit code 6 (`config`) or 7 (`plugin`).

## 10. Versioning & migration

Every on-disk format carries an integer `schemaVersion`. `schema-versions.json` records the
current version per format on this machine, so the tool can detect a downgrade (older binary on
newer data) and refuse safely rather than corrupt.

| Format | Version field | Migration strategy |
|---|---|---|
| `config.yml` | top-level `schemaVersion` | On read, if older: run ordered migrators → write back a backup `config.yml.bak-<v>` then the upgraded file. If newer than tool supports: refuse (exit 6). Owned by spec 24. |
| Staging manifest | per-line `schemaVersion` | Never rewritten. Reader upgrades each line in memory via migrators. Old sessions stay readable for rollback for their retention window. |
| Audit NDJSON | per-line `schemaVersion` | Append-only; never migrated in place. Readers upgrade per line. Old daily files remain as-is. |
| Scan cache | header + per-line `schemaVersion` | Not migrated — on version mismatch the cache is **discarded** (safe; it's a hint). Header `toolVersion` major bump = full invalidation. |
| Report JSON | top-level `schemaVersion` | Additive within major; new major documented. Old reports never rewritten. |
| Profiles | per-file `schemaVersion` | Migrated on read, backup-then-write like config. |

Migrator contract: migrators are pure `(olderJSON) -> newerJSON` functions registered in an
ordered chain `v1→v2→v3…`; reading applies the chain from the file's version to the tool's
current version. A **downgrade** (file version > tool max) is a hard error for
config/profiles/reports (exit 6) and a silent discard for the cache. Migration paths are covered
by golden-file tests in CI (spec 34).

## 11. Retention & rotation

| Data | Default retention | Rotation / GC |
|---|---|---|
| **Staging sessions** | `staging.retentionDays` (default 14) | A background sweep (run at CLI start or via `cleaner staging gc`) purges sessions past retention *after* confirming no pending rollback; also enforce a max total staging size (default: min(user-set, 20% of free space)) evicting oldest-first. Purge writes an audit `item.purged` event. |
| **Audit logs** | Keep ≥ 90 days (config `audit.retentionDays`) | Daily file rollover by date. Files older than retention are compressed (`.ndjson.zst`) then deleted past a hard cap (default 365 days). Never deleted while referenced by an un-expired staging session. |
| **`cleaner.log`** | Size-based | Rotate at 10 MB, keep 5 generations (`cleaner.log.1`…), gzip old ones (spec 28). |
| **Scan cache** | Generation-based | Compacted when journal > N entries or > M MB (dedupe to latest stamp per path); entries whose paths no longer exist are dropped on compaction. Fully rebuildable, so aggressive GC is safe. |
| **Reports** | Keep last 100 or `reports.retentionDays` | Oldest-first eviction; never auto-deleted within 24 h of creation. |

All retention values are config-overridable (spec 24). GC is itself audited.

## 12. Concurrency & locking (single-writer)

The tool assumes multiple `cleaner` processes may exist (a background `scan`, an interactive
`clean`). Correctness requires **single-writer** discipline on shared files.

- **Global lock (`~/.cleaner/.lock`).** An advisory `flock(LOCK_EX)` acquired for operations that
  mutate shared state broadly (config migration, staging GC, cache compaction). Held briefly;
  `LOCK_NB` with a friendly "another cleaner is running" message (exit 1) rather than blocking
  indefinitely.
- **Per-session staging manifest.** Only the owning session writes its
  `manifest.ndjson`; it holds `manifest.ndjson.lock` (`flock`) for the duration of the `clean`.
  Rollback of that session also takes the same lock. Append-only + `O_APPEND` writes are atomic
  for lines under `PIPE_BUF`; larger lines are written via a temp file + atomic rename of a
  segment, or guarded by the lock.
- **Scan cache.** `scan-index.ndjson.lock` guards *compaction* (rewrite). Concurrent scans append
  under `O_APPEND`; the reader tolerates a partially written trailing line (ignored until the
  writer completes it). Compaction is exclusive.
- **Audit log.** Append-only with `O_APPEND`; each line ≤ `PIPE_BUF` where feasible so appends are
  atomic across processes. The audit sink (spec 28) serializes writes within a process via an
  `actor`; across processes `O_APPEND` ordering plus per-session `seq` gives a reconstructable
  order.
- **Atomicity for whole-file formats** (config, profiles, report, cache header, schema-versions):
  write to `*.tmp` then `rename(2)` (atomic on APFS) — never partial-write in place. A crash
  leaves either the old file or the new, never a torn one.
- **fsync policy:** manifest and audit appends `fsync` after each record for crash-durability of
  the restore/audit trail (safety-critical); the scan cache does *not* fsync per-write (it is a
  rebuildable hint) and fsyncs only on compaction.
- **Stale lock recovery:** locks are `flock`-based (auto-released on process death), so no manual
  stale-lock cleanup is needed; a `.lock` file lingering with no holder is harmless.

## Open Questions

- **OQ-15.1** Should the staging manifest embed per-file checksums inline for small trees and
  spill to `manifest-files.ndjson` only past a threshold, or always spill? *Leaning: inline under
  ~100 files, spill beyond.*
- **OQ-15.2** Is SHA-256 for staged-tree integrity worth the I/O on multi-GB caches, or should we
  use a faster non-cryptographic hash (xxHash, already a dep for dedupe) since this is integrity-
  not-security? *Leaning: xxHash for tree-manifest integrity, SHA-256 reserved for dedupe/security.*
- **OQ-15.3** Do we need a global monotonic session sequence across processes (for a merged audit
  view), or is per-session `seq` + timestamp sufficient? *Leaning: per-session sufficient for v1.*
- **OQ-15.4** Scan cache as NDJSON journal vs a single embedded key-value store (e.g. a memory-
  mapped file). *Leaning: NDJSON for v1 (inspectable, no dep); revisit if compaction cost bites.*
- **OQ-15.5** Should audit logs be optionally signed/append-only-enforced (chained hashes) to
  detect tampering? *Deferred to spec 36 (threat model); default off in v1.*
- **OQ-15.6** Retention defaults (14 d staging, 90 d audit) — confirm against spec 07 NFRs and
  disk-footprint budget.

## Dependencies

**Consumes:** 00-constitution (Article 8 layout, Principle 8 observability, Principle 2
reversibility), 10-tech-stack (Codable, Yams, NDJSON), 14-domain-model (entity shapes serialized
here).

**Feeds:** 17-scan-engine (scan cache read/write, § 7), 20-cleanup-engine (writes manifest &
audit, § 5/6), 21-rollback-design (reads manifest to restore, § 5), 24-config (owns config.yml
schema referenced in § 4), 28-logging (owns audit sink implementing § 6), 34-cicd (golden-file
migration tests, § 10), 36-threat-model (permissions, tamper-evidence OQ-15.5).
