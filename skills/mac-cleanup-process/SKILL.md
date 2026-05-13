---
name: mac-cleanup-process
description: Scan macOS for zombie/stuck processes (orphan MCP servers, leftover Docker cagent, long-running dev servers, old claude sessions, long-lived terminal tabs, large memory over-age) and produce a tiered diagnostic report + suggested kill commands. Trigger words "cleanup zombies", "scan zombies", "system cleanup", "check mcp orphans", "kill stuck processes", "清理僵尸进程", "系统清理", "MCP 孤儿", "kernel_task 高", "内存高", "系统卡", "扫僵尸", "清进程", "清卡死进程". The skill itself never kills — diagnosis + suggestion only. Sister skill mac-cleanup-disk (disk cache cleanup, never touches processes).
---

# mac-cleanup-process

A skill for diagnosing macOS zombie processes — pure diagnostic mode. **Never proactively kills any process.**

## Execution Flow After Trigger

### Step 1: Run the scan script

```bash
bash "${CLAUDE_SKILL_DIR}/scan.sh"
```

The script:
- Prints a full Markdown report to stdout
- Tees it to `~/Downloads/mac-cleanup-process-<timestamp>.md`
- Exits 0 on success, 1 on failure with diagnostics to stderr

### Step 2: Present the report

**Paste the stdout Markdown content to the user verbatim.** A line or two of contextual observation is OK (e.g. pointing out the "most suspicious"), but:

- **Never** modify / fabricate / omit factual data in the report (PID, etime, command)
- **Never** add candidates from your own `ps | grep` that the script didn't surface
- If the script outputs "🎉 no zombies found", just report all-clear and stop

### Step 3: Wait for user instruction

Handle per this table:

| User reply | Claude action | Second confirmation? |
|------------|---------------|----------------------|
| No reply / "ok" / "got it" | Do nothing | - |
| "run explicit-orphan cleanup" / "one-click cleanup" | Run all kill commands from the "Explicit Orphans" section of the suggested-commands block | **No** (the report already labels these as "safe to nuke") |
| `kill <PID1> <PID2>` (space or comma separated) | Kill each one; skip and continue if a PID is missing | **No** |
| "clean everything" / "clean all suspicious" or other vague instructions | Ask back: "Do you mean including these suspicious items [list]?" | **Yes** |
| "dry run" / "look only" | Reiterate "the skill is diagnostic-only by design" | - |

### Step 4: Post-kill verification

After an actual kill:
1. `sleep 2` to let the kernel reap
2. `ps -p <PID>` to confirm the target has exited
3. Brief report (before/after memory comparison, cite `vm_stat`'s compressor number)
4. **Don't** auto-rescan (the user will say so if they want another scan)

### Step 5: Error handling

| Situation | Action |
|-----------|--------|
| `scan.sh` exits 1 | Paste stderr verbatim, don't patch with your own ps |
| Killed PID no longer exists | Report "PID X has exited (possibly reaped along with the parent you just killed)", continue |
| Kill denied (permissions) | Suggest `sudo`, but **don't** sudo on the user's behalf |
| Downloads write fails | Report to the conversation as usual, warn "Not persisted this run: <reason>" |

## Core Guards (bolded!)

1. **Claude must not kill on its own initiative**. Only act when the user has explicitly stated PIDs, said "one-click cleanup", or said "run explicit-orphan cleanup".
2. **Claude must not modify the factual data emitted by scan.sh**. All PIDs / etime / commands / numbers in the report come strictly from the script.
3. **Claude must not kill any PID tagged `[current session — DO NOT KILL]`**, even on explicit user request. Ask back: "Are you sure you want to kill the current conversation process? If you really mean it, please run it manually in your terminal."

## Related Files

- `scan.sh` — scan engine
- `DESIGN.md` — design doc
- `README.md` — user docs (threshold tuning)
