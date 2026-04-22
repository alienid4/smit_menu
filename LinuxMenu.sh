#!/bin/bash
###############################################################################
# Script Name: LinuxMenu.sh
# Version: v1.2
# Last Update: 2026-04-22
# Description: 金融業 Linux 維運工具 主選單 (Main Controller)
# Style     : 雙線邊框、call_mod 派遣、CASLOG 環境變數
# Scope v1.2: 三色 wrapper、audit log、跨 distro (RHEL/Debian)、17 個子模組
#             + T0 合規 (append-only + HMAC) + baseline + triage + tooling
#             預設根路徑 /CASLog/AI (可由 CASLOG_BASE env 覆蓋)
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

# --- Distro 偵測 ---
distro_detect() {
    if   [ -f /etc/redhat-release ]; then DISTRO=rhel
    elif [ -f /etc/debian_version ]; then DISTRO=debian
    else DISTRO=unknown; fi
    case "${DISTRO}" in
        rhel)
            PKG=yum;           PKG_UPDATE="yum check-update"
            AUTHLOG=/var/log/secure
            SYSLOG=/var/log/messages
            SSHD_SVC=sshd;     FW=firewall-cmd
            FAILLOCK=faillock; SECMOD=sestatus
            ;;
        debian)
            PKG=apt;           PKG_UPDATE="apt list --upgradable"
            AUTHLOG=/var/log/auth.log
            SYSLOG=/var/log/syslog
            SSHD_SVC=ssh;      FW=ufw
            FAILLOCK=pam_tally2; SECMOD=aa-status
            ;;
        *)  PKG=""; PKG_UPDATE=""; AUTHLOG=""; SYSLOG=""
            SSHD_SVC=""; FW=""; FAILLOCK=""; SECMOD="" ;;
    esac
    export DISTRO PKG PKG_UPDATE AUTHLOG SYSLOG SSHD_SVC FW FAILLOCK SECMOD
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

# 紅：高衝擊 (需輸入 CONFIRM)
run_impact_cmd() {
    local desc="$1"; shift
    echo -e "${RED}[IMPACT]${RST} ${desc}"
    echo -e "\$ $*"
    echo -e "${RED}此操作具有高度影響，請輸入 CONFIRM 以繼續：${RST}"
    read -r typed
    if [ "${typed}" != "CONFIRM" ]; then
        echo -e "${YEL}已取消。${RST}"
        audit_log "${desc}" "CANCEL" "user declined"
        return 1
    fi
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
    echo "======================================================"
    echo " 金融業 Linux 維運工具  [Version: v1.2]"
    echo " 主機: $(hostname)   使用者: $(whoami)"
    echo -e " OS: ${distro_tag}   時間: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "======================================================"
    echo " 查詢類"
    echo "   1) 系統資訊            2) 網路診斷"
    echo "   3) 檔案 & 目錄         4) 程序監控"
    echo "   6) 日誌 & 稽核         7) 套件 / Repo"
    echo "   8) 儲存 & 備份"
    echo "------------------------------------------------------"
    echo -e " 變更類 (${YEL}黃=變更${RST} / ${RED}紅=高風險${RST})"
    echo -e "   5) ${YEL}帳號 & 權限${RST}         9) ${RED}Java & 憑證 (Impact)${RST}"
    echo -e "  10) ${RED}安全稽核 (Impact)${RST}"
    echo "------------------------------------------------------"
    echo " 報表 / 急救"
    echo "  11) 快速自辯 (Troubleshoot) — 非尖峰時段、客訴「慢/連不進去」"
    echo "  15) 快速 Triage (<1 秒) — 交易期間 / 系統 freeze 時"
    echo "  12) 每日巡檢報表產生器"
    echo "  13) DB 健康檢查 (Oracle/MSSQL/MySQL/DB2/PG/Mongo)"
    echo "------------------------------------------------------"
    echo " 輔助"
    echo "  14) 工具盤點 (哪些套件已裝、缺哪些、給變更申請用)"
    echo "  16) Baseline 管理 (開盤前快照 + diff，抓「今天跟平日不一樣」)"
    echo "  17) 審計封存與驗證 (T0 合規, append-only + HMAC)"
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
            1)  call_mod "mod_system.sh"   ;;
            2)  call_mod "mod_network.sh"  ;;
            3)  call_mod "mod_file.sh"     ;;
            4)  call_mod "mod_process.sh"  ;;
            5)  call_mod "mod_user.sh"     ;;
            6)  call_mod "mod_audit.sh"    ;;
            7)  call_mod "mod_pkg.sh"      ;;
            8)  call_mod "mod_storage.sh"  ;;
            9)  call_mod "mod_java.sh"     ;;
            10) call_mod "mod_security.sh"    ;;
            11) call_mod "mod_troubleshoot.sh" ;;
            12) call_mod "mod_daily.sh"       ;;
            13) call_mod "mod_db.sh"           ;;
            14) call_mod "mod_tooling.sh"      ;;
            15) call_mod "mod_triage.sh"       ;;
            16) call_mod "mod_baseline.sh"     ;;
            17) call_mod "mod_audit_seal.sh"   ;;
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

# 只有直接執行時才跑 main；被 source 時僅匯入函式與變數。
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
