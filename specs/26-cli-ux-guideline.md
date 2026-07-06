# 26 — CLI UX Guideline

> **Phase F · Depends on:** 00-constitution (Art. 1 principles, Art. 7 exit codes), 07 (NFR-070…082
> a11y/i18n, NFR-112 stream separation), 08-command-reference (surface, flags, stdout/stderr
> contract, JSON), 09-information-architecture (taxonomy, disclosure, terminology), 24 (config/env),
> 25 (TUI components/themes) · **Depended on by:** 27 (error message style), 28 (log routing), 29
> (consent copy), 31 (CLI snapshot + golden-output tests).
>
> The house style for the command-line surface: principles (a CLIG.dev-adapted charter), flag and
> naming conventions, defaults, dangerous-action policy, `--dry-run`, error/next-step style, machine
> output, verbosity, TTY/pipe behavior, `--no-input`, help-text style, discoverability, the
> stdout/stderr/color output guide, the copywriting voice, and localization hooks. RFC-2119 keywords
> are normative. Where this spec and spec 08 overlap, **spec 08 is the surface of record**; this spec
> is the *how it should feel*.

---

## 1. The charter (adapted from CLIG.dev, ranked)

These are ranked; when two conflict, the lower number wins. They are the CLI-surface reading of
Constitution Article 1.

1. **Human-first, scriptable-always.** The default experience is designed for a person at a TTY; but
   **every** action is fully reachable non-interactively (flags, env, `--json`, `--yes`, `--no-input`)
   with stable exit codes. No capability is TUI-only (IA-1, NFR-070).
2. **Safe by default** (principle 1). Destructive verbs preview first, confirm second, execute third.
   Defaults never surprise a user into data loss: default disposition is reversible `stage`, 🔴 is
   never auto-selected, `--yes` never touches 🔴.
3. **Honest output** (principle 3). Never overstate savings, never claim success not achieved, always
   report what was skipped and why. Same measurement code for dry-run and real run.
4. **Consistency.** One grammar for flags, selectors, sizes, and output across every command
   (spec 08). A user who learns `clean` can predict `optimize`.
5. **Discoverable.** `--help` everywhere, examples in help, `did you mean` suggestions, `doctor` to
   diagnose, completions for bash/zsh/fish. The next step is always one command away.
6. **Respect the environment.** Detect TTY vs pipe; honor `NO_COLOR`, `TERM`, `$EDITOR`, `$PAGER`,
   reduced-motion, `CI`. Never emit control codes into a pipe.
7. **Composable.** stdout is the result and pipe-clean; `--json` is a stable contract; exit codes are
   the script API (Article 7). Chrome goes to stderr so `… --json | jq` just works (NFR-112).
8. **Minimal, then deep.** Terse by default; `-v`/`-vv` and drilling reveal more. Never dump L3 detail
   a user didn't ask for (spec 09 §6).

---

## 2. Anatomy of a command & naming conventions

`cleaner <noun-or-verb> [subcommand] [args] [--flags]` (spec 08 §1). Conventions:

- **Verbs for actions, nouns for management.** Top-level verbs: `analyze`, `audit`, `clean`,
  `optimize`, `doctor`, `report`. Management nouns take subcommands: `plugins`, `config`, `staging`,
  `profile`. This mirrors `git`, `docker`, `gh`.
- **Flag names:** long `--kebab-case`; short single-letter only for the top ~8 (`-v -y -h`); a short
  flag's meaning is **stable forever** across commands. Booleans are positive (`--cache` /
  `--no-cache`), never double-negative. Pairs use the `--flag` / `--no-flag` idiom.
- **Consistent flag vocabulary** (same name = same meaning everywhere): `--dry-run`, `--yes/-y`,
  `--json`, `--ci`, `--no-tui`, `--no-color`, `--verbose/-v`, `--debug`, `--config`, `--profile`,
  `--include/--exclude`, `--plugins`, `--min-size`, `--older-than`, `--all-volumes`, `--output`,
  `--format`. A concept never gets two spellings.
- **Values:** sizes accept binary/decimal units (`500MB`, `2GiB`; spec 24 `ByteSize`); durations
  accept `30d/12h/90m` **or** bare `--older-than <days>` where spec 08 already fixed days; selectors
  use the spec-08 §2 grammar (`plugin:`, `category:`, `risk:`, `path:`).
- **No hidden aliases** that change behavior; documented aliases only (`--version` ≡ `version`).
- **Arguments vs flags:** paths are positional (`analyze ~/Developer`); everything else is a flag.
  Never make a required flag where a positional reads more naturally.

---

## 3. Defaults (sensible, safe, overridable)

| Concern | Default | Why |
|---|---|---|
| Subcommand + TTY | interactive TUI | human-first (FR-076) |
| Subcommand + no TTY | help, exit `2` | ambiguous non-interactively (spec 08) |
| Scope | `$HOME` | least surprise; `--all-volumes` widens |
| Disposition | `stage` (reversible) | reversibility (principle 2) |
| Risk selection | 🟢 pre-selected, 🟡 shown, 🔴 locked | Article 4.1 |
| Confirmation | required for destructive verbs | principle 1 |
| Color | `auto` (on iff TTY & !NO_COLOR) | respect env |
| Sort | descending Reclaim | biggest win first (IA-4) |
| Verbosity | L1/L2 summary | minimal-then-deep |
| Output | human on stdout, chrome on stderr | composable (§ 7) |

Every default is overridable by config (spec 24) then env then flag (spec 08 precedence). Defaults are
chosen so the **zero-flag** invocation is the safe, common intent.

---

## 4. Dangerous actions

- **Preview → confirm → execute** is mandatory for `clean`, `optimize`, `staging purge`, `staging
  restore --force`, and any `config set` of an unsafe key (spec 24 §7).
- **Graduated confirmation:** reversible staging = `[Y/n]` (safe default yes); permanent purge /
  `--no-stage` = `[y/N]` (safe default no); 🔴 items = **typed-confirm** (type the phrase, Article
  4.1, spec 25 §4.6). A single keypress never destroys 🔴 data.
- **`--yes` is bounded:** auto-confirms 🟢 (and 🟡 only with `--include medium`); **never** 🔴; never
  implies `--no-stage`. `--dry-run --yes` is legal (yes is a no-op).
- **`--no-stage` (permanent)** requires explicit confirmation interactively, and in `--ci`/`--json`
  requires `--yes` **and** a signed policy (Article 4.4, spec 08 §4.3, spec 23) — otherwise exit `2`.
- **Show the blast radius before asking.** The confirm prompt always states item count, total bytes,
  disposition, recoverability, and (for 🔴) exact paths (spec 09 §6, principle 1).

---

## 5. `--dry-run` everywhere

Every mutating command accepts `--dry-run` and produces the **exact** plan it would execute — same
findings, same totals (measured by the same code, principle 3), same JSON shape (spec 08 §9.3) —
disposing of nothing, exit `0`.

```
$ cleaner clean --profile developer-daily --dry-run
DRY RUN — nothing will be changed.
Would stage 42 items · reclaim 24.8 GiB · disposition stage
  🟢 Safe 38   🟡 Medium 4   🔴 Dangerous 0
  Largest: DerivedData 21.4 GiB, Docker build cache 4.1 GiB, npm 3.4 GiB
Re-run without --dry-run to apply, or add --yes to skip the prompt.
exit: 0
```

Dry-run output is clearly banner-marked (`DRY RUN`) on both human and TUI paths; `--json` sets
`"dryRun": true`. `--dry-run` is the recommended first step in every destructive example in help.

---

## 6. Errors: helpful, located, with a next step

Full taxonomy and envelope live in spec 27; the **UX contract** here:

- Every error states **what went wrong · why · what to do next** (spec 27), on **stderr**, with the
  correct exit code (Article 7).
- **Suggest the fix, not just the failure.** Permission → the exact System Settings path; bad flag →
  `did you mean`; unknown plugin → nearest ids; invalid config → file:line + `config validate`.
- **Never a stack trace** to a user by default (only under `--debug`). Never a bare error code.

```
$ cleaner clean --plugins derved-data
error: unknown plugin "derved-data"                                       [stderr]
  did you mean:  derived-data ?
  list plugins:  cleaner plugins list
exit: 2 (usage)
```

```
$ cleaner analyze ~/Library/Mail
error: can't read ~/Library/Mail — Full Disk Access is required          [stderr]
  why:  macOS restricts this folder to apps with Full Disk Access
  fix:  System Settings › Privacy & Security › Full Disk Access → enable "cleaner"
        then re-run.  Skipping this folder for now.
partial results follow.
exit: 3 (partial)                     # or 4 if nothing could be read
```

---

## 7. Output style guide (stdout vs stderr, color, tables)

Normative extension of spec 08 §3:

- **stdout = the result.** Human report or, with `--json`, exactly one JSON document and nothing else
  (no logs, no color, no progress). Piping stdout must always yield clean data.
- **stderr = chrome.** Progress bars, spinners, TUI frames, prompts, `-v`/`--debug` diagnostics,
  warnings, and errors. `cleaner … --json | jq` stays clean because chrome never touches stdout
  (NFR-112).
- **Color** only when stdout/stderr respectively is a TTY and neither `NO_COLOR`/`--no-color`/`--ci`
  is set (spec 25 §6.3). Color is **decoration**; meaning is always in text+icon too (IA-3).
- **Tables** (spec 25 §4.4) for human TTY output; **plain aligned columns** when piped; **JSON** for
  machines. Never emit box-drawing into a pipe.
- **Byte sizes** always labeled binary vs decimal (GiB vs GB), locale-formatted (NFR-081), integers in
  JSON with a `humanSize` companion (spec 08 §9).
- **One blank line** between logical sections; no trailing chrome after the last result line so tools
  like `tail`/`grep` behave.
- **Quiet completions:** management commands that "did the thing" print a single confirming line
  (`✔ set staging.retentionDays = 30d`) — not a paragraph.

### 7.1 Verbosity & quiet levels

| Level | Flag | Human output |
|---|---|---|
| quiet | `-q/--quiet` | only errors + the final result line; no progress |
| normal | (default) | L1/L2 summary + progress on stderr |
| verbose | `-v` | + per-plugin L2 detail, per-item where small-N (spec 09 §6) |
| very verbose | `-vv` | + L3 per-item paths, evidence, dispositions |
| debug | `--debug` | + timings, decisions, adapter calls → **stderr only** (never stdout, NFR-112) |

`--quiet` and `--json` both suppress progress; `--json` ignores `-v` (machines get full L1+L2+L3
always, spec 09 §6). `--debug` is orthogonal to `-v` and additive.

---

## 8. Machines: `--json`, `--ci`, exit codes, `--no-input`

- **`--json`** — the machine contract (spec 08 §9): single versioned document on stdout, `exitCode`/
  `exitReason` echoed, unknown-field-forward-compatible. Implies non-interactive; a required prompt
  without `--yes`/policy is an error (exit `2`), never a hang.
- **`--ci`** — implies `--no-tui --no-color --no-input`; stable exit codes; never prompts; maps
  `doctor`/`audit` health to `0/3/1` (Article 7). Also auto-enabled when `$CI` is truthy (a convenience,
  overridable by `--no-ci`? — see OQ-26.1).
- **`--no-input`** — the automation switch: the tool MUST NOT read stdin or prompt; any point that
  would prompt instead errors with a message naming the flag/policy that would satisfy it (exit `2`).
  Distinct from `--yes` (which *answers* prompts): `--no-input` *forbids* them.
- **Exit codes are the API** (Article 7, spec 08 §10). Scripts branch on the code; humans read the
  message. `0` ok · `2` usage · `3` partial · `4` permission · `5` cancelled · `6` config · `7`
  plugin · `8` safety · `10` precondition. Every command documents which it can return.

```
# idiomatic script usage
if cleaner clean --profile conservative --yes --json > result.json; then
  reclaimed=$(jq -r '.result.humanSize' result.json)
  echo "freed $reclaimed"
else
  case $? in
    3) echo "some items skipped — see result.json .result.skipped" ;;
    4) echo "grant Full Disk Access and retry" ;;
    *) echo "clean failed ($?)" ;;
  esac
fi
```

---

## 9. TTY, pipes, and progress in non-TTY

- **Detect, don't assume.** Interactive TUI renders only when stderr is a TTY and none of
  `--no-tui/--ci/--json` is set (spec 08 §3.4). Otherwise: linear plain output.
- **Piped stdout** ⇒ no color, no cursor codes, no TUI; result is plain/JSON. Piped **stderr** ⇒
  progress degrades to periodic plain lines (spec 25 §4.1), rate-limited, or silent under
  `--quiet`/`--ci`.
- **Non-TTY progress:** in a CI log, emit a plain progress line at ≥ 500 ms intervals and on phase
  boundaries (NFR-022) — enough to prove liveness, not a spinner spam. `--ci` prefers milestone lines
  (`scan: done 4.6M files 68s`) over percentages.
- **Pager:** long human output on a TTY may page via `$PAGER` (default `less -R`) when
  `ui.pager: auto` (spec 24); never page when piped or `--no-input`.

---

## 10. Help text style & discoverability

- **Every node has `--help`** (swift-argument-parser, CC-2). Structure: one-line abstract → usage →
  arguments → options (grouped) → **Examples** → See also. Abstracts are a single imperative sentence.
- **Examples are mandatory** on every action command and show the safe path first (`--dry-run` before
  the real run). Copy-pasteable, real flags, realistic paths.
- **Discoverability:** `cleaner` with no args + TTY opens the TUI (the friendliest front door);
  `cleaner help <topic>` and `cleaner <cmd> -h`; `did you mean` on typos (Levenshtein over the command
  + plugin id sets); `doctor` diagnoses environment; `completion` for shells.
- **Progressive help:** `-h` is terse (abstract + common flags + 2 examples); `--help` is full.
- **`See also`** cross-links related commands (e.g. `clean` → "preview with --dry-run; undo with
  staging restore").

```
$ cleaner clean --help
OVERVIEW: Preview, confirm, and reclaim disk space (the primary cleanup verb).

USAGE: cleaner clean [selectors] [--stage|--trash|--no-stage] [options]

SELECTORS:
  --plugins <ids>          Restrict to these plugin ids (default: all enabled)
  --include <sel>          plugin:<id>|category:<name>|risk:<safe|medium|dangerous>|path:<glob>
  --exclude <sel>          Same grammar; --exclude wins over --include
  --profile <name>         Apply a saved profile's selection + options

DISPOSITION (mutually exclusive):
  --stage                  Move to recoverable staging (default; undo anytime)
  --trash                  Route to macOS Trash
  --no-stage               Permanent delete — requires confirmation (+ policy in CI)

SAFETY & AUTOMATION:
  --dry-run                Show the full plan; change nothing (exit 0)
  -y, --yes                Auto-confirm 🟢 (and 🟡 with --include medium); NEVER 🔴
      --no-input           Never prompt or read stdin (automation)

EXAMPLES:
  # See what would happen — always safe to run:
  cleaner clean --profile developer-daily --dry-run

  # Auto-clean only the safe items, no prompt:
  cleaner clean --include risk:safe --yes

  # Interactive review of Docker + DerivedData:
  cleaner clean --plugins docker,derived-data

SEE ALSO:  analyze (what's using space) · staging restore (undo) · optimize (curated safe)
EXIT CODES: 0 ok · 3 partial · 4 permission · 5 cancelled · 6 config · 7 plugin · 8 safety
```

---

## 11. Copywriting & voice

The voice matches truth-in-reporting (principle 3): **concise, honest, plain, no hype**.

- **Do:** short declaratives; active voice; name the exact number/path; say "staged" when staging,
  "purged" when purging (spec 09 §5 terminology); use the glossary words verbatim (Reclaimable,
  Reclaimed, Finding, Item, Stage, Purge, Restore, Safe/Medium/Dangerous).
- **Don't:** "Blazing-fast!", "Supercharge!", "Free up GBs instantly!"; exclamation marks; scare
  copy; "deleted" when it's recoverable staging; vague "cleaned up some junk" without numbers;
  anthropomorphizing ("I found…"). The tool reports, it doesn't sell.
- **Numbers are honest.** Never round up savings; show `12.0 GiB` not "~13 GB". If a step is skipped,
  say so with the reason. Estimates are labeled "estimated".
- **Warnings are calm and specific.** "2 items are locked and were skipped" — not "⚠️ WARNING!!!".
- **Success is understated.** "Reclaimed 12.0 GiB (staged — recoverable 30 days)." — one line, true.
- **Sentence case** for messages and headings; Title Case only for proper nouns and screen titles.

| Instead of | Write |
|---|---|
| "🚀 Cleaned up your Mac!" | "Reclaimed 12.0 GiB (staged — recoverable 30 days)." |
| "Deleting files…" (when staging) | "Staging 40 items…" |
| "Oops! Something went wrong." | "Couldn't read ~/Library/Mail — Full Disk Access required." |
| "Are you sure???" | "Type `delete` to confirm 2 Dangerous items, or Esc to cancel." |
| "Freed up tons of space!" | "Freed 12.0 GiB." |

---

## 12. Localization hooks

- **Externalize everything.** No user-facing literal in view/CLI code; all strings route through the
  localization layer (`String(localized:)` / a string catalog), keyed and commented (NFR-080). v1
  ships `en` only but is fully externalized; adding a locale requires no code change.
- **Format locale-aware.** Byte sizes via `ByteCountFormatter` (binary/decimal per config), dates via
  `Date.FormatStyle`, numbers via locale grouping (NFR-081). Never hand-format `1,234.5 GB`.
- **Layout tolerates expansion.** UI budgets ≥ +40 % string growth and double-width scripts without
  misalignment (NFR-082, spec 25 §10). Truncation is grapheme-correct.
- **The confirm phrase is localization-safe.** `default.confirmPhrase` (spec 24) is user-set and
  compared after locale-aware case-folding; help shows the active phrase.
- **`--json` and exit codes are locale-invariant.** Machine surfaces (field names, `exitReason`
  tokens, schema) are ASCII and never localized; only `message`/`humanSize` display strings localize.
- **Selector keywords, flags, and plugin ids are locale-invariant** (stable API surface); only their
  help text localizes.

---

## Open Questions

- **OQ-26.1** Auto-enable `--ci` when `$CI` is set — helpful default, or too magic? Provide
  `--no-ci`? *Leaning: auto-enable with a one-line stderr note + `--no-ci` escape.*
- **OQ-26.2** `-q/--quiet` vs `--json` overlap — should `--quiet` also apply to `--json` runs (it
  already suppresses progress), or is `--json` implicitly quiet? *Leaning: `--json` is implicitly
  quiet; `--quiet` is a human-mode modifier.*
- **OQ-26.3** Do we ship `did you mean` for flag typos too (not just commands/plugins)? swift-argument-
  parser gives some; do we augment? *Leaning: augment for plugin ids and subcommands, rely on SAP for
  flags.*
- **OQ-26.4** Pager default — `less -R` vs never-page-by-default? Some users dislike auto-paging.
  *Leaning: `auto` = page only when output exceeds one screen on a TTY; documented + `ui.pager`.*
- **OQ-26.5** Should `--verbose` counting cap at `-vv`, or allow `-vvv` for trace-to-stdout? *Leaning:
  cap at `-vv`; trace is `--debug` (stderr) to protect the stdout contract.*

## Dependencies

- **Consumes:** 00 (Art. 1 principles, Art. 7 exit codes, glossary), 07 (NFR-070…082, NFR-112), 08
  (command surface, flags, stdout/stderr contract, JSON schemas — surface of record), 09 (taxonomy,
  disclosure levels, terminology), 24 (defaults/config/env precedence, confirm phrase, pager/color),
  25 (components, themes, degradation the CLI text reuses).
- **Feeds:** 27 (error message style & next-step contract), 28 (what goes to stderr vs files, quiet/CI
  behavior), 29 (consent copy voice), 31 (CLI golden-output + help-text + exit-code snapshot tests).
