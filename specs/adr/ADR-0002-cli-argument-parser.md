# ADR-0002: CLI Parsing = swift-argument-parser

- **Status:** Accepted
- **Date:** 2026-07-06
- **Deciders:** Architecture
- **Realizes:** Constitution Article 10 · CC-2 · deep analysis in spec 10 §4
- **Constitution articles engaged:** 7 (exit codes), 6 (conventions)

## Context

The `cleaner` binary exposes a substantial command tree (spec 08): `analyze`, `audit`, `clean`,
`optimize`, `doctor`, `report`, plus `plugins`, `config`, `staging`, `profile`, `completion`,
`version`, and a reserved `self-update` stub. It needs consistent `--help` on every node, usage
errors that map to **exit code 2** (Article 7), shell completions for bash/zsh/fish (a
distribution requirement, ADR-0011), and a parser that is trivially unit-testable without a real
process/argv. The command surface is the public contract and must be stable and self-documenting.

## Decision Drivers

1. **First-party guarantee & longevity** — the CLI is the product's public API; its parser should
   track Swift/Apple, not a third party's roadmap.
2. **Declarative command tree** mapping 1:1 to spec 08 with minimal boilerplate.
3. **Built-in `--help`, usage errors → exit 2, and completions** for all three shells.
4. **Testability** — construct and exercise commands in-process, no argv plumbing.

## Options Considered

### swift-argument-parser (Apple) — chosen
- **Pros:** first-party Apple library; declarative `ParsableCommand` subcommand tree maps directly
  to spec 08; free `--help`, standardized usage errors (exit 2), and generated bash/zsh/fish
  completions; commands are plain structs, unit-testable by constructing them directly; validation
  hooks integrate with our `CleanerError`/exit-code model (Article 7).
- **Cons:** occasional friction expressing exotic flag grammars (our `--include`/`--exclude`
  selector grammar needs a custom `ExpressibleByArgument` — acceptable, one type).

### Hand-rolled parser — rejected
- **Pros:** total control; zero dependency.
- **Cons / why rejected:** reinvents `--help` rendering, completion generation, and error
  formatting — hundreds of lines of undifferentiated, bug-prone code we'd own forever. No upside
  over the first-party option; violates the "minimize what we own" instinct behind CC-8/spec 10 §11.

### Third-party parsers (Commander, swift-cli, etc.) — rejected
- **Pros:** some ergonomic sugar.
- **Cons / why rejected:** no first-party longevity guarantee; weaker or absent completion
  generation; smaller maintenance surface; adds a dependency that must be vendor-audited (spec 10
  §11) for no capability the Apple library lacks.

## Decision

Use **swift-argument-parser**. Model the spec 08 tree as nested `ParsableCommand`s; centralize
global flags on the root; map `ValidationError`/`ExitCode` to Article 7 codes; ship completions
via the `completion` subcommand. Custom `ExpressibleByArgument` types encode the selector grammar
and size/duration arguments.

## Consequences

- Usage errors uniformly exit `2`; completions ship for free — one less thing to hand-maintain.
- The command tree stays declarative and close to spec 08, easing traceability (Article 9).
- We depend on one more Apple package (already in the allowed set, spec 10 §11) — low risk.
- Exotic flag grammar (selectors) lives in small custom argument types, snapshot-tested (spec 31).

## Links

- Constitution Article 10 (CC-2), Article 7 (exit codes).
- Spec 08 (command reference — the surface parsed here), spec 10 §4, spec 26 (CLI UX), spec 27
  (error→exit-code), spec 31 (CLI tests).
- Related: ADR-0001 (Swift/SPM), ADR-0009 (testing).
