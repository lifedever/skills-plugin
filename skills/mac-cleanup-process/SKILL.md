---
name: mac-cleanup-process
description: 扫描 macOS 僵尸/卡死进程（MCP server 孤儿、Docker cagent 残留、长期 dev server、老 claude 会话、长寿命终端 tab、大内存超龄），生成分级诊断报告 + 建议 kill 命令。触发词：清理僵尸进程、系统清理、MCP 孤儿、kernel_task 高、内存高、系统卡、扫僵尸、cleanup zombies、scan zombies、system cleanup、check mcp orphans、清进程、清卡死进程。skill 本身不 kill，只诊断 + 建议。姊妹 skill：mac-cleanup-disk（清磁盘缓存，不动进程）。
---

# mac-cleanup-process

诊断 macOS 僵尸进程的 skill，纯诊断模式。**绝不主动 kill 任何进程**。

## 触发后的执行流程

### 步骤 1：执行扫描脚本

```bash
bash "${CLAUDE_SKILL_DIR}/scan.sh"
```

脚本会：
- stdout 输出完整 Markdown 报告
- tee 到 `~/Downloads/mac-cleanup-process-<timestamp>.md`
- 成功 exit 0；失败 exit 1 并把诊断写到 stderr

### 步骤 2：呈现报告

**直接把 stdout 的 Markdown 内容原样贴给用户。** 允许补充一两句上下文观察（比如点明"最可疑"），但：

- **严禁** 修改/伪造/遗漏报告里的事实数据（PID、etime、命令）
- **严禁** Claude 自己用 `ps | grep` 补充脚本没扫到的候选
- 如果脚本输出"🎉 未发现僵尸"，直接汇报干净，结束

### 步骤 3：等待用户指令

按下表处理：

| 用户回复 | Claude 处理 | 是否二次确认 |
|---------|-----------|-------------|
| 不回复 / "好" / "知道了" | 什么都不做 | - |
| `执行明确孤儿清理` / `一键清理` | 执行建议命令块里"明确孤儿"部分所有 kill 命令 | **不需要**（报告已明示"可闭眼"） |
| `kill <PID1> <PID2>`（空格或逗号分隔） | 逐个 `kill`，PID 不存在就跳过继续 | **不需要** |
| `全部清理` / `清理所有可疑` 等模糊指令 | 反问"你是指也包括这些可疑项 [列出] 吗？" | **需要** |
| `dry run` / `只看不动` | 重申"skill 本来就是纯诊断" | - |

### 步骤 4：执行 kill 后验证

如果实际 kill 了：
1. `sleep 2` 等内核回收
2. `ps -p <PID>` 确认目标已退出
3. 简短汇报（前后内存对比，引用 `vm_stat` 的 compressor 数值）
4. **不** 自动再跑 scan（用户想再扫会主动说）

### 步骤 5：错误处理

| 情况 | 处理 |
|-----|------|
| `scan.sh` exit 1 | 把 stderr 原文贴给用户，不自己用 ps 补救 |
| kill 的 PID 已不存在 | 汇报"PID X 已退出（可能被刚杀的父进程带走）"，继续 |
| kill 权限不足 | 建议 `sudo`，但**不**代跑 sudo |
| Downloads 写入失败 | 报告输出到对话照常，警告"本次未落盘：<原因>" |

## 核心守卫（加粗！）

1. **Claude 不得自作主张 kill**。只有用户明示（命名 PID、说"一键清理"、说"执行明确孤儿清理"）才能动手。
2. **Claude 不得修改 scan.sh 输出的事实数据**。报告里的 PID/etime/命令/数字全部严格来自脚本。
3. **Claude 不得 kill `[当前会话·勿杀]` 标注的 PID**，即使用户明示。反问"你确认要杀当前对话进程吗？如果真要，请手动在终端执行"。

## 关联文件

- `scan.sh` — 扫描核心
- `DESIGN.md` — 设计文档
- `README.md` — 用户文档（阈值调整说明）
