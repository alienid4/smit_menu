#!/bin/bash
# mod_storage.sh - 儲存 & 備份 (含 snapshot / fstab 驗證 / iostat / NFS)
_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_HERE}/LinuxMenu.sh" 2>/dev/null
: "${YEL:=\033[1;33m}"; : "${RED:=\033[0;31m}"; : "${RST:=\033[0m}"

THRESHOLD=80

disk_usage_highlight() {
    printf "%-30s %8s %8s %8s %6s  %s\n" "FILESYSTEM" "SIZE" "USED" "AVAIL" "USE%" "MOUNT"
    df -hP -x tmpfs -x devtmpfs | awk 'NR>1 {print}' | while read -r fs size used avail pct mnt; do
        num=${pct%\%}
        if   [ "${num}" -ge 90 ]; then color="${RED}"
        elif [ "${num}" -ge ${THRESHOLD} ]; then color="${YEL}"
        else color=""; fi
        printf "${color}%-30s %8s %8s %8s %6s  %s${RST}\n" "${fs}" "${size}" "${used}" "${avail}" "${pct}" "${mnt}"
    done
    echo
    echo "門檻: >=90% 紅色 / >=${THRESHOLD}% 黃色 / <${THRESHOLD}% 白色"
}

fstab_check() {
    echo "-- /etc/fstab 驗證 --"
    local ok=1
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        set -- $line
        [ $# -lt 4 ] && { echo -e "${RED}格式錯誤:${RST} $line"; ok=0; continue; }
        local dev="$1" mnt="$2"
        # 忽略 swap/special 檔案系統
        case "$mnt" in
            none|swap|/proc|/sys|/dev*|/run*) continue ;;
        esac
        if [ ! -e "$mnt" ]; then
            echo -e "${YEL}掛載點不存在:${RST} $mnt"
            ok=0
        fi
    done < /etc/fstab
    [ "$ok" -eq 1 ] && echo "/etc/fstab 看起來 OK"
}

lvm_snapshot() {
    if command -v lvs >/dev/null 2>&1; then
        echo "-- LVM snapshot 狀態 --"
        lvs -o +lv_attr,origin 2>/dev/null | grep -E 'Attr|s-' || echo "(無 snapshot)"
    else
        echo "lvm tools 不可用"
    fi
}

nfs_mounts() {
    echo "-- NFS 掛載 --"
    mount | grep -E 'nfs|cifs' || echo "(無 NFS/CIFS 掛載)"
    echo
    echo "-- /etc/exports (若此機為 NFS server) --"
    [ -f /etc/exports ] && cat /etc/exports || echo "(無 /etc/exports)"
}

menu() {
    clear
    echo "======================================================"
    echo " 儲存 & 備份 (Storage & Backup)"
    echo "======================================================"
    echo "  1) 磁碟使用率 (門檻 ${THRESHOLD}%，含顏色)"
    echo "  2) Inode 使用率"
    echo "  3) LVM PV / VG / LV"
    echo "  4) LVM snapshot 狀態"
    echo "  5) 掛載點 (mount)"
    echo "  6) /etc/fstab 驗證"
    echo "  7) Top 10 佔用目錄 (/var)"
    echo "  8) I/O 統計 (iostat 3 次取樣)"
    echo "  9) NFS / CIFS 掛載與 exports"
    echo "  b) 返回主選單"
    echo "======================================================"
}

while true; do
    menu
    read -r -p "選擇 > " c || exit 0
    case "$c" in
        1) run_cmd "Disk usage"      disk_usage_highlight ;;
        2) run_cmd "Inode usage"     df -i ;;
        3) run_cmd "LVM info"        bash -c "pvs; echo; vgs; echo; lvs" ;;
        4) run_cmd "LVM snapshot"    lvm_snapshot ;;
        5) run_cmd "Mounts"          mount ;;
        6) run_cmd "fstab check"     fstab_check ;;
        7) run_cmd "Top dirs /var"   bash -c "du -xh /var 2>/dev/null | sort -rh | head -n 10" ;;
        8) run_cmd "iostat"          bash -c "command -v iostat >/dev/null && iostat -x 1 3 || echo 'iostat 不可用，安裝 sysstat 套件'" ;;
        9) run_cmd "NFS mounts"      nfs_mounts ;;
        b|B) exit 0 ;;
        *)   echo "無效選項" ;;
    esac
    pause
done
