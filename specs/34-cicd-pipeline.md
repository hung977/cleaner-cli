# 34 — CI/CD Pipeline

> **Phase G · Depends on:** 00-constitution (Art. 6 conventions, Art. 7 exit codes, CC-9/CC-11),
> 07-nonfunctional (all gated NFRs), 12-module (per-target build/cache, DAG acyclicity), 30 (benchmark
> regression gate), 31 (test suites & gates), 32 (build→sign→notarize→SBOM), 33 (channels, tag trigger,
> tap automation) ·
> **Depended on by:** the delivery of every other spec (this is the enforcement engine).

## 1. Purpose & scope

The concrete **GitHub Actions** automation on **macOS runners** that enforces every gate the suite
defines and executes the release. This spec is the *mechanism*; specs 30–33 are the *policy*. It covers:
PR checks (build, lint, tests, coverage, benchmark regression, `doctor --ci` self-test), the **safety-
test gate** (100 %), security scanning, the release pipeline, the OS/arch matrix, caching, secrets, the
required status checks, and the **CI-mode (`--ci`) exit-code contract**. YAML below is illustrative
(pinned action SHAs and final runner labels are resolved at implementation).

## 2. Runner matrix

| Runner label | OS / arch | Role |
|---|---|---|
| `macos-14` (arm64) | Sonoma, Apple silicon | primary PR build+test, notarization host |
| `macos-15` (arm64) | Sequoia, Apple silicon | forward-compat matrix |
| `macos-13` (x86_64) | Ventura, Intel | **baseline OS** (NFR-090) + x86_64 slice (NFR-091) |
| `self-hosted rm-mstudio` | Apple M-class | nightly absolute-target benchmarks (spec 30 §9) |
| `self-hosted sm-intel` | Intel | nightly portability-floor benchmarks |

**Matrix policy (NFR-090/091):** PR checks run on `{macos-14 arm64, macos-13 x86_64}` (baseline OS +
newest, both arches). Nightly adds `macos-15`. The **oldest supported OS (13)** is always in the PR
matrix so a Ventura break can't merge; a `T-os-gate` test asserts an unsupported-OS launch exits 10.

## 3. Workflow inventory

| Workflow file | Trigger | Purpose |
|---|---|---|
| `.github/workflows/pr.yml` | `pull_request`, `push: main` | build, lint, tests, coverage, `doctor --ci`, safety gate |
| `.github/workflows/safety.yml` | `pull_request`, `push` | isolated **safety suite** gate (100 %), fast, first to report |
| `.github/workflows/bench.yml` | `pull_request` (label `perf`), `schedule` nightly | benchmark regression (PR subset) + nightly full grid |
| `.github/workflows/security.yml` | `pull_request`, `schedule` | dependency review, SBOM diff, pinned-deps check |
| `.github/workflows/release.yml` | `push: tag v*` | build→sign→notarize→staple→checksum→SBOM→Release→tap bump |
| `.github/workflows/nightly.yml` | `schedule` (green main) | nightly channel build + publish (spec 33 §3) |

## 4. PR checks (`pr.yml`)

```yaml
name: pr
on:
  pull_request:
  push: { branches: [main] }
concurrency: { group: pr-${{ github.ref }}, cancel-in-progress: true }

jobs:
  build-test:
    strategy:
      fail-fast: false
      matrix:
        include:
          - { runner: macos-14, arch: arm64 }
          - { runner: macos-13, arch: x86_64 }   # baseline OS + Intel slice
    runs-on: ${{ matrix.runner }}
    timeout-minutes: 25                            # NFR-103: keep the loop tight
    steps:
      - uses: actions/checkout@<sha>
      - uses: swift-actions/setup-swift@<sha>      # pin Swift 6 toolchain (spec 32 §12)
        with: { swift-version: "6.0" }
      - name: Cache SPM & build                    # §8
        uses: actions/cache@<sha>
        with:
          path: |
            .build
            ~/.cache/org.swift.swiftpm
          key: spm-${{ matrix.runner }}-${{ hashFiles('Package.resolved') }}-${{ hashFiles('Sources/**') }}
          restore-keys: spm-${{ matrix.runner }}-${{ hashFiles('Package.resolved') }}-

      - name: Resolve (offline, pinned)            # NFR-054: no floating deps
        run: swift package resolve && git diff --exit-code Package.resolved

      - name: Build (strict concurrency)           # NFR-033 gate
        run: swift build -c debug -Xswiftc -strict-concurrency=complete --arch ${{ matrix.arch }}

      - name: Lint — format                        # swift-format (Apple), fails on diff
        run: swift format lint --strict --recursive Sources Tests

      - name: Lint — swiftlint                     # complexity/force-unwrap/// SAFETY: (NFR-102)
        run: swiftlint --strict

      - name: Lint — no gratuitous public / acyclic modules   # spec 12 §5, NFR-101
        run: scripts/check-module-graph.sh          # parses Package.swift DAG, fails on cycle

      - name: Lint — i18n externalized             # NFR-080, T-i18n-externalized
        run: scripts/check-i18n.sh

      - name: Unit + integration + property + snapshot + contract
        run: swift test --enable-code-coverage
             --skip-tags stress --skip-tags perf --parallel        # <5 min (NFR-103); stress→nightly

      - name: Coverage gate                        # NFR-034
        run: scripts/coverage-gate.sh              # safety-critical ≥95% line+branch; overall ≥ floor
                                                   # (reads Tests/coverage-critical.txt, spec 31 §11)

      - name: doctor --ci self-test                # §10 CI-mode contract
        run: |
          set +e
          .build/${{ matrix.arch }}-apple-macosx/debug/cleaner doctor --ci
          test $? -eq 0 || { echo "doctor --ci not healthy on clean runner"; exit 1; }

      - name: Traceability check                   # spec 31 §13
        run: scripts/gen-traceability.sh --check   # new NFR/FR without a test ⇒ fail

      - name: Headless link check                  # NFR-092, T-headless-link
        run: scripts/check-headless-link.sh        # links without AppKit
```

Lint stack (spec 10, Art. 6): **swift-format** (canonical formatting, fails on any diff),
**swiftlint** (`--strict`: cyclomatic complexity, file length, force-unwrap without `// SAFETY:`,
NFR-102), plus repo scripts for the module-graph acyclicity (NFR-101), i18n externalization (NFR-080),
and the public-surface linter (spec 12 §5).

## 5. Safety-test gate (`safety.yml`) — must pass 100 %

The single most important check. Split into its **own workflow** so it is fast, first to report, and
never competes with the unit budget (spec 31 OQ-31.3). **Required, non-overridable, no retries.**

```yaml
name: safety
on: { pull_request: {}, push: {} }
jobs:
  safety-suite:
    runs-on: macos-14
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@<sha>
      - uses: swift-actions/setup-swift@<sha>
        with: { swift-version: "6.0" }
      - uses: actions/cache@<sha>
        with: { path: .build, key: spm-safety-${{ hashFiles('Package.resolved','Sources/**') }} }
      - name: Run safety suite (VFS + TempDir, exhaustive)      # spec 31 §8
        run: swift test --filter-tags safety --no-retry --parallel
      - name: Assert zero skips                                 # a skipped safety test is a failure
        run: scripts/assert-no-skips.sh safety
```

Branch protection marks `safety-suite` a **required status check** (§9); a red or *flaky* safety run
blocks merge and is triaged as P0 (spec 31 §1, Principle 1). It also runs inside `release.yml` as a
hard pre-build gate (spec 33 §10).

## 6. Benchmark regression (`bench.yml`)

```yaml
name: bench
on:
  pull_request: { }          # runs the PR subset only when labeled 'perf' (below)
  schedule: [ { cron: "0 7 * * *" } ]   # nightly full grid on self-hosted RM/SM
jobs:
  pr-subset:
    if: github.event_name == 'pull_request' && contains(github.event.pull_request.labels.*.name, 'perf')
    runs-on: macos-14
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@<sha>
      - uses: swift-actions/setup-swift@<sha>
      - name: Restore fixture cache                 # spec 30 §5 cached materialization
        uses: actions/cache@<sha>
        with: { path: ${{ env.CLEANER_BENCH_FIXTURES }}, key: fixtures-${{ hashFiles('Benchmarks/**/FixtureCatalog.swift') }} }
      - name: PR-gate benchmarks (relative + invariant metrics)   # spec 30 §8.3
        run: swift package benchmark --grouping metric
             --scenario W-tiny,W-small,alloc-per-file,startup,tui-frame
      - name: Regression gate                       # spec 30 §8.2 thresholds
        run: swift package benchmark baseline compare gh-macos-arm --check   # fails on >threshold

  nightly-full:
    if: github.event_name == 'schedule'
    runs-on: [self-hosted, rm-mstudio]              # absolute targets (spec 30 §9)
    steps:
      - uses: actions/checkout@<sha>
      - name: Full grid + absolute targets
        run: swift package benchmark --scenario all
      - name: Update trend store + PR-less baseline
        run: scripts/publish-trends.sh rm-mstudio   # appends Benchmarks/history, updates dashboard
```

The PR benchmark job is **label-gated** (`perf`) so most PRs skip it (keeping the loop tight), but any
PR touching hot paths (`CleanerEngine`, `CleanerPlatform`, `CleanerTUI`) is auto-labeled `perf` by a
path filter, forcing the gate. Absolute-number enforcement happens only on self-hosted reference
machines (spec 30 §8.1); ephemeral runners enforce relative + invariant metrics only.

## 7. Security scanning (`security.yml`)

- **`actions/dependency-review-action`** on PRs — flags newly introduced deps / license changes /
  known-vuln advisories; a new dep requires an ADR (spec 10 §11) and reviewer approval.
- **Pinned-deps check:** `Package.resolved` committed and unchanged unless the PR intends it; floating
  requirements (`branch:`/`from:` without a lock) rejected (NFR-054).
- **SBOM diff:** regenerate the SPDX SBOM (spec 32 §11) and diff against the last release's — surface
  added components for review.
- **Secret scanning / push protection** enabled repo-wide; a leaked signing cred is rotated per §11.
- **No-egress assertion in CI:** the `T-no-egress` test (spec 31 §8) runs under a network-blocking
  harness so a stray network call in the core path fails a PR (NFR-060).

## 8. Caching

| Cache | Key | Scope |
|---|---|---|
| SPM checkouts + `.build` per-target artifacts | `spm-<runner>-<Package.resolved hash>-<Sources hash>` | per runner/arch; per-target incremental (spec 12 §7 DAG parallelism) |
| Toolchain | pinned Swift version (setup-swift cache) | shared |
| Benchmark fixtures | `fixtures-<FixtureCatalog hash>` | reused across runs (spec 30 §5 — build once) |
| Benchmark baselines | committed in-repo `Benchmarks/.baselines/<machine>` | not a cache; versioned |

Cache is keyed so a `Package.resolved` change invalidates dep caches (correctness) while a pure source
edit reuses dependency builds and only recompiles changed targets (the leaf-`CleanerCore`-rarely-changes
property, spec 12 §7). Restore-keys give partial-hit warm starts.

## 9. Required status checks (branch protection on `main` and `release/*`)

The following must be green to merge (configured on the protected branches, spec 33 §4):

- `safety-suite` (100 %, no skips) — **the non-negotiable one**.
- `build-test (macos-14 arm64)` and `build-test (macos-13 x86_64)` — build + all non-stress tests +
  strict-concurrency + lint + coverage + `doctor --ci` + headless link + traceability.
- `dependency-review` / `security`.
- `bench / pr-subset` **when the `perf` label/path filter applies**.
- Linear history / signed commits per policy; ≥ 1 review; conversations resolved.

A PR cannot merge with any of these red. Admins do not bypass the safety gate (Principle 1).

## 10. CI-mode (`--ci`) exit-code contract

`--ci` makes commands non-interactive, machine-parseable (JSON to stdout, diagnostics to stderr — spec
08), and maps outcomes onto Constitution Art. 7 exit codes so pipelines can branch on `$?`:

| Command (`--ci`) | Exit semantics |
|---|---|
| `cleaner doctor --ci` | **0** healthy · **3** warnings · **1** critical (Constitution Art. 7 CI mapping). |
| `cleaner analyze --ci --json` | **0** ok (findings streamed as JSON) · **4** permission (FDA missing) · **6** bad config · **10** unsupported OS. |
| `cleaner clean --ci --yes --json` | **0** all requested items cleaned · **3** partial (some skipped/failed — report lists them, NFR-035) · **4** permission · **8** safety-invariant abort (protected-path attempt) · **5** cancelled/timeout · **7** plugin contract violation. |
| any command, bad flags | **2** usage (ArgumentParser). |

`--ci` implies `--no-tui --no-color --yes`-is-still-explicit (it does **not** imply `--yes`; a `clean`
in CI without `--yes` and without a signed policy refuses destructive work and exits 2/5 — Principle 1,
no unattended deletion by accident). These codes are asserted by `T-doctor-ci-exit` and per-flow
integration tests (spec 31 §5/§12). A CI consumer treats **0** as success, **3** as "review the report",
and everything else as failure.

## 11. Secrets management

Release secrets live only in a protected **GitHub Environment** (`release`) with required reviewers; PR
workflows from forks **cannot** access them (default GitHub behavior — signing never runs on untrusted
PRs):

| Secret | Use | Handling |
|---|---|---|
| `DEVELOPER_ID_CERT_P12` (+ `_PASSWORD`) | codesign (spec 32 §4) | imported into a throwaway keychain per job, deleted in `always()` cleanup |
| `NOTARY_APPLE_ID`, `NOTARY_TEAMID`, `NOTARY_APP_PW` | notarytool (spec 32 §5) | or a `notarytool store-credentials` keychain profile |
| `RELEASE_MINISIGN_SECKEY` (+ `_PASSWORD`) | sign checksums (spec 33 §6) | never logged; public key pinned in repo/self-updater |
| `TAP_REPO_TOKEN` | open the Homebrew bump PR (spec 33 §7) | fine-scoped PAT/app token to the tap repo only |

Keychain is created with `security create-keychain` on a random path, unlocked for the job, and
**destroyed on exit** (`security delete-keychain` in an `if: always()` step). No secret is ever echoed;
`set -x` is off in signing steps.

## 12. Release pipeline (`release.yml`)

Triggered by a signed tag `vX.Y.Z[-pre]` (spec 33 §4). Sequence mirrors spec 32/33:

```yaml
name: release
on: { push: { tags: ["v*"] } }
jobs:
  gate:                                   # re-run the hard gates before we build/sign anything
    uses: ./.github/workflows/safety.yml  # reusable: safety suite 100 %
  build-sign-notarize:
    needs: gate
    runs-on: macos-14
    environment: release                  # required-reviewer approval + secrets (§11)
    timeout-minutes: 60
    steps:
      - uses: actions/checkout@<sha>
        with: { fetch-depth: 0 }          # need tags for version stamp (spec 32 §11)
      - name: Assert clean tagged tree
        run: scripts/assert-clean-tag.sh  # refuse -dirty (spec 32 §11)
      - uses: swift-actions/setup-swift@<sha>
        with: { swift-version: "6.0" }
      - name: Build universal + strip + dSYM        # spec 32 §3
        run: scripts/build-universal.sh "${GITHUB_REF_NAME#v}"
      - name: Import signing keychain               # §11
        run: scripts/import-signing-cert.sh
      - name: Codesign (hardened runtime, entitlements)   # spec 32 §4/§6
        run: scripts/codesign.sh
      - name: Notarize + staple                     # spec 32 §5
        run: scripts/notarize.sh
      - name: Gatekeeper assess
        run: spctl --assess --type execute --verbose=4 .build/cleaner-universal
      - name: Package tarball + completions + man   # spec 32 §8/§9
        run: scripts/package.sh
      - name: Checksums + minisign signature        # spec 33 §6
        run: scripts/checksums-sign.sh
      - name: SBOM (SPDX)                            # spec 32 §11, NFR-054
        run: scripts/sbom.sh
      - name: Size gate                             # NFR-122
        run: scripts/size-gate.sh                   # <25MB binary / <40MB footprint
      - name: Create GitHub Release + upload artifacts   # spec 33 §6
        run: scripts/publish-release.sh
      - name: Bump Homebrew tap (PR)                # spec 33 §7
        if: ${{ !contains(github.ref_name, '-') }}  # stable only
        run: scripts/bump-tap.sh
        env: { GH_TOKEN: ${{ secrets.TAP_REPO_TOKEN }} }
      - name: Cleanup keychain
        if: always()
        run: security delete-keychain "$RUNNER_KEYCHAIN" || true
```

The `environment: release` protection means a human approves before secrets are exposed and the artifact
is published (spec 33 §10 human gates + beta→stable promotion). Nightly (`nightly.yml`) reuses
`build-universal.sh` but publishes to a pre-release without the tap bump (spec 33 §3).

## 13. Failure handling & observability

- **Fail fast on gates, fail-soft on matrix breadth:** `fail-fast: false` across the OS/arch matrix so
  one arch's failure still reports the other; but any single required check red blocks merge (§9).
- **Flaky-test policy:** no automatic retries on the safety suite (a flake is a bug). Non-safety flakes
  are quarantined via a tracked issue + a `.flaky` tag excluded from the gate *only* with an owner and a
  deadline — never silently.
- **Artifacts on failure:** test logs, coverage reports, benchmark JSON, and (release) the notary log are
  uploaded as workflow artifacts for triage.
- **Status → dashboard:** benchmark trends (spec 30 §10) and the traceability matrix (spec 31 §13) are
  published to GitHub Pages from `main`.

## Open Questions

- **OQ-34.1** Notarization latency (minutes, sometimes longer) makes `release.yml` slow/occasionally
  flaky on Apple's side — do we need a submit-then-poll split job with a longer timeout and retry-on-
  Apple-5xx? *Leaning: yes, wrap notarytool with bounded retry on transient service errors only.*
- **OQ-34.2** Self-hosted reference runners (spec 30 §9) need maintenance & security hardening (they
  hold no release secrets, but run PR-adjacent code on schedule). Ephemeral VM per run vs. a pinned box?
  *Leaning: pinned box, scheduled-only, no PR-triggered code from forks.*
- **OQ-34.3** Should the `perf` benchmark gate be blocking on every hot-path PR or advisory-with-override?
  *Leaning: blocking with the explicit `perf-baseline-change` escape (spec 30 §8.2).*
- **OQ-34.4** GitHub-hosted macOS runner minutes cost for the full matrix + nightly — do we push more to
  self-hosted to control cost, accepting maintenance? *Leaning: PR on GitHub-hosted, heavy nightly on
  self-hosted.*
- **OQ-34.5** Do we gate merges on the `macos-15` (newest) runner too, or keep it nightly-only until it's
  GA-stable as a hosted image? *Leaning: nightly-only until stable, then add to PR matrix.*

## Dependencies

**Consumes:** 00 (Art. 7 exit codes for the `--ci` contract, Art. 6 lint conventions, CC-9 test/bench,
CC-11 distribution), 07 (every gated NFR: 033 strict concurrency, 034 coverage, 054 supply chain, 080
i18n, 090/091 OS/arch matrix, 101 acyclicity, 103 suite time, 122 size), 12 (per-target build/cache,
module DAG acyclicity check), 30 (benchmark regression gate & fixtures cache), 31 (safety gate, coverage
gate, traceability check, `doctor --ci` self-test), 32 (build→sign→notarize→staple→SBOM→size-gate
steps), 33 (tag trigger, channels, release checklist, tap-bump automation, secrets/environment
protection).

**Feeds:** the whole suite's Definition of Done — this pipeline is where every other spec's gate is
mechanically enforced before code merges or ships.
