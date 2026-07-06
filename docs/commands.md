# Command Reference

`cleaner` is a safe, native macOS disk-cleaner. It scans well-known cache and
temp locations, shows you what it found grouped by source, and reclaims space
only after you confirm. Cleaned items are **moved to a recoverable staging
area**, not permanently deleted (see [safety.md](./safety.md)).

## `cleaner`

The primary command. Running it with no arguments:

1. Scans all sources.
2. Prints a grouped summary (by source, sizes right-aligned, risk-coloured).
3. Asks `Reclaim X? [Y/n]`.

Pressing Enter or `y` cleans the **Safe (🟢)** items by moving them to staging.
Pressing `n` aborts without touching anything.

```
cleaner
```

### Flags

| Flag | Description |
| --- | --- |
| `--dry-run` | Preview only. Shows the summary plus a "NEXT STEPS" block and cleans nothing. |
| `--yes` | Skip the prompt and auto-clean Safe items. Intended for automation/CI. |
| `--all` | Also clean **Medium (🟡)** items (browser/app caches, logs, DeviceSupport). Never touches Dangerous (🔴). |
| `--json` | Machine-readable JSON output, including a `schemaVersion` field. |
| `--md` | Markdown storage report, grouped by source, with a Risk column. |
| `-v`, `--verbose` | Expand grouped sources into individual items. |
| `--no-color` | Disable ANSI colour. |
| `--include <ids>` | Comma-separated plugin ids to include. |
| `--exclude <ids>` | Comma-separated plugin ids to exclude. |
| `--profile <name>` | Apply a named profile from your config. |

### Examples

```bash
# Preview what would be reclaimed, change nothing
cleaner --dry-run

# Clean Safe items without a prompt
cleaner --yes

# Clean Safe + Medium items after confirmation
cleaner --all

# Emit JSON for tooling
cleaner --json

# Clean everything except browser caches
cleaner --all --exclude dev.cleaner.browser.cache
```

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
cleaner docker [--prune] [--yes]
```

`--prune` runs **only safe prunes** (image, builder, container). It **never**
runs volume prunes or `docker system prune`.

### `cleaner brew`

Show a `brew cleanup` dry-run.

```bash
cleaner brew [--run] [--yes]
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
