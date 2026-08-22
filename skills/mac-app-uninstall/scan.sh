#!/usr/bin/env bash
# mac-app-uninstall scan.sh — locate a macOS app and every leftover it owns.
# READ-ONLY. This script never deletes, moves, or modifies anything.
# See DESIGN.md in the same directory for the tiering rules.

set -u
set -o pipefail

# ===== Infrastructure =====
timestamp="$(date +%Y-%m-%d-%H%M%S)"
output_dir="$HOME/Downloads"
mkdir -p "$output_dir"

# Written by report(); the manifest is what uninstall.sh consumes.
report_file=""
manifest_file=""

usage() {
  cat >&2 <<'EOF'
Usage: scan.sh <app name | bundle id | /path/to/App.app>

Examples:
  scan.sh Slack
  scan.sh com.tinyspeck.slackmacgap
  scan.sh "/Applications/Google Chrome.app"

Read-only. Produces a tiered leftover report + a manifest for uninstall.sh.
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
    echo "ERROR: required tool '$tool' not found in PATH" >&2
    exit 1
  fi
done

# ===== Shared helpers =====
# Sourced so scan.sh and list-apps.sh cannot drift apart on how an app bundle is
# read or how the census is built.
MAU_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -f "$MAU_LIB_DIR/lib.sh" ]; then
  echo "ERROR: lib.sh not found next to scan.sh (looked in $MAU_LIB_DIR)" >&2
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
INSTALL_SOURCE="Unknown"

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
    add_block "**Apple system app** (\`$BUNDLE_ID\`). This skill refuses to uninstall Apple-signed system software. Removing it can break the OS and most of it is on the sealed system volume anyway."
    ;;
esac
case "$APP_PATH" in
  /System/*)
    add_block "Located on the **sealed system volume** (\`$APP_PATH\`). Not removable, even with sudo."
    ;;
esac

# 3b. Setapp-managed apps must go through Setapp.
case "$APP_PATH" in
  */Applications/Setapp/*)
    add_block "**Setapp-managed app**. Uninstall it from the Setapp client instead — deleting the bundle directly leaves Setapp's database inconsistent and Setapp will silently reinstall it."
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
  INSTALL_SOURCE="Homebrew cask (\`$BREW_CASK\`)"
  add_warn "**Installed via Homebrew cask** (\`$BREW_CASK\`). Prefer \`brew uninstall --zap --cask $BREW_CASK\` — it removes the app *and* the leftovers the cask author declared, and keeps brew's state consistent. Deleting the bundle by hand leaves brew thinking it is still installed."
fi

# 3d. Mac App Store receipt. Wrapped iOS apps keep theirs inside the wrapper.
if [ $APP_FOUND -eq 0 ] &&
   { [ -f "$APP_PATH/Contents/_MASReceipt/receipt" ] || [ -f "$APP_PATH/WrappedBundle/_MASReceipt/receipt" ]; }; then
  INSTALL_SOURCE="Mac App Store"
  add_warn "**Mac App Store app.** Redownloadable from the App Store at any time, but any in-app purchase state stored in the leftovers below will be gone."
fi

# 3e. iOS/iPadOS app running on Apple Silicon.
if [ $APP_FOUND -eq 0 ] && [ -d "$APP_PATH/Wrapper" ]; then
  INSTALL_SOURCE="iOS/iPadOS app (Designed for iPad)"
  add_warn "**This is an iOS/iPadOS app** running on Apple Silicon. Its data lives in \`~/Library/Containers/$BUNDLE_ID\` rather than the usual macOS locations."
fi
if [ "$INSTALL_SOURCE" = "Unknown" ] && [ $APP_FOUND -eq 0 ]; then
  INSTALL_SOURCE="Direct download / installer"
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
  add_warn "**Another copy of \`$BUNDLE_ID\` is still installed** elsewhere on this machine. Its preferences and data are shared with the copy you are removing, so nothing is listed as safe — review each item by hand."
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
  local p="$1" base owner
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
    printf 'SHARED\t%s\tBelongs to still-installed app `%s` — deleting this breaks that app\n' "$p" "$owner" >> "$CANDIDATES_FILE"
    return 0
  fi

  # A second copy of the same app is still installed somewhere, so this data is
  # live for that copy too. Demote rather than claim it is safe.
  if [ -n "$DUPLICATE_INSTALL" ]; then
    printf 'REVIEW\t%s\tBundle-id match, but another copy of this app is still installed\n' "$p" >> "$CANDIDATES_FILE"
    return 0
  fi
  printf 'SAFE\t%s\tExact bundle-id match\n' "$p" >> "$CANDIDATES_FILE"
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
        add_sudo "- 🚫 \`$hit\` — **belongs to \`$owner\`, do not remove**"
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

safe_name="$(printf '%s' "$APP_NAME" | tr -c '[:alnum:]._-' '-')"
report_file="$output_dir/mac-app-uninstall-$safe_name-$timestamp.md"
manifest_file="$output_dir/mac-app-uninstall-$safe_name-$timestamp.tsv"

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
  [ $found -eq 0 ] && printf -- '_none_\n'
}

{
  printf '# Uninstall report — %s\n\n' "$APP_NAME"
  printf '_Generated %s by mac-app-uninstall (read-only scan)._\n\n' "$timestamp"

  printf '## Identity\n\n'
  printf '| Field | Value |\n|---|---|\n'
  if [ $APP_FOUND -eq 0 ]; then
    printf '| Bundle | `%s` |\n' "$APP_PATH"
    printf '| Size | %s |\n' "$APP_SIZE"
  else
    printf '| Bundle | **not installed** — leftover-only cleanup |\n'
  fi
  printf '| Bundle ID | `%s` |\n' "${BUNDLE_ID:-unknown}"
  [ -n "$APP_VERSION" ] && printf '| Version | %s |\n' "$APP_VERSION"
  printf '| Install source | %s |\n' "$INSTALL_SOURCE"
  printf '| Installed apps censused | %s |\n' "$census_count"
  printf '\n'

  if [ -n "$GATE_BLOCK" ]; then
    printf '## 🛑 Blocked\n\n'
    printf '%s\n' "$GATE_BLOCK"
    printf 'No manifest was written. Nothing can be removed through this skill.\n\n'
  fi

  if [ -n "$GATE_WARN" ]; then
    printf '## ⚠️ Before you proceed\n\n'
    printf '%s\n' "$GATE_WARN"
  fi

  if [ -n "$RUNNING_PIDS" ]; then
    printf '## 🏃 Currently running\n\n'
    printf 'PIDs:'
    for pid in $RUNNING_PIDS; do printf ' `%s`' "$pid"; done
    printf '\n\n**Quit the app before uninstalling.** A running app rewrites its preferences on exit, so deleting them first accomplishes nothing.\n\n'
  fi

  if [ -n "$GATE_BLOCK" ]; then
    # Never print "safe to remove" under a blocked target — the heading alone
    # invites someone to go delete these by hand.
    printf '## 📋 Leftovers found (%s) — informational only\n\n' "$n_safe"
    printf 'This target is **blocked** (see above). Nothing here may be removed through this skill.\n\n'
  else
    printf '## ✅ Safe to remove (%s)\n\n' "$n_safe"
    printf 'Exact bundle-id matches, not claimed by any other installed app.\n\n'
  fi
  emit_tier SAFE
  printf '\n'

  printf '## ⚠️ Needs your review (%s)\n\n' "$n_review"
  printf 'Bundle-id matches that could not be called safe — another copy of this app is\n'
  printf 'still installed, so the data is live for that copy too.\n\n'
  emit_tier REVIEW
  printf '\n' 

  printf '## 🚫 Shared — do not remove (%s)\n\n' "$n_shared"
  printf 'Another app that is **still installed** also owns these paths.\n\n'
  emit_tier SHARED
  printf '\n'

  if [ -n "$SUDO_FINDINGS" ] || [ -n "$LAUNCHD_JOBS" ] || [ -n "$SYSEXTS" ] || [ -n "$PKG_RECEIPTS" ]; then
    printf '## 🔐 System-level (requires sudo — run these yourself)\n\n'
    printf 'This skill never runs sudo. Review each line, then run it manually if you agree.\n\n'
    if [ -n "$LAUNCHD_JOBS" ]; then
      printf '**Loaded launchd jobs** — bootout these *before* deleting their plists:\n\n'
      printf '%s\n' "$LAUNCHD_JOBS"
    fi
    if [ -n "$SUDO_FINDINGS" ]; then
      printf '**System files:**\n\n'
      printf '%s\n' "$SUDO_FINDINGS"
    fi
    if [ -n "$SYSEXTS" ]; then
      printf '**System extensions** (must be deactivated by the app itself, or in System Settings → General → Login Items & Extensions):\n\n```\n%s\n```\n\n' "$SYSEXTS"
    fi
    if [ -n "$PKG_RECEIPTS" ]; then
      printf '**Installer receipts** (`sudo pkgutil --forget <id>`):\n\n```\n%s\n```\n\n' "$PKG_RECEIPTS"
    fi
  fi

  if [ -s "$SKIPPED_FILE" ]; then
    printf '## ⏭️ Skipped (unrepresentable paths)\n\n'
    printf 'These contain tabs or newlines and cannot go in the manifest. Handle them by hand:\n\n'
    while IFS= read -r p; do printf -- '- `%s`\n' "$p"; done < "$SKIPPED_FILE"
    printf '\n'
  fi

  printf '## Next step\n\n'
  if [ -n "$GATE_BLOCK" ]; then
    printf 'Blocked — see above.\n'
  else
    printf 'Manifest: `%s`\n\n' "$manifest_file"
    printf 'To remove the ✅ tier (moves to Trash, recoverable):\n\n'
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
      printf 'BUNDLE\t%s\tThe application bundle itself\n' "$APP_PATH"
    fi
    cat "$CANDIDATES_FILE"
  } > "$manifest_file"
  printf '\n[manifest] %s\n' "$manifest_file" >&2
fi

printf '[report] %s\n' "$report_file" >&2

exit 0
