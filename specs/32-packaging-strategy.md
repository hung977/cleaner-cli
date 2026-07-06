# 32 — Packaging Strategy

> **Phase G · Depends on:** 00-constitution (Art. 6 naming, Art. 8 tool home, CC-11 distribution),
> 07-nonfunctional (NFR-090..093 portability, NFR-120..123 install size/startup), 10-tech-stack
> (Swift/SPM, native frameworks, AppKit-optional), 12-module (products & targets), 23-permission-model
> (Full Disk Access rationale) ·
> **Depended on by:** 33 (release consumes these artifacts), 34 (CI runs the build/sign/notarize
> pipeline).

## 1. Purpose & scope

How we turn the SPM package (spec 12) into a **trustworthy, installable artifact** on macOS: a
signed, notarized, stapled **universal binary**, distributed via a **Homebrew tap** and **GitHub
Releases** (CC-11). Covers the build, code signing, notarization, hardened runtime & entitlements
(and why the tool is **not** sandboxed), Gatekeeper behavior, the tap formula, shell completions & man
page, install-size budget (NFR-122), version stamping, reproducible-build aspiration, and the SBOM.

Non-goals: the release *process/cadence* (spec 33), the CI *workflow YAML* (spec 34) — this spec
defines *what* is built and *how* it's assembled; those specs define *when* and *by which automation*.

## 2. Artifacts produced per release

| Artifact | Filename | Purpose |
|---|---|---|
| Universal binary tarball | `cleaner-<version>-macos-universal.tar.gz` | the notarized `cleaner` + completions + man |
| Checksums | `cleaner-<version>-checksums.txt` (SHA-256) | integrity, Homebrew `sha256`, self-update (spec 33) |
| Detached signature | `cleaner-<version>-checksums.txt.minisig` | supply-chain: signed checksums (spec 33) |
| SBOM | `cleaner-<version>-sbom.spdx.json` | supply-chain (NFR-054), §11 |
| Notarization log | `cleaner-<version>-notary-log.json` | audit of the notarytool submission |

All five are attached to the GitHub Release (spec 33 §GitHub Releases). The tarball is what the Homebrew
bottle wraps.

## 3. Build — release SPM build → universal binary

Baseline **macOS 13** deployment target (Constitution Art. 6, spec 10 §3). Build each slice, then
`lipo`:

```bash
set -euo pipefail
VERSION="${1:?tag}"                                   # e.g. 1.4.0
BUILD_FLAGS=(-c release -Xswiftc -Onone=false \
             -Xswiftc -g \                             # keep debug info → dSYM, then strip binary
             --disable-sandbox)                        # SPM build sandbox off (notarization later)

# arm64 slice
swift build "${BUILD_FLAGS[@]}" --arch arm64 \
  --destination-target arm64-apple-macosx13.0
# x86_64 slice (NFR-091 universal; revisit x86 in v2 per OQ-10.3)
swift build "${BUILD_FLAGS[@]}" --arch x86_64 \
  --destination-target x86_64-apple-macosx13.0

ARM=".build/arm64-apple-macosx/release/cleaner"
X64=".build/x86_64-apple-macosx/release/cleaner"

# fuse to a universal (fat) Mach-O (NFR-091)
lipo -create -output ".build/cleaner-universal" "$ARM" "$X64"
lipo -info ".build/cleaner-universal"     # → arm64 x86_64

# split dSYM out, then strip the shipped binary for size (NFR-122)
dsymutil ".build/cleaner-universal" -o "cleaner.dSYM"
strip -rSTx ".build/cleaner-universal"    # keep exported symbols the runtime needs; drop debug/locals
```

- **Static-ish linking:** Swift runtime is back-deployed / statically bundled where possible so the
  binary self-contains (no Homebrew runtime dependency, NFR-123). AppKit (`NSWorkspace`) is
  **weak-linked / probed** so a headless environment links without it (NFR-092, `T-headless-link`,
  spec 10 §10). CryptoKit, DiskArbitration, CoreServices, System link against system frameworks (always
  present ≥ macOS 13).
- **dSYM** is uploaded as a build artifact (not in the release tarball) for symbolicating crash reports
  from opted-in bug reports; it is **not** shipped to users (size).
- **Compiler flags:** release optimization on, whole-module, `-g` for dSYM then `strip`. Strict
  concurrency stays on (NFR-033) — a strict-concurrency build failure blocks the build (spec 34).

## 4. Code signing — Developer ID

The binary is signed with a **Developer ID Application** certificate (the identity Gatekeeper trusts
for software distributed *outside* the App Store — CC-11):

```bash
codesign --force --timestamp --options runtime \        # secure timestamp + hardened runtime (§6)
  --sign "Developer ID Application: <Org> (<TEAMID>)" \
  --entitlements packaging/cleaner.entitlements \        # §6
  --identifier "com.<org>.cleaner" \
  ".build/cleaner-universal"

codesign --verify --strict --verbose=4 ".build/cleaner-universal"
codesign --display --entitlements - ".build/cleaner-universal"   # inspect what was signed
```

- Certificate + private key live only in CI as encrypted secrets, imported into a throwaway keychain
  per job (spec 34 §secrets). Never committed, never on a developer laptop for release builds.
- **Signing is per-slice-transparent:** `codesign` signs the fat binary; both architectures are covered.

## 5. Notarization & stapling — notarytool

After signing, submit to Apple's notary service and staple the ticket so the artifact validates
**offline** (no network needed at first launch, aligning with Principle 10 / NFR-060):

```bash
# zip the signed binary for submission
ditto -c -k --keepParent ".build/cleaner-universal" "cleaner-notarize.zip"

xcrun notarytool submit "cleaner-notarize.zip" \
  --apple-id "$NOTARY_APPLE_ID" --team-id "$TEAMID" \
  --password "$NOTARY_APP_SPECIFIC_PASSWORD" \           # or --keychain-profile in CI
  --wait --output-format json | tee "cleaner-<ver>-notary-log.json"

# staple the ticket to the binary (works for CLI Mach-O via the containing tar on modern tooling;
# we staple the tarball's payload dir, then re-tar)
xcrun stapler staple ".build/cleaner-universal" || true   # CLI staple caveat → §5.1
xcrun stapler validate ".build/cleaner-universal"
spctl --assess --type execute --verbose=4 ".build/cleaner-universal"   # Gatekeeper dry-run
```

### 5.1 Stapling caveat for a bare CLI binary

`stapler` staples to bundles/disk-images/pkgs reliably; a **bare Mach-O** cannot always hold a stapled
ticket. Two robustness measures:
- The notarization ticket is also served by Apple's CDN, so a signed+notarized binary validates online
  even without a staple.
- For fully-offline first-launch validation we additionally ship an optional **`.pkg`** (component
  package containing the binary + completions + man), signed with **Developer ID Installer** and
  stapled — Homebrew uses the tarball, but the `.pkg` is offered for users who want a double-clickable,
  offline-validating installer. (Decision: tarball is primary for `brew`; `.pkg` is a convenience
  artifact, OQ-32.1.)

## 6. Hardened runtime & entitlements — and why NOT sandboxed

**Hardened runtime** (`--options runtime`) is **required** for notarization and is enabled. It hardens
the process (no unsigned dylib injection, restricted DYLD env, etc.).

**The tool is deliberately NOT App-Sandboxed.** Rationale (Constitution Principle 1 & 6, spec 23):
`cleaner`'s entire job is to enumerate and reclaim space across the user's disk — developer caches,
`~/Library/Caches`, browser caches, logs. That requires **Full Disk Access (FDA)**, which the App
Sandbox fundamentally prevents (a sandboxed process is confined to its container + user-selected files).
A sandbox would make the core feature impossible. Therefore:

- **No `com.apple.security.app-sandbox`** entitlement. This is a documented, deliberate decision
  (recorded in the security review, spec 35, and threat model, spec 36) — the tool compensates with the
  deny-list (Art. 5), least-privilege (no setuid/daemon, NFR-050), per-op Authorization (spec 23), and
  the reversibility model (staging, Principle 2).
- **Full Disk Access** is not an entitlement the app *grants itself*; it is a **TCC privacy
  permission** the *user* grants in System Settings → Privacy & Security → Full Disk Access. The tool
  detects its absence (spec 23), explains why it's needed, and degrades gracefully (exit 4 where an
  operation truly needs it). We do not (and cannot) bypass TCC.

Entitlements file (minimal — hardened runtime exceptions only where a framework needs them):

```xml
<!-- packaging/cleaner.entitlements -->
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <!-- NOT sandboxed: no app-sandbox key (see §6 rationale). -->
  <!-- Hardened runtime is on via --options runtime; these are the only exceptions we need: -->
  <key>com.apple.security.cs.allow-jit</key><false/>
  <key>com.apple.security.cs.disable-library-validation</key><false/>  <!-- keep strict; v1 has no external dylibs -->
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key><false/>
  <!-- No network entitlement is required for the core path (Principle 10); telemetry opt-in path,
       if built, would add outbound client only when enabled (spec 29). -->
</dict></plist>
```

If v2 introduces out-of-process/dylib plugins (CC-8 deferral), `disable-library-validation` may need
revisiting behind an ADR; v1's statically-linked plugins (CC-8) keep library validation strict.

## 7. Gatekeeper behavior (user experience)

Because the binary is Developer-ID-signed + notarized (+ stapled/`.pkg`), Gatekeeper allows it without
the "unidentified developer" block. First run from a `brew`-installed path or the `.pkg` passes
`spctl --assess`. If a user downloads the raw tarball via a browser (quarantine xattr set), the notarized
signature still clears Gatekeeper; the tool's own handling of `com.apple.quarantine` on *scanned* files
is unrelated (spec 16 §5). The release notes document the expected first-run flow and the FDA grant step.

## 8. Homebrew tap

Distribution is a **custom tap** (not homebrew-core in v1 — faster iteration, our own signing story),
`<org>/homebrew-cleaner`, installed via `brew install <org>/cleaner/cleaner` (CC-11).

### 8.1 Tap repo structure

```
homebrew-cleaner/                      # repo: <org>/homebrew-cleaner
├── Formula/
│   └── cleaner.rb                      # the formula (bottle + from-source fallback)
├── .github/workflows/
│   └── bump.yml                        # auto-bump on new release (spec 33/34)
└── README.md
```

### 8.2 Formula — bottle primary, from-source fallback

We ship a **pre-built bottle** (the notarized universal tarball) so `brew install` does **no compile and
no runtime network fetch beyond the bottle** (NFR-123). A `head`/from-source path exists for
transparency and Apple-silicon-only edge cases.

```ruby
# Formula/cleaner.rb
class Cleaner < Formula
  desc "Safe, plugin-based macOS disk cleaner (CLI + TUI)"
  homepage "https://github.com/<org>/cleaner-cli"
  version "1.4.0"
  license "Apache-2.0"                                   # spec 33 recommends Apache-2.0

  # Pre-built, notarized universal binary (bottle-equivalent "binary release"):
  url "https://github.com/<org>/cleaner-cli/releases/download/v1.4.0/cleaner-1.4.0-macos-universal.tar.gz"
  sha256 "<sha256 from cleaner-1.4.0-checksums.txt>"     # verified at install (integrity)

  depends_on macos: :ventura                             # >= 13 (NFR-090)

  # From-source fallback (brew install --build-from-source cleaner):
  head "https://github.com/<org>/cleaner-cli.git", branch: "main"
  on_macos do
    # build deps only used on --build-from-source / head
  end

  def install
    if build.head? || build.bottle? == false && !File.exist?("cleaner")
      system "swift", "build", "-c", "release", "--arch", "arm64", "--arch", "x86_64"
      bin.install ".build/apple/Products/Release/cleaner"
    else
      bin.install "cleaner"                              # the notarized universal binary
    end
    # shell completions (§9)
    generate_completions_from_executable(bin/"cleaner", "completions")
    man1.install "share/man/man1/cleaner.1"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/cleaner --version")
    system bin/"cleaner", "doctor", "--ci"               # exit 0 on a clean box (Art. 7)
  end
end
```

- The formula's `sha256` is the release checksum (§2) — Homebrew verifies integrity on download; the
  notarized signature covers authenticity.
- Formula bumping is automated on release (spec 33 §tap-automation, spec 34): the release job opens a PR
  to `homebrew-cleaner` updating `version`, `url`, `sha256`.

## 9. Shell completions & man page

- **Completions** are generated by swift-argument-parser (spec 10 §4) for **bash, zsh, fish**:
  `cleaner completions bash|zsh|fish`. Homebrew installs them via
  `generate_completions_from_executable`, so tab-completion works immediately after `brew install`.
- **Man page** `cleaner.1` is generated from the ArgumentParser command tree at build time (a build
  step renders `--help` trees to roff) and installed to `man1`.
- Both are **inside the release tarball** (`share/man/man1/cleaner.1`, `completions/`) so non-Homebrew
  installs (`.pkg`, manual) get them too.

## 10. Install size budget (NFR-122)

| Component | Budget | Notes |
|---|---|---|
| Universal binary (stripped) | **< 25 MB** distributed (NFR-122) | both slices; static Swift runtime portion dominates |
| Completions (3 shells) | < 200 KB | generated text |
| Man page | < 100 KB | roff |
| **Total installed footprint** | **< 40 MB** (NFR-122) | binary + completions + man |

The packaging CI job **fails** if the stripped universal binary exceeds 25 MB or the footprint exceeds
40 MB (spec 34 packaging gate). Size reductions available if needed: `-Osize` for cold paths, dropping
the x86_64 slice (OQ-10.3), and dead-strip (`-dead_strip`). dSYM (large) is never shipped.

## 11. Version stamping into the binary

`cleaner --version` (and the JSON report `toolVersion`, `--json`) reports an authoritative version
compiled **into** the binary — never read from a mutable file. Mechanism:

- A generated `Version.swift` (SPM build tool plugin) stamps: semver (from the git tag, spec 33),
  `git describe` (commit + dirty flag), build date, and the `Package.resolved` hash. Example:

```swift
// generated by the VersionStamp build plugin — DO NOT EDIT
public enum BuildInfo {
    public static let version   = "1.4.0"
    public static let gitSHA    = "a1b2c3d"
    public static let gitDescribe = "v1.4.0"          // clean tag, no -dirty on a release build
    public static let buildDate = "2026-07-06T00:00:00Z"   // SOURCE_DATE_EPOCH (§12)
    public static let resolvedHash = "sha256:…"       // Package.resolved digest (supply-chain)
}
```

- A **release build refuses to stamp a `-dirty` describe** (the packaging job asserts a clean tree at the
  tagged commit, spec 34) — a released binary always reports a clean tag, satisfying reproducibility and
  audit.
- `cleaner --version --json` emits all fields for support/telemetry (opt-in, spec 29) and for the
  self-update version check (spec 33 §self-update).

**SBOM** (`cleaner-<ver>-sbom.spdx.json`): an SPDX document generated from `Package.resolved` (exact
pinned dependency versions + checksums, spec 10 §11 policy) plus the toolchain/OS SDK versions. Produced
in CI (spec 34), attached to the release (NFR-054). It lists swift-argument-parser, swift-log,
swift-metrics, swift-collections, Yams, System, and the toolchain — nothing performing runtime network
I/O (Principle 10).

## 12. Reproducible builds (aspiration)

Goal: two builds of the same tagged commit on the same toolchain produce **byte-identical** binaries
(strengthens supply-chain trust, NFR-054). Measures:
- Pin the exact **Swift toolchain version** (a `.swift-version`/toolchain pin) and macOS SDK; CI records
  both in the SBOM.
- Set **`SOURCE_DATE_EPOCH`** (from the tag's commit date) so `buildDate` and any embedded timestamps are
  deterministic; version stamping reads it (§11).
- Avoid embedding absolute build paths (`-Xswiftc -no-toolchain-stdlib-rpath`, path remapping via
  `-debug-prefix-map` in the dSYM) so slices don't carry the runner's home dir.
- **Aspiration, not a v1 gate:** signing/notarization inject non-deterministic bytes (timestamps,
  tickets), so *the signed artifact* is not bit-reproducible; the **pre-sign `lipo` output** is the
  reproducibility target. CI records a hash of the pre-sign universal binary; a later rebuild comparing
  equal is a "nice-to-have" green check, not a blocking gate in v1 (OQ-32.3).

## Open Questions

- **OQ-32.1** Ship the optional signed+stapled `.pkg` for offline first-launch validation (§5.1), or
  rely solely on the tarball + Apple's notary CDN? *Leaning: tarball primary for `brew`; publish the
  `.pkg` too for the offline/manual audience.*
- **OQ-32.2** Homebrew **core** submission (wider reach) vs. staying on our own tap — core forbids
  pre-built binaries requiring our signing story and slows iteration. *Leaning: own tap for v1, evaluate
  core once the formula is stable.*
- **OQ-32.3** How far do we chase reproducible builds (§12) in v1 — pre-sign hash check only, or invest
  in full toolchain-container reproducibility? *Leaning: pre-sign hash recorded, full reproducibility a
  v2 goal.*
- **OQ-32.4** Keep the x86_64 slice (inherits OQ-10.3) — dropping it saves ~40 % binary size and eases
  the 25 MB budget. *Leaning: keep for v1 (NFR-091), revisit v2.*
- **OQ-32.5** Do we need Developer ID **Installer** cert provisioning in CI for the `.pkg`, or is the
  Application cert sufficient if we defer the `.pkg`? *Depends on OQ-32.1.*

## Dependencies

**Consumes:** 00 (Art. 6 `cleaner` naming, Art. 8 `~/.cleaner` layout the installer must not touch,
CC-11 notarized-tap distribution), 07 (NFR-090..093 portability/universal/headless, NFR-120..123 size/
startup/self-contained), 10 (Swift/SPM build, native frameworks, AppKit-optional weak link, dependency
pinning for SBOM), 12 (the `cleaner` executable product + `CleanerPluginAPI` library product), 23 (Full
Disk Access / TCC rationale behind the no-sandbox decision).

**Feeds:** 33 (the artifacts, checksums, SBOM, and signature this spec produces are what a release
publishes; formula-bump automation), 34 (the CI pipeline executes this build→sign→notarize→staple→
checksum→SBOM sequence and enforces the size gate), 35/36 (the no-sandbox + hardened-runtime decision is
reviewed there).
