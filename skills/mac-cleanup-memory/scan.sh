#!/usr/bin/env bash
# mac-cleanup-memory scan.sh —— macOS 内存状态全景诊断（纯诊断，不 kill）
# 详见同目录 DESIGN.md

set -u
set -o pipefail

# 预检：必须有 vm_stat / ps / sysctl
for cmd in vm_stat ps sysctl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: 缺少必要命令 $cmd" >&2
    exit 1
  fi
done

# ===== 配置（可改）=====
TOP_N=15                  # Top RAM 大户列前 N 个
APP_AGG_MIN_RSS_MB=100    # 按 app 聚合时，总 RSS 低于此值不显示
DUP_PROCESS_MIN_COUNT=2   # 同名进程数 ≥ 此值时报告"重复进程"观察

# ===== 基础设施 =====
timestamp="$(date +%Y-%m-%d-%H%M%S)"
output_dir="$HOME/Downloads"
output_file="$output_dir/mac-cleanup-memory-$timestamp.md"
mkdir -p "$output_dir"

# 自适应 page size：Apple Silicon 16K，Intel 4K
PAGE_SIZE_BYTES="$(sysctl -n hw.pagesize 2>/dev/null || echo 4096)"
PAGE_SIZE_KB=$((PAGE_SIZE_BYTES / 1024))
TOTAL_RAM_BYTES="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
TOTAL_RAM_GB=$(awk -v b="$TOTAL_RAM_BYTES" 'BEGIN{printf "%.0f", b/1024/1024/1024}')

# 把 KB 数转成人类可读 (例: 9437184 → "9.0 GB"; 384512 → "375 MB")
humanize_kb() {
  local kb="$1"
  awk -v k="$kb" 'BEGIN{
    if (k >= 1024*1024) printf "%.1f GB", k/1024/1024;
    else if (k >= 1024) printf "%.0f MB", k/1024;
    else printf "%d KB", k;
  }'
}

# 给定 process 完整 command，提取它属于的"逻辑 app 组"
# - 路径含 /XXX.app/  → 取最外层 .app 名（去掉 .app 后缀）
# - 否则取可执行文件 basename
# - claude 这种没有 .app 但有多实例的，按 basename 分组
get_app_group() {
  local cmd="$1"
  # 匹配最外层 .app（最浅一层）
  local app_part
  app_part="$(echo "$cmd" | grep -oE '/[^/]+\.app/' | head -1 | sed 's|^/||;s|\.app/$||')"
  if [ -n "$app_part" ]; then
    echo "$app_part"
    return
  fi
  # 没有 .app，取第一个 token 的 basename
  local first
  first="$(echo "$cmd" | awk '{print $1}')"
  basename "$first" 2>/dev/null || echo "?"
}

# 命令摘要（去敏 + 截断）
sanitize_cmd() {
  sed -E 's#(://[A-Za-z0-9._-]+):[^@[:space:]]+@#\1:***@#g'
}

cmd_summary() {
  local cmd="$1"
  echo "$cmd" | sanitize_cmd | cut -c1-90
}

# ===== 数据采集 =====

# 解析 vm_stat 输出 → 各类页数
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
      # 输出格式: free_kb active_kb inactive_kb wired_kb comp_kb purg_kb spec_kb swap_in swap_out
      printf "%d %d %d %d %d %d %d %d %d\n",
        free*page_kb, active*page_kb, inactive*page_kb, wired*page_kb,
        comp*page_kb, purg*page_kb, spec*page_kb, si, so
    }
  '
}

# Swap 总量/已用/剩余 (bytes)，从 sysctl 解析
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

# 内存压力 free percentage (0-100)，取不到返回空
get_pressure_free_pct() {
  memory_pressure 2>/dev/null | awk -F': *' '
    /System-wide memory free percentage/ { gsub(/%/, "", $2); print $2; exit }
  '
}

# 把 free percentage 映射到 Normal/Warning/Critical
classify_pressure() {
  local pct="$1"
  [ -z "$pct" ] && { echo "Unknown"; return; }
  if   [ "$pct" -ge 70 ]; then echo "Normal (健康)"
  elif [ "$pct" -ge 40 ]; then echo "Normal (有压力)"
  elif [ "$pct" -ge 10 ]; then echo "Warning"
  else                          echo "Critical"
  fi
}

# 进程分类：识别"用户正在使用"vs"孤儿/可清"
# 输出 4 种 emoji 标记之一 + 短标签：
#   🟢 IDE  —— IDE 进程关联（VSCode/Cursor/JetBrains/Xcode）或路径含 IDE 扩展
#   🟢 TTY  —— 有 controlling terminal（用户在终端 tab 里看着）
#   🔴 孤儿 —— PPID=1（被 launchd 收养，原父已死）
#   🟡 新   —— etime < 30 分钟（可能用户刚启动）
#   —      —— 其它（普通进程）
#
# 所有数据从单次 ps 全表抓取，避免 N+1 ps 调用
# 输出: RSS_KB<TAB>PID<TAB>CLASS<TAB>COMMAND（按 RSS 降序）
get_top_processes_with_class() {
  local n="$1"
  ps -axo pid=,ppid=,etime=,rss=,tty=,command= 2>/dev/null | awk '
    # 把 etime 字符串转成总分钟数
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
      # 1. cmd 路径直接含 IDE 扩展（最强信号）
      if (rec_cmd[idx] ~ /vscode\/extensions\/anthropic\.claude-code|\.cursor\/extensions\/anthropic/) return "🟢 IDE"

      # 2. 父进程是 IDE
      ppid = rec_ppid[idx]
      if (ppid != "1" && ppid != "" && (ppid in pid_to_idx)) {
        parent_cmd = rec_cmd[pid_to_idx[ppid]]
        if (parent_cmd ~ /Visual Studio Code|Code Helper|\/Applications\/Code\.app\/|Cursor|\/Applications\/Cursor\.app\/|JetBrains|IntelliJ|PyCharm|WebStorm|GoLand|RubyMine|CLion|Xcode\.app|\/Applications\/Sublime Text\.app/) return "🟢 IDE"
      }

      # 3. 有 TTY（用户在终端里）
      if (rec_tty[idx] != "?" && rec_tty[idx] != "??" && rec_tty[idx] != "") return "🟢 TTY"

      # 4. 孤儿（PPID=1 但**排除**正常情况）
      # GUI .app 由 launchd 启动是正常的；系统服务 /System/Library/、/usr/libexec/、
      # /Library/Input Methods/ 等 PPID=1 也是正常的。
      # 真正的孤儿 = "本该有父进程但父进程死了"，主要是 CLI 子进程类型
      if (rec_ppid[idx] == "1") {
        if (rec_cmd[idx] ~ /\.app\//) {
          # GUI app 走正常路径
        } else if (rec_cmd[idx] ~ /^\/System\/Library\/|^\/usr\/libexec\/|^\/usr\/sbin\/|^\/Library\/Input Methods\/|^\/sbin\//) {
          # 系统/IME 服务
        } else {
          return "🔴 孤儿"
        }
      }

      # 5. 新启动
      total_mins = etime_to_mins(rec_etime[idx])
      if (total_mins < 30) return "🟡 新"

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

# 所有进程：用于按 app 聚合
get_all_processes() {
  ps -axo pid=,rss=,command= 2>/dev/null | awk '{
    pid=$1; rss=$2;
    cmd="";
    for (i=3; i<=NF; i++) cmd=(cmd==""?$i:cmd" "$i);
    printf "%s\t%s\t%s\n", pid, rss, cmd
  }'
}

# 同 get_top_processes_with_class，但返回所有进程（不截断）
# 用于"按 app 聚合"和"客观观察"按分类细分
# 输出: RSS_KB<TAB>PID<TAB>CLASS<TAB>COMMAND
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

# ===== 报告渲染 =====

render_header() {
  local display_time pressure_pct pressure_band
  display_time="$(date '+%Y-%m-%d %H:%M:%S')"
  pressure_pct="$(get_pressure_free_pct)"
  pressure_band="$(classify_pressure "$pressure_pct")"

  cat <<EOF
# 🧠 macOS 内存状态扫描报告

**扫描时间**：$display_time
**总 RAM**：${TOTAL_RAM_GB} GB （page size ${PAGE_SIZE_KB}K）
**当前压力等级**：${pressure_band}（free percentage: ${pressure_pct:-?}%）

📄 完整结果已保存到 \`$output_file\`

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
## 📊 系统快照

| 类别 | 大小 | 说明 |
|------|------|------|
| **Free** | $(humanize_kb "$free_kb") | 完全空闲 |
| **Active** | $(humanize_kb "$active_kb") | 正在使用中 |
| **Inactive** | $(humanize_kb "$inactive_kb") | 最近用过，可被系统回收 |
| **Wired** | $(humanize_kb "$wired_kb") | 内核固定，不可换出 |
| **Compressor** | $(humanize_kb "$comp_kb") | 压缩页占用（替代 swap） |
| **Purgeable** | $(humanize_kb "$purg_kb") | 可立即丢弃 |
| **Swap 已用** | ${used_mb} MB / ${total_mb} MB | (累计 $so 次 swap-out, $si 次 swap-in) |

EOF
}

render_pressure_table() {
  local pct="$1"
  local current_band
  current_band="$(classify_pressure "$pct")"

  cat <<EOF
## 🌡️ 压力等级对照表

| Free % | 等级 | 含义 |
|--------|------|------|
| > 70% | Normal (健康) | 完全正常 |
| 40-70% | Normal (有压力) | 系统在边缘工作但稳定 |
| 10-40% | Warning | 该收拾东西了 |
| < 10% | Critical | 系统会主动 kill 大户 |

**当前**：${current_band}（${pct:-?}%）

EOF
}

render_top_processes() {
  local rows
  rows="$(get_top_processes_with_class "$TOP_N")"
  echo ""
  echo "## 🥇 Top ${TOP_N} RAM 大户（按进程）"
  echo ""
  echo "**状态标记**：🟢 IDE = 编辑器/IDE 关联（**正在用，别动**）；🟢 TTY = 在终端 tab 里看着；🟡 新 = 30 分钟内启动；🔴 孤儿 = 父进程已死；— = 普通"
  echo ""
  echo "| RSS | PID | 状态 | 命令摘要 |"
  echo "|-----|-----|-----|---------|"
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

  # 用 awk 聚合：app -> {count, total_rss, pid_list}
  # 注意：用 index/substr 替代 match() 正则，规避部分 awk 版本对 [^/] 字符类的解析问题
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

  echo "## 📦 按 App 聚合（总 RSS ≥ ${APP_AGG_MIN_RSS_MB} MB）"
  echo ""
  if [ -z "$agg" ]; then
    echo "（无）"
    echo ""
    return
  fi
  echo "| 总 RSS | 进程数 | App | PIDs |"
  echo "|--------|--------|-----|------|"
  while IFS=$'\t' read -r total_rss count app pids; do
    [ -z "$app" ] && continue
    local total_human pids_short
    total_human="$(humanize_kb "$total_rss")"
    # PID 列表过长时截断
    if [ "$(echo "$pids" | tr ',' '\n' | wc -l)" -gt 6 ]; then
      pids_short="$(echo "$pids" | cut -d',' -f1-6)..."
    else
      pids_short="$pids"
    fi
    printf "| %s | %d | **%s** | %s |\n" "$total_human" "$count" "$app" "$pids_short"
  done <<< "$agg"
  echo ""
}

# 客观观察（不评价）
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

  echo "## 👀 客观观察"
  echo ""

  local has_obs=0

  # 观察 1: 同名进程聚集（按分类拆开 IDE-attached / 其它）
  # 排除浏览器/Electron 类 app 的 helper 大军（count > 8 是架构性的）
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
      # 按 class 累加 PID 列表
      key=app "::" cls
      if (cls_pids[key] == "") cls_pids[key]=pid; else cls_pids[key]=cls_pids[key] " " pid
      cls_count[key]++
      cls_rss[key]+=rss
      app_classes[app, cls]=1
    }
    END {
      for (a in counts) {
        if (counts[a] < min_count || counts[a] > 8 || total[a]/1024 < 500) continue
        # 输出：total_rss, total_count, app, ide_pids, ide_count, tty_pids, tty_count, orphan_pids, orphan_count, new_pids, new_count, other_pids, other_count
        printf "%d\t%d\t%s", total[a], counts[a], a
        for (cls in classes_arr) delete classes_arr[cls]  # awk 兼容性
        for (cls_name in c) delete c[cls_name]
        # 按固定顺序列出每个类的 PID 列表
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
      printf -- "- 检测到 **%d 个 \`%s\`** 实例，合计 %s\n" "$count" "$app" "$total_human"
      [ "$ide_n" -gt 0 ] && printf -- "    - 🟢 **IDE-attached（正在用，别动）**：%d 个 → PID %s\n" "$ide_n" "$ide_pids"
      [ "$tty_n" -gt 0 ] && printf -- "    - 🟢 **TTY-attached（在终端里）**：%d 个 → PID %s\n" "$tty_n" "$tty_pids"
      [ "$new_n" -gt 0 ] && printf -- "    - 🟡 30 分钟内启动：%d 个 → PID %s\n" "$new_n" "$new_pids"
      [ "$orphan_n" -gt 0 ] && printf -- "    - 🔴 **孤儿（可清）**：%d 个 → PID %s\n" "$orphan_n" "$orphan_pids"
      [ "$other_n" -gt 0 ] && printf -- "    - — 其它：%d 个 → PID %s\n" "$other_n" "$other_pids"
      has_obs=1
    done <<< "$dup_lines"
  fi

  # 观察 2: Inactive 可回收
  if awk -v g="$inactive_gb" 'BEGIN{exit !(g >= 2.0)}'; then
    echo "- Inactive **${inactive_gb} GB** 可通过 \`sudo purge\` 立即归还系统（治标不治本）"
    has_obs=1
  fi

  # 观察 3: Compressor 体积
  local comp_pct
  comp_pct=$(awk -v c="$comp_kb" -v t="$TOTAL_RAM_BYTES" 'BEGIN{printf "%.0f", c*1024*100/t}')
  if [ "$comp_pct" -ge 20 ]; then
    echo "- Compressor 占 **${comp_pct}%** 内存（${comp_gb} GB），系统在压缩内存避免 swap，已经在边缘工作"
    has_obs=1
  fi

  # 观察 4: Swap 接近上限
  if [ "$swap_used_pct" -ge 50 ]; then
    echo "- Swap 已用 **${swap_used_pct}%**（${used_mb} / ${total_mb} MB），再涨会进 Warning"
    has_obs=1
  fi

  # 观察 5: 累计 swap 活动
  if [ "$so" -ge 100000 ]; then
    echo "- 累计 swap-out **${so}** 次（自上次重启），说明系统持续在 swap 数据"
    has_obs=1
  fi

  if [ "$has_obs" -eq 0 ]; then
    echo "（无明显问题）"
  fi
  echo ""
}

render_action_hint() {
  cat <<'EOF'
---

## 📋 操作提示

- **决定要杀的进程后**，回复 `kill <PID>` 或 `kill <PID1> <PID2>`
- ⚠️ **标 🟢 的进程是你正在使用的（IDE/终端关联）**，要杀必须**明确单独说出这个 PID**，不接受"全杀"/"杀那 N 个"等模糊指令
- 🔴 标记的孤儿进程是清理优先目标
- **想立即回收 inactive 内存**：回复"执行 purge"或自己跑 `sudo purge`
- 我执行 kill 前会再次校验 PID 当前命令是否还匹配（防 PID 重用），
  先发 SIGTERM 等 3 秒再升级 SIGKILL，绝不动系统进程和当前 claude 会话
EOF
}

# ===== 主流程 =====
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
