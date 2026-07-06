# 16 — Filesystem Strategy

> **Phase D · Depends on:** 00-constitution (Articles 4, 5, 10 / CC-10), 10-tech-stack (native
> frameworks), 14-domain-model (`Evidence`, `Item`, `VolumeID`, reclaim) ·
> **Depended on by:** 17 (scan), 19 (detection), 20 (cleanup), 21 (rollback), 22 (safety),
> 23 (permissions), 37 (performance).

## 1. Purpose & scope

This is the **native-first heart** of cleaner-cli (Constitution Principle 4, CC-1). It specifies
*how* the tool enumerates, measures, classifies, and safely mutates the filesystem — correctly and
fast enough for a 4 TB SSD with millions of files (Principle 9), while never overstating reclaim
(Principle 3, CC-10) and never touching protected or dataless data (Articles 4–5).

It defines the API choices (with a decision table, § 12), the macOS-version gates (baseline
macOS 13), and the exact semantics that populate the `Evidence` bag and the truthful `Item`
sizes from spec 14. Everything here is exposed to the rest of the system through a
`FilesystemService` façade (module boundary in spec 12) so plugins never call Darwin syscalls
directly; the engine enforces safety centrally (Article 4.4).

```swift
/// The façade every scan/clean path uses. Native-first; shell-outs are not part of this layer.
protocol FilesystemService: Sendable {
    func enumerate(root: FilePath, options: EnumerationOptions) -> AsyncThrowingStream<FSNode, Error>
    func measure(_ path: FilePath) async throws -> SizePair          // logical + on-disk (§3)
    func evidence(for path: FilePath, want: EvidenceFields) async throws -> Evidence   // §5/6
    func volume(for path: FilePath) async throws -> VolumeInfo        // §7
    func canonicalize(_ path: FilePath) throws -> FilePath            // §9
    func dispose(_ path: FilePath, as: Disposition, into: StagingContext) async throws -> DispositionResult // §11
}
```

## 2. Enumeration — `getattrlistbulk` first, `FileManager` fallback

The tool walks huge trees. The two viable native strategies:

### 2.1 Foundation `FileManager.enumerator(at:includingPropertiesForKeys:options:)`

- **Pros:** ergonomic, URL-based, integrates with `URLResourceValues` prefetch
  (`includingPropertiesForKeys`), handles symlink/hidden options, cross-platform-ish.
- **Cons:** allocates a `URL` (and often `NSDictionary`-backed resource values) per entry; for
  millions of entries this is significant heap churn and CFString bridging cost; less control over
  batching; lazy resource fetching can trigger extra `stat` calls.

### 2.2 Darwin `getattrlistbulk(2)`

- **Pros:** the fastest documented bulk enumeration on Darwin. A single syscall returns **many**
  directory entries *with their requested attributes* (name, `fsobj_type`, `st_size`,
  allocated size via `ATTR_FILE_ALLOCSIZE`/`ATTR_FILE_DATAALLOCSIZE`, `st_ino`, `st_mtime`
  nanosecond, `st_flags`, `st_nlink`, owner/mode) in one shot — no per-entry `stat`. It amortizes
  syscall overhead across a batch and returns exactly the attributes we ask for, avoiding the
  double-fetch problem. This is why it is *materially* faster than `readdir`+`stat` or
  `FileManager` on trees of millions of files: fewer syscalls, no object allocation per entry,
  cache-friendly fixed buffers.
- **Cons:** raw C API (attribute-buffer packing, `attrreference_t` offset math, alignment,
  endianness of packed fields), easy to misuse; must be wrapped carefully in a `// SAFETY:`-noted
  adapter.

### 2.3 Decision

**Use `getattrlistbulk` for the hot enumeration path**, wrapped in a `BulkEnumerator` adapter that
yields typed `FSNode` values, with a **`FileManager.enumerator` fallback** selected when:

- the volume is non-local/network (DiskArbitration, § 7) where bulk attribute support is uneven, or
- `getattrlistbulk` returns `ENOTSUP` / an unexpected error for a directory, or
- a build/runtime flag forces the Foundation path (diagnostics).

```swift
struct FSNode: Sendable {
    let name: String
    let path: FilePath                 // parent + name, built without re-stat
    let type: FSObjType                // regular, directory, symlink, other
    let inode: UInt64
    let sizeLogical: Int64
    let sizeOnDisk: Int64              // ATTR_FILE_ALLOCSIZE (allocated blocks) — truthful (§3)
    let mtimeNs: Int64
    let flags: UInt32                  // st_flags (UF_COMPRESSED, UF_HIDDEN, SF_* …)
    let nlink: UInt32
    let mode: UInt16
    let ownerUID: UInt32
    let isDataless: Bool               // derived from flags/attrs (SF_DATALESS) — §4.4
}

struct EnumerationOptions: Sendable {
    var followSymlinks = false         // NEVER true for deletion walks (Article 4.4)
    var includeHidden = true
    var maxDepth: Int? = nil
    var batchSizeHint = 100            // getattrlistbulk entries per syscall
    var wantAllocatedSize = true
}
```

**Batching.** `BulkEnumerator` issues `getattrlistbulk` into a reused fixed buffer (e.g. 64 KiB),
decoding N entries per call, and streams them as an `AsyncThrowingStream<FSNode>` so downstream
consumers (scan engine, spec 17) process with **bounded memory** — we never build an in-memory
tree of the whole volume. Directory recursion is a work queue (`Deque`, swift-collections) of
directory FDs, not recursion, to bound stack and enable cancellation at directory boundaries
(spec 17 `Task.checkCancellation()`).

**Directory descent via file descriptors.** Open each directory once (`open(…, O_DIRECTORY |
O_NOFOLLOW | O_CLOEXEC)`), enumerate via the FD (`getattrlistbulk` takes an fd), and descend using
`openat(2)` on child names — this is both faster (no path re-resolution per level) and TOCTOU-safer
(§ 9), because we operate relative to a fixed, already-verified directory fd rather than re-walking
a mutable path string.

## 3. Size measurement — truthful on-disk allocation (CC-10)

Reclaim is measured from **on-disk allocation**, not logical size (spec 14 § 6). APIs:

- **`URLResourceValues.totalFileAllocatedSizeKey`** — for a file, the total blocks allocated
  including resource forks/metadata. Recursive directory size = streaming sum of this over
  descendants.
- **`URLResourceValues.fileAllocatedSizeKey`** — allocated size of the file's data fork only.
- **`.fileSizeKey` / `.totalFileSizeKey`** — logical sizes, kept for context (`sizeLogical`).
- Hot path uses `getattrlistbulk`'s `ATTR_FILE_ALLOCSIZE` directly (same number, no per-file URL).

```swift
struct SizePair: Sendable, Hashable {
    var logical: Int64       // st_size sum
    var onDisk: Int64        // allocated-block sum (headline reclaim)
    var sharedExcluded: Int64 = 0   // blocks not counted due to clone/hardlink sharing (§4)
}
```

**Directory sums with bounded memory.** Directory `onDisk` is accumulated by *streaming* the
enumeration (§ 2) and adding each node's `sizeOnDisk` into a running `Int64` — **never** by
materializing a full node list. Per-directory subtotals live in the scan accumulator actor
(spec 17), keyed by the directory fd/inode, and are folded upward as the work queue drains. Memory
stays O(open directory depth × batch buffer), not O(files).

## 4. APFS specifics

### 4.1 Clones (shared blocks) — don't double-count

APFS `clonefile(2)` creates files that share physical extents (copy-on-write). Two consequences:

- **Measurement:** summing `allocatedSize` of a clone *and* its origin double-counts shared
  extents. The tool detects sharing within a volume and records shared bytes in
  `SizePair.sharedExcluded` / `ReclaimEstimate.sharedBytesExcluded` (spec 14 § 6). Detection
  signals: identical `st_ino` is a hardlink (§ 6), but clones have *distinct* inodes sharing
  extents — detected via per-file allocated-vs-logical anomalies and, where needed, `fcntl`
  `F_LOG2PHYS_EXT` / extent queries to identify overlapping physical block ranges. When exact
  extent introspection is unavailable, the tool marks `Evidence.isClone` heuristically and sets
  `ReclaimConfidence.estimated` rather than overstating (Principle 3).
- **Deletion:** removing a clone frees only its *unshared* extents; the origin retains the shared
  ones. Reclaim credit reflects that.

The tool itself **uses `clonefile`** where copying is needed (never in the delete path; relevant to
staging on the same volume — but staging prefers `rename`, § 11).

### 4.2 Sparse files

`allocatedSize < logicalSize`. Reported truthfully: `sizeLogical` = logical, `sizeOnDisk` =
allocated blocks. Reclaim credits only allocated blocks. `Evidence.isSparse = allocatedSize < size`.

### 4.3 Snapshots (local Time Machine) — report, never delete

Local APFS/TM snapshots are read-only point-in-time mounts. The tool:

- **Detects** paths under a snapshot mount (via `statfs` mount source / DiskArbitration, and the
  presence of a snapshot mount root) and sets `Evidence.snapshotRef` (spec 14 § 4.7).
- **Never deletes** anything under a snapshot mount (Constitution Article 5 — "any path under a
  Time Machine local snapshot mount" is protected). Snapshots are surfaced in reports as space
  that *appears* used but is reclaimable only by the OS / `tmutil` (which we do **not** invoke to
  delete in v1).
- Space held by snapshots is **reported for context** (informational finding, `purgeable`) but
  contributes **0** to actionable reclaim.

### 4.4 Purgeable space & dataless / placeholder files (iCloud)

- **Purgeable space** (APFS can free on demand) is reported informationally; the tool does not
  claim it as reclaim it caused.
- **Dataless / placeholder files** (iCloud Drive "optimized storage", `SF_DATALESS` flag /
  `NSURLUbiquitousItemIsDownloadedKey` states). **Hard rules (Article 1 safety):**
  - The tool MUST NOT read file *contents* of a dataless file in a way that triggers a download.
    Enumeration reads *attributes only* (`getattrlistbulk` does not fault the data in); we never
    `open()`+`read()` a dataless file's data during scan.
  - The tool MUST NOT delete a dataless/placeholder file — deleting it can evict cloud data the
    user expects to re-materialize; treat as protected, set `Evidence.isDataless = true`, skip
    with `SkipReason.dataless` (spec 14 § 4.12).
  - Dataless files contribute **0** reclaim (they occupy ~no local blocks anyway).

### 4.5 Compression

`UF_COMPRESSED` (HFS+/APFS transparent compression): `allocatedSize` already reflects the
compressed on-disk footprint, so no special handling for measurement — it is truthful by
construction. Flag surfaced in `Evidence` for detection heuristics.

## 5. Extended attributes & metadata

Read via `listxattr(2)` / `getxattr(2)` (with `XATTR_NOFOLLOW` on symlinks). Populate `Evidence`:

- **`com.apple.metadata:kMDItemWhereFroms`** — download origin URL(s); decoded from the binary
  plist blob into `Evidence.whereFroms`. A strong signal that a file is a re-downloadable artifact
  (raises safety score for caches; used by detection, spec 19).
- **`com.apple.quarantine`** — parsed into `QuarantineInfo` (agent, timestamp, origin URL).
- **`com.apple.metadata:_kMDItemUserTags`** — Finder tags → `Evidence.finderTags` (user-authored
  tags are a signal the file matters — can *lower* safety score).
- **Arbitrary xattrs** — captured as a bounded map (`Evidence.xattrs`), each value base64-encoded
  for the staging manifest (spec 15 § 5) so restore is byte-faithful; values past a size cap are
  elided with a `truncated` flag (we still record presence for restore-completeness warnings).

**Spotlight/Launch Services** (CoreServices, spec 10 § 10):

- `MDItem` / `MDQuery` → `kMDItemKind` (`Evidence.spotlightKind`), `kMDItemLastUsedDate`
  (`Evidence.lastUsedDate`, more reliable than `atime` under `relatime`).
- Launch Services → `LaunchServicesInfo` (bundle registration, is the owning app installed,
  last-used-by-app) for unused-app/orphan detection.

Metadata acquisition is **best-effort and permission-gated**: a `nil` field means "not gathered",
never "zero" (spec 14 § 4.7). Missing Full Disk Access downgrades metadata richness, not
correctness (spec 23).

## 6. Symlinks & hardlinks

**Symlinks.**

- Enumeration never follows symlinks by default (`O_NOFOLLOW`, `followSymlinks = false`). A symlink
  is reported *as a link* (its own tiny size), never as its target's size.
- **Deletion safety (Article 4.4):** the tool MUST NOT follow a symlink out of an allowed root to
  delete the target. Before any disposition, the resolved real path is re-checked against
  allow-space ∩ roots − deny-list (§ 9). Deleting a symlink removes only the link.
- Staging preserves symlinks as links (`symlinkTarget` recorded, spec 15 § 5) — never dereferenced.

**Hardlinks.**

- `st_nlink > 1` ⇒ `Evidence.isHardlink`, `hardlinkCount` recorded. Multiple directory entries
  share one inode; the blocks are freed only when the **last** link is unlinked.
- **Reference counting to avoid freeing shared inodes wrongly:** within a scan, the tool groups
  entries by `(volumeUUID, inode)`. Reclaim credit for a hardlinked file is granted only if the
  plan removes *all* links that live within the allowed roots; if links exist outside the roots
  (or outside the plan), the blocks are excluded from reclaim (`sharedExcluded`) and the finding is
  flagged so the user understands deleting one link frees nothing.
- Detected hardlink clusters are reported (spec 19 detection can offer "these N paths are the same
  inode").

## 7. Volume awareness — DiskArbitration

Each root is resolved to a `VolumeInfo` via DiskArbitration (`DASession`, `DADiskCopyDescription`)
+ `statfs`:

```swift
struct VolumeInfo: Sendable, Hashable {
    let id: VolumeID                   // volume UUID (stable key used in Item/cache, spec 14/15)
    let mountPoint: FilePath
    let fsType: String                 // "apfs", "hfs", "smbfs", "nfs", "exfat" …
    let medium: VolumeMedium           // ssd | hdd | network | external | virtual | unknown
    let isInternal: Bool
    let isRemovable: Bool
    let isReadOnly: Bool
    let isSystemVolume: Bool           // the sealed system volume — writes REFUSED (Article 4.4)
}
enum VolumeMedium: String, Sendable { case ssd, hdd, network, external, virtual, unknown }
```

Uses:

- **Per-volume concurrency tuning (spec 17):** SSD → high parallelism (e.g. cores×2); HDD →
  low/serial (seeks dominate); network → very low + longer timeouts; external → moderate. The
  scan engine's concurrency limiter reads `medium`.
- **Refuse system-volume writes:** `isSystemVolume || isReadOnly` ⇒ no disposition may target it
  (Article 4.4). Mount roots and `/` are refused as delete targets.
- **Cross-volume Item split:** an `Item`'s paths are guaranteed same-volume (DM-6); the scanner
  splits groups spanning volumes and picks the right staging strategy (rename vs copy, § 11).
- **VolumeID stability:** the volume UUID keys the incremental scan cache (spec 15 § 7); a changed
  UUID (remount of a different volume at the same path) invalidates cache entries.

## 8. In-use / locked detection

Before disposing of a file the engine checks whether it is open/locked (Article 4.4): BSD flags
(`UF_IMMUTABLE`/`SF_IMMUTABLE`), advisory locks, and (best-effort) open-file detection. A locked
or currently-open file is skipped unless an explicit override is given, and the state is recorded
in `Evidence.isOpenOrLocked`. (Full policy in spec 20.)

## 9. Path safety — canonicalization & TOCTOU

**Canonicalization** (`FilesystemService.canonicalize`):

1. Expand `~`, resolve environment, make absolute.
2. Resolve `.` and `..` lexically, then resolve symlink components via `realpath(3)` /
   `FilePath` canonical form to get the true on-disk path.
3. NFC-normalize Unicode.

The **canonical** path is what feeds allow/deny checks and `FindingID` derivation (spec 14 § 4.1),
so a `..` or symlink cannot smuggle an action outside the allowed roots.

**Deny/allow enforcement (Article 5, engine-side).** For every candidate action path:
`allowed = (⋃ pluginDeclaredRoots ∩ allowSpace) − denyList`. The deny-list (`/`, `/System`,
`/usr` except `/usr/local`, user content roots, `~/.ssh`, keychains, `*.key`/`*.pem`, TM snapshot
mounts, the tool's own home, etc.) is checked against the **canonical** path *and* its real parent.
A path failing the check yields a display-only, `isProtected` finding (DM-4) and, if an action is
somehow attempted, aborts with exit code 8 (`safety`).

**TOCTOU-safe mutation.** Because a path can change between check and act, mutations operate on
**file descriptors**, not path strings:

- Open the target's *parent directory* with `O_DIRECTORY | O_NOFOLLOW`, then operate on the child
  by name relative to that fd using the `*at` family (`openat`, `fstatat`, `unlinkat`,
  `renameat`/`renameatx_np`).
- After opening the target (`openat(…, O_NOFOLLOW)`), `fstat` it and verify identity
  (`dev`, `inode`, and expected `nlink`/type) matches what the scan recorded **before** disposing.
  If identity drifted, abort the action for that item (skip + report), never act on the wrong file.
- Never re-resolve the full path string at act time; act relative to the already-verified parent
  fd. This closes the classic symlink-swap race.

## 10. Trash integration (`Disposition.trash`)

The `trash` disposition uses the OS Trash so items appear in Finder's Trash:

- Primary: `FileManager.trashItem(at:resultingItemURL:)` (Foundation, no AppKit).
- Alt: `NSWorkspace.shared.recycle(_:completionHandler:)` (AppKit, thin/optional adapter — spec 10
  § 10; isolated so headless builds don't require AppKit).

Trash is a *terminal* disposition from the tool's perspective (recovery is via Finder, not tool
rollback), so it is offered but `stage` remains the default (Principle 2). Trashing respects the
same allow/deny and TOCTOU checks as staging/purge.

## 11. Disposition mechanics (stage / trash / purge)

- **stage (default):** same-volume → `renameat`/`renameatx_np` into the session staging tree
  (atomic, no data copy — fast even for huge dirs). Cross-volume → `clonefile` where possible else
  streamed `copyfile(3)` then `unlink`, with checksum capture (spec 15 § 5) and a rollback-safe
  temp-then-rename. Metadata (owner/mode/ACL/xattrs/flags/timestamps) is captured *before* the move
  for restore fidelity.
- **trash:** § 10.
- **purge:** permanent `unlinkat` / recursive removal via fd-relative walk. Only reached via
  explicit escalation (spec 14 DM-5). Purge of a directory re-walks under the already-opened dir fd
  to avoid re-resolving paths.

All three go through the same safety gate (§ 9) and emit audit events (spec 15 § 6) before/after.

## 12. Decision table — signal → API

| Need / signal | Chosen API | Fallback | Gate |
|---|---|---|---|
| Bulk directory enumeration (hot path) | `getattrlistbulk(2)` (fd-relative) | `FileManager.enumerator` | macOS 13+ |
| Network/unknown-FS enumeration | `FileManager.enumerator` | — | any |
| Logical size | `st_size` / `.fileSizeKey` | — | any |
| On-disk allocated size (reclaim, CC-10) | `getattrlistbulk` `ATTR_FILE_ALLOCSIZE` / `URLResourceValues.totalFileAllocatedSizeKey` | `.fileAllocatedSizeKey` | any |
| Clone / shared-extent detection | `fcntl F_LOG2PHYS_EXT` + alloc-vs-logical heuristic | heuristic only → `confidence=estimated` | APFS |
| Sparse detection | `allocatedSize < size` | — | any |
| Snapshot detection | `statfs` mount source + DiskArbitration | mount-table scan | APFS |
| Dataless/placeholder | `SF_DATALESS` flag / `NSURLUbiquitousItemDownloadingStatusKey` | attr-only, never open | macOS 13+ |
| xattrs (whereFroms, quarantine, tags) | `listxattr`/`getxattr` (`XATTR_NOFOLLOW`) | — | any |
| Spotlight kind / last-used | `MDItem`/`MDQuery` (CoreServices) | `atime` (lower-bound) | macOS 13+; 14+ refinements gated |
| App registration / installed | Launch Services | — | any |
| Volume type (SSD/HDD/net) & mount roots | DiskArbitration + `statfs` | `statfs` only (no medium) | any |
| Symlink-safe open/descent | `openat`/`open` `O_NOFOLLOW`,`O_DIRECTORY` | — | any |
| TOCTOU-safe delete | `openat`+`fstat` identity check + `unlinkat`/`renameatx_np` | lock + re-stat | any |
| Trash | `FileManager.trashItem` | `NSWorkspace.recycle` | any (AppKit optional) |
| Atomic same-volume stage | `renameat`/`renameatx_np` | `copyfile`+`unlink` | any |
| Cross-volume stage copy | `clonefile` (same-vol only) / `copyfile` | streamed copy | APFS/any |

**macOS version gates.** Baseline **macOS 13 (Ventura)** (Constitution Article 6, ADR-0001). APIs
newer than 13 (some Spotlight refinements, APFS conveniences) are **runtime-probed** and gated;
`getattrlistbulk`, `clonefile`, `renameatx_np`, DiskArbitration, `*at` syscalls, xattr, and
`URLResourceValues` allocated-size keys are all available at 13, so no core capability is gated.
Where a newer refinement is absent, the fallback column applies with a possible
`ReclaimConfidence.estimated` downgrade — never a correctness loss.

## 13. Performance & memory model

- **Bounded memory:** streaming enumeration + streaming size sums (§ 2, § 3); no whole-tree
  materialization. Working set ~ O(open dir depth × batch buffer + accumulator subtotals).
- **Syscall economy:** `getattrlistbulk` batches attributes so a scan is roughly one syscall per
  ~100 entries instead of one `stat` per entry — the primary reason it scales to millions of files.
- **fd-relative traversal** avoids repeated path resolution and is TOCTOU-safe (§ 9).
- **Concurrency** is per-volume tuned (§ 7) and cooperatively cancellable at directory boundaries
  (spec 17). Reused fixed buffers avoid per-entry allocation.
- Benchmarks and thresholds in spec 30; deeper tuning in spec 37.

## Open Questions

- **OQ-16.1** How aggressively should we pursue exact APFS clone/extent introspection
  (`F_LOG2PHYS_EXT` walking) vs. accepting `estimated` confidence for shared blocks? Exact is
  costly per-file. *Leaning: heuristic by default, exact only when a finding's shared-block
  estimate would materially change a reclaim headline.*
- **OQ-16.2** Do we need a private-API-free way to enumerate/report snapshot space precisely, or is
  the informational `tmutil listlocalsnapshots`-style read (read-only shell-out adapter) acceptable
  for the *report* (never delete)? *Leaning: read-only adapter for reporting, gated behind an ADR.*
- **OQ-16.3** Dataless-file detection reliability across iCloud vs third-party file providers —
  is `SF_DATALESS` sufficient, or do we also need `NSFileProvider` awareness? *Leaning: SF_DATALESS
  + ubiquitous-item keys for v1; file-provider deferred.*
- **OQ-16.4** `getattrlistbulk` attribute set: fetch owner/mode/flags always (richer evidence, more
  bytes/entry) or lazily on candidate findings only (faster bulk walk)? *Leaning: fetch a lean core
  set in bulk, enrich candidates on demand.*
- **OQ-16.5** Should the Foundation fallback be a build-time or purely runtime decision? *Leaning:
  runtime probe per volume/error, no `#if`.*

## Dependencies

**Consumes:** 00-constitution (Articles 4.4 hard invariants, 5 protected paths, 10 native-first /
CC-10), 10-tech-stack (Foundation, System `FilePath`, Darwin `getattrlistbulk`/`clonefile`/xattr,
DiskArbitration, CoreServices, AppKit-optional), 14-domain-model (`Evidence`, `Item`, `SizePair`
mapping to reclaim, `VolumeID`).

**Feeds:** 17-scan-engine (enumeration, concurrency tuning, cache stamps), 19-detection-algorithms
(evidence signals: whereFroms, lastUsed, hardlink clusters), 20-cleanup-engine (TOCTOU-safe
disposition mechanics, trash), 21-rollback-design (metadata capture for restore), 22-safety-model
(allow/deny enforcement, dataless/snapshot protection), 23-permission-model (FDA/metadata gating),
37-performance-optimization (syscall/memory tuning).
