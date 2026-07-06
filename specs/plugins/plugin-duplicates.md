# plugin-duplicates — Duplicate Finder

> **Phase H · Plugin id:** `dev.cleaner.duplicates` · **Target release:** v1.0 ·
> **Depends on:** plugins/README, 13, 14, 16 (clone/hardlink, sizing), 19 (multi-stage dedup —
> authoritative), 00 Art. 4/5.

Finds duplicate files across user-designated search roots using the **multi-stage dedup pipeline
of spec 19** (size bucket → cheap head/tail hash → full content hash → optional byte compare),
and is **clone/hardlink-aware** so it never claims reclaim for files that already share blocks.
Because duplicates are **user files**, this plugin is a *detector*: it is 🟡, **never
auto-selects**, and always leaves the choice of *which* copy to keep to the user.

## 1. Identity

```swift
PluginManifest(
    id: "dev.cleaner.duplicates", name: "Duplicate Finder", category: .duplicates,
    apiVersion: "1.4.0", pluginVersion: "1.0.0",
    declaredRoots: [],                           // no fixed roots — operates ONLY on user-configured searchRoots (§4)
    defaultRisk: .medium,                        // 🟡 — user files; never 🟢
    capabilities: [.dryRun, .estimate, .rollback, .audit, .incremental],
    requiresElevation: false, trust: .firstParty)
```

Scope boundary: operates only on **explicit user-provided `searchRoots`** (spec 18 target rules) —
never the whole disk, never protected content roots unless the user names them and the engine
allows. It **presents duplicate sets**; it does not decide deletions. Auto-selection is
categorically disabled (see §5).

## 2. What it targets

| Sub-item | What | Risk |
|---|---|---|
| Duplicate file sets | ≥ 2 files with identical content across `searchRoots` | 🟡 (user files) |
| Already-shared sets | duplicates that are APFS clones or hardlinks of each other | informational (0 reclaim) |

It produces a **duplicate set** (a group of paths with identical content) and, within each set,
marks a *suggested keeper* (heuristic, §5) — but **selects nothing** for deletion. Does not target:
system files, app bundles, anything on the deny-list, or files it cannot fully hash (skipped, not
guessed).

## 3. Detection signals & algorithm (spec 19 pipeline)

Duplicate detection is expensive; the pipeline is staged so full hashing is only done on genuine
candidates (spec 19 is the authority; summarized here for implementability):

1. **Stage 0 — enumerate & filter.** Walk `searchRoots` (streaming, spec 16 §2). Skip: symlinks
   (never followed out of root), dataless/iCloud placeholders (`isDataless` — never faulted in),
   files below `minFileSize` (default 1 MiB — tiny dup noise not worth it), and zero-byte files.
2. **Stage 1 — size bucketing.** Group by exact `size`. A file with a unique size cannot have a
   duplicate → dropped immediately (cheapest filter, no I/O).
3. **Stage 2 — cheap partial hash.** For each size-collision bucket, hash the **first + last N KiB**
   (default 4 KiB each) with a fast hash (spec 19: e.g. xxHash/SHA-256-truncated). Sub-group by
   this signature; singletons dropped. Eliminates most false collisions with minimal reads.
4. **Stage 3 — full content hash.** For surviving candidates, stream a full cryptographic hash
   (SHA-256) with bounded buffers. Equal full hashes = a duplicate set.
5. **Stage 4 — optional byte-for-byte verify.** If `paranoidCompare` (default false), confirm
   equality by direct byte comparison to eliminate hash-collision risk entirely.
6. **Clone/hardlink correction (critical, spec 16 §4/§6).** Within a confirmed set, cluster by
   `(volumeID, inode)` (hardlinks) and detect APFS clones (shared extents). Files that already
   share blocks contribute **0 marginal reclaim** — removing one frees nothing until the last
   reference goes. The set is still shown (informational) but its reclaim reflects only *distinct*
   physical copies (`sharedBytesExcluded`, DM-8).
7. **FindingID** for a set = `"dup:" + sha256(contentHash + sortedCanonicalPaths)` — deterministic
   per set membership (DM-7). Each set is one grouped `Item` (spec 14 §4.8) spanning the duplicate
   paths, or one `Finding` per removable copy referencing the shared keeper — see §6.

## 4. Roots / paths with justification

**No declared roots.** The plugin scans exactly the `searchRoots` the user configures (e.g.
`~/Downloads`, an external archive volume). Each is validated as a user target rule (spec 18): the
engine intersects with allow-space and subtracts the deny-list (spec 16 §9), so even a user-named
root cannot reach `~/.ssh` or system paths. Scanning `~/Documents`/`~/Desktop` is only possible if
the user explicitly names them *and* acknowledges (they are otherwise protected, Art. 5) — and even
then the plugin only *detects*, never auto-deletes.

## 5. Risk & safety scoring — and the no-auto-select rule

- **All duplicate findings are 🟡** and, uniquely, this plugin **overrides pre-selection to
  off** regardless of score: a duplicate is *someone's real file*, and which copy is "the
  duplicate" is a human judgment (the one in `~/Downloads` might be the one they want; the one in a
  curated folder might be canonical). Proposed `SafetyScore ≈ 60`, but the plugin sets a flag the
  engine honors: **never pre-select; require explicit per-set user
  choice** (Principle 1). Under `--yes`, duplicate findings are reported but never actioned.
- **Suggested keeper heuristic** (advisory only, shown in preview, selects nothing): prefer the
  copy that is oldest (`birthtime`), in a non-`Downloads`/non-temp location, has Finder tags, or is
  referenced by more apps (Launch Services). The user can override.
- Clone/hardlink members are shown as "already shared — deleting frees nothing" (informational,
  0 reclaim) so the user isn't misled.

## 6. Recoverability & staging

- `Disposition = .stage` for any copy the *user* selects (Principle 2). `Recoverability = .instant`
  — the other copies remain, and the staged copy is one-command restorable (spec 21). This is why
  duplicates, despite being user files, are *safe to act on once chosen*: a keeper always remains
  and the removed copy is staged.
- The `Finding`/`Item` model: the plugin emits the set with each *non-keeper* copy as an actionable
  path and the keeper marked non-actionable, so the engine can never stage the last copy of a set
  (guard: at least one member of every set must remain — enforced at plan time).
- `RollbackHint`: "identical copy retained at `<keeper>`; restore this copy from staging if needed."

## 7. Dry-run / estimate

- `estimate`: sum of `allocatedSize` of the **removable** copies only, with clone/hardlink
  exclusion (CC-10, DM-8) → the *true* reclaimable bytes if the user removes all-but-one per set.
  `confidence = .estimated` when clone detection is heuristic (spec 16 OQ-16.1), else `.exact`.
- `--dry-run` shows each set: the copies, sizes, suggested keeper, and the reclaim if reduced to
  one — but selects nothing.

## 8. Shell fallback & its safety

**N/A — fully native.** Hashing uses CryptoKit/Foundation; enumeration uses `context.fs`. No
external process. (Content hashing reads file *data*, which is allowed for non-dataless files;
dataless files are excluded in Stage 0 so no download is triggered, spec 16 §4.4.)

## 9. Edge cases & false-positive mitigations

| Edge case | Mitigation |
|---|---|
| Files that are already clones/hardlinks | Detected in Stage 6; shown as 0-reclaim informational; never counted as savings. |
| Hash collision | Optional Stage 4 byte-compare; SHA-256 makes accidental collision negligible. |
| Deleting the last copy of a set | Plan-time guard: every set must retain ≥ 1 member; keeper marked non-actionable. |
| iCloud/dataless placeholders | Excluded in Stage 0 (never faulted in / downloaded). |
| Bundles (`.app`, `.photoslibrary`) treated as many files | Treat known bundle types as opaque single items (config `treatBundlesAsOpaque`), avoid partial-bundle deletion. |
| Files changing during scan | fd-identity re-check at act time (spec 16 §9); re-hash-on-doubt; skip if changed. |
| Sparse files with equal logical size | Compared on content; reclaim uses allocated blocks. |
| Symlinks pointing at set members | Not followed; the link itself is not a duplicate of its target's content. |
| Very large corpora (millions of files) | Staged pipeline keeps full-hash work to genuine candidates; bounded memory (spec 16 §13). |

## 10. Test cases

- **T1 three identical 5 MiB files in searchRoots** → one set, two removable, one keeper; reclaim =
  2× allocated.
- **T2 two files, same size, different content (Stage 3 differs)** → not a set.
- **T3 two files, same content, one a hardlink of the other** → informational, 0 reclaim.
- **T4 APFS clones** → informational, 0 reclaim (clone detection).
- **T5 under `--yes`** → sets reported, nothing actioned.
- **T6 user selects all copies of a set** → plan-time guard forces ≥1 keeper retained.
- **T7 dataless duplicate** → excluded (Stage 0).
- **T8 file mutated mid-scan** → re-hash/skip, never acts on changed file.
- **T9 `.app` bundle dup with `treatBundlesAsOpaque`** → single opaque Item, not per-file.

## 11. Config keys

`plugins.duplicates`:

| Key | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | bool | `true` | Master toggle. |
| `searchRoots` | list<path> | `[]` | **Required** roots to scan (user target rules). Empty ⇒ no findings. |
| `minFileSize` | int (bytes) | `1048576` | Ignore files below this (dup noise). |
| `partialHashBytes` | int | `4096` | Head/tail bytes for Stage 2. |
| `paranoidCompare` | bool | `false` | Enable Stage 4 byte-for-byte verify. |
| `treatBundlesAsOpaque` | bool | `true` | Treat `.app`/`.bundle`/libraries as single items. |
| `suggestKeeper` | enum(`oldest`,`curated`,`none`) | `oldest` | Keeper hint strategy (advisory). |

## Open Questions

- **OQ-dup.1** Should the plugin ever *auto-select* non-keepers in an explicit `--dedup --yes`
  power-user mode, or is manual selection always mandatory? *Leaning: always manual in v1; a
  policy-file-authorized auto mode is a v2 consideration (spec 23).*
- **OQ-dup.2** Cross-volume duplicates: report them (can't rename-stage across volumes cheaply) or
  restrict to same-volume sets? *Leaning: report all; note cross-volume staging cost.*
- **OQ-dup.3** Similarity (near-duplicate images/media via perceptual hash) — in scope for v1.0 or
  a separate plugin? *Leaning: exact-content only for v1; perceptual dedup is a future plugin.*
- **OQ-dup.4** How is `FindingID` kept stable when set membership changes between scans (a third
  copy appears)? *Leaning: per-set hash changes with membership; incremental cache re-keys.*

## Dependencies

**Consumes:** 13 (contract; grouped Items), 14 (`Item` groups, DM-8 shared-block reclaim), 16
§2/§4/§6/§9/§13 (streaming, clones, hardlinks, TOCTOU, memory), 18 (searchRoots as target rules),
19 (the multi-stage dedup pipeline — authoritative), 00 Art. 1 (safety), Art. 4.1 (medium), Art. 5.
**Feeds:** 20 (stages user-chosen copies, ≥1-keeper guard), 21 (instant rollback), 22 (scores +
no-auto-select flag), 25 (duplicate-set presentation).
