# 10 — Technology Stack

> **Phase C · Depends on:** 00-constitution, 07-nonfunctional-requirements ·
> **Depended on by:** 11, 12, 13, all engine specs.

## 1. Purpose

Fix the languages, frameworks, and libraries for v1.0, with the trade-off analysis behind
each choice and the rejected alternatives. Constitution Article 10 records the one-line
decisions; this spec is their justification and the pinned dependency set. Each major choice
has a matching ADR in `specs/adr/`.

## 2. Decision summary

| Concern | Choice | Alternatives rejected | ADR |
|---|---|---|---|
| Language | **Swift 6** (strict concurrency) | Rust, Go, Bash, Python | ADR-0001 |
| Build/pkg | **Swift Package Manager** | Xcodeproj, Make, Bazel | ADR-0001 |
| CLI parsing | **swift-argument-parser** | Custom, Commander, swift-cli | ADR-0002 |
| Concurrency | **Swift Concurrency** (actors, TaskGroup, AsyncSequence) | Dispatch/OperationQueue, Combine | ADR-0003 |
| TUI/render | **Custom component layer over ANSI** + `swift-terminal-size`-style width, `Rainbow`/own SGR | SwiftTUI, Noora, ncurses (via C), blessed-port | ADR-0004 |
| Config | **Yams** (YAML) | JSON-only, TOML (TOMLKit), custom | ADR-0005 |
| Logging | **swift-log** + custom audit backend | os.Logger only, print, CocoaLumberjack | ADR-0006 |
| Metrics | **swift-metrics** (opt-in) | custom counters | ADR-0006 |
| Testing | **Swift Testing** + XCTest bridge | XCTest only, Quick/Nimble | ADR-0009 |
| Benchmarks | **package-benchmark** (ordo-one) | XCTest measure, hand-rolled | ADR-0009 |
| JSON | **Foundation `Codable`** | swift-json, custom | — |
| Hashing (dupes) | **CryptoKit** (SHA-256) + custom rolling/`xxHash` for prefilter | CommonCrypto, Foundation only | ADR (dup) |
| Collections | **swift-collections** (`OrderedSet`, `Deque`, `Heap`) | Foundation only | — |
| System APIs | **Foundation, System (`FilePath`), Darwin, DiskArbitration, CoreServices (LaunchServices, Metadata/Spotlight), Security/Authorization** | shell-outs | ADR-0001 |

## 3. Language & runtime — Swift 6 (ADR-0001)

**Context.** The tool must call macOS-native APIs deeply (URLResourceValues, DiskArbitration,
Spotlight `MDQuery`, Launch Services, xattr, APFS clone detection, Authorization Services),
process millions of files with bounded memory, ship as a single fast binary, and be
maintainable for years. Constitution principle 4 ("native first") and 9 ("performance").

**Options considered.**

- **Swift** — first-class access to every macOS framework with no FFI; value types + ARC give
  predictable memory; Swift 6 strict concurrency prevents data races at compile time; SPM
  builds a static universal binary; async/await gives structured cancellation (needed for the
  `cancel`/`resume` NFRs). *Cons:* TUI ecosystem is thin (addressed in ADR-0004); longer
  compile times; smaller cross-platform story (irrelevant — macOS-only).
- **Rust** — excellent performance and safety, great CLI/TUI crates (clap, ratatui, indicatif).
  *Rejected:* macOS framework access requires `objc2`/`core-foundation` FFI bindings that are
  incomplete for Spotlight, DiskArbitration, Authorization Services, and Launch Services;
  we'd fight bindings instead of building features. Native-first principle favors Swift.
- **Go** — fast to build, single binary, good CLI ecosystem (cobra, bubbletea). *Rejected:*
  cgo bridging to the needed frameworks is painful and slow; GC pauses are acceptable but the
  binding gap is the dealbreaker, same as Rust but worse for Apple APIs.
- **Bash / Python** — explicitly rejected by the brief ("not a bash script") and by the
  performance + safety + native-API requirements.

**Decision.** Swift 6, SPM, min deployment **macOS 13 (Ventura)**; APIs newer than 13 are
runtime-probed and feature-gated (Spotlight-on-14 refinements, some APFS niceties). Universal
binary (arm64 + x86_64).

**Consequences.** We own a TUI component layer (ADR-0004). Build times mitigated by module
splitting (spec 12) and CI caching. Team must be comfortable with Swift concurrency's
sendability rules.

## 4. CLI parsing — swift-argument-parser (ADR-0002)

First-party Apple library; declarative `ParsableCommand` tree maps 1:1 to the command
reference (spec 08); gives `--help`, usage errors (exit code 2), shell completions
(bash/zsh/fish, needed for distribution), and is trivially unit-testable by constructing
`CommandLine`-free instances. Rejected hand-rolling (reinvents help/completions) and
third-party parsers (no first-party guarantee, weaker completions).

## 5. Concurrency — Swift Concurrency (ADR-0003)

- **Scan fan-out:** `TaskGroup` per root, bounded by a concurrency limiter (spec 17) tuned to
  volume type (SSD vs spinning, local vs network — from DiskArbitration).
- **Shared state:** `actor ScanAccumulator`, `actor StagingManager` serialize mutation without
  locks; results stream out as `AsyncStream<Finding>` for live TUI updates.
- **Cancellation:** cooperative `Task.checkCancellation()` at directory boundaries satisfies
  the `cancel` NFR; a checkpoint file satisfies `resume`.
- Rejected Dispatch/OperationQueue (manual cancellation, easy data races) and Combine
  (deprecated trajectory, heavier, worse cancellation ergonomics).

## 6. TUI & rendering — custom layer over ANSI (ADR-0004)

**Context.** The brief demands a first-class TUI (progress, spinner, tree, table,
multi-select, checkbox, keyboard nav, live update, themes) rivaling Claude Code / gh / pnpm.
Swift lacks a mature, maintained TUI comparable to Rust's ratatui or Go's bubbletea.

**Options.** (a) SwiftTUI (rensbreur) — SwiftUI-like, but experimental, layout-limited, small
maintenance surface. (b) Noora (Tuist) — nice prompt components but not a full-screen TUI
framework and adds a large dep. (c) ncurses via C interop — powerful but ugly API, poor
Unicode/emoji width handling, hard to theme. (d) **Build a focused component layer.**

**Decision.** Build a small, owned rendering layer (`CleanerTUI` module, spec 25):
- Low level: ANSI/SGR escape writer, alternate-screen + raw-mode terminal control, a
  double-buffered frame renderer that diffs and emits minimal escapes (flicker-free live
  update), and a resize (`SIGWINCH`) handler.
- Width/Unicode: an East-Asian-width + emoji-grapheme width table (correct truncation/columns).
- Components: `ProgressBar`, `Spinner`, `Tree`, `Table`, `SelectList`/`MultiSelect`,
  `Confirm`, `Summary`, `KeyRouter`. All theme-driven (spec 25 themes) and degrade to plain
  output when not a TTY / `NO_COLOR` / `--no-tui`.

**Why own it.** Total control over the exact aesthetic the brief requires, no heavy/unstable
deps, correct emoji width (critical since the UI uses Unicode icons), and a clean non-TTY
fallback path for CI/JSON. Small third-party helpers allowed for color SGR and terminal size,
behind an adapter so they're swappable. **Consequence:** more code to own and test (covered in
spec 31's snapshot tests of rendered frames).

## 7. Configuration — Yams / YAML (ADR-0005)

`~/.cleaner/config.yml` (Constitution Article 8). YAML chosen for comments and readability
(power users hand-edit it; CleanMyMac users expect friendliness). Yams is the SSWG-adjacent,
widely-used, `Codable`-integrated YAML lib. Rejected TOML (less familiar for nested
whitelist/rules), JSON (no comments), custom format (needless). Schema + validation in spec 24.

## 8. Logging & metrics — swift-log (+ audit sink) (ADR-0006)

`swift-log` gives a backend-agnostic façade; we ship an `os.Logger` backend (Console.app,
signposts) for dev and a file/NDJSON backend for the audit trail (spec 28). A dedicated
**audit backend** records every filesystem mutation as an append-only NDJSON event
(Constitution principle 8). `swift-metrics` is compiled in but wired to a no-op backend
unless telemetry is opted in (spec 29). Rejected: raw `os.Logger` only (no file/audit
routing), `print` (unstructured), CocoaLumberjack (Obj-C, heavy).

## 9. Testing & benchmarks — Swift Testing + package-benchmark (ADR-0009)

Swift Testing (`@Test`, `#expect`, parameterized traits) is the modern first-party framework;
XCTest kept only where a bridge is needed. `package-benchmark` (ordo-one) provides statistical
benchmarks with thresholds enforced in CI (spec 30). A **virtual filesystem fixture** layer
lets us test scan/detection/cleanup against synthesized trees without touching the real disk
(spec 31). Rejected Quick/Nimble (extra deps, matcher-heavy) and XCTest-only (weaker
parameterization).

## 10. Native frameworks used (native-first, spec 16 for details)

| Framework | Used for |
|---|---|
| **Foundation / `FileManager` / `URLResourceValues`** | Enumeration, allocated size, mtime/atime, is-directory, volume info. |
| **System (`FilePath`)** | Safe, allocation-light path handling on hot loops. |
| **Darwin (`getattrlistbulk`, `statfs`, `xattr`, `clonefile`)** | Bulk metadata (fast enumeration), extended attributes, APFS clone/space queries. |
| **DiskArbitration** | Volume type/model (SSD vs HDD vs network), mount roots (protected-path enforcement). |
| **CoreServices — Metadata (`MDQuery`/`MDItem`)** | Spotlight kind, last-used date, download origin (`kMDItemWhereFroms`). |
| **CoreServices — Launch Services** | App registration, "is this app installed/used", bundle→app mapping (unused-app & orphan detection). |
| **AppKit `NSWorkspace`** (thin, optional) | Trash via `recycle`, running-app checks. Isolated so headless builds don't require it. |
| **Security / Authorization Services** | Elevation for the rare admin-owned path (spec 23). |
| **CryptoKit** | SHA-256 for duplicate confirmation. |

Every shell-out (e.g. `docker system df`, `xcrun simctl`, `brew`) is a *fallback adapter*
(spec 13 plugin capability), justified per-plugin because those tools have no stable native
API. Adapters are sandboxed, argument-escaped, and timeout-bounded (spec 36 threat model).

## 11. Dependency policy

- Minimize third-party deps; each new dep needs an ADR noting license, maintenance, and a
  removal plan. Pin exact versions; vendor-audit before bumping.
- No dependency may perform network I/O at runtime in the core path (Constitution principle 10).
- Allowed set (v1): swift-argument-parser, swift-log, swift-metrics, swift-collections, Yams,
  package-benchmark (test-only), a color/terminal-size helper (behind adapter). Everything
  else is first-party Apple.

## 12. Open questions

- **OQ-10.1** Minimum OS: is macOS 13 acceptable, or must we support 12 (Monterey)? Affects
  which APFS/Spotlight APIs are baseline vs gated. *Default: 13.*
- **OQ-10.2** Do we vendor the emoji-width table or generate it from Unicode data at build time?
  *Leaning: generate in a build plugin for correctness.*
- **OQ-10.3** Ship x86_64 slice given Apple-silicon dominance? *Default: yes for v1, revisit v2.*

## 13. Dependencies (specs)

Feeds: 11 (architecture), 12 (modules), 13 (plugins), 16 (filesystem), 17 (scan), 25 (TUI),
28 (logging), 30/31 (bench/test), 32 (packaging). Consumes: 07 (NFRs), 00 (constitution).
