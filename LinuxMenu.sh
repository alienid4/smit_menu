#!/bin/bash
###############################################################################
# Script Name: LinuxMenu.sh
# Version    : v1.8
# Build Time : 2026-04-23 08:20:00   (git commit 時刻，由 release 人寫死)
# Deploy Time: <UNSET>                (部署時由 install.sh 或 scp hook sed 寫入)
# Description: 金融業 Linux 維運工具 主選單 (Main Controller)
# Style      : 雙線邊框、call_mod 派遣、CASLOG 環境變數
# Scope v1.8: + 預設根路徑 /CASLog/AI → /CASLog/AI/sos (CASLOG_BASE env 覆蓋)
#               目的: 預留 /CASLog/AI 給其他工具集並行 (sos=Support / Observability System)
#               影響: scripts/logs/reports/conf 全部往 /CASLog/AI/sos/ 下面搬
#               舊部署遷移: mv 舊 4 個子目錄到 /CASLog/AI/sos/ 下，改 cron 路徑
# Scope v1.7: + AP port 智慧偵測 (無 hardcoded 8080 fallback)
#               - 擴大白名單: 80/443/3000/5000/7001/8000/8001/8080/8081/8443/9080/9090
#               - 掃到 listener → 用那個 port
#               - 沒掃到 → AP_PORT 空 → check_ap 走 N/A (非 FAIL)
#               - TS_AP_PORT 有設 → 尊重 SP 意圖 (SOP 指定的 port，沒 listener 就 FAIL)
#             + s_block 新增 N/A state (中性，不列入 PASS/WARN/FAIL 統計)
#             + top summary 新增 N/A 欄位顯示
# Scope v1.6: + mod_troubleshoot.sh 預設簡潔模式
#               - 預設 stdout 只印: 進度 + 總結字卡 + 「詳情看檔案」footer
#               - 加 -m / -v / --full 才在 stdout 倒完整細項 (v1.5 的行為)
#               - 報告檔 (SUMMARY/DETAIL) 永遠是全版，不受 -m 影響
#               - 加 -h 顯示 usage
# Scope v1.5: + mod_troubleshoot.sh 重構輸出順序 — 先總結再細項
#               - 跑完 9 面向後，先印「主機狀態 / FAIL 項 / WARN 項 / 客訴關聯」字卡
#               - 之後才倒出完整 9 個面向細項 (給要深挖的 SP 看)
#               - SUMMARY 報告檔也同順序 (離線看檔一致)
#               - 跑期間 stderr 顯示一行進度: [n/9] name STATE
# Scope v1.4: + prompt 簡化 (能自動判斷就不問；有合理預設改 3 秒 timeout)
#               - mod_file.sh 選項 1/2: 3 秒 timeout，過了走預設 (/ + 100M, /var/log)
#               - mod_troubleshoot.sh: AP port 自動掃 (8080/8443/9090/7001...)，
#                                      ping 目標自動抓 default gateway
#               - 需指定時走 TS_AP_PORT / TS_PING_TGT env var (較無人工 typo 風險)
#             + 檔頭內嵌 Build/Deploy 時刻，可直接 head -6 LinuxMenu.sh 確認版本
# Scope v1.3: + run_impact_cmd 雙重確認 (CONFIRM + 打主機名, 10 秒 timeout)
#             + distro 細版本偵測 (/etc/os-release, RHEL 7/8/9, Ubuntu, Debian, Rocky, Alma...)
#             + 依版本自動切 PKG (yum/dnf) 與 FAILLOCK (pam_tally2/faillock)
# Scope v1.8: 預設根路徑 /CASLog/AI → /CASLog/AI/sos (預留 /CASLog/AI 給其他工具集)
# Scope v1.2: 預設根路徑 /CASLog/AI (可由 CASLOG_BASE env 覆蓋)
# Scope v1.0: 三色 wrapper、audit log、17 個子模組、T0 合規、baseline、triage、tooling
###############################################################################

# 部署時刻 (由 install/deploy 腳本覆寫這一行；未部署時顯示 UNSET)
export SMIT_VERSION="v1.8"
export SMIT_BUILD_TIME="2026-04-23 08:20:00"
export SMIT_DEPLOY_TIME="UNSET"   # DEPLOY_HOOK_LINE — deploy 腳本會 sed 這行

# --- 環境變數 ---
# CASLOG_BASE 可透過環境變數覆蓋，預設 /CASLog/AI/sos (v1.8)
export CASLOG_BASE="${CASLOG_BASE:-/CASLog/AI/sos}"
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
    echo "======================================================"
    echo " 金融業 Linux 維運工具  [Version: ${SMIT_VERSION}]"
    echo "   Build:  ${SMIT_BUILD_TIME}"
    echo "   Deploy: ${SMIT_DEPLOY_TIME}"
    echo " 主機: $(hostname)   使用者: $(whoami)"
    echo -e " OS: ${DISTRO_PRETTY} (${distro_tag} family)"
    echo "    時間: $(date '+%Y-%m-%d %H:%M:%S')   PKG: ${PKG}   FW: ${FW}   FAILLOCK: ${FAILLOCK}"
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
