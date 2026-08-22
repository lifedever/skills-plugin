#!/usr/bin/env bash
# mac-app-uninstall uninstall.sh — move the leftovers a scan.sh manifest lists
# into the Trash. Dry-run unless --execute is passed. Never uses rm.
# See DESIGN.md in the same directory.

set -u
set -o pipefail

MANIFEST=""
TIER="safe"
EXECUTE=0

usage() {
  cat >&2 <<'EOF'
Usage: uninstall.sh --manifest <file> [--tier safe|review|bundle|all] [--execute]

  --manifest <file>  Manifest produced by scan.sh (required)
  --tier <t>         Which tier to act on (default: safe)
                       safe    exact bundle-id matches, unclaimed by other apps
                       review  name-only matches — inspect them first
                       bundle  the .app itself
                       all     safe + review + bundle
  --execute          Actually move to Trash. Without it, this is a dry run.

Everything goes to the Trash and stays recoverable. There is no permanent-delete
option by design — empty the Trash yourself once you are satisfied.

The SHARED tier is never actionable: those paths belong to apps that are still
installed.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --manifest)
      [ $# -ge 2 ] || { echo "ERROR: --manifest needs a value" >&2; exit 2; }
      MANIFEST="$2"; shift 2 ;;
    --tier)
      [ $# -ge 2 ] || { echo "ERROR: --tier needs a value" >&2; exit 2; }
      TIER="$2"; shift 2 ;;
    --execute) EXECUTE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument '$1'" >&2; usage; exit 2 ;;
  esac
done

[ -n "$MANIFEST" ] || { echo "ERROR: --manifest is required" >&2; usage; exit 2; }
[ -f "$MANIFEST" ] || { echo "ERROR: manifest not found: $MANIFEST" >&2; exit 1; }

case "$TIER" in
  safe|review|bundle|all) ;;
  shared)
    echo "ERROR: the SHARED tier is never removable — those paths belong to apps that are still installed." >&2
    exit 2 ;;
  *) echo "ERROR: invalid --tier '$TIER'" >&2; usage; exit 2 ;;
esac

command -v /usr/bin/trash > /dev/null 2>&1 || {
  echo "ERROR: /usr/bin/trash not found. It ships with macOS 14+; on older systems" >&2
  echo "       move the listed paths to the Trash manually via Finder." >&2
  exit 1
}

# Escape ERE metacharacters — pgrep -f takes a regex, and a bundle id of ".*"
# would otherwise match every process and permanently block execution.
escape_ere() { printf '%s' "$1" | sed 's/[][^$.*+?(){}|\\]/\\&/g'; }

# ===== Path safety gate =====
# A manifest is just a text file. Treat every path in it as untrusted: an edited
# or stale manifest must never be able to trash $HOME, /Library, or a whole
# top-level cache directory.
is_allowed_path() {
  local p="$1"

  # No traversal segments — we compare literal prefixes below.
  case "$p" in
    *"/../"* | */.. | ../*) return 1 ;;
  esac

  # NB: `*` in a case pattern matches `/` too, so the deeper pattern must come
  # first — otherwise "$HOME/Library/*" would swallow every nested path.
  case "$p" in
    # Inside a ~/Library subdirectory (Caches/<id>, Preferences/<id>.plist, ...).
    "$HOME"/Library/*/*) return 0 ;;

    # Sitting directly under ~/Library. Some apps do this, and scan.sh's breadth
    # sweep finds them, so refusing outright would make the two scripts disagree.
    # But "~/Library/Caches" must never be removable. Decide from evidence rather
    # than a hardcoded list of Apple directory names (such a list would rot):
    # accept it only when the name lives in the target's bundle-id namespace.
    "$HOME"/Library/*)
      [ -n "$BUNDLE_ID" ] && [ "$BUNDLE_ID" != "unknown" ] || return 1
      case "$(basename "$p")" in
        "$BUNDLE_ID" | "$BUNDLE_ID".*) return 0 ;;
      esac
      return 1
      ;;

    # An app bundle, never the /Applications directory itself.
    /Applications/*.app | /Applications/*/*.app) return 0 ;;
    "$HOME"/Applications/*.app) return 0 ;;
  esac
  return 1
}

# Second, independent line of defence. scan.sh already blocks Apple and Setapp
# apps, but the manifest is an editable text file in ~/Downloads — this script
# must never assume the scanner did its job. Checked per path, regardless of tier.
is_protected_target() {
  local p="$1" base bid plist

  case "$p" in
    # Setapp reinstalls what you delete behind its back.
    /Applications/Setapp/*) return 0 ;;
    # Sealed system volume and system-wide locations this skill never touches.
    /System/* | /Library/* | /usr/* | /bin/* | /sbin/* | /private/*) return 0 ;;
  esac

  # Apple-owned bundle id, whether it names a .app or a ~/Library leftover.
  base="$(basename "$p")"
  case "$base" in
    com.apple.* | .* ) return 0 ;;
  esac

  # For a real bundle, read its identity instead of trusting the filename.
  if [ -d "$p" ]; then
    for plist in "$p/Contents/Info.plist" "$p/WrappedBundle/Info.plist"; do
      [ -f "$plist" ] || continue
      bid="$(plutil -extract CFBundleIdentifier raw -o - "$plist" 2>/dev/null)"
      case "$bid" in
        com.apple.*) return 0 ;;
      esac
      break
    done
  fi

  return 1
}

# ===== Read the manifest =====

BUNDLE_ID="$(awk -F'\t' '/^# bundle_id\t/ {print $2; exit}' "$MANIFEST" 2>/dev/null)"
APP_LABEL="$(awk -F'\t' '/^# app\t/ {print $2; exit}' "$MANIFEST" 2>/dev/null)"

tier_matches() {
  local t="$1"
  case "$TIER" in
    all) [ "$t" = "SAFE" ] || [ "$t" = "REVIEW" ] || [ "$t" = "BUNDLE" ] ;;
    safe) [ "$t" = "SAFE" ] ;;
    review) [ "$t" = "REVIEW" ] ;;
    bundle) [ "$t" = "BUNDLE" ] ;;
  esac
}

n_shared_skipped=0
TARGETS_FILE="$(mktemp -t mau_targets)"
REJECTED_FILE="$(mktemp -t mau_rejected)"
PROTECTED_FILE="$(mktemp -t mau_protected)"
MISSING_FILE="$(mktemp -t mau_missing)"
ANCESTORS_FILE="$(mktemp -t mau_ancestors)"
trap 'rm -f "$TARGETS_FILE" "$REJECTED_FILE" "$PROTECTED_FILE" "$MISSING_FILE" "$ANCESTORS_FILE"' EXIT

while IFS=$'\t' read -r tier path reason; do
  case "$tier" in
    '#'*|'') continue ;;
  esac
  [ -n "${path:-}" ] || continue

  # Hard refusal, independent of --tier, so a hand-edited tier column cannot
  # smuggle a shared path through. Counted, not silently dropped.
  if [ "$tier" = "SHARED" ]; then
    n_shared_skipped=$((n_shared_skipped + 1))
    continue
  fi

  tier_matches "$tier" || continue

  if ! is_allowed_path "$path"; then
    printf '%s\t%s\n' "$tier" "$path" >> "$REJECTED_FILE"
    continue
  fi
  if is_protected_target "$path"; then
    printf '%s\t%s\n' "$tier" "$path" >> "$PROTECTED_FILE"
    continue
  fi
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    printf '%s\n' "$path" >> "$MISSING_FILE"
    continue
  fi
  printf '%s\t%s\n' "$tier" "$path" >> "$TARGETS_FILE"
done < "$MANIFEST"

n_targets=$(wc -l < "$TARGETS_FILE" | tr -d ' ')

# ===== Running-process guard =====
# Trashing a running app's preferences accomplishes nothing: it rewrites them on
# quit. Trashing the bundle out from under a running process is worse.
RUNNING=""
if [ -n "$BUNDLE_ID" ] && [ "$BUNDLE_ID" != "unknown" ]; then
  RUNNING="$(pgrep -f "$(escape_ere "$BUNDLE_ID")" 2>/dev/null | grep -v "^$$\$" | tr '\n' ' ' || true)"
fi

echo "# Uninstall — ${APP_LABEL:-unknown app}"
echo
echo "Manifest : $MANIFEST"
echo "Tier     : $TIER"
echo "Mode     : $([ $EXECUTE -eq 1 ] && echo 'EXECUTE (moves to Trash)' || echo 'DRY RUN (nothing is touched)')"
echo

if [ -s "$REJECTED_FILE" ]; then
  echo "## Refused — outside the allowed roots"
  echo
  echo "These are not under ~/Library/<dir>/, /Applications, or ~/Applications."
  echo "A manifest should never contain them; if this is unexpected, re-run scan.sh."
  echo
  while IFS=$'\t' read -r t p; do echo "  [$t] $p"; done < "$REJECTED_FILE"
  echo
fi

if [ -s "$PROTECTED_FILE" ]; then
  echo "## 🛑 Refused — protected (Apple / Setapp / system)"
  echo
  echo "These are protected regardless of what the manifest claims. If a manifest"
  echo "produced by scan.sh contains these, it has been edited or corrupted."
  echo
  while IFS=$'\t' read -r t p; do echo "  [$t] $p"; done < "$PROTECTED_FILE"
  echo
fi

if [ "$n_shared_skipped" -gt 0 ]; then
  echo "## Held back — shared with still-installed apps ($n_shared_skipped)"
  echo
  echo "Listed in the scan report under 🚫. These are never removable here."
  echo
fi

if [ -s "$MISSING_FILE" ]; then
  echo "## Already gone (skipped)"
  echo
  while IFS= read -r p; do echo "  $p"; done < "$MISSING_FILE"
  echo
fi

if [ "$n_targets" -eq 0 ]; then
  echo "Nothing to do for tier '$TIER'."
  exit 0
fi

echo "## Targets ($n_targets)"
echo
total_kb=0
while IFS=$'\t' read -r tier path; do
  kb="$(du -sk "$path" 2>/dev/null | awk '{print $1}')"
  [ -n "$kb" ] && total_kb=$((total_kb + kb))
  printf '  [%s] %s (%s)\n' "$tier" "$path" \
    "$(awk -v k="${kb:-0}" 'BEGIN{if(k<1024)printf "%dKB",k; else if(k<1048576)printf "%.1fMB",k/1024; else printf "%.2fGB",k/1048576}')"
done < "$TARGETS_FILE"
echo
awk -v k="$total_kb" 'BEGIN{printf "Total: %.1f MB\n", k/1024}'
echo

if [ -n "$RUNNING" ]; then
  echo "## ⚠️  Still running: PIDs $RUNNING"
  echo
  echo "Quit the app first — it rewrites its preferences on exit."
  echo
  if [ $EXECUTE -eq 1 ]; then
    echo "Refusing to execute while the app is running."
    exit 1
  fi
fi

if [ $EXECUTE -eq 0 ]; then
  echo "Dry run only. Re-run with --execute to move these to the Trash."
  exit 0
fi

# ===== Execute =====

# Record every ancestor of every target BEFORE touching anything. Verification
# then checks these still exist. Deriving the list from what we are about to do
# beats hardcoding "important directories" — it adapts to whatever is removed.
while IFS=$'\t' read -r tier path; do
  d="$(dirname "$path")"
  while [ -n "$d" ] && [ "$d" != "/" ] && [ "$d" != "." ]; do
    printf '%s\n' "$d" >> "$ANCESTORS_FILE"
    [ "$d" = "$HOME" ] && break
    d="$(dirname "$d")"
  done
done < "$TARGETS_FILE"
# Anchors: roots this script may reach into, plus user data it must never touch.
for anchor in "$HOME" "$HOME/Library" "$HOME/Library/Caches" \
              "$HOME/Library/Preferences" "$HOME/Library/Application Support" \
              "$HOME/Documents" "$HOME/Desktop" "$HOME/Downloads" \
              /Applications /Library /System /usr; do
  printf '%s\n' "$anchor" >> "$ANCESTORS_FILE"
done
sort -u "$ANCESTORS_FILE" -o "$ANCESTORS_FILE"

ok=0
fail=0
while IFS=$'\t' read -r tier path; do
  if /usr/bin/trash "$path" 2>/dev/null; then
    ok=$((ok + 1))
    printf '  ✔ %s\n' "$path"
  else
    fail=$((fail + 1))
    printf '  ✘ %s (trash failed — check permissions or Full Disk Access)\n' "$path" >&2
  fi
done < "$TARGETS_FILE"

echo
echo "Moved to Trash: $ok    Failed: $fail"

# ===== Verify =====

echo
echo "## Verification"
echo

verify_fail=0

# 1. Targets actually left their original locations.
still=0
while IFS=$'\t' read -r tier path; do
  if [ -e "$path" ] || [ -L "$path" ]; then
    printf '  ✘ still in place: %s\n' "$path"
    still=$((still + 1))
  fi
done < "$TARGETS_FILE"
if [ "$still" -eq 0 ]; then
  printf '  ✔ all %s target(s) gone from their original locations\n' "$ok"
else
  verify_fail=$((verify_fail + still))
fi

# 2. Nothing ABOVE the targets was harmed. This is the check that would catch a
#    path-handling bug taking a parent directory with it.
missing_anc=0
n_anc="$(wc -l < "$ANCESTORS_FILE" | tr -d ' ')"
while IFS= read -r d; do
  [ -n "$d" ] || continue
  if [ ! -d "$d" ]; then
    printf '  ✘✘ MISSING DIRECTORY: %s\n' "$d" >&2
    missing_anc=$((missing_anc + 1))
  fi
done < "$ANCESTORS_FILE"
if [ "$missing_anc" -eq 0 ]; then
  printf '  ✔ all %s parent and system directories intact\n' "$n_anc"
else
  verify_fail=$((verify_fail + missing_anc))
fi

# 3. Recoverability — the whole point of this script is that a mistake can be
#    undone, so verify each item is really sitting in the Trash.
#    NB: LISTING ~/.Trash requires Full Disk Access and is commonly denied, but
#    stat'ing a known path inside it is allowed. So check per item instead of
#    gating the whole check on `ls`, which would needlessly downgrade this to a
#    guess. Finder renames on name collision, so a miss is inconclusive, not loss.
found=0
inconclusive=0
while IFS=$'\t' read -r tier path; do
  b="$(basename "$path")"
  if [ -e "$HOME/.Trash/$b" ] || [ -L "$HOME/.Trash/$b" ]; then
    found=$((found + 1))
  else
    inconclusive=$((inconclusive + 1))
  fi
done < "$TARGETS_FILE"

if [ "$inconclusive" -eq 0 ]; then
  printf '  ✔ all %s item(s) confirmed in ~/.Trash — recoverable\n' "$found"
else
  printf '  ✔ %s item(s) confirmed in ~/.Trash\n' "$found"
  printf '  ⚠ %s not found there under the same name. Finder renames on collision,\n' "$inconclusive"
  printf '    so this is inconclusive rather than lost — check the Trash in Finder.\n'
fi

echo
if [ "$verify_fail" -gt 0 ]; then
  echo "❌ VERIFICATION FAILED — $verify_fail problem(s) above. Stop and inspect." >&2
  exit 1
fi
if [ "$fail" -gt 0 ]; then
  echo "Some items failed to move. Do not retry blindly — inspect the errors above." >&2
  exit 1
fi
echo "✅ Verified. Everything above is recoverable from the Trash until you empty it."
exit 0
