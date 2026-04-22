#!/bin/bash
# mod_baseline.sh - Baseline 快照管理
# 用途：
#   每天開盤前自動跑一次 troubleshoot，存為「當天的 baseline」，
#   交易中出事時 diff 兩份 summary，秒級看出「今天跟平日不一樣在哪」。
#
# 設定 (透過 /CASLog/AI/conf/baseline.conf 或環境變數):
#   BL_AP_PORT=8080
#   BL_PING_TGT=10.0.0.1         (空白則自動抓 gateway)
#   BL_RETAIN_DAYS=30            (保留天數，超過自動清)
#
# cron 範例 (每天開盤前 07:30):
#   30 7 * * 1-5 root  bash ${CASLOG_SCRIPT}/mod_baseline.sh --snapshot >/dev/null 2>&1
_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_HERE}/LinuxMenu.sh" 2>/dev/null
: "${YEL:=\033[1;33m}"; : "${RED:=\033[0;31m}"; : "${RST:=\033[0m}"

BL_DIR="${CASLOG_REPORT}/baselines"
BL_CONF="${CASLOG_CONF}/baseline.conf"
mkdir -p "${BL_DIR}"
[ -f "${BL_CONF}" ] && . "${BL_CONF}"

: "${BL_AP_PORT:=8080}"
: "${BL_PING_TGT:=}"
: "${BL_RETAIN_DAYS:=30}"

# =============================================================================
# snapshot: 跑一次 troubleshoot (non-interactive), 存成 baseline
# =============================================================================
snapshot() {
    local day="${1:-$(date +%Y%m%d)}"
    local prefix="${BL_DIR}/baseline_$(hostname)_${day}"

    echo "[baseline] 產生 ${day} 的 baseline..."
    TS_NONINTERACTIVE=1 \
    TS_AP_PORT="${BL_AP_PORT}" \
    TS_PING_TGT="${BL_PING_TGT}" \
    TS_OUTPUT_PREFIX="${prefix}" \
        bash "${_HERE}/mod_troubleshoot.sh" >/dev/null 2>&1

    if [ -f "${prefix}_summary.txt" ]; then
        echo "[baseline] 產出: ${prefix}_summary.txt"
        audit_log "Baseline snapshot" "OK" "${prefix}_summary.txt"
        # 清理超過保留天數的舊 baseline
        find "${BL_DIR}" -maxdepth 1 -name "baseline_*_summary.txt" \
             -mtime +"${BL_RETAIN_DAYS}" -delete 2>/dev/null
        find "${BL_DIR}" -maxdepth 1 -name "baseline_*_detail.txt" \
             -mtime +"${BL_RETAIN_DAYS}" -delete 2>/dev/null
        return 0
    else
        echo "[baseline] ${RED}FAIL${RST} — 產出不存在"
        audit_log "Baseline snapshot" "FAIL" "${prefix}"
        return 1
    fi
}

# =============================================================================
# list: 列出本機現有 baselines
# =============================================================================
list_baselines() {
    echo "── 本機 baseline ──"
    local count=0
    for f in $(ls -1t "${BL_DIR}"/baseline_*_summary.txt 2>/dev/null); do
        count=$((count+1))
        local day size
        day=$(basename "$f" | awk -F_ '{print $(NF-1)}')
        size=$(stat -c%s "$f" 2>/dev/null)
        # 從 summary 抓結論 (PASS/WARN/FAIL 計數)
        local stat
        stat=$(grep -E '^ 9 項檢查' "$f" 2>/dev/null | head -1 | sed 's/^ //')
        printf "  %2d) %s  (%s bytes)  %s\n" "${count}" "${day}" "${size}" "${stat:-?}"
    done
    [ "${count}" -eq 0 ] && echo "  (無) — 請先跑 snapshot"
}

# =============================================================================
# diff: 今天 vs 某天
# =============================================================================
diff_baselines() {
    local day_a="${1:-}" day_b="${2:-}"
    if [ -z "${day_a}" ] || [ -z "${day_b}" ]; then
        echo "用法: diff_baselines <今天 YYYYMMDD> <baseline YYYYMMDD>"
        return 1
    fi
    local a="${BL_DIR}/baseline_$(hostname)_${day_a}_summary.txt"
    local b="${BL_DIR}/baseline_$(hostname)_${day_b}_summary.txt"
    [ -f "${a}" ] || { echo "${RED}找不到 ${a}${RST}"; return 1; }
    [ -f "${b}" ] || { echo "${RED}找不到 ${b}${RST}"; return 1; }

    echo "── diff ${day_b} (baseline) vs ${day_a} (今天) ──"
    echo "   -  表示 baseline 有但今天沒有"
    echo "   +  表示今天新出現的"
    echo "───────────────────────────────────────────"
    # 只 diff 每塊的「實測數值」那幾行，濾掉時間戳差異
    # 用 diff -u 輸出 unified，讓 SP 能 grep '^+' 看新增
    diff -u \
        <(grep -vE 'uptime|since|當前時段|產出時間|Summary :|Detail  :' "${b}") \
        <(grep -vE 'uptime|since|當前時段|產出時間|Summary :|Detail  :' "${a}")
}

# =============================================================================
# 互動選單
# =============================================================================
interactive() {
    while true; do
        clear
        echo "======================================================"
        echo " Baseline 管理    conf: ${BL_CONF}"
        echo "======================================================"
        echo "  1) 列出現有 baseline"
        echo "  2) 立即產生今天的 baseline (手動)"
        echo "  3) Diff — 今天 vs 某天"
        echo "  4) Diff — 今天 vs 最近一份 (最常用)"
        echo "  5) 清除 7 天以上舊 baseline"
        echo "  6) 顯示 cron 範例"
        echo "  b) 返回主選單"
        echo "======================================================"
        read -r -p "選擇 > " c || exit 0
        case "$c" in
            1) run_cmd "List baselines" list_baselines ;;
            2) run_cmd "Create baseline today" snapshot ;;
            3) read -r -p "今天 YYYYMMDD [$(date +%Y%m%d)] > " da
               da="${da:-$(date +%Y%m%d)}"
               read -r -p "baseline 對比日 YYYYMMDD > " db
               run_cmd "Diff ${da} vs ${db}" diff_baselines "${da}" "${db}"
               ;;
            4) today=$(date +%Y%m%d)
               latest=$(ls -1t "${BL_DIR}"/baseline_*_summary.txt 2>/dev/null \
                        | grep -v "_${today}_" | head -1 \
                        | awk -F_ '{print $(NF-1)}')
               if [ -z "${latest}" ]; then
                   echo "(無更早的 baseline 可比)"
               else
                   run_cmd "Diff ${today} vs ${latest}" diff_baselines "${today}" "${latest}"
               fi
               ;;
            5) run_change_cmd "Purge baselines >7 days" \
                   find "${BL_DIR}" -maxdepth 1 -name "baseline_*" -mtime +7 -delete ;;
            6) cat <<EOF

── cron 範例 ──
  金融業開盤前 07:30 自動跑 (週一到週五)：

  # /etc/cron.d/linuxmenu-baseline
  SHELL=/bin/bash
  PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

  30 7 * * 1-5 root  bash ${CASLOG_SCRIPT}/mod_baseline.sh --snapshot >> ${CASLOG_LOG}/baseline.log 2>&1

  建立方式：
    sudo nano /etc/cron.d/linuxmenu-baseline
    貼上上面內容，chmod 644，cron 自動重讀

EOF
               ;;
            b|B) exit 0 ;;
            *)   echo "無效選項" ;;
        esac
        pause
    done
}

# =============================================================================
# CLI 參數 (給 cron 用)
# =============================================================================
case "${1:-}" in
    --snapshot)    shift; snapshot "$@"; exit $? ;;
    --list)        list_baselines; exit 0 ;;
    --diff)        shift; diff_baselines "$@"; exit $? ;;
    --help|-h)
        cat <<EOF
用法:
  bash mod_baseline.sh                       互動選單
  bash mod_baseline.sh --snapshot            產生今天的 baseline (給 cron 用)
  bash mod_baseline.sh --list                列出 baseline
  bash mod_baseline.sh --diff YYYYMMDD YYYYMMDD  diff 兩天
EOF
        exit 0 ;;
    "")  # 無參數 = 互動模式
        if [ "${BASH_SOURCE[0]}" = "$0" ]; then
            interactive
        fi
        ;;
esac
