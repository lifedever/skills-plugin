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
用法: uninstall.sh --manifest <清单文件> [--tier safe|review|bundle|all] [--execute]

  --manifest <文件>  scan.sh 生成的删除清单（必填）
  --tier <档位>      处理哪一档（默认 safe）
                       safe    Bundle ID 精确匹配、无其他应用占用
                       review  需人工确认的项
                       bundle  应用程序本体（.app）
                       all     safe + review + bundle
  --execute          真正执行（移入废纸篓）。不加则只做预演。

所有删除内容一律移入废纸篓，可随时还原。本工具**没有**永久删除选项，
这是有意设计——确认无误后由你自己清空废纸篓。

🚫 共享档永远不会被处理：那些文件属于仍然安装着的其他应用。
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --manifest)
      [ $# -ge 2 ] || { echo "错误: --manifest 需要一个值" >&2; exit 2; }
      MANIFEST="$2"; shift 2 ;;
    --tier)
      [ $# -ge 2 ] || { echo "错误: --tier 需要一个值" >&2; exit 2; }
      TIER="$2"; shift 2 ;;
    --execute) EXECUTE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "错误: 未知参数 '$1'" >&2; usage; exit 2 ;;
  esac
done

[ -n "$MANIFEST" ] || { echo "错误: 必须指定 --manifest" >&2; usage; exit 2; }
[ -f "$MANIFEST" ] || { echo "错误: 找不到清单文件: $MANIFEST" >&2; exit 1; }

case "$TIER" in
  safe|review|bundle|all) ;;
  shared)
    echo "错误: 共享档永远不可删除——那些文件属于仍然安装着的其他应用。" >&2
    exit 2 ;;
  *) echo "错误: --tier 取值无效 '$TIER'" >&2; usage; exit 2 ;;
esac

command -v /usr/bin/trash > /dev/null 2>&1 || {
  echo "错误: 找不到 /usr/bin/trash（macOS 14+ 自带）。" >&2
  echo "      在更老的系统上，请在访达里手动把这些路径拖进废纸篓。" >&2
  exit 1
}

# Escape ERE metacharacters — pgrep -f takes a regex, and a bundle id of ".*"
# would otherwise match every process and permanently block execution.
escape_ere() { printf '%s' "$1" | sed 's/[][^$.*+?(){}|\\]/\\&/g'; }

# Does this basename identify the app being uninstalled? Used by both gates to
# decide whether a dot-directory in $HOME may be touched. Requiring a name match
# is what keeps ~/.ssh, ~/.gnupg and ~/.config unreachable: they match no app.
matches_target_name() {
  local base="$1" stripped lbase lbid
  stripped="${base#.}"
  lbase="$(printf '%s' "$stripped" | tr '[:upper:]' '[:lower:]')"
  [ -n "$lbase" ] || return 1

  if [ -n "${APP_LABEL:-}" ]; then
    [ "$lbase" = "$(printf '%s' "$APP_LABEL" | tr '[:upper:]' '[:lower:]')" ] && return 0
  fi
  if [ -n "${BUNDLE_ID:-}" ] && [ "$BUNDLE_ID" != "unknown" ]; then
    lbid="$(printf '%s' "$BUNDLE_ID" | tr '[:upper:]' '[:lower:]')"
    [ "$lbase" = "$lbid" ] && return 0
    [ "$lbase" = "${lbid##*.}" ] && return 0
  fi
  return 1
}

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

    # Anything deeper than one level inside a dot-directory is out of scope.
    # Listed before the single-level pattern below, since `*` matches `/` too.
    "$HOME"/.*/*) return 1 ;;

    # A dot-directory directly in $HOME — the Unix convention Java and CLI-style
    # apps use instead of ~/Library. FreeBox (JavaFX) kept all its config and
    # caches in ~/.freebox while ~/Library held nothing at all, so refusing these
    # outright means "uninstall cleanly" quietly misses the only real leftover.
    # Gated on a name match, so ~/.ssh and friends stay unreachable.
    "$HOME"/.*)
      matches_target_name "$(basename "$p")" && return 0
      return 1
      ;;
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
    com.apple.*) return 0 ;;
    # Hidden files stay protected unless the name identifies the target app —
    # the same test is_allowed_path applies, so both gates must agree.
    .*) matches_target_name "$base" || return 0 ;;
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
OUTCOMES_FILE="$(mktemp -t mau_outcomes)"
trap 'rm -f "$TARGETS_FILE" "$REJECTED_FILE" "$PROTECTED_FILE" "$MISSING_FILE" "$ANCESTORS_FILE" "$OUTCOMES_FILE"' EXIT

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
# pgrep -f matches the WHOLE command line, so the bundle id appearing in the
# command that launched this script (or in an ancestor shell's history) reads as
# "the app is running" and blocks the uninstall. Two defences: prefer matching
# the bundle's executable path, and exclude our own process ancestry.
self_chain=" $$ "
_anc="$PPID"; _depth=0
while [ -n "$_anc" ] && [ "$_anc" != "0" ] && [ "$_anc" != "1" ] && [ "$_depth" -lt 12 ]; do
  self_chain="$self_chain$_anc "
  _anc="$(ps -p "$_anc" -o ppid= 2>/dev/null | tr -d ' ')"
  _depth=$((_depth + 1))
done

BUNDLE_PATH="$(awk -F'\t' '$1=="BUNDLE" {print $2; exit}' "$MANIFEST" 2>/dev/null)"
running_raw=""
if [ -n "$BUNDLE_PATH" ]; then
  # Anchored on the executable path — a mention in someone's command line
  # cannot match this.
  running_raw="$(pgrep -f "^$(escape_ere "$BUNDLE_PATH")/" 2>/dev/null || true)"
elif [ -n "$BUNDLE_ID" ] && [ "$BUNDLE_ID" != "unknown" ]; then
  running_raw="$(pgrep -f "$(escape_ere "$BUNDLE_ID")" 2>/dev/null || true)"
fi

RUNNING=""
for _pid in $running_raw; do
  case "$self_chain" in *" $_pid "*) continue ;; esac
  RUNNING="$RUNNING$_pid "
done

echo "# 卸载 — ${APP_LABEL:-未知应用}"
echo
echo "清单文件 : $MANIFEST"
echo "处理档位 : $TIER"
echo "运行模式 : $([ $EXECUTE -eq 1 ] && echo '执行（移入废纸篓）' || echo '预演（不改动任何文件）')"
echo

if [ -s "$REJECTED_FILE" ]; then
  echo "## 已拒绝 — 超出允许范围"
  echo
  echo "这些路径不在 ~/Library/<子目录>/、/Applications 或 ~/Applications 之下。"
  echo "正常的清单不应包含它们；如果意外出现，请重新运行 scan.sh。"
  echo
  while IFS=$'\t' read -r t p; do echo "  [$t] $p"; done < "$REJECTED_FILE"
  echo
fi

if [ -s "$PROTECTED_FILE" ]; then
  echo "## 🛑 已拒绝 — 受保护（Apple / Setapp / 系统）"
  echo
  echo "无论清单里怎么写，这些内容都受保护、不会被删除。"
  echo "如果 scan.sh 生成的清单里出现了它们，说明文件被改过或损坏了。"
  echo
  while IFS=$'\t' read -r t p; do echo "  [$t] $p"; done < "$PROTECTED_FILE"
  echo
fi

if [ "$n_shared_skipped" -gt 0 ]; then
  echo "## 已保留 — 与仍安装着的应用共享（$n_shared_skipped 项）"
  echo
  echo "即扫描报告里 🚫 档的内容，本工具永远不会删除它们。"
  echo
fi

if [ -s "$MISSING_FILE" ]; then
  echo "## 已不存在（跳过）"
  echo
  while IFS= read -r p; do echo "  $p"; done < "$MISSING_FILE"
  echo
fi

if [ "$n_targets" -eq 0 ]; then
  echo "档位 '$TIER' 没有需要处理的内容。"
  exit 0
fi

echo "## 将要删除（$n_targets 项）"
echo
total_kb=0
while IFS=$'\t' read -r tier path; do
  kb="$(du -sk "$path" 2>/dev/null | awk '{print $1}')"
  [ -n "$kb" ] && total_kb=$((total_kb + kb))
  printf '  [%s] %s (%s)\n' "$tier" "$path" \
    "$(awk -v k="${kb:-0}" 'BEGIN{if(k<1024)printf "%dKB",k; else if(k<1048576)printf "%.1fMB",k/1024; else printf "%.2fGB",k/1048576}')"
done < "$TARGETS_FILE"
echo
awk -v k="$total_kb" 'BEGIN{printf "合计: %.1f MB\n", k/1024}'
echo

if [ -n "$RUNNING" ]; then
  echo "## ⚠️  应用仍在运行，PID: $RUNNING"
  echo
  echo "请先退出该应用——它退出时会重写偏好设置。"
  echo
  if [ $EXECUTE -eq 1 ]; then
    echo "应用运行期间拒绝执行。"
    exit 1
  fi
fi

if [ $EXECUTE -eq 0 ]; then
  echo "以上仅为预演。确认无误后加 --execute 才会真正移入废纸篓。"
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
    printf 'ok\t%s\n' "$path" >> "$OUTCOMES_FILE"
  else
    fail=$((fail + 1))
    printf '  ✘ %s（移入废纸篓失败——检查权限或「完全磁盘访问」）\n' "$path" >&2
    printf 'fail\t%s\n' "$path" >> "$OUTCOMES_FILE"
  fi
done < "$TARGETS_FILE"

echo
echo "已移入废纸篓: $ok    失败: $fail"

# ===== Verify =====

echo
echo "## 验证结果"
echo

verify_fail=0

# 1. Targets actually left their original locations.
still=0
while IFS=$'\t' read -r tier path; do
  if [ -e "$path" ] || [ -L "$path" ]; then
    printf '  ✘ 仍然存在: %s\n' "$path"
    still=$((still + 1))
  fi
done < "$TARGETS_FILE"
if [ "$still" -eq 0 ]; then
  printf '  ✔ %s 项均已从原位置移走\n' "$ok"
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
    printf '  ✘✘ 目录丢失: %s\n' "$d" >&2
    missing_anc=$((missing_anc + 1))
  fi
done < "$ANCESTORS_FILE"
if [ "$missing_anc" -eq 0 ]; then
  printf '  ✔ %s 个上级目录及系统目录完好无损\n' "$n_anc"
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
  printf '  ✔ %s 项已确认在废纸篓中，可还原\n' "$found"
else
  printf '  ✔ %s 项已确认在废纸篓中\n' "$found"
  printf '  ⚠ 另有 %s 项未按原名找到。废纸篓里重名时访达会自动改名，\n' "$inconclusive"
  printf '    所以这只是无法确认，并不代表丢失——请在访达的废纸篓里核对。\n'
fi

# ===== Archive =====
# Written next to the manifest, so report.md / manifest.tsv / result.md for one
# uninstall live in the same folder. Rebuilt from recorded state rather than by
# capturing stdout — a tee'd process substitution can be cut off at exit.
RESULT_FILE="$(dirname "$MANIFEST")/result.md"
{
  printf '# 卸载结果 — %s\n\n' "${APP_LABEL:-未知应用}"
  printf '| | |\n|---|---|\n'
  printf '| 时间 | %s |\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  printf '| 处理档位 | `%s` |\n' "$TIER"
  printf '| 清单文件 | `%s` |\n' "$MANIFEST"
  printf '| 已移入废纸篓 | %s |\n' "$ok"
  printf '| 失败 | %s |\n\n' "$fail"

  printf '## 已移入废纸篓\n\n'
  if [ -s "$OUTCOMES_FILE" ]; then
    while IFS=$'\t' read -r st pth; do
      [ "$st" = "ok" ] || continue
      printf -- '- `%s`\n' "$pth"
    done < "$OUTCOMES_FILE"
  else
    printf '_无_\n'
  fi
  printf '\n'

  if [ "$fail" -gt 0 ]; then
    printf '## 失败的条目\n\n'
    while IFS=$'\t' read -r st pth; do
      [ "$st" = "fail" ] || continue
      printf -- '- `%s`\n' "$pth"
    done < "$OUTCOMES_FILE"
    printf '\n'
  fi

  printf '## 验证结果\n\n'
  printf -- '- 目标已从原位置移走：%s\n' \
    "$([ "$still" -eq 0 ] && echo "是（全部 $ok 项）" || echo "否 —— 仍有 $still 项存在")"
  printf -- '- 上级目录及系统目录完好：%s\n' \
    "$([ "$missing_anc" -eq 0 ] && echo "是（已检查 $n_anc 个）" || echo "否 —— 丢失 $missing_anc 个")"
  printf -- '- 已确认在废纸篓中：%s / %s\n' "$found" "$ok"
  [ "$inconclusive" -gt 0 ] && printf -- '  （另有 %s 项未按原名找到；废纸篓重名时访达会自动改名）\n' "$inconclusive"
  printf '\n'

  if [ "$verify_fail" -gt 0 ]; then
    printf '**验证未通过 —— 有 %s 处异常。**\n\n' "$verify_fail"
  fi
  printf '_以上内容在废纸篓被清空之前都可以还原。_\n'
} > "$RESULT_FILE"

printf '\n[已保存] %s\n' "$RESULT_FILE"

echo
if [ "$verify_fail" -gt 0 ]; then
  echo "❌ 验证未通过——上面有 $verify_fail 处异常，请停下来检查。" >&2
  exit 1
fi
if [ "$fail" -gt 0 ]; then
  echo "有条目移动失败。不要盲目重试，先看上面的报错。" >&2
  exit 1
fi
echo "✅ 验证通过。以上内容在你清空废纸篓之前都可以还原。"
exit 0
