# Configuration

`cleaner` reads an optional YAML config file at:

```
~/.cleaner/config.yml
```

Every key is optional. If the file is missing, built-in defaults are used. If
the file is present but invalid, the run stops with exit code `6`.

## Example

```yaml
version: 1

ignore:            # glob patterns; matching findings are dropped from results
  - "*Keep*"

whitelist:         # glob patterns the tool must never touch
  - "*/critical/*"

profiles:          # named selection presets, used via --profile <name>
  developer-daily:
    include:
      - dev.cleaner.xcode.deriveddata
      - dev.cleaner.swiftpm.cache
  aggressive:
    risky: true    # includes Medium items
```

## Keys

### `version`

Config schema version. Use `1`.

### `ignore`

A list of glob patterns. Any finding whose path matches is **dropped from the
results** — you won't see it and it won't be cleaned.

### `whitelist`

A list of glob patterns the tool must **never touch**. This is stronger than
`ignore`: whitelisted paths are protected from cleaning even if a profile or
flag would otherwise select them.

### `profiles`

Named selection presets, applied on the command line with `--profile <name>`.
Each profile can set:

- `include` — a list of plugin ids to include.
- `exclude` — a list of plugin ids to exclude.
- `risky: true` — include Medium items (equivalent to `--all`).

List saved profiles with:

```bash
cleaner profile list
```

## Precedence

Settings are layered, lowest to highest:

```
built-in defaults  <  config.yml  <  profile  <  CLI flags
```

CLI flags always win. An invalid config produces exit code `6`.

## Plugin ids

Sources are identified by plugin ids such as:

- `dev.cleaner.xcode.deriveddata`
- `dev.cleaner.swiftpm.cache`
- `dev.cleaner.browser.cache`

Use these ids with `--include`, `--exclude`, and profile `include`/`exclude`.
To see the id for any finding, run `cleaner --json` and look at the `plugin`
field of each item.

## Files under `~/.cleaner/`

| Path | Purpose |
| --- | --- |
| `~/.cleaner/staging/` | Quarantine for cleaned items (restored via `cleaner undo`). |
| `~/.cleaner/logs/` | Append-only NDJSON audit log. |
| `~/.cleaner/config.yml` | Your configuration. |
| `~/.cleaner/profiles` | Saved profiles. |
