---
name: npm-safety
description: >
  Vet npm / yarn / pnpm packages with socket.dev before they enter the project,
  and audit an existing project's full dependency tree. Auto-detects the
  project's package manager (npm / yarn / pnpm) and uses it for the actual
  install — the safety check is the wrapper, not the installer.
  Use when the user wants to add a dependency ("install lodash", "add vue-router",
  "pnpm add zod", "yarn add axios"), audit existing deps ("is my project safe",
  "scan dependencies", "扫一下依赖", "检查依赖安全"), or check a single package
  ("is X safe to install", "X 这个包有问题吗", "vet this package").
  Especially relevant when the package is unfamiliar, from a new author, or
  recently published.
---

# npm-safety

Vet npm-ecosystem packages with [socket.dev](https://socket.dev) before they enter the project. The skill is the orchestrator: it runs the safety checks, surfaces capability / supply-chain signals, and only then runs the project's own package manager for the actual install.

The skill is package-manager-aware. It detects whether the project uses **npm**, **yarn**, or **pnpm** from the lockfile and uses that one — it does not force `npm install`.

## When to use which command

| Situation | Command |
|---|---|
| User asks to add 1+ packages | `socket package shallow npm <a> <b> ...` (batch) or `socket package score npm <a>` (deep, single) |
| User asks for project-wide audit | `socket scan create` in the project root |
| User asks "is package X safe?" without intent to install yet | `socket package score npm <X> --markdown` |
| User asks to fix CVEs | `socket fix` (npm projects only — see [Caveats](#caveats)) |

## Workflow: pre-install vetting

This is the most common path. Follow it whenever the user asks to add a new dependency, regardless of the package manager they mention.

### Step 1 — Preflight

Run the preflight script from the project root the user is working in:

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/preflight.sh" "<project-dir>"
```

The script:

- Confirms `socket` CLI is installed (exit 2 with install hint if not)
- Confirms an API token is configured (exit 2 with setup hint if not)
- Detects package manager from lockfile (`pnpm-lock.yaml` > `yarn.lock` > `package-lock.json`), or from `packageManager` field in `package.json` as fallback
- Prints key=value pairs on stdout — parse `package_manager` and `lockfile`

If preflight exits non-zero, **stop and show the user the stderr message verbatim**. Do not attempt to install anything until they fix the prerequisite.

### Step 2 — Query Socket for risk signals

For a **single** package, use `socket package score` — it includes transitive dependency scores, which matters because most supply-chain risk lives in transitives:

```bash
socket package score npm <package-name> --markdown
```

For **multiple** packages in one shot (cheaper, but shallow — own package only):

```bash
socket package shallow npm <pkg-a> <pkg-b> <pkg-c> --markdown
```

Pin a specific version when the user requested one: `<name>@<version>`. The CLI accepts purl syntax too (`pkg:npm/<name>@<version>`).

### Step 3 — Read the signals

Socket reports six sub-scores out of 100 plus capabilities and alerts. What matters at install time:

- **Overall score < 50** — strongly worth flagging. Treat as a hard stop unless the user has a specific reason.
- **`vulnerability` < 100** — a known CVE exists. Surface the alert.
- **`supplyChain` < 70** — recently changed maintainer, install scripts, obfuscated code, or telemetry. The most common cause of *modern* npm investigations.
- **Capabilities containing `shell`, `network`, `filesystem`, `env`, `eval`** — the package can run shell commands / make network calls / read files / read env vars / use `eval`. Not automatically bad (eslint legitimately reads files), but worth telling the user.
- **Alerts with severity `critical` or `high`** — surface every one.

Lower-severity signals (`middle`, `low`) like `usesEval` on lodash are common and rarely actionable; mention them only if asked.

### Step 4 — Decision point

Summarize the findings to the user in this shape:

```
<package>@<version>: overall <N>/100
  - vulnerability: <N>   supplyChain: <N>   quality: <N>
  - capabilities: <list>
  - alerts (critical/high only): <list, or "none">
```

Then decide whether to ask the user before installing. Use `AskUserQuestion` if **any** of:

- Overall score < 70
- Any critical / high severity alert
- Any of these capabilities present: `shell`, `eval` (network / filesystem alone don't trigger — most legit libs have them)

Otherwise proceed with the install and just include the score line in your summary. The goal is to interrupt only when there's a real signal — most small utility packages score 70-79 due to maintenance penalties even when they're fine, and prompting on every one of them makes the skill annoying instead of useful.

### Step 5 — Install with the project's package manager

Use the `package_manager` value from preflight. Never substitute one PM for another.

| PM | Add command |
|---|---|
| `npm`  | `npm install <name>` (or `npm install -D <name>` for dev) |
| `yarn` | `yarn add <name>` (or `yarn add -D <name>`) |
| `pnpm` | `pnpm add <name>` (or `pnpm add -D <name>`) |

Preserve flags the user already gave (`-D`, `--save-exact`, version pin, workspace targeting like `pnpm add -F app-web`). Don't translate user intent across PMs — if they typed `pnpm add` but the lockfile is yarn, tell them about the mismatch instead of silently using yarn.

### Step 6 — Post-install audit (optional, only if user is onboarding a new project)

If this is the first time vetting this project, suggest one full project scan to baseline:

```bash
socket scan create
```

This uploads the manifest + lockfile to Socket and produces a report covering the whole dep tree. Don't run this every install — too noisy.

## Workflow: project-wide audit

When the user says "audit my deps" / "扫一下依赖" / "is my project safe":

1. Run preflight to confirm tooling
2. From project root: `socket scan create`
3. Surface the report URL the CLI prints; summarize critical/high alerts if any
4. If the user wants to fix vulns and the project is **npm**: offer `socket fix`. For yarn/pnpm, see [Caveats](#caveats).

## Workflow: standalone package check

User asks "is package X safe?" without intent to install:

```bash
socket package score npm <X> --markdown
```

Report the score + top alerts. Don't run preflight (no project context needed) — but if `socket` itself is missing, the command will fail with a clear error.

## Caveats

- **`socket npm install` wrapper only supports npm.** There's no `socket yarn` / `socket pnpm` install wrapper. The strategy in this skill — query first via `socket package score`, then install via the project's actual PM — works for all three because the scoring API is package-manager-agnostic (it talks about packages in the npm registry, not how you install them).
- **`socket fix` mutates npm projects only.** Running it in a pnpm/yarn project may add a `package-lock.json` or otherwise confuse the lockfile state. For non-npm projects, surface the alerts from `socket scan create` and let the user decide on a per-vuln basis (upgrade, override, or accept).
- **Private registries** (corporate npm mirrors, internal packages): Socket has no data for these and will return "package not found". Treat as unknown rather than safe. Tell the user the package wasn't in Socket's database and ask whether to proceed.
- **Quota costs.** `socket package score` costs 100 units per call (deep scan); `socket package shallow` costs 100 per call but takes a batch. Prefer `shallow` when checking many packages at once.
- **`socket login` is interactive only.** It cannot run inside the Claude Code Bash tool (non-TTY). If the preflight fails on auth, point the user at the `SOCKET_CLI_API_TOKEN` env var path or have them run `socket login` themselves in their terminal with the `!` prompt prefix.

## Failure modes

- `socket` not in PATH → preflight exits 2 with install hint
- token not configured → preflight exits 2 with setup hint
- Not a Node project (no `package.json`) → preflight exits 3 — don't attempt to install
- Socket API rate-limit or transient failure → retry once, then tell the user and skip the safety check rather than blocking their install (with an explicit note that the check was skipped)
- Package not found in Socket → could be private/internal, very new, or removed. Treat as unknown; ask the user.
