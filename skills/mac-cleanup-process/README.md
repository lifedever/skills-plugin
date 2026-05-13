# mac-cleanup-process

macOS zombie / stuck process scan skill. **Diagnosis only, never kills.**

Sister skill: [mac-cleanup-disk](../mac-cleanup-disk/SKILL.md) handles disk cleanup. This skill only looks at processes.

## Usage

**In Claude Code:** say "scan zombies", "cleanup zombies", "system is slow", or any Chinese/English trigger phrase and the skill auto-triggers.

**Run the script directly (bypassing Claude Code):** locate the script in the plugin cache (version numbers shift) with `find`:

```bash
bash "$(find ~/.claude/plugins/cache -name scan.sh -path '*mac-cleanup-process*' 2>/dev/null | sort | tail -1)"
```

The full report is both:
- Printed to stdout
- Saved to `~/Downloads/mac-cleanup-process-<timestamp>.md`

## Tuning Scan Thresholds

Open `scan.sh` and edit the top-of-file constants:

```bash
OLD_CLAUDE_HOURS=24       # threshold for old claude session (hours)
OLD_DEV_SERVER_DAYS=2     # threshold for long-running dev server (days)
OLD_SHELL_TAB_DAYS=3      # threshold for long-lived terminal tab (days, matches any macOS terminal)
BIG_MEM_RSS_MB=500        # RSS bar for large-memory candidates (MB)
BIG_MEM_DAYS=3            # etime bar for large-memory candidates (days)
```

Takes effect immediately, no restart needed.

## Extending MCP Server Detection

If you use a new MCP server, find `MCP_PATTERN` in `scan.sh` and add the new signature to the regex:

```bash
readonly MCP_PATTERN='(npm exec.*mcp|mcp-server-|@playwright/mcp|...|your-new-mcp-pattern)'
```

## Cleaning Up Persisted Files

`~/Downloads/mac-cleanup-process-*.md` accumulates one file per scan. Clean periodically:

```bash
# e.g. delete files older than 7 days
find ~/Downloads -name 'mac-cleanup-process-*.md' -mtime +7 -delete
```

## Dependencies

Pure macOS built-ins: `ps`, `pgrep`, `awk`, `sed`, `lsof`, `vm_stat`, `sysctl`, `top`.
**Zero external dependencies** — no `jq`, no `brew install` of anything.

## Design and Implementation

- `DESIGN.md` — full design doc (background, rules, edge cases, future-proofing)
- `SKILL.md` — skill entry point (trigger words + Claude interaction guide)

## Bash Gotchas

- **CJK punctuation directly adjacent to a variable reference**: things like `$var）`, `$var，` make bash treat the Chinese bytes as a continuation of the variable name, causing "unbound variable" under `set -u`. Fix: use `${var}` to explicitly delimit (e.g. `${var}）`).
