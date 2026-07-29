---
name: dev-launcher
description: >
  Use when the user wants a single one-command script to start a project's
  frontend and backend together for local development.
  Triggers: "生成启动脚本", "帮我生成启动脚本", "写一个dev.sh", "写启动脚本",
  "前后端一起启动", "一键启动前后端", "一键启动脚本",
  "generate dev script", "create launch script", "one command to run frontend and backend".
---

# Dev Launcher

Generate a `dev.sh` script that starts frontend and backend together with interactive controls (restart, status, quit).

## Workflow

### 1. Detect project structure

Scan the project root to identify:

**Backend** (check in order, first match wins):
- `pom.xml` → Maven + Spring Boot
- `build.gradle` / `build.gradle.kts` → Gradle + Spring Boot
- `go.mod` → Go project
- `requirements.txt` / `pyproject.toml` → Python project

**Frontend package manager** (check in order):
- `pnpm-lock.yaml` → pnpm
- `yarn.lock` → yarn
- `package-lock.json` → npm

**Directory names**: List root to find server/client dirs. Common patterns: `*-server`/`*-client`, `backend`/`frontend`, `server`/`client`, `api`/`web`.

**Spring profile**: Check for `application-dev.yml`. If exists, default to `dev`. Respect user-specified profile.

**Frontend dev command**: Read `package.json` `scripts.dev` to confirm.

### 2. Fill template

Read [references/template.sh](references/template.sh) and replace all `{{...}}` placeholders.

| Placeholder | Description |
|---|---|
| `{{SERVER_DIR_NAME}}` | Server directory name |
| `{{CLIENT_DIR_NAME}}` | Client directory name |
| `{{SERVER_PGREP_PATTERN}}` | pgrep pattern uniquely identifying this project (abs-path fragment, not a bare common dir name) |
| `{{CLIENT_PGREP_PATTERN}}` | pgrep pattern uniquely identifying this project (abs-path fragment, not a bare common dir name) |
| `{{SERVER_START_LOG}}` | Log message for server start |
| `{{SERVER_START_CMD}}` | Full server start command |
| `{{CLIENT_START_LOG}}` | Log message for client start |
| `{{CLIENT_START_CMD}}` | Full client start command |
| `{{SERVER_EXTRA_PGREP}}` | Extra pgrep logic for Maven/Gradle, or remove line |

### 3. Backend variants

**Maven + Spring Boot:**
```
PATTERN: spring-boot:run.*{{DIR}}
CMD: mvn clean spring-boot:run -P{{PROFILE}} -Dspring-boot.run.profiles={{PROFILE}} -Dspring.output.ansi.enabled=ALWAYS
EXTRA_PGREP: local mvn_pids=$(pgrep -f "maven.*{{DIR}}" 2>/dev/null)
             pids=$(echo -e "${pids}\n${mvn_pids}" | sort -u | grep -v '^$')
```

> **Why `clean` and `-P`:** Maven resources filtering only copies `application-${profileActive}.yml` to target. Without `clean`, stale resource files in target may be used. Without `-P{{PROFILE}}`, the default active profile (often `local`) determines which yml files get copied, causing config mismatch when `spring-boot.run.profiles` differs.

**Gradle + Spring Boot:**
```
PATTERN: bootRun.*{{DIR}}
CMD: ./gradlew bootRun --args='--spring.profiles.active={{PROFILE}}'
EXTRA_PGREP: local gradle_pids=$(pgrep -f "gradle.*{{DIR}}" 2>/dev/null)
             pids=$(echo -e "${pids}\n${gradle_pids}" | sort -u | grep -v '^$')
```

**Go:** `PATTERN: go run.*{{DIR}}`, `CMD: go run .`, no extra pgrep.

**Python:** `PATTERN: python.*{{DIR}}`, `CMD: python manage.py runserver` (or uvicorn/flask), no extra pgrep.

### 4. Frontend variants

- **pnpm:** `FORCE_COLOR=1 pnpm dev`
- **yarn:** `FORCE_COLOR=1 yarn dev`
- **npm:** `FORCE_COLOR=1 npm run dev`

### 5. Critical rules

- **NEVER kill by port.** `lsof -i:PORT` matches client *connections* to that port too, not just the listener — feeding it to `kill` will take down unrelated apps. Match only by project-specific pgrep patterns.
- **All background commands MUST use `< /dev/null`** — prevents stdin conflicts with Vite/webpack keyboard shortcuts.
- **pgrep patterns MUST be uniquely identifying.** Anchor with an absolute-path fragment of the project (e.g. `spring-boot:run.*/abs/path/to/proj/server`), not just a bare directory name. If the dir name is a common word (`web`, `api`, `server`, `app`, `client`), a bare-name pattern will also match *other* projects' processes and kill them — always include enough of the path to be unique to this project.
- **Never escalate to `kill -9` on a stale PID list.** Between SIGTERM and SIGKILL a PID may be recycled by the OS; re-match by pattern before force-killing so you only ever `-9` processes that still belong to this project.

### 6. Output

Write to `./dev.sh`, run `chmod +x ./dev.sh`, show brief usage to user.
