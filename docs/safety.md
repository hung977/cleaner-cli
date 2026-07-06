# Safety Model

`cleaner` is designed so that a run can never lose data you care about. Safety
does not rely on risk grades or classifications. It rests on three guarantees.

## 1. You choose what's cleaned

Nothing is removed without your consent. A run always presents what it found
first, then acts only on what you pick:

```
Clean all <size>? [Y = all · s = select each · n = cancel]
```

- `Y` / Enter — clean everything found.
- `s` — walk each source with a `clean? [y/N]` prompt and pick per-source.
- `n` — cancel; nothing is touched.

For automation, `cleaner --yes` cleans everything found with no prompt.
`cleaner --dry-run` stops after the summary and changes nothing.

## 2. Everything is recoverable

Cleaned items are **moved to a staging quarantine**, not permanently deleted:

```
~/.cleaner/staging/
```

Every staged item keeps its metadata so it can be restored faithfully — this
includes the Trash, which is **staged, not emptied**. To recover:

```bash
cleaner undo            # restore the most recent clean, byte-for-byte
cleaner undo --list     # see what can be restored
cleaner undo <id>       # restore a specific session
```

Restores are **byte-identical**.

## 3. Protected paths can never be touched

The engine refuses — independently of any plugin — to act on a hard-coded list
of paths. If a plugin ever tries, the run stops with exit code `8`.

Protected paths include:

- `/`, `/System`, `/usr` (except `/usr/local`), and the system `/Library`
- `~/Documents`, `~/Desktop`, `~/Pictures`, `~/Movies`, `~/Music`
- `~/.ssh`, `~/.gnupg`, Keychains
- `*.key`, `*.pem`, and other credential files
- Time Machine snapshots
- The tool's own directories under `~/.cleaner/`

Additional guarantees:

- **Browsers:** only cache directories are ever targeted — never cookies,
  history, or passwords.
- **Accurate measurements:** reclaim is measured as **true on-disk allocated
  size** (APFS-aware), so `--dry-run` matches a real run exactly.
- **Audit log:** every action is written to an append-only audit log at
  `~/.cleaner/logs/`, giving a full, replayable history of what was cleaned,
  staged, and restored.

## Full Disk Access

Some system-managed paths require macOS **Full Disk Access**. `cleaner`
degrades gracefully when it is missing — it skips what it cannot read and
exits with code `4` to signal the limitation. See the [FAQ](./faq.md) for how
to grant it.

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

See [commands.md](./commands.md) for the full command reference.
