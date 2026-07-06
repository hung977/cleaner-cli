# 03 — Personas

> **Phase A · Depends on:** 00-constitution, 01-product-vision, 02-problem-statement ·
> **Depended on by:** 04, 05, 06, 24, 25, 26.
>
> **Status:** Draft · **Version:** 1.0 · **Owner:** Product / UX

## 1. Purpose

Give the design a cast of concrete users so that requirements, user stories (spec 04), use
cases (spec 05), and the UX specs (24–26) can be written *for someone specific* rather than an
abstract "user". Personas here are the canonical referents for the "As a `<persona>`…" clause
in every user story. They also anchor the **risk-tolerance spectrum** (§ 8) that the Safety
Model (spec 22) tunes defaults against.

These personas are archetypes, not real individuals. Each MUST be traceable to a pain in the
problem statement (spec 02) and to at least one KPI in the vision (spec 01).

## 2. Persona roster (at a glance)

| ID | Name | Role | Risk tolerance | Primary interface | Signature need |
|---|---|---|---|---|---|
| P1 | **Mai** | iOS/macOS developer | Low–medium | TUI (interactive) | Reclaim Xcode/simulator junk without breaking her toolchain. |
| P2 | **Diego** | Full-stack (Node + Docker) developer | Medium | CLI + TUI | Tame Docker & `node_modules` sprawl across many projects. |
| P3 | **Priya** | DevOps / CI platform engineer | Medium (in prod: low) | Headless CLI (JSON) | Keep CI runners lean, unattended, auditable. |
| P4 | **Sam** | Power user / prosumer | Medium–high | TUI, some CLI | Squeeze a small SSD; enjoys tuning and dashboards. |
| P5 | **Rosa** | Security-conscious skeptic (staff eng / SRE) | Very low | CLI, reads source | Trust nothing; verify everything before it deletes. |
| P6 | **Tomás** | Engineering manager / team lead (secondary) | Low | Delegates; reviews reports | Standardize safe cleanup across the team's machines. |

P1–P5 are the primary personas the brief requires (≥ 5); P6 is a secondary persona included
because team standardization drives the automation/reporting epics (spec 04).

---

## 3. P1 — Mai, the iOS/macOS developer

> *"I'll happily nuke DerivedData, but if you touch my simulators' installed apps or my
> signing stuff, we're done."*

- **Snapshot.** 31, senior iOS engineer at a product company. Ships an App Store app plus
  internal tools. Lives in Xcode all day.
- **Technical level.** High in Apple tooling; comfortable in the terminal but not a shell
  power user. Reads man pages when stuck.
- **Environment.** 512 GB MacBook Pro (Apple silicon), perpetually 85–95% full. Xcode + 6–8
  simulator runtimes, CocoaPods **and** SPM, Homebrew, Fastlane, a little Docker. Multiple
  large app repos with big `DerivedData` and archives.
- **Goals.** Reclaim the 20–60 GB of Xcode/simulator/DerivedData junk (spec 02 § 4) quickly;
  do it *between* builds without breaking her signing, provisioning, or a simulator she has a
  specific app state in.
- **Frustrations.** "Disk full" mid-archive; Xcode's own cleanup is buried; deleting the
  wrong simulator loses a carefully set-up device; `xcrun simctl` incantations are easy to
  get wrong.
- **How she'd use cleaner-cli.** Runs `cleaner clean` interactively, scans the tree in the TUI,
  bulk-selects 🟢 Xcode/DerivedData/stale-runtime findings, **skips** anything touching
  provisioning profiles or a named simulator she recognizes, confirms, done in a minute. Keeps
  staging around for a day in case a build misbehaves.
- **What makes her distrust it.** Any hint it would delete signing assets, provisioning
  profiles, a *booted* or named simulator, or Keychain items. A reclaim number that doesn't
  match what Finder later shows (breaks truth-in-reporting, principle 3).
- **Serves KPIs.** K2 (big reclaim), K3 (TTFV), K6 (no false positives on her signing assets).

---

## 4. P2 — Diego, the full-stack (Node + Docker) developer

> *"I have forty repos and a Docker VM that eats disks for breakfast. Just show me what's safe
> and let me tick boxes."*

- **Snapshot.** 27, full-stack engineer at an agency; jumps between client projects weekly.
- **Technical level.** Strong generalist; fluent CLI; scripts his own dotfiles; not a systems
  programmer.
- **Environment.** 1 TB MacBook, ~40 project folders, each with `node_modules`; pnpm + npm +
  yarn coexist; Docker Desktop with a bloated VM disk (images, build cache, dangling volumes);
  Homebrew, a couple of Postgres containers.
- **Goals.** Reclaim Docker space (his #1 hog, spec 02 § 4) and stale `node_modules` from
  projects he isn't touching this month, without nuking the containers/volumes of the client
  he's actively on.
- **Frustrations.** `docker system prune` is scary (what about my volumes?); he can't remember
  which `node_modules` are safe; global package caches are opaque; he over-tolerates a full
  disk because cleaning is a chore.
- **How he'd use cleaner-cli.** `cleaner analyze` first to see the breakdown by category, then
  `cleaner clean` interactively; relies on risk badges to avoid touching *running* Docker
  resources and the active project. Later graduates to `cleaner clean --yes` on 🟢 only for a
  quick weekly sweep, and adds a couple of active projects to his ignore config.
- **What makes him distrust it.** Deleting a Docker **volume** with data, or the `node_modules`
  of the repo he's mid-feature on, or anything that forces a slow `npm install` he didn't
  expect (medium-risk items acting like safe ones).
- **Serves KPIs.** K2, K8 (automation ratio via weekly `--yes` sweep), K9 (repeat usage).

---

## 5. P3 — Priya, the DevOps / CI platform engineer

> *"If it can't run headless, emit JSON, and return a sane exit code, it doesn't exist to me."*

- **Snapshot.** 35, platform/DevOps engineer owning the macOS CI fleet for a 200-engineer org.
- **Technical level.** Expert. Lives in YAML, shell, and CI config; automates everything;
  cares about idempotence and exit codes.
- **Environment.** A fleet of macOS CI runners (self-hosted + cloud), each doing Xcode builds
  and Docker work all day; disks fill within hours; runners are cattle, not pets.
- **Goals.** Keep runners from failing builds on `ENOSPC`; reclaim between jobs *unattended*;
  get machine-readable results into dashboards; never have cleanup itself break a build.
- **Frustrations.** GUI cleaners are useless to her (spec 02 cause 6); homegrown `rm -rf`
  scripts are fragile and occasionally nuke a build cache they shouldn't; no unified report.
- **How she'd use cleaner-cli.** In a CI pre/post step: `cleaner doctor --ci` as a health gate,
  `cleaner clean --yes --include ...` scoped to safe categories, `cleaner report --json` piped
  to her observability stack. Uses a signed automation policy (Constitution Article 5 / spec
  23) so unattended runs are governed, and exit codes (Article 7) drive pipeline logic.
- **What makes her distrust it.** Non-deterministic scans (breaks idempotence, principle 5);
  any interactive prompt in `--yes` mode; unclear exit codes; deleting a warm cache that
  slows every subsequent build (medium-risk treated as safe). A tool that phones home
  (principle 10) is an instant no.
- **Serves KPIs.** K8 (automation ratio), K10 (doctor-clean rate), K5 (preview accuracy for
  dashboards).

---

## 6. P4 — Sam, the power user / prosumer

> *"I want the pretty tree view, the big number going down, and knobs to turn. Show me the
> duplicates and the giant old files too."*

- **Snapshot.** 42, indie hacker / prosumer; not a full-time SWE but codes side projects and
  tinkers constantly. A "quantified-self of my disk" type.
- **Technical level.** Comfortable and curious; will read the config file and tune it; enjoys
  a good TUI.
- **Environment.** 256 GB MacBook Air (small SSD, constant pressure); a grab-bag of tools
  (Homebrew, a bit of Xcode, Node, Python, some VMs), a messy Downloads folder, lots of
  duplicate exports and old installers.
- **Goals.** Reclaim every safe byte on a small disk; hunt duplicates and large/old files;
  enjoy the process (dashboards, themes); set up a saved profile for a monthly ritual.
- **Frustrations.** Small SSD fills weekly; DaisyDisk shows him big folders but won't clean
  safely; he's willing to go a bit aggressive but has been burned by `rm`.
- **How he'd use cleaner-cli.** Interactive TUI for the experience; uses the duplicate-finder
  and large/old-file finder; sometimes opts into `--include medium`; saves a
  "prosumer-monthly" **profile** (Constitution glossary) and tweaks themes and the config
  whitelist. Exports an HTML report to feel good about the reclaimed space.
- **What makes him distrust it.** A duplicate-finder that flags files that aren't truly
  identical (hash false positive), or deleting the *original* instead of the copy; a reclaim
  number that doesn't stick. He tolerates medium risk but not sloppiness.
- **Serves KPIs.** K2, K9 (ritual/repeat), K4 (rollback when he goes aggressive).

---

## 7. P5 — Rosa, the security-conscious skeptic

> *"Show me exactly what you'll delete, prove you can't touch my keys, and let me dry-run
> everything. I'll read your source before I run it."*

- **Snapshot.** 39, staff engineer / SRE with a security bent; the person teammates ask "is
  this tool safe?".
- **Technical level.** Deep systems knowledge; audits tools; reads code and man pages; assumes
  the worst.
- **Environment.** Locked-down 1 TB Mac; SSH keys, GPG, cloud credentials, signing material
  all present; corporate policy against tools that exfiltrate data.
- **Goals.** Reclaim space **only** if she can verify, before and after, exactly what happens;
  guarantee that credentials/keys are untouchable; keep an audit trail.
- **Frustrations.** Opaque GUIs she can't audit; tools that phone home; anything that runs with
  elevated privileges without explanation; `rm`-based scripts that could dereference a bad
  symlink into `~/.ssh`.
- **How she'd use cleaner-cli.** Always `--dry-run` first; inspects the JSON report; verifies
  protected-path enforcement (Constitution Article 5) covers `~/.ssh`, `~/.gnupg`, Keychains,
  `*.pem/*.key`; runs with least privilege and only grants Full Disk Access after reading the
  rationale (spec 23); checks the NDJSON audit log after every real run; keeps staging until
  she's satisfied, then purges deliberately.
- **What makes her distrust it (instant disqualifiers).** *Any* network call in the cleaning
  path (principle 10); silent privilege escalation (principle 6); following a symlink out of
  an allowed root (Article 4.4); a proposed action touching credentials; a dry-run number that
  differs from the real run without explanation; an unexplained deletion (no evidence).
- **Serves KPIs.** K1 (zero-data-loss guardrail — she is its human embodiment), K5 (dry-run =
  real-run accuracy), K6 (false positives).

---

## 8. P6 — Tomás, the engineering manager / team lead (secondary)

> *"I want every laptop on my team to clean up the same safe way, and I want a report I can
> glance at — I'm not going to run commands myself."*

- **Snapshot.** 45, EM of a 12-person mobile team; still technical but mostly in reviews and
  planning.
- **Technical level.** Was a strong dev; now rusty on the CLI; prefers copy-paste runbooks.
- **Environment.** Manages team standards; team members are P1/P2-like; IT provisions machines.
- **Goals.** Standardize a *safe* cleanup across the team (a shared profile/policy), reduce
  "my disk is full" support tickets, see aggregate reclaim in a report.
- **Frustrations.** Every dev cleans differently (or not at all); occasional data-loss scares
  from ad-hoc `rm`; no visibility.
- **How he'd use cleaner-cli.** Ships a shared `config.yml` / profile and a one-line runbook
  command to the team; asks for `cleaner report` output in retros; never touches the internals
  himself. Values the **audit trail** and reversibility as a governance story.
- **What makes him distrust it.** A single data-loss incident on any team machine; a tool
  that's too fiddly for his less-CLI-comfortable reports; anything requiring per-machine
  hand-holding.
- **Serves KPIs.** K7 (adoption via team rollout), K1 (his reputation rides on it), K8/K10.

---

## 9. The risk-tolerance spectrum

The Safety Model (spec 22) sets *defaults* conservatively (Constitution principle 1) and lets
each persona opt toward more aggression explicitly. Mapping personas onto the spectrum:

```
 Very low            Low            Medium            Medium–high
 risk tolerance      tolerance      tolerance         tolerance
 ┌──────────┬───────────────┬────────────────────┬──────────────────┐
 │  Rosa P5 │  Mai P1        │  Diego P2          │  Sam P4          │
 │  Tomás P6│  Priya P3*     │  Priya P3 (in CI)  │                  │
 └──────────┴───────────────┴────────────────────┴──────────────────┘
   dry-run,     🟢 only,        🟢 + selected 🟡     🟢 + 🟡, uses
   verify,      skips named     via --include,       duplicate/large
   audit        assets          scoped policy        finders, --include
```

\* Priya is *very low* risk on production-critical caches but *medium* on runner scratch space;
her policy scopes categories rather than applying one global tolerance.

**Design implications:**

- The **default** posture MUST satisfy the most conservative persona (Rosa/Mai): pre-select
  only 🟢, never pre-select 🟡, require typed confirmation for 🔴 (Constitution Article 4.1).
- Aggression MUST be an **explicit opt-in** (`--include medium`, duplicate/large finders,
  `--no-stage`), never a default — so P4/P2 can go further without endangering P1/P3/P5.
- Every persona, regardless of tolerance, depends on **reversibility** (staging/rollback) and
  **truth-in-reporting**; these are not tunable and serve K1/K4/K5 universally.
- **Trust disqualifiers are shared:** network calls, silent escalation, symlink escapes, and
  credential-adjacent deletions would break trust for *every* persona, not just Rosa — so they
  are hard invariants (Article 4.4 / 5), not persona preferences.

## 10. Persona → interface & feature affinity

| Feature / surface | P1 Mai | P2 Diego | P3 Priya | P4 Sam | P5 Rosa | P6 Tomás |
|---|---|---|---|---|---|---|
| Interactive TUI (`clean`) | ●●● | ●● | ○ | ●●● | ● | ○ |
| Headless `--yes` / `--ci` | ○ | ●● | ●●● | ● | ● | ●● (via runbook) |
| `analyze` (read-only) | ●● | ●●● | ●● | ●●● | ●●● | ● |
| `dry-run` preview | ●● | ●● | ●● | ●● | ●●● | ○ |
| `doctor` | ● | ● | ●●● | ● | ●● | ● |
| `report` (JSON/HTML) | ● | ● | ●●● | ●● | ●● | ●●● |
| Rollback / staging | ●● | ●● | ● | ●●● | ●●● | ●● |
| Config / profiles / ignore | ● | ●● | ●●● | ●●● | ●● | ●●● (shared) |
| Duplicate finder | ○ | ● | ○ | ●●● | ● | ○ |
| Large/old-file finder | ● | ● | ● | ●●● | ● | ○ |
| Plugins (Xcode/Docker/…) | ●●● Xcode | ●●● Docker/Node | ●● | ●● | ● | ● |
| Audit trail | ● | ● | ●● | ● | ●●● | ●●● |

Legend: ●●● core to persona · ●● important · ● occasional · ○ rarely/never.

## Open Questions

- **OQ-03.1** Is P6 (manager) in-scope enough to earn dedicated features (shared policy
  distribution, aggregate reporting), or is he served incidentally by P3's automation surface?
  *Leaning: served incidentally in v1; revisit for a team edition on the roadmap (spec 38).*
- **OQ-03.2** Should there be a distinct "reluctant/non-technical" persona, or does Tomás cover
  the low-CLI-comfort case adequately for v1? *Leaning: Tomás suffices.*
- **OQ-03.3** Do we need a persona for the *plugin author* (third-party developer extending
  coverage)? They are a real user of the plugin architecture (spec 13). *Leaning: yes, but
  their needs live in spec 13, not here, since they are a developer-of-the-tool not an end
  user.*
- **OQ-03.4** Are the disk-size assumptions (256 GB–1 TB) still representative given growing
  base storage, and does that weaken the "small SSD" urgency for P1/P4? Validate against the
  benchmark cohort (spec 30).

## Dependencies

**Consumes:** 00-constitution (Article 4 risk levels drive the spectrum; principles 1/2/6/10
define the shared trust disqualifiers), 01-product-vision (personas must serve its KPIs),
02-problem-statement (each persona embodies a quantified pain and root cause).

**Feeds:** 04-user-stories (the `<persona>` in every story), 05-use-cases (actors),
06-functional-requirements (features prioritized by persona affinity), 22-safety-model
(defaults tuned to the risk spectrum), 24-configuration-system / 25-tui-design-system /
26-cli-ux-guideline (UX designed per persona interface affinity § 10).
