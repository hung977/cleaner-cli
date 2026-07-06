# cleaner-cli

> A production-grade, plugin-based **macOS disk cleaner for the terminal** — a CleanMyMac
> for developers and power users, built native in Swift with a beautiful TUI, safety-first
> cleanup, preview, and rollback.

**Status:** 🚧 In development (v0.5). The full SpecKit specification suite lives in
[`specs/`](./specs); the CLI is being built against it.

```
cleaner                 # scan, pick what to clean, reclaim (interactive) — one command
cleaner --dry-run       # preview only (scan + suggestions, nothing deleted)
cleaner --yes           # clean Safe items without prompting (automation/CI)
cleaner --json          # machine-readable output
cleaner undo            # restore the last clean (everything is recoverable)
cleaner find large      # biggest personal files    ·    cleaner find dupes   # duplicates
# advanced: cleaner docker · cleaner brew · cleaner doctor · cleaner profile
```

## What it cleans (safely, with preview + rollback)

Developer caches (Xcode, DerivedData, Simulators, SwiftPM, CocoaPods, npm/yarn/pnpm,
Python, Ruby, Java/Gradle/Maven, Android Studio), build artifacts, Docker, Homebrew,
browser caches (Chrome/Safari), system & app logs, crash reports, Mail downloads, Trash —
plus detectors for large files, duplicates, old files, unused apps, orphaned packages,
obsolete SDKs, stale DerivedData, old simulator runtimes, old archives, and more.

## Why it's different

- **Safety-first:** every destructive action is preview → confirm → execute, defaults to a
  recoverable staging area (rollback in one command), never touches protected paths.
- **Native, not a bash script:** uses Foundation, `URLResourceValues`, Spotlight, Launch
  Services, APFS/xattr metadata — not hard-coded paths and `rm`.
- **Plugin architecture:** every capability is an independent plugin; add new ones without
  touching the core.
- **Beautiful TUI:** progress, spinners, tree view, tables, multi-select, keyboard nav —
  dark-terminal friendly, in the spirit of Claude Code / gh / Docker / pnpm.

## Documentation map

The full design lives in [`specs/`](./specs). Start with the
[**Constitution**](./specs/00-constitution.md) — it fixes the principles, glossary, safety
constants, and conventions every other document depends on. Then the
[**spec index**](./specs/README.md).

## Project status & roadmap

MVP → v1.0 (production) → v2.x (AI-assisted, scheduling, automation) → v3.x (plugin & rule
marketplaces, remote management). See [`specs/38-future-roadmap.md`](./specs/38-future-roadmap.md).

## License

TBD (see spec 33 — likely MIT for the engine, with a CLA for plugin contributions).
