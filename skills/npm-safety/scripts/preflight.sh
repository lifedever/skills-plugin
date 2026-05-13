#!/usr/bin/env bash
# Preflight check for npm-safety skill.
#
# Verifies that the socket CLI is installed and authenticated, then detects the
# project's package manager from its lockfile. All output is key=value lines on
# stdout so the calling skill can parse it; human-facing errors go to stderr.
#
# Exit codes:
#   0 — all good, parse stdout for socket_version / package_manager / lockfile
#   2 — missing prerequisite (socket not installed, or token not set)
#   3 — not a Node project (no package.json found at the target directory)

set -euo pipefail

TARGET_DIR="${1:-$PWD}"

if ! command -v socket >/dev/null 2>&1; then
    cat >&2 <<'EOF'
ERROR: socket CLI not installed.

Install it globally:

    npm install -g socket@latest

Then authenticate:

    1. Get an API token at https://socket.dev/ (sign in with GitHub)
    2. Add to your shell profile (~/.zshrc):
       export SOCKET_CLI_API_TOKEN="your-token-here"
    3. Reload: source ~/.zshrc
EOF
    exit 2
fi

socket_version=$(socket --version 2>/dev/null | head -n1 | tr -d '[:space:]')

# Probe auth state. `socket --help` prints a banner showing the token state to
# stderr without making a network call, so it's the cheapest way to check.
banner=$(socket --help 2>&1 || true)
if echo "$banner" | grep -qE "token: .?\(not set\)"; then
    cat >&2 <<'EOF'
ERROR: socket CLI installed but no API token configured.

Setup steps:

    1. Get an API token at https://socket.dev/ (free tier is enough for personal use)
    2. Add to your shell profile (~/.zshrc):
       export SOCKET_CLI_API_TOKEN="your-token-here"
    3. Reload: source ~/.zshrc

Alternative (interactive shell only):
    socket login
EOF
    exit 2
fi

if [ ! -f "$TARGET_DIR/package.json" ]; then
    echo "ERROR: no package.json found at $TARGET_DIR — not a Node project." >&2
    exit 3
fi

# Detect package manager. Lockfile presence is the source of truth.
# Order matters: pnpm > yarn > npm. If multiple lockfiles exist (mistake), the
# most specific one wins — pnpm/yarn lockfiles imply intent more clearly than
# package-lock.json, which npm creates by default.
pm="npm"
lockfile=""
if [ -f "$TARGET_DIR/pnpm-lock.yaml" ]; then
    pm="pnpm"
    lockfile="pnpm-lock.yaml"
elif [ -f "$TARGET_DIR/yarn.lock" ]; then
    pm="yarn"
    lockfile="yarn.lock"
elif [ -f "$TARGET_DIR/package-lock.json" ]; then
    pm="npm"
    lockfile="package-lock.json"
fi

# Fall back to packageManager field in package.json when no lockfile exists.
# This is the modern Corepack convention (e.g. "packageManager": "pnpm@9.7.0").
if [ -z "$lockfile" ]; then
    pm_field=$(grep -oE '"packageManager"[[:space:]]*:[[:space:]]*"[^"]+"' "$TARGET_DIR/package.json" 2>/dev/null | sed -E 's/.*"([^"@]+)@?.*/\1/' || true)
    case "$pm_field" in
        pnpm) pm="pnpm" ;;
        yarn) pm="yarn" ;;
        npm)  pm="npm" ;;
    esac
fi

echo "socket_version=${socket_version}"
echo "package_manager=${pm}"
echo "lockfile=${lockfile}"
echo "target_dir=${TARGET_DIR}"
