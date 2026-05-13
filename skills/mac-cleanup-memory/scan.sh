#!/usr/bin/env bash
# mac-cleanup-memory scan.sh — macOS memory landscape diagnostic (diagnosis only, never kills)
# See DESIGN.md in the same directory for details.

set -u
set -o pipefail

# Pre-flight: vm_stat / ps / sysctl must exist
for cmd in vm_stat ps sysctl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command $cmd not found" >&2
    exit 1
  fi
done

# ===== Config (tunable) =====
TOP_N=15                  # show top N RAM consumers
APP_AGG_MIN_RSS_MB=100    # hide app aggregates below this MB
DUP_PROCESS_MIN_COUNT=2   # report "duplicate processes" observation when same-name count >= this

# ===== Infrastructure =====
timestamp="$(date +%Y-%m-%d-%H%M%S)"
output_dir="$HOME/Downloads"
output_file="$output_dir/mac-cleanup-memory-$timestamp.md"
mkdir -p "$output_dir"

# Adaptive page size: Apple Silicon 16K, Intel 4K
PAGE_SIZE_BYTES="$(sysctl -n hw.pagesize 2>/dev/null || echo 4096)"
PAGE_SIZE_KB=$((PAGE_SIZE_BYTES / 1024))
TOTAL_RAM_BYTES="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
TOTAL_RAM_GB=$(awk -v b="$TOTAL_RAM_BYTES" 'BEGIN{printf "%.0f", b/1024/1024/1024}')

# Convert KB to human-readable (e.g. 9437184 → "9.0 GB"; 384512 → "375 MB")
humanize_kb() {
  local kb="$1"
  awk -v k="$kb" 'BEGIN{
    if (k >= 1024*1024) printf "%.1f GB", k/1024/1024;
    else if (k >= 1024) printf "%.0f MB", k/1024;
    else printf "%d KB", k;
  }'
}

# Given a full process command, extract the "logical app group" it belongs to.
# - path contains /XXX.app/  → outermost .app name (without .app suffix)
# - otherwise → basename of the executable
# - things like `claude` (no .app but multiple instances) bucket by basename
get_app_group() {
  local cmd="$1"
  # Match the outermost (shallowest) .app
  local app_part
  app_part="$(echo "$cmd" | grep -oE '/[^/]+\.app/' | head -1 | sed 's|^/||;s|\.app/$||')"
  if [ -n "$app_part" ]; then
    echo "$app_part"
    return
  fi
  # No .app, take basename of the first token
  local first
  first="$(echo "$cmd" | awk '{print $1}')"
  basename "$first" 2>/dev/null || echo "?"
}

# Sanitize command (remove secrets + truncate)
sanitize_cmd() {
  sed -E 's#(://[A-Za-z0-9._-]+):[^@[:space:]]+@#\1:***@#g'
}

cmd_summary() {
  local cmd="$1"
  echo "$cmd" | sanitize_cmd | cut -c1-90
}

# ===== Data collection =====

# Parse vm_stat output → page counts per category
parse_vm_stat() {
  vm_stat | awk -v page_kb="$PAGE_SIZE_KB" '
    /Pages free/                       {free=$3+0}
    /Pages active/                     {active=$3+0}
    /Pages inactive/                   {inactive=$3+0}
    /Pages speculative/                {spec=$3+0}
    /Pages wired down/                 {wired=$4+0}
    /Pages occupied by compressor/     {comp=$5+0}
    /Pages purgeable/                  {purg=$3+0}
    /Swapins/                          {si=$2+0}
    /Swapouts/                         {so=$2+0}
    END {
      # Output: free_kb active_kb inactive_kb wired_kb comp_kb purg_kb spec_kb swap_in swap_out
      printf "%d %d %d %d %d %d %d %d %d\n",
        free*page_kb, active*page_kb, inactive*page_kb, wired*page_kb,
        comp*page_kb, purg*page_kb, spec*page_kb, si, so
    }
  '
}

# Swap total/used/free (bytes), parsed from sysctl
parse_swap() {
  # vm.swapusage: total = 4096.00M  used = 2509.81M  free = 1586.19M  (encrypted)
  sysctl -n vm.swapusage 2>/dev/null | awk '
    {
      total=used=free=0
      for (i=1; i<=NF; i++) {
        if ($i == "total") {
          gsub(/[MG]$/, "", $(i+2))
          total=$(i+2)
          if ($0 ~ /total = [0-9.]+G/) total *= 1024
        }
        if ($i == "used") {
          gsub(/[MG]$/, "", $(i+2))
          used=$(i+2)
          if (match($0, /used = [0-9.]+G/)) used *= 1024
        }
        if ($i == "free") {
          gsub(/[MG]$/, "", $(i+2))
          free_v=$(i+2)
          if (match($0, /free = [0-9.]+G/)) free_v *= 1024
        }
      }
      printf "%.0f %.0f %.0f\n", total, used, free_v
    }
  '
}

# Memory pressure free percentage (0-100), empty if not available
get_pressure_free_pct() {
  memory_pressure 2>/dev/null | awk -F': *' '
    /System-wide memory free percentage/ { gsub(/%/, "", $2); print $2; exit }
  '
}

# Map free percentage to Normal/Warning/Critical
classify_pressure() {
  local pct="$1"
  [ -z "$pct" ] && { echo "Unknown"; return; }
  if   [ "$pct" -ge 70 ]; then echo "Normal (healthy)"
  elif [ "$pct" -ge 40 ]; then echo "Normal (under pressure)"
  elif [ "$pct" -ge 10 ]; then echo "Warning"
  else                          echo "Critical"
  fi
}

# Process classification: identify "actively in use" vs "orphan/cleanable"
# Outputs one of these emoji markers + short label:
#   🟢 IDE    — IDE-associated (VSCode/Cursor/JetBrains/Xcode child, or path contains IDE extension)
#   🟢 TTY    — has a controlling terminal (user is watching it in a terminal tab)
#   🔴 orphan — PPID=1 (adopted by launchd, original parent died)
#   🟡 new    — etime < 30 minutes (possibly just started)
#   —         — other (normal process)
#
# All data is fetched from a single ps dump, avoiding N+1 ps calls.
# Output: RSS_KB<TAB>PID<TAB>CLASS<TAB>COMMAND (sorted by RSS desc)
get_top_processes_with_class() {
  local n="$1"
  ps -axo pid=,ppid=,etime=,rss=,tty=,command= 2>/dev/null | awk '
    # Convert etime string to total minutes
    function etime_to_mins(e,    days, rest, n_parts, b, mins) {
      if (e ~ /-/) {
        split(e, a, "-"); days = a[1] + 0; rest = a[2]
      } else {
        days = 0; rest = e
      }
      n_parts = split(rest, b, ":")
      if (n_parts == 3) mins = b[1]*60 + b[2]
      else if (n_parts == 2) mins = b[1] + 0
      else mins = 99999
      return days * 1440 + mins
    }

    function classify(idx,    ppid, parent_cmd, total_mins) {
      # 1. Command path directly contains an IDE extension (strongest signal)
      if (rec_cmd[idx] ~ /vscode\/extensions\/anthropic\.claude-code|\.cursor\/extensions\/anthropic/) return "🟢 IDE"

      # 2. Parent process is an IDE
      ppid = rec_ppid[idx]
      if (ppid != "1" && ppid != "" && (ppid in pid_to_idx)) {
        parent_cmd = rec_cmd[pid_to_idx[ppid]]
        if (parent_cmd ~ /Visual Studio Code|Code Helper|\/Applications\/Code\.app\/|Cursor|\/Applications\/Cursor\.app\/|JetBrains|IntelliJ|PyCharm|WebStorm|GoLand|RubyMine|CLion|Xcode\.app|\/Applications\/Sublime Text\.app/) return "🟢 IDE"
      }

      # 3. Has a TTY (user is in a terminal)
      if (rec_tty[idx] != "?" && rec_tty[idx] != "??" && rec_tty[idx] != "") return "🟢 TTY"

      # 4. Orphan (PPID=1 with **exclusions** for normal cases)
      # GUI .app launched by launchd is normal; system services /System/Library/,
      # /usr/libexec/, /Library/Input Methods/, etc with PPID=1 are normal too.
      # A true orphan = "should have a parent but parent died" — mostly CLI child processes.
      if (rec_ppid[idx] == "1") {
        if (rec_cmd[idx] ~ /\.app\//) {
          # GUI app — normal path
        } else if (rec_cmd[idx] ~ /^\/System\/Library\/|^\/usr\/libexec\/|^\/usr\/sbin\/|^\/Library\/Input Methods\/|^\/sbin\//) {
          # System / IME service
        } else {
          return "🔴 orphan"
        }
      }

      # 5. Recently started
      total_mins = etime_to_mins(rec_etime[idx])
      if (total_mins < 30) return "🟡 new"

      return "—"
    }

    {
      pid=$1; ppid=$2; etime=$3; rss=$4; tty=$5
      cmd=""; for (i=6; i<=NF; i++) cmd=(cmd==""?$i:cmd" "$i)
      rec_pid[NR]=pid; rec_ppid[NR]=ppid; rec_etime[NR]=etime
      rec_rss[NR]=rss; rec_tty[NR]=tty; rec_cmd[NR]=cmd
      pid_to_idx[pid]=NR
    }
    END {
      for (i = 1; i <= NR; i++) {
        printf "%s\t%s\t%s\t%s\n", rec_rss[i], rec_pid[i], classify(i), rec_cmd[i]
      }
    }
  ' | sort -t$'\t' -k1 -rn | head -"$n"
}

# All processes: for aggregation by app
get_all_processes() {
  ps -axo pid=,rss=,command= 2>/dev/null | awk '{
    pid=$1; rss=$2;
    cmd="";
    for (i=3; i<=NF; i++) cmd=(cmd==""?$i:cmd" "$i);
    printf "%s\t%s\t%s\n", pid, rss, cmd
  }'
}

# Same as get_top_processes_with_class but returns all processes (no truncation).
# Used for "aggregate by app" and "objective observations" broken down by class.
# Output: RSS_KB<TAB>PID<TAB>CLASS<TAB>COMMAND
get_all_with_class() {
  ps -axo pid=,ppid=,etime=,rss=,tty=,command= 2>/dev/null | awk '
    function etime_to_mins(e,    days, rest, n_parts, b, mins) {
      if (e ~ /-/) { split(e, a, "-"); days = a[1] + 0; rest = a[2] }
      else { days = 0; rest = e }
      n_parts = split(rest, b, ":")
      if (n_parts == 3) mins = b[1]*60 + b[2]
      else if (n_parts == 2) mins = b[1] + 0
      else mins = 99999
      return days * 1440 + mins
    }
    function classify(idx,    ppid, parent_cmd, total_mins) {
      if (rec_cmd[idx] ~ /vscode\/extensions\/anthropic\.claude-code|\.cursor\/extensions\/anthropic/) return "IDE"
      ppid = rec_ppid[idx]
      if (ppid != "1" && ppid != "" && (ppid in pid_to_idx)) {
        parent_cmd = rec_cmd[pid_to_idx[ppid]]
        if (parent_cmd ~ /Visual Studio Code|Code Helper|\/Applications\/Code\.app\/|Cursor|\/Applications\/Cursor\.app\/|JetBrains|IntelliJ|PyCharm|WebStorm|GoLand|RubyMine|CLion|Xcode\.app|\/Applications\/Sublime Text\.app/) return "IDE"
      }
      if (rec_tty[idx] != "?" && rec_tty[idx] != "??" && rec_tty[idx] != "") return "TTY"
      if (rec_ppid[idx] == "1") return "ORPHAN"
      total_mins = etime_to_mins(rec_etime[idx])
      if (total_mins < 30) return "NEW"
      return "OTHER"
    }
    {
      pid=$1; ppid=$2; etime=$3; rss=$4; tty=$5
      cmd=""; for (i=6; i<=NF; i++) cmd=(cmd==""?$i:cmd" "$i)
      rec_pid[NR]=pid; rec_ppid[NR]=ppid; rec_etime[NR]=etime
      rec_rss[NR]=rss; rec_tty[NR]=tty; rec_cmd[NR]=cmd
      pid_to_idx[pid]=NR
    }
    END {
      for (i = 1; i <= NR; i++) {
        printf "%s\t%s\t%s\t%s\n", rec_rss[i], rec_pid[i], classify(i), rec_cmd[i]
      }
    }
  '
}

# ===== Report rendering =====

render_header() {
  local display_time pressure_pct pressure_band
  display_time="$(date '+%Y-%m-%d %H:%M:%S')"
  pressure_pct="$(get_pressure_free_pct)"
  pressure_band="$(classify_pressure "$pressure_pct")"

  cat <<EOF
# 🧠 macOS Memory Status Report

**Scan time**: $display_time
**Total RAM**: ${TOTAL_RAM_GB} GB (page size ${PAGE_SIZE_KB}K)
**Current pressure level**: ${pressure_band} (free percentage: ${pressure_pct:-?}%)

📄 Full report saved to \`$output_file\`

---

EOF
}

render_snapshot() {
  local stats free_kb active_kb inactive_kb wired_kb comp_kb purg_kb spec_kb si so
  stats="$(parse_vm_stat)"
  read -r free_kb active_kb inactive_kb wired_kb comp_kb purg_kb spec_kb si so <<< "$stats"

  local swap total_mb used_mb free_mb
  swap="$(parse_swap)"
  read -r total_mb used_mb free_mb <<< "$swap"

  cat <<EOF
## 📊 System Snapshot

| Category | Size | Notes |
|----------|------|-------|
| **Free** | $(humanize_kb "$free_kb") | Completely idle |
| **Active** | $(humanize_kb "$active_kb") | In active use |
| **Inactive** | $(humanize_kb "$inactive_kb") | Recently used, reclaimable by the system |
| **Wired** | $(humanize_kb "$wired_kb") | Kernel-pinned, not swappable |
| **Compressor** | $(humanize_kb "$comp_kb") | Compressed pages (instead of swap) |
| **Purgeable** | $(humanize_kb "$purg_kb") | Discardable on demand |
| **Swap used** | ${used_mb} MB / ${total_mb} MB | (cumulative $so swap-outs, $si swap-ins) |

EOF
}

render_pressure_table() {
  local pct="$1"
  local current_band
  current_band="$(classify_pressure "$pct")"

  cat <<EOF
## 🌡️ Pressure Level Reference

| Free % | Level | Meaning |
|--------|-------|---------|
| > 70% | Normal (healthy) | Fully normal |
| 40-70% | Normal (under pressure) | System running on the edge but stable |
| 10-40% | Warning | Time to tidy up |
| < 10% | Critical | System will actively kill large consumers |

**Current**: ${current_band} (${pct:-?}%)

EOF
}

render_top_processes() {
  local rows
  rows="$(get_top_processes_with_class "$TOP_N")"
  echo ""
  echo "## 🥇 Top ${TOP_N} RAM Consumers (by process)"
  echo ""
  echo "**Status markers**: 🟢 IDE = editor/IDE-associated (**in use, don't touch**); 🟢 TTY = visible in a terminal tab; 🟡 new = started within 30 min; 🔴 orphan = parent died; — = normal"
  echo ""
  echo "| RSS | PID | Status | Command summary |"
  echo "|-----|-----|--------|-----------------|"
  while IFS=$'\t' read -r rss pid cls cmd; do
    [ -z "$pid" ] && continue
    local rss_human summary
    rss_human="$(humanize_kb "$rss")"
    summary="$(cmd_summary "$cmd")"
    printf "| %s | %s | %s | \`%s\` |\n" "$rss_human" "$pid" "$cls" "$summary"
  done <<< "$rows"
  echo ""
}

render_app_aggregation() {
  local all_rows
  all_rows="$(get_all_processes)"

  # awk aggregation: app -> {count, total_rss, pid_list}
  # Note: use index/substr instead of match() regex to dodge awk-version differences
  # with the [^/] character class.
  local agg
  agg="$(echo "$all_rows" | awk -F'\t' -v min_mb="$APP_AGG_MIN_RSS_MB" '
    function get_app(cmd,    pos, before, i, n, parts, first, m, segs) {
      pos = index(cmd, ".app/")
      if (pos == 0) {
        n = split(cmd, parts, " ")
        first = parts[1]
        m = split(first, segs, "/")
        return segs[m]
      }
      before = substr(cmd, 1, pos - 1)
      for (i = length(before); i >= 1; i--) {
        if (substr(before, i, 1) == "/") {
          return substr(before, i + 1)
        }
      }
      return before
    }
    BEGIN{ FS="\t" }
    {
      pid=$1; rss=$2; cmd=$3
      app=get_app(cmd)
      if (app == "") app="?"
      counts[app]++
      total[app]+=rss
      if (pids[app] == "") pids[app]=pid
      else pids[app]=pids[app] "," pid
    }
    END {
      for (a in counts) {
        if (total[a]/1024 < min_mb) continue
        printf "%d\t%d\t%s\t%s\n", total[a], counts[a], a, pids[a]
      }
    }
  ' | sort -t$'\t' -k1 -rn)"

  echo "## 📦 Aggregated by App (total RSS >= ${APP_AGG_MIN_RSS_MB} MB)"
  echo ""
  if [ -z "$agg" ]; then
    echo "(none)"
    echo ""
    return
  fi
  echo "| Total RSS | Process count | App | PIDs |"
  echo "|-----------|---------------|-----|------|"
  while IFS=$'\t' read -r total_rss count app pids; do
    [ -z "$app" ] && continue
    local total_human pids_short
    total_human="$(humanize_kb "$total_rss")"
    # Truncate long PID lists
    if [ "$(echo "$pids" | tr ',' '\n' | wc -l)" -gt 6 ]; then
      pids_short="$(echo "$pids" | cut -d',' -f1-6)..."
    else
      pids_short="$pids"
    fi
    printf "| %s | %d | **%s** | %s |\n" "$total_human" "$count" "$app" "$pids_short"
  done <<< "$agg"
  echo ""
}

# Objective observations (no judgment)
render_observations() {
  local stats free_kb active_kb inactive_kb wired_kb comp_kb purg_kb spec_kb si so
  stats="$(parse_vm_stat)"
  read -r free_kb active_kb inactive_kb wired_kb comp_kb purg_kb spec_kb si so <<< "$stats"

  local swap total_mb used_mb free_mb swap_used_pct
  swap="$(parse_swap)"
  read -r total_mb used_mb free_mb <<< "$swap"
  swap_used_pct=0
  if [ "$total_mb" -gt 0 ]; then
    swap_used_pct=$(awk -v u="$used_mb" -v t="$total_mb" 'BEGIN{printf "%.0f", u*100/t}')
  fi

  local comp_gb inactive_gb
  comp_gb=$(awk -v k="$comp_kb" 'BEGIN{printf "%.1f", k/1024/1024}')
  inactive_gb=$(awk -v k="$inactive_kb" 'BEGIN{printf "%.1f", k/1024/1024}')

  echo "## 👀 Objective Observations"
  echo ""

  local has_obs=0

  # Observation 1: Duplicate-name processes (broken down by class: IDE-attached / others)
  # Exclude browser/Electron-class apps with helper armies (count > 8 is architectural)
  local dup_lines
  dup_lines="$(get_all_with_class | awk -F'\t' -v min_count="$DUP_PROCESS_MIN_COUNT" '
    function get_app(cmd,    pos, before, i, n, parts, first, m, segs) {
      pos = index(cmd, ".app/")
      if (pos == 0) {
        n = split(cmd, parts, " ")
        first = parts[1]
        m = split(first, segs, "/")
        return segs[m]
      }
      before = substr(cmd, 1, pos - 1)
      for (i = length(before); i >= 1; i--) {
        if (substr(before, i, 1) == "/") return substr(before, i + 1)
      }
      return before
    }
    {
      rss=$1; pid=$2; cls=$3; cmd=$4
      app=get_app(cmd)
      counts[app]++
      total[app]+=rss
      # Accumulate PID list per class
      key=app "::" cls
      if (cls_pids[key] == "") cls_pids[key]=pid; else cls_pids[key]=cls_pids[key] " " pid
      cls_count[key]++
      cls_rss[key]+=rss
      app_classes[app, cls]=1
    }
    END {
      for (a in counts) {
        if (counts[a] < min_count || counts[a] > 8 || total[a]/1024 < 500) continue
        # Output: total_rss, total_count, app, ide_pids, ide_count, tty_pids, tty_count, orphan_pids, orphan_count, new_pids, new_count, other_pids, other_count
        printf "%d\t%d\t%s", total[a], counts[a], a
        for (cls in classes_arr) delete classes_arr[cls]  # awk compatibility
        for (cls_name in c) delete c[cls_name]
        # Emit each class PID list in a fixed order
        printf "\t%s\t%d", (cls_pids[a "::IDE"] ? cls_pids[a "::IDE"] : "-"), (cls_count[a "::IDE"]+0)
        printf "\t%s\t%d", (cls_pids[a "::TTY"] ? cls_pids[a "::TTY"] : "-"), (cls_count[a "::TTY"]+0)
        printf "\t%s\t%d", (cls_pids[a "::NEW"] ? cls_pids[a "::NEW"] : "-"), (cls_count[a "::NEW"]+0)
        printf "\t%s\t%d", (cls_pids[a "::ORPHAN"] ? cls_pids[a "::ORPHAN"] : "-"), (cls_count[a "::ORPHAN"]+0)
        printf "\t%s\t%d", (cls_pids[a "::OTHER"] ? cls_pids[a "::OTHER"] : "-"), (cls_count[a "::OTHER"]+0)
        printf "\n"
      }
    }
  ' | sort -t$'\t' -k1 -rn | head -5)"

  if [ -n "$dup_lines" ]; then
    while IFS=$'\t' read -r total_rss count app ide_pids ide_n tty_pids tty_n new_pids new_n orphan_pids orphan_n other_pids other_n; do
      [ -z "$app" ] && continue
      local total_human
      total_human="$(humanize_kb "$total_rss")"
      printf -- "- Detected **%d \`%s\`** instances, total %s\n" "$count" "$app" "$total_human"
      [ "$ide_n" -gt 0 ] && printf -- "    - 🟢 **IDE-attached (in use, don't touch)**: %d → PID %s\n" "$ide_n" "$ide_pids"
      [ "$tty_n" -gt 0 ] && printf -- "    - 🟢 **TTY-attached (in a terminal)**: %d → PID %s\n" "$tty_n" "$tty_pids"
      [ "$new_n" -gt 0 ] && printf -- "    - 🟡 started within 30 min: %d → PID %s\n" "$new_n" "$new_pids"
      [ "$orphan_n" -gt 0 ] && printf -- "    - 🔴 **orphan (cleanable)**: %d → PID %s\n" "$orphan_n" "$orphan_pids"
      [ "$other_n" -gt 0 ] && printf -- "    - — other: %d → PID %s\n" "$other_n" "$other_pids"
      has_obs=1
    done <<< "$dup_lines"
  fi

  # Observation 2: Inactive reclaimable
  if awk -v g="$inactive_gb" 'BEGIN{exit !(g >= 2.0)}'; then
    echo "- Inactive **${inactive_gb} GB** can be returned to the system immediately via \`sudo purge\` (symptomatic relief, not a cure)"
    has_obs=1
  fi

  # Observation 3: Compressor footprint
  local comp_pct
  comp_pct=$(awk -v c="$comp_kb" -v t="$TOTAL_RAM_BYTES" 'BEGIN{printf "%.0f", c*1024*100/t}')
  if [ "$comp_pct" -ge 20 ]; then
    echo "- Compressor occupies **${comp_pct}%** of memory (${comp_gb} GB); the system is compressing memory to avoid swap and is already running on the edge"
    has_obs=1
  fi

  # Observation 4: Swap near limit
  if [ "$swap_used_pct" -ge 50 ]; then
    echo "- Swap is **${swap_used_pct}%** used (${used_mb} / ${total_mb} MB); further growth will push pressure into Warning"
    has_obs=1
  fi

  # Observation 5: Cumulative swap activity
  if [ "$so" -ge 100000 ]; then
    echo "- Cumulative swap-outs: **${so}** (since last reboot), indicating the system has been swapping data continuously"
    has_obs=1
  fi

  if [ "$has_obs" -eq 0 ]; then
    echo "(no obvious issues)"
  fi
  echo ""
}

render_action_hint() {
  cat <<'EOF'
---

## 📋 Next-Step Hints

- **Once you've decided which to kill**, reply `kill <PID>` or `kill <PID1> <PID2>`
- ⚠️ **Processes marked 🟢 are ones you're actively using (IDE/terminal-associated)**. To kill one, you must **state that specific PID explicitly** — vague instructions like "kill them all" / "kill those N" are not accepted
- 🔴 orphan processes are top priority for cleanup
- **To reclaim inactive memory immediately**: reply "run purge" or run `sudo purge` yourself
- Before executing a kill, I'll re-verify that the PID's current command still matches (PID-reuse guard),
  send SIGTERM first and wait 3 seconds before escalating to SIGKILL, and never touch system processes or the current claude session
EOF
}

# ===== Main flow =====
render_report() {
  render_header
  render_snapshot

  local pct
  pct="$(get_pressure_free_pct)"
  render_pressure_table "$pct"

  render_top_processes
  render_app_aggregation
  render_observations
  render_action_hint
}

main() {
  render_report | tee "$output_file"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
