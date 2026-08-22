---
name: mac-app-uninstall
description: Uninstall a macOS app and every leftover it left behind — a scriptable replacement for AppCleaner / CleanMyMac. Scans ~/Library, /Library, launchd jobs, privileged helpers, system extensions and installer receipts, then tiers each finding into safe / review / shared-do-not-touch before moving anything to the Trash. Use this whenever the user wants to remove, uninstall, or delete an application, or clean up the residue of an app they already deleted. Trigger words "uninstall app", "remove app", "delete app", "uninstall cleanly", "remove leftovers", "app leftovers", "appcleaner", "app cleaner", "cleanmymac", "get rid of this app", "purge app", "卸载应用", "卸载软件", "删除应用", "删除软件", "彻底卸载", "卸载干净", "干净卸载", "清理残留", "应用残留", "残留文件", "卸载不干净". Everything goes to the Trash and stays recoverable; the skill never runs sudo and never runs rm. Sister skills mac-cleanup-disk (system-wide cache cleanup), mac-cleanup-process (processes).
---

# mac-app-uninstall

Removes a macOS app *and* its leftovers, the way AppCleaner does — but with the reasoning visible and auditable at every step.

**The bottom line: everything goes to the Trash, so any mistake can be undone.** There is no permanent-delete path in this skill, by design. Never work around that with your own `rm`.

**Iron rule: identify → scan → show the report → confirm → dry run → execute → verify.**

## Division of labour

You do the judgement, the scripts do the enforcement:

| You (the agent) | The scripts |
|---|---|
| Work out *which* app the user means; ask when ambiguous | Enumerate leftovers across ~20 known locations |
| Optionally hunt for extra leftovers by name (step 4) | Decide ownership when apps nest in each other's namespaces |
| Explain, summarise, get consent | Enforce the path allow-list, Apple/Setapp protection, Trash-only |

`scan.sh` deliberately does **no** fuzzy matching — it takes an exact bundle id, exact app name, or a path. Guessing is your job, because you can ask a clarifying question and it cannot.

## 0. Pre-flight

`/usr/bin/trash` ships with macOS 14+. Both scripts are pure base-system bash; nothing to install.

`mole` is optional — `mo uninstall --list` gives a JSON app inventory with a Homebrew/Setapp/App source field. **Never use `mo uninstall` to remove anything**: with an app argument it doesn't list what it will delete and it blocks on a `[y/N]` prompt, so there is nothing to audit.

## 1. Identify the app

If the user gave anything less than an exact name or bundle id, resolve it *before* scanning:

```bash
ls /Applications ~/Applications 2>/dev/null | grep -i "<what they said>"
```

If more than one plausible match comes back, **ask which one**. Do not pick for them — removing the wrong app's data is not recoverable from the user's point of view, even if the files are in the Trash.

## 2. Scan

```bash
bash "${CLAUDE_SKILL_DIR}/scan.sh" "<exact app name | bundle id | /path/to/App.app>"
```

Read-only. Writes a Markdown report and a TSV manifest to `~/Downloads/`.

If it reports **not installed**, that's fine for leftover-only cleanup — pass the bundle id to sweep up orphans of an app that's already gone. But if you expected it to be installed, you probably passed a name it couldn't match: go back to step 1 rather than trying variations.

## 3. Present the report

**Paste the report to the user**, then summarise in a line or two: how much the safe tier frees, and whether anything landed in the shared or sudo sections.

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

`--execute` ends with a verification block. **Show it and read it** — don't just say "done":

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
2. **Never delete outside the two scripts.** The allow-list and Apple/Setapp protection live in `uninstall.sh`; a hand-written `trash` command has neither.
3. **Never run sudo**, even if asked. Give the command instead.
4. **Never touch the 🚫 shared tier.** If the user insists, name the app that owns it and let them do it by hand.
5. **Never present a blocked app's leftovers as removable**, even though the scan still lists them for information.
6. **Stop on verification failure.** A failed verification means the machine is in an unexpected state; further commands make it harder to diagnose.

## Related files

- `scan.sh` — read-only scanner and tiering engine
- `uninstall.sh` — Trash executor, path allow-list, post-delete verification
- `DESIGN.md` — why the tiering and the division of labour work this way
- `README.md` — user-facing docs
