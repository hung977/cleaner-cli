# 35 — Security Review

> **Phase E · Depends on:** 00-constitution (Articles 4, 5, 6, 10; CC-8/11/12), 10-tech-stack
> (dependency policy, native-first, shell-out adapters), 13-plugin-architecture (trust model,
> capabilities), 15-data-model (audit log, staging manifest, config), 16-filesystem-strategy
> (canonicalization, TOCTOU, symlink/dataless), 22-safety-model (`SR-###`), 23-permission-model
> (`SR-1xx`, entitlements), 24-config, 36-threat-model (`THR-###`) ·
> **Depended on by:** 32/33/34 (release integrity), 39 (risk register), 13 (v2 plugin security).

## 1. Purpose & scope

A systematic review of **cleaner-cli's own security posture** — not the security of the user's
machine in general, but whether *this tool*, given its power to read and delete across the disk, can
be turned into a weapon or made to fail unsafely. It complements spec 22 (which prevents *wrong
deletions* by design) and spec 23 (privileges) by covering the classic application-security surface:
input validation, path/symlink attacks, TOCTOU, injection, untrusted plugins, supply chain, audit
integrity, secrets, safe defaults, DoS, and privilege boundaries.

This spec is organized as a **security checklist** with numbered items `SEC-###`, each stating the
control, its rationale, the threat(s) it mitigates (`THR-###` from spec 36), and the enforcing
requirement (`SR-###` from specs 22/23) where one exists. The checklist is a **release gate**
(spec 33): every `SEC-###` must be "met" (with a test) or explicitly "accepted residual" before a
release.

**Posture summary.** Native-first (fewer shell surfaces), least-privilege (spec 23), reversible-by-
default (staging), no network in the core path (Principle 10), untrusted-plugin-output even for
first-party plugins (spec 22 axiom), and defense-in-depth so no single bug causes data loss.

## 2. Review methodology

- **STRIDE-driven:** each control traces to a threat in spec 36.
- **Assume-breach for plugins & input:** treat all plugin output and all external input as hostile,
  even in v1 where plugins are first-party (spec 13 § 11).
- **Test-backed:** every control has an automated test (spec 31) — a fuzz test, a negative test, or
  a property test — or is an explicitly-accepted residual (spec 36 § 7).
- **Data-loss-first triage:** a control that prevents a wrong *deletion* outranks one that prevents
  a crash or disclosure (Constitution Principle 1).

## 3. Input validation (config, paths, plugin data) — TB1/TB2

| ID | Control | Mitigates | Enforced by |
|---|---|---|---|
| **SEC-01** | **Config schema validation.** `config.yml` is parsed by Yams into typed models and validated against the spec-24 schema before use; unknown keys are rejected or ignored per policy, types are checked, and invalid config exits **6** (`config`). No config value is used as an unchecked path or command. | THR-014 | spec 24; SR-042 |
| **SEC-02** | **Environment sanitization.** `CLEANER_HOME`, `SUDO_USER/UID`, `NO_COLOR`, `PATH` are read defensively: `CLEANER_HOME` is canonicalized and confined to a writable, user-owned location; the real user under `sudo` is resolved safely (SR-123); the tool never trusts `PATH` to locate a security-relevant external binary (see SEC-11). | THR-004 | SR-123 |
| **SEC-03** | **Target-rule / glob validation.** User `extraTargets`, `extraProtected`, and `--exclude`/`--include` globs are canonicalized (spec 16 § 9) and pass the allow∩roots−deny gate before use; a target that resolves into the deny-list is rejected, not silently dropped. Overly-broad globs (e.g. `~/**`) trigger a warning (spec 26). | THR-013 | SR-040, SR-043 |
| **SEC-20** | **Plugin output is untrusted.** Every `Finding` from a plugin has its path canonicalized, its `isProtected`/`PathConfidence` re-derived by the engine, and its safety re-scored; a plugin cannot raise a score, assert `.high` confidence, mark itself first-party, or point at an out-of-root path (all such outputs are rejected/tightened). | THR-002, THR-017, THR-053 | SR-011, SR-020, SR-030, SR-032 |
| **SEC-21** | **Plugin capability enforcement.** Plugins never call the filesystem directly; all access goes through the engine's `FilesystemService` behind the safety gate. Declared `capabilities`/`usesShellOut`/`requiresElevation` are enforced; a scan-only plugin cannot mutate; an undeclared shell-out is refused (exit 7). | THR-053 | spec 13 § 11 |

**Principle:** *validate at the boundary, canonicalize before deciding, re-derive trust in the
engine.* No component downstream re-parses raw input.

## 4. Path traversal & symlink attacks — TB1/TB2, filesystem

| ID | Control | Mitigates | Enforced by |
|---|---|---|---|
| **SEC-04** | **No symlink following on delete walks; canonical allow/deny.** Enumeration opens directories `O_NOFOLLOW|O_DIRECTORY`; the canonical, symlink-resolved path (and its real parent) is checked against `(⋃ roots ∩ allowSpace) − denyList` with component-boundary prefix matching (so `~/.sshx` ≠ `~/.ssh`). Deleting a symlink removes only the link, never the target. | THR-010, THR-011 | SR-035, SR-040 |
| **SEC-05** | **Hardlink safety.** `st_nlink>1` is detected; reclaim is credited only when all links live within allowed roots; a hardlink pointing an inode into protected space never causes that inode to be targeted. | THR-012 | spec 16 § 6; SR-034 |
| **SEC-03b** | **`..` and Unicode normalization.** Paths are lexically resolved (`.`/`..`) then `realpath`-resolved then NFC-normalized before any allow/deny decision or `FindingID` derivation, so encoding tricks or `..` cannot smuggle a path across a boundary. | THR-013 | spec 16 § 9; SR-040 |

## 5. TOCTOU (time-of-check to time-of-use) — filesystem

| ID | Control | Mitigates | Enforced by |
|---|---|---|---|
| **SEC-04t** | **fd-relative mutation with identity re-check.** Mutations operate relative to an already-verified parent directory fd using the `*at` family (`openat`, `fstatat`, `unlinkat`, `renameatx_np`). Immediately before the mutating syscall, the engine re-opens the target `O_NOFOLLOW`, `fstat`s it, and verifies `(dev, inode, type, nlink)` match the scan record; on drift it aborts that item (skip + report). The full path string is never re-resolved at act time. | THR-010 | SR-061, SR-063; spec 16 § 9 |
| **SEC-04v** | **Re-validate protection & volume at execute.** Protected-path, system/read-only-volume, mount-root, in-use, and dataless/snapshot checks are re-run at execute time, not trusted from scan time. A re-validation failure yields `blockedBySafety` (exit 8) for that item without aborting the whole run. | THR-010, THR-050 | SR-061, SR-062, SR-038 |

## 6. Injection into shell-fallback adapters — TB3

The tool prefers native APIs (Principle 4); the few unavoidable shell-outs (`docker system df`,
`xcrun simctl`, `brew`, read-only `tmutil`) are isolated behind adapters (spec 13).

| ID | Control | Mitigates | Enforced by |
|---|---|---|---|
| **SEC-11** | **No shell interpretation, ever.** Adapters spawn subprocesses via `Foundation.Process`/`posix_spawn` with an **explicit `argv` array** and an **absolute executable path** (or a strictly allow-listed, path-resolved tool). Never `sh -c`, never string concatenation, never `system()`. No user/plugin/filesystem value is ever interpolated into a shell string. Values passed as arguments are validated (no NUL, length-bounded) and passed as *separate argv elements*, so they cannot become flags/commands. | THR-054 | SR-134 |
| **SEC-12** | **Scrubbed, minimal subprocess environment.** Adapters run with a minimal, sanitized environment (controlled `PATH`, no inherited secrets), a bounded working directory, no stdin unless required, captured stdout/stderr with size caps, and **no** secret values in argv or env. | THR-034 | SR-135 |
| **SEC-11t** | **Timeout & cancellation.** Every adapter call is timeout-bounded and cancellation-aware; a hung external tool is killed and its failure is non-fatal (contributes a `partial`, exit 3), never a hang of the whole run. | THR-043 | SR-133 |
| **SEC-11o** | **Untrusted output parsing.** Adapter stdout is parsed defensively (size-capped, typed, tolerant of garbage) and treated as *hints*, never as authoritative paths to delete without the engine's own allow/deny + TOCTOU checks. | THR-054, THR-017 | SR-020, SR-061 |

New requirements introduced by this section (registered into the safety-requirement namespace so the
threat model can cite them):

- **SR-131** *(defined here)* All external-tool invocation uses an argv array + absolute/allow-listed
  path; shell interpolation is banned repo-wide (lint-enforced).
- **SR-132** *(defined here)* Adapter output is size-capped and never used as a delete target without
  re-running the engine safety gate.
- **SR-133** *(defined here)* Every adapter call is timeout-bounded and cancellable; failure is
  non-fatal.
- **SR-134** *(alias of the shell-injection control)* No shell metacharacter reaches an external
  process; arguments are validated and passed as discrete argv elements.
- **SR-135** *(defined here)* Subprocess environment is minimal and secret-free.

## 7. Untrusted plugin code — TB2

| ID | Control | Mitigates | Notes |
|---|---|---|---|
| **SEC-20** | (see § 3) Engine re-derives all trust from plugin output. | THR-002/017/053 | v1 & v2 |
| **SEC-22** | **v1: static, first-party, compile-time registry only.** There is no dynamic loading, no `dlopen`, no third-party plugin path in v1 — the trust boundary is the compiled binary (spec 13 § 3/5). The attack surface of "untrusted plugin code" is therefore **empty** in v1 by construction. | THR-002 | v1 |
| **SEC-23** | **v2/v3 third-party plugins (design-gated).** Any future third-party plugin support requires: mandatory Developer-ID signing + notarization of the plugin, capability restriction (no elevation without a named reason), reserved-namespace enforcement (`dev.cleaner.*` is first-party only), and (v3) out-of-process XPC isolation so a plugin cannot corrupt or hang the host. Enabling third-party plugins re-triggers this security review and the threat model (spec 36 RR-3). | THR-002/044 | v2/v3, deferred |

## 8. Supply chain — TB5

| ID | Control | Mitigates | Enforced by |
|---|---|---|---|
| **SEC-30** | **Dependency pinning & audit.** Every third-party dependency is pinned to an exact version, license-reviewed, and vendor-audited before any bump (spec 10 § 11). The allowed dependency set is closed (swift-argument-parser, swift-log, swift-metrics, swift-collections, Yams, package-benchmark [test], a color/terminal-size helper). No dependency performs network I/O in the core path. | THR-001, RR-4 | spec 10 § 11 |
| **SEC-31** | **Signed, notarized releases with checksum pinning.** Release binaries are built with the hardened runtime, signed with Developer ID, notarized (and stapled where possible), and published with SHA-256 checksums; the Homebrew formula pins the checksum, so a tampered artifact fails install-time verification. | THR-001 | SR-124, SR-127 |
| **SEC-32** | **Reproducible, provenance-tracked builds.** CI builds are pinned (toolchain version, dependency graph) and release provenance is recorded (spec 33/34), so an unexpected artifact is detectable. Signing keys live only in CI secret storage, never in the repo. | RR-4 | spec 33/34 |
| **SEC-33** | **No post-install code fetch.** The tool never downloads or executes code at runtime (no self-update that runs unsigned code, no remote plugin fetch in v1). Updates come through the signed channel only (CC-11). | THR-001 | Principle 10 |

## 9. Audit log as tamper-evidence — A4

| ID | Control | Mitigates | Enforced by |
|---|---|---|---|
| **SEC-13** | **Append-only, hash-chained audit.** Every filesystem mutation and every consent decision is written as an append-only NDJSON event (spec 15 § 6, spec 28), each record carrying the hash of the previous record (a hash chain) so truncation, reordering, or edits are detectable. The audit sink is engine-owned; plugins cannot suppress it. `doctor` verifies chain integrity. | THR-015, THR-020, THR-021 | SR-060, SR-128 |
| **SEC-14** | **Staging integrity.** The staging manifest records full restore metadata and a content checksum captured *before* the move; rollback verifies the checksum before restoring, so corrupted/substituted staged data is caught. Staging and audit dirs are deny-listed and per-session locked. | THR-016 | spec 15 § 5; SR-052 |

**Residual (RR-1):** a root attacker can still rewrite these files; the hash chain provides
*detectability*, not prevention (spec 36 § 7). Accepted for v1.

## 10. Secrets & credential paths — A1, info disclosure

| ID | Control | Mitigates | Enforced by |
|---|---|---|---|
| **SEC-06** | **Never read secret contents.** Scanning reads **attributes only**, never file contents (spec 16 § 2). `~/.ssh`, `~/.gnupg`, Keychains, credential config, `*.key`/`*.pem`/private material are deny-listed (Article 5) — never enumerated for deletion, never opened. The FDA probe checks accessibility, not content (prefer a directory listing over opening `TCC.db`). | THR-030, THR-032 | SR-034, SR-103 |
| **SEC-07** | **No secrets in logs/reports/telemetry; local-only.** Logs and reports store paths + metadata, never file contents; argv is sanitized of secrets before audit (spec 14 § 4.15); telemetry is off by default and local-only unless opted in (CC-12); no network I/O in the core path. | THR-033, THR-034 | Principle 10; CC-12 |
| **SEC-08** | **No iCloud/dataless materialization.** Placeholder files are never faulted-in or deleted (attributes-only enumeration; dataless exclusion gate). | THR-031 | SR-026 |

## 11. Safe defaults — cross-cutting

| ID | Control | Mitigates | Enforced by |
|---|---|---|---|
| **SEC-50** | **Reversible by default.** Default disposition is `.stage`; permanent `.purge` is an explicit escalation with confirmation. Nothing is `unlink()`-ed when a recoverable path exists. | data loss (RR-2) | SR-052, SR-053, SR-055 |
| **SEC-51** | **Conservative safety defaults.** Nothing is pre-selected for permanent removal — everything is staged and recoverable via `cleaner undo`. `--yes` cleans all detected items but protected paths stay hard-blocked; missing evidence is handled conservatively by refusing to act outside allowed roots. When in doubt, don't. | THR-017; F1 | SR-015, SR-029, SR-045, SR-057 |
| **SEC-52** | **No network, no telemetry, no self-update code execution by default.** Privacy-by-default; the core cleaning path makes zero network calls. | THR-033 | Principle 10; CC-12 |
| **SEC-53** | **Fail safe, not open.** Any ambiguity, error, or unmet permission on a *destructive* path results in *not acting* (skip + report), never in acting anyway. Errors map to precise exit codes (4/6/7/8/10). | F1/F2 | SR-062; spec 27 |

## 12. Denial of service — DoS resilience

| ID | Control | Mitigates | Enforced by |
|---|---|---|---|
| **SEC-09** | **Bounded traversal.** Iterative fd work-queue (no recursion), `(dev,inode)` cycle detection → `SkipReason.cycle`, `maxDepth` bound → `SkipReason.tooDeep`, streaming enumeration + streaming size sums keep memory O(depth × buffer). A symlink loop or pathological tree cannot hang or OOM the tool. | THR-040, THR-041 | spec 16 §§ 2, 13 |
| **SEC-10** | **Bounded metadata capture.** xattr/ACL values are size-capped with a `truncated` flag; no content decompression during scan; per-entry work is bounded so a bomb file cannot blow up memory. | THR-042 | spec 16 § 5 |
| **SEC-11t** | (see § 6) Adapter timeouts prevent a hung subprocess from wedging the run. | THR-043 | SR-133 |
| **SEC-24** | **Plugin liveness (v2/v3).** Per-plugin timeout + cancellation; v3 out-of-process isolation so a runaway plugin cannot hang the host. v1 relies on static review. | THR-044 | spec 13 § 8 |

## 13. Privilege boundaries — TB4/TB6

| ID | Control | Mitigates | Enforced by |
|---|---|---|---|
| **SEC-40** | **Least privilege; unrelaxable deny-list.** The tool runs as the invoking user; the protected-path deny-list is enforced identically and cannot be relaxed even as root. System/read-only volumes and mount roots are refused. v1 performs no root-owned mutation. | THR-050 | SR-038, SR-042, SR-115, SR-121 |
| **SEC-41** | **No deprecated/insecure elevation.** `AuthorizationExecuteWithPrivileges` is banned. Elevation, if ever added, is a notarized `SMAppService` XPC helper with a narrow enumerated interface. | THR-051 | SR-113, SR-114 |
| **SEC-42** | **Privileged boundary trusts nothing.** A future root helper re-validates every operation against the full safety model inside the root context and verifies the XPC peer's code-signing identity; approval on the unprivileged side does not transfer trust. | THR-052, THR-003 | SR-114, SR-119, SR-126 |
| **SEC-43** | **Minimal entitlements & hardened runtime.** No App Sandbox (incompatible with purpose), no `get-task-allow` in release, no library-validation/JIT exceptions; every entitlement is justified or removed. | THR-051 | SR-125 |

## 14. Security checklist (release gate)

Every item is `met` (test-backed), `n/a-v1` (deferred surface, e.g. third-party plugins), or
`accepted-residual` (spec 36 § 7). A release (spec 33) is blocked on any `unmet` item.

| SEC | Area | Status (v1 target) | Test (spec 31) |
|---|---|---|---|
| SEC-01 | Config validation | met | config-fuzz, invalid-config → exit 6 |
| SEC-02 | Env sanitization | met | env-injection negative tests |
| SEC-03 / 03b | Target/glob & `..`/Unicode | met | path-algebra fuzz |
| SEC-04 / 04t / 04v | Symlink + TOCTOU | met | symlink-swap race test, identity-drift test |
| SEC-05 | Hardlink safety | met | hardlink-cluster tests |
| SEC-06 / 07 / 08 | Secrets / disclosure / dataless | met | deny-list tests, no-content-read assertion, telemetry-off |
| SEC-09 / 10 | DoS traversal & metadata | met | symlink-loop, deep-tree, bomb-xattr tests |
| SEC-11 / 11t / 11o / 12 | Shell-out injection/timeout/env | met | argv-only assertion, injection corpus, timeout test |
| SEC-13 / 14 | Audit chain & staging integrity | met | chain-tamper detection, restore-checksum test |
| SEC-20 / 21 | Plugin output/capability | met | forged-Finding tests, capability-violation tests |
| SEC-22 | v1 static registry | met | no-dynamic-load assertion |
| SEC-23 / 24 | v2/v3 third-party plugin | n/a-v1 | (gated; re-review on enable) |
| SEC-30 / 31 / 32 / 33 | Supply chain | met | pinned deps, checksum-verify, notarization check in CI |
| SEC-40 / 41 / 42 / 43 | Privilege boundaries/entitlements | met | root-guard test, no-AEWP lint, entitlement audit |
| SEC-50 / 51 / 52 / 53 | Safe defaults | met | default-stage test, --yes-stages-all test, fail-safe tests |

## 15. Findings & recommendations

- **Strengths.** Native-first shrinks the injection surface; untrusted-plugin-output-even-in-v1 and
  engine-side trust re-derivation remove a whole class of confused-deputy bugs; staging-by-default
  turns most residual mistakes into recoverable ones; the deny-list is unrelaxable even as root.
- **Weakest links (drive the risk register, spec 39).**
  1. **First-party plugin false positives** (RR-2 / RISK-001) — the dominant data-loss path; mitigated
     but not eliminated. *Recommendation:* invest heavily in the detection test corpus (spec 31) and
     keep staging as the safety net; never let a plugin bug bypass the scorer gates.
  2. **Audit/staging tamper by an already-root attacker** (RR-1) — detectability only. *Recommendation:*
     document the boundary; consider external chain anchoring in v2 (spec 36 OQ-36.1).
  3. **Supply-chain upstream of signing** (RR-4). *Recommendation:* pin + audit deps, record build
     provenance, minimize the dependency set.
- **Action items feeding other specs:** enforce the shell-injection ban via a repo lint (SEC-11);
  add the audit hash-chain to spec 28's format; add checksum-verify + notarization checks to the CI
  gate (spec 34); add the security checklist to the release runbook (spec 33).

## Open Questions

- **OQ-35.1** Should the shell-injection ban (SEC-11) be enforced by a custom SwiftSyntax lint rule
  in CI (detect `Process` with a shell path or string interpolation), or by code review + a wrapper
  type that makes argv-only the *only* constructible form? *Leaning: a wrapper `ExternalCommand`
  type (argv-only by construction) plus a lint backstop.*
- **OQ-35.2** Do we ship a `cleaner security-selfcheck` command (verify deny-list coverage, adapter
  allow-list, entitlements, audit-chain) as a user-facing control, or keep it internal to `doctor`?
  *Leaning: fold into `doctor --security`.*
- **OQ-35.3** For SEC-30, do we adopt an SBOM (software bill of materials) in v1 or defer? *Leaning:
  generate a minimal SBOM in CI (cheap given the closed dep set); full SLSA provenance is v2.*
- **OQ-35.4** Is checksum pinning in the Homebrew formula sufficient, or do we also want signed
  release manifests (e.g. minisign) users can verify independently? *Leaning: add a signed
  `SHA256SUMS` in v1.1; notarization + formula checksum covers v1.*
- **OQ-35.5** Should adapter output parsing (SEC-11o) run in a resource-limited child task with its
  own memory cap, given untrusted output size? *Leaning: size-cap the captured bytes (already
  required); a full cgroup-style limit is overkill on macOS for v1.*

## Dependencies

**Consumes:** 00-constitution (Articles 4/5/6/10; CC-8 static plugins, CC-11 notarization,
CC-12 telemetry-off), 10-tech-stack (dependency policy, native-first, adapter isolation),
13-plugin-architecture (trust model, capabilities, static registry, shell-out justification),
15-data-model (audit NDJSON, staging manifest, config), 16-filesystem-strategy (canonicalization,
TOCTOU fd-relative ops, symlink/hardlink/dataless, bounded traversal), 22-safety-model
(`SR-###` invariants, scorer gates, defaults), 23-permission-model (`SR-1xx`, entitlements,
no-deprecated-elevation, root guard), 24-config (schema validation), 36-threat-model
(`THR-###` bi-directional mapping, residual risks).

**Feeds:** 32-packaging (hardened runtime, minimal entitlements, notarization), 33-release
(security checklist as release gate, signed checksums, provenance), 34-ci-cd (dependency pinning,
checksum/notarization checks, injection lint, negative-security tests), 39-risk-register
(`SEC-###`/`THR-###` → `RISK-###` security & safety rows), 13-plugin-architecture (v2 third-party
plugin security gate).
