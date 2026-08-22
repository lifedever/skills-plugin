# skills-plugin

<h3 align="center">🧰 skills-plugin</h3>

<p align="center">
  <strong>日常开发用的 Claude Code 技能集</strong><br>
  macOS 开发工具、运行时调试、图标生成、专业绘图、多语言、系统诊断——打包成一个 plugin，支持自动更新。
</p>

<p align="center">
  <a href="https://github.com/lifedever/skills-plugin/tags"><img src="https://img.shields.io/github/v/tag/lifedever/skills-plugin?style=flat-square&color=34D399&label=%E6%9C%80%E6%96%B0%E7%89%88%E6%9C%AC" alt="最新版本"></a>
  <a href="https://github.com/lifedever/skills-plugin/stargazers"><img src="https://img.shields.io/github/stars/lifedever/skills-plugin?style=flat-square&color=F59E0B&label=Stars" alt="Stars"></a>
  <img src="https://img.shields.io/badge/%E6%8A%80%E8%83%BD%E6%95%B0-15-7C3AED?style=flat-square" alt="技能数">
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

## 亮点

- **15 个精选 skill**，作者日常都在用——Swift 应用脚手架、图标生成、运行时调试、第一性原理根因分析、对抗式代码审查、交付级流程图 / 架构图、应用干净卸载、内存 / 磁盘 / 进程诊断、多语言并行同步、npm 供应链安全检查，外加一个 meta 浏览器，装多了忘了用哪个就靠它
- **专注 macOS 开发场景**，覆盖日常高频工作流
- **一条命令装齐全部 15 个**，通过 Claude Code plugin marketplace 自动更新
- **统一命名空间** `/lifedever:<skill>`，不会和其他 plugin 撞名

## 包含的技能

| | 技能 | 用途 |
|---|---|---|
| 🎨 | `app-icon-generator` | 从 SVG 生成 macOS / Windows / iOS / Tauri / Electron 应用图标。完整流水线：SVG → 多尺寸 PNG → `.icns` / `.ico`。 |
| ⚡ | `debug-mode` | 运行时调试流程——插入日志探针、收集运行时数据、定位修复 Bug。灵感来自 Cursor 的 Debug Mode。 |
| 🚀 | `dev-launcher` | 生成 `dev.sh` 启动脚本，一键拉起前后端，附带交互式控制（重启 / 状态 / 退出）。 |
| 📐 | `diagram-pro` | 交付级业务流程图 / 技术架构图：手写 SVG 装进自包含 HTML，draw.io 视觉语法（标准形状 + 线性图标 + 必备图例），自带预览工具栏（缩放 / 网格 / PNG@2x / 纯净导出），交付前强制渲染回看校验。投标、汇报、文档配图用，Mermaid 撑不住排版的场合。 |
| 🌍 | `localize` | 把单条内容变更并行同步到项目里所有语言文件，用子 Agent 加速。 |
| 🗑️ | `mac-app-uninstall` | 列出所有已安装应用，并把选中的**卸载干净、不留残留**——可审计的 AppCleaner / CleanMyMac 替代品。把每一项残留分为「可安全删 / 待你确认 / 共享禁删」三档，覆盖 launchd 任务、特权 helper 和系统扩展，全部移入废纸篓可恢复。绝不执行 `sudo`，绝不执行 `rm`。 |
| 💾 | `mac-cleanup-disk` | macOS 磁盘维护流程，基于 [`tw93/mole`](https://github.com/tw93/mole)。dry-run 优先，删除前必须用户文字确认。 |
| 🧠 | `mac-cleanup-memory` | 诊断 macOS 内存压力——系统快照、TOP 内存大户、Swap / 压缩器分析。**纯诊断**，绝不主动 kill 进程。 |
| ♻️ | `mac-cleanup-process` | 扫描 macOS 僵尸 / 卡死进程（MCP server 孤儿、过期 dev server、老 Claude 会话等），给出建议的 kill 命令。**纯诊断**。 |
| 🍎 | `macos-app-scaffold` | 生成生产级原生 macOS 应用脚手架（SwiftUI + SwiftData + SPM），包含自动更新、开发/发布构建脚本、本地化、菜单栏常驻等。 |
| 🖼️ | `image-upload` | 把图片上传到你自己的 GitHub repo，返回 jsDelivr CDN / GitHub raw / Markdown 三种链接。支持文件路径、批量、剪贴板。首次需在 `~/.zshrc` 设 `IMAGE_HOST_REPO` 环境变量，详见 [SKILL.md](./skills/image-upload/SKILL.md)。 |
| 🛡️ | `npm-safety` | 用 [socket.dev](https://socket.dev) 在装包前校验 npm / yarn / pnpm 依赖的供应链安全。自动识别项目包管理器并用它来真正装包——安全检查是包装层，不替你装。首次需装 `socket` CLI + 配 API token，详见 [SKILL.md](./skills/npm-safety/SKILL.md)。 |
| 🧩 | `root-cause` | 第一性原理分析——强制从最基本的事实出发推导，而不是套用训练数据里的现成方案。用于调试找真正根因、架构决策、方案设计。 |
| 💥 | `break-it` | 对抗式审查——站在攻击者 / 极端用户的角度，在上线前找出 Bug、边界 case 和失败模式。功能 / 重构 / 复杂 Bug 修复完成后跑一遍。 |
| 🔎 | `skill-scan` | 浏览 + 推荐本地装的**所有** skill（个人 + 插件 + 项目级）。两种模式：分类清单（一行一个，突出核心使用场景），或按场景推荐（必要时反问 1-2 轮收敛）。解决"skill 装多了不知道用哪个"的痛点。 |

## 各 Skill 前置条件

大部分 skill 装上即用。少数需要一次性配置或装个额外工具——只装你会用到的那几个：

| Skill | 需要 | 怎么配 |
|---|---|---|
| `image-upload` | **`IMAGE_HOST_REPO` 环境变量** + `gh` CLI 已登录 | `echo 'export IMAGE_HOST_REPO="<你的 gh 用户名>/images"' >> ~/.zshrc && source ~/.zshrc && gh auth login` |
| `npm-safety` | `socket` CLI + **`SOCKET_CLI_API_TOKEN` 环境变量** | `npm install -g socket@latest && echo 'export SOCKET_CLI_API_TOKEN="<你的 token>"' >> ~/.zshrc && source ~/.zshrc`（在 [socket.dev](https://socket.dev/) 注册拿 token） |
| `mac-cleanup-disk` | [`tw93/mole`](https://github.com/tw93/mole) CLI | `brew install mole` |
| `app-icon-generator` | `librsvg`（必装）+ `Pillow`（可选，出 `.ico` 才需要） | `brew install librsvg && pip3 install Pillow` |
| `macos-app-scaffold` | Xcode ≥ 16（Swift 6.0 工具链） | App Store / Xcode 官网装 |
| `debug-mode` | `node`（只在用可选 HTTP 日志收集器时需要） | 写 JS/TS 的话一般都有 |
| `diagram-pro` | Google Chrome（或任意 Chromium）跑无头渲染校验；`Pillow` 可选，用于裁图 | `brew install --cask google-chrome && pip3 install Pillow` |

其余的 `dev-launcher`、`localize`、`mac-app-uninstall`、`mac-cleanup-memory`、`mac-cleanup-process`、`root-cause`、`break-it`、`skill-scan` 装上即用，无需配置。

每个 skill 运行时也会自检前置条件并给出友好提示，所以也可以直接试一下、按报错信息装就行。

## 安装

在 Claude Code 里执行：

```
/plugin marketplace add lifedever/skills-plugin
/plugin install lifedever@skills-plugin
/reload-plugins
```

第三条 `/reload-plugins` 刷新当前会话让新装的 skill 立即生效。如果跳过它，得等下次重启 Claude Code 才能用。

之后通过带命名空间的方式调用 skill：

```
/lifedever:debug-mode 我的登录流程偶尔会丢 session
/lifedever:mac-cleanup-memory
/lifedever:app-icon-generator
```

### 更新

Claude Code 每 24h 左右自动检查 plugin 更新。手动触发：

```
/plugin update lifedever@skills-plugin
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
