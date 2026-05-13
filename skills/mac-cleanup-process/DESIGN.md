# mac-cleanup-process 设计文档

**日期**：2026-04-24
**状态**：Design Approved，待实施
**作者**：brainstorming 会话产出（用户 + Claude 协作对齐）

---

## 1. 背景与目标

### 问题

macOS 日常使用中，长期运行后 `kernel_task` 经常飙到高 CPU，表现像散热问题，但真实根因往往是**内存压缩器被僵尸进程压垮**。典型罪魁：

- Claude Code 关闭 tab 但 claude 进程未正常退出，遗留一堆 MCP server 孤儿（PPID=1）
- Docker Desktop UI 退出后 `cagent` 后台进程未清理
- dev server（vite / pnpm dev / webpack）开完忘了关，挂几天甚至几周
- 终端 tab（任何 macOS 终端）累积 zsh，时间一长占资源

手动用 `ps | grep` 排查费时，编写 shell 脚本又怕规则写死误杀。

### 目标

交付一个 Claude Code skill `mac-cleanup-process`，在用户觉得系统卡时触发，做到：

1. **自动发现**上述各类候选进程，分"明确孤儿"和"可疑需判断"两级
2. **只诊断不动手** —— skill 本身绝不主动 kill
3. **生成可复制的 kill 命令**，用户自行决定执行方式（复制到终端 / 让 Claude 代跑）
4. **完整上下文呈现** —— 可疑项附带项目路径、运行时长、子进程数
5. **落盘报告** —— 方便事后回看

### 非目标

- 不做后台定时巡检（误杀风险，用户明确反对）
- 不做 Claude Code hook 自动触发（MVP 阶段 YAGNI）
- 不覆盖非当前用户的进程（系统进程永不扫）

---

## 2. 整体设计

### 2.1 目录结构

```
<skill-dir>/
├── SKILL.md           # skill 入口：description、frontmatter、交互流程指引
├── scan.sh            # 核心扫描脚本，所有判定规则写在这里
├── DESIGN.md          # 本文档
└── README.md          # 用户手动文档（说明如何调阈值）
```

### 2.2 触发方式

- **Slash command**：`/mac-cleanup-process`
- **自然语言关键词**（通过 SKILL.md frontmatter description 声明）：
  - 中文：清理僵尸进程、系统清理、MCP 孤儿、kernel_task 高、内存高、系统卡、扫僵尸
  - 英文：cleanup zombies, scan zombies, system cleanup, check mcp orphans

### 2.3 数据流

```
用户触发 (关键词/slash)
    ↓
Claude 加载 SKILL.md
    ↓
Claude 执行: bash <skill-dir>/scan.sh
    ↓
scan.sh 扫描 → 输出 Markdown 报告到 stdout
              → tee 到 ~/Downloads/mac-cleanup-process-<timestamp>.md
    ↓
Claude 直接呈现 stdout 内容（几乎零加工）
    ↓
用户查看报告，决定：
    (a) 不做任何事（最常见）
    (b) 回复 "执行明确孤儿清理" → Claude 执行建议命令块里的明确孤儿部分
    (c) 回复 "kill <PID1> <PID2>" → Claude 逐个 kill 指定 PID
    (d) 自己复制命令到终端执行（Claude 完全不介入）
```

---

## 3. 扫描规则（scan.sh 核心）

分两大类。所有阈值写在 `scan.sh` 顶部常量区，可改。

### 3.1 类别 A：明确孤儿（建议闭眼 kill）

| 子类 | 识别条件 |
|------|---------|
| **MCP server 孤儿** | `PPID=1` **且** 命令匹配以下任一：`npm exec.*mcp`、`mcp-server-*`、`@playwright/mcp`、`@upstash/context7-mcp`、`@modelcontextprotocol/*`、`@henkey/postgres-mcp-server`、`figma-developer-mcp`、`xcodebuildmcp`、`mcp-mongo-server`、`alibabacloud-devops-mcp-server`、`drawio/mcp`、`context7-mcp` |
| **MCP 孤儿子进程** | 上述 MCP 孤儿父进程的后代（`pgrep -P` 递归） |
| **Docker cagent 残留** | 进程名含 `cagent` **且** `pgrep -x Docker` 为空（Docker UI 未运行） |

### 3.2 类别 B：可疑需判断

| 子类 | 识别条件（默认阈值） |
|------|--------------------|
| **老 claude 会话** | 进程名 `claude` **且** `etime > 24h` |
| **长期 dev server** | 命令匹配 `vite\|webpack\|pnpm dev\|next dev\|nuxt dev\|npm run dev\|yarn dev\|rollup.*watch` **且** `etime > 2 天` |
| **长寿命终端 tab** | zsh 进程的父进程是 `/usr/bin/login`（终端 tab 内的 shell）**且** `etime > 3 天` |
| **大内存超龄** | RSS > 500 MB **且** `etime > 3 天` **且** 未被上述规则覆盖（去重） |

### 3.3 可调阈值（scan.sh 顶部常量）

```bash
OLD_CLAUDE_HOURS=24
OLD_DEV_SERVER_DAYS=2
OLD_SHELL_TAB_DAYS=3
BIG_MEM_RSS_MB=500
BIG_MEM_DAYS=3
```

### 3.4 守卫规则

**守卫 1：绝不把当前 claude 会话进程列入建议 kill 命令**
- 脚本通过 `$$ → $PPID` 向上追溯祖先，找到命令匹配 `claude` 的进程 PID
- 该 PID 在报告里打 `[当前会话·勿杀]` 标签
- 建议命令块自动排除它
- 追溯不到（用户在普通终端手动跑测试）则置 null，不做排除

**守卫 2：系统级进程绝不扫**
- 只处理 `UID == 当前用户 UID` 的进程
- 过滤掉 root、_windowserver、_driverkit 等系统账户

**守卫 3：命令行敏感信息脱敏**
- 报告和落盘 Markdown 中，命令里的 `scheme://user:password@host` 部分自动把密码替换成 `***`
- 防止 MongoDB 连接串、postgres 连接串等泄露

---

## 4. 输出格式

### 4.1 stdout（Claude 读取 + 用户看到）

脚本输出**完整 Markdown**，Claude 几乎零加工直接呈现。示例结构：

```markdown
# 🧹 系统僵尸扫描报告

**扫描时间**：2026-04-24 12:35:12
**系统快照**：Load 4.5 | 内存用 30G，压缩器 11.4G，空闲 1.3G
**预计可释放**：~2.1 GB（明确孤儿）+ ~1.8 GB（如清可疑项）

📄 完整结果已保存到 `~/Downloads/mac-cleanup-process-2026-04-24-123512.md`

---

## ✅ 明确孤儿（建议闭眼清理）

| 类别 | 数量 | PID 列表 |
|------|-----|---------|
| MCP 孤儿 | 10 | 2396, 8572, ... |
| MCP 孤儿子进程 | 12 | 2458, 8614, ... |
| Docker cagent 残留 | 51 | 35019, 35465, ... |

**合计 73 个进程，预计释放 ~2.1 GB**

---

## ⚠️ 可疑 —— 需要你判断

### ① 老 claude 会话（>24h）

- **PID 91608** [最可疑]
  - 项目：`~/code/some-old-project`
  - 运行时长：7 天 21 小时
  - 内存：106 MB（自身）+ ~400 MB（18 个 MCP 子进程）
  - 父进程链：终端 → zsh → claude

- **PID 19157** `[当前会话·勿杀]`
  - 项目：`~/code/current-project`
  - 运行时长：35 分钟

### ② 长期 dev server（>2 天）
...

### ③ 长期未关的终端 tab（>3 天）
...

### ④ 大内存超龄（RSS >500MB 且 >3 天）
...

---

## 💡 建议命令（复制即用）

```bash
# === 明确孤儿（可闭眼执行）===
kill 2396 8572 8641 ...
pkill -9 -f cagent

# === 可疑项（自行判断后取消注释）===
# kill 91608   # 老 claude 会话，7 天没关 → 会带走 18 个 MCP 子进程
# kill 3404    # vite dev server，挂了 13 天
```

---

**使用提示**：
- 建议命令块里已自动排除当前 claude 会话（PID 19157）
- 如果想让我执行，回复 `kill 2396 8572 ...` 或 `执行明确孤儿清理`
- 如果你自己复制到终端跑，我不会再做任何动作
```

### 4.2 落盘

- 位置：`~/Downloads/mac-cleanup-process-<timestamp>.md`
- 内容：**与 stdout 完全相同的 Markdown**（脚本通过 tee 同时写两端）
- 好处：Finder 预览 / VS Code / Typora 都能直接看，用户随时清理
- 不保留历史对比机制（用户明确说可随时清）

### 4.3 空结果处理

扫描没发现任何候选时，仍输出报告（"🎉 未发现僵尸，系统干净"），落盘照常 —— 便于用户查"今天几点扫过"。

---

## 5. 交互流程（SKILL.md 指引 Claude 的行为）

### 5.1 标准流程

1. **执行扫描**：`bash <skill-dir>/scan.sh`
2. **呈现报告**：把 stdout 原样呈现，允许补充少量上下文标签（如"最可疑"）
3. **等待用户指令**：不主动催促，不自动再扫

### 5.2 用户后续指令的处理

| 用户回复 | Claude 处理 | 是否需要二次确认 |
|---------|-----------|-----------------|
| 不回复 / "好" / "知道了" | 什么都不做 | - |
| `执行明确孤儿清理` / `一键清理` | 执行建议命令块里"明确孤儿"部分 | 否（报告已明示"可闭眼") |
| `kill <PID1> <PID2>`（PID 可空格或逗号分隔） | 逐个 `kill` | 否（用户点名了具体 PID） |
| `全部清理` / `清理所有可疑` 等模糊指令 | 反问"你是指也包括这些可疑项 [列表] 吗？" | 是 |
| `dry run` / `只看不动` | 重申"skill 本来就是纯诊断" | - |

### 5.3 kill 执行后验证

1. `sleep 2` 等内核回收
2. `ps -p <PID>` 验证目标确实退出
3. 简短汇报（前后内存对比）
4. **不** 自动再跑 scan

### 5.4 核心约束（SKILL.md 加粗强调）

1. **Claude 不得自作主张 kill**，只有用户明示后才动手
2. **Claude 不得修改 scan.sh 的事实数据**，报告数据严格来自脚本输出
3. **Claude 不得杀 `[当前会话·勿杀]` 标注的 PID**，即使用户明示。反问"你确认要杀当前会话吗？如果真要，请在终端手动执行"

---

## 6. 技术决策

### 6.1 实现方式

**方案：脚本 + 交互式命令生成**（brainstorming 中方案 3）
- `scan.sh` 输出完整 Markdown + 建议命令块
- Claude 只做格式化呈现和响应用户后续指令
- 理由：稳定、快速、可独立测试、误杀风险低

### 6.2 依赖

| 工具 | 用途 |
|-----|------|
| `ps` | 核心 |
| `pgrep` | 分类扫描 |
| `awk` | 过滤 |
| `lsof` | 项目路径推断（读 claude 进程 cwd） |
| `vm_stat` / `sysctl` | 系统快照（内存/压缩器/load） |

**纯 macOS 原生工具，零外部依赖**（不依赖 jq、不依赖 GNU 工具集）。

### 6.3 退出码

- `0`：扫描成功（包括"未发现僵尸"的正常情况）
- `1`：脚本自身错误（ps 失败 / 权限异常 / 系统工具缺失）

### 6.4 性能目标

单次扫描 < 3 秒。

---

## 7. 边界情况

| 情况 | 处理 |
|-----|------|
| 首次运行发现什么都没有 | 报告仍输出"🎉 未发现僵尸"，落盘照常 |
| 扫描过程中某 PID 已退出 | 容忍 `ps -p` 失败，跳过继续 |
| 同一天跑了多次 | Downloads 里多个带时间戳文件，用户自行清理 |
| Downloads 目录被删 | `mkdir -p ~/Downloads` 兜底 |
| PPID 追溯链中断（普通终端测试） | `current_claude_pid` 置 null，跳过排除 |
| 阈值不符合用户习惯 | 改 scan.sh 顶部常量 |
| 命令行含密码 | 自动脱敏 `://user:***@` |

---

## 8. 测试计划

MVP 阶段手动验证，不写自动化测试。

### 测试用例

1. **干净状态**：清完所有可疑后跑 skill，期望"未发现僵尸"
2. **伪造孤儿**：挂 `(sleep 10000) &; disown` 让 PPID=1 但命令不匹配 MCP 特征 → 期望不被识别
3. **真实场景**：像 2026-04-24 调试时那样的僵尸堆积下跑，对比人工调试的结论
4. **当前会话保护**：故意让 Claude 尝试 `kill <current_claude_pid>`，期望被守卫拦截
5. **脱敏**：手工起一个 `mongodb://user:pass@host` 命令，期望报告里是 `mongodb://user:***@host`

---

## 9. 演进预留（不在 MVP 做）

| 想法 | 何时可能会加 |
|-----|-------------|
| `--json` flag 强制输出 JSON | 想做"历史趋势分析"时 |
| Claude Code Stop/SessionEnd hook 集成 | 手动跑不够频繁时 |
| 排除列表（某个 PID/命令永不报告） | 某个"故意挂的"反复被误报时 |
| 更多 dev server watcher（rollup/turbo） | 发现漏识别时 |
| 其他 AI 工具的 MCP 识别 | 开始用其他 MCP 客户端时 |

---

## 10. 实施路径

交付物 = **3 个文件**：

1. `<skill-dir>/SKILL.md` —— 入口（frontmatter + 交互流程指引）
2. `<skill-dir>/scan.sh` —— 核心脚本
3. `<skill-dir>/README.md` —— 用户文档（讲阈值怎么调）

实施顺序建议：
1. 先写 `scan.sh`（核心功能）
2. 手动跑几次验证输出（用今天真实系统状态测）
3. 写 `SKILL.md` 指引 Claude 的交互行为
4. 写 `README.md`
5. 在真实"感觉卡"的场景再测一次端到端

实施计划（任务拆分）由后续 `writing-plans` skill 产出。
