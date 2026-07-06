# FAQ

## Is it safe?

Yes. **You choose what's cleaned** — the interactive prompt lets you clean all,
select each source, or cancel, and nothing is removed without your consent.
Even then, items are **moved to a recoverable staging area** rather than
deleted, and the engine refuses to touch a hard-coded list of protected paths
(Documents, Desktop, SSH/GPG keys, Keychains, credentials, and more). See
[safety.md](./safety.md) for the full model.

## Does it delete permanently?

No. Cleaned items are moved to `~/.cleaner/staging/` with their metadata
preserved. You can restore them at any time with `cleaner undo`.

## How do I undo a clean?

```bash
cleaner undo            # restore the most recent clean
cleaner undo --list     # list what can be restored
cleaner undo <session-id>
```

Restores are byte-identical.

## How do I pick specific things?

Run `cleaner`, choose `s` (select each) at the prompt, and answer `y`/`n` for
each source:

```
Clean all <size>? [Y = all · s = select each · n = cancel]
```

Alternatively, skip a source with `--exclude <plugin-id>` (e.g.
`cleaner --exclude dev.cleaner.browser.cache`) or drop it permanently via the
config `ignore` list.

## Does it touch my browser cookies or passwords?

No. Browser cleaning targets **cache only**. Cookies, history, and passwords
are never touched.

## Does it need Full Disk Access?

Some system-managed paths require macOS **Full Disk Access**. Without it,
`cleaner` still works — it skips what it cannot read and exits with code `4` to
flag the limitation. To grant it:

1. Open **System Settings → Privacy & Security → Full Disk Access**.
2. Add your terminal application (or the `cleaner` binary).
3. Restart the terminal.

## How do I run it in CI?

Skip the prompt with `--yes` to clean everything found:

```bash
cleaner --yes
```

For a health check, use:

```bash
cleaner doctor --ci    # exit 0 healthy, 3 warnings, 1 critical
```

## How do I exclude something?

Three options:

- Config `ignore` — drop matching findings from results.
- Config `whitelist` — protect paths the tool must never touch.
- `--exclude <plugin-id>` — skip a source for a single run, e.g.
  `cleaner --exclude dev.cleaner.browser.cache`.

## Where are the logs?

An append-only audit log lives at:

```
~/.cleaner/logs/
```

## How do I uninstall it?

```bash
brew uninstall cleaner
rm -rf ~/.cleaner     # optional: remove staging, logs, and config
```

See [commands.md](./commands.md) for the full command reference.
