---
name: mac-cleanup-memory
description: Scan the macOS memory landscape — system snapshot (Free/Active/Inactive/Wired/Compressor/Swap) + pressure level + top RAM consumers (aggregated by PID and by App) + objective observations (duplicate-name processes, reclaimable inactive, swap trends, etc.). Trigger words "check memory", "memory pressure", "ram usage", "who is using memory", "memory high", "scan memory", "内存检查", "看内存", "查内存", "谁占内存", "内存压力", "内存紧张", "压缩器多大", "内存高", "扫内存". The skill itself never kills any process — it is diagnostic only. Kill only happens after the user names specific PIDs, and with strict validation (PID reuse protection, TERM→KILL escalation, system-process blacklist, double confirmation). Sister skills mac-cleanup-process (abnormal/stuck processes) and mac-cleanup-disk (disk cleanup).
---

# mac-cleanup-memory

A skill for diagnosing macOS memory state — **diagnostic-only mode**. Never proactively kills any process.

## Execution Flow After Trigger

### Step 1: Run the scan script

```bash
bash "${CLAUDE_SKILL_DIR}/scan.sh"
```

The script:
- Prints a full Markdown report to stdout
- Tees it to `~/Downloads/mac-cleanup-memory-<timestamp>.md`
- Exits 0 on success, 1 on failure with diagnostics written to stderr

### Step 2: Present the report

**Paste the stdout Markdown content to the user verbatim.** You may add one or two observations at the end pointing out the most notable items, but:

- **Never** modify / fabricate / omit any numbers in the report (RSS, PID, pressure level)
- **Never** add candidates from your own `ps aux | grep` that the script didn't surface
- **Never** add "I suggest killing X" to the report — that's the user's call

### Step 3: Wait for user instruction

| User reply | Action |
|------------|--------|
| No reply / "ok" / "got it" | Do nothing |
| `kill <PID>` or `kill <PID1> <PID2>` | Follow the [Kill Safety Protocol], one PID at a time |
| "run purge" / "执行 purge" | Run `sudo purge` (user enters their own password) |
| "kill all WeChat" / "把微信全杀了" | **Must** list every PID + command for confirmation first — never use `pkill`/`killall` directly |
| "clean up everything" / vague instruction | Ask back: "Which specific PIDs?" |

---

## 🛡️ Kill Safety Protocol (core, bolded)

For each kill, walk through all the steps **one PID at a time**. If any step fails, abort that PID (other PIDs are unaffected).

### 0. Active session strong protection (highest priority, added 2026-05-13)

Each process in the `scan.sh` report carries a status tag:
- 🟢 **IDE** — IDE/editor associated (VSCode/Cursor/JetBrains/Xcode/Sublime child process, or path contains `vscode/extensions/anthropic.claude-code`)
- 🟢 **TTY** — has a controlling terminal (the user is watching it in a terminal tab)
- 🟡 **new** — etime < 30 minutes
- 🔴 **orphan** — true zombie (CLI child class with PPID=1)
- — — normal

**Hard rule**: for any PID tagged 🟢 (IDE/TTY), you may only act after the user **explicitly states that PID number by itself**. The following vague instructions do NOT count:

- ❌ "kill those claude ones"
- ❌ "kill them all"
- ❌ "kill the 3" (even if PIDs were listed above)
- ❌ "yes" / "confirm" / "go"
- ❌ "kill all the recommended ones"

**Correct behavior**: if any 🟢-tagged PID is on the kill list, echo it separately:

```
⚠️ PID 84807 is 🟢 IDE (VSCode claude, currently in use). To kill it, please type explicitly:
   kill 84807
Other 🔴 / — tagged PIDs I can handle per your batch instruction.
```

**True orphans (🔴) may be batched**: if the user says "kill all orphans" or "clear the 🔴 ones", batch is allowed (by definition these are dead remnants).

**Counter-example (2026-05-13 incident)**: a `claude` process with PPID=VSCode, etime=11 minutes, 19 live children was listed alongside true orphan `claude` as "3 old claude processes" with a kill suggestion. The user replied "kill the 3" and the action ran → interrupted work the user was actively doing.
**Root cause**: scan.sh did not yet emit classification tags; Claude was reading `vscode/extensions/` from raw text, but the suggestion didn't single it out. **Fix**: scan.sh now emits the 🟢 tag directly, and this rule mandates that any 🟢 entry requires explicit single-PID confirmation.

### 1. Blacklist hard reject

The following PIDs are **never killed**, even on explicit user request. Push back with "Are you sure about X? If you really want this, run it manually in your terminal":

- PID 1 (launchd)
- Commands containing `kernel_task` / `WindowServer` / `loginwindow` / `launchd` / `mds` / `mds_stores`
- The current claude session PID (use the `find_current_claude_pid` logic, see mac-cleanup-process/scan.sh)

### 2. PID reuse validation (avoid friendly fire)

```bash
# User asked to kill PID X. RECORDED_CMD is what scan.sh saw.
CURRENT_CMD="$(ps -p X -o command= 2>/dev/null)"
```

- If `CURRENT_CMD` is empty: PID has already exited. Report "PID X has exited (possibly by another action)" and skip.
- If `CURRENT_CMD` does **not** match the recorded command (use substring check, not strict equality — args can drift): abort + warn "PID X has been reused by a new process, currently `<new command>`, aborted."

### 3. System-UI second confirmation

If the command path contains any of the following, ask for **one extra** confirmation (even if not on the hard blacklist):

- `/System/Library/CoreServices/` → system service
- `Finder.app` / `Dock.app` / `SystemUIServer.app` / `ControlCenter.app` → desktop UI (recoverable, but the user's UI will flicker)
- `coreaudiod` / `bluetoothd` / `WiFiAgent` → system daemons

```
"PID X is <App>. Killing will briefly interrupt <UI behavior> (the system will auto-restart it). Continue? Reply yes/no."
```

### 4. SIGTERM first, SIGKILL only after 3 seconds

```bash
kill <PID>           # SIGTERM
sleep 3
if ps -p <PID> >/dev/null 2>&1; then
  echo "PID X did not respond to SIGTERM, escalating to SIGKILL"
  kill -9 <PID>
  sleep 1
fi
ps -p <PID> >/dev/null 2>&1 && echo "⚠️ PID X still alive" || echo "✅ PID X has exited"
```

Reason: SIGTERM gives the app a chance to save state; SIGKILL is the last resort. WeChat / VSCode / Chrome all have unsaved state.

### 5. Batch kill must echo each entry + final confirmation

If the user names multiple PIDs at once, print a confirmation table before acting:

```
Processes to kill:
  PID 50484 → claude (RSS 500 MB)
  PID 74039 → claude -c (RSS 504 MB)
2 total. Reply `confirm` to execute, `cancel` to abort.
```

Execute only on `confirm`. Anything else counts as cancel.

### 6. Never use pkill / killall / pkill -f

```bash
# ❌ Never allowed
pkill -f "WeChat"        # matches WeChatAppEx, WeChatHelper, any path with WeChat
killall WeChat           # same problem
pkill -9 chrome          # same problem

# ✅ Allowed
kill <specific PID>
kill -9 <specific PID>   # only after SIGTERM + 3s no response
```

If the user says "kill all WeChat processes": first use scan data to list every WeChat-related PID (or rescan), then ask the user to **confirm each one** or confirm all.

### 7. Audit log every action

After each actual kill, append to `~/Downloads/mac-cleanup-memory-killed-<date>.log`:

```
2026-05-13T13:55:32  PID=50484  CMD="claude"  RSS=500MB  signal=TERM  result=exited
2026-05-13T13:55:36  PID=74039  CMD="claude -c"  RSS=504MB  signal=TERM→KILL  result=exited
```

So issues are traceable.

---

## Step 4: Run purge

If the user says "run purge" / "execute purge":

```bash
sudo purge
```

Notes:
- This prompts for the user's password in the terminal (`sudo` password prompt, handled by macOS itself)
- After it runs, do not pretend "freed X GB" — `purge` doesn't report a freed amount. To see the effect, run `vm_stat | head -5` before and after.
- `purge` just immediately returns inactive memory; **no side effects** (caches rebuild on demand, slightly slower next access).

## Step 5: Error handling

| Situation | Action |
|-----------|--------|
| `scan.sh` exits 1 | Paste the stderr text verbatim to the user, don't try to patch with your own ps |
| `kill` denied (`kill: <PID>: Operation not permitted`) | Usually a SIP-protected system process. Suggest `sudo kill`, but **don't** sudo on the user's behalf |
| `Downloads` write fails | Report to the conversation as usual, warn "Not persisted this run: <reason>" |
| PID the user asked to kill doesn't exist | Report "PID X not found", continue with other PIDs |

## Related files

- `scan.sh` — scan engine
- `README.md` — user docs (thresholds / blacklist / output location)
- `DESIGN.md` — design doc (decisions and tradeoffs)

## Sister skills

- **mac-cleanup-process** — finds abnormal / stuck processes (orphans, over-aged, zombies). This skill answers "who is using memory", the process skill answers "who shouldn't be alive"
- **mac-cleanup-disk** — disk cache cleanup. This skill doesn't touch disk.
