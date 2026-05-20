# skills-plugin

<h3 align="center">🧰 skills-plugin</h3>

<p align="center">
  <strong>A curated set of Claude Code skills for daily development.</strong><br>
  macOS dev utilities, runtime debugging, icon generation, localization, and system diagnostics — bundled into a single plugin with auto-updates.
</p>

<p align="center">
  <a href="https://github.com/lifedever/skills-plugin/tags"><img src="https://img.shields.io/github/v/tag/lifedever/skills-plugin?style=flat-square&color=34D399&label=Latest" alt="Latest"></a>
  <a href="https://github.com/lifedever/skills-plugin/stargazers"><img src="https://img.shields.io/github/stars/lifedever/skills-plugin?style=flat-square&color=F59E0B&label=Stars" alt="Stars"></a>
  <img src="https://img.shields.io/badge/skills-11-7C3AED?style=flat-square" alt="Skills">
  <img src="https://img.shields.io/badge/Claude%20Code-Plugin-FF6B35?style=flat-square" alt="Claude Code Plugin">
  <a href="./LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="License"></a>
</p>

<p align="center">
  <a href="#installation">⚡ <strong>Install</strong></a> ｜ <a href="https://www.lifedever.com/sponsor/">💖 <strong>Sponsor</strong></a>
</p>

<p align="center">
  <a href="README_zh.md">中文文档</a>
</p>

---

## Highlights

- **Eleven curated skills** the author uses daily — Swift app scaffolding, icon generation, runtime debugging, memory / disk / process diagnostics, parallel localization, npm supply-chain checks, and a meta browser to find the right skill when you've forgotten what you have
- **macOS-dev focused** — most skills target the everyday macOS workflow
- **One command to install all eleven** and they auto-update via the Claude Code plugin marketplace
- **Namespaced** under `/lifedever:<skill>` so they never collide with other plugins

## Skills included

| | Skill | What it does |
|---|---|---|
| 🎨 | `app-icon-generator` | Generate macOS / Windows / iOS / Tauri / Electron app icons from an SVG. Full pipeline: SVG → multi-size PNG → `.icns` / `.ico`. |
| ⚡ | `debug-mode` | Runtime debug workflow — insert log probes, collect runtime data, locate and fix bugs. Inspired by Cursor's Debug Mode. |
| 🚀 | `dev-launcher` | Generate a `dev.sh` script that starts frontend + backend together with interactive controls. |
| 🌍 | `localize` | Apply one content change across every language file in parallel using dispatched agents. |
| 💾 | `mac-cleanup-disk` | macOS disk maintenance workflow built on top of [`tw93/mole`](https://github.com/tw93/mole). Dry-run first, requires text confirmation before any deletion. |
| 🧠 | `mac-cleanup-memory` | Diagnose macOS memory pressure — system snapshot, top RAM consumers, Swap / Compressor analysis. Pure diagnostic, never kills processes on its own. |
| ♻️ | `mac-cleanup-process` | Scan macOS for zombie / stuck processes (MCP server orphans, stale dev servers, long-lived Claude sessions, etc.) and suggest kill commands. Pure diagnostic. |
| 🍎 | `macos-app-scaffold` | Generate a production-ready native macOS app scaffold (SwiftUI + SwiftData + SPM) with auto-update, dev/release build scripts, localization, and menu-bar persistence. |
| 🖼️ | `image-upload` | Upload images to your own GitHub repo, get jsDelivr CDN / GitHub raw / Markdown URLs back. Supports file paths, batch, and clipboard. Requires one-time env var setup — see [SKILL.md](./skills/image-upload/SKILL.md). |
| 🛡️ | `npm-safety` | Vet npm / yarn / pnpm packages with [socket.dev](https://socket.dev) before they hit your project. Auto-detects your package manager and uses it for the actual install — the safety check is the wrapper, not the installer. Requires one-time `socket` CLI + API token setup — see [SKILL.md](./skills/npm-safety/SKILL.md). |
| 🔎 | `skill-scan` | Browse and recommend across **all** locally installed skills (personal + plugin + project). Two modes: a concise categorized list, or scenario-based recommendation with narrowing questions. Solves the "I have too many skills, forgot which to use" problem. |

## Prerequisites per Skill

Most skills run as-is. A few need a one-time setup or an extra tool — install only the ones you'll actually use:

| Skill | Requirement | How |
|---|---|---|
| `image-upload` | **`IMAGE_HOST_REPO` env var** + `gh` CLI authenticated | `echo 'export IMAGE_HOST_REPO="<your-gh-user>/images"' >> ~/.zshrc && source ~/.zshrc && gh auth login` |
| `npm-safety` | `socket` CLI + **`SOCKET_CLI_API_TOKEN` env var** | `npm install -g socket@latest && echo 'export SOCKET_CLI_API_TOKEN="<your-token>"' >> ~/.zshrc && source ~/.zshrc` (get token at [socket.dev](https://socket.dev/)) |
| `mac-cleanup-disk` | [`tw93/mole`](https://github.com/tw93/mole) CLI | `brew install mole` |
| `app-icon-generator` | `librsvg` (required) + `Pillow` (optional, for `.ico`) | `brew install librsvg && pip3 install Pillow` |
| `macos-app-scaffold` | Xcode ≥ 16 (Swift 6.0 toolchain) | Install via App Store / Xcode releases |
| `debug-mode` | `node` (only for the optional HTTP log collector) | Already installed if you write JS/TS |

The remaining skills — `dev-launcher`, `localize`, `mac-cleanup-memory`, `mac-cleanup-process`, `skill-scan` — need no setup.

Each skill also detects its own missing prerequisites at runtime and prints a setup hint, so you can also just try one and follow the error message.

## Installation

In Claude Code, run:

```
/plugin marketplace add lifedever/skills-plugin
/plugin install lifedever@skills-plugin
/reload-plugins
```

The third command refreshes the current session so the new skills are picked up immediately. If you skip it, the skills only become available after restarting Claude Code.

Then invoke any skill via its namespaced name, e.g.:

```
/lifedever:debug-mode my login flow randomly drops the session
/lifedever:mac-cleanup-memory
/lifedever:app-icon-generator
```

### Updates

Claude Code checks for plugin updates roughly every 24 hours. To update manually:

```
/plugin update lifedever@skills-plugin
```

### Migrating from a standalone skill

If you previously installed any of these as a standalone skill (e.g. cloned into `~/.claude/skills/`), remove the local copy before installing this plugin to avoid duplicates:

```bash
rm -rf ~/.claude/skills/<skill-name>
```

`debug-mode` was previously available at [`lifedever/claudecode-debug-mode`](https://github.com/lifedever/claudecode-debug-mode); that repository is archived and superseded by this plugin.

## Requirements

- Claude Code (any recent version with plugin marketplace support)
- macOS for the `mac-cleanup-*`, `macos-app-scaffold`, and `app-icon-generator` skills
- [`mole`](https://github.com/tw93/mole) for `mac-cleanup-disk` (auto-checked at runtime)

## Sponsor

If these skills are useful to you, consider [sponsoring](https://www.lifedever.com/sponsor/) the developer to support ongoing maintenance.

## License

[MIT](./LICENSE) © [lifedever](https://github.com/lifedever)
