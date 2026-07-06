# 25 — TUI Design System

> **Phase F · Depends on:** 00-constitution (Art. 4 risk icons, Art. 7, CC-4/ADR-0004), 07 (NFR-020…
> 024 frame budget, NFR-070…075 a11y, NFR-082 width), 08 (stdout/stderr contract), 09 (screens S0–S8,
> nav map, terminology), 10 (ADR-0004 custom TUI), 24 (theme/animation/unicode/locale config) ·
> **Depended on by:** 26 (CLI UX), 27 (error rendering in TUI), 31 (snapshot tests of frames).
>
> The owned component layer of `CleanerTUI` (ADR-0004): every component with an ASCII mockup **and**
> behavior, the color-theme system and semantic tokens, the Unicode icon set, the keyboard map, the
> animation policy, responsive/layout rules, and the rendering model (double-buffer diff, alt-screen,
> `SIGWINCH`). RFC-2119 keywords are normative. Screens (S0–S8) and terminology come from spec 09 and
> MUST match it verbatim. Where color conveys meaning it MUST be redundant with text+icon (NFR-071/072).

---

## 1. Scope & non-goals

`CleanerTUI` is a **small, focused, owned** component + rendering library (ADR-0004), not a general
framework. It renders the screens of spec 09, the outputs of spec 08, and nothing else. Non-goals:
mouse support (v1 is keyboard-only, NFR-074), truecolor gradients as *load-bearing* signal, arbitrary
layout engines. It has two output personalities selected once at startup by capability probing (§ 11):

- **Interactive TUI** — alternate screen, raw mode, full-screen diff rendering (S0–S8).
- **Linear plain** — a byte-stream, screen-reader-friendly equivalent for non-TTY / `--no-tui` /
  `--ci` / `--json` (IA-1, NFR-070). Every component defines *both* renderings.

---

## 2. Design language

- **Truth over flourish.** Chrome never implies progress or savings that isn't real (principle 3).
  A spinner spins only while work advances (NFR-022). A bar's percentage is measured, never faked.
- **Redundant encoding.** Risk = icon **+** word **+** (optional) color, never color alone (IA-3).
- **Calm density.** Dense but scannable: right-aligned sizes, aligned columns, one idea per line.
- **Progressive disclosure** (spec 09 §6): L1 summary → L2 detail → L3 item; drilling is cheap,
  clutter is opt-in.
- **Respect the terminal.** Restore cooked mode on every exit path (NFR-043); degrade, never crash,
  on dumb terminals; honor `NO_COLOR`, reduced-motion, and narrow widths.

---

## 3. Layout skeleton (every full-screen screen)

Persistent **header** (scope + running reclaim total) and **footer** (context key hints) frame every
screen (spec 09 §2). The middle is the screen body. A transient **toast** row sits above the footer.

```
┌─ Row 0  HEADER ─────────────────────────────────────────────────────────────┐
│ cleaner · Clean            Volume: Macintosh HD (home)     Selected: 12.4 GiB │  ← scope + total
├──────────────────────────────────────────────────────────────────────────────┤
│ Row 1..H-3  BODY                                                              │
│   (screen content: tree / table / list / preview / progress / summary)       │
│                                                                              │
├──────────────────────────────────────────────────────────────────────────────┤
│ Row H-2  TOAST (transient)   ⓘ Staged 40 items · press u to undo             │
├─ Row H-1  FOOTER ───────────────────────────────────────────────────────────┤
│ ↑↓ move  space select  a all  ⏎ preview  / filter  s sort  ? help  q quit    │  ← context hints
└──────────────────────────────────────────────────────────────────────────────┘
```

Header/footer are **1 row** each (2 in `--wide` breakpoint, § 10). Footer hints are **context-
sensitive** (only keys valid on the current screen) and truncate right-to-left when narrow.

---

## 4. Components

Each component: an ASCII mockup, behavior, states, and the **linear (non-TTY) rendering**. All are
theme-driven (§ 6) and width-correct (§ 10).

### 4.1 ProgressBar

Determinate (known total) and indeterminate (unknown) forms. Frame budget ≤ 33 ms (NFR-020);
updates coalesce to ≤ 1 repaint per frame even if data updates faster.

```
Determinate:
  Scanning ~/Library/Caches                                            72%
  ▕████████████████████████████████████████▏                ▏  1.8 GiB / 2.5 GiB
  312,481 files · 41k files/s · eta 3s

Indeterminate (unknown total, e.g. hashing before sizes known):
  Hashing duplicate candidates  ⟨▪▪▪▪�ढ▪▪▪⟩   18,204 files · 2m04s
```

- **Fill glyphs:** full `█`, partial via 8ths (`▏▎▍▌▋▊▉`) for sub-cell precision; track `░`/space.
  ASCII fallback: `[####----]`. Width = available columns minus labels; min bar width 10 cols or the
  bar is dropped in favor of a bare percentage (§ 10).
- **Right label** carries measured/total bytes (same measurement code as the real run, principle 3).
- **Reduced-motion / `--no-animation`:** no sweep animation; the bar still advances but only on
  discrete percentage change (NFR-075).
- **Linear:** periodic lines to stderr: `scan: 72% (1.8/2.5 GiB, 312481 files) eta 3s`, rate-limited
  to ≥ 500 ms and on completion (NFR-022). Suppressed entirely under `--quiet`/`--json`.

### 4.2 Spinner

For unmeasurable waits (adapter calls, Spotlight query, permission dialog). Never used when a
determinate bar is possible.

```
⠋ Querying Spotlight for last-used dates…
```

- **Frames (Braille, default):** `⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏` at **80 ms/frame** (12.5 fps — subtle, § 9).
- **ASCII fallback frames:** `| / - \`. **Dots theme:** `⣾⣽⣻⢿⡿⣟⣯⣷`.
- Stops with a terminal glyph: `✔` success, `✖` failure, `⚠` warning, `⓪` skipped — colored by
  semantic token, always with trailing text.
- **Reduced-motion:** a static `⏳` + text; updates the text, not the glyph.
- **Linear:** prints the label once, then a single result line (`✔ Queried Spotlight (0.4s)`).

### 4.3 Tree (collapsible, sized)

The Category → Plugin → Finding hierarchy (spec 09 §1). Collapsible nodes, roll-up sizes on every
node header (spec 09 §4), tri-state selection cascade.

```
▾ 🧰 Developer                                              28.9 GiB   ▣ (tri)
│  ▾ derived-data  · Xcode DerivedData                      21.4 GiB   ☑
│  │   🟢 App-abcdef/Build                     12.1 GiB   manual   ☑
│  │   🟢 Framework-123/Build                   9.3 GiB   manual   ☑
│  ▸ swiftpm  · SwiftPM caches                               4.1 GiB   ☑
│  ▸ npm-cache · ~/.npm                                      3.4 GiB   ☐
▸ 🌐 Browsers                                                6.2 GiB   ☐
▸ 🗃 System                                                  2.1 GiB   ☐
```

- **Disclosure glyphs:** `▾` expanded, `▸` collapsed, leaf none. Indent guides `│  `. Size column
  **right-aligned** at a fixed rule; risk icon precedes leaf labels; recoverability + checkbox trail.
- **Selection:** `☑` selected, `☐` unselected, `▣` partial (tri-state); cascades down, rolls up
  (spec 09 §1). 🔴 leaves render `☐🔒` and cannot be checked without the typed-confirm gate (§ 4.6).
- **Sizes** are allocated bytes, clone/hardlink-deduped (CC-10, FR-042). Recompute on
  expand/collapse is O(children), cached.
- **Linear:** an indented outline with `[x]/[ ]/[~]` markers and `(risk word)`; expansion becomes a
  `--depth`-controlled flatten.

### 4.4 Table (aligned, box-drawing)

For `plugins list`, `staging list`, `analyze` breakdowns. Unicode box-drawing, per-column alignment,
truncation with an ellipsis that respects grapheme width (§ 10).

```
┌──────────────┬────────────┬────────┬──────────┬───────────┐
│ Plugin       │ Category   │  Risk  │  Enabled │  Reclaim  │
├──────────────┼────────────┼────────┼──────────┼───────────┤
│ derived-data │ Developer  │  🟢 Safe│    ✔    │  21.4 GiB │
│ docker       │ Developer  │ 🟡 Med  │    ✔    │   8.2 GiB │
│ browser-cache│ Browsers   │  🟢 Safe│    ✔    │   6.2 GiB │
│ unused-apps  │ System     │ 🔴 Dang │    ✔    │   0 B (advisory) │
└──────────────┴────────────┴────────┴──────────┴───────────┘
  3 plugins shown · 1 advisory · totals exclude advisory-only
```

- **Alignment:** text left, numbers/sizes right, icons centered. Column widths computed from content
  with min/max caps; overflow truncates the widest text column first (`…`), never the size column.
- **Border styles by theme:** rounded (`╭╮╰╯`), square (`┌┐└┘`), or ASCII (`+---+`). High-contrast
  uses heavy rules (`┃━╋`).
- **Zebra** striping via `muted` background token (skipped under `NO_COLOR`; alignment still parses).
- **Linear:** the same rows as TSV-ish aligned columns without borders, or true TSV under `--json`
  is N/A (JSON path bypasses the table).

### 4.5 SelectList / MultiSelect (checkboxes)

The interactive selection primitive behind S2/S3. Cursor row, space toggles, `a` toggles all
visible, `/` filters.

```
Select findings to clean               3 selected · 12.4 GiB      [/ to filter]
────────────────────────────────────────────────────────────────────────────
❯ ☑ 🟢 DerivedData · App-abcdef            12.1 GiB   manual
  ☑ 🟢 DerivedData · Framework-123          9.3 GiB   manual
  ☐ 🟡 npm cache · ~/.npm                    3.4 GiB   manual   (re-download)
  ☐🔒 🔴 Old Xcode 14.2 runtime              6.1 GiB   hard     [type to confirm]
────────────────────────────────────────────────────────────────────────────
 space toggle · a all · n none · enter preview · tab groups · esc back
```

- **Cursor** `❯`; selected `☑`; 🔴 locked `☐🔒`. Filter (`/`) narrows in place; `a`/`n` act on the
  *filtered* set (and say so in a toast). Selection total updates live in the header.
- **Linear (non-TTY):** a numbered list + a prompt: `Enter numbers to toggle (e.g. 1,3-5), 'a' all,
  Enter to continue:` — same semantics, sequential (IA-1, NFR-070).

### 4.6 Confirm / typed-confirm prompt

Two forms: a simple `[y/N]` for reversible defaults, and a **typed-confirm** for 🔴 (Article 4.1) —
a single keypress is never enough to destroy 🔴 items.

```
Simple:
  Stage 40 items (12.4 GiB) to ~/.cleaner/staging?  [Y/n] ▏

Typed-confirm (🔴 present):
  ⚠ 2 Dangerous 🔴 items are selected — these may be hard to recover:
      • /Applications/OldTool.app                 640 MiB   recoverability: hard
      • ~/Library/Developer/…/iOS 14.2.simruntime 6.1 GiB   recoverability: hard
  This cannot be undone from Staging for 'hard' items.
  Type  delete  to confirm, or press Esc to cancel:  ▏
```

- **Default is the safe choice** (capital letter): `[Y/n]` when the action is reversible staging,
  `[y/N]` when it purges. Enter picks the capitalized default.
- **Typed-confirm** requires the exact `default.confirmPhrase` (config § 24, default `delete`),
  matched case-insensitively after trim; anything else re-prompts; Esc cancels → exit `5`.
- **Non-TTY:** confirmation is impossible ⇒ requires `--yes` (🟢/🟡 only) or a signed policy; else
  exit `2` (spec 08 conflicts). 🔴 is **never** auto-confirmed by `--yes` (Article 4.1).

### 4.7 Summary panel (the reclaim summary — S7)

The payoff screen. Honest totals, per-category breakdown, skipped/failed with reasons, rollback hint,
report path.

```
╭─────────────────────────  ✅  Reclaimed 12.0 GiB  ─────────────────────────╮
│                                                                            │
│   Freed        12.0 GiB   (staged — recoverable for 30 days)               │
│   Items        40 staged · 2 skipped · 0 failed                            │
│   Duration     4.2s                                                        │
│                                                                            │
│   By category                                                              │
│     🧰 Developer     ████████████████████████░░░░   9.8 GiB   (35 items)   │
│     🌐 Browsers      ██████░░░░░░░░░░░░░░░░░░░░░░░   1.9 GiB   ( 4 items)   │
│     🗑 Trash & Temp  █░░░░░░░░░░░░░░░░░░░░░░░░░░░░   0.3 GiB   ( 1 item )   │
│                                                                            │
│   Skipped (2)                                                              │
│     🟡 ~/.npm            locked (in use)      3.4 GiB    kept              │
│     🟢 …/DerivedData/X   vanished mid-run     —          kept              │
│                                                                            │
│   Undo        cleaner staging restore 6f1c9c2e                             │
│   Report      ~/.cleaner/reports/6f1c9c2e.json  ·  --format markdown       │
╰────────────────────────────────────────────────────────────────────────────╯
  press r to restore · o to open report · q to quit
```

- **Volume-freed sparkbars** use `muted`→`accent` gradient in one axis; each carries a numeric size,
  so `NO_COLOR`/mono keep it legible. Bars are proportional to *this run's* freed bytes.
- **"Freed"** = actual on-disk allocation freed (CC-10); if staging (not purge) the panel says
  "staged — recoverable", never "deleted" (spec 09 §5 terminology).
- **Skipped/failed** always list a machine-stable reason (spec 27); "vanished mid-run" and "locked"
  are common, honestly shown, exit `3` if any (Article 7).
- **Linear:** the same content as a flat, labeled block (no box) — the canonical `--no-tui` summary,
  identical to the human stdout of `clean` (spec 08 §3).

### 4.8 Live-updating scan view (S1/S6 body)

Streams `AsyncStream<Finding>` (spec 10 §5) into a top-N live table while a bar tracks coverage.
Off-render-actor work keeps input < 100 ms (NFR-021/023).

```
Analyzing  Macintosh HD · home                                    ⠹  elapsed 6s
▕██████████████████████████████████▏░░░░░░░░░░░░░  68%   3.1M / 4.6M files · 47k/s

Top findings so far                                        (live · sorted by size)
  🟢 🧰 Xcode DerivedData                    21.4 GiB   ▲
  🟢 🌐 Chrome cache                          4.8 GiB
  🟡 🐳 Docker build cache                    4.1 GiB   ▲
  🟢 📦 SwiftPM caches                        3.9 GiB
  🟢 🗑 Trash                                 2.2 GiB
  … 41 more categories                       scanning…
────────────────────────────────────────────────────────────────────────────
 q cancel (keeps partial)   space pause stream   enter drill when done
```

- **`▲`** marks rows that changed since the last frame (subtle, decays after 1 frame). List is capped
  to visible rows + a "N more" tail; full list on completion. Sort is stable descending Reclaim
  (IA-4) even while streaming.
- **Cancel** (`q`/Ctrl-C) is honored < 200 ms at the next boundary (NFR-040) and lands on a partial
  Summary (S7), exit `5`.
- **Linear:** progress lines (§ 4.1) plus a final ranked list; no live table.

---

## 5. Keyboard navigation map

One global map; screens add context keys shown in the footer (spec 09 §2). Keys are documented and
discoverable via `?` (NFR-074).

| Key(s) | Action | Scope |
|---|---|---|
| `↑ ↓` / `k j` | Move cursor | lists, trees, tables |
| `← →` / `h l` | Collapse / expand node | tree |
| `PgUp PgDn` / `Ctrl-b Ctrl-f` | Page | lists |
| `Home End` / `g G` | First / last | lists |
| `Space` | Toggle selection (tri-state cascade) | select lists, tree |
| `a` | Select all (filtered) visible | select |
| `n` | Select none | select |
| `Enter` | Drill in / confirm / preview | context |
| `Esc` / `Backspace` | Back (pop screen) | nav |
| `Tab` / `Shift-Tab` | Next / prev pane or group | multi-pane |
| `/` | Filter (incremental) | lists |
| `s` | Cycle sort key (size→risk→age→name) | lists |
| `?` | Help overlay (full key map) | global |
| `u` | Undo last (restore staged session) | after S7 |
| `r` / `o` | Restore / open report | S7 |
| `q` | Quit, or cancel a running op → partial | global |
| `Ctrl-C` | Cancel (SIGINT) → exit `5`/`130` | global |
| digits, `,` `-` | Toggle by number/range | **linear** mode select |

- **Modality:** typing into `/` filter or a typed-confirm captures alphanumerics; `Esc` exits the
  field. Otherwise keys are commands. Ambiguity resolved by an explicit input-mode flag.
- **Help overlay (`?`)** is a scrollable modal listing the *current screen's* keys first, then
  globals; dismiss with `?`/`Esc`.

---

## 6. Color theme system

### 6.1 Semantic tokens

Views reference **tokens**, never raw colors — themes remap tokens (NFR-072). Tokens:

| Token | Meaning | Default-dark (256/truecolor) | Mono/`NO_COLOR` |
|---|---|---|---|
| `risk.safe` | 🟢 Safe | green `#3FB950` | (icon+word only) |
| `risk.medium` | 🟡 Medium | amber `#D29922` | " |
| `risk.danger` | 🔴 Dangerous | red `#F85149` | " |
| `accent` | primary action / selection | blue `#58A6FF` | reverse-video |
| `success` | ✔ done / reclaimed | green `#3FB950` | `✔` glyph |
| `warning` | ⚠ caution | amber `#D29922` | `⚠` glyph |
| `error` | ✖ failure | red `#F85149` | `✖` glyph |
| `muted` | secondary text, guides, tracks | grey `#8B949E` | dim/none |
| `fg` / `bg` | default text / background | `#C9D1D9` / default | terminal default |
| `border` | box-drawing rules | `#30363D` | default |
| `cursor` | `❯` current row | accent + bold | reverse-video |

Risk color is **always** paired with icon+word (IA-3); removing color never removes meaning.

### 6.2 Named themes (shipped)

| Theme id | For | Notes |
|---|---|---|
| `default-dark` | dark terminals | truecolor→256→8 downshift |
| `light` | light terminals | darker fg, lighter muted |
| `high-contrast` | low vision | max contrast, heavy borders, bold labels |
| `deuteranopia` | red-green CVD (deutan) | risk via **blue/orange/magenta** hues + icons (NFR-072) |
| `protanopia` | red-green CVD (protan) | protan-safe palette variant |
| `mono` | `NO_COLOR`, dumb terms, pipes | zero SGR; icons + words + shape only |

CVD themes never rely on red vs green (NFR-072): risk is disambiguated by hue-shifted, luminance-
distinct colors **and** the mandatory icon+word. Theme is chosen by `ui.theme` (spec 24), overridden
by `--no-color`/`NO_COLOR` (→ `mono`) and by capability probing (8-color terminals collapse to the
8-color ramp).

### 6.3 Degradation ladder

```
truecolor (24-bit)  →  256-color  →  8-color ANSI  →  mono (no SGR)
     ↑ probed from $COLORTERM / terminfo; NO_COLOR or --no-color jumps straight to mono
```

Each theme defines its palette at every rung; the renderer picks the highest the terminal supports
(§ 11). `NO_COLOR` (any value) and `--no-color` force `mono` (NFR-071). Non-TTY stdout is always
`mono` regardless (spec 08 §3).

---

## 7. Unicode icon set

Icons are **redundant labels**, never the sole signal. A width-correct table (§ 10, NFR-082) governs
their column cost. `ui.unicode: ascii` swaps every icon for an ASCII token.

| Category / concept | Icon | ASCII fallback | Notes |
|---|---|---|---|
| Developer | 🧰 | `[dev]` | category |
| Browsers | 🌐 | `[web]` | |
| System | 🗃 | `[sys]` | |
| Caches | 🧹 | `[cache]` | |
| Media / Duplicates | 🎞 | `[media]` | |
| Trash & Temp | 🗑 | `[trash]` | |
| Docker | 🐳 | `[docker]` | plugin glyph |
| Package cache (npm/spm/brew) | 📦 | `[pkg]` | |
| Risk Safe | 🟢 | `(safe)` | + word, always |
| Risk Medium | 🟡 | `(med)` | + word |
| Risk Dangerous | 🔴 | `(dang)` | + word |
| Success / reclaimed | ✅ / ✔ | `OK` | |
| Warning | ⚠ | `!` | |
| Error | ✖ | `X` | |
| Info / toast | ⓘ | `i` | |
| Protected / locked | 🔒 | `[locked]` | 🔴 lock, whitelist |
| Advisory (audit) | 💡 | `[hint]` | opportunities |

All are drawn from a curated set with **known display width** (most emoji = 2 cells; § 10). No icon
is chosen whose width is terminal-ambiguous without a fallback.

---

## 8. Animation policy

- **Subtle by default.** Spinner 12.5 fps (§ 4.2); progress-bar sweep is a 1-cell shimmer at ≤ 10 fps;
  row-change `▲` markers decay in 1 frame. No blinking, no bounce, no color cycling.
- **Frame budget:** the render loop targets **≥ 30 fps / ≤ 33 ms p95** (NFR-020) and coalesces data
  updates to ≤ 1 repaint per frame. Animations never exceed the budget; if a frame would overrun, the
  animation step is dropped, not the data.
- **Reduced motion** (`ui.animation: false`, `CLEANER_NO_ANIMATION`, `--no-animation`, or an OS
  reduced-motion signal, NFR-075): spinners → static glyph + text; bars → discrete percentage only;
  no shimmer, no `▲`. Meaning is preserved; only motion is removed.
- **Never** animate to imply progress that isn't happening (principle 3) — a stalled operation shows a
  static "waiting…" not a spinning frame.

---

## 9. Rendering model

### 9.1 Pipeline

```
 View tree ──layout──▶ Cell buffer (back)      ┌ diff(back, front) ─▶ minimal ANSI escapes ─▶ stderr
   (components)         W×H grid of Cell        │
 Cell = { grapheme, width(1|2), fg, bg, attrs } └ swap: front ← back
```

- **Double-buffered diff.** Each frame renders into a back buffer of `Cell`s; the renderer diffs
  against the displayed front buffer and emits only changed spans (cursor-move + SGR + text),
  achieving flicker-free live update (ADR-0004, NFR-020). Full repaint only on theme change, resize,
  or first frame.
- **Cell width** carries 1 or 2 (emoji/CJK) so column math and diffing stay correct (§ 10). A
  2-wide cell owns a trailing "continuation" cell that the diff treats atomically.
- **Alternate screen + raw mode.** Interactive mode enters the alt screen (`ESC[?1049h`), hides the
  cursor, sets raw mode; on **any** exit path (normal, error, signal, panic) a terminal-restore guard
  runs (`ESC[?1049l`, show cursor, cooked mode) — NFR-043. Registered via `atexit` + signal handlers
  + a Swift `defer`/actor teardown.
- **Render runs on its own actor**, off the scan/clean work actors (NFR-023); input is read on a
  dedicated reader; components are `Sendable` snapshots handed to the renderer per frame.

### 9.2 Resize (`SIGWINCH`)

A `SIGWINCH` handler posts a resize event; the next frame re-queries `TIOCGWINSZ`, re-layouts, and
does a **full** repaint into a buffer of the new size, reflowing within 1 frame without corruption
(NFR-024). Debounced to coalesce rapid drags.

### 9.3 Frame budget accounting (from spec 07)

| Stage | Budget (of 33 ms) | Notes |
|---|---|---|
| Layout | ≤ 8 ms | O(visible rows); virtualized lists |
| Buffer render | ≤ 10 ms | cell fills, width lookup cached |
| Diff + encode | ≤ 8 ms | minimal-span emit |
| Write (stderr) | ≤ 5 ms | batched single `write` |
| slack | ~2 ms | dropped-animation cushion |

Snapshot tests (spec 31) render frames deterministically (fixed clock, fixed size) and assert byte
output; a bench (`tui-frame`) enforces the budget (NFR-020).

---

## 10. Responsive & width rules

- **Width source of truth:** an East-Asian-width + emoji-grapheme width table (ADR-0004, OQ-10.2),
  generated from Unicode data at build time. Every layout/truncation query goes through it — never
  `String.count` (which mismeasures emoji/CJK, causing misalignment, NFR-082).
- **Truncation** cuts on grapheme-cluster boundaries and never splits a 2-wide cell; the ellipsis `…`
  (1 cell) replaces the tail. Middle-truncation for paths: `~/Lib…/DerivedData/App-abc`.
- **Breakpoints** (terminal columns):

| Width | Mode | Behavior |
|---|---|---|
| `< 40` | **minimal** | single-column list; drop bars → bare `72%`; icons→ascii if `unicode:auto` can't fit; no side columns |
| `40–79` | **compact** | 1-line header/footer; tables drop the least-important column (recoverability), sizes kept |
| `80–119` | **standard** | full layout as mocked here |
| `≥ 120` | **wide** | 2-line header (adds free-space gauge), tree shows evidence hints inline, wider size column |
| height `< 10` | **short** | collapse header/footer to 1 row combined; body scrolls |

- **Column priority** (drop order when narrowing): recoverability → risk-word (keep icon) → count →
  age → path (middle-truncate) → **size never dropped**.
- Below a usable floor (`< 20` cols or `< 4` rows) the TUI refuses and falls back to linear plain
  output with a note (still exit-code correct).

---

## 11. Capability probing & mode selection (startup)

```
 is stderr a TTY?  ──no──▶ LINEAR plain (mono)         [also: --no-tui/--ci/--json → LINEAR]
        │yes
 --no-tui / ui.tui:false? ──yes──▶ LINEAR plain
        │no
 term size ≥ floor? ──no──▶ LINEAR plain (+note)
        │yes
 probe: TERM/terminfo, $COLORTERM (truecolor?), alt-screen, unicode width, reduced-motion
        │
        ▼
 INTERACTIVE TUI  @ (theme rung, unicode level, animation on/off) resolved from probe + spec-24 config
```

Probing never assumes; it reads `TERM`/terminfo, `$COLORTERM`, `NO_COLOR`, tmux/ssh hints, and the OS
reduced-motion signal (NFR-093). Any negative result degrades one rung, never crashes.

---

## 12. Full-screen interactive mockup (S3 Findings → S4 Preview)

```
┌ cleaner · Clean ─────────────────────────────────────────────────────────────┐
│ Volume: Macintosh HD (home)              Scope: $HOME        Selected: 21.4 GiB│
├──────────────────────────────────────────────────────────────────────────────┤
│ Findings · Developer › derived-data                       sort: size ▾  /filter│
│                                                                              │
│ ❯ ☑ 🟢 App-abcdef · DerivedData/Build            12.1 GiB   manual           │
│   ☑ 🟢 Framework-123 · DerivedData/Build          9.3 GiB   manual           │
│   ☐ 🟡 ModuleCache.noindex                         2.7 GiB   manual  (rebuild)│
│   ☐🔒 🔴 iOS 14.2 Simulator runtime                6.1 GiB   hard   [confirm] │
│                                                                              │
│   ▸ swiftpm    · SwiftPM caches                    4.1 GiB   ☑                │
│   ▸ npm-cache  · ~/.npm                            3.4 GiB   ☐                │
│                                                                              │
│   Why flagged (App-abcdef):  regenerable ✔ · last built 12d ago · no user data│
├──────────────────────────────────────────────────────────────────────────────┤
│ ⓘ 2 selected · 21.4 GiB reclaimable · disposition: stage (recoverable 30d)   │
├──────────────────────────────────────────────────────────────────────────────┤
│ space select  a all  s sort  / filter  ⏎ preview  esc back  ? help  q quit   │
└──────────────────────────────────────────────────────────────────────────────┘

  ── press ⏎ preview ──▶

┌ cleaner · Clean · Preview ───────────────────────────────────────────────────┐
│ Plan: stage 2 items · reclaim 21.4 GiB · 0 Dangerous selected                 │
├──────────────────────────────────────────────────────────────────────────────┤
│  🟢 App-abcdef/Build       12.1 GiB → stage   ~/…/DerivedData/App-abcdef       │
│  🟢 Framework-123/Build     9.3 GiB → stage   ~/…/DerivedData/Framework-123    │
│                                                                              │
│  Risk recap:  🟢 Safe 2   🟡 Medium 0   🔴 Dangerous 0                        │
│  Disposition: stage → ~/.cleaner/staging/<new-session>  (restore anytime)     │
│  Nothing is deleted permanently. Undo with:  cleaner staging restore <id>     │
├──────────────────────────────────────────────────────────────────────────────┤
│ Stage 2 items (21.4 GiB)?  [Y/n]  ▏                                           │
├──────────────────────────────────────────────────────────────────────────────┤
│ ⏎/y confirm   n/esc back to edit   d show exact paths (L3)   q cancel        │
└──────────────────────────────────────────────────────────────────────────────┘
```

If a 🔴 item were selected, the confirm row becomes the typed-confirm prompt of § 4.6.

---

## 13. Non-interactive output mockup (the same run, `--no-tui`)

Linear, screen-reader-friendly, byte-stable modulo the timing block (spec 08 §3, NFR-070). stdout =
result; progress/prompts = stderr.

```
$ cleaner clean --plugins derived-data --no-tui
Scanning derived-data … done (312,481 files, 3.1s)                        [stderr]

Findings — Developer › derived-data                                       [stdout]
  [x] Safe  App-abcdef · DerivedData/Build           12.1 GiB   manual
  [x] Safe  Framework-123 · DerivedData/Build         9.3 GiB   manual
  [ ] Med   ModuleCache.noindex                        2.7 GiB   manual
  2 of 3 selected · 21.4 GiB reclaimable · disposition: stage

Preview:
  stage  App-abcdef/Build      12.1 GiB   ~/Library/Developer/Xcode/DerivedData/App-abcdef
  stage  Framework-123/Build    9.3 GiB   ~/Library/Developer/Xcode/DerivedData/Framework-123
  Risk: Safe 2, Medium 0, Dangerous 0. Nothing deleted permanently.

Stage 2 items (21.4 GiB)? [Y/n]                                           [stderr]
> y

Reclaimed 21.4 GiB (staged — recoverable for 30 days).                   [stdout]
  40 staged · 0 skipped · 0 failed · 3.4s
  Undo:   cleaner staging restore 6f1c9c2e
  Report: ~/.cleaner/reports/6f1c9c2e.json
exit: 0
```

Under `--json`, none of the above chrome appears; stdout is the single spec-08 §9.3 document and all
progress/prompts are suppressed (a run needing a prompt without `--yes` errors, exit `2`).

---

## Open Questions

- **OQ-25.1** Width table: vendor a prebuilt table or generate via SPM build plugin from Unicode data
  (inherits OQ-10.2)? *Leaning: build plugin for correctness across Unicode versions.*
- **OQ-25.2** Do we detect terminal emoji-width *variance* (some terminals render certain emoji as 1
  cell) at runtime, or standardize on the Unicode `Wide`/`Emoji_Presentation` table and accept rare
  drift? *Leaning: standardize + `unicode:ascii` escape hatch.*
- **OQ-25.3** Should the S6 live scan table be pausable (`space`) in v1, or is that scope creep?
  *Leaning: include — cheap and helps reading a fast stream.*
- **OQ-25.4** Reduced-motion auto-detection on macOS from the CLI (no AppKit in headless builds,
  NFR-092) — read the defaults domain, or rely on config/env only? *Leaning: config/env + optional
  isolated AppKit probe.*
- **OQ-25.5** High-contrast theme: ship one, or split into dark-HC and light-HC? *Leaning: one
  auto-inverting HC in v1.*

## Dependencies

- **Consumes:** 00 (Art. 4 risk icons/gates, Art. 7 exit codes, CC-4/ADR-0004), 07 (NFR-020…024
  responsiveness/frame budget, NFR-070…075 a11y, NFR-082 width), 08 (stdout/stderr contract, screens
  to render, prompts→exit codes), 09 (S0–S8 screen map, nav keys, terminology, disclosure), 10
  (ADR-0004 custom layer, width table, deps), 24 (theme/animation/unicode/locale/color config).
- **Feeds:** 26 (CLI UX reuses tokens, output policy, degradation), 27 (error/toast rendering,
  terminal restore on panic), 31 (frame snapshot tests, resize/width/theme-CVD tests, input-latency
  and frame-budget benches).
