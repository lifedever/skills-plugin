#!/usr/bin/env bash
# mac-app-uninstall scan.sh — locate a macOS app and every leftover it owns.
# READ-ONLY. This script never deletes, moves, or modifies anything.
# See DESIGN.md in the same directory for the tiering rules.

set -u
set -o pipefail

# ===== Infrastructure =====
timestamp="$(date +%Y-%m-%d-%H%M%S)"
# Output dir is resolved after lib.sh is sourced (mau_out_dir lives there).
output_dir=""

# Written by report(); the manifest is what uninstall.sh consumes.
report_file=""
manifest_file=""

usage() {
  cat >&2 <<'EOF'
用法: scan.sh <应用名 | bundle id | /path/to/App.app>

示例:
  scan.sh Slack
  scan.sh com.tinyspeck.slackmacgap
  scan.sh "/Applications/Google Chrome.app"

只读，不修改任何内容。生成分级残留报告 + 供 uninstall.sh 使用的清单，
写入 ~/Downloads/mac-app-uninstall/ 并自动用 Typora 打开。
EOF
}

if [ $# -lt 1 ]; then
  usage
  exit 2
fi

TARGET_INPUT="$*"

# Pre-flight: these are all base-system tools, but fail loudly if absent.
for tool in plutil find du awk sed grep; do
  if ! command -v "$tool" > /dev/null 2>&1; then
    echo "错误: 缺少必需的命令 '$tool'" >&2
    exit 1
  fi
done

# ===== Shared helpers =====
# Sourced so scan.sh and list-apps.sh cannot drift apart on how an app bundle is
# read or how the census is built.
MAU_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -f "$MAU_LIB_DIR/lib.sh" ]; then
  echo "错误: 未找到 lib.sh（应与 scan.sh 同目录: ${MAU_LIB_DIR}）" >&2
  exit 1
fi
# shellcheck source=lib.sh
. "$MAU_LIB_DIR/lib.sh"

# ===== Step 1: Census every installed app =====
# Built FIRST, because everything downstream depends on it: resolving the target,
# deciding who owns a leftover, and detecting duplicate installs. Enumerating the
# app directories ourselves replaces what used to be a Spotlight query — mdfind's
# query language has no shell-side escaping, which cost two injection surfaces and
# a 120s hang. A plain directory walk has neither problem and does not depend on
# the Spotlight index being healthy.
#
# /System/Applications is included deliberately: Apple's bundle ids must be in the
# ownership table, or an Apple leftover could be attributed to the target instead.

CENSUS_FILE="$(mktemp -t mau_census)"
trap 'rm -f "$CENSUS_FILE"' EXIT

census_count="$(build_census "$CENSUS_FILE")"

# ===== Step 2: Resolve the target =====
# Only two forms are accepted: a path to a bundle, or an exact bundle id / app
# name found in the census. Fuzzy matching is deliberately NOT done here — the
# calling agent is far better at "did you mean Chrome or Chrome Canary?" and can
# just ask. Guessing in this script is how an unrelated app's data ends up in a
# removal manifest.

APP_PATH=""

resolve_app() {
  local input="$1" bid nm path linput

  # 2a. A path to a real bundle.
  if [ -d "$input" ] && [ -n "$(info_plist_for "$input")" ]; then
    APP_PATH="$input"
    return 0
  fi

  # 2b. Exact bundle id.
  while IFS=$'\t' read -r bid nm path; do
    [ -n "$bid" ] || continue
    if [ "$bid" = "$input" ]; then
      APP_PATH="$path"
      return 0
    fi
  done < "$CENSUS_FILE"

  # 2c. Exact app name, case-insensitive.
  linput="$(lower "$input")"
  while IFS=$'\t' read -r bid nm path; do
    [ -n "$nm" ] || continue
    if [ "$(lower "$nm")" = "$linput" ]; then
      APP_PATH="$path"
      return 0
    fi
  done < "$CENSUS_FILE"

  return 1
}

APP_FOUND=1
if resolve_app "$TARGET_INPUT"; then
  APP_FOUND=0
fi

# ===== Step 2: Identity =====

BUNDLE_ID=""
APP_NAME=""
APP_VERSION=""
APP_SIZE="-"
INSTALL_SOURCE="未知"

if [ $APP_FOUND -eq 0 ]; then
  APP_PLIST="$(info_plist_for "$APP_PATH")"
  if [ -n "$APP_PLIST" ]; then
    BUNDLE_ID="$(plist_get "$APP_PLIST" CFBundleIdentifier)"
    APP_VERSION="$(plist_get "$APP_PLIST" CFBundleShortVersionString)"
  fi
  APP_NAME="$(basename "$APP_PATH" .app)"
  APP_SIZE="$(path_size "$APP_PATH")"
else
  # App already gone — the user may be cleaning up leftovers of a deleted app.
  # Treat the input as an identity hint directly.
  case "$TARGET_INPUT" in
    *.*.*) BUNDLE_ID="$TARGET_INPUT" ;;
    *) APP_NAME="$TARGET_INPUT" ;;
  esac
fi

[ -z "$APP_NAME" ] && APP_NAME="$TARGET_INPUT"

# Glob-escaped bundle id, used in every find pattern below. Computed once.
BID_GLOB=""
[ -n "$BUNDLE_ID" ] && BID_GLOB="$(escape_glob "$BUNDLE_ID")"

# ===== Step 3: Safety gates =====
# These decide whether the uninstall may proceed at all.

GATE_BLOCK=""      # hard stop reasons
GATE_WARN=""       # proceed-with-care reasons

add_block() { GATE_BLOCK="${GATE_BLOCK}$1"$'\n'; }
add_warn() { GATE_WARN="${GATE_WARN}$1"$'\n'; }

# 3a. Apple system apps are off limits.
case "$BUNDLE_ID" in
  com.apple.*)
    add_block "**这是 Apple 系统应用**（\`$BUNDLE_ID\`）。本工具拒绝卸载 Apple 签名的系统软件——删除可能导致系统异常，而且大部分位于只读的系统卷上，本来也删不掉。"
    ;;
esac
case "$APP_PATH" in
  /System/*)
    add_block "位于**只读系统卷**上（\`$APP_PATH\`），即使用 sudo 也无法删除。"
    ;;
esac

# 3b. Setapp-managed apps must go through Setapp.
case "$APP_PATH" in
  */Applications/Setapp/*)
    add_block "**这是 Setapp 托管的应用**。请在 Setapp 客户端里卸载——直接删除会让 Setapp 的数据库状态不一致，而且它会悄悄把应用装回来。"
    ;;
esac

# 3c. Homebrew cask — brew has its own zap that also handles leftovers.
BREW_CASK=""
if command -v brew > /dev/null 2>&1; then
  brew_prefix="$(brew --prefix 2>/dev/null)"
  if [ -n "$brew_prefix" ] && [ -d "$brew_prefix/Caskroom" ]; then
    while IFS= read -r caskdir; do
      [ -n "$caskdir" ] || continue
      cask_name="$(basename "$caskdir")"
      # Match the cask by the app bundle it ships.
      if [ -n "$APP_PATH" ] && find "$caskdir" -maxdepth 3 -name "$(escape_glob "$(basename "$APP_PATH")")" -print -quit 2>/dev/null | grep -q .; then
        BREW_CASK="$cask_name"
        break
      fi
      if [ "$(lower "$cask_name")" = "$(lower "$APP_NAME")" ]; then
        BREW_CASK="$cask_name"
        break
      fi
    done < <(find "$brew_prefix/Caskroom" -maxdepth 1 -mindepth 1 -type d 2>/dev/null)
  fi
fi
if [ -n "$BREW_CASK" ]; then
  INSTALL_SOURCE="Homebrew cask（\`$BREW_CASK\`）"
  add_warn "**通过 Homebrew cask 安装**（\`$BREW_CASK\`）。建议改用 \`brew uninstall --zap --cask $BREW_CASK\`——它会同时清掉 cask 作者声明的残留，并保持 brew 状态一致。手动删除会让 brew 仍以为该应用还装着。"
fi

# 3d. Mac App Store receipt. Wrapped iOS apps keep theirs inside the wrapper.
if [ $APP_FOUND -eq 0 ] &&
   { [ -f "$APP_PATH/Contents/_MASReceipt/receipt" ] || [ -f "$APP_PATH/WrappedBundle/_MASReceipt/receipt" ]; }; then
  INSTALL_SOURCE="Mac App Store"
  add_warn "**来自 Mac App Store**，随时可以重新下载。但下面这些残留里如果存有内购/授权状态，删除后就没了。"
fi

# 3e. iOS/iPadOS app running on Apple Silicon.
if [ $APP_FOUND -eq 0 ] && [ -d "$APP_PATH/Wrapper" ]; then
  INSTALL_SOURCE="iOS/iPadOS 应用（Designed for iPad）"
  add_warn "**这是跑在 Apple Silicon 上的 iOS/iPadOS 应用**。它的数据存放在 \`~/Library/Containers/$BUNDLE_ID\`，而不是 macOS 应用的常规位置。"
fi
if [ "$INSTALL_SOURCE" = "未知" ] && [ $APP_FOUND -eq 0 ]; then
  INSTALL_SOURCE="直接下载 / 安装包"
fi

# 3e. Running processes — deleting a running app leaves it able to rewrite prefs on quit.
RUNNING_PIDS=""
if [ $APP_FOUND -eq 0 ]; then
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    RUNNING_PIDS="${RUNNING_PIDS}${pid} "
  done < <(pgrep -f "^$(escape_ere "$APP_PATH")/" 2>/dev/null)
fi
if [ -n "$BUNDLE_ID" ]; then
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    case " $RUNNING_PIDS " in
      *" $pid "*) ;;
      *) RUNNING_PIDS="${RUNNING_PIDS}${pid} " ;;
    esac
  done < <(pgrep -f "$(escape_ere "$BUNDLE_ID")" 2>/dev/null)
fi
# Never report our own scan process or its parents.
FILTERED_PIDS=""
for pid in $RUNNING_PIDS; do
  [ "$pid" = "$$" ] && continue
  [ "$pid" = "$PPID" ] && continue
  FILTERED_PIDS="${FILTERED_PIDS}${pid} "
done
RUNNING_PIDS="$FILTERED_PIDS"

# A second install of the *same* bundle id (e.g. /Applications and ~/Applications)
# means every leftover below is still live data for that other copy.
DUPLICATE_INSTALL=""
if [ -n "$BUNDLE_ID" ]; then
  while IFS=$'\t' read -r c_bid c_nm c_path; do
    [ "$c_bid" = "$BUNDLE_ID" ] || continue
    [ "$c_path" = "$APP_PATH" ] && continue
    DUPLICATE_INSTALL="yes"
    break
  done < "$CENSUS_FILE"
fi
if [ -n "$DUPLICATE_INSTALL" ]; then
  add_warn "**本机还装着另一份 \`$BUNDLE_ID\`**。它和你要删的这份共用同一批配置和数据，因此不会有任何项被标记为「可安全删除」——请逐条人工确认。"
fi

# Returns the MOST SPECIFIC bundle id that owns this basename, considering every
# installed app plus the target itself. Ownership = the basename equals that
# bundle id or sits under its "<id>." namespace.
#
# "Most specific wins" is what resolves the two-way ambiguity between an app and
# a sibling that lives inside its namespace. With com.x.App and com.x.App.dev
# both installed:
#   base=com.x.App.dev      -> App matches (prefix), App.dev matches (exact)
#                              -> longest is App.dev, so it belongs to the dev app
#   base=com.x.App.plist    -> only App matches -> belongs to App
# A naive "does any other app match" test gets both of these wrong in opposite
# directions, which is exactly the bug this replaced.
owner_of() {
  local base="$1" best="" bid nm path probe cand

  # Group Containers are "<TEAMID>.<bundle id>". Strip a leading 10-char team id
  # so the comparison can see the real bundle id underneath.
  probe="$base"
  case "$base" in
    ??????????.*) probe="${base#??????????.}" ;;
  esac

  for cand in "$base" "$probe"; do
    while IFS=$'\t' read -r bid nm path; do
      [ -n "$bid" ] || continue
      # The target's own bundle is not a third-party claimant.
      [ -n "$APP_PATH" ] && [ "$path" = "$APP_PATH" ] && continue
      case "$cand" in
        "$bid" | "$bid".*)
          [ ${#bid} -gt ${#best} ] && best="$bid"
          ;;
      esac
    done < "$CENSUS_FILE"

    if [ -n "$BUNDLE_ID" ]; then
      case "$cand" in
        "$BUNDLE_ID" | "$BUNDLE_ID".*)
          [ ${#BUNDLE_ID} -gt ${#best} ] && best="$BUNDLE_ID"
          ;;
      esac
    fi
  done

  printf '%s' "$best"
}

# ===== Step 5: Collect leftover candidates =====

# Candidate records accumulate as TAB-separated lines: tier \t path \t reason
CANDIDATES_FILE="$(mktemp -t mau_cand)"
SEEN_FILE="$(mktemp -t mau_seen)"
SKIPPED_FILE="$(mktemp -t mau_skip)"
trap 'rm -f "$CENSUS_FILE" "$CANDIDATES_FILE" "$SEEN_FILE" "$SKIPPED_FILE"' EXIT

# classify + record a single path.
consider() {
  local p="$1" why="${2:-Bundle ID 精确匹配}" base owner
  [ -e "$p" ] || return 0

  # Never propose the target bundle itself here (handled separately).
  [ "$p" = "$APP_PATH" ] && return 0

  # Dedupe.
  if grep -qxF "$p" "$SEEN_FILE" 2>/dev/null; then return 0; fi
  printf '%s\n' "$p" >> "$SEEN_FILE"

  if ! path_is_manifest_safe "$p"; then
    printf '%s\n' "$p" >> "$SKIPPED_FILE"
    return 0
  fi

  base="$(basename "$p")"

  # Shared-component check (the important one).
  owner="$(owner_of "$base")"
  if [ -n "$owner" ] && [ "$owner" != "$BUNDLE_ID" ]; then
    printf 'SHARED\t%s\t属于仍安装着的 `%s`，删除会影响该应用\n' "$p" "$owner" >> "$CANDIDATES_FILE"
    return 0
  fi

  # A second copy of the same app is still installed somewhere, so this data is
  # live for that copy too. Demote rather than claim it is safe.
  if [ -n "$DUPLICATE_INSTALL" ]; then
    printf 'REVIEW\t%s\tBundle ID 匹配，但本机还装着该应用的另一份\n' "$p" >> "$CANDIDATES_FILE"
    return 0
  fi
  printf 'SAFE\t%s\t%s\n' "$p" "$why" >> "$CANDIDATES_FILE"
}

# 5a. Exact bundle-id lookups across the standard leftover locations.
USER_LIB="$HOME/Library"
BID_DIRS="
$USER_LIB/Application Support
$USER_LIB/Caches
$USER_LIB/Containers
$USER_LIB/Group Containers
$USER_LIB/HTTPStorages
$USER_LIB/WebKit
$USER_LIB/Application Scripts
$USER_LIB/Saved Application State
$USER_LIB/Preferences
$USER_LIB/Preferences/ByHost
$USER_LIB/Cookies
$USER_LIB/Logs
$USER_LIB/LaunchAgents
$USER_LIB/Autosave Information
$USER_LIB/SyncedPreferences
$USER_LIB/Internet Plug-Ins
$USER_LIB/Services
$USER_LIB/QuickLook
$USER_LIB/PreferencePanes
$USER_LIB/Daemon Containers
"

if [ -n "$BUNDLE_ID" ]; then
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    [ -d "$dir" ] || continue
    # Match "<bid>", "<bid>.<anything>" — covers .plist, .savedState,
    # .binarycookies, ByHost UUID suffixes and sub-domain bundle ids.
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      consider "$hit"
    done < <(find "$dir" -maxdepth 1 -mindepth 1 \( -name "$BID_GLOB" -o -name "$BID_GLOB.*" \) 2>/dev/null)
    # Group Containers use TEAMID.bundleid or group.bundleid prefixes.
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      consider "$hit"
    done < <(find "$dir" -maxdepth 1 -mindepth 1 -name "*.$BID_GLOB" 2>/dev/null)
  done <<EOF
$BID_DIRS
EOF
fi

# 5b. Breadth sweep — catches locations the fixed list above does not know about.
# This is deliberate: any hardcoded list of directories will rot as macOS adds new
# ones, so the fixed list gives precision and this sweep gives coverage.
if [ -n "$BUNDLE_ID" ]; then
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    consider "$hit"
  done < <(find "$USER_LIB" -maxdepth 3 \( -name "$BID_GLOB" -o -name "$BID_GLOB.*" \) 2>/dev/null)
fi

# 5c. Unix-style dot directory in $HOME.
# Java and CLI-style apps keep their data in ~/.<name> rather than ~/Library.
# FreeBox (a JavaFX app) had 68KB of config and spider caches in ~/.freebox while
# ~/Library contained nothing whatsoever — without this the scan reports "0
# leftovers" for an app that clearly has some, which is worse than useless.
#
# Only exact name matches are considered: the app's own name, and the last
# segment of its bundle id. No globbing, so ~/.ssh can never surface here.
# macOS filesystems are case-insensitive by default, so ~/.FreeBox and
# ~/.freebox resolve to the SAME directory and both pass -e. String dedup does
# not catch that; -ef compares inodes and does. Lowercase is tried first so the
# surviving entry carries the name the user will actually see on disk.
DOTS_SEEN="$(mktemp -t mau_dots)"
for dot_name in "$(lower "$APP_NAME")" "$APP_NAME" "$(lower "${BUNDLE_ID##*.}")" "${BUNDLE_ID##*.}" "$BUNDLE_ID"; do
  [ -n "$dot_name" ] || continue
  dot_path="$HOME/.$dot_name"
  [ -e "$dot_path" ] || continue

  dot_dup=0
  while IFS= read -r dot_prev; do
    [ -n "$dot_prev" ] || continue
    if [ "$dot_path" -ef "$dot_prev" ]; then dot_dup=1; break; fi
  done < "$DOTS_SEEN"
  [ "$dot_dup" -eq 1 ] && continue

  printf '%s\n' "$dot_path" >> "$DOTS_SEEN"
  consider "$dot_path" "应用把数据存在了 ~/.${dot_name}（Java / 命令行风格应用的惯例）"
done
rm -f "$DOTS_SEEN"

# ===== Step 6: sudo-tier findings (reported, never executed by this skill) =====

SUDO_FINDINGS=""
add_sudo() { SUDO_FINDINGS="${SUDO_FINDINGS}$1"$'\n'; }

SYS_DIRS="
/Library/Application Support
/Library/Caches
/Library/Preferences
/Library/LaunchAgents
/Library/LaunchDaemons
/Library/PrivilegedHelperTools
/Library/Extensions
/Library/Internet Plug-Ins
/Library/Logs
"

if [ -n "$BUNDLE_ID" ]; then
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    [ -d "$dir" ] || continue
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      base="$(basename "$hit")"
      owner="$(owner_of "$base")"
      if [ -n "$owner" ] && [ "$owner" != "$BUNDLE_ID" ]; then
        add_sudo "- 🚫 \`$hit\` — **属于 \`$owner\`，请勿删除**"
      else
        add_sudo "- \`$hit\` ($(path_size "$hit"))"
      fi
    done < <(find "$dir" -maxdepth 1 -mindepth 1 \( -name "$BID_GLOB" -o -name "$BID_GLOB.*" \) 2>/dev/null)
  done <<EOF
$SYS_DIRS
EOF
fi

# Loaded launchd jobs must be booted out before their plists are removed,
# otherwise launchd keeps the job running and some apps rewrite the plist.
LAUNCHD_JOBS=""
if [ -n "$BUNDLE_ID" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    LAUNCHD_JOBS="${LAUNCHD_JOBS}${line}"$'\n'
  done < <(launchctl list 2>/dev/null | awk -v b="$BUNDLE_ID" '$3 ~ b {print "- `" $3 "` (PID " $1 ")"}')
fi

# System extensions (VPN / network / endpoint-security apps).
SYSEXTS=""
if [ -n "$BUNDLE_ID" ] && command -v systemextensionsctl > /dev/null 2>&1; then
  SYSEXTS="$(systemextensionsctl list 2>/dev/null | grep -F "$BUNDLE_ID" || true)"
fi

# Installer receipts.
PKG_RECEIPTS=""
if [ -n "$BUNDLE_ID" ] && command -v pkgutil > /dev/null 2>&1; then
  PKG_RECEIPTS="$(pkgutil --pkgs 2>/dev/null | grep -F "$BUNDLE_ID" || true)"
fi

# ===== Step 7: Emit the report =====

# One folder per uninstall, so a report, its manifest and (later) the execution
# result stay together instead of scattering across ~/Downloads.
safe_name="$(mau_safe_name "$APP_NAME")"
[ -n "$safe_name" ] || safe_name="app"
output_dir="$(mau_out_dir)/$safe_name-$timestamp"
mkdir -p "$output_dir"
report_file="$output_dir/report.md"
manifest_file="$output_dir/manifest.tsv"

# grep -c prints 0 AND exits 1 when nothing matches, so `|| echo 0` would emit
# two zeros. Swallow the exit status instead.
count_tier() { grep -c "^$1"$'\t' "$CANDIDATES_FILE" 2>/dev/null || true; }

n_safe="$(count_tier SAFE)"
n_review="$(count_tier REVIEW)"
n_shared="$(count_tier SHARED)"

emit_tier() {
  local tier="$1"
  local found=0
  while IFS=$'\t' read -r t p reason; do
    [ "$t" = "$tier" ] || continue
    found=1
    printf -- '- `%s` — %s _(%s)_\n' "$p" "$reason" "$(path_size "$p")"
  done < "$CANDIDATES_FILE"
  [ $found -eq 0 ] && printf -- '_无_\n'
}

{
  printf '# 卸载报告 — %s\n\n' "$APP_NAME"
  printf '生成时间：%s（只读扫描，未改动任何文件）\n\n' "$(date '+%Y-%m-%d %H:%M:%S')"

  printf '## 应用信息\n\n'
  printf '| 项目 | 值 |\n|---|---|\n'
  if [ $APP_FOUND -eq 0 ]; then
    printf '| 应用路径 | `%s` |\n' "$APP_PATH"
    printf '| 应用本体大小 | %s |\n' "$APP_SIZE"
  else
    printf '| 应用路径 | **未安装** — 仅清理残留 |\n'
  fi
  printf '| Bundle ID | `%s` |\n' "${BUNDLE_ID:-未知}"
  [ -n "$APP_VERSION" ] && printf '| 版本 | %s |\n' "$APP_VERSION"
  printf '| 安装方式 | %s |\n' "$INSTALL_SOURCE"
  printf '| 已扫描应用总数 | %s |\n' "$census_count"
  printf '\n'

  if [ -n "$GATE_BLOCK" ]; then
    printf '## 🛑 已阻止\n\n'
    printf '%s\n' "$GATE_BLOCK"
    printf '未生成删除清单，本工具不会删除该应用的任何内容。\n\n'
  fi

  if [ -n "$GATE_WARN" ]; then
    printf '## ⚠️ 操作前请注意\n\n'
    printf '%s\n' "$GATE_WARN"
  fi

  if [ -n "$RUNNING_PIDS" ]; then
    printf '## 🏃 应用正在运行\n\n'
    printf '进程 PID：'
    for pid in $RUNNING_PIDS; do printf ' `%s`' "$pid"; done
    printf '\n\n**请先退出该应用再卸载。** 应用退出时会重写自己的偏好设置，先删了也会被它写回来。\n\n'
  fi

  if [ -n "$GATE_BLOCK" ]; then
    # Never print "safe to remove" under a blocked target — the heading alone
    # invites someone to go delete these by hand.
    printf '## 📋 发现的残留（%s）— 仅供参考\n\n' "$n_safe"
    printf '该应用**已被阻止卸载**（原因见上），这里列出的内容不会被本工具删除。\n\n'
  else
    printf '## ✅ 可安全删除（%s）\n\n' "$n_safe"
    printf 'Bundle ID 精确匹配，且没有其他已安装应用占用这些文件。\n\n'
  fi
  emit_tier SAFE
  printf '\n'

  printf '## ⚠️ 需要你确认（%s）\n\n' "$n_review"
  printf 'Bundle ID 匹配，但不能算安全：本机还装着这个应用的另一份，\n'
  printf '这些数据对那一份来说仍在使用中。\n\n'
  emit_tier REVIEW
  printf '\n' 

  printf '## 🚫 共享文件 — 请勿删除（%s）\n\n' "$n_shared"
  printf '这些路径属于**仍然安装着的其他应用**，删除会导致那些应用出问题。\n\n'
  emit_tier SHARED
  printf '\n'

  if [ -n "$SUDO_FINDINGS" ] || [ -n "$LAUNCHD_JOBS" ] || [ -n "$SYSEXTS" ] || [ -n "$PKG_RECEIPTS" ]; then
    printf '## 🔐 系统级残留（需要 sudo — 请你自己执行）\n\n'
    printf '本工具从不执行 sudo。请逐条确认后，自行在终端执行。\n\n'
    if [ -n "$LAUNCHD_JOBS" ]; then
      printf '**已加载的 launchd 任务** —— 必须**先** bootout 再删除对应的 plist：\n\n'
      printf '%s\n' "$LAUNCHD_JOBS"
    fi
    if [ -n "$SUDO_FINDINGS" ]; then
      printf '**系统文件：**\n\n'
      printf '%s\n' "$SUDO_FINDINGS"
    fi
    if [ -n "$SYSEXTS" ]; then
      printf '**系统扩展**（只能由应用自己停用，或在「系统设置 → 通用 → 登录项与扩展」里移除，`rm` 删不掉）：\n\n```\n%s\n```\n\n' "$SYSEXTS"
    fi
    if [ -n "$PKG_RECEIPTS" ]; then
      printf '**安装收据**（`sudo pkgutil --forget <id>`）：\n\n```\n%s\n```\n\n' "$PKG_RECEIPTS"
    fi
  fi

  if [ -s "$SKIPPED_FILE" ]; then
    printf '## ⏭️ 已跳过（路径含特殊字符）\n\n'
    printf '这些路径含制表符或换行，无法写入清单文件，需要你手动处理：\n\n'
    while IFS= read -r p; do printf -- '- `%s`\n' "$p"; done < "$SKIPPED_FILE"
    printf '\n'
  fi

  printf '## 下一步\n\n'
  if [ -n "$GATE_BLOCK" ]; then
    printf '已阻止，原因见上。\n'
  else
    printf '删除清单：`%s`\n\n' "$manifest_file"
    printf '删除 ✅ 档的内容（移入废纸篓，可随时还原）：\n\n'
    printf '```bash\nbash uninstall.sh --manifest "%s" --tier safe\n```\n' "$manifest_file"
  fi
} | tee "$report_file"

# ===== Step 8: Write the manifest =====
# Blocked targets get no manifest at all — uninstall.sh has nothing to act on.

if [ -z "$GATE_BLOCK" ]; then
  {
    printf '# mac-app-uninstall manifest\n'
    printf '# app\t%s\n' "$APP_NAME"
    printf '# bundle_id\t%s\n' "${BUNDLE_ID:-unknown}"
    printf '# generated\t%s\n' "$timestamp"
    if [ $APP_FOUND -eq 0 ]; then
      printf 'BUNDLE\t%s\t应用程序本体\n' "$APP_PATH"
    fi
    cat "$CANDIDATES_FILE"
  } > "$manifest_file"
  printf '[删除清单] %s\n' "$manifest_file"
fi

printf '[已保存] %s\n' "$report_file"
mau_open_file "$report_file"

exit 0
