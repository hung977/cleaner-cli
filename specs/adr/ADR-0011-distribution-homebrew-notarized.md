# ADR-0011: Distribution = Notarized Homebrew Tap + GitHub Releases

- **Status:** Accepted
- **Date:** 2026-07-06
- **Deciders:** Architecture
- **Realizes:** Constitution Article 10 · CC-11 · analysis in spec 10, spec 32/33
- **Constitution principles engaged:** 6 (least privilege), 10 (privacy — no telemetry hook in install)

## Context

cleaner-cli is a developer-facing macOS CLI that deletes files and requests Full Disk Access /
admin elevation (FR-098). Users must be able to **trust the binary they run** — that means it
passes Gatekeeper on a clean machine, is signed and notarized by a known Developer ID, and is
installed through a channel developers already trust and can audit. Distribution must not
introduce a network/telemetry hook (principle 10) and must reach the target audience (developers,
CleanMyMac refugees) with a familiar, scriptable install and upgrade path.

## Decision Drivers

1. **Trust on macOS** — Developer-ID signed + **notarized + stapled** so Gatekeeper is satisfied
   with no scary warnings for a tool that requests deep disk access.
2. **Reach & familiarity** — the audience installs developer CLIs via Homebrew by reflex.
3. **Auditable, scriptable install/upgrade** — formula is inspectable; upgrades are one command.
4. **No install-time telemetry / network coupling** (principle 10).
5. **Reproducible artifacts** — checksummed universal binary from CI (spec 34).

## Options Considered

### Notarized Homebrew tap + GitHub Releases — chosen
- **Pros:** Homebrew is the de-facto macOS developer install channel — instant familiarity and
  `brew upgrade cleaner` for updates (the v1 `self-update` stub points here, spec 08); the formula
  is a plain, auditable file; artifacts are a **Developer-ID-signed, notarized, stapled** universal
  binary (arm64 + x86_64) published on GitHub Releases with SHA-256 checksums (spec 32/33), so
  Gatekeeper is satisfied on clean machines and provenance is verifiable; no install-time telemetry.
- **Cons:** we must run/maintain the notarization pipeline (Developer ID account, `notarytool`,
  stapling) in CI (spec 34) and keep the tap formula current on each release — real but standard
  operational cost.

### Mac App Store — rejected
- **Pros:** maximum consumer trust, automatic updates, sandbox.
- **Cons / why rejected:** the App Store **sandbox forbids** the deep, broad filesystem access and
  the admin/Full-Disk-Access elevation this tool fundamentally requires (FR-098) — it literally
  cannot do its job sandboxed; review friction for a "delete files" utility is high; the audience
  wants a CLI, not a sandboxed GUI app.

### `curl … | bash` install script — rejected
- **Pros:** zero infrastructure, works everywhere, common for CLIs.
- **Cons / why rejected:** piping a script from the network into a shell is exactly the
  anti-pattern a security-conscious, file-deleting tool should not normalize; harder to audit;
  weaker provenance than a signed/notarized artifact + checksum; poor upgrade story. Against
  least-privilege/trust posture (principle 6).

### Raw unsigned binary download — rejected
- **Cons / why rejected:** Gatekeeper blocks/warns on unsigned, un-notarized binaries; asking users
  to `xattr -d com.apple.quarantine` a tool that then requests Full Disk Access is a trust
  catastrophe. Unsigned distribution is a non-starter for this tool class.

## Decision

Distribute a **Developer-ID-signed, notarized, and stapled universal binary** (arm64 + x86_64)
via a **Homebrew tap** with **GitHub Releases** as the artifact host (checksummed). CI (spec 34)
runs sign → `notarytool` → staple → checksum → publish; the release process (spec 33) updates the
tap formula. The v1 `self-update` command is a **stub** directing users to `brew upgrade cleaner`
and exits `10`, performing **no network I/O** (principle 10) — a real self-updater is v2.1
(spec 38 §6.3).

## Consequences

- Users install/upgrade through a trusted, familiar, auditable channel; Gatekeeper is happy.
- We own a notarization pipeline in CI (Developer ID cert management, `notarytool`, stapling) and
  keep the tap current per release — standard, bounded ops cost.
- Provenance is verifiable (signature + notarization ticket + checksum) — appropriate for a tool
  that requests deep disk access (principle 6).
- Real self-update deferred to v2.1 and will build directly on this signed/notarized foundation.

## Links

- Constitution Article 10 (CC-11), principles 6 & 10.
- Spec 32 (packaging — universal binary, signing), spec 33 (release), spec 34 (CI/CD pipeline),
  spec 08 (`self-update` v1 stub), spec 38 §6.3 (v2.1 real self-update).
- Related: ADR-0001 (single universal binary), ADR-0008 (one signed binary, all plugins static).
