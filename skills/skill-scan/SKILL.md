---
name: skill-scan
description: >
  Browse and recommend across all locally installed Claude Code skills
  (personal + plugin + project). Use when the user wants to see what skills
  are available, has forgotten what they have, or asks which skill best fits
  a specific scenario.
  List-mode triggers: "list my skills", "what skills do I have",
  "show installed skills", "browse skills", "有哪些 skill", "本地 skill",
  "列一下 skill", "看下我装了什么 skill", "skill 清单", "/skill-scan".
  Recommend-mode triggers: "which skill should I use for X",
  "recommend a skill for X", "is there a skill that does Y",
  "我想做 X 用哪个 skill", "推荐一个 skill", "哪个 skill 能搞定 Y",
  "有没有处理 X 的 skill".
---

# skill-scan

Discover and recommend across the user's locally installed skills. Solves the "I have too many skills installed and don't remember which one to use" problem.

## Step 1 — Always scan first

Run the scan script to get the current inventory. Pass through the working directory so project-level skills are included:

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/scan.sh"
```

Output is TSV (`name\tsource\tpath\tdescription`) on stdout, plus a one-line summary on stderr. Sources: `project`, `personal`, or `plugin:<plugin-name>`. Same-named skills are deduplicated by priority (project > personal > plugin).

If the summary says `scanned 0 skills`, tell the user and stop — likely no install. Otherwise, continue.

## Step 2 — Decide mode from the user's phrasing

| User said | Mode |
|---|---|
| "list / browse / 有哪些 / 清单" type | **List** |
| Describes a scenario / asks "which skill for X" | **Recommend** |
| Ambiguous | Ask once: list, or scenario-based recommendation? |

## List mode

Emit a categorized inventory. Rules:

1. **No preamble.** Don't say "Here are your skills" — go straight into categories.

2. **Detect current project context, then order categories by relevance.** In `${PROJECT_DIR:-$PWD}`, check for:

   - Claude config: `CLAUDE.md`, `AGENTS.md`, `.claude/`, `.claude-plugin/`
   - Repo marker: `.git/`
   - Language manifests: `package.json`, `Package.swift`, `Cargo.toml`, `go.mod`, `pyproject.toml`, `requirements.txt`, `Gemfile`, `pom.xml`, `build.gradle`, `composer.json`
   - Container: `Dockerfile`, `docker-compose.yml`

   **Project mode** — any of the above exist:

   - Read `CLAUDE.md` (if present) plus the manifest filenames you found; infer the specific project type (e.g. "macOS Swift app", "Vue frontend", "Claude Code skills plugin", "Rust CLI", "Node monorepo").
   - Order: categories most-aligned with that project type first → general/utility categories middle → unrelated categories last.
   - Stat-line suffix: `· 已按当前项目（<inferred-type>）相关性排序`.

   **Environment mode** — NONE of the above exist (home dir, `~/Downloads`, scratch, etc.):

   - Order: system / maintenance / utility first (macOS 维护, 剪贴板 / 图床) → skill-mgmt and doc-sync middle → all dev workflows (Superpowers, Git/CR, Apple/Swift, frontend, build/release, project-specific) at the bottom.
   - Stat-line suffix: `· 未检测到项目上下文，按系统 / 通用工具优先排序`.

   Within a category, keep skill order stable (alphabetical or as scanned). Reordering is at the *category* level only.

3. **Categories are LLM-inferred** from the descriptions. Typical buckets: *macOS 维护 / 本机工具*, *Apple / Swift 开发*, *前端 / 开发脚手架*, *调试*, *构建 / 发版 / CI*, *Git / Code review*, *实施工作流（Superpowers）*, *Skill / Plugin 自动化管理*, *剪贴板 / 图床*, *多语言 / 文档同步*, *客户 / 项目专属*. Skip empty buckets. Don't invent a bucket for a single skill — group it with the closest neighbor.

4. **Each category header carries one emoji** chosen for fit; the skill lines under it stay emoji-free (emoji on every line creates visual clutter). Suggested mapping:

   - 🧹 macOS 维护 / 本机工具
   - 🍎 Apple / Swift 开发
   - 🎨 前端 / 开发脚手架
   - 🐛 调试
   - 🚀 构建 / 发版 / CI
   - 🔀 Git / Code review
   - 🧭 实施工作流（Superpowers）
   - 🧩 Skill / Plugin 自动化管理
   - 📎 剪贴板 / 图床
   - 🔁 多语言 / 文档同步
   - 🏢 客户 / 项目专属

5. **One line per skill**, format:

   ```
   · <name> — <core use case in one sentence>
   ```

6. **The one-liner must answer "when do I use this?"** — distill from the description, do NOT copy it verbatim. Drop trigger-word lists, emoji, marketing language. Keep concrete signals (platform, file type, "before X / after Y").

   - ❌ Vague: `debug-mode — 调试工具`
   - ❌ Lazy verbatim: `debug-mode — Runtime debug mode - insert log probes, collect runtime data...`
   - ✅ Useful: `debug-mode — 运行时插探针定位 race condition / 内存泄漏 / 偶发 bug，静态分析搞不定时用`

7. **Source tag** only when ambiguity matters. Add `(project)` or `(personal)` suffix only if a name collision was hidden by dedup, or if the user explicitly asks about source. Plugin skills get no tag by default.

8. **End with one stat line**, terse: `<N> skills · <K> categories` + the context-aware suffix from rule 2 (only when context was detected — in the indeterminate case, just `<N> skills · <K> categories`).

That's it. No "let me know if..." trailing question.

## Recommend mode

Goal: surface 1–3 best-fit skills for the user's scenario, with enough info that they can invoke directly next time without going through skill-scan.

**Round 1:**

1. Read the user's scenario. Score each scanned skill internally (don't show scores).
2. If the top candidate is clearly dominant (only one skill matches the platform/domain), skip to output.
3. If top 2–3 candidates are plausible and disambiguating questions would help, ask **at most one** narrowing question (e.g., "is this for macOS or Linux?", "CLI or in-code?", "do you already have X installed?"). Use `AskUserQuestion` with 2–4 concrete options.
4. **Cap at 2 rounds total.** If still unclear, present the 2–3 candidates with their differences and let the user pick.

**Output format per recommended skill:**

```
<name>  ← why this fits
  • 触发词: <one or two phrases that auto-activate it in future conversations>
  • 前置: <prerequisites if any, else "无">
  • 适用: <the scenario sentence that matched>
```

If no skill matches well, say so plainly:

> 本地装的 skill 里没有专门处理这个的。可以用 `/skill-creator` 创建一个，或者直接告诉我具体步骤我手动做。

Do not pad with low-confidence suggestions.

## Edge cases

- **0 skills scanned** → check `~/.claude/skills` and `~/.claude/plugins/cache` exist; report which is missing.
- **Skill name collisions across sources** → dedup keeps highest-priority; mention in list mode only if the user asks about sources.
- **Missing frontmatter** → script skips silently, stderr reports count. Don't surface this unless the count is large.
- **Description in a language the user isn't using** → translate the one-liner to the user's language, don't quote the original.

## Why scan every time (no cache)

Skills get added, removed, and bumped (plugin versions) frequently. A stale cache would silently miss new skills or recommend a version that doesn't exist anymore. The scan takes well under a second for typical installs.
