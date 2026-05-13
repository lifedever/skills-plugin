---
name: mac-cleanup-disk
description: macOS disk deep-clean and maintenance workflow, built on tw93/mole (brew install mole, CLI name `mo`). Trigger words "clean mac", "clean system", "disk full", "free up disk", "clear caches", "uninstall app", "disk analysis", "mole", "mo clean", "clean node_modules", "clean build artifacts", "mac maintenance", "deep clean mac", "清理 mac", "清理系统", "磁盘空间不足", "磁盘满", "清理缓存", "卸载应用", "磁盘分析", "清理 node_modules", "清项目构建产物", "mac 维护". Safety policy dry-run first + explicit user text confirmation before any deletion. Sister skill mac-cleanup-process (processes, never touches disk).
---

# mac-cleanup-disk

A macOS maintenance workflow based on tw93/mole. **Iron rule: preview first, confirm, then execute. Any deletion requires explicit user text confirmation.**

## 0. Pre-flight Check

Before any workflow, verify mole is installed:

```bash
which mo && mo --version
```

If it isn't installed, **don't proactively `brew install`** — report "mole not installed, requires `brew install mole`. Proceed?" and wait for the user to agree before installing.

## 1. First Step After a Request: Clarify the Mode

Don't jump in just because the user said "clean my Mac". Lay out the 4 modes first:

| # | Mode | When to use | Main commands |
|---|------|-------------|---------------|
| 1 | 💨 Daily clean | Periodic maintenance, clear caches and logs | `mo clean --dry-run` → `mo clean` |
| 2 | 🔍 Deep clean | Disk space tight, thorough sweep | `mo analyze` + `mo clean` + `mo installer` + `mo optimize` |
| 3 | 💻 Developer clean | Clean `node_modules` / `target` / `venv`, etc. | `mo purge` |
| 4 | 🩺 Smart diagnosis | Not sure what to clean — look at data first | `mo status` + `mo analyze` + `mo clean --dry-run` |

If the user already knows which command they want ("I just want to run mo clean"), skip this step and go straight to the safety flow.

## 2. TUI Restrictions (important!)

The following mole subcommands are **full-screen TUI interactive programs**. Running them via Claude Code's Bash tool will hang, show no content, and refuse keypresses:

- `mo` (no-args main menu)
- `mo analyze`
- `mo uninstall`
- `mo purge`
- `mo installer`
- `mo status`

**Handling principle**: **let the user run these in their own terminal**. The AI must not run them on the user's behalf, and must not timeout-then-kill. The AI's role is:
- Help **interpret the TUI output** (user screenshots or pastes text back)
- **Run non-TUI commands** on the user's behalf: `mo clean --dry-run`, `mo clean`, `mo optimize --dry-run`, `mo optimize`, `df -h`

## 3. Safety Rules (non-negotiable)

1. **Destructive operations must be preceded by `--dry-run`**: includes `mo clean`, `mo optimize`, `mo uninstall`, `mo purge`, `mo installer`
2. **After the dry-run output, wait for user text reply** like "go / continue / confirm / OK" before running the real version — verbal consent counts, silence does not
3. **Before deep clean, ask**: "Have you saved important work? Are dev projects committed?" mole won't touch those, but in case the user picked a destructive mode by mistake
4. **Stop on error**: any non-zero exit from a mo command — report the error immediately, **do not retry / do not work around / do not swap commands**. Could be a mole bug or permission issue, needs the user's judgment.
5. **Never proactively run** `mo uninstall`, `mo purge` — these may delete files the user is actively using; the user must hand-pick items in the TUI

## 4. Mode Workflows

### 4.1 Daily Clean

```bash
df -h /                      # current disk usage snapshot
mo clean --dry-run           # list cleanable items + total size
```

**Present the dry-run output in full** to the user (don't omit file categories). After confirmation → `mo clean` → run `df -h /` again to compare freed space.

### 4.2 Deep Clean (multi-step, confirm each step)

In order, **confirm each step independently**:

1. **Disk scan**: have the user run `mo analyze` in their own terminal and paste back the top-10 largest directories
2. **Cache clean**: AI runs `mo clean --dry-run --debug` → confirm → `mo clean`
3. **Installer cleanup**: have the user run `mo installer` themselves (TUI, hand-pick)
4. **System optimization**: AI runs `mo optimize --dry-run` → confirm → `mo optimize`

After each step, report freed space and ask "continue to next step?". **Don't run the whole sequence non-stop.**

### 4.3 Developer Clean

`mo purge` is a TUI — let the user run it in their terminal; the AI can't help.

If the user **just wants to know which project directories are eating space**, the AI can use `find` instead:

```bash
# Scan node_modules in common project directories (sorted by size)
find ~/Documents/Dev ~/Projects ~/GitHub -name node_modules -type d -prune 2>/dev/null \
  | xargs -I {} du -sh {} 2>/dev/null \
  | sort -hr | head -20
```

Hand the result to the user; they decide whether to run `mo purge` or `rm -rf` specific directories manually.

### 4.4 Smart Diagnosis

```bash
df -h /                      # overall disk usage
du -sh ~/Library/Caches ~/Downloads ~/.Trash 2>/dev/null   # frequent heavy consumers
mo clean --dry-run           # mole's cleanable items
```

Recommend based on the data:
- Disk >85% → recommend **deep clean**
- Disk 60-85% → recommend **daily clean**
- Found `node_modules` >5GB → also recommend **developer clean**

Let the user pick a mode, then proceed via the corresponding workflow.

## 5. mole Command Cheatsheet

| Command | Purpose | Destructive | TUI |
|---------|---------|:-----------:|:---:|
| `mo status` | System monitoring (CPU/mem/disk) | - | ✓ |
| `mo analyze [path]` | Disk-usage visualization | △ | ✓ |
| `mo clean [--dry-run]` | Clear caches/logs/trash | **✓** | - |
| `mo uninstall` | Uninstall app + residuals | **✓** | ✓ |
| `mo optimize [--dry-run]` | Rebuild system caches | △ | - |
| `mo purge` | Clean project build artifacts | **✓** | ✓ |
| `mo installer` | Clean .dmg/.pkg installers | **✓** | ✓ |
| `mo touchid` | Configure sudo Touch ID | △ | - |

Common flags: `--dry-run` to preview, `--debug` for verbose logs (including risk level), `--whitelist` to manage protected paths.

## 6. After Cleanup

After a real deletion, **always run** `df -h /` to compare freed space and report "freed X GB, now Y GB available" to the user. This step is non-negotiable — it's the sanity check.

## 7. Common Issues

| Symptom | Action |
|---------|--------|
| `mo: command not found` | `brew install mole` |
| App slow to launch after cleanup | Normal — caches rebuild once, then back to normal |
| Disk space didn't go down | `rm -rf ~/.Trash/*` to empty trash; reboot to release swap files |
| `mo` shows garbled output in iTerm2 | Known issue — try Alacritty / kitty / WezTerm / Ghostty / Warp |

---

**Core mindset**: you're an assistant, not a janitor. **Persuade the user to run the TUI in their own terminal and paste output back for you to interpret** — more reliable than running on their behalf, lower cost on error.
