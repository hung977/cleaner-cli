# plugin-node — Node.js ecosystem

> **Phase H · Plugin id:** `dev.cleaner.node` · **Target release:** MVP ·
> **Depends on:** plugins/README, 13, 14, 16, 19 (staleness), 00 Art. 4/5.

Cleans the multi-package-manager Node ecosystem: npm, yarn (classic + berry), pnpm, and corepack
caches, plus **stale `node_modules`** in dormant projects — often the single largest source of
reclaimable developer space (thousands of tiny files per project). Package-manager caches are 🟢;
`node_modules` is 🟡 (re-installable, but re-install costs time and needs network).

## 1. Identity

```swift
PluginManifest(
    id: "dev.cleaner.node", name: "Node / npm / yarn / pnpm", category: .developer,
    apiVersion: "1.4.0", pluginVersion: "1.0.0",
    declaredRoots: [
        RootSpec(base: .home,          glob: ".npm/_cacache/**"),        // npm cache
        RootSpec(base: .home,          glob: ".cache/yarn/**"),          // yarn classic (older)
        RootSpec(base: .libraryCaches, glob: "Yarn/**"),                 // yarn (~/Library/Caches/Yarn)
        RootSpec(base: .home,          glob: ".yarn/berry/cache/**"),    // yarn berry global cache
        RootSpec(base: .libraryCaches, glob: "pnpm/**"),                 // pnpm store (~/Library/Caches/pnpm)
        RootSpec(base: .home,          glob: ".local/share/pnpm/store/**"),// pnpm content-addressable store
        RootSpec(base: .home,          glob: ".node-gyp/**"),            // node-gyp headers cache
        // node_modules are discovered under user project roots via the scan engine, see §3.3
    ],
    defaultRisk: .safe,                          // caches 🟢; node_modules escalates to 🟡
    capabilities: [.dryRun, .estimate, .rollback, .audit, .incremental],
    requiresElevation: false, trust: .firstParty)
```

Scope boundary: package-manager caches (always safe) and `node_modules` directories **only inside
user-designated project search roots** the user opts into (default: none auto-scanned outside
declared caches — `node_modules` under `~/Documents` etc. is protected, Art. 5). It never removes
a `node_modules` for a project with uncommitted work or recent activity, and never global npm
*packages* (`-g` installs are tools the user relies on).

## 2. What it targets

| Sub-item | Path | Why junk | Risk |
|---|---|---|---|
| npm cache | `~/.npm/_cacache` | Content-addressable download cache; re-fetchable. | 🟢 |
| yarn cache | `~/Library/Caches/Yarn`, `~/.cache/yarn`, `~/.yarn/berry/cache` | Re-fetchable. | 🟢 |
| pnpm store | `~/Library/Caches/pnpm`, `~/.local/share/pnpm/store` | Content-addressable; re-fetchable (**hardlink-aware**, §9). | 🟢 |
| node-gyp cache | `~/.node-gyp` | Downloaded headers; re-fetchable. | 🟢 |
| Stale `node_modules` | `<project>/node_modules` in dormant projects | Rebuildable via `npm/yarn/pnpm install`; costs time+network. | 🟡 |

Does **not** target: global `-g` packages, a project's source, `package.json`/lockfiles,
`node_modules` of active projects, or `.pnp.cjs`/Plug'n'Play state.

## 3. Detection signals & algorithm

### 3.1 Caches (🟢)

Each cache root is a pure download cache by construction (content-addressable dirs like
`_cacache`, `v3`, `store/v3`). Enumerate, size (`allocatedSize`), emit 🟢 Findings. No staleness
needed — these are always safe to clear. `Evidence.whereFroms`/naming corroborates re-downloadable.

### 3.2 Package-manager detection

Resolve real cache locations without hard-coding via the read-only probe (§8): `npm config get
cache`, `yarn cache dir`, `pnpm store path`. Fall back to the declared defaults if the tool is
absent.

### 3.3 Stale `node_modules` (🟡 — the valuable part)

`node_modules` sits **inside project directories**, which live under user content roots (protected,
Art. 5). So the plugin does **not** wander the home dir; instead it operates on **project search
roots the user configures** (`plugins.node.projectRoots`, e.g. `~/Developer`, `~/src`). Within
those:

1. Enumerate directories named `node_modules` (skip nested `node_modules/**/node_modules`; the
   top-level one owns the whole subtree as one grouped `Item`, spec 14 §4.8).
2. Locate the sibling project markers: `package.json`, lockfile (`package-lock.json`/`yarn.lock`/
   `pnpm-lock.yaml`). No `package.json` sibling → not a real project → skip (avoid false positive).
3. **Staleness (spec 19):** the strongest safety signal is *project* activity, not the
   `node_modules` mtime (install touches it). Use the **newest mtime among source files** near the
   project root (excluding `node_modules`) and/or the lockfile mtime, and `lastUsedDate`. A project
   whose source is untouched > `staleDays` (default 90) → `node_modules` is 🟡 removable.
4. **Active-work guard:** if a `.git` sibling shows recent activity, or any file under the project
   (excluding `node_modules`) is `isOpenOrLocked`, or mtime < `protectActiveDays` (default 14) →
   **not** removable (skip). Never remove `node_modules` for a project you touched recently.
5. `FindingID = "node:modules:<canonicalProjectPath>"` (deterministic, DM-7).

## 4. Roots / paths with justification

| RootSpec | Resolves to | Justification |
|---|---|---|
| `.home / .npm/_cacache/**` | `~/.npm/_cacache` | npm's content-addressable cache; not user data. |
| `.libraryCaches / pnpm/**`, `.home / .local/share/pnpm/store/**` | pnpm store | Content-addressable store; **hardlinked into node_modules** (§9). |
| `.home / .cache/yarn/**`, `.libraryCaches / Yarn/**`, `.home / .yarn/berry/cache/**` | yarn caches | Re-fetchable. |
| `.home / .node-gyp/**` | `~/.node-gyp` | Header cache. |
| *project roots* (config `projectRoots`) | e.g. `~/Developer/**/node_modules` | Only user-opted search roots; each `node_modules` confirmed by a sibling `package.json`. Not auto-scanned. |

`node_modules` under protected roots (`~/Documents`, `~/Desktop`) is unreachable unless the user
explicitly adds a target rule (spec 18); the engine enforces this (spec 16 §9).

## 5. Risk & safety scoring

| Sub-item | Risk | Score | Notes |
|---|---|---|---|
| npm/yarn/pnpm caches | 🟢 92 | pure cache | pre-selected |
| node-gyp cache | 🟢 90 | header cache | |
| Stale node_modules (dormant) | 🟡 70 | re-installable, network+time cost | not pre-selected |
| node_modules (semi-recent) | 🟡 55 | higher re-cost / possible active | shown, low priority |

`Recoverability`: caches `.manual`; `node_modules` `.manual` (`install` again, needs network — so
`.hard` if the lockfile references private/removed registries, which the plugin flags). Scores only
lowered with evidence (DM-2).

## 6. Recoverability & staging

- `Disposition = .stage` for all (Principle 2). Staging a `node_modules` (hundreds of thousands of
  files) uses same-volume `renameat` on the top dir — atomic and instant regardless of file count
  (spec 16 §11), a key reason we group the whole tree as one Item.
- `RollbackHint`: `restoreFromStaging`, note "or run `npm/yarn/pnpm install` to regenerate."
- pnpm hardlink caveat surfaced in the hint (§9).

## 7. Dry-run / estimate

- `estimate`: `allocatedSize` per cache/`node_modules`. **pnpm hardlink correction is essential**
  (§9): a pnpm `node_modules` mostly hardlinks into the global store, so removing it frees far less
  than its logical size — `sharedExcluded` reflects this and `confidence = .estimated` when the
  store is on the same volume.
- `--dry-run` groups caches vs. node_modules, shows the top-N largest node_modules by *on-disk*
  (not logical) size so the estimate is honest (Principle 3).

## 8. Shell fallback & its safety

Read-only probes to resolve real cache paths and package-manager presence (native FS does the
work; probes just locate):
```
["npm","config","get","cache"]     # 5s
["yarn","cache","dir"]             # yarn classic
["pnpm","store","path"]            # pnpm store location
["corepack","--version"]           # presence
```
All read-only; failure → declared defaults (§4). **No mutating package-manager commands** — the
tool never runs `npm cache clean`/`pnpm store prune`; it stages files itself so the action is
reversible (Principle 2) and consistent with the engine's safety funnel. Justification: cache
*locations* are configurable and only the CLI reports them; clearing is done natively.

## 9. Edge cases & false-positive mitigations

| Edge case | Mitigation |
|---|---|
| **pnpm hardlinks** node_modules→store | `(volumeID, inode)` clustering (spec 16 §6); reclaim credited only for unshared blocks; hint warns removing node_modules alone frees little if the store remains. |
| Active project swept | Source-activity staleness + `protectActiveDays` + `isOpenOrLocked` + `.git` recency guards (§3.3). |
| Monorepo with many nested node_modules | Top-level `node_modules` owns the subtree; nested ones not separately actioned. |
| Yarn PnP project (no node_modules) | Nothing to remove; caches still handled. |
| Global `-g` tools | Never targeted (only caches + project node_modules). |
| node_modules on external/network volume | Volume-aware staging; refuse read-only volumes (spec 16 §7). |
| Missing package.json sibling | Not a project → skip (avoid deleting a coincidentally-named dir). |
| Corepack-managed pnpm/yarn shims | Probe corepack; treat its cache as re-fetchable. |

## 10. Test cases

- **T1 `~/.npm/_cacache` present** → 🟢, pre-selected.
- **T2 project source untouched 200d, has package.json** → node_modules 🟡, not pre-selected.
- **T3 project touched yesterday** → node_modules skipped (active guard).
- **T4 pnpm node_modules hardlinked to store** → estimate excludes shared blocks, `.estimated`.
- **T5 dir named node_modules with no package.json sibling** → skipped.
- **T6 nested node_modules in monorepo** → only top-level Item.
- **T7 npm probe fails** → declared default cache path used.
- **T8 node_modules under `~/Documents`** → unreachable (protected) unless user target rule added.

## 11. Config keys

`plugins.node`:

| Key | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | bool | `true` | Master toggle. |
| `cleanNpmCache` / `cleanYarnCache` / `cleanPnpmStore` | bool | `true` | Per-manager cache toggles. |
| `nodeModules.enabled` | bool | `true` | Enable stale node_modules detection. |
| `nodeModules.projectRoots` | list<path> | `[]` | Search roots for projects (must be user-owned, non-protected). |
| `nodeModules.staleDays` | int | `90` | Source-inactivity age to call node_modules stale. |
| `nodeModules.protectActiveDays` | int | `14` | Below this, never remove. |
| `usePmProbes` | bool | `true` | Allow read-only `npm/yarn/pnpm` path probes. |

## Open Questions

- **OQ-node.1** Should pnpm store *pruning* (removing store entries no referenced by any
  node_modules) be offered, given hardlink semantics make it the real reclaim? *Leaning: yes as a
  🟡 sub-action once we can enumerate references safely.*
- **OQ-node.2** Auto-discover project roots (scan `~` shallowly for `.git`+`package.json`) vs.
  require explicit `projectRoots`? *Leaning: explicit for v1 (avoid touching protected roots);
  guided auto-discovery later.*
- **OQ-node.3** Detect private/removed-registry lockfiles to escalate node_modules to `.hard`
  recoverability? *Leaning: parse lockfile registry hosts; flag when non-public.*

## Dependencies

**Consumes:** 13 (contract, probes), 14 (grouped `Item` for node_modules, types), 16 §6/§7/§8/§9
(hardlinks, volume, in-use, canonicalization), 18 (user target rules for protected-root projects),
19 (staleness), 00 Art. 4/5. **Feeds:** 20 (rename-stages node_modules atomically), 22 (scores),
25 (grouping).
