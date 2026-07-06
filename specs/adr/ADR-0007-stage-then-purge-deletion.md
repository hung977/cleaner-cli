# ADR-0007: Deletion = Stage-then-Purge (macOS Trash optional)

- **Status:** Accepted
- **Date:** 2026-07-06
- **Deciders:** Architecture
- **Realizes:** Constitution Article 10 · CC-7 · analysis in spec 10 (deletion model), spec 20/21
- **Constitution principles engaged:** 1 (safety over savings), 2 (reversibility by default), 8 (audit)

## Context

The tool's entire reason to be trusted is that it *never loses data you need* (principle 1) and
that *nothing is unlinked outright when a recoverable path exists* (principle 2). Deletion is the
one irreversible act, so its default must be recoverable. The engine must also enforce the hard
invariant "never purge without staging first, unless `--no-stage` **and** confirmation"
(Article 4.4) and record every disposition in the audit trail (principle 8).

## Decision Drivers

1. **Reversibility by default** — a one-command rollback for anything the tool "deletes"
   (recoverability class `instant`, Article 4.3).
2. **Truth & auditability** — original path + metadata preserved, every move recorded (FR-087/099).
3. **Cross-volume correctness** — staging on another volume must copy-then-verify before removing
   the source (FR-087).
4. **Explicit, escalated permanence** — irreversible purge is never a default (principle 2).
5. **User choice** — some users prefer Finder-visible recovery (macOS Trash).

## Options Considered

### Stage-then-purge (tool-managed quarantine) — chosen
- **Pros:** disposal default is *move-to-staging* (`~/.cleaner/staging/<session-uuid>`) preserving
  original path + metadata, giving instant one-command `staging restore` (FR-088); purge is a
  separate, explicit, irreversible escalation (`staging purge` / `--no-stage` + confirm, FR-089);
  the engine can enforce "no purge without stage" centrally (FR-110/Article 4.4); every move and
  restore is audited (principle 8); session-scoped staging enables whole-run rollback and
  retention-based auto-purge (spec 24).
- **Cons:** transient double storage (staged copy until purge) — bounded by retention config and,
  for cross-volume, by copy-then-verify cost; we own the staging index and its crash-consistency
  (spec 21), which must survive SIGKILL mid-operation.

### Direct `rm` / `unlink()` — rejected
- **Pros:** simplest, no extra storage, immediate space reclaim.
- **Cons / why rejected:** **irreversible by default** — a direct, categorical violation of
  principles 1 and 2. One wrong classification and the user's data is gone with no recourse. For a
  tool whose worst-case bug is exactly this, an unrecoverable default is disqualifying.

### macOS Trash only (`NSWorkspace.recycle`) — rejected as the *default*, kept as an *option*
- **Pros:** Finder-visible, user-familiar recovery; OS-managed.
- **Cons / why rejected as default:** the system Trash is user-owned space and mixes tool actions
  with the user's own deletions (muddying the audit trail and per-session rollback); it doesn't
  give the tool a clean, session-scoped, metadata-preserving quarantine or programmatic
  whole-session restore; it can't uniformly handle per-volume `.Trashes` semantics the way our
  staging does. Offered as an opt-in disposition (`--trash`, FR-090) for users who prefer it.

## Decision

**Default disposition = stage** to `~/.cleaner/staging/<session-uuid>`, preserving original path
and metadata (FR-087); cross-volume moves fall back to **copy-then-verify-then-remove-source**.
**Purge** (permanent) is an explicit escalation (`staging purge` or `--no-stage` **with**
confirmation) and is the only irreversible operation (FR-089/Article 4.4). Offer **`--trash`**
(FR-090) to route to the macOS Trash for users who prefer Finder recovery. The engine enforces
"no purge without stage" and audits every disposition/restore (FR-110/FR-099). The `TrashPlugin`
is a special case: emptying the *user's own* Trash uses `purge` disposition (no re-staging) with
typed confirmation (FR-037).

## Consequences

- Every routine cleanup is reversible in one command — the core trust promise (principle 2).
- We own a crash-consistent staging index (spec 21) that must survive process kill mid-clean and
  be repairable by `doctor --fix` (roadmap v0.5 exit criteria).
- Transient double storage is the accepted cost of reversibility, bounded by retention (spec 24).
- Purge remains rare, explicit, audited, and irreversible — as intended.

## Links

- Constitution Article 10 (CC-7), Article 3 (staging/purge/rollback glossary), Article 4.4
  (invariants), principles 1, 2, 8.
- Spec 20 (cleanup engine), spec 21 (rollback/staging index), spec 24 (retention), spec 08 §7
  (`staging` commands), FR-087/088/089/090/099/110.
- Related: ADR-0006 (audit sink records dispositions), ADR-0010 (reclaim measured on purge/stage).
