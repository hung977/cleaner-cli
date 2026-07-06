# 23 — Permission Model

> **Phase E · Depends on:** 00-constitution (Principle 6 least-privilege, Article 7 exit codes,
> Article 8 layout, CC-11 notarization), 10-tech-stack (Security/Authorization Services,
> Foundation, DiskArbitration), 14-domain-model (`PluginDescriptor.requiresFullDiskAccess`,
> `PolicyRef`), 16-filesystem-strategy (permission-gated metadata, volume awareness), 22-safety-model
> (SR-015 missing-evidence scoring, SR-058 automation policies) ·
> **Depended on by:** 17 (scan degradation), 20 (elevated disposition), 27 (exit code 4),
> 32 (packaging/entitlements/notarization), 35 (security review), 36 (threat model).

## 1. Purpose & scope

Defines how cleaner-cli acquires, detects, degrades under, and requests the two macOS privileges
that matter for a disk cleaner:

1. **Full Disk Access (FDA)** — the TCC-gated privilege to read the many locations Apple protects
   by default (§ 3–5).
2. **Administrator / root elevation** — for the rare path owned by another user or by root (§ 6–8).

It is governed by Constitution **Principle 6 (least privilege)**: the tool runs as the invoking
user, requests elevation only for the specific operations that require it, never silently
escalates, and explains every request. It also fixes what v1.0 **will and will not** elevate for
(§ 9), the sandbox/entitlement/hardened-runtime posture needed for notarization (§ 10, feeding
spec 32), and `sudo` behavior (§ 8.4).

Every normative requirement carries an `SR-###` id (continuing the safety-requirement namespace
shared with spec 22; ids here are `SR-1xx` to avoid collision).

**Design axiom.** *Degrade, don't fail; scope, don't escalate.* Missing a privilege reduces what
the tool can see or do — it never reduces correctness or safety, and it is always reported
truthfully (Constitution Principle 3).

## 2. The two privileges at a glance

| Privilege | Mechanism | Granularity | Persistence | v1.0 stance |
|---|---|---|---|---|
| **Full Disk Access** | TCC (Transparency, Consent & Control), user-granted in System Settings | Per-binary (by code-signing identity / bundle id / path) | Persists until revoked | **Detect, guide, degrade** — never bypass |
| **Admin / root** | Authorization Services; privileged helper via `SMAppService` (deferred) | Per-operation ideal; process-wide with `sudo` | Per-authorization / session | **v1: refuse + explain**; scan-only for admin-owned paths |

## 3. Full Disk Access — why it is needed

macOS TCC protects a growing set of locations even from a process running as the user: `~/Library/`
subtrees (Mail, Messages, Safari, Containers, Group Containers, Application Support for protected
apps), `~/Library/Caches` for TCC-protected apps, Time Machine areas, and others. A disk cleaner
whose entire job is to find reclaimable junk in exactly those Library subtrees is **materially
crippled without FDA**: many plugins (browser caches, Mail attachments, container caches, developer
tool caches under protected Application Support) will see `EPERM`/empty enumerations.

- **SR-101** The tool MUST function **without** FDA, degrading gracefully (§ 5), and MUST clearly
  report what it could and could not scan (Constitution Principle 3). FDA is an enhancement, never
  a precondition for the tool to run at all.
- **SR-102** Plugins declare `requiresFullDiskAccess` (spec 14 § 4.11). The engine uses this to
  (a) warn before a scan that certain plugins will be limited without FDA, and (b) attribute empty
  results to permission, not absence (avoiding a false "nothing to clean").

## 4. Detecting whether FDA is granted

There is no public "am I granted FDA?" API. TCC status is inferred by a **probe**:

- **SR-103** The tool detects FDA by attempting a **read-only** probe of a known TCC-protected
  path that requires FDA — e.g. `~/Library/Application Support/com.apple.TCC/TCC.db` (or a
  Mail/Safari container marker) — via `open(…, O_RDONLY)` / a directory listing, and interpreting
  `EPERM`/`EACCES` as "not granted" and success as "granted". The probe:
  - reads **nothing sensitive** (it checks accessibility, not content; it does not copy or log the
    file's data — see spec 35 secrets rule);
  - is **read-only** and touches a **stable** protected marker, not a user document;
  - is cached for the session (probed once, `Session`-scoped; spec 14 § 4.15).
- **SR-104** The probe result is recorded as a tri-state, never a bare bool:
  `FDAStatus ∈ { granted, denied, unknown }`. `unknown` (probe inconclusive, e.g. marker absent)
  is treated **conservatively** as `denied` for warnings but does not block scanning.
- **SR-105** FDA status feeds the safety scorer's missing-evidence handling (spec 22 SR-015): when
  `denied`, metadata acquisition (Spotlight, xattrs under protected trees) is expected to be
  partial, so affected findings are marked `degraded` (spec 22 SR-069), never silently
  over-trusted.

```swift
enum FDAStatus: String, Sendable, Codable { case granted, denied, unknown }

protocol PermissionService: Sendable {
    func fullDiskAccess() async -> FDAStatus          // §4 probe, session-cached
    func openFDASettingsPane() throws                 // §5.3 guidance
    func canElevate(for op: ElevatedOp) -> ElevationDecision  // §6
}
```

## 5. Graceful degradation without FDA

- **SR-106** Without FDA, the tool **scans what it can** and **reports what it cannot** as
  `SkippedPath` entries with `SkipReason.permissionDenied` (spec 14 § 4.12). It never presents a
  permission-limited scan as complete.
- **SR-107** A permission-limited **`scan`** still exits `0` (it succeeded at what it could do) but
  the report header states clearly that results are partial and which plugins/roots were limited.
  A permission-limited **`clean`** that could not complete a *requested* action set because of
  permission exits **4** (`permission`, Constitution Article 7) — the user asked for something the
  tool could not do.
- **SR-108** `doctor` (health command) reports FDA status as a first-class health item: `granted`
  → healthy, `denied` → warning with the remediation steps (§ 5.3). In `--ci` mode this maps per
  Constitution Article 7 (warning → 3).

### 5.1 What still works without FDA

User-owned, non-TCC areas remain fully scannable: `~/Library/Developer` (much of Xcode/DerivedData
is *not* TCC-protected but *some* is — attributed per-root), `~/.npm`, `~/.gradle`, `~/.cargo`,
`/private/var/folders` user temp, `~/Downloads` (with its own protection prompt), `/usr/local`
(Homebrew), Trash. The tool remains **genuinely useful** unprivileged.

### 5.2 First-run UX

- **SR-109** On the **first interactive run**, if FDA is `denied`, the tool shows a concise,
  one-time explainer: *why* FDA helps (which categories become visible), that it is **optional**,
  that the tool works without it, and the exact steps to grant it (§ 5.3). It MUST NOT nag on every
  run; the explainer is suppressed after first acknowledgement (persisted flag in config/state,
  spec 15) and re-shown only when a user runs a plugin that specifically needs FDA.
- **SR-110** The tool **never** attempts to grant itself FDA programmatically, script System
  Settings, or use private TCC APIs (spec 35 — no TCC tampering). The user grants it, manually,
  with full understanding.

### 5.3 Guiding the user to grant FDA

- **SR-111** When guidance is warranted (interactive, `denied`, and the user opts to enable a
  plugin needing it), the tool offers to open the exact System Settings pane:
  `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`
  (Privacy & Security → Full Disk Access) via
  `NSWorkspace.open(URL)` / `open` fallback, then prints the precise manual steps:
  1. Add the terminal app **or** the `cleaner` binary to the Full Disk Access list.
  2. Toggle it on.
  3. Re-run the command.
- **SR-112** The guidance clarifies the **TCC identity nuance**: TCC grants attach to the
  *host process's* signing identity. When run from a terminal, granting FDA to that terminal
  (Terminal.app / iTerm) is what takes effect; when installed via the notarized Homebrew tap /
  release binary with a stable Developer ID signature (CC-11), FDA can attach to `cleaner` itself.
  The tool detects its invocation context and tells the user **which** entry to add, avoiding the
  common "I granted it but it still says denied" trap.

## 6. Admin / root elevation

### 6.1 The problem space

A few reclaimable locations are owned by **root** or another user, not the invoking user: some
`/Library/Caches`, `/private/var` system caches, other users' caches (multi-user machines),
root-owned leftovers from installers. Removing these requires elevated privilege.

### 6.2 The deprecated path we do NOT use

- **SR-113** The tool MUST NOT use `AuthorizationExecuteWithPrivileges` — it is **deprecated**
  since macOS 10.7, insecure (runs an arbitrary tool as root over a pipe with no strong caller
  authentication, a classic privilege-escalation vector), and unacceptable for a safety-first tool
  (spec 35, THR in spec 36). It is banned in the codebase.

### 6.3 The modern path (design target, deferred to a later version)

The correct modern approach is a **privileged helper tool** installed and managed via
`SMAppService.daemon(...)` (macOS 13+), communicating over a typed **XPC** connection. The helper:
runs as root, exposes a *narrow, audited* XPC interface (not a shell), validates every request
against the same allow∩roots−deny algebra (spec 22 § 7) **again** inside the privileged boundary,
performs only whitelisted per-path operations, and is itself code-signed and notarized. This mirrors
the v3 out-of-process plugin isolation direction (spec 13 § 8) and is the only acceptable way to
run privileged filesystem mutation.

- **SR-114** If/when a privileged helper is shipped, it MUST: (a) be installed via `SMAppService`,
  never a hand-rolled `launchd` plist; (b) re-validate every operation against the full safety model
  (spec 22 §§ 6, 7, 11) **inside** the root context — the helper trusts nothing from the
  unprivileged parent; (c) expose only a fixed, enumerated set of per-path dispositions, never an
  arbitrary "run command" or "delete path" primitive that accepts unconstrained input; (d) audit
  every privileged action to the append-only audit log (spec 28) attributed to the requesting
  session; (e) verify the calling process's code-signing identity (audit token / `SecCode`) before
  honoring any request.

### 6.4 v1.0 decision — refuse + explain

- **SR-115** **v1.0 does NOT elevate.** It ships **no** privileged helper and performs **no**
  root-owned mutation. For any reclaimable item the tool detects that is **not writable by the
  invoking user** (`Evidence.isWritableByUser == false` / owner ≠ current uid; spec 14 § 4.7,
  spec 16 § 5):
  - The item is **scanned and reported** (read access permitting) so the user sees the reclaimable
    space, annotated **"requires admin — not removed"**.
  - It is **never** actioned by v1. It is presented as informational, `Disposition.skip`, with a
    clear rationale and, where useful, a **manual command the user can run themselves** (e.g. the
    exact `sudo rm -rf <path>` they *could* run, shown but never executed by us).
  - The finding's risk is computed normally; being admin-owned raises caution (it lowers
    `s_uac`/path-confidence context), so such items skew 🟡/🔴 and are never auto-selected.
- **SR-116** This keeps v1 firmly least-privilege and safe: the tool that runs as *you* can only
  delete what *you* can delete. Elevation is a v2 feature gated on the privileged-helper design
  (SR-114) passing a dedicated security review (spec 35) and threat model update (spec 36).

## 7. Least-privilege & per-operation scoping (forward-looking, binds v2)

- **SR-117** Any future elevation MUST be **per-operation and per-path**, scoped to the specific
  admin-owned path being cleaned — never a blanket "run the whole clean as root". The unprivileged
  process does all scanning, scoring, planning, and confirmation; only the *individual* mutation of
  a *specific* admin-owned path crosses to the helper.
- **SR-118** Elevation MUST be **explicit and consented**: the user is shown exactly which paths
  require admin and must approve the elevation (Authorization Services prompt via the helper's
  installation, plus the tool's own typed confirmation for any 🔴 among them, spec 22 § 8.4). No
  silent escalation (Principle 6).
- **SR-119** The privileged boundary is a **trust boundary** (spec 36): the helper re-derives
  safety independently and rejects anything the unprivileged side "already approved" that fails the
  helper's own checks. Approval does not transfer trust across the boundary.

```swift
enum ElevatedOp: Sendable { case removeAdminOwnedPath(FilePath) }   // v2; enumerated, narrow

enum ElevationDecision: Sendable {
    case notNeeded                        // user owns it — normal path
    case refusedV1(reason: String)        // v1: report-only, SR-115
    case availableViaHelper               // v2+: SMAppService helper present & consented
}
```

## 8. Sandbox, `sudo`, and invocation contexts

### 8.1 Not App-Sandboxed

- **SR-120** cleaner-cli is a **CLI/TUI distributed outside the Mac App Store** (Homebrew tap +
  GitHub Releases, CC-11); it is **not App-Sandboxed** (the App Sandbox would make a general disk
  cleaner impossible). It relies on **TCC (FDA)** for protected-location access and the **hardened
  runtime + Developer ID notarization** for distribution trust (§ 10), not the App Sandbox.

### 8.2 Running as the user (default)

The overwhelmingly common invocation is `cleaner ...` as the logged-in user, no `sudo`. Full
safety model applies; admin-owned paths are report-only (SR-115).

### 8.3 Root detection & guard rails

- **SR-121** The tool **detects when it is running as root** (`getuid() == 0`, e.g. under `sudo`)
  and applies **extra guard rails**, because a mistake as root is far more dangerous:
  - It **warns prominently** that it is running as root and that the safety model is doing more
    work to protect the (now much larger) blast radius.
  - The protected-path deny-list and every § 6 invariant of spec 22 are enforced **identically**
    and **cannot** be relaxed by being root — running as root does not unlock the deny-list
    (Constitution Article 5; spec 22 SR-042).
  - 🔴 typed confirmation is still required; `--yes` still cannot auto-clean 🔴 (spec 22 SR-045).
- **SR-122** The tool **discourages** `sudo cleaner` in docs and first-run guidance: it is broader
  than necessary (violates least-privilege), muddies file ownership of the tool's own
  `~/.cleaner/` state (root-owned config/staging can then break unprivileged runs), and is
  unnecessary because v1 does not clean admin-owned paths anyway (SR-115). Preferred: run as the
  user; let v2's scoped helper handle the rare admin path.
- **SR-123** When run under `sudo`, the tool resolves `~/.cleaner/` to the **invoking user's** home
  (via `SUDO_USER`/`SUDO_UID` when present) and never writes root-owned files into a user's tool
  home, to avoid the ownership-corruption footgun (SR-122). If it cannot safely determine the real
  user's home, it warns and uses a root-scoped `CLEANER_HOME` rather than silently polluting a
  user directory.

### 8.4 `sudo` behavior summary

| Invocation | uid | Admin-owned paths | Deny-list | 🔴 confirm | `~/.cleaner` home |
|---|---|---|---|---|---|
| `cleaner` (user) | user | report-only (SR-115) | enforced | required | user home |
| `sudo cleaner` (discouraged) | 0 | still report-only in v1 (SR-115) | **enforced, unrelaxed** (SR-121) | required | invoking user's home (SR-123) |

## 9. What v1.0 will and will not do — explicit statement

**v1.0 WILL:**

- Run as the invoking user with no elevation (SR-115, SR-120).
- Detect FDA status and degrade gracefully, scanning everything the user can read (SR-101, SR-106).
- Guide the user to grant FDA manually via the correct System Settings pane (SR-111, SR-112).
- Detect and *report* admin-owned reclaimable space, with a manual command the user may run
  themselves, but not act on it (SR-115).
- Detect root invocation and keep every safety invariant enforced and unrelaxable (SR-121).

**v1.0 WILL NOT:**

- Ship or install a privileged helper, or perform any root-owned mutation (SR-115).
- Use `AuthorizationExecuteWithPrivileges` or any deprecated/insecure elevation (SR-113).
- Programmatically grant itself FDA, script System Settings, or touch TCC internals (SR-110).
- Relax the protected-path deny-list under any privilege, including root (SR-121, spec 22 SR-042).
- Run App-Sandboxed (incompatible with the tool's purpose) (SR-120).

## 10. Entitlements, hardened runtime & notarization (feeds spec 32)

Distribution trust on macOS requires the **hardened runtime** and **Developer ID notarization**
(Constitution CC-11). This section fixes the entitlement posture; the build/sign/notarize pipeline
is spec 32.

- **SR-124** The release binary is signed with a **Developer ID Application** certificate, built
  with the **hardened runtime** enabled, and **notarized** (and stapled where a container permits),
  so Gatekeeper admits it without warnings and TCC can attach a stable identity to `cleaner`
  (SR-112).
- **SR-125** Entitlements are **minimal** (least privilege at the process level too). The tool
  requests **no** sandbox entitlement (SR-120). It does **not** request the
  `com.apple.security.get-task-allow` entitlement in release builds (that would weaken the hardened
  runtime and is debug-only). Any hardened-runtime exception (e.g. a JIT or
  disable-library-validation entitlement) is **forbidden** — the tool has no need and each such
  entitlement is an attack-surface expansion flagged in spec 35/36.
- **SR-126** If a privileged helper is added (v2, SR-114), it is a **separately signed & notarized**
  Developer-ID daemon registered via `SMAppService`, with its own minimal entitlements and its own
  code-signing-identity check on the XPC peer (SR-114e). The `SMPrivilegedExecutables` /
  `SMAuthorizedClients` code-signing requirement strings pin the two sides to each other so an
  attacker cannot substitute either binary.
- **SR-127** The signing identity and notarization ticket are part of the **supply-chain
  integrity** story (spec 35 § supply chain, spec 36 distribution-channel threats): release
  artifacts are checksummed and the Homebrew formula pins the checksum, so a tampered binary fails
  verification before it can ever request a privilege.

## 11. Interaction with the safety model & audit

- **SR-128** Permission state is **recorded in the audit log and report** (spec 28, spec 15 § 8):
  FDA status at scan time, whether any finding was limited by permission, and whether any admin-owned
  path was report-only. Consent given via `--yes`/policy is logged with its scope (spec 22 SR-060).
- **SR-129** Missing FDA **never** causes the tool to over-trust a finding: partial metadata yields
  conservative signal defaults (spec 22 SR-015) and a `degraded` flag (SR-105, spec 22 SR-069). A
  permission-limited run can only be *more* cautious, never less.
- **SR-130** Every permission-related refusal exits with the correct code: unmet required access on
  a requested action → **4** (`permission`); a safety-invariant abort (attempted protected/system
  path even under root) → **8** (`safety`); environment precondition unmet (e.g. required TTY for a
  🔴 typed confirmation absent) → **10** (`precondition`) or **3** (`partial`) per spec 22 SR-051.

## Open Questions

- **OQ-23.1** Is the FDA probe target (`~/Library/Application Support/com.apple.TCC/TCC.db`) stable
  and safe across macOS 13–15, or should we probe a less sensitive protected marker (a Mail/Safari
  container directory listing)? *Leaning: probe a directory *listing* of a protected container
  rather than opening `TCC.db`, to avoid even appearing to read a sensitive DB (spec 35). Validate
  per-OS in spec 31.*
- **OQ-23.2** Should v1 ship the privileged-helper design behind a disabled feature flag, or defer
  it entirely to v2? *Leaning: defer entirely (SR-115); shipping dormant privileged code is
  attack surface with no v1 benefit.*
- **OQ-23.3** For the report-only admin path (SR-115), do we print an actual `sudo rm` command
  (convenient but risky if the user blindly pastes) or only describe the path and let them decide?
  *Leaning: show the path + a copy-guarded, clearly-labeled suggested command with a warning;
  never auto-run. Revisit with UX (spec 25).*
- **OQ-23.4** When invoked via a terminal, can we reliably tell the user *which* app to grant FDA
  to (Terminal vs iTerm vs the packaged binary) across environments? *Leaning: detect parent
  process / signing identity and tailor the message (SR-112); fall back to listing both options.*
- **OQ-23.5** Should `doctor` attempt an *active* FDA guidance flow (offer to open Settings) or stay
  purely diagnostic? *Leaning: diagnostic by default, `--fix`-style interactive guidance opt-in.*

## Dependencies

**Consumes:** 00-constitution (Principle 6 least-privilege, Principle 3 truth-in-reporting,
Article 5 non-overridable deny-list, Article 7 exit codes 4/8/10, Article 8 `~/.cleaner` home,
CC-11 notarized distribution), 10-tech-stack (Security/Authorization Services, `SMAppService`,
Foundation `NSWorkspace`, DiskArbitration), 14-domain-model
(`PluginDescriptor.requiresFullDiskAccess`, `Evidence.isWritableByUser`/owner, `PolicyRef`,
`SkipReason.permissionDenied`), 16-filesystem-strategy (permission-gated metadata, volume/owner
signals), 22-safety-model (SR-015 missing-evidence conservatism, SR-042 unrelaxable deny-list,
SR-045 no-auto-🔴, SR-051 non-TTY exit, SR-058 automation policies, SR-069 `degraded`).

**Feeds:** 17-scan-engine (FDA-aware degradation, permission `SkippedPath` attribution),
20-cleanup-engine (report-only admin-owned handling, root guard rails, exit code 4),
27-error-handling (exit codes 4/8/10 semantics), 28-logging (permission/consent audit),
32-packaging (Developer ID signing, hardened runtime, notarization, minimal entitlements,
`SMAppService` helper packaging when v2), 35-security-review (privilege boundaries, entitlement
minimization, no deprecated elevation), 36-threat-model (privilege-boundary and distribution-channel
threats, local-malware-leveraging-our-privileges persona).
