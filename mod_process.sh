#!/bin/bash
# mod_process.sh - 程序監控 (含 FD 耗用 / 可疑進程 / pstree)
_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_HERE}/LinuxMenu.sh" 2>/dev/null
: "${YEL:=\033[1;33m}"; : "${RED:=\033[0;31m}"; : "${RST:=\033[0m}"

menu() {
    clear
    echo "======================================================"
    echo " 程序監控 (Process Monitor)"
    echo "======================================================"
    echo "  1) Top 10 CPU 使用率"
    echo "  2) Top 10 記憶體使用率"
    echo "  3) 殭屍程序 (Zombie)"
    echo "  4) 開啟檔案描述子最多的 10 個進程"
    echo "  5) 可疑進程 (無 tty / 無父進程)"
    echo "  6) Process tree (pstree)"
    echo "  b) 返回主選單"
    echo "  (lite 版已移除 Kill 等變更類操作)"
    echo "======================================================"
}

top_fd() {
    if command -v lsof >/dev/null 2>&1; then
        lsof 2>/dev/null | awk 'NR>1 {c[$2]++} END {for (p in c) print c[p], p}' \
          | sort -rn | head -10 | while read -r count pid; do
              comm=$(ps -p "$pid" -o comm= 2>/dev/null)
              user=$(ps -p "$pid" -o user= 2>/dev/null)
              printf "%6d FDs  PID=%-7s USER=%-12s %s\n" "$count" "$pid" "$user" "$comm"
          done
    else
        echo "lsof 不可用，改掃 /proc"
        for p in /proc/[0-9]*; do
            pid=${p##*/}
            n=$(ls "$p/fd" 2>/dev/null | wc -l)
            [ "$n" -gt 0 ] && echo "$n $pid"
        done | sort -rn | head -10
    fi
}

suspicious_procs() {
    echo "-- 無 tty 且非 systemd/init 子孫的進程 (可疑) --"
    ps -eo pid,ppid,tty,user,comm | awk '$3=="?" && $2!=0 && $2!=1 && $2!=2' | head -30
    echo
    echo "-- 父進程 PID 為 1 的所有 daemons (正常情況) --"
    ps -eo pid,ppid,user,comm | awk '$2==1' | wc -l | xargs echo "count:"
}

ptree() {
    if command -v pstree >/dev/null 2>&1; then
        pstree -p | head -60
    else
        ps -eo pid,ppid,comm --forest | head -60
    fi
}

while true; do
    menu
    read -r -p "選擇 > " c || exit 0
    case "$c" in
        1) run_cmd "Top 10 CPU" \
               bash -c "ps -eo pid,ppid,user,%cpu,%mem,comm --sort=-%cpu | head -n 11" ;;
        2) run_cmd "Top 10 MEM" \
               bash -c "ps -eo pid,ppid,user,%cpu,%mem,comm --sort=-%mem | head -n 11" ;;
        3) run_cmd "Zombie processes" \
               bash -c "ps -eo pid,ppid,state,comm | awk '\$3==\"Z\"'" ;;
        4) run_cmd "Top FD usage"    top_fd ;;
        5) run_cmd "Suspicious procs" suspicious_procs ;;
        6) run_cmd "Process tree"    ptree ;;
        b|B) exit 0 ;;
        *)   echo "無效選項" ;;
    esac
    pause
done
