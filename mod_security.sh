#!/bin/bash
# mod_security.sh - 安全稽核 (含 fail2ban / auditctl / PAM / bash_history)
_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_HERE}/LinuxMenu.sh" 2>/dev/null
: "${YEL:=\033[1;33m}"; : "${RED:=\033[0;31m}"; : "${RST:=\033[0m}"
: "${SSHD_SVC:=sshd}"
: "${FW:=firewall-cmd}"
: "${SECMOD:=sestatus}"

list_fw_zones() {
    case "${DISTRO}" in
        debian) ufw status verbose ;;
        *)      firewall-cmd --list-all-zones ;;
    esac
}

mac_status() {
    case "${DISTRO}" in
        debian) aa-status 2>/dev/null || echo "AppArmor not installed" ;;
        *)      sestatus 2>/dev/null || echo "SELinux not installed" ;;
    esac
}

fail2ban_stat() {
    if command -v fail2ban-client >/dev/null 2>&1; then
        fail2ban-client status 2>/dev/null
        echo
        for j in $(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/{print $2}' | tr ',' ' '); do
            echo "── jail: $j ──"
            fail2ban-client status "$j" 2>/dev/null
        done
    else
        echo -e "${YEL}fail2ban 未安裝 (金融業建議安裝)${RST}"
    fi
}

auditctl_rules() {
    if command -v auditctl >/dev/null 2>&1; then
        echo "-- Loaded audit rules --"
        auditctl -l 2>/dev/null
        echo
        echo "-- /etc/audit/rules.d/*.rules --"
        ls -la /etc/audit/rules.d/ 2>/dev/null
    else
        echo "auditd 未安裝"
    fi
}

pam_audit() {
    echo "-- PAM 密碼鎖定策略 (pam_tally2 / pam_faillock) --"
    grep -l 'pam_tally2\|pam_faillock' /etc/pam.d/* 2>/dev/null \
      | xargs grep -H 'pam_tally2\|pam_faillock' 2>/dev/null
    echo
    echo "-- PAM 密碼強度 (pam_pwquality / pam_cracklib) --"
    grep -l 'pam_pwquality\|pam_cracklib' /etc/pam.d/* 2>/dev/null \
      | xargs grep -H 'pam_pwquality\|pam_cracklib' 2>/dev/null
}

bash_history_check() {
    for home in /root /home/*; do
        [ -d "$home" ] || continue
        hf="${home}/.bash_history"
        if [ -f "$hf" ]; then
            mode=$(stat -c %a "$hf" 2>/dev/null)
            size=$(stat -c %s "$hf" 2>/dev/null)
            printf "%-30s  mode=%-4s  size=%s\n" "$hf" "$mode" "$size"
            if [ "$mode" != "600" ] && [ "$mode" != "640" ]; then
                echo -e "  ${RED}權限不當 (應為 600 或 640)${RST}"
            fi
        fi
    done
}

menu() {
    clear
    echo "======================================================"
    echo " 安全稽核 (Security)    MAC=${SECMOD}    FW=${FW}    Impact"
    echo "======================================================"
    echo "  1) SSHD 設定關鍵項 (PermitRootLogin/Protocol)"
    echo "  2) 當前 SSH 連線"
    echo "  3) authorized_keys 清單 (root)"
    echo "  4) MAC 狀態 (SELinux / AppArmor)"
    echo "  5) 防火牆 zones"
    echo "  6) fail2ban 狀態"
    echo "  7) auditctl 規則"
    echo "  8) PAM 稽核 (密碼策略 / 鎖定)"
    echo "  9) bash_history 權限檢查"
    echo -e " 10) ${RED}[高風險] 重啟 ${SSHD_SVC} (會中斷連線)${RST}"
    echo -e " 11) ${RED}[高風險] 切斷指定 SSH PTS${RST}"
    echo "  b) 返回主選單"
    echo "======================================================"
}

while true; do
    menu
    read -r -p "選擇 > " c || exit 0
    case "$c" in
        1) run_cmd "sshd_config key items" \
               bash -c "grep -Ei '^(PermitRootLogin|Protocol|PasswordAuthentication|PermitEmptyPasswords|X11Forwarding|ClientAliveInterval|MaxAuthTries)' /etc/ssh/sshd_config" ;;
        2) run_cmd "Current SSH sessions" bash -c "who; echo; ss -tnp state established '( sport = :22 )'" ;;
        3) run_cmd "root authorized_keys" bash -c "cat /root/.ssh/authorized_keys 2>/dev/null || echo '(none)'" ;;
        4) run_cmd "MAC status"       mac_status ;;
        5) run_cmd "Firewall zones"   list_fw_zones ;;
        6) run_cmd "fail2ban status"  fail2ban_stat ;;
        7) run_cmd "auditctl rules"   auditctl_rules ;;
        8) run_cmd "PAM audit"        pam_audit ;;
        9) run_cmd "bash_history check" bash_history_check ;;
        10) run_impact_cmd "Restart ${SSHD_SVC}" systemctl restart "${SSHD_SVC}" ;;
        11) read -r -p "pts (e.g. pts/2) > " t
            run_impact_cmd "Kick ${t}" pkill -KILL -t "${t}" ;;
        b|B) exit 0 ;;
        *)   echo "無效選項" ;;
    esac
    pause
done
