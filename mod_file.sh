#!/bin/bash
# mod_file.sh - 檔案 & 目錄 (含 SUID 稽核 / world-writable / 敏感檔 checksum)
_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_HERE}/LinuxMenu.sh" 2>/dev/null
: "${YEL:=\033[1;33m}"; : "${RED:=\033[0;31m}"; : "${RST:=\033[0m}"

menu() {
    clear
    echo "======================================================"
    echo " 檔案 & 目錄 (File & Directory)"
    echo "======================================================"
    echo "  1) 搜尋大檔 (自訂路徑 + 大小門檻)"
    echo "  2) 目錄空間使用量 (自訂路徑)"
    echo "  3) SUID / SGID 檔案稽核 (合規)"
    echo "  4) World-writable 檔案 (後門風險)"
    echo "  5) 敏感檔異動時間 (/etc/passwd /etc/shadow /etc/sudoers)"
    echo "  6) 敏感檔 checksum (sha256)"
    echo -e "  7) ${YEL}[變更] 壓縮指定天數以上之 *.log (自訂路徑/天數)${RST}"
    echo -e "  8) ${RED}[高風險] 刪除指定天數以上之 *.log.gz (自訂路徑/天數)${RST}"
    echo "  b) 返回主選單"
    echo "======================================================"
}

suid_audit() {
    echo "-- SUID 檔案清單 (可能造成權限提升) --"
    find / -xdev -type f -perm -4000 -printf "%M %u %g %p\n" 2>/dev/null
    echo
    echo "-- SGID 檔案清單 --"
    find / -xdev -type f -perm -2000 -printf "%M %u %g %p\n" 2>/dev/null
}

world_writable() {
    echo "-- 世界可寫檔（排除 /proc /sys /dev） --"
    find / -xdev -type f -perm -0002 -not -path "/proc/*" \
         -not -path "/sys/*" -not -path "/dev/*" \
         -printf "%M %u %g %p\n" 2>/dev/null | head -50
    echo
    echo "-- sticky bit 未設的世界可寫目錄 (/tmp 應設 sticky) --"
    find / -xdev -type d -perm -0002 -not -perm -1000 \
         -printf "%M %p\n" 2>/dev/null | head -20
}

sensitive_mtime() {
    for f in /etc/passwd /etc/shadow /etc/group /etc/sudoers /etc/sudoers.d \
             /etc/ssh/sshd_config /etc/pam.d/system-auth \
             /root/.ssh/authorized_keys /root/.bash_history; do
        if [ -e "$f" ]; then
            stat -c "%y %n" "$f" 2>/dev/null
        fi
    done
}

sensitive_sha() {
    for f in /etc/passwd /etc/shadow /etc/group /etc/sudoers \
             /etc/ssh/sshd_config; do
        [ -f "$f" ] && sha256sum "$f"
    done
}

while true; do
    menu
    read -r -p "選擇 > " c || exit 0
    case "$c" in
        1) echo "掃描路徑 [/]，大小門檻 [100M] - 3 秒內可改，否則用預設"
           p=""; sz=""
           read -r -t 3 -p "路徑 (Enter=/) > " p || true; p="${p:-/}"
           read -r -t 3 -p "大小 (Enter=100M, 如 500M/1G) > " sz || true; sz="${sz:-100M}"
           echo "→ find ${p} >${sz}"
           run_cmd "Find >${sz} files in ${p}" \
               find "${p}" -xdev -type f -size +"${sz}" -printf "%s %p\n" ;;
        2) echo "目錄使用量 [/var/log] - 3 秒內可改，否則用預設"
           d=""
           read -r -t 3 -p "目錄 (Enter=/var/log) > " d || true; d="${d:-/var/log}"
           echo "→ du -sh ${d}/*"
           run_cmd "Disk usage ${d}" du -sh "${d}"/* ;;
        3) run_cmd "SUID/SGID audit" suid_audit ;;
        4) run_cmd "World-writable scan" world_writable ;;
        5) run_cmd "Sensitive files mtime" sensitive_mtime ;;
        6) run_cmd "Sensitive files sha256" sensitive_sha ;;
        7) read -r -p "目錄 [/var/log] > " d; d="${d:-/var/log}"
           read -r -p "保留天數 [7]  (超過此天數的 *.log 會被壓縮) > " days
           days="${days:-7}"
           run_change_cmd "Compress *.log >${days}d in ${d}" \
               find "${d}" -type f -mtime +"${days}" -name "*.log" -exec gzip {} \; ;;
        8) read -r -p "目錄 [/var/log] > " d; d="${d:-/var/log}"
           read -r -p "保留天數 [30] (超過此天數的 *.log.gz 會被刪除) > " days
           days="${days:-30}"
           run_impact_cmd "Delete *.log.gz >${days}d in ${d}" \
               find "${d}" -type f -mtime +"${days}" -name "*.gz" -delete ;;
        b|B) exit 0 ;;
        *)   echo "無效選項" ;;
    esac
    pause
done
