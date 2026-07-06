# cleaner-cli — Specification Suite (SpecKit)

This directory is the **single source of truth** for the design of cleaner-cli. It is written
Specification-Driven Development style: the *what/why* and the *how* are fully specified and
agreed before implementation. A competent engineer or coding agent should be able to build
v1.0 from these documents without further clarification.

**Read order:** start with [`00-constitution.md`](./00-constitution.md). It fixes principles,
glossary, safety constants, exit codes, conventions, and the phase plan that everything else
inherits. Then read within a phase in numeric order.

## Index

### Phase A — Foundations
- [00 — Constitution](./00-constitution.md) — principles, glossary, safety constants, conventions *(anchor)*
- [01 — Product Vision](./01-product-vision.md)
- [02 — Problem Statement](./02-problem-statement.md)
- [03 — Personas](./03-personas.md)
- [04 — User Stories](./04-user-stories.md)
- [05 — Use Cases](./05-use-cases.md)

### Phase B — Requirements & Interface
- [06 — Functional Requirements](./06-functional-requirements.md) *(+ capability matrix, traceability)*
- [07 — Non-functional Requirements](./07-nonfunctional-requirements.md)
- [08 — Command Reference](./08-command-reference.md)
- [09 — Information Architecture](./09-information-architecture.md)

### Phase C — Architecture & Tech
- [10 — Technology Stack](./10-tech-stack.md) *(+ ADRs)*
- [11 — Architecture Overview](./11-architecture-overview.md)
- [12 — Module Decomposition](./12-module-decomposition.md)
- [13 — Plugin Architecture](./13-plugin-architecture.md)

### Phase D — Core Engines
- [14 — Domain Model](./14-domain-model.md)
- [15 — Data Model](./15-data-model.md)
- [16 — Filesystem Strategy](./16-filesystem-strategy.md)
- [17 — Scan Engine Design](./17-scan-engine.md)
- [18 — Rule Engine](./18-rule-engine.md)
- [19 — Detection Algorithms](./19-detection-algorithms.md)
- [20 — Cleanup Engine](./20-cleanup-engine.md)
- [21 — Rollback Design](./21-rollback-design.md)

### Phase E — Safety & Trust
- [22 — Safety Model](./22-safety-model.md)
- [23 — Permission Model](./23-permission-model.md)
- [35 — Security Review](./35-security-review.md)
- [36 — Threat Model](./36-threat-model.md)
- [39 — Risk Register](./39-risk-register.md)

### Phase F — Experience
- [24 — Configuration System](./24-configuration-system.md)
- [25 — TUI Design System](./25-tui-design-system.md)
- [26 — CLI UX Guideline](./26-cli-ux-guideline.md)
- [27 — Error Handling Strategy](./27-error-handling.md)
- [28 — Logging Strategy](./28-logging-strategy.md)
- [29 — Telemetry](./29-telemetry.md)

### Phase G — Quality & Delivery
- [30 — Benchmark Plan](./30-benchmark-plan.md)
- [31 — Testing Strategy](./31-testing-strategy.md)
- [32 — Packaging Strategy](./32-packaging-strategy.md)
- [33 — Release Strategy](./33-release-strategy.md)
- [34 — CI/CD Pipeline](./34-cicd-pipeline.md)
- [37 — Performance Optimization](./37-performance-optimization.md)

### Phase H — Direction & Records
- [38 — Future Roadmap](./38-future-roadmap.md)
- [ADRs](./adr/) — Architecture Decision Records
- [Plugin specs](./plugins/) — per-plugin detailed designs

### Phase I — Business Model & Pro Product (open-core)
> This repository is the **free, open-source** CLI. The commercial specs (monetization,
> licensing, and the paid Pro app architecture — specs 40, 41 and ADR-0013/0014) live in a
> **separate private repository**. The only commitment that surfaces here is Constitution
> Principle 1.11: **safety is never behind a paywall** — the free CLI is exactly as safe and
> capable at cleaning as any paid edition.

## Conventions used across specs

- **Requirement IDs:** `FR-###` functional, `NFR-###` non-functional, `SR-###` safety.
- **RFC-2119 keywords** (MUST/SHOULD/MAY) carry their normative meaning.
- Every doc ends with **Open Questions** and **Dependencies** sections.
- Decisions cite at least one rejected alternative (Constitution Article 11).
