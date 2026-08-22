#!/usr/bin/env bash
# mac-app-uninstall list-apps.sh — inventory of installed applications.
# READ-ONLY. Never deletes, moves, or modifies anything.
#
# This lists EVERYTHING by default. It is a browsable inventory, like the app
# list in AppCleaner — not a list of removal suggestions. Sorting and the
# last-used column exist so a person can find what they are looking for; neither
# implies anything about what should be removed. Deciding that is the user's job.

set -u
set -o pipefail

MAU_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -f "$MAU_LIB_DIR/lib.sh" ]; then
  echo "ERROR: lib.sh not found next to list-apps.sh (looked in $MAU_LIB_DIR)" >&2
  exit 1
fi
# shellcheck source=lib.sh
. "$MAU_LIB_DIR/lib.sh"

SHOW_SIZE=0
INCLUDE_SYSTEM=0
LIMIT=0
SORT_BY="name"

usage() {
  cat >&2 <<'EOF'
Usage: list-apps.sh [--sort name|used|size] [--size] [--limit N] [--all]

  --sort name   Alphabetical (default)
  --sort used   Least recently used first
  --sort size   Largest first (implies --size)
  --size        Include each app's size. Adds ~7s — it walks every bundle.
  --limit N     Show only the first N rows. Default: no limit, everything shown.
  --all         Include /System applications. They cannot be uninstalled and are
                hidden by default.

Lists every installed application. Read-only.
Pick one, then run: scan.sh "<app name or bundle id>"
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --size) SHOW_SIZE=1; shift ;;
    --all) INCLUDE_SYSTEM=1; shift ;;
    --sort)
      [ $# -ge 2 ] || { echo "ERROR: --sort needs a value" >&2; exit 2; }
      case "$2" in
        name|used) SORT_BY="$2" ;;
        size) SORT_BY="size"; SHOW_SIZE=1 ;;
        *) echo "ERROR: --sort must be name, used, or size" >&2; exit 2 ;;
      esac
      shift 2 ;;
    --limit)
      [ $# -ge 2 ] || { echo "ERROR: --limit needs a value" >&2; exit 2; }
      case "$2" in
        ''|*[!0-9]*) echo "ERROR: --limit must be a positive integer" >&2; exit 2 ;;
      esac
      LIMIT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument '$1'" >&2; usage; exit 2 ;;
  esac
done

for tool in plutil find awk sed date mdfind; do
  command -v "$tool" > /dev/null 2>&1 || {
    echo "ERROR: required tool '$tool' not found in PATH" >&2; exit 1; }
done

CENSUS_FILE="$(mktemp -t mau_census)"
TIMES_FILE="$(mktemp -t mau_times)"
ROWS_FILE="$(mktemp -t mau_rows)"
trap 'rm -f "$CENSUS_FILE" "$TIMES_FILE" "$ROWS_FILE"' EXIT

census_count="$(build_census "$CENSUS_FILE")"

# Last-used timestamps: one Spotlight call for the whole machine rather than an
# mdls per app. The query is a fixed literal — no user input reaches it, so the
# injection problem that got mdfind removed from scan.sh does not apply here.
#
# Output is "<path>   kMDItemLastUsedDate = <value>", and paths contain spaces,
# so the split keys off the attribute name rather than whitespace.
mdfind "kMDItemContentType == 'com.apple.application-bundle'" \
       -attr kMDItemLastUsedDate 2>/dev/null \
| awk '{
    key = "kMDItemLastUsedDate = "
    i = index($0, key)
    if (i > 0) {
      p = substr($0, 1, i - 1); sub(/[ \t]+$/, "", p)
      v = substr($0, i + length(key))
      if (v != "(null)" && v != "") print p "\t" v
    }
  }' > "$TIMES_FILE"

now_epoch="$(date +%s)"

# Row layout: usedkey \t inferred \t size_kb \t name \t kind \t bundle_id \t path
#
# Every field is non-empty on purpose. Tab is an IFS whitespace character, so
# bash collapses runs of them on read — an empty field would be swallowed and
# every later column would shift left. Sentinels: usedkey "0000-…" = no record,
# inferred 0/1, size_kb 0 = not measured.
while IFS=$'\t' read -r bid nm path; do
  [ -n "$path" ] || continue
  case "$path" in
    /System/*) [ "$INCLUDE_SYSTEM" -eq 1 ] || continue ;;
  esac

  used=""
  while IFS=$'\t' read -r t_path t_val; do
    if [ "$t_path" = "$path" ]; then used="$t_val"; break; fi
  done < "$TIMES_FILE"

  # Spotlight has no kMDItemLastUsedDate for some apps — Xcode and the Office
  # suite lack it on the dev machine despite obvious use. Fall back to the mtime
  # of the app's preferences file (most apps write prefs on quit) and mark it as
  # inferred so it is never mistaken for a real usage record.
  inferred=0
  if [ -z "$used" ] && [ -n "$bid" ]; then
    pref="$HOME/Library/Preferences/$bid.plist"
    if [ -f "$pref" ]; then
      pref_epoch="$(stat -f %m "$pref" 2>/dev/null)"
      if [ -n "$pref_epoch" ]; then
        used="$(date -r "$pref_epoch" -u '+%Y-%m-%d %H:%M:%S +0000' 2>/dev/null)"
        [ -n "$used" ] && inferred=1
      fi
    fi
  fi
  [ -n "$used" ] || used="0000-00-00 00:00:00 +0000"

  size_kb=0
  if [ "$SHOW_SIZE" -eq 1 ]; then
    size_kb="$(du -sk "$path" 2>/dev/null | awk '{print $1}')"
    [ -n "$size_kb" ] || size_kb=0
  fi

  kind="App"
  case "$path" in
    /Applications/Setapp/*) kind="Setapp" ;;
    /System/*) kind="System" ;;
    *)
      if [ -d "$path/Wrapper" ]; then
        kind="iOS"
      elif [ -f "$path/Contents/_MASReceipt/receipt" ] || [ -f "$path/WrappedBundle/_MASReceipt/receipt" ]; then
        kind="MAS"
      fi
      ;;
  esac

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$used" "$inferred" "$size_kb" "$nm" "$kind" "${bid:-unknown}" "$path" >> "$ROWS_FILE"
done < "$CENSUS_FILE"

TAB="$(printf '\t')"
case "$SORT_BY" in
  # The timestamp format is fixed-width UTC, so a lexical sort is chronological.
  used) sort -t"$TAB" -k1,1 "$ROWS_FILE" -o "$ROWS_FILE" ;;
  size) sort -t"$TAB" -k3,3nr "$ROWS_FILE" -o "$ROWS_FILE" ;;
  name) sort -f -t"$TAB" -k4,4 "$ROWS_FILE" -o "$ROWS_FILE" ;;
esac

total_rows="$(wc -l < "$ROWS_FILE" | tr -d ' ')"
norec_count="$(awk -F'\t' '$1 ~ /^0000/ {n++} END{print n+0}' "$ROWS_FILE")"

case "$SORT_BY" in
  name) order="name (A–Z)" ;;
  used) order="last used, oldest first" ;;
  size) order="size, largest first" ;;
esac

OUT_DIR="$(mau_out_dir)"
OUT_FILE="$OUT_DIR/apps-$(date +%Y-%m-%d-%H%M%S).md"

{
echo "# Installed applications"
echo
printf '**%s apps**, sorted by %s.' "$total_rows" "$order"
[ "$INCLUDE_SYSTEM" -eq 0 ] && printf ' System apps are hidden (`--all` to include them).'
printf '\n\n'
if [ "$norec_count" -gt 0 ]; then
  printf '_%s have no last-used date. Spotlight does not record one for every app,\n' "$norec_count"
  printf 'so **no record** means unknown, not unused. A date marked `~` is inferred\n'
  printf 'from the preferences file mtime rather than an actual usage record._\n\n'
fi

if [ "$SHOW_SIZE" -eq 1 ]; then
  printf '| App | Size | Last used | Kind | Bundle ID |\n'
  printf '|---|---|---|---|---|\n'
else
  printf '| App | Last used | Kind | Bundle ID |\n'
  printf '|---|---|---|---|\n'
fi

shown=0
while IFS=$'\t' read -r usedkey inferred size_kb nm kind bid path; do
  [ -n "$nm" ] || continue
  if [ "$LIMIT" -gt 0 ] && [ "$shown" -ge "$LIMIT" ]; then break; fi
  shown=$((shown + 1))

  case "$usedkey" in
    0000-*) last_used="**no record**" ;;
    *)
      last_used="$(date -j -f '%Y-%m-%d %H:%M:%S %z' "$usedkey" '+%Y-%m-%d' 2>/dev/null)"
      [ -n "$last_used" ] || last_used="?"
      [ "$inferred" = "1" ] && last_used="$last_used ~"
      ;;
  esac

  if [ "$SHOW_SIZE" -eq 1 ]; then
    size_h="$(awk -v k="$size_kb" 'BEGIN{
      if (k <= 0) printf "?";
      else if (k < 1024) printf "%dKB", k;
      else if (k < 1048576) printf "%.1fMB", k/1024;
      else printf "%.2fGB", k/1048576; }')"
    printf '| %s | %s | %s | %s | `%s` |\n' "$nm" "$size_h" "$last_used" "$kind" "$bid"
  else
    printf '| %s | %s | %s | `%s` |\n' "$nm" "$last_used" "$kind" "$bid"
  fi
done < "$ROWS_FILE"

echo
if [ "$LIMIT" -gt 0 ] && [ "$total_rows" -gt "$LIMIT" ]; then
  printf '_Showing %s of %s — %s hidden by `--limit`._\n\n' "$shown" "$total_rows" "$((total_rows - shown))"
fi
printf 'To inspect one: `scan.sh "<app name or bundle id>"`\n'
} | tee "$OUT_FILE"

printf '\n[saved] %s\n' "$OUT_FILE" >&2
