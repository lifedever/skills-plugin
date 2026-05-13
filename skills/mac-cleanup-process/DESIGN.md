# mac-cleanup-process Design Doc

**Date**: 2026-04-24
**Status**: Design Approved, pending implementation
**Author**: brainstorming session output (user + Claude collaboration)

---

## 1. Background and Goals

### Problem

In day-to-day macOS use, after running long enough, `kernel_task` often spikes to high CPU. It looks like a thermal issue, but the real root cause is usually **the memory compressor being overwhelmed by zombie processes**. Common culprits:

- Claude Code tabs closed but the claude process didn't exit cleanly, leaving behind a pile of orphan MCP servers (PPID=1)
- Docker Desktop UI quit but the `cagent` background processes weren't cleaned
- dev servers (vite / pnpm dev / webpack) left running for days or weeks
- Terminal tabs (any macOS terminal) accumulating zsh — eventually eats resources

Manually triaging with `ps | grep` is time-consuming, and writing a shell script risks hardcoded rules that friendly-fire kills.

### Goals

Ship a Claude Code skill `mac-cleanup-process` that triggers when the user feels the system is sluggish, and:

1. **Auto-discovers** candidate processes in the above classes, split into "explicit orphans" and "suspicious — needs judgment"
2. **Diagnoses without acting** — the skill itself never proactively kills
3. **Generates copy-paste-ready kill commands**, leaving the execution choice to the user (paste to terminal / ask Claude to run)
4. **Presents full context** — suspicious items include project path, runtime duration, child-process count
5. **Persists the report** — easy to revisit later

### Non-goals

- No background scheduled scanning (friendly-fire risk, user explicitly opposes)
- No Claude Code hook auto-trigger (YAGNI for MVP)
- Does not cover processes of users other than the current one (system processes never scanned)

---

## 2. Overall Design

### 2.1 Directory Structure

```
<skill-dir>/
├── SKILL.md           # skill entry: description, frontmatter, interaction guide
├── scan.sh            # core scan script — all detection rules live here
├── DESIGN.md          # this doc
└── README.md          # user-facing manual (how to tune thresholds)
```

### 2.2 Trigger

- **Slash command**: `/mac-cleanup-process`
- **Natural-language keywords** (declared via SKILL.md frontmatter description):
  - Chinese: 清理僵尸进程, 系统清理, MCP 孤儿, kernel_task 高, 内存高, 系统卡, 扫僵尸
  - English: cleanup zombies, scan zombies, system cleanup, check mcp orphans

### 2.3 Data Flow

```
User trigger (keyword / slash)
    ↓
Claude loads SKILL.md
    ↓
Claude runs: bash <skill-dir>/scan.sh
    ↓
scan.sh scans → Markdown report to stdout
              → tee to ~/Downloads/mac-cleanup-process-<timestamp>.md
    ↓
Claude presents stdout content (near zero post-processing)
    ↓
User reads the report and decides:
    (a) Do nothing (most common)
    (b) Reply "run explicit-orphan cleanup" → Claude executes the explicit-orphan section of the suggested commands
    (c) Reply "kill <PID1> <PID2>" → Claude kills the named PIDs one by one
    (d) Copy commands to a terminal themselves (Claude does not get involved)
```

---

## 3. Scan Rules (scan.sh core)

Two main categories. All thresholds are constants at the top of `scan.sh`, easy to tune.

### 3.1 Category A: Explicit Orphans (safe to nuke)

| Subclass | Detection condition |
|----------|---------------------|
| **MCP server orphan** | `PPID=1` **and** command matches any of: `npm exec.*mcp`, `mcp-server-*`, `@playwright/mcp`, `@upstash/context7-mcp`, `@modelcontextprotocol/*`, `@henkey/postgres-mcp-server`, `figma-developer-mcp`, `xcodebuildmcp`, `mcp-mongo-server`, `alibabacloud-devops-mcp-server`, `drawio/mcp`, `context7-mcp` |
| **MCP orphan descendants** | Descendants of the above orphan parents (`pgrep -P` recursive) |
| **Docker cagent leftover** | Process name contains `cagent` **and** `pgrep -x Docker` is empty (Docker UI not running) |

### 3.2 Category B: Suspicious — Needs Judgment

| Subclass | Detection condition (default thresholds) |
|----------|------------------------------------------|
| **Old claude session** | Process name `claude` **and** `etime > 24h` |
| **Long-running dev server** | Command matches `vite\|webpack\|pnpm dev\|next dev\|nuxt dev\|npm run dev\|yarn dev\|rollup.*watch` **and** `etime > 2 days` |
| **Long-lived terminal tab** | A zsh process whose parent is `/usr/bin/login` (the shell inside a terminal tab) **and** `etime > 3 days` |
| **Large-memory over-age** | RSS > 500 MB **and** `etime > 3 days` **and** not already covered by a rule above (dedupe) |

### 3.3 Tunable Thresholds (top of scan.sh)

```bash
OLD_CLAUDE_HOURS=24
OLD_DEV_SERVER_DAYS=2
OLD_SHELL_TAB_DAYS=3
BIG_MEM_RSS_MB=500
BIG_MEM_DAYS=3
```

### 3.4 Guard Rules

**Guard 1: Never include the current claude session PID in suggested kill commands**
- The script walks ancestors via `$$ → $PPID`, finding the PID whose command matches `claude`
- That PID is tagged `[current session — DO NOT KILL]` in the report
- The suggested-command block automatically excludes it
- If the walk fails (user running tests from a plain terminal), the value is null and no exclusion is applied

**Guard 2: Never scan system-level processes**
- Only handle processes where `UID == current user UID`
- Filter out root, _windowserver, _driverkit, and similar system accounts

**Guard 3: Redact sensitive info in command lines**
- In the report and persisted Markdown, `scheme://user:password@host` style URIs have the password replaced with `***`
- Prevents leaking MongoDB / postgres connection strings

---

## 4. Output Format

### 4.1 stdout (read by Claude + seen by the user)

The script outputs **complete Markdown** that Claude presents with near zero post-processing. Example structure:

```markdown
# 🧹 System Zombie Scan Report

**Scan time**: 2026-04-24 12:35:12
**System snapshot**: Load 4.5 | memory used 30G, compressor 11.4G, free 1.3G
**Estimated reclaim**: ~2.1 GB (explicit orphans) + ~1.8 GB (if you clean suspicious too)

📄 Full report saved to `~/Downloads/mac-cleanup-process-2026-04-24-123512.md`

---

## ✅ Explicit Orphans (safe to nuke)

| Category | Count | PID list |
|----------|-------|----------|
| MCP orphan | 10 | 2396, 8572, ... |
| MCP orphan descendants | 12 | 2458, 8614, ... |
| Docker cagent leftover | 51 | 35019, 35465, ... |

**Total 73 processes, estimated reclaim ~2.1 GB**

---

## ⚠️ Suspicious — Needs Your Judgment

### ① Old claude sessions (>24h)

- **PID 91608** [most suspicious]
  - Project: `~/code/some-old-project`
  - Runtime: 7 days 21 hours
  - Memory: 106 MB (self) + ~400 MB (18 MCP children)
  - Parent chain: terminal → zsh → claude

- **PID 19157** `[current session — DO NOT KILL]`
  - Project: `~/code/current-project`
  - Runtime: 35 minutes

### ② Long-running dev servers (>2 days)
...

### ③ Long-lived terminal tabs (>3 days)
...

### ④ Large-memory over-age (RSS >500MB and >3 days)
...

---

## 💡 Suggested Commands (copy-paste ready)

```bash
# === Explicit orphans (safe to nuke) ===
kill 2396 8572 8641 ...
pkill -9 -f cagent

# === Suspicious items (uncomment after your own judgment) ===
# kill 91608   # old claude session, 7 days idle → will reap 18 MCP children
# kill 3404    # vite dev server, alive 13 days
```

---

**Usage hints**:
- The suggested-command block already excludes the current claude session (PID 19157)
- To have me run them, reply `kill 2396 8572 ...` or `run explicit-orphan cleanup`
- If you copy to a terminal yourself, I won't take any further action
```

### 4.2 Persistence

- Location: `~/Downloads/mac-cleanup-process-<timestamp>.md`
- Content: **identical Markdown to stdout** (the script tees to both)
- Benefit: opens directly in Finder Preview / VS Code / Typora; the user can clean any time
- No historical-comparison machinery (the user explicitly said they'll clean as they like)

### 4.3 Empty Result Handling

When the scan finds nothing, still output the report ("🎉 no zombies found, system clean"), persisted as usual — handy when the user wants to check "when was the last scan today".

---

## 5. Interaction Flow (SKILL.md directs Claude's behavior)

### 5.1 Standard Flow

1. **Run the scan**: `bash <skill-dir>/scan.sh`
2. **Present the report**: surface stdout verbatim; a small amount of context labeling is OK (e.g. "most suspicious")
3. **Wait for user instruction**: don't push; don't auto-rescan

### 5.2 Handling Follow-up Instructions

| User reply | Claude action | Second confirmation? |
|------------|---------------|----------------------|
| No reply / "ok" / "got it" | Do nothing | - |
| "run explicit-orphan cleanup" / "one-click cleanup" | Run the "Explicit Orphans" section of the suggested-command block | No (report already labels these as "safe to nuke") |
| `kill <PID1> <PID2>` (space or comma separated) | Kill each | No (user named specific PIDs) |
| "clean everything" / "clean all suspicious" or other vague instructions | Ask back: "Do you mean including these suspicious items [list]?" | Yes |
| "dry run" / "look only" | Reiterate "the skill is diagnostic-only by design" | - |

### 5.3 Post-kill Verification

1. `sleep 2` to let the kernel reap
2. `ps -p <PID>` to verify the target actually exited
3. Brief report (before/after memory comparison)
4. **Don't** auto-rescan

### 5.4 Core Constraints (bolded in SKILL.md)

1. **Claude must not kill on its own initiative** — only act after the user has explicitly said so
2. **Claude must not modify the factual data emitted by scan.sh** — report data comes strictly from the script
3. **Claude must not kill any PID tagged `[current session — DO NOT KILL]`**, even on explicit user request. Ask back: "Are you sure you want to kill the current session? If you really mean it, please do it manually in a terminal."

---

## 6. Technical Decisions

### 6.1 Implementation Approach

**Approach: script + interactive command generation** (option 3 from brainstorming)
- `scan.sh` outputs full Markdown + suggested-command block
- Claude only does formatting/presentation and responds to follow-up
- Reasons: stable, fast, independently testable, low friendly-fire risk

### 6.2 Dependencies

| Tool | Use |
|------|-----|
| `ps` | Core |
| `pgrep` | Categorized scanning |
| `awk` | Filtering |
| `lsof` | Project-path inference (reads claude process cwd) |
| `vm_stat` / `sysctl` | System snapshot (memory / compressor / load) |

**Pure macOS native tools, zero external dependencies** (no jq, no GNU toolset).

### 6.3 Exit Codes

- `0`: scan succeeded (including the "no zombies found" normal case)
- `1`: script-level error (ps failed / permission anomaly / system tool missing)

### 6.4 Performance Target

Single scan < 3 seconds.

---

## 7. Edge Cases

| Situation | Action |
|-----------|--------|
| First run finds nothing | Still emit "🎉 no zombies found", persist as usual |
| A PID exits during scanning | Tolerate `ps -p` failure, skip and continue |
| Multiple runs in one day | Multiple timestamped files in Downloads; user cleans on their own |
| Downloads directory removed | `mkdir -p ~/Downloads` fallback |
| PPID walk breaks (testing from plain terminal) | `current_claude_pid` is null, skip exclusion |
| Threshold doesn't match user's habits | Edit the top-of-file constants in scan.sh |
| Command line contains a password | Auto-redact `://user:***@` |

---

## 8. Test Plan

MVP stage relies on manual verification, no automated tests.

### Test Cases

1. **Clean state**: after cleaning all suspicious items, run the skill — expect "no zombies found"
2. **Fake orphan**: spawn `(sleep 10000) &; disown` so PPID=1 but the command doesn't match MCP signatures → expect not detected
3. **Real scenario**: run during a real zombie pile-up like 2026-04-24, compare with the manual-debug conclusions
4. **Current-session protection**: deliberately ask Claude to `kill <current_claude_pid>` — expect the guard to block
5. **Redaction**: manually start a `mongodb://user:pass@host` command — expect the report to show `mongodb://user:***@host`

---

## 9. Future-proofing (not in MVP)

| Idea | When it might land |
|------|---------------------|
| `--json` flag to force JSON output | When we want historical trend analysis |
| Claude Code Stop/SessionEnd hook integration | When manual runs aren't frequent enough |
| Exclusion list (a PID/command never reported) | When some "intentionally running" thing keeps getting flagged |
| More dev server watchers (rollup/turbo) | When we discover gaps |
| Other AI tool MCP detection | When we start using non-Claude MCP clients |

---

## 10. Implementation Path

Deliverables = **3 files**:

1. `<skill-dir>/SKILL.md` — entry (frontmatter + interaction guide)
2. `<skill-dir>/scan.sh` — core script
3. `<skill-dir>/README.md` — user docs (threshold tuning)

Suggested order:
1. Write `scan.sh` first (core functionality)
2. Manually run a few times to verify output (test against today's real system state)
3. Write `SKILL.md` to direct Claude's interaction
4. Write `README.md`
5. End-to-end test once more in a real "feels slow" scenario

Task breakdown is produced by the subsequent `writing-plans` skill.
