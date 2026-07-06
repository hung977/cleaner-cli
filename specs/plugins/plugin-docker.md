# plugin-docker — Docker

> **Phase H · Plugin id:** `dev.cleaner.docker` · **Target release:** v0.5 ·
> **Depends on:** plugins/README, 13 (`process` fallback, propose/dispose), 14, 16, 36 (process
> sandbox), 00 Art. 4/5.

The **most safety-sensitive** plugin and the only **shell-only** one: Docker stores everything
inside an opaque VM disk image (`Docker.raw`), so there is **no meaningful native filesystem
analysis** — deleting files under the VM would corrupt it. All reclaim goes through the Docker CLI.
The critical rule: **never remove named volumes or in-use data by default** (volumes are 🔴 user
data).

## 1. Identity

```swift
PluginManifest(
    id: "dev.cleaner.docker", name: "Docker", category: .containers,
    apiVersion: "1.4.0", pluginVersion: "1.0.0",
    declaredRoots: [],                          // NO filesystem roots — Docker data is inside an opaque VM image
    defaultRisk: .medium,                       // dangling images/build cache are 🟡; volumes are 🔴
    capabilities: [.dryRun, .estimate, .audit], // NO .rollback — pruned Docker objects are NOT recoverable
    requiresElevation: false, trust: .firstParty)
```

`declaredRoots` is **empty**: the plugin does not enumerate the filesystem at all. It reports the
opaque `Docker.raw` for *context* only (informational) and does all detection/cleanup through the
Docker daemon's own API via the CLI. Because there are no declared roots, the engine's
ProtectedPathGuard has nothing to intersect; the plugin's authority is entirely mediated by the
`context.process` sandbox (spec 36) and the safety rails below.

Scope boundary: dangling (untagged) images, stopped containers, unused build cache, and — only
with explicit escalation — **anonymous** (unnamed) unused volumes. It NEVER prunes named volumes,
running containers, or tagged images in use.

## 2. What it targets

| Sub-item | Docker concept | Why junk | Risk | Reversible? |
|---|---|---|---|---|
| Dangling images | `<none>:<none>` untagged layers | Superseded build layers; nothing references them. | 🟡 | no (re-buildable) |
| Stopped containers | `status=exited/created` | Finished/abandoned runs; not running. | 🟡 | no (re-runnable) |
| Build cache | BuildKit cache | Rebuildable; often the biggest reclaim. | 🟢/🟡 | no (rebuild) |
| Unused images (all) | tagged images with no container | Re-pullable, but may be intentionally cached offline. | 🟡 | no (re-pull) |
| **Anonymous unused volumes** | volumes w/ no container, no name | May be leftover DB/data volumes. | 🔴 | **none — data lost** |
| Named volumes | user-named volumes | **User data. NEVER pruned by default.** | 🔴 | none |

Does **not** target: running containers, named volumes (default), the Docker VM image itself,
Docker Desktop settings, or anything a `--filter` would exclude.

## 3. Detection signals & algorithm

There is no filesystem walk. Detection = **read-only Docker API queries** parsed into Findings:

1. **Daemon liveness:** `docker version --format json` (§8). If the daemon is not running →
   emit zero findings + a `SkippedPath`-style note "Docker not running"; never start it.
2. **Space report:** `docker system df --format json` and `docker system df -v --format json` →
   per-category reclaimable bytes (`Reclaimable` field) for Images, Containers, Local Volumes,
   Build Cache. This is Docker's *own* accounting and is the source of truth for `estimate`.
3. **Per-object enumeration for Findings:**
   - Images: `docker image ls --filter dangling=true --format json` → dangling. Optionally
     `docker image ls --format json` cross-referenced against `docker ps -a` to find images with
     no container (only if `pruneUnusedImages` enabled).
   - Containers: `docker ps -a --filter status=exited --filter status=created --format json`.
   - Volumes: `docker volume ls --format json` + inspect → classify **named vs anonymous**
     (anonymous names are 64-hex). Cross-reference `docker ps -a` mounts to find *unused* volumes.
   - Build cache: from `system df` (BuildKit cache is not individually addressable except via
     `builder prune`).
4. Each object → one `Finding` with `Evidence` populated from the JSON (size, created-at,
   last-used where available), `FindingID = "docker:<type>:<id>"` (deterministic, DM-7).
5. **Volume classification is the safety-critical step:** a volume is eligible for a Finding only
   if it is (a) not attached to any container AND (b) anonymous (unless the user explicitly opts
   into named-volume handling, which is 🔴 + typed confirm and off by default).

## 4. Roots / paths with justification

**N/A — no declared roots.** Docker data lives inside `~/Library/Containers/com.docker.docker/
Data/vms/0/data/Docker.raw` (or `~/.docker`), an opaque sparse VM image. Declaring it as a
scannable root would be dangerous (partial deletion corrupts the VM) and useless (contents are not
individually addressable from the host). The plugin reports the image's `allocatedSize` as an
*informational* finding (`isProtected = true`, display-only) so the user sees where the space is,
but the only actionable reclaim is via the daemon.

## 5. Risk & safety scoring

| Sub-item | Risk | Score | Rationale |
|---|---|---|---|
| Dangling images | 🟡 75 | superseded, rebuildable | pre-shown, not pre-selected under `--yes` unless `--include medium` |
| Build cache | 🟢/🟡 80 | rebuildable; large | |
| Stopped containers | 🟡 70 | re-runnable | |
| Unused tagged images | 🟡 60 | re-pullable but may be offline cache | opt-in |
| Anonymous unused volumes | 🔴 30 | **may be data**, unrecoverable | never pre-selected, typed confirm |
| Named volumes | 🔴 (excluded) | user data | **never actioned by default** |

`Recoverability = .none` for everything Docker prunes (there is no staging of Docker objects) →
by DM-1 anything with real data-loss potential is forced 🔴. Images/containers/build-cache are
`.manual`-ish in practice (rebuild/re-pull) but since the tool cannot stage them, the plugin
labels them honestly and relies on medium-under-`--yes` skip semantics (Art. 4.1).

## 6. Recoverability & staging

**Staging does not apply** — Docker objects live inside the daemon, not the host filesystem, so
the engine cannot `renameat` them into staging. This is the one category where the reversibility
default (Principle 2) is physically impossible; the plugin therefore:

- Advertises **no `.rollback` capability** and sets `Recoverability = .none`/`.manual`.
- Proposes cleanup not as a `.stage`/`.purge` disposition on a path, but as an **audited daemon
  command** executed by the engine's process runner *after* the same preview→confirm→execute gate
  (Principle 1). The `CleanDirective` for a Docker Finding carries an opaque command token the
  engine validates against an allow-list of safe prune argv (see §8), not a filesystem path.
- Because there is no rollback, the confirmation bar is **higher**: even 🟡 Docker items get an
  explicit "this is permanent, Docker cannot undo a prune" notice in the preview.

## 7. Dry-run / estimate

- `estimate`/`--dry-run`: driven by `docker system df` `Reclaimable` fields **plus** the dry-run
  form of prune where available: `docker builder prune --dry-run` etc. gives Docker's own
  projection. `confidence = .estimated` (Docker's reclaimable is an estimate; actual freed space
  depends on layer sharing) — surfaced honestly (Principle 3).
- The `Docker.raw` host image does **not** shrink automatically after a prune (the VM disk is
  sparse and must be compacted); the report says so and notes the user can compact via Docker
  Desktop — the tool does **not** claim host-level bytes it did not free (Principle 3).

## 8. Shell fallback & its safety

**Entirely shell-based** (justified: Docker exposes no native macOS API; its documented interface
is the CLI/HTTP socket). Every call is an argv array through `context.process` (no shell string,
spec 36), timeout-bounded, and split into **read-only** vs **mutating** tiers:

**Read-only (scan/estimate) — always allowed:**
```
["docker","version","--format","json"]                 # liveness, 5s
["docker","system","df","--format","json"]             # totals, 10s
["docker","system","df","-v","--format","json"]        # per-object, 15s
["docker","image","ls","--filter","dangling=true","--format","json"]
["docker","ps","-a","--format","json"]
["docker","volume","ls","--format","json"]  + inspect
["docker","builder","prune","--dry-run","--format","json"]  # projection only
```

**Mutating (clean) — allow-listed, scoped, never destructive-by-default:**
```
["docker","image","prune","-f"]                        # dangling only (no -a by default)
["docker","container","prune","-f"]                    # stopped only
["docker","builder","prune","-f"]                      # build cache
# Volumes: ONLY if user explicitly enabled, and ONLY anonymous, one id at a time:
["docker","volume","rm","<anonymous-id>"]              # NEVER `volume prune`, NEVER named
```

**Safety rails (the core of this spec):**
- **Never** `docker system prune` (too broad — it can take volumes/networks). Compose the narrow
  per-object prunes instead.
- **Never** `docker volume prune` and **never** `-a`/`--all` on volumes — that would sweep named
  volumes. Volumes are removed only by explicit id, only when anonymous, only with typed
  confirmation, and only if `pruneAnonymousVolumes` is enabled (default **false**).
- The engine validates each mutating argv against the allow-list above before running it (a
  plugin-proposed command outside the list → exit 8 safety, spec 13 §9).
- All prunes run with `-f` (no interactive daemon prompt) *because* the tool already obtained
  consent at its own gate — the daemon prompt would be redundant, but the tool's confirmation is
  mandatory.
- Timeouts on mutating commands are generous (120 s) but bounded; cancellation aborts before the
  next object.

## 9. Edge cases & false-positive mitigations

| Edge case | Mitigation |
|---|---|
| Named volume looks unused | Named + unused is still 🔴 and **excluded by default**; only anonymous unused volumes are ever eligible. |
| Volume in use by a stopped container | Cross-reference `ps -a` mounts; a volume referenced by any container (even stopped) is not "unused." |
| Image is an offline base you can't re-pull | `pruneUnusedImages` defaults false; only dangling by default. |
| Daemon not running | Zero findings + note; never auto-start Docker. |
| Docker Desktop vs. Colima vs. Podman | v1 supports the `docker` CLI only; other engines are OQ-P.3. |
| Compose project mid-`up` | Running containers and their volumes are excluded (only exited/created + unused). |
| `Docker.raw` doesn't shrink post-prune | Reported honestly; not counted as host reclaim (Principle 3). |
| Concurrent `docker build` running | Build cache prune could remove in-flight cache; detect a running `buildx`/build via `ps` and defer build-cache prune with a warning. |

## 10. Test cases

Using a fake `ProcessRunning` returning canned JSON (no real Docker):

- **T1 daemon down** → zero findings, "Docker not running" note.
- **T2 two dangling images** → 🟡 findings; sizes from JSON.
- **T3 named volume `pgdata` unused** → **not** a Finding (excluded).
- **T4 anonymous unused volume, `pruneAnonymousVolumes=false`** → not a Finding.
- **T5 anonymous unused volume, opt-in true** → 🔴, typed confirm required.
- **T6 plugin proposes `docker system prune`** → engine rejects (not on allow-list) → exit 8.
- **T7 estimate** → sums `system df` Reclaimable, `confidence == .estimated`.
- **T8 build running** → build-cache prune deferred with warning.
- **T9 stopped container using a volume** → that volume not classified unused.

## 11. Config keys

`plugins.docker`:

| Key | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | bool | `true` | Master toggle. |
| `pruneDanglingImages` | bool | `true` | Remove `<none>` images. |
| `pruneAllUnusedImages` | bool | `false` | Also remove tagged-but-unused (re-pull risk). |
| `pruneStoppedContainers` | bool | `true` | Remove exited/created containers. |
| `pruneBuildCache` | bool | `true` | Remove BuildKit cache. |
| `pruneAnonymousVolumes` | bool | `false` | **Danger:** allow removing anonymous unused volumes (🔴, typed confirm). |
| `pruneNamedVolumes` | bool | `false` | **Hard-gated:** even true still requires per-volume typed confirm; strongly discouraged. |
| `dockerBinary` | string | `docker` | Path/name of the CLI (validated to exist). |

## Open Questions

- **OQ-docker.1** Use the Docker HTTP API over the unix socket instead of the CLI for structured,
  version-stable JSON and no argv parsing? *Leaning: CLI for v1 (simpler, respects user's Docker
  context); socket in v1.0 behind the same allow-list.*
- **OQ-docker.2** Should the informational `Docker.raw` size finding offer VM compaction guidance
  or ever attempt it? *Leaning: guidance only; never auto-compact in v1 (data-integrity risk).*
- **OQ-docker.3** How to safely detect an in-progress build across `buildx` builders to defer
  build-cache prune? *Leaning: `docker buildx ls` + active-build heuristic; conservative defer.*
- **OQ-docker.4** Named-volume handling: keep it entirely out (recommended) or allow an
  expert-mode per-id removal? *Leaning: out by default, expert per-id only, never a prune.*

## Dependencies

**Consumes:** 13 (`context.process`, propose-only, allow-list validation at gate ④), 14 (types;
`Recoverability.none` → DM-1 forces 🔴 for volumes), 16 (informational `Docker.raw` sizing only),
36 (process sandbox, argv escaping, timeouts). **Feeds:** 20 (executes allow-listed prune argv
under confirmation), 22 (scores), 25 (containers category grouping; separated 🔴 volumes block).
