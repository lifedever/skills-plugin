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
  echo "错误: 未找到 lib.sh（应与 list-apps.sh 同目录: ${MAU_LIB_DIR}）" >&2
  exit 1
fi
# shellcheck source=lib.sh
. "$MAU_LIB_DIR/lib.sh"

SHOW_SIZE=0
INCLUDE_SYSTEM=0
MAU_NO_OPEN="${MAU_NO_OPEN:-0}"
LIMIT=0
SORT_BY="name"

usage() {
  cat >&2 <<'EOF'
用法: list-apps.sh [--sort name|used|size] [--size] [--limit N] [--all] [--no-open]

  --sort name   按名称排序（默认）
  --sort size   按应用本体大小排序（自动启用 --size）
  --sort used   按最后使用时间排序，最久未用的在前
  --size        增加"应用本体"大小列。需多花约 7 秒遍历所有 .app。
                注意：只是 .app 本身的体积，不含残留文件，不等于卸载可释放的空间。
  --limit N     只显示前 N 行。默认不限制，全部列出。
  --all         包含 /System 下的系统应用（无法卸载，默认隐藏）。
  --no-open     生成后不自动打开文件。

列出所有已安装的应用。只读，不修改任何内容。
结果写入 ~/Downloads/mac-app-uninstall/ 并自动用 Typora 打开。
选定后执行: scan.sh "<应用名或 bundle id>"
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --size) SHOW_SIZE=1; shift ;;
    --all) INCLUDE_SYSTEM=1; shift ;;
    --no-open) MAU_NO_OPEN=1; shift ;;
    --sort)
      [ $# -ge 2 ] || { echo "错误: --sort 需要一个值" >&2; exit 2; }
      case "$2" in
        name|used) SORT_BY="$2" ;;
        size) SORT_BY="size"; SHOW_SIZE=1 ;;
        *) echo "错误: --sort 只能是 name、used 或 size" >&2; exit 2 ;;
      esac
      shift 2 ;;
    --limit)
      [ $# -ge 2 ] || { echo "错误: --limit 需要一个值" >&2; exit 2; }
      case "$2" in
        ''|*[!0-9]*) echo "错误: --limit 必须是正整数" >&2; exit 2 ;;
      esac
      LIMIT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "错误: 未知参数 '$1'" >&2; usage; exit 2 ;;
  esac
done

for tool in plutil find awk sed date mdfind; do
  command -v "$tool" > /dev/null 2>&1 || {
    echo "错误: 缺少必需的命令 '$tool'" >&2; exit 1; }
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

  category="$(mau_category_zh "$path")"
  [ -n "$category" ] || category="-"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$used" "$inferred" "$size_kb" "$nm" "$category" "$kind" "${bid:-unknown}" "$path" >> "$ROWS_FILE"
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
  name) order="名称" ;;
  used) order="最后使用时间（最久未用在前）" ;;
  size) order="应用本体大小（从大到小）" ;;
esac

OUT_DIR="$(mau_out_dir)"
OUT_FILE="$OUT_DIR/apps-$(date +%Y-%m-%d-%H%M%S).md"

{
echo "# 已安装的应用"
echo
printf '生成时间：%s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')"
printf '共 **%s 个应用**，按%s排序。' "$total_rows" "$order"
[ "$INCLUDE_SYSTEM" -eq 0 ] && printf '系统应用已隐藏（加 `--all` 可显示，但它们无法卸载）。'
printf '\n\n'
printf '> **类别**取自应用自己声明的 App Store 分类，部分应用没有声明，显示为 `-`。\n'
printf '> macOS 不提供应用简介字段，所以这里只能给出类别而非详细描述。\n\n'
if [ "$norec_count" -gt 0 ]; then
  printf '> 有 %s 个应用**没有使用记录**。Spotlight 并非对每个应用都记录最后使用时间，\n' "$norec_count"
  printf '> 所以「无记录」表示**未知，不代表没用过**（Xcode、Office 系列常出现这种情况）。\n'
  printf '> 标注 `~` 的日期是根据偏好设置文件修改时间**推断**的，不是真实使用记录。\n\n'
fi
if [ "$SHOW_SIZE" -eq 1 ]; then
  printf '> **应用本体**列只是 .app 自身的体积，**不含残留文件**，不等于卸载后可释放的空间。\n'
  printf '> 想知道某个应用卸载能释放多少，对它执行 `scan.sh` —— 报告里会按可删 / 共享分别给出。\n\n'
fi

if [ "$SHOW_SIZE" -eq 1 ]; then
  printf '| 应用 | 类别 | 应用本体 | 最后使用 | 安装方式 | Bundle ID |\n'
  printf '|---|---|---|---|---|---|\n'
else
  printf '| 应用 | 类别 | 最后使用 | 安装方式 | Bundle ID |\n'
  printf '|---|---|---|---|---|\n'
fi

shown=0
while IFS=$'\t' read -r usedkey inferred size_kb nm category kind bid path; do
  [ -n "$nm" ] || continue
  if [ "$LIMIT" -gt 0 ] && [ "$shown" -ge "$LIMIT" ]; then break; fi
  shown=$((shown + 1))

  case "$usedkey" in
    0000-*) last_used="**无记录**" ;;
    *)
      last_used="$(date -j -f '%Y-%m-%d %H:%M:%S %z' "$usedkey" '+%Y-%m-%d' 2>/dev/null)"
      [ -n "$last_used" ] || last_used="?"
      [ "$inferred" = "1" ] && last_used="$last_used ~"
      ;;
  esac

  case "$kind" in
    MAS)    kind_zh="App Store" ;;
    Setapp) kind_zh="Setapp" ;;
    iOS)    kind_zh="iOS 应用" ;;
    System) kind_zh="系统" ;;
    *)      kind_zh="直接安装" ;;
  esac

  if [ "$SHOW_SIZE" -eq 1 ]; then
    size_h="$(awk -v k="$size_kb" 'BEGIN{
      if (k <= 0) printf "?";
      else if (k < 1024) printf "%dKB", k;
      else if (k < 1048576) printf "%.1fMB", k/1024;
      else printf "%.2fGB", k/1048576; }')"
    printf '| %s | %s | %s | %s | %s | `%s` |\n' "$nm" "$category" "$size_h" "$last_used" "$kind_zh" "$bid"
  else
    printf '| %s | %s | %s | %s | `%s` |\n' "$nm" "$category" "$last_used" "$kind_zh" "$bid"
  fi
done < "$ROWS_FILE"

echo
if [ "$LIMIT" -gt 0 ] && [ "$total_rows" -gt "$LIMIT" ]; then
  printf '_只显示了 %s / %s 个，`--limit` 隐藏了 %s 个。_\n\n' "$shown" "$total_rows" "$((total_rows - shown))"
fi
printf '%s\n\n' '---'   # printf would read a bare --- as an option
printf '想卸载其中某个，执行：`scan.sh "<应用名或 bundle id>"`，\n'
printf '会先列出它的全部残留文件供确认，删除的内容一律进废纸篓，可随时还原。\n'
} > "$OUT_FILE"

printf '[已保存] %s\n' "$OUT_FILE"
mau_open_file "$OUT_FILE"
