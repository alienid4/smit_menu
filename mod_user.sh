#!/bin/bash
# mod_user.sh - 帳號 & 權限 (含 UID=0 檢查 / 空密碼 / 新增帳號 / sudo 規則)
_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_HERE}/LinuxMenu.sh" 2>/dev/null
: "${YEL:=\033[1;33m}"; : "${RED:=\033[0;31m}"; : "${RST:=\033[0m}"
: "${FAILLOCK:=faillock}"

menu() {
    clear
    echo "======================================================"
    echo " 帳號 & 權限 (User & Permission)    重設工具: ${FAILLOCK}"
    echo "======================================================"
    echo "  1) 最近登入紀錄 (last -20)"
    echo "  2) 登入失敗紀錄 (lastb -20)"
    echo "  3) 全帳號鎖定狀態"
    echo "  4) 密碼到期資訊 (chage)"
    echo "  5) UID=0 全帳號清單 (後門檢查)"
    echo "  6) 空密碼帳號檢查"
    echo "  7) 近 7 日新增 / 變更的帳號"
    echo "  8) sudo 規則清單"
    echo "  9) SSH authorized_keys 稽核 (每個可登入帳號)"
    echo "  b) 返回主選單"
    echo "  (lite 版已移除解鎖/重設失敗計數等變更類操作)"
    echo "======================================================"
}

list_lock_status() {
    printf "%-20s %-12s %-12s\n" "USER" "STATUS" "LAST-CHG"
    printf "%-20s %-12s %-12s\n" "----" "------" "--------"
    while IFS=: read -r user _ uid _ _ _ _; do
        [ "${uid}" -ge 0 ] || continue
        status=$(passwd -S "${user}" 2>/dev/null | awk '{print $2}')
        case "${status}" in
            L|LK) label="LOCKED"   ;;
            P|PS) label="ACTIVE"   ;;
            NP)   label="NO-PASS"  ;;
            *)    label="${status:-N/A}" ;;
        esac
        lastchg=$(chage -l "${user}" 2>/dev/null | awk -F': ' '/Last password change/{print $2}')
        printf "%-20s %-12s %-12s\n" "${user}" "${label}" "${lastchg}"
    done < /etc/passwd
}

uid0_accounts() {
    echo "-- 所有 UID=0 的帳號 (正常只有 root) --"
    awk -F: '$3==0 {print $1, $3, $6, $7}' /etc/passwd
    local n
    n=$(awk -F: '$3==0' /etc/passwd | wc -l)
    if [ "${n}" -gt 1 ]; then
        echo -e "${RED}警告: 偵測到多個 UID=0 帳號！可能是後門。${RST}"
    fi
}

empty_password() {
    echo "-- 空密碼帳號 (shadow 第二欄為空) --"
    local n
    n=$(awk -F: '$2=="" {print $1}' /etc/shadow 2>/dev/null | wc -l)
    awk -F: '$2=="" {print $1}' /etc/shadow 2>/dev/null
    if [ "${n}" -gt 0 ]; then
        echo -e "${RED}警告: ${n} 個空密碼帳號。${RST}"
    else
        echo "(無)"
    fi
}

recent_accounts() {
    echo "-- 近 7 日建立/變更的 /etc/passwd, /etc/shadow, /etc/group --"
    find /etc/passwd /etc/shadow /etc/group -mtime -7 -printf "%TY-%Tm-%Td %TH:%TM  %p\n" 2>/dev/null
    echo
    echo "-- 近 7 日密碼變更 (chage) --"
    while IFS=: read -r user _ uid _ _ _ _; do
        [ "${uid}" -ge 1000 ] || continue
        last=$(chage -l "${user}" 2>/dev/null | awk -F': ' '/Last password change/{print $2}')
        [ -z "${last}" ] && continue
        ts=$(date -d "${last}" +%s 2>/dev/null) || continue
        now=$(date +%s); diff=$(( (now-ts)/86400 ))
        [ "${diff}" -lt 7 ] && echo "${user}  最後變更: ${last}  (${diff} 天前)"
    done < /etc/passwd
}

sudo_rules() {
    echo "-- /etc/sudoers --"
    cat /etc/sudoers 2>/dev/null | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$'
    echo
    echo "-- /etc/sudoers.d/* --"
    for f in /etc/sudoers.d/*; do
        [ -f "$f" ] || continue
        echo "## $f ##"
        cat "$f" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$'
    done
}

authkey_audit() {
    for home in /root /home/*; do
        [ -d "$home" ] || continue
        ak="${home}/.ssh/authorized_keys"
        if [ -f "$ak" ]; then
            n=$(grep -cv '^[[:space:]]*$\|^[[:space:]]*#' "$ak" 2>/dev/null)
            owner=$(stat -c %U "$ak" 2>/dev/null)
            mode=$(stat -c %a "$ak" 2>/dev/null)
            printf "%-30s keys=%-3s owner=%-10s mode=%s\n" "$ak" "$n" "$owner" "$mode"
            [ "$mode" != "600" ] && echo -e "  ${RED}警告: 權限應為 600${RST}"
        fi
    done
}

reset_fail_counter() {
    local u="$1"
    case "${FAILLOCK}" in
        pam_tally2) pam_tally2 --user "${u}" --reset ;;
        faillock)   faillock --user "${u}" --reset ;;
        *)          echo "faillock/pam_tally2 皆不可用，請檢查 PAM 設定"; return 1 ;;
    esac
}

while true; do
    menu
    read -r -p "選擇 > " c || exit 0
    case "$c" in
        1)  run_cmd "Recent logins"      last -n 20 ;;
        2)  run_cmd "Failed logins"      lastb -n 20 ;;
        3)  run_cmd "Lock status table"  list_lock_status ;;
        4)  read -r -p "帳號 > " u
            run_cmd "chage ${u}"         chage -l "${u}" ;;
        5)  run_cmd "UID=0 accounts"     uid0_accounts ;;
        6)  run_cmd "Empty password"     empty_password ;;
        7)  run_cmd "Recent account changes" recent_accounts ;;
        8)  run_cmd "Sudo rules"         sudo_rules ;;
        9)  run_cmd "authorized_keys audit" authkey_audit ;;
        b|B) exit 0 ;;
        *)   echo "無效選項" ;;
    esac
    pause
done
