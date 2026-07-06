# Command Reference

`cleaner` is a safe, native macOS disk-cleaner. It scans well-known cache and
temp locations, shows you what it found grouped by source, and reclaims space
only after you decide. Cleaned items are **moved to a recoverable staging
area**, not permanently deleted (see [safety.md](./safety.md)).

## `cleaner`

The primary command. Running it with no arguments:

1. Scans all sources.
2. Prints a grouped summary (by source, sizes right-aligned).
3. Asks:

```
Clean all <size>? [Y = all · s = select each · n = cancel]
```

| Answer | Result |
| --- | --- |
| `Y` / Enter | Clean **everything** found (moves it to staging). |
| `s` | Walk each source with a `clean? [y/N]` prompt, picking per-source. |
| `n` | Cancel without touching anything. |

```
cleaner
```

### Flags

| Flag | Description |
| --- | --- |
| `--yes` | Skip the prompt and clean everything found. Intended for automation/CI. |
| `--dry-run` | Preview only. Shows the summary plus a "NEXT STEPS" block and cleans nothing. |
| `--json` | Machine-readable JSON output, including a `schemaVersion` field. |
| `--md` | Markdown storage report, grouped by source, with columns `Source \| Reclaimable`. |
| `-v`, `--verbose` | Expand grouped sources into individual items. |
| `--no-color` | Disable ANSI colour. |
| `--include <ids>` | Comma-separated plugin ids to include. |
| `--exclude <ids>` | Comma-separated plugin ids to exclude. |
| `--profile <name>` | Apply a named profile from your config. |

### Examples

```bash
# Scan and decide interactively (all / select each / cancel)
cleaner

# Preview what would be reclaimed, change nothing
cleaner --dry-run

# Clean everything found, no prompt
cleaner --yes

# Emit JSON for tooling
cleaner --json

# Clean everything except browser caches
cleaner --yes --exclude dev.cleaner.browser.cache
```

To pick specific things, run `cleaner` and choose `s` (select each), then
answer `y`/`n` per source.

## `cleaner undo`

Restore a previous clean from staging. Restores are **byte-identical**.

```bash
cleaner undo               # restore the most recent clean
cleaner undo <session-id>  # restore a specific session
cleaner undo --list        # list what can be restored
cleaner undo --list --json # same, as JSON
```

## Detectors (`cleaner find`)

Read-only. These commands **list only and never delete**.

### `cleaner find large`

Find the largest files under Downloads, Desktop, Documents and Movies (or
given paths).

```bash
cleaner find large [--min 100MB] [--top 20] [PATH...]
```

| Flag | Description |
| --- | --- |
| `--min <size>` | Minimum file size to report (default `100MB`). |
| `--top <n>` | Show only the top N results (default `20`). |
| `PATH...` | One or more paths to scan instead of the defaults. |

### `cleaner find dupes`

Find byte-identical duplicate groups using SHA-256. Hardlink-aware.

```bash
cleaner find dupes [--min 1MB] [PATH...]
```

| Flag | Description |
| --- | --- |
| `--min <size>` | Minimum file size to consider (default `1MB`). |
| `PATH...` | One or more paths to scan. |

## Advanced commands

Hidden from the main help, but still runnable.

### `cleaner docker`

Show Docker reclaimable space via `docker system df`.

```bash
cleaner docker [--prune]
```

`--prune` runs **only safe prunes** (image, builder, container). It **never**
runs volume prunes or `docker system prune`.

### `cleaner brew`

Show a `brew cleanup` dry-run.

```bash
cleaner brew [--run]
```

`--run` performs the cleanup.

### `cleaner doctor`

Environment and health check.

```bash
cleaner doctor [--ci]
```

`--ci` maps health to exit codes: `0` healthy, `3` warnings, `1` critical.

### `cleaner profile list`

List saved profiles from your config.

```bash
cleaner profile list
```

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | OK |
| `2` | Usage error |
| `3` | Partial (some items failed or were skipped) |
| `4` | Permission (Full Disk Access required) |
| `5` | Cancelled |
| `6` | Config error |
| `8` | Safety (blocked a protected path) |

See [safety.md](./safety.md) for the safety model and [faq.md](./faq.md) for
common questions.
