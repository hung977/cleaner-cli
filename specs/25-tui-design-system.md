# 25 — Terminal Presentation System

> **Phase F · Depends on:** 00-constitution (Art. 3 terminology, Art. 5 deny-list, Art. 7 exit
> codes), 07 (NFR-070…075 a11y, NFR-082 width), 08 (stdout/stderr contract), 09 (object model,
> scan → summary → prompt flow, terminology), 24 (color/unicode/locale config) ·
> **Depended on by:** 26 (CLI UX), 27 (error rendering), 31 (snapshot tests of output).
>
> The presentation layer of `cleaner`: the single-line **spinner**, the aligned **summary**, the
> **prompts**, and the **color** system — each with its exact rendering and behavior, the semantic
> color tokens and their truecolor→256→mono degradation, and the width/alignment rules. RFC-2119
> keywords are normative. The object model, terminology, and flow come from spec 09 and MUST match
> it verbatim. Where color conveys anything it MUST be redundant with text (NFR-071/072).
>
> **v0.6 note — the interactive TUI was removed.** An earlier version implemented a full-screen,
> alternate-screen, raw-mode picker (checkbox multi-select, tree view, progress bars,
> double-buffered diff renderer). It was **dropped** — see § 8 for the rationale. What ships, and
> what this spec now describes, is a **robust line-based CLI**: a stderr spinner, an aligned stdout
> summary, and plain `readLine` prompts. There are **no** alt-screen, no keyboard navigation, no
> checkboxes, no bars, no risk colours, and no frame renderer.

---

## 1. Scope & non-goals

The presentation layer is a **small set of pure string builders** plus two tiny stderr helpers
(the spinner line and the prompts). It renders exactly the flow of spec 09 (scan → summary →
prompt → clean report) and nothing else. It has two personalities, chosen per output stream by
simple capability checks (§ 6):

- **Colored line output** — ANSI SGR on a TTY, slate/teal/green palette, single-line spinner on
  stderr.
- **Plain line output** — no SGR at all for non-TTY / `--no-color` / `NO_COLOR` / `--json`; the
  spinner and prompts go silent or degrade to plain text. Byte output is screen-reader-friendly
  and pipe-safe (IA-1, NFR-070).

**Non-goals (explicitly out, and removed):** alternate screen / raw mode, keyboard navigation,
checkbox multi-select or tree pickers, determinate progress bars, box-drawing tables, a
double-buffered cell renderer, `SIGWINCH` reflow, mouse support, truecolor gradients as
load-bearing signal, and any risk-tier colouring (no 🟢🟡🔴).

---

## 2. Design language

- **Look like a normal CLI.** Output reads like `du`/`brew`: aligned columns, one idea per line,
  no chrome. No frames, no header/footer, no full-screen takeover.
- **Truth over flourish.** The spinner advances only while work advances; the summary total and
  the clean report use the **same measurement code** as the engine (principle 3). Nothing implies
  progress or savings that isn't real.
- **Color is decoration, never meaning.** Removing color (via `--no-color`/`NO_COLOR`/non-TTY)
  never removes information — every size and label is printed as text (IA-3). Color is a subtle
  slate/teal/green accent, not a signal channel.
- **Respect the terminal.** Never enter raw mode; never leave escape state behind (the spinner
  only ever writes `\r`+clear-line, and clears itself when done). Degrade to plain text on pipes
  and dumb terminals; honor `NO_COLOR` and narrow widths.

---

## 3. Output channels & layout

There is **no full-screen layout**. Output is a plain scrollback split across two streams (spec 08
§ 3):

```
 stdout   ← the result: the summary, the clean report, JSON, Markdown
 stderr   ← the process: the scan spinner, the prompts, warnings
```

- The **summary** and **clean report** are the payload → **stdout** (pipeable, redirectable).
- The **spinner** and all **prompts** are transient interaction → **stderr** (so `> out.txt`
  captures only the result).
- Width is read once from the controlling TTY (§ 7) and used to right-align sizes; it is clamped to
  `[40, 100]` columns so output stays tidy on both narrow and ultrawide terminals.

---

## 4. Components

Each component is a pure builder (given data + a `Style`, returns a `String`) or a thin stderr
writer. All are color-optional via `Style` (§ 5) and width-correct via padding helpers (§ 7).

### 4.1 Spinner (scan progress, stderr)

A single in-place status line drawn while the scan runs, so the tool never sits silent. It is the
**only** live/animated element in the whole tool.

```
  ⠹  scanning 6/8 · 18.4 GB · 4.1s
```

- **Frames (Braille):** `⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏`, advanced every **90 ms** (`Spinner.frames`).
- **Payload:** `scanning <done>/<total> · <bytes-so-far> · <elapsed>s` — plugin progress, running
  reclaimable, and wall time. Detectors reuse the same helper with a custom label
  (`⠹  finding large files · 2.1s`).
- **Draw / clear:** `LiveLine` writes `\r` + `ESC[2K` (clear-line) + text; on completion it clears
  the line entirely (`\r` + `ESC[2K`) so the final stdout summary starts clean. It never scrolls
  and never leaves partial escapes behind.
- **Silent when not live:** `LiveLine` is a **no-op** unless stderr is a TTY and output isn't
  machine mode — i.e. suppressed under pipes/CI and `--json` (`liveEnabled = isatty(stderr) &&
  !json`).
- There is **no determinate progress bar** and no percentage; total byte size isn't known until a
  plugin finishes, so a truthful bar isn't possible (principle 3) and a spinner is used instead.

### 4.2 Summary (the scan result, stdout)

A plain, aligned list: name on the left, **Reclaimable** size right-aligned to the width rule,
grouped Category → Source (spec 09 § 1). No bars, no boxes, no emoji, no risk colours.

```
  DISK RECLAIMABLE                                              18.4 GB
  3 source(s) · 4.1s

  Developer Cache                                               12.1 GB
    Xcode DerivedData (12)                                      12.1 GB

  Browser Cache                                                  4.8 GB
    Chrome cache                                                 4.8 GB

  Trash                                                          1.5 GB
    Trash                                                        1.5 GB

  Total  18.4 GB   ·   run cleaner to reclaim
```

- **Header:** `DISK RECLAIMABLE` (strong) with the grand total (green), then a dim
  `<n> source(s) · <elapsed>` line.
- **Category block:** a teal, bold category name with its roll-up size, then its **Source** rows
  indented beneath.
- **Source rows collapse per plugin:** a plugin with many Findings renders one row
  `Name (count)  size` (e.g. `Xcode DerivedData (12)`); a single-Finding Source shows the Item
  title directly. `-v`/`--verbose` expands a multi-item Source into a sub-header plus one line per
  Item.
- **Footer:** a `Total <bytes>` line; on a live run it ends `· run cleaner to reclaim` (or,
  mid-scan, `discovered so far`).
- **Empty state:** `Nothing reclaimable — your disk is tidy.`
- **Skipped plugins** print a dim `skipped <plugin>  <reason>` line.
- **Right-alignment** is measured on the **raw** (pre-ANSI) string so color codes never break
  column math; the size column width is the widest formatted size, and the name column
  middle-/tail-truncates with `…` when the line would overflow the width rule.

### 4.3 Prompts (confirmation, stderr)

Plain `readLine` prompts — **no raw mode, no single-keypress capture**. Two forms.

**Three-way clean prompt** (the top-level choice, spec 09 § 2):

```
  Clean all 18.4 GB? [Y = all · s = select each · n = cancel]
```

- Empty / `y` / `yes` / `a` / `all` → clean everything; `s` / `select` / `p` / `pick` → the
  per-Source walk; anything else → **cancel** (exit `cancelled`). The capitalized `Y` is the
  Enter-default.

**Per-Source `y/N`** (only after choosing `select each`), largest Source first:

```
    Xcode DerivedData (12)              12.1 GB  clean? [y/N]
    Chrome cache                         4.8 GB  clean? [y/N]
```

- Default is **No** (`[y/N]`): a bare Enter skips the Source, so nothing is cleaned by accident.
  If nothing is selected, the run ends with `Nothing selected.`
- **Non-TTY:** prompts are impossible, so an interactive run refuses and prints
  `Not a terminal — run with --yes to clean all.` `--yes` cleans all found Findings without
  prompting (the automation path). There is no typed-phrase confirmation because the default
  surface only ever **stages** (recoverable); nothing is irreversibly purged.

### 4.4 Clean report (the payoff, stdout)

The honest result of the run.

```
  Reclaimed  18.4 GB
  47 item(s) processed

  Undo with  cleaner undo
```

- **`Reclaimed <bytes>`** = actual allocation freed (CC-10); under `--dry-run` it reads
  `Would reclaim <bytes>   dry-run — nothing changed` in teal.
- **Counts:** `<ok> item(s) processed`, plus `· <n> failed` (red) and/or `· <n> blocked by safety`
  (red) when present; up to ten offending paths are listed with an `×` and a machine-stable reason
  (spec 27).
- **Undo hint:** whenever a real run staged anything, the `Undo with cleaner undo` line is shown —
  every clean is recoverable (spec 09 § 5).

### 4.5 NEXT STEPS (preview only, stdout)

Under `--dry-run`, the prompt is replaced by a suggestion block:

```
  NEXT STEPS
    cleaner               pick & reclaim 18.4 GB
    cleaner find large    biggest personal files
    cleaner find dupes    duplicate files
    cleaner docker        reclaim Docker space
    cleaner brew          clean old Homebrew versions
```

- The command column is padded to a fixed width (green, bold); the description is muted. The
  `docker`/`brew` rows appear only when those tools are on `PATH`.

### 4.6 Detector & undo output (stdout)

`cleaner find large` / `find dupes` and `cleaner undo [--list]` reuse the same primitives — aligned
`size  path` rows, teal session ids, `✓`/`×` result marks — never boxes or checkboxes. `--json`
bypasses all of this and prints the single machine document (spec 08).

---

## 5. Color system

### 5.1 The `Style` primitive

All coloring goes through `Style`, which is a **no-op when disabled** so callers never branch on
color themselves. Color is enabled only when: not `--no-color`, `NO_COLOR` unset, **and** the
target stream is a TTY (`useColor = !noColor && NO_COLOR==nil && isatty(stdout)`). Non-TTY stdout
is always plain (spec 08 § 3).

### 5.2 Truecolor → 256 degradation (the load-bearing rule)

`Style` emits color from a `0xRRGGBB` hex so the palette is defined once:

- **24-bit truecolor** (`ESC[38;2;r;g;bm`) **only** when `COLORTERM` is `truecolor` or `24bit`
  (iTerm2, VS Code, Ghostty, etc.).
- **Nearest xterm-256** (`ESC[38;5;Nm`, 6×6×6 cube + grayscale ramp) everywhere else. This is the
  critical fix: **Apple Terminal does not support truecolor** — it mis-parses `38;2;…` and eats
  the following characters — so we must fall back to 256-color there.
- **Plain** (no SGR) when color is disabled (§ 5.1).

There is no separate 8-color or "mono theme" rung; the two rungs are truecolor and xterm-256, with
plain text as the color-off path.

### 5.3 Semantic palette (slate / teal / green)

A subtle slate base with teal and green accents — chosen to read as a calm, normal CLI, not a
dashboard. Tokens reference hex, resolved per § 5.2.

| Token | Role | Hex |
|---|---|---|
| `textStrong` | headers, totals | `#E9F0F6` |
| `text` | body labels | `#C6D2DC` |
| `muted` | secondary text, hints | `#8B98A5` |
| `dim` / `faint` | tertiary text, separators | `#5E7180` / `#4D5A66` |
| `teal` | category names, session ids, accents | `#7ECEC0` |
| `green` | totals, `Reclaimed`, `✓`, primary CTA | `#8AC776` |
| `amber` | `skipped`, warnings | `#D9A441` |
| `red` | failures, `×`, blocked-by-safety | `#E5595C` |

Risk colours (green/amber/red as a Safe/Medium/Dangerous *signal*) are **not** used in v0.6 —
amber and red appear only for skipped/failed operational states, always alongside explanatory text.

---

## 6. Capability checks (per stream, at call time)

There is no startup "mode probe" and no interactive/linear branch — each builder is told whether to
color, and the spinner checks liveness:

```
 color on stdout?   = !--no-color  &&  NO_COLOR unset  &&  isatty(STDOUT)
 truecolor?         = COLORTERM ∈ {truecolor, 24bit}      → else nearest xterm-256
 spinner live?      = isatty(STDERR)  &&  !--json         → else silent no-op
 prompts possible?  = isatty(STDIN)                       → else require --yes
```

Every check degrades safely: no color, no spinner, no prompt — never a crash, never leftover
escape state.

---

## 7. Width & alignment

- **Width source of truth:** `ioctl(TIOCGWINSZ)` on stdout for the live column count; falls back to
  `$COLUMNS`, then `80`. The result is clamped to `[40, 100]` columns.
- **Alignment helpers:** `padLeft` / `padRight` pad to a fixed width, and `truncate` cuts with a
  trailing `…`. All measure the **raw** string, so ANSI SGR sequences never throw off column math.
- **Right-aligned sizes:** the size column is sized to the widest formatted `ByteCount`; name
  columns absorb the remaining width and tail-truncate with `…` when a line would overflow.
- **Caveat:** width is counted in Swift `Character`s, not display cells, so category glyphs and
  wide/emoji characters can misalign by a cell. This is accepted for v0.6 (the summary avoids emoji
  in the aligned columns); a grapheme-width table is deferred (OQ-25.1).

---

## 8. Why the interactive TUI was removed (history / rationale)

An earlier iteration shipped a full-screen `CleanerTUI`: alternate screen + raw mode, a
keyboard-navigated checkbox multi-select over a Category→Source tree, live progress bars, and a
double-buffered cell diff renderer. It was **removed** in favour of the line-based flow above.
Recorded so it isn't re-attempted without addressing the causes:

- **Truecolor mis-parse on Apple Terminal.** The renderer emitted `ESC[38;2;r;g;bm`; Apple Terminal
  doesn't support 24-bit color and mis-parsed the sequence, **eating following characters** and
  corrupting the frame. (Fixed generally by the truecolor→xterm-256 fallback in § 5.2.)
- **Narrow-terminal wrapping.** Full-screen layout assumed a width/height floor; on narrow or
  short windows the fixed-width frame wrapped and smeared, and `SIGWINCH` reflow was fragile.
- **Fragility vs. payoff.** Raw mode, cursor hiding, and alt-screen all need bullet-proof
  restore-on-every-exit-path; the complexity and the terminal-specific breakage weren't worth it
  for a tool whose core interaction is "show me the list, ask me once."

The line-based flow is **robust by construction**: it never enters raw mode or the alt screen, the
only escape it writes is the self-clearing spinner line, and it degrades cleanly to plain text on
any terminal, pipe, or CI.

---

## 9. Non-interactive / machine output

Under `--json`, none of the presentation chrome appears: stdout is the single spec-08 machine
document, the spinner is silent, and no prompt is issued (a run that would need a prompt but has no
`--yes` refuses, per § 4.3). Under `--md`, stdout is a Markdown report (implies preview). Under
`--no-color`/`NO_COLOR`/non-TTY, the same summary and report render as plain aligned text —
byte-stable modulo the timing values (NFR-070).

```
$ cleaner --dry-run --no-color | cat
  DISK RECLAIMABLE                                              18.4 GB
  3 source(s) · 4.1s

  Developer Cache                                               12.1 GB
    Xcode DerivedData (12)                                      12.1 GB
  …
  Total  18.4 GB   ·   run cleaner to reclaim

  NEXT STEPS
    cleaner               pick & reclaim 18.4 GB
    cleaner find large    biggest personal files
```

---

## Open Questions

- **OQ-25.1** Adopt a grapheme/East-Asian-width table so category glyphs and wide characters align
  to the cell, or keep `Character`-count padding and avoid emoji in aligned columns? *Leaning: keep
  simple padding for v0.6; the summary already avoids emoji in the size columns.*
- **OQ-25.2** Detect Apple Terminal (or absence of truecolor) beyond `COLORTERM`, or trust
  `COLORTERM` alone as the truecolor gate? *Leaning: `COLORTERM` alone — it's the reliable signal
  and the 256-color fallback is safe everywhere.*
- **OQ-25.3** Should the per-Source walk show a running "selected so far" total on stderr as the
  user answers? *Leaning: no — keep the prompt line minimal.*
- **OQ-25.4** Add a light/high-contrast palette variant, or keep the single slate theme? *Leaning:
  single theme for v0.6; `--no-color` covers accessibility needs.*

## Dependencies

- **Consumes:** 00 (terminology, deny-list, exit codes), 07 (a11y NFR-070…075, width NFR-082), 08
  (stdout/stderr contract, `--json`/`--md` machine paths, prompt→exit codes), 09 (object model,
  scan→summary→prompt flow, terminology), 24 (color/unicode/locale config).
- **Feeds:** 26 (CLI UX reuses `Style`, the palette, and the output policy), 27 (error/skip
  rendering, plain-text degradation), 31 (snapshot tests of the summary, spinner suppression, and
  color-off output).
</content>
