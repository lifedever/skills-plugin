#!/usr/bin/env bash
# mac-cleanup-process scan.sh — 诊断 macOS 僵尸/卡死进程，只扫描不 kill
# 详见 ~/.claude/skills/mac-cleanup-process/DESIGN.md

set -u  # 未定义变量报错
set -o pipefail

# 预检：ps 命令不可用则直接失败
if ! ps -eo pid=,ppid= > /dev/null 2>&1; then
  echo "ERROR: ps 命令不可用或权限异常" >&2
  exit 1
fi

# ===== 阈值常量（用户可改） =====
OLD_CLAUDE_HOURS=24
OLD_DEV_SERVER_DAYS=2
OLD_GHOSTTY_TAB_DAYS=3
BIG_MEM_RSS_MB=500
BIG_MEM_DAYS=3

# ===== 基础设施 =====
timestamp="$(date +%Y-%m-%d-%H%M%S)"
output_dir="$HOME/Downloads"
output_file="$output_dir/mac-cleanup-process-$timestamp.md"
mkdir -p "$output_dir"

# 系统快照
get_system_snapshot() {
  local load_1m mem_used compressor free
  load_1m="$(sysctl -n vm.loadavg | awk '{print $2}')"
  # top 的 PhysMem 行形如: "PhysMem: 30G used (4288M wired, 11G compressor), 329M unused."
  local physmem
  physmem="$(top -l 1 -n 0 | awk -F'[:,]' '/^PhysMem/ {print}')"
  mem_used="$(echo "$physmem" | awk '{print $2}')"
  compressor="$(echo "$physmem" | grep -oE '[0-9]+[KMG] compressor' | awk '{print $1}')"
  free="$(echo "$physmem" | grep -oE '[0-9]+[KMG] unused' | awk '{print $1}')"
  echo "Load ${load_1m:-?} | 内存用 ${mem_used:-?}，压缩器 ${compressor:-?}，空闲 ${free:-?}"
}

# 从 $$ 向上追溯 PPID，找第一个命令匹配 claude 的进程 PID
# 失败返回空
find_current_claude_pid() {
  local pid=$$
  local max_depth=20  # 防止追溯死循环
  local i=0
  while [ "$pid" != "1" ] && [ "$pid" != "0" ] && [ -n "$pid" ] && [ $i -lt $max_depth ]; do
    local comm
    comm="$(ps -p "$pid" -o comm= 2>/dev/null | awk '{print $1}')"
    # comm 可能是 "claude"，也可能是 claude 被重命名的内部值（如 "2.1.119"）
    # 更稳健：用完整 command 匹配
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

# 脱敏命令行中的密码：scheme://user:password@host → scheme://user:***@host
sanitize_cmd() {
  sed -E 's#(://[A-Za-z0-9._-]+):[^@[:space:]]+@#\1:***@#g'
}

# MCP 服务命令特征（扩展 ERE 正则）
readonly MCP_PATTERN='(npm exec.*mcp|mcp-server-|@playwright/mcp|@upstash/context7-mcp|@modelcontextprotocol/|@henkey/postgres-mcp-server|figma-developer-mcp|xcodebuildmcp|mcp-mongo-server|alibabacloud-devops-mcp-server|drawio/mcp|context7-mcp|chrome-devtools-mcp|Pencil.app/Contents/Resources/app.asar.unpacked/out/mcp-server)'

# 找 PPID=1 且命令匹配 MCP 特征的进程（当前用户）
# 输出格式: PID<TAB>etime<TAB>rss<TAB>sanitized_command
find_mcp_orphans() {
  local my_uid
  my_uid="$(id -u)"
  # ps -eo 格式: uid pid ppid etime rss command
  ps -eo uid=,pid=,ppid=,etime=,rss=,command= 2>/dev/null | awk -v uid="$my_uid" '
    $1 == uid && $3 == 1 {
      # 重组 command（从第 6 列开始）
      cmd = ""
      for (i = 6; i <= NF; i++) cmd = (cmd == "" ? $i : cmd " " $i)
      print $2 "\t" $4 "\t" $5 "\t" cmd
    }
  ' | grep -E "$MCP_PATTERN" | while IFS=$'\t' read -r pid etime rss cmd; do
    local sanitized
    sanitized="$(echo "$cmd" | sanitize_cmd)"
    # 命令摘要截断（避免表格爆宽）
    local summary
    summary="$(echo "$sanitized" | cut -c1-80)"
    local rss_mb=$((rss / 1024))
    printf '%s\t%s\t%s\t%s\n' "$pid" "$etime" "$rss_mb" "$summary"
  done
}

# 给定一个 PID 列表（换行分隔），递归收集所有后代 PID
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
    # 递归：kids 的 kids
    collect_descendants "$all_kids"
  fi
}

# 从 MCP 孤儿的 PID 列表，递归找到所有后代，输出为带详情的表格行
find_mcp_orphan_children() {
  local parent_pids="$1"  # 换行分隔
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

# Docker UI 是否在跑
is_docker_ui_running() {
  pgrep -x -f '/Applications/Docker.app/Contents/MacOS/Docker' > /dev/null 2>&1
}

# 找 cagent 残留进程（仅当 Docker UI 未运行时）
# 输出格式: PID<TAB>etime<TAB>rss_mb<TAB>command_summary
find_cagent_residuals() {
  if is_docker_ui_running; then
    return 0  # 空输出 = 没有残留
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

# 把 etime 字符串转换为总小时数（整数，向下取整；mins >= 30 进 1）
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
  # 去掉前导 0 以防被当 8 进制
  days=$((10#$days))
  hours=$((10#$hours))
  mins=$((10#$mins))
  echo $((days * 24 + hours + (mins >= 30 ? 1 : 0)))
}

# "7-21:28:08" → "7 天 21 小时"
# "23:30:05"   → "23 小时 30 分"
# "40:12"      → "40 分钟"
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
    echo "$days 天 $hours 小时"
  elif [ "$hours" -gt 0 ]; then
    echo "$hours 小时 $mins 分"
  else
    echo "$mins 分钟"
  fi
}

# 用 lsof 读进程的 cwd
get_cwd() {
  local pid="$1"
  lsof -p "$pid" 2>/dev/null | awk '$4 == "cwd" {for (i=9; i<=NF; i++) printf "%s%s", $i, (i<NF?" ":""); exit}'
}

# 把绝对路径里的 $HOME 替换为 ~
# 用 case 分支而非 bash pattern substitution，避免某些 bash 版本对 ${p/#$home/~} 的边界情况处理不一致
tildify_path() {
  local p="$1"
  case "$p" in
    "$HOME"/*) echo "~${p#"$HOME"}" ;;
    "$HOME") echo "~" ;;
    *) echo "$p" ;;
  esac
}

# 父进程链（进程名），最多上溯 5 层
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

# 找老 claude 会话
# 参数: $1 = current_claude_pid（可空）
# 输出每行: PID<TAB>etime<TAB>etime_human<TAB>cwd<TAB>rss_mb<TAB>mcp_children_count<TAB>parent_chain<TAB>flags
# flags: "current" / "most_suspicious" / 空
find_old_claude_sessions() {
  local current_claude="$1"
  local threshold_hours="$OLD_CLAUDE_HOURS"
  local my_uid
  my_uid="$(id -u)"

  # 所有 claude 进程（完整 command 含 claude 词）
  local candidates
  candidates="$(ps -eo uid=,pid=,etime=,rss=,command= 2>/dev/null | awk -v uid="$my_uid" '
    $1 == uid {
      cmd = ""
      for (i = 5; i <= NF; i++) cmd = (cmd == "" ? $i : cmd " " $i)
      if (cmd ~ /(^|\/)claude( |$)/) print $2 "\t" $3 "\t" $4 "\t" cmd
    }
  ')"

  # 筛选超阈值 + 找最老的
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

  # 补充详情
  while IFS=$'\t' read -r pid etime rss; do
    [ -z "$pid" ] && continue
    local human cwd_raw cwd_tilde rss_mb mcp_count chain flags=""
    human="$(etime_humanize "$etime")"
    cwd_raw="$(get_cwd "$pid")"
    cwd_tilde="$(tildify_path "${cwd_raw:-?}")"
    rss_mb=$((rss / 1024))
    # MCP 子进程数：递归收集 + 过滤 MCP 特征
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

# 输出: PID<TAB>etime<TAB>etime_human<TAB>cwd<TAB>command_summary
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

# Ghostty 老 zsh tab
# 输出: PID<TAB>etime<TAB>etime_human
find_old_ghostty_tabs() {
  local threshold_hours=$((OLD_GHOSTTY_TAB_DAYS * 24))
  local my_uid
  my_uid="$(id -u)"
  # 先找所有 zsh 进程
  ps -eo uid=,pid=,ppid=,etime=,comm= 2>/dev/null | awk -v uid="$my_uid" '
    $1 == uid && $5 ~ /zsh$/ { print $2 "\t" $3 "\t" $4 }
  ' | while IFS=$'\t' read -r pid ppid etime; do
    # 父进程命令是否为 /usr/bin/login
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

# excluded_pids: 换行分隔的 PID 字符串，这些已被前面规则覆盖不再重复列
# 输出: PID<TAB>etime_human<TAB>rss_mb<TAB>command_summary
find_big_mem_old() {
  local excluded_pids="$1"
  local threshold_hours=$((BIG_MEM_DAYS * 24))
  local threshold_rss_kb=$((BIG_MEM_RSS_MB * 1024))
  local my_uid
  my_uid="$(id -u)"

  # 构造 excluded 查找表（关联数组在 Bash 3.2 不支持，用临时文件 + grep -xF）
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
    # 检查是否被排除
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

# ===== 报告生成 =====
render_mcp_orphans_section() {
  local rows="$1"
  echo ""
  echo "### MCP server 孤儿"
  echo ""
  if [ -z "$rows" ]; then
    echo "（无）"
    return
  fi
  echo "| PID | etime | RSS (MB) | 命令摘要 |"
  echo "|-----|-------|---------|---------|"
  while IFS=$'\t' read -r pid etime rss summary; do
    echo "| $pid | $etime | $rss | $summary |"
  done <<< "$rows"
  local count
  count="$(echo "$rows" | wc -l | tr -d ' ')"
  echo ""
  echo "**共 $count 个。**"
}

render_mcp_children_section() {
  local child_rows="$1"  # 已经是详情行（PID<TAB>PPID<TAB>etime<TAB>rss_mb<TAB>summary）

  echo ""
  echo "### MCP 孤儿子进程"
  echo ""
  if [ -z "$child_rows" ]; then
    echo "（无）"
    return
  fi
  echo "| PID | 父 PID | etime | RSS (MB) | 命令摘要 |"
  echo "|-----|-------|-------|---------|---------|"
  while IFS=$'\t' read -r pid ppid etime rss summary; do
    echo "| $pid | $ppid | $etime | $rss | $summary |"
  done <<< "$child_rows"
  local count
  count="$(echo "$child_rows" | wc -l | tr -d ' ')"
  echo ""
  echo "**共 $count 个（kill 上述 MCP 父孤儿时会自动带走这些子进程）。**"
}

render_cagent_section() {
  local rows="$1"
  echo ""
  echo "### Docker cagent 残留"
  echo ""
  if is_docker_ui_running; then
    echo "（Docker UI 正在运行，跳过扫描 cagent）"
    return
  fi
  if [ -z "$rows" ]; then
    echo "（无）"
    return
  fi
  echo "| PID | etime | RSS (MB) | 命令摘要 |"
  echo "|-----|-------|---------|---------|"
  while IFS=$'\t' read -r pid etime rss summary; do
    echo "| $pid | $etime | $rss | $summary |"
  done <<< "$rows"
  local count
  count="$(echo "$rows" | wc -l | tr -d ' ')"
  echo ""
  echo "**共 $count 个（Docker UI 未运行，这些 cagent 可闭眼清理）。**"
}

render_old_claude_section() {
  local current_claude="$1"
  local rows="$2"
  echo ""
  echo "### ① 老 claude 会话（>${OLD_CLAUDE_HOURS}h）"
  echo ""
  if [ -z "$rows" ]; then
    echo "（无）"
    return
  fi
  while IFS=$'\t' read -r pid etime human cwd rss mcp_count chain flags; do
    local label=""
    case "$flags" in
      current) label=' `[当前会话·勿杀]`' ;;
      most_suspicious) label=' [最可疑]' ;;
    esac
    echo "- **PID $pid**$label"
    echo "  - 项目：\`$cwd\`"
    echo "  - 运行时长：$human"
    echo "  - 内存：${rss} MB（自身）+ ${mcp_count} 个 MCP 子进程"
    echo "  - 父进程链：$chain"
    echo ""
  done <<< "$rows"
}

render_old_dev_server_section() {
  local rows="$1"
  echo ""
  echo "### ② 长期 dev server（>${OLD_DEV_SERVER_DAYS} 天）"
  echo ""
  if [ -z "$rows" ]; then
    echo "（无）"
    return
  fi
  while IFS=$'\t' read -r pid etime human cwd summary; do
    echo "- **PID $pid**"
    echo "  - 命令：\`$summary\`"
    echo "  - 项目：\`$cwd\`"
    echo "  - 运行时长：$human"
    echo ""
  done <<< "$rows"
}

render_old_ghostty_section() {
  local rows="$1"
  echo ""
  echo "### ③ Ghostty 老 tab（>${OLD_GHOSTTY_TAB_DAYS} 天）"
  echo ""
  if [ -z "$rows" ]; then
    echo "（无）"
    return
  fi
  while IFS=$'\t' read -r pid etime human; do
    echo "- **PID $pid** zsh, $human"
  done <<< "$rows"
  local count
  count="$(echo "$rows" | wc -l | tr -d ' ')"
  echo ""
  echo "**共 $count 个。关闭对应 Ghostty tab 即可。**"
}

render_big_mem_section() {
  local rows="$1"
  echo ""
  echo "### ④ 大内存超龄（RSS >${BIG_MEM_RSS_MB}MB 且 >${BIG_MEM_DAYS} 天）"
  echo ""
  if [ -z "$rows" ]; then
    echo "（无）"
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
  echo "## 💡 建议命令（复制即用）"
  echo ""
  echo '```bash'

  # 明确孤儿
  local has_obvious=""
  local mcp_pids
  mcp_pids="$(echo "$mcp_rows" | awk -F'\t' 'NF>0 {print $1}' | tr '\n' ' ' | sed 's/ $//')"
  if [ -n "$mcp_pids" ]; then
    echo "# === 明确孤儿（可闭眼执行）==="
    echo "# MCP 孤儿 + 子进程（kill 父孤儿后子进程会自动退出）"
    echo "kill $mcp_pids"
    has_obvious=1
  fi
  if [ -n "$cagent_rows" ]; then
    [ -z "$has_obvious" ] && echo "# === 明确孤儿（可闭眼执行）==="
    echo ""
    echo "# Docker cagent 残留"
    echo "pkill -9 -f cagent"
    has_obvious=1
  fi

  # 可疑项
  local has_suspicious=""
  local suspicious_lines=""

  # 老 claude（排除当前）
  if [ -n "$oldc_rows" ]; then
    while IFS=$'\t' read -r pid etime human cwd rss mcp_count chain flags; do
      [ -z "$pid" ] && continue
      if [ "$flags" = "current" ] || [ "$pid" = "$current_claude" ]; then
        continue  # 绝不 suggest kill 当前会话
      fi
      local basename
      basename="$(echo "$cwd" | awk -F/ '{print $NF}')"
      local note="$basename 老 claude, $human"
      if [ "$mcp_count" -gt 0 ]; then
        note="$note → 会带走 $mcp_count 个 MCP 子进程"
      fi
      suspicious_lines+="# kill $pid   # $note"$'\n'
      has_suspicious=1
    done <<< "$oldc_rows"
  fi

  # 老 dev server
  if [ -n "$olds_rows" ]; then
    while IFS=$'\t' read -r pid etime human cwd summary; do
      [ -z "$pid" ] && continue
      local basename
      basename="$(echo "$cwd" | awk -F/ '{print $NF}')"
      suspicious_lines+="# kill $pid   # $basename dev server, 挂了 $human"$'\n'
      has_suspicious=1
    done <<< "$olds_rows"
  fi

  # 大内存超龄（Ghostty 老 tab 不放这里，因为只建议"关 tab"不建议 kill zsh）
  if [ -n "$bigmem_rows" ]; then
    while IFS=$'\t' read -r pid human rss_mb summary; do
      [ -z "$pid" ] && continue
      suspicious_lines+="# kill $pid   # $summary, $human, ${rss_mb} MB"$'\n'
      has_suspicious=1
    done <<< "$bigmem_rows"
  fi

  if [ -n "$has_suspicious" ]; then
    echo ""
    echo "# === 可疑项（自行判断后取消注释）==="
    echo -n "$suspicious_lines"
  fi

  echo '```'
  echo ""
  echo "---"
  echo ""
  echo "**使用提示**："
  if [ -n "$current_claude" ]; then
    echo "- 建议命令块里已自动排除当前 claude 会话（PID ${current_claude}）"
  fi
  echo "- 如果想让我执行，回复 \`kill <PID>\` 或 \`执行明确孤儿清理\`"
  echo "- 如果你自己复制到终端跑，我不会再做任何动作"
}

render_report() {
  local snapshot display_time current_claude
  snapshot="$(get_system_snapshot)"
  display_time="$(date '+%Y-%m-%d %H:%M:%S')"
  current_claude="$(find_current_claude_pid)"

  local guard_line
  if [ -n "$current_claude" ]; then
    guard_line="**当前会话·勿杀**：PID $current_claude"
  else
    guard_line="**当前会话·勿杀**：（未识别，所有 claude 进程都可作为清理候选）"
  fi

  # 一次性扫描所有类别 —— 缓存到变量避免重复调用
  local mcp_rows mcp_kids_rows cagent_rows oldc_rows olds_rows ghost_rows bigmem_rows
  mcp_rows="$(find_mcp_orphans)"

  local mcp_parent_pids
  mcp_parent_pids="$(echo "$mcp_rows" | awk -F'\t' 'NF>0 {print $1}')"
  mcp_kids_rows="$(find_mcp_orphan_children "$mcp_parent_pids")"

  cagent_rows="$(find_cagent_residuals)"
  oldc_rows="$(find_old_claude_sessions "$current_claude")"
  olds_rows="$(find_old_dev_servers)"
  ghost_rows="$(find_old_ghostty_tabs)"

  # 聚合已分类 PID（大内存节去重用）
  local classified
  classified="$(printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$(echo "$mcp_rows" | awk -F'\t' 'NF>0 {print $1}')" \
    "$(echo "$mcp_kids_rows" | awk -F'\t' 'NF>0 {print $1}')" \
    "$(echo "$cagent_rows" | awk -F'\t' 'NF>0 {print $1}')" \
    "$(echo "$oldc_rows" | awk -F'\t' 'NF>0 {print $1}')" \
    "$(echo "$olds_rows" | awk -F'\t' 'NF>0 {print $1}')" \
    "$(echo "$ghost_rows" | awk -F'\t' 'NF>0 {print $1}')")"
  bigmem_rows="$(find_big_mem_old "$classified")"

  # 统计 —— 明确孤儿
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

  # 统计 —— 可疑项
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

  # 摘要行
  local summary_lines=""
  if [ "$obvious_count" -gt 0 ] || [ "$suspicious_count" -gt 0 ]; then
    local release_line="**预计可释放**：~${obvious_rss} MB（明确孤儿）"
    if [ "$suspicious_rss" -gt 0 ]; then
      release_line+=" + ~${suspicious_rss} MB（如清可疑项）"
    fi
    summary_lines="$release_line
**扫描结果**：${obvious_count} 个明确孤儿 · ${suspicious_count} 个可疑待判断"
  fi

  # 判断全局是否完全没有候选
  local total_rows=0
  local rows
  for rows in "$mcp_rows" "$mcp_kids_rows" "$cagent_rows" "$oldc_rows" "$olds_rows" "$ghost_rows" "$bigmem_rows"; do
    if [ -n "$rows" ]; then
      total_rows=$((total_rows + $(echo "$rows" | wc -l | tr -d ' ')))
    fi
  done

  # 输出头部（无论干净与否都要出）
  cat <<EOF
# 🧹 系统僵尸扫描报告

**扫描时间**：$display_time
**系统快照**：$snapshot
$guard_line

📄 完整结果已保存到 \`$output_file\`

---

EOF

  if [ "$total_rows" -eq 0 ]; then
    echo "## 🎉 未发现僵尸"
    echo ""
    echo "系统干净，无需清理。"
    return
  fi

  # 有候选时插入摘要行到报告
  if [ -n "$summary_lines" ]; then
    echo "$summary_lines"
    echo ""
  fi

  echo "## ✅ 明确孤儿（建议闭眼清理）"
  render_mcp_orphans_section "$mcp_rows"
  render_mcp_children_section "$mcp_kids_rows"
  render_cagent_section "$cagent_rows"

  echo ""
  echo "## ⚠️ 可疑 —— 需要你判断"
  render_old_claude_section "$current_claude" "$oldc_rows"
  render_old_dev_server_section "$olds_rows"
  render_old_ghostty_section "$ghost_rows"
  render_big_mem_section "$bigmem_rows"

  render_suggested_commands \
    "$mcp_rows" \
    "$cagent_rows" \
    "$oldc_rows" \
    "$olds_rows" \
    "$bigmem_rows" \
    "$current_claude"
}

# ===== 主流程 =====
main() {
  render_report | tee "$output_file"
}

# 只在直接执行时跑主流程，source 时不跑
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
