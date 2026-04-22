#!/bin/bash
# mod_trading.sh - 股票交易系統特化指標 (lite-v0.2)
# 需 conf/trading.conf 啟用；若該檔不存在則顯示啟用指引後返回
# 特色：
#   - 時段感知 (盤前/早盤/尾盤/盤後/非交易)
#   - pps 1 秒取樣 (封包率比頻寬更敏感)
#   - 交易所 gateway ping RTT
#   - 股票嚴格閾值 (retrans 0.01% 就警告)
#   - IRQ affinity / softirq 分布
_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_HERE}/LinuxMenu.sh" 2>/dev/null
: "${YEL:=\033[1;33m}"; : "${RED:=\033[0;31m}"; : "${RST:=\033[0m}"

TRADING_CONF="${CASLOG_CONF}/trading.conf"

# ─── 啟用檢查 ───
if [ ! -f "${TRADING_CONF}" ]; then
    clear
    cat <<EOF
======================================================
 交易系統指標
======================================================

  ⚠️  ${TRADING_CONF} 不存在
      本機不視為交易系統主機，此模組未啟用

  若要啟用 (僅限真的是股票交易系統主機)：

   1. cd ${CASLOG_CONF}
   2. cp trading.conf.sample trading.conf
   3. chmod 600 trading.conf
   4. 編輯 trading.conf，填入實際值：
        EXCHANGE_GATEWAYS="<gw1_ip>:GW-A <gw2_ip>:GW-B"
        FIX_PORTS="9876 9877"
        TRADING_HOURS="09:00-13:30"
        MCAST_GROUPS="<mcast_ip>:6100"       (選配)
   5. 回主選單，再按 18

  注意：trading.conf 含內部拓撲，屬敏感資訊
        chmod 600 且不要 commit 進 git

EOF
    pause
    exit 0
fi

# shellcheck disable=SC1090
. "${TRADING_CONF}"

# 檢查必要欄位
if [ -z "${EXCHANGE_GATEWAYS:-}" ] && [ -z "${FIX_PORTS:-}" ] && [ -z "${MCAST_GROUPS:-}" ]; then
    clear
    echo "======================================================"
    echo " 交易系統指標"
    echo "======================================================"
    echo "  ⚠️  ${TRADING_CONF} 存在但必要欄位都空白"
    echo "      EXCHANGE_GATEWAYS / FIX_PORTS / MCAST_GROUPS 至少要填一個"
    echo
    pause
    exit 0
fi

# ─── 時段判斷 ───
detect_trading_phase() {
    local now=$(date '+%H:%M')
    local dow=$(date '+%u')   # 1-5=weekday
    if [ "${WEEKEND_SKIP:-1}" = "1" ] && [ "${dow}" -ge 6 ]; then
        echo "非交易日 (週末)"
        return
    fi
    _in_range() {
        local n="$1" rng="$2"
        [ -z "${rng}" ] && return 1
        local start end
        start="${rng%-*}"
        end="${rng#*-}"
        [[ "${n}" > "${start}" || "${n}" == "${start}" ]] && [[ "${n}" < "${end}" ]]
    }
    if _in_range "${now}" "${CLOSING_AUCTION:-}";   then echo "尾盤集合競價"; return; fi
    if _in_range "${now}" "${TRADING_HOURS:-}";      then echo "交易時段"; return; fi
    if _in_range "${now}" "${PREMARKET_HOURS:-}";    then echo "盤前測試"; return; fi
    if _in_range "${now}" "${POSTMARKET_HOURS:-}";   then echo "盤後清算"; return; fi
    echo "非交易時段"
}

# ─── pps 1 秒取樣 ───
measure_pps() {
    local pnic rx0 tx0 rxp0 txp0 rx1 tx1 rxp1 txp1
    pnic=$(ip -o route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="dev")print $(i+1)}' | head -1)
    pnic="${pnic:-eth0}"
    [ ! -r /sys/class/net/${pnic}/statistics/rx_bytes ] && return
    rxp0=$(cat /sys/class/net/${pnic}/statistics/rx_packets)
    txp0=$(cat /sys/class/net/${pnic}/statistics/tx_packets)
    rx0=$(cat /sys/class/net/${pnic}/statistics/rx_bytes)
    tx0=$(cat /sys/class/net/${pnic}/statistics/tx_bytes)
    sleep 1
    rxp1=$(cat /sys/class/net/${pnic}/statistics/rx_packets)
    txp1=$(cat /sys/class/net/${pnic}/statistics/tx_packets)
    rx1=$(cat /sys/class/net/${pnic}/statistics/rx_bytes)
    tx1=$(cat /sys/class/net/${pnic}/statistics/tx_bytes)
    RX_PPS=$((rxp1 - rxp0))
    TX_PPS=$((txp1 - txp0))
    RX_MBPS=$(awk -v a="${rx0}" -v b="${rx1}" 'BEGIN{printf "%.1f",(b-a)/1048576}')
    TX_MBPS=$(awk -v a="${tx0}" -v b="${tx1}" 'BEGIN{printf "%.1f",(b-a)/1048576}')
    PNIC="${pnic}"
}

# ─── 交易所 gateway ping ───
ping_gateway() {
    local entry="$1"
    local ip="${entry%%:*}"
    local label="${entry##*:}"
    [ "${ip}" = "${label}" ] && label="${ip}"
    local out rtt rc
    out=$(timeout 2 ping -c 2 -W 1 "${ip}" 2>&1)
    rc=$?
    if [ $rc -ne 0 ]; then
        echo "  🔴 ${label} ${ip}     不通 (ping fail)"
        return
    fi
    rtt=$(echo "${out}" | awk -F'/' '/rtt|round-trip/{printf "%.2f", $5}')
    [ -z "${rtt}" ] && rtt="N/A"
    local state="🟢"
    awk -v r="${rtt}" -v w="${RTT_WARN_MS:-5}" 'BEGIN{exit !(r>=w)}' && state="🟡"
    awk -v r="${rtt}" -v f="${RTT_FAIL_MS:-20}" 'BEGIN{exit !(r>=f)}' && state="🔴"
    printf "  %s %-10s %-15s  RTT %s ms\n" "${state}" "${label}" "${ip}" "${rtt}"
}

# ─── FIX port sessions ───
count_fix_sessions() {
    local port="$1"
    local est
    est=$(ss -tn state established 2>/dev/null | awk -v p=":${port}" '$4 ~ p || $5 ~ p' | wc -l)
    echo "${est}"
}

# ─── IRQ 分布 ───
irq_balance() {
    # /proc/interrupts 的網卡相關 IRQ 每 core 佔比
    if [ ! -r /proc/interrupts ]; then
        echo "  (/proc/interrupts 不可讀)"
        return
    fi
    awk '
        NR==1 {
            for (i=1; i<=NF; i++) if ($i ~ /CPU/) cpus[i]=$i
            next
        }
        /eth|ens|eno|enp/ {
            for (i in cpus) sum[cpus[i]] += $i
        }
        END {
            total = 0
            for (c in sum) total += sum[c]
            if (total == 0) { print "  (無網卡 IRQ 資料)"; exit }
            for (c in sum) {
                pct = (sum[c]/total)*100
                printf "  %s  %6d  (%.0f%%)\n", c, sum[c], pct
            }
        }
    ' /proc/interrupts | sort
}

# ─── Multicast group 狀態 ───
check_mcast() {
    local entry="$1"
    local grp="${entry%%:*}"
    local port="${entry##*:}"
    if [ -r /proc/net/igmp ]; then
        if grep -q "${grp}" /proc/net/igmp 2>/dev/null; then
            echo "  🟢 ${grp}:${port}   已訂閱"
        else
            echo "  🟡 ${grp}:${port}   未見訂閱記錄"
        fi
    fi
}

# ─── 主流程 ───
run_dashboard() {
    clear
    local phase=$(detect_trading_phase)
    local ts=$(date '+%Y-%m-%d %H:%M:%S')

    echo "======================================================"
    echo " 交易系統指標    當下: ${phase}    ${ts}"
    echo "======================================================"
    echo

    measure_pps

    # 流量
    if [ -n "${PNIC:-}" ]; then
        echo "── packet / pps (${PNIC}, 1 秒取樣) ──"
        # 時段判斷流量是否合理
        local pps_state="🟢" pps_hint=""
        if [[ "${phase}" =~ 交易|尾盤 ]]; then
            [ "${RX_PPS:-0}" -lt "${PPS_TRADING_MIN:-1000}" ] 2>/dev/null && pps_state="🔴" && pps_hint="  (交易時段 pps 偏低 — AP 可能斷)"
        elif [[ "${phase}" == "非交易時段" ]] || [[ "${phase}" == "非交易日"* ]]; then
            [ "${RX_PPS:-0}" -gt "${PPS_NONTRADING_MAX:-500}" ] 2>/dev/null && pps_state="🟡" && pps_hint="  (非交易時段 pps 偏高 — 有何活動?)"
        fi
        printf "  ${pps_state} rx pps            %10d${pps_hint}\n" "${RX_PPS:-0}"
        printf "  🟢 tx pps            %10d\n" "${TX_PPS:-0}"
        printf "  🟢 rx / tx MB/s      %6s / %-6s\n" "${RX_MBPS:-0}" "${TX_MBPS:-0}"
        echo
    fi

    # TCP retrans (股票嚴格閾值)
    local tseg tret retrans_pct ret_state="🟢"
    tseg=$(awk '/^Tcp:/ && h++{print $11}' /proc/net/snmp | head -1)
    tret=$(awk '/^Tcp:/ && h++{print $13}' /proc/net/snmp | head -1)
    if [ -n "${tseg}" ] && [ "${tseg}" -gt 0 ]; then
        retrans_pct=$(awk -v r="${tret}" -v s="${tseg}" 'BEGIN{printf "%.4f",(r/s)*100}')
        awk -v p="${retrans_pct}" -v w="${TCP_RETRANS_TRADING_WARN_PCT:-0.01}" 'BEGIN{exit !(p>=w)}' && ret_state="🟡"
        awk -v p="${retrans_pct}" -v f="${TCP_RETRANS_TRADING_FAIL_PCT:-0.1}" 'BEGIN{exit !(p>=f)}' && ret_state="🔴"
    else
        retrans_pct="N/A"
    fi
    echo "── 延遲 / 重送 (股票嚴格閾值) ──"
    printf "  %s TCP retransmit     %s%%    (WARN ≥ %s / FAIL ≥ %s)\n" \
        "${ret_state}" "${retrans_pct}" "${TCP_RETRANS_TRADING_WARN_PCT:-0.01}" "${TCP_RETRANS_TRADING_FAIL_PCT:-0.1}"
    echo

    # 交易所 gateway
    if [ -n "${EXCHANGE_GATEWAYS:-}" ]; then
        echo "── 交易所連線 (from trading.conf) ──"
        for gw in ${EXCHANGE_GATEWAYS}; do
            ping_gateway "${gw}"
        done
        echo
    fi

    # FIX sessions
    if [ -n "${FIX_PORTS:-}" ]; then
        echo "── FIX / 交易 port session 數 ──"
        for port in ${FIX_PORTS}; do
            local n
            n=$(count_fix_sessions "${port}")
            printf "  🟢 port %-6s       %d 條 session\n" "${port}" "${n}"
        done
        echo
    fi

    # Multicast
    if [ -n "${MCAST_GROUPS:-}" ]; then
        echo "── Multicast 行情訂閱 ──"
        for grp in ${MCAST_GROUPS}; do
            check_mcast "${grp}"
        done
        echo
    fi

    # IRQ 分布
    echo "── NIC IRQ 分布 (檢查 CPU affinity 是否均勻) ──"
    irq_balance
    echo

    # NTP 偏差 (股票要求 ms 等級)
    if command -v chronyc >/dev/null 2>&1; then
        local ntp_offset
        ntp_offset=$(chronyc tracking 2>/dev/null | awk '/Last offset/{print $4}')
        local ntp_state="🟢"
        if [ -n "${ntp_offset}" ]; then
            local abs_off="${ntp_offset#-}"
            local off_ms
            off_ms=$(awk -v s="${abs_off}" 'BEGIN{printf "%.3f", s*1000}')
            awk -v m="${off_ms}" -v w="${NTP_DRIFT_WARN_MS:-5}" 'BEGIN{exit !(m>=w)}' && ntp_state="🟡"
            awk -v m="${off_ms}" -v f="${NTP_DRIFT_FAIL_MS:-50}" 'BEGIN{exit !(m>=f)}' && ntp_state="🔴"
            echo "── 時間同步 ──"
            printf "  %s NTP 偏差         %+.3f s (%.3f ms)\n" "${ntp_state}" "${ntp_offset}" "${off_ms}"
            echo
        fi
    fi

    echo "──────────────────────────────────────────────"
    echo "提示: 按 s 進入 5 分鐘 sparkline 即時監控 (下一版 lite-v0.3 實作)"
    echo

    audit_log "Trading dashboard" "OK" "phase=${phase}"
    pause
}

run_dashboard
