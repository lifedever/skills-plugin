#!/usr/bin/env bash
# mac-cleanup-process scan.sh — diagnose macOS zombie / stuck processes. Scan only, never kill.
# See DESIGN.md in the same directory for details.

set -u  # error on undefined variables
set -o pipefail

# Pre-flight: fail fast if ps is unavailable
if ! ps -eo pid=,ppid= > /dev/null 2>&1; then
  echo "ERROR: ps command unavailable or permission denied" >&2
  exit 1
fi

# ===== Threshold constants (user-tunable) =====
OLD_CLAUDE_HOURS=24
OLD_DEV_SERVER_DAYS=2
OLD_SHELL_TAB_DAYS=3
BIG_MEM_RSS_MB=500
BIG_MEM_DAYS=3

# ===== Infrastructure =====
timestamp="$(date +%Y-%m-%d-%H%M%S)"
output_dir="$HOME/Downloads"
output_file="$output_dir/mac-cleanup-process-$timestamp.md"
mkdir -p "$output_dir"

# System snapshot
get_system_snapshot() {
  local load_1m mem_used compressor free
  load_1m="$(sysctl -n vm.loadavg | awk '{print $2}')"
  # top's PhysMem line looks like: "PhysMem: 30G used (4288M wired, 11G compressor), 329M unused."
  local physmem
  physmem="$(top -l 1 -n 0 | awk -F'[:,]' '/^PhysMem/ {print}')"
  mem_used="$(echo "$physmem" | awk '{print $2}')"
  compressor="$(echo "$physmem" | grep -oE '[0-9]+[KMG] compressor' | awk '{print $1}')"
  free="$(echo "$physmem" | grep -oE '[0-9]+[KMG] unused' | awk '{print $1}')"
  echo "Load ${load_1m:-?} | memory used ${mem_used:-?}, compressor ${compressor:-?}, free ${free:-?}"
}

# Walk up PPID from $$, find the first ancestor whose command matches claude.
# Empty on failure.
find_current_claude_pid() {
  local pid=$$
  local max_depth=20  # prevent infinite loop
  local i=0
  while [ "$pid" != "1" ] && [ "$pid" != "0" ] && [ -n "$pid" ] && [ $i -lt $max_depth ]; do
    local comm
    comm="$(ps -p "$pid" -o comm= 2>/dev/null | awk '{print $1}')"
    # comm may be "claude", or claude's renamed internal value (e.g. "2.1.119").
    # More robust: match against the full command.
    local full_cmd
    full_cmd="$(ps -p "$pid" -o command= 2>/dev/null)"
    if echo "$full_cmd" | grep -qE '(^|/)claude(\s|$)'; then
      echo "$pid"
      return 0
    fi
    pid="$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ')"
    i=$((i + 1))
  done
  echo ""
}

# Redact passwords in command lines: scheme://user:password@host → scheme://user:***@host
sanitize_cmd() {
  sed -E 's#(://[A-Za-z0-9._-]+):[^@[:space:]]+@#\1:***@#g'
}

# MCP service command signature (extended ERE regex)
readonly MCP_PATTERN='(npm exec.*mcp|mcp-server-|@playwright/mcp|@upstash/context7-mcp|@modelcontextprotocol/|@henkey/postgres-mcp-server|figma-developer-mcp|xcodebuildmcp|mcp-mongo-server|alibabacloud-devops-mcp-server|drawio/mcp|context7-mcp|chrome-devtools-mcp|Pencil.app/Contents/Resources/app.asar.unpacked/out/mcp-server)'

# Find PPID=1 processes (current user) whose command matches MCP_PATTERN.
# Output format: PID<TAB>etime<TAB>rss<TAB>sanitized_command
find_mcp_orphans() {
  local my_uid
  my_uid="$(id -u)"
  # ps -eo format: uid pid ppid etime rss command
  ps -eo uid=,pid=,ppid=,etime=,rss=,command= 2>/dev/null | awk -v uid="$my_uid" '
    $1 == uid && $3 == 1 {
      # Reassemble command (from column 6 on)
      cmd = ""
      for (i = 6; i <= NF; i++) cmd = (cmd == "" ? $i : cmd " " $i)
      print $2 "\t" $4 "\t" $5 "\t" cmd
    }
  ' | grep -E "$MCP_PATTERN" | while IFS=$'\t' read -r pid etime rss cmd; do
    local sanitized
    sanitized="$(echo "$cmd" | sanitize_cmd)"
    # Truncate command summary (keep table width sane)
    local summary
    summary="$(echo "$sanitized" | cut -c1-80)"
    local rss_mb=$((rss / 1024))
    printf '%s\t%s\t%s\t%s\n' "$pid" "$etime" "$rss_mb" "$summary"
  done
}

# Given a newline-separated PID list, recursively collect all descendant PIDs.
collect_descendants() {
  local parents="$1"
  [ -z "$parents" ] && return
  local all_kids=""
  while IFS= read -r parent_pid; do
    [ -z "$parent_pid" ] && continue
    local kids
    kids="$(pgrep -P "$parent_pid" 2>/dev/null)"
    if [ -n "$kids" ]; then
      all_kids="${all_kids}${kids}
"
    fi
  done <<< "$parents"
  if [ -n "$all_kids" ]; then
    echo "$all_kids"
    # Recurse: kids' kids
    collect_descendants "$all_kids"
  fi
}

# From the MCP orphan PID list, recursively find all descendants and output
# table rows with details.
find_mcp_orphan_children() {
  local parent_pids="$1"  # newline-separated
  [ -z "$parent_pids" ] && return
  local all_descendants
  all_descendants="$(collect_descendants "$parent_pids" | sort -u | grep -v '^$')"
  [ -z "$all_descendants" ] && return
  while IFS= read -r pid; do
    [ -z "$pid" ] && continue
    local info
    info="$(ps -p "$pid" -o ppid=,etime=,rss=,command= 2>/dev/null)"
    [ -z "$info" ] && continue
    local ppid etime rss cmd
    ppid="$(echo "$info" | awk '{print $1}')"
    etime="$(echo "$info" | awk '{print $2}')"
    rss="$(echo "$info" | awk '{print $3}')"
    cmd="$(echo "$info" | awk '{for(i=4;i<=NF;i++) printf "%s%s", $i, (i<NF?" ":"")}')"
    local sanitized summary rss_mb
    sanitized="$(echo "$cmd" | sanitize_cmd)"
    summary="$(echo "$sanitized" | cut -c1-80)"
    rss_mb=$((rss / 1024))
    printf '%s\t%s\t%s\t%s\t%s\n' "$pid" "$ppid" "$etime" "$rss_mb" "$summary"
  done <<< "$all_descendants"
}

# Whether the Docker UI is running
is_docker_ui_running() {
  pgrep -x -f '/Applications/Docker.app/Contents/MacOS/Docker' > /dev/null 2>&1
}

# Find leftover cagent processes (only when the Docker UI is NOT running).
# Output format: PID<TAB>etime<TAB>rss_mb<TAB>command_summary
find_cagent_residuals() {
  if is_docker_ui_running; then
    return 0  # empty output = no residuals
  fi
  local my_uid
  my_uid="$(id -u)"
  ps -eo uid=,pid=,etime=,rss=,command= 2>/dev/null | awk -v uid="$my_uid" '
    $1 == uid && /cagent/ {
      cmd = ""
      for (i = 5; i <= NF; i++) cmd = (cmd == "" ? $i : cmd " " $i)
      print $2 "\t" $3 "\t" $4 "\t" cmd
    }
  ' | while IFS=$'\t' read -r pid etime rss cmd; do
    local sanitized summary rss_mb
    sanitized="$(echo "$cmd" | sanitize_cmd)"
    summary="$(echo "$sanitized" | cut -c1-80)"
    rss_mb=$((rss / 1024))
    printf '%s\t%s\t%s\t%s\n' "$pid" "$etime" "$rss_mb" "$summary"
  done
}

# Convert an etime string to a total hour count (integer, floored; mins >= 30 rounds up).
etime_to_hours() {
  local etime="$1"
  local days=0 hours=0 mins=0
  if [[ "$etime" == *-* ]]; then
    days="${etime%%-*}"
    etime="${etime#*-}"
  fi
  local parts
  IFS=':' read -ra parts <<< "$etime"
  if [ "${#parts[@]}" -eq 3 ]; then
    hours="${parts[0]}"
    mins="${parts[1]}"
  elif [ "${#parts[@]}" -eq 2 ]; then
    hours=0
    mins="${parts[0]}"
  fi
  # Strip leading zeros to avoid octal interpretation
  days=$((10#$days))
  hours=$((10#$hours))
  mins=$((10#$mins))
  echo $((days * 24 + hours + (mins >= 30 ? 1 : 0)))
}

# "7-21:28:08" → "7 days 21 hours"
# "23:30:05"   → "23 hours 30 min"
# "40:12"      → "40 minutes"
etime_humanize() {
  local etime="$1"
  local days=0 hours=0 mins=0
  if [[ "$etime" == *-* ]]; then
    days="${etime%%-*}"
    etime="${etime#*-}"
  fi
  local parts
  IFS=':' read -ra parts <<< "$etime"
  if [ "${#parts[@]}" -eq 3 ]; then
    hours="${parts[0]}"; mins="${parts[1]}"
  elif [ "${#parts[@]}" -eq 2 ]; then
    hours=0; mins="${parts[0]}"
  fi
  days=$((10#$days)); hours=$((10#$hours)); mins=$((10#$mins))

  if [ "$days" -gt 0 ]; then
    echo "$days days $hours hours"
  elif [ "$hours" -gt 0 ]; then
    echo "$hours hours $mins min"
  else
    echo "$mins minutes"
  fi
}

# Read a process's cwd via lsof
get_cwd() {
  local pid="$1"
  lsof -p "$pid" 2>/dev/null | awk '$4 == "cwd" {for (i=9; i<=NF; i++) printf "%s%s", $i, (i<NF?" ":""); exit}'
}

# Replace $HOME prefix in an absolute path with ~.
# Use case branches rather than bash pattern substitution to dodge inconsistencies in
# how some bash versions handle ${p/#$home/~} edge cases.
tildify_path() {
  local p="$1"
  case "$p" in
    "$HOME"/*) echo "~${p#"$HOME"}" ;;
    "$HOME") echo "~" ;;
    *) echo "$p" ;;
  esac
}

# Parent chain (process names), up to 5 levels
parent_chain() {
  local pid="$1"
  local chain="" cur="$pid"
  local i=0
  while [ -n "$cur" ] && [ "$cur" != "1" ] && [ "$cur" != "0" ] && [ $i -lt 5 ]; do
    local pcomm
    pcomm="$(ps -p "$cur" -o comm= 2>/dev/null | awk -F/ '{print $NF}' | awk '{print $1}')"
    [ -z "$pcomm" ] && break
    chain="$pcomm${chain:+ → $chain}"
    cur="$(ps -p "$cur" -o ppid= 2>/dev/null | tr -d ' ')"
    i=$((i + 1))
  done
  echo "$chain"
}

# Find old claude sessions
# Args: $1 = current_claude_pid (may be empty)
# Output per line: PID<TAB>etime<TAB>etime_human<TAB>cwd<TAB>rss_mb<TAB>mcp_children_count<TAB>parent_chain<TAB>flags
# flags: "current" / "most_suspicious" / empty
find_old_claude_sessions() {
  local current_claude="$1"
  local threshold_hours="$OLD_CLAUDE_HOURS"
  local my_uid
  my_uid="$(id -u)"

  # All claude processes (full command contains the claude word)
  local candidates
  candidates="$(ps -eo uid=,pid=,etime=,rss=,command= 2>/dev/null | awk -v uid="$my_uid" '
    $1 == uid {
      cmd = ""
      for (i = 5; i <= NF; i++) cmd = (cmd == "" ? $i : cmd " " $i)
      if (cmd ~ /(^|\/)claude( |$)/) print $2 "\t" $3 "\t" $4 "\t" cmd
    }
  ')"

  # Filter over-threshold + find the oldest
  local filtered=""
  local max_hours=0
  local max_pid=""
  while IFS=$'\t' read -r pid etime rss cmd; do
    [ -z "$pid" ] && continue
    local hours
    hours="$(etime_to_hours "$etime")"
    if [ "$hours" -ge "$threshold_hours" ]; then
      filtered="${filtered}${pid}"$'\t'"${etime}"$'\t'"${rss}"$'\n'
      if [ "$hours" -gt "$max_hours" ]; then
        max_hours="$hours"
        max_pid="$pid"
      fi
    fi
  done <<< "$candidates"

  [ -z "$filtered" ] && return 0

  # Add details
  while IFS=$'\t' read -r pid etime rss; do
    [ -z "$pid" ] && continue
    local human cwd_raw cwd_tilde rss_mb mcp_count chain flags=""
    human="$(etime_humanize "$etime")"
    cwd_raw="$(get_cwd "$pid")"
    cwd_tilde="$(tildify_path "${cwd_raw:-?}")"
    rss_mb=$((rss / 1024))
    # MCP children count: recursively collect + filter by MCP signature
    local descendants
    descendants="$(collect_descendants "$pid" | sort -u | grep -v '^$')"
    if [ -z "$descendants" ]; then
      mcp_count=0
    else
      mcp_count="$(echo "$descendants" | while read -r dpid; do
        [ -z "$dpid" ] && continue
        ps -p "$dpid" -o command= 2>/dev/null
      done | grep -cE "$MCP_PATTERN")"
    fi
    chain="$(parent_chain "$pid")"

    if [ -n "$current_claude" ] && [ "$pid" = "$current_claude" ]; then
      flags="current"
    elif [ "$pid" = "$max_pid" ]; then
      flags="most_suspicious"
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$pid" "$etime" "$human" "$cwd_tilde" "$rss_mb" "$mcp_count" "$chain" "$flags"
  done <<< "$filtered"
}

readonly DEV_SERVER_PATTERN='(vite|webpack|pnpm dev|next dev|nuxt dev|npm run dev|yarn dev|rollup.*watch)'

# Output: PID<TAB>etime<TAB>etime_human<TAB>cwd<TAB>command_summary
find_old_dev_servers() {
  local threshold_hours=$((OLD_DEV_SERVER_DAYS * 24))
  local my_uid
  my_uid="$(id -u)"
  local candidates
  candidates="$(ps -eo uid=,pid=,etime=,command= 2>/dev/null | awk -v uid="$my_uid" '
    $1 == uid {
      cmd = ""
      for (i = 4; i <= NF; i++) cmd = (cmd == "" ? $i : cmd " " $i)
      print $2 "\t" $3 "\t" cmd
    }
  ' | grep -E "$DEV_SERVER_PATTERN")"

  [ -z "$candidates" ] && return

  while IFS=$'\t' read -r pid etime cmd; do
    [ -z "$pid" ] && continue
    local hours
    hours="$(etime_to_hours "$etime")"
    [ "$hours" -lt "$threshold_hours" ] && continue
    local human cwd cwd_tilde sanitized summary
    human="$(etime_humanize "$etime")"
    cwd="$(get_cwd "$pid")"
    cwd_tilde="$(tildify_path "${cwd:-?}")"
    sanitized="$(echo "$cmd" | sanitize_cmd)"
    summary="$(echo "$sanitized" | cut -c1-100)"
    printf '%s\t%s\t%s\t%s\t%s\n' "$pid" "$etime" "$human" "$cwd_tilde" "$summary"
  done <<< "$candidates"
}

# Long-lived login shell (terminal tab) — matches any old zsh launched by /usr/bin/login
# Output: PID<TAB>etime<TAB>etime_human
find_old_shell_tabs() {
  local threshold_hours=$((OLD_SHELL_TAB_DAYS * 24))
  local my_uid
  my_uid="$(id -u)"
  # First, find all zsh processes
  ps -eo uid=,pid=,ppid=,etime=,comm= 2>/dev/null | awk -v uid="$my_uid" '
    $1 == uid && $5 ~ /zsh$/ { print $2 "\t" $3 "\t" $4 }
  ' | while IFS=$'\t' read -r pid ppid etime; do
    # Is the parent process /usr/bin/login?
    local parent_cmd
    parent_cmd="$(ps -p "$ppid" -o command= 2>/dev/null | awk '{print $1}')"
    [ "$parent_cmd" != "/usr/bin/login" ] && continue
    local hours
    hours="$(etime_to_hours "$etime")"
    [ "$hours" -lt "$threshold_hours" ] && continue
    local human
    human="$(etime_humanize "$etime")"
    printf '%s\t%s\t%s\n' "$pid" "$etime" "$human"
  done
}

# excluded_pids: newline-separated PID list — already covered by a previous rule, don't list again
# Output: PID<TAB>etime_human<TAB>rss_mb<TAB>command_summary
find_big_mem_old() {
  local excluded_pids="$1"
  local threshold_hours=$((BIG_MEM_DAYS * 24))
  local threshold_rss_kb=$((BIG_MEM_RSS_MB * 1024))
  local my_uid
  my_uid="$(id -u)"

  # Build the excluded-lookup file (associative arrays aren't in Bash 3.2;
  # use a temp file + grep -xF)
  local excl_file
  excl_file="$(mktemp)"
  echo "$excluded_pids" > "$excl_file"

  ps -eo uid=,pid=,etime=,rss=,command= 2>/dev/null | awk -v uid="$my_uid" -v rss_min="$threshold_rss_kb" '
    $1 == uid && $4 >= rss_min {
      cmd = ""
      for (i = 5; i <= NF; i++) cmd = (cmd == "" ? $i : cmd " " $i)
      print $2 "\t" $3 "\t" $4 "\t" cmd
    }
  ' | while IFS=$'\t' read -r pid etime rss cmd; do
    # Check if excluded
    if grep -qxF "$pid" "$excl_file"; then
      continue
    fi
    local hours
    hours="$(etime_to_hours "$etime")"
    [ "$hours" -lt "$threshold_hours" ] && continue
    local human rss_mb sanitized summary
    human="$(etime_humanize "$etime")"
    rss_mb=$((rss / 1024))
    sanitized="$(echo "$cmd" | sanitize_cmd)"
    summary="$(echo "$sanitized" | cut -c1-80)"
    printf '%s\t%s\t%s\t%s\n' "$pid" "$human" "$rss_mb" "$summary"
  done

  rm -f "$excl_file"
}

# ===== Report generation =====
render_mcp_orphans_section() {
  local rows="$1"
  echo ""
  echo "### MCP server orphans"
  echo ""
  if [ -z "$rows" ]; then
    echo "(none)"
    return
  fi
  echo "| PID | etime | RSS (MB) | Command summary |"
  echo "|-----|-------|----------|-----------------|"
  while IFS=$'\t' read -r pid etime rss summary; do
    echo "| $pid | $etime | $rss | $summary |"
  done <<< "$rows"
  local count
  count="$(echo "$rows" | wc -l | tr -d ' ')"
  echo ""
  echo "**$count total.**"
}

render_mcp_children_section() {
  local child_rows="$1"  # already detailed rows (PID<TAB>PPID<TAB>etime<TAB>rss_mb<TAB>summary)

  echo ""
  echo "### MCP orphan descendants"
  echo ""
  if [ -z "$child_rows" ]; then
    echo "(none)"
    return
  fi
  echo "| PID | Parent PID | etime | RSS (MB) | Command summary |"
  echo "|-----|------------|-------|----------|-----------------|"
  while IFS=$'\t' read -r pid ppid etime rss summary; do
    echo "| $pid | $ppid | $etime | $rss | $summary |"
  done <<< "$child_rows"
  local count
  count="$(echo "$child_rows" | wc -l | tr -d ' ')"
  echo ""
  echo "**$count total (killing the MCP parents above will reap these automatically).**"
}

render_cagent_section() {
  local rows="$1"
  echo ""
  echo "### Docker cagent leftovers"
  echo ""
  if is_docker_ui_running; then
    echo "(Docker UI is running, cagent scan skipped)"
    return
  fi
  if [ -z "$rows" ]; then
    echo "(none)"
    return
  fi
  echo "| PID | etime | RSS (MB) | Command summary |"
  echo "|-----|-------|----------|-----------------|"
  while IFS=$'\t' read -r pid etime rss summary; do
    echo "| $pid | $etime | $rss | $summary |"
  done <<< "$rows"
  local count
  count="$(echo "$rows" | wc -l | tr -d ' ')"
  echo ""
  echo "**$count total (Docker UI is not running; these cagent processes are safe to nuke).**"
}

render_old_claude_section() {
  local current_claude="$1"
  local rows="$2"
  echo ""
  echo "### ① Old claude sessions (>${OLD_CLAUDE_HOURS}h)"
  echo ""
  if [ -z "$rows" ]; then
    echo "(none)"
    return
  fi
  while IFS=$'\t' read -r pid etime human cwd rss mcp_count chain flags; do
    local label=""
    case "$flags" in
      current) label=' `[current session — DO NOT KILL]`' ;;
      most_suspicious) label=' [most suspicious]' ;;
    esac
    echo "- **PID $pid**$label"
    echo "  - Project: \`$cwd\`"
    echo "  - Runtime: $human"
    echo "  - Memory: ${rss} MB (self) + ${mcp_count} MCP children"
    echo "  - Parent chain: $chain"
    echo ""
  done <<< "$rows"
}

render_old_dev_server_section() {
  local rows="$1"
  echo ""
  echo "### ② Long-running dev servers (>${OLD_DEV_SERVER_DAYS} days)"
  echo ""
  if [ -z "$rows" ]; then
    echo "(none)"
    return
  fi
  while IFS=$'\t' read -r pid etime human cwd summary; do
    echo "- **PID $pid**"
    echo "  - Command: \`$summary\`"
    echo "  - Project: \`$cwd\`"
    echo "  - Runtime: $human"
    echo ""
  done <<< "$rows"
}

render_old_shell_section() {
  local rows="$1"
  echo ""
  echo "### ③ Long-lived terminal tabs (>${OLD_SHELL_TAB_DAYS} days)"
  echo ""
  if [ -z "$rows" ]; then
    echo "(none)"
    return
  fi
  while IFS=$'\t' read -r pid etime human; do
    echo "- **PID $pid** zsh, $human"
  done <<< "$rows"
  local count
  count="$(echo "$rows" | wc -l | tr -d ' ')"
  echo ""
  echo "**$count total. Just close them with Cmd+W in the corresponding terminal (works with any macOS terminal: Terminal / iTerm2 / Ghostty / WezTerm, etc.).**"
}

render_big_mem_section() {
  local rows="$1"
  echo ""
  echo "### ④ Large-memory over-age (RSS >${BIG_MEM_RSS_MB}MB and >${BIG_MEM_DAYS} days)"
  echo ""
  if [ -z "$rows" ]; then
    echo "(none)"
    return
  fi
  while IFS=$'\t' read -r pid human rss_mb summary; do
    echo "- **PID $pid** \`$summary\`, $human, ${rss_mb} MB"
  done <<< "$rows"
}

render_suggested_commands() {
  local mcp_rows="$1"
  local cagent_rows="$2"
  local oldc_rows="$3"
  local olds_rows="$4"
  local bigmem_rows="$5"
  local current_claude="$6"

  echo ""
  echo "---"
  echo ""
  echo "## 💡 Suggested commands (copy-paste ready)"
  echo ""
  echo '```bash'

  # Explicit orphans
  local has_obvious=""
  local mcp_pids
  mcp_pids="$(echo "$mcp_rows" | awk -F'\t' 'NF>0 {print $1}' | tr '\n' ' ' | sed 's/ $//')"
  if [ -n "$mcp_pids" ]; then
    echo "# === Explicit orphans (safe to nuke) ==="
    echo "# MCP orphans + descendants (killing the parents reaps the children automatically)"
    echo "kill $mcp_pids"
    has_obvious=1
  fi
  if [ -n "$cagent_rows" ]; then
    [ -z "$has_obvious" ] && echo "# === Explicit orphans (safe to nuke) ==="
    echo ""
    echo "# Docker cagent leftovers"
    echo "pkill -9 -f cagent"
    has_obvious=1
  fi

  # Suspicious items
  local has_suspicious=""
  local suspicious_lines=""

  # Old claude (excluding current)
  if [ -n "$oldc_rows" ]; then
    while IFS=$'\t' read -r pid etime human cwd rss mcp_count chain flags; do
      [ -z "$pid" ] && continue
      if [ "$flags" = "current" ] || [ "$pid" = "$current_claude" ]; then
        continue  # NEVER suggest killing the current session
      fi
      local basename
      basename="$(echo "$cwd" | awk -F/ '{print $NF}')"
      local note="$basename old claude, $human"
      if [ "$mcp_count" -gt 0 ]; then
        note="$note → will reap $mcp_count MCP children"
      fi
      suspicious_lines+="# kill $pid   # $note"$'\n'
      has_suspicious=1
    done <<< "$oldc_rows"
  fi

  # Old dev servers
  if [ -n "$olds_rows" ]; then
    while IFS=$'\t' read -r pid etime human cwd summary; do
      [ -z "$pid" ] && continue
      local basename
      basename="$(echo "$cwd" | awk -F/ '{print $NF}')"
      suspicious_lines+="# kill $pid   # $basename dev server, alive $human"$'\n'
      has_suspicious=1
    done <<< "$olds_rows"
  fi

  # Large-memory over-age (long-lived shell tabs are not listed here, since we
  # only recommend "close the tab", not "kill zsh")
  if [ -n "$bigmem_rows" ]; then
    while IFS=$'\t' read -r pid human rss_mb summary; do
      [ -z "$pid" ] && continue
      suspicious_lines+="# kill $pid   # $summary, $human, ${rss_mb} MB"$'\n'
      has_suspicious=1
    done <<< "$bigmem_rows"
  fi

  if [ -n "$has_suspicious" ]; then
    echo ""
    echo "# === Suspicious items (uncomment after your own judgment) ==="
    echo -n "$suspicious_lines"
  fi

  echo '```'
  echo ""
  echo "---"
  echo ""
  echo "**Usage hints**:"
  if [ -n "$current_claude" ]; then
    echo "- The suggested-command block already excludes the current claude session (PID ${current_claude})"
  fi
  echo "- To have me execute, reply \`kill <PID>\` or \`run explicit-orphan cleanup\`"
  echo "- If you copy to a terminal yourself, I won't take any further action"
}

render_report() {
  local snapshot display_time current_claude
  snapshot="$(get_system_snapshot)"
  display_time="$(date '+%Y-%m-%d %H:%M:%S')"
  current_claude="$(find_current_claude_pid)"

  local guard_line
  if [ -n "$current_claude" ]; then
    guard_line="**Current session — DO NOT KILL**: PID $current_claude"
  else
    guard_line="**Current session — DO NOT KILL**: (not identified; all claude processes are cleanup candidates)"
  fi

  # Scan every category once — cache to variables to avoid duplicate calls
  local mcp_rows mcp_kids_rows cagent_rows oldc_rows olds_rows ghost_rows bigmem_rows
  mcp_rows="$(find_mcp_orphans)"

  local mcp_parent_pids
  mcp_parent_pids="$(echo "$mcp_rows" | awk -F'\t' 'NF>0 {print $1}')"
  mcp_kids_rows="$(find_mcp_orphan_children "$mcp_parent_pids")"

  cagent_rows="$(find_cagent_residuals)"
  oldc_rows="$(find_old_claude_sessions "$current_claude")"
  olds_rows="$(find_old_dev_servers)"
  shell_rows="$(find_old_shell_tabs)"

  # Aggregate classified PIDs (used to dedupe the large-memory section)
  local classified
  classified="$(printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$(echo "$mcp_rows" | awk -F'\t' 'NF>0 {print $1}')" \
    "$(echo "$mcp_kids_rows" | awk -F'\t' 'NF>0 {print $1}')" \
    "$(echo "$cagent_rows" | awk -F'\t' 'NF>0 {print $1}')" \
    "$(echo "$oldc_rows" | awk -F'\t' 'NF>0 {print $1}')" \
    "$(echo "$olds_rows" | awk -F'\t' 'NF>0 {print $1}')" \
    "$(echo "$ghost_rows" | awk -F'\t' 'NF>0 {print $1}')")"
  bigmem_rows="$(find_big_mem_old "$classified")"

  # Stats — explicit orphans
  local obvious_count=0 obvious_rss=0
  if [ -n "$mcp_rows" ]; then
    obvious_count=$((obvious_count + $(echo "$mcp_rows" | wc -l | tr -d ' ')))
    obvious_rss=$((obvious_rss + $(echo "$mcp_rows" | awk -F'\t' '{s+=$3} END {print s+0}')))
  fi
  if [ -n "$mcp_kids_rows" ]; then
    obvious_count=$((obvious_count + $(echo "$mcp_kids_rows" | wc -l | tr -d ' ')))
    obvious_rss=$((obvious_rss + $(echo "$mcp_kids_rows" | awk -F'\t' '{s+=$4} END {print s+0}')))
  fi
  if [ -n "$cagent_rows" ]; then
    obvious_count=$((obvious_count + $(echo "$cagent_rows" | wc -l | tr -d ' ')))
    obvious_rss=$((obvious_rss + $(echo "$cagent_rows" | awk -F'\t' '{s+=$3} END {print s+0}')))
  fi

  # Stats — suspicious
  local suspicious_count=0 suspicious_rss=0
  if [ -n "$oldc_rows" ]; then
    suspicious_count=$((suspicious_count + $(echo "$oldc_rows" | wc -l | tr -d ' ')))
    suspicious_rss=$((suspicious_rss + $(echo "$oldc_rows" | awk -F'\t' '{s+=$5} END {print s+0}')))
  fi
  if [ -n "$olds_rows" ]; then
    suspicious_count=$((suspicious_count + $(echo "$olds_rows" | wc -l | tr -d ' ')))
  fi
  if [ -n "$ghost_rows" ]; then
    suspicious_count=$((suspicious_count + $(echo "$ghost_rows" | wc -l | tr -d ' ')))
  fi
  if [ -n "$bigmem_rows" ]; then
    suspicious_count=$((suspicious_count + $(echo "$bigmem_rows" | wc -l | tr -d ' ')))
    suspicious_rss=$((suspicious_rss + $(echo "$bigmem_rows" | awk -F'\t' '{s+=$3} END {print s+0}')))
  fi

  # Summary line
  local summary_lines=""
  if [ "$obvious_count" -gt 0 ] || [ "$suspicious_count" -gt 0 ]; then
    local release_line="**Estimated reclaim**: ~${obvious_rss} MB (explicit orphans)"
    if [ "$suspicious_rss" -gt 0 ]; then
      release_line+=" + ~${suspicious_rss} MB (if you clean suspicious too)"
    fi
    summary_lines="$release_line
**Scan result**: ${obvious_count} explicit orphans · ${suspicious_count} suspicious — needs judgment"
  fi

  # Detect globally-empty case
  local total_rows=0
  local rows
  for rows in "$mcp_rows" "$mcp_kids_rows" "$cagent_rows" "$oldc_rows" "$olds_rows" "$ghost_rows" "$bigmem_rows"; do
    if [ -n "$rows" ]; then
      total_rows=$((total_rows + $(echo "$rows" | wc -l | tr -d ' ')))
    fi
  done

  # Emit the header (regardless of clean state)
  cat <<EOF
# 🧹 System Zombie Scan Report

**Scan time**: $display_time
**System snapshot**: $snapshot
$guard_line

📄 Full report saved to \`$output_file\`

---

EOF

  if [ "$total_rows" -eq 0 ]; then
    echo "## 🎉 No zombies found"
    echo ""
    echo "System is clean. Nothing to do."
    return
  fi

  # Insert summary lines into the report when there are candidates
  if [ -n "$summary_lines" ]; then
    echo "$summary_lines"
    echo ""
  fi

  echo "## ✅ Explicit orphans (safe to nuke)"
  render_mcp_orphans_section "$mcp_rows"
  render_mcp_children_section "$mcp_kids_rows"
  render_cagent_section "$cagent_rows"

  echo ""
  echo "## ⚠️ Suspicious — needs your judgment"
  render_old_claude_section "$current_claude" "$oldc_rows"
  render_old_dev_server_section "$olds_rows"
  render_old_shell_section "$shell_rows"
  render_big_mem_section "$bigmem_rows"

  render_suggested_commands \
    "$mcp_rows" \
    "$cagent_rows" \
    "$oldc_rows" \
    "$olds_rows" \
    "$bigmem_rows" \
    "$current_claude"
}

# ===== Main =====
main() {
  render_report | tee "$output_file"
}

# Only run main when executed directly, not when sourced
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
