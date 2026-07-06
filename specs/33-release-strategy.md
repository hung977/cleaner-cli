# 33 — Release Strategy

> **Phase G · Depends on:** 00-constitution (Art. 6 naming, CC-11 distribution, Art. 11 DoD),
> 07-nonfunctional (NFR-054 supply chain, NFR-123 self-contained install), 13 (plugin SDK semver
> surface), 31 (safety/coverage gates), 32 (the artifacts a release ships) ·
> **Depended on by:** 34 (CI implements the release pipeline & tap automation), 38 (roadmap channels).

## 1. Purpose & scope

How `cleaner` goes from a merged commit to something a user can install and trust: the versioning
policy, release channels, branching model, changelog discipline, GitHub Releases contents, Homebrew tap
update automation, the (v2) self-update design, deprecation policy, license/CLA recommendation, and the
release checklist/gates. It sits on top of spec 32 (which defines *what* the artifacts are) and is
executed by spec 34 (the automation).

## 2. Semantic versioning policy

`cleaner` follows **SemVer 2.0.0** (`MAJOR.MINOR.PATCH`). Two versioned surfaces, versioned together but
governed by distinct compatibility contracts:

| Surface | What a breaking change means |
|---|---|
| **CLI / behavior contract** | Removing/renaming a command or flag, changing an exit code (Art. 7), changing `--json` schema incompatibly, changing a default that alters what gets cleaned. |
| **`CleanerPluginAPI` SDK** (spec 12 §7, spec 13) | Any source-breaking change to `CleanerPlugin`, `PluginManifest`, `PluginContext`, provider protocols, or capability flags. |

- **MAJOR** — breaking change to either surface. Requires a deprecation cycle (§9) and migration notes.
- **MINOR** — backward-compatible additions: new command/flag/plugin, new optional config key, additive
  `--json` field (consumers must tolerate unknown fields — documented contract), new SDK method with a
  default.
- **PATCH** — backward-compatible bug/safety/perf fixes only.
- **`--json` `schemaVersion`** (NFR-111) tracks its own integer, bumped only on JSON breaking changes and
  called out in the changelog; the tool can emit a prior `schemaVersion` via `--json-schema <n>` for one
  major cycle (deprecation window).
- **Plugin `apiVersion`** in each manifest (spec 13) is checked at load: the engine loads a plugin only
  if its `apiVersion` is semver-compatible with the built-in SDK; incompatible ⇒ refuse with exit 7
  (spec 31 §10), never silently mis-drive it.
- **Pre-1.0 / pre-release identifiers:** `1.4.0-beta.2`, `1.5.0-nightly.20260706+a1b2c3d` (SemVer
  pre-release + build metadata). Build metadata (`+sha`) never affects precedence.

## 3. Release channels

| Channel | Version form | Cadence | Audience | Gate |
|---|---|---|---|---|
| **stable** | `X.Y.Z` | on demand (features/fixes ready) | everyone; default `brew install` | full release checklist (§10) |
| **beta** | `X.Y.Z-beta.N` | before a MINOR/MAJOR | opt-in testers | safety suite 100 % + full test suite; may relax perf-trend |
| **nightly** | `X.Y.Z-nightly.<date>+<sha>` | automated on green `main` | contributors, CI dogfood | safety suite 100 % + unit/integration green |

Install by channel via the tap:

```bash
brew install <org>/cleaner/cleaner            # stable
brew install <org>/cleaner/cleaner@beta       # beta formula (Formula/cleaner@beta.rb)
brew install --HEAD <org>/cleaner/cleaner     # from-source main (bleeding)
```

**Invariant across all channels (Principle 1):** the **safety test suite (spec 31 §8) is 100 % green —
no channel, not even nightly, ships with a failing safety test.** Perf-trend and polish gates may relax
for beta/nightly; safety never does.

## 4. Branching model — trunk-based + release branches

- **`main` is trunk:** always releasable, protected (required status checks from spec 34, safety gate,
  review). Short-lived feature branches merge via PR (squash, conventional-commit title, §5).
- **Nightly** builds off green `main` automatically (§3).
- **Release branches** `release/X.Y` cut at feature freeze for a MINOR/MAJOR. Only stabilization
  fixes (cherry-picked from `main` or landed on the branch then forward-ported) go there. Stable and
  beta tags are cut from the release branch. This lets `main` keep taking features while `X.Y`
  stabilizes.
- **Patch releases** (`X.Y.Z+1`) are cut from the corresponding `release/X.Y` branch (backport the fix,
  tag). Security/safety patches follow the same path with priority (§10).
- **Tags** are the release trigger: pushing an annotated tag `vX.Y.Z[-pre]` starts the release pipeline
  (spec 34). Tags are signed (git tag signature) by a release maintainer.

## 5. Changelog & commit convention

- **Conventional Commits** for every commit title: `feat:`, `fix:`, `perf:`, `refactor:`, `docs:`,
  `test:`, `build:`, `ci:`, `chore:`, with `!`/`BREAKING CHANGE:` for majors and an optional scope
  (`feat(plugins/xcode): …`). Special trailers this suite defines: `perf-baseline-change:` (spec 30 §8),
  `safety-impact:` (flags a commit the safety reviewer must sign off, spec 35).
- **CHANGELOG.md** follows **Keep a Changelog** (`Added/Changed/Deprecated/Removed/Fixed/Security`
  sections, an `[Unreleased]` heading, ISO dates, links to compare ranges). It is **generated** from
  conventional commits on release and then human-curated for the user-facing "Highlights" (Constitution
  truth-in-reporting extends to release notes — no overstated features).
- Each release's notes call out: breaking changes + migration, new/removed plugins, changed defaults
  (especially anything affecting *what gets cleaned* — Principle 1), `schemaVersion`/`apiVersion` bumps,
  and known issues.

## 6. GitHub Releases (the canonical distribution point)

Every stable/beta tag produces a **GitHub Release** carrying the spec 32 artifacts:

- `cleaner-<version>-macos-universal.tar.gz` — notarized, stapled universal binary + completions + man.
- `cleaner-<version>-checksums.txt` — SHA-256 of the tarball (and binary).
- `cleaner-<version>-checksums.txt.minisig` — **minisign** detached signature over the checksums file
  (release-signing key; public key published in the repo README and pinned in the self-updater, §8).
- `cleaner-<version>-sbom.spdx.json` — SBOM (NFR-054).
- `cleaner-<version>-notary-log.json` — notarization record.
- Auto-generated release notes (§5) + curated highlights.

Nightlies publish to a **pre-release** GitHub Release (or a rolling `nightly` release), not the tap's
stable formula. The release is created by CI (spec 34 §release-pipeline); a human approves the promotion
of a beta→stable via an environment protection rule.

## 7. Homebrew tap update automation

On a successful **stable** release, the release pipeline (spec 34) automatically:

1. Computes the tarball `sha256` (from `checksums.txt`).
2. Opens a PR against `<org>/homebrew-cleaner` updating `Formula/cleaner.rb`'s `version`, `url`,
   `sha256` (spec 32 §8.2).
3. CI on the tap repo runs `brew install --formula ./Formula/cleaner.rb`, `brew test cleaner`
   (`--version` + `doctor --ci`), and `brew audit --strict cleaner`.
4. On green, auto-merges (or waits for maintainer approval per branch protection).

Beta releases bump `Formula/cleaner@beta.rb` by the same flow. A failed tap-bump does **not** roll back
the GitHub Release but pages the release owner (the binary is already published & valid; only the
convenience installer lags).

## 8. Self-update mechanism (v2 — design sketch)

v1 relies on `brew upgrade`. v2 adds an **opt-in** `cleaner self-update` (kept out of v1 scope per
Constitution Art. 2 / spec 38, sketched here so v1 doesn't foreclose it). Design honoring Principles 1,
6, 10:

```
cleaner self-update [--channel stable|beta] [--check-only] [--yes]
```

1. **Check.** Fetch the latest release metadata for the channel (a small signed `latest.json` on the
   releases CDN) — this is the *only* network call, explicit and user-initiated (Principle 10; not in
   the core cleaning path). Compare against `BuildInfo.version` (spec 32 §11). `--check-only` stops here.
2. **Download** the universal tarball + `checksums.txt` + `.minisig` for the target version.
3. **Verify (defense in depth):**
   - **minisign** signature of `checksums.txt` against the **pinned public key** compiled into the
     binary (a rotated key is itself introduced via a signed release + a grace window).
   - SHA-256 of the downloaded tarball == the entry in the verified `checksums.txt`.
   - `codesign --verify --strict` + `spctl --assess` on the extracted binary (Developer ID + notarized,
     spec 32) — refuse to install anything Gatekeeper rejects.
4. **Swap atomically.** Extract to a temp dir on the same volume as the current binary, then
   `renameat`/`renameatx_np` over the old binary (atomic replace; the same TOCTOU-safe primitive the
   cleaner uses, spec 16 §11). If the tool was installed by Homebrew, `self-update` **refuses** and
   directs the user to `brew upgrade` (don't fight the package manager) — it self-updates only
   manually-installed binaries it owns and can write.
5. **Rollback on failure.** Keep the prior binary as `cleaner.prev` until the new one passes a
   post-swap `cleaner doctor --ci`; on failure, atomically restore. Never leave the user without a
   working binary (Principle 1 reliability, NFR-032-style consistency).

Every step is logged to the audit trail (Principle 8). No auto-update, no background daemon (Principle
6, NFR-050) — the user runs it deliberately.

## 9. Deprecation policy

- Anything user-facing (a command, flag, config key, `--json` field, default, or plugin) marked
  **deprecated** keeps working for **≥ one MINOR cycle and is removed no sooner than the next MAJOR**.
- Deprecations emit a **stderr warning** (never on `--json` stdout — spec 08 stream contract) naming the
  replacement and the removal version; they are listed under `Deprecated` in the changelog (§5) on
  introduction and under `Removed` when dropped.
- **SDK deprecations** (`CleanerPluginAPI`) use Swift `@available(*, deprecated, message:)` so plugin
  authors get compile-time warnings a full major cycle before removal (spec 13 forward-compat).
- **Config migration:** a renamed config key is auto-migrated on load with a warning for the deprecation
  window (spec 24), never silently dropped (truth-in-reporting).
- **Safety-relevant defaults** get a longer, louder deprecation and an explicit changelog `Security`/
  Principle-1 callout — changing what is cleaned by default is treated as high-risk.

## 10. Release checklist & gates

A stable release is blocked until **all** gates are green (Constitution Art. 11 DoD + spec 31 gates):

**Automated gates (enforced by CI, spec 34 — cannot be overridden):**
- [ ] **Safety test suite 100 % green** (spec 31 §8) — hard block, no exceptions.
- [ ] Full unit + integration + property + snapshot + contract suites green.
- [ ] Coverage: safety-critical ≥ 95 % line+branch (NFR-034); overall ≥ floor (spec 31 §11).
- [ ] Strict-concurrency build clean (NFR-033); no un-noted `@unchecked Sendable`.
- [ ] Benchmark regression gate green (spec 30 §8) or an approved `perf-baseline-change`.
- [ ] Universal binary built, **signed, notarized, stapled**; `spctl --assess` passes (spec 32 §4–7).
- [ ] Size gate: binary < 25 MB, footprint < 40 MB (NFR-122, spec 32 §10).
- [ ] SBOM generated; dependency review clean; all deps pinned with checksums (NFR-054).
- [ ] `cleaner doctor --ci` exits 0 on a clean box; `--version` reports the exact clean tag (no
      `-dirty`, spec 32 §11).
- [ ] Checksums + minisign signature produced and verify against the artifact.
- [ ] Traceability artifact up to date — no requirement without a test (spec 31 §13).

**Human gates (release owner sign-off, environment protection rule):**
- [ ] `safety-impact:` commits since last release reviewed & signed off (spec 35).
- [ ] Changelog highlights curated, breaking changes + migration documented (§5).
- [ ] Manual a11y checklist done for UX-affecting releases (NFR-073, spec 25).
- [ ] Beta soak period elapsed for MINOR/MAJOR (≥ 1 week beta in the wild, no P0/P1 open).
- [ ] Tag signed by a release maintainer.

**Post-release:**
- [ ] Homebrew tap PR merged & `brew test` green (§7).
- [ ] Release notes published; known issues listed.
- [ ] dSYM archived for symbolication (spec 32 §3).
- [ ] Rollback plan confirmed: a bad stable is remedied by a fast PATCH from `release/X.Y` and a tap
      revert to the prior formula (`brew` users can `brew install cleaner@<prev>` meanwhile).

## 11. License & CLA recommendation

- **Recommended license: Apache-2.0** (over MIT). Rationale: Apache-2.0 adds an **explicit patent
  grant** and a `NOTICE`/attribution mechanism — valuable for a security-sensitive system tool that
  third parties will build plugins against — while staying permissive (matching the permissive Apple
  first-party deps: swift-argument-parser, swift-log, etc.). MIT is simpler but lacks the patent grant;
  GPL/MPL are rejected as too restrictive for a CLI meant to be widely embedded/scripted. (Decision
  recorded here; final call OQ-33.1.)
- **Third-party plugins & CLA:** because plugins are a security boundary (they propose deletions, spec
  13), contributions of **bundled** plugins into the main repo should require a lightweight **DCO
  sign-off** (`Signed-off-by:`) at minimum, and a **CLA** if the project needs relicensing latitude or
  patent assurances for shipped-in-the-box plugins. External plugins distributed by their own authors
  need no CLA (they link only the Apache-2.0 SDK product, spec 12 §7). *Recommendation: DCO for all
  contributions; a CLA only if a governance/foundation move later requires it (OQ-33.2).*
- The SDK product (`CleanerPluginAPI`) ships under the same Apache-2.0 license with a clear statement
  that plugins may be independently licensed.

## Open Questions

- **OQ-33.1** Apache-2.0 (patent grant, recommended) vs. MIT (simplicity)? *Leaning: Apache-2.0.*
- **OQ-33.2** DCO-only vs. a full CLA for in-repo contributions/plugins? *Leaning: DCO now, CLA only if
  governance later demands it.*
- **OQ-33.3** Nightly channel — rolling single pre-release vs. a dated release per night (retention/
  noise trade-off)? *Leaning: rolling `nightly` pre-release + a short-retention dated artifact.*
- **OQ-33.4** Ship self-update in v1 as check-only (`--check-only` nags to `brew upgrade`) or fully
  defer to v2? *Leaning: v1 ships a passive "update available" notice on `doctor`; full self-update in
  v2 per §8.*
- **OQ-33.5** Beta soak length for MINOR vs. MAJOR — is one week enough for a MAJOR that changes cleaning
  defaults? *Leaning: 1 week MINOR, 2 weeks + explicit dogfood for MAJOR.*

## Dependencies

**Consumes:** 00 (Art. 6 naming, CC-11 notarized-tap distribution, Art. 11 DoD feeding the checklist,
Art. 7 exit codes governing CLI semver), 07 (NFR-054 supply chain → signed checksums/SBOM, NFR-111
`schemaVersion`, NFR-123 self-contained install), 13 (the `CleanerPluginAPI` semver surface & plugin
`apiVersion` gate), 31 (the safety + coverage + traceability gates the checklist enforces), 32 (the
artifacts, checksums, SBOM, signature, and version stamping a release publishes).

**Feeds:** 34 (implements the tag→build→sign→notarize→publish→tap-bump pipeline and the channel/branch
protections), 38 (self-update, channels, and roadmap of v2 features referenced here), 35 (the
`safety-impact` human sign-off gate).
