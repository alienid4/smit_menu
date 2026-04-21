#!/bin/bash
# mod_audit.sh - 日誌 & 稽核 (含 root 登入統計 / sudo 錯誤 / journalctl)
_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_HERE}/LinuxMenu.sh" 2>/dev/null
: "${YEL:=\033[1;33m}"; : "${RED:=\033[0;31m}"; : "${RST:=\033[0m}"
: "${SYSLOG:=/var/log/messages}"
: "${AUTHLOG:=/var/log/secure}"

menu() {
    clear
    echo "======================================================"
    echo " 日誌 & 稽核 (Log & Audit)"
    echo " syslog: ${SYSLOG}    auth: ${AUTHLOG}"
    echo "======================================================"
    echo "  1) 今日系統錯誤 (syslog 今日 error/critical)"
    echo "  2) 今日認證失敗 (authlog 今日 fail/invalid)"
    echo "  3) dmesg error / crit / alert"
    echo "  4) journalctl -p err (本次開機以來)"
    echo "  5) auditd 近期事件"
    echo "  6) root 登入成功 / 失敗 統計 (本月)"
    echo "  7) sudo 錯誤事件"
    echo "  8) 本工具審計 log (LinuxMenu)"
    echo "  b) 返回主選單"
    echo "======================================================"
}

recent_audit() {
    if [ "${DISTRO}" = "debian" ]; then
        journalctl --no-pager -n 40 _TRANSPORT=audit 2>/dev/null \
          || journalctl --no-pager -n 40 -p warning..err
    else
        ausearch -ts today 2>/dev/null | tail -n 40
    fi
}

root_login_stats() {
    local month; month=$(date +%b)
    echo "-- ${month} root 登入成功 --"
    grep -E "Accepted.*for root" "${AUTHLOG}" 2>/dev/null \
        | grep "${month}" | wc -l | xargs echo "count:"
    echo "-- ${month} root 登入失敗 --"
    grep -E "Failed.*for root|authentication failure.*user=root" "${AUTHLOG}" 2>/dev/null \
        | grep "${month}" | wc -l | xargs echo "count:"
    echo
    echo "-- 最近 5 筆失敗詳情 --"
    grep -E "Failed.*for root" "${AUTHLOG}" 2>/dev/null | tail -5
}

sudo_errors() {
    echo "-- sudo NOT in sudoers (授權不足) --"
    grep "NOT in sudoers" "${AUTHLOG}" 2>/dev/null | tail -20
    echo
    echo "-- sudo 密碼錯誤 --"
    grep "incorrect password attempts" "${AUTHLOG}" 2>/dev/null | tail -10
}

while true; do
    menu
    read -r -p "選擇 > " c || exit 0
    case "$c" in
        1) run_cmd "${SYSLOG} today ERROR" \
               bash -c "grep -Ei 'error|fail|critical' \"${SYSLOG}\" 2>/dev/null | grep \"$(date '+%b %e')\"" ;;
        2) run_cmd "${AUTHLOG} today failures" \
               bash -c "grep -Ei 'fail|invalid' \"${AUTHLOG}\" 2>/dev/null | grep \"$(date '+%b %e')\"" ;;
        3) run_cmd "dmesg errors"    bash -c "dmesg -T --level=err,crit,alert" ;;
        4) run_cmd "journalctl -p err -b" journalctl --no-pager -p err -b ;;
        5) run_cmd "Recent auditd"   recent_audit ;;
        6) run_cmd "root login stats" root_login_stats ;;
        7) run_cmd "sudo errors"     sudo_errors ;;
        8) run_cmd "LinuxMenu log"   tail -n 40 "${LOG_FILE}" ;;
        b|B) exit 0 ;;
        *)   echo "無效選項" ;;
    esac
    pause
done
