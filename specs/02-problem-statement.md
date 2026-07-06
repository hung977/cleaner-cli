# 02 — Problem Statement

> **Phase A · Depends on:** 00-constitution, 01-product-vision ·
> **Depended on by:** 03, 04, 05, 06, 39.
>
> **Status:** Draft · **Version:** 1.0 · **Owner:** Product

## 1. Purpose

State precisely the problem cleaner-cli solves, *who* suffers it, *how much* it costs them,
*why* it happens (root causes), what people do today (alternatives) and where those fall
short, and the crisp **job-to-be-done** the product is hired for. This grounds the vision
(spec 01) in a real, quantified pain and gives downstream requirements (spec 06) a problem to
be measured against. RFC-2119 keywords are used where this document asserts what a solution
MUST address.

## 2. The problem in one sentence

> **A macOS developer's SSD silently fills with gigabytes of invisible, regenerable junk that
> is tedious and genuinely dangerous to clean by hand, while the tools that could help are
> paid, opaque GUIs that cannot be scripted, audited, or safely trusted.**

## 3. Who hurts, and why

The acute sufferer is the **macOS software developer** (and adjacent DevOps/CI engineer and
power user — see personas, spec 03). Their disk fills faster than anyone's because their daily
tools are *cache-heavy by design*:

| Junk source | Where it hides | Why it grows unbounded |
|---|---|---|
| **Xcode** DerivedData, Archives, device-support, old simulators/runtimes | `~/Library/Developer/Xcode/...` | New DerivedData per project/config; simulators/runtimes never GC'd; device-support per iOS build. |
| **Docker** images, build cache, volumes, layers | Docker Desktop VM disk | `docker build` layers accumulate; dangling images; `buildx` cache; nobody runs `prune`. |
| **node_modules** and package caches | per-project + `~/.npm`, `~/.pnpm`, `~/.yarn` | Every JS project re-materializes hundreds of MB; global caches never expire. |
| **Package-manager caches** | `~/Library/Caches/Homebrew`, `~/.gradle`, `~/.cargo`, `~/.m2`, `~/.cocoapods`, pip, SPM | Downloaded artifacts cached "for speed", never evicted. |
| **Build artifacts** | `target/`, `build/`, `.build/`, `dist/`, `DerivedData` | Regenerated on demand but kept between builds. |
| **Browser & app caches, logs** | `~/Library/Caches`, `~/Library/Logs` | Grow continuously; opaque to the user. |
| **Duplicates & stale large/old files** | Downloads, scattered exports, old installers | No lifecycle; accumulate silently. |

Because this junk lives under `~/Library` and dotfile-cache directories, it is **invisible in
Finder** (hidden or Library-shielded) and semantically opaque even when found: a user staring
at a 40 GB `~/Library/Developer` folder cannot tell what is safe to delete.

The pain manifests as: **"Your disk is almost full"** alerts mid-workflow, failed builds and
Docker pulls from `ENOSPC`, Time Machine/`APFS` snapshot bloat, and hours lost to manual
spelunking — or worse, a panicked `rm -rf` that removes the wrong thing.

## 4. Quantifying the pain

Order-of-magnitude figures characteristic of a working developer machine (to be validated by
the benchmark sweep, spec 30; treated as provisional per OQ-02.1):

| Signal | Typical magnitude | Consequence |
|---|---|---|
| Reclaimable junk on a "dirty" dev machine | **20–150 GB** | On a 256–512 GB SSD (still common), this is 10–40% of the disk. |
| Xcode DerivedData + simulators alone | **10–60 GB** | Often the single largest reclaimable category for iOS/macOS devs. |
| Docker reclaimable (`docker system df`) | **5–50 GB** | Frequently the largest for backend/full-stack devs. |
| `node_modules` across projects | **0.3–1 GB each**, ×N projects | 20 projects ≈ 10–20 GB of regenerable dependencies. |
| Time to clean manually, done carefully | **30–90 min**, and repeated monthly | Recurring tax on expensive engineer time. |
| Cost of getting it wrong | **hours to days** of recovery, or unrecoverable loss | A single mistaken `rm -rf` on the wrong path. |
| Frequency of "disk full" events for active devs | **Monthly to weekly** near end of an SSD's life | Interrupts flow, blocks builds/CI. |

**The compounding problem:** cleanup is *recurring* (junk regenerates continuously), so the
manual tax is paid over and over, and each repetition carries the same risk. A tool that makes
each cleanup fast, safe, and automatable converts a recurring hours-long risk into a
sub-minute, zero-risk, scriptable operation — the core value proposition (spec 01 § 3).

## 5. Root causes

Why does this problem exist and persist? Six root causes, none of which existing tools remove:

1. **Cache-by-default toolchains.** Modern dev tools trade disk for speed and *never
   self-evict*. There is no OS-level GC for developer caches; growth is monotonic.
2. **Invisibility.** Junk lives under `~/Library` and hidden dotfile dirs, outside Finder's
   default view; users cannot see it accumulating and cannot easily size it.
3. **Opacity / semantic gap.** Even when found, a path like `~/Library/Developer/CoreSimulator`
   gives the user no signal about whether deleting it is safe. Domain knowledge is required
   and unevenly distributed.
4. **High blast radius of manual tools.** The only universally available cleaner is `rm`,
   whose failure modes are silent, unbounded, and irreversible. Fear (rational) makes users
   *under*-clean and tolerate a full disk instead.
5. **Fragmentation.** Reclaiming space means knowing a dozen tool-specific incantations
   (`xcrun simctl delete unavailable`, `docker system prune`, `brew cleanup`, `npm cache
   clean`, `pod cache clean`, `./gradlew clean`), each with its own flags and caveats. No one
   remembers all of them; no one runs all of them.
6. **No automation surface on trustworthy tools.** The tools that *are* safe and pretty
   (CleanMyMac, DaisyDisk) are GUIs with no scriptable interface, so they cannot be part of a
   CI image, a machine-setup script, or a team runbook. Safety and automation are, today,
   mutually exclusive.

A solution MUST attack causes 3–6 directly: it MUST encode the domain knowledge (cause 3),
bound the blast radius with previews/staging/rollback (cause 4), unify the fragmented
incantations behind one command (cause 5), and expose a scriptable, auditable surface (cause 6).
Causes 1–2 are inherent to the ecosystem; the tool mitigates their *effects*.

## 6. Current alternatives and their gaps

| Alternative | What it does well | Where it fails our user (the gap) |
|---|---|---|
| **CleanMyMac X** | Polished, safe-ish, broad; approachable for non-experts. | Paid; opaque "Smart Scan" black box; GUI-only, **not scriptable / CI-usable**; shallow developer-junk literacy; trust is asserted, not auditable. |
| **DaisyDisk** | Beautiful, fast **visualization** of where space went. | Only *shows* size; the human still decides and deletes; no risk scoring, no reversibility, no developer semantics, no automation. |
| **OmniDiskSweeper** | Free; simple largest-first list. | Same as DaisyDisk minus the polish: pure sizing, no safety, no semantics, no automation, no undo. |
| **GrandPerspective / Disk Inventory X** | Free visual treemaps. | Visualization only; identical gaps to DaisyDisk. |
| **Manual `rm -rf` + shell aliases** | Free, fast, fully scriptable; expert-tunable. | **Dangerous** (unbounded, irreversible failure modes); no preview; no evidence; no rollback; requires and re-derives domain knowledge; not shared or safe for teams. |
| **Per-tool cleaners** (`docker prune`, `brew cleanup`, `simctl`, `npm cache clean`) | Authoritative for their own domain. | Fragmented (cause 5); no unified view; each has its own risks/flags; no cross-tool preview, reporting, or rollback; easy to forget. |
| **Do nothing / buy a bigger disk** | No effort; no risk of deletion. | Expensive; delays the problem; impossible on soldered-SSD Macs; the junk still slows Spotlight/backups and eventually fills any disk. |

**The uncovered quadrant.** No existing option is simultaneously **safe, transparent,
developer-literate, reversible, *and* scriptable**. GUIs give safety without automation;
`rm`/scripts give automation without safety; visualizers give neither cleanup nor semantics.
cleaner-cli exists precisely to occupy that quadrant (positioning, spec 01 § 4).

## 7. The job-to-be-done

Framed as a JTBD statement (the "hire" the user makes):

> **When** my Mac warns me the disk is nearly full (or before a big build/CI run, or on a
> monthly cadence), **I want to** reclaim the most space I safely can from developer junk
> without spelunking through `~/Library` or risking a mistaken deletion, **so that** I get
> gigabytes back in under a minute, keep working, and trust that nothing I need was lost —
> and I want the same operation to run unattended in scripts and CI.

### 7.1 Functional job

Identify all reclaimable junk across fragmented developer toolchains, present it ranked by
size and risk with evidence, let the user (or an automation policy) decide, reclaim it
safely (staging + rollback), and produce an auditable, machine-readable record.

### 7.2 Emotional / social jobs

- **Emotional:** replace *fear* ("what if I delete the wrong thing?") and *guilt/procrastination*
  ("I know it's full, I'll deal with it later") with *confidence* and *closure*.
- **Social:** be recommendable — a tool a developer can put in a team runbook or share in
  dotfiles without warning colleagues "be careful with it."

### 7.3 Success criteria for the job (the bar a solution MUST clear)

1. Reclaim materially more space than the user would dare to by hand, **without any data
   loss** (Constitution principle 1; spec 01 K1/K2).
2. Reach an actionable, trustworthy preview **fast** (spec 01 K3, TTFV ≤ 60 s).
3. Be **reversible** — a regretted action is undoable with one command (Constitution
   principle 2; spec 01 K4).
4. Be **explainable** — every proposed deletion carries evidence answering "why?"
   (Constitution principle 8).
5. Be **scriptable and auditable** — usable non-interactively with JSON output and exit codes
   (Constitution Article 7), leaving an NDJSON audit trail (Article 8).

## 8. Problem-to-vision alignment

Each root-cause/gap maps to a vision differentiator (spec 01 § 5), confirming the vision
actually addresses the stated problem:

| Problem (cause / gap) | Addressed by vision differentiator |
|---|---|
| Semantic opacity (cause 3) | Native-first depth + evidence-based findings |
| High blast radius (cause 4) | Safety-first: preview / staging / rollback / invariants |
| Fragmentation (cause 5) | One command; plugin per toolchain |
| No automation on safe tools (cause 6) | First-class headless CLI (JSON + exit codes) |
| Opaque paid GUIs (§ 6 gap) | Free, open, transparent, auditable |
| Coverage we can't foresee | Plugin architecture (extensibility) |

## Open Questions

- **OQ-02.1** The magnitudes in § 4 are experience-based estimates. A benchmark sweep (spec
  30) across representative developer machines SHOULD replace them with measured medians
  before v1 sign-off; downstream KPI targets (spec 01 § 7) depend on them.
- **OQ-02.2** How wide is the non-developer prosumer pain? If material, it may broaden the
  problem framing (and the vision segment, OQ-01.3). *Leaning: treat as secondary in v1.*
- **OQ-02.3** Snapshot/Time Machine local-snapshot bloat is a real "disk full" cause but sits
  behind system tooling and protected paths (Constitution Article 5). Is *reporting* it (not
  deleting) in scope for v1? Decide in spec 06. *Leaning: report-only, no deletion.*
- **OQ-02.4** Do we quantify the *cost of a mistaken deletion* rigorously (for the risk
  register, spec 39), or is "safety is absolute" sufficient framing? *Leaning: qualitative is
  enough; K1 already encodes it as a guardrail.*

## Dependencies

**Consumes:** 00-constitution (principles 1–2 and 8 frame the safety/reversibility/audit bar;
Article 4 risk model; Article 5 protected paths bound what "reclaimable" can mean),
01-product-vision (the outcome and KPIs this problem justifies).

**Feeds:** 03-personas (embodies "who hurts"), 04-user-stories / 05-use-cases (concrete jobs
derived from § 7), 06-functional-requirements (requirements must resolve a cause/gap here),
39-risk-register (blast-radius and data-loss risks originate in § 5).
