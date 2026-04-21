#!/bin/bash
# mod_system.sh - 系統資訊 (含金融業 SP 所需的硬體/熵值/開機原因)
_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_HERE}/LinuxMenu.sh" 2>/dev/null
: "${YEL:=\033[1;33m}"; : "${RED:=\033[0;31m}"; : "${RST:=\033[0m}"

menu() {
    clear
    echo "======================================================"
    echo " 系統資訊 (System Info)"
    echo "======================================================"
    echo "  1) Uptime / Load Average"
    echo "  2) Kernel 版本 (uname -a)"
    echo "  3) NTP 時間同步狀態"
    echo "  4) CPU / Memory 概況"
    echo "  5) 硬體資訊 (製造商/型號/BIOS)"
    echo "  6) 加密熵值 (/proc/sys/kernel/random/entropy_avail)"
    echo "  7) 最近開機 / 關機 紀錄"
    echo "  b) 返回主選單"
    echo "======================================================"
}

hw_info() {
    if command -v dmidecode >/dev/null 2>&1; then
        echo "-- DMI (BIOS/HW) --"
        dmidecode -s system-manufacturer 2>/dev/null
        dmidecode -s system-product-name 2>/dev/null
        dmidecode -s system-serial-number 2>/dev/null
        dmidecode -s bios-version 2>/dev/null
        dmidecode -s bios-release-date 2>/dev/null
    else
        echo "dmidecode 不可用"
    fi
    echo
    echo "-- Virtualization --"
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        echo "virt: $(systemd-detect-virt)"
    fi
}

entropy_check() {
    local e
    e=$(cat /proc/sys/kernel/random/entropy_avail 2>/dev/null || echo 0)
    echo "entropy_avail = ${e}"
    if [ "${e}" -lt 256 ]; then
        echo -e "${RED}警告: entropy 過低（<256），加密/SSL 操作可能等待。建議安裝 haveged 或 rng-tools。${RST}"
    else
        echo "entropy 正常（>=256）"
    fi
}

boot_history() {
    echo "-- 最近 5 次開機 --"
    last -n 5 reboot 2>/dev/null || last -x | grep -i reboot | head -5
    echo
    echo "-- 最近 5 次關機 --"
    last -n 5 shutdown 2>/dev/null || last -x | grep -i shutdown | head -5
    echo
    echo "-- 當前 runlevel / target --"
    systemctl get-default 2>/dev/null || runlevel
}

while true; do
    menu
    read -r -p "選擇 > " c || exit 0
    case "$c" in
        1) run_cmd "Uptime / Load"    uptime ;;
        2) run_cmd "Kernel version"   uname -a ;;
        3) run_cmd "NTP sync status"  timedatectl status ;;
        4) run_cmd "CPU & Memory"     bash -c "lscpu | head; echo; free -h" ;;
        5) run_cmd "Hardware info"    hw_info ;;
        6) run_cmd "Entropy check"    entropy_check ;;
        7) run_cmd "Boot/shutdown history" boot_history ;;
        b|B) exit 0 ;;
        *)   echo "無效選項" ;;
    esac
    pause
done
