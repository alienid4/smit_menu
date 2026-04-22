#!/bin/bash
# mod_tooling.sh - 工具盤點：列出本機裝了哪些巡檢用工具、缺哪些
#                   提供 RHEL / Debian 的安裝指令建議
# 金融業用途：走變更申請前先盤點，一次提交一份清單。
_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_HERE}/LinuxMenu.sh" 2>/dev/null
: "${YEL:=\033[1;33m}"; : "${RED:=\033[0;31m}"; : "${RST:=\033[0m}"

# =============================================================================
# 工具清單
# 格式:  CMD|RHEL_PKG|DEB_PKG|用途|必備度  (必備度: CORE / RECOMMEND / OPTIONAL)
# =============================================================================
TOOLS=(
    # --- CORE 一般預設都有，但精簡版可能缺 ---
    "ss|iproute|iproute2|網路 socket 狀態 (ss -tnlp)|CORE"
    "ip|iproute|iproute2|網路設定與路由|CORE"
    "ping|iputils|iputils-ping|ICMP 連通測試|CORE"
    "systemctl|systemd|systemd|服務管理|CORE"
    "journalctl|systemd|systemd|系統日誌查詢|CORE"
    "dmesg|util-linux|util-linux|核心環形緩衝|CORE"
    "last|util-linux|util-linux|登入紀錄|CORE"
    "who|coreutils|coreutils|當前登入 session|CORE"
    "awk|gawk|gawk|文字處理|CORE"
    "find|findutils|findutils|檔案搜尋|CORE"

    # --- RECOMMEND: troubleshoot 用到、沒裝會退化 ---
    "iostat|sysstat|sysstat|磁碟/CPU I/O (含 await/%util)|RECOMMEND"
    "sar|sysstat|sysstat|歷史效能資料|RECOMMEND"
    "pidstat|sysstat|sysstat|每 PID 資源統計|RECOMMEND"
    "lsof|lsof|lsof|FD/port 細查|RECOMMEND"
    "ethtool|ethtool|ethtool|網卡速率/ring/duplex|RECOMMEND"
    "nc|nmap-ncat|netcat-openbsd|TCP port 連通測試|RECOMMEND"
    "ncat|nmap-ncat|ncat|(同 nc)|RECOMMEND"
    "pstree|psmisc|psmisc|Process tree 視覺化|RECOMMEND"
    "chronyc|chrony|chrony|NTP 狀態查詢|RECOMMEND"
    "arping|iputils|iputils-arping|IP 衝突偵測|RECOMMEND"
    "nstat|iproute|iproute2|kernel 網路計數|RECOMMEND"

    # --- 安全/稽核 ---
    "auditctl|audit|auditd|auditd 規則管理|RECOMMEND"
    "ausearch|audit|auditd|auditd 事件查詢|RECOMMEND"
    "fail2ban-client|fail2ban|fail2ban|暴力登入防護|RECOMMEND"
    "sestatus|policycoreutils|selinux-basics|SELinux 狀態 (RHEL)|RECOMMEND"
    "aa-status|apparmor-utils|apparmor-utils|AppArmor 狀態 (Debian)|RECOMMEND"

    # --- 硬體 / kernel ---
    "dmidecode|dmidecode|dmidecode|BIOS / HW 資訊|RECOMMEND"
    "mcelog|mcelog|mcelog|記憶體 ECC 錯誤分析|OPTIONAL"
    "smartctl|smartmontools|smartmontools|磁碟 SMART|OPTIONAL"
    "lsblk|util-linux|util-linux|區塊裝置清單|CORE"

    # --- Java (金融業重要) ---
    "java|java-17-openjdk|openjdk-17-jre|Java 執行環境|RECOMMEND"
    "keytool|java-17-openjdk|openjdk-17-jre|keystore 管理|RECOMMEND"
    "jstat|java-17-openjdk-devel|openjdk-17-jdk|GC 統計 (P1 Troubleshoot 需要)|OPTIONAL"
    "jstack|java-17-openjdk-devel|openjdk-17-jdk|Thread dump|OPTIONAL"
    "jmap|java-17-openjdk-devel|openjdk-17-jdk|Heap dump|OPTIONAL"

    # --- DB clients (視部署選配) ---
    "sqlplus|oracle-instantclient-sqlplus|-|Oracle client|OPTIONAL"
    "sqlcmd|mssql-tools|mssql-tools|MSSQL client|OPTIONAL"
    "mysql|mariadb|mariadb-client|MySQL/MariaDB client|OPTIONAL"
    "psql|postgresql|postgresql-client|PostgreSQL client|OPTIONAL"
    "db2|ibm-db2-client|ibm-db2-client|DB2 client|OPTIONAL"
    "mongosh|mongodb-mongosh|mongodb-mongosh|MongoDB shell v2|OPTIONAL"
)

# =============================================================================
# 輸出
# =============================================================================
report() {
    local show_level="$1"   # all / missing / core
    local ok=0 missing=0 total=0
    local distro_pkg_col="RHEL package"
    [ "${DISTRO}" = "debian" ] && distro_pkg_col="Debian package"

    printf "%-20s %-8s %-30s %s\n" "Command" "Status" "${distro_pkg_col}" "用途"
    printf "%-20s %-8s %-30s %s\n" "-------" "------" "$(printf '%.0s-' {1..30})" "----"

    local miss_rhel=() miss_deb=()

    for item in "${TOOLS[@]}"; do
        IFS='|' read -r cmd rhel_pkg deb_pkg desc level <<<"${item}"
        total=$((total+1))
        local pkg
        if [ "${DISTRO}" = "debian" ]; then pkg="${deb_pkg}"; else pkg="${rhel_pkg}"; fi

        local installed="✗" color="${RED}"
        if command -v "${cmd}" >/dev/null 2>&1; then
            installed="✓"; color=""
            ok=$((ok+1))
        else
            missing=$((missing+1))
            [ "${level}" != "OPTIONAL" ] && {
                miss_rhel+=("${rhel_pkg}")
                miss_deb+=("${deb_pkg}")
            }
        fi

        # 過濾
        case "${show_level}" in
            missing) [ "${installed}" = "✓" ] && continue ;;
            core)    [ "${level}" != "CORE" ] && continue ;;
        esac

        printf "%-20s ${color}%-8s${RST} %-30s [%s] %s\n" \
            "${cmd}" "${installed}" "${pkg:--}" "${level}" "${desc}"
    done

    echo
    printf "總計: %d，已裝: %d，未裝: %d\n" "${total}" "${ok}" "${missing}"

    # 去重後輸出安裝指令
    if [ "${#miss_rhel[@]}" -gt 0 ]; then
        echo
        echo "── 建議安裝指令 (排除 OPTIONAL) ──"
        if [ "${DISTRO}" = "debian" ]; then
            local uniq_pkgs
            uniq_pkgs=$(printf "%s\n" "${miss_deb[@]}" | grep -v '^-$' | sort -u | tr '\n' ' ')
            [ -n "${uniq_pkgs}" ] && echo "  sudo apt-get install -y ${uniq_pkgs}"
        else
            local uniq_pkgs
            uniq_pkgs=$(printf "%s\n" "${miss_rhel[@]}" | grep -v '^-$' | sort -u | tr '\n' ' ')
            [ -n "${uniq_pkgs}" ] && echo "  sudo dnf install -y ${uniq_pkgs}"
            [ -n "${uniq_pkgs}" ] && echo "  (RHEL 7/CentOS 7: sudo yum install -y ${uniq_pkgs})"
        fi
    fi
}

export_csv() {
    local csv="${CASLOG_REPORT}/tooling_$(hostname)_$(date +%Y%m%d_%H%M%S).csv"
    {
        echo "cmd,installed,rhel_pkg,deb_pkg,level,desc"
        for item in "${TOOLS[@]}"; do
            IFS='|' read -r cmd rhel_pkg deb_pkg desc level <<<"${item}"
            local inst="no"
            command -v "${cmd}" >/dev/null 2>&1 && inst="yes"
            printf '"%s","%s","%s","%s","%s","%s"\n' \
                "${cmd}" "${inst}" "${rhel_pkg}" "${deb_pkg}" "${level}" "${desc}"
        done
    } > "${csv}"
    echo "CSV 已輸出: ${csv}"
    audit_log "Tooling audit CSV" "OK" "${csv}"
}

menu() {
    clear
    echo "======================================================"
    echo " 工具盤點 (Tooling Audit)    Distro: ${DISTRO}"
    echo "======================================================"
    echo "  1) 顯示全部 (含已安裝)"
    echo "  2) 只顯示缺少的"
    echo "  3) 只顯示 CORE 等級"
    echo "  4) 匯出 CSV (給採購/變更申請用)"
    echo "  b) 返回主選單"
    echo "======================================================"
}

while true; do
    menu
    read -r -p "選擇 > " c || exit 0
    case "$c" in
        1) run_cmd "Tooling audit (all)"     report all ;;
        2) run_cmd "Tooling audit (missing)" report missing ;;
        3) run_cmd "Tooling audit (core)"    report core ;;
        4) run_cmd "Tooling audit CSV export" export_csv ;;
        b|B) exit 0 ;;
        *)   echo "無效選項" ;;
    esac
    pause
done
