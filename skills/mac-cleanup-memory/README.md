# mac-cleanup-memory

macOS 内存状态扫描 skill。**只诊断，不 kill**。

姊妹 skill：[mac-cleanup-process](../mac-cleanup-process/SKILL.md)（异常/卡死进程）、[mac-cleanup-disk](../mac-cleanup-disk/SKILL.md)（磁盘清理）。三件套覆盖 macOS 维护的"内存 / 进程 / 磁盘"三个维度。

## 使用

**在 Claude Code 里：** 说"看一下内存"、"内存压力多大"、"谁在吃内存"等中英文触发词，skill 会自动触发。

**在终端独立跑：**

```bash
bash ~/.claude/skills/mac-cleanup-memory/scan.sh
```

完整报告会同时：
- 输出到 stdout
- 保存到 `~/Downloads/mac-cleanup-memory-<timestamp>.md`

## 报告内容

1. **系统快照** —— Free / Active / Inactive / Wired / Compressor / Purgeable / Swap
2. **压力等级对照表** —— Normal / Warning / Critical 阈值 + 当前所在区间
3. **Top RAM 大户（按进程）** —— 前 15 个 RSS 最大进程
4. **按 App 聚合** —— 把同一个 .app 下的所有进程合并（如 WeChat 主进程 + wxocr + 各种 helper 合并显示），方便看真实占用
5. **客观观察** —— 列举可疑模式（多个同名进程、大量 inactive、swap 高、压缩器满载等），**不评价不建议杀谁**

## 调整阈值

打开 `scan.sh`，修改顶部常量：

```bash
TOP_N=15                  # Top RAM 大户列前 N 个
APP_AGG_MIN_RSS_MB=100    # 按 app 聚合时低于此值不显示
DUP_PROCESS_MIN_COUNT=2   # 同名进程数 ≥ 此值时报告"重复进程"观察
```

改完直接生效，不需要重启任何东西。

## Kill 安全协议

skill 本身不 kill 进程。当用户明示 `kill <PID>` 时，Claude 会按 [SKILL.md](./SKILL.md#kill-安全协议核心加粗) 中的协议执行：

1. 黑名单硬拒（PID 1、kernel_task、WindowServer、当前 claude 会话）
2. PID 重用校验（杀前再次确认命令未变）
3. 系统 UI 二次确认（Finder/Dock 之类）
4. SIGTERM 优先，3 秒后才 SIGKILL
5. 批量 kill 必须逐条 echo + `confirm` 才动手
6. 永不用 `pkill -f` / `killall`（防模式误伤）
7. 操作落 audit log 到 `~/Downloads/mac-cleanup-memory-killed-*.log`

## 落盘文件清理

```bash
# 报告（每次扫描一份）
find ~/Downloads -name 'mac-cleanup-memory-*.md' -mtime +7 -delete

# audit log（每次 kill 操作累加）
find ~/Downloads -name 'mac-cleanup-memory-killed-*.log' -mtime +30 -delete
```

## 依赖

纯 macOS 自带工具：`vm_stat`、`sysctl`、`memory_pressure`、`ps`、`awk`、`sed`。
**零外部依赖**，不需要 `jq` / `brew install` 任何东西。

自适应 page size：Apple Silicon (16K) 和 Intel Mac (4K) 都正确换算。

## 压力等级阈值

参考 macOS `memory_pressure` 的 free percentage：

| Free % | 等级 | 含义 |
|--------|------|------|
| > 70% | Normal (健康) | 完全正常 |
| 40-70% | Normal (有压力) | 系统在边缘工作但稳定 |
| 10-40% | Warning | 该收拾东西了 |
| < 10% | Critical | 系统会主动 kill 大户 |

注意：这是简化模型。macOS 真实压力等级还涉及压缩率、swap 活动等，但 free percentage 作为粗略指示器够用。

## 与 mac-cleanup-process 的边界

| skill | 关注点 | 输出 |
|-------|--------|------|
| `mac-cleanup-memory` | **整体内存** + Top 占用大户 | 系统快照 + 大户排行 + 客观观察 |
| `mac-cleanup-process` | **异常**进程（孤儿/超龄/卡死） | 列 PID + 建议 kill 命令块 |

差别：memory 关心"现在内存什么状况、谁在吃"——即使所有进程都正常，内存也可能紧张；process 只关心"不该活着的东西"。

## Bash / awk 坑记录

- **awk 正则字符类内的 `/`**：`match(cmd, /\/[^/]+\.app\//)` 在某些 awk 版本下报 "extra ]"。改用 `index()` + `substr()` 函数式实现，规避正则解析差异
- **macOS page size 自适应**：Apple Silicon 是 16K，Intel 是 4K。**别硬编码**，用 `sysctl -n hw.pagesize`
- **vm.swapusage 输出格式**：`total = 4096.00M used = 2509.81M free = 1586.19M (encrypted)` —— 单位可能是 M 或 G，解析时要分辨
