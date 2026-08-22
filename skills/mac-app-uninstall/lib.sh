#!/usr/bin/env bash
# mac-app-uninstall lib.sh — shared helpers for scan.sh and list-apps.sh.
# Sourced, never executed directly. Defines functions only; no side effects.
#
# Everything here is shared on purpose: a second copy of the app census or of the
# Info.plist resolution would drift, and the half that drifts is the half that
# silently stops finding things.

# Locate a bundle's Info.plist. iOS/iPadOS apps installed on Apple Silicon
# ("Designed for iPad") are wrappers — the real bundle sits behind the
# WrappedBundle symlink and puts Info.plist at its root, not under Contents/.
# Without this, those apps report an unknown bundle id and every leftover lookup
# silently finds nothing.
info_plist_for() {
  local app="$1"
  if [ -f "$app/Contents/Info.plist" ]; then
    printf '%s' "$app/Contents/Info.plist"
  elif [ -f "$app/WrappedBundle/Info.plist" ]; then
    printf '%s' "$app/WrappedBundle/Info.plist"
  fi
}

# plutil-based Info.plist read. Empty string on any failure.
plist_get() {
  local plist="$1" key="$2" val
  val="$(plutil -extract "$key" raw -o - "$plist" 2>/dev/null)" || return 0
  # plutil emits "<stdin>" style errors to stdout in some versions; guard.
  case "$val" in
    *"Could not extract"* | *"is not a valid"*) return 0 ;;
  esac
  printf '%s' "$val"
}

# Human-readable size of a path. "?" when unreadable.
path_size() {
  local p="$1" kb
  kb="$(du -sk "$p" 2>/dev/null | awk '{print $1}')"
  [ -z "$kb" ] && { printf '?'; return 0; }
  awk -v k="$kb" 'BEGIN{
    if (k < 1024) printf "%dKB", k;
    else if (k < 1048576) printf "%.1fMB", k/1024;
    else printf "%.2fGB", k/1048576;
  }'
}

# Lowercase without relying on bash 4 (macOS ships bash 3.2).
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Escape glob metacharacters for find -name/-iname. Without this, an app named
# "Foo [2024]" matches nothing, and a hostile or careless "****" expands to match
# EVERYTHING under ~/Library — measured at 8461 paths on the dev machine, all of
# which would land in the review tier and become removable with --tier all.
escape_glob() { printf '%s' "$1" | sed 's/[][*?\\]/\\&/g'; }

# Escape ERE metacharacters for pgrep -f, whose pattern is a regex. A bundle id
# of ".*" would otherwise match every process on the machine.
escape_ere() { printf '%s' "$1" | sed 's/[][^$.*+?(){}|\\]/\\&/g'; }

# A path is unsafe for a TAB-separated record if it contains a tab or newline.
# Callers surface these rather than silently dropping them.
# NB: must use $'\t' / $'\n' — $(printf '\n') strips the trailing newline in
# command substitution, collapsing the pattern to `*` which matches everything.
path_is_manifest_safe() {
  case "$1" in
    *$'\t'* | *$'\n'*) return 1 ;;
    *) return 0 ;;
  esac
}

# All output lands in one folder under ~/Downloads rather than scattered across
# it. Wide Markdown tables wrap and misalign in a terminal, so the readable copy
# is always a file the user opens; stdout is for the agent.
# Echoes the path, creating it if needed.
mau_out_dir() {
  local d="$HOME/Downloads/mac-app-uninstall"
  mkdir -p "$d" 2>/dev/null
  printf '%s' "$d"
}

# Turn an app name into something safe for a file or directory name. Keeps
# non-ASCII (a folder called 微店 is fine and more readable than mangled ASCII);
# only strips what the filesystem or a shell would choke on.
mau_safe_name() {
  printf '%s' "$1" | tr '/:' '__' | tr ' ' '-' | tr -d '\n\t'
}

# Directories searched for installed applications.
#
# /System/Applications is included deliberately: Apple's bundle ids must be in
# the ownership table, or an Apple-owned leftover could be attributed to the
# target app and tiered as safe to delete.
MAU_APP_DIRS='/Applications
'"$HOME"'/Applications
/Applications/Setapp
/Applications/Utilities
/System/Applications
/System/Applications/Utilities'

# build_census <outfile>
# Writes one TAB-separated record per installed app: bundle_id \t name \t path
# Echoes the number of apps found.
#
# Enumerating these directories replaces what used to be a Spotlight query.
# mdfind's query language has no shell-side escaping, which cost two injection
# surfaces and a 120s hang; a directory walk has neither problem and does not
# depend on the Spotlight index being healthy.
build_census() {
  local out="$1" d app app_plist bid nm n=0
  : > "$out"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    [ -d "$d" ] || continue
    while IFS= read -r app; do
      [ -n "$app" ] || continue
      app_plist="$(info_plist_for "$app")"
      bid=""
      [ -n "$app_plist" ] && bid="$(plist_get "$app_plist" CFBundleIdentifier)"
      nm="$(basename "$app" .app)"
      # Tabs/newlines in a path or name would corrupt the record.
      path_is_manifest_safe "$app" || continue
      path_is_manifest_safe "$nm" || continue
      printf '%s\t%s\t%s\n' "$bid" "$nm" "$app" >> "$out"
      n=$((n + 1))
    done < <(find "$d" -maxdepth 2 -name "*.app" -prune 2>/dev/null)
  done <<EOF
$MAU_APP_DIRS
EOF
  # Deduplicate: the search directories overlap (a -maxdepth 2 walk of
  # /Applications also reaches /Applications/Setapp/*.app), so the same bundle
  # can be recorded twice. Records for one path are byte-identical, so a plain
  # unique sort is enough.
  sort -u "$out" -o "$out"
  n="$(wc -l < "$out" | tr -d ' ')"
  printf '%s' "$n"
}
