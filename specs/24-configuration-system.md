# 24 — Configuration System

> **Phase F · Depends on:** 00-constitution (Art. 3/4/5/7/8, CC-5), 08-command-reference (`config`,
> global flags, env vars), 09-information-architecture, 10-tech-stack (Yams/ADR-0005), 18-rule-engine
> (custom rule + target/whitelist grammar), 13-plugin-architecture (per-plugin option schema) ·
> **Depended on by:** 17 (scan thresholds), 20 (cleanup/staging retention), 21 (staging), 22 (risk
> thresholds), 25 (theme/animation), 26 (CLI UX), 27 (config errors), 28 (log level), 29 (telemetry).
>
> The complete, normative specification of `~/.cleaner/config.yml`: its schema, the layered
> precedence model, validation and error surface (exit `6`), the `config` command family, profiles,
> environment-variable mapping, and versioned migration. RFC-2119 keywords are normative. Rule
> *syntax* (custom rules, target rules, glob grammar) is owned by **spec 18**; this spec owns only
> where those rules live in config and how they are validated and layered.

---

## 1. Purpose & principles

Configuration exists to let a user tune behavior **without weakening safety**. Every design choice
here serves Constitution principle 1 (safety over savings), 3 (truth in reporting), 6 (least
privilege), and 10 (privacy by default). Three invariants govern the whole system:

- **CFG-INV-1 — Safety is not configurable downward.** No key, layer, env var, or flag can remove a
  protected path (Article 5), raise a plugin's safety score above the scorer ceiling (Article 4.2),
  or auto-confirm 🔴 (Article 4.1). Keys that *could* weaken safety require `--force-unsafe` **and** a
  typed ack, and are recorded in the audit log (spec 28). See § 7.
- **CFG-INV-2 — Deterministic resolution.** Given the same layers, the resolved (effective) config is
  byte-identical across runs (principle 5 / NFR-031). Resolution order is fixed (§ 3) and observable
  via `config get --explain`.
- **CFG-INV-3 — Fail closed, fail loud.** An invalid config never silently degrades to defaults for
  the *whole* file. Parsing/validation failure aborts the command with exit `6` and a precise,
  located error (§ 5). A missing config file is **not** an error — built-in defaults apply.

---

## 2. File location, format, ownership

- **Path:** `~/.cleaner/config.yml` (Article 8). Overridable, in precedence order, by `--config
  <path>` (CC-2), the `CLEANER_CONFIG` env var, and the `CLEANER_HOME` env var (which relocates the
  whole `~/.cleaner` tree). If `--config` is given, `CLEANER_CONFIG` is ignored.
- **Format:** YAML 1.1 via **Yams** (CC-5 / ADR-0005). Comments (`#`) are preserved on `config edit`
  round-trips where feasible (§ 6.3). Anchors/aliases are permitted but resolved before validation.
- **Encoding:** UTF-8, LF line endings. A UTF-8 BOM is tolerated and stripped.
- **Permissions:** created `0600` (user-only). On load, if the file is group/world-writable the tool
  emits a `WARN` (spec 28) — a writable config is a safety surface — but does not refuse.
- **Absence:** if no file exists, the tool runs on built-in defaults and, on first `config set`/
  `config edit`, materializes a fully-commented file from the annotated template (§ 9).

---

## 3. Layered precedence (resolution model)

The **effective configuration** is computed by merging six layers. Later layers override earlier
ones on a **per-leaf-key** basis (a deep merge for maps; **replace, not append**, for scalars and —
by default — for lists; see § 3.1). Lowest → highest priority:

```
 ┌────────────────────────────────────────────────────────────────────────────┐
 │ 6  CLI flags            cleaner clean --no-color --include risk:safe  (win)  │  highest
 ├────────────────────────────────────────────────────────────────────────────┤
 │ 5  Environment vars     CLEANER_*  (§ 8)                                     │
 ├────────────────────────────────────────────────────────────────────────────┤
 │ 4  Active profile       --profile <name> / config default.profile (§ 6.5)   │
 ├────────────────────────────────────────────────────────────────────────────┤
 │ 3  Project config       ./.cleaner.yml (opt-in, --project / config flag)    │
 ├────────────────────────────────────────────────────────────────────────────┤
 │ 2  User config          ~/.cleaner/config.yml (or --config <path>)          │
 ├────────────────────────────────────────────────────────────────────────────┤
 │ 1  Built-in defaults    compiled-in, always present, always valid           │  lowest
 └────────────────────────────────────────────────────────────────────────────┘
   Safety floor (Article 4/5) is applied AFTER merge and cannot be raised by any layer.
```

- **Layer 1 (defaults)** is embedded in the binary, is always schema-valid, and is the fallback for
  every unspecified leaf. `config get <key>` on an unset key returns the default and labels its
  source `default`.
- **Layer 3 (project config)** is **opt-in** and off by default (a repo dropping a `.cleaner.yml`
  must not silently change a user's cleaning behavior — safety). It is consulted only when
  `--project` is passed, `CLEANER_PROJECT_CONFIG=1` is set, or `config.projectConfig.enabled: true`
  in the user config. Project config MAY tighten but MUST NOT loosen safety keys (§ 7); loosening
  keys in a project file are ignored with a `WARN`.
- **Layer 4 (profile)** applies a named profile's `plugins`/`options` subset (§ 6.5).
- The **safety floor** (deny-list, risk gates, score ceiling) is re-applied *after* all merging so no
  layer can escape it (CFG-INV-1).

### 3.1 List-merge semantics

Lists default to **replace** (a higher layer's list wins wholesale) to keep precedence obvious.
Three curated **append-lists** are the exception because users expect them to accumulate across
layers: `whitelist.paths`, `ignore.paths`, and `rules.custom`. For these the merge is **union with
de-duplication**, later layers first, canonical-path/rule-id as the identity key. A higher layer MAY
subtract from an append-list using the `!unset <value>` sentinel (§ 5.4). Blacklist/target rules
(`rules.targets`) are **replace** by design — additive cleaning targets must be explicit per layer.

### 3.2 Explainability

`cleaner config get <key> --explain` prints the resolved value and the full provenance chain:

```
$ cleaner config get scan.minLargeFileSize --explain
scan.minLargeFileSize = 500 MiB

  resolved from  env  CLEANER_SCAN_MIN_LARGE_FILE_SIZE=500MB
  would be       1 GiB            (built-in default)
  overridden at:
    2 user config    ~/.cleaner/config.yml:41   scan.minLargeFileSize: 2GiB
    5 env            CLEANER_SCAN_MIN_LARGE_FILE_SIZE=500MB   ← winner
  type: ByteSize   range: ≥ 0   unit: binary (KiB/MiB/GiB)
```

---

## 4. Schema (every key)

The schema is a typed tree. Notation: `type` `= default` — description. Types: `Bool`, `Int`,
`String`, `Enum{…}`, `ByteSize` (integer + binary/decimal unit, e.g. `500MB`, `2GiB`; bare integer =
bytes), `Duration` (`30d`, `12h`, `90m`), `Path` (tilde/`$VAR` expanded, canonicalized), `Glob`
(spec 18 grammar), `[T]` (list of `T`), `{K:V}` (map). Unknown top-level keys are an error (exit
`6`, "unknown key"); unknown keys **under** `plugins.<id>.options` are passed to the plugin, which
validates them (spec 13). Every key is dot-addressable by `config get/set` (`scan.minLargeFileSize`,
`plugins.docker.options.pruneVolumes`).

### 4.1 Top-level shape

```yaml
version:        Int                 # config schema version (§ 9). Required once written.
default:        DefaultsBlock       # default profile, scope, disposition
scan:           ScanBlock           # thresholds, concurrency, cache
safety:         SafetyBlock         # risk thresholds & gates (bounded — § 7)
staging:        StagingBlock        # retention, size caps
ignore:         IgnoreBlock         # paths never scanned (view-level exclude)
whitelist:      WhitelistBlock      # paths never acted on (protected, additive to Article 5)
rules:          RulesBlock          # custom rules + target (blacklist) rules — grammar per spec 18
plugins:        {String: PluginCfg} # per-plugin enable + options
ui:             UIBlock             # theme, animation, locale, output
telemetry:      TelemetryBlock      # OFF by default (spec 29)
logging:        LoggingBlock        # level, retention (spec 28)
projectConfig:  ProjectCfgBlock     # layer-3 opt-in switch
```

### 4.2 `default` — DefaultsBlock

```yaml
default:
  profile:      String?  = null       # profile applied when no --profile given (§ 6.5)
  disposition:  Enum{stage,trash,no-stage} = stage   # cannot be no-stage without ack (§ 7)
  scope:        Enum{home,all-volumes} = home        # default root set
  yesForSafe:   Bool  = false         # allow auto-confirm 🟢 without -y (still NEVER 🟡/🔴)
  confirmPhrase: String = "delete"    # typed-confirm word for 🔴 (Art. 4.1); localized-safe
```

### 4.3 `scan` — ScanBlock (thresholds, concurrency; feeds spec 17)

```yaml
scan:
  minLargeFileSize:  ByteSize = 1GiB    # `analyze` large-file threshold (FR-070; --min-size overrides)
  oldFileAge:        Duration = 180d    # `analyze --old` / age classifier cutoff (FR-005)
  minSavings:        ByteSize = 10MiB   # hide findings/opportunities below this (audit --min-savings)
  followSymlinks:    Bool     = false   # NEVER follows out of an allowed root regardless (Art. 4.4)
  crossVolume:       Bool     = false   # descend into other mounted volumes during a scan
  concurrency:
    mode:            Enum{auto,fixed} = auto   # auto = min(cores, IO-derived cap) (NFR-006)
    maxTasks:        Int?     = null    # used only when mode=fixed; 1..256
    ssdMultiplier:   Float    = 1.0     # tune parallelism on SSD volumes (spec 17 limiter)
    hddMultiplier:   Float    = 0.25    # throttle spinning/network volumes (NFR-012)
  cache:
    enabled:         Bool     = true    # incremental scan cache (FR-007; --no-cache overrides)
    maxAgeDays:      Duration = 7d      # invalidate cache entries older than this
    maxSize:         ByteSize = 200MiB  # cap ~/.cleaner/cache
```

### 4.4 `safety` — SafetyBlock (risk thresholds; **bounded**, feeds spec 22)

Only the *mappings* are tunable, and only **within** engine-enforced bounds. The score→risk cut
points may be raised (stricter) but **not** lowered past the Article 4.2 minimums; attempts clamp
with a `WARN`. See § 7 for the unsafe subset.

```yaml
safety:
  scoreSafeMin:    Int = 85   # >= → 🟢. May be raised to be stricter; MUST stay ≥ 85 (Art 4.2)
  scoreMediumMin:  Int = 50   # 50..84 → 🟡; < → 🔴. MUST stay ≥ 50 (raise-only)
  includeMedium:   Bool = false   # pre-select 🟡 by default? (still requires confirm; NEVER 🔴)
  requireTypedConfirmDangerous: Bool = true   # TRUE is a floor; setting false is rejected (§ 7)
  minRecoverability: Enum{instant,manual,hard,none} = manual
                                  # refuse to auto-select findings below this recoverability
  lockedFileMode:  Enum{skip,prompt} = skip   # in-use/locked file handling (Art 4.4)
```

### 4.5 `staging` — StagingBlock (retention; feeds spec 20/21)

```yaml
staging:
  retention:       Duration = 30d      # auto-purge staged sessions older than this (spec 21)
  maxSize:         ByteSize = 20GiB    # cap total staging; oldest sessions purged past cap (LRU)
  autoPurge:       Bool     = true     # run retention sweep at session end
  path:            Path     = "~/.cleaner/staging"  # relocatable; MUST stay on a writable volume
  onCrossVolume:   Enum{copy,skip} = copy  # when original & staging differ (NFR-005 fallback)
```

### 4.6 `ignore` — IgnoreBlock (view-level; never scanned)

`ignore.paths` are **not visited** during scan (a performance + noise control), distinct from
`whitelist` (visited for reporting but never acted on). Append-list (§ 3.1). Globs per spec 18.

```yaml
ignore:
  paths:   [Glob] = []          # e.g. ["~/Library/Containers/com.example.*", "**/node_modules/.cache"]
  hidden:  Bool   = false       # skip dotfiles/dirs entirely during scan (still deny-list-safe)
  vcsDirs: Bool   = true        # skip .git/.hg/.svn internals from size attribution noise
```

### 4.7 `whitelist` — WhitelistBlock (protected; never acted on)

User-declared protected paths, **added to** the non-overridable Article 5 deny-list (never
subtracted from it). Append-list. These paths appear in reports as `Protected` (spec 09 § 5).

```yaml
whitelist:
  paths:   [Glob] = []          # e.g. ["~/Projects/keep-forever/**", "~/.config/rclone/*"]
  apps:    [String] = []        # bundle-ids/app names whose caches are never targeted
```

### 4.8 `rules` — RulesBlock (custom + target rules; **grammar owned by spec 18**)

This spec fixes *where* rules live and *how they layer/validate*; the DSL (matchers, glob syntax,
risk assignment, actions) is normative in **spec 18**. `rules.custom` is an append-list keyed by
`id`; `rules.targets` (the "blacklist"/additional cleanable paths) is a replace-list per layer
(§ 3.1). Every custom/target rule is validated against the spec-18 grammar at load; a malformed
rule fails the whole file (exit `6`) with the rule `id` and line located.

```yaml
rules:
  custom:                      # additional detection rules (spec 18 §_matchers)
    - id:        my-cache-rule
      match:     "~/Library/Caches/com.acme.*"   # Glob (spec 18)
      category:  caches
      risk:      safe                             # may LOWER computed risk; MUST NOT raise (Art 4.2)
      recoverability: manual
      rationale: "Acme app regenerates on next launch"
  targets:                     # user-added cleanable paths ("blacklist" of junk)
    - id:        scratch-dir
      match:     "~/scratch/**"
      risk:      medium
      confirm:   true          # force confirmation even if scorer would call it safe
```

### 4.9 `plugins` — per-plugin config (feeds spec 13)

```yaml
plugins:
  <plugin-id>:
    enabled:  Bool = <plugin default>     # disable a plugin entirely
    risk:     Enum{safe,medium,dangerous}? = null   # OVERRIDE only stricter; raise-safety rejected
    options:  {String: Any} = {}          # plugin-specific; validated by the plugin (spec 13)
# example:
  docker:
    enabled: true
    options:
      pruneVolumes:      false     # dangerous — plugin marks 🔴; config can't auto-confirm it
      pruneBuildCache:   true
  derived-data:
    enabled: true
    options:
      keepActiveProjects: true     # skip DerivedData for projects opened in last 7d
```

### 4.10 `ui` — UIBlock (theme, language, animation; feeds spec 25/26)

```yaml
ui:
  theme:      Enum{default-dark,light,high-contrast,deuteranopia,protanopia,mono} = default-dark
  color:      Enum{auto,always,never} = auto   # `never` == NO_COLOR; auto = TTY-detect (spec 26)
  animation:  Bool = true          # spinners/animated bars; false honors reduced-motion (NFR-075)
  unicode:    Enum{auto,full,ascii} = auto     # ascii = no emoji/box-drawing (dumb terminals)
  language:   String = "auto"      # BCP-47; v1 ships "en" only, others fall back (NFR-080)
  byteUnits:  Enum{binary,decimal} = binary    # GiB vs GB (NFR-081); always labeled
  pager:      Enum{auto,always,never} = auto   # page long human output when stdout is a TTY
  tui:        Bool = true          # master switch; false == always linear (=$--no-tui)
```

### 4.11 `telemetry`, `logging`, `projectConfig`

```yaml
telemetry:                 # FULL schema in spec 29; OFF by default (CC-12, principle 10)
  enabled:      Bool = false     # local counters only; false = collect nothing
  network:      Bool = false     # SECOND opt-in required for any egress (spec 29 §_consent)
logging:                   # FULL schema in spec 28
  level:        Enum{trace,debug,info,notice,warning,error,critical} = info
  retentionDays: Duration = 14d
  redactPaths:  Bool = false     # hash user path components in exported logs/reports (NFR-062)
  audit:
    retentionDays: Duration = 90d   # audit NDJSON kept longer than app logs (Art 8, spec 28)
projectConfig:
  enabled:      Bool = false     # opt-in to layer 3 (./.cleaner.yml) globally
  filename:     String = ".cleaner.yml"
```

---

## 5. Validation & error surface (exit `6`)

Validation runs in four ordered phases; the **first** failing phase aborts with exit `6` (`config`)
and a single, precisely-located, remediation-bearing error (spec 27 style):

1. **Parse** — YAML syntax. Location = line:col from Yams.
2. **Structure** — unknown top-level keys, wrong types, out-of-range scalars, malformed
   `ByteSize`/`Duration`/`Glob`.
3. **Rule grammar** — `rules.custom`/`rules.targets` against spec-18 grammar.
4. **Cross-field & safety** — safety-floor clamps (§ 7), duplicate rule ids, references to unknown
   plugin ids, whitelist/target contradictions, staging path on a read-only volume.

Phase-3/4 *safety clamps* (e.g. `scoreSafeMin: 70`) are **not** fatal by default — they clamp to the
floor and emit a `WARN` — **unless** the value is a hard-forbidden setting (§ 7), which is fatal.

### 5.1 Error message format

```
error[CFG-021]: scan.minLargeFileSize is not a valid ByteSize
  ┌─ ~/.cleaner/config.yml:41:22
  │
41│   minLargeFileSize:  1 Gigabyte
  │                      ^^^^^^^^^^ expected an integer with an optional unit (KiB, MiB, GiB, KB, MB, GB)
  │
  = help: use `1GiB` (binary) or `1GB` (decimal); bare numbers are bytes
  = docs:  spec 24 §4.3
exit: 6 (config)
```

Every config error carries a stable `CFG-###` code (§ 5.5), a source location, the offending
snippet, one actionable `help:` line, and a `docs:` pointer. In `--json` the same surfaces as the
spec-27 error envelope with `exitReason: "config"`.

### 5.2 `config validate`

```
$ cleaner config validate ./team-config.yml
✔ syntax            YAML parsed
✔ structure         37 keys, 0 unknown
✔ rules             4 custom, 2 targets — grammar OK (spec 18)
⚠ safety            safety.scoreSafeMin 70 → clamped to 85 (raise-only floor, §7)
✔ cross-field       no duplicate ids; all plugin ids known
Result: VALID with 1 warning.        exit: 0
```

`config validate` on an **invalid** file prints the § 5.1 error and exits `6`. With `--json` it emits
`{ "valid": false, "errors": [...], "warnings": [...] }`. With `--strict`, warnings become errors
(exit `6`) — used in CI to gate team configs.

### 5.3 `config get` / `config set` / `config edit`

- **`config get <key> [--explain] [--json]`** — resolves through all layers (§ 3). Unknown key ⇒
  exit `2`. `--explain` prints provenance (§ 3.2).
- **`config set <key> <value> [--force-unsafe] [--global|--project]`** — validates the *single*
  edit against the schema, then **re-validates the whole resolved file** before persisting (spec 08
  §6). Writing an unsafe key (§ 7) without `--force-unsafe` ⇒ exit `2` with the ack prompt shown.
  Persists to the user config (layer 2) by default; `--project` targets `./.cleaner.yml`. Preserves
  surrounding comments (§ 6.3). Setting a value equal to the default offers to remove the key.
- **`config edit`** — opens `$VISUAL`/`$EDITOR` (fallback `nano`) on the config, then validates on
  save; if invalid, offers to reopen (loop) or discard, and **never** persists an invalid file
  (CFG-INV-3). A backup `config.yml.bak` is written before editing.

### 5.4 Sentinels & unset

`!unset` removes a leaf so a lower layer's value re-surfaces (useful in profiles/project files);
`!unset <value>` subtracts one entry from an append-list (§ 3.1); `!default` resets a key to the
built-in default explicitly.

### 5.5 Error-code ranges

`CFG-0xx` parse/structure · `CFG-1xx` type/range · `CFG-2xx` value format (ByteSize/Duration/Glob) ·
`CFG-3xx` rule grammar (delegated to spec 18 `RULE-###`, surfaced under `CFG-3xx`) · `CFG-4xx`
cross-field/safety · `CFG-5xx` migration/version. Codes are stable across releases (spec 27).

---

## 6. Profiles

A **Profile** (Article 3) is a named, saved subset of `plugins` selection + `options` + a curated
slice of `scan`/`safety`/`default` keys, stored as `~/.cleaner/profiles/<name>.yml`. Profiles layer
**above** the user config (layer 4, § 3) and **below** env/flags.

### 6.1 Built-in profiles (read-only, shipped)

| Name | Intent | Selection | Notable overrides |
|---|---|---|---|
| `conservative` | Only the safest wins | `risk:safe` plugins | `safety.includeMedium: false`, disposition `stage` |
| `developer-daily` | Dev caches/artifacts | Developer category + Trash/Temp | `derived-data.keepActiveProjects: true` |
| `aggressive` | Maximum reclaim (still safe-gated) | all enabled, `includeMedium: true` | still NEVER auto-🔴 (Art 4.1) |

Built-ins are immutable; `profile save <builtin>` ⇒ exit `2`. A user may `profile show conservative`
then `profile save my-conservative` to fork.

### 6.2 Profile file shape

```yaml
# ~/.cleaner/profiles/my-weekly.yml
version: 1
name: my-weekly
description: "Weekly dev cleanup, medium included"
plugins: [derived-data, swiftpm, npm-cache, docker, browser-cache]
include: [risk:safe, risk:medium]      # selector grammar (spec 08 §2)
exclude: [plugin:docker.volumes]
options:
  docker: { pruneBuildCache: true }
overrides:                              # curated allow-set of config keys a profile may set
  safety.includeMedium: true
  staging.retention: 14d
```

A profile MAY override only keys in the **profile-allowed set** (`plugins.*`, `scan.*`,
`safety.includeMedium`, `safety.minRecoverability`, `staging.*`, `default.disposition`,
`ui.*`); it MUST NOT set telemetry, whitelist/deny, or any unsafe key (§ 7). Violations ⇒ exit `6`.

### 6.3 Comment & formatting preservation

`config set` and `profile save` round-trip through Yams' node API to preserve comments, key order,
and blank lines on the edited branch; unrelated branches are byte-preserved. Full reserialization is
a fallback only when structure changed incompatibly, and then the header comment block is retained.

### 6.4 Applying a profile

`--profile <name>` (flag) > `CLEANER_PROFILE` (env) > `default.profile` (config). `profile show
<name> --resolved` prints the effective config *as if* that profile were active (for review before a
`--yes` run).

---

## 7. The unsafe subset (safety cannot be configured down)

Certain keys can only be **tightened**, and a small set are **hard-forbidden** from being weakened at
all. This realizes CFG-INV-1 and Constitution Article 4/5.

| Key | Allowed direction | Weakening attempt result |
|---|---|---|
| `safety.scoreSafeMin` / `scoreMediumMin` | raise only (stricter) | clamp to floor + `WARN` |
| `safety.requireTypedConfirmDangerous` | must stay `true` | **fatal** exit `6` (`CFG-410`) |
| `safety.minRecoverability` | tighten only | clamp + `WARN` |
| `plugins.<id>.risk` | raise risk only (safe→medium→dangerous) | reject raise-to-safer + `WARN` |
| `default.disposition: no-stage` | requires `--force-unsafe` + typed ack | prompt; refuse in `--ci`/`--json` w/o signed policy (Art 4.4, spec 23) |
| `whitelist` subtraction of an Article-5 path | impossible | ignored + `WARN` (deny-list is absolute) |
| `rules.*.risk` raising above scorer ceiling | impossible | clamp to ceiling + `WARN` (Art 4.2) |
| `default.yesForSafe` | allowed (🟢 only) | n/a — never affects 🟡/🔴 |

`config set` of a **fatal** unsafe key without `--force-unsafe` prints the ack prompt and the exact
consequence, and exits `2`. With `--force-unsafe`, an interactive typed ack (or a signed policy in
automation, spec 23) is still required, and the change is written to the **audit log** (spec 28) with
the old/new value and session UUID.

---

## 8. Environment-variable mapping

`CLEANER_*` env vars (layer 5) override config for one process. Two forms exist:

**Named vars (stable, documented in spec 08 § 2):**

| Env var | Overrides | Notes |
|---|---|---|
| `CLEANER_HOME` | the whole `~/.cleaner` tree root | relocation; affects all sub-paths |
| `CLEANER_CONFIG` | config file path | ignored if `--config` given |
| `CLEANER_PROFILE` | `default.profile` | profile name |
| `CLEANER_LOG_LEVEL` | `logging.level` | `trace…critical` |
| `NO_COLOR` (any value) | `ui.color: never` | external standard; also disables SGR (NFR-071) |
| `CLEANER_PROJECT_CONFIG` | `projectConfig.enabled` | `1`/`true` opts into layer 3 |
| `CLEANER_NO_ANIMATION` | `ui.animation: false` | reduced-motion hook (NFR-075) |

**Generic mapping** (any leaf key): `CLEANER_<PATH>` where the dotted key is upper-snake-cased
(`scan.minLargeFileSize` → `CLEANER_SCAN_MIN_LARGE_FILE_SIZE`). Values parse with the same
`ByteSize`/`Duration`/`Bool`/`Enum` grammar as the file; a parse failure is exit `6` located at the
env var name. The generic mapping is **subject to the same unsafe-subset rules** (§ 7): an env var
cannot weaken safety either. Precedence within layer 5: a named var wins over its generic equivalent.

```
CLEANER_SCAN_MIN_LARGE_FILE_SIZE=500MB \
CLEANER_UI_THEME=high-contrast \
CLEANER_LOG_LEVEL=debug \
  cleaner analyze ~/Developer
```

---

## 9. Versioning & migration

`config.version` (Int) records the schema generation the file was written for. v1 = `1`.

- **On load,** if `file.version < CURRENT`, the tool runs an in-memory **migration chain**
  (`m1→2`, `m2→3`, …), each a pure function `(YAML, warnings) → YAML`. Migrations rename/relocate
  keys, apply new defaults, and never lose user data (unknown-but-preserved keys are carried).
- **Persisting** a migrated config is **explicit**: the tool does not silently rewrite the user's
  file. On the next `config set`/`config edit`, or via `config migrate`, the upgraded file is written
  with a `config.yml.v<old>.bak` backup and a summary of changes.
- **If `file.version > CURRENT`** (config from a newer binary): the tool refuses with exit `6`
  (`CFG-500`) and advises upgrading `cleaner` — it will not guess at unknown semantics (fail closed).
- **Unknown top-level keys** from a future version are preserved on round-trip but reported as
  `WARN` (they are not honored by the current binary).

```
$ cleaner config migrate
Config at ~/.cleaner/config.yml is version 1; current is 2.
Migration 1→2:
  • renamed  scan.maxConcurrency  →  scan.concurrency.maxTasks
  • added    staging.maxSize (default 20GiB)
  • kept     3 unknown keys under plugins.experimental.* (WARN)
Backup written: ~/.cleaner/config.yml.v1.bak
✔ Migrated and validated.        exit: 0
```

---

## 10. Fully annotated example `config.yml`

```yaml
# ~/.cleaner/config.yml — cleaner-cli configuration
# Docs: spec 24. Precedence: defaults < this file < profile < CLEANER_* env < CLI flags.
# Safety (Article 4/5) is a FLOOR: nothing here can delete a protected path,
# auto-confirm a 🔴 Dangerous item, or make a plugin "safer" than the scorer allows.

version: 1

# ── Defaults applied when you don't pass flags ───────────────────────────────
default:
  profile: developer-daily     # applied when no --profile is given (null = none)
  disposition: stage           # stage (recoverable) | trash | no-stage (needs ack, §7)
  scope: home                  # home | all-volumes
  yesForSafe: false            # auto-confirm 🟢 only; NEVER 🟡/🔴 regardless
  confirmPhrase: delete        # what you type to confirm a 🔴 Dangerous clean

# ── Scan thresholds & performance (spec 17) ──────────────────────────────────
scan:
  minLargeFileSize: 1GiB       # `analyze` flags files ≥ this (override: --min-size)
  oldFileAge: 180d             # "old file" cutoff (override: --old <days>)
  minSavings: 10MiB            # hide findings smaller than this
  followSymlinks: false        # never followed OUT of an allowed root regardless
  crossVolume: false
  concurrency:
    mode: auto                 # auto = min(cores, IO cap); or fixed + maxTasks
    ssdMultiplier: 1.0
    hddMultiplier: 0.25        # throttle spinning/network volumes
  cache:
    enabled: true              # incremental scan cache (override: --no-cache)
    maxAgeDays: 7d
    maxSize: 200MiB

# ── Risk thresholds — RAISE-ONLY (stricter). Lowering is clamped (§7). ────────
safety:
  scoreSafeMin: 85             # ≥ → 🟢 (must stay ≥ 85)
  scoreMediumMin: 50           # 50–84 → 🟡, below → 🔴 (must stay ≥ 50)
  includeMedium: false         # pre-select 🟡? (still needs confirmation)
  requireTypedConfirmDangerous: true   # MUST remain true (setting false is rejected)
  minRecoverability: manual    # don't auto-select anything less recoverable than this
  lockedFileMode: skip         # skip | prompt for in-use files

# ── Staging / quarantine (spec 21) ───────────────────────────────────────────
staging:
  retention: 30d               # auto-purge staged sessions older than this
  maxSize: 20GiB               # LRU-purge oldest sessions past this cap
  autoPurge: true
  # path: ~/.cleaner/staging   # relocate (must be a writable volume)

# ── Never SCANNED (perf/noise). Different from whitelist (never ACTED on). ────
ignore:
  paths:
    - "**/node_modules/.cache"
    - "~/Library/Containers/com.example.noisyapp.*"
  hidden: false
  vcsDirs: true

# ── Never ACTED ON — added to the built-in protected deny-list (Article 5) ───
whitelist:
  paths:
    - "~/Projects/keep-forever/**"
    - "~/.config/rclone/*"
  apps:
    - com.acme.CriticalTool

# ── Custom detection rules (+) and target/"blacklist" rules. Grammar: spec 18 ─
rules:
  custom:
    - id: acme-cache
      match: "~/Library/Caches/com.acme.*"
      category: caches
      risk: safe               # may only LOWER computed risk, never raise it
      recoverability: manual
      rationale: "Acme regenerates on next launch"
  targets:                     # extra things YOU consider junk
    - id: scratch
      match: "~/scratch/**"
      risk: medium
      confirm: true

# ── Per-plugin config (spec 13). options are validated by each plugin. ────────
plugins:
  derived-data:
    enabled: true
    options: { keepActiveProjects: true }
  docker:
    enabled: true
    options:
      pruneBuildCache: true
      pruneVolumes: false      # plugin marks this 🔴; config can't auto-confirm it
  browser-cache:
    enabled: true

# ── Look & feel (spec 25/26) ─────────────────────────────────────────────────
ui:
  theme: default-dark          # default-dark|light|high-contrast|deuteranopia|protanopia|mono
  color: auto                  # auto|always|never (NO_COLOR forces never)
  animation: true              # false = reduced-motion (discrete % instead of spinners)
  unicode: auto                # auto|full|ascii
  language: auto               # v1 ships en; others fall back to en
  byteUnits: binary            # binary (GiB) | decimal (GB) — always labeled
  pager: auto
  tui: true

# ── Privacy: telemetry is OFF by default and local-only (spec 29, CC-12) ──────
telemetry:
  enabled: false               # collect nothing
  network: false               # a SECOND opt-in is required for any egress

# ── Logging & audit (spec 28) ────────────────────────────────────────────────
logging:
  level: info                  # trace|debug|info|notice|warning|error|critical
  retentionDays: 14d
  redactPaths: false           # hash user path components in EXPORTED logs/reports
  audit:
    retentionDays: 90d         # append-only NDJSON of every mutation, kept longer

# ── Layer-3 project config (./.cleaner.yml) — opt-in, off by default ─────────
projectConfig:
  enabled: false
  filename: .cleaner.yml
```

---

## Open Questions

- **OQ-24.1** Project config (layer 3): scan up the directory tree for `.cleaner.yml` (git-style) or
  only the CWD? *Leaning: CWD only in v1 to avoid surprise; ancestor search behind a flag in 1.x.*
- **OQ-24.2** Should the generic env mapping (`CLEANER_<KEY>`) be enabled by default, or require
  `CLEANER_ALLOW_ENV_KEYS=1` to reduce accidental overrides in shared shells? *Leaning: enabled but
  documented; named vars cover the common cases.*
- **OQ-24.3** Comment preservation on `config set` — is Yams' node round-trip sufficient, or do we
  need a thin CST layer for guaranteed fidelity? *Leaning: Yams node API; CST only if snapshot tests
  (spec 31) show loss.*
- **OQ-24.4** Do profiles get their own `version`/migration chain, or ride the config version?
  *Leaning: share the config version to avoid a second migration surface.*
- **OQ-24.5** `--strict` validation in CI: should `config validate --strict` also fail on *deprecated*
  (still-honored) keys, or only on warnings? Coordinate with § 9. *Leaning: deprecations = warnings,
  `--strict` promotes them.*

## Dependencies

- **Consumes:** 00 (Art. 3 glossary, Art. 4 risk/score, Art. 5 deny-list, Art. 7 exit `6`, Art. 8
  layout, CC-5 Yams), 08 (`config`/`profile` surface, global flags, env vars, `--force-unsafe`), 09
  (terminology, categories), 10 (Yams/ADR-0005), 18 (rule/glob grammar for `rules.*`, `ignore`,
  `whitelist`), 13 (per-plugin option schema & validation).
- **Feeds:** 17 (scan thresholds/concurrency/cache), 20 & 21 (staging retention/size/disposition),
  22 (risk-threshold bounds), 25 (theme/animation/unicode/locale), 26 (color/pager/output policy),
  27 (config error taxonomy CFG-###), 28 (log level/retention/redaction/audit retention), 29
  (telemetry keys & consent), 31 (config parse/validate/migration snapshot tests), 23 (signed policy
  for unsafe keys under automation).
