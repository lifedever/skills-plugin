#!/bin/bash

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER_DIR="$BASE_DIR/{{SERVER_DIR_NAME}}"
CLIENT_DIR="$BASE_DIR/{{CLIENT_DIR_NAME}}"

# Project-unique identifiers for pgrep (avoid killing unrelated processes)
SERVER_PATTERN="{{SERVER_PGREP_PATTERN}}"
CLIENT_PATTERN="{{CLIENT_PGREP_PATTERN}}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

log()  { echo -e "${CYAN}[$1]${NC} $2"; }
ok()   { echo -e "${GREEN}[$1]${NC} $2"; }
warn() { echo -e "${YELLOW}[$1]${NC} $2"; }
err()  { echo -e "${RED}[$1]${NC} $2"; }

# 追踪各服务的后台进程(命名变量,不用扁平数组)——
# 单独重启一个服务不会丢失另一个的 PID;停止时清空,避免陈旧 PID 被系统复用后误杀
SERVER_PID=""
CLIENT_PID=""

# 只杀"仍存活、且确实是我们启动的"那个后台进程组;PID 已退出则跳过
# ——退出后该 PID 可能被系统复用给无关进程,盲目 kill 进程组会误伤(见项目杀进程红线)
kill_own_pgid() {
    local pid=$1
    [ -z "$pid" ] && return
    kill -0 "$pid" 2>/dev/null || return
    local pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pgid" ] && { kill -- -"$pgid" 2>/dev/null || kill "$pid" 2>/dev/null; }
}

cleanup() {
    echo ""
    log "dev" "shutting down..."
    kill_own_pgid "$SERVER_PID"
    kill_own_pgid "$CLIENT_PID"
    # pattern 兜底:pattern 含项目专属路径,只匹配本项目进程,扫掉 fork 出的残余子进程
    pgrep -f "$SERVER_PATTERN" 2>/dev/null | xargs kill 2>/dev/null
    pgrep -Ef "$CLIENT_PATTERN" 2>/dev/null | xargs kill 2>/dev/null
    sleep 1
    pgrep -f "$SERVER_PATTERN" 2>/dev/null | xargs kill -9 2>/dev/null
    pgrep -Ef "$CLIENT_PATTERN" 2>/dev/null | xargs kill -9 2>/dev/null
    ok "dev" "all stopped"
    exit 0
}

trap cleanup SIGINT SIGTERM

run_server() {
    log "server" "cleaning & {{SERVER_START_LOG}}"
    cd "$SERVER_DIR"
    {{SERVER_START_CMD}} < /dev/null 2>&1 | awk '{print "\033[0;32m[server]\033[0m " $0}'
}

run_client() {
    log "client" "{{CLIENT_START_LOG}}"
    cd "$CLIENT_DIR"
    {{CLIENT_START_CMD}} < /dev/null 2>&1 | awk '{print "\033[0;35m[client]\033[0m " $0}'
}

start_server_bg() {
    run_server &
    SERVER_PID=$!
}

start_client_bg() {
    run_client &
    CLIENT_PID=$!
}

# 停止一个服务:全程只用项目专属 pattern 精确匹配,绝不按端口、绝不用 PGID
# (PGID 杀组会连累同会话其他服务;按端口会误杀"连到"该端口的客户端——见项目杀进程红线)
stop_by_name() {
    local name=$1
    local found=0
    local pids=""
    if [ "$name" = "server" ]; then
        pids=$(pgrep -f "$SERVER_PATTERN" 2>/dev/null)
        {{SERVER_EXTRA_PGREP}}
        SERVER_PID=""
    elif [ "$name" = "client" ]; then
        pids=$(pgrep -Ef "$CLIENT_PATTERN" 2>/dev/null)
        CLIENT_PID=""
    fi
    if [ -n "$pids" ]; then
        echo "$pids" | xargs kill 2>/dev/null       # 先 SIGTERM 礼貌退出
        found=1
    fi
    if [ "$found" -eq 1 ]; then
        sleep 2
        # 升级 SIGKILL 前重新按 pattern 抓一次,只 -9 此刻仍匹配本项目的存活进程;
        # 不复用 sleep 前的旧 PID 列表——这 2s 内进程若已退出,其 PID 可能被系统复用,盲目 -9 会误杀
        local survivors=""
        if [ "$name" = "server" ]; then
            survivors=$(pgrep -f "$SERVER_PATTERN" 2>/dev/null)
        else
            survivors=$(pgrep -Ef "$CLIENT_PATTERN" 2>/dev/null)
        fi
        [ -n "$survivors" ] && echo "$survivors" | xargs kill -9 2>/dev/null
        sleep 0.5
        ok "$name" "stopped"
    else
        warn "$name" "no running process found"
    fi
}

check_status() {
    local name=$1 pattern=$2
    local pids
    if [ "$name" = "client" ]; then
        pids=$(pgrep -Ef "$pattern" 2>/dev/null)
    else
        pids=$(pgrep -f "$pattern" 2>/dev/null)
    fi
    if [ -n "$pids" ]; then
        ok "$name" "running (pid: $(echo $pids | tr '\n' ' '))"
    else
        warn "$name" "not running"
    fi
}

status() {
    check_status "server" "$SERVER_PATTERN"
    check_status "client" "$CLIENT_PATTERN"
}

print_shortcuts() {
    echo ""
    echo -e "  ${BOLD}Shortcuts${NC}"
    echo -e "  ${DIM}press key + enter${NC}"
    echo -e "  ${CYAN}r${NC}   restart all"
    echo -e "  ${CYAN}rs${NC}  restart server"
    echo -e "  ${CYAN}rc${NC}  restart client"
    echo -e "  ${CYAN}s${NC}   status"
    echo -e "  ${CYAN}h${NC}   help"
    echo -e "  ${CYAN}q${NC}   quit"
    echo ""
}

restart_service() {
    local target=$1
    if [ "$target" = "all" ]; then
        stop_by_name server; stop_by_name client
        start_server_bg; start_client_bg
        ok "dev" "both restarted"
    elif [ "$target" = "server" ]; then
        stop_by_name server        # 只清 SERVER_PID,CLIENT_PID 原样保留
        start_server_bg
        ok "server" "restarted"
    elif [ "$target" = "client" ]; then
        stop_by_name client
        start_client_bg
        ok "client" "restarted"
    fi
}

print_hint() {
    echo -e "\n${DIM}────────────────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}r${NC} restart all ${DIM}|${NC} ${BOLD}rs${NC} server ${DIM}|${NC} ${BOLD}rc${NC} client ${DIM}|${NC} ${BOLD}s${NC} status ${DIM}|${NC} ${BOLD}h${NC} help ${DIM}|${NC} ${BOLD}q${NC} quit"
    echo -e "${DIM}────────────────────────────────────────────────────${NC}"
}

interactive_loop() {
    print_hint
    while true; do
        read -r cmd 2>/dev/null || break
        case "$cmd" in
            r)  restart_service all ;;
            rs) restart_service server ;;
            rc) restart_service client ;;
            s)  status ;;
            h)  print_shortcuts ;;
            q)  cleanup ;;
            "") ;;
            *)  warn "dev" "unknown command '$cmd', press h + enter for help" ;;
        esac
    done
}

usage() {
    echo ""
    echo "Usage: $0 <command> [target]"
    echo ""
    echo "Commands:"
    echo "  start   [server|client]   Start services (default: both, interactive)"
    echo "  stop    [server|client]   Stop services (default: both)"
    echo "  restart [server|client]   Restart services (default: both)"
    echo "  status                    Show running status"
    echo ""
    echo "Examples:"
    echo "  $0 start                  Start both (interactive mode)"
    echo "  $0 start server           Start server only"
    echo "  $0 stop client            Stop client only"
    echo "  $0 stop                   Stop both"
    echo ""
}

case "$1" in
    start)
        case "$2" in
            server) run_server ;;
            client) run_client ;;
            "")
                start_server_bg
                start_client_bg
                ok "dev" "both started"
                interactive_loop
                wait
                ;;
            *) usage ;;
        esac
        ;;
    stop)
        case "$2" in
            server) stop_by_name server ;;
            client) stop_by_name client ;;
            "") stop_by_name server; stop_by_name client ;;
            *) usage ;;
        esac
        ;;
    restart)
        case "$2" in
            server) stop_by_name server; run_server ;;
            client) stop_by_name client; run_client ;;
            "")
                stop_by_name server; stop_by_name client
                start_server_bg
                start_client_bg
                ok "dev" "both restarted"
                interactive_loop
                wait
                ;;
            *) usage ;;
        esac
        ;;
    status) status ;;
    *) usage ;;
esac
