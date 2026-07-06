# ADR-0010: Reclaim Measured by Allocated On-Disk Size (APFS clone/sparse truth)

- **Status:** Accepted
- **Date:** 2026-07-06
- **Deciders:** Architecture
- **Realizes:** Constitution Article 10 · CC-10 · analysis in spec 10 §10, spec 16
- **Constitution principles engaged:** 3 (truth in reporting — the direct driver)

## Context

Principle 3 forbids overstating savings: "the tool never overstates savings." On APFS this is
subtle. **Clones** (copy-on-write) and **hardlinks** share physical blocks — deleting one
reference frees *nothing* until the last reference goes. **Sparse files** report a large logical
size but occupy few allocated blocks. Naive logical size (what `ls -l` or a simple sum shows)
therefore *lies* about reclaimable space, sometimes by gigabytes. Because dry-run and real-run
must use the **same** measurement code (FR-082/principle 3), whatever we choose is baked into both
projection and reporting — it cannot be corrected after the fact honestly.

## Decision Drivers

1. **Truth in reporting (principle 3)** — the reported number must equal bytes actually freed.
2. **APFS correctness** — clones, hardlinks, and sparse files must not inflate the total.
3. **One measurement path** for dry-run and real-run (FR-082/111).
4. **Determinism** — same tree ⇒ same number (principle 5).

## Options Considered

### Allocated on-disk size via `URLResourceValues` (+ inode/clone accounting) — chosen
- **Pros:** `URLResourceValues.totalFileAllocatedSize` (and `fileAllocatedSize`) reports actual
  allocated blocks — sparse-correct by construction; combined with inode (`st_ino`) grouping we
  collapse **hardlinks** (count once) and, via `st_nlink`/clone detection, treat **APFS clones** as
  shared storage where Reclaim = 0 unless we remove the last reference (FR-059/111). This is the
  only option that can honestly answer "how many bytes will actually come back?" and it's the same
  code for dry-run and real-run (FR-082).
- **Cons:** more work per item (extra resource-value fetch, inode bookkeeping, clone/last-reference
  reasoning); allocated size can slightly exceed logical (block rounding) — but that's the *truth*
  of what's on disk, which is exactly what we want to report.

### Logical (byte) size — rejected
- **Pros:** trivial to compute, matches `ls -l`/naive expectations.
- **Cons / why rejected:** **overstates** reclaim for clones/hardlinks (shared blocks counted
  multiple times) and for sparse files (logical ≫ allocated) — a direct violation of principle 3.
  For a trust-first tool, a number that promises 12 GiB and frees 3 GiB is a betrayal, not a bug.

### `du`-style block sum via shell-out — rejected
- **Pros:** `du` accounts for allocation and hardlinks within a walk.
- **Cons / why rejected:** shelling out violates native-first (principle 4); `du`'s hardlink
  dedup is per-invocation and doesn't compose with our streaming, cancellable, cross-root scan;
  no clean clone/last-reference semantics; adds a subprocess threat surface (spec 36) for data we
  can compute natively and more precisely.

## Decision

Measure **Reclaim as actual allocated on-disk bytes freed**, via Foundation `URLResourceValues`
allocated-size keys, with **inode-based hardlink collapsing** and **APFS clone/last-reference
accounting** (Reclaim = 0 for a shared clone unless removing the final reference), and **sparse
awareness** (allocated, not logical). The **same measurement code** serves `--dry-run`
projection and real-run reporting (FR-082/111). Totals never overstate savings (FR-111).

## Consequences

- The headline reclaim number is honest — the foundation of user trust (principle 3) and a v0.5
  exit criterion (spec 38: dry-run number == real-run number on fixtures).
- Extra per-item cost (resource fetch + inode bookkeeping); acceptable and bounded by the
  streaming scan design (spec 17).
- Requires the clone/hardlink/sparse/snapshot awareness of FR-059 as a hard dependency — the
  measurement and the detection share this machinery (spec 16).
- Round-trip/measurement tests (ADR-0009) must include clone and sparse fixtures to prevent
  regressions into logical-size lies.

## Links

- Constitution Article 10 (CC-10), principle 3, principle 5.
- Spec 10 §10, spec 16 (filesystem strategy — allocated size, clone/sparse), FR-001, FR-059,
  FR-082, FR-111.
- Related: ADR-0007 (measured at stage/purge), ADR-0009 (measurement round-trip tests).
