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

PIDS=()

cleanup() {
    echo ""
    log "dev" "shutting down..."
    for pid in "${PIDS[@]}"; do
        local pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
        if [ -n "$pgid" ]; then
            kill -- -"$pgid" 2>/dev/null || kill "$pid" 2>/dev/null
        fi
    done
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
    PIDS+=($!)
}

start_client_bg() {
    run_client &
    PIDS+=($!)
}

stop_by_name() {
    local name=$1
    local found=0
    local pids=""
    if [ "$name" = "server" ]; then
        pids=$(pgrep -f "$SERVER_PATTERN" 2>/dev/null)
        {{SERVER_EXTRA_PGREP}}
        if [ -n "$pids" ]; then
            echo "$pids" | xargs kill 2>/dev/null
            found=1
        fi
    elif [ "$name" = "client" ]; then
        pids=$(pgrep -Ef "$CLIENT_PATTERN" 2>/dev/null)
        if [ -n "$pids" ]; then
            echo "$pids" | xargs kill 2>/dev/null
            found=1
        fi
    fi
    if [ "$found" -eq 1 ]; then
        sleep 2
        # 还没死的强杀
        for pid in $pids; do
            if kill -0 "$pid" 2>/dev/null; then
                kill -9 "$pid" 2>/dev/null
            fi
        done
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
    PIDS=()
    if [ "$target" = "all" ]; then
        stop_by_name server; stop_by_name client
        start_server_bg; start_client_bg
        ok "dev" "both restarted"
    elif [ "$target" = "server" ]; then
        stop_by_name server
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
