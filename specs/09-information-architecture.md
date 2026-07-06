# 09 — Information Architecture

> **Phase B · Depends on:** 00-constitution, 06-functional-requirements, 08-command-reference ·
> **Depended on by:** 25 (TUI design system), 26 (CLI UX), 27 (errors), 31 (tests).
>
> The **mental model** the user navigates, the object hierarchy, the single scan → summary →
> prompt flow, the command-surface taxonomy, and the grouping/sorting rules + progressive
> disclosure. Terminology here is the Constitution glossary (Article 3) surfaced to users
> verbatim — the tool MUST use these exact words. RFC-2119 keywords are normative.
>
> **v0.6 note.** `cleaner` is a **line-based CLI**, not a full-screen interactive TUI. An earlier
> alternate-screen, keyboard-navigated picker was built and then **removed** (it mis-rendered on
> Apple Terminal — see spec 25 § 8). There are no risk tiers (no 🟢🟡🔴 / Safe·Medium·Dangerous)
> in v0.6; the IA below describes what actually ships.

## 1. Object hierarchy (the mental model)

The user reasons about disk cleanup as a four-level containment hierarchy. Every screen line and
JSON document is a projection of some slice of this tree.

```
Volume            the disk being reclaimed (the boot/APFS volume containing $HOME)
  └─ Category     a human bucket: Developer Cache · Build Artifacts · Browser Cache · Trash · Logs …
       └─ Source  one plugin's contribution, collapsed to a single row — e.g. "Xcode DerivedData (12)"
            └─ Finding   an Item plus its reclaimable size and proposed disposition (stage)
                 └─ Item      the atomic actionable unit: a file, directory, or logical group
```

- **Volume** (FR-001/002): the top scope. v0.6 scans the boot volume containing `$HOME` (the
  plugins' configured roots). System/mount roots are navigable for *reporting* but deny-listed
  for *action* (Article 5, `ProtectedPathGuard`).
- **Category** (`FindingCategory`): a stable, user-facing grouping of Findings, presentation only —
  plugins own behavior. Shipped set: **Trash**, **Developer Cache**, **Build Artifacts**,
  **Application Cache**, **Logs & Crash Reports**, **Browser Cache**, plus the detector-only
  **Large Files** and **Duplicate Files** (surfaced by `cleaner find`, not the main scan).
- **Source** = a plugin's Findings collapsed into one row. Because a plugin often produces many
  Findings (e.g. one per DerivedData folder), the summary shows a single **`Name (count)`** line
  with the roll-up size; `-v`/`--verbose` expands the Source into its individual Items.
- **Finding** (Article 3): what the user reviews and decides on — an Item plus its **Reclaimable**
  size and its proposed disposition (stage → recoverable). v0.6 attaches **no risk icon or safety
  score** to a Finding at the surface.
- **Item** (Article 3): what the engine *acts on*. One Finding may wrap a group Item (e.g.
  "DerivedData for project X" = a directory Item). Reclaim is measured on the Item (allocated
  bytes, CC-10).

**Selection semantics.** There is no tri-state cascade and no risk-gated pre-selection. The user
makes one top-level choice, then (optionally) one choice per **Source**:

- **Clean all** selects every Finding.
- **Select each** walks the Sources largest-first, asking `clean? [y/N]` per Source; a `y` adds
  that Source's Findings, anything else skips it.
- **Cancel** changes nothing.

The engine acts only on selected Findings' Items, always via staging (recoverable with
`cleaner undo`).

---

## 2. Flow (scan → summary → prompt)

`cleaner` (the default command, FR-076) is a **single linear flow**, not a screen stack. There is
no header/footer chrome, no navigation, no drilling — the whole interaction is three phases on one
scrollback.

```
   ┌──────────────┐        ┌──────────────────┐        ┌───────────────────────┐
   │  1. SCAN     │  ───▶  │  2. SUMMARY       │  ───▶  │  3. PROMPT            │
   │  spinner on  │        │  aligned list to  │        │  Clean all X?         │
   │  stderr;     │        │  stdout, grouped  │        │  [Y = all · s = select│
   │  clears when │        │  Category→Source; │        │   each · n = cancel]  │
   │  done        │        │  Total line       │        │                       │
   └──────────────┘        └──────────────────┘        └───────────┬───────────┘
                                                            all │  select │  n
                                          ┌─────────────────────┘         │        └─▶ cancel: nothing changed
                                          ▼                               ▼
                                 ┌──────────────────┐        ┌──────────────────────────┐
                                 │  clean all       │        │  per-Source y/N walk      │
                                 │  Findings        │        │  "Xcode DerivedData (12)  │
                                 └────────┬─────────┘        │   12.1 GB  clean? [y/N]"  │
                                          │                  └────────────┬─────────────┘
                                          └──────────────┬────────────────┘
                                                         ▼
                                              ┌────────────────────────┐
                                              │  4. CLEAN REPORT        │
                                              │  Reclaimed X · N items  │
                                              │  Undo with cleaner undo │
                                              └────────────────────────┘
```

**Phase inventory:**

| # | Phase | Channel | Content |
|---|---|---|---|
| 1 | Scan | stderr (TTY only) | one-line braille spinner: `⠹ scanning 6/8 · 18.4 GB · 4.1s`; cleared on completion; silent under non-TTY / `--json` |
| 2 | Summary | stdout | `DISK RECLAIMABLE` header + total; per-Category blocks; each Category lists its Sources (`Name (count)  size`, right-aligned); a `Total` footer. Under `--dry-run`, a **NEXT STEPS** block replaces the prompt |
| 3 | Prompt | stderr | three-way `[Y = all · s = select each · n = cancel]`; on `s`, a per-Source `clean? [y/N]` walk |
| 4 | Clean report | stdout | `Reclaimed <bytes>`, item counts, any failed/blocked, and the `Undo with cleaner undo` hint |

**Modes that skip the prompt.** `--dry-run` (preview only; prints NEXT STEPS, changes nothing),
`--json` (machine document to stdout, no prompt), `--md` (Markdown report, implies preview),
`--yes` (non-interactive: cleans **all** found Findings — the automation path). A non-TTY stdin
without `--yes` refuses to act and tells the user to pass `--yes`.

**Confirmation gate.** No deletion occurs without either an interactive confirmation (Phase 3) or
`--yes`. Everything acted on is **staged** (recoverable), so the confirmation guards a reversible
operation; `cleaner undo` restores the last session (FR-088/089). There is no typed-phrase gate in
v0.6 because there is no irreversible-purge path at the default surface.

---

## 3. Command-surface taxonomy

The command tree (spec 08) maps onto three intents. This taxonomy is the user's map from "what I
want" to "which verb".

| Intent | Question the user asks | Commands | Mutating? |
|---|---|---|---|
| **Understand** | "What's using my space? What could I reclaim?" | `cleaner --dry-run`, `cleaner --json`, `cleaner --md`, `cleaner find large`, `cleaner find dupes`, `cleaner undo --list`, `cleaner doctor` *(hidden)* | No (read-only) |
| **Act** | "Reclaim space now." (recoverable) | `cleaner` (default), `cleaner --yes`, `cleaner undo`, `cleaner docker` / `cleaner brew` *(hidden)* | Yes (guarded, staged) |
| **Configure** | "Tune how it behaves." | `--include` / `--exclude` / `--profile` flags, `cleaner profile` *(hidden)*, `config.yml` | State only |

- **Understand-before-Act** is enforced structurally: the default `cleaner` always runs a scan and
  prints the summary *before* offering the prompt (principle 1); `--dry-run` stops at the summary.
- **Primary surface is one command.** `cleaner` with no subcommand is the whole clean flow. The
  read-only detectors (`find large`, `find dupes`) and rollback (`undo`) are the only user-facing
  subcommands; `docker`, `brew`, `doctor`, and `profile` are **hidden** (`shouldDisplay: false`)
  helpers.
- **No `analyze` / `clean` / `optimize` / `report` / `audit` / `staging` commands exist** — those
  intents collapsed into flags on `cleaner` (`--dry-run`, `--md`, `--json`) and into `undo`.
- Read-only verbs never require confirmation. The Act path routes through summary → confirm →
  stage, and is always undoable.

---

## 4. Grouping & sorting

**Default grouping.** The summary groups **Category → Source (plugin) → (Item, under `-v`)**
(§ 1). Each plugin's Findings collapse to a single Source row with an item count
(`Xcode DerivedData (12)`); `--verbose` expands each Source into its Items. `cleaner find`'s
detector lists group by their finding type instead (largest files; duplicate groups by content
hash, one keep-candidate implied).

**Sorting.** Sort is **descending Reclaimable (allocated bytes)** everywhere — the user's primary
question is "biggest win first". Categories, Sources within a category, and the per-Source
selection walk are all ordered largest-total-first. There is no risk sort (no risk tiers) and no
user-facing `--sort` flag in v0.6.

**Filtering / scoping.** Applied via flags, not an interactive filter:

- `--include` / `--exclude` — narrow the plugin universe by comma-separated plugin ids.
- `--profile <name>` — apply a saved include/exclude set from `config.yml`.
- `cleaner find large --min <size> --top <n> [paths…]` — detector thresholds and roots.
- deny-list / protected paths (Article 5) always win over any include.

Precedence: `--profile`/`--include` select the plugin set → `--exclude` removes → the protected
deny-list is absolute. Filters change what's scanned/shown, never what's protected.

**Roll-up totals.** Every Category header and every Source row shows its aggregate **Reclaimable**
(sum of Item allocated bytes, clone/hardlink-deduped, FR-042/111) and, for multi-item Sources, the
item count. The `Total` footer and the prompt's `Clean all <X>?` show the grand total. Preview
(`--dry-run`) and real-run totals use the same measurement code (principle 3).

---

## 5. Terminology surfaced to users (glossary projection)

The UI MUST use these exact terms (Article 3); alternatives in parentheses are **forbidden** to
avoid ambiguity.

| User-facing term | Meaning shown | Never say |
|---|---|---|
| **Reclaimable** | Space freeable now (allocated bytes) | "junk size", "wasted" |
| **Reclaimed** | Space actually freed after a run | "deleted size" |
| **Finding** | A reviewable item (path + reclaimable size) | "result", "hit" |
| **Source** | One plugin's collapsed contribution (`Name (count)`) | "group", "bucket" |
| **Item** | The concrete file/dir/group acted on | "object", "entry" |
| **Stage / Staging** | Move to the tool's recoverable quarantine | "delete" (it isn't) |
| **Undo** | Restore the last (or a chosen) staged session | "undelete", "rollback UI" |
| **Profile** | Saved plugin include/exclude set | "preset" |
| **Protected** | Never touched (deny-list) | "safe path" |

Because v0.6 stages (never permanently purges at the default surface), the payoff line says
**"Reclaimed … (recoverable)"** and the undo hint is always shown. **No risk vocabulary**
(Safe/Medium/Dangerous, safety score, recoverability class) is surfaced in v0.6; those concepts
exist in the engine core but are not presented to the user.

---

## 6. Progressive disclosure (summary → source → item)

Information is revealed in three depths; each mode picks a default and `-v` deepens it. This keeps
a large scan legible (NFR-013).

| Depth | What's shown | Where |
|---|---|---|
| **L1 Summary** | Category totals + grand `Total`; the `DISK RECLAIMABLE` header | default `cleaner`, `--json` category totals |
| **L2 Source** | Per-Source collapsed rows: `Name (count)  reclaimable` | default `cleaner` body |
| **L3 Item** | Each Item's title + reclaimable size, un-collapsed | `-v` / `--verbose`, `--json` `items[]` |

**Rules.**

- The default view is **L1 + L2**: category headers with collapsed Source rows. L3 is opt-in via
  `--verbose` so the common case stays uncluttered.
- `--json` always carries the full L1+L2+L3 structure (machines don't need progressive
  disclosure); human output respects `--verbose`.
- `--md` renders a Markdown report at L2/L3 for sharing or archiving.
- The per-Source selection walk (Phase 3 `s`) is effectively an L2 decision surface: one y/N per
  Source, with its collapsed size shown inline.

---

## 7. Consistency requirements (IA invariants)

| ID | Priority | Requirement |
|---|---|---|
| IA-1 | MUST | The flow has a non-interactive equivalent: `--yes` (act on all) and `--json`/`--md`/`--dry-run` (no prompt); a non-TTY stdin without `--yes` refuses to act (NFR-070). |
| IA-2 | MUST | The four-level hierarchy (§ 1) is the single model across the summary, the selection walk, and JSON structure — no command invents a different object model. |
| IA-3 | MUST | Meaning never depends on color alone: sizes and labels are legible under `--no-color`/`NO_COLOR`/non-TTY (spec 25 § 5). |
| IA-4 | MUST | Default order is descending Reclaimable everywhere (§ 4). |
| IA-5 | MUST | No deletion without an interactive confirmation or `--yes`; every acted-on Item is staged and undoable (§ 2). |
| IA-6 | SHOULD | Terminology matches the glossary projection (§ 5) verbatim in all surfaces. |

---

## Open Questions

- **OQ-09.1** Category set (§ 1) is presently fine-grained (Developer Cache vs Build Artifacts vs
  Application Cache). Should some collapse into a single **Developer** umbrella for a shorter
  summary? *Leaning: keep granular; the collapsed Source rows already keep it short.*
- **OQ-09.2** Should the per-Source selection walk offer an "expand this Source to pick Items"
  step, or stay Source-granular? *Leaning: stay Source-granular; Item-level picking was the removed
  TUI's job and proved not worth the complexity.*
- **OQ-09.3** Should `cleaner find large/dupes` gain their own guarded clean path, or remain
  strictly read-only detectors? *Leaning: keep read-only; `cleaner` is the only mutating surface.*
- **OQ-09.4** Do we resurface a lightweight risk/recoverability hint in the summary now that the
  engine computes it, or keep the surface risk-free? *Leaning: keep risk-free for v0.6 clarity.*

## Dependencies

- **Consumes:** 00 (glossary, safety/deny-list model), 06 (capabilities the IA organizes),
  08 (command surface the taxonomy maps).
- **Feeds:** 25 (line-based presentation implements this flow, colours, and spinner), 26 (CLI UX
  applies the taxonomy + disclosure), 27 (error presentation), 31 (flow + snapshot tests validate
  the summary shape and terminology).
</content>
</invoke>
