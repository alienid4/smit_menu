#!/bin/bash
# mod_audit_seal.sh - T0 合規：審計 log 封存與驗證
# 零成本 tamper-evident 機制 (無需 SIEM)：
#   1. append-only (chattr +a)
#   2. 每日 HMAC-SHA256 封存 (manifest)
#   3. 隨時可 verify "log 是否被動過"
#
# 金融業稽核三要素：
#   - 可追溯 (audit_log 本來就有)
#   - 不可竄改 (本模組提供)
#   - 保留期 (logrotate / archive 配合；本模組不強制)
#
# 依賴：openssl, sha256sum, chattr (ext2/3/4)
# cron 範例 (每天 23:59 封存前一天):
#   59 23 * * * root bash ${TWLOG_SCRIPT}/mod_audit_seal.sh --daily >> ${TWLOG_LOG}/audit_seal.log 2>&1
_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_HERE}/LinuxMenu.sh" 2>/dev/null
: "${YEL:=\033[1;33m}"; : "${RED:=\033[0;31m}"; : "${RST:=\033[0m}"

HMAC_KEY_FILE="${TWLOG_CONF}/hmac.key"
MANIFEST="${TWLOG_LOG}/audit_seal.manifest"
SEAL_HISTORY="${TWLOG_LOG}/audit_seal_history.log"
# manifest 不進 LOG_DIR 根目錄以免自己被 +a 後影響 rotate; 但仍寫在 LOG_DIR 方便集中

# 覆蓋 audit_log — 本模組的審計寫到獨立 history 檔，
# 避免 seal/verify 自己的記錄寫入被 seal 的主 LOG_FILE，造成 hash 無法驗證
audit_log() {
    local item="$1" status="$2" detail="$3"
    printf "%s | %-24s | %-7s | %s\n" \
        "$(date '+%Y-%m-%d %H:%M:%S')" "${item}" "${status}" "${detail}" \
        >> "${SEAL_HISTORY}" 2>/dev/null
}

# =============================================================================
# 初始化 HMAC key (若不存在)
# =============================================================================
ensure_key() {
    if [ -f "${HMAC_KEY_FILE}" ]; then
        return 0
    fi
    mkdir -p "$(dirname "${HMAC_KEY_FILE}")"
    chmod 700 "$(dirname "${HMAC_KEY_FILE}")" 2>/dev/null
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32 > "${HMAC_KEY_FILE}"
    else
        # fallback: /dev/urandom
        head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "${HMAC_KEY_FILE}"
        echo >> "${HMAC_KEY_FILE}"
    fi
    chmod 600 "${HMAC_KEY_FILE}"
    # immutable — 連 root 都不能誤刪 (需先 chattr -i)
    chattr +i "${HMAC_KEY_FILE}" 2>/dev/null || true
    echo "[seal] 已產生 HMAC key: ${HMAC_KEY_FILE}"
    echo "[seal] 請立即備份此 key 到離線安全保管 (沒它就無法 verify 歷史 log)"
    audit_log "HMAC key created" "OK" "${HMAC_KEY_FILE}"
}

# =============================================================================
# HMAC 計算
# =============================================================================
hmac_of() {
    local f="$1"
    local key
    key=$(cat "${HMAC_KEY_FILE}")
    openssl dgst -sha256 -hmac "${key}" "${f}" 2>/dev/null | awk '{print $NF}'
}

sha256_of() {
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

# =============================================================================
# manifest 寫入 helper
# 格式: TS | HOST | filename | sha256=... | hmac=... | lines=N | size=N
# =============================================================================
manifest_append() {
    local entry="$1"
    if [ ! -f "${MANIFEST}" ]; then
        : > "${MANIFEST}"
        chmod 640 "${MANIFEST}"
    fi
    # 若 manifest 被 +a，append 仍可；我們也對它套 +a
    echo "${entry}" >> "${MANIFEST}"
    chattr +a "${MANIFEST}" 2>/dev/null || true
}

# =============================================================================
# 啟用 append-only 於當前 log
# =============================================================================
protect_logs() {
    local applied=0 skipped=0
    for f in "${TWLOG_LOG}"/*.log; do
        [ -f "$f" ] || continue
        if lsattr "$f" 2>/dev/null | grep -q '\-\-\-\-a'; then
            skipped=$((skipped+1))
        else
            if chattr +a "$f" 2>/dev/null; then
                applied=$((applied+1))
            else
                skipped=$((skipped+1))
            fi
        fi
    done
    echo "append-only 已啟用: ${applied} 個檔 (${skipped} 個略過, 可能是 xfs / 已設定)"
}

# =============================================================================
# 每日封存 (給 cron 用)
# 封存對象：前一天的 log (23:59 跑，避免鎖住今天正在寫的檔)
# =============================================================================
daily_seal() {
    ensure_key
    local day="${1:-$(date -d 'yesterday' +%Y%m%d 2>/dev/null || date +%Y%m%d)}"
    local host; host=$(hostname)
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')

    echo "[seal] ${ts} 封存 ${day} 的 log..."
    local count=0 failed=0
    for f in "${TWLOG_LOG}"/*"${day}"*.log; do
        [ -f "$f" ] || continue
        local name sha hmac lines size
        name=$(basename "$f")
        sha=$(sha256_of "$f")
        hmac=$(hmac_of "$f")
        lines=$(wc -l < "$f" 2>/dev/null)
        size=$(stat -c%s "$f" 2>/dev/null)
        if [ -z "${sha}" ] || [ -z "${hmac}" ]; then
            echo "  [${RED}FAIL${RST}] ${name} — 無法計算 sha/hmac"
            failed=$((failed+1))
            continue
        fi
        manifest_append "${ts} | ${host} | ${name} | sha256=${sha} | hmac=${hmac} | lines=${lines} | size=${size}"
        echo "  [OK] ${name}  sha256=${sha:0:16}...  hmac=${hmac:0:16}..."
        count=$((count+1))
    done

    if [ "${count}" -eq 0 ]; then
        echo "[seal] ${day} 無 log 檔"
        audit_log "Audit seal ${day}" "OK" "no logs"
        return 0
    fi

    protect_logs >/dev/null
    audit_log "Audit seal ${day}" "OK" "sealed=${count} failed=${failed}"
    echo "[seal] 完成: sealed=${count} failed=${failed}"
    echo "[seal] manifest: ${MANIFEST}"
    [ "${failed}" -gt 0 ] && return 1
    return 0
}

# =============================================================================
# 驗證單一 log (對照 manifest)
# =============================================================================
verify_log() {
    local target="$1"
    if [ -z "${target}" ]; then
        echo "用法: verify_log <log 檔名或完整路徑>"
        return 2
    fi
    ensure_key
    [ ! -f "${MANIFEST}" ] && { echo "${RED}無 manifest${RST} — 尚未 seal 過"; return 2; }

    # 接受完整路徑或只有檔名
    local name; name=$(basename "${target}")
    local path="${TWLOG_LOG}/${name}"
    [ ! -f "${path}" ] && { echo "${RED}log 不存在: ${path}${RST}"; return 2; }

    # 從 manifest 抓最後一次該檔的紀錄
    local recorded
    recorded=$(grep "| ${name} |" "${MANIFEST}" | tail -1)
    [ -z "${recorded}" ] && { echo "${RED}manifest 中無 ${name} 的紀錄${RST}"; return 2; }

    local rec_sha rec_hmac cur_sha cur_hmac
    rec_sha=$(echo "${recorded}" | grep -oP 'sha256=\K[a-f0-9]+')
    rec_hmac=$(echo "${recorded}" | grep -oP 'hmac=\K[a-f0-9]+')
    cur_sha=$(sha256_of "${path}")
    cur_hmac=$(hmac_of "${path}")

    echo "── Verify: ${name} ──"
    echo " manifest sha256 : ${rec_sha}"
    echo " 目前    sha256  : ${cur_sha}"
    echo " manifest hmac   : ${rec_hmac}"
    echo " 目前    hmac    : ${cur_hmac}"

    if [ "${rec_sha}" = "${cur_sha}" ] && [ "${rec_hmac}" = "${cur_hmac}" ]; then
        echo " 結果 : PASS — log 未被竄改"
        audit_log "Audit verify ${name}" "OK" "PASS"
        return 0
    else
        echo -e " 結果 : ${RED}FAIL${RST} — log 已被動過！（或 HMAC key 不同）"
        audit_log "Audit verify ${name}" "FAIL" "tampered or key mismatch"
        return 1
    fi
}

# =============================================================================
# 驗證全部 manifest 中的 log
# =============================================================================
verify_all() {
    ensure_key
    [ ! -f "${MANIFEST}" ] && { echo "${RED}無 manifest${RST}"; return 2; }
    local total=0 pass=0 fail=0 missing=0
    # 取 manifest 中每個不重複 log 檔名的最新一筆
    local names
    names=$(awk -F'|' '{gsub(/ /,"",$3); print $3}' "${MANIFEST}" | sort -u)
    for name in ${names}; do
        total=$((total+1))
        local path="${TWLOG_LOG}/${name}"
        if [ ! -f "${path}" ]; then
            echo -e "  [${YEL}MISSING${RST}] ${name}"
            missing=$((missing+1))
            continue
        fi
        local recorded rec_sha cur_sha
        recorded=$(grep "| ${name} |" "${MANIFEST}" | tail -1)
        rec_sha=$(echo "${recorded}" | grep -oP 'sha256=\K[a-f0-9]+')
        cur_sha=$(sha256_of "${path}")
        if [ "${rec_sha}" = "${cur_sha}" ]; then
            echo "  [OK] ${name}"
            pass=$((pass+1))
        else
            echo -e "  [${RED}FAIL${RST}] ${name} (sha mismatch)"
            fail=$((fail+1))
        fi
    done
    echo
    echo "總計: ${total}  PASS: ${pass}  FAIL: ${fail}  MISSING: ${missing}"
    audit_log "Audit verify-all" "$([ "${fail}" -eq 0 ] && echo OK || echo FAIL)" \
              "total=${total} pass=${pass} fail=${fail} missing=${missing}"
    [ "${fail}" -gt 0 ] && return 1
    return 0
}

# =============================================================================
# 顯示狀態（給人看）
# =============================================================================
show_status() {
    echo "── 審計封存狀態 ──"
    echo "  HMAC key       : ${HMAC_KEY_FILE} $([ -f "${HMAC_KEY_FILE}" ] && echo '[存在]' || echo '[未建立]')"
    echo "  Manifest       : ${MANIFEST}"
    if [ -f "${MANIFEST}" ]; then
        local n; n=$(wc -l < "${MANIFEST}" 2>/dev/null)
        local last; last=$(tail -1 "${MANIFEST}" | cut -c1-19)
        echo "  封存筆數       : ${n}"
        echo "  最後 seal      : ${last}"
    fi
    echo
    echo "── append-only log ──"
    for f in "${TWLOG_LOG}"/*.log; do
        [ -f "$f" ] || continue
        local attr; attr=$(lsattr "$f" 2>/dev/null | awk '{print $1}')
        local marker="  "
        echo "${attr}" | grep -q 'a' && marker="✓ "
        printf "  %s%s  %s\n" "${marker}" "${attr:-?}" "$(basename "$f")"
    done
    echo
    echo "── cron 狀態 ──"
    if [ -f /etc/cron.d/linuxmenu-audit-seal ]; then
        echo "  /etc/cron.d/linuxmenu-audit-seal [存在]"
        grep -v '^#' /etc/cron.d/linuxmenu-audit-seal | grep -v '^$' | sed 's/^/    /'
    else
        echo "  /etc/cron.d/linuxmenu-audit-seal [未建立]"
        echo "  (install.sh 會自動建立；若遺失可手動建立，範例見選項 5)"
    fi
}

show_cron_template() {
    cat <<EOF
── 建議 cron 設定 ──
  /etc/cron.d/linuxmenu-audit-seal 內容：

  SHELL=/bin/bash
  PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

  # 每日 23:59 封存今日 log
  59 23 * * * root  bash ${TWLOG_SCRIPT}/mod_audit_seal.sh --daily >> ${TWLOG_LOG}/audit_seal.log 2>&1

建立：
  sudo install -m 644 /dev/stdin /etc/cron.d/linuxmenu-audit-seal <<EOF2
  [上面內容貼這]
  EOF2

EOF
}

# =============================================================================
# 互動選單
# =============================================================================
interactive() {
    while true; do
        clear
        echo "======================================================"
        echo " 審計封存與驗證 (T0 合規)"
        echo " Key: ${HMAC_KEY_FILE}"
        echo "======================================================"
        echo "  1) 顯示狀態 (key / manifest / append-only / cron)"
        echo "  2) 立即執行 daily seal (手動)"
        echo "  3) 驗證單一 log (檢查是否被動過)"
        echo "  4) 驗證全部 manifest 紀錄"
        echo "  5) 顯示 cron 範例"
        echo "  6) 列出 manifest (最近 30 筆)"
        echo -e "  7) ${YEL}[變更] 啟用所有現有 log 為 append-only${RST}"
        echo "  b) 返回主選單"
        echo "======================================================"
        read -r -p "選擇 > " c || exit 0
        case "$c" in
            1) run_cmd "Audit status"       show_status ;;
            2) run_cmd "Daily seal"         daily_seal ;;
            3) read -r -p "log 檔名 (LinuxMenu_main_YYYYMMDD.log) > " f
               run_cmd "Verify ${f}"        verify_log "${f}" ;;
            4) run_cmd "Verify all"         verify_all ;;
            5) run_cmd "Show cron template" show_cron_template ;;
            6) run_cmd "List manifest"      bash -c "tail -30 '${MANIFEST}' 2>/dev/null || echo '(manifest 不存在)'" ;;
            7) run_change_cmd "Enable append-only" protect_logs ;;
            b|B) exit 0 ;;
            *)   echo "無效選項" ;;
        esac
        pause
    done
}

# =============================================================================
# CLI
# =============================================================================
case "${1:-}" in
    --daily)       shift; daily_seal "$@"; exit $? ;;
    --verify)      shift; verify_log "$@"; exit $? ;;
    --verify-all)  verify_all; exit $? ;;
    --status)      show_status; exit 0 ;;
    --protect)     protect_logs; exit 0 ;;
    --ensure-key)  ensure_key; exit 0 ;;
    --help|-h)
        cat <<EOF
用法:
  bash mod_audit_seal.sh                      互動選單
  bash mod_audit_seal.sh --daily [YYYYMMDD]   封存指定日 log (預設昨天, 給 cron 用)
  bash mod_audit_seal.sh --verify <log 檔名>  驗證某 log
  bash mod_audit_seal.sh --verify-all         驗證所有 manifest 紀錄
  bash mod_audit_seal.sh --status             顯示狀態
  bash mod_audit_seal.sh --protect            對現有 log 套用 append-only
  bash mod_audit_seal.sh --ensure-key         確保 HMAC key 存在 (install.sh 用)
EOF
        exit 0 ;;
    "")
        if [ "${BASH_SOURCE[0]}" = "$0" ]; then
            interactive
        fi
        ;;
esac
