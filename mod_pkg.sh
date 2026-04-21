#!/bin/bash
# mod_pkg.sh - 套件 / Repo (含 CVE / yum history / GPG key)
_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_HERE}/LinuxMenu.sh" 2>/dev/null
: "${YEL:=\033[1;33m}"; : "${RED:=\033[0;31m}"; : "${RST:=\033[0m}"
: "${PKG:=yum}"

menu() {
    clear
    echo "======================================================"
    echo " 套件 / Repo (Package)    套件工具: ${PKG}"
    echo "======================================================"
    echo "  1) Repo 清單"
    echo "  2) 可更新之套件"
    echo "  3) 安全更新 (CVE) [RHEL yum --security]"
    echo "  4) 已安裝套件數"
    echo "  5) 查詢特定套件"
    echo "  6) ${PKG} 歷史 (最近 10 次)"
    echo "  7) 已匯入 GPG key 清單"
    echo -e "  8) ${YEL}[變更] 重建套件庫 cache${RST}"
    echo "  b) 返回主選單"
    echo "======================================================"
}

repolist() {
    case "${DISTRO}" in
        debian) apt-cache policy ;;
        *)      yum repolist ;;
    esac
}

updatable() {
    case "${DISTRO}" in
        debian) apt list --upgradable 2>/dev/null ;;
        *)      yum check-update ;;
    esac
}

security_updates() {
    case "${DISTRO}" in
        debian)
            if command -v unattended-upgrades >/dev/null 2>&1; then
                apt-get -s upgrade 2>&1 | grep -i security
            else
                echo "(Debian: 請安裝 unattended-upgrades 以識別 security 更新)"
            fi
            ;;
        *)
            if yum --help 2>&1 | grep -q security; then
                yum --security check-update 2>&1 || true
            else
                echo "(yum-plugin-security 未安裝)"
            fi
            ;;
    esac
}

installed_count() {
    case "${DISTRO}" in
        debian) dpkg-query -f '${binary:Package}\n' -W | wc -l ;;
        *)      rpm -qa | wc -l ;;
    esac
}

query_pkg() {
    case "${DISTRO}" in
        debian) dpkg -s "$1" 2>/dev/null || apt show "$1" ;;
        *)      rpm -qi "$1" ;;
    esac
}

pkg_history() {
    case "${DISTRO}" in
        debian) grep -E 'install |upgrade |remove ' /var/log/dpkg.log 2>/dev/null | tail -20 ;;
        *)      yum history 2>/dev/null | head -12 ;;
    esac
}

gpg_keys() {
    case "${DISTRO}" in
        debian) apt-key list 2>/dev/null | head -40 ;;
        *)      rpm -qa gpg-pubkey --queryformat "%{NAME}-%{VERSION}-%{RELEASE} %{SUMMARY}\n" ;;
    esac
}

rebuild_cache() {
    case "${DISTRO}" in
        debian) apt update ;;
        *)      yum makecache ;;
    esac
}

while true; do
    menu
    read -r -p "選擇 > " c || exit 0
    case "$c" in
        1) run_cmd "Repolist"          repolist ;;
        2) run_cmd "Updatable"         updatable ;;
        3) run_cmd "Security updates"  security_updates ;;
        4) run_cmd "Installed count"   installed_count ;;
        5) read -r -p "套件名 > " p
           run_cmd "Query ${p}"        query_pkg "${p}" ;;
        6) run_cmd "Package history"   pkg_history ;;
        7) run_cmd "GPG keys"          gpg_keys ;;
        8) run_change_cmd "Rebuild package cache" rebuild_cache ;;
        b|B) exit 0 ;;
        *)   echo "無效選項" ;;
    esac
    pause
done
