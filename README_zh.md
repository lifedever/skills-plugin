# skills-plugin

<h3 align="center">🧰 skills-plugin</h3>

<p align="center">
  <strong>日常开发用的 Claude Code 技能集</strong><br>
  macOS 开发工具、运行时调试、图标生成、多语言、系统诊断——打包成一个 plugin，支持自动更新。
</p>

<p align="center">
  <a href="https://github.com/lifedever/skills-plugin/tags"><img src="https://img.shields.io/github/v/tag/lifedever/skills-plugin?style=flat-square&color=34D399&label=%E6%9C%80%E6%96%B0%E7%89%88%E6%9C%AC" alt="最新版本"></a>
  <a href="https://github.com/lifedever/skills-plugin/stargazers"><img src="https://img.shields.io/github/stars/lifedever/skills-plugin?style=flat-square&color=F59E0B&label=Stars" alt="Stars"></a>
  <img src="https://img.shields.io/badge/%E6%8A%80%E8%83%BD%E6%95%B0-8-7C3AED?style=flat-square" alt="技能数">
  <img src="https://img.shields.io/badge/Claude%20Code-Plugin-FF6B35?style=flat-square" alt="Claude Code Plugin">
  <a href="./LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="License"></a>
</p>

<p align="center">
  <a href="#安装">⚡ <strong>立即安装</strong></a> ｜ <a href="https://www.lifedever.com/sponsor/">💖 <strong>捐赠支持</strong></a>
</p>

<p align="center">
  <a href="README.md">English</a>
</p>

---

## 为什么需要它

Claude Code 的 skill 机制很好用，但放在 `~/.claude/skills/` 下的自定义 skill 得手动 `git pull` 才能更新。这个 plugin 把 8 个常用 skill 打成一个 marketplace plugin：

- 一条命令安装
- Plugin marketplace 自动更新（每 24h 检查一次）
- 独立命名空间（`/lifedever:<skill>`），不会和其他 plugin 撞名

## 包含的技能

| | 技能 | 用途 |
|---|---|---|
| 🎨 | `app-icon-generator` | 从 SVG 生成 macOS / Windows / iOS / Tauri / Electron 应用图标。完整流水线：SVG → 多尺寸 PNG → `.icns` / `.ico`。 |
| ⚡ | `debug-mode` | 运行时调试流程——插入日志探针、收集运行时数据、定位修复 Bug。灵感来自 Cursor 的 Debug Mode。 |
| 🚀 | `dev-launcher` | 生成 `dev.sh` 启动脚本，一键拉起前后端，附带交互式控制（重启 / 状态 / 退出）。 |
| 🌍 | `localize` | 把单条内容变更并行同步到项目里所有语言文件，用子 Agent 加速。 |
| 💾 | `mac-cleanup-disk` | macOS 磁盘维护流程，基于 [`tw93/mole`](https://github.com/tw93/mole)。dry-run 优先，删除前必须用户文字确认。 |
| 🧠 | `mac-cleanup-memory` | 诊断 macOS 内存压力——系统快照、TOP 内存大户、Swap / 压缩器分析。**纯诊断**，绝不主动 kill 进程。 |
| ♻️ | `mac-cleanup-process` | 扫描 macOS 僵尸 / 卡死进程（MCP server 孤儿、过期 dev server、老 Claude 会话等），给出建议的 kill 命令。**纯诊断**。 |
| 🍎 | `macos-app-scaffold` | 生成生产级原生 macOS 应用脚手架（SwiftUI + SwiftData + SPM），包含自动更新、开发/发布构建脚本、本地化、菜单栏常驻等。 |

## 安装

在 Claude Code 里执行：

```
/plugin marketplace add lifedever/skills-plugin
/plugin install lifedever
```

之后通过带命名空间的方式调用 skill：

```
/lifedever:debug-mode 我的登录流程偶尔会丢 session
/lifedever:mac-cleanup-memory
/lifedever:app-icon-generator
```

### 更新

Claude Code 每 24h 左右自动检查 plugin 更新。手动触发：

```
/plugin update lifedever
```

### 从独立 skill 迁移

如果你以前是把某个 skill 单独 clone 到 `~/.claude/skills/` 用的，安装本 plugin 前先把老副本删掉避免重复：

```bash
rm -rf ~/.claude/skills/<skill-name>
```

`debug-mode` 原本在独立仓库 [`lifedever/claudecode-debug-mode`](https://github.com/lifedever/claudecode-debug-mode)，该仓库已归档，统一由本 plugin 接管。

## 系统要求

- Claude Code（任意支持 plugin marketplace 的近期版本）
- macOS 系统（`mac-cleanup-*`、`macos-app-scaffold`、`app-icon-generator` 这几个需要）
- [`mole`](https://github.com/tw93/mole)（`mac-cleanup-disk` 运行时自动检查）

## 捐赠支持

如果这些 skill 对你有帮助，欢迎 [捐赠支持](https://www.lifedever.com/sponsor/) 开发者持续维护。

## 协议

[MIT](./LICENSE) © [lifedever](https://github.com/lifedever)
