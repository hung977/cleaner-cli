# 26 — CLI UX Guideline

> **Phase F · Depends on:** 00-constitution (Art. 1 principles, Art. 7 exit codes), 07 (NFR-070…082
> a11y/i18n, NFR-112 stream separation), 08-command-reference (surface, flags, stdout/stderr
> contract, JSON), 09-information-architecture (taxonomy, disclosure, terminology), 24 (config/env),
> 25 (TUI components/themes) · **Depended on by:** 27 (error message style), 28 (log routing), 29
> (consent copy), 31 (CLI snapshot + golden-output tests).
>
> The house style for the command-line surface as shipped in **v0.6**: principles (a CLIG.dev-adapted
> charter), flag and naming conventions, defaults, the **clean-all / select-each / cancel** flow,
> confirm-before-destructive policy, `--dry-run`, error/next-step style, machine output, verbosity,
> TTY/pipe behavior, help-text style, discoverability, the stdout/stderr/color output guide, the
> copywriting voice, and localization hooks. RFC-2119 keywords are normative. Where this spec and spec
> 08 overlap, **spec 08 is the surface of record**; this spec is the *how it should feel*.

---

## 1. The charter (adapted from CLIG.dev, ranked)

These are ranked; when two conflict, the lower number wins. They are the CLI-surface reading of
Constitution Article 1.

1. **Human-first, scriptable-always.** The default experience is designed for a person at a TTY; but
   **every** action is fully reachable non-interactively (`--yes`, `--json`, `--md`, env) with stable
   exit codes. No capability is prompt-only (IA-1, NFR-070).
2. **Safe by default** (principle 1). The default `cleaner` run **previews first** (a grouped summary)
   and **confirms second** before touching anything. Cleaned items are **moved to staging** — never
   permanently deleted in the same step — so any clean is reversible via `cleaner undo`.
3. **Honest output** (principle 3). Never overstate savings, never claim success not achieved, always
   report what was skipped and why. Same measurement code for `--dry-run` and the real run.
4. **Consistency.** One grammar for flags, plugin-id selectors, sizes, and output across every command
   (spec 08). A user who learns the default run can predict `find` and the advanced commands.
5. **Discoverable.** `--help` everywhere, examples in help, `did you mean` suggestions, `doctor` to
   diagnose, completions for bash/zsh/fish. The next step is always one command away — and `--dry-run`
   spells it out in a **NEXT STEPS** block.
6. **Respect the environment.** Detect TTY vs pipe; honor `NO_COLOR`, `TERM`, `$PAGER`, `CI`. Never
   emit control codes into a pipe.
7. **Composable.** stdout is the result and pipe-clean; `--json` and `--md` are stable contracts; exit
   codes are the script API (Article 7). Chrome goes to stderr so `cleaner --json | jq` just works
   (NFR-112).
8. **Minimal, then deep.** Terse by default — a grouped summary, name left and size right; `-v`
   expands each source to its items. Never dump per-item detail a user didn't ask for (spec 09 §6).

---

## 2. Anatomy of a command & naming conventions

`cleaner [subcommand] [args] [--flags]` (spec 08 §1) — the **primary invocation has no subcommand**.
Conventions:

- **Default verb is the bare command.** `cleaner` scans and offers to clean. Subcommands are `undo`,
  `find large`, `find dupes`, and the hidden advanced set (`docker`, `brew`, `doctor`, `profile
  list`). This mirrors tools whose common path is zero-argument.
- **Flag names:** long `--kebab-case`; short single-letter only for the very common (`-v`, `-h`); a
  short flag's meaning is **stable forever**. Booleans are positive; no double-negatives.
- **Consistent flag vocabulary** (same name = same meaning everywhere): `--dry-run`, `--yes`,
  `--json`, `--md`, `--verbose/-v`, `--no-color`, `--include`, `--exclude`, `--profile`. A concept
  never gets two spellings.
- **Values:** sizes accept binary/decimal units (`100MB`, `2GiB`; spec 24 `ByteSize`); `--include` /
  `--exclude` take **comma-separated plugin ids** (spec 08 §2) — there is no category/risk/path
  grammar.
- **No hidden aliases** that change behavior; documented aliases only.
- **Arguments vs flags:** paths are positional (`cleaner find large ~/Developer`); everything else is
  a flag. Never make a required flag where a positional reads more naturally.

---

## 3. Defaults (sensible, safe, overridable)

| Concern | Default | Why |
|---|---|---|
| No subcommand | scan all enabled plugins → grouped summary → prompt | human-first (FR-076) |
| Scope | all enabled plugins | one-command "clean my Mac" intent |
| Disposition | move to **staging** (reversible via `undo`) | reversibility (principle 2) |
| Selection at prompt | `Y` = all · `s` = select each · `n` = cancel | explicit choice, no surprise |
| Confirmation | required before any clean | principle 1 |
| Color | `auto` (on iff TTY & !NO_COLOR) | respect env |
| Sort | descending Reclaimable | biggest win first (IA-4) |
| Verbosity | grouped summary (source name + size) | minimal-then-deep |
| Output | human on stdout, prompt/chrome on stderr | composable (§ 7) |

Every default is overridable by config (spec 24) then env then flag (spec 08 precedence). The
**zero-flag** invocation is the safe, common intent: preview, then confirm.

---

## 4. The clean flow & dangerous actions

The default `cleaner` run is: **scan → grouped summary → confirm → move to staging.** The summary
lists one line per source (name left, size right; no risk colours, no levels, no emoji; largest
first), then prompts:

```
Clean all 24.8 GiB? [Y = all · s = select each · n = cancel]
```

- **`Y` / Enter** → clean everything found.
- **`s`** → walk each source in turn, asking `clean? [y/N]` (safe default **no** per source).
- **`n`** → cancel, exit `5`.

Rules:

- **Confirm before anything is moved.** A clean never runs without either an interactive answer or an
  explicit `--yes`. Under a non-TTY with neither `--yes` nor `--json`/`--md`, the run previews only
  (behaves as `--dry-run`) rather than hanging or guessing.
- **`--yes` cleans everything found, no prompt** — the automation/CI switch. It still moves items to
  staging (reversible); it never permanently deletes.
- **Recoverable by design.** Because every clean moves items to staging, there is no separate
  permanent-delete verb in the primary flow and no typed-confirmation tier — `cleaner undo` is always
  the escape hatch. Advanced adapter commands (`docker --prune`, `brew --run`) confirm before running
  and accept `--yes`.
- **Show the blast radius before asking.** The summary always states the per-source sizes and the
  total before the prompt (principle 1); `-v` expands each source to its items.

---

## 5. `--dry-run` and NEXT STEPS

`cleaner --dry-run` produces the **exact** grouped summary the real run would act on — same sources,
same totals (measured by the same code, principle 3), same JSON shape (spec 08 §9.2) — moving
nothing, exit `0`. It then prints a **NEXT STEPS** block telling the user precisely what to run to
reclaim and how to undo.

```
$ cleaner --dry-run
DRY RUN — nothing will be changed.
Reclaimable: 24.8 GiB across 6 sources
  Xcode DerivedData      21.4 GiB
  Docker build cache      4.1 GiB
  npm cache               3.4 GiB
  …

NEXT STEPS
  Reclaim now:   cleaner            (review the summary, then confirm)
  No prompt:     cleaner --yes      (clean everything found)
  Undo later:    cleaner undo       (restore the last clean from staging)
exit: 0
```

Dry-run output is clearly banner-marked (`DRY RUN`) on the human path; `--json` sets `"dryRun":
true`. `--dry-run` is the recommended first step in every destructive example in help.

---

## 6. Errors: helpful, located, with a next step

Full taxonomy and envelope live in spec 27; the **UX contract** here:

- Every error states **what went wrong · why · what to do next** (spec 27), on **stderr**, with the
  correct exit code (Article 7).
- **Suggest the fix, not just the failure.** Permission → the exact System Settings path; bad flag →
  `did you mean`; unknown plugin id → nearest ids; invalid config → file:line.
- **Never a stack trace** to a user by default. Never a bare error code.

```
$ cleaner --include derved-data
error: unknown plugin "derved-data"                                       [stderr]
  did you mean:  derived-data ?
exit: 2 (usage)
```

```
$ cleaner find large ~/Library/Mail
error: can't read ~/Library/Mail — additional disk access is required     [stderr]
  why:  macOS restricts this folder to apps with Full Disk Access
  fix:  System Settings › Privacy & Security › Full Disk Access → enable "cleaner"
        then re-run.  Skipping this folder for now.
partial results follow.
exit: 3 (partial)                     # or 4 if nothing could be read
```

---

## 7. Output style guide (stdout vs stderr, color, tables)

Normative extension of spec 08 §3:

- **stdout = the result.** Human summary; with `--json`, exactly one JSON document; with `--md`,
  exactly the Markdown report (`| Source | Reclaimable |`, no Risk column) and nothing else. Piping
  stdout must always yield clean data.
- **stderr = chrome.** Progress lines, the confirm prompt, warnings, and errors. `cleaner --json |
  jq` stays clean because chrome never touches stdout (NFR-112).
- **Color** only when the stream is a TTY and neither `NO_COLOR` / `--no-color` is set (spec 25
  §6.3). Color is **decoration**; meaning is always in text too (IA-3). There are **no risk colours**
  — sources are neutral; only the size is emphasized.
- **Tables/aligned columns** for human output (source name left, size right); **plain aligned
  columns** when piped; **JSON** or **Markdown** for machines/reports. Never emit box-drawing into a
  pipe.
- **Byte sizes** always labeled binary vs decimal (GiB vs GB), locale-formatted (NFR-081), integers
  in JSON with a `humanSize` companion (spec 08 §9).
- **One blank line** between logical sections; no trailing chrome after the last result line.
- **Quiet completions:** `undo` and the advanced commands that "did the thing" print a single
  confirming line — not a paragraph.

### 7.1 Verbosity

| Level | Flag | Human output |
|---|---|---|
| normal | (default) | grouped summary (source name + size) + progress on stderr |
| verbose | `-v` | + each source expanded to its underlying items and paths (spec 09 §6) |

`--json` and `--md` ignore `-v` (machines/reports get full detail always, spec 09 §6). Debug/trace
diagnostics route to **stderr only** (never stdout, NFR-112) and are gated by `CLEANER_LOG_LEVEL`.

---

## 8. Machines: `--json`, `--md`, `--yes`, exit codes

- **`--json`** — the machine contract (spec 08 §9): single versioned document on stdout, `exitCode` /
  `exitReason` echoed, unknown-field-forward-compatible. Implies non-interactive; never prompts,
  never hangs.
- **`--md`** — a Markdown report on stdout (`| Source | Reclaimable |`, no Risk column) for pasting
  into issues/PRs. Also non-interactive.
- **`--yes`** — clean everything found without prompting. Still moves to staging (reversible via
  `undo`); the automation switch for CI.
- **Exit codes are the API** (Article 7, spec 08 §10). Scripts branch on the code; humans read the
  message. `0` ok · `2` usage · `3` partial · `4` permission · `5` cancelled · `6` config · `7`
  plugin · `8` safety · `10` precondition · `11` entitlement. Every command documents which it can
  return.

```
# idiomatic script usage
if cleaner --yes --json > result.json; then
  reclaimed=$(jq -r '.result.humanSize' result.json)
  echo "freed $reclaimed (staged — undo with: cleaner undo)"
else
  case $? in
    3) echo "some items skipped — see result.json .result.skipped" ;;
    4) echo "grant Full Disk Access and retry" ;;
    5) echo "cancelled" ;;
    *) echo "clean failed ($?)" ;;
  esac
fi
```

---

## 9. TTY, pipes, and progress in non-TTY

- **Detect, don't assume.** The confirm prompt renders only when stdin is a TTY and none of `--yes` /
  `--json` / `--md` is set (spec 08 §3.4). Otherwise: linear plain output; a non-TTY run without
  `--yes` previews only (as `--dry-run`) rather than blocking.
- **Piped stdout** ⇒ no color, no cursor codes; result is plain / JSON / Markdown. Piped **stderr** ⇒
  progress degrades to periodic plain lines (spec 25 §4.1), rate-limited.
- **Non-TTY progress:** in a CI log, emit a plain progress line at ≥ 500 ms intervals and on phase
  boundaries (NFR-022) — enough to prove liveness, not a spinner spam.
- **Pager:** long human output on a TTY may page via `$PAGER` (default `less -R`) when `ui.pager:
  auto` (spec 24); never page when piped.

---

## 10. Help text style & discoverability

- **Every node has `--help`** (swift-argument-parser, CC-2). Structure: one-line abstract → usage →
  arguments → options (grouped) → **Examples** → See also. Abstracts are a single imperative sentence.
- **Examples are mandatory** and show the safe path first (`--dry-run` before the real run).
  Copy-pasteable, real flags, realistic paths.
- **Discoverability:** `cleaner` with no args scans and previews (the friendliest front door);
  `cleaner <cmd> -h`; `did you mean` on typos (Levenshtein over the command + plugin-id sets);
  `doctor` diagnoses the environment; `completion` for shells. The four advanced commands are hidden
  from the top-level listing (`shouldDisplay:false`) but respond to `--help` when named.
- **`See also`** cross-links related commands (e.g. the default run → "preview with --dry-run; undo
  with cleaner undo").

```
$ cleaner --help
OVERVIEW: Scan for reclaimable disk space, then confirm and clean (moving to recoverable staging).

USAGE: cleaner [options]

SELECTION:
  --include <ids>          Restrict to these plugin ids (comma-separated)
  --exclude <ids>          Drop these plugin ids (comma-separated; wins over --include)
  --profile <name>         Apply a saved profile's selection

OUTPUT & AUTOMATION:
  --dry-run                Show the plan + NEXT STEPS; change nothing (exit 0)
  --yes                    Clean everything found, no prompt (automation/CI)
  --json                   Emit one machine document on stdout
  --md                     Emit a Markdown report on stdout
  -v, --verbose            Expand each source to its underlying items
      --no-color           Disable color

EXAMPLES:
  # See what would happen — always safe to run:
  cleaner --dry-run

  # Scan and choose at the prompt (all / select each / cancel):
  cleaner

  # Clean everything, no prompt:
  cleaner --yes

SEE ALSO:  find large / find dupes (read-only) · undo (restore the last clean)
EXIT CODES: 0 ok · 3 partial · 4 permission · 5 cancelled · 6 config · 7 plugin · 8 safety · 11 entitlement
```

---

## 11. Copywriting & voice

The voice matches truth-in-reporting (principle 3): **concise, honest, plain, no hype**.

- **Do:** short declaratives; active voice; name the exact number/path; say "staged" when moving to
  staging, "restored" when undoing (spec 09 §5 terminology); use the glossary words verbatim
  (Reclaimable, Reclaimed, Source, Item, Stage, Restore, Undo).
- **Don't:** "Blazing-fast!", "Supercharge!", "Free up GBs instantly!"; exclamation marks; scare
  copy; "deleted" when it's recoverable staging; vague "cleaned up some junk" without numbers;
  anthropomorphizing ("I found…"). The tool reports, it doesn't sell. Never name or compare against
  third-party products.
- **Numbers are honest.** Never round up savings; show `12.0 GiB` not "~13 GB". If a source is
  skipped, say so with the reason. Estimates are labeled "estimated".
- **Warnings are calm and specific.** "2 items are locked and were skipped" — not "⚠️ WARNING!!!".
- **Success is understated.** "Reclaimed 12.0 GiB (staged — undo with: cleaner undo)." — one line,
  true.
- **Sentence case** for messages and headings; Title Case only for proper nouns and screen titles.

| Instead of | Write |
|---|---|
| "🚀 Cleaned up your Mac!" | "Reclaimed 12.0 GiB (staged — undo with: cleaner undo)." |
| "Deleting files…" (when staging) | "Staging 40 items…" |
| "Oops! Something went wrong." | "Couldn't read ~/Library/Mail — Full Disk Access required." |
| "Are you sure???" | "Clean all 24.8 GiB? [Y = all · s = select each · n = cancel]" |
| "Freed up tons of space!" | "Freed 12.0 GiB." |

---

## 12. Localization hooks

- **Externalize everything.** No user-facing literal in view/CLI code; all strings route through the
  localization layer (`String(localized:)` / a string catalog), keyed and commented (NFR-080). v0.6
  ships `en` only but is fully externalized; adding a locale requires no code change.
- **Format locale-aware.** Byte sizes via `ByteCountFormatter` (binary/decimal per config), dates via
  `Date.FormatStyle`, numbers via locale grouping (NFR-081). Never hand-format `1,234.5 GB`.
- **Layout tolerates expansion.** UI budgets ≥ +40 % string growth and double-width scripts without
  misalignment (NFR-082, spec 25 §10). Truncation is grapheme-correct.
- **The prompt keys are localization-safe.** The prompt answers (`Y`/`s`/`n`) are compared after
  locale-aware case-folding; help shows the active keys.
- **`--json`, `--md` field names, and exit codes are locale-invariant.** Machine surfaces (field
  names, `exitReason` tokens, schema, Markdown column headers) are ASCII and never localized; only
  `message` / `humanSize` display strings localize.
- **Selector keywords, flags, and plugin ids are locale-invariant** (stable API surface); only their
  help text localizes.

---

## Open Questions

- **OQ-26.1** Auto-detect `$CI` to suppress the prompt (force preview-only unless `--yes`) — helpful
  default, or too magic? *Leaning: preview-only under `$CI` without `--yes`, with a one-line stderr
  note.*
- **OQ-26.2** Should `s` (select each) support a "back"/"all remaining" shortcut mid-walk, or stay a
  strict per-source `[y/N]`? *Leaning: strict per-source in v0.6; revisit.*
- **OQ-26.3** Do we ship `did you mean` for flag typos too (not just plugin ids)? swift-argument-
  parser gives some; do we augment? *Leaning: augment for plugin ids, rely on SAP for flags.*
- **OQ-26.4** Pager default — `less -R` vs never-page-by-default? *Leaning: `auto` = page only when
  output exceeds one screen on a TTY; documented + `ui.pager`.*

## Dependencies

- **Consumes:** 00 (Art. 1 principles, Art. 7 exit codes, glossary), 07 (NFR-070…082, NFR-112), 08
  (command surface, flags, stdout/stderr contract, JSON/Markdown — surface of record), 09 (taxonomy,
  disclosure levels, terminology), 24 (defaults/config/env precedence, pager/color), 25 (components,
  themes, degradation the CLI text reuses).
- **Feeds:** 27 (error message style & next-step contract), 28 (what goes to stderr vs files, CI
  behavior), 29 (consent copy voice), 31 (CLI golden-output + help-text + exit-code snapshot tests).
