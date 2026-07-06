# plugin-homebrew — Homebrew

> **Phase H · Plugin id:** `dev.cleaner.homebrew` · **Target release:** v0.5 ·
> **Depends on:** plugins/README, 13, 14, 16, 19, 00 Art. 4/5.

Cleans Homebrew's reclaimable state: old formula versions left after upgrades, the download
cache, and (surfaced, not auto) orphan/leaf packages. Native cache-path analysis is primary; the
`brew` CLI is used **read-only** (dry-run) to corroborate what Homebrew itself considers safe.

## 1. Identity

```swift
PluginManifest(
    id: "dev.cleaner.homebrew", name: "Homebrew", category: .developer,
    apiVersion: "1.4.0", pluginVersion: "1.0.0",
    declaredRoots: [
        RootSpec(base: .libraryCaches, glob: "Homebrew/**"),        // ~/Library/Caches/Homebrew (downloads)
        RootSpec(base: .brewCellar,    glob: "*/*/**"),             // <prefix>/Cellar/<formula>/<version>
        RootSpec(base: .brewCache,     glob: "downloads/**"),       // <prefix>/var/... / HOMEBREW_CACHE
    ],
    defaultRisk: .safe,                          // cache + superseded versions are 🟢; leaves are 🟡
    capabilities: [.dryRun, .estimate, .rollback, .audit],
    requiresElevation: false, trust: .firstParty)
```

Scope boundary: only Homebrew-owned cache/cellar paths. It never removes the *current* linked
version of a formula, never touches `/opt/homebrew`/`/usr/local` binaries in active use, and never
uninstalls a package that other packages depend on.

## 2. What it targets

| Sub-item | Path/concept | Why junk | Risk |
|---|---|---|---|
| Download cache | `~/Library/Caches/Homebrew/downloads/*`, `HOMEBREW_CACHE` | Bottle/source tarballs already installed; re-downloadable. | 🟢 |
| Old formula versions | `Cellar/<f>/<oldver>` when a newer linked version exists | Superseded by upgrade; not linked. | 🟢 |
| Old cask artifacts | `Caches/Homebrew/Cask/*` | Installer images already applied. | 🟢 |
| Orphan/leaf packages | formulae installed as deps, now unused | Reclaimable but user may want them. | 🟡 |

Does **not** target: the currently-linked version of any formula, `HOMEBREW_PREFIX/bin` symlinks,
tap git repos, or a formula another installed formula depends on.

## 3. Detection signals & algorithm

**Native path structure is authoritative; `brew` dry-run corroborates.** Homebrew's Cellar layout
is deterministic: `Cellar/<formula>/<version>/`. Algorithm:

1. Resolve `HOMEBREW_PREFIX` (native: check `/opt/homebrew` on Apple Silicon, `/usr/local` on
   Intel; or read `HOMEBREW_PREFIX` env) and `HOMEBREW_CACHE`.
2. **Old versions:** for each `Cellar/<formula>/`, list version subdirs. The *linked* version is
   the target of `HOMEBREW_PREFIX/opt/<formula>` (a symlink — read it *without following out of
   root*, spec 16 §6). Every version dir that is **not** the linked target and older by semver →
   🟢 removable (`Evidence`: not-linked, superseded). The linked version is never a Finding.
3. **Download cache:** every file under the downloads cache whose corresponding formula is
   installed → 🟢. `Evidence.whereFroms`/naming (`<formula>-<ver>.bottle.tar.gz`) confirms it is a
   re-downloadable artifact (spec 16 §5).
4. **Leaves/orphans:** requires dependency graph → use the read-only `brew` probe (§8):
   `brew leaves --installed-on-request` vs `brew leaves` to find dependency-only leaves.
   Surfaced 🟡, never pre-selected (uninstalling a package changes system state).
5. `FindingID = "brew:<subcategory>:<canonicalPath-or-formula>"` (deterministic, DM-7).

## 4. Roots / paths with justification

| RootSpec | Resolves to | Justification |
|---|---|---|
| `.libraryCaches / Homebrew/**` | `~/Library/Caches/Homebrew/downloads/…` | The per-user download cache; pure re-downloadable artifacts. |
| `.brewCellar / */*/**` | `/opt/homebrew/Cellar/wget/1.21/…` | Cellar versions; only *non-linked* ones become Findings (§3). `.brewCellar` = resolved `HOMEBREW_PREFIX/Cellar`. |
| `.brewCache / downloads/**` | resolved `HOMEBREW_CACHE/downloads` | Alternate cache location when `HOMEBREW_CACHE` is set. |

`.brewCellar`/`.brewCache` are **proposed `RootBase` anchors resolved from Homebrew's own
environment** (not hard-coded absolutes), so the engine can still verify they land in allow-space
(they are user-writable prefixes, not `/System`). If the prefix resolves under a protected root,
the engine drops it (spec 16 §9). See Open Questions.

## 5. Risk & safety scoring

| Sub-item | Risk | Score | Notes |
|---|---|---|---|
| Download cache | 🟢 92 | re-downloadable, not linked | pre-selected |
| Old non-linked version | 🟢 90 | superseded, unlinked | pre-selected |
| Cask cache | 🟢 90 | installer already applied | |
| Leaf/orphan package | 🟡 60 | uninstall changes state | never pre-selected |

Scores lowered with evidence only (DM-2). Leaves stay 🟡 because uninstalling is a state change
the user may not want (they might use the tool directly), and recoverability is `.manual`
(`brew install` again).

## 6. Recoverability & staging

- `Disposition = .stage` for cache files and old version dirs (Principle 2) — same-volume
  `renameat`, cheap and reversible.
- **Leaves/orphans are different:** uninstalling a package is a `brew uninstall`, not a file move.
  For v1, leaf *uninstalls* are proposed as an **audited `brew` command** (like Docker's model,
  §8) gated behind confirmation, `Recoverability = .manual`. The file-based sub-items use normal
  staging.
- `RollbackHint`: for staged versions, `restoreFromStaging` note "restoring an old Cellar version
  does not re-link it; run `brew link` if needed."

## 7. Dry-run / estimate

- `estimate`: `allocatedSize` sum of cache files + non-linked version dirs (CC-10),
  `confidence = .exact`.
- `--dry-run` also runs `brew cleanup -n` (§8) and reconciles the tool's own finding with
  Homebrew's projection, surfacing any delta honestly (Principle 3).

## 8. Shell fallback & its safety

Native path analysis covers cache + old versions; `brew` is used **read-only** for the dependency
graph and to corroborate:

**Read-only (allowed):**
```
["brew","--prefix"]                     # resolve HOMEBREW_PREFIX (5s)
["brew","--cache"]                      # resolve HOMEBREW_CACHE
["brew","cleanup","-n"]                 # DRY-RUN projection of what brew would remove
["brew","leaves","--installed-on-request"]   # user-requested formulae
["brew","autoremove","-n"]              # DRY-RUN orphan list
["brew","list","--versions"]            # installed versions
```
**Mutating (allow-listed, opt-in, confirmed):**
```
["brew","cleanup","<formula>"]          # scoped cleanup of one formula's old bits
["brew","autoremove"]                   # remove orphans — only if user opted in, typed confirm
["brew","uninstall","<leaf>"]           # per-leaf, confirmed
```

**Safety rails:**
- Prefer native staging for cache/version files; only use `brew cleanup`/`autoremove` when the
  user explicitly enables `useBrewCleanup` (so the tool's staging remains the reversible default).
- Never `brew cleanup --prune=all` unscoped by default; never `brew uninstall` a non-leaf.
- Every mutating argv is engine-allow-listed (spec 13 gate ④); anything else → exit 8.
- `brew` runs as the invoking user (Homebrew refuses root); no elevation.

Justification: Homebrew's dependency graph and "what is safe to clean" logic have no native API;
`brew`'s dry-run flags are the documented safe interface.

## 9. Edge cases & false-positive mitigations

| Edge case | Mitigation |
|---|---|
| Linked (current) version swept | Never a Finding; only non-linked older versions (via `opt/<f>` symlink target). |
| Pinned formula (`brew pin`) | `brew list --pinned` (read-only) excludes pinned versions from removal. |
| Formula used directly by the user but installed as a dep | Leaves are 🟡, never pre-selected; user decides. |
| Multi-user / shared prefix | Operates on the resolved prefix; ownership checks (spec 16). |
| Cache for a formula no longer installed | Still 🟢 (pure download cache), safe to remove. |
| `HOMEBREW_NO_CLEANUP` user intent | Respect a config `respectBrewEnv` that defers to Homebrew's own settings. |
| Cellar version dir currently executing a binary | `isOpenOrLocked` → skip (spec 16 §8). |

## 10. Test cases

- **T1 formula with linked 1.21 + old 1.20** → 1.20 is 🟢 Finding, 1.21 excluded.
- **T2 download cache for installed formula** → 🟢.
- **T3 pinned formula old version** → excluded.
- **T4 leaf package (dep-only, unused)** → 🟡, not pre-selected.
- **T5 brew dry-run projects extra removals** → delta surfaced honestly.
- **T6 plugin proposes `brew cleanup --prune=all`** → engine rejects (not allow-listed).
- **T7 prefix resolves under a protected root** → root dropped, no findings there.
- **T8 estimate** → allocated sum, exact confidence.

## 11. Config keys

`plugins.homebrew`:

| Key | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | bool | `true` | Master toggle. |
| `cleanDownloadCache` | bool | `true` | Remove cached downloads. |
| `removeOldVersions` | bool | `true` | Remove non-linked superseded versions. |
| `surfaceLeaves` | bool | `true` | Show orphan/leaf packages (🟡). |
| `autoremoveOrphans` | bool | `false` | Allow `brew autoremove` (confirmed). |
| `useBrewCleanup` | bool | `false` | Use `brew cleanup` instead of native staging. |
| `respectBrewEnv` | bool | `true` | Honor `HOMEBREW_NO_CLEANUP`/pins. |

## Open Questions

- **OQ-brew.1** Ratify `.brewCellar`/`.brewCache` anchors resolved from Homebrew env in spec 13
  §4, or treat the whole prefix as a user-target rule the user adds? *Leaning: env-resolved
  anchors, engine-verified against allow-space.*
- **OQ-brew.2** Should old-version removal be native staging (reversible) or delegate to
  `brew cleanup` (canonical but not reversible)? *Leaning: native staging default; `brew cleanup`
  opt-in.*
- **OQ-brew.3** Handle Homebrew Cask app removal (whole `.app`s) here or refuse (Art. 5 protects
  `.app`)? *Leaning: refuse cask app uninstall in v1; only cask *caches*.*

## Dependencies

**Consumes:** 13 (contract, `process` fallback, allow-list gate), 14 (types), 16 §5/§6/§8/§9
(whereFroms, symlink target read, in-use, canonicalization), 19 (version comparison), 00 Art. 4/5.
**Feeds:** 20 (stages files / runs allow-listed brew argv), 22 (scores), 25 (grouping).
