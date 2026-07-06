# plugin-browser — Chrome & Safari caches

> **Phase H · Plugin id:** `dev.cleaner.browser` · **Target release:** MVP ·
> **Depends on:** plugins/README, 13, 14, 16, 00 Art. 4/5.

Cleans **web caches only** for Chrome and Safari. This plugin exists inside a hard safety
boundary that is the entire point of its design: **it MUST NEVER touch cookies, history,
passwords, bookmarks, autofill, sessions, extensions, or Local/IndexedDB storage.** Deleting
those would log the user out of everything, destroy saved logins, and lose browsing history —
exactly the "byte wrongly deleted is worse than a gigabyte wrongly kept" failure the Constitution
forbids (Principle 1). Caches are 🟡: safe to clear but re-downloaded (costs bandwidth, slows the
next few page loads).

## 1. Identity

```swift
PluginManifest(
    id: "dev.cleaner.browser", name: "Browser Caches", category: .browser,
    apiVersion: "1.4.0", pluginVersion: "1.0.0",
    declaredRoots: [
        // Chrome (per-profile Cache/Code Cache/GPUCache only):
        RootSpec(base: .libraryCaches,             glob: "Google/Chrome/**/Cache/**"),
        RootSpec(base: .libraryApplicationSupport, glob: "Google/Chrome/*/Cache/**"),
        RootSpec(base: .libraryApplicationSupport, glob: "Google/Chrome/*/Code Cache/**"),
        RootSpec(base: .libraryApplicationSupport, glob: "Google/Chrome/*/GPUCache/**"),
        RootSpec(base: .libraryApplicationSupport, glob: "Google/Chrome/*/Service Worker/CacheStorage/**"),
        // Safari (sandboxed container — cache only):
        RootSpec(base: .libraryCaches,    glob: "com.apple.Safari/**"),
        RootSpec(base: .libraryContainers, glob: "com.apple.Safari/Data/Library/Caches/**"),
    ],
    defaultRisk: .medium,                        // 🟡 — clearing caches slows next loads / re-downloads
    capabilities: [.dryRun, .estimate, .rollback, .audit],
    requiresElevation: false, trust: .firstParty)
```

The `declaredRoots` are **surgically narrow**: every glob ends in a *cache* leaf. The plugin does
not declare — and the engine's guard would reject — any path that could reach credential or
history stores. This is defense in depth: even a bug in detection cannot wander into
`Cookies`/`History`/`Login Data` because those paths are not declared and are additionally on the
protected deny-list (Art. 5, `~/.config credentials`, keychains).

## 2. What it targets — and the explicit NEVER list

**Targets (cache only):**

| Browser | Path leaf | What |
|---|---|---|
| Chrome | `<profile>/Cache`, `Code Cache`, `GPUCache`, `Service Worker/CacheStorage` | HTTP cache, compiled JS cache, GPU shader cache, SW response cache. |
| Safari | `~/Library/Caches/com.apple.Safari`, container `Caches` | WebKit disk cache, favicons cache. |

**NEVER touches (the safety boundary — enforced by non-declaration + deny-list):**

```
Chrome:  Cookies, History, Login Data, Web Data (autofill), Bookmarks, Preferences,
         Local Storage, IndexedDB, Sessions/Session Storage, Extensions, Sync Data,
         "Local State", Network/Cookies
Safari:  Cookies (~/Library/Cookies, container Cookies), History.db, Bookmarks.plist,
         LocalStorage, Databases, saved passwords (Keychain — always protected),
         Reading List, Downloads.plist, per-site data
```

Any of these appearing in a Finding is a **contract violation → exit 8** (spec 13 §9). Tested
explicitly (§10 T-boundary).

## 3. Detection signals & algorithm

**Path scopes to cache; structure confirms; metadata sizes.** Web caches are junk by location
(they sit in a `Cache`/`Code Cache`/`GPUCache` directory) — no staleness needed to justify
safety, but the plugin still gathers evidence for honest reporting:

1. **Profile discovery (Chrome):** Chrome has multiple profiles (`Default`, `Profile 1`, …). Read
   `Local State` **read-only** only to enumerate profile directory names (never their contents) —
   or simply glob `Google/Chrome/*/Cache`. Each profile's cache is one grouped `Item`.
2. For each declared cache dir: verify the leaf name is in the allow-set (`Cache`, `Code Cache`,
   `GPUCache`, `CacheStorage`) — a **positive allow-list check**, so an unexpected sibling like
   `Cookies` is never included even if a glob over-matched.
3. Size via `allocatedSize` (CC-10). Emit 🟡 Findings; `rationale`: "Browser web cache; re-fetched
   on next visit."
4. **Running-browser guard:** if Chrome/Safari is running, clearing its live cache can corrupt the
   session or be immediately rewritten. Detect via `isOpenOrLocked` on cache DB files (spec 16 §8)
   and (best-effort) a running-process check; if running → down-rank and warn "quit the browser
   first" rather than silently clearing (see §9).
5. `FindingID = "browser:<chrome|safari>:<profile>:<cacheLeaf>"` (deterministic, DM-7).

## 4. Roots / paths with justification

| RootSpec | Resolves to | Justification |
|---|---|---|
| `.libraryApplicationSupport / Google/Chrome/*/Cache/**` | `~/Library/Application Support/Google/Chrome/Default/Cache` | Chrome stores its HTTP cache here; glob ends in `Cache` — cannot reach `Cookies`/`Login Data` siblings. |
| `.libraryApplicationSupport / Google/Chrome/*/Code Cache/**` | `…/Default/Code Cache` | V8 compiled-JS cache; regenerated. |
| `.libraryApplicationSupport / Google/Chrome/*/GPUCache/**` | `…/Default/GPUCache` | Shader cache. |
| `.libraryCaches / com.apple.Safari/**` | `~/Library/Caches/com.apple.Safari` | Safari's cache dir; Cookies/History live elsewhere (`~/Library/Safari`, `~/Library/Cookies`) and are NOT declared. |
| `.libraryContainers / com.apple.Safari/Data/Library/Caches/**` | sandboxed Safari cache | Container cache; the container's `Cookies`/`History` are outside this glob. |

`.libraryApplicationSupport`/`.libraryContainers` are proposed `RootBase` anchors (see Open
Questions). The engine still subtracts the deny-list (keychains, credential stores) from every
resolved path (spec 16 §9).

## 5. Risk & safety scoring

- **All browser caches: 🟡** (Art. 4.1) — clearing them is not *invisible* (the next page loads
  are slower, some offline SW content is lost), so never 🟢. Proposed `SafetyScore ≈ 70` (50–84
  band): regenerable=yes, user-content=no, but user-perceptible cost=yes.
- Service Worker `CacheStorage` is the highest of the medium band toward caution (some PWAs cache
  offline content there) — proposed score ~60, and gated behind a config flag
  (`clearServiceWorkerCache`, default true but separately toggleable).
- Never escalates to touching credential stores (those are simply out of scope). Scores lowered
  with evidence only (DM-2).

## 6. Recoverability & staging

- `Disposition = .stage` (Principle 2). Cache dirs rename-stage atomically (spec 16 §11).
- `Recoverability = .manual` (re-fetched by browsing). Restoring from staging is possible but
  rarely useful; `RollbackHint` note: "caches repopulate automatically; restore only if a specific
  offline PWA cache is needed."

## 7. Dry-run / estimate

- `estimate`: `allocatedSize` per cache dir/profile (CC-10), `confidence = .exact` (caches don't
  clone-share typically).
- `--dry-run` groups by browser → profile → cache type with per-profile totals, and clearly labels
  that no cookies/history/passwords are in scope (reassurance in the preview, Principle 3).

## 8. Shell fallback & its safety

**N/A — fully native.** No browser CLI is invoked; profile enumeration reads only directory names
(and, at most, the `Local State` JSON keys for profile names, read-only). No `context.process`.

## 9. Edge cases & false-positive mitigations

| Edge case | Mitigation |
|---|---|
| **Cookies/History/passwords** | Not declared + on deny-list; positive allow-list on cache leaf names; contract-violation test (§10). |
| Browser running | `isOpenOrLocked` + process check → down-rank, warn "quit first"; optionally still clear on-disk cache if config allows, but never the live SQLite of a running profile. |
| PWA offline content in Service Worker cache | Separate toggle; medium-low score; warned. |
| Chrome multiple profiles / Beta/Canary/Chromium | Glob covers `*` profiles; sibling channels (`Google/Chrome Beta`) handled by additional roots or config; each profile is its own Item. |
| Third-party Chromium browsers (Edge, Brave, Arc) | Out of scope for v1 (config `extraChromiumRoots` reserved); not auto-included to avoid guessing credential layouts. |
| Symlinked profile dir | `O_NOFOLLOW`; never follow out of root (spec 16 §6). |
| Favicon cache vs. bookmarks | Favicons are cache (in scope); bookmarks are not (never declared). |
| Enterprise-managed Chrome with policy caches | Only `Cache`-leaf dirs; policy/preferences untouched. |

## 10. Test cases

- **T1 Chrome Default `Cache` present** → 🟡 Finding, sized.
- **T2 profile dir also contains `Cookies`, `Login Data`, `History`** → those are **absent** from
  findings (boundary test).
- **T-boundary: plugin somehow yields a `Cookies` path** → engine rejects, exit 8 (asserted).
- **T3 Safari cache present, `~/Library/Cookies` present** → only cache is a Finding.
- **T4 Chrome running (lock on `Cache/data_0`)** → down-ranked + warned, live SQLite untouched.
- **T5 Service Worker CacheStorage with `clearServiceWorkerCache=false`** → excluded.
- **T6 two Chrome profiles** → two grouped Items.
- **T7 estimate** → per-profile allocated sum, exact.
- **T8 symlinked cache dir** → link not followed out of root.

## 11. Config keys

`plugins.browser`:

| Key | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | bool | `true` | Master toggle. |
| `chrome.enabled` / `safari.enabled` | bool | `true` | Per-browser toggles. |
| `chrome.profiles` | list<string> | `[]` (all) | Restrict to named profiles. |
| `clearHttpCache` | bool | `true` | Chrome `Cache` / Safari WebKit cache. |
| `clearCodeCache` | bool | `true` | Chrome `Code Cache`. |
| `clearGpuCache` | bool | `true` | Chrome `GPUCache`. |
| `clearServiceWorkerCache` | bool | `true` | SW `CacheStorage` (may drop PWA offline content). |
| `warnIfRunning` | bool | `true` | Warn/down-rank when the browser is running. |

There is deliberately **no** config key that could enable clearing cookies/history/passwords —
that boundary is not user-overridable (it would require declaring protected roots, which the engine
rejects).

## Open Questions

- **OQ-browser.1** Ratify `.libraryApplicationSupport`/`.libraryContainers` anchors in spec 13 §4.
  *Leaning: yes; they are common, non-protected, and needed by several plugins.*
- **OQ-browser.2** Support Firefox (`~/Library/Application Support/Firefox/Profiles/*/cache2`) and
  other Chromium browsers in v1 or defer? *Leaning: defer to v1.0 with per-browser cache-leaf
  allow-lists so the boundary stays airtight.*
- **OQ-browser.3** Should a running browser hard-block clearing (safest) or allow on-disk cache
  clearing with a warning? *Leaning: hard-block clearing a running profile's live cache; allow only
  after quit.*
- **OQ-browser.4** Is reading Chrome `Local State` for profile *names* acceptable, or should we
  rely purely on directory globbing to avoid touching any state file? *Leaning: pure globbing;
  read `Local State` only for display names, never required.*

## Dependencies

**Consumes:** 13 (contract, four-gate guard rejects credential paths → exit 8), 14 (types), 16
§6/§8/§9 (symlink, in-use, canonicalization/deny-list), 00 Art. 4.1 (medium), Art. 5 (credential
stores protected). **Feeds:** 20 (stages cache dirs), 22 (scores), 25 (browser→profile grouping),
36 (the boundary is a threat-model assertion).
