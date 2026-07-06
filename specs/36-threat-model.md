# 36 — Threat Model

> **Phase E · Depends on:** 00-constitution (Articles 4, 5, 6, 10), 13-plugin-architecture
> (`TrustLevel`, static registry, shell-out adapters), 14-domain-model, 16-filesystem-strategy
> (canonicalization, TOCTOU, symlink/dataless rules), 22-safety-model (SR-### invariants),
> 23-permission-model (privilege boundaries), 35-security-review (mitigation detail) ·
> **Depended on by:** 35 (mitigation cross-ref), 39 (risk register), 32/33/34 (release integrity),
> 13 (v2/v3 plugin isolation).

## 1. Purpose, scope & method

This spec is the **systematic STRIDE threat model** for cleaner-cli. It enumerates *what can go
wrong on purpose* — adversarial and accidental-adversarial scenarios — and ties each to a mitigation
already required by the safety model (spec 22 `SR-###`), the permission model (spec 23 `SR-1xx`),
or the security review (spec 35). Threats are numbered `THR-###`.

**Method.** STRIDE (Spoofing, Tampering, Repudiation, Information disclosure, Denial of service,
Elevation of privilege) applied per trust boundary (§ 3). Each threat carries **likelihood** and
**impact** (H/M/L), a **STRIDE** category, and **mitigations** (cross-referencing `SR-###` and
spec 35 checklist items `SEC-###`). Residual risks are stated (§ 7) and flow into the risk register
(spec 39).

**Scope.** The tool's *own* security posture: the binary, its plugins (static in v1, third-party in
v2+), its shell-fallback adapters, its interaction with the OS/TCC, its on-disk state, and its
distribution channel. Out of scope: general macOS/TCC vulnerabilities, physical attacks, and
compromise of the developer's signing key material at rest (covered operationally in spec 33).

**Overriding property.** The *worst* outcome for this tool is **irreversible loss of user data**
(the existential risk, RISK-001 in spec 39). Every tampering/elevation threat is evaluated first
for "could this cause a wrong deletion?" because that dominates confidentiality/availability of the
tool itself.

## 2. Assets

| # | Asset | Why it matters | Primary protections |
|---|---|---|---|
| A1 | **User data on the filesystem** (documents, keys, media, source) | The thing we must never wrongly delete or read | Deny-list (Art. 5), safety model (spec 22), least-privilege (spec 23) |
| A2 | **The filesystem's integrity** (correct target of every mutation) | A confused-deputy write hits the wrong path | TOCTOU close-out (spec 22 § 11), fd-relative ops (spec 16 § 9) |
| A3 | **Staging quarantine** (`~/.cleaner/staging`) | Holds "deleted" items pending purge; the safety net for rollback | Owned dir, deny-listed, per-session manifest (spec 15/21) |
| A4 | **Audit log** (`~/.cleaner/logs/audit`) | Tamper-evidence: the record of every mutation and consent | Append-only NDJSON, hash-chain (spec 35), deny-listed |
| A5 | **Config & policies** (`config.yml`, signed automation policies) | Drives what is targeted and what is auto-authorized | Schema validation (spec 24), policy signing (spec 23), deny-listed |
| A6 | **The release binary & Homebrew formula** | Supply-chain root of trust for everyone who installs | Developer ID sign + notarize, pinned checksums (CC-11, spec 32/33) |
| A7 | **The invoking user's privileges** (incl. FDA, future root helper) | We hold real power over the disk; misuse = damage | Least-privilege, no silent escalation (spec 23), TCC |
| A8 | **The user's trust / truthful reporting** | A dishonest report could mask damage | Same-code dry/real measurement (Principle 3), audit |

## 3. Trust boundaries

```
                            ┌──────────────────── DISTRIBUTION CHANNEL ─────────────────────┐
                            │  GitHub Releases / Homebrew tap  (signed, notarized, checksum) │
                            └───────────────────────────────┬───────────────────────────────┘
                                                            │  TB5: channel ↔ user
                                                            ▼
   ┌──────────┐  TB1: user ↔ tool   ┌───────────────────────────────────────────────────────┐
   │  User /  │────CLI args, config─►│                  cleaner  (this process)               │
   │  Operator│◄───preview/report────│                                                        │
   └──────────┘                      │   ┌───────────────┐        ┌──────────────────────┐    │
                                     │   │ CleanerCore    │ TB2   │  Plugins             │    │
   ┌──────────┐  TB4: tool ↔ OS/TCC │   │ engine:        │◄──────│ v1 static/trusted    │    │
   │  macOS /  │◄───syscalls, TCC───►│   │ scorer, safety │ tool  │ v2+ third-party      │    │
   │  Kernel/  │    DiskArb, LS,     │   │ invariants,    │ ↔     │ (untrusted output)   │    │
   │  TCC      │    Spotlight        │   │ allow/deny,    │plugin └──────────┬───────────┘    │
   └──────────┘                      │   │ TOCTOU gate    │                  │ TB3: tool ↔     │
                                     │   └───────┬────────┘                  │ shell-fallback  │
        A1 A2 (filesystem) ◄─────────┼───────────┘                          ▼                 │
        A3 staging  A4 audit  A5 cfg │                         ┌────────────────────────────┐ │
        (all under ~/.cleaner,       │                         │ shell-out adapters         │ │
         deny-listed)                │                         │ (docker, simctl, brew…)    │ │
                                     └─────────────────────────┴────────────────────────────┘ │
                                                                                  (subprocess) │
   [v2] TB6: unprivileged ↔ privileged helper (XPC, SMAppService) — deferred, spec 23 §6      │
```

Trust boundaries:

- **TB1 — User ↔ tool.** Untrusted *input* (argv, config YAML, target rules, typed confirmations).
- **TB2 — Engine ↔ plugin.** In v1 plugins are first-party & static, but the engine **still treats
  plugin output as untrusted** (spec 13 § 11, spec 22 axiom). In v2+ plugins may be third-party.
- **TB3 — Tool ↔ shell-fallback adapters.** The tool spawns external tools (`docker`, `xcrun
  simctl`, `brew`, `tmutil` read-only) whose output and exit behavior are untrusted, and whose
  invocation must never allow argument injection.
- **TB4 — Tool ↔ OS / TCC.** The tool relies on the kernel/TCC for isolation and permission truth;
  it must not tamper with TCC or trust attacker-controllable ambient state.
- **TB5 — Distribution channel ↔ user.** From build artifact to the user's machine (Homebrew,
  GitHub Releases): the supply-chain boundary.
- **TB6 — Unprivileged ↔ privileged helper.** v2 only; the root helper trusts nothing from the
  unprivileged parent (spec 23 § 6).

## 4. Attacker personas

- **P1 — Malicious/hostile repository.** A cloned repo the user scans that deliberately plants
  crafted content: a `node_modules` full of symlinks pointing at `~/Documents`, a hardlink to a
  keychain, a directory named to look like a cache, a symlink loop, a decompression bomb. The
  attacker's goal: trick the cleaner into deleting or reading something outside the repo. (Primary
  driver of TB2/filesystem threats.)
- **P2 — Malicious third-party plugin (v2+).** A plugin the user installs that returns crafted
  `Finding`s: out-of-root paths, forged high safety scores, forged `.instant` recoverability, or
  attempts to shell out. (TB2.)
- **P3 — Compromised release channel.** An attacker who tampers with the GitHub release artifact,
  the Homebrew formula, or a dependency to ship a backdoored `cleaner`. (TB5.)
- **P4 — Local malware / co-resident process.** Malware already on the machine (no root) that wants
  to *leverage the cleaner's privileges* — e.g. race the cleaner into deleting a target, poison its
  config/policy, or tamper the audit log to hide its own tracks. (TB1/TB4/A4.)
- **P5 — Malicious config/policy author.** On a shared or managed machine, someone who edits
  `config.yml` or drops an automation policy to widen what gets auto-deleted. (TB1/A5.)

## 5. STRIDE threat enumeration

Likelihood/Impact are **H/M/L**. "Mitig." lists governing `SR-###` (spec 22 / spec 23) and spec 35
checklist ids (`SEC-###`).

### 5.1 Spoofing

| ID | Threat | Persona | L | I | Mitigations |
|---|---|---|---|---|---|
| **THR-001** | A tampered binary/formula masquerades as the official `cleaner` (typosquatted tap, fake release). | P3 | M | H | Developer ID signature + notarization (SR-124), pinned Homebrew checksum (SR-127), release provenance (spec 33), `SEC-30/31`. User verifies via `cleaner --version` + notarization. |
| **THR-002** | A third-party plugin spoofs a first-party `PluginID` (`dev.cleaner.*`) or `TrustLevel.firstParty`. | P2 | M | H | Compile-time static registry is the only v1 source of identity (spec 13 § 5); v2 signing + reserved-namespace enforcement; engine sets `isProtected`/trust, not the plugin. `SEC-20`. |
| **THR-003** | A privileged-helper client is spoofed by another process to issue root ops (v2). | P4 | L | H | Helper verifies XPC peer's code-signing identity/audit token (SR-114e, SR-126); `SMAuthorizedClients` requirement pinning. |
| **THR-004** | Ambient environment spoofing: attacker sets `CLEANER_HOME`, `SUDO_USER`, `PATH` to redirect the tool. | P4/P5 | M | M | Validate/normalize env (SEC-02); resolve real user safely under sudo (SR-123); shell-outs use absolute/allow-listed tool paths, not `$PATH` search (SR-134/`SEC-11`). |

### 5.2 Tampering

| ID | Threat | Persona | L | I | Mitigations |
|---|---|---|---|---|---|
| **THR-010** | **Symlink swap (TOCTOU):** between scan and delete, a path is replaced with a symlink to `~/Documents`/a keychain, so the tool deletes the target. | P1/P4 | M | **H** | fd-relative mutation with `O_NOFOLLOW`, `openat`+`fstat` identity re-check, re-run allow∩−deny on resolved path (SR-035, SR-061, SR-063; spec 16 § 9). `SEC-04`. |
| **THR-011** | **Symlink-out-of-root:** a crafted repo contains a symlink pointing outside the allowed root; the cleaner follows it and deletes the target. | P1 | M | **H** | Enumeration never follows symlinks (SR-035); canonical resolved path re-checked vs deny-list incl. real parent (SR-035, SR-040). Deleting a symlink removes only the link. `SEC-04`. |
| **THR-012** | **Hardlink to protected content:** a hardlink to a keychain/private key placed inside a cache dir; deleting "the cache file" risks the protected inode. | P1 | L | H | `st_nlink>1` detected; reclaim credited only if all links within allowed roots (spec 16 § 6); deny-list checked on canonical path; protected inode never targeted (SR-034, SR-040). `SEC-05`. |
| **THR-013** | **Path traversal via config/target rule:** `extraTargets` or a plugin root containing `..`/symlink smuggles a path into the deny-list. | P5/P2 | M | H | Canonicalize before allow/deny (SR-040); user targets pass allow∩−deny (SR-043); plugin roots are symbolic anchors, validated, `..`-free (SR-041; spec 13 § 4). `SEC-01/03`. |
| **THR-014** | **Config/policy tampering** to widen targets or auto-authorize deletions. | P5/P4 | M | H | Schema validation (spec 24); deny-list is compiled-in & non-overridable except signed policy naming a specific path, with absolute roots never unlockable (SR-042); policies are signature-verified (SR-058); config under deny-list. `SEC-01/22`. |
| **THR-015** | **Audit-log tampering** to erase evidence of a wrong/malicious deletion. | P4 | M | M | Append-only NDJSON with per-record **hash chain** (prev-hash) making truncation/edit detectable (`SEC-13`); log dir deny-listed & owned; `doctor` verifies chain integrity. Residual: a root attacker can still rewrite (§ 7). |
| **THR-016** | **Staging tampering:** attacker corrupts/removes staged items or the manifest so rollback restores wrong/incomplete data. | P4 | L | M | Manifest captures full restore metadata + checksums before move (spec 15 § 5, spec 16 § 11); restore verifies checksum; staging deny-listed & per-session locked (spec 15 § 12). `SEC-14`. |
| **THR-017** | **Plugin returns a Finding whose path ≠ what it scanned** (mutation between scan & report). | P2 | M | H | Engine re-derives `isProtected`, path confidence, and safety from the *canonical* path itself, not plugin claims (SR-011, SR-020, SR-032); execute-time re-validation (SR-061). `SEC-20/21`. |

### 5.3 Repudiation

| ID | Threat | Persona | L | I | Mitigations |
|---|---|---|---|---|---|
| **THR-020** | User (or attacker impersonating a run) denies that a destructive action was authorized ("I never said delete that"). | P4/P1 | L | M | Every action + its `ConfirmationState` + consent scope (`--yes`/policy) recorded in the audit log (SR-060, SR-128; Principle 8); typed-confirmation events logged (SR-049). `SEC-13`. |
| **THR-021** | A malicious run hides which files it touched by suppressing logging. | P2/P4 | L | M | Audit sink is engine-owned, not plugin-controllable (spec 10 § 8); mutations emit before/after audit events (spec 16 § 11) that a plugin cannot suppress; hash-chain detects gaps. `SEC-13`. |

### 5.4 Information disclosure

| ID | Threat | Persona | L | I | Mitigations |
|---|---|---|---|---|---|
| **THR-030** | Tool **reads secret file contents** (keys, keychains, `.env`) during scan/metadata and leaks them into logs/reports/telemetry. | P1/P5 | M | H | Scan reads **attributes only**, not contents (spec 16 § 2); secret paths deny-listed (Art. 5); `*.key`/`*.pem`/credential material never opened (SR-034); logs/reports store paths+metadata, never file contents; xattr values bounded/elided (spec 16 § 5). No network in core path (Principle 10). `SEC-06/07`. |
| **THR-031** | **Dataless (iCloud) file materialization**: scanning/deleting a placeholder forces a download, disclosing/consuming cloud data. | P1 | M | M | Attributes-only enumeration never faults data in; dataless files excluded (SR-026; spec 16 § 4.4). `SEC-08`. |
| **THR-032** | FDA probe reads a sensitive DB (`TCC.db`) and its contents leak. | — | L | M | Probe checks *accessibility*, reads no content; prefer probing a protected directory listing (spec 23 OQ-23.1); nothing from the probe is logged (SR-103). `SEC-06`. |
| **THR-033** | Report/telemetry export leaks the user's directory structure or filenames off-machine. | P5 | L | M | Telemetry off by default, local-only unless opted in (Principle 10, CC-12); reports stay local unless user exports (spec 15); no core-path network I/O. `SEC-07`. |
| **THR-034** | Shell-out adapter arguments/output leak sensitive paths into a subprocess environment visible to other users. | P4 | L | L | Adapters pass minimal args, sanitized env, no secrets in argv; subprocess env scrubbed (`SEC-11/12`). |

### 5.5 Denial of service

| ID | Threat | Persona | L | I | Mitigations |
|---|---|---|---|---|---|
| **THR-040** | **Symlink loop / cyclic directory** causes infinite traversal, hang, or unbounded memory. | P1 | M | M | No symlink following (SR-035); iterative fd work-queue with visited `(dev,inode)` cycle detection → `SkipReason.cycle`; `maxDepth` bound (spec 16 § 2, spec 14 SkipReason). `SEC-09`. |
| **THR-041** | **Pathological tree** (millions of tiny files / very deep nesting) exhausts memory or wedges the tool. | P1 | M | M | Streaming enumeration + streaming size sums, bounded memory O(depth×buffer) (spec 16 § 13); `tooDeep` skip; cooperative cancellation (spec 17). `SEC-09`. |
| **THR-042** | **Decompression/quota bomb** or a giant xattr value blows up memory when captured for staging. | P1 | L | M | xattr capture bounded with `truncated` flag past a cap (spec 16 § 5); no content decompression during scan. `SEC-10`. |
| **THR-043** | A **shell-out adapter hangs** (e.g. `docker` stuck) and stalls the whole run. | P1/P4 | M | M | Adapters are timeout-bounded, run in a child task, killed on timeout/cancel; failure is non-fatal (partial, exit 3) (spec 13; SR-133). `SEC-11`. |
| **THR-044** | A **malicious plugin** loops/allocates forever, hanging the engine (v2). | P2 | M | M | v1: static & reviewed. v2/v3: per-plugin timeout, cancellation, and (v3) out-of-process isolation so a plugin cannot wedge the host (spec 13 § 8). `SEC-21`. |

### 5.6 Elevation of privilege

| ID | Threat | Persona | L | I | Mitigations |
|---|---|---|---|---|---|
| **THR-050** | Tool is coerced into running a destructive op **as root** it shouldn't (e.g. via `sudo` + a crafted target reaching a system path). | P1/P4 | L | **H** | Deny-list unrelaxable under root (SR-121, SR-042); refuse system/read-only volume & mount roots (SR-038); v1 does no root-owned mutation at all (SR-115). `SEC-40`. |
| **THR-051** | **Insecure elevation primitive** (`AuthorizationExecuteWithPrivileges`) is abused to run arbitrary code as root. | P4 | L | H | Banned outright (SR-113). v2 uses `SMAppService` XPC helper with a narrow enumerated interface (SR-114). `SEC-41`. |
| **THR-052** | v2 **privileged helper** is tricked by the unprivileged parent (or a spoofed client) into an out-of-scope deletion. | P2/P4 | L | H | Helper re-validates every op against the full safety model inside the root context and trusts nothing from the caller (SR-114b, SR-119); peer code-signing check (SR-114e). `SEC-42`. |
| **THR-053** | **Plugin escapes its capability set** — a scan-only plugin performs a mutation, or a plugin shells out without declaring it. | P2 | M | H | Plugins never touch the filesystem directly; all mutation goes through the engine's `FilesystemService` + safety gate (spec 16 § 1, spec 13 § 11); `usesShellOut`/capabilities declared & enforced; injected-only capabilities (spec 13 § 13). `SEC-20/21`. |
| **THR-054** | **Argument/command injection** into a shell-fallback adapter yields arbitrary command execution. | P1/P2 | M | H | No shell interpolation ever: adapters use `Process`/`posix_spawn` with an **argv array**, absolute tool path, no `sh -c`, no string concatenation; all interpolated values are validated (SR-134; spec 35 `SEC-11`). `SEC-11/12`. |

## 6. Data-flow diagram (with trust boundaries and safety checkpoints)

```
 user argv ─TB1─►[ argparse + config validate (spec 24) ]──► resolved config/profile ─┐
 config.yml ─TB1─►[ schema validate, canonicalize targets (SR-040/43) ]───────────────┤
 policy    ─TB1─►[ signature verify (SR-058) ]────────────────────────────────────────┤
                                                                                       ▼
                                              ┌───────────────── CleanerCore ─────────────────┐
                                              │                                                │
 plugin roots (symbolic) ─TB2─► validate ─────►│  allow∩roots−deny  (SR-040/41/42)  ◄── deny-list│
                                              │            │                          (Art.5)   │
   FS attributes ◄────TB4──── getattrlistbulk │            ▼                                    │
   (attrs only, no  ─────────►[ enumerate (O_NOFOLLOW), cycle/depth guard (THR-040/41) ]        │
    content; SR-030) │                        │            │                                    │
                    │                         │            ▼                                    │
   shell adapters ◄─TB3─ argv array, timeout ─│      Evidence + Item (spec 14)                  │
   (no shell, SR-134)│                        │            │                                    │
                     │                        │            ▼                                    │
                     │                        │   SafetyScorer (spec 22) → risk/score/gates     │
                     │                        │            │                                    │
                     │                        │            ▼                                    │
                     │                        │   Findings ──► PREVIEW (TB1) ──► CONFIRM         │
                     │                        │            (confirm; --yes stages all, SR-049/045) │
                     │                        │            │                                    │
                     │                        │            ▼  CleanPlan (confirmed)             │
                     │                        │   EXECUTE: per-item TOCTOU re-validate (SR-061)  │
                     │                        │            fd-relative dispose (SR-035/63)       │
                     │                        │            │                                    │
                     ▼                        │            ▼                                    │
             (subprocess, sandboxed)          │   stage (default) → ~/.cleaner/staging (A3)     │
                                              │   audit event (A4, hash-chained) ◄── every op    │
                                              └────────────────────────────────────────────────┘
                                                             │
                                              report/JSON ─TB1─► user (truthful, SR-065/69)
```

Every arrow crossing a boundary is a validation point: **TB1** = input validation (spec 35 § input,
`SEC-01..03`); **TB2** = engine re-derivation of trust (SR-011/020/032); **TB3** = argv-only,
timeout-bounded subprocess (SR-134); **TB4** = attributes-only, TCC-honest (SR-030, spec 23);
**TB5** = signature/notarization/checksum at install (SR-124/127).

## 7. Residual risks

- **RR-1 — Root attacker can rewrite the audit log and staging.** The hash-chain (THR-015) makes
  *undetected* tampering hard for a non-root attacker, but a process already running as root can
  overwrite anything the tool owns. We do not defend against an already-root adversary of the host;
  this is out of scope (§ 1) and noted in the risk register (spec 39, RISK-sec). Mitigation ceiling:
  detectability, not prevention.
- **RR-2 — First-party plugin bug causing a false positive (F1, spec 22 § 2).** The safety model
  makes a *wrong* deletion require both a scoring miss and an invariant miss, but a first-party
  plugin bug that mislabels genuinely-user data as a cache remains the top residual (RISK-001).
  Mitigated by staging-by-default (recoverable), the scorer gates (SR-017/024), and the detection
  test corpus (spec 31), but not eliminated.
- **RR-3 — Third-party plugin trust (v2+).** v1 has no untrusted plugin code; v2's model (signing,
  capability restriction, out-of-process) is designed but unbuilt. Until then, third-party plugins
  are **not supported**, and that constraint is the mitigation. Enabling them requires re-running
  this threat model (spec 13 § 13).
- **RR-4 — Supply-chain compromise upstream of our signing.** A compromised *dependency* (before we
  build/sign) or a compromised build machine could ship a signed-but-malicious binary. Mitigated by
  dependency pinning + vendor audit (spec 10 § 11), reproducible-ish builds and release provenance
  (spec 33), but a determined upstream compromise is a residual (RISK-dep).
- **RR-5 — TCC/OS trust.** We rely on the kernel and TCC to be honest about permissions and
  isolation. A macOS TCC bypass vulnerability is outside our control; we neither depend on private
  TCC internals nor attempt to tamper (SR-110), limiting our exposure but not eliminating OS risk.

## 8. STRIDE ↔ mitigation coverage summary

| STRIDE | Top threats | Governing requirements |
|---|---|---|
| Spoofing | THR-001/002/003/004 | SR-124/127, SR-114e/126, SR-123/134; spec 13 registry |
| Tampering | THR-010…017 | SR-035/040/041/042/043/061/063, SR-058; SEC-01/04/05/13/14 |
| Repudiation | THR-020/021 | SR-049/060/128; engine-owned audit; SEC-13 |
| Info disclosure | THR-030…034 | SR-026/030/034/103; Principle 10; SEC-06/07/08 |
| DoS | THR-040…044 | streaming/bounded (spec 16 § 13), cycle guard, SR-133 timeouts; SEC-09/10/11 |
| Elevation | THR-050…054 | SR-038/042/113/114/115/119/121/134; SEC-40/41/42 |

## Open Questions

- **OQ-36.1** Should the audit hash-chain be strengthened to an append-only external anchor (e.g.
  periodic notarization of the chain head) to raise the bar against a root attacker (RR-1), or is
  detectability sufficient for v1? *Leaning: local hash-chain for v1; external anchoring is v2+.*
- **OQ-36.2** For THR-054, do we allow-list the *specific* external binaries an adapter may spawn
  (by absolute path + code-signing check) or only by absolute path? *Leaning: absolute path +
  version probe for v1; code-signing check on the spawned tool in v2.*
- **OQ-36.3** Is `tmutil listlocalsnapshots` (read-only, for reporting snapshot space) an acceptable
  shell-out given TB3, or does even a read-only adapter widen the surface unacceptably? *Leaning:
  acceptable behind an ADR, argv-only, read-only, timeout-bounded (spec 16 OQ-16.2).*
- **OQ-36.4** Should v1 verify its *own* binary integrity at startup (self-checksum / signature
  self-check) to detect post-install tampering (THR-001), or rely solely on Gatekeeper? *Leaning:
  rely on Gatekeeper + notarization; a self-check is trivially bypassable by the same attacker.*
- **OQ-36.5** How do we threat-model user-provided `--exclude`/target-rule globs that could
  *accidentally* widen deletion, versus adversarial ones? *Leaning: same canonical allow∩−deny gate
  applies (SR-043); UX warns on broad globs (spec 26).*

## Dependencies

**Consumes:** 00-constitution (Article 4.4 invariants, Article 5 deny-list, Principle 6/10,
CC-11), 13-plugin-architecture (`TrustLevel`, static registry, capability declaration, shell-out
adapters, v2/v3 isolation), 14-domain-model (`Finding`, `Evidence`, `SkipReason`,
`ConfirmationState`), 16-filesystem-strategy (canonicalization, TOCTOU fd-relative ops, symlink/
hardlink/dataless handling, streaming bounds), 22-safety-model (all `SR-###` invariants, scorer
gates, TOCTOU close-out), 23-permission-model (privilege boundaries, no-deprecated-elevation,
root guard rails, notarization/entitlements).

**Feeds:** 35-security-review (`SEC-###` checklist realizes these mitigations; bi-directional
cross-ref), 39-risk-register (`THR-###` → `RISK-###` security & safety rows), 13-plugin-architecture
(v2/v3 isolation gated on RR-3 re-review), 32/33/34 (release-integrity mitigations for TB5).
