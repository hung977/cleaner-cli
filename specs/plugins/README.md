# Plugin Catalog & Spec Template

> **Phase H · Depends on:** 00-constitution (Art. 3–5 glossary/safety/protected paths, Art. 7 exit
> codes, CC-8), 13-plugin-architecture (`CleanerPlugin`, `PluginManifest`, `PluginContext`,
> `CleanDirective`, `RootSpec`), 14-domain-model (`Item`, `Finding`, `RiskLevel`, `SafetyScore`,
> `Recoverability`, `Disposition`, `Evidence`), 16-filesystem-strategy (enumeration, sizing,
> metadata), 19-detection-algorithms (staleness/dedup) ·
> **Depended on by:** every `plugins/plugin-*.md`, 17 (scan), 20 (cleanup), 22 (safety).

## 1. Purpose

This document is the **index of every v1 cleaning plugin** and the **normative template** each
per-plugin spec (`plugins/plugin-*.md`) follows. It exists so the plugin suite is legible as a
whole: what ships, in which release, at what default risk, via native API or shell fallback, and
how recoverable each category is. It does **not** redefine the plugin contract (that is spec 13)
or the domain types (spec 14); it *applies* them.

Governing rule (Constitution Art. 4.4, spec 13 §2): **plugins propose, the engine disposes.**
Every risk level, safety score, and recoverability in every plugin spec is a *proposal* that the
engine's `SafetyScorer` (spec 22), `RuleEngine` (spec 18), and `ProtectedPathGuard` (spec 16 §9)
re-validate. A plugin may present a *stricter* (higher) risk with evidence, never a looser one
(DM-3). No plugin ever calls `unlink`/`rename`/`FileManager` — deletion happens only in the engine.

> **How to read the risk grades in these plugin specs (v0.6 as-built).** The shipped `cleaner` is a
> line-based CLI with **no user-facing risk tiers** — no 🟢🟡🔴 icons, no Safe/Medium/Dangerous
> display, no risk-based pre-selection, and no typed-confirm-for-dangerous gate. User selection is
> `Clean all / select each (y/N) / cancel` (or `--yes`), and safety comes from the staging
> quarantine (every action is reversible via `cleaner undo`) plus the engine-enforced
> protected-path guard — not from risk grading (see specs 14 §1, 22 §1). The `defaultRisk` /
> `SafetyScore` / "pre-selected" / "typed confirm" narratives below are therefore **vestigial
> internal-scorer design**: `RiskLevel`/`SafetyScore` survive as internal metadata and inform each
> plugin's *conservative defaults* (what a plugin offers vs. holds back — e.g. Archives, named
> Docker volumes, and user-content files are excluded from the default offer), but they no longer
> drive any user-facing selection, gating, or display. Read the per-category tables as
> classification rationale (what is rebuildable vs. what may be user data), not as a shipped UI.

## 2. Catalog of v1 plugins

Columns:

- **id** — stable reverse-DNS `PluginID`.
- **cat** — `Category` bucket used for TUI grouping (spec 09/25).
- **Cleans** — the junk category, one line.
- **Risk** — the plugin's *default* baseline `defaultRisk` (🟢 safe / 🟡 medium / 🔴 dangerous,
  Art. 4.1). Per-Finding risk varies by sub-item and evidence; the table shows the *baseline* and
  the *worst-case* sub-item in parentheses.
- **Recov.** — dominant `Recoverability` (instant = staged one-command rollback; manual =
  re-downloadable/re-buildable; hard = external source needed; none = irreversible).
- **API** — native-first mechanism, and shell fallback if any (Constitution Principle 4, CC-8).
- **Ver.** — target release (MVP → v0.5 → v1.0).

### 2.1 Apple / Xcode developer

| id | cat | Cleans | Risk | Recov. | API / fallback | Ver. |
|---|---|---|---|---|---|---|
| `dev.cleaner.xcode` | developer | DerivedData, Archives, iOS DeviceSupport, module/SwiftPM caches, old simulators-index | 🟢 (🔴 Archives) | manual (🔴 hard for Archives) | native FS + metadata; `xcrun`/`xcodebuild -version` probe (read-only) | MVP |
| `dev.cleaner.simulator` | developer | CoreSimulator: unavailable/old runtimes, orphaned device data, per-device caches | 🟡 (🔴 booted/has-data) | manual | native path analysis; `xcrun simctl list -j` fallback | v0.5 |

### 2.2 Language ecosystems

| id | cat | Cleans | Risk | Recov. | API / fallback | Ver. |
|---|---|---|---|---|---|---|
| `dev.cleaner.homebrew` | developer | old formula versions, download cache, orphan/leaf packages | 🟢 (🟡 leaves) | manual | native cache path; `brew --cache`/`brew cleanup -n`/`brew autoremove -n` (dry-run only) | v0.5 |
| `dev.cleaner.node` | developer | npm/yarn/pnpm/corepack caches; stale `node_modules` in dormant projects | 🟢 (🟡 node_modules) | manual | native FS + metadata; `npm config get cache` probe | MVP |
| `dev.cleaner.python` | developer | pip/poetry/conda caches, `__pycache__`/`*.pyc`, detected virtualenvs | 🟢 (🔴 venvs) | manual (🔴 hard for venvs) | native FS + marker parsing; `python -m site` probe | v0.5 |
| `dev.cleaner.devcache` | developer | Go build/mod cache, Rust `target/`+cargo registry, Gradle/Maven, CocoaPods, Carthage, SwiftPM | 🟢 (🟡 project build dirs) | manual | native FS + metadata; tool `--version` probes | v1.0 |

### 2.3 Containers

| id | cat | Cleans | Risk | Recov. | API / fallback | Ver. |
|---|---|---|---|---|---|---|
| `dev.cleaner.docker` | containers | dangling images, stopped containers, build cache, unused (anonymous) volumes | 🟡 (🔴 volumes) | hard (🔴 none for pruned data) | **shell-only** (no native API): `docker system df --format json` + scoped `docker … prune` | v0.5 |

### 2.4 Browsers

| id | cat | Cleans | Risk | Recov. | API / fallback | Ver. |
|---|---|---|---|---|---|---|
| `dev.cleaner.browser` | browser | Chrome & Safari **cache only** — never cookies/history/passwords/bookmarks | 🟡 | manual | native FS + profile parsing; no shell | MVP |

### 2.5 System

| id | cat | Cleans | Risk | Recov. | API / fallback | Ver. |
|---|---|---|---|---|---|---|
| `dev.cleaner.trash` | system | the macOS Trash (`~/.Trash`, per-volume `.Trashes`) | 🟡 | none (Trash *is* the buffer) → `.trash`/`.purge` | native `FileManager`/`NSWorkspace` | MVP |
| `dev.cleaner.logs` | system | `~/Library/Logs`, crash reports (`DiagnosticReports`), rotated app logs | 🟢 (🟡 recent crashes) | manual | native FS + metadata; no shell | MVP |
| `dev.cleaner.duplicates` | duplicates | multi-stage duplicate finder (clone/hardlink-aware) — **detector, never auto-selects** | 🟡 | instant (staged) | native FS + hashing (spec 19); no shell | v1.0 |
| `dev.cleaner.largefiles` | large-old | Large/old-file finder — presents top-N; **detector only, user data** | 🔴 (always manual select) | instant (staged) | native FS + metadata; no shell | v1.0 |

### 2.6 Registration

The compile-time registry (spec 13 §5, `BuiltinPlugins.all`) contains exactly the ids above.
Adding a plugin is a rebuild (CC-8); no plugin edits the engine or another plugin (Principle 7).
`TrustLevel` is `.firstParty` for all v1 plugins.

## 3. PLUGIN SPEC TEMPLATE (normative)

Every `plugins/plugin-*.md` MUST contain the following sections **in this order**, then close with
`## Open Questions` and `## Dependencies` (Constitution Art. 11, suite convention). A section that
does not apply states "N/A" with a one-line reason rather than being omitted (no silent gaps).

1. **Identity** — the `PluginManifest` block: `id`, `name`, `category`, `apiVersion`,
   `pluginVersion`, `defaultRisk`, `capabilities`, `requiresElevation`, `trust`, target release.
   One paragraph on what the plugin is and its scope boundary.

2. **What it targets** — the concrete sub-categories of junk, each with a one-line "why it is
   junk / how it regenerates." Explicitly list what it **does not** touch (the safety boundary).

3. **Detection signals & algorithm** — how findings are produced. MUST specify the *metadata
   signals* (`Evidence` fields from spec 14 §4.7 / spec 16) that confirm safety, not just
   hard-coded paths. Give the per-sub-item scan procedure, staleness thresholds, and how
   `FindingID` is derived (deterministic, DM-7).

4. **Roots / paths with justification** — the `declaredRoots` as `RootSpec`s (symbolic anchor +
   glob, spec 13 §4). For each root: the resolved example path, *why it is safe to declare*, and
   which anchor of the allow-space it lands in. Never absolute strings in the manifest.

5. **Risk & safety scoring** — per-sub-item `RiskLevel` and the *proposed* `SafetyScore` inputs
   (regenerability, user-content presence, recency, orphan state). State the mapping to the
   engine's Art. 4.2 bands and where the plugin *lowers* a score with evidence (never raises,
   DM-2). Note anything that forces 🔴 (e.g. `Recoverability.none`, DM-1).

6. **Recoverability & staging** — the `Recoverability` per sub-item, the `Disposition` proposed in
   `CleanDirective`, and the `RollbackHint`. Default is `.stage` (Principle 2); justify any
   deviation (only `TrashPlugin` may propose `.trash`).

7. **Dry-run / estimate** — how `estimate` computes reclaim from `allocatedSize` (CC-10) and what
   `--dry-run` shows. Confidence level (`exact`/`estimated`) and why.

8. **Shell fallback (if any) & its safety** — if the plugin uses `context.process`: the exact
   argv (arg-escaped, no shell string, spec 36), timeout, why no native API exists (Principle 4
   ADR requirement), what is parsed, and the safety rails (read-only probes vs. mutating commands,
   never mutate by default). State "N/A — fully native" if none.

9. **Edge cases & false-positive mitigations** — enumerated traps (active projects, in-use files,
   dataless/iCloud, symlinks, multi-user, running tools) and how each is mitigated.

10. **Test cases** — concrete Swift-Testing scenarios (fixtures + expected findings/risks), using
    injected fakes (spec 13 §6) — a plugin unit test never touches a real disk.

11. **Config keys** — the plugin's `ConfigSlice` sub-tree (spec 24): keys, types, defaults,
    validation. These are the `PluginOptionMap` values (spec 14 §4.16).

### 3.1 Shared conventions all plugin specs inherit

- **Symbolic anchors, not paths.** Roots use `RootSpec(base:glob:)` where `base` is a `RootBase`
  anchor the engine resolves against the real user (spec 13 §4). v1 anchors used across the
  catalog: `.home`, `.libraryCaches` (`~/Library/Caches`), `.libraryApplicationSupport`
  (`~/Library/Application Support`), `.libraryContainers` (`~/Library/Containers`),
  `.libraryLogs` (`~/Library/Logs`), `.developer` (`~/Library/Developer`), `.tmp`
  (`$TMPDIR`/`/private/var/folders/...`). New anchors needed by a plugin are flagged in that
  plugin's Open Questions as a proposed addition to `RootBase` (see OQ across specs).
- **Never hard-code "delete this path."** A path being *declared* only makes it *scannable*; a
  Finding requires *evidence* (mtime/lastUsed/orphan/whereFroms) that the specific item is junk.
  The catalog's design principle: **path scopes the search; metadata justifies the action.**
- **Engine re-scores everything.** Any `SafetyScore` a plugin emits is a ceiling-bounded proposal
  (DM-2). Any `Disposition` other than `.stage`/`.trash`(Trash only) is forced back to `.stage`.
- **Reclaim is on-disk allocation** with clone/hardlink correction (CC-10, spec 14 §6), never
  logical size.
- **Cancellation** is checked at directory boundaries (spec 13 §6, spec 16 §2).

## Open Questions

- **OQ-P.1** Should `dev.cleaner.devcache` be one broad plugin or split per-ecosystem (Go, Rust,
  JVM, CocoaPods) for finer config and risk? *Leaning: one plugin with per-ecosystem sub-config
  for v1.0; split only if a sub-ecosystem needs elevation or a shell fallback that others don't.*
- **OQ-P.2** The `RootBase` anchor set above extends spec 13's illustrative list
  (`.home/.libraryCaches/.developer/.tmp`). Ratify the full enum (`.libraryApplicationSupport`,
  `.libraryContainers`, `.libraryLogs`) in spec 13 §4 so plugins don't smuggle absolute paths.
- **OQ-P.3** Do container/VM tools beyond Docker (Podman, Colima, OrbStack, Lima) warrant their
  own plugins or a shared `dev.cleaner.containers` with per-engine adapters? *Leaning: shared
  adapter behind the same shell-safety rails as Docker, v1.0+.*
- **OQ-P.4** Should the catalog encode inter-plugin overlap resolution (Xcode vs. devcache both
  under `~/Library/Developer`, browser vs. devcache under `~/Library/Caches`) here, or defer to the
  engine's canonical-path de-dup (spec 13 OQ-13.3, spec 17)? *Leaning: defer to engine dedup;
  document the overlap in each plugin's Edge cases.*
- **OQ-P.5** Release gating: is `dev.cleaner.docker`'s shell-only nature acceptable for v0.5, or
  should it wait for a hardened `ProcessRunning` sandbox review (spec 36)? *Leaning: ship in v0.5
  read-only (`df`) and gate the mutating prune path behind the spec 36 sign-off.*

## Dependencies

**Consumes:** 00-constitution (Art. 3 glossary, Art. 4 safety constants, Art. 5 protected paths,
Art. 7 exit codes, CC-8 static plugins), 13-plugin-architecture (`CleanerPlugin`/`PluginManifest`/
`PluginContext`/`CleanDirective`/`RootSpec`/`CapabilitySet`), 14-domain-model (all entity/enum
names), 16-filesystem-strategy (enumeration, sizing, evidence, dataless/symlink/volume rules),
19-detection-algorithms (staleness scoring, multi-stage dedup), 24-configuration-system
(`ConfigSlice` shapes).

**Feeds:** every `plugins/plugin-*.md` (this template governs their structure), 17-scan-engine
(the registered plugin set it fans out over), 20-cleanup-engine (dispositions it executes),
22-safety-model (the proposed scores it finalizes), 09/25 (category grouping in the preview).
