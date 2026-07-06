# plugin-python — Python ecosystem

> **Phase H · Plugin id:** `dev.cleaner.python` · **Target release:** v0.5 ·
> **Depends on:** plugins/README, 13, 14, 16, 19, 00 Art. 4/5.

Cleans Python caches (pip, poetry, conda) and bytecode (`__pycache__`/`*.pyc`), and **detects
virtualenvs** — which are the risky part: a venv can be trivially recreated (🟡) *or* contain an
irreproducible environment / installed local packages (🔴). Bytecode and download caches are 🟢.

## 1. Identity

```swift
PluginManifest(
    id: "dev.cleaner.python", name: "Python", category: .developer,
    apiVersion: "1.4.0", pluginVersion: "1.0.0",
    declaredRoots: [
        RootSpec(base: .libraryCaches, glob: "pip/**"),          // ~/Library/Caches/pip
        RootSpec(base: .home,          glob: ".cache/pip/**"),   // XDG pip cache
        RootSpec(base: .libraryCaches, glob: "pypoetry/**"),     // poetry cache
        RootSpec(base: .home,          glob: ".cache/pypoetry/**"),
        RootSpec(base: .home,          glob: ".conda/pkgs/**"),  // conda package cache
        RootSpec(base: .home,          glob: "miniconda3/pkgs/**"),
        RootSpec(base: .home,          glob: ".cache/uv/**"),    // uv cache
        // __pycache__ and venvs are discovered under user project roots (opt-in), §3
    ],
    defaultRisk: .safe,                          // caches/bytecode 🟢; venvs escalate 🟡/🔴
    capabilities: [.dryRun, .estimate, .rollback, .audit, .incremental],
    requiresElevation: false, trust: .firstParty)
```

Scope boundary: caches (always safe), `__pycache__`/`*.pyc` (safe, regenerated on import), and
virtualenv directories **only inside user-opted project roots**. It never removes the system
Python, a Homebrew/pyenv-managed interpreter, or `site-packages` of a non-venv global install.

## 2. What it targets

| Sub-item | Path | Why junk | Risk |
|---|---|---|---|
| pip cache | `~/Library/Caches/pip`, `~/.cache/pip` | Downloaded wheels; re-fetchable. | 🟢 |
| poetry cache | `~/Library/Caches/pypoetry`, `~/.cache/pypoetry` | Re-fetchable. | 🟢 |
| conda pkgs cache | `~/.conda/pkgs`, `<conda>/pkgs` | Extracted packages; re-fetchable (**hardlinked into envs**, §9). | 🟢 |
| uv cache | `~/.cache/uv` | Re-fetchable. | 🟢 |
| Bytecode | `**/__pycache__`, `*.pyc`, `*.pyo` | Recompiled on next import. | 🟢 |
| Virtualenvs | `<proj>/.venv`, `venv/`, `~/.virtualenvs/*`, `~/Library/Caches/pypoetry/virtualenvs/*` | Recreatable *if* reproducible; may hold local/editable installs. | 🟡 / 🔴 |

Does **not** target: `pyenv`/system interpreters, global `site-packages`, `conda` base env,
`.python-version`, or a project's source.

## 3. Detection signals & algorithm

### 3.1 Caches & bytecode (🟢)

- Caches: enumerate + size; always 🟢 (re-fetchable / regenerated). `__pycache__` dirs and loose
  `*.pyc` under opted project roots → 🟢, grouped per directory.
- Bytecode outside project roots (e.g. in a cache) is covered by the cache root.

### 3.2 Virtualenv detection (the careful part)

A venv is a **directory containing `pyvenv.cfg`** (PEP 405) — that marker, not the folder name, is
the authoritative signal (avoids false positives on dirs coincidentally named `venv`). Algorithm
within opted project roots:

1. Find `pyvenv.cfg` → the directory is a venv. Read it: `home` (interpreter path), `version`.
2. **Reproducibility signal → risk:**
   - If a sibling `requirements.txt`/`poetry.lock`/`Pipfile.lock`/`pyproject.toml` exists AND the
     `home` interpreter still exists → **reproducible** → 🟡 (recreatable via `pip install -r` /
     `poetry install`).
   - If **no** dependency manifest is found near the project, OR the venv contains **editable
     installs** (`*.egg-link`/`__editable__*` in `site-packages`) or non-PyPI local wheels →
     **not trivially reproducible** → 🔴 (`Recoverability = .hard`, DM-1 keeps it low). Never
     pre-selected.
   - If the referenced `home` interpreter is **gone** (e.g. removed pyenv version) → the venv is
     broken/orphan → 🟡 (recreate) but flag "interpreter missing."
3. **Activity guard:** venv or project source `mtime`/`lastUsedDate` recent (< `protectActiveDays`)
   or `isOpenOrLocked` (a running process holds a lib) → skip.
4. `FindingID = "py:venv:<canonicalVenvPath>"` / `"py:pycache:<dir>"` / `"py:cache:<path>"`
   (deterministic, DM-7).

## 4. Roots / paths with justification

| RootSpec | Resolves to | Justification |
|---|---|---|
| `.libraryCaches / pip/**`, `.home / .cache/pip/**` | pip caches | Re-fetchable wheel cache. |
| `.home / .cache/pypoetry/**`, `.libraryCaches / pypoetry/**` | poetry cache | Re-fetchable. |
| `.home / .conda/pkgs/**` | conda package cache | Re-fetchable; hardlink-aware (§9). |
| *project roots* (config) | `<root>/**/{pyvenv.cfg,__pycache__}` | Only user-opted, non-protected roots; venv confirmed by `pyvenv.cfg`. |

Venvs/bytecode under protected roots (`~/Documents`) are unreachable without an explicit target
rule (spec 18), enforced by the engine (spec 16 §9).

## 5. Risk & safety scoring

| Sub-item | Risk | Score | Notes |
|---|---|---|---|
| pip/poetry/conda/uv cache | 🟢 92 | pure cache | pre-selected |
| `__pycache__`/`*.pyc` | 🟢 95 | regenerated on import | pre-selected |
| Reproducible venv (has manifest) | 🟡 65 | recreatable, costs time | not pre-selected |
| Non-reproducible / editable venv | 🔴 30 | possible irreproducible env | never pre-selected, typed confirm |
| Broken venv (interpreter gone) | 🟡 70 | recreate | flagged |

`Recoverability`: caches/bytecode `.manual`; reproducible venv `.manual`; non-reproducible venv
`.hard`. Scores only lowered with evidence (DM-2); 🔴 venvs cannot map above dangerous (DM-1).

## 6. Recoverability & staging

- `Disposition = .stage` for all (Principle 2). A venv (many small files) rename-stages atomically
  on the same volume (spec 16 §11).
- `RollbackHint`: bytecode → "regenerates on next import"; reproducible venv → "or recreate:
  `python -m venv .venv && pip install -r requirements.txt`"; non-reproducible → strong note
  naming the editable/local packages found.

## 7. Dry-run / estimate

- `estimate`: `allocatedSize` sums (CC-10). **conda hardlink correction** (§9): conda envs
  hardlink into `pkgs`; removing an env or the cache must not double-count — `sharedExcluded`
  reflects it, `confidence = .estimated`.
- `--dry-run` separates 🟢 (caches/bytecode, pre-selected) from 🟡/🔴 venvs (never pre-selected),
  showing venvs by on-disk size with the reproducibility verdict per venv.

## 8. Shell fallback & its safety

Read-only probes to resolve real paths and interpreter validity:
```
["python3","-m","site","--user-base"]      # user site location, 5s
["pip","cache","dir"]                       # pip cache path
["poetry","config","cache-dir"]             # poetry cache path (if poetry present)
["conda","info","--json"]                   # conda envs/pkgs dirs (if conda present)
```
Read-only only. **No mutating commands** (`pip cache purge`, `conda clean` are *not* run) — the
tool stages files itself for reversibility (Principle 2). Probes locate; native FS cleans.
Justification: cache dirs and conda env layout are configurable and only reported by the tools;
there is no native API.

## 9. Edge cases & false-positive mitigations

| Edge case | Mitigation |
|---|---|
| Dir named `venv` that isn't one | Require `pyvenv.cfg` marker, not the name. |
| **conda hardlinks** env↔pkgs | `(volumeID, inode)` clustering (spec 16 §6); reclaim credits unshared blocks only. |
| Editable / local-wheel install in venv | Detect `*.egg-link`/`__editable__`/non-PyPI wheels → 🔴, never pre-select. |
| venv with a running process | `isOpenOrLocked` on a loaded `.so`/`site-packages` → skip. |
| pyenv/system interpreter | Never targeted (only caches + project venvs). |
| conda base environment | Excluded (removing base breaks conda). |
| `__pycache__` inside a venv about to be kept | Handled as part of the venv Item, not separately, to avoid partial state. |
| Poetry-managed venvs in `Caches/pypoetry/virtualenvs` | Recognized location; reproducibility from the owning project's `poetry.lock`. |

## 10. Test cases

- **T1 pip cache present** → 🟢, pre-selected.
- **T2 `__pycache__` under project** → 🟢.
- **T3 venv with `pyvenv.cfg` + sibling requirements.txt, source old** → 🟡, not pre-selected.
- **T4 venv with editable install, no manifest** → 🔴, typed confirm.
- **T5 venv whose interpreter path is gone** → 🟡 "interpreter missing."
- **T6 conda env hardlinked to pkgs** → estimate excludes shared blocks, `.estimated`.
- **T7 dir `venv/` without `pyvenv.cfg`** → skipped.
- **T8 running process holds venv lib** → skipped (`isOpenOrLocked`).

## 11. Config keys

`plugins.python`:

| Key | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | bool | `true` | Master toggle. |
| `cleanPipCache` / `cleanPoetryCache` / `cleanCondaPkgs` / `cleanUvCache` | bool | `true` | Per-tool cache toggles. |
| `cleanBytecode` | bool | `true` | Remove `__pycache__`/`*.pyc`. |
| `venvs.enabled` | bool | `true` | Enable venv detection. |
| `venvs.projectRoots` | list<path> | `[]` | Non-protected search roots for projects/venvs. |
| `venvs.staleDays` | int | `90` | Inactivity age to surface a venv. |
| `venvs.protectActiveDays` | int | `14` | Below this, never remove. |
| `venvs.requireManifestForMedium` | bool | `true` | If true, venvs without a dep manifest are 🔴 not 🟡. |

## Open Questions

- **OQ-py.1** Should conda env *removal* (not just pkgs cache) be offered, given hardlink
  semantics mean the cache is the real reclaim? *Leaning: envs only via explicit opt-in, 🔴 unless
  an `environment.yml` proves reproducibility.*
- **OQ-py.2** Detect pipx/`~/.local/pipx` app venvs separately (they are tools, higher risk to
  remove)? *Leaning: exclude pipx by default; surface as 🔴 only.*
- **OQ-py.3** Is `pyvenv.cfg` sufficient across virtualenv (not just venv) and older Pythons?
  *Leaning: `pyvenv.cfg` for PEP 405; add `bin/activate`+`lib/pythonX` heuristic fallback.*

## Dependencies

**Consumes:** 13 (contract, probes), 14 (grouped `Item`, types; `.hard` venvs → DM-1), 16
§6/§8/§9 (hardlinks, in-use, canonicalization), 18 (target rules for protected-root projects), 19
(staleness), 00 Art. 4/5. **Feeds:** 20 (stages caches/venvs), 22 (scores), 25 (grouping).
