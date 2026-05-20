#!/usr/bin/env bash
#
# scan.sh — Discover locally installed Claude Code skills and emit metadata.
#
# Scans three sources, in priority order (first occurrence of a skill name wins):
#   1. project:  ${PROJECT_DIR:-$PWD}/.claude/skills/
#   2. personal: ~/.claude/skills/
#   3. plugin:   ~/.claude/plugins/cache/<marketplace>/<plugin>/<latest-version>/skills/
#
# Output (stdout, TSV, one skill per line):
#   <name>\t<source>\t<path>\t<description>
#
# `<source>` is one of: project | personal | plugin:<plugin-name>
# `<description>` is the YAML `description:` field, flattened to a single line.
#
# Summary line goes to stderr.
# Broken symlinks and SKILL.md files with no frontmatter are silently skipped
# (counted as `skipped`).

set -euo pipefail

BROKEN=0
NO_FRONTMATTER=0

# Extract YAML frontmatter `name` and `description` from a SKILL.md.
# Prints "name<TAB>description" or nothing if frontmatter is missing/empty.
parse_frontmatter() {
    awk '
    BEGIN { state=0; name=""; desc=""; in_folded=0 }
    NR==1 && /^---[[:space:]]*$/ { state=1; next }
    state==1 && /^---[[:space:]]*$/ { state=2; exit }
    state==1 {
        if (match($0, /^[a-zA-Z_][a-zA-Z0-9_-]*:/)) {
            key = substr($0, 1, RLENGTH-1)
            val = substr($0, RLENGTH+1)
            sub(/^[ \t]+/, "", val)
            sub(/[ \t]+$/, "", val)
            if (key == "name") {
                name = val
                in_folded = 0
            } else if (key == "description") {
                if (val == ">" || val == "|" || val == ">-" || val == "|-") {
                    desc = ""
                    in_folded = 1
                } else {
                    desc = val
                    in_folded = 0
                }
            } else {
                in_folded = 0
            }
        } else if (in_folded) {
            line = $0
            sub(/^[ \t]+/, "", line)
            sub(/[ \t]+$/, "", line)
            if (line != "") {
                if (desc == "") desc = line
                else desc = desc " " line
            }
        }
    }
    END {
        if (name != "") print name "\t" desc
    }
    ' "$1"
}

emit_skill() {
    local source="$1" path="$2"
    local parsed
    parsed=$(parse_frontmatter "$path")
    if [ -z "$parsed" ]; then
        NO_FRONTMATTER=$((NO_FRONTMATTER + 1))
        return
    fi
    local name desc
    name=${parsed%%$'\t'*}
    desc=${parsed#*$'\t'}
    [ -n "$name" ] || { NO_FRONTMATTER=$((NO_FRONTMATTER + 1)); return; }
    printf '%s\t%s\t%s\t%s\n' "$name" "$source" "$path" "$desc"
}

scan_dir() {
    local source="$1" base="$2"
    [ -d "$base" ] || return 0
    # shellcheck disable=SC2231
    for entry in "$base"/*; do
        # Broken symlinks: `-e` is false even though the entry exists in listing.
        if [ -L "$entry" ] && [ ! -e "$entry" ]; then
            BROKEN=$((BROKEN + 1))
            continue
        fi
        [ -d "$entry" ] || continue
        [ -f "$entry/SKILL.md" ] || continue
        emit_skill "$source" "$entry/SKILL.md"
    done
}

scan_plugin_cache() {
    local cache="$HOME/.claude/plugins/cache"
    [ -d "$cache" ] || return 0
    for marketplace_dir in "$cache"/*/; do
        [ -d "$marketplace_dir" ] || continue
        for plugin_dir in "$marketplace_dir"*/; do
            [ -d "$plugin_dir" ] || continue
            local plugin
            plugin=$(basename "$plugin_dir")
            local latest
            latest=$(ls -1 "$plugin_dir" 2>/dev/null | sort -V | tail -1)
            [ -n "$latest" ] || continue
            local skills_dir="$plugin_dir$latest/skills"
            [ -d "$skills_dir" ] || continue
            scan_dir "plugin:$plugin" "$skills_dir"
        done
    done
}

TMP=$(mktemp)
trap 'rm -f "$TMP" "$TMP.out"' EXIT

scan_dir "project"  "${PROJECT_DIR:-$PWD}/.claude/skills" >> "$TMP"
scan_dir "personal" "$HOME/.claude/skills"                >> "$TMP"
scan_plugin_cache                                          >> "$TMP"

# Dedup by skill name, first occurrence wins (= highest priority source).
awk -F'\t' '!seen[$1]++' "$TMP" > "$TMP.out"
cat "$TMP.out"

COUNT=$(wc -l < "$TMP.out" | tr -d ' ')
SUMMARY="scanned $COUNT skills"
[ "$BROKEN" -gt 0 ] && SUMMARY="$SUMMARY, $BROKEN broken symlink(s) skipped"
[ "$NO_FRONTMATTER" -gt 0 ] && SUMMARY="$SUMMARY, $NO_FRONTMATTER without frontmatter skipped"
echo "$SUMMARY" >&2
