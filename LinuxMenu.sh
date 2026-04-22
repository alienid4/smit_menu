#!/bin/bash
###############################################################################
# Script Name: LinuxMenu.sh
# Version: lite-v0.2
# Last Update: 2026-04-22
# Description: 金融業 Linux 系統觀察工具 (Lite — 純觀察、無 DB、無 AP)
# Style     : 雙線邊框、call_mod 派遣、CASLOG 環境變數
# Scope lite-v0.2 (新增):
#   [0)  mod_dashboard] 健康儀表板 (40+ 指標, 7 區, 含通知建議)
#        三模式 --fast/default/--full + --simple 淺白 + --json
#        壓力感知自動降級、NFS timeout 保護、缺套件自動降級
#   [18) mod_trading]   股票交易系統特化 (含 pps / RTT / IRQ 分布)
#        需 conf/trading.conf 啟用 (SP 自填，不 auto 產)
#   [19) mod_sfp]       光纖模組 SFP/GBIC 老化監控 (ethtool -m + baseline)
#   [新] compat_check   啟動前偵測 VM / 容器 / 舊 kernel / 衝突 agent
#   [新] banner mini health 進選單一行看健康度
# Scope lite-v0.1: 13 模組純觀察，去 DB/AP
# 適用：純觀察主機、稽核主機、DMZ、合規機 — 變更透過 Ansible 從外部下發
###############################################################################

# --- 環境變數 ---
# CASLOG_BASE 可透過環境變數覆蓋，預設 /CASLog/AI
export CASLOG_BASE="${CASLOG_BASE:-/CASLog/AI}"
export CASLOG_SCRIPT="${CASLOG_BASE}/scripts"
export CASLOG_LOG="${CASLOG_BASE}/logs"
export CASLOG_REPORT="${CASLOG_BASE}/reports"
export CASLOG_CONF="${CASLOG_BASE}/conf"
mkdir -p "${CASLOG_LOG}" "${CASLOG_REPORT}" "${CASLOG_SCRIPT}"

export TODAY="$(date +%Y%m%d)"
export LOG_FILE="${CASLOG_LOG}/LinuxMenu_main_${TODAY}.log"

# T0 合規：若當日 log 尚未存在先建，並設 append-only (tamper-evident)
# 在 xfs / 權限不足情況下靜默略過，不擋流程
if [ ! -f "${LOG_FILE}" ]; then
    touch "${LOG_FILE}" 2>/dev/null && chmod 640 "${LOG_FILE}" 2>/dev/null
fi
if command -v lsattr >/dev/null 2>&1 && [ -f "${LOG_FILE}" ]; then
    if ! lsattr "${LOG_FILE}" 2>/dev/null | awk '{print $1}' | grep -q 'a'; then
        chattr +a "${LOG_FILE}" 2>/dev/null || true
    fi
fi

# --- 色碼 (v1.0 規則：紅=高風險 / 黃=變更 / 其他白) ---
export GRN=''              # 查詢 (純白)
export YEL=$'\033[1;33m'   # 變更
export RED=$'\033[0;31m'   # 高風險
export CYN=''              # 資訊 (純白)
export RST=$'\033[0m'
export NC="${RST}"         # 相容 v1.4

# --- Distro 偵測 (v1.3 強化: /etc/os-release + 細版本) ---
# 產出變數：
#   DISTRO_FAMILY   = rhel / debian / unknown    (舊 code 用 ${DISTRO} 相容，等同 FAMILY)
#   DISTRO_ID       = rhel / centos / rocky / almalinux / fedora / ol / debian / ubuntu / ...
#   DISTRO_VERSION  = 9.7 / 22.04 / 12
#   DISTRO_VERSION_MAJOR = 9 / 22 / 12
#   DISTRO_PRETTY   = "Rocky Linux 9.7 (Blue Onyx)" 之類的顯示字串
distro_detect() {
    local ID="" VERSION_ID="" PRETTY_NAME="" ID_LIKE=""
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        DISTRO_ID="${ID:-unknown}"
        DISTRO_VERSION="${VERSION_ID:-0}"
        DISTRO_PRETTY="${PRETTY_NAME:-${DISTRO_ID} ${DISTRO_VERSION}}"
    elif [ -f /etc/redhat-release ]; then
        DISTRO_ID="rhel"
        DISTRO_VERSION=$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release | head -1)
        DISTRO_VERSION="${DISTRO_VERSION:-0}"
        DISTRO_PRETTY=$(head -1 /etc/redhat-release)
    elif [ -f /etc/debian_version ]; then
        DISTRO_ID="debian"
        DISTRO_VERSION=$(cat /etc/debian_version)
        DISTRO_PRETTY="Debian ${DISTRO_VERSION}"
    else
        DISTRO_ID="unknown"; DISTRO_VERSION="0"; DISTRO_PRETTY="unknown"
    fi
    DISTRO_VERSION_MAJOR="${DISTRO_VERSION%%.*}"
    # 預防 VERSION_ID 格式異常
    case "${DISTRO_VERSION_MAJOR}" in ''|*[!0-9]*) DISTRO_VERSION_MAJOR=0 ;; esac

    # 判斷家族 (用 ID 或 ID_LIKE)
    case "${DISTRO_ID}" in
        rhel|centos|rocky|almalinux|fedora|ol|amzn|oracle)
            DISTRO_FAMILY=rhel ;;
        debian|ubuntu|linuxmint|raspbian|pop|kali)
            DISTRO_FAMILY=debian ;;
        *)
            if echo " ${ID_LIKE} " | grep -qE ' (rhel|fedora|centos) '; then
                DISTRO_FAMILY=rhel
            elif echo " ${ID_LIKE} " | grep -qE ' debian '; then
                DISTRO_FAMILY=debian
            else
                DISTRO_FAMILY=unknown
            fi ;;
    esac

    # 依家族 + 細版本決定預設工具
    case "${DISTRO_FAMILY}" in
        rhel)
            # RHEL 8+ 預設 dnf (yum 是 alias)；RHEL 7/CentOS 7 只有 yum
            if [ "${DISTRO_VERSION_MAJOR}" -ge 8 ] 2>/dev/null; then
                PKG=dnf; PKG_UPDATE="dnf check-update"
            else
                PKG=yum; PKG_UPDATE="yum check-update"
            fi
            AUTHLOG=/var/log/secure
            SYSLOG=/var/log/messages
            SSHD_SVC=sshd; FW=firewall-cmd
            # RHEL 8+ 用 faillock，RHEL 7 用 pam_tally2
            if [ "${DISTRO_VERSION_MAJOR}" -ge 8 ] 2>/dev/null; then
                FAILLOCK=faillock
            else
                FAILLOCK=pam_tally2
            fi
            SECMOD=sestatus
            ;;
        debian)
            PKG=apt; PKG_UPDATE="apt list --upgradable"
            AUTHLOG=/var/log/auth.log
            SYSLOG=/var/log/syslog
            SSHD_SVC=ssh; FW=ufw
            FAILLOCK=pam_tally2
            SECMOD=aa-status
            ;;
        *)  PKG=""; PKG_UPDATE=""; AUTHLOG=""; SYSLOG=""
            SSHD_SVC=""; FW=""; FAILLOCK=""; SECMOD="" ;;
    esac

    # 舊 code 相容：DISTRO 就是 FAMILY
    DISTRO="${DISTRO_FAMILY}"
    export DISTRO DISTRO_FAMILY DISTRO_ID DISTRO_VERSION DISTRO_VERSION_MAJOR DISTRO_PRETTY
    export PKG PKG_UPDATE AUTHLOG SYSLOG SSHD_SVC FW FAILLOCK SECMOD
}
distro_detect

# --- 審計 log ---
# Format: YYYY-MM-DD HH:MM:SS | ITEM | STATUS | DETAIL
audit_log() {
    local item="$1" status="$2" detail="$3"
    printf "%s | %-24s | %-7s | %s\n" \
        "$(date '+%Y-%m-%d %H:%M:%S')" "${item}" "${status}" "${detail}" \
        >> "${LOG_FILE}"
}

# --- 三色執行 wrapper ---
# 綠：查詢（白色顯示）
run_cmd() {
    local desc="$1"; shift
    echo -e "[QUERY] ${desc}"
    echo -e "\$ $*"
    "$@"
    local rc=$?
    audit_log "${desc}" "$([ $rc -eq 0 ] && echo OK || echo FAIL)" "$*"
    return $rc
}

# 黃：設定變更 (按 Enter 確認)
run_change_cmd() {
    local desc="$1"; shift
    echo -e "${YEL}[CHANGE]${RST} ${desc}"
    echo -e "\$ $*"
    read -r -p "變更操作，按 Enter 繼續或 Ctrl+C 取消 > " _
    "$@"
    local rc=$?
    audit_log "${desc}" "$([ $rc -eq 0 ] && echo OK || echo FAIL)" "$*"
    return $rc
}

# 紅：高衝擊 (雙重確認 — 金融業標準防誤觸)
#   1. 輸入 CONFIRM
#   2. 輸入主機名稱 (10 秒 timeout)，防「登錯機敲錯命令」
run_impact_cmd() {
    local desc="$1"; shift
    echo -e "${RED}[IMPACT]${RST} ${desc}"
    echo -e "\$ $*"

    # ---- 第 1 次確認 ----
    echo -e "${RED}── 第 1 次確認 ──${RST}"
    echo -e "${RED}此操作具有高度影響，請輸入 CONFIRM 以繼續：${RST}"
    local t1
    if ! read -r t1; then
        echo -e "${YEL}已取消 (stdin EOF)${RST}"
        audit_log "${desc}" "CANCEL" "1st-confirm EOF"
        return 1
    fi
    if [ "${t1}" != "CONFIRM" ]; then
        echo -e "${YEL}已取消 (第 1 次確認未通過)${RST}"
        audit_log "${desc}" "CANCEL" "1st-confirm fail: ${t1}"
        return 1
    fi

    # ---- 第 2 次確認：打主機名 (防登錯機) ----
    local host; host=$(hostname)
    echo
    echo -e "${RED}── 第 2 次確認 (10 秒內)${RST}"
    echo -e "  主機   : ${host}"
    echo -e "  使用者 : $(whoami)"
    echo -e "  時間   : $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "  指令   : $*"
    echo -e "${RED}請輸入主機名稱 [${host}] 以完成二次確認：${RST}"
    local t2
    if ! read -r -t 10 t2; then
        echo
        echo -e "${YEL}已取消 (10 秒逾時)${RST}"
        audit_log "${desc}" "CANCEL" "2nd-confirm timeout"
        return 1
    fi
    if [ "${t2}" != "${host}" ]; then
        echo -e "${YEL}已取消 (主機名稱不符：'${t2}' != '${host}')${RST}"
        audit_log "${desc}" "CANCEL" "2nd-confirm mismatch: '${t2}' vs '${host}'"
        return 1
    fi

    # ---- 執行 ----
    echo -e "${RED}雙重確認通過，執行中...${RST}"
    "$@"
    local rc=$?
    audit_log "${desc}" "$([ $rc -eq 0 ] && echo OK || echo FAIL)" "$*"
    return $rc
}

# 統一的「繼續」提示：按 Enter 回子選單、q 直接返回主選單、EOF 也離開
pause() {
    local k
    read -r -p "按 Enter 繼續，q 返回主選單 > " k || { echo; exit 0; }
    [ "$k" = "q" ] || [ "$k" = "Q" ] && exit 0
    return 0
}

export -f audit_log run_cmd run_change_cmd run_impact_cmd pause

# --- 子腳本派遣 (承襲 v1.4) ---
call_mod() {
    local mod_file="${CASLOG_SCRIPT}/$1"
    if [[ -f "$mod_file" ]]; then
        bash "$mod_file"
    else
        echo -e "${YEL}[SKIP] Module $1 not found.${RST}"
        sleep 1
    fi
}

# --- 主選單版面 ---
show_menu() {
    clear
    local distro_tag="${DISTRO}"
    [ "${DISTRO}" = "unknown" ] && distro_tag="${RED}unknown${RST}"
    compute_mini_health
    echo "======================================================"
    echo " 金融業 Linux 系統觀察工具  [Lite v0.2] (純觀察版)"
    echo " 主機: $(hostname)   使用者: $(whoami)"
    echo -e " OS: ${DISTRO_PRETTY} (${distro_tag} family)"
    echo "    PKG: ${PKG}   FW: ${FW}   FAILLOCK: ${FAILLOCK}"
    echo "------------------------------------------------------"
    echo " 健康: ${MINI_HEALTH}   詳 → 選 0   時間: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "======================================================"
    echo "   0) 健康儀表板 (40+ 指標, 7 區, 含通知建議)"
    echo "------------------------------------------------------"
    echo " 系統觀察"
    echo "   1) 系統資訊            2) 網路狀態"
    echo "   3) 檔案 & 目錄         4) 程序監控"
    echo "   5) 帳號狀態            6) 日誌 & 稽核"
    echo "   7) 套件清單            8) 儲存狀態"
    echo "   9) 憑證掃描           10) 安全稽核狀態"
    echo "------------------------------------------------------"
    echo " 急救 / 報表"
    echo "  11) 快速自辯 (7 面向, 去 AP/DB) — 非尖峰時段"
    echo "  15) 快速 Triage (3 項系統指標, <1 秒) — 交易期間"
    echo "  12) 每日巡檢報表產生器"
    echo "------------------------------------------------------"
    echo " 輔助"
    echo "  14) 工具盤點"
    echo "  16) Baseline 管理 (開盤前快照 + diff)"
    echo "  17) 審計封存與驗證 (T0 合規, append-only + HMAC)"
    echo "  18) 交易系統指標 (股票交易專用, 需 trading.conf)"
    echo "  19) 光纖模組 SFP/GBIC 老化監控"
    echo "------------------------------------------------------"
    echo " q) 離開"
    echo "======================================================"
    if [ "${DISTRO}" = "unknown" ]; then
        echo -e "${YEL}警告: distro 未知，變更類指令可能失敗，建議僅使用查詢類。${RST}"
    fi
}

main() {
    audit_log "LinuxMenu" "START" "session opened by $(whoami) on ${DISTRO}"
    while true; do
        show_menu
        read -r -p "請選擇項目 > " choice || { echo; audit_log "LinuxMenu" "END" "stdin EOF"; exit 0; }
        case "${choice}" in
            0)  call_mod "mod_dashboard.sh" ;;     # 健康儀表板 (lite-v0.2 新)
            1)  call_mod "mod_system.sh"   ;;
            2)  call_mod "mod_network.sh"  ;;
            3)  call_mod "mod_file.sh"     ;;
            4)  call_mod "mod_process.sh"  ;;
            5)  call_mod "mod_user.sh"     ;;
            6)  call_mod "mod_audit.sh"    ;;
            7)  call_mod "mod_pkg.sh"      ;;
            8)  call_mod "mod_storage.sh"  ;;
            9)  call_mod "mod_cert.sh"        ;;  # lite: 憑證掃描 (原 mod_java)
            10) call_mod "mod_security.sh"    ;;
            11) call_mod "mod_troubleshoot.sh" ;;  # lite: 7 面向 (去 AP/DB)
            12) call_mod "mod_daily.sh"       ;;
            # 13) mod_db.sh — lite 版已移除
            14) call_mod "mod_tooling.sh"      ;;
            15) call_mod "mod_triage.sh"       ;;  # lite: 3 項系統指標
            16) call_mod "mod_baseline.sh"     ;;
            17) call_mod "mod_audit_seal.sh"   ;;
            18) call_mod "mod_trading.sh"      ;;  # lite-v0.2 新 (需 trading.conf)
            19) call_mod "mod_sfp.sh"          ;;  # lite-v0.2 新 SFP 監控
            q|Q)
                audit_log "LinuxMenu" "END" "session closed"
                echo "再見。"
                exit 0
                ;;
            *)  echo -e "${YEL}無效選項，請重新輸入。${RST}"; sleep 1 ;;
        esac
        read -r -p "按 Enter 返回主選單..." _
    done
}

# ---- lite-v0.2 compat_check：啟動前相容性檢查 ----
compat_check() {
    local blockers=()
    local warnings=()
    local infos=()

    # bash >= 4
    if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
        blockers+=("bash ${BASH_VERSION} < 4.0 — associative array 不可用")
    fi

    # kernel >= 3.10
    local kmajor kminor
    kmajor=$(uname -r | cut -d. -f1)
    kminor=$(uname -r | cut -d. -f2)
    if [ "${kmajor:-0}" -lt 3 ] || { [ "${kmajor}" = "3" ] && [ "${kminor:-0}" -lt 10 ]; }; then
        blockers+=("kernel ${kmajor}.${kminor} 過舊 (< 3.10)，多數 /proc 功能不存在")
    fi

    # BusyBox / Alpine
    if [ -f /etc/alpine-release ]; then
        blockers+=("偵測到 Alpine Linux — BusyBox 指令不完整，本工具多數功能會壞")
    fi

    # 容器環境
    if [ -f /.dockerenv ]; then
        warnings+=("Docker 容器 (/.dockerenv) — 本工具為主機層設計，容器內指標會失真")
    elif grep -qE 'kubepods|containerd|docker|lxc' /proc/1/cgroup 2>/dev/null; then
        warnings+=("容器 cgroup 偵測到 — 建議改用 kubectl top / 或到宿主機執行")
    fi

    # 衝突 / 併存 agent (資訊性)
    for svc in wazuh-agent zabbix-agent datadog-agent telegraf node_exporter; do
        if systemctl is-active "$svc" 2>/dev/null | grep -qx active; then
            infos+=("偵測到 ${svc} 運行中 — 監控層重複，本工具僅作 SP 手動診斷，可併存")
        fi
    done

    # K8s node
    if systemctl is-active kubelet 2>/dev/null | grep -qx active; then
        infos+=("K8s worker node — node 層指標可信；業務 Pod 請用 kubectl")
    fi

    # 未知 distro
    if [ "${DISTRO_FAMILY:-unknown}" = "unknown" ]; then
        warnings+=("無法識別 distro 家族 — 指令對應可能失敗")
    fi

    # 關鍵 GNU 工具
    for t in ss ip systemctl journalctl awk; do
        if ! command -v "$t" >/dev/null 2>&1; then
            blockers+=("缺指令: ${t} (核心依賴)")
        fi
    done

    if [ ${#blockers[@]} -gt 0 ] || [ ${#warnings[@]} -gt 0 ] || [ ${#infos[@]} -gt 0 ]; then
        echo "=========================================="
        echo " 相容性檢查"
        echo "=========================================="
        for b in "${blockers[@]}"; do echo "  ❌ ${b}"; done
        for w in "${warnings[@]}"; do echo -e "  ${YEL}⚠️  ${w}${RST}"; done
        for i in "${infos[@]}"; do echo "  ℹ️  ${i}"; done
        echo "=========================================="

        if [ ${#blockers[@]} -gt 0 ]; then
            echo -e "${RED} 有 ❌ 項目，無法執行。${RST}"
            exit 2
        fi
        if [ ${#warnings[@]} -gt 0 ]; then
            echo " 繼續執行？(y/N, 5 秒預設 N 自動退出)"
            local yn
            if ! read -r -t 5 yn; then
                echo; echo " [超時] 已取消"; exit 0
            fi
            [ "${yn}" != "y" ] && [ "${yn}" != "Y" ] && exit 0
        fi
    fi
}

# ---- lite-v0.2 mini health：進主選單前算一行健康摘要 ----
MINI_HEALTH=""
compute_mini_health() {
    # 快速指標 (全部 /proc 讀，不取樣，~50ms)
    local cores load1 swap mem_g disk_max
    cores=$(nproc 2>/dev/null || echo 1)
    load1=$(awk '{print $1}' /proc/loadavg)
    swap=$(awk '/^Swap(Total|Free):/{v[$1]=$2} END{t=v["SwapTotal:"]; f=v["SwapFree:"]; if(t>0)printf "%d",((t-f)/t)*100; else print 0}' /proc/meminfo)
    mem_g=$(awk '/^MemAvailable:/{printf "%.1f", $2/1048576}' /proc/meminfo)
    disk_max=$(timeout 2 df -hP 2>/dev/null | awk 'NR>1 && $6!~/^\/(dev|proc|sys|run)/ {gsub(/%/,"",$5); if($5+0>m) m=$5+0} END{print m+0}')

    local pass=0 warn=0 fail=0
    # load
    awk -v l="${load1}" -v c="${cores}" 'BEGIN{exit !(l>=c*4)}' && fail=$((fail+1)) || {
        awk -v l="${load1}" -v c="${cores}" 'BEGIN{exit !(l>=c*2)}' && warn=$((warn+1)) || pass=$((pass+1))
    }
    # mem
    awk -v m="${mem_g}" 'BEGIN{exit !(m<0.3)}' && fail=$((fail+1)) || {
        awk -v m="${mem_g}" 'BEGIN{exit !(m<1.0)}' && warn=$((warn+1)) || pass=$((pass+1))
    }
    # disk
    [ "${disk_max:-0}" -ge 95 ] && fail=$((fail+1)) || {
        [ "${disk_max:-0}" -ge 80 ] && warn=$((warn+1)) || pass=$((pass+1))
    }
    # swap
    [ "${swap:-0}" -ge 50 ] && fail=$((fail+1)) || {
        [ "${swap:-0}" -ge 10 ] && warn=$((warn+1)) || pass=$((pass+1))
    }
    # systemd failed
    local failed_svc
    failed_svc=$(systemctl --failed --no-legend 2>/dev/null | wc -l)
    [ "${failed_svc}" -gt 3 ] && fail=$((fail+1)) || {
        [ "${failed_svc}" -gt 0 ] && warn=$((warn+1)) || pass=$((pass+1))
    }

    local emoji="🟢" label="正常"
    [ "${warn}" -gt 0 ] && emoji="🟡" && label="需注意"
    [ "${fail}" -gt 0 ] && emoji="🔴" && label="異常"
    MINI_HEALTH="${emoji} ${label} (${fail}F/${warn}W/${pass}P)"
}

# 只有直接執行時才跑 main；被 source 時僅匯入函式與變數。
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    compat_check
    main "$@"
fi
