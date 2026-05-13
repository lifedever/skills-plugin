# mac-cleanup-process

macOS 僵尸/卡死进程扫描 skill。**只诊断，不 kill**。

姊妹 skill：[mac-cleanup-disk](../mac-cleanup-disk/SKILL.md) 负责磁盘清理。本 skill 只看进程。

## 使用

**在 Claude Code 里：** 说"扫一下僵尸"、"清理僵尸进程"、"系统卡"等中英文触发词，skill 会自动触发。

**直接跑脚本（绕过 Claude Code）：** 先用 `find` 定位 plugin 缓存中的脚本路径（版本号会变）：

```bash
bash "$(find ~/.claude/plugins/cache -name scan.sh -path '*mac-cleanup-process*' 2>/dev/null | sort | tail -1)"
```

完整报告会同时：
- 输出到 stdout
- 保存到 `~/Downloads/mac-cleanup-process-<timestamp>.md`

## 调整扫描阈值

打开 `scan.sh`，修改顶部常量：

```bash
OLD_CLAUDE_HOURS=24       # 老 claude 会话阈值（小时）
OLD_DEV_SERVER_DAYS=2     # 长期 dev server 阈值（天）
OLD_SHELL_TAB_DAYS=3      # 长寿命终端 tab 阈值（天，匹配任何 macOS 终端）
BIG_MEM_RSS_MB=500        # 大内存候选的 RSS 门槛（MB）
BIG_MEM_DAYS=3            # 大内存候选的 etime 门槛（天）
```

改完直接生效，不需要重启任何东西。

## 扩展 MCP server 识别规则

如果使用新的 MCP server，在 `scan.sh` 里找到 `MCP_PATTERN`，把新特征加到正则里：

```bash
readonly MCP_PATTERN='(npm exec.*mcp|mcp-server-|@playwright/mcp|...|your-new-mcp-pattern)'
```

## 落盘文件清理

`~/Downloads/mac-cleanup-process-*.md` 每次扫描都会新增一份。定期清理：

```bash
# 比如清理 7 天前的
find ~/Downloads -name 'mac-cleanup-process-*.md' -mtime +7 -delete
```

## 依赖

纯 macOS 自带工具：`ps`、`pgrep`、`awk`、`sed`、`lsof`、`vm_stat`、`sysctl`、`top`。
**零外部依赖**，不需要 `jq` / `brew install` 任何东西。

## 设计与实施

- `DESIGN.md` — 完整设计文档（背景、规则、边界情况、演进预留）
- `SKILL.md` — skill 入口（触发词 + Claude 交互流程指引）

## Bash 坑记录

- **CJK 标点紧邻变量引用**：`$var）`、`$var，` 等会让 bash 把中文字节当变量名延续，导致 `set -u` 下报 "unbound variable"。修复：用 `${var}` 显式界定（`${var}）`）。
