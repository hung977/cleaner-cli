# plugin-trash — macOS Trash

> **Phase H · Plugin id:** `dev.cleaner.trash` · **Target release:** MVP ·
> **Depends on:** plugins/README (template), 13 (`CleanerPlugin`, `CleanDirective`), 14
> (`Item`/`Finding`/`Disposition`/`Recoverability`), 16 §10 (Trash integration), 00 Art. 4/5.

This is the **reference example** for the plugin suite — the simplest possible plugin, kept
deliberately small so it can be read end-to-end. It empties the macOS Trash.

## 1. Identity

```swift
PluginManifest(
    id: "dev.cleaner.trash", name: "Empty Trash", category: .system,
    apiVersion: "1.4.0", pluginVersion: "1.0.0",
    declaredRoots: [
        RootSpec(base: .home,   glob: ".Trash/**"),          // per-user Trash
        RootSpec(base: .volumes, glob: "*/.Trashes/<uid>/**") // per-volume Trash (external disks)
    ],
    defaultRisk: .medium,                    // 🟡 — Trash contents ARE user data the user chose to discard
    capabilities: [.estimate, .dryRun],      // sizes cheap; NO .rollback (Trash is itself the recovery buffer)
    requiresElevation: false, trust: .firstParty)
```

The Trash is a user-controlled recovery buffer: items land there because the user pressed
Delete, but they are recoverable from Finder until emptied. Emptying it is therefore a **medium**
action (🟡), not safe (🟢): the loss is intended but irreversible from the tool's perspective.
Scope boundary: this plugin only ever touches paths *inside* a Trash directory; it never puts
things *into* Trash (that is the `.trash` disposition other plugins may request via the engine).

## 2. What it targets

| Sub-item | What | Why it is junk / how it regenerates |
|---|---|---|
| User Trash entries | Top-level files/dirs under `~/.Trash` | Already discarded by the user; regenerates only if the user restores from Finder first. Does not regenerate automatically. |
| Per-volume Trash | `/Volumes/<disk>/.Trashes/<uid>` for mounted external/secondary volumes | Same, on non-boot volumes. Each is a distinct `VolumeID` (DM-6). |

Does **not** touch: anything outside a Trash dir; the Trash directory *itself* (only its
contents); the `.Trashes` directory structure; another user's `.Trashes/<other-uid>` subtree
(different owner — skipped, see §9).

## 3. Detection signals & algorithm

Trash contents are junk *by definition of location* — being under `~/.Trash` is the primary
evidence. The plugin still gathers metadata so the preview is honest and the engine can score:

1. For each resolved root (already `∩ allow-space − deny-list`, spec 13 §6), enumerate
   **top-level entries only** (`EnumerationOptions.maxDepth = 1` conceptually; `.topLevel`), so
   each Trash entry is one `Item` (a dragged folder is one Item spanning many `paths`).
2. For each entry gather `Evidence`: `allocatedSize` (recursive on-disk, CC-10),
   `mtime`/`birthtime`, and `whereFroms`/`quarantine` if present (context only). Record
   `Evidence.isDataless` — a dataless placeholder in Trash contributes **0** reclaim and is
   skipped (spec 16 §4.4).
3. Emit one `Finding` per entry: `risk = .medium`, proposed `SafetyScore ≈ 70` (regenerable=no,
   user-content=yes-but-discarded, recoverability=none→but user-intended). `rationale`:
   "In the Trash; emptying is permanent."
4. `FindingID = "trash:" + canonicalPath` (deterministic, DM-7). An aggregate "Empty entire
   Trash" grouping is a presentation concern (spec 25), not a separate Item.

Emptiness is honest: if a Trash root has no entries, the plugin yields nothing (idempotent —
running `cleaner` twice finds nothing, Principle 5).

## 4. Roots / paths with justification

| RootSpec | Resolves to (example) | Why safe to declare |
|---|---|---|
| `base: .home, glob: ".Trash/**"` | `/Users/alice/.Trash/*` | Inside the user home, not a protected content root (Art. 5 protects `~/Documents`, `~/Desktop`, … but the Trash is explicitly discardable). |
| `base: .volumes, glob: "*/.Trashes/<uid>/**"` | `/Volumes/USB/.Trashes/501/*` | Per-volume Trash for the *invoking* uid only; other uids' subtrees are outside this glob and rejected by ownership check (§9). Never the volume root itself. |

`.volumes` is a symbolic anchor for `/Volumes` (proposed `RootBase` addition — see Open
Questions). The engine still intersects with allow-space and refuses mount roots / system volumes
(spec 16 §7), so even a bad glob cannot escalate.

## 5. Risk & safety scoring

- **Baseline:** 🟡 medium for all Trash contents. Never 🟢 — see Art. 4.1 (loss is *not*
  invisible; the user could still want to restore). The plugin proposes `SafetyScore` in the
  50–84 band; the engine's `SafetyScorer` (spec 22) finalizes.
- **Escalation to 🔴:** an entry whose `Evidence` shows recent `mtime` (< 24 h) *and* Finder tags
  or `whereFroms` pointing at a `~/Documents`/`~/Desktop` origin → the plugin *lowers* the score
  (DM-2, never raises) toward the medium/dangerous boundary and appends
  `Evidence.finderTags`/`whereFroms` to the rationale, so a just-trashed tagged document is not
  swept silently under `--yes`.
- Because `Recoverability == .none` for the *tool* (Trash is the last buffer), DM-1 would force
  🔴 — but Trash is the documented exception (Art. 3 glossary: Trash *is* the recovery buffer), so
  the plugin proposes 🟡 with `recoverability = .none`.

## 6. Recoverability & staging

`Recoverability = .none` (Trash is already the recovery buffer; re-staging Trash into the tool's
staging would be redundant double-buffering and waste space). Disposition options:

- **Default `CleanDirective.proposedDisposition = .trash`** is *not* used here — the item is
  already in Trash. The plugin proposes **`.purge`** for confirmed items (permanent removal of
  Trash contents), which is the semantic of "Empty Trash." This is the one plugin where `.purge`
  is the natural disposition — but per spec 13 §10 gate ④, a plugin **cannot** force `.purge`; it
  proposes it and the engine requires the same explicit escalation as any purge (typed
  confirmation, DM-5). `RollbackHint = nil` (nothing to restore to).
- Under `--no-stage` is irrelevant here (there is no stage step); under interactive mode the user
  gets the standard "This is permanent" confirmation (Principle 1).

## 7. Dry-run / estimate

- `estimate`: sum `allocatedSize` over all Trash entries (recursive), `confidence = .exact` for
  local APFS volumes (no clones expected inside Trash typically) — downgraded to `.estimated` if
  any entry is flagged `isClone`/`isSparse`. Dataless entries contribute 0.
- `--dry-run`: lists each entry with its on-disk size and the aggregate; performs no removal
  (Principle 3 — same measurement code as the real run, CC-10).

## 8. Shell fallback & its safety

**N/A — fully native.** Uses `context.fs` for enumeration/sizing and the engine's disposition
mechanics (`FileManager.trashItem` is not needed since items are already in Trash; permanent
removal is the engine's fd-relative `unlinkat` recursive purge, spec 16 §11). No `context.process`.

## 9. Edge cases & false-positive mitigations

| Edge case | Mitigation |
|---|---|
| Another user's `.Trashes/<other-uid>` on a shared volume | Ownership check: skip entries whose `Evidence.ownerUID != invoking uid` with `SkipReason.permissionDenied`; glob is scoped to `<uid>` anyway. |
| Item currently being restored / in-use | `Evidence.isOpenOrLocked` → skip that entry (Art. 4.4, spec 16 §8). |
| Dataless/iCloud placeholder dragged to Trash | `isDataless` → 0 reclaim, skip (never trigger a download, spec 16 §4.4). |
| Symlink in Trash pointing outside | Remove only the link, never follow (`O_NOFOLLOW`, spec 16 §6); size counted is the link's own. |
| Trash on a network/read-only volume | Volume `isReadOnly`/`network` → report but refuse removal (spec 16 §7). |
| APFS "Put Back" metadata (`.DS_Store`/plist that maps original location) | Left untouched unless its own entry is selected; not required for our purge. |
| Very large Trash (millions of tiny files) | Streaming enumeration + bounded memory (spec 16 §2, §13); cancellation at dir boundaries. |

## 10. Test cases

Using injected `FileSystemReading`/`MetadataReading` fakes (spec 13 §6) — no real disk:

- **T1 empty Trash →** yields zero findings; idempotent.
- **T2 three files, one dir →** four Items; sizes = recursive `allocatedSize`; each 🟡.
- **T3 dataless placeholder →** skipped, `SkipReason.dataless`, 0 reclaim.
- **T4 recently-trashed tagged doc (mtime < 24 h, finderTags set) →** score lowered toward
  boundary, `whereFroms`/tags in rationale.
- **T5 foreign-uid entry on external `.Trashes` →** skipped with `permissionDenied`.
- **T6 symlink to `~/Documents/secret` →** only the link is an Item; target never sized/removed.
- **T7 `estimate` with a clone-flagged entry →** `confidence == .estimated`.
- **T8 clean proposes `.purge` →** engine requires typed confirmation (DM-5) before removal.

## 11. Config keys

`ConfigSlice` sub-tree `plugins.trash` (spec 24):

| Key | Type | Default | Meaning / validation |
|---|---|---|---|
| `enabled` | bool | `true` | Master toggle. |
| `includeExternalVolumes` | bool | `true` | Also scan per-volume `.Trashes`. |
| `minAgeDays` | int | `0` | Only surface entries trashed ≥ N days ago (≥ 0). Lets users keep a "just deleted" grace window. |
| `skipRecentlyTaggedHours` | int | `24` | Below this mtime age, tagged entries are down-scored, not pre-selected (≥ 0). |

## Open Questions

- **OQ-trash.1** Ratify a `.volumes` `RootBase` anchor (for `/Volumes`) in spec 13 §4, or require
  per-volume Trash to be handled by the scan engine's volume walk rather than a declared root?
  *Leaning: `.volumes` anchor, engine still guards mount roots.*
- **OQ-trash.2** Should "Empty Trash" ever offer `.stage` (double-buffer) for the extra-cautious,
  or is `.purge`-with-confirm the only sensible disposition given Trash is already a buffer?
  *Leaning: purge-only; a config flag `restageOnEmpty` deferred.*
- **OQ-trash.3** Do we honor a per-item "Put Back" location to warn when a to-be-purged item came
  from a protected root? *Leaning: yes as rationale enrichment, not as a hard block.*

## Dependencies

**Consumes:** 13 (`CleanerPlugin`, `CleanDirective`, `.purge` gate ④), 14 (`Item`/`Finding`/
`Disposition`/`Recoverability`/`Evidence`), 16 §4.4/§6/§7/§8/§10/§11 (dataless, symlink, volume,
in-use, Trash, purge mechanics), 00 Art. 3 (Trash = buffer), Art. 4.1 (medium under `--yes`),
Art. 4.4 (in-use), Art. 5 (protected roots), spec 24 (config). **Feeds:** 20 (executes the
proposed purge under confirmation), 25 (aggregate "Empty Trash" presentation).
