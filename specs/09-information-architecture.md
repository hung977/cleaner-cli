# 09 — Information Architecture

> **Phase B · Depends on:** 00-constitution, 06-functional-requirements, 08-command-reference ·
> **Depended on by:** 25 (TUI design system), 26 (CLI UX), 27 (errors), 31 (tests).
>
> The **mental model** the user navigates, the object hierarchy, the TUI navigation map, the
> command-surface taxonomy, and the grouping/sorting/filtering + progressive-disclosure rules.
> Terminology here is the Constitution glossary (Article 3) surfaced to users verbatim — the
> tool MUST use these exact words. RFC-2119 keywords are normative.

## 1. Object hierarchy (the mental model)

The user reasons about disk cleanup as a five-level containment hierarchy. Every screen, list,
and JSON document is a projection of some slice of this tree.

```
Volume            a mounted disk/APFS volume (capacity, used, free, purgeable, reclaimable)
  └─ Category     a human bucket of junk: Developer · Browsers · System · Caches · Media · Duplicates
       └─ Plugin  the unit that scans+cleans one thing (DerivedData, Chrome cache, Docker…)
            └─ Finding   an Item + its assessment: risk 🟢🟡🔴, safety score, recoverability, rationale
                 └─ Item      the atomic actionable unit: a file, directory, or logical group
```

- **Volume** (FR-001/002): the top scope. Default single volume = the boot volume containing
  `$HOME`; `--all-volumes` widens to every mounted local volume. System/mount roots are
  navigable for *reporting* but deny-listed for *action* (Article 5).
- **Category:** a stable, user-facing grouping of plugins. Categories are presentation only —
  plugins own behavior. Canonical set (v1): **Developer**, **Browsers**, **System**,
  **Caches**, **Media/Duplicates**, **Trash & Temp**. Advisory-only results from `audit`
  surface under a virtual **Opportunities** category.
- **Plugin** (Article 3): the leaf capability. Carries id, category, default risk,
  recoverability, native/fallback status (from `plugins info`, spec 08 §5).
- **Finding** (Article 3): what the user *sees and decides on* — an Item plus risk icon, safety
  score (0–100), recoverability class, and a one-line rationale. Findings are what checkboxes
  toggle.
- **Item** (Article 3): what the engine *acts on*. One Finding may wrap a group Item
  (e.g. "DerivedData for project X" = a directory Item). Reclaim is measured on the Item
  (allocated bytes, CC-10).

**Selection semantics.** Selection cascades down and rolls up: selecting a Category selects all
its Plugins' eligible Findings; a partially-selected parent renders a tri-state box. Risk gates
the default: 🟢 pre-selected, 🟡 shown-unselected, 🔴 shown-unselected-and-locked-until-typed-
confirm (Article 4.1). The engine acts only on selected Findings' Items.

---

## 2. Navigation map (interactive TUI)

The interactive `cleaner` (FR-076) is a stack-based, keyboard-driven navigator over the
hierarchy in §1. Screens push/pop; a persistent header (scope + running reclaim total) and
footer (key hints) frame every screen (spec 25).

```
                         ┌───────────────────────────┐
                         │      S0  Home / Dashboard  │  volume summary, quick actions
                         └───────────────────────────┘
              Analyze │        │ Clean        │ Audit        │ Manage
        ┌─────────────┘        │              │              └──────────────┐
        ▼                      ▼              ▼                             ▼
 ┌──────────────┐     ┌────────────────┐  ┌───────────────┐        ┌──────────────────┐
 │ S1 Analysis  │     │ S2 Categories  │  │ S5 Audit list │        │ S8 Manage menu   │
 │  storage +   │     │  (tree/multi-  │  │ (opportunities│        │  plugins/config/ │
 │  breakdown   │     │   select)      │  │  risk-ranked) │        │  profiles/staging│
 └──────┬───────┘     └───────┬────────┘  └──────┬────────┘        └────────┬─────────┘
        │ drill               │ expand           │ drill                   │
        ▼                     ▼                   ▼                         ▼
 ┌──────────────┐     ┌────────────────┐  ┌───────────────┐        ┌──────────────────┐
 │ S1a Item list│     │ S3 Findings    │  │ S5a Evidence  │        │ S8a Staging list │
 │ (large/dupe/ │     │  (per plugin,  │  │  (why flagged)│        │  restore / purge │
 │  old detail) │     │   checkboxes)  │  └───────────────┘        └──────────────────┘
 └──────────────┘     └───────┬────────┘
                              │ confirm
                              ▼
                      ┌────────────────┐        ┌────────────────┐        ┌──────────────┐
                      │ S4 Preview     │──run──▶ │ S6 Progress    │──done─▶│ S7 Summary   │
                      │ (plan + total  │        │  (live counts, │        │ (reclaimed,  │
                      │  + risk recap) │        │   cancellable) │        │  skipped,    │
                      │  [type to      │        └────────────────┘        │  next steps) │
                      │   confirm 🔴]  │                                   └──────────────┘
                      └────────────────┘
```

**Screen inventory & transitions:**

| ID | Screen | Purpose | Exits to |
|---|---|---|---|
| S0 | Home/Dashboard | Volume summary, reclaimable estimate, quick-action menu (Analyze/Clean/Audit/Manage) | S1, S2, S5, S8; `q` quits |
| S1 | Analysis | Storage report + category breakdown (FR-070) | S1a (drill), S0 (back) |
| S1a | Detail list | Large-file / duplicate / old-file items | S0/S1 (back) |
| S2 | Categories | Category tree, multi-select, live sizes (FR-075 selection) | S3 (expand), S4 (confirm), S0 |
| S3 | Findings | Per-plugin Findings with checkboxes, risk icon, size | S3-item detail, S4, S2 |
| S4 | Preview | Final plan: items, total Reclaim, disposition, risk recap; **typed confirm for 🔴** | S6 (run), S2/S3 (back/edit), S0 (cancel) |
| S5 | Audit | Risk-ranked opportunities (FR-071), advisory | S5a (evidence), "send to Clean" → S2 preselected, S0 |
| S5a | Evidence | Why an opportunity was flagged (evidence, Article 3) | S5 (back) |
| S6 | Progress | Live disposal: per-item status, counts, spinner/bar, **cancellable** (`q`/Ctrl-C → S7 partial) | S7 |
| S7 | Summary | Reclaimed total, skipped/failed with reasons, rollback hint, report path | S0, `q` quit |
| S8 | Manage | Sub-menu: Plugins, Config, Profiles, Staging | S8a…, S0 |
| S8a | Staging | List staged sessions; restore / purge (FR-088/089) | S8 |

**Global keys** (spec 25 owns the full map): `↑/↓/j/k` move · `←/→/h/l` collapse/expand ·
`Space` toggle select · `Enter` drill/confirm · `Tab` next pane · `/` filter · `s` sort ·
`?` help · `Esc` back · `q`/Ctrl-C cancel-or-quit. Every screen has a non-TTY linear equivalent
(NFR-070); the same transitions become sequential prompts.

**Confirmation gates.** No transition S4→S6 (execute) occurs without explicit confirmation;
🔴 Findings require typing a confirmation phrase (Article 4.1), not a single key. Cancellation
from S6 always lands on S7 with an accurate partial report (FR-093/NFR-042).

---

## 3. Command-surface taxonomy

The command tree (spec 08 §1) maps onto three intents. This taxonomy is the user's map from
"what I want" to "which verb".

| Intent | Question the user asks | Commands | Mutating? |
|---|---|---|---|
| **Understand** | "What's using my space? What could I reclaim?" | `analyze`, `audit`, `report`, `doctor`, `plugins list/info`, `staging list` | No (read-only) |
| **Act** | "Reclaim space now." | `clean`, `optimize`, `staging restore/purge` | Yes (guarded) |
| **Configure** | "Tune, save, and manage how it behaves." | `config …`, `profile …`, `completion`, `version` | State only |

- **Understand-before-Act** is the enforced flow: `clean`/`optimize` internally run an
  Understand pass (scan+classify) and render a Preview (S4) before any Act (principle 1).
- The interactive TUI is the unifying surface: S1=Understand, S2–S4/S6=Act, S8=Configure.
- Read-only verbs never require confirmation or elevation beyond read access; Act verbs route
  through preview→confirm→dispose and may request scoped elevation (FR-098).

---

## 4. Grouping, sorting, filtering

**Default grouping.** Results group by **Category → Plugin → Finding** (§1). `analyze`'s detail
lists (large/dupe/old) group by their finding type instead. Duplicates group by content hash
(the group is the unit; one keep-candidate marked, FR-004).

**Sorting.** Default sort = **descending Reclaim (allocated bytes)** everywhere — the user's
primary question is "biggest win first". Alternate keys (spec 08 `--sort`, TUI `s`): `size`,
`risk` (🟢→🔴 or 🔴→🟢), `age` (mtime/atime), `count`, `name/path`. Sort MUST be stable
(NFR-031): ties broken by canonical path.

**Filtering.** Applied consistently across TUI (`/`) and CLI (`--include`/`--exclude`,
`--min-size`, `--older-than`, `--categories`, `--min-savings`):
- by **risk** (`safe|medium|dangerous`),
- by **category** or **plugin id**,
- by **size** (min threshold) / **age** (older-than),
- by **path glob**.
Precedence (spec 08 §2): `--plugins` narrows the universe → `--include` selects → `--exclude`
removes → deny-list/protected paths always win. Filters are non-destructive view operations;
they change what's shown/selected, never what's protected.

**Roll-up totals.** Every group header shows its aggregate Reclaim (sum of Item allocated bytes,
clone/hardlink-deduped, FR-042/111) and item count; the global header shows the running selected
total. Totals in preview and real-run use the same measurement code (principle 3).

---

## 5. Terminology surfaced to users (glossary projection)

The UI MUST use these exact terms (Article 3); alternatives in parentheses are **forbidden** to
avoid ambiguity.

| User-facing term | Meaning shown | Never say |
|---|---|---|
| **Reclaimable** | Space freeable now (allocated bytes) | "junk size", "wasted" |
| **Reclaimed** | Space actually freed after a run | "deleted size" |
| **Finding** | A reviewable item + its risk assessment | "result", "hit" |
| **Item** | The concrete file/dir/group acted on | "object", "entry" |
| **Stage / Staging** | Move to the tool's recoverable quarantine | "delete" (it isn't) |
| **Purge** | Permanent, irreversible deletion | "clean", "remove" |
| **Restore / Rollback** | Put staged items back | "undelete" |
| **Risk: Safe 🟢 / Medium 🟡 / Dangerous 🔴** | Article 4.1 meanings, word + icon (never color alone, NFR-071/072) | "low/high" without icon |
| **Safety score** | 0–100 confidence removal is harmless | "confidence %" alone |
| **Recoverability: instant / manual / hard / none** | Article 4.3 | "reversible?" yes/no |
| **Profile** | Saved plugin selection + options | "preset" |
| **Protected / Whitelisted** | Never touched (deny-list) | "safe path" |

Risk is **always** presented as icon + word + (optionally) score, so meaning survives
`NO_COLOR`, screen readers, and color-blindness (NFR-071/072/070).

---

## 6. Progressive disclosure (summary → detail → item)

Information is revealed in three depths; each command and screen picks a default depth and lets
the user drill. This keeps the 5 M-file case legible (NFR-013) and matches `-v` levels.

| Depth | What's shown | Where (TUI / CLI) |
|---|---|---|
| **L1 Summary** | Totals per Volume/Category: reclaimable bytes, item count, dominant risk | S0/S1 header, `analyze` default, `--json` `byCategory` |
| **L2 Detail** | Per-Plugin Findings: risk icon, size, recoverability, one-line rationale, checkbox | S2/S3, `clean` preview list, `-v` |
| **L3 Item** | Per-Item: full path(s), allocated vs logical, mtime/atime, evidence, disposition | S3-item / S5a evidence, `-vv`, `--json` `items[].evidence` |

**Rules.**
- Default views start at **L1/L2**; L3 is opt-in (drill in TUI, `-vv`/`--json` in CLI) so
  common cases stay uncluttered.
- The **Preview (S4)** is always at least L2 and MUST expose L3 on demand before any 🔴 confirm —
  the user can always see *exact paths* before deciding (principle 1, truth-in-reporting).
- Evidence (Article 3) lives at L3 and answers "why?" for audit (principle 8); it is one drill
  from any Finding.
- `--json` always carries L1+L2+L3 (machines don't need progressive disclosure); human output
  respects the depth chosen by `-v` count.

---

## 7. Consistency requirements (IA invariants)

| ID | Priority | Requirement |
|---|---|---|
| IA-1 | MUST | Every TUI screen has an equivalent linear plain-output path (non-TTY / `--no-tui`), same transitions as sequential prompts (NFR-070). |
| IA-2 | MUST | The five-level hierarchy (§1) is the single navigation model across TUI, CLI grouping, and JSON structure — no command invents a different object model. |
| IA-3 | MUST | Risk is shown as icon + word everywhere (§5), never color alone (NFR-071/072). |
| IA-4 | MUST | Default sort is descending Reclaim; all sorts stable (§4, NFR-031). |
| IA-5 | MUST | No execute transition without preview + confirmation; 🔴 needs typed confirm (§2, Article 4.1). |
| IA-6 | SHOULD | Terminology matches the glossary projection (§5) verbatim in all surfaces. |

---

## Open Questions

- **OQ-09.1** Canonical category set (§1) — is six the right count, or should **Media/Duplicates**
  split into two? *Leaning: keep six for v1.*
- **OQ-09.2** Should `audit` opportunities be their own top-level TUI tab (S5) or fold into the
  Categories tree as an "Opportunities" category? *Leaning: separate tab for risk clarity.*
- **OQ-09.3** Default disclosure depth for `clean` preview — L2 with per-item drill, or L3 flat
  when the item count is small (< 20)? *Leaning: L2 default, auto-L3 under a small-N threshold.*
- **OQ-09.4** Do we surface the numeric safety score in the default L2 list, or only at L3 to
  avoid clutter? *Leaning: L3 by default, icon+word at L2.*
- **OQ-09.5** Volume navigation for `--all-volumes`: a top-level S-volume picker above S0, or a
  scope switcher in the header? *Leaning: header scope switcher.*

## Dependencies

- **Consumes:** 00 (glossary, risk model, safety gates), 06 (capabilities the IA organizes),
  08 (command surface the taxonomy maps).
- **Feeds:** 25 (TUI design system implements these screens/keys/themes), 26 (CLI UX applies the
  taxonomy + disclosure), 27 (error presentation within screens), 31 (navigation + snapshot
  tests validate the screen map and terminology).
