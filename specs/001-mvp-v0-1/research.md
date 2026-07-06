# Phase 0 Research: MVP v0.1

**Feature**: `001-mvp-v0-1` | **Date**: 2026-07-06

Resolves the key unknowns needed to implement the v0.1 safety spine. Each topic records a
**Decision**, its **Rationale**, and the **Alternatives considered**. Decisions reuse the
Constitution's fixed cross-cutting choices (CC-#) and the engine specs (16, 17, 20, 21, 22) — no
new exit codes, risk levels, or type names are introduced.

---

## R1 — Directory enumeration API

**Decision**: Use `FileManager.enumerator(at:includingPropertiesForKeys:options:)` as the v0.1
enumeration path, wrapped behind the `FilesystemService.enumerate(root:options:) ->
AsyncThrowingStream<FSNode, Error>` protocol. `getattrlistbulk(2)` (`BulkEnumerator`) is
implemented behind the same protocol as a **performance follow-up** and can be swapped in without
touching the engine or plugins.

**Rationale**: v0.1 fixtures are small; correctness and simplicity dominate. `FileManager`'s
enumerator with a pre-fetched resource-key set (`.isDirectoryKey`, `.fileSizeKey`,
`.totalFileAllocatedSizeKey`, `.isSymbolicLinkKey`, `.contentModificationDateKey`,
`.volumeIdentifierKey`, `.isUbiquitousItemKey`) is well-documented, batches metadata, respects
`.skipsHiddenFiles`/`.skipsSubdirectoryDescendants`, and never triggers iCloud downloads when we
avoid reading contents. Because both implementations sit behind one `Sendable` provider protocol
(spec 12/16), the perf upgrade is invisible to callers — satisfying the streaming requirement
(NFR-002/010) now and the throughput target (NFR-001) later.

**Alternatives considered**:
- *`getattrlistbulk(2)` from day one* — the eventual hot path (spec 16, ~1 syscall per batch,
  `ATTR_FILE_ALLOCSIZE` inline). Rejected for v0.1 as premature optimization: more unsafe-pointer
  code and edge cases (network volumes returning `ENOTSUP`) than the MVP needs. Kept as the
  documented follow-up behind the same protocol.
- *Raw `readdir`/`fts`* — loses Foundation's metadata batching and adds C-string handling;
  offers nothing `getattrlistbulk` won't do better.

**Follow-up**: `BulkEnumerator` + `FileManager` fallback (on `ENOTSUP`/network) is the v0.5 perf
task; the `FilesystemService` protocol is designed to accept it unchanged.

---

## R2 — Allocated-size (reclaim) measurement

**Decision**: Reclaim is measured from **on-disk allocated size** via
`URLResourceValues.totalFileAllocatedSize` (recursive, for directories/groups) and
`fileAllocatedSize` (single file), exposed as `FilesystemService.measure(_:) -> SizePair`
(`logical: Int64`, `onDisk: Int64`, `sharedExcluded: Int64`). Logical `size` (`fileSize`) is kept
only as display context. Clone/hardlink shared blocks are excluded from reclaim and recorded in
`ReclaimEstimate.sharedBytesExcluded`; sparse files contribute allocated blocks only; dataless
files contribute `0`. The **same measurement code** runs for dry-run and real-run.

**Rationale**: Constitution CC-10 / ADR-0010 and Principle 3 (truth in reporting). Logical size
lies on APFS: a clone reports full size but shares extents; a sparse file reports large logical
but few blocks. Allocated size is the honest headline. Verifying realized reclaim against
`statfs` before/after (spec 20) closes the loop (SC-002/007). Sharing detection at v0.1 breadth:
hardlinks via `st_nlink > 1` grouped by `(volumeUUID, inode)`; clones via the allocated-vs-logical
anomaly heuristic — sufficient for the three 🟢 plugins, which rarely clone.

**Alternatives considered**:
- *Logical `st_size` only* — simplest, but violates truth-in-reporting; would overstate savings on
  clones/sparse. Rejected outright (non-negotiable principle).
- *`statfs` delta only, no per-item accounting* — cheap but can't attribute reclaim per item or
  power dry-run projections; also noisy under concurrent FS activity. Used as a **cross-check**,
  not the primary per-item number.
- *`F_LOG2PHYS_EXT` full extent-overlap mapping for clones* — most precise, deferred to v0.5;
  the v0.1 heuristic + `sharedBytesExcluded` is honest (never overstates) if coarser.

---

## R3 — Atomic staging move (same-volume vs cross-volume)

**Decision**: `StagingManager.stage(_:)` moves each item into
`~/.cleaner/staging/<session-uuid>/files/<mirrored-original-path>`:
- **Same volume** → atomic `renameat`/`renameatx_np` (O(1), crash-atomic for the whole subtree).
- **Cross volume** → `clonefile` (same-vol fast path where applicable) else streamed
  `copyfile(3)` to a staging temp, **re-checksum-verify against the source**, re-apply captured
  metadata, then `unlinkat` the source only after verification, then atomic-rename temp → final.

All operations are **fd-relative** (`openat` with `O_NOFOLLOW`, operate via
`unlinkat`/`renameat`) — never re-resolving the path string (TOCTOU-safe). A
`StagingManifestEntry` is appended (and `fsync`'d) before/after the move as a journal.

**Rationale**: FR-087 mandates copy-then-remove with verify-before-remove for cross-volume;
Principle 2 (reversibility) and NFR-032 (crash consistency). Same-volume `rename` gives the
disposal-throughput target (NFR-005, ≥10K items/min, O(1)) and atomicity for free. Copy-verify-
unlink guarantees a crash before `unlinkat` leaves the source intact (never half-moved). Capturing
metadata *before* the move is what makes byte-exact restore (SC-001) possible.

**Alternatives considered**:
- *Always copy (never rename)* — uniform code but O(size) even same-volume, missing NFR-005 and
  losing subtree atomicity. Rejected.
- *`FileManager.moveItem`* — convenient but re-resolves paths (TOCTOU-unsafe) and hides the
  same-vol/cross-vol distinction we must control. Rejected for the mutation path.
- *macOS Trash as the only quarantine* — not restorable by `cleaner staging restore` and not
  session-scoped; kept as a *separate* `--trash` disposition (deferred to v0.5), not the staging
  mechanism.

---

## R4 — Audit + staging manifest NDJSON format

**Decision**: Two append-only NDJSON streams, one event per line, `fsync`'d per record.

- **Audit trail** — `~/.cleaner/logs/audit/<date>.ndjson` (FR-099). Every filesystem mutation
  appends:
  ```json
  {"schemaVersion":1,"ts":"2026-07-06T12:00:00.123Z","session":"<uuid>","event":"item.staged",
   "plugin":"dev.cleaner.xcode","path":"/Users/me/Library/Developer/Xcode/DerivedData/App-abc",
   "disposition":"stage","allocatedBytes":5368709120,"logicalBytes":5400000000,
   "stagedAs":"<manifestEntryId>","risk":"safe","result":"staged"}
  ```
  `event ∈ {item.staged, item.purged, item.restored, item.trashed, item.skipped, safety.blocked}`.

- **Staging manifest** — `~/.cleaner/staging/<session-uuid>/manifest.ndjson`, guarded by a
  single-writer `manifest.ndjson.lock` (flock). One `StagingManifestEntry` per item, plus later
  `{"event":"restored","entry":"<id>","ts":"…"}` lines; restore reduces the stream last-write-wins.
  Each entry captures the fields needed for byte-exact restore (path, `relativePath`, checksum,
  `volumeUUID`, `posixPermissions`, `ownerUID/GID`, `xattrs` (base64), `flags`, `mtime`/`atime`/
  `birthtime`, `symlinkTarget`, `hardlinkCount`) — full field list in data-model.md.

**Rationale**: NDJSON is append-only, crash-friendly (a torn last line is detectable and
discardable), human-greppable, and needs no database (Article 8). `fsync`-per-record + an
append-only journal is the crash-consistency substrate (NFR-032/042). Versioning each line with
`schemaVersion` lets the format evolve (spec 15 governance).

**Alternatives considered**:
- *SQLite index* — transactional but heavyweight for v0.1, adds a dependency and a corruption/
  migration surface; the self-describing on-disk `files/` tree + NDJSON manifest is reconstructable
  by itself. Rejected for MVP.
- *Single combined log for audit + manifest* — couples the durable rollback record to the rotating
  audit log; kept separate so retention/rotation policies differ.

---

## R5 — Plugin registration (static registry)

**Decision**: v1 plugins are **in-process, statically linked**, registered at compile time via a
`BuiltinPlugins.all: [any CleanerPlugin]` array in `CleanerEngine/PluginRegistry.swift`
(populated with `TrashPlugin()`, `DerivedDataPlugin()`, `NpmCachePlugin()`). No dynamic loading,
no `dlopen`, no IPC. Each plugin links only `CleanerPluginAPI` + `CleanerCore`; the engine
resolves them from the registry, intersects `declaredRoots` with allow-space − deny-list, and
hands each a read-only `PluginContext`.

**Rationale**: Constitution CC-8 / ADR-0008 fix static in-process plugins for v1 — no
dynamic-loading threat surface (roadmap §6 defers XPC/dylib to v2.2). A plain array is the
simplest thing that satisfies "adding a plugin doesn't modify the engine or CLI" (Principle 7 /
NFR-100): a new plugin is one file + one registry line, no engine edits. The compiler-enforced
absence of `Plugins → Engine` guarantees plugins can only *propose*.

**Alternatives considered**:
- *Runtime plugin discovery / dylib loading* — explicitly a v2.2 feature; adds sandboxing,
  signing, and a fresh ADR. Out of scope (roadmap §10).
- *Protocol-witness auto-registration via a macro/`#if`* — cleverness without benefit at three
  plugins; a literal array is clearer and trivially testable.

---

## R6 — Argument-parser command tree

**Decision**: Build the CLI with `swift-argument-parser` (CC-2) as a root `Cleaner`
`ParsableCommand` with `subcommands: [Analyze, Clean, Staging]` (and `Staging` nesting
`List`, `Restore`, plus `Purge` for retention plumbing). Global flags live in a shared
`@OptionGroup GlobalOptions` (`--json`, `--dry-run`, `-y/--yes`, `-v/--verbose`, `--debug`,
`--include`, `--exclude`, `--plugins`, `--no-color`, `--config`, `--no-tui`). Usage/parse errors
map to exit `2` automatically; each node gets `--help`. The executable is the single composition
root — the only target allowed to import everything.

**Rationale**: CC-2 / ADR-0002: first-party, declarative, testable, generates completions. Matches
the spec-08 command tree exactly for the v0.1 subset (`analyze`, `clean`, `staging list|restore`).
Keeping global flags in one `OptionGroup` gives the CLI-flag > env > config > default precedence
(spec 08 §2) in one place. ArgumentParser's `ExitCode`/`ValidationError` maps cleanly to the
Article 7 contract.

**Alternatives considered**:
- *Hand-rolled `CommandLine.arguments` parsing* — reinvents help, completions, precedence, and
  usage errors; violates CC-2. Rejected.
- *A single flat command with a `--mode` flag* — hostile UX and can't produce per-verb help/exit
  semantics. Rejected.

---

## R7 — Coarse safety scorer for v0.1

**Decision**: Ship the `SafetyScorer` with the spec-22 six-signal weighted model
(`regenerability` 0.30, absence-of-`userAuthored` 0.25, `recoverability` 0.15, `pathConfidence`
0.15, `recency` 0.10, `lockState` 0.05) but exercise it **coarsely** — the three v0.1 plugins
declare high-confidence regenerable roots, so all three land firmly 🟢 (score ≥ 85). The monotonic
downward **gates** are still enforced (`.irreversible` → cap 49, `.inUse` → cap 49, `.dataless`/
`.snapshot`/`.protectedPath` → excluded), as is the risk mapping (≥85 safe / 50–84 medium / <50
dangerous). Plugins may *lower* but never *raise* a score above the scorer ceiling (DM-2).

**Rationale**: Roadmap §3 calls for a "coarse scorer" in MVP; the *shape* (signals, gates,
mapping) must be the real one so v0.5's full breadth is not a rewrite. Enforcing gates and the
lower-only rule now proves the safety-scoring contract (SC-006) even though only 🟢 fixtures
exercise it. Trash is baseline 🟡 (FR-037) via a plugin hint, demonstrating a non-🟢 path through
the same scorer.

**Alternatives considered**:
- *Hard-coded per-plugin risk, no scorer* — quickest, but leaves the scorer contract unproven and
  makes v0.5 a retrofit (which the roadmap forbids for hard-to-retrofit safety machinery).
  Rejected.
- *Full evidence-driven production scorer* — more than three 🟢 plugins need; deferred to v0.5,
  where the breadth of plugins actually exercises every signal.

---

## Resolved / not-applicable for v0.1

- **Incremental scan cache, resume checkpoints, cancellation-resume** — designed in the specs
  (17/15) but *deferred*; v0.1 supports plain cancellation → exit `5` only.
- **Full Disk Access elevation flow** — merely *detected*; the three plugins live under `$HOME`.
- **Shell-out adapters** — none in v0.1 (native-first, threat surface deferred to v0.5).
- **Config file / profiles** — `CleanerConfig` resolves only `CLEANER_HOME` + built-in defaults;
  no YAML config surface yet.
