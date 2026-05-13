# mac-cleanup-memory

macOS memory status scan skill. **Diagnosis only, never kills.**

Sister skills: [mac-cleanup-process](../mac-cleanup-process/SKILL.md) (abnormal / stuck processes), [mac-cleanup-disk](../mac-cleanup-disk/SKILL.md) (disk cleanup). The three together cover the memory / process / disk dimensions of macOS maintenance.

## Usage

**In Claude Code:** say "check memory", "how's memory pressure", "who is eating memory", or any Chinese/English trigger phrase and the skill auto-triggers.

**Run the script directly (bypassing Claude Code):** locate the script in the plugin cache (version numbers shift) with `find`:

```bash
bash "$(find ~/.claude/plugins/cache -name scan.sh -path '*mac-cleanup-memory*' 2>/dev/null | sort | tail -1)"
```

The full report is both:
- Printed to stdout
- Saved to `~/Downloads/mac-cleanup-memory-<timestamp>.md`

## Report Contents

1. **System snapshot** — Free / Active / Inactive / Wired / Compressor / Purgeable / Swap
2. **Pressure level reference table** — Normal / Warning / Critical thresholds + current bucket
3. **Top RAM consumers (by process)** — top 15 processes by RSS
4. **Aggregated by App** — merges all processes under the same .app (e.g. WeChat main process + wxocr + helpers shown together) for true usage
5. **Objective observations** — flags suspicious patterns (duplicate-name processes, large inactive, high swap, compressor saturated, etc.). **No judgments, no kill recommendations.**

## Tuning Thresholds

Open `scan.sh` and edit the top-of-file constants:

```bash
TOP_N=15                  # show top N processes
APP_AGG_MIN_RSS_MB=100    # hide app aggregates below this MB
DUP_PROCESS_MIN_COUNT=2   # report "duplicate processes" observation when same-name count >= this
```

Takes effect immediately, no restart needed.

## Kill Safety Protocol

The skill itself does not kill processes. When the user explicitly says `kill <PID>`, Claude follows the protocol in [SKILL.md](./SKILL.md#-kill-safety-protocol-core-bolded):

1. Blacklist hard reject (PID 1, kernel_task, WindowServer, current claude session)
2. PID reuse validation (re-verify command unchanged before kill)
3. System UI second confirmation (Finder / Dock and similar)
4. SIGTERM first, SIGKILL only after 3 seconds
5. Batch kill must echo each entry + `confirm` before acting
6. Never use `pkill -f` / `killall` (avoid pattern friendly fire)
7. Append every action to audit log at `~/Downloads/mac-cleanup-memory-killed-*.log`

## Cleaning Up Persisted Files

```bash
# Reports (one per scan)
find ~/Downloads -name 'mac-cleanup-memory-*.md' -mtime +7 -delete

# Audit logs (appended every kill action)
find ~/Downloads -name 'mac-cleanup-memory-killed-*.log' -mtime +30 -delete
```

## Dependencies

Pure macOS built-ins: `vm_stat`, `sysctl`, `memory_pressure`, `ps`, `awk`, `sed`.
**Zero external dependencies** — no `jq`, no `brew install` of anything.

Adaptive page size: works on Apple Silicon (16K) and Intel Mac (4K).

## Pressure Level Thresholds

Based on free percentage as reported by macOS `memory_pressure`:

| Free % | Level | Meaning |
|--------|-------|---------|
| > 70% | Normal (healthy) | Fully normal |
| 40-70% | Normal (under pressure) | System running on the edge but stable |
| 10-40% | Warning | Time to tidy up |
| < 10% | Critical | System will start actively killing big consumers |

Note: this is a simplified model. The real macOS pressure level also involves compression ratio, swap activity, etc., but free percentage is good enough as a rough indicator.

## Boundary with mac-cleanup-process

| skill | Focus | Output |
|-------|-------|--------|
| `mac-cleanup-memory` | **Overall memory** + top consumers | System snapshot + top list + objective observations |
| `mac-cleanup-process` | **Abnormal** processes (orphans / over-aged / stuck) | Lists PIDs + suggested kill commands |

Difference: memory cares about "what's the memory state right now, who's eating it" — even if every process is normal, memory can still be tight; process only cares about "things that shouldn't be alive".

## Bash / awk Gotchas

- **`/` inside an awk regex character class**: `match(cmd, /\/[^/]+\.app\//)` reports "extra ]" on some awk versions. Use a functional `index()` + `substr()` implementation to dodge regex-parser differences.
- **macOS page size is adaptive**: Apple Silicon is 16K, Intel is 4K. **Do not hardcode** — use `sysctl -n hw.pagesize`.
- **vm.swapusage output format**: `total = 4096.00M used = 2509.81M free = 1586.19M (encrypted)` — units can be M or G, parser must distinguish.
