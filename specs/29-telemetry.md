# 29 — Telemetry (opt-in, off by default)

> **Phase F · Depends on:** 00-constitution (principle 10 privacy, CC-12 telemetry off/local-only,
> Art. 8 layout), 07 (NFR-060…063 privacy: no egress by default, inspectable payload), 08 (`--json`,
> `--print-telemetry`), 10 (swift-metrics no-op backend, ADR-0006/0012), 24 (`telemetry.*` config),
> 28 (redaction, no-egress, session UUID) · **Depended on by:** 31 (privacy/egress tests), 35/36
> (security & threat review).
>
> The telemetry design. **Telemetry is OFF by default and collects nothing** (Constitution principle
> 10, CC-12, NFR-060). This spec describes what *could* be collected **if** a user explicitly opts
> in, the two-stage consent flow, the strict local-only default, data minimization, how a user
> inspects/exports/deletes their data, the config keys, and the privacy guarantees. It is written
> conservatively and privacy-first: when in doubt, collect nothing. RFC-2119 keywords are normative.

---

## 1. Privacy stance (non-negotiable)

- **TEL-INV-1 — Off by default, collects nothing.** With default config, the tool records **zero**
  telemetry and makes **zero** network calls, ever (NFR-060). The metrics backend is a no-op
  (spec 10 §8). This is not configurable to "on" implicitly — it requires an explicit act (§ 3).
- **TEL-INV-2 — Two independent opt-ins.** *Collecting* local telemetry (`telemetry.enabled`) and
  *sending* it anywhere (`telemetry.network`) are **separate** consents. Enabling collection never
  enables egress. Egress requires a **second**, explicit opt-in (CC-12, § 3.2).
- **TEL-INV-3 — Never paths, filenames, or contents.** No telemetry payload — local or transmitted —
  contains a path, filename, hostname, username, volume name, plugin *option values*, or any file
  data (NFR-062/063). Only anonymous aggregate counters (§ 4).
- **TEL-INV-4 — Inspectable before it exists and before it leaves.** A user can see the exact payload
  (`--print-telemetry`) before any send, and browse everything stored locally (§ 6). No hidden fields.
- **TEL-INV-5 — Fully revocable & erasable.** Opt-out stops collection immediately; a single command
  erases all stored telemetry (§ 6). Revocation is honored without residue.
- **TEL-INV-6 — No dark patterns.** Consent copy is neutral, states exactly what's collected, defaults
  to *no*, and never nags. Declining is frictionless and remembered.

Telemetry exists to help the project understand *aggregate* usage (which plugins help, how much space
users reclaim, where errors cluster) — **only** from users who deliberately choose to share, and
even then, by default, only on their own machine.

---

## 2. Layered model: local-only vs egress

```
 ┌─────────────────────────────────────────────────────────────────────────┐
 │ DEFAULT (no config)                                                       │
 │   collect: NOTHING      store: NOTHING      send: NOTHING   (no-op sink)  │  ← TEL-INV-1
 ├─────────────────────────────────────────────────────────────────────────┤
 │ OPT-IN #1  telemetry.enabled: true                                        │
 │   collect: aggregate counters (§4)                                        │
 │   store:   ~/.cleaner/telemetry/*.ndjson  (LOCAL ONLY)                     │
 │   send:    NOTHING          ← egress still OFF                             │  ← local-only
 ├─────────────────────────────────────────────────────────────────────────┤
 │ OPT-IN #2  telemetry.network: true   (requires #1, separate consent)      │
 │   send:    the SAME aggregate payload, batched, over HTTPS to the         │
 │            configured endpoint, after --print-telemetry-style disclosure  │  ← egress (rare)
 └─────────────────────────────────────────────────────────────────────────┘
```

The **common recommended** state for a privacy-conscious user who still wants to self-inspect is
**opt-in #1 only**: telemetry is collected and kept **on their machine**, useful for their own
`report`/insight, and never transmitted. Egress (#2) is a deliberate, separate, rare step.

---

## 3. Consent flow

### 3.1 First opt-in (collection, local-only)

Telemetry is enabled only by an explicit user act: `cleaner config set telemetry.enabled true`, an
interactive `telemetry enable` prompt, or editing config. The tool **never** prompts unsolicited on
first run (no nag; TEL-INV-6). When enabled interactively, it shows exactly what will be collected and
confirms with a default-**no** prompt:

```
$ cleaner telemetry enable
Telemetry is OFF by default. If you turn it on, cleaner will record — ON THIS MACHINE ONLY —
anonymous aggregate counters to help improve the tool. It will NOT record:
  • file paths, names, or contents      • usernames, hostnames, volume names
  • your config values or selections     • anything that identifies you

It WILL record (see the full list: cleaner telemetry schema):
  • counts of runs per command           • total bytes reclaimed (aggregate)
  • which plugins ran + succeeded/failed  • error codes (no messages/paths)
  • app version, macOS major version, arch

Nothing is sent anywhere. Enabling collection does NOT enable sending.
Turn on LOCAL telemetry collection?  [y/N] ▏
```

### 3.2 Second opt-in (egress)

Sending anything off-machine requires a **separate** consent, gated on collection already being on:

```
$ cleaner telemetry enable --network
LOCAL telemetry is on. This second step would allow cleaner to SEND the aggregate payload
over HTTPS to:  https://telemetry.example.org/v1/ingest    (configurable; no third-party analytics)

Before every send you can inspect the exact bytes:  cleaner telemetry preview
Sending is batched, rate-limited, and can be revoked anytime:  cleaner telemetry disable --network

Enable SENDING aggregate telemetry?  Type  send  to confirm, or Esc to cancel: ▏
```

Egress uses a **typed** confirmation because it's the only path that leaves the
machine. In `--ci`/`--json`/`--no-input`, egress can be enabled **only** via config set with a signed
policy (spec 23) — never silently. The endpoint is configurable and defaults to a first-party,
documented ingest URL; there is **no** third-party analytics SDK (principle 10, NFR-054).

---

## 4. What is collected (if opted in)

Only anonymous, aggregate counters and low-cardinality dimensions. The **complete** collectible set
(`cleaner telemetry schema` prints this verbatim):

| Metric | Type | Example | Notes |
|---|---|---|---|
| `run.count` | counter | `{command:"clean"}` | per command; dimension is the fixed verb set only |
| `run.durationMs` | histogram | `1843` | bucketed; no timestamps that could fingerprint |
| `run.exitCode` | counter | `{code:3}` | Article-7 codes only |
| `reclaim.bytes` | counter | `12884901888` | **aggregate** bytes reclaimed; never per-item, never a path |
| `reclaim.itemCount` | counter | `40` | count only |
| `plugin.ran` | counter | `{plugin:"docker"}` | plugin **id** only (a fixed, public set), never options/values |
| `plugin.outcome` | counter | `{plugin:"docker",outcome:"skipped"}` | succeeded/skipped/failed |
| `error.code` | counter | `{code:"plugin.adapterTimeout"}` | `CleanerError.code` only — **no** message, **no** path (spec 27) |
| `disposition` | counter | `{kind:"stage"}` | stage/trash/purge counts |
| `env.appVersion` | dimension | `"1.0.0"` | tool version |
| `env.osMajor` | dimension | `"14"` | macOS **major** only (not minor/build — too identifying) |
| `env.arch` | dimension | `"arm64"` | arm64/x86_64 |
| `feature.tui` | counter | `{used:true}` | TUI vs plain, coarse |

**Explicitly excluded, always:** paths, filenames, extensions, hashes of files, volume/model/serial,
username, hostname, IP, MAC, install id that persists across reinstalls, config contents, rule text,
whitelist/blacklist entries, plugin option values, error *messages*, timestamps finer than a day
bucket. Dimensions are **low-cardinality closed sets** (the command verbs, the shipped plugin ids, the
Article-7 codes, arch) so no free-form string can leak identity (data minimization, NFR-063).

There is **no** persistent user identifier. A transmitted batch carries at most a random per-batch id
(discarded after ingest) and never a stable device/user id (§ 5).

---

## 5. Storage, batching, and transport

- **Storage (local):** counters accumulate in-memory during a run and flush to
  `~/.cleaner/telemetry/pending/<session>.ndjson` at session end (Article 8), `0600`. Aggregation is
  additive; the file is human-readable NDJSON identical to what would be sent (TEL-INV-4).
- **swift-metrics** feeds these counters when `telemetry.enabled`; otherwise the backend is a **no-op**
  (NFR-114, spec 10 §8) — zero cost, zero storage.
- **No stable id.** Each transmit batch gets a fresh random UUID used only to de-dup a single upload;
  it is not stored and not linkable across batches. No cross-run correlation id leaves the machine
  (the local `session` UUID from spec 28 is **stripped** from any egress payload).
- **Batching & rate-limit (egress only):** batches are aggregated (e.g. daily), size-capped, and rate-
  limited; a failed send is retried with backoff and **never blocks or delays** a cleaning run
  (privacy path is fully off the hot path; failures are silent `debug` logs). No send ever happens
  during the core cleaning path (principle 10).
- **Transport:** HTTPS `POST` of the exact previewed JSON to the configured endpoint; TLS-verified;
  no cookies, no third-party SDK, no redirect-following to other hosts. The request body is the
  aggregate payload and nothing else; standard HTTP headers only (no custom fingerprinting headers).

---

## 6. Inspect, export, delete (user control)

The `telemetry` command family gives full control (TEL-INV-4/5):

| Command | Effect |
|---|---|
| `cleaner telemetry status` | shows both opt-in states, endpoint, pending/sent counts, storage size |
| `cleaner telemetry schema` | prints the complete collectible field list (§ 4) — the honest catalog |
| `cleaner telemetry preview` / `--print-telemetry` | prints the **exact** payload that would be sent, pretty JSON, before any send (NFR-063) |
| `cleaner telemetry export --output <path>` | writes all locally stored telemetry to a file the user chooses |
| `cleaner telemetry delete` | erases `~/.cleaner/telemetry/**` (pending + sent history) immediately |
| `cleaner telemetry enable [--network]` | opt-in #1 / #2 (§ 3), typed confirm for `--network` |
| `cleaner telemetry disable [--network]` | revoke; `--network` disables only egress, keeps local collection |

`--print-telemetry` is also a global flag (spec 08) so a user can inspect on any run. `status` and
`preview` never trigger a send.

```
$ cleaner telemetry status
Telemetry
  collection (local):  ON      since 2026-06-01
  sending (network):   OFF
  endpoint:            (n/a — sending disabled)
  stored locally:      ~/.cleaner/telemetry  ·  3 pending batches  ·  41 KiB
  never collected:     paths · filenames · contents · username · hostname · config values
  inspect:  cleaner telemetry preview     erase:  cleaner telemetry delete
```

```
$ cleaner telemetry preview
{
  "payloadVersion": "1.0.0",
  "window": "2026-07-06",                       // day bucket, not a precise time
  "batchId": "ephemeral-9c2e…",                 // random per-batch, not stored, not linkable
  "env": { "appVersion": "1.0.0", "osMajor": "14", "arch": "arm64" },
  "runs":     { "clean": 4, "analyze": 11, "audit": 2 },
  "exitCodes":{ "0": 15, "3": 2 },
  "reclaim":  { "bytes": 51539607552, "items": 210 },
  "plugins":  { "derived-data": {"ran":4,"failed":0}, "docker": {"ran":3,"skipped":1} },
  "errors":   { "plugin.adapterTimeout": 1 },
  "disposition": { "stage": 4 },
  "feature":  { "tui": 12, "plain": 5 }
}
// No paths, no names, no identifiers. This is the entire payload.
```

---

## 7. Config keys (spec 24 §4.11)

```yaml
telemetry:
  enabled:   false     # opt-in #1: collect aggregate counters LOCALLY. Default false. (TEL-INV-1)
  network:   false     # opt-in #2: SEND them. Requires enabled:true. Default false. (TEL-INV-2)
  endpoint:  ""        # egress URL; empty = none. Must be https://. First-party only. (§5)
  window:    daily     # aggregation bucket: daily|weekly (coarser = more private)
  # No user id, no salt, no persistent identifier keys exist by design.
```

- Setting `network: true` while `enabled: false` is a **config error** (exit `6`, `CFG-4xx`): egress
  without collection is nonsensical and the schema enforces the dependency (spec 24 §5.4).
- Setting `network: true` via `config set` prints the § 3.2 disclosure and requires the typed ack (or
  a signed policy in automation); the change is recorded in the audit log (spec 28).
- `NO_COLOR`-style overrides don't apply here; there is **no** env var that can silently enable
  telemetry — it is config/consent only (defense against a shared-shell foot-gun).

---

## 8. Privacy guarantees (summary, verifiable)

| Guarantee | Mechanism | Verified by |
|---|---|---|
| No collection by default | no-op metrics backend, `enabled:false` | `T-metrics-noop` (spec 31/NFR-114) |
| No network by default (and rarely ever) | no HTTP in core path; egress gated on `network:true` | `T-no-egress` network sandbox (NFR-060) |
| Payload inspectable pre-send | `--print-telemetry`/`preview` prints exact bytes | `T-telemetry-payload` (NFR-063) |
| No paths/names/contents | closed-set dimensions; export redaction reused (spec 28 §11) | `T-telemetry-no-pii` |
| No stable identifier | ephemeral per-batch id only; session UUID stripped on egress | review + `T-telemetry-anon` |
| Fully revocable & erasable | `telemetry disable` / `delete` remove all residue | `T-telemetry-erase` |
| Two independent opt-ins | schema dependency + separate typed consent | `T-telemetry-consent` |

All guarantees are testable (spec 31) and reviewed in the security review (spec 35) and threat model
(spec 36). The default build ships with `enabled:false`, `network:false`, `endpoint:""`.

---

## Open Questions

- **OQ-29.1** Do we ship telemetry at all in v1, or defer the *egress* half to v2 and ship only the
  local-collection + inspection surface first? *Leaning: ship local-only (#1) + full inspection in
  v1; keep egress (#2) behind config, endpoint empty by default, and validate it in beta before
  documenting a public endpoint.*
- **OQ-29.2** Aggregation window default — `daily` vs `weekly`? Coarser is more private but less
  useful. *Leaning: daily buckets, no finer than a day, never wall-clock times.*
- **OQ-29.3** Should `reclaim.bytes` be bucketed (order-of-magnitude) rather than exact, to further
  reduce fingerprinting from an unusual value? *Leaning: exact aggregate is fine (it's a sum across
  runs); revisit if threat model (spec 36) flags it.*
- **OQ-29.4** Where does the (v2) tamper/authenticity story for egress live — signed payloads, or
  trust-the-TLS-endpoint? *Leaning: TLS only in v1's optional egress; defer signing to v2.*
- **OQ-29.5** Should a first successful `clean` show a one-time, dismissible pointer to `telemetry
  enable` (informational, not a prompt), or stay completely silent until asked? *Leaning: a single
  non-blocking one-liner max, respecting TEL-INV-6; err toward silence.*

## Dependencies

- **Consumes:** 00 (principle 10 privacy, CC-12 off/local-only, Art. 8 layout), 07 (NFR-060…063
  privacy targets), 08 (`--json`, `--print-telemetry`, `telemetry` command surface, exit `6`), 10
  (swift-metrics no-op backend, ADR-0006/0012), 24 (`telemetry.*` config keys + schema dependency),
  28 (redaction, no-egress infrastructure, session-UUID stripping), 23 (signed policy for enabling
  egress under automation).
- **Feeds:** 31 (no-egress, payload, anonymity, consent, erase tests), 35 (security review of the
  egress path), 36 (threat model: fingerprinting, endpoint trust).
