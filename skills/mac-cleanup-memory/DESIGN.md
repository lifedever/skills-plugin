# mac-cleanup-memory Design Doc

## Background

`mac-cleanup-process` looks for **abnormal** processes (things that should have died but haven't). `mac-cleanup-disk` cleans disks. But the most common daily macOS slowness complaint is actually a third class — "Nothing's stuck, but memory is tight. Who's using it?"

That's the gap this skill fills: look at the system from a **memory perspective**, list the big consumers, don't judge — let the user decide who to close.

## Core Goals

1. **Zero judgment**: never output "I suggest killing X". The report only lists facts; the decision is fully in the user's hands.
2. **Aggregate by app**: looking at a single PID, WeChat seems to use only 600 MB — you miss the whole picture. Aggregated, WeChat's full family adds up to 2 GB.
3. **Objective observations**: use rules to identify suspicious patterns (duplicate-name processes, swap near limit, etc.), but only describe — never recommend.
4. **Extreme caution when killing**: only act on explicit PIDs from the user, and walk the full 7-step safety protocol. Never use batch pattern matching.

## Three-Skill Positioning

| skill | Perspective | Typical question |
|-------|-------------|------------------|
| `mac-cleanup-process` | Abnormal processes | "Pile of orphan MCP servers stuck around" |
| `mac-cleanup-memory` | Memory landscape | "Memory full, who's eating it?" |
| `mac-cleanup-disk` | Disk space | "Disk full, clean caches" |

## Key Design Decisions

### Decision 1: Don't proactively suggest who to kill

**Option A**: like mac-cleanup-process, give a "suggested commands block" listing suspicious PIDs for the user to copy-paste.
**Option B** (chosen): pure data presentation; the user verbally says "kill which one", Claude follows the strict protocol.

**Reason**:
- The process skill targets **clearly abnormal** processes (orphans, stuck) — suggestions are reasonable.
- The memory skill looks at **normal** process usage; "which should I close" is a subjective decision.
- Suggestions invite friendly fire (user sees "3 claude processes" suggestion and kills them all, but one of them might be running a long-running task).

### Decision 2: Aggregate by app, not by executable basename

**Pitfall**: aggregating by the basename of the first command token splits "Google Chrome --restart" into "Google" and "Visual Studio Code" into "Visual".

**Correct approach**: first check if the path contains `*.app/` — if so, use the outermost `.app` name (with `.app` suffix stripped); fall back to basename otherwise.

```awk
function get_app(cmd) {
  pos = index(cmd, ".app/")
  if (pos == 0) {
    # fallback: basename of first token
    n = split(cmd, parts, " ")
    first = parts[1]
    m = split(first, segs, "/")
    return segs[m]
  }
  before = substr(cmd, 1, pos - 1)
  for (i = length(before); i >= 1; i--) {
    if (substr(before, i, 1) == "/") return substr(before, i + 1)
  }
  return before
}
```

So `/Applications/WeChat.app/.../wxocr` and `/Applications/WeChat.app/.../WeChat` both bucket under "WeChat".

### Decision 3: Duplicate observation has a count cap

**Pitfall**: reporting "33 node processes" or "26 Google Chrome processes" is pure noise — Electron/Chromium architecturally requires many helpers, and the user can't "open fewer".

**Rule**: only report apps where `count >= 2 && count <= 8 && total_rss >= 500MB`.

- count 2-8: typical range across multiple independent instances (multiple claude sessions, multiple VSCode windows).
- count > 8: essentially a helper army — architectural, can't be reduced.
- total RSS >= 500MB: below this is not worth surfacing.

### Decision 4: Page size must be adaptive

```bash
PAGE_SIZE_BYTES="$(sysctl -n hw.pagesize)"
```

Apple Silicon is 16384 bytes (16K), Intel Mac is 4096 bytes (4K). Hardcoding 4K **breaks every calculation by a factor of 4** on M-series machines.

General principle: list / constant-style things default to "fetch at runtime", don't hardcode. Apple Silicon vs Intel page size is the textbook example — hardcoded 4K is **completely wrong** on M-series.

### Decision 5: Pressure level uses a simplified threshold table

The real `memory_pressure` decision involves: free %, compressor rate, swap activity, kernel notification level. Fully replicating that is too complex.

Simplified to free percentage as the single signal:

| Free % | Level |
|--------|-------|
| > 70% | Normal (healthy) |
| 40-70% | Normal (under pressure) |
| 10-40% | Warning |
| < 10% | Critical |

Not fully accurate (macOS may trigger Warning at 30% free if swap is already full), but good enough as a rough mapping. Docs say this is a simplified model.

### Decision 6: 7 rules of the "anti-friendly-fire" kill protocol

Origin: user explicit request — "be extra careful when killing processes, don't kill the wrong one".

Each rule corresponds to a real failure mode:

| Rule | Failure mode prevented | Real case |
|------|------------------------|-----------|
| 1. Blacklist hard reject | User accidentally specifies PID 1 / WindowServer | `kill 1` triggers immediate panic |
| 2. PID reuse validation | Post-scan PID has been recycled to a system process | macOS PID reuse is fast — 30 s idle is enough |
| 3. System UI second confirmation | Killing Finder/Dock isn't fatal but user may not know | Killing ControlCenter makes the top bar briefly disappear |
| 4. SIGTERM first | SIGKILL doesn't give the app time to save | VSCode / WeChat both have unsaved content |
| 5. Batch echo per entry | User mis-spoke a PID | Type "5" instead of "6" and you kill the wrong thing |
| 6. Never `pkill -f` | Pattern matching causes friendly fire | `pkill -f Chrome` matches ChromeDriver and anything with Chrome in the path |
| 7. Audit log | Traceability when something goes wrong | If user later says "the system feels weird", you can look back |

None of these is over-defense — each maps to a real incident that has happened.

## Output Format Choice

Markdown tables + sections. Reasons:
- Claude presents directly to the user; the dialog window renders tables fine
- Persisted to `~/Downloads`, opens directly in Preview / Typora / Obsidian
- Doesn't depend on any extra renderer

## Performance Characteristics

Measured on a 32 GB Mac with 200+ processes:
- vm_stat: < 50ms
- ps full dump: < 200ms
- awk aggregation: < 100ms
- Total < 1 second

No caching or async needed.

## Possible Future Extensions

Not in v1.0 scope, but worth recording:

1. **History trend**: write key metrics to `<skill-dir>/history.csv` on each scan, surface week-long pressure changes
2. **App allowlist ("don't suggest killing important apps")**: if Decision 1 is reversed to support suggestions, an allowlist can be added
3. **Activity Monitor energy impact integration**: high energy != high memory, but users often conflate them
4. **Webhook on Critical**: auto-notify when pressure enters Critical

## Maintenance Notes

- `scan.sh` is the script core. Edit logic here.
- `SKILL.md` is Claude's behavior guide. Edit interaction flow here.
- When changing the kill protocol, **sync all three places**: SKILL.md / README.md / this file all describe the 7 rules.
- When adding a new observation type: add a case in `render_observations` in scan.sh, and add a description to the report-contents section of README.md.
