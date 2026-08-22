# mac-app-uninstall

Uninstall a macOS app and everything it left behind — an auditable, scriptable stand-in for AppCleaner / CleanMyMac.

Everything it removes goes to the **Trash** and stays recoverable — there is no
permanent-delete option, on purpose. It never runs `sudo` and never runs `rm`, and
every `--execute` run ends with a verification pass.

## Usage

Just ask:

> 卸载 Slack / uninstall Slack cleanly / 帮我把这个 app 删干净

Want to browse what's installed? It lists **everything**, alphabetically:

```bash
bash list-apps.sh                 # every app, A–Z
bash list-apps.sh --sort used     # by last used, oldest first
bash list-apps.sh --sort size     # by size, largest first
bash list-apps.sh --all           # include /System apps (not removable)
```

It's an inventory, not a set of suggestions — nothing in it implies an app should
go.

⚠️ **`no record` means Spotlight has no last-used date for that app — not that it
is unused.** Xcode and the Office apps commonly show it despite daily use. A date
marked `~` is inferred from the preferences file, not a real usage record. Verify
before removing anything.

Or run the scan/uninstall scripts directly:

`scan.sh` takes an **exact** app name, bundle id, or path — it does no fuzzy
matching, so that "did you mean Chrome or Chrome Canary?" stays a question someone
can answer rather than a guess a script makes.

```bash
# Read-only scan. Writes a report + manifest to ~/Downloads.
bash scan.sh "Slack"
bash scan.sh com.tinyspeck.slackmacgap
bash scan.sh "/Applications/Google Chrome.app"

# Preview what would be trashed
bash uninstall.sh --manifest ~/Downloads/mac-app-uninstall-Slack-<ts>.tsv --tier safe

# Actually do it
bash uninstall.sh --manifest ~/Downloads/mac-app-uninstall-Slack-<ts>.tsv --tier safe --execute
```

The scan also works for apps you already dragged to the Trash — pass the name or bundle id to sweep up the orphaned leftovers.

## What the tiers mean

| Tier | Meaning |
|---|---|
| ✅ Safe | Exact bundle-id match, and no other installed app claims it |
| ⚠️ Review | Bundle-id match, but another copy of the app is still installed |
| 🚫 Shared | Owned by an app that is **still installed**. Never removable. |
| 🔐 System | Needs sudo — reported with commands, never executed for you |

`--tier` accepts `safe` (default), `review`, `bundle` (the `.app` itself), or `all`.

## What it looks for

`~/Library` (Application Support, Caches, Containers, Group Containers, HTTPStorages, WebKit, Preferences incl. ByHost, Saved Application State, LaunchAgents, Application Scripts, Logs, Cookies, and more), plus a breadth sweep to catch locations the fixed list doesn't know about.

Then the parts most tools skip: `/Library/LaunchDaemons`, `/Library/PrivilegedHelperTools`, loaded `launchctl` jobs, **system extensions**, and `pkgutil` receipts.

## After it deletes

Every `--execute` run verifies and reports:

- each target actually left its original location
- **every parent and system directory is still intact** — the check that would
  catch a path bug taking a directory with it
- each item is confirmed sitting in `~/.Trash`, so it can be put back

A failed verification exits non-zero and tells you to stop and inspect.

## Things it refuses to do

- Uninstall Apple system apps
- Uninstall Setapp-managed apps (use the Setapp client — it reinstalls them otherwise)
- Delete anything in the 🚫 shared tier
- Run `sudo` on your behalf
- Delete permanently — there is no `--permanent` flag, on purpose
- Empty the Trash for you — that's the one-way step, so it stays yours

For Homebrew casks it will point you at `brew uninstall --zap --cask <name>` first, since that keeps brew's state consistent.

## Requirements

None beyond macOS 14+ (for `/usr/bin/trash`). Both scripts are plain bash using base-system tools.

`mole` (`brew install mole`) is optional — the scripts never call it. `mo uninstall --list`
is handy as a JSON inventory of installed apps when you're working out which app you
mean. Don't use `mo uninstall` to actually remove anything: it doesn't tell you which
leftovers it will delete.

## Notes

- Quit the app before uninstalling. A running app rewrites its preferences on exit.
- Leftovers named after the app (crash logs, some support folders) aren't matched
  by bundle id. Ask the assistant to sweep by name — it will confirm each hit with
  you and route them through the same safety gates.
- If two copies of the same app are installed, nothing is marked safe — the data is live for the other copy.
- Reports and manifests accumulate in `~/Downloads`; delete them whenever.
