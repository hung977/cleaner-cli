# 06 — Functional Requirements

> **Phase B · Depends on:** 00-constitution, 03-personas, 04-user-stories, 05-use-cases ·
> **Depended on by:** 07, 08, 09, 11–13, 17–22, 31 (testing).
>
> This spec enumerates **what** the tool does. Every capability from the brief is a numbered
> `FR-###` with an RFC-2119 priority and an owning module. Non-functional targets live in 07;
> the command surface that exposes these FRs lives in 08; the safety constants they obey live
> in Constitution Articles 4–5. Where an FR names a disposition
> (`stage`/`trash`/`purge`/`skip`), a recoverability class (`instant`/`manual`/`hard`/`none`),
> or an exit code, the source of truth is the Constitution.
>
> **v0.6 as-built note.** Risk grading (🟢🟡🔴 / Safe·Medium·Dangerous, `--all`, `--include
> medium`, risk-based pre-/auto-selection) was **removed**. `RiskLevel`/`SafetyScore` survive
> only as unused internal metadata and drive no selection, display, or confirmation. Every
> source is staged and recoverable via `cleaner undo`. FRs below keep their IDs; where behavior
> changed the wording is updated and flagged inline rather than deleted.

## 1. Purpose & reading guide

- **Priority.** `MUST` = required for v1.0 GA. `SHOULD` = strongly expected, may slip to a
  1.x point release with an ADR. `MAY` = optional/roadmap-adjacent, built if cheap.
- **Owning module.** The module (spec 11/12) that holds the primary responsibility. Cross-cut
  concerns list the coordinating module first.
- **Traceability.** Section 9 maps every FR to its owning module and capability; US/UC/test
  columns are referenceable placeholders that resolve against specs 04, 05, and 31.
- **Modules referenced:** `CLI` (Argument Parser front end, spec 08/26), `TUI` (spec 25),
  `Engine` (orchestration, spec 11), `ScanEngine` (17), `RuleEngine` (18), `Detection` (19),
  `CleanupEngine` (20), `Staging` (21), `Safety` (22), `Permissions` (23), `PluginHost` (13),
  `Reporting` (08 §JSON / spec 28), `Config` (24), `Logging` (28), plus the concrete plugins
  in `specs/plugins/`.

---

## 2. Category (a) — Analysis (read-only)

Analysis FRs never mutate the filesystem (Constitution: *Scan is read-only*). They emit
Findings and reports only.

| FR | Priority | Requirement | Owning module |
|---|---|---|---|
| **FR-001** | MUST | The tool MUST perform **disk-usage analysis** of one or more selected roots/volumes, producing a size-attributed tree where each node carries logical size and *allocated* on-disk size (APFS-clone/sparse aware, per CC-10). | ScanEngine |
| **FR-002** | MUST | The tool MUST produce a **storage report** summarizing total capacity, used, free, purgeable (macOS "purgeable"), and reclaimable-by-cleaner space, broken down by category and by plugin. | Reporting |
| **FR-003** | MUST | The tool MUST perform **large-file detection**: surface files whose allocated size exceeds a configurable threshold (default 1 GiB, overridable via `--min-size`/config), ranked descending, with path, size, mtime, and Spotlight kind. | Detection |
| **FR-004** | MUST | The tool MUST perform **duplicate detection** using a staged pipeline: (1) group by size, (2) cheap hash of head/tail blocks (xxHash prefilter), (3) full **SHA-256** confirmation (CC/CryptoKit) only on collision groups. It MUST treat APFS clones/hardlinks as *not* duplicates (same inode ⇒ no reclaim). Output groups the duplicate set and marks a keep-candidate. | Detection |
| **FR-005** | MUST | The tool MUST perform **old-file detection**: surface files/dirs whose last-access (`atime`, falling back to `mtime` when `atime` is unreliable) precedes a configurable age (default 180 days), with per-category age overrides. | Detection |
| **FR-006** | SHOULD | Analysis SHOULD support **scoped roots**: whole volume, `$HOME`, an explicit path, or a plugin's declared roots, selected via `--path`/args (spec 08). | ScanEngine |
| **FR-007** | SHOULD | Analysis SHOULD reuse an **incremental scan cache** (`~/.cleaner/cache`, spec 17) keyed on (path, size, mtime, inode) to skip unchanged subtrees, and MUST fall back to a full scan if the cache is stale or absent. | ScanEngine |
| **FR-008** | MAY | Analysis MAY render a **treemap-style textual breakdown** (nested bars) in the TUI for the largest N subtrees. | TUI |

---

## 3. Category (b) — Cleaning categories (one FR per category)

Every cleaning FR is realized by a **plugin** (Constitution principle 7). Each MUST: declare
its roots (intersected with the allow-space, deny-list subtracted, per Article 5); default to
disposition `stage` unless stated; be **idempotent** (principle 5); and measure Reclaim as
allocated bytes freed (CC-10). *(v0.6: cleaning is no longer risk-graded — every source is
staged and recoverable via `cleaner undo`; the per-plugin risk baseline and shared scorer are
retired.)* The **Category** column groups each source for reporting: Developer Cache, Browser
Cache, Application Cache, Logs & Crash Reports, Trash. Rows marked *(roadmap)* are specified
but not yet shipped in v0.6.

| FR | Priority | Category / requirement | Category | Owning plugin |
|---|---|---|---|---|
| **FR-020** | MUST | **Xcode** junk: device support, iOS DeviceSupport, old archives, `Xcode/DerivedData` umbrella, module cache, Previews caches. Archive removal may hold shippable builds, so (like everything) it is staged and recoverable. | Developer Cache | `XcodePlugin` |
| **FR-021** | MUST | **DerivedData**: per-project `~/Library/Developer/Xcode/DerivedData/<proj-hash>`; fully regenerable. | Developer Cache | `DerivedDataPlugin` |
| **FR-022** | MUST | **Simulators**: unavailable/orphaned simulator devices and their data, via `xcrun simctl` fallback adapter; also unused simulator *runtimes*. | Developer Cache | `SimulatorPlugin` |
| **FR-023** | MUST | **SwiftPM**: `~/Library/Caches/org.swift.swiftpm`, per-project `.build`, cloned-dependency cache. | Developer Cache | `SwiftPMPlugin` |
| **FR-024** | MUST | **CocoaPods**: `~/Library/Caches/CocoaPods`, `~/.cocoapods/repos` spec repos (re-clonable). | Developer Cache | `CocoaPodsPlugin` |
| **FR-025** | MUST | **npm / yarn / pnpm**: `~/.npm/_cacache`, `~/.cache/yarn`, pnpm store (`~/Library/pnpm/store` / `~/.pnpm-store`), and discovered `node_modules` (re-installable but costly). | Developer Cache | `NodePlugin` |
| **FR-026** | MUST | **Python**: pip cache (`~/Library/Caches/pip`), `__pycache__`, `.pyc`, virtualenv/`venv` caches, poetry/pipenv caches. | Developer Cache | `PythonPlugin` |
| **FR-027** | MUST | **Ruby** *(roadmap)*: gem cache, bundler cache (`~/.bundle/cache`), `vendor/bundle`. | Developer Cache | `RubyPlugin` |
| **FR-028** | MUST | **Java / Gradle / Maven**: `~/.gradle/caches`, Gradle daemon logs, `~/.m2/repository` (re-downloadable), build `target/`/`build/` dirs. | Developer Cache | `JvmPlugin` |
| **FR-029** | SHOULD | **Android Studio** *(roadmap)*: `~/Library/Caches/Google/AndroidStudio*`, AVD system images/snapshots, `~/.android/avd`, Gradle overlap deduped with FR-028. | Developer Cache | `AndroidPlugin` |
| **FR-030** | MUST | **Docker**: reclaimable images/containers/volumes/build-cache via `docker system df`/`prune` shell adapter; NEVER prunes running containers or named volumes without explicit opt-in (volumes hold user data). | Developer Cache | `DockerPlugin` |
| **FR-031** | MUST | **Homebrew**: `brew cleanup` targets — old formula versions, download cache (`~/Library/Caches/Homebrew`), stale downloads; via native cache-path scan with `brew` adapter fallback. | Developer Cache | `HomebrewPlugin` |
| **FR-032** | MUST | **Chrome cache**: `~/Library/Caches/Google/Chrome`, profile `Cache`/`Code Cache`/`GPUCache`; NEVER touches profile data, cookies, passwords, history (deny-listed). Edge/Brave follow the same cache-only rule. | Browser Cache | `ChromeCachePlugin` |
| **FR-033** | MUST | **Safari cache**: `~/Library/Caches/com.apple.Safari`, WebKit cache; NEVER touches bookmarks/history/passwords. Firefox follows the same cache-only rule. | Browser Cache | `SafariCachePlugin` |
| **FR-034** | MUST | **Logs**: `~/Library/Logs`, `/Library/Logs` (user-readable), rotated app logs; retains most-recent N per app by default. | Logs & Crash Reports | `LogsPlugin` |
| **FR-035** | MUST | **Crash reports**: `~/Library/Logs/DiagnosticReports`, `.crash`/`.ips` diagnostic files. | Logs & Crash Reports | `CrashReportsPlugin` |
| **FR-036** | SHOULD | **Mail downloads** *(roadmap)*: `~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads` temporary attachments (user may not have saved them elsewhere). | Application Cache | `MailDownloadsPlugin` |
| **FR-037** | MUST | **Trash**: enumerate `~/.Trash` and per-volume `.Trashes`; report size. *(v0.6: emptying stages the Trash contents like every other source, so it is recoverable via `cleaner undo` — no longer an irreversible `purge`.)* | Trash | `TrashPlugin` |
| **FR-038** | MUST | **Generic / Application cache**: `~/Library/Caches/*` for apps without a dedicated plugin, using heuristics (dir named `Cache*`, regenerable evidence). | Application Cache | `GenericCachePlugin` |
| **FR-039** | MUST | **Temporary files** *(roadmap)*: `$TMPDIR`, `/private/var/folders` user-owned temp, `/tmp` user-owned entries older than a threshold. | Application Cache | `TempFilesPlugin` |
| **FR-040** | MUST | **Build artifacts** *(roadmap)*: generic discovery of regenerable build outputs (`build/`, `target/`, `.build/`, `DerivedData`, `dist/`, `out/`, `.next/`, `.gradle/`) under user project roots, gated by presence of a matching build manifest. | Developer Cache | `BuildArtifactsPlugin` |

**FR-041 (MUST, PluginHost).** Each cleaning plugin MUST expose the same lifecycle
(`declareRoots → scan → classify → plan → dispose`) and MUST be independently selectable via
`--include`/`--exclude`/`--plugins` (spec 08) and profiles (FR-095).

**FR-042 (MUST, RuleEngine).** Overlapping plugins (e.g. FR-028 Gradle vs FR-040 build
artifacts, FR-029 Android Gradle vs FR-028) MUST deduplicate Items by canonical path so no
byte is double-counted in Reclaim and no path is disposed twice.

---

## 4. Category (c) — Detection & audit (read-only advisories)

Detection produces advisories; acting on them routes through the same Cleanup/Staging path.

| FR | Priority | Requirement | Owning module |
|---|---|---|---|
| **FR-050** | MUST | **Unused apps**: detect installed `.app`s with no Launch Services launch record and old last-used dates (Spotlight `kMDItemLastUsedDate`). Reports the app + its caches/support; the `.app` bundle itself is deny-listed (Article 5) and only *advised*, never auto-cleaned. | Detection |
| **FR-051** | MUST | **Orphan packages**: package-manager artifacts whose owning project/manifest no longer exists (dangling `node_modules`, `.build`, `vendor/bundle`, pods) — cross-checked with FR-025–028. | Detection |
| **FR-052** | MUST | **Obsolete SDKs**: old iOS/watchOS/tvOS DeviceSupport and platform SDKs superseded by newer installed versions. | Detection |
| **FR-053** | MUST | **Stale DerivedData**: DerivedData folders whose source project path is missing or untouched beyond a threshold. | Detection |
| **FR-054** | MUST | **Old simulator runtimes**: installed runtimes with no devices and superseded by a newer minor/major. | Detection |
| **FR-055** | MUST | **Old archives**: `Xcode/Archives` older than a threshold (may be needed for re-submission/dSYMs). | Detection |
| **FR-056** | SHOULD | **Unnecessary localizations**: `*.lproj` bundles for languages outside the user's preferred set, inside *cache/support* dirs only (never inside a signed `.app`, which would break the signature — deny-listed). | Detection |
| **FR-057** | SHOULD | **Temporary downloads**: stale files in `~/Downloads` flagged by `kMDItemWhereFroms` + age; advisory-only, `~/Downloads` is user-content, never auto-cleaned. | Detection |
| **FR-058** | SHOULD | **Duplicate cache**: identical cache blobs across app caches (via FR-004 hashing scoped to cache roots). | Detection |
| **FR-059** | MUST | **Symlink / hardlink / sparse / APFS-snapshot awareness**: detection MUST identify symlinks (and not follow them out of allowed roots — Article 4.4), collapse hardlink groups (count reclaim once), detect sparse files (report allocated not logical), and recognize APFS local snapshots as *protected* (Article 5) and clones as shared storage (Reclaim = 0 unless last reference). | ScanEngine / Safety |
| **FR-060** | SHOULD | **Zombie directories**: empty or near-empty leftover directories (only regenerable/empty content) left by uninstalled tools. | Detection |

**FR-061 (MUST, Detection).** Every advisory MUST carry **evidence** (Article 3) — the exact
signals used (mtime/atime, xattrs, Spotlight kind, Launch Services state, manifest presence) —
so the audit trail (principle 8) can answer "why was this flagged?".

---

## 5. Category (d) — System commands (behavioral requirements)

These define the *behavior* of the top-level verbs; their CLI surface (flags, exit codes,
JSON) is fully specified in spec 08.

| FR | Priority | Requirement | Owning module |
|---|---|---|---|
| **FR-070** | MUST | *(was `analyze`)* The default `cleaner` scan phase (and `cleaner --dry-run`) MUST run a read-only scan (FR-001–008) and present per-source Findings + reclaimable totals without deleting; `cleaner find large` / `cleaner find dupes` expose the standalone detectors. *(v0.6: the separate `analyze` command was folded into the default scan and the `find` subcommands.)* | Engine/CLI |
| **FR-071** | MUST | *(was `audit`)* `cleaner find large\|dupes` MUST run the detectors (FR-050–061, as implemented) and list reclaimable opportunities without acting; `--json`/`--md` emit machine output. *(v0.6: the `audit` command was replaced by `find`.)* | Detection/CLI |
| **FR-072** | MUST | The hidden **`cleaner doctor`** MUST check environment health: OS version, Full Disk Access, admin availability, TTY, config validity, plugin load status, staging integrity, free-space headroom — and report an ok/warning/critical status per check. CI mapping: 0 healthy, 3 warnings, 1 critical (Article 7). | CLI/Permissions |
| **FR-073** | MUST | *(was `report`)* Machine-readable session results MUST be emitted inline via `--json`/`--md`, and the staged actions of prior sessions MUST be listable via `cleaner undo --list`. *(v0.6: the separate `report` command was dropped; results are printed inline and recorded for `undo` rather than re-rendered from a report store.)* | Reporting |
| **FR-074** | MUST | *(was `optimize`)* The default `cleaner` run IS the one-shot "make space now" flow: it scans **all** discovered sources and, on `Y`/`--yes`, cleans them all — every action staged and recoverable. *(v0.6: `optimize` merged into the default command; there is no separate curated verb and no risk-based category exclusion.)* | Engine/CLI |
| **FR-075** | MUST | *(was `clean`)* The default `cleaner` command MUST execute the preview→confirm→dispose pipeline for the discovered sources (default disposition `stage`), and is the primary destructive command. Confirmation prompt: `Clean all X? [Y = all · s = select each · n = cancel]`, where `s` walks each source with `y/N`. | CleanupEngine |
| **FR-076** | MUST | The **interactive `cleaner`** entry (no subcommand, TTY present) MUST scan and then present the inline confirmation prompt (`Y` = clean all · `s` = select each source · `n` = cancel). *(v0.6: there is no multi-level TUI navigator or multi-select item picker; selection is a simple per-source `y/N` walk.)* With no TTY and no `--yes`, a destructive run MUST refuse and exit `2`. | CLI |

---

## 6. Category (e) — Cross-cutting requirements

These apply to **every** destructive command unless noted.

| FR | Priority | Requirement | Owning module |
|---|---|---|---|
| **FR-080** | MUST | **Preview-first.** No destructive command disposes of anything before presenting a preview of exactly what will be affected (paths, sizes, disposition, recoverability). (Principle 1.) | Engine |
| **FR-081** | MUST | **Confirmation.** Interactive runs MUST require explicit confirmation before disposal via the `Clean all X? [Y = all · s = select each · n = cancel]` prompt; `s` selects sources individually with `y/N`. *(v0.6: risk-tiered typed confirmation was removed — every action is staged and reversible via `cleaner undo`, so no bare-`y` vs typed distinction applies.)* | CLI |
| **FR-082** | MUST | **`--dry-run`.** MUST compute and display the full plan and projected Reclaim using the *same* measurement code as a real run (principle 3) and dispose of nothing, exiting `0`. | Engine |
| **FR-083** | MUST | **`--yes`.** MUST clean **all** discovered sources without prompting. Absent a TTY, a destructive `cleaner` run without `--yes` MUST refuse and exit `2`. *(v0.6: `--yes` no longer filters by risk; there is no `--include medium`, no `--all`, and no red-item exclusion.)* | CLI/Safety |
| **FR-084** | MUST | **`--json` / `--md`.** Any command MUST emit a versioned (`schemaVersion`) machine-readable result to stdout with all human chrome suppressed; logs/progress go to stderr (spec 08 stdout/stderr contract). | Reporting |
| **FR-085** | MUST | **`--ci`.** MUST imply non-interactive, `--no-tui`, `--no-color`, stable exit-code semantics (Article 7, incl. doctor/audit mapping) and machine-friendly output; MUST NOT prompt. | CLI |
| **FR-086** | MUST | **Verbose/debug.** `-v/--verbose` MUST increase human detail; `--debug` MUST emit diagnostic logs (timings, decisions, adapter calls) to stderr without polluting `--json` stdout. | Logging |
| **FR-087** | MUST | **Staging.** The default disposition MUST be *move-to-staging* (`~/.cleaner/staging/<session-uuid>`), preserving original path + metadata for rollback (principle 2, CC-7). Cross-volume moves MUST fall back to copy-then-remove and MUST verify before removing the source. | Staging |
| **FR-088** | MUST | **Rollback / restore.** The tool MUST restore staged Items to their original locations on request via **`cleaner undo`** (with `cleaner undo --list` enumerating sessions), refusing if the destination is now occupied unless `--force`, and MUST record restores in the audit trail. *(v0.6: restore is the `cleaner undo` command; the `staging restore` subcommand name is retired.)* | Staging |
| **FR-089** | MUST | **Purge.** Permanent deletion (staged items aged past retention, or `--no-stage` **with** confirmation) MUST be an explicit escalation, and is the only irreversible operation (Article 3/4.4). | Staging |
| **FR-090** | MUST | **macOS Trash disposition.** The tool SHOULD offer `--trash` to route disposal to the system Trash (via `NSWorkspace.recycle`) instead of tool staging, for users who prefer Finder-visible recovery. | CleanupEngine |
| **FR-091** | MUST | **Cancellation.** Any long-running scan/clean MUST be cancellable (Ctrl-C / `q`) at directory boundaries, leaving the filesystem consistent and exiting `5` (Article 7). Partial disposal MUST be recorded so it can be reported/rolled back. | Engine |
| **FR-092** | SHOULD | **Resume.** An interrupted scan SHOULD be resumable from a checkpoint (spec 17) rather than restarting from zero. | ScanEngine |
| **FR-093** | MUST | **Partial-success reporting.** When some Items succeed and others fail/skip, the tool MUST exit `3` and the report MUST list each skipped/failed Item with the reason (principle 3). | Reporting |
| **FR-094** | MUST | **Include/exclude filtering.** `--include`/`--exclude` MUST filter by plugin id, category, or path glob, applied deterministically (documented precedence in spec 08). *(v0.6: risk-level is no longer a filter dimension.)* | RuleEngine |
| **FR-095** | MUST | **Profiles.** Named profiles in `~/.cleaner/config.yml` (`profiles:` map) MUST capture source selection as `{include, exclude}` lists and be invocable via `--profile`. *(v0.6: profiles carry only `include`/`exclude` — there is no `risky:` field or risk-tiered profile.)* | Config |
| **FR-096** | MUST | **Whitelist / protected paths.** User whitelist entries MUST be honored in addition to the hard-coded deny-list (Article 5); the engine MUST intersect plugin roots with the allow-space and subtract both lists before any action (Article 4.4). | Safety/RuleEngine |
| **FR-097** | SHOULD | **Target rules (blacklist).** Users SHOULD be able to add target rules marking additional cleanable paths (Article 3), which MUST still pass all hard invariants (Article 4.4) and MUST NOT override the deny-list. | RuleEngine |
| **FR-098** | MUST | **Permissions.** When an operation needs Full Disk Access or admin, the tool MUST detect the gap, explain it, and either request elevation scoped to that operation (Authorization Services) or exit `4` — never silently escalate (principle 6, spec 23). | Permissions |
| **FR-099** | MUST | **Audit trail.** Every filesystem mutation MUST append a structured NDJSON event (`~/.cleaner/logs/audit/<date>.ndjson`) recording path, size, disposition, session, and evidence (principle 8, spec 28). | Logging |
| **FR-100** | MUST | **No network in core path.** No analysis/clean/audit code path MAY perform network I/O (principle 10). Adapter shell-outs that themselves reach the network (e.g. none in scope) are prohibited in v1's cleaning path. | Engine |

---

## 7. Capability Matrix

Columns: **Capability** → owning **Plugin/Module** → **Category** → **Recoverability**
(default disposition) → **Native API used** (primary) → **Shell fallback** (adapter, spec 13).
"Native" means the primary path is a documented macOS/Foundation API (principle 4); the shell
column is the isolated, justified fallback where no stable native API exists. *(v0.6: the former
"Risk default" column is gone — cleaning is not risk-graded; every disposition below stages and
is recoverable via `cleaner undo`.)*

| Capability | Plugin / Module | Category | Recoverability (disposition) | Native API (primary) | Shell fallback |
|---|---|---|---|---|---|
| Disk-usage analysis | ScanEngine | read-only | n/a | `getattrlistbulk`, `URLResourceValues` | — |
| Storage report | Reporting | read-only | n/a | `statfs`, DiskArbitration | — |
| Large-file detection | Detection | read-only | n/a | `URLResourceValues` (allocated size) | — |
| Duplicate detection | Detection | read-only | n/a | CryptoKit SHA-256, `stat` inode | — |
| Old-file detection | Detection | read-only | n/a | `URLResourceValues` (atime/mtime) | — |
| Xcode junk | XcodePlugin | Developer Cache | manual (stage) | FileManager, Spotlight | `xcodebuild`/`xcrun` (paths) |
| DerivedData | DerivedDataPlugin | Developer Cache | manual (stage) | FileManager | — |
| Simulators | SimulatorPlugin | Developer Cache | manual (stage) | FileManager (CoreSimulator dirs) | `xcrun simctl delete` |
| SwiftPM caches | SwiftPMPlugin | Developer Cache | manual (stage) | FileManager | — |
| CocoaPods | CocoaPodsPlugin | Developer Cache | manual (stage) | FileManager | `pod cache clean` |
| npm/yarn/pnpm | NodePlugin | Developer Cache | manual (stage) | FileManager | `npm cache clean` |
| Python caches | PythonPlugin | Developer Cache | manual (stage) | FileManager | `pip cache purge` |
| Ruby/gems *(roadmap)* | RubyPlugin | Developer Cache | manual (stage) | FileManager | `gem cleanup`, `bundle` |
| Java/Gradle/Maven | JvmPlugin | Developer Cache | manual (stage) | FileManager | `gradle`/`mvn` (rarely) |
| Android Studio *(roadmap)* | AndroidPlugin | Developer Cache | manual (stage) | FileManager | `avdmanager`, `sdkmanager` |
| Docker | DockerPlugin | Developer Cache | manual (purge via daemon) | — (no native) | `docker system df`/`prune` |
| Homebrew | HomebrewPlugin | Developer Cache | manual (stage) | FileManager (cache path) | `brew cleanup -s` |
| Chrome cache | ChromeCachePlugin | Browser Cache | manual (stage) | FileManager | — |
| Safari cache | SafariCachePlugin | Browser Cache | manual (stage) | FileManager | — |
| Logs | LogsPlugin | Logs & Crash Reports | manual (stage) | FileManager | — |
| Crash reports | CrashReportsPlugin | Logs & Crash Reports | manual (stage) | FileManager | — |
| Mail downloads *(roadmap)* | MailDownloadsPlugin | Application Cache | manual (stage) | FileManager (container) | — |
| Trash | TrashPlugin | Trash | manual (stage) | FileManager, `NSWorkspace` | — |
| Generic cache | GenericCachePlugin | Application Cache | manual (stage) | FileManager, Spotlight | — |
| Temporary files *(roadmap)* | TempFilesPlugin | Application Cache | manual (stage) | `confstr(_CS_DARWIN_USER_TEMP_DIR)`, FileManager | — |
| Build artifacts *(roadmap)* | BuildArtifactsPlugin | Developer Cache | manual (stage) | FileManager | — |
| Unused apps (advise) | Detection | read-only | advisory only | Launch Services, Spotlight | — |
| Orphan packages | Detection | read-only | manual (stage) | FileManager | — |
| Obsolete SDKs | Detection | read-only | hard (stage) | FileManager | `xcrun` |
| Stale DerivedData | Detection | read-only | manual (stage) | FileManager | — |
| Old simulator runtimes | Detection | read-only | hard (stage) | FileManager | `xcrun simctl runtime` |
| Old archives | Detection | read-only | hard (stage) | FileManager | — |
| Unnecessary localizations | Detection | read-only | manual (stage) | FileManager, preferred-languages | — |
| Temporary downloads | Detection | read-only | advisory only | Spotlight `kMDItemWhereFroms` | — |
| Duplicate cache | Detection | read-only | manual (stage) | CryptoKit | — |
| Symlink/hardlink/sparse/snapshot awareness | ScanEngine/Safety | read-only | n/a | `lstat`, `stat` (st_nlink, st_blocks), DiskArbitration, `fs_snapshot` | — |
| Zombie directories | Detection | read-only | manual (stage) | FileManager | — |

---

## 8. Consistency requirements (engine-enforced invariants restated as FRs)

| FR | Priority | Requirement | Owning module |
|---|---|---|---|
| **FR-110** | MUST | The engine MUST enforce all Article 4.4 hard invariants centrally, NOT trusting plugins (refuse action outside allowed roots, on deny-list, across escaping symlinks, on mount roots/`/`/system volumes, purge-without-stage without confirmation). Violation aborts with exit `8`. | Safety |
| **FR-111** | MUST | Reclaim reporting MUST use allocated on-disk size and MUST subtract shared storage for clones/hardlinks so totals never overstate savings (principle 3, CC-10). | Reporting |
| **FR-112** | MUST | Running any destructive command twice MUST be safe and idempotent: the second run finds nothing new (principle 5). | CleanupEngine |
| **FR-113** | SHOULD | Plugin failures MUST be isolated: one failing plugin MUST NOT abort the session; it is reported and the run exits `3` or `7` as appropriate. | PluginHost |

---

## 9. Traceability Matrix (skeleton)

Columns fully populated for this spec: **FR ↔ owning module** and **FR ↔ capability**. The
**US**, **UC**, and **Test-ID** columns are referenceable placeholders — `US-*` resolves in
spec 04 (User Stories), `UC-*` in spec 05 (Use Cases), `T-*` in spec 31 (Testing Strategy).
Each FR MUST, before Phase-B sign-off, trace to ≥1 US, ≥1 UC, ≥1 test, and its module
(Constitution Article 9 traceability rule).

| FR | Capability | Module | US (spec 04) | UC (spec 05) | Test (spec 31) |
|---|---|---|---|---|---|
| FR-001 | Disk-usage analysis | ScanEngine | US-analyze-* | UC-analyze | T-scan-* |
| FR-002 | Storage report | Reporting | US-report-* | UC-report | T-report-* |
| FR-003 | Large-file detection | Detection | US-large-* | UC-analyze | T-detect-large-* |
| FR-004 | Duplicate detection | Detection | US-dupe-* | UC-audit | T-detect-dupe-* |
| FR-005 | Old-file detection | Detection | US-old-* | UC-audit | T-detect-old-* |
| FR-006–008 | Analysis scoping/cache/treemap | ScanEngine/TUI | US-analyze-* | UC-analyze | T-scan-cache-* |
| FR-020–040 | Cleaning categories (per plugin) | `*Plugin` | US-clean-<cat>-* | UC-clean | T-plugin-<cat>-* |
| FR-041–042 | Plugin lifecycle / dedup | PluginHost/RuleEngine | US-plugins-* | UC-clean | T-plugin-host-*, T-dedup-* |
| FR-050–061 | Detection & audit advisories | Detection/ScanEngine/Safety | US-audit-* | UC-audit | T-detect-* |
| FR-070–076 | System commands | Engine/CLI/TUI | US-cmd-* | UC-<verb> | T-cmd-* |
| FR-080–093 | Preview/confirm/dry-run/yes/json/ci/staging/rollback/cancel/resume | Engine/Staging/Reporting | US-safety-* | UC-clean, UC-rollback | T-flow-* |
| FR-094–097 | Filtering / profiles / whitelist / target rules | RuleEngine/Config | US-config-* | UC-config | T-rules-*, T-profile-* |
| FR-098–100 | Permissions / audit trail / no-network | Permissions/Logging/Engine | US-safety-* | UC-permission | T-perm-*, T-audit-* |
| FR-110–113 | Engine-enforced invariants | Safety/Reporting/CleanupEngine/PluginHost | US-safety-* | UC-clean | T-invariant-*, T-idempotent-* |

---

## Open Questions

- **OQ-06.1** *(resolved in v0.6)* Risk-tiered inclusion was dropped entirely: the default
  `cleaner` run (FR-074) cleans **all** discovered sources; there is no `--include medium` and no
  🟢/🟡 split.
- **OQ-06.2** Duplicate detection (FR-004) default scope — whole `$HOME` is expensive; should
  the default be cache/Downloads roots only, with whole-volume behind a flag? *Leaning: scoped.*
- **OQ-06.3** *(resolved in v0.6)* `node_modules`/`vendor` are surfaced and cleaned like any
  other source when selected (`Y`/`s`/`--yes`); there is no risk gate. Re-install cost is
  communicated in the preview, and the action is staged/recoverable via `cleaner undo`.
- **OQ-06.4** Should unnecessary-localization removal (FR-056) be dropped from v1 given code-sign
  risk, keeping it advisory-only? *Leaning: advisory-only in v1.*
- **OQ-06.5** *(resolved in v0.6)* Trash emptying (FR-037) **stages** the Trash contents like
  every other source, so it is recoverable via `cleaner undo` rather than an irreversible purge.
- **OQ-06.6** Exact age/size default thresholds (FR-003/005/039/055) — pending persona data in
  spec 03; values above are provisional defaults.

## Dependencies

- **Consumes:** 00 (principles, glossary, safety constants, exit codes, protected paths),
  03 (personas → thresholds), 04 (user stories), 05 (use cases), 10 (tech stack → native APIs).
- **Feeds:** 07 (NFRs quantify these FRs), 08 (command surface exposing FRs), 09 (IA/navigation),
  11–13 (architecture/modules/plugin contract realizing FRs), 17 (scan), 18 (rules), 19
  (detection algorithms), 20 (cleanup), 21 (rollback), 22 (safety scoring), 23 (permissions),
  28 (logging/audit), 31 (tests close the traceability matrix).
