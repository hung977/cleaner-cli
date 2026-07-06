# Safety Model

`cleaner` is designed so that a normal run can never lose data you care about.
This document explains how.

## Preview → confirm → execute

Nothing is ever deleted without your consent. Every run follows the same flow:

1. **Preview** — scan and print a grouped summary of what was found.
2. **Confirm** — an interactive `[Y/n]` prompt, or an explicit `--yes` flag.
3. **Execute** — act only on the confirmed items.

`--dry-run` stops after the preview and changes nothing.

## Move-to-staging, not delete

The default disposition is **move-to-staging**, not permanent deletion.
Cleaned items are moved into a quarantine directory:

```
~/.cleaner/staging/
```

Every staged item keeps its metadata so it can be restored faithfully. To
recover a clean, run:

```bash
cleaner undo            # restore the most recent clean
cleaner undo --list     # see what can be restored
```

Restores are **byte-identical**.

## Risk levels

Findings are classified by risk and shown in colour:

| Level | Colour | Meaning | Cleaned when |
| --- | --- | --- | --- |
| Safe | 🟢 green | Regenerated automatically, no user data. | Default (and `--yes`). |
| Medium | 🟡 amber | Regenerated but costs time to rebuild. | Only with `--all` or explicit confirmation. |
| Dangerous | 🔴 red | May hold irreplaceable data. | **Never auto-cleaned.** Shown only. |

- `--yes` cleans **Safe** items only.
- `--all` adds **Medium** items.
- **Dangerous** items (e.g. Xcode Archives with dSYMs/shipped builds) are never
  cleaned automatically — they are only reported.

## Protected paths

The engine enforces a hard list of paths it will **never** touch, independently
of any plugin. If a plugin ever tries to act on one, the run stops with exit
code `8`.

Protected paths include:

- `/`, `/System`, `/usr` (except `/usr/local`), and the system `/Library`
- `~/Documents`, `~/Desktop`, `~/Pictures`, `~/Movies`, `~/Music`
- `~/.ssh`, `~/.gnupg`, Keychains
- `*.key`, `*.pem`, and other credential files
- Time Machine snapshots
- The tool's own directories under `~/.cleaner/`

## Audit log

Every action is recorded in an append-only NDJSON audit log:

```
~/.cleaner/logs/
```

This gives you a full, replayable history of what was cleaned, staged, and
restored.

## Accurate measurements

Reclaimable space is measured as **true on-disk allocated size** (APFS-aware),
so the numbers reflect what you actually get back. Dry-run and real runs use
identical code, so previews match results.

## Full Disk Access

Some system-managed paths require macOS **Full Disk Access**. `cleaner`
degrades gracefully when it is missing — it skips what it cannot read and
exits with code `4` to signal the limitation. See the
[FAQ](./faq.md) for how to grant it.

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
