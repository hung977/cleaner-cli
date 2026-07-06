# Contributing to cleaner

Thanks for your interest! cleaner is safety-critical software — it deletes files — so the bar
for changes on the deletion path is high. These notes keep contributions smooth.

## Ground rules

1. **Safety is never negotiable.** No change may weaken the safety model: preview→confirm→execute,
   move-to-staging by default, protected-path enforcement, and "Dangerous is never auto-cleaned".
   Any deletion-path change needs a paired safety test.
2. **The safety test suite must stay 100% green.** It proves protected paths can never be deleted.
3. **Native-first.** Prefer a documented macOS/Foundation API over shelling out; every shell
   fallback is an isolated, justified adapter.
4. **Plugins propose, the engine disposes.** New cleaning capability is a plugin (see
   `Sources/CleanerPlugins/`); it never bypasses the engine's safety funnel.

## Getting set up

```sh
git clone https://github.com/hung977/cleaner-cli && cd cleaner-cli
swift build
swift test                     # run the full suite (incl. the safety gate)
./Scripts/integration-smoke.sh # end-to-end checks against a synthesized home
./Scripts/install-local.sh     # install locally (builds + re-signs)
```

Requires macOS 13+ and a Swift 6 toolchain (Xcode 16+).

## Adding a plugin

A plugin is a small `CleanerPlugin` in `Sources/CleanerPlugins/`. It declares its roots,
scans them read-only into `Finding`s with a **risk** and **rationale**, and proposes a
disposition (usually `.stage`). Register it in `BundledPlugins.all()`. Add a test in
`Tests/CleanerPluginsTests/` — cover the safety boundary (e.g. a browser plugin must target
cache dirs only). Use the correct risk: 🟢 only for auto-regenerated, no-user-data caches.

## Pull requests

- Keep changes focused; match the surrounding style.
- `swift test` and `./Scripts/integration-smoke.sh` must pass.
- For anything touching deletion, staging, or the safety guard, explain the safety reasoning
  in the PR description.
- Commits: conventional style (`feat:`, `fix:`, `docs:`…) is appreciated but not required.

## Design docs

The full design lives in [`specs/`](./specs) — start with the
[Constitution](./specs/00-constitution.md) and the [Safety Model](./specs/22-safety-model.md).
