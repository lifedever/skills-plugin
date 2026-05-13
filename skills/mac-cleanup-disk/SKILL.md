---
name: mac-cleanup-disk
description: macOS 磁盘深度清理与维护工作流，基于 tw93/mole 工具（brew install mole，命令名 mo）。触发词：清理 mac、清理系统、磁盘空间不足、磁盘满、清理缓存、卸载应用、磁盘分析、mole、mo clean、清理 node_modules、清项目构建产物、mac 维护、deep clean mac。安全策略：dry-run 优先 + 删除前必须用户文字确认。姊妹 skill：mac-cleanup-process（清进程，不动磁盘）。
---

# mac-cleanup-disk

基于 tw93/mole 的 macOS 维护工作流。**铁律：先预览、再确认、最后执行。任何删除动作前必须用户文字确认。**

## 0. 前置检查

任何流程之前，先确认 mole 已装：

```bash
which mo && mo --version
```

未装时**不要主动 `brew install`**——汇报"未安装 mole，需 `brew install mole`，是否继续？"，等用户同意再装。

## 1. 收到请求第一步：澄清模式

不要听到"清理 Mac"就动手。先把 4 种模式列给用户选：

| # | 模式 | 适用场景 | 主要命令 |
|---|------|----------|----------|
| 1 | 💨 日常清理 | 周期维护、清缓存日志 | `mo clean --dry-run` → `mo clean` |
| 2 | 🔍 深度清理 | 磁盘空间告急、彻底清 | `mo analyze` + `mo clean` + `mo installer` + `mo optimize` |
| 3 | 💻 开发者清理 | 清 `node_modules` / `target` / `venv` 等 | `mo purge` |
| 4 | 🩺 智能诊断 | 不确定要清啥，先看数据 | `mo status` + `mo analyze` + `mo clean --dry-run` |

如果用户明确知道要哪条命令（"我就想跑 mo clean"），跳过这一步直接进入安全流程。

## 2. TUI 限制（重要！）

以下 mole 子命令是**全屏 TUI 交互程序**，在 Claude Code 的 Bash 工具里跑会卡死、看不到内容、按键无效：

- `mo`（无参数主菜单）
- `mo analyze`
- `mo uninstall`
- `mo purge`
- `mo installer`
- `mo status`

**处理原则**：**让用户在自己终端里跑这些**。AI 不要代跑、不要 timeout 后强 kill。AI 的位置是：
- 帮用户**解读 TUI 的输出**（用户截屏或粘贴文本回来）
- **代跑非 TUI 命令**：`mo clean --dry-run`、`mo clean`、`mo optimize --dry-run`、`mo optimize`、`df -h`

## 3. 安全规则（不可妥协）

1. **destructive 操作前必须 `--dry-run`**：包括 `mo clean`、`mo optimize`、`mo uninstall`、`mo purge`、`mo installer`
2. **dry-run 输出后必须等用户文字回复**「执行 / 继续 / 确认 / OK」之类才能跑真版本——口头同意算，沉默不算
3. **跑深度清理前先问一句**："重要工作是否已保存？开发项目是否已 git commit？" mole 不会动这些，但万一用户误选 destructive 模式
4. **报错就停**：mo 任何命令非零退出，立即汇报错误，**不要重试 / 不要绕过 / 不要换命令**——可能是 mole bug 或权限问题，要用户判断
5. **永不主动跑** `mo uninstall`、`mo purge` —— 这两个删的可能是用户活跃文件，必须用户在 TUI 里亲手勾选

## 4. 各模式工作流

### 4.1 日常清理

```bash
df -h /                      # 当前磁盘占用快照
mo clean --dry-run           # 列出可清理项 + 总大小
```

把 dry-run 输出**完整呈现**给用户（不要省略文件类别），等确认 → `mo clean` → 跑完再 `df -h /` 对比释放空间。

### 4.2 深度清理（多步骤，逐步确认）

按顺序，**每步独立确认**：

1. **磁盘扫描**：让用户自己开终端跑 `mo analyze`，把 top-10 大目录贴回来
2. **缓存清理**：AI 跑 `mo clean --dry-run --debug` → 确认 → `mo clean`
3. **安装包清理**：让用户自己开终端跑 `mo installer`（TUI，自己勾选）
4. **系统优化**：AI 跑 `mo optimize --dry-run` → 确认 → `mo optimize`

每步完成都报告释放空间，问"是否继续下一步"。**不要一口气跑完。**

### 4.3 开发者清理

`mo purge` 是 TUI，让用户自己在终端跑，AI 帮不上忙。

如果用户**只想知道哪些项目目录占空间**，AI 可以用 `find` 替代扫描：

```bash
# 扫常见项目目录的 node_modules（按大小排）
find ~/Documents/Dev ~/Projects ~/GitHub -name node_modules -type d -prune 2>/dev/null \
  | xargs -I {} du -sh {} 2>/dev/null \
  | sort -hr | head -20
```

把结果给用户，让用户决定跑 `mo purge` 还是手动 `rm -rf` 具体目录。

### 4.4 智能诊断

```bash
df -h /                      # 磁盘整体情况
du -sh ~/Library/Caches ~/Downloads ~/.Trash 2>/dev/null   # 高频大户
mo clean --dry-run           # mole 的可清理项
```

根据数据给方案：
- 磁盘 >85% → 推荐**深度清理**
- 磁盘 60-85% → 推荐**日常清理**
- 发现 `node_modules` >5GB → 加推**开发者清理**

让用户选方案，再走对应模式。

## 5. mole 命令速查

| 命令 | 作用 | destructive | TUI |
|------|------|:-:|:-:|
| `mo status` | 系统监控（CPU/内存/磁盘） | - | ✓ |
| `mo analyze [path]` | 磁盘空间可视化 | △ | ✓ |
| `mo clean [--dry-run]` | 清缓存/日志/废纸篓 | **✓** | - |
| `mo uninstall` | 卸载应用 + 残留 | **✓** | ✓ |
| `mo optimize [--dry-run]` | 重建系统缓存 | △ | - |
| `mo purge` | 清项目构建产物 | **✓** | ✓ |
| `mo installer` | 清 .dmg/.pkg 安装包 | **✓** | ✓ |
| `mo touchid` | 配 sudo Touch ID | △ | - |

通用参数：`--dry-run` 预览、`--debug` 详细日志（含风险等级）、`--whitelist` 管理保护路径。

## 6. 清理后

执行真删除后**必跑** `df -h /` 对比释放空间，把"释放了 X GB，当前可用 Y GB"汇报给用户。这一步不能省——它是 sanity check。

## 7. 常见故障

| 现象 | 处理 |
|------|------|
| `mo: command not found` | `brew install mole` |
| 清理后应用启动变慢 | 正常，缓存首次重建一次后恢复 |
| 磁盘空间未释放 | `rm -rf ~/.Trash/*` 清废纸篓；重启释放交换文件 |
| `mo` 在 iTerm2 显示乱码 | 已知问题，换 Alacritty / kitty / WezTerm / Ghostty / Warp |

---

**核心心法**：你是助手不是清洁工。**说服用户在自己终端跑 TUI、把输出贴回来给你解读**，比硬代跑更可靠、出错成本更低。
