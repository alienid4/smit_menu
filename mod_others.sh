#!/bin/bash
# mod_others.sh - Crontab & environment
_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_HERE}/LinuxMenu.sh" 2>/dev/null
: "${GRN:=\033[0;32m}"; : "${YEL:=\033[1;33m}"; : "${RED:=\033[0;31m}"; : "${RST:=\033[0m}"

menu() {
    clear
    echo "── 其他工具 Others ───────────────────────────────"
    echo -e "  ${GRN}1) 所有使用者 crontab${RST}"
    echo -e "  ${GRN}2) /etc/crontab & cron.d${RST}"
    echo -e "  ${GRN}3) 環境變數 (env)${RST}"
    echo -e "  ${GRN}4) Locale / Timezone${RST}"
    echo -e "  ${GRN}5) Systemd timers${RST}"
    echo    "  b) 返回"
}

all_crontabs() {
    for u in $(cut -d: -f1 /etc/passwd); do
        ct=$(crontab -u "${u}" -l 2>/dev/null)
        [ -n "${ct}" ] && { echo "── ${u} ──"; echo "${ct}"; }
    done
}

while true; do
    menu
    read -r -p "選擇 > " c || exit 0
    case "$c" in
        1) run_cmd "All crontabs"   all_crontabs ;;
        2) run_cmd "System cron"    bash -c "cat /etc/crontab; echo; ls -l /etc/cron.d" ;;
        3) run_cmd "env"            env ;;
        4) run_cmd "locale/tz"      bash -c "locale; echo; timedatectl" ;;
        5) run_cmd "timers"         systemctl list-timers --all ;;
        b|B) exit 0 ;;
        *)   echo "無效選項" ;;
    esac
    pause
done
