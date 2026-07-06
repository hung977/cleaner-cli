# plugin-large-files — Large / Old File Finder

> **Phase H · Plugin id:** `dev.cleaner.largefiles` · **Target release:** v1.0 ·
> **Depends on:** plugins/README, 13, 14, 16 (sizing, dataless), 19 (ranking), 00 Art. 4/5.

Surfaces the **largest (and optionally oldest) files** in user-designated search roots so the user
can reclaim space by hand. This is a pure **detector**, not an auto-cleaner: every file it reports
is *user content*, so all findings are **🔴 and always manual-select** — the tool ranks and
presents, the user decides. It never pre-selects, never acts under `--yes`, and never deletes on
its own judgment.

## 1. Identity

```swift
PluginManifest(
    id: "dev.cleaner.largefiles", name: "Large & Old Files", category: .largeOld,
    apiVersion: "1.4.0", pluginVersion: "1.0.0",
    declaredRoots: [],                           // operates ONLY on user-configured searchRoots (§4)
    defaultRisk: .dangerous,                     // 🔴 — all findings are user files
    capabilities: [.dryRun, .estimate, .rollback, .audit, .incremental],
    requiresElevation: false, trust: .firstParty)
```

Scope boundary: only user-provided `searchRoots`. It is a *reporting* plugin — it produces ranked
Findings but the disposition is always a deliberate, per-file user choice. It does not classify
anything as junk (it cannot know), so it never assigns 🟢/🟡; everything is 🔴 by construction.

## 2. What it targets

| Sub-item | What | Risk |
|---|---|---|
| Top-N largest files | Files above `minSize`, ranked by on-disk `allocatedSize` | 🔴 |
| Large + old files | Large files also untouched > `oldDays` (stronger "maybe forgotten" signal) | 🔴 |
| Large sparse/dataless (context) | Sparse files and iCloud placeholders, reported truthfully (0 or allocated-only reclaim) | informational |

It targets nothing automatically. It does **not** decide these files are removable — it only makes
the biggest space consumers *visible* (a common request: "what's eating my disk?"). Directories are
optionally rolled up (e.g. a huge `~/Downloads/VMs` folder) but the actionable unit is a file the
user picks.

## 3. Detection signals & algorithm (ranking, spec 19)

**Size + age are ranking signals, not safety signals** (there is no "safe" verdict — it's user
data). Per `searchRoot`:

1. Stream-enumerate (spec 16 §2). For each file record `allocatedSize` (on-disk, CC-10),
   `mtime`/`lastUsedDate`, `spotlightKind`, `whereFroms`.
2. Filter to `allocatedSize ≥ minSize` (default 100 MiB). Skip dataless placeholders for *reclaim*
   (they occupy ~0 blocks) but optionally list them for context (never faulted in, spec 16 §4.4).
3. Maintain a bounded **top-N heap** by `allocatedSize` (default N=100) so memory is O(N), not
   O(files) — never materialize the whole tree (spec 16 §13).
4. **Age enrichment:** flag files untouched > `oldDays` (default 180) via `lastUsedDate`/`mtime` as
   "large & old" — a stronger hint they may be forgotten (but still the user's call).
5. **Context evidence** for each: `spotlightKind` (e.g. "Disk Image", "Video"), `whereFroms`
   (download origin), Finder tags. This helps the user recognize the file without opening it
   (Principle 10: no content reading).
6. `FindingID = "large:" + canonicalPath` (deterministic, DM-7).

## 4. Roots / paths with justification

**No declared roots.** Scans only user-configured `searchRoots` (spec 18 target rules), engine-
intersected with allow-space minus deny-list (spec 16 §9). A user may point it at `~/Downloads`,
`~/Movies` (normally protected — allowed only if explicitly named + acknowledged, Art. 5), or an
external volume. Even then, findings are display/manual-only, so naming a protected root exposes
information, never an automatic deletion.

## 5. Risk & safety scoring

- **Every finding is 🔴**, `SafetyScore` capped low (≈ 20–40), `Recoverability = .instant` (staged
  if the user chooses to act). The 🔴 is *not* because acting is irreversible (staging makes it
  reversible) but because the tool has **no evidence the file is junk** — it is definitionally user
  content, so per Principle 1 it must never be pre-selected or auto-cleaned (Art. 4.1: 🔴 never
  auto-cleaned, requires typed confirmation).
- The plugin does not lower or contest the risk (there is nothing to lower it *with*); the engine's
  scorer keeps it 🔴. Ranking (`size`, `age`) affects *presentation order*, not risk.

## 6. Recoverability & staging

- If the user explicitly selects a file, `Disposition = .stage` (Principle 2), `Recoverability =
  .instant` (spec 21 one-command restore). This is the safety net that makes acting on a
  deliberately-chosen large file acceptable despite 🔴.
- `RollbackHint`: `restoreFromStaging` with the file's kind/origin so a mistaken removal is obvious
  and reversible within the retention window.
- Purge is only via the standard escalation (`--no-stage` + typed confirm, DM-5) — never a plugin
  default.

## 7. Dry-run / estimate

- `estimate`: sum `allocatedSize` of the **top-N** (or of user-selected) files (CC-10). Sparse
  files counted at allocated blocks; dataless at 0. `confidence = .exact` for regular files.
- `--dry-run` = the normal mode really: it *is* a report. Output is a ranked table (path, on-disk
  size, kind, last-used, origin) with the "large & old" subset flagged. Selecting is a separate,
  explicit user step.

## 8. Shell fallback & its safety

**N/A — fully native.** Sizing/metadata via `context.fs`/`context.metadata`; ranking in-process.
No external process; no content reads (Principle 10).

## 9. Edge cases & false-positive mitigations

| Edge case | Mitigation |
|---|---|
| Reporting a critical user file as "junk" | It is never called junk; 🔴, never pre-selected, manual only. |
| Sparse VM/disk images (huge logical, small on-disk) | Ranked by `allocatedSize`, not logical — honest (spec 16 §4.2); logical shown as context. |
| Dataless/iCloud files | 0 reclaim; listed for context only, never faulted/downloaded. |
| APFS clones (large logical, shared blocks) | Reclaim reflects unshared blocks only; flagged "shares blocks" (DM-8). |
| Bundles/packages (`.photoslibrary`, `.app`) | Optionally rolled up as one item (`treatBundlesAsOpaque`); never partially deleted. |
| Symlinks to large targets | Not followed; the link's own size, not the target's. |
| File in use (VM running) | `isOpenOrLocked` flagged so the user isn't offered to move a live disk image. |
| Protected roots named by user | Allowed only with acknowledgment; still 🔴/manual. |

## 10. Test cases

- **T1 root with files 50/150/900 MiB, minSize 100 MiB** → 150 & 900 reported, 50 excluded; ranked
  by on-disk size.
- **T2 sparse 40 GiB image, 2 GiB allocated** → ranked by 2 GiB; logical shown as context.
- **T3 dataless 8 GiB placeholder** → listed context-only, 0 reclaim, not downloaded.
- **T4 under `--yes`** → reported, nothing actioned (🔴).
- **T5 large file untouched 300d** → flagged "large & old."
- **T6 user selects a file** → staged, `.instant` recoverability, rollback works.
- **T7 clone-backed large file** → reclaim shows unshared blocks only.
- **T8 top-N heap with 1M files** → memory O(N), correct top-N.

## 11. Config keys

`plugins.largefiles`:

| Key | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | bool | `true` | Master toggle. |
| `searchRoots` | list<path> | `[]` | **Required** roots (user target rules). Empty ⇒ no findings. |
| `minSize` | int (bytes) | `104857600` | Minimum on-disk size to report (100 MiB). |
| `topN` | int | `100` | Max files to surface (heap size). |
| `oldDays` | int | `180` | Untouched-longer-than flag for "large & old." |
| `includeDataless` | bool | `true` | List dataless files for context (0 reclaim). |
| `treatBundlesAsOpaque` | bool | `true` | Roll bundles up as single items. |
| `rollUpDirectories` | bool | `false` | Also report directory subtotals, not just files. |

## Open Questions

- **OQ-large.1** Should directory roll-ups ("this folder holds 40 GB") be first-class Findings or a
  separate view derived from file findings? *Leaning: derived view for v1; a directory Finding only
  if the whole dir is user-selected.*
- **OQ-large.2** Auto-discover obvious large-file locations (`~/Downloads`, `~/Movies`) with an
  acknowledgment, or always require explicit `searchRoots`? *Leaning: suggest common roots in the
  TUI but require the user to confirm each (they are protected content roots).*
- **OQ-large.3** Merge with the duplicate finder into a single "space explorer" surface, or keep
  distinct plugins? *Leaning: distinct plugins, shared TUI "explore" view (spec 25).*
- **OQ-large.4** Old-file detection reliability given `atime`/`relatime` — rely on
  `kMDItemLastUsedDate` only? *Leaning: `lastUsedDate` primary, `mtime` fallback, `atime` as a weak
  lower-bound (spec 14 OQ-14.4).*

## Dependencies

**Consumes:** 13 (contract; detector-only), 14 (types; 🔴/manual, DM-8 shared blocks), 16
§2/§4.2/§4.4/§6/§13 (streaming, sparse, dataless, symlink, memory), 18 (searchRoots as target
rules), 19 (size/age ranking), 00 Art. 1 (safety), Art. 4.1 (🔴 never auto), Art. 5. **Feeds:** 20
(stages user-selected files), 21 (instant rollback), 22 (keeps 🔴), 25 (ranked "explore" table).
