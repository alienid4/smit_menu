#!/bin/bash
# mod_troubleshoot.sh - 客戶投訴「慢/連不進去」時的自辯報告 (v1.7)
# 9 個面向 + 應用層附錄，每項以「檢查範圍/指令/基準/實測/判定/對客訴影響/建議」呈現
#   1) 效能        2) 頻寬 (含 conntrack/TW/SYN drop)   3) AP port
#   4) Session     5) Storage                         6) 時間/憑證
#   7) DB          8) Infra 穩定 (OOM/MCE/failed)     9) 運維軌跡 (近 1h)
#   Appendix A (選配): 應用層深度 — 需 conf/app.conf
#
# v1.6 用法:
#   bash mod_troubleshoot.sh          # 預設簡潔: 進度 + 總結字卡 + 報告檔路徑
#   bash mod_troubleshoot.sh -m       # 顯示完整細項 (-v / --full / --verbose 同義)
#   bash mod_troubleshoot.sh -h       # 顯示 usage
# 報告檔 ( SUMMARY/DETAIL ) 內容永遠是全版，不受 -m 影響。
_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_HERE}/LinuxMenu.sh" 2>/dev/null
: "${YEL:=\033[1;33m}"; : "${RED:=\033[0;31m}"; : "${RST:=\033[0m}"

# v1.6: CLI 參數解析
VERBOSE=0
for arg in "$@"; do
    case "${arg}" in
        -m|-v|--full|--verbose) VERBOSE=1 ;;
        -h|--help)
            cat <<'USAGE'
mod_troubleshoot.sh — 客訴自辯報告

用法:
  bash mod_troubleshoot.sh          預設簡潔輸出 (9 行進度 + 總結字卡)
  bash mod_troubleshoot.sh -m       完整細項 (進度 + 總結 + 9 面向 + Appendix)
  bash mod_troubleshoot.sh -h       顯示此 help

參數別名:
  -m  -v  --full  --verbose         以上四個等價，皆進入 verbose 模式

環境變數 (可覆蓋自動偵測):
  TS_NONINTERACTIVE=1               跳過 prompt 與 pause (cron / batch 用)
  TS_AP_PORT=8080                   AP 監聽 port (預設自動掃常見 AP port)
  TS_PING_TGT=10.1.1.1              Ping 目標 (預設自動抓 default gateway)
  TS_OUTPUT_PREFIX=/path/ts         自訂輸出檔路徑前綴

輸出:
  stdout                            依 -m 決定詳簡
  ${CASLOG_REPORT}/ts_<host>_<ts>_summary.txt   永遠全版 (總結字卡 + 9 面向 + Appendix)
  ${CASLOG_REPORT}/ts_<host>_<ts>_detail.txt    raw 指令輸出 (最底層)
USAGE
            exit 0
            ;;
        *)  echo "未知參數: ${arg}  (用 -h 看 help)" >&2 ;;
    esac
done

# 嘗試載入 DB 模組（給第 7 塊用）
DB_MOD="${CASLOG_SCRIPT}/mod_db.sh"
[ -f "${DB_MOD}" ] && . "${DB_MOD}"

# 選配 app.conf (Appendix A)
APP_CONF="${CASLOG_CONF}/app.conf"
[ -f "${APP_CONF}" ] && . "${APP_CONF}"

REPORT_DIR="${CASLOG_REPORT}"
TS="$(date '+%Y%m%d_%H%M%S')"
HOST="$(hostname)"
# 非互動模式 (baseline cron 會用)：
#   TS_NONINTERACTIVE=1  跳過 prompt 與 pause
#   TS_AP_PORT=8080      AP port
#   TS_PING_TGT=10.1.1.1 ping 目標 (空白則自動抓 gateway)
#   TS_OUTPUT_PREFIX     自訂輸出檔名前綴 (整路徑)，會產生 <prefix>_summary.txt/_detail.txt
if [ -n "${TS_OUTPUT_PREFIX:-}" ]; then
    SUMMARY="${TS_OUTPUT_PREFIX}_summary.txt"
    DETAIL="${TS_OUTPUT_PREFIX}_detail.txt"
    mkdir -p "$(dirname "${SUMMARY}")"
else
    SUMMARY="${REPORT_DIR}/ts_${HOST}_${TS}_summary.txt"
    DETAIL="${REPORT_DIR}/ts_${HOST}_${TS}_detail.txt"
    mkdir -p "${REPORT_DIR}"
fi

# v1.7: AP port 偵測策略
#   1. 若 TS_AP_PORT 有設 → 尊重 SP 意圖 (SOP 指定的 port，沒 listener 就該 FAIL)
#   2. 否則自動掃 common AP port 白名單
#      (80/443/3000/5000/7001/8000/8001/8080/8081/8443/9080/9090)
#   3. 若仍沒抓到 → AP_PORT 保持空字串 → check_ap 會回報 N/A (非 AP 角色)
AP_PORT_SCAN_LIST='80|443|3000|5000|7001|8000|8001|8080|8081|8443|9080|9090'

auto_detect_ap_port() {
    ss -tnlp 2>/dev/null \
        | awk -v w="^(${AP_PORT_SCAN_LIST})\$" \
              'NR>1{n=split($4,a,":"); p=a[n]; if(p ~ w){print p; exit}}'
}

if [ "${TS_NONINTERACTIVE:-0}" = "1" ]; then
    if [ -n "${TS_AP_PORT:-}" ]; then
        AP_PORT="${TS_AP_PORT}"
    else
        AP_PORT="$(auto_detect_ap_port)"   # 空 = 本機非 AP 角色
    fi
    PING_TGT="${TS_PING_TGT:-}"
else
    clear
    echo "======================================================"
    if [ "${VERBOSE:-0}" = "1" ]; then
        echo " 快速自辯報告 (Troubleshoot) v1.7  [mode=verbose]"
    else
        echo " 快速自辯報告 (Troubleshoot) v1.7  [mode=簡潔，加 -m 看細項]"
    fi
    echo " 客訴「系統慢 / 連不進去」時執行，涵蓋 9 面向 + Appendix A (選配)"
    echo "======================================================"
    if [ -n "${TS_AP_PORT:-}" ]; then
        AP_PORT="${TS_AP_PORT}"
    else
        AP_PORT="$(auto_detect_ap_port)"   # 可能為空 (本機非 AP 角色)
    fi
    PING_TGT=""
fi
if [ -z "${PING_TGT}" ]; then
    PING_TGT=$(ip route 2>/dev/null | awk '/default/{print $3; exit}')
fi
[ -z "${PING_TGT}" ] && PING_TGT="127.0.0.1"
if [ "${TS_NONINTERACTIVE:-0}" != "1" ]; then
    if [ -n "${AP_PORT}" ]; then
        echo " AP 監聽 port (自動): ${AP_PORT}"
    else
        echo " AP 監聽 port (自動): 未偵測到 (本機可能非 AP 角色，該項將標 N/A)"
    fi
    echo " Ping 目標 (自動):    ${PING_TGT}"
    echo " (如需指定： TS_AP_PORT=xxxx TS_PING_TGT=x.x.x.x bash mod_troubleshoot.sh)"
    echo " 開始檢查，約 30-60 秒..."
fi

: > "${SUMMARY}"
: > "${DETAIL}"

declare -A RESULT NAME IMPACT ACTION

# =============================================================================
# 輸出 helpers
# =============================================================================
header() {
    local uptime_str
    uptime_str=$(uptime -p 2>/dev/null || uptime | awk -F'up ' '{print $2}' | awk -F',' '{print $1}')
    {
        echo "============================================================"
        echo " 快速自辯報告    金融業 Linux 維運工具 v1.0"
        echo "------------------------------------------------------------"
        echo " 主機      : ${HOST}"
        echo " 操作者    : $(whoami)"
        echo " 產出時間  : $(date '+%Y-%m-%d %H:%M:%S')"
        echo " OS        : ${DISTRO}     Uptime: ${uptime_str}"
        echo " AP port   : ${AP_PORT:-(未偵測 / 非 AP 角色)}    Ping 目標: ${PING_TGT}"
        echo "============================================================"
        echo
        echo "本報告 9 個面向："
        echo "  1) 效能 (CPU/記憶體/Load/Swap)"
        echo "  2) 頻寬 (網卡/TCP retrans/Ping/conntrack/TIME_WAIT/SYN drop)"
        echo "  3) AP  (指定 port 監聽狀態與程序資源)"
        echo "  4) Session (連線總數與狀態分佈)"
        echo "  5) Storage (磁碟/Inode/tmp)"
        echo "  6) 時間 / 憑證 (NTP / keystore 到期)"
        echo "  7) DB  (偵測到的 DB 做連通性與健康檢查)"
        echo "  8) Infra 穩定 (OOM/MCE/systemd failed/kernel tainted)"
        echo "  9) 運維軌跡 (近 1h 誰登入 / 改 /etc / 重啟 service)"
        if [ -f "${APP_CONF}" ]; then
            echo "  +) Appendix A 應用層深度 (app.conf 已載入)"
        else
            echo "  +) Appendix A 應用層深度 — 不執行 (app.conf 不存在)"
        fi
        echo
    } | tee -a "${SUMMARY}" >> "${DETAIL}"
}

d_sec() { { echo; echo "========================================"; echo "  $1"; echo "========================================"; } >> "${DETAIL}"; }
d_run() { local t="$1"; shift; d_sec "${t}"; "$@" >> "${DETAIL}" 2>&1; }

# 主角：s_block — 一個 check 的完整呈現
# 用法：
#   s_block "1/9" "效能" "PASS" <<EOF
#   檢查範圍   : ...
#   檢查指令   : ...
#   ...
#   EOF
s_block() {
    local n="$1" name="$2" result="$3"
    local color=""
    case "${result}" in
        WARN) color="${YEL}" ;;
        FAIL) color="${RED}" ;;
        N/A)  color="" ;;   # 中性: 不適用 (e.g. 本機非 AP 角色)
    esac
    local body
    body=$(cat)
    RESULT[$n]="${result}"
    NAME[$n]="${name}"
    # v1.5: 自動抓「對客訴影響 / 建議動作」首行，讓 top summary 可以一行秀出問題
    IMPACT[$n]=$(echo "${body}" | awk '/對客訴影響/{sub(/^[^:]*:[ ]*/,""); gsub(/ +$/,""); print; exit}')
    ACTION[$n]=$(echo "${body}" | awk '/建議動作/{sub(/^[^:]*:[ ]*/,""); gsub(/ +$/,""); print; exit}')
    # 完整 block 僅寫入 SUMMARY 檔 (不再 stream 到 stdout；由 top summary 與 cat 負責輸出順序)
    {
        echo
        printf "[%s] %-12s  %s%s%s\n" "${n}" "${name}" "${color}" "${result}" "${RST}"
        printf -- "-----------------------------------------------------------\n"
        echo "${body}"
    } >> "${SUMMARY}"
    # 即時進度 (stderr) — 讓使用者知道每個面向已跑完
    printf "  [%s] %-12s  %s%-4s%s\n" "${n}" "${name}" "${color}" "${result}" "${RST}" >&2
}

# =============================================================================
# 1/7 效能
# =============================================================================
check_load() {
    local cores load1 load5 load15 idle swap_pct mem_free_mb
    cores=$(nproc 2>/dev/null || echo 1)
    read -r load1 load5 load15 _ < /proc/loadavg
    idle=$(vmstat 1 3 2>/dev/null | tail -n +4 | awk '{s+=$15; n++} END{printf "%.0f",(n?s/n:0)}')
    swap_pct=$(free 2>/dev/null | awk '/Swap:/{if($2>0)printf "%d",($3/$2)*100;else print 0}')
    mem_free_mb=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}')

    local result="PASS"
    local load_warn=$((cores*2)) load_fail=$((cores*4))
    local load_status="PASS" idle_status="PASS" swap_status="PASS"

    awk -v l="${load1}" -v c="${cores}" 'BEGIN{exit !(l>=c*4)}' && { result="FAIL"; load_status="FAIL"; }
    if [ "${load_status}" = "PASS" ]; then
        awk -v l="${load1}" -v c="${cores}" 'BEGIN{exit !(l>=c*2)}' && { result="WARN"; load_status="WARN"; }
    fi
    [ "${idle:-100}" -lt 10 ] 2>/dev/null && { idle_status="WARN"; [ "${result}" = PASS ] && result=WARN; }
    [ "${swap_pct:-0}" -ge 10 ] && { swap_status="WARN"; [ "${result}" = PASS ] && result=WARN; }
    [ "${swap_pct:-0}" -ge 50 ] && { swap_status="FAIL"; result=FAIL; }

    # detail 完整輸出
    d_run "1. 效能 - uptime"          uptime
    d_run "1. 效能 - /proc/loadavg"   cat /proc/loadavg
    d_run "1. 效能 - vmstat 1 3"      bash -c "vmstat 1 3"
    d_run "1. 效能 - free -h"         free -h
    d_run "1. 效能 - top 前 15"       bash -c "top -bn1 | head -15"
    d_run "1. 效能 - iostat"          bash -c "command -v iostat >/dev/null && iostat -x 1 3 || echo '(未裝 sysstat)'"

    local impact
    case "${result}" in
        PASS) impact="無 — CPU/記憶體充裕，效能層不可能是客訴原因" ;;
        WARN) impact="中度 — 資源已接近門檻，尖峰時段可能出現 AP 回應延遲" ;;
        FAIL) impact="高度 — 主機資源耗盡，AP 必定卡頓或 hang，為客訴主因" ;;
    esac

    s_block "1/9" "效能" "${result}" <<EOF
  檢查範圍   : CPU load、CPU idle%、Swap 使用率、可用記憶體
  檢查指令   : cat /proc/loadavg ; vmstat 1 3 ; free -h ; top -bn1 ; iostat -x 1 3
  正常基準   : Load(1m)  < cores × 2           (此機 cores=${cores}，WARN>=${load_warn}，FAIL>=${load_fail})
               CPU idle  >= 10%
               Swap used < 10%                 (FAIL 門檻 50%)
  實測數值   : Load(1/5/15m) = ${load1} / ${load5} / ${load15}      [${load_status}]
               CPU idle avg  = ${idle}%                       [${idle_status}]
               Swap used     = ${swap_pct:-0}%                       [${swap_status}]
               Mem available = ${mem_free_mb:-?} MB
  判定依據   : ${result}  (任一子項 FAIL → FAIL；任一 WARN → WARN；全 PASS → PASS)
  對客訴影響 : ${impact}
  建議動作   : $([ "$result" = "PASS" ] && echo "無需動作。" || echo "用 top 與 ps --sort=-%cpu 找最耗 CPU 者；若 swap 高則查 OOM 歷史 dmesg -T | grep -i killed。")
EOF
}

# =============================================================================
# 2/7 頻寬
# =============================================================================
check_net() {
    local result="PASS"
    local tot_err=0 tot_drop=0 err_nic=0 nic_detail=""
    for nic in $(ls /sys/class/net/ 2>/dev/null | grep -v '^lo$'); do
        local rxe txe rxd txd
        rxe=$(cat /sys/class/net/${nic}/statistics/rx_errors 2>/dev/null || echo 0)
        txe=$(cat /sys/class/net/${nic}/statistics/tx_errors 2>/dev/null || echo 0)
        rxd=$(cat /sys/class/net/${nic}/statistics/rx_dropped 2>/dev/null || echo 0)
        txd=$(cat /sys/class/net/${nic}/statistics/tx_dropped 2>/dev/null || echo 0)
        tot_err=$((tot_err + rxe + txe))
        tot_drop=$((tot_drop + rxd + txd))
        if [ "$((rxe+txe+rxd+txd))" -gt 0 ]; then
            err_nic=$((err_nic+1))
            nic_detail+="${nic}: rxe=${rxe} txe=${txe} rxd=${rxd} txd=${txd}; "
        fi
    done

    local tcp_seg tcp_retrans retrans_pct
    tcp_seg=$(awk '/^Tcp:/ && h++ {print $11}' /proc/net/snmp | head -1)
    tcp_retrans=$(awk '/^Tcp:/ && h++ {print $13}' /proc/net/snmp | head -1)
    if [ -n "${tcp_seg}" ] && [ "${tcp_seg}" -gt 0 ]; then
        retrans_pct=$(awk -v r="${tcp_retrans}" -v s="${tcp_seg}" 'BEGIN{printf "%.3f",(r/s)*100}')
    else
        retrans_pct="0.000"
    fi

    local ping_rc=1 ping_loss="N/A" ping_rtt="N/A" ping_out=""
    if [ -n "${PING_TGT}" ]; then
        ping_out=$(ping -c 3 -W 2 "${PING_TGT}" 2>&1); ping_rc=$?
        ping_loss=$(echo "${ping_out}" | awk -F, '/packet loss/{gsub(/[^0-9]/,"",$3); print $3}')
        ping_rtt=$(echo "${ping_out}" | awk -F'/' '/rtt|round-trip/ {printf "%.1fms",$5}')
    fi

    local err_status="PASS" retrans_status="PASS" ping_status="PASS"
    if [ "${err_nic}" -gt 0 ]; then err_status="WARN"; result="WARN"; fi
    if awk -v p="${retrans_pct}" 'BEGIN{exit !(p+0>1)}'; then retrans_status="WARN"; result="WARN"; fi
    if awk -v p="${retrans_pct}" 'BEGIN{exit !(p+0>5)}'; then retrans_status="FAIL"; result="FAIL"; fi
    if [ "${ping_rc}" -ne 0 ]; then ping_status="FAIL"; result="FAIL"
    elif [ -n "${ping_loss}" ] && [ "${ping_loss}" != "N/A" ] && [ "${ping_loss}" -gt 0 ] 2>/dev/null; then
        ping_status="WARN"; [ "${result}" = PASS ] && result=WARN
    fi

    # --- conntrack 用量 (金融業高併發殺手) ---
    local ct_count="N/A" ct_max="N/A" ct_pct="N/A" ct_status="N/A"
    if [ -r /proc/sys/net/netfilter/nf_conntrack_count ]; then
        ct_count=$(cat /proc/sys/net/netfilter/nf_conntrack_count)
        ct_max=$(cat /proc/sys/net/netfilter/nf_conntrack_max)
        ct_pct=$(awk -v c=${ct_count} -v m=${ct_max} 'BEGIN{if(m>0)printf "%.0f",(c/m)*100;else print 0}')
        ct_status="PASS"
        [ "${ct_pct}" -ge 80 ] && { ct_status="WARN"; [ "${result}" = PASS ] && result=WARN; }
        [ "${ct_pct}" -ge 95 ] && { ct_status="FAIL"; result=FAIL; }
    else
        ct_status="SKIP"   # 無 nf_conntrack 模組
    fi

    # --- TIME_WAIT 佔 ephemeral port range 比例 ---
    local tw_count port_lo port_hi port_range tw_pct tw_status="PASS"
    tw_count=$(ss -tn state time-wait 2>/dev/null | tail -n +2 | wc -l)
    read -r port_lo port_hi < <(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null | awk '{print $1, $2}')
    if [ -n "${port_lo}" ] && [ -n "${port_hi}" ]; then
        port_range=$((port_hi - port_lo + 1))
        tw_pct=$(awk -v t=${tw_count} -v r=${port_range} 'BEGIN{if(r>0)printf "%.0f",(t/r)*100;else print 0}')
        [ "${tw_pct}" -ge 60 ] && { tw_status="WARN"; [ "${result}" = PASS ] && result=WARN; }
        [ "${tw_pct}" -ge 90 ] && { tw_status="FAIL"; result=FAIL; }
    else
        tw_pct="N/A"; port_range="N/A"
    fi

    # --- SYN backlog / listen drops (累積值) ---
    local syn_drops listen_drops syn_status="PASS"
    syn_drops=$(nstat -az 2>/dev/null | awk '/TcpExtListenDrops/{print $2}' | head -1)
    listen_drops=$(nstat -az 2>/dev/null | awk '/TcpExtListenOverflows/{print $2}' | head -1)
    [ -z "${syn_drops}" ] && syn_drops=$(awk '/TcpExt:/ && h++{print}' /proc/net/netstat | awk '{print $21}' | head -1)
    syn_drops="${syn_drops:-0}"
    listen_drops="${listen_drops:-0}"
    if [ "${syn_drops}" -gt 0 ] || [ "${listen_drops}" -gt 0 ]; then
        syn_status="WARN"; [ "${result}" = PASS ] && result=WARN
    fi

    d_run "2. 頻寬 - ip -br a"        bash -c "ip -br a"
    d_run "2. 頻寬 - NIC stats"       bash -c 'for n in /sys/class/net/*; do nm=$(basename $n); [ "$nm" = lo ] && continue; echo "$nm: rx_err=$(cat $n/statistics/rx_errors 2>/dev/null) tx_err=$(cat $n/statistics/tx_errors 2>/dev/null) rx_drop=$(cat $n/statistics/rx_dropped 2>/dev/null) tx_drop=$(cat $n/statistics/tx_dropped 2>/dev/null)"; done'
    d_run "2. 頻寬 - ethtool 速率"    bash -c 'for n in $(ls /sys/class/net/|grep -v "^lo$"); do echo "== $n =="; ethtool $n 2>/dev/null|grep -E "Speed|Duplex|Link"; done'
    d_run "2. 頻寬 - ss -s"           ss -s
    d_run "2. 頻寬 - netstat -s 前 60 行" bash -c "netstat -s 2>/dev/null | head -60"
    d_run "2. 頻寬 - ping 詳細"       bash -c "ping -c 5 -W 2 \"${PING_TGT}\""
    d_run "2. 頻寬 - conntrack"       bash -c 'if [ -r /proc/sys/net/netfilter/nf_conntrack_count ]; then echo "count=$(cat /proc/sys/net/netfilter/nf_conntrack_count) max=$(cat /proc/sys/net/netfilter/nf_conntrack_max)"; conntrack -S 2>/dev/null | head -5 || true; else echo "(nf_conntrack 模組未載入)"; fi'
    d_run "2. 頻寬 - TIME_WAIT 統計"  bash -c "ss -tn state time-wait | tail -n+2 | wc -l | xargs echo 'TIME_WAIT:'; sysctl -n net.ipv4.ip_local_port_range"
    d_run "2. 頻寬 - SYN / listen drops" bash -c "nstat -az 2>/dev/null | grep -E 'TcpExtListenDrops|TcpExtListenOverflows|TcpExtTCPBacklogDrop' || echo '(無 nstat)'"

    local impact
    case "${result}" in
        PASS) impact="無 — 主機網路層無異常，客訴若為「慢」則非來自本機網路" ;;
        WARN) impact="中度 — NIC 累積錯誤 / retrans 偏高 / conntrack 接近滿 / TIME_WAIT 過多 / SYN drop 已發生，任一都可能是偶發斷線或新連線失敗的原因" ;;
        FAIL) impact="高度 — Ping 失敗、retrans 過高、conntrack 溢出或 TIME_WAIT 耗盡；主機網路層已無法承接新連線，客訴「連不進去」直接相關" ;;
    esac

    s_block "2/9" "頻寬" "${result}" <<EOF
  檢查範圍   : NIC 錯誤/dropped、TCP retransmit、Ping 延遲、**conntrack 用量**、
               **TIME_WAIT 佔 port range 比例**、**SYN / listen drops** (金融業高併發關鍵)
  檢查指令   : cat /sys/class/net/*/statistics/{rx,tx}_{errors,dropped}
               awk /proc/net/snmp (Tcp InSegs/RetransSegs)
               ping -c 3 -W 2 ${PING_TGT}
               cat /proc/sys/net/netfilter/nf_conntrack_{count,max}
               ss -tn state time-wait | wc -l  ; sysctl net.ipv4.ip_local_port_range
               nstat -az | grep TcpExtListenDrops / TcpExtListenOverflows
  正常基準   : NIC errors + dropped = 0
               TCP retransmit < 1%    (FAIL > 5%)
               Ping loss = 0%
               conntrack 用量 < 80%   (FAIL >= 95%)
               TIME_WAIT 佔 port range < 60%  (FAIL >= 90%)
               SYN/listen drops = 0
  實測數值   : NIC 錯誤網卡 = ${err_nic} 張  (err=${tot_err} drop=${tot_drop})         [${err_status}]
               TCP retransmit = ${retrans_pct}%  (seg=${tcp_seg} retrans=${tcp_retrans})    [${retrans_status}]
               Ping ${PING_TGT}: loss=${ping_loss:-N/A}% rtt=${ping_rtt:-N/A}         [${ping_status}]
               conntrack = ${ct_count} / ${ct_max}  (${ct_pct}%)                  [${ct_status}]
               TIME_WAIT = ${tw_count} 條，port range=${port_range} (${tw_pct}%)  [${tw_status}]
               SYN drops = ${syn_drops}   Listen overflows = ${listen_drops}          [${syn_status}]
  明細       : ${nic_detail:-NIC 無錯誤}
  判定依據   : 任一子項 FAIL → FAIL；任一 WARN → WARN；全 PASS → PASS
  對客訴影響 : ${impact}
  建議動作   : $([ "$result" = "PASS" ] && echo "無需動作。" || echo "conntrack 高 → sysctl -w net.netfilter.nf_conntrack_max=... 提升上限 / 縮短 timeout；TIME_WAIT 多 → ip_local_port_range 拉大、tcp_tw_reuse=1；SYN drop → somaxconn、tcp_max_syn_backlog 調高。")
EOF
}

# =============================================================================
# 3/7 AP
# =============================================================================
check_ap() {
    local pid="" comm="" cpu="" mem="" fd_count=0 result="PASS"

    # v1.7: 若 AP_PORT 為空 (自動偵測沒抓到) → 本機非 AP 角色，走 N/A
    if [ -z "${AP_PORT}" ]; then
        d_run "3. AP - 未偵測到 AP port" bash -c "ss -tlnp 2>/dev/null | head -40; echo; echo '(已掃描 common AP port 白名單: ${AP_PORT_SCAN_LIST//|/ })'"
        s_block "3/9" "AP" "N/A" <<EOF
  檢查範圍   : 指定 AP port 有無 listener、該程序 CPU/記憶體/FD 使用、近 1h systemd journal
  檢查指令   : ss -tlnp  (掃描 common AP port 白名單)
  白名單     : ${AP_PORT_SCAN_LIST//|/ }
  偵測結果   : 本機未偵測到任何常見 AP port 的 listener → 推定為非 AP 角色
  判定依據   : N/A  (不適用；不列入 PASS/WARN/FAIL 統計)
  對客訴影響 : 無 — 本機未在跑 AP 服務，客訴若為 AP 連線問題請查真正跑 AP 的主機
  建議動作   : 若本機應為 AP 節點但未偵測到，檢查服務啟動狀態 (systemctl status <svc>) 或用 TS_AP_PORT=xxxx 明確指定；否則略過此項。
EOF
        return 0
    fi

    pid=$(ss -tlnp 2>/dev/null | awk -v p=":${AP_PORT}" '$4 ~ p {print}' | grep -oP 'pid=\K[0-9]+' | head -1)

    local impact=""
    local reason=""
    local cpu_status="N/A" fd_status="N/A"

    if [ -z "${pid}" ]; then
        result="FAIL"
        reason="port ${AP_PORT} 無任何 process 監聽 — AP 服務完全未運作"
        impact="高度嚴重 — 所有連線會立即被 reset，此為客訴「連不進去」的直接原因"
    else
        comm=$(ps -p "${pid}" -o comm= 2>/dev/null | tr -d ' ')
        cpu=$(ps -p "${pid}" -o %cpu= 2>/dev/null | tr -d ' ')
        mem=$(ps -p "${pid}" -o %mem= 2>/dev/null | tr -d ' ')
        fd_count=$(ls /proc/${pid}/fd 2>/dev/null | wc -l)
        cpu_status="PASS"; fd_status="PASS"
        awk -v c="${cpu}" 'BEGIN{exit !(c+0>=90)}' && { cpu_status="WARN"; result=WARN; }
        awk -v c="${cpu}" 'BEGIN{exit !(c+0>=99)}' && { cpu_status="FAIL"; result=FAIL; }
        [ "${fd_count}" -gt 1000 ] && { fd_status="WARN"; [ "${result}" = PASS ] && result=WARN; }
        [ "${fd_count}" -gt 10000 ] && { fd_status="FAIL"; result=FAIL; }
        reason="PID=${pid} (${comm}) CPU=${cpu}% MEM=${mem}% FDs=${fd_count}"
        case "${result}" in
            PASS) impact="無 — AP 程序健康，客訴原因不在本服務進程層" ;;
            WARN) impact="中度 — 程序資源偏高（CPU 接近 100% 或 FD > 1000），高併發時段可能回應緩慢" ;;
            FAIL) impact="高度嚴重 — 程序資源耗盡（CPU pegged 或 FD 近上限），AP 幾乎必定拒絕新連線" ;;
        esac
    fi

    d_run "3. AP - 所有 listener"    bash -c "ss -tlnp 2>/dev/null | head -40"
    d_run "3. AP - 目標 port 狀態"   bash -c "ss -tlnp 2>/dev/null | grep ':${AP_PORT} ' || echo 'port ${AP_PORT} 無 listener'"
    if [ -n "${pid}" ]; then
        d_run "3. AP - 程序詳情"     bash -c "ps -p ${pid} -f; echo; ls -la /proc/${pid}/fd 2>/dev/null | head -22; echo; cat /proc/${pid}/limits 2>/dev/null | head"
        d_run "3. AP - journal 近 1h" bash -c "journalctl --no-pager --since '1 hour ago' _PID=${pid} 2>/dev/null | tail -40; echo; echo '(若為空 = 未走 systemd 或無近期 log)'"
    fi

    s_block "3/9" "AP" "${result}" <<EOF
  檢查範圍   : 指定 AP port 有無 listener、該程序 CPU/記憶體/FD 使用、近 1h systemd journal
  檢查指令   : ss -tlnp | grep ':${AP_PORT} '
               ps -p <PID> -o %cpu,%mem ; ls /proc/<PID>/fd | wc -l
               journalctl _PID=<PID> --since '1 hour ago'
  正常基準   : port 有 listener (PID 存在)
               process CPU  < 90%   (FAIL > 99%)
               process FDs  < 1000  (FAIL > 10000)
  實測數值   : ${reason}   [CPU: ${cpu_status}, FD: ${fd_status}]
  判定依據   : 無 listener → FAIL；CPU 或 FD 達 FAIL 門檻 → FAIL；達 WARN 門檻 → WARN
  對客訴影響 : ${impact}
  建議動作   : $([ "$result" = "PASS" ] && echo "無需動作。" || echo "若 port 無監聽，立刻 systemctl status <svc>；若 CPU 過高，jstack <PID> 或 strace -p <PID>；若 FD 過高，lsof -p <PID> 看洩漏。")
EOF
}

# =============================================================================
# 4/7 Session
# =============================================================================
check_session() {
    local est cw tw syn_sent
    est=$(ss -tn state established 2>/dev/null | tail -n +2 | wc -l)
    cw=$( ss -tn state close-wait  2>/dev/null | tail -n +2 | wc -l)
    tw=$( ss -tn state time-wait   2>/dev/null | tail -n +2 | wc -l)
    syn_sent=$(ss -tn state syn-sent 2>/dev/null | tail -n +2 | wc -l)

    local top_src top_src_cnt=0
    read -r top_src_cnt top_src < <(ss -tn state established 2>/dev/null | tail -n +2 \
        | awk '{n=split($4,a,":"); print a[n-1]}' | sort | uniq -c | sort -rn | head -1)
    top_src="${top_src:-無}"

    local result="PASS"
    local cw_status="PASS" tw_status="PASS" src_status="PASS"
    [ "${cw}" -gt 100 ] && { cw_status="WARN"; result="WARN"; }
    [ "${cw}" -gt 500 ] && { cw_status="FAIL"; result="FAIL"; }
    [ "${tw}" -gt 10000 ] && { tw_status="WARN"; [ "${result}" = PASS ] && result=WARN; }
    [ "${top_src_cnt}" -gt 100 ] && { src_status="WARN"; [ "${result}" = PASS ] && result=WARN; }

    d_run "4. Session - ss -s"        ss -s
    d_run "4. Session - 狀態分布"     bash -c "ss -tn -a 2>/dev/null | awk 'NR>1{print \$1}' | sort | uniq -c | sort -rn"
    d_run "4. Session - Top 10 來源"  bash -c "ss -tn state established 2>/dev/null | tail -n+2 | awk '{n=split(\$4,a,\":\"); print a[n-1]}' | sort | uniq -c | sort -rn | head -10"
    d_run "4. Session - CLOSE_WAIT 明細" bash -c "ss -tnp state close-wait 2>/dev/null | head -30"

    local impact
    case "${result}" in
        PASS) impact="無 — 連線狀態健康" ;;
        WARN) impact="中度 — CLOSE_WAIT > 100 多半是 AP 未正確關 socket，會持續消耗 FD；或單一來源 IP 連線異常多（疑似程式 bug 或攻擊）" ;;
        FAIL) impact="高度 — CLOSE_WAIT 累積嚴重，AP 遲早會因 FD 耗盡或連線上限被擋，客訴「慢/連不進去」高度相關" ;;
    esac

    s_block "4/9" "Session" "${result}" <<EOF
  檢查範圍   : TCP 連線各狀態數量、連線來源 IP 分布
  檢查指令   : ss -tn state established | wc -l
               ss -tn state close-wait  | wc -l
               ss -tn state established | awk 來源 IP 統計
  正常基準   : CLOSE_WAIT < 100   (FAIL > 500)
               TIME_WAIT < 10000  (WARN)
               單一來源 IP 連線 < 100  (WARN)
  實測數值   : ESTABLISHED = ${est}
               CLOSE_WAIT  = ${cw}        [${cw_status}]
               TIME_WAIT   = ${tw}        [${tw_status}]
               SYN_SENT    = ${syn_sent}
               Top source  = ${top_src} (${top_src_cnt:-0} 條)   [${src_status}]
  判定依據   : 任一子項達 FAIL → FAIL；達 WARN → WARN
  對客訴影響 : ${impact}
  建議動作   : $([ "$result" = "PASS" ] && echo "無需動作。" || echo "ss -tnp state close-wait 看是哪個程序累積；若是 AP 請查程式是否在 exception 路徑忘了 close socket；若某 IP 異常多查 fail2ban/iptables。")
EOF
}

# =============================================================================
# 5/7 Storage
# =============================================================================
check_storage() {
    local result="PASS"
    local disk_warn disk_fail inode_warn tmp_pct
    disk_warn=$(df -hP 2>/dev/null | awk 'NR>1 && int($5)>=80 && int($5)<95' | wc -l)
    disk_fail=$(df -hP 2>/dev/null | awk 'NR>1 && int($5)>=95' | wc -l)
    tmp_pct=$(df -hP /tmp 2>/dev/null | awk 'NR>1{gsub(/%/,"",$5); print $5}')
    inode_warn=$(df -i 2>/dev/null | awk 'NR>1 && int($5)>=80 && $5!="-"' | wc -l)

    local disk_status="PASS" tmp_status="PASS" inode_status="PASS"
    [ "${disk_warn}" -gt 0 ] && { disk_status="WARN"; result="WARN"; }
    [ "${disk_fail}" -gt 0 ] && { disk_status="FAIL"; result="FAIL"; }
    [ "${tmp_pct:-0}" -ge 90 ] && { tmp_status="FAIL"; result="FAIL"; }
    [ "${tmp_pct:-0}" -ge 80 ] && [ "${tmp_status}" = "PASS" ] && { tmp_status="WARN"; [ "${result}" = PASS ] && result=WARN; }
    [ "${inode_warn}" -gt 0 ] && { inode_status="WARN"; [ "${result}" = PASS ] && result=WARN; }

    local worst_fs
    worst_fs=$(df -hP 2>/dev/null | awk 'NR>1{gsub(/%/,"",$5); print $5, $6}' | sort -rn | head -1 | awk '{printf "%s%% (%s)",$1,$2}')

    d_run "5. Storage - df -hP"    df -hP
    d_run "5. Storage - df -i"     df -i
    d_run "5. Storage - /tmp 佔用" bash -c "du -sh /tmp/* 2>/dev/null | sort -rh | head -10"

    local impact
    case "${result}" in
        PASS) impact="無 — 磁碟空間充足，非客訴原因" ;;
        WARN) impact="中度 — 有檔案系統接近 80%，持續成長會演變成 FAIL；/tmp 滿會讓許多 AP 寫入失敗" ;;
        FAIL) impact="高度 — 有 FS 超過 95% 或 /tmp 超過 90%，寫入已開始或即將失敗，AP 會出錯" ;;
    esac

    s_block "5/9" "Storage" "${result}" <<EOF
  檢查範圍   : 所有檔案系統使用率、inode 使用率、/tmp 狀態
  檢查指令   : df -hP
               df -i
               du -sh /tmp/*
  正常基準   : 所有 FS < 80%   (WARN 80-94%, FAIL >=95%)
               /tmp < 80%      (FAIL >=90%)
               所有 inode < 80%
  實測數值   : FS 80-94%: ${disk_warn} 個     FS >=95%: ${disk_fail} 個   [${disk_status}]
               最高使用率: ${worst_fs:-N/A}
               /tmp = ${tmp_pct:-0}%                                      [${tmp_status}]
               Inode >=80%: ${inode_warn} 個                              [${inode_status}]
  判定依據   : 任一子項 FAIL → FAIL；任一 WARN → WARN
  對客訴影響 : ${impact}
  建議動作   : $([ "$result" = "PASS" ] && echo "無需動作。" || echo "mod_file 第 1 項搜尋大檔；mod_file 第 7 項壓縮舊 log；/tmp 可安全清 tmpwatch。")
EOF
}

# =============================================================================
# 6/7 時間 / 憑證
# =============================================================================
check_time_cert() {
    local result="PASS"
    local ntp_sync ntp_source time_drift
    ntp_sync=$(timedatectl 2>/dev/null | awk -F: '/synchronized/{gsub(/^ */,"",$2); print $2}')
    ntp_sync="${ntp_sync:-unknown}"
    ntp_source=$(chronyc tracking 2>/dev/null | awk -F: '/Reference/{gsub(/^ */,"",$2); print $2}' | head -1)
    [ -z "${ntp_source}" ] && ntp_source=$(ntpq -p 2>/dev/null | awk '/^\*/{print $1}' | head -1)
    time_drift=$(chronyc tracking 2>/dev/null | awk '/Last offset/{print $4, $5}')

    [ "${ntp_sync}" != "yes" ] && result="WARN"

    local cert_warn=0 cert_fail=0
    local defks="${JAVA_HOME:-/usr/lib/jvm/default}/lib/security/cacerts"
    if command -v keytool >/dev/null 2>&1 && [ -f "${defks}" ]; then
        read -r cert_warn cert_fail < <(keytool -list -v -keystore "${defks}" -storepass changeit 2>/dev/null | awk '
            /Valid from/ {
                sub(/.*until: /,""); exp=$0
                cmd="date -d \""exp"\" +%s 2>/dev/null"
                if ((cmd|getline ts)>0) {
                    d=int((ts-systime())/86400)
                    if (d<0) f++
                    else if (d<30) w++
                }
                close(cmd)
            }
            END { print w+0, f+0 }')
    fi
    [ "${cert_warn:-0}" -gt 0 ] && [ "${result}" = PASS ] && result=WARN
    [ "${cert_fail:-0}" -gt 0 ] && result=FAIL

    d_run "6. 時間 - timedatectl"    timedatectl
    d_run "6. 時間 - chrony/ntp"     bash -c "chronyc tracking 2>/dev/null; chronyc sources 2>/dev/null; ntpq -p 2>/dev/null"

    local ntp_status="PASS"; [ "${ntp_sync}" != "yes" ] && ntp_status="WARN"
    local cert_status="PASS"
    [ "${cert_warn:-0}" -gt 0 ] && cert_status="WARN"
    [ "${cert_fail:-0}" -gt 0 ] && cert_status="FAIL"

    local impact
    case "${result}" in
        PASS) impact="無 — 時間與憑證均健康" ;;
        WARN) impact="中度 — NTP 未同步會導致日誌時間亂、Kerberos/TLS 偶發失敗；憑證 30 天內到期需進入更新流程" ;;
        FAIL) impact="高度 — 已有憑證過期，相依服務 SSL handshake 會失敗；若為 API gateway 憑證則客戶端直接 TLS 錯誤" ;;
    esac

    s_block "6/9" "時間/憑證" "${result}" <<EOF
  檢查範圍   : NTP 同步狀態與偏差、系統預設 Java keystore 內憑證到期
  檢查指令   : timedatectl ; chronyc tracking ; ntpq -p
               keytool -list -v -keystore ${defks}
  正常基準   : NTP synchronized = yes
               憑證 30 天內到期 = 0 張   (FAIL: 已過期)
  實測數值   : NTP synced   = ${ntp_sync}     [${ntp_status}]
               NTP source   = ${ntp_source:-(無)}
               Last offset  = ${time_drift:-N/A}
               憑證 30天內到期 = ${cert_warn:-0} 張
               憑證 已過期      = ${cert_fail:-0} 張      [${cert_status}]
  判定依據   : NTP 未同步或有 30 天內到期憑證 → WARN；有已過期憑證 → FAIL
  對客訴影響 : ${impact}
  建議動作   : $([ "$result" = "PASS" ] && echo "無需動作。" || echo "systemctl restart chronyd 或 ntpd；憑證即將到期請走 CA 更新流程，勿等過期才處理。")
EOF
}

# =============================================================================
# 7/7 DB
# =============================================================================
check_db() {
    local result="PASS"
    local detected="" detail_table=""

    if ! declare -F detect_oracle >/dev/null 2>&1; then
        s_block "7/9" "DB" "PASS" <<EOF
  檢查範圍   : 6 種 DB 偵測與連通
  檢查指令   : mod_db.sh (不可用)
  結果       : mod_db.sh 未載入，跳過。請確認 ${DB_MOD} 存在並可讀。
  對客訴影響 : 未知 (需手動進主選單 13) DB 健康檢查 看)
EOF
        return
    fi

    local db m found=0 outputs=""
    for db in oracle mssql mysql db2 pg mongo; do
        m=$(detect_${db})
        [ "${m}" = "none" ] && continue
        found=1
        detected+="${db}:${m}  "
        local out rc
        out=$(check_${db} "${m}" 2>&1); rc=$?
        local label="PASS"
        case "${rc}" in
            1) label="WARN"; [ "${result}" = PASS ] && result=WARN ;;
            2) label="FAIL"; result=FAIL ;;
        esac
        # 取第二行（PASS/FAIL/WARN 的敘述）作為 summary note
        local note
        note=$(echo "${out}" | sed -n '2p')
        detail_table+="$(printf '%-8s %-6s %s\n' "${db}" "${label}" "${note:-(無輸出)}")
"
        outputs+="${out}"$'\n\n'
    done

    # 寫 detail
    d_sec "7. DB - 偵測 + 檢查完整輸出"
    [ -n "${outputs}" ] && echo "${outputs}" >> "${DETAIL}"
    [ "${found}" -eq 0 ] && echo "(本機無任何 DB server / client)" >> "${DETAIL}"

    local impact
    if [ "${found}" -eq 0 ]; then
        impact="無 — 本機不是 DB server 也沒 DB client，客訴與 DB 無關"
    else
        case "${result}" in
            PASS) impact="無 — 偵測到的 DB 全部連通且健康" ;;
            WARN) impact="中度 — 有 DB 有警訊（如 replication lag 偏高、連線數接近上限），尖峰時段可能影響查詢延遲" ;;
            FAIL) impact="高度嚴重 — 有 DB 無法連通，依賴此 DB 的 AP 必然出錯；此為客訴「連不進去/慢」的直接原因之一" ;;
        esac
    fi

    s_block "7/9" "DB" "${result}" <<EOF
  檢查範圍   : 自動偵測 Oracle / MSSQL / MySQL / DB2 / PostgreSQL / MongoDB
               對偵測到的 DB 跑連通性、版本、連線數、replication lag、空間
  檢查指令   : detect_<db>  (ss port listen + client 指令 + /var/lib 目錄)
               check_<db>   (透過各 DB 原生認證檔執行 health SQL)
  正常基準   : 每個偵測到的 DB 連通成功且無 WARN/FAIL 子項
  偵測結果   : ${detected:-無任何 DB}
  明細       :
${detail_table:-  (本機無 DB)}
  判定依據   : 任一 DB 回 FAIL → FAIL；任一 WARN → WARN；全 PASS 或無 DB → PASS
  對客訴影響 : ${impact}
  建議動作   : $([ "$result" = "PASS" ] && echo "無需動作。" || echo "失敗的 DB 請到主選單 13) DB 健康檢查 手動測；錯誤訊息在 detail 報告 '7. DB' 段。另檢查 ${CONF_FILE} 是否正確。")
EOF
}

# =============================================================================
# 8/9 Infra 穩定度 (OOM / MCE / systemd failed / kernel tainted)
# =============================================================================
check_infra() {
    local result="PASS"
    local oom_cnt mce_cnt failed_cnt tainted worst=""

    # OOM kill (近 24h)
    oom_cnt=$(journalctl -k --since '24 hour ago' 2>/dev/null | grep -ci 'killed process')
    [ -z "${oom_cnt}" ] && oom_cnt=$(dmesg -T 2>/dev/null | grep -ci 'killed process')
    # MCE / ECC (dmesg 全)
    mce_cnt=$(dmesg -T 2>/dev/null | grep -ciE 'mce:|hardware error|edac.*correct|ecc error')
    # systemd failed
    failed_cnt=$(systemctl --failed --no-legend 2>/dev/null | wc -l)
    # kernel tainted (bitmask)
    tainted=$(cat /proc/sys/kernel/tainted 2>/dev/null || echo 0)

    local oom_status="PASS" mce_status="PASS" failed_status="PASS" tainted_status="PASS"
    [ "${oom_cnt:-0}" -gt 0 ] && { oom_status="WARN"; result="WARN"; worst="近 24h OOM=${oom_cnt}"; }
    [ "${oom_cnt:-0}" -gt 3 ] && { oom_status="FAIL"; result="FAIL"; worst="近 24h OOM=${oom_cnt} (頻繁)"; }
    [ "${mce_cnt:-0}" -gt 0 ] && { mce_status="WARN"; [ "${result}" = PASS ] && result=WARN; }
    [ "${failed_cnt:-0}" -gt 0 ] && { failed_status="WARN"; [ "${result}" = PASS ] && result=WARN; }
    [ "${failed_cnt:-0}" -gt 3 ] && { failed_status="FAIL"; result=FAIL; }
    [ "${tainted:-0}" -ne 0 ] && { tainted_status="WARN"; [ "${result}" = PASS ] && result=WARN; }

    local failed_list
    failed_list=$(systemctl --failed --no-legend 2>/dev/null | awk '{print $1}' | tr '\n' ',' | sed 's/,$//')

    d_run "8. Infra - OOM kill 近 24h"  bash -c "journalctl -k --since '24 hour ago' 2>/dev/null | grep -i 'killed process' | tail -20; echo; dmesg -T 2>/dev/null | grep -i 'killed process' | tail -20"
    d_run "8. Infra - MCE / ECC"        bash -c "dmesg -T 2>/dev/null | grep -iE 'mce:|hardware error|edac|ecc' | tail -20"
    d_run "8. Infra - systemd --failed" systemctl --failed
    d_run "8. Infra - kernel tainted"   bash -c "echo 'tainted=$(cat /proc/sys/kernel/tainted)'; if command -v dmesg >/dev/null; then dmesg -T 2>/dev/null | grep -i 'taint' | tail -5; fi"

    local impact
    case "${result}" in
        PASS) impact="無 — 系統近期無 OOM、無硬體錯誤、所有服務健康" ;;
        WARN) impact="中度 — 基礎設施層面有警訊，現在可能穩定但不代表先前；客訴時段若與事件吻合則高度相關" ;;
        FAIL) impact="高度 — OOM 頻繁或有 service failed，主機已不穩定，客訴與此高度相關" ;;
    esac

    s_block "8/9" "Infra 穩定" "${result}" <<EOF
  檢查範圍   : OOM kill 歷史 / MCE / ECC / systemd failed units / kernel tainted
  檢查指令   : journalctl -k --since '24 hour ago' | grep -i 'killed process'
               dmesg -T | grep -iE 'mce|hardware error|edac'
               systemctl --failed
               cat /proc/sys/kernel/tainted
  正常基準   : 近 24h OOM kill = 0 (FAIL > 3)
               MCE / ECC 錯誤 = 0
               systemd failed units = 0 (FAIL > 3)
               kernel tainted = 0
  實測數值   : 近 24h OOM kill = ${oom_cnt:-0}               [${oom_status}]
               MCE / ECC 錯誤  = ${mce_cnt:-0}               [${mce_status}]
               Failed units    = ${failed_cnt:-0}  ${failed_list:+(${failed_list})}     [${failed_status}]
               Kernel tainted  = ${tainted:-0}               [${tainted_status}]
  判定依據   : 任一子項 FAIL → FAIL；任一 WARN → WARN
  對客訴影響 : ${impact}
  建議動作   : $([ "$result" = "PASS" ] && echo "無需動作。" || echo "OOM → 查 dmesg 看哪支進程被殺、調整 MemMax / swap；MCE → 立即請硬體廠商換記憶體；failed unit → systemctl status <name>；tainted 非 0 → 看 dmesg 找原因。")
EOF
}

# =============================================================================
# 9/9 運維軌跡 (近 1 小時誰登入 / 誰改 /etc / 誰 restart service)
# =============================================================================
check_ops_trail() {
    local result="PASS"
    # 近 1h 登入
    local recent_login_raw recent_login_cnt
    recent_login_raw=$(last -s "$(date -d '1 hour ago' '+%Y-%m-%d %H:%M')" 2>/dev/null | head -20)
    recent_login_cnt=$(echo "${recent_login_raw}" | grep -c -v '^$\|^wtmp begins' 2>/dev/null)
    # 近 1h /etc 變更
    local etc_mod_raw etc_mod_cnt
    etc_mod_raw=$(find /etc -mmin -60 -type f 2>/dev/null | head -20)
    etc_mod_cnt=$(echo "${etc_mod_raw}" | grep -c '^/')
    # 近 1h restart
    local svc_event_raw svc_event_cnt
    svc_event_raw=$(journalctl --since '1 hour ago' 2>/dev/null | grep -iE 'Started|Stopped|Restarted' | grep -iE 'service|unit|\.service' | tail -20)
    svc_event_cnt=$(echo "${svc_event_raw}" | grep -c -v '^$')

    # 僅做資訊性提示，預設 PASS；只要有活動就 WARN（提醒 SP：這些剛好在客訴窗內）
    local login_status="PASS" etc_status="PASS" svc_status="PASS"
    [ "${recent_login_cnt:-0}" -gt 0 ] && { login_status="INFO"; }
    [ "${etc_mod_cnt:-0}" -gt 0 ]      && { etc_status="INFO"; }
    [ "${svc_event_cnt:-0}" -gt 0 ]    && { svc_status="INFO"; }
    # 若近 1h 內同時發生登入 + 改 /etc + restart（3 個都有）→ WARN 提醒 SP 務必自辯
    if [ "${recent_login_cnt:-0}" -gt 0 ] && [ "${etc_mod_cnt:-0}" -gt 0 ] && [ "${svc_event_cnt:-0}" -gt 0 ]; then
        result="WARN"
    fi

    d_run "9. 運維 - 近 1h 登入"      bash -c "last -s \"$(date -d '1 hour ago' '+%Y-%m-%d %H:%M')\" 2>/dev/null | head -20"
    d_run "9. 運維 - 近 1h /etc 變更"  bash -c "find /etc -mmin -60 -type f -printf '%TY-%Tm-%Td %TH:%TM  %p\n' 2>/dev/null | head -20"
    d_run "9. 運維 - 近 1h service 事件" bash -c "journalctl --since '1 hour ago' 2>/dev/null | grep -iE 'Started|Stopped|Restarted' | grep -iE 'service|\.service' | tail -20"

    local impact
    if [ "${result}" = "WARN" ]; then
        impact="重要 — 近 1h 內本機同時發生「有人登入 + 改 /etc + service 被 restart」，這剛好是典型「最近動過」情境。SP 被主管問「你剛剛是不是動過什麼」時，本塊的 detail 就是答案，務必審閱確認每項是否預期。"
    else
        impact="低 — 近 1h 僅有零星或無維運動作，客訴非運維誤動作引起"
    fi

    s_block "9/9" "運維軌跡" "${result}" <<EOF
  檢查範圍   : 近 1 小時內本機發生的運維動作 (登入/改檔/重啟服務)
  目的       : 金融業 SP 被問「你剛剛是不是動過什麼」時能秒回答
  檢查指令   : last -s "1 hour ago"
               find /etc -mmin -60 -type f
               journalctl --since '1 hour ago' | grep Started|Stopped|Restarted
  正常基準   : 資訊性檢查，不會 FAIL。若 3 項同時發生 → WARN 請 SP 務必自辯
  實測數值   : 近 1h 登入人次     = ${recent_login_cnt:-0}              [${login_status}]
               近 1h /etc 異動檔  = ${etc_mod_cnt:-0}              [${etc_status}]
               近 1h service 事件 = ${svc_event_cnt:-0}              [${svc_status}]
  判定依據   : 3 項皆 > 0 → WARN (剛動過，客訴可能相關)；否則 PASS
  對客訴影響 : ${impact}
  建議動作   : $([ "$result" = "PASS" ] && echo "無需動作。" || echo "本塊 detail 逐項核對：登入者是你嗎？改的檔是你的預期嗎？重啟的 service 是你做的嗎？若任一否定 → 立刻升級為安全事件，查 /var/log/audit/audit.log。")
EOF
}

# =============================================================================
# Appendix A 應用層深度 (選配，需 ${CASLOG_CONF}/app.conf)
# =============================================================================
appendix_a() {
    [ ! -f "${APP_CONF}" ] && return 0

    {
        echo
        echo "============================================================"
        echo " Appendix A  應用層深度 (app.conf 驅動)"
        echo "============================================================"
        echo " Config: ${APP_CONF}"
    } | tee -a "${SUMMARY}"

    # A1 — AP log 近 N 分鐘 ERROR 統計
    local total_err=0 matched_files=0
    if [ -n "${AP_LOG_PATHS:-}" ]; then
        echo "-- A1 AP log ERROR 統計 (近 ${AP_LOG_WINDOW_MIN:-60} 分鐘) --" | tee -a "${SUMMARY}"
        d_sec "Appendix A1 — AP log ERROR 統計"
        for pattern in ${AP_LOG_PATHS}; do
            for f in $pattern; do
                [ -f "$f" ] || continue
                # 取近 N 分鐘內的行並 grep
                local age_min
                age_min=$(( ( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0) ) / 60 ))
                if [ "${age_min}" -le "${AP_LOG_WINDOW_MIN:-60}" ]; then
                    local cnt
                    cnt=$(tail -n 5000 "$f" 2>/dev/null | grep -Ec "${AP_LOG_ERROR_PATTERN:-ERROR|Exception}")
                    total_err=$((total_err + cnt))
                    matched_files=$((matched_files + 1))
                    printf "  %-60s  %d 筆錯誤\n" "${f}" "${cnt}" | tee -a "${SUMMARY}"
                    echo "## ${f} ##" >> "${DETAIL}"
                    tail -n 5000 "$f" 2>/dev/null | grep -E "${AP_LOG_ERROR_PATTERN:-ERROR|Exception}" | tail -30 >> "${DETAIL}"
                fi
            done
        done
        [ "${matched_files}" -eq 0 ] && echo "  (無最近 ${AP_LOG_WINDOW_MIN:-60} 分鐘內異動的 AP log)" | tee -a "${SUMMARY}"
        echo "  總計 ${total_err} 筆錯誤於 ${matched_files} 個檔" | tee -a "${SUMMARY}"
    fi

    # A2 — Java GC pause
    if command -v jstat >/dev/null 2>&1; then
        local java_pids=""
        if [ -n "${JAVA_PIDS:-}" ]; then
            java_pids="${JAVA_PIDS}"
        elif [ -n "${JAVA_SVC_NAMES:-}" ]; then
            for sv in ${JAVA_SVC_NAMES}; do
                java_pids+="$(pgrep -f "$sv") "
            done
        else
            java_pids=$(pgrep -f java | tr '\n' ' ')
        fi
        echo | tee -a "${SUMMARY}"
        echo "-- A2 Java GC 統計 (jstat -gc) --" | tee -a "${SUMMARY}"
        d_sec "Appendix A2 — Java GC"
        if [ -z "${java_pids// /}" ]; then
            echo "  (未偵測到 Java 程序)" | tee -a "${SUMMARY}"
        else
            for pid in ${java_pids}; do
                echo "## PID=${pid} ##" | tee -a "${SUMMARY}"
                jstat -gc "$pid" 2>&1 | tee -a "${SUMMARY}" >> "${DETAIL}"
                # Full GC 次數 FGC、Full GC 累積時間 FGCT
                local fgc fgct
                fgc=$(jstat -gc "$pid" 2>/dev/null | awk 'NR==2{print $14}')
                fgct=$(jstat -gc "$pid" 2>/dev/null | awk 'NR==2{print $16}')
                echo "  Full GC 次數: ${fgc:-N/A}  累積秒數: ${fgct:-N/A}" | tee -a "${SUMMARY}"
            done
        fi
    else
        echo "  (jstat 未安裝，跳過 A2；請裝 JDK 即有)" | tee -a "${SUMMARY}"
    fi

    # A3 — Java Thread 狀態分佈
    if command -v jstack >/dev/null 2>&1 && [ -n "${java_pids:-}" ]; then
        echo | tee -a "${SUMMARY}"
        echo "-- A3 Java Thread 狀態分佈 --" | tee -a "${SUMMARY}"
        d_sec "Appendix A3 — Java Thread 狀態"
        for pid in ${java_pids}; do
            echo "## PID=${pid} ##" | tee -a "${SUMMARY}"
            jstack "$pid" 2>/dev/null | awk '/State:/{print $2}' | sort | uniq -c | sort -rn | tee -a "${SUMMARY}" >> "${DETAIL}"
        done
    fi

    audit_log "Troubleshoot appendix A" "OK" "${APP_CONF}"
}

# =============================================================================
# Main
# =============================================================================
header
echo "-- 開始檢查 (9 個面向) --"
echo

check_load
check_net
check_ap
check_session
check_storage
check_time_cert
check_db
check_infra
check_ops_trail
# v1.5: appendix_a 的 stdout 也導走 (其 tee 仍會寫 SUMMARY 檔)，避免在 top summary 之前先噴 app 細項
appendix_a > /dev/null

# ========================================================================
# v1.5: 結尾輸出重構 — 先 top summary (一眼看到問題) 再細項
# 流程:
#   1. 從 RESULT[] 算統計
#   2. 組 top summary (一張字卡就能下判讀)
#   3. 印到 stdout: top summary → 「完整細項」分隔線 → cat SUMMARY (header+9 面向+appendix)
#   4. 把 SUMMARY 檔重組為「top summary + 原內容」，讓離線看檔也是這個順序
# ========================================================================
pass=0; warn=0; fail=0; na=0
for k in "${!RESULT[@]}"; do
    case "${RESULT[$k]}" in
        PASS) pass=$((pass+1)) ;;
        WARN) warn=$((warn+1)) ;;
        FAIL) fail=$((fail+1)) ;;
        N/A)  na=$((na+1))    ;;
    esac
done
applicable=$((pass + warn + fail))   # N/A 不算在總數內

# 客訴判讀語 (v1.7: N/A 不計 fail/warn，但 verdict 會附註 N/A 數量)
na_note=""
[ "${na}" -gt 0 ] && na_note="  (另有 ${na} 項 N/A: 本機不適用)"

if [ "${fail}" -gt 0 ]; then
    verdict_state="${RED:-}異常 — 系統有明確故障${RST:-}"
    relate_client="高度相關 (FAIL 即為客訴直接原因)"
elif [ "${warn}" -gt 0 ]; then
    verdict_state="${YEL:-}警告 — 有可觀察項${RST:-}"
    relate_client="可能相關 (WARN 項可能是累積/偶發原因)"
else
    verdict_state="健康 (${pass}/${applicable} PASS${na_note})"
    if [ "${na}" -gt 0 ]; then
        relate_client="低度相關 (本機非完整 AP 角色，建議往真正跑 AP 的主機排查)"
    else
        relate_client="低度相關 (本機 9/9 通過，建議往上游/AP/DB 排查)"
    fi
fi

# 列出某狀態的所有項目
print_state_items() {
    local target_state="$1"
    for n in "1/9" "2/9" "3/9" "4/9" "5/9" "6/9" "7/9" "8/9" "9/9"; do
        [ "${RESULT[$n]:-}" = "${target_state}" ] || continue
        printf "   [%s] %-10s %s\n" "${n}" "${NAME[$n]:-}" "${IMPACT[$n]:-}"
        printf "          動作 → %s\n" "${ACTION[$n]:-無需動作。}"
    done
}

# 組 top summary → 暫存檔 (之後要印到 stdout + prepend 到 SUMMARY)
TOP_TMP="$(mktemp 2>/dev/null || echo /tmp/ts_top.$$)"
{
    echo
    echo "════════════════════════════════════════════════════════════════════"
    printf " 主機狀態: %b\n" "${verdict_state}"
    printf " 統計:     PASS=%d  WARN=%d  FAIL=%d  N/A=%d      主機: %s  時間: %s\n" \
           "${pass}" "${warn}" "${fail}" "${na}" "${HOST}" "$(date '+%Y-%m-%d %H:%M:%S')"
    echo "────────────────────────────────────────────────────────────────────"

    if [ "${fail}" -gt 0 ]; then
        printf " %b■ FAIL 項 (立即處理)%b\n" "${RED:-}" "${RST:-}"
        print_state_items "FAIL"
        echo
    fi
    if [ "${warn}" -gt 0 ]; then
        printf " %b● WARN 項 (排程處理)%b\n" "${YEL:-}" "${RST:-}"
        print_state_items "WARN"
        echo
    fi
    if [ "${fail}" -eq 0 ] && [ "${warn}" -eq 0 ]; then
        if [ "${na}" -gt 0 ]; then
            printf " 適用項目 %d 項皆 PASS；另有 %d 項 N/A (不適用於本機角色)\n" "${applicable}" "${na}"
            # 列出 N/A 項
            for n in "1/9" "2/9" "3/9" "4/9" "5/9" "6/9" "7/9" "8/9" "9/9"; do
                [ "${RESULT[$n]:-}" = "N/A" ] || continue
                printf "   [%s] %-10s %s\n" "${n}" "${NAME[$n]:-}" "${IMPACT[$n]:-}"
            done
        else
            echo " 所有 9 個面向皆 PASS — 本機無異常"
        fi
        echo
    fi

    printf " 客訴「慢 / 連不進去」: %s\n" "${relate_client}"
    echo " 完整細項: ${SUMMARY}"
    echo " 深度記錄: ${DETAIL}"
    echo "════════════════════════════════════════════════════════════════════"
    echo
} > "${TOP_TMP}"

# 1) 先印 top summary 到 stdout (永遠)
cat "${TOP_TMP}"

# 2) 依 VERBOSE 決定是否在 stdout 接著印完整細項
if [ "${VERBOSE:-0}" = "1" ]; then
    echo "─────────────────────── 以下為完整細項 ───────────────────────"
    cat "${SUMMARY}"
else
    # 簡潔模式: 不 stream 細項，只提示檔案位置
    cat <<TIP

 ▸ 詳情請開報告檔:  less ${SUMMARY}
 ▸ 或重跑加參數看細項:  bash ${BASH_SOURCE[0]##*/} -m
TIP
fi

# 3) 把 SUMMARY 檔重組: top summary 在最前 (離線看檔也是一樣順序)
SUM_TMP="$(mktemp 2>/dev/null || echo /tmp/ts_sum.$$)"
{
    cat "${TOP_TMP}"
    echo "─────────────────────── 以下為完整細項 ───────────────────────"
    cat "${SUMMARY}"
} > "${SUM_TMP}"
mv "${SUM_TMP}" "${SUMMARY}"
rm -f "${TOP_TMP}"

# 4) detail 檔尾端串 summary 快照 (維持原行為)
{
    echo ""
    echo "================ SUMMARY SNAPSHOT ================"
    cat "${SUMMARY}"
} >> "${DETAIL}"

# 5) 審計 log
audit_log "Troubleshoot report" "OK" "PASS=${pass} WARN=${warn} FAIL=${fail}  ${SUMMARY}"

echo
[ "${TS_NONINTERACTIVE:-0}" = "1" ] || pause
