<h1 align="center">cleaner</h1>

<p align="center">
  <b>A safe, native macOS disk cleaner for the terminal — a CleanMyMac for developers.</b><br>
  Scan, pick what to clean, reclaim gigabytes — and undo any of it with one command.
</p>

<p align="center">
  <a href="https://github.com/hung977/cleaner-cli/actions"><img src="https://github.com/hung977/cleaner-cli/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-black?logo=apple" alt="macOS 13+">
  <img src="https://img.shields.io/badge/Swift-6-orange?logo=swift" alt="Swift 6">
  <img src="https://img.shields.io/badge/license-MIT-8AC776" alt="MIT">
</p>

---

## Install

```sh
brew tap hung977/tap
brew trust hung977/tap      # Homebrew requires trusting third-party taps (one-time)
brew install cleaner
```

Builds from source with `swift build` (needs the Xcode command-line tools).
🌐 **[Landing page](https://hung977.github.io/cleaner-cli/)** · 📖 **[Docs](./docs/commands.md)**

## Quick start

```sh
cleaner                 # scan → summary → "Reclaim X? [Y/n]" → clean (recoverable)
cleaner --all           # also clean Medium items (browser/app caches, logs)
cleaner --dry-run       # preview only, delete nothing
cleaner undo            # restore the last clean, byte-for-byte
```

```
❯ cleaner

  DISK RECLAIMABLE                                    24.9 GB
  11 sources · 7.8s

  Developer Cache                                     22.8 GB
    Xcode DerivedData (7)                              3.4 GB
    SwiftPM cache (2)                                  4.6 GB
    Gradle caches                                      4.6 GB
    Xcode Archives (16)                              623.8 MB   (never auto-cleaned)

  Browser Cache                                        1.5 GB
    Chrome cache                                       1.5 GB

  Total  24.9 GB   ·   14.4 GB Safe now · 9.9 GB more with --all

  Reclaim 14.4 GB? [Y/n]
```

## Why cleaner

- **🛟 Recoverable by default** — cleaned items move to a staging area, not the void. `cleaner undo` restores them byte-for-byte.
- **🎯 Risk-aware** — every source is graded 🟢 Safe / 🟡 Medium / 🔴 Dangerous. Safe is cleaned by default; Dangerous is never auto-touched.
- **🔒 Protected paths** — Documents, Desktop, SSH keys, Keychains and system files can never be deleted, enforced in the engine independently of plugins.
- **⚡ Native & deep** — uses Foundation / APFS APIs, measures true on-disk size (not logical), no shelling out where a native API exists.
- **🤖 Scriptable** — `--yes` for automation, `--json`/`--md` for machines, a clean exit-code contract for CI.
- **🔎 More than cleaning** — `cleaner find large` and `cleaner find dupes` surface big files and byte-identical duplicates, read-only.

## What it cleans

| Category | Sources | Risk |
|---|---|---|
| **Developer Cache** | Xcode DerivedData · SwiftPM · CocoaPods · pip · Gradle · Homebrew cache · npm/yarn/pnpm | 🟢 Safe |
| | Xcode DeviceSupport · orphaned Simulator devices | 🟡 Medium |
| | Xcode Archives (dSYMs / shipped builds) | 🔴 never auto |
| **Browser Cache** | Chrome · Safari · Firefox · Edge · Brave — *cache only, never cookies/history/passwords* | 🟡 Medium |
| **Application Cache** | `~/Library/Caches` (excl. dev/browser) | 🟡 Medium |
| **Logs & Crash Reports** | `~/Library/Logs` | 🟡 Medium |
| **Trash** | `~/.Trash` | 🟡 Medium |

Plus external tools via their own commands: `cleaner docker` (safe prunes only) and `cleaner brew`.

## Safety

A byte wrongly deleted is worse than a gigabyte wrongly kept. Every destructive action is
**preview → confirm → execute**; the default disposition is *move-to-staging*, not permanent
delete. `cleaner --yes` cleans **Safe** only; `--all` adds **Medium**; **Dangerous** is never
auto-cleaned. Nothing outside plugin-declared roots — and never a protected path — is ever
touched. Every action is recorded in an append-only audit log. See **[docs/safety.md](./docs/safety.md)**.

## Commands

| Command | What it does |
|---|---|
| `cleaner` | Scan, preview, confirm, reclaim (Safe items, recoverable) |
| `cleaner --all` / `--dry-run` / `--yes` | Include Medium / preview only / no prompt |
| `cleaner undo` · `undo --list` | Restore the last clean / list what can be restored |
| `cleaner find large` · `find dupes` | Largest files / duplicate files (read-only) |
| `cleaner --json` · `--md` | Machine-readable / Markdown report |
| `cleaner doctor` · `docker` · `brew` · `profile` | Health check · external-tool cleanup · profiles |

Full reference: **[docs/commands.md](./docs/commands.md)** · Config: **[docs/configuration.md](./docs/configuration.md)** · FAQ: **[docs/faq.md](./docs/faq.md)**

## Configuration

`~/.cleaner/config.yml` (all keys optional):

```yaml
version: 1
ignore:  ["*Keep*"]            # drop matching findings
profiles:
  aggressive: { risky: true }  # cleaner --profile aggressive
```

## Build from source

```sh
git clone https://github.com/hung977/cleaner-cli && cd cleaner-cli
swift build -c release
swift test                     # ~75 tests incl. a 100% protected-path safety gate
./Scripts/install-local.sh     # build + install + re-sign to /opt/homebrew/bin
```

## Design

Built Specification-Driven (SpecKit). The full design suite — architecture, safety model,
detection algorithms, threat model — lives in **[`specs/`](./specs)**, anchored by the
[Constitution](./specs/00-constitution.md).

## License

MIT © 2026 hung977 — see [LICENSE](./LICENSE). Contributions welcome: [CONTRIBUTING.md](./CONTRIBUTING.md).
