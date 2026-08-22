# mac-app-uninstall — design notes

Why this skill is shaped the way it is. Read before changing `scan.sh` or `uninstall.sh`.

## Why not just wrap mole?

`mac-cleanup-disk` is built on tw93/mole, so wrapping `mo uninstall` was the obvious first idea. It was measured and rejected (mole 1.36.2):

| Command | Result |
|---|---|
| `mo uninstall --list` | Useful. Emits JSON with `name` / `bundle_id` / `source` (`App` / `Homebrew` / `Setapp`) / `path`. |
| `mo uninstall --dry-run "<app>"` | **Prints one line** (`FileLens dev 8.1MB \| Last: 3m ago`) and then blocks on `Proceed with uninstallation? [y/N]`. It never lists which leftover files it intends to remove. |

A scan of the same app found 11 leftovers that mole's dry-run displayed none of. An uninstaller that won't tell you what it is about to delete can't be audited, which conflicts with the project rule that a write operation must expose its blast radius before running. So mole stays an **optional name-resolution helper** and the removal logic is ours.

Note for whoever maintains `mac-cleanup-disk`: its SKILL.md claims `mo uninstall` is TUI-only. That is only true with no arguments — mole takes app names non-interactively.

## Division of labour: what belongs in a script at all

A skill is instructions for an agent; scripts are optional. So each piece of logic
has to earn its place in a script rather than in SKILL.md. Two things earn it:

1. **Hard constraints.** "Don't delete system directories" in prose is a
   *suggestion* an agent can rationalise its way around. A path allow-list in code
   is a *constraint*. Verified: a manifest hand-edited to contain
   `/Applications/Safari.app` is refused because `uninstall.sh` reads the bundle's
   real `CFBundleIdentifier` — not because the agent recognised the name.
2. **Deterministic drudgery.** ~20 leftover locations, a census of every installed
   app, longest-match ownership. Re-deriving that per session is slow and
   error-prone, and quoting Chinese/space-bearing paths is a reliable way for an
   agent to mangle a shell command.

Everything else belongs to the agent. The first version violated this: it did
fuzzy app-name resolution (Spotlight) and fuzzy leftover matching (name sweep)
inside the script. **Four of the five vulnerabilities in the audit below came from
exactly those two features** — they did not exist in a "let the agent figure out
which app" design. They were removed:

| Removed | Why | Where it went |
|---|---|---|
| `mdfind` resolution | Query language has no shell-side escaping — two injection surfaces plus a 120s hang | Agent lists `/Applications` and *asks* which app; scripts take exact input only |
| Name sweep | Noisy, and the source of a >2min DoS | Agent greps by name, judges the hits, and appends confirmed ones to the manifest as review rows — so they still pass every gate |

`scan.sh` lost ~85 lines and its entire injection surface. What stayed is what an
agent genuinely cannot do reliably in-context.

The corollary for step 4 in SKILL.md: when the agent finds an extra leftover, it
must **append it to the manifest**, never `trash` it directly. Appending keeps the
allow-list, the Apple/Setapp protection and the shared-tier refusal in the path.

## Census first

The census (every installed app: bundle id, name, path) is built before anything
else, because target resolution, ownership and duplicate detection all read it.
Resolving the target from this table instead of Spotlight means no query language,
no injection, and no dependency on a healthy Spotlight index.

`/System/Applications` is included on purpose: if Apple's bundle ids are missing
from the ownership table, an Apple-owned leftover can be attributed to the target
and tiered as safe.

## Ownership: why "most specific wins"

This is the core of the skill and the part that took two attempts.

Leftovers are named after bundle ids, so the question "does this path belong to the app being removed?" looks like simple prefix matching. It isn't, because apps nest inside each other's namespaces. On the development machine this was built on, both of these were installed:

- `com.lifedever.FileLens`
- `com.lifedever.FileLens.dev`

A naive "does any *other* installed app claim this path" test fails in **both** directions:

- Removing `FileLens`: `~/Library/Caches/com.lifedever.FileLens.dev` is a prefix match for the target, so it gets marked safe — and deleting it wipes the still-installed dev app's data.
- Removing `FileLens dev`: its own `~/Library/Caches/com.lifedever.FileLens.dev` is claimed by `com.lifedever.FileLens` (also a prefix match), so everything is wrongly quarantined as shared.

The fix (`owner_of`) is to resolve ownership to the **longest** bundle id that the basename equals or sits under, considering every installed app *and* the target:

```
base = com.lifedever.FileLens.dev
  candidates: com.lifedever.FileLens (22)  com.lifedever.FileLens.dev (26)
  winner: com.lifedever.FileLens.dev  -> belongs to the dev app

base = com.lifedever.FileLens.plist
  candidates: com.lifedever.FileLens (22)
  winner: com.lifedever.FileLens      -> belongs to the release app
```

Both directions now come out right, and the same rule generalises to helper bundles, `.dev` builds, beta channels, and any other sub-domain scheme.

## Shared components are derived, not listed

`~/Library/Application Support/Google` is shared by Chrome, Drive and the Keystone updater. `com.microsoft.autoupdate.helper` is shared by all of Office. Deleting either while removing a single app breaks the others.

AppCleaner-style tools handle this with a curated blacklist. A blacklist rots: it can't know about a shared component that ships next year.

Instead, `scan.sh` censuses every installed app (`/Applications`, `~/Applications`, `/Applications/Setapp`, `/Applications/Utilities`) and reads each `CFBundleIdentifier`. Any leftover whose owner resolves to an app that is **still installed** is tiered 🚫 and is unreachable from `uninstall.sh`. Shared components fall out of the data instead of being remembered.

Cost: one `plutil` call per installed app, ~2s for ~100 apps. Acceptable for an interactive workflow.

## Fixed location list *and* a breadth sweep

`scan.sh` does both:

1. **Precise pass** over the ~20 known leftover directories, matching `<bid>` and `<bid>.*`.
2. **Breadth sweep** — `find ~/Library -maxdepth 3` for the same patterns.

The fixed list is precise but will rot as macOS adds directories (`Daemon Containers` is recent). The sweep catches whatever the list forgot — it found `Application Support/CrashReporter/<AppName>_<UUID>.plist` during testing, which no fixed list had. Precision plus coverage; neither alone is sufficient.

Display-name matching runs only when the name is ≥4 characters and always lands in ⚠️ review, never ✅ safe. Names like "Notes" or "Mail" would otherwise match half of `~/Library`.

## The path allow-list

A manifest is a plain text file in `~/Downloads`. It can be stale, hand-edited, or wrong. `uninstall.sh` therefore treats every path in it as untrusted and re-validates independently of what the tier column claims:

- Must sit under `~/Library/<dir>/`, `/Applications/*.app`, or `~/Applications/*.app`
- A path directly under `~/Library` is allowed **only** if its basename is in the target's bundle-id namespace — this is what keeps `~/Library/Caches` unreachable while still allowing `~/Library/com.foo.bar`, which the breadth sweep can legitimately surface
- No `..` segments
- `SHARED` rows are refused regardless of `--tier`, so editing the tier column smuggles nothing through

Verified by feeding it a hostile manifest listing `$HOME`, `$HOME/Documents`, `~/Library`, `~/Library/Caches`, `/Applications`, `/Library/LaunchDaemons`, `/System/Library/CoreServices`, `/`, and a `..` traversal — all nine refused, with `--tier all`.

Note the ordering subtlety: in a `case` pattern `*` matches `/` as well, so `"$HOME"/Library/*/*` **must** be tested before `"$HOME"/Library/*` or the shallow pattern swallows every nested path.

## Trash only, no permanent delete

Every removal goes through `/usr/bin/trash` (macOS 14+, Finder API). There is
deliberately no `--permanent` flag: recoverability is the entire value of the
skill. Users who want the space back empty the Trash themselves.

Audit this whenever the scripts change — the only deletion of a user path should
be `uninstall.sh`'s single `trash` call:

```bash
grep -nE '\brm\b|unlink|rmdir|trash' scan.sh uninstall.sh
```

The only other hits should be `rm -f` in `scan.sh`'s EXIT traps, which delete its
own `mktemp` scratch files.

**TCC nuance:** `/usr/bin/trash` writes to `~/.Trash` fine without Full Disk
Access because it goes through FileManager. *Listing* `~/.Trash` is denied — but
`stat`ing a known path inside it is allowed. So verification checks each item
individually rather than gating on `ls`, which would downgrade a real check into
a guess. Confirmed end to end: trash a file, confirm it at `~/.Trash/<name>`,
`mv` it back, contents identical.

## Post-delete verification

`--execute` verifies three things and exits non-zero if any fail:

1. **Targets left their original locations.** Catches a `trash` that reported
   success without moving anything.
2. **Every ancestor still exists.** This is the "did we take a parent directory
   with it" check. The list is *derived* — every ancestor of every path actually
   removed, walked up to `$HOME`, plus fixed anchors (`~/Documents`, `~/Desktop`,
   `/Applications`, `/Library`, `/System`, …). Deriving it means the check adapts
   to whatever was removed instead of asserting against a guess at what matters.
3. **Each item is in `~/.Trash`.** Recoverability, verified rather than assumed.
   A miss is reported as *inconclusive*, not as loss, because Finder renames on
   name collision.

SKILL.md instructs the agent to stop on failure rather than continue — an
unexpected state gets harder to diagnose with every further command.

## sudo is never run

`/Library/LaunchDaemons`, `/Library/PrivilegedHelperTools`, `/private/var/db/receipts` and system extensions are **reported with commands, never executed**. Two reasons: the project's write policy requires explicit confirmation for privileged operations, and these are exactly where shared components live (Office's autoupdate helper, for example).

`launchctl bootout` must precede deleting a job's plist, otherwise launchd keeps the job running and some apps rewrite the file — so the report always emits loaded jobs above the file list.

System extensions can't be removed with `rm` at all; they require the app to deactivate them or user action in System Settings. The scan surfaces them because a deleted app leaves them behind permanently, and no AppCleaner-class tool reports this.

## iOS apps on Apple Silicon are wrappers

"Designed for iPad" apps installed from the App Store don't have the usual layout:

```
微店.app/
├── WrappedBundle -> Wrapper/WDBuyerUniv.app
└── Wrapper/
    └── WDBuyerUniv.app/
        └── Info.plist        <- at the bundle root, NOT under Contents/
```

`$APP_PATH/Contents/Info.plist` doesn't exist, so a naive read yields an empty
bundle id and every leftover lookup then silently finds nothing — the app looks
"clean" when it isn't. `mole` reports `"bundle_id": "unknown"` for all three such
apps on the development machine; `info_plist_for()` resolves them correctly
(`com.koudai.weidian.buyer`, etc.).

Their data lives in `~/Library/Containers/<bundle id>` rather than the spread of
`Application Support` / `Caches` / `Preferences` that native apps use, so the
report calls this out explicitly.

## Bugs found during development

Recorded because each one was silent:

- `case "$1" in *"$(printf '\n')"*)` — command substitution strips trailing newlines, so the pattern collapsed to `*` and matched **every** path. Use `$'\n'`.
- `grep -c ... || echo 0` — `grep -c` prints `0` *and* exits 1 when there are no matches, so the fallback appended a second zero and counts rendered as `0\n0`.
- `scan.sh` surfaced `~/Library/<bundleid>` (depth 2) but `uninstall.sh`'s depth rule rejected it — the two scripts disagreed about what a valid leftover is. Same class of bug as "one resolver copied half-way into a second entry point".
- A blocked target still printed the heading "✅ Safe to remove". The heading alone invites someone to go delete them by hand; blocked targets now print an informational heading instead.

## Adversarial audit

Run after the happy path worked. Every item below was a real finding, not a
hypothetical — the first three were exploitable.

**Read this together with "Division of labour" above.** The first three findings
were each patched (escaping, input refusal, bundle validation) and then made moot
when the features that carried them — Spotlight resolution and the name sweep —
were removed outright. They are recorded because the *pattern* recurs: every one
came from putting fuzzy matching inside a script, where a hostile or careless
string reaches an interpreter that has no escaping story. If you ever add fuzzy
matching back, these are the bugs you will be re-introducing.

**Glob injection into `find` (critical).** App names went straight into
`-iname "*$APP_NAME*"`. Input `****` expanded to match **8461 paths** under
`~/Library` — the entire tree. All of it landed in the review tier, and
`uninstall.sh`'s allow-list happily passes `~/Library/*/*`, so
`--tier review --execute` would have trashed the user's whole Library. The same
bug silently broke legitimate names containing `[` or `]`
(`Adobe Photoshop [2024]` matched nothing). Fixed with `escape_glob` on every
`-name`/`-iname` interpolation; verified that `\*\*\*\*` then matches only a file
literally named `****`.

**mdfind query injection, two surfaces (critical).** The query string is not
escapable from the shell side:
1. A quote closes the literal. Payload `' || kMDItemDisplayName == '*` made
   Spotlight walk the whole disk — still running after 120s.
2. `*` and `?` are wildcards *inside* the query. `kMDItemDisplayName == '*****'c`
   matched **456 apps** and resolved to `/Applications/Safari.app`; the scan then
   presented an unrelated app's data as this app's leftovers.

Neither is escapable, so `mdfind_safe` refuses any input containing `'`, `"`,
`\`, `*` or `?`. The 1c directory walk still resolves those names correctly.

**Spotlight index pollution (high).** `resolve_app` accepted any mdfind hit that
was a directory. Spotlight indexes anything named `*.app` — including leftover
folders like `~/Library/HTTPStorages/com.muxy.app`. Input `com.` resolved to that
residue directory and treated it as the application bundle. Now a real
`Info.plist` is required.

**Unbounded name sweep (DoS).** `plist` matched 1468 paths; processing them cost
an ownership walk plus a `du` of each (some are huge container directories) and
ran past two minutes. Truncating to the first N was the wrong fix: a name
matching hundreds of paths has no discriminating power, so every hit is noise.
The sweep now **counts first and abandons wholesale** above 100 matches, and says
so in the report. Worst case dropped from >120s to 2s.

**ERE injection into `pgrep -f`.** `pgrep` takes a regex, so a bundle id of `.*`
matches every process, and `uninstall.sh` would then refuse to ever run. Fixed
with `escape_ere` in both scripts.

Verified safe, no change needed:

- **`trash` does not follow symlinks.** A symlink at `~/Library/Caches/<id>`
  pointing at a real directory is itself moved to the Trash; the target is
  untouched. This also closes the TOCTOU window between scan and execute.
- **SHARED is unreachable.** `--tier shared` is rejected outright, and `--tier all`
  still skips SHARED rows and reports the count rather than dropping them quietly.
- **Tab-bearing paths in a hand-edited manifest** truncate the path at the tab,
  which then fails the existence check and is skipped. `scan.sh` never emits such
  a row in the first place.

## Test matrix

Run these after any change to the tiering logic. All are read-only except the sandbox case.

| Case | Expectation |
|---|---|
| App with a `.dev` sibling installed, scan release | sibling's leftovers → 🚫 |
| Same pair, scan the `.dev` build | its own leftovers → ✅, release's not listed |
| Apple app (`Xcode`) | 🛑 blocked, no manifest written |
| Setapp app | 🛑 blocked |
| Homebrew cask | ⚠️ warns, recommends `brew uninstall --zap` |
| Network app (`Surge`) | launchd jobs + PrivilegedHelperTools + system extension all reported under 🔐 |
| Hostile manifest | every out-of-root path refused |
| Sandbox dir under `~/Library` | actually moved to Trash, idempotent on re-run |
| `scan.sh '****'` / `'????'` / `'plist'` / quote payload | resolves nothing, ~2s, no hang |
| Manifest hand-edited to add `/Applications/Safari.app` | refused as protected (read from its real bundle id) |
| Manifest hand-edited to add `~/Documents` | refused, outside allowed roots |
| Agent appends a confirmed name-match row (SKILL.md step 4) | removed and verified, gates still applied |
| Any `--execute` run | verification block passes all three checks |
| Trash a file, then `mv` it back from `~/.Trash` | contents identical |
