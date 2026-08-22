---
name: mac-app-uninstall
description: Browse installed macOS applications and uninstall any of them together with every leftover they left behind — a scriptable replacement for AppCleaner / CleanMyMac. Also use this to simply LIST what is installed, since choosing what to remove usually starts with browsing the full inventory. Scans ~/Library, /Library, launchd jobs, privileged helpers, system extensions and installer receipts, then tiers each finding into safe / review / shared-do-not-touch before moving anything to the Trash. Trigger words for listing "list installed apps", "list all apps", "list my apps", "what apps do I have", "what's installed", "show installed applications", "app inventory", "installed applications", "which apps are installed", "列出所有应用", "列出所有 app", "列一下我装的软件", "我装了哪些软件", "有哪些应用", "应用列表", "已安装的应用", "看看装了什么", "所有已安装的 app". Trigger words for removal "uninstall app", "remove app", "delete app", "uninstall cleanly", "remove leftovers", "app leftovers", "appcleaner", "app cleaner", "cleanmymac", "get rid of this app", "purge app", "卸载应用", "卸载软件", "删除应用", "删除软件", "彻底卸载", "卸载干净", "干净卸载", "清理残留", "应用残留", "残留文件", "卸载不干净". Everything goes to the Trash and stays recoverable; the skill never runs sudo and never runs rm. Sister skills mac-cleanup-disk (system-wide cache cleanup), mac-cleanup-process (processes).
---

# mac-app-uninstall

Removes a macOS app *and* its leftovers, the way AppCleaner does — but with the reasoning visible and auditable at every step.

**The bottom line: everything goes to the Trash, so any mistake can be undone.** There is no permanent-delete path in this skill, by design. Never work around that with your own `rm`.

**Iron rule: identify → scan → show the report → confirm → dry run → execute → verify.**

## Division of labour

You do the judgement, the scripts do the enforcement:

| You (the agent) | The scripts |
|---|---|
| Work out *which* app the user means — ask, never guess | Inventory installed apps and enumerate leftovers |
| Optionally hunt for extra leftovers by name (step 4) | Decide ownership when apps nest in each other's namespaces |
| Explain, summarise, get consent | Enforce the path allow-list, Apple/Setapp protection, Trash-only |

`scan.sh` deliberately does **no** fuzzy matching — it takes an exact bundle id, exact app name, or a path. Guessing is your job, because you can ask a clarifying question and it cannot.

## Where output goes

Everything lands under `~/Downloads/mac-app-uninstall/`:

```
apps-<ts>.md              the installed-app inventory
<App>-<ts>/report.md      scan report for one app
<App>-<ts>/manifest.tsv   what uninstall.sh acts on
<App>-<ts>/result.md      what was trashed + verification
```

One folder per uninstall, so a run's report, manifest and result stay together.

## 0. Pre-flight

`/usr/bin/trash` ships with macOS 14+. The scripts are pure base-system bash; nothing to install.

`mole` is optional — `mo uninstall --list` gives a JSON app inventory with a Homebrew/Setapp/App source field. **Never use `mo uninstall` to remove anything**: with an app argument it doesn't list what it will delete and it blocks on a `[y/N]` prompt, so there is nothing to audit.

## 1. Identify the app

The user often does **not** know the app's name, or has not said which one they
mean. Never guess, and never narrow the field for them.

**If they named something specific**, resolve it before scanning:

```bash
ls /Applications ~/Applications 2>/dev/null | grep -i "<what they said>"
```

More than one plausible match? **Ask which one.**

**If they want to see what's installed** — "列出所有 app", "what do I have",
"我看看有哪些", or anything else short of naming one — show the whole inventory:

```bash
bash "${CLAUDE_SKILL_DIR}/list-apps.sh"                  # every app, A–Z
bash "${CLAUDE_SKILL_DIR}/list-apps.sh" --sort used      # by last used, oldest first
bash "${CLAUDE_SKILL_DIR}/list-apps.sh" --sort size      # by size, largest first
```

Read-only. It writes the table to `~/Downloads/mac-app-uninstall/apps-<ts>.md`
and prints the path.

**Give the user that file path — do not paste the table into chat.** A 90-row
Markdown table wraps and misaligns in a terminal, and the Bash tool's output is
collapsed anyway (`… +103 lines`). The file renders properly and they can keep it.
Say how many apps there are, hand over the path, and stop.

- **Never `--limit`.** The file holds everything; the user is browsing for an app
  they may not be able to name. Truncating hides the one they wanted.
- **Never summarise it into "the interesting ones"** in place of the path.
- **Do not nominate candidates.** Not "these look unused", not "you could remove
  these". Sorting by last-used is a *view*, not a recommendation. The user decides
  what goes; you are the inventory, not the advisor.
- **Only sort by last-used if they ask for it.** Alphabetical is the default
  precisely because it implies nothing.
- **no record** means Spotlight has no last-used date — **not** that the app is
  unused. Xcode and the Office apps land there on machines where they're in daily
  use. A date marked `~` is inferred from the preferences file, not a usage record.
  State this accurately if the column comes up.

Then wait. Act on the app the user names, not the one you would have picked.

## 2. Scan

```bash
bash "${CLAUDE_SKILL_DIR}/scan.sh" "<exact app name | bundle id | /path/to/App.app>"
```

Read-only. Writes a Markdown report and a TSV manifest to `~/Downloads/`.

If it reports **not installed**, that's fine for leftover-only cleanup — pass the bundle id to sweep up orphans of an app that's already gone. But if you expected it to be installed, you probably passed a name it couldn't match: go back to step 1 rather than trying variations.

## 3. Present the report

The report goes to `~/Downloads/mac-app-uninstall/<App>-<ts>/report.md`, next to the manifest.

**Give the path, and in chat list the ✅ safe paths as a plain bullet list** — not as a table, which misaligns in a terminal:

```
- ~/Library/Application Support/com.foo.bar   (7.6 MB)
- ~/Library/Caches/com.foo.bar                (18.9 MB)
```

Then state the totals: how much the safe tier frees, and whether anything landed in the shared or sudo sections.

**The user must be able to see what they are approving.** Never ask them to confirm a deletion on the strength of a file they haven't opened — bullets in chat plus the file for detail. If the safe tier is large (say over 25 paths), give counts and the path, and tell them to open the report before confirming.

- **Never** move an item between tiers on your own judgement
- **Never** add paths the script did not find (except via step 4, explicitly)
- **Never** describe the ⚠️ review tier as safe

| Tier | Meaning | Action |
|---|---|---|
| ✅ Safe | Exact bundle-id match, no other installed app claims it | Removable |
| ⚠️ Review | Bundle-id match, but a second copy of the app is still installed | User confirms each |
| 🚫 Shared | Belongs to an app that is **still installed** | Never removable — scripts refuse |
| 🔐 System | Needs sudo | **User runs it themselves** |

If there's a 🛑 **Blocked** section, stop and explain. No manifest was written.

| Blocked because | Tell the user |
|---|---|
| Apple system app | Refused. Removing it can break the OS. |
| Setapp-managed | Uninstall from the Setapp client, or it reinstalls. |
| Homebrew cask | Recommend `brew uninstall --zap --cask <name>` first — keeps brew consistent. |
| App running | Ask them to quit it; a running app rewrites prefs on exit. |

## 4. Optional: hunt for name-based leftovers

`scan.sh` only matches bundle ids, so files named after the app (crash logs, some
support folders) won't appear. If the app is likely to have them, look yourself:

```bash
find ~/Library -maxdepth 3 -iname "*<AppName>*" 2>/dev/null | head -40
```

Judge each hit — most are noise, and a generic name will match things belonging to other apps. For the ones you and the user agree on, **append them to the manifest as review rows** rather than deleting them by hand:

```bash
printf 'REVIEW\t%s\tName match, user confirmed\n' "<path>" >> "<manifest>"
```

They then go through every safety gate like anything else. Deleting them yourself with `trash` would bypass the allow-list and the Apple/Setapp protection.

## 5. Dry run, then execute

Always dry run first, even after the user says go:

```bash
bash "${CLAUDE_SKILL_DIR}/uninstall.sh" --manifest "<path>" --tier safe
```

Then, only after they confirm the target list:

```bash
bash "${CLAUDE_SKILL_DIR}/uninstall.sh" --manifest "<path>" --tier safe --execute
```

`--tier` takes `safe`, `review`, `bundle` (the `.app` itself), or `all`.

**Verbal consent is required; silence is not consent.** "go ahead" / "删吧" counts. Use `review` or `all` only when the user has accepted those items by name.

## 6. Report the verification

`--execute` writes `result.md` into the same folder and ends with a verification block. That block is a few narrow lines, so **copy it into your reply verbatim** (tool output is collapsed otherwise) — don't just say "done":

- `all N target(s) gone from their original locations`
- `all N parent and system directories intact` — proof nothing above the targets was touched
- `all N item(s) confirmed in ~/.Trash — recoverable`

If it prints `❌ VERIFICATION FAILED`, or any `MISSING DIRECTORY` line, **stop immediately** and show the user. Do not run anything else, do not retry.

If some items were `not found there under the same name`, that's inconclusive, not loss — Finder renames on collision. Say so accurately.

## 7. The sudo tier is the user's job

Never run these. Hand them over:

```bash
sudo launchctl bootout system/<label>          # BEFORE deleting the plist
sudo rm /Library/LaunchDaemons/<label>.plist
sudo rm -rf /Library/PrivilegedHelperTools/<label>
sudo pkgutil --forget <receipt-id>
```

Order matters: **bootout before deleting the plist**, or launchd keeps the job alive and some apps rewrite the file.

System extensions can't be removed with `rm` — the app must deactivate them, or the user does it in System Settings → General → Login Items & Extensions.

Anything the report marked 🚫 in this section is shared (Microsoft AutoUpdate serves all of Office); deleting it breaks the other apps.

## Core guards

1. **Trash only.** Never `rm` a user file to "finish the job", never offer a permanent delete, never offer to empty the Trash. Recoverability is the entire point.
2. **Never say "above" about tool output — it is collapsed in the UI.** Wide tables (the inventory, the report) go to a file: give the path. Narrow content (verification block, a handful of paths) goes in your reply text as bullets. Either way the user must be able to actually see what they are approving; running a command and commenting on it does not count.
3. **Never delete outside the two scripts.** The allow-list and Apple/Setapp protection live in `uninstall.sh`; a hand-written `trash` command has neither.
4. **Never run sudo**, even if asked. Give the command instead.
5. **Never touch the 🚫 shared tier.** If the user insists, name the app that owns it and let them do it by hand.
6. **Never present a blocked app's leftovers as removable**, even though the scan still lists them for information.
7. **Stop on verification failure.** A failed verification means the machine is in an unexpected state; further commands make it harder to diagnose.

## Related files

- `list-apps.sh` — read-only inventory, written to `~/Downloads/mac-app-uninstall/`
- `scan.sh` — read-only scanner and tiering engine
- `lib.sh` — shared helpers + the app census, sourced by both
- `uninstall.sh` — Trash executor, path allow-list, post-delete verification
- `DESIGN.md` — why the tiering and the division of labour work this way
- `README.md` — user-facing docs
