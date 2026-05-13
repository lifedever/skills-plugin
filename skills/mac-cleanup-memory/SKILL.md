---
name: mac-cleanup-memory
description: 扫描 macOS 内存全景：系统快照（Free/Active/Inactive/Wired/Compressor/Swap）+ 压力等级 + Top RAM 大户（按 PID 和按 App 聚合）+ 客观观察（多个同名进程、可回收 inactive、swap 趋势等）。触发词：内存检查、看内存、查内存、谁占内存、内存压力、内存紧张、压缩器多大、check memory、memory pressure、ram usage、who is using memory、内存高、扫内存。skill 本身不 kill 任何进程，只做诊断。用户明示 PID 后才执行严格校验的 kill（PID 重用防护、TERM→KILL 升级、系统进程黑名单、双重确认）。姊妹 skill：mac-cleanup-process（异常/卡死进程）、mac-cleanup-disk（磁盘清理）。
---

# mac-cleanup-memory

诊断 macOS 内存状态的 skill，**纯诊断模式**。绝不主动 kill 任何进程。

## 触发后的执行流程

### 步骤 1：执行扫描脚本

```bash
bash ~/.claude/skills/mac-cleanup-memory/scan.sh
```

脚本会：
- stdout 输出完整 Markdown 报告
- tee 到 `~/Downloads/mac-cleanup-memory-<timestamp>.md`
- 成功 exit 0；失败 exit 1 并把诊断写到 stderr

### 步骤 2：呈现报告

**直接把 stdout 的 Markdown 内容原样贴给用户。** 允许在末尾补一两句观察（点出最值得注意的项），但：

- **严禁** 修改/伪造/遗漏报告里的数字（RSS、PID、压力等级）
- **严禁** 自己用 `ps aux | grep` 补充脚本没扫到的候选
- **严禁** 在报告里加"建议 kill 哪些"——这是用户的决定

### 步骤 3：等待用户指令

| 用户回复 | 处理 |
|---------|------|
| 不回复 / "好" / "知道了" | 什么都不做 |
| `kill <PID>` 或 `kill <PID1> <PID2>` | 走【Kill 安全协议】，逐个执行 |
| `执行 purge` / `跑 purge` | 执行 `sudo purge`（用户自己输密码）|
| `kill all WeChat` / `把微信全杀了` | **必须**先列出所有 PID + 命令让用户确认，不能直接 `pkill`/`killall` |
| `全部清理` / 模糊指令 | 反问"具体杀哪几个 PID？" |

---

## 🛡️ Kill 安全协议（核心，加粗）

每次执行 kill 前**逐 PID** 走完所有步骤。任何一步失败就 abort 这个 PID（不影响其它 PID）。

### 0. 活跃 session 强保护（最高优先级，2026-05-13 加）

`scan.sh` 输出的报告里，每个进程都带状态标记：
- 🟢 **IDE** —— IDE/编辑器关联（VSCode/Cursor/JetBrains/Xcode/Sublime 子进程，或路径含 `vscode/extensions/anthropic.claude-code`）
- 🟢 **TTY** —— 有 controlling terminal（用户在终端 tab 里看着）
- 🟡 **新** —— etime < 30 分钟
- 🔴 **孤儿** —— 真·僵尸（PPID=1 的 CLI 子进程类）
- — —— 普通

**铁律**：任何带 🟢 标记的 PID（IDE/TTY），用户说杀必须**让用户明确单独说出这个 PID 数字**才能动手。不接受这些模糊指令：

- ❌ "杀那几个 claude"
- ❌ "全杀"
- ❌ "杀掉 3 个"（即使前面列过 PID）
- ❌ "yes" / "确认" / "go"
- ❌ "把建议的都杀了"

**正确做法**：发现待杀名单里有 🟢 标记的 PID，单独 echo：

```
⚠️ PID 84807 是 🟢 IDE（VSCode claude，正在用）。如果真要杀，请单独输入：
   kill 84807
其它 🔴 / — 标记的 PID 我可以按你的批量指令处理。
```

**真孤儿（🔴）才允许批量**：用户说"杀所有孤儿"或"清掉 🔴"，可以批量执行（这些定义上就是死掉的进程残留）。

**反例（2026-05-13 事故）**：把 PPID=VSCode、etime=11 分钟、19 个活子进程的 `claude` 和真·孤儿 claude 一起列为"3 个旧 claude"建议杀，用户回"杀掉3个"就动手了 → 中断用户正在干的活。
**根因**：当时 scan.sh 还没分类标记，靠 Claude 在文本里识别 `vscode/extensions/` 关键字，但建议时没单独 highlight。**修复**：scan.sh 现在直接输出 🟢 标签，本规则要求看到 🟢 必须强制单 PID 确认。

### 1. 黑名单硬拒

以下 PID **绝不杀**，即使用户明示。回反问"你确认要杀 X 吗？如果真要请手动在终端跑"：

- PID 1 (launchd)
- 命令含 `kernel_task` / `WindowServer` / `loginwindow` / `launchd` / `mds` / `mds_stores`
- 当前 claude 会话 PID（用 `find_current_claude_pid` 逻辑，参考 mac-cleanup-process/scan.sh）

### 2. PID 重用校验（防误伤）

```bash
# 用户说要杀 PID X，扫描时记录的命令是 RECORDED_CMD
CURRENT_CMD="$(ps -p X -o command= 2>/dev/null)"
```

- 如果 `CURRENT_CMD` 为空：PID 已退出，汇报"PID X 已退出（可能被其它操作带走）"，跳过
- 如果 `CURRENT_CMD` 和扫描时记录的**不一致**（用 substring 校验，不要求完全相同——参数可能微变）：abort + 警告"PID X 已被新进程复用，当前是 `<新命令>`，已 abort"

### 3. 系统 UI 二次确认

如果命令路径含以下任一，**额外问一次**确认（即使不在硬黑名单）：

- `/System/Library/CoreServices/` → 系统服务
- `Finder.app` / `Dock.app` / `SystemUIServer.app` / `ControlCenter.app` → 桌面 UI（杀了能恢复，但用户 UI 会闪一下）
- `coreaudiod` / `bluetoothd` / `WiFiAgent` → 系统守护

```
"PID X 是 <App>，杀掉会让 <UI 行为> 短暂中断（系统会自动重启它）。继续吗？回 yes/no"
```

### 4. SIGTERM 优先，3 秒后才 SIGKILL

```bash
kill <PID>           # SIGTERM
sleep 3
if ps -p <PID> >/dev/null 2>&1; then
  echo "PID X 未响应 SIGTERM，升级 SIGKILL"
  kill -9 <PID>
  sleep 1
fi
ps -p <PID> >/dev/null 2>&1 && echo "⚠️ PID X 仍存活" || echo "✅ PID X 已退出"
```

理由：SIGTERM 给 app 机会保存数据；SIGKILL 是最后手段。微信/VSCode/Chrome 都有未保存状态。

### 5. 批量 kill 必须逐条 echo + 最终确认

如果用户一次说多个 PID，先打印一次确认表再动手：

```
你要 kill 的进程：
  PID 50484 → claude (RSS 500 MB)
  PID 74039 → claude -c (RSS 504 MB)
共 2 个，回 confirm 执行，回 cancel 取消。
```

收到 `confirm` 才执行。任何其它回复都视为 cancel。

### 6. 永远不用 pkill / killall / pkill -f

```bash
# ❌ 永远禁止
pkill -f "WeChat"        # 会匹到 WeChatAppEx, WeChatHelper, 任何路径含 WeChat 的进程
killall WeChat           # 同上
pkill -9 chrome          # 同上

# ✅ 只允许
kill <具体 PID>
kill -9 <具体 PID>       # 仅 SIGTERM 3 秒后未响应才升级
```

如果用户说"杀掉所有微信进程"：先用扫描数据列出每个 WeChat 相关 PID（或重新扫一次），让用户**逐个确认**或全选 confirm。

### 7. 操作落 audit log

每次实际执行 kill 后追加到 `~/Downloads/mac-cleanup-memory-killed-<date>.log`：

```
2026-05-13T13:55:32  PID=50484  CMD="claude"  RSS=500MB  signal=TERM  result=exited
2026-05-13T13:55:36  PID=74039  CMD="claude -c"  RSS=504MB  signal=TERM→KILL  result=exited
```

出问题能追溯。

---

## 步骤 4：执行 purge

如果用户说"跑 purge" / "执行 purge"：

```bash
sudo purge
```

注意：
- 这会让用户在终端被询问密码（`sudo` 弹密码框，由 macOS 自己处理）
- 跑完不要假装"释放了 X GB"——`purge` 不报告释放量。如果要看效果，跑前后各一次 `vm_stat | head -5`
- `purge` 只是让 inactive 立即归还，**没有副作用**（缓存会按需重建，下次访问稍慢一点点而已）

## 步骤 5：错误处理

| 情况 | 处理 |
|------|------|
| `scan.sh` exit 1 | 把 stderr 原文贴给用户，不自己用 ps 补救 |
| `kill` 权限不足（`kill: <PID>: Operation not permitted`）| 通常是受 SIP 保护的系统进程。建议跑 `sudo kill`，但**不**代跑 sudo |
| `Downloads` 写入失败 | 报告输出到对话照常，警告"本次未落盘：<原因>" |
| 用户说要杀的 PID 不存在 | 汇报"PID X 不存在"，继续处理其它 PID |

## 关联文件

- `scan.sh` — 扫描核心
- `README.md` — 用户文档（阈值/黑名单/输出位置）
- `DESIGN.md` — 设计文档（决策与权衡）

## 姊妹 skill

- **mac-cleanup-process** — 找异常/卡死进程（孤儿、超龄、僵尸）。本 skill 看的是"谁占内存"，process skill 看的是"谁不该活着"
- **mac-cleanup-disk** — 磁盘缓存清理。本 skill 不动磁盘
