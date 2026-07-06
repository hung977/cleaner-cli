# ADR-0004: TUI = Custom Component Layer over ANSI

- **Status:** Accepted
- **Date:** 2026-07-06
- **Deciders:** Architecture
- **Realizes:** Constitution Article 10 · CC-4 · deep analysis in spec 10 §6
- **Constitution principles engaged:** 8 (observability/UX clarity), 9 (responsiveness)

## Context

The brief demands a first-class TUI rivaling Claude Code / `gh` / `pnpm`: progress bars,
spinners, a size-attributed tree, tables, multi-select checkboxes, keyboard navigation, live
in-place updates, and themes — while degrading cleanly to plain output for non-TTY, `NO_COLOR`,
`--no-tui`, `--ci`, and `--json`. The UI leans heavily on Unicode icons and emoji (🟢🟡🔴),
so **grapheme/East-Asian width correctness** is a hard requirement (wrong widths corrupt every
column and truncation). Swift has no mature, maintained TUI comparable to Rust's ratatui or Go's
bubbletea.

## Decision Drivers

1. **Exact control of the aesthetic** the brief specifies, including flicker-free live update.
2. **Correct emoji/wide-character width** — non-negotiable given icon-heavy rows.
3. **Clean non-TTY fallback** so `--json`/CI output is never polluted (spec 08 §3 contract).
4. **Minimal, stable dependencies** — no large or experimental framework in the render path.
5. **Testability** — deterministic rendered frames we can snapshot-test (spec 31).

## Options Considered

### Custom component layer over ANSI — chosen
- **Pros:** total control over aesthetic and behavior; a double-buffered renderer that diffs
  frames and emits minimal escapes gives flicker-free live update; we own the emoji/EAW width
  table (correct truncation/columns); clean, first-class plain fallback path; rendered frames are
  deterministic and snapshot-testable; no heavy/experimental dependency in the hot path. Small
  third-party helpers (color SGR, terminal size) are allowed *behind an adapter* so they're
  swappable (spec 10 §11).
- **Cons:** more code to own and test — the terminal control (alt-screen, raw mode, `SIGWINCH`),
  the width table, and the component set (spec 25) are ours to maintain.

### SwiftTUI (rensbreur) — rejected
- **Pros:** SwiftUI-like declarative API, pleasant for simple layouts.
- **Cons / why rejected:** experimental, layout-limited, small maintenance surface; we'd hit its
  ceiling fast and be unable to hit the exact aesthetic or the width-correctness bar without
  forking it — at which point we own it anyway, but with someone else's model.

### Noora (Tuist) — rejected
- **Pros:** polished prompt components.
- **Cons / why rejected:** it's a prompt toolkit, **not a full-screen TUI framework**; doesn't
  cover the tree/table/live-dashboard needs; adds a large dependency for partial coverage,
  against our dependency-minimization policy.

### ncurses via C interop — rejected
- **Pros:** powerful, ubiquitous, proven.
- **Cons / why rejected:** ugly C API, poor Unicode/emoji width handling (the exact thing we most
  need to get right), awkward theming, and a clumsy bridge from Swift concurrency. Fighting
  ncurses' width model would cost more than owning a correct one.

## Decision

Build a small, owned **`CleanerTUI`** module (spec 25): a low-level ANSI/SGR writer with
alternate-screen + raw-mode control, a double-buffered diffing frame renderer, a `SIGWINCH`
resize handler, an emoji/East-Asian-width table, and theme-driven components (`ProgressBar`,
`Spinner`, `Tree`, `Table`, `SelectList`/`MultiSelect`, `Confirm`, `Summary`, `KeyRouter`). All
components degrade to plain output when not a TTY / `NO_COLOR` / `--no-tui` / `--ci` / `--json`.
Third-party color/terminal-size helpers are permitted only behind a swappable adapter.

## Consequences

- We own more code — offset by snapshot tests of rendered frames across widths (spec 31) and by
  avoiding an unstable dependency in the critical UI path.
- The width table is a correctness dependency; generate it from Unicode data in a build plugin
  (OQ-10.2) rather than hand-maintaining it.
- The plain-fallback path is a first-class code path, not an afterthought — it guards the
  stdout/stderr contract (spec 08 §3) that keeps `--json | jq` clean.

## Links

- Constitution Article 10 (CC-4), principles 8 & 9.
- Spec 10 §6, spec 25 (TUI design system), spec 09 (navigation IA), spec 08 §3 (stdout/stderr),
  spec 31 (frame snapshot tests). OQ-10.2 (width-table generation).
- Related: ADR-0001 (thin Swift TUI ecosystem is the root cause).
