# 21 — Rollback Design

> **Phase D · Depends on:** 00-constitution (Principle 2 reversibility-by-default, Principle 3
> truth, Art. 3 glossary Staging/Purge/Rollback, Art. 5 protected paths, Art. 7 exit codes,
> Art. 8 layout, CC-7 stage-then-purge), 07-nfr (NFR-032 crash consistency, NFR-042 partial
> journal), 14-domain-model (`StagedRef`, `Disposition`, `CleanReport`, `ActionOutcome`),
> 15-data-model (§3 layout, §5 staging manifest, §6 audit, §11 retention, §12 locking),
> 16-filesystem-strategy (§6 symlink/hardlink, §9 TOCTOU, §11 disposition), 20-cleanup-engine
> (writes the staging tree this restores) · **Depended on by:** 22 (safety guarantees),
> 25 (`cleaner undo` UX), 28 (audit), 31 (crash-consistency tests).

## 1. Purpose & scope

**Reversibility by default** (Principle 2) is why the default disposition is `stage`, not delete
(CC-7). This spec defines the **staging/quarantine + restore system**: how staged items are laid
out and described so they can be restored *faithfully* (permissions, ownership, xattrs, ACLs, BSD
flags, timestamps, symlink targets, hardlink groups), the restore algorithm (including conflict,
cross-volume, and integrity handling), the `cleaner undo` / `cleaner undo --list` and retention-purge behavior,
retention/auto-purge policy, permanent-purge safeguards, macOS Trash as an alternative recoverable
disposition and its trade-offs, and an **honest declaration of what is NOT recoverable** (Principle
3), plus crash-consistency of staging.

Non-goals: deciding what to clean (18/19), the mechanics of the *stage* move itself (spec 16 §11 /
spec 20 §6 — this spec consumes what they produce), the on-disk manifest *schema* (spec 15 §5 owns
it; this spec defines its *use* for restore).

## 2. Staging directory structure (session-scoped)

Per Constitution Art. 8 / spec 15 §3, staging is **session-scoped** so each `clean` run is an
independent, atomically-restorable unit:

```
~/.cleaner/staging/
└── <session-uuid>/
    ├── manifest.ndjson          # spec 15 §5 — one StagingManifestEntry per staged item + restore events
    ├── manifest.ndjson.lock     # per-session single-writer flock (spec 15 §12)
    ├── manifest-files.ndjson     # per-file checksums for large trees (spec 15 §5, OQ-15.1)
    └── files/                    # the quarantined payload, MIRRORING the original absolute path
        └── Users/h/Library/Developer/Xcode/DerivedData/App-abc/…
```

**Payload layout = mirrored original path.** A staged item at `/Users/h/Library/.../App-abc` lives
at `files/Users/h/Library/.../App-abc`. This makes restore a mechanical "prepend the staged root,
strip it on restore" and makes the staging tree self-describing when inspected by hand (Principle
3/8). The `StagingManifestEntry.staged.relativePath` records this path (spec 15 §5).

**Same-volume invariant.** The staging root for a session is chosen on the **same volume** as the
items where possible (spec 20 OQ-20.3) so staging is an atomic `rename` (spec 16 §11) — no data
copy, instant, and crash-atomic (NFR-032). When an item lives on a different volume than
`~/.cleaner`, a per-volume staging root (`<volume-mount>/.cleaner-staging/<session>/`) is used, or
the cross-volume copy path applies (spec 20 §6.2).

## 3. Restore-fidelity metadata (what must be captured)

To restore an item *byte-and-metadata identically* it is not enough to move bytes back — the
original's full metadata must be captured **before** the stage move (the original is gone
afterward). Spec 15 §5 defines the manifest fields; this spec enumerates *why each is required for
faithful restore* and how it is re-applied:

| Captured (manifest `original.*`) | Source (spec 16) | Restore action | If unrecoverable |
|---|---|---|---|
| **POSIX mode** (`posixPermissions`) | `st_mode` | `fchmod` after restore | warn; default umask |
| **Owner / group** (`ownerUID`/`ownerGID`) | `st_uid`/`st_gid` | `fchown` (needs privilege if not owner) | warn; keep restorer's uid (§8 limits) |
| **ACLs** (`acl`, base64) | `acl(3)`/`getattrlist` | re-apply NFSv4/POSIX ACL | warn; POSIX mode only |
| **xattrs** (all, base64) | `listxattr`/`getxattr` (spec 16 §5) | `setxattr` each, incl. quarantine/whereFroms/tags | warn per elided/truncated xattr |
| **BSD flags** (`flags`: uchg/hidden/…) | `st_flags` (spec 16 §2) | `chflags` after content restore | warn |
| **Timestamps** (mtime/atime/birthtime) | `getattrlist` (spec 16 §2) | `setattrlist`/`utimensat`; birthtime via `setattrlist` | mtime/atime best-effort; birthtime may not be settable (§10) |
| **Symlink target** (`symlinkTarget`) | `readlink` (`XATTR_NOFOLLOW`) | recreate the *link* (never deref, spec 16 §6) | — |
| **Hardlink group** (`hardlinkCount`) | `st_nlink` | see §5.3 | warn if siblings changed |
| **Content checksum** (`staged.checksum`) | xxHash tree / sha256 (spec 15 §5) | verify before restore | refuse silent restore (§6) |
| **Volume UUID** (`original.volumeUUID`) | DiskArbitration (spec 16 §7) | match on restore or warn | warn on volume change |

Capture order (spec 20 §6.1): metadata + checksum are read **before** the atomic move, written to
the manifest, and `fsync`'d (spec 15 §12) — so even if the process dies immediately after the
move, the manifest fully describes how to put the item back.

## 4. Rollback flow diagram

```
 cleaner undo <session|entry> [--to <path>] [--collision fail|rename|overwrite]
        │
        ▼
 ① acquire manifest.ndjson.lock (single-writer, spec 15 §12)
        │
 ② reduce manifest lines → effective state per entry (last-write-wins on "restored", spec 15 §5)
        │  skip entries already restored=true
        ▼
 ③ FOR each entry to restore (parents BEFORE children — inverse of disposal order §7):
        │
        ├─ a. VERIFY integrity: re-checksum staged payload == manifest checksum
        │        mismatch → refuse this entry, report corruption (Principle 3) → exit 3
        │
        ├─ b. RESOLVE target = original.path (or --to remap); canonicalize (spec 16 §9)
        │        re-guard: target must be under an allowed root, not protected (Art. 5)
        │
        ├─ c. COLLISION check: does target already exist?
        │        fail(default) → skip+report │ rename → target.restored-<ts> │ overwrite → stage-aside then replace
        │
        ├─ d. MOVE BACK: same-volume → renameat (atomic) │ cross-volume → copy+verify+unlink (§8)
        │
        ├─ e. RE-APPLY metadata (§3): owner→mode→ACL→xattrs→flags→timestamps  (order matters, §5.2)
        │
        └─ f. APPEND manifest "restored" event + audit item.restored (spec 15 §6); fsync
        │
        ▼
 ④ release lock → RestoreReport (restored / skipped-collision / failed-integrity counts, exit code)
```

## 5. Restore algorithm details

### 5.1 Ordering (parents before children)

Disposal deletes children before parents (spec 20 §5.1); **restore is the inverse** — recreate
parent directories first so children have a home. The engine sorts restore entries by path depth
**ascending**, recreating any missing intermediate directories with the captured parent metadata
where a parent was itself staged (else with sane defaults, flagged).

### 5.2 Metadata re-application order

Order matters because some attributes gate others:

1. **Create content** (rename/copy the payload into place).
2. **Ownership** (`fchown`) — before mode, since chown can clear setuid bits.
3. **Mode** (`fchmod`).
4. **ACLs** — after POSIX mode (ACL supplements it).
5. **xattrs** (`setxattr`) — including `com.apple.quarantine`, `whereFroms`, Finder tags, so the
   restored file is indistinguishable from the original to Spotlight/Finder.
6. **BSD flags** (`chflags`) — **last among metadata** because setting `uchg` (immutable) would
   block prior steps.
7. **Timestamps** (`setattrlist`/`utimensat`) — **truly last**, because every preceding write
   updates mtime/ctime; timestamps are re-stamped at the very end to reproduce the original.

All operate on the restored file's **fd** (fd-relative, spec 16 §9), never re-resolving the path
(TOCTOU-safe even during restore).

### 5.3 Hardlink groups

A staged item that had `st_nlink > 1` shared an inode with siblings (spec 16 §6). On restore:

- If **all** links in the group were staged together (recorded as a hardlink cluster in the
  manifest), restore the first as content and recreate the others with `link(2)` to it — preserving
  the shared-inode relationship.
- If siblings were **not** staged (links outside the plan still exist), restore recreates an
  independent copy and **warns** that the hardlink relationship is not reconstructed (the original
  inode may differ). This is an honest limit (§10), not silent divergence.

### 5.4 Symlinks

Restore recreates the **link** with the captured `symlinkTarget` via `symlinkat` — never the
resolved target (spec 16 §6). A dangling target is preserved as dangling (faithful to the original).

### 5.5 Integrity verification (mandatory)

Before moving any payload back, restore re-computes the staged payload's checksum and compares to
the manifest's captured checksum (spec 15 §5). A mismatch (staging corruption, tampering, disk
error) → the entry is **refused**, reported as a corruption failure (Principle 3 — never restore
something we can't prove is intact), contributing to exit 3. `--force` may override with a loud
warning (spec 25), but the default is refuse.

## 6. `cleaner undo` — list & restore

```
 cleaner undo --list [--session <id>] [--json]        # enumerate sessions/entries, sizes, expiry
 cleaner undo [<session-id> | <entry-id> | --last] [--to <path>]
              [--collision fail|rename|overwrite] [--dry-run] [--force]
```

Permanent purge is not a user command in v0.6 — staged payloads are freed automatically by the
retention policy (§7).

### 6.1 `list`

Enumerates staging sessions and their entries from the manifests (read-only; no lock needed for a
consistent-enough read — reduces manifest lines, tolerates a partially-written trailing line, spec
15 §12). Shows per-session: date, item count, staged on-disk size, retention-expiry, restored/
pending counts. `--json` emits a stable schema for scripting (Principle 3).

### 6.2 `restore`

Executes the §4 flow. `--dry-run` computes the full plan (integrity checks, collision detection,
target re-guard) and reports what *would* be restored **without moving anything** — identical-
numbers principle (DM-9 analog). `--to <path>` remaps the restore root (useful when the original
location is now occupied or the user wants it elsewhere). Restoring an already-restored entry is a
no-op (idempotent — the reduced manifest state shows `restored=true`).

### 6.3 Purge (automatic)

Permanent deletion of staged payloads (the only irreversible op, Principle/Art. 3). Safeguards in
§9. Purge is driven only by the retention policy (§7) — sessions past retention or over the size cap
are freed automatically. Purge appends `item.purged` audit events (spec 15 §6) and frees the staging
budget.

## 7. Retention & auto-purge policy

Staging cannot grow forever (it holds "freed" bytes until purged). Policy (spec 15 §11, config-
overridable spec 24):

- **Age cap.** Sessions older than `staging.retentionDays` (default 14) are eligible for
  auto-purge. Auto-purge runs opportunistically at CLI start (a quick check).
- **Size cap.** Total staging ≤ `min(user-set, 20% of volume free space)`. When exceeded, evict
  **oldest-first** until under cap. This bounds the "space is freed but still held" surprise: the
  user sees reclaim immediately, and staging self-trims.
- **Safety gate on auto-purge.** A session is auto-purged only if (a) past retention **and** (b) no
  pending interactive rollback references it **and** (c) its audit `item.staged` events are all
  reconciled. Auto-purge writes `item.purged` audit events (Principle 8 — even automatic deletion
  is recorded).
- **Never auto-purge within 24 h** of creation regardless of size pressure (a safety floor so a
  same-day mistake is always recoverable).

The tension (reclaim-now vs. keep-recoverable) is resolved in favor of **recoverability by
default** (Principle 2) with a bounded, transparent budget; the user is told in the report exactly
when a session will expire (`staging.retentionExpiresAt`, spec 15 §8).

## 8. Cross-volume & privilege on restore

- **Cross-volume restore.** If the original volume differs from staging (or from where the item
  now must land), restore uses copy-verify-then-unlink (mirror of spec 20 §6.2): copy payload to
  target, verify checksum, then remove the staged copy. Never remove staging until the restored
  copy is verified (crash-safe).
- **Privilege.** Restoring owner/group of a file the restoring user doesn't own requires elevation
  (spec 23 Authorization Services). If elevation is declined, restore proceeds with the **content
  and non-privileged metadata** restored, the ownership left as the restorer's uid, and a
  **warning** that ownership was not fully reproduced (honest partial — §10). It never silently
  drops fidelity.

## 9. Permanent-purge safeguards

Purge is the single irreversible operation (Art. 4.4, CC-7). Safeguards:

1. **Never a default.** No scan/clean path purges live items; every removal is staged first
   (`stage` is the only path). Purge of *staged* items happens only via automatic retention (§7) —
   there is no user-invoked purge command.
2. **Protected re-check.** Even purging from staging re-guards the *original* path recorded in the
   manifest against the deny-list — a manifest tampered to point purge at a protected path is
   rejected (exit 8).
3. **Write-intent journaling.** Audit `item.purged` intent is written (and fsync'd) *before* the
   `unlinkat`, so a crash mid-purge is reconstructable (spec 15 §12).
4. **Automatic-purge accounting.** Retention auto-purge (§7) records the total bytes and item count
   in the audit trail and runs only behind the §7 safety gate (24 h floor, no pending rollback).

## 10. Guarantees & limits — what is NOT recoverable (declared honestly)

Principle 3 demands we state the limits plainly rather than imply perfect reversibility:

**Guaranteed recoverable (within the retention window):**
- Any item staged via `Disposition.stage` — restored to its original path with full POSIX mode,
  ownership (given privilege), ACLs, xattrs, BSD flags, mtime/atime, and symlink targets.
- Same-volume stages are crash-atomic (NFR-032): after a crash an item is either fully staged
  (restorable) or fully in place (never restored, never lost).

**NOT recoverable / degraded (documented limits):**
1. **Purged items.** `purge` is permanent by definition — no rollback (Art. 3). The audit trail
   records that it happened, but the bytes are gone.
2. **Trashed items.** `Disposition.trash` hands items to the macOS Trash; recovery is via **Finder**
   (or emptied-Trash tools), **not** `cleaner undo`. The trade-off is deliberate (§11).
3. **Items past retention.** Auto-purged sessions (§7) are gone; `cleaner undo --list` shows expiry so the
   user isn't surprised.
4. **birthtime (creation date).** May not be settable on all filesystems; restore best-efforts it
   and warns if it couldn't be reproduced. Content and mtime are always restored.
5. **Hardlink relationships to un-staged siblings** (§5.3) — restored as an independent copy with a
   warning; the shared inode is not reconstructed.
6. **Ownership without privilege** (§8) — restored as the restorer's uid with a warning if
   elevation is declined.
7. **Externally-modified originals** — if the original path was recreated/occupied after staging,
   the collision policy governs (default `fail` → the restore is skipped, not forced; the user
   chooses `rename`/`overwrite`).
8. **Clone/COW sharing** — a restored file no longer shares extents with a former clone origin
   (it's a full copy); its on-disk footprint may exceed the original's *shared* footprint. This is
   a footprint difference, not a data-loss.

These limits are surfaced in `cleaner undo --list` and in restore warnings, so the user's mental
model matches reality (Principle 1/3).

## 11. macOS Trash as an alternative recoverable disposition

`Disposition.trash` (spec 16 §10) is offered as an *alternative* recoverable path, with explicit
trade-offs vs. tool-staging:

| Aspect | Tool staging (`stage`, default) | macOS Trash (`trash`) |
|---|---|---|
| Recovery UX | `cleaner undo` (scriptable, faithful metadata) | Finder "Put Back" (GUI, familiar) |
| Metadata fidelity | Full (ACL/xattr/flags/birthtime best-effort, §3) | Finder-managed; "Put Back" restores original location |
| Auto-cleanup | Tool retention policy (§7) | macOS "empty Trash automatically" (30 d) or manual |
| Space accounting | Counts against tool staging budget under `~/.cleaner` | Counts against `~/.Trash` (per-volume `.Trashes`) |
| Cross-tool visibility | Only via `cleaner` | Visible in Finder to the user |
| Atomicity | Same-volume rename (atomic) | `trashItem` (system-managed) |
| Rollback granularity | Per-session, per-entry, integrity-verified | Per-item via Finder |

**When Trash is preferable:** the user wants items visible in Finder's Trash and to use the
familiar "Put Back" workflow, or wants macOS to manage auto-empty. **Default remains `stage`**
(Principle 2) because it gives scriptable, metadata-faithful, integrity-verified, per-session
rollback that the Trash does not. The `TrashPlugin` (spec 13 §11) is the one category that
*proposes* trash (emptying the Trash itself), and even then the engine validates the path.

## 12. Crash consistency of staging

Staging must survive `SIGKILL`/power-loss mid-clean and mid-restore with a *deterministic*
recovered state (NFR-032/042):

- **Atomic move.** Same-volume stage is a single `renameat` — the item is atomically either in the
  live tree or in `files/`. No torn/half-moved directory (a directory rename moves the whole
  subtree atomically).
- **Manifest is an append-only journal** (spec 15 §5/12). Each entry is written **before** the
  move completes (write-intent) and confirmed after; `fsync` per record. On recovery, the engine
  reduces the manifest: an entry with a payload present in `files/` but no matching original is
  `staged`; an entry whose original still exists and whose payload is absent is `proposed` (the
  move never happened) — either way a definite state.
- **Cross-volume** uses copy-verify-then-unlink (§8, spec 20 §6.2): a crash before the source
  unlink leaves the source intact (safe); after, the staged copy is verified-present.
- **Restore** likewise appends a `restored` event only **after** the payload is back and verified;
  a crash mid-restore leaves the entry `staged` (payload still in `files/` if the move didn't
  complete, or in place if it did) — re-running restore is idempotent (§6.2).
- **Recovery command** (implicit at `cleaner undo --list` and automatic retention gc): reconciles
  each session's manifest against the `files/` tree, flags any entry it cannot classify (payload
  present but original also present → a copy-path crash before source unlink) for the user rather
  than guessing. No silent data operations during recovery.
- **Orphan cleanup.** A `files/` payload with no manifest entry (impossible in normal flow because
  intent is journaled first, but possible after `files/` corruption) is quarantined and reported,
  never auto-deleted.

## 13. API sketch

```swift
public protocol RollbackEngine: Sendable {
    func listSessions() async throws -> [StagingSessionSummary]
    func restore(_ target: RestoreTarget, options: RestoreOptions) async throws -> RestoreReport
    func purge(_ target: PurgeTarget, confirmed: ConfirmationState) async throws -> PurgeReport
    func gc(policy: RetentionPolicy) async throws -> GCReport          // §7
    func reconcile(_ session: SessionID) async throws -> ReconcileReport  // §12 crash recovery
}

enum RestoreTarget: Sendable { case session(SessionID), entry(UUID), last }
struct RestoreOptions: Sendable {
    var remapTo: FilePath? = nil
    var collision: CollisionPolicy = .fail       // fail | rename | overwrite
    var dryRun = false
    var force = false                             // override integrity refusal (loud warning)
}
enum CollisionPolicy: String, Sendable, Codable { case fail, rename, overwrite }

struct RestoreReport: Sendable, Codable {
    let session: SessionID
    let restored: [UUID]                          // manifestEntryIDs
    let skippedCollision: [UUID]
    let failedIntegrity: [UUID]
    let warnings: [RestoreWarning]                // ownership/birthtime/hardlink limits (§10)
    let exitCode: Int                             // 0 all restored; 3 partial; 8 protected breach
}
struct RestoreWarning: Sendable, Codable { let entry: UUID; let kind: WarningKind; let detail: String }
enum WarningKind: String, Sendable, Codable {
    case ownershipNotRestored, birthtimeNotSet, hardlinkNotReconstructed, xattrTruncated,
         volumeChanged, cloneShapeLost
}

/// Reads the manifest (spec 15 §5) — the SOURCE OF TRUTH for restore. Never re-reads the (gone) original.
struct ManifestReader: Sendable {
    func reduce(_ session: SessionID) throws -> [EffectiveEntry]   // last-write-wins on restored
    func verifyIntegrity(_ entry: EffectiveEntry) throws -> Bool   // §5.5 checksum re-check
}
```

The engine acquires the per-session `manifest.ndjson.lock` for `restore`/`purge` (spec 15 §12),
operates fd-relative (spec 16 §9), and writes `restored`/`purged` events append-only so the
staging tree stays a crash-safe journal end to end.

## Open Questions

- **OQ-21.1** Per-volume staging roots (`<mount>/.cleaner-staging`) vs. always-`~/.cleaner/staging`
  with a cross-volume copy fallback — the former keeps rename atomicity on external volumes but
  scatters staging. *Leaning: per-volume staging root when the item's volume ≠ home volume;
  reconcile at `cleaner undo --list`. Coordinate with spec 20 OQ-20.3.*
- **OQ-21.2** Integrity hash choice for staged trees (xxHash vs. SHA-256) — inherits spec 15
  OQ-15.2 / spec 20 OQ-20.1. *Leaning: xxHash tree-manifest for integrity; SHA-256 only if already
  computed for dedup.*
- **OQ-21.3** Should `restore --collision overwrite` stage the overwritten target into the *same*
  staging session (so the overwrite is itself reversible), or trust the user's explicit choice?
  *Leaning: stage-aside the overwritten target (reversibility all the way down).*
- **OQ-21.4** birthtime restoration reliability across APFS versions — is `setattrlist`
  `ATTR_CMN_CRTIME` dependable, or do we always warn? *Leaning: attempt + warn on failure (§10.4);
  never fail the restore over birthtime.*
- **OQ-21.5** Auto-purge aggressiveness under size pressure vs. the 24 h floor — is 20% of free
  space the right cap, or should it scale with volume size? *Inherits spec 15 OQ-15.6; re-baseline
  against spec 07 footprint budget.*
- **OQ-21.6** Do we offer a "restore entire session as of a point" transactional restore (all-or-
  nothing) in addition to per-entry? *Leaning: per-entry with a session convenience wrapper;
  true all-or-nothing restore across a huge session is impractical to make atomic — document the
  per-entry semantics.*

## Dependencies

**Consumes:** 00-constitution (Principle 2 reversibility-by-default, Principle 3 truth-in-reporting
/ honest limits, Art. 3 Staging/Purge/Rollback/Trash, Art. 4.4 invariants, Art. 5 protected paths,
Art. 7 exit codes 3/8, Art. 8 layout, CC-7 stage-then-purge), 07-nfr (NFR-032 crash consistency,
NFR-042 partial journal), 14-domain-model (`StagedRef`, `Disposition`, `CleanReport`,
`ActionOutcome`, `ConfirmationState`), 15-data-model (§3 layout, §5 staging manifest schema &
fidelity fields, §6 audit events, §11 retention, §12 locking/fsync/atomic-rename), 16-filesystem-
strategy (§6 symlink/hardlink, §9 canonicalize/TOCTOU/fd-relative, §11 disposition mechanics,
§7 volume/DiskArbitration), 20-cleanup-engine (produces the staging tree + manifest this restores;
capture-before-move), 23-permission-model (elevation for ownership restore).

**Feeds:** 22-safety-model (reversibility guarantee underpins risk/recoverability), 25-tui
(`cleaner undo` / `cleaner undo --list` UX, confirmation prompt, warnings), 28-logging
(`item.restored`/`item.purged` audit), 31-testing-strategy (crash-consistency & restore-fidelity
tests), 24-config (retention overrides).
