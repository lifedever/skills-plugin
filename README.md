# skills-plugin

A curated set of [Claude Code](https://docs.claude.com/en/docs/claude-code) skills I use daily — macOS development utilities, runtime debugging, icon generation, localization, and system diagnostics.

Installed as a single Claude Code plugin. Auto-updates via the plugin marketplace.

## Installation

```
/plugin marketplace add lifedever/skills-plugin
/plugin install skills
```

Claude Code checks for plugin updates roughly every 24 hours. To update manually:

```
/plugin update skills
```

## Skills included

| Skill | What it does |
|---|---|
| `app-icon-generator` | Generate macOS / Windows / iOS / Tauri / Electron app icons from an SVG. Full pipeline: SVG → multi-size PNG → `.icns` / `.ico`. |
| `debug-mode` | Runtime debug workflow — insert log probes, collect runtime data, locate and fix bugs. Inspired by Cursor's Debug Mode. |
| `dev-launcher` | Generate a `dev.sh` script that starts frontend + backend together with interactive controls (restart, status, quit). |
| `localize` | Apply one content change across every language file in parallel using dispatched agents. |
| `mac-cleanup-disk` | macOS disk maintenance workflow built on top of [`tw93/mole`](https://github.com/tw93/mole). Dry-run first, requires text confirmation before any deletion. |
| `mac-cleanup-memory` | Diagnose macOS memory pressure — system snapshot, top RAM consumers (per-PID and per-app), Swap / Compressor analysis. Pure diagnostic, never kills processes on its own. |
| `mac-cleanup-process` | Scan macOS for zombie / stuck processes (MCP server orphans, stale dev servers, long-lived Claude sessions, etc.) and suggest kill commands. Pure diagnostic. |
| `macos-app-scaffold` | Generate a production-ready native macOS app scaffold (SwiftUI + SwiftData + SPM) with auto-update, dev/release build scripts, localization, and menu-bar persistence. |

## Migrating from a standalone skill

If you previously installed any of these as a standalone skill (e.g. by cloning into `~/.claude/skills/<name>/`), remove the local copy before installing this plugin to avoid duplicates:

```bash
rm -rf ~/.claude/skills/<skill-name>
```

Then run `/plugin install skills` and invoke skills via their namespaced names (e.g. `/skills:debug-mode`).

## License

[MIT](./LICENSE) © lifedever
