#!/bin/bash
# mod_network.sh - 網路診斷 (含 bonding / DNS / ARP / 防火牆 CRUD)
_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_HERE}/LinuxMenu.sh" 2>/dev/null
: "${YEL:=\033[1;33m}"; : "${RED:=\033[0;31m}"; : "${RST:=\033[0m}"
: "${FW:=firewall-cmd}"

# =============================================================================
# 基礎查詢函式
# =============================================================================
bonding_status() {
    if ls /proc/net/bonding/ 2>/dev/null | grep -q .; then
        for b in /proc/net/bonding/*; do
            echo "── $(basename "$b") ──"
            cat "$b"
        done
    else
        echo "(無 bonding interface)"
    fi
    echo
    if command -v teamdctl >/dev/null 2>&1; then
        for t in $(teamnl list 2>/dev/null); do
            echo "── team: $t ──"; teamdctl "$t" state
        done
    fi
}

dns_info() {
    echo "-- /etc/resolv.conf --"
    cat /etc/resolv.conf 2>/dev/null
    echo
    if command -v resolvectl >/dev/null 2>&1; then
        echo "-- resolvectl status --"
        resolvectl status 2>/dev/null | head -30
    fi
}

fw_rules() {
    if command -v nft >/dev/null 2>&1; then
        echo "-- nftables --"
        nft list ruleset 2>/dev/null | head -40
        echo
    fi
    if command -v iptables >/dev/null 2>&1; then
        echo "-- iptables -L -n -v --line-numbers --"
        iptables -L -n -v --line-numbers 2>/dev/null | head -40
    fi
}

# =============================================================================
# 防火牆 CRUD (跨 distro 封裝)
# =============================================================================
fw_list() {
    case "${DISTRO}" in
        debian)
            echo "-- ufw status --"
            ufw status verbose 2>/dev/null
            echo
            echo "-- 編號規則 --"
            ufw status numbered 2>/dev/null
            ;;
        *)
            echo "-- firewall-cmd --list-all --"
            firewall-cmd --list-all 2>/dev/null
            echo
            echo "-- 所有 zones 摘要 --"
            firewall-cmd --get-active-zones 2>/dev/null
            ;;
    esac
}

fw_add_port() {
    local port="$1" proto="$2"
    case "${DISTRO}" in
        debian) ufw allow "${port}/${proto}" ;;
        *)      firewall-cmd --add-port="${port}/${proto}" --permanent \
                  && firewall-cmd --reload ;;
    esac
}

fw_remove_port() {
    local port="$1" proto="$2"
    case "${DISTRO}" in
        debian) ufw delete allow "${port}/${proto}" ;;
        *)      firewall-cmd --remove-port="${port}/${proto}" --permanent \
                  && firewall-cmd --reload ;;
    esac
}

fw_add_service() {
    local svc="$1"
    case "${DISTRO}" in
        debian) ufw allow "${svc}" ;;
        *)      firewall-cmd --add-service="${svc}" --permanent \
                  && firewall-cmd --reload ;;
    esac
}

fw_remove_service() {
    local svc="$1"
    case "${DISTRO}" in
        debian) ufw delete allow "${svc}" ;;
        *)      firewall-cmd --remove-service="${svc}" --permanent \
                  && firewall-cmd --reload ;;
    esac
}

fw_reload() {
    case "${DISTRO}" in
        debian) ufw reload ;;
        *)      firewall-cmd --reload ;;
    esac
}

fw_runtime_to_perm() {
    case "${DISTRO}" in
        debian) echo "(ufw 無 runtime/permanent 區分，變更即寫入)" ;;
        *)      firewall-cmd --runtime-to-permanent ;;
    esac
}

# =============================================================================
# 防火牆管理子選單
# =============================================================================
firewall_menu() {
    while true; do
        clear
        echo "======================================================"
        echo " 防火牆管理 (${FW})"
        echo "======================================================"
        echo "  1) 列出當前規則 (ports / services / zones)"
        echo -e "  2) ${YEL}[變更] 新增 port${RST}"
        echo -e "  3) ${YEL}[變更] 刪除 port${RST}"
        echo -e "  4) ${YEL}[變更] 新增 service (http/https/ssh/...)${RST}"
        echo -e "  5) ${YEL}[變更] 刪除 service${RST}"
        echo -e "  6) ${YEL}[變更] Reload 防火牆${RST}"
        echo -e "  7) ${YEL}[變更] Runtime → Permanent (RHEL only)${RST}"
        echo "  b) 返回上層"
        echo "======================================================"
        read -r -p "選擇 > " c || exit 0
        case "$c" in
            1) run_cmd "Firewall list" fw_list ;;
            2) read -r -p "Port 號 > " p
               read -r -p "Protocol [tcp / udp] (預設 tcp) > " pr
               pr="${pr:-tcp}"
               run_change_cmd "FW add ${p}/${pr}" fw_add_port "${p}" "${pr}" ;;
            3) read -r -p "Port 號 > " p
               read -r -p "Protocol [tcp / udp] (預設 tcp) > " pr
               pr="${pr:-tcp}"
               run_change_cmd "FW remove ${p}/${pr}" fw_remove_port "${p}" "${pr}" ;;
            4) read -r -p "Service 名稱 (e.g. http / https / ssh) > " s
               run_change_cmd "FW add service ${s}" fw_add_service "${s}" ;;
            5) read -r -p "Service 名稱 > " s
               run_change_cmd "FW remove service ${s}" fw_remove_service "${s}" ;;
            6) run_change_cmd "FW reload" fw_reload ;;
            7) run_change_cmd "FW runtime→permanent" fw_runtime_to_perm ;;
            b|B) return 0 ;;
            *)   echo "無效選項" ;;
        esac
        pause
    done
}

# =============================================================================
# 主選單
# =============================================================================
menu() {
    clear
    echo "======================================================"
    echo " 網路診斷 (Network)    防火牆: ${FW}"
    echo "======================================================"
    echo "  1) IP 位址 (ip a)"
    echo "  2) 路由表 (ip route)"
    echo "  3) 監聽埠 (ss -tnlp)"
    echo "  4) Ping 測試 (5 次)"
    echo "  5) Bonding / Teaming 狀態"
    echo "  6) DNS 解析器設定"
    echo "  7) ARP 快取表"
    echo "  8) iptables / nftables 規則"
    echo -e "  9) ${YEL}[變更] 防火牆管理 (列出/新增/刪除/reload)${RST}"
    echo "  b) 返回主選單"
    echo "======================================================"
}

while true; do
    menu
    read -r -p "選擇 > " c || exit 0
    case "$c" in
        1) run_cmd "IP address"      ip a ;;
        2) run_cmd "Routing table"   ip route ;;
        3) run_cmd "Listening ports" ss -tnlp ;;
        4) read -r -p "目標主機 > " h
           run_cmd "Ping ${h}"       ping -c 5 "${h}" ;;
        5) run_cmd "Bonding/Teaming" bonding_status ;;
        6) run_cmd "DNS resolver"    dns_info ;;
        7) run_cmd "ARP cache"       ip neigh ;;
        8) run_cmd "Firewall rules"  fw_rules ;;
        9) firewall_menu; continue ;;   # 進子選單，返回後不需要再 pause
        b|B) exit 0 ;;
        *)   echo "無效選項" ;;
    esac
    pause
done
