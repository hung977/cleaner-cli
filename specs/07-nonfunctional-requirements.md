# 07 — Non-functional Requirements

> **Phase B · Depends on:** 00-constitution, 06-functional-requirements ·
> **Depended on by:** 10 (tech stack), 11, 16, 17, 20, 25, 30 (benchmarks), 31 (testing),
> 37 (performance optimization).
>
> Each `NFR-###` carries an RFC-2119 priority, a **measurable target**, and a **verification**
> method (how spec 30/31 proves it). "No number" is a defect (Constitution Article 11). Targets
> are stated against a **reference machine** unless noted.

## 1. Reference environment & workloads

- **Reference machine (RM):** Apple silicon (M-class), ≥16 GB RAM, internal APFS SSD.
- **Secondary machine (SM):** Intel x86_64, 8 GB RAM, SATA/NVMe SSD (portability floor).
- **Reference workloads:**
  - **W-small:** ~200 K files, ~50 GB (typical `$HOME` dev cache set).
  - **W-large:** ~5 M files across a 4 TB SSD (stress target, principle 9).
  - **W-dupes:** 1 M files, 30 % duplicate bytes (duplicate pipeline stress).
- Targets are **p95** unless stated. Benchmarks run under `package-benchmark` (CC-9) with
  thresholds enforced in CI (spec 30/34).

---

## 2. Performance

| NFR | Priority | Target (measurable) | Verification |
|---|---|---|---|
| **NFR-001** | MUST | Metadata scan throughput ≥ **250 K files/min** sustained on RM for W-large (read-only enumeration via `getattrlistbulk`), ≥ 120 K/min on SM. | bench `scan-throughput` |
| **NFR-002** | MUST | Peak resident memory (**RSS**) for a full W-large scan **< 300 MB**, independent of tree size (streaming, bounded accumulators — no whole-tree-in-memory). Duplicate pass **< 500 MB** RSS. | bench `mem-rss`, `heap-peak` |
| **NFR-003** | MUST | `analyze` on W-small completes **< 20 s** cold, **< 5 s** warm (incremental cache, FR-007) on RM. | bench `analyze-latency` |
| **NFR-004** | SHOULD | Duplicate detection on W-dupes completes **< 8 min** on RM; SHA-256 confirmation runs only on size+prefilter collision groups (FR-004), hashing **< 5 %** of total bytes in the common case. | bench `dupe-pipeline` |
| **NFR-005** | MUST | Disposal (staging move) throughput ≥ **10 K items/min**; intra-volume moves MUST be `rename`-based (O(1) per item), not copy. Cross-volume copy fallback bounded and reported. | bench `dispose-throughput` |
| **NFR-006** | MUST | CPU: scan MUST scale across cores via bounded `TaskGroup` (concurrency limiter tuned to volume type, spec 17) and MUST NOT spin idle cores; default parallelism = min(cores, IO-derived cap). | bench `cpu-scaling` |
| **NFR-007** | SHOULD | Allocation discipline: hot enumeration loop performs **≤ 1 heap allocation per file** amortized (use `System.FilePath`, reuse buffers). | instrument + bench `alloc-per-file` |
| **NFR-008** | MUST | Reclaim measurement adds **< 5 %** overhead vs. raw enumeration (allocated-size query is batched, CC-10). | bench `measure-overhead` |

---

## 3. Scalability

| NFR | Priority | Target | Verification |
|---|---|---|---|
| **NFR-010** | MUST | Correct and bounded on volumes up to **4 TB** and **≥ 10 M** files without OOM or unbounded runtime growth (linear in file count, no worse than O(n log n) for sorted outputs). | bench `scale-4tb` (synthesized FS) |
| **NFR-011** | MUST | Handles pathological trees: directories with **≥ 1 M** direct children, path depth **≥ 64**, path length up to `PATH_MAX`, without stack overflow (iterative traversal, no unbounded recursion). | test `T-scale-pathological` |
| **NFR-012** | SHOULD | Multiple mounted volumes scanned concurrently with per-volume concurrency caps (network/HDD throttled below SSD). | test `T-multi-volume` |
| **NFR-013** | SHOULD | Result sets of ≥ 1 M Findings are paged/streamed to the TUI and to `--json` (no requirement to materialize all at once). | test `T-large-result-stream` |

---

## 4. Responsiveness (TUI)

| NFR | Priority | Target | Verification |
|---|---|---|---|
| **NFR-020** | MUST | TUI frame budget: render loop sustains **≥ 30 fps** (frame ≤ **33 ms** p95) during live scan updates, via double-buffered diff rendering (spec 25/ADR-0004). | bench `tui-frame`, snapshot tests |
| **NFR-021** | MUST | Input latency: keystroke → visible response **< 100 ms** p95 (nav, select, scroll). | test `T-tui-input-latency` |
| **NFR-022** | MUST | Progress feedback appears **< 500 ms** after a long operation starts; spinner/progress never freezes >1 s without an update while work proceeds. | test `T-progress-liveness` |
| **NFR-023** | MUST | Scan/clean work runs off the render actor; the UI MUST remain interactive (cancel responsive < 200 ms) while a scan proceeds. | test `T-tui-nonblocking` |
| **NFR-024** | SHOULD | Terminal resize (`SIGWINCH`) reflows within **1 frame** without corruption. | snapshot test `T-resize` |

---

## 5. Reliability & idempotence

| NFR | Priority | Target | Verification |
|---|---|---|---|
| **NFR-030** | MUST | **Idempotence:** re-running any command on an unchanged FS yields byte-identical results (principle 5); re-running `clean` finds nothing new (FR-112). | test `T-idempotent-*` |
| **NFR-031** | MUST | **Determinism:** identical inputs ⇒ identical ordering and totals; no dependence on wall-clock, hash-map iteration order, or filesystem enumeration order (stable sort keys). | test `T-determinism` |
| **NFR-032** | MUST | **Crash consistency:** a `SIGKILL`/power loss mid-disposal leaves every Item either fully staged or untouched (no half-moved directory); staging uses atomic `rename` + a journal so recovery is deterministic (spec 21). | fault-injection test `T-crash-consistency` |
| **NFR-033** | MUST | **Data-race freedom** proven at compile time (Swift 6 strict concurrency, CC-3); zero `@unchecked Sendable` without a documented invariant. | build gate (strict concurrency) |
| **NFR-034** | SHOULD | **Mean time between defects:** no data-loss defect escapes to a release; the safety-critical paths (staging, deny-list, invariants) have ≥ 95 % line + branch coverage. | coverage gate (spec 31) |
| **NFR-035** | MUST | **Graceful degradation:** a failing plugin/adapter/permission is isolated and reported (FR-113), never aborts the whole session or corrupts state; exit `3`/`7` as appropriate. | test `T-plugin-isolation` |

---

## 6. Cancellation & resume

| NFR | Priority | Target | Verification |
|---|---|---|---|
| **NFR-040** | MUST | Cancellation (Ctrl-C / `q`) takes effect **< 200 ms** at the next directory boundary, leaves FS consistent, exits `5` (FR-091). | test `T-cancel-latency` |
| **NFR-041** | SHOULD | A cancelled/interrupted scan resumes from a checkpoint (FR-092), re-scanning **< 10 %** of already-covered subtrees. | test `T-resume` |
| **NFR-042** | MUST | Partial disposal is journaled so that after cancellation the session report and `staging` reflect exactly what moved (FR-093). | test `T-partial-journal` |
| **NFR-043** | MUST | No orphaned OS resources (open FDs, temp files, raw-mode terminal) after cancel/crash; terminal MUST be restored to cooked mode on any exit path. | test `T-terminal-restore` |

---

## 7. Security

| NFR | Priority | Target | Verification |
|---|---|---|---|
| **NFR-050** | MUST | **Least privilege** (principle 6): the tool runs as the invoking user and requests elevation only per-operation via Authorization Services (spec 23); no setuid, no persistent helper daemon in v1. | review + test `T-no-escalation` |
| **NFR-051** | MUST | **Deny-list enforcement** (Article 5) is unconditional and centrally enforced; no config, plugin, or flag can delete a protected path except a signed policy with explicit ack. Attempts abort with exit `8`. | test `T-denylist`, threat model (spec 36) |
| **NFR-052** | MUST | **Adapter hardening:** every shell-out (spec 13) MUST use argument-vector exec (no shell string interpolation), an allow-list of binaries at absolute paths, a timeout, and output-size caps — preventing injection (spec 36). | test `T-adapter-injection` |
| **NFR-053** | MUST | **Symlink/TOCTOU safety:** disposal MUST re-validate the target against invariants using `O_NOFOLLOW`/`fstatat` semantics at the moment of action; MUST NOT follow a symlink out of an allowed root (Article 4.4). | test `T-toctou` |
| **NFR-054** | SHOULD | **Supply chain:** dependencies pinned to exact versions with checksums; SBOM produced at release; no runtime network I/O in core path (principle 10). | CI gate (spec 34), audit |
| **NFR-055** | MUST | **Signed policy verification:** automation policy files (spec 23) MUST be signature-verified before granting any escalation; an invalid signature is treated as absent, not trusted. | test `T-policy-verify` |

---

## 8. Privacy

| NFR | Priority | Target | Verification |
|---|---|---|---|
| **NFR-060** | MUST | **No telemetry by default** (principle 10, CC-12): zero network egress unless the user opts in; the opt-in is explicit and revocable (spec 29). | test `T-no-egress` (network sandbox) |
| **NFR-061** | MUST | Reports, logs, and audit trails stay **local** under `~/.cleaner` and are never transmitted; export is a deliberate user action. | review + test |
| **NFR-062** | MUST | Logs MUST NOT record file *contents*; paths are recorded (needed for audit) but the tool MUST offer a `--redact-paths` mode that hashes user-identifying path components in exported reports. | test `T-log-redaction` |
| **NFR-063** | SHOULD | Any opt-in telemetry payload MUST be inspectable (`--print-telemetry`) before send and contain no path/content data (aggregate counters only, spec 29). | test `T-telemetry-payload` |

---

## 9. Accessibility

| NFR | Priority | Target | Verification |
|---|---|---|---|
| **NFR-070** | MUST | **Plain-output mode:** every TUI screen has a non-TTY / `--no-tui` equivalent that is fully linear, screen-reader-friendly text (no reliance on cursor positioning or color to convey meaning). | test `T-plain-output` |
| **NFR-071** | MUST | **`NO_COLOR`** env var and `--no-color` MUST fully disable color/SGR; all information conveyed by color MUST also be conveyed by text/symbol (status conveyed as word/label, not color alone). | test `T-no-color` |
| **NFR-072** | MUST | **Color-blind-safe themes:** ship at least one deuteranopia/protanopia-safe theme and never rely on red/green alone to convey meaning (any emphasis is also carried by text/labels). | review + snapshot `T-theme-cvd` |
| **NFR-073** | SHOULD | Screen-reader compatibility validated with VoiceOver on the plain-output path; interactive prompts are answerable without visual context. | manual a11y checklist (spec 25) |
| **NFR-074** | SHOULD | All interactive actions are reachable by keyboard only; no mouse requirement. Key bindings documented and discoverable (`?` help). | test `T-keyboard-only` |
| **NFR-075** | SHOULD | Respect `prefers-reduced-motion` semantics: a `--no-animation`/config option disables spinners/animated bars in favor of discrete percentage updates. | test `T-reduced-motion` |

---

## 10. Internationalization / localization hooks

| NFR | Priority | Target | Verification |
|---|---|---|---|
| **NFR-080** | MUST | All user-facing strings MUST route through a localization layer (string catalog / `String(localized:)`), with **zero** hard-coded user-facing literals in view code (build lint). v1 ships `en` only but is fully externalized. | lint gate `T-i18n-externalized` |
| **NFR-081** | MUST | Numbers, byte sizes, and dates MUST format via locale-aware formatters (`ByteCountFormatter`, `Measurement`, `Date.FormatStyle`); byte sizes MUST clearly indicate binary vs decimal (GiB vs GB) consistently. | test `T-locale-format` |
| **NFR-082** | SHOULD | TUI layout MUST tolerate string expansion (≥ +40 %) and East-Asian double-width / emoji grapheme widths without misalignment (width table, ADR-0004). | snapshot `T-width-tables` |
| **NFR-083** | MAY | RTL awareness deferred to v2 but the rendering layer MUST NOT assume LTR-only in its width/column model. | review |

---

## 11. Portability

| NFR | Priority | Target | Verification |
|---|---|---|---|
| **NFR-090** | MUST | Supported OS: **macOS 13 (Ventura) and newer**; APIs newer than 13 are runtime-probed/feature-gated (spec 10 §3). Launch on an unsupported OS exits `10` with a clear message. | test `T-os-gate` |
| **NFR-091** | MUST | **Universal binary** (arm64 + x86_64), verified on RM and SM; feature parity across both, performance targets scaled per §1. | CI matrix (spec 34) |
| **NFR-092** | MUST | No dependency on Xcode-only frameworks at runtime; headless/CI build MUST NOT require AppKit (`NSWorkspace` usage isolated behind a probe so headless builds link without it, spec 10 §10). | build test `T-headless-link` |
| **NFR-093** | SHOULD | Works under common terminals (Terminal.app, iTerm2, VS Code, tmux, ssh) and degrades cleanly where truecolor/altscreen unsupported (capability probing, not assumptions). | matrix test `T-terminal-compat` |

---

## 12. Maintainability

| NFR | Priority | Target | Verification |
|---|---|---|---|
| **NFR-100** | MUST | **Extensibility without core edits** (principle 7): adding a plugin MUST require zero changes to Engine/CLI/other plugins — proven by a reference "hello" plugin added in a test. | test `T-plugin-additive` |
| **NFR-101** | SHOULD | Module boundaries per spec 12 are acyclic; no module import cycles (enforced in CI). Public API of each module documented. | CI graph check |
| **NFR-102** | SHOULD | Cyclomatic complexity and file length within agreed lints; no force-unwrap in non-test code without a `// SAFETY:` note (Article 6). | lint gate |
| **NFR-103** | SHOULD | Test suite runs **< 5 min** on CI for unit+integration (excluding scale benches), keeping the feedback loop tight. | CI timing |

---

## 13. Observability

| NFR | Priority | Target | Verification |
|---|---|---|---|
| **NFR-110** | MUST | Every run is reconstructable from logs (principle 8): structured `swift-log` output (spec 28) + append-only NDJSON **audit trail** of every mutation (path, size, disposition, session UUID, evidence). | test `T-audit-completeness` |
| **NFR-111** | MUST | A machine-readable session **report** (`--json`, `schemaVersion`) is produced for every run and persisted under `~/.cleaner/reports` for later inspection (`cleaner undo --list`, FR-073). | test `T-report-persist` |
| **NFR-112** | SHOULD | `--debug` emits timing/decision traces (per-phase durations, per-plugin counts, adapter calls) to **stderr** without polluting `--json` **stdout** (stdout/stderr contract, spec 08). | test `T-debug-stream-separation` |
| **NFR-113** | SHOULD | Log volume is bounded: audit/logs rotate (size+age) under `~/.cleaner/logs` and never grow unboundedly (spec 28). | test `T-log-rotation` |
| **NFR-114** | MAY | Optional `swift-metrics` counters (scan rate, reclaim bytes, durations) exposed when telemetry opted in, no-op backend otherwise (spec 10 §8). | test `T-metrics-noop` |

---

## 14. Install size & startup time

| NFR | Priority | Target | Verification |
|---|---|---|---|
| **NFR-120** | MUST | **Cold startup** (`cleaner --version`) **< 150 ms** on RM, **< 300 ms** on SM (fast binary, principle 9). | bench `startup` |
| **NFR-121** | SHOULD | `analyze`/`clean` reach first visible progress **< 500 ms** after launch (overlaps NFR-022). | bench `time-to-first-frame` |
| **NFR-122** | SHOULD | Distributed universal binary **< 25 MB**; installed footprint (binary + completions + man) **< 40 MB**. | packaging gate (spec 32) |
| **NFR-123** | SHOULD | Homebrew install (`brew install`) completes with no runtime network fetch of dependencies beyond the bottle itself (self-contained static binary, CC-11). | release test |

---

## Open Questions

- **OQ-07.1** RSS ceiling: is **< 300 MB** for scan (NFR-002) too tight given the emoji-width
  table + accumulators, or should the dupe pass get a separate, higher budget? *Leaning: keep
  scan < 300 MB, dupe pass < 500 MB as stated.*
- **OQ-07.2** Throughput target (NFR-001) depends heavily on `getattrlistbulk` vs
  `URLResourceValues` — final number to be re-baselined once spec 16 prototypes land.
- **OQ-07.3** Do we commit to **resume** (NFR-041) for v1 or downgrade to MAY? Depends on
  checkpoint complexity in spec 17. *Leaning: SHOULD, may slip.*
- **OQ-07.4** Startup budget (NFR-120) — does static-linking Foundation/CryptoKit keep us under
  150 ms on Intel, or is 300 ms the realistic floor on SM? Re-baseline in spec 30.
- **OQ-07.5** Minimum OS (NFR-090) inherits OQ-10.1 (12 vs 13). Resolve jointly with spec 10.

## Dependencies

- **Consumes:** 00 (principles 5/6/8/9/10, exit codes), 06 (the FRs these targets quantify),
  10 (tech choices that make the targets achievable).
- **Feeds:** 11 (architecture must meet these), 16 (filesystem strategy → NFR-001/002/007),
  17 (scan engine → throughput/memory/cancel/resume), 20 (cleanup → NFR-005/032), 21 (rollback
  → crash consistency), 23 (permissions → security NFRs), 25 (TUI → responsiveness/a11y/i18n),
  28 (logging → observability), 29 (telemetry → privacy), 30 (benchmark plan implements every
  `bench` verification), 31 (testing strategy implements every `T-*` verification), 32
  (packaging → install size), 34 (CI enforces gates), 37 (performance optimization).
