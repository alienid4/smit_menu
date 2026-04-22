#!/bin/bash
# mod_sfp.sh - 光纖模組 SFP/GBIC DDM 監控 (lite-v0.2)
# 用 ethtool -m 讀 I2C EEPROM 的 Digital Diagnostic Monitoring 數值
#
# 能抓什麼：溫度、電壓、Laser bias、TX/RX 光功率
# 老化判定：跟 baseline 比對 delta，bias 升 20% / 光功率掉 2 dB 視為 WARN
#
# 限制（啟動時會告知）：
#   - VM 通常無實體 SFP，除非 SR-IOV / PCI passthrough
#   - RJ45 銅纜網卡沒光學資料
#   - 便宜 SFP 無 DDM 支援
#
# CLI:
#   mod_sfp.sh              互動選單
#   mod_sfp.sh --scan       掃一次 + timeline append (供 cron 每日跑)
#   mod_sfp.sh --init       記錄 baseline (新裝模組時一次)
#   mod_sfp.sh --csv        輸出 timeline CSV
#   mod_sfp.sh --aging      僅列老化徵兆
_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_HERE}/LinuxMenu.sh" 2>/dev/null
: "${YEL:=\033[1;33m}"; : "${RED:=\033[0;31m}"; : "${RST:=\033[0m}"

BASELINE="${CASLOG_REPORT}/sfp_baseline.csv"
TIMELINE="${CASLOG_REPORT}/sfp_timeline.csv"
mkdir -p "${CASLOG_REPORT}"

# ─── 門檻 ───
TEMP_WARN_C=70
TEMP_FAIL_C=85
VOLTAGE_LO=3.0
VOLTAGE_HI=3.6
BIAS_DELTA_WARN_PCT=20    # bias 上升 ≥20% 視為老化徵兆
BIAS_DELTA_FAIL_PCT=50
POWER_DELTA_WARN_DB=2     # 光功率掉 ≥2 dB
POWER_DELTA_FAIL_DB=4

# ─── 環境偵測 ───
VIRT=""
detect_virt() {
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        VIRT=$(systemd-detect-virt 2>/dev/null)
    elif grep -qE "hypervisor" /proc/cpuinfo 2>/dev/null; then
        VIRT="virtualized"
    else
        VIRT="none"
    fi
}

env_note() {
    detect_virt
    if [ "${VIRT}" != "none" ] && [ -n "${VIRT}" ]; then
        echo "──────────────────────────────────────────────"
        echo " 偵測到虛擬化環境: ${VIRT}"
        echo " 一般 VM 無實體 SFP 模組，多數網卡會回 \"cannot get module info\"。"
        echo " 若此主機是 PCI Passthrough 或 SR-IOV 直通，可能仍有資料。"
        echo "──────────────────────────────────────────────"
        echo
    fi
}

# ─── SFP 資料解析 ───
# 輸入: ethtool -m 輸出
# 輸出: TAB 分隔 vendor pn sn date temp voltage bias tx_dbm rx_dbm
parse_eeprom() {
    local output="$1"
    local vendor pn sn date temp voltage bias tx rx
    vendor=$(echo "${output}"  | awk -F': +' '/Vendor name/{print $2}' | head -1 | tr -d ' ')
    pn=$(echo "${output}"      | awk -F': +' '/Vendor PN/{print $2}' | head -1 | tr -d ' ')
    sn=$(echo "${output}"      | awk -F': +' '/Vendor SN/{print $2}' | head -1 | tr -d ' ')
    date=$(echo "${output}"    | awk -F': +' '/Date code/{print $2}' | head -1 | tr -d ' ')
    temp=$(echo "${output}"    | awk -F': +' '/Module temperature/{print $2}' | awk '{print $1}')
    voltage=$(echo "${output}" | awk -F': +' '/Module voltage/{print $2}' | awk '{print $1}')
    bias=$(echo "${output}"    | awk -F': +' '/Laser bias current/{print $2}' | awk '{print $1}')
    tx=$(echo "${output}"      | awk -F': +' '/Laser output power|Laser tx power/{print $2}' | head -1 | awk '{for(i=1;i<=NF;i++)if($i~/dBm/)print $(i-1)}')
    rx=$(echo "${output}"      | awk -F': +' '/Receiver signal average optical power|Rx power/{print $2}' | head -1 | awk '{for(i=1;i<=NF;i++)if($i~/dBm/)print $(i-1)}')
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "${vendor:-N/A}" "${pn:-N/A}" "${sn:-N/A}" "${date:-N/A}" \
        "${temp:-N/A}" "${voltage:-N/A}" "${bias:-N/A}" "${tx:-N/A}" "${rx:-N/A}"
}

# ─── 掃單一網卡 ───
# 回傳: "iface|vendor|pn|sn|date|temp|voltage|bias|tx|rx" 或 "iface|SKIP|原因"
scan_nic() {
    local nic="$1"
    local operstate
    operstate=$(cat /sys/class/net/${nic}/operstate 2>/dev/null)
    if ! command -v ethtool >/dev/null 2>&1; then
        echo "${nic}|SKIP|未裝 ethtool"
        return
    fi
    local out
    out=$(timeout 3 ethtool -m "${nic}" 2>&1)
    local rc=$?
    if [ $rc -ne 0 ] || echo "${out}" | grep -qiE "cannot get module|not supported|no such|no module"; then
        echo "${nic}|SKIP|無 SFP 或不支援 DDM (${operstate})"
        return
    fi
    local data
    data=$(parse_eeprom "${out}")
    echo "${nic}|OK|${data//$'\t'/|}"
}

# ─── 全主機掃描 ───
scan_all() {
    env_note
    local found=0
    for nic in $(ls /sys/class/net/ 2>/dev/null | grep -vE '^(lo|docker|veth|br-|virbr|tun|tap)'); do
        local line
        line=$(scan_nic "${nic}")
        local status=$(echo "${line}" | cut -d'|' -f2)
        if [ "${status}" = "OK" ]; then
            found=$((found+1))
            parse_and_print "${line}"
            echo
        fi
    done
    if [ "${found}" -eq 0 ]; then
        echo "本機未偵測到任何可讀 SFP 模組。"
        [ "${VIRT}" != "none" ] && echo "(正常；VM 環境或 RJ45 網卡)"
    fi
}

# 比對 baseline 產出人類可讀報表
parse_and_print() {
    local line="$1"
    IFS='|' read -r nic _ vendor pn sn date temp voltage bias tx rx <<<"${line}"
    local days_installed="N/A"
    local b_temp="N/A" b_voltage="N/A" b_bias="N/A" b_tx="N/A" b_rx="N/A" b_date="N/A"
    # 找 baseline
    if [ -f "${BASELINE}" ]; then
        local row
        row=$(awk -F, -v n="${nic}" -v s="${sn}" '$2==n && $5==s' "${BASELINE}" | head -1)
        if [ -n "${row}" ]; then
            b_date=$(echo "${row}"    | cut -d, -f1)
            b_temp=$(echo "${row}"    | cut -d, -f6)
            b_voltage=$(echo "${row}" | cut -d, -f7)
            b_bias=$(echo "${row}"    | cut -d, -f8)
            b_tx=$(echo "${row}"      | cut -d, -f9)
            b_rx=$(echo "${row}"      | cut -d, -f10)
            # 計算天數差
            local b_epoch now_epoch
            b_epoch=$(date -d "${b_date}" +%s 2>/dev/null)
            now_epoch=$(date +%s)
            [ -n "${b_epoch}" ] && days_installed=$(( (now_epoch - b_epoch) / 86400 ))
        fi
    fi

    # 狀態判定
    local s_temp="PASS" s_vol="PASS" s_bias="PASS" s_tx="PASS" s_rx="PASS"
    _num_ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0>=b+0)}'; }
    _num_lt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0<b+0)}'; }

    [ "${temp}" != "N/A" ] && {
        _num_ge "${temp}" "${TEMP_WARN_C}" && s_temp="WARN"
        _num_ge "${temp}" "${TEMP_FAIL_C}" && s_temp="FAIL"
    }
    [ "${voltage}" != "N/A" ] && {
        _num_lt "${voltage}" "${VOLTAGE_LO}" && s_vol="WARN"
        _num_ge "${voltage}" "${VOLTAGE_HI}" && s_vol="WARN"
    }

    # 老化：bias 上升 %
    local bias_delta_pct="-"
    if [ "${bias}" != "N/A" ] && [ "${b_bias}" != "N/A" ] && [ "${b_bias}" != "-" ]; then
        bias_delta_pct=$(awk -v c="${bias}" -v b="${b_bias}" 'BEGIN{if(b>0)printf "%+.0f",((c-b)/b)*100}')
        if [ -n "${bias_delta_pct}" ]; then
            local abs_delta="${bias_delta_pct#+}"
            _num_ge "${abs_delta}" "${BIAS_DELTA_WARN_PCT}" && s_bias="WARN"
            _num_ge "${abs_delta}" "${BIAS_DELTA_FAIL_PCT}" && s_bias="FAIL"
        fi
    fi

    # 老化：光功率下降 dB
    local tx_delta="-" rx_delta="-"
    if [ "${tx}" != "N/A" ] && [ "${b_tx}" != "N/A" ] && [ "${b_tx}" != "-" ]; then
        tx_delta=$(awk -v c="${tx}" -v b="${b_tx}" 'BEGIN{printf "%+.1f", c-b}')
        local abs_tx="${tx_delta#-}"; abs_tx="${abs_tx#+}"
        _num_ge "${abs_tx}" "${POWER_DELTA_WARN_DB}" && s_tx="WARN"
        _num_ge "${abs_tx}" "${POWER_DELTA_FAIL_DB}" && s_tx="FAIL"
    fi
    if [ "${rx}" != "N/A" ] && [ "${b_rx}" != "N/A" ] && [ "${b_rx}" != "-" ]; then
        rx_delta=$(awk -v c="${rx}" -v b="${b_rx}" 'BEGIN{printf "%+.1f", c-b}')
        local abs_rx="${rx_delta#-}"; abs_rx="${abs_rx#+}"
        _num_ge "${abs_rx}" "${POWER_DELTA_WARN_DB}" && s_rx="WARN"
        _num_ge "${abs_rx}" "${POWER_DELTA_FAIL_DB}" && s_rx="FAIL"
    fi

    # 輸出 (inline emoji 函式改 case inline)
    _em() { case "$1" in PASS) echo "🟢" ;; WARN) echo "🟡" ;; FAIL) echo "🔴" ;; *) echo "⚪";; esac; }
    echo "  ${nic} (${vendor} ${pn}, SN:${sn}, 出廠:${date})"
    [ "${days_installed}" != "N/A" ] && echo "    └ 首次記錄: ${b_date} (${days_installed} 天前)"
    printf "    ├ %s 溫度      %6s °C    基準 %-6s          [<${TEMP_WARN_C} 正常 / ≥${TEMP_WARN_C} 警告 / ≥${TEMP_FAIL_C} 危險] ↓\n" "$(_em "${s_temp}")" "${temp}" "${b_temp}"
    printf "    ├ %s 電壓      %6s V     基準 %-6s          [${VOLTAGE_LO}-${VOLTAGE_HI} V 正常]                              =\n" "$(_em "${s_vol}")" "${voltage}" "${b_voltage}"
    printf "    ├ %s Laser bias %6s mA   基準 %-6s  Δ%-5s  [< 基準 +${BIAS_DELTA_WARN_PCT}%% 正常，超過 = 老化] ↓\n" "$(_em "${s_bias}")" "${bias}" "${b_bias}" "${bias_delta_pct:--}%"
    printf "    ├ %s TX 光功率 %6s dBm   基準 %-6s  Δ%-5s  [<${POWER_DELTA_WARN_DB}dB drop 正常] ↑\n" "$(_em "${s_tx}")" "${tx}" "${b_tx}" "${tx_delta:--}"
    printf "    └ %s RX 光功率 %6s dBm   基準 %-6s  Δ%-5s  [<${POWER_DELTA_WARN_DB}dB drop 正常] ↑\n" "$(_em "${s_rx}")" "${rx}" "${b_rx}" "${rx_delta:--}"

    # Action hint
    if [ "${s_tx}" != "PASS" ] || [ "${s_rx}" != "PASS" ] || [ "${s_bias}" != "PASS" ]; then
        echo "    ⚠️  建議:"
        [ "${s_rx}" != "PASS" ] && echo "       - 清潔對端光纖接頭 (RX 光功率下降)"
        [ "${s_tx}" != "PASS" ] && echo "       - 檢查本端 SFP laser (TX 光功率下降)"
        [ "${s_bias}" != "PASS" ] && echo "       - Laser bias 上升，排程下次維運窗口換備品比對"
        [ "${days_installed}" != "N/A" ] && [ "${days_installed}" -gt 730 ] && \
            echo "       - 模組已服役 ${days_installed} 天 (>2 年)，可預防性更換"
    fi
}

# ─── Timeline CSV append ───
append_timeline() {
    env_note >/dev/null
    if [ ! -f "${TIMELINE}" ]; then
        echo "ts,iface,vendor,pn,sn,date,temp_c,voltage_v,bias_ma,tx_dbm,rx_dbm" > "${TIMELINE}"
        chmod 640 "${TIMELINE}"
    fi
    local ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    for nic in $(ls /sys/class/net/ 2>/dev/null | grep -vE '^(lo|docker|veth|br-|virbr|tun|tap)'); do
        local line
        line=$(scan_nic "${nic}")
        local status=$(echo "${line}" | cut -d'|' -f2)
        [ "${status}" = "OK" ] || continue
        IFS='|' read -r _ _ vendor pn sn date temp voltage bias tx rx <<<"${line}"
        echo "${ts},${nic},${vendor},${pn},${sn},${date},${temp},${voltage},${bias},${tx},${rx}" >> "${TIMELINE}"
    done
    echo "[sfp] ${ts} timeline 已 append → ${TIMELINE}"
    audit_log "SFP scan" "OK" "timeline ${TIMELINE}"
}

# ─── Baseline init ───
init_baseline() {
    env_note
    : > "${BASELINE}"
    echo "ts,iface,vendor,pn,sn,date,temp_c,voltage_v,bias_ma,tx_dbm,rx_dbm" > "${BASELINE}"
    chmod 640 "${BASELINE}"
    local ts=$(date '+%Y-%m-%d')
    local count=0
    for nic in $(ls /sys/class/net/ 2>/dev/null | grep -vE '^(lo|docker|veth|br-|virbr|tun|tap)'); do
        local line
        line=$(scan_nic "${nic}")
        local status=$(echo "${line}" | cut -d'|' -f2)
        [ "${status}" = "OK" ] || continue
        IFS='|' read -r _ _ vendor pn sn date temp voltage bias tx rx <<<"${line}"
        echo "${ts},${nic},${vendor},${pn},${sn},${date},${temp},${voltage},${bias},${tx},${rx}" >> "${BASELINE}"
        echo "  記錄 baseline: ${nic} (${vendor} ${pn} SN:${sn})"
        count=$((count+1))
    done
    echo
    echo "共記錄 ${count} 個 SFP 模組。"
    [ "${count}" -eq 0 ] && rm -f "${BASELINE}" && echo "(未找到 SFP，baseline 未建立)" && return 1
    echo "之後 --scan 會跟此 baseline 比對老化徵兆。"
    audit_log "SFP baseline init" "OK" "${count} modules"
}

# ─── 互動選單 ───
interactive() {
    while true; do
        clear
        echo "======================================================"
        echo " 光纖模組 SFP / GBIC 監控"
        echo "======================================================"
        echo "  1) 掃描 + 顯示 (含 baseline 比對)"
        echo "  2) 記錄 baseline (新裝模組時執行一次)"
        echo "  3) Timeline CSV 路徑與行數"
        echo "  4) Baseline 檔案內容"
        echo "  5) 僅列老化徵兆 (WARN/FAIL)"
        echo "  6) 顯示建議的 cron"
        echo "  b) 返回主選單"
        echo "======================================================"
        read -r -p "選擇 > " c || exit 0
        case "$c" in
            1) run_cmd "SFP scan"          scan_all ;;
            2) run_cmd "SFP baseline init" init_baseline ;;
            3) run_cmd "Timeline info"     bash -c "ls -la '${TIMELINE}' 2>/dev/null && wc -l '${TIMELINE}' 2>/dev/null || echo '(無 timeline，先跑 --scan)'" ;;
            4) run_cmd "Baseline content"  bash -c "[ -f '${BASELINE}' ] && cat '${BASELINE}' || echo '(無 baseline，請先 2) init)'" ;;
            5) run_cmd "Aging only"        bash -c 'scan_all 2>&1 | grep -E "🟡|🔴|建議:|─|老化"' ;;
            6) cat <<EOF
建議 cron：每日 06:00 記錄 SFP 數值 (用於趨勢分析)

  /etc/cron.d/linuxmenu-sfp:
    SHELL=/bin/bash
    PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

    0 6 * * * root  bash ${CASLOG_SCRIPT}/mod_sfp.sh --scan >> ${CASLOG_LOG}/sfp.log 2>&1

EOF
               ;;
            b|B) exit 0 ;;
            *)   echo "無效選項" ;;
        esac
        pause
    done
}

# ─── CLI ───
case "${1:-}" in
    --scan)   append_timeline; exit 0 ;;
    --init)   init_baseline; exit $? ;;
    --csv)    cat "${TIMELINE}" 2>/dev/null || echo "(無 timeline)"; exit 0 ;;
    --aging)  scan_all 2>&1 | grep -E "🟡|🔴|建議" ; exit 0 ;;
    --help|-h)
        cat <<EOF
用法:
  mod_sfp.sh              互動選單
  mod_sfp.sh --scan       掃一次 + timeline append (cron 用)
  mod_sfp.sh --init       記錄 baseline
  mod_sfp.sh --csv        輸出 timeline CSV
  mod_sfp.sh --aging      僅列老化徵兆
EOF
        exit 0 ;;
    "")
        if [ "${BASH_SOURCE[0]}" = "$0" ]; then
            interactive
        fi
        ;;
esac
