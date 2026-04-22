#!/bin/bash
# mod_daily.sh - 每日巡檢報表產生器 (含 CVE / 憑證到期 / 帳號變動)
_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_HERE}/LinuxMenu.sh" 2>/dev/null
: "${YEL:=\033[1;33m}"; : "${RED:=\033[0;31m}"; : "${RST:=\033[0m}"
: "${AUTHLOG:=/var/log/secure}"
: "${SYSLOG:=/var/log/messages}"

REPORT_DIR="${CASLOG_REPORT}"
TS="$(date '+%Y%m%d_%H%M%S')"
REPORT="${REPORT_DIR}/daily_$(hostname)_${TS}.txt"
mkdir -p "${REPORT_DIR}"

section() {
    echo ""                                            >> "${REPORT}"
    echo "============================================" >> "${REPORT}"
    echo "  $1"                                        >> "${REPORT}"
    echo "============================================" >> "${REPORT}"
}

run_block() {
    local title="$1"; shift
    section "${title}"
    "$@" >> "${REPORT}" 2>&1
}

firewall_snapshot() {
    case "${DISTRO}" in
        debian) ufw status verbose 2>/dev/null ;;
        *)      firewall-cmd --state 2>/dev/null
                firewall-cmd --list-all 2>/dev/null ;;
    esac
}

mac_snapshot() {
    case "${DISTRO}" in
        debian) aa-status 2>/dev/null || echo "AppArmor not installed" ;;
        *)      sestatus 2>/dev/null || echo "SELinux not installed" ;;
    esac
}

cert_expiry_summary() {
    local defks="${JAVA_HOME:-/usr/lib/jvm/default}/lib/security/cacerts"
    if command -v keytool >/dev/null 2>&1 && [ -f "${defks}" ]; then
        keytool -list -v -keystore "${defks}" -storepass changeit 2>/dev/null \
        | awk '
            /Alias name/    {alias=$3}
            /Valid from/    {
                sub(/.*until: /,""); exp=$0
                cmd="date -d \""exp"\" +%s"; cmd | getline exp_ts; close(cmd)
                now=systime(); days=int((exp_ts-now)/86400)
                if (days<30) printf "  %-30s  %5d days  %s\n", alias, days, (days<0?"EXPIRED":"WARN")
            }'
    else
        echo "(keytool 或 cacerts 不可用)"
    fi
}

recent_account_changes() {
    find /etc/passwd /etc/shadow /etc/group -mtime -7 \
         -printf "  %TY-%Tm-%Td %TH:%TM  %p\n" 2>/dev/null
    echo
    echo "近 7 日登入失敗次數 (lastb):"
    lastb 2>/dev/null | awk -v cutoff=$(date -d '7 days ago' +%s) '
        NR==1 {next}
        {
            cmd="date -d \""$4" "$5" "$6" "$7" "$9"\" +%s 2>/dev/null"
            cmd | getline ts; close(cmd)
            if (ts >= cutoff) c++
        }
        END {print "  count:", c+0}
    '
}

cve_summary() {
    case "${DISTRO}" in
        debian)
            if command -v apt-get >/dev/null; then
                apt-get -s upgrade 2>&1 | grep -ic security | xargs echo "security packages count:"
            fi
            ;;
        *)
            if yum --help 2>&1 | grep -q security; then
                yum --security check-update 2>&1 | tail -20
            else
                echo "(yum-plugin-security 未安裝)"
            fi
            ;;
    esac
}

generate() {
    : > "${REPORT}"
    {
        echo "Linux Daily Health Report"
        echo "Host     : $(hostname)"
        echo "Distro   : ${DISTRO}"
        echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Operator : $(whoami)"
        echo "Spec     : 金融業 Linux 維運工具 v1.0"
    } >> "${REPORT}"

    run_block "1. System"           bash -c "uname -a; uptime; timedatectl | head"
    run_block "2. CPU / MEM"        bash -c "lscpu | head; echo; free -h"
    run_block "3. Disk"             df -hP
    run_block "4. Inode"            df -i
    run_block "5. LVM"              bash -c "pvs 2>/dev/null; echo; vgs 2>/dev/null; echo; lvs 2>/dev/null"
    run_block "6. Top CPU"          bash -c "ps -eo pid,user,%cpu,%mem,comm --sort=-%cpu | head -n 11"
    run_block "7. Top MEM"          bash -c "ps -eo pid,user,%cpu,%mem,comm --sort=-%mem | head -n 11"
    run_block "8. Network"          bash -c "ip -br a; echo; ip route; echo; ss -tnlp | head -n 20"
    run_block "9. User audit"       bash -c "last -n 10; echo; lastb -n 10 2>/dev/null"
    run_block "10. Auth errors"     bash -c "grep -Ei 'fail|invalid' \"${AUTHLOG}\" 2>/dev/null | tail -n 20"
    run_block "11. Sys errors"      bash -c "grep -Ei 'error|critical' \"${SYSLOG}\" 2>/dev/null | tail -n 20"
    run_block "12. Java"            bash -c "java -version 2>&1; echo; ps -eo pid,user,args | grep -i [j]ava"
    run_block "13. Services"        bash -c "systemctl --failed"
    run_block "14. Firewall"        firewall_snapshot
    run_block "15. MAC"             mac_snapshot

    section "16. 憑證到期警示 (30 天內)"
    cert_expiry_summary              >> "${REPORT}"
    section "17. 近 7 日帳號變動"
    recent_account_changes           >> "${REPORT}"
    section "18. 安全更新 (CVE) 摘要"
    cve_summary                      >> "${REPORT}"

    section "Summary"
    {
        disk_warn=$(df -hP | awk 'NR>1 && int($5)>=80 {print}' | wc -l)
        failed=$(systemctl --failed --no-legend | wc -l)
        auth_fail=$(grep -Eci 'fail|invalid' "${AUTHLOG}" 2>/dev/null || echo 0)
        echo "Filesystems >=80% : ${disk_warn}"
        echo "Failed services   : ${failed}"
        echo "Auth failures     : ${auth_fail}"
        echo "Report file       : ${REPORT}"
    } >> "${REPORT}"
}

echo "正在產生每日巡檢報表..."
run_cmd "Daily report generation" generate
echo "報表已輸出: ${REPORT}"
echo
echo "── 報表摘要 ────────────────────────────"
tail -n 30 "${REPORT}"
